// Cooperative kernel-thread scheduler (round-robin).
//
// Each thread has its own kernel stack and a saved stack pointer. Switching
// threads means saving the current thread's callee-saved registers + rsp onto
// its stack, then loading the next thread's rsp and restoring — `switchContext`
// does this in assembly and "returns" into the new thread.
//
// This first version is COOPERATIVE: a thread runs until it calls yield(). A
// later step makes it preemptive by calling yield() from the timer interrupt.

const serial = @import("../drivers/serial.zig");
const kstack = @import("kstack.zig"); // guarded kernel stacks (unmapped guard page per stack)
const pic = @import("../arch/pic.zig"); // timer tick hook + tick counter
const sync = @import("sync.zig"); // honor the print lock (don't switch mid-print)
const mutex = @import("mutex.zig"); // blocking Mutex (used by the mutex self-test)
const vmm = @import("../mm/vmm.zig"); // per-process address spaces (CR3 switch)
const gdt = @import("../arch/gdt.zig"); // TSS.rsp0 (kernel stack for user traps)
const syscall = @import("../arch/syscall.zig"); // per-process syscall kernel stack
const usermode = @import("../arch/usermode.zig"); // enterRing3 (first user dispatch)
const pmm = @import("../mm/pmm.zig"); // frames for the demo's user pages
const tty = @import("../tty.zig"); // terminal foreground + Ctrl-C interrupt flag
const vfs = @import("../fs/vfs.zig"); // VFS open-file handle for open file descriptors

const MAX_THREADS = 16; // also the number of guarded stack slots (kstack.MAX_STACKS)

// --- Per-process file-descriptor table ---------------------------------------
// A process refers to an open file by a small integer (a "file descriptor"). The
// kernel keeps, per process, a fixed-size array mapping each descriptor to the
// open file it names; an empty slot is `null`. By POSIX convention the first
// three descriptors are reserved: 0 = stdin, 1 = stdout, 2 = stderr. We don't
// model real stdin/stdout files yet (writes to fd 1/2 still go straight to the
// serial console), so those slots stay `null` and are simply never handed out by
// open(); a freshly opened file gets the LOWEST free descriptor at or above 3.
pub const FD_MAX = 16; // descriptors 0..15 per process (0/1/2 reserved)
pub const FD_FIRST_FREE: usize = 3; // open() allocates from here up (0/1/2 reserved)

// One open file: a VFS handle that tracks where in the file we are. Routing this
// through the VFS (rather than a raw FAT32 cursor) is what lets a descriptor name a
// file on ANY mounted backend — the FAT32 disk, /tmp (tmpfs), or /dev (devfs) —
// instead of only the FAT32 disk. `dup` makes a second descriptor refer to the same
// file; we model that by copying the cursor (each fd then has its own independent
// position). Reference-counted shared offsets are a later refinement once real
// shared-fd semantics (e.g. dup2 onto a pipe) are needed.
// NOTE: vfs.OpenFile carries a fixed inline reader buffer, so it is larger than the
// old bare FAT32 cursor; with FD_MAX=16 and MAX_THREADS=16 the per-process fd tables
// grow to ~a few hundred KiB of static .bss in total — fine for this kernel.
pub const OpenFile = struct {
    file: vfs.OpenFile, // the VFS streaming handle (backend + cursor + offset)
};

// The low-level context switch, written in assembly (a normal Zig function with
// a compiler prologue would corrupt the hand-managed stack). It saves the
// callee-saved registers + rsp into *old, loads rsp from new, restores, and
// `ret`s — so control resumes wherever the new thread last left off. Args follow
// the C ABI: old -> rdi, new -> rsi.
extern fn switchContext(old: *u64, new: u64) callconv(.c) void;
comptime {
    asm (
        \\.global switchContext
        \\.type switchContext, @function
        \\switchContext:
        \\  push %rbp
        \\  push %rbx
        \\  push %r12
        \\  push %r13
        \\  push %r14
        \\  push %r15
        \\  mov %rsp, (%rdi)
        \\  mov %rsi, %rsp
        \\  pop %r15
        \\  pop %r14
        \\  pop %r13
        \\  pop %r12
        \\  pop %rbx
        \\  pop %rbp
        \\  ret
    );
}

// A thread's life-cycle state.
//   .ready    - runnable, waiting its turn on the CPU
//   .running  - currently on the CPU
//   .blocked  - asleep / waiting on an event (sleep, mutex, wait queue)
//   .finished - done, and nobody is interested in its exit code: the slot can be
//               reused on the next spawn (the historical "dead, forget it" state).
//   .zombie   - done, BUT it left an exit code a waiter still wants to collect.
//               The slot is NOT reused until someone wait()s on it and reaps it
//               (which flips it back to a free .finished slot). This is the Unix
//               "zombie process" idea: a finished child lingers just long enough
//               for its parent to read how it ended, then disappears. Without this
//               the exit code would be lost the instant the child stopped running.
const State = enum { ready, running, finished, blocked, zombie };

const Thread = struct {
    rsp: u64, // saved stack pointer (points at the saved context)
    stack: []u8, // the thread's kernel stack (empty for the main thread)
    state: State,
    name: []const u8,
    entry: *const fn () void = undefined, // the function the thread runs
    wake_tick: u64 = 0, // if sleeping, the tick at which to wake (0 = not sleeping)
    // Exit code a finished/zombie thread left behind. Only meaningful once the
    // thread reaches .zombie (a waiter reads it, then reaps the slot). 0 otherwise.
    exit_code: u64 = 0,
    // Process fields (0/unused for plain kernel threads):
    pml4: u64 = 0, // address space to run in (0 = the shared kernel space)
    kstack_top: u64 = 0, // ring-0 stack top for this thread's traps/syscalls
    user_entry: u64 = 0, // ring-3 entry point (user processes only)
    user_stack: u64 = 0, // ring-3 stack top (user processes only)
    // Per-process open-file table. Every slot starts empty (`null`); the file
    // syscalls (open/close/read/lseek/dup) hand out and reclaim slots. Kernel
    // threads have one too but never use it — they don't make file syscalls.
    fd: [FD_MAX]?OpenFile = [_]?OpenFile{null} ** FD_MAX,
};

var threads: [MAX_THREADS]Thread = undefined;
var thread_count: usize = 0;
var current: usize = 0; // index of the running thread
var alive: usize = 0; // number of non-finished worker threads (atomic)
var preempting: bool = false; // true while timer-driven preemption is enabled
var current_as: u64 = 0; // address space currently in CR3 (0 = not yet established)

// Atomic accessor for `alive` so a busy-wait reader sees worker updates.
pub fn aliveCount() usize {
    return @atomicLoad(usize, &alive, .monotonic);
}

// Adopt the current (boot) context as thread 0. Its rsp gets filled in by the
// first switchContext that leaves it.
fn setupMain() void {
    threads[0] = .{ .rsp = 0, .stack = &.{}, .state = .running, .name = "main" };
    thread_count = 1;
    current = 0;
    alive = 0;
}

