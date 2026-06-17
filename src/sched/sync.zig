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

// --- Interrupt-flag critical sections ----------------------------------------
// Capture the interrupt-enable flag (IF, bit 9 of RFLAGS) and then mask
// interrupts. Returns whether IF *was* set, so the caller can restore exactly the
// state it came in with rather than blindly re-enabling. This lets a critical
// section behave correctly whether entered with interrupts on (thread context) or
// already off (nested in another cli region, or interrupt context). The blocking
// primitives (Mutex, WaitQueue) use this to make "decide to wait" + "block"
// atomic against the interrupt that would wake them.
pub fn saveAndDisableInterrupts() bool {
    var flags: u64 = undefined; // receives the pushed RFLAGS
    asm volatile ("pushfq; popq %[f]; cli" // snapshot RFLAGS, then disable interrupts
        : [f] "=r" (flags),
        :
        : "memory"
    );
    return (flags & 0x200) != 0; // bit 9 = IF; true if interrupts were enabled
}

// Restore the interrupt flag captured above: re-enable only if it was on before
// (never a blind sti, so a cli/interrupt-context caller stays masked).
pub fn restoreInterrupts(if_was: bool) void {
    if (if_was) asm volatile ("sti");
}
