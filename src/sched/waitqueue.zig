// A device-interrupt wait queue: block a thread until an interrupt handler says
// something happened.
//
// This factors out the pattern a driver needs for interrupt-driven I/O: a thread
// issues a request, then sleeps until the device's IRQ fires, giving up the CPU
// meanwhile (other threads run, or the idle thread halts). The AC'97 player is the
// first user; AHCI / NIC drivers can share it.
//
// Built on the scheduler's block/wake pair (like Mutex). Two properties matter:
//   - Lost-wakeup safety: wait() holds interrupts masked across "is a signal
//     already pending?" and "block myself", and signal() runs masked too, so an
//     IRQ that fires just as we decide to wait can't be missed.
//   - Timeout safety net: wait() takes a timeout so a *missed* interrupt only
//     costs latency, never a hang — a driver's correctness never depends on the
//     IRQ actually arriving, only its promptness.

const scheduler = @import("scheduler.zig"); // blockTimeout(), wake(id), currentId()
const sync = @import("sync.zig"); // IF-aware critical-section helpers

// The scheduler caps threads at 16, so a u16 bitmask has one bit per possible
// thread id — every thread in the system could wait here at once and still fit.
pub const WaitQueue = struct {
    waiters: u16 = 0, // bit i set => thread i is blocked in wait() here
    pending: bool = false, // a signal arrived with no waiter; consumed by the next wait()

    // Block the current thread until signal() wakes it, or `timeout` ticks elapse
    // (0 = wait forever). Returns true if a signal woke us, false on timeout. A
    // signal that arrived since the last wait() is consumed here and returns
    // immediately (no lost wakeup).
    pub fn wait(self: *WaitQueue, timeout: u64) bool {
        const if_was = sync.saveAndDisableInterrupts(); // atomic vs. signal()
        if (self.pending) { // a signal already arrived — consume it, don't block
            self.pending = false;
            sync.restoreInterrupts(if_was);
            return true;
        }
        const bit = @as(u16, 1) << @as(u4, @intCast(scheduler.currentId()));
        self.waiters |= bit; // register as a waiter (so signal() can find us)
        scheduler.blockTimeout(timeout); // yields; resumes here (still masked) when woken
        // signal() clears our bit when it wakes us; a timeout leaves it set (the
        // timer just readied us), so the bit tells the two apart.
        const timed_out = (self.waiters & bit) != 0;
        self.waiters &= ~bit; // either way, we're no longer waiting
        sync.restoreInterrupts(if_was);
        return !timed_out;
    }

    // Wake every thread blocked in wait() here. If none are waiting, remember the
    // signal so the next wait() returns at once. Safe from interrupt context (and
    // from thread context — it masks interrupts around its work either way).
    pub fn signal(self: *WaitQueue) void {
        const if_was = sync.saveAndDisableInterrupts();
        defer sync.restoreInterrupts(if_was);
        if (self.waiters == 0) { // no one waiting yet — don't lose the event
            self.pending = true;
            return;
        }
        var w = self.waiters;
        self.waiters = 0; // clearing the bits marks these as signalled (vs. timed out)
        var id: usize = 0;
        while (w != 0) : (id += 1) {
            if (w & 1 != 0) scheduler.wake(id); // make this waiter runnable
            w >>= 1;
        }
    }
};