// Find a thread-table slot for a new thread. Prefer reusing a slot that a finished
// thread left behind (state .finished, already reaped — its exit code collected and
// the slot relinquished), since that frees no kernel stack but lets the table not
// grow without bound; otherwise append a fresh slot. Returns the slot index, or
// null if the table is full of live/zombie threads. Reusing a reaped slot is what
// makes "reaping" observable: a slot a wait()ed-on child vacated gets handed to the
// next spawn. We never reuse a .zombie slot — its exit code is still owed to a waiter.
//
// IMPORTANT: a reused slot keeps the kernel stack it was first given (kstack slots
// are indexed by thread-table position and are never freed). kstack.alloc() is
// idempotent — asked for an already-mapped slot it hands back the SAME stack — so
// spawn/spawnUser can call it unconditionally whether the slot is fresh or reused.
fn findFreeSlot() ?usize {
    var i: usize = 1; // never reuse slot 0 (the idle/main thread)
    while (i < thread_count) : (i += 1) {
        if (threads[i].state == .finished) return i; // a reaped slot — reuse it
    }
    if (thread_count < MAX_THREADS) return thread_count; // else append a fresh one
    return null; // table full of live/zombie threads
}

// Create a thread that will start executing `func`. We hand-build its stack so
// the first switchContext "returns" into func, and so that if func ever returns
// it lands in threadExit.
pub fn spawn(name: []const u8, func: *const fn () void) void {
    const idx = findFreeSlot() orelse return; // reuse a reaped slot, or append
    const appending = idx == thread_count; // a brand-new slot grows the table
    // Guarded kernel stack keyed to this slot index. alloc() is idempotent, so a
    // reused (reaped) slot gets back its original stack rather than fresh frames.
    const gs = kstack.alloc(idx) orelse {
        serial.log("[SCHED]   failed to allocate a thread stack\n", .{});
        return;
    };
    const stack = @as([*]u8, @ptrFromInt(gs.bottom))[0 .. gs.top - gs.bottom]; // record of the mapped region

    // 16-byte-aligned top. After switchContext's `ret` pops `func`, rsp will be
    // (top - 8), i.e. 8 mod 16 — the alignment the ABI expects at a call entry.
    const top = gs.top & ~@as(usize, 0xF); // page-aligned already; mask kept for clarity
    var sp: usize = top;
    push(&sp, @intFromPtr(&threadExit)); // where the thread lands if it returns
    push(&sp, @intFromPtr(&threadStart)); // switchContext's `ret` enters the trampoline
    for (0..6) |_| push(&sp, 0); // saved rbp, rbx, r12, r13, r14, r15

    threads[idx] = .{ .rsp = sp, .stack = stack, .state = .ready, .name = name, .entry = func, .kstack_top = top };
    if (appending) thread_count += 1;
    _ = @atomicRmw(usize, &alive, .Add, 1, .monotonic);
}

// Prepare the CPU to run thread `idx`: point the kernel-trap and syscall stacks at
// its kernel stack, and switch CR3 if it lives in a different address space than
// the one currently loaded. Called just before switchContext. Kernel threads use
// the shared kernel space; only switches involving a process touch CR3.
fn applyContext(idx: usize) void {
    const t = &threads[idx];
    if (t.kstack_top != 0) { // where a trap/syscall from this thread should land
        gdt.setKernelStack(t.kstack_top);
        syscall.setKernelStack(t.kstack_top);
    }
    const target = if (t.pml4 != 0) t.pml4 else vmm.kernelSpace();
    if (target != current_as) {
        vmm.switchTo(target);
        current_as = target;
    }
}

// First thing a new thread runs: enable interrupts (so it's preemptible — a
// preemptive switch enters here with interrupts masked), then call its function.
// If the function returns, we fall through to threadExit (the address above us).
fn threadStart() void {
    asm volatile ("sti"); // become preemptible
    threads[current].entry(); // run the thread's body
}

// Push a value onto a hand-built stack (grows down).
fn push(sp: *usize, value: usize) void {
    sp.* -= 8;
    @as(*usize, @ptrFromInt(sp.*)).* = value;
}

// Switch to the next ready thread (round-robin). Interrupt-flag-aware: it
// captures the caller's IF, masks interrupts across the switch (so the thread
// table isn't touched re-entrantly), and restores IF when this thread resumes.
// This lets blocking code (sleep/mutex) call yield cooperatively while
// preemption is on; it's also safe when called from the timer IRQ (IF already 0).
pub fn yield() void {
    var flags: u64 = undefined;
    asm volatile ("pushfq; popq %[f]; cli"
        : [f] "=r" (flags),
        :
        : "memory"
    );
    const if_was = (flags & 0x200) != 0; // bit 9 = interrupt-enable flag

    const prev = current;
    var i: usize = 1;
    while (i <= thread_count) : (i += 1) {
        const cand = (prev + i) % thread_count; // round-robin from prev+1
        if (threads[cand].state == .ready) {
            if (threads[prev].state == .running) threads[prev].state = .ready;
            threads[cand].state = .running;
            current = cand;
            applyContext(cand); // set the kernel/syscall stacks + CR3 for the incoming thread
            switchContext(&threads[prev].rsp, threads[cand].rsp);
            break; // resumes here when we're switched back to
        }
    }
    // If only the current thread is ready we keep running it; either way restore
    // the interrupt flag we came in with.
    if (if_was) asm volatile ("sti");
}

// The timer-tick hook: wake any sleepers whose deadline has passed, then preempt
// (unless the print lock forbids switching right now). Runs in the timer IRQ.
fn tick() void {
    const now = pic.ticks();
    for (threads[0..thread_count]) |*t| {
        if (t.state == .blocked and t.wake_tick != 0 and now >= t.wake_tick) {
            t.state = .ready; // its sleep is over
            t.wake_tick = 0;
        }
    }
    if (!sync.preemptDisabled()) yield(); // don't switch mid-print
}

// Block the current thread for `ticks` timer ticks (100 Hz). It gives up the CPU
// entirely (the idle thread / other threads run) and the timer wakes it.
pub fn sleep(ticks: u64) void {
    asm volatile ("cli"); // set our wake time + state atomically vs the timer
    threads[current].wake_tick = pic.ticks() + ticks;
    threads[current].state = .blocked;
    yield(); // switch away (IF is 0, so yield won't re-enable); we resume when woken
    asm volatile ("sti"); // back on the CPU; re-enable interrupts
}

// The running thread's id (e.g. so it can register itself to be woken later).
pub fn currentId() usize {
    return current;
}

// The currently-running process's open-file table. The file syscalls call this to
// read and mutate the caller's descriptors. It's a pointer into the live thread
// slot, so changes (open/close/dup) persist for the process. Single-core +
// syscalls-run-with-interrupts-masked means no locking is needed here.
pub fn currentFdTable() *[FD_MAX]?OpenFile {
    return &threads[current].fd;
}

// Empty the current process's descriptor table (every slot -> null). Used by the
// file-syscall boot self-test to start from a known-clean table; real process
// teardown will reuse this idea once it frees a process's fds on exit.
pub fn resetCurrentFds() void {
    threads[current].fd = [_]?OpenFile{null} ** FD_MAX;
}

// Find the lowest free descriptor at or above FD_FIRST_FREE in `table` (0/1/2 are
// reserved for stdin/stdout/stderr and never handed out by open/dup). Returns the
// index, or null if every slot is taken. A pure helper so the allocation policy
// can be unit-tested without a live process.
fn lowestFreeFd(table: *const [FD_MAX]?OpenFile) ?usize {
    var i: usize = FD_FIRST_FREE;
    while (i < FD_MAX) : (i += 1) {
        if (table[i] == null) return i; // first empty slot, lowest index first
    }
    return null; // table full
}

// Allocate the lowest free descriptor for `file` in the current process's table,
// returning the fd, or null if the table is full. The file syscalls (open, dup)
// go through here so the "lowest free fd" rule lives in exactly one place.
pub fn allocFd(file: OpenFile) ?usize {
    const table = currentFdTable();
    const i = lowestFreeFd(table) orelse return null;
    table[i] = file;
    return i;
}

