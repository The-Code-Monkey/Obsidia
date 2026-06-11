// Low-level synchronization shared between the output path (serial/console) and
// the scheduler. It imports nothing, so serial/console can use it without
// creating an import cycle with the scheduler.
//
// The "print lock": on a single core, the simplest way to stop two threads from
// interleaving their output is to forbid context switches for the duration of a
// print. preemptDisable/Enable bump a counter the scheduler checks on each timer
// tick — interrupts stay on (the timer still ticks), we just don't switch
// threads while it's nonzero. So a print can't be cut in half by another thread.

var preempt_off: usize = 0;

// Forbid preemptive context switches (nestable).
pub fn preemptDisable() void {
    _ = @atomicRmw(usize, &preempt_off, .Add, 1, .acq_rel);
}

// Allow preemptive context switches again.
pub fn preemptEnable() void {
    _ = @atomicRmw(usize, &preempt_off, .Sub, 1, .acq_rel);
}

// Are preemptive switches currently forbidden? (Checked by the scheduler.)
pub fn preemptDisabled() bool {
    return @atomicLoad(usize, &preempt_off, .acquire) != 0;
}
