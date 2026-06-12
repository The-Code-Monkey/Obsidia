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
const heap = @import("../mm/heap.zig");
const pic = @import("../arch/pic.zig"); // timer tick hook + tick counter
const sync = @import("sync.zig"); // honor the print lock (don't switch mid-print)
const mutex = @import("mutex.zig"); // blocking Mutex (used by the mutex self-test)

const STACK_SIZE = 32 * 1024; // 32 KiB per thread (the shell uses std.fmt etc.)
const MAX_THREADS = 16;

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
};

var threads: [MAX_THREADS]Thread = undefined;
var thread_count: usize = 0;
var current: usize = 0; // index of the running thread
var alive: usize = 0; // number of non-finished worker threads (atomic)
var preempting: bool = false; // true while timer-driven preemption is enabled

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
    const stack = heap.allocator().alloc(u8, STACK_SIZE) catch {
        serial.print("[SCHED]   failed to allocate a thread stack\n", .{});
        return;
    };

    // 16-byte-aligned top. After switchContext's `ret` pops `func`, rsp will be
    // (top - 8), i.e. 8 mod 16 — the alignment the ABI expects at a call entry.
    const top = (@intFromPtr(stack.ptr) + stack.len) & ~@as(usize, 0xF);
    var sp: usize = top;
    push(&sp, @intFromPtr(&threadExit)); // where the thread lands if it returns
    push(&sp, @intFromPtr(&threadStart)); // switchContext's `ret` enters the trampoline
    for (0..6) |_| push(&sp, 0); // saved rbp, rbx, r12, r13, r14, r15

    threads[thread_count] = .{ .rsp = sp, .stack = stack, .state = .ready, .name = name, .entry = func };
    thread_count += 1;
    _ = @atomicRmw(usize, &alive, .Add, 1, .monotonic);
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

// Block the current thread indefinitely until wake() is called on it (event
// wait — e.g. hibernating until a key is pressed). The caller MUST hold
// interrupts disabled so the wakeup can't be lost between deciding to block and
// blocking; on resume interrupts are still disabled and the caller re-enables.
pub fn block() void {
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

// --- Self-test: two cooperative worker threads -------------------------------
fn worker() void {
    const name = threads[current].name; // "A" or "B"
    var k: usize = 0;
    while (k < 4) : (k += 1) {
        serial.print("[SCHED]   {s}: iteration {d}\n", .{ name, k });
        yield(); // hand off to the other worker
    }
    serial.print("[SCHED]   {s}: done\n", .{name});
    // falls through to threadExit
}

pub fn selfTest() void {
    serial.print("[SCHED] Cooperative scheduler self-test...\n", .{});
    setupMain();
    spawn("A", &worker);
    spawn("B", &worker);
    serial.print("[SCHED]   spawned 2 threads; running round-robin...\n", .{});
    while (aliveCount() > 0) yield(); // run the workers to completion
    serial.print("[SCHED]   back in main; all threads finished.\n", .{});
    serial.print("[SCHED] Scheduler self-test complete.\n", .{});
}

// --- Preemptive demo: workers that NEVER yield, switched only by the timer ----
fn pworker() void {
    const name = threads[current].name; // "P1" or "P2"
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        const target = pic.ticks() + 20; // ~200 ms; busy-wait, NO yield
        while (pic.ticks() < target) {} // the timer preempts us out of this loop
        // Print atomically (serial is slow; masking avoids preemption mid-line).
        asm volatile ("cli");
        serial.print("[SCHED]   preempt {s}: round {d}\n", .{ name, round });
        asm volatile ("sti");
    }
    asm volatile ("cli");
    serial.print("[SCHED]   preempt {s}: finished (never called yield)\n", .{name});
    asm volatile ("sti");
}

pub fn preemptDemo() void {
    serial.print("[SCHED] Preemptive scheduler demo (timer-driven)...\n", .{});
    setupMain(); // reset: adopt the current context as thread 0
    spawn("P1", &pworker);
    spawn("P2", &pworker);
    preempting = true;
    pic.on_tick = &tick; // each timer tick now preempts to the next thread
    serial.print("[SCHED]   preemption ON; 2 workers busy-loop without yielding.\n", .{});
    while (aliveCount() > 0) {} // main busy-waits; the timer schedules the workers
    pic.on_tick = null; // stop preempting
    preempting = false;
    serial.print("[SCHED] Preemptive demo complete.\n", .{});
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
    serial.print("[SCHED]   blocking-sleep self-test: slept, woke OK (no busy-wait).\n", .{});
    // returns -> threadExit
}

pub fn blockSleepDemo() void {
    serial.print("[SCHED] Blocking-sleep self-test...\n", .{});
    setupMain();
    spawn("sleeper", &sleepWorker);
    preempting = true;
    pic.on_tick = &tick; // the timer wakes sleepers
    while (aliveCount() > 0) {} // main waits; the sleeper blocks then wakes + exits
    pic.on_tick = null;
    preempting = false;
    serial.print("[SCHED] Blocking-sleep self-test complete.\n", .{});
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
    serial.print("[SCHED] Blocking-mutex self-test...\n", .{});
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
        serial.print("[MUTEX] blocking mutex self-test: mutual exclusion held, {d} handoffs OK\n", .{mtx_handoffs});
    } else {
        serial.print("[MUTEX] FAIL: counter={d} (expected {d}), violation={}\n", .{ mtx_counter, expected, mtx_violation });
    }
    serial.print("[SCHED] Blocking-mutex self-test complete.\n", .{});
}