// Block the current thread indefinitely until wake() is called on it (event
// wait — e.g. hibernating until a key is pressed). The caller MUST hold
// interrupts disabled so the wakeup can't be lost between deciding to block and
// blocking; on resume interrupts are still disabled and the caller re-enables.
pub fn block() void {
    blockTimeout(0);
}

// Like block(), but also wakes after `timeout` ticks if nothing wakes us sooner
// (timeout 0 = block indefinitely). The timer's tick() readies us at the deadline,
// and wake() readies us earlier; either way we resume just after the yield(). Same
// contract as block(): the caller MUST hold interrupts disabled (so a wake can't be
// lost between deciding to block and blocking), and we resume with them disabled.
// The WaitQueue uses the timeout as a safety net against a missed device interrupt.
pub fn blockTimeout(timeout: u64) void {
    threads[current].wake_tick = if (timeout != 0) pic.ticks() + timeout else 0;
    threads[current].state = .blocked;
    yield();
}

// Make a blocked thread runnable again. Safe to call from interrupt context.
pub fn wake(id: usize) void {
    if (id < thread_count and threads[id].state == .blocked) {
        threads[id].state = .ready;
        threads[id].wake_tick = 0;
    }
}

// Where a thread lands if its entry function returns: mark it finished and yield
// away forever (a finished thread is never switched back to).
fn threadExit() noreturn {
    // When preempting, mask interrupts so a timer tick can't preempt us mid-exit
    // (the thread we switch to restores its own interrupt flag via iretq/sti).
    if (preempting) asm volatile ("cli");
    threads[current].state = .finished;
    _ = @atomicRmw(usize, &alive, .Sub, 1, .monotonic);
    yield();
    unreachable;
}

// --- User processes ----------------------------------------------------------
// Create a user process: a thread that begins in ring 3 at `user_entry` (stack
// `user_stack`) inside address space `pml4`. Like spawn(), the kernel stack is
// hand-built so the first switchContext "returns" into a trampoline — userStart,
// which drops to ring 3. The kernel stack also catches the process's syscalls and
// traps (applyContext points TSS.rsp0 / the syscall stack at it while it runs).
// Returns true on success, or false if it couldn't start the process (the thread
// table is full or the kernel stack allocation failed) — the caller must check
// this and NOT wait on a process that was never created (see runUser).
pub fn spawnUser(name: []const u8, user_entry: u64, user_stack: u64, pml4: u64) bool {
    const idx = findFreeSlot() orelse return false; // reuse a reaped slot, or append
    const appending = idx == thread_count; // a brand-new slot grows the table
    const gs = kstack.alloc(idx) orelse { // guarded kernel stack (idempotent for a reused slot)
        serial.log("[SCHED]   failed to allocate a user kernel stack\n", .{});
        return false;
    };
    const stack = @as([*]u8, @ptrFromInt(gs.bottom))[0 .. gs.top - gs.bottom]; // record of the mapped region
    const top = gs.top & ~@as(usize, 0xF);
    var sp: usize = top;
    push(&sp, @intFromPtr(&threadExit)); // fallback (userStart never returns here)
    push(&sp, @intFromPtr(&userStart)); // switchContext's `ret` enters this trampoline
    for (0..6) |_| push(&sp, 0); // saved rbp, rbx, r12-r15

    threads[idx] = .{
        .rsp = sp,
        .stack = stack,
        .state = .ready,
        .name = name,
        .kstack_top = top,
        .pml4 = pml4,
        .user_entry = user_entry,
        .user_stack = user_stack,
    };
    last_user_idx = idx; // remember which slot this process got (for Ctrl-C kill / wait)
    if (appending) thread_count += 1;
    _ = @atomicRmw(usize, &alive, .Add, 1, .monotonic);
    return true;
}

// Index of the most recently spawnUser()'d thread. runUser uses it to terminate
// the foreground process if a Ctrl-C arrives. Valid only between a successful
// spawnUser and that process finishing.
var last_user_idx: usize = 0;

// First thing a user thread runs (ring 0, in its own address space): drop to
// ring 3. It returns to ring 0 only via a syscall or interrupt, never to here.
fn userStart() void {
    const t = &threads[current];
    usermode.enterRing3(t.user_entry, t.user_stack);
}

// SYS_exit handler for user processes (installed into syscall.exit_handler while a
// process is scheduled): mark the caller finished and switch away for good.
fn exitProcessHandler(code: u64) callconv(.c) noreturn {
    _ = code;
    asm volatile ("cli"); // the thread we switch to restores its own interrupt flag
    threads[current].state = .finished;
    _ = @atomicRmw(usize, &alive, .Sub, 1, .monotonic);
    yield();
    unreachable; // a finished thread is never scheduled again
}

// --- Launch a user process and wait for it (used by the program loader) -------
// runUser spawns one user process and blocks the *calling* thread until that
// process calls exit(), then returns the exit code it passed. This is how the
// loader runs a binary "synchronously": the launcher (the boot init-run, or the
// shell's `exec`) parks here, cooperatively yielding the CPU so the new process
// (and anything else ready) gets to run, and wakes once the child is done.
//
// Single-process-at-a-time by design: one global exit handler + result slot,
// matching the loader's one-image-at-a-time model. A real multi-process kernel
// would key these by pid; that's a later task.
var user_done: bool = false; // set by the exit handler when the launched process exits
var user_exit_code: u64 = 0; // the code it passed to exit()

// Exit code runUser returns when the process could never be spawned (thread table
// full or out of memory). Non-zero so the loader treats it as a failed run, and a
// distinctive value so it's recognizable in the log.
pub const SPAWN_FAILED: u64 = 0xFFFF_FFFF_FFFF_FFFF;

// SYS_exit handler installed while runUser waits: record the code, flag done, and
// finish the process (same teardown as exitProcessHandler — finished threads are
// never rescheduled, so the launcher's yield loop is what observes `user_done`).
fn captureUserExit(code: u64) callconv(.c) noreturn {
    user_exit_code = code;
    @atomicStore(bool, &user_done, true, .release); // publish before we switch away
    asm volatile ("cli"); // the thread we switch to restores its own interrupt flag
    threads[current].state = .finished;
    _ = @atomicRmw(usize, &alive, .Sub, 1, .monotonic);
    yield();
    unreachable; // a finished thread is never scheduled again
}

// Spawn `entry`/`user_stack` as a ring-3 process in address space `pml4`, then
// yield until it exits; returns its exit code. MUST be called from within an
// existing scheduler thread (so yield() has a context to return to) — the shell,
// which runs as a real thread, satisfies this. The boot path, which runs before
// the scheduler is live, uses runUserStandalone() below instead.
pub fn runUser(name: []const u8, user_entry: u64, user_stack: u64, pml4: u64) u64 {
    @atomicStore(bool, &user_done, false, .release);
    user_exit_code = 0;
    const prev = syscall.exit_handler; // restore afterwards so nested/other users are unaffected
    syscall.exit_handler = &captureUserExit;

    if (!spawnUser(name, user_entry, user_stack, pml4)) {
        // The process never started, so its exit handler will never fire and set
        // `user_done` — waiting below would hang the launcher forever. Restore the
        // previous handler and report the failure instead.
        syscall.exit_handler = prev;
        serial.log("[SCHED]   could not spawn user process '{s}'.\n", .{name});
        return SPAWN_FAILED;
    }
    const uidx = last_user_idx; // the slot this process occupies (set by spawnUser)

    // While this program runs it owns the terminal: a Ctrl-C should interrupt IT,
    // not cancel the shell's line. The TTY records such a Ctrl-C as a pending
    // interrupt, which we check on each turn of the wait loop. We run on a separate
    // thread from the program (single core, cooperative yield), so when we observe
    // the flag the program is parked and we can end it cleanly with no frame surgery.
    tty.setForeground(.process);
    while (!@atomicLoad(bool, &user_done, .acquire)) {
        if (tty.takeIntr()) { // Ctrl-C: terminate the foreground program (SIGINT default action)
            killForeground(uidx);
            break;
        }
        yield();
    }
    tty.setForeground(.shell); // the shell is reading commands again

    syscall.exit_handler = prev;
    return user_exit_code;
}

