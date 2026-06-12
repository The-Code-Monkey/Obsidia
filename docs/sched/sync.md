# `src/sched/sync.zig`

> A dependency-free "print lock": a nestable counter that tells the scheduler not to switch threads while output is in progress.

## What it does
This tiny module provides the low-level synchronization primitive shared between the output path (serial/console) and the scheduler. On a single core, the simplest way to stop two threads from interleaving their output is to forbid context switches for the duration of a print; this module exposes a nestable counter for exactly that. It deliberately imports nothing, so serial/console can use it without forming an import cycle with the scheduler.

## Key components
- `preemptDisable()` — atomically increment the `preempt_off` counter, forbidding preemptive context switches (nestable).
- `preemptEnable()` — atomically decrement the counter, re-allowing switches.
- `preemptDisabled()` — returns whether switches are currently forbidden (counter nonzero); read by the scheduler each timer tick.

## Depends on / used by
- **Imports:** nothing (intentionally, to avoid an import cycle).
- **Used by:** the serial/console output path wraps prints in `preemptDisable`/`preemptEnable`; the scheduler's `tick()` calls `preemptDisabled()` before deciding to `yield()`.

## Notes
- Interrupts stay enabled while the lock is held — the timer still ticks; the scheduler simply declines to switch threads while the counter is nonzero, so a print can't be cut in half.
- The counter is manipulated with `.acq_rel` atomics and read with `.acquire`, making it safe across the timer interrupt.
- Being a counter rather than a boolean makes it nestable, so nested print paths balance correctly.
