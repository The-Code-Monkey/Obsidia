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
const fat32 = @import("../fs/fat32.zig"); // FileReader for open file descriptors

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

// One open file: the FAT32 streaming cursor that tracks where in the file we are.
// `dup` makes a second descriptor refer to the same file; we model that by copying
// the cursor (each fd then has its own independent position), which is enough for
// the read/lseek/dup self-test. Reference-counted shared offsets are a later
// refinement once real shared-fd semantics (e.g. dup2 onto a pipe) are needed.
pub const OpenFile = struct {
    reader: fat32.FileReader, // the file's streaming read cursor
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

const State = enum { ready, running, finished, blocked };

const Thread = struct {
    rsp: u64, // saved stack pointer (points at the saved context)
    stack: []u8, // the thread's kernel stack (empty for the main thread)
    state: State,
    name: []const u8,
    entry: *const fn () void = undefined, // the function the thread runs
    wake_tick: u64 = 0, // if sleeping, the tick at which to wake (0 = not sleeping)
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

// Create a thread that will start executing `func`. We hand-build its stack so
// the first switchContext "returns" into func, and so that if func ever returns
// it lands in threadExit.
pub fn spawn(name: []const u8, func: *const fn () void) void {
    if (thread_count >= MAX_THREADS) return;
    const gs = kstack.alloc(thread_count) orelse { // guarded stack for this thread slot
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

    threads[thread_count] = .{ .rsp = sp, .stack = stack, .state = .ready, .name = name, .entry = func, .kstack_top = top };
    thread_count += 1;
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
    if (thread_count >= MAX_THREADS) return false;
    const gs = kstack.alloc(thread_count) orelse { // guarded kernel stack for this slot
        serial.log("[SCHED]   failed to allocate a user kernel stack\n", .{});
        return false;
    };
    const stack = @as([*]u8, @ptrFromInt(gs.bottom))[0 .. gs.top - gs.bottom]; // record of the mapped region
    const top = gs.top & ~@as(usize, 0xF);
    var sp: usize = top;
    push(&sp, @intFromPtr(&threadExit)); // fallback (userStart never returns here)
    push(&sp, @intFromPtr(&userStart)); // switchContext's `ret` enters this trampoline
    for (0..6) |_| push(&sp, 0); // saved rbp, rbx, r12-r15

    threads[thread_count] = .{
        .rsp = sp,
        .stack = stack,
        .state = .ready,
        .name = name,
        .kstack_top = top,
        .pml4 = pml4,
        .user_entry = user_entry,
        .user_stack = user_stack,
    };
    last_user_idx = thread_count; // remember which slot this process got (for Ctrl-C kill)
    thread_count += 1;
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
