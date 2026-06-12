# `src/drivers/serial.zig`

> COM1 (16550 UART) serial-port driver: the kernel's primary debug-output and shell-input channel, plus the low-level x86 port-I/O primitives.

## What it does
Drives the legacy 16550 UART at COM1 (I/O base `0x3F8`) over x86 port I/O, configured for 38400 baud 8N1. It is the kernel's main logging channel — every subsystem prints its state here and QEMU captures it to a log file. The file also exposes the raw `inb`/`outb`/`outw` port helpers that other drivers reuse, and an optional "mirror" hook so all serial output can be echoed to the framebuffer console.

## Key components

Port I/O primitives (reused across the kernel):
- `outb(port, data)` — write one byte to an I/O port (inline `outb` instruction).
- `outw(port, data)` — write one 16-bit word (used for the ACPI poweroff register).
- `inb(port)` — read one byte from an I/O port.

UART setup and output:
- `PORT` — COM1 base port `0x3F8`; the UART's 8 registers live at `PORT..PORT+7`.
- `init()` — programs the UART: disables interrupts, sets the 38400-baud divisor, 8N1 framing, enables/clears FIFOs, asserts MCR lines.
- `print(format, args)` — public printf-style logger used everywhere; formats through a `std.io.Writer` and holds the print lock so a line can't be interleaved by preemption.
- `putc(c)` — echo a single character (used by the shell's line editor).
- `isTransmitEmpty()` / `writeByte(b)` (internal) — busy-wait until the transmit register drains, then send a byte.

Mirroring:
- `setMirror(f)` — register (or clear) a sink that receives a copy of every transmitted byte; the framebuffer console registers itself here.
- `mirror` (internal) — optional `?*const fn ([]const u8) void` forwarded to by `writeFn` and `putc`.

Input (RX) for the serial shell:
- `dataAvailable()` — is a received byte waiting (LSR data-ready bit)?
- `readByteRaw()` — read one received byte (also clears the RX interrupt).
- `enableRxInterrupt()` — enable the "received data available" interrupt so COM1 raises IRQ4.

## Depends on / used by
- **Imports:** `std` (for `std.fmt` + `std.io.Writer`), `../sched/sync.zig` (the print lock / preemption disable). Talks directly to the COM1 16550 UART via port I/O.
- **Used by:** Effectively the whole kernel — `serial.print` is the universal logger. `console.zig`, `keyboard.zig`, and `ata.zig` all import this module (the latter two reuse `inb`/`outb`). It is initialized very early in boot, before most other subsystems, so they can log.

## Notes
- Output is polled (busy-wait on the transmit-empty bit), not interrupt-driven; only RX uses an interrupt and only when `enableRxInterrupt()` is called.
- `writeFn` reports it can never fail (`error{}`), so callers use `catch unreachable`.
- `print` and `putc` disable preemption around the write to keep lines atomic.
- The mirror is forwarded on the same path as serial output, so registering the framebuffer console makes all logging appear on screen with no changes to call sites.