// Forcibly end the foreground user process at slot `uidx` because it was
// interrupted (Ctrl-C / SIGINT, whose default action is to terminate). This mirrors
// captureUserExit's teardown, but is driven from the launcher instead of the
// program's own exit() call: mark the slot finished (so yield() never resumes it),
// drop the alive count spawnUser bumped, and report exit code 130 (the conventional
// "killed by SIGINT" = 128 + signal 2). The launcher's caller (loader.execUser) then
// frees the address space as it does after any run. Always-on `^C` so the user sees it.
fn killForeground(uidx: usize) void {
    asm volatile ("cli"); // touch shared scheduler state with interrupts off
    threads[uidx].state = .finished;
    threads[uidx].exit_code = 130; // also retain it in the TCB so a wait()er can collect it
    _ = @atomicRmw(usize, &alive, .Sub, 1, .monotonic);
    user_exit_code = 130; // 128 + SIGINT(2)
    asm volatile ("sti");
    serial.print("^C\n", .{}); // user-facing feedback
    serial.log("[TTY] SIGINT -> terminated foreground process (code 130)\n", .{});
}

// --- Fault -> signal: terminate the *current* user process on a CPU fault ------
// Called from the IDT handler when a ring-3 (CPL3) process triggers a fatal CPU
// fault (e.g. a page fault on an unmapped address, or an illegal opcode). The
// default action of the corresponding signal (SIGSEGV / SIGILL / SIGFPE) is to
// kill the process, so we do exactly that here — the kernel must NOT halt just
// because a *user* program misbehaved (only a *kernel* fault is fatal to the box).
//
// This is the fault analogue of captureUserExit(): the faulting thread IS the
// current thread (the fault was taken on its kernel trap stack), so we mark that
// thread finished, drop the alive count spawnUser() bumped, record the conventional
// exit code (128 + signal number) so runUser() returns it, publish `user_done` so
// the launcher's wait loop wakes, and yield() away for good. A finished thread is
// never scheduled again, so this never returns — the next switch lands in the
// launcher (the shell), which tears the process down and prints the next prompt.
// Crucially we do NOT dump-and-halt: control returns to the shell instead.
pub fn terminateUserProcess(exit_code: u64) noreturn {
    asm volatile ("cli"); // touch shared scheduler state with interrupts off
    // A ring-3 fault is always taken on a spawnUser()'d process thread, never on
    // thread 0 (the idle/boot context, which never runs at CPL3). If `current` were
    // 0 here something is deeply wrong (we'd mark the idle thread finished and
    // underflow `alive`), so refuse rather than corrupt the scheduler — a readable
    // panic beats silent damage. This never fires on any reachable path.
    if (current == 0) @panic("terminateUserProcess: CPL3 fault on thread 0 (not a user process)");
    user_exit_code = exit_code; // the code runUser() will hand back to the loader
    threads[current].exit_code = exit_code; // also retain it in the TCB so a wait()er can collect it
    @atomicStore(bool, &user_done, true, .release); // publish before we switch away
    threads[current].state = .finished; // never reschedule the faulted process
    _ = @atomicRmw(usize, &alive, .Sub, 1, .monotonic); // it no longer counts as alive
    yield(); // hand the CPU back to the launcher (the shell); we never come back
    unreachable; // a finished thread is never scheduled again
}

// Like runUser, but for callers that are NOT yet part of the scheduler (the boot
// init-run, which happens before scheduler.init()). It adopts the current context
// as a throwaway "main" thread first, so yield() has somewhere to return to. The
// real scheduler.init() later calls setupMain() again, discarding this state — the
// same disposable pattern the boot self-tests/demos use.
pub fn runUserStandalone(name: []const u8, user_entry: u64, user_stack: u64, pml4: u64) u64 {
    setupMain();
    return runUser(name, user_entry, user_stack, pml4);
}

// --- wait/waitpid: collect a child's exit code, then reap it ------------------
// `runUser` above runs a child SYNCHRONOUSLY: the launcher parks until the child
// exits and immediately gets its code back through the global `user_exit_code`
// slot. That is fine when the parent has nothing else to do meanwhile, but it
// can't express the Unix shape "spawn a child, keep running, LATER ask how it
// ended" — and a synchronously-collected child is gone the moment runUser returns.
//
// wait/waitpid adds that shape. A child that exits becomes a ZOMBIE: its thread
// slot stays occupied, holding only its exit code, until a waiter collects it.
// The waiter (waitLastChild below, or the SYS_wait syscall) blocks until the
// target child is a zombie, reads its exit code, then REAPS the slot — flips it to
// .finished so the next spawn can reuse it (findFreeSlot). Reaping is what keeps
// the thread table from filling with dead-but-remembered children.
//
// Single-child model (matches the rest of this file's one-image-at-a-time loader):
// we track only the most-recently-spawned user process (`last_user_idx`). A full
// multi-child PID table is a later refinement; the lifecycle mechanics — retain on
// exit, block until zombie, read, reap — are the real, reusable part and are
// exercised by the self-test below.

// The slot the next wait() will collect. Set when a child is spawned to be wait()ed
// on; cleared (to "no waitable child") after it's reaped. ~0 = none.
const NO_CHILD: usize = ~@as(usize, 0);
var wait_child_idx: usize = NO_CHILD;

// SYS_exit handler installed while a child runs under waitLastChild: record the
// child's exit code IN ITS OWN TCB and leave it as a ZOMBIE (not .finished), so the
// waiter can still read the code after the child stops running. Same teardown shape
// as captureUserExit, but the slot lingers until reaped instead of being forgotten.
fn zombieExitHandler(code: u64) callconv(.c) noreturn {
    asm volatile ("cli"); // the thread we switch to restores its own interrupt flag
    threads[current].exit_code = code; // retain the code in the child's TCB...
    threads[current].state = .zombie; // ...and keep the slot until a waiter reaps it
    _ = @atomicRmw(usize, &alive, .Sub, 1, .monotonic); // a zombie no longer counts as alive
    yield(); // hand the CPU back; a zombie is never scheduled again
    unreachable;
}

// Reap an ENDED child at `idx`: read its retained exit code, then relinquish the
// slot (force it to .finished) so the next spawn can reuse it. Returns the exit code.
// The caller must have confirmed `idx` ended (childEnded: .zombie from a clean exit,
// or .finished from a forced kill — both retain exit_code). Done with interrupts off
// so the state flip can't race the scheduler. After this the child is GONE — a
// second reap of the same slot would read a stale code, so wait() clears
// wait_child_idx once reaped to make a double-reap impossible.
fn reap(idx: usize) u64 {
    asm volatile ("cli");
    const code = reapState(idx); // the read + state flip (pure; unit-tested)
    asm volatile ("sti");
    return code;
}

