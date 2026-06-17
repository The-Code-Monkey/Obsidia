// A sleeping (blocking) Mutex built on top of the scheduler's block/wake pair.
//
// Unlike a spinlock, a thread that finds this mutex held does NOT busy-wait: it
// deschedules itself via scheduler.block() so other threads (including the lock
// holder) get the CPU, and is later made runnable again by scheduler.wake() when
// the holder calls unlock(). This is the right primitive for critical sections
// that may be held across a yield/sleep or for a non-trivial amount of work.
//
// Why this lives in its own file: sync.zig deliberately imports nothing (to avoid
// an import cycle with the scheduler, since serial/console use it). A Mutex needs
// to call into the scheduler, so it can't live in sync.zig — it belongs here,
// importing the scheduler directly.

const scheduler = @import("scheduler.zig"); // block(), wake(id), currentId()
const sync = @import("sync.zig"); // IF-aware critical-section helpers

// The maximum number of threads that can be queued waiting on a single mutex.
// MAX_THREADS in the scheduler is 16, so a queue this size can never overflow:
// every thread in the system could be waiting on us at once and still fit.
const MAX_WAITERS = 16;

// A sentinel meaning "no thread" — used for the owner field when the lock is
// free. Real thread ids are small indices (0..MAX_THREADS), so a huge value can
// never collide with a valid id.
const NO_OWNER: usize = ~@as(usize, 0);

// IF-aware critical sections live in sync.zig (shared with WaitQueue). Aliased
// here so the lock/unlock bodies below read unchanged.
const saveAndDisableInterrupts = sync.saveAndDisableInterrupts;
const restoreInterrupts = sync.restoreInterrupts;

pub const Mutex = struct {
    // The id of the thread currently holding the lock, or NO_OWNER if free.
    // Guarded by the cli regions in lock()/unlock(): on this single-core kernel,
    // masking interrupts (and thus preemption) makes those regions atomic.
    owner: usize = NO_OWNER,

    // A fixed-size FIFO queue of blocked waiters (thread ids), so no dynamic
    // allocation is needed in this core primitive. We push at `tail` and pop at
    // `head`; `len` tracks how many are queued.
    waiters: [MAX_WAITERS]usize = undefined,
    head: usize = 0, // index of the next waiter to wake
    tail: usize = 0, // index where the next waiter will be enqueued
    len: usize = 0, // number of queued waiters

    // Construct a fresh, unlocked mutex. Provided so call sites read clearly and
    // so we have an obvious place to set the free state explicitly.
    pub fn init() Mutex {
        return .{ .owner = NO_OWNER, .head = 0, .tail = 0, .len = 0 };
    }

    // Enqueue a waiting thread id at the tail of the FIFO (called with interrupts
    // already masked, so it's atomic vs. unlock()).
    fn enqueue(self: *Mutex, id: usize) void {
        self.waiters[self.tail] = id; // store the id at the tail slot
        self.tail = (self.tail + 1) % MAX_WAITERS; // advance the tail (wrap around)
        self.len += 1; // one more waiter queued
    }

    // Pop and return the head waiter id, or null if the queue is empty (called
    // with interrupts already masked).
    fn dequeue(self: *Mutex) ?usize {
        if (self.len == 0) return null; // no one is waiting
        const id = self.waiters[self.head]; // the oldest waiter (FIFO order)
        self.head = (self.head + 1) % MAX_WAITERS; // advance the head (wrap around)
        self.len -= 1; // one fewer waiter queued
        return id;
    }

    // Acquire the lock, blocking (descheduling) if it's currently held.
    //
    // Lost-wakeup safety: we make the "is it free?" decision and the "block
    // myself" action one atomic step by holding cli across both. scheduler.block()
    // yields while interrupts are still masked (IF=0), so a racing unlock() — which
    // also runs under cli — cannot slip in between our decision to wait and our
    // actually blocking. When we're woken and resume out of block(), interrupts are
    // still masked, so we re-loop and re-check the owner under the same protection.
    pub fn lock(self: *Mutex) void {
        const if_was = saveAndDisableInterrupts(); // enter the critical region
        while (self.owner != NO_OWNER) { // someone else holds it -> we must wait
            self.enqueue(scheduler.currentId()); // register ourselves to be woken
            scheduler.block(); // deschedule; resumes (still cli) when unlock wakes us
            // Loop back and re-check: another woken waiter may have grabbed the
            // lock first, so a wake is permission to *try*, not a guarantee.
        }
        self.owner = scheduler.currentId(); // the lock is free -> claim it
        restoreInterrupts(if_was); // leave the critical region (restore IF)
    }

    // Release the lock and hand off to one waiting thread, if any.
    //
    // Only the holder should call this. We clear the owner and wake exactly one
    // waiter (FIFO); that waiter will re-check the owner in its lock() loop and
    // claim the lock. Done under cli so it's atomic vs. a concurrent lock().
    pub fn unlock(self: *Mutex) void {
        const if_was = saveAndDisableInterrupts(); // enter the critical region
        self.owner = NO_OWNER; // mark the lock free
        if (self.dequeue()) |id| { // is anyone waiting?
            scheduler.wake(id); // make the oldest waiter runnable again
        }
        restoreInterrupts(if_was); // leave the critical region (restore IF)
    }
};
