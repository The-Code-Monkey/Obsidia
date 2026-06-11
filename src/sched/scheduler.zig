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
};

var threads: [MAX_THREADS]Thread = undefined;
var thread_count: usize = 0;
var current: usize = 0; // index of the running thread
var alive: usize = 0; // number of non-finished worker threads

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
    push(&sp, @intFromPtr(&threadExit)); // where func returns to if it returns
    push(&sp, @intFromPtr(func)); // switchContext's `ret` jumps here
    for (0..6) |_| push(&sp, 0); // saved rbp, rbx, r12, r13, r14, r15

    threads[thread_count] = .{ .rsp = sp, .stack = stack, .state = .ready, .name = name };
    thread_count += 1;
    alive += 1;
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
    threads[current].state = .finished;
    alive -= 1;
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
    while (alive > 0) yield(); // run the workers to completion
    serial.print("[SCHED]   back in main; all threads finished.\n", .{});
    serial.print("[SCHED] Scheduler self-test complete.\n", .{});
}