// The pure heart of reap(): read the zombie's retained exit code and flip its slot
// to .finished (relinquished, reusable). Split out from reap() so it can be unit-
// tested on the host without the cli/sti interrupt-masking (privileged instructions
// that fault outside ring 0). reap() wraps this in cli/sti; nothing else calls it.
fn reapState(idx: usize) u64 {
    const code = threads[idx].exit_code; // the code the child left behind
    threads[idx].state = .finished; // relinquish the slot (now reusable by findFreeSlot)
    return code;
}

// Is the thread at `idx` a zombie (finished, exit code retained, not yet reaped)?
fn isZombie(idx: usize) bool {
    return idx < thread_count and threads[idx].state == .zombie;
}

// Has the child at `idx` ENDED, by any route? A clean exit() leaves it a .zombie;
// the two forced-termination paths (a CPU fault -> terminateUserProcess, or Ctrl-C
// -> killForeground) leave it .finished. Both retain the exit code in the TCB, so
// the waiter must wake on EITHER — waiting only for .zombie would spin forever if a
// waited-on child instead faulted or was interrupted. (The window where a .finished
// slot is reused by another spawn before the waiter reaps it cannot occur in the
// single-child, cooperative-single-core model: the same thread that waits is the
// only one that spawns, so nothing spawns between the child ending and this reap.)
fn childEnded(idx: usize) bool {
    if (idx >= thread_count) return false;
    return threads[idx].state == .zombie or threads[idx].state == .finished;
}

// Spawn `entry` as a ring-3 child to be wait()ed on later, returning its slot index
// ("pid"), or null if it couldn't be spawned. Unlike runUser this does NOT block:
// the child runs as a zombie-on-exit process (its exit code is retained) and the
// caller collects it with waitChild()/SYS_wait. Installs zombieExitHandler for the
// child's exit() so the slot lingers; the caller restores the previous handler after
// reaping (the self-test does this).
fn spawnWaitableChild(name: []const u8, user_entry: u64, user_stack: u64, pml4: u64) ?usize {
    syscall.exit_handler = &zombieExitHandler; // child's exit() -> retain code + become zombie
    if (!spawnUser(name, user_entry, user_stack, pml4)) return null;
    wait_child_idx = last_user_idx; // the slot we'll wait on
    return last_user_idx;
}

// Block (cooperatively yielding) until the waitable child is a zombie, then read its
// exit code and reap the slot. Returns the child's exit code, or SPAWN_FAILED if
// there is no waitable child. MUST be called from a scheduler thread (so yield() has
// somewhere to go). This is the kernel side of waitpid: "wait for the child to end,
// tell me how, and clean it up". After it returns, wait_child_idx is cleared so a
// second wait can't double-reap a reused slot.
fn waitLastChild() u64 {
    const idx = wait_child_idx;
    if (idx == NO_CHILD) return SPAWN_FAILED; // nothing to wait on
    while (!childEnded(idx)) yield(); // run the child (and others) until it ends (exit OR forced-kill)
    const code = reap(idx); // collect its code + relinquish the slot
    wait_child_idx = NO_CHILD; // collected: prevent a double-reap of a reused slot
    return code;
}

// The outcome of a wait(): which child was collected and how it ended. `pid` is the
// reaped child's thread-table slot index (our stand-in for a real PID); `code` is
// its exit code. `pid == NO_CHILD` means "no child to wait on" (the caller maps that
// to ECHILD). Returned by-value so the SYS_wait handler can both report the pid and
// write the status without reaching into scheduler internals.
pub const WaitResult = struct { pid: usize, code: u64 };

// The public wait primitive the SYS_wait syscall calls: block until the most-
// recently-spawned waitable child becomes a zombie, reap it, and report which child
// it was + its exit code. Returns pid == noChild() when there's no waitable child.
// (Single-child today; the slot index doubles as the PID — see the module notes.)
pub fn waitForChild() WaitResult {
    const idx = wait_child_idx; // captured before waitLastChild clears it
    if (idx == NO_CHILD) return .{ .pid = NO_CHILD, .code = 0 };
    const code = waitLastChild(); // block-until-zombie, read code, reap the slot
    return .{ .pid = idx, .code = code };
}

// The sentinel `waitForChild` returns in `.pid` when there is no child to wait on,
// exposed so the syscall layer can recognize it without importing the constant.
pub fn noChild() usize {
    return NO_CHILD;
}

// --- Self-test: two cooperative worker threads -------------------------------
fn worker() void {
    const name = threads[current].name; // "A" or "B"
    var k: usize = 0;
    while (k < 4) : (k += 1) {
        serial.log("[SCHED]   {s}: iteration {d}\n", .{ name, k });
        yield(); // hand off to the other worker
    }
    // falls through to threadExit
}

pub fn selfTest() void {
    setupMain();
    spawn("A", &worker);
    spawn("B", &worker);
    while (aliveCount() > 0) yield(); // run the workers to completion
    serial.log("[SCHED]   back in main; all threads finished.\n", .{});
    serial.log("[SCHED] Scheduler self-test complete.\n", .{});
}

// --- Preemptive demo: workers that NEVER yield, switched only by the timer ----
fn pworker() void {
    const name = threads[current].name; // "P1" or "P2"
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        const target = pic.ticks() + 20; // ~200 ms; busy-wait, NO yield
        while (pic.ticks() < target) {} // the timer preempts us out of this loop
    }
    asm volatile ("cli");
    serial.log("[SCHED]   preempt {s}: finished (never called yield)\n", .{name});
    asm volatile ("sti");
}

pub fn preemptDemo() void {
    setupMain(); // reset: adopt the current context as thread 0
    spawn("P1", &pworker);
    spawn("P2", &pworker);
    preempting = true;
    pic.on_tick = &tick; // each timer tick now preempts to the next thread
    while (aliveCount() > 0) {} // main busy-waits; the timer schedules the workers
    pic.on_tick = null; // stop preempting
    preempting = false;
    serial.log("[SCHED] Preemptive demo complete.\n", .{});
}

// --- Permanent multitasking --------------------------------------------------
// Adopt the current (boot) context as thread 0 — the idle thread.
pub fn init() void {
    setupMain();
    threads[0].name = "idle";
}

// Turn on timer-driven preemption for good: every timer tick wakes sleepers and
// switches threads.
pub fn startPreemption() void {
    preempting = true;
    pic.on_tick = &tick;
}

// The idle thread's body: halt until an interrupt; the timer preempts us to any
// runnable thread (e.g. the shell). Never returns.
pub fn idle() noreturn {
    while (true) asm volatile ("hlt");
}

// Print the thread table (used by the shell's `ps` command).
pub fn dump() void {
    serial.print("  ID  STATE      NAME\n", .{});
    for (threads[0..thread_count], 0..) |t, i| {
        const st = switch (t.state) {
            .ready => "ready",
            .running => "running",
            .finished => "finished",
            .blocked => "blocked",
            .zombie => "zombie",
        };
        serial.print("  {d:>2}  {s:<9}  {s}\n", .{ i, st, t.name });
    }
}

// --- One-shot blocking-sleep self-test ---------------------------------------
fn sleepWorker() void {
    sleep(20); // block for ~200 ms (the timer wakes us; we don't busy-wait)
    serial.log("[SCHED]   blocking-sleep self-test: slept, woke OK (no busy-wait).\n", .{});
    // returns -> threadExit
}

