# `src/sched/scheduler.zig`

> A cooperative-and-preemptive round-robin scheduler for kernel threads, each with its own kernel stack.

## What it does
This file implements the kernel's multitasking core: it manages a fixed table of kernel threads, hands each a private 32 KiB stack, and switches between them by saving/restoring callee-saved registers and the stack pointer via a hand-written assembly `switchContext`. It supports cooperative switching (threads call `yield()`), timer-driven preemption (the PIC tick hook calls `tick()`), blocking sleeps, and indefinite event waits. It is the layer the shell and idle thread run on top of once the kernel reaches permanent multitasking.

## Key components

### Context switch
- `switchContext(old, new)` — `extern`/inline-asm routine that pushes `rbp/rbx/r12-r15`, stores `rsp` into `*old`, loads `new` into `rsp`, restores the registers, and `ret`s into the resumed thread. C ABI: `old`→rdi, `new`→rsi.

### Types & constants
- `Thread` — per-thread record: saved `rsp`, `stack` slice, `state`, `name`, `entry` function, and `wake_tick`.
- `State` — `ready`, `running`, `finished`, `blocked`.
- `STACK_SIZE` (32 KiB), `MAX_THREADS` (16).

### Thread lifecycle
- `spawn(name, func)` — allocates a stack from the heap and hand-builds it so the first switch "returns" into `threadStart` (which runs `func`), with `threadExit` as the fall-through if `func` returns; increments the atomic `alive` count.
- `threadStart()` / `threadExit()` — internal trampolines: the former enables interrupts then runs the body; the latter marks the thread `finished`, decrements `alive`, and yields away forever.
- `setupMain()` / `init()` — adopt the current boot context as thread 0 (named "idle" in `init`).

### Scheduling & blocking
- `yield()` — IF-aware round-robin switch to the next `ready` thread; safe from both cooperative callers and the timer IRQ.
- `tick()` — timer-tick hook: wakes due sleepers, then preempts via `yield()` unless the print lock forbids it.
- `sleep(ticks)` — block the current thread for N timer ticks (100 Hz) and give up the CPU.
- `block()` / `wake(id)` — indefinite event wait and its wakeup (caller must hold interrupts disabled around `block`).
- `startPreemption()` — installs `tick` as `pic.on_tick` permanently.
- `idle()` — the idle thread body: `hlt` loop, never returns.

### Introspection & demos
- `aliveCount()`, `currentId()`, `dump()` (the shell `ps` table).
- `selfTest()`, `preemptDemo()`, `blockSleepDemo()` — self-contained demonstrations of cooperative, preemptive, and blocking-sleep behavior.

## Depends on / used by
- **Imports:** `drivers/serial.zig` (logging), `mm/heap.zig` (thread stacks), `arch/pic.zig` (timer tick hook `on_tick` + `ticks()` counter), `sched/sync.zig` (the print lock, to avoid switching mid-print).
- **Used by:** the kernel main/boot path (calls `init` then `startPreemption`), the idle thread, and the shell (`ps` → `dump`, plus any `spawn`ed worker threads). Self-test entry points are invoked during boot bring-up.

## Notes
- `switchContext` must be assembly: a normal Zig prologue would corrupt the hand-managed stack.
- The hand-built stack is aligned so that after the first `ret` pops `func`, `rsp` is 8 mod 16 — the alignment the System V ABI expects at a call entry.
- `yield()` masks interrupts across the switch so the thread table isn't touched re-entrantly, and restores the caller's original interrupt flag on resume.
- `block()` requires the caller to have interrupts disabled so a wakeup can't be lost between deciding to block and actually blocking.
- `alive` is accessed atomically so a busy-waiting reader (e.g. `main`) sees worker completions.
