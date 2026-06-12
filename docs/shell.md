# `src/shell.zig`

> An interrupt-driven read-eval-print loop over COM1 (and the framebuffer console), with a full line editor, command history, and a handful of built-in commands.

## What it does
The shell is the kernel's interactive front end and, once scheduled, one of its threads. Input arrives via IRQ4 (UART "received data available") and/or the PS/2 keyboard; both producers push bytes into a single-producer/single-consumer ring buffer. The run loop drains the ring, edits the current line (insert/delete, cursor movement, history browsing via ANSI escape sequences), and on Enter parses and dispatches a command. When the ring is empty the CPU `hlt`s until the next interrupt, so the shell is idle-friendly rather than busy-polling.

## Key components

### Public entry points
- `init()` — prints a banner, enables the UART RX interrupt, and registers `onSerialIrq` on IRQ4 (PIC vector 4).
- `run()` — the shell loop; `noreturn`. Blinks the on-screen cursor, drains the input ring, and `hlt`s when idle.
- `feed(c)` — public input sink; pushes one byte into the ring. The keyboard driver registers this so keystrokes share the serial input path.

### Input ring (SPSC)
- `ring`, `ring_head`, `ring_tail`, `RING_SIZE` (256) — the byte buffer and indices. `ringPush` (producer/IRQ) and `ringPop` (consumer/run loop) coordinate via atomic acquire/release on the indices; `ringEmpty` checks for pending input.
- `onSerialIrq()` — IRQ4 handler: drains all bytes the UART has buffered into the ring.

### Line editor
- `insertChar`, `backspace`, `deleteForward`, `replaceLine` — editing primitives that keep the on-screen line in sync by emitting ANSI sequences (`moveLeft`/`moveRight`/`printRange`).
- `handleChar`, `handleCsi` — input state machine driving an ESC/CSI parser for arrow keys, Home/End, and Delete.
- History: `addHistory`, `histAt`, `historyUp`, `historyDown` over a 16-entry ring (`HIST_SIZE`), with `browse` tracking recall depth.

### Command dispatch
- `execute(raw)` — trims, splits command word from args, and dispatches. Built-ins: `help`, `clear`, `echo <text>`, `mem`, `uptime`, `history`, `ps`, `ls [path]`, `cat <path>`, `sleep`, `restart`/`reboot`, `shutdown`/`poweroff`, `crash`.
- `systemSleep()` — full-system sleep: masks the LAPIC timer and deep-halts the machine until an input interrupt arrives, then resumes the timer and discards the waking key.

## Depends on / used by
- **Imports:** `drivers/serial` (I/O), `arch/pic` (IRQ4 registration + uptime ticks), `mm/pmm` (`mem`), `drivers/console` (cursor blink), `arch/power` (restart/shutdown), `sched/scheduler` (`ps`), `arch/apic` (pause/resume timer for `sleep`), `fs/fat32` (`ls`/`cat`), and `std`.
- **Used by:** `main.zig` calls `shell.init()` and runs `shell.run()` as a kernel thread; the keyboard driver calls `shell.feed` as its sink.

## Notes
- Both input producers (serial IRQ and keyboard IRQ) are IRQ handlers serialized on a single core, so the single-producer ring invariant holds even though two callers use `feed`.
- A full ring drops bytes rather than blocking.
- `sleep` deliberately stops timekeeping and preemption for the whole system; `crash` writes to `0xdeadbeef` to demonstrate the IDT page-fault crash dump.
- `systemSleep` relies on `sti; hlt` being atomic so a key arriving in the wakeup window can't be lost.