pub fn blockSleepDemo() void {
    setupMain();
    spawn("sleeper", &sleepWorker);
    preempting = true;
    pic.on_tick = &tick; // the timer wakes sleepers
    while (aliveCount() > 0) {} // main waits; the sleeper blocks then wakes + exits
    pic.on_tick = null;
    preempting = false;
}

// --- One-shot blocking-mutex self-test ---------------------------------------
// Two threads hammer one shared counter, but only ever touch it while holding a
// single Mutex. The test proves two things:
//   1. Mutual exclusion: the counter is incremented NON-atomically (read into a
//      local, deliberately yield to let the other thread run, then write back).
//      Without the lock this lost-update pattern would drop increments and the
//      final total would be < expected. With the lock the other thread blocks on
//      lock() instead of corrupting the half-done update, so the total is EXACT.
//   2. Blocking handoff: an "in critical section" flag is set on entry and
//      cleared on exit; if two threads were ever inside at once we'd catch the
//      flag already set (recorded in mtx_violation). And mtx_handoffs counts how
//      many times a thread actually had to block on a held lock and was later
//      woken — proving lock() blocks rather than spins.

const MTX_ITERS = 200; // increments per worker
const MTX_WORKERS = 2; // number of contending threads
var mtx_lock: mutex.Mutex = .{}; // the single contended lock (default = unlocked)
var mtx_counter: usize = 0; // shared counter, mutated only under mtx_lock
var mtx_in_cs: bool = false; // true while SOME thread is inside the critical section
var mtx_violation: bool = false; // set if two threads are ever in the CS at once
var mtx_handoffs: usize = 0; // times a worker blocked on a held lock and was woken

fn mtxWorker() void {
    var i: usize = 0; // this worker's iteration counter
    while (i < MTX_ITERS) : (i += 1) {
        // Note whether the lock was held *before* we tried to take it: if it was,
        // our lock() call will have to block until the holder releases it. We read
        // the owner under cli so the snapshot can't be torn by a context switch.
        asm volatile ("cli");
        const was_held = mtx_lock.owner != ~@as(usize, 0); // != NO_OWNER => held
        asm volatile ("sti");

        mtx_lock.lock(); // <-- blocks here (descheduled) if another worker holds it

        if (was_held) mtx_handoffs += 1; // we waited on a held lock and got woken

        // --- critical section --------------------------------------------------
        // If mutual exclusion holds, no other thread can be in here with us.
        if (mtx_in_cs) mtx_violation = true; // someone else is already inside -> bug
        mtx_in_cs = true; // mark the section occupied

        const tmp = mtx_counter; // read-modify-write, split across a yield to make
        yield(); // the race window as wide as possible (a non-atomic ++ under lock)
        mtx_counter = tmp + 1; // write back: safe only because we hold the lock

        mtx_in_cs = false; // leave the section
        // --- end critical section ----------------------------------------------

        mtx_lock.unlock(); // release; wakes one blocked waiter (the other worker)
    }
    // falls through to threadExit
}

pub fn mutexDemo() void {
    setupMain(); // adopt the boot context as thread 0 (main)
    // Reset all shared state so the test is deterministic on repeated runs.
    mtx_lock = mutex.Mutex.init();
    mtx_counter = 0;
    mtx_in_cs = false;
    mtx_violation = false;
    mtx_handoffs = 0;
    var w: usize = 0; // spawn MTX_WORKERS contending threads
    while (w < MTX_WORKERS) : (w += 1) spawn("mtx", &mtxWorker);
    preempting = true;
    pic.on_tick = &tick; // the timer drives preemption + wakes blocked waiters
    while (aliveCount() > 0) {} // main waits for both workers to finish
    pic.on_tick = null;
    preempting = false;

    const expected = MTX_ITERS * MTX_WORKERS; // the exact total if no update was lost
    if (mtx_counter == expected and !mtx_violation) {
        // Unique success marker the integration harness greps for.
        serial.log("[MUTEX] blocking mutex self-test: mutual exclusion held, {d} handoffs OK\n", .{mtx_handoffs});
    } else {
        serial.log("[MUTEX] FAIL: counter={d} (expected {d}), violation={}\n", .{ mtx_counter, expected, mtx_violation });
    }
}

// --- User-process self-test --------------------------------------------------
// Spawn a real ring-3 process (its own address space) alongside a kernel thread
// and run them under preemption. The process loops in ring 3 doing SYS_yield and
// incrementing a counter in ITS user memory, then SYS_exit; the kernel thread
// increments a kernel counter. Both advancing proves user/kernel co-scheduling
// across address spaces (CR3 switch + per-process kernel stack on every switch).
const DEMO_ITERS = 5;
var demo_kcounter: usize = 0;

fn demoKWorker() void {
    var k: usize = 0;
    while (k < DEMO_ITERS) : (k += 1) {
        demo_kcounter += 1;
        yield(); // interleave with the user process
    }
    // falls through to threadExit
}

// Little-endian stores into the hand-assembled user stub.
fn wr64(p: [*]u8, v: u64) void {
    var i: usize = 0;
    while (i < 8) : (i += 1) p[i] = @truncate(v >> @intCast(i * 8));
}
fn wr32(p: [*]u8, v: u32) void {
    var i: usize = 0;
    while (i < 4) : (i += 1) p[i] = @truncate(v >> @intCast(i * 8));
}

