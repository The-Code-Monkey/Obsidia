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

const STACK_SIZE = 16 * 1024; // 16 KiB per thread
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

const State = enum { ready, running, finished };

const Thread = struct {
    rsp: u64, // saved stack pointer (points at the saved context)
    stack: []u8, // the thread's kernel stack (empty for the main thread)
    state: State,
    name: []const u8,
    entry: *const fn () void = undefined, // the function the thread runs
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
fn spawn(name: []const u8, func: *const fn () void) void {
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

// Voluntarily give up the CPU to the next ready thread (round-robin).
pub fn yield() void {
    const prev = current;
    var i: usize = 1;
    while (i <= thread_count) : (i += 1) {
        const cand = (prev + i) % thread_count; // round-robin from prev+1
        if (threads[cand].state == .ready) {
            if (threads[prev].state == .running) threads[prev].state = .ready;
            threads[cand].state = .running;
            current = cand;
            switchContext(&threads[prev].rsp, threads[cand].rsp);
            return; // resumes here when we're switched back to
        }
    }
    // No other ready thread: keep running prev.
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
    pic.on_tick = &yield; // each timer tick now preempts to the next thread
    serial.print("[SCHED]   preemption ON; 2 workers busy-loop without yielding.\n", .{});
    while (aliveCount() > 0) {} // main busy-waits; the timer schedules the workers
    pic.on_tick = null; // stop preempting
    preempting = false;
    serial.print("[SCHED] Preemptive demo complete.\n", .{});
}
