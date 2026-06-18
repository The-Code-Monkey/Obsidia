============================
``src/drivers/keyboard.zig``
============================

   PS/2 keyboard driver: decodes scancode set 1 from the 8042 controller into ASCII (and ANSI escape sequences) and hands them to a sink callback.

What it does
============

Handles the PS/2 keyboard via the 8042 controller, which raises IRQ1 and places a scancode at port ``0x60``. It decodes scancode set 1 (the default QEMU delivers) — make codes for presses, the same code ``| 0x80`` for releases, and a ``0xE0`` prefix for extended keys — applying Shift and Caps Lock. Decoded characters are delivered to a registered sink (the shell's input buffer). Extended keys (arrows, Home/End/Delete) are translated into ANSI escape sequences so keyboard and serial input parse identically.

Key components
==============

Ports and tables:

- ``DATA`` (``0x60``) / ``STATUS`` (``0x64``) — PS/2 data and status/command ports.
- ``map`` / ``map_shift`` — comptime-built 128-entry scancode-to-ASCII tables (unshifted and Shift-held); ``0`` means "no character".

State:

- ``shift``, ``caps``, ``extended`` (internal) — track Shift held, Caps Lock toggle, and a pending ``0xE0`` extended-key prefix.
- ``sink`` / ``setSink(f)`` — register the ``*const fn (u8) void`` that receives decoded characters.

Decoding:

- ``translate(code)`` (internal) — map a make code to a character; letters upper-case when Shift XOR Caps, other keys shifted only when Shift held.
- ``emit(seq)`` / ``emitExtended(code)`` (internal) — push a multi-byte sequence to the sink; translate extended make codes to ANSI escapes (Up ``\x1b[A``, Down, Left, Right, Home, End, Delete ``\x1b[3~``).
- ``handle(sc)`` (internal) — decode one scancode: absorb the ``0xE0`` prefix, update modifiers, emit characters on press only.
- ``onIrq()`` (internal) — the IRQ1 handler: read the scancode from ``DATA`` and decode it.

Setup:

- ``init()`` — log, drain any queued bytes from the controller, then ``pic.register(1, &onIrq)`` to route and unmask IRQ1.

Depends on / used by
====================

- **Imports:** ``serial.zig`` (for ``inb`` port I/O and logging), ``../arch/pic.zig`` (to register the IRQ1 handler).
- **Used by:** The shell, which calls ``setSink`` to receive typed input. ``init()`` is called during driver bring-up after the PIC is configured. The IRQ1 path is driven by hardware interrupts via the PIC.

Notes
=====

- Decodes scancode set 1 only (QEMU's default); a real BIOS set-2 translation is assumed off.
- Characters are emitted on key press only; releases update modifier state but produce no output.
- Caps Lock toggles only on press and affects letters only — digits/symbols are unaffected (so Shift XOR Caps gives lowercase for letters but Caps alone does not shift ``1``).
- Extended keys are emitted as ANSI escape sequences so the console's CSI parser and the shell handle keyboard arrows the same way as serial input.
- ``init()`` drains the controller's queued bytes first so a stale scancode doesn't fire IRQ1 immediately.
- Includes ``zig build test`` unit tests covering unshifted keys, Shift symbols, Caps-only letters, Shift/Caps cancellation, and extended arrow escape sequences.