pub fn userProcessDemo() void {
    setupMain();
    demo_kcounter = 0;

    const as = vmm.createAddressSpace() orelse {
        serial.log("[SCHED]   FAILED: no memory for a user address space\n", .{});
        return;
    };
    const code_frame = pmm.allocZeroed() orelse return;
    const data_frame = pmm.allocZeroed() orelse return;
    const stack_frame = pmm.allocZeroed() orelse return;

    const U_CODE: u64 = 0x400000; // ring-3 code
    const U_DATA: u64 = 0x401000; // a counter the process bumps each iteration
    const U_STACK_TOP: u64 = 0x403000; // top of a one-page user stack at 0x402000

    // Hand-assemble the ring-3 stub into the code frame via its HHDM alias:
    //   xor ebx,ebx; loop: mov eax,SYS_yield; syscall; inc rbx; mov rax,rbx;
    //   mov [U_DATA],rax; cmp rbx,N; jl loop; mov eax,SYS_exit; xor edi,edi; syscall
    const code: [*]u8 = @ptrFromInt(pmm.physToVirt(code_frame));
    code[0] = 0x31; code[1] = 0xDB; // xor ebx, ebx
    code[2] = 0xB8; wr32(code + 3, @intCast(syscall.SYS_yield)); // mov eax, SYS_yield
    code[7] = 0x0F; code[8] = 0x05; // syscall
    code[9] = 0x48; code[10] = 0xFF; code[11] = 0xC3; // inc rbx
    code[12] = 0x48; code[13] = 0x89; code[14] = 0xD8; // mov rax, rbx
    code[15] = 0x48; code[16] = 0xA3; wr64(code + 17, U_DATA); // mov [U_DATA], rax
    code[25] = 0x48; code[26] = 0x83; code[27] = 0xFB; code[28] = DEMO_ITERS; // cmp rbx, N
    code[29] = 0x7C; code[30] = 0xE3; // jl loop (-29 -> back to offset 2)
    code[31] = 0xB8; wr32(code + 32, @intCast(syscall.SYS_exit)); // mov eax, SYS_exit
    code[36] = 0x31; code[37] = 0xFF; // xor edi, edi
    code[38] = 0x0F; code[39] = 0x05; // syscall (exit)
    code[40] = 0xEB; code[41] = 0xFE; // jmp $ (safety)

    const counter: *volatile u64 = @ptrFromInt(pmm.physToVirt(data_frame));
    counter.* = 0;

    vmm.mapInto(as, U_CODE, code_frame, vmm.FLAG_USER); // RX, user
    vmm.mapInto(as, U_DATA, data_frame, vmm.FLAG_USER | vmm.FLAG_WRITE | vmm.FLAG_NX);
    vmm.mapInto(as, U_STACK_TOP - 0x1000, stack_frame, vmm.FLAG_USER | vmm.FLAG_WRITE | vmm.FLAG_NX);

    // Run the process + a kernel thread under preemption until both finish. Only
    // start the kernel thread + wait loop if the user process actually spawned;
    // otherwise skip straight to the (FAILED) result report + teardown.
    syscall.exit_handler = &exitProcessHandler;
    if (spawnUser("uproc", U_CODE, U_STACK_TOP, as)) {
        spawn("kproc", &demoKWorker);
        preempting = true;
        pic.on_tick = &tick;
        while (aliveCount() > 0) {} // main waits; the timer co-schedules both
        pic.on_tick = null;
        preempting = false;
    } else {
        serial.log("[SCHED]   could not spawn the user process\n", .{});
    }
    syscall.exit_handler = null;

    const user_iters = counter.*;
    if (user_iters == DEMO_ITERS and demo_kcounter == DEMO_ITERS) {
        serial.log("[SCHED] User-process self-test OK: ring-3 process + kernel thread co-scheduled across address spaces.\n", .{});
    } else {
        serial.log("[SCHED] User-process self-test FAILED (user={d}, kernel={d}).\n", .{ user_iters, demo_kcounter });
    }

    // Tear down the process's address space + frames (its kernel stack, like the
    // other self-tests' thread stacks, is left allocated — these run once at boot).
    vmm.unmapInto(as, U_CODE);
    vmm.unmapInto(as, U_DATA);
    vmm.unmapInto(as, U_STACK_TOP - 0x1000);
    pmm.free(code_frame);
    pmm.free(data_frame);
    pmm.free(stack_frame);
    vmm.destroyAddressSpace(as);
}

// --- Fault -> signal self-test -----------------------------------------------
// Spawn a real ring-3 process whose very first instruction dereferences an
// UNMAPPED user address. That triggers a page fault (#PF) from CPL3, which the
// IDT handler turns into "SIGSEGV, terminate the process" via terminateUserProcess
// — NOT a dump-and-halt. We then check that runUser() returned the conventional
// SIGSEGV exit code (139) AND that control came back here (proving the kernel did
// NOT halt). This exercises the whole fault->terminate->return-to-launcher path
// over the exact runUser() route the shell's `exec` uses.
const FAULT_ADDR: u64 = 0x0000000000300000; // a low (user-half) address we never map -> #PF on touch

pub fn userFaultDemo() void {
    // (No setupMain() here: runUserStandalone() below adopts the boot context as
    // thread 0 itself — the same disposable-main pattern the loader's boot path
    // uses. The user process runs as thread 1, faults, and we resume back here.)
    const as = vmm.createAddressSpace() orelse {
        serial.log("[SCHED]   FAILED: no memory for a fault-test address space\n", .{});
        return;
    };
    const code_frame = pmm.allocZeroed() orelse return;
    const stack_frame = pmm.allocZeroed() orelse return;

    const U_CODE: u64 = 0x400000; // ring-3 code page
    const U_STACK_TOP: u64 = 0x403000; // top of a one-page user stack at 0x402000

    // Hand-assemble a ring-3 stub that immediately faults by reading an unmapped
    // address: mov rax, FAULT_ADDR ; mov rax, [rax] (deref -> #PF, no page there).
    //   48 B8 <FAULT_ADDR>   mov rax, FAULT_ADDR
    //   48 8B 00             mov rax, [rax]      ; dereference -> page fault at CPL3
    //   EB FE                jmp $               ; safety (never reached)
    const code: [*]u8 = @ptrFromInt(pmm.physToVirt(code_frame));
    code[0] = 0x48; code[1] = 0xB8; wr64(code + 2, FAULT_ADDR); // mov rax, FAULT_ADDR
    code[10] = 0x48; code[11] = 0x8B; code[12] = 0x00; // mov rax, [rax]
    code[13] = 0xEB; code[14] = 0xFE; // jmp $

    // Map ONLY the code (RX, user) and the stack (RW, user). FAULT_ADDR is left
    // deliberately unmapped, so the deref is the fault we want to deliver.
    vmm.mapInto(as, U_CODE, code_frame, vmm.FLAG_USER);
    vmm.mapInto(as, U_STACK_TOP - 0x1000, stack_frame, vmm.FLAG_USER | vmm.FLAG_WRITE | vmm.FLAG_NX);

    // Run it via the same path the shell's `exec` uses. The process faults on its
    // first deref; the IDT handler delivers SIGSEGV (code 139) through
    // terminateUserProcess, which ends the process and yields back into this loop.
    const code_ret = runUserStandalone("ufault", U_CODE, U_STACK_TOP, as);

    if (code_ret == 139) {
        // We're back here (the kernel did NOT halt) AND the process was terminated
        // with the SIGSEGV exit code — the fault->signal path works end to end.
        serial.log("[SCHED] Fault->signal self-test OK: ring-3 page fault terminated the process (code {d}); returned to the kernel.\n", .{code_ret});
    } else {
        serial.log("[SCHED] Fault->signal self-test FAILED (exit code {d}, expected 139).\n", .{code_ret});
    }

    // Tear down: the faulting process never freed its pages, so we do it here.
    vmm.unmapInto(as, U_CODE);
    vmm.unmapInto(as, U_STACK_TOP - 0x1000);
    pmm.free(code_frame);
    pmm.free(stack_frame);
    vmm.destroyAddressSpace(as);
}

// --- wait/waitpid + zombie-reaping self-test ---------------------------------
// Proves the wait lifecycle end to end without touching the disk:
//   1. Build a ring-3 child that immediately exits with a KNOWN exit code.
//   2. Spawn it as a waitable child (zombie-on-exit), then waitForChild():
//      block until it's a zombie, read its retained exit code, reap the slot.
//   3. Assert the collected code matches AND the slot was REAPED — verified by
//      spawning a SECOND child and checking findFreeSlot handed it the SAME slot
//      (a leaked zombie would have forced a new, higher slot).
//   4. Repeat with a normal exit(0) child to prove the zero-code path is waited +
//      reaped too.
// Debug-log-gated (run from main only under -Ddebug-log); the harness greps the
// success marker. A self-contained ring-3 exercise — no FAT32 needed.
const WAIT_CODE_A: u8 = 42; // first child's non-zero exit code
const WAIT_CODE_B: u8 = 0; // second child's exit code (the zero path)

// Build a one-page-code + one-page-stack address space whose ring-3 entry is just
// `exit(code)`. Returns the address space and its three frames so the caller can run
// the child then tear everything down. Returns null on any allocation failure (and
// frees whatever it already took, so the run-once self-test never leaks).
const ExitChild = struct { as: u64, code_frame: u64, stack_frame: u64 };
fn buildExitChild(code: u8) ?ExitChild {
    const as = vmm.createAddressSpace() orelse return null;
    const code_frame = pmm.allocZeroed() orelse {
        vmm.destroyAddressSpace(as);
        return null;
    };
    const stack_frame = pmm.allocZeroed() orelse {
        pmm.free(code_frame);
        vmm.destroyAddressSpace(as);
        return null;
    };

    const U_CODE: u64 = 0x400000;
    const U_STACK_TOP: u64 = 0x403000; // top of a one-page stack at 0x402000

    // Hand-assemble: mov eax, SYS_exit ; mov edi, code ; syscall ; jmp $ (safety).
    //   B8 <SYS_exit>       mov eax, SYS_exit
    //   BF <code>           mov edi, code        ; the exit code (32-bit immediate)
    //   0F 05               syscall              ; exit(code) — does not return
    //   EB FE               jmp $                ; never reached
    const c: [*]u8 = @ptrFromInt(pmm.physToVirt(code_frame));
    c[0] = 0xB8; wr32(c + 1, @intCast(syscall.SYS_exit)); // mov eax, SYS_exit
    c[5] = 0xBF; wr32(c + 6, code); // mov edi, code
    c[10] = 0x0F; c[11] = 0x05; // syscall
    c[12] = 0xEB; c[13] = 0xFE; // jmp $

    vmm.mapInto(as, U_CODE, code_frame, vmm.FLAG_USER); // RX, user (the exit stub)
    vmm.mapInto(as, U_STACK_TOP - 0x1000, stack_frame, vmm.FLAG_USER | vmm.FLAG_WRITE | vmm.FLAG_NX);
    return .{ .as = as, .code_frame = code_frame, .stack_frame = stack_frame };
}

// Tear down a child built by buildExitChild (unmap + free its frames + destroy the
// address space). The child already exited, so the kernel owns this cleanup.
fn teardownExitChild(ch: ExitChild) void {
    const U_CODE: u64 = 0x400000;
    const U_STACK_TOP: u64 = 0x403000;
    vmm.unmapInto(ch.as, U_CODE);
    vmm.unmapInto(ch.as, U_STACK_TOP - 0x1000);
    pmm.free(ch.code_frame);
    pmm.free(ch.stack_frame);
    vmm.destroyAddressSpace(ch.as);
}

// Spawn one exit(code) child, wait for it, and reap it. Fills `*out_pid` with the
// slot it ran in and returns its collected exit code (or SPAWN_FAILED on spawn
// failure). The address-space frames are torn down after the wait completes.
fn runWaitChild(name: []const u8, code: u8, out_pid: *usize) u64 {
    const ch = buildExitChild(code) orelse {
        serial.log("[WAIT]   could not build an exit({d}) child\n", .{code});
        out_pid.* = noChild();
        return SPAWN_FAILED;
    };
    const U_CODE: u64 = 0x400000;
    const U_STACK_TOP: u64 = 0x403000;
    const pid = spawnWaitableChild(name, U_CODE, U_STACK_TOP, ch.as) orelse {
        teardownExitChild(ch);
        out_pid.* = noChild();
        return SPAWN_FAILED;
    };
    out_pid.* = pid;
    // Drive the child to completion under preemption, then collect it. We run under
    // the timer (like the other process demos) so the child actually gets CPU time;
    // waitForChild() yields until the child becomes a zombie, then reaps it.
    preempting = true;
    pic.on_tick = &tick;
    const result = waitForChild(); // block-until-zombie -> read code -> reap slot
    pic.on_tick = null;
    preempting = false;
    teardownExitChild(ch);
    return result.code;
}

pub fn waitReapDemo() void {
    setupMain(); // adopt the boot context as thread 0; thread_count = 1
    const prev = syscall.exit_handler; // restore after (spawnWaitableChild installs ours)

    // Child A: exits with a known NON-ZERO code. Wait for it and reap it.
    var pid_a: usize = undefined;
    const code_a = runWaitChild("waitA", WAIT_CODE_A, &pid_a);

    // Child B: a normal exit(0). Wait + reap proves the zero-code path too — AND, by
    // reusing the slot A vacated, that A was genuinely reaped (not left a zombie).
    var pid_b: usize = undefined;
    const code_b = runWaitChild("waitB", WAIT_CODE_B, &pid_b);

    syscall.exit_handler = prev;

    // Verdict: both exit codes collected correctly, and child B reused child A's
    // slot — which can only happen if waitForChild() actually reaped A (a leaked
    // zombie would have kept slot A occupied, forcing B into a fresh, higher slot).
    const codes_ok = code_a == WAIT_CODE_A and code_b == WAIT_CODE_B;
    const reaped_ok = pid_a != noChild() and pid_a == pid_b;
    if (codes_ok and reaped_ok) {
        serial.log("[WAIT] wait/reap self-test OK: collected exit codes {d} and {d}; zombie reaped (slot {d} reused).\n", .{ code_a, code_b, pid_a });
    } else {
        serial.log("[WAIT] wait/reap self-test FAILED (code_a={d} code_b={d} pid_a={d} pid_b={d}).\n", .{ code_a, code_b, pid_a, pid_b });
    }
}

// --- Inline unit tests: the pure wait/reap lifecycle helpers -----------------
// These run on the host (`zig build test`) and poke the thread table directly —
// they need no hardware, so the slot-selection / zombie-retention / reap policy is
// checked without booting. A tiny helper sets a slot's state with a placeholder
// stack pointer so the table is well-formed for the functions under test.
const testing = @import("std").testing;

fn setTestSlot(idx: usize, st: State, code: u64) void {
    threads[idx] = .{ .rsp = 0, .stack = &.{}, .state = st, .name = "t", .exit_code = code };
}

test "findFreeSlot reuses a reaped (.finished) slot, never slot 0 or a zombie/live one" {
    // Table: [0]=running idle, [1]=zombie (owes a waiter), [2]=finished (reaped).
    thread_count = 3;
    setTestSlot(0, .running, 0);
    setTestSlot(1, .zombie, 7); // a zombie's slot must NOT be reused (code still owed)
    setTestSlot(2, .finished, 0); // a reaped slot is free for reuse
    try testing.expectEqual(@as(?usize, 2), findFreeSlot()); // picks the reaped slot, not 0 or the zombie

    // With no reusable slot below thread_count, it appends a fresh one.
    setTestSlot(2, .ready, 0); // slot 2 now live -> nothing reusable
    try testing.expectEqual(@as(?usize, 3), findFreeSlot()); // appends at thread_count

    // Full table of live/zombie threads -> no slot available.
    thread_count = MAX_THREADS;
    for (1..MAX_THREADS) |i| setTestSlot(i, .ready, 0);
    try testing.expectEqual(@as(?usize, null), findFreeSlot());
}

test "reap reads a zombie's exit code and relinquishes the slot (.zombie -> .finished)" {
    thread_count = 2;
    setTestSlot(0, .running, 0);
    setTestSlot(1, .zombie, 99); // a zombie holding exit code 99
    try testing.expect(isZombie(1)); // it is a zombie before reaping
    try testing.expectEqual(@as(u64, 99), reapState(1)); // reap returns the retained code (pure core, no cli/sti)
    try testing.expectEqual(State.finished, threads[1].state); // slot relinquished (reusable)
    try testing.expect(!isZombie(1)); // and is no longer a zombie (so a double-reap can't happen)
}

test "waitLastChild reports no child when none is registered" {
    wait_child_idx = NO_CHILD;
    try testing.expectEqual(SPAWN_FAILED, waitLastChild()); // nothing to wait on
    try testing.expectEqual(noChild(), waitForChild().pid); // and the public wrapper agrees
}
