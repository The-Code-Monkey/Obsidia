# `src/drivers/console.zig`

> A framebuffer text console that renders characters as pixels into Limine's linear framebuffer using an embedded PSF bitmap font, with a minimal ANSI terminal and a blinking cursor.

## What it does
Implements an on-screen text console by drawing glyphs from an embedded PSF (PC Screen Font) into a Limine-provided 32-bpp linear framebuffer. The PSF header (PSF1 or PSF2) is parsed at comptime, so swapping fonts is a one-line `@embedFile` change. It supports scrolling, line wrapping, a small subset of ANSI/CSI escape sequences for the shell's line editor, and a time-paced blinking underline cursor. Registered as the serial driver's mirror, it shows everything the kernel logs.

## Key components

Font handling (comptime):
- `Font` — descriptor: glyph bytes, count, width/height, bytes-per-row, bytes-per-glyph.
- `parsePsf(data)` — decodes a PSF1 (`0x36 0x04`) or PSF2 (`0x72 0xb5 0x4a 0x86`) header into a `Font`; `@compileError` on unknown magic.
- `readU32(data, off)` — little-endian u32 reader for the header.
- `psf` / `font` — the embedded `Tamzen8x16.psf` file and its parsed descriptor.

Framebuffer + drawing:
- `FramebufferInfo` — public struct describing the framebuffer (address, width, height, pitch, bpp, channel shifts).
- `makeColor(r,g,b)` / `putpixel(x,y,color)` — compose a pixel value and write it (assumes 32 bpp).
- `clear()`, `scroll()`, `newline()`, `drawGlyph()`, `clearCell()`, `eraseToEol()` (internal) — screen and cell rendering primitives.

Terminal emulation:
- `putcharRaw(c)` (internal) — core character handler: ANSI ESC `[` CSI parser, plus `\n`, `\r`, backspace (`0x08`), and printable glyph output with right-edge wrapping.
- `handleCsi(final, n)` (internal) — implements `ESC[2J` (clear), `ESC[H` (home), `ESC[K` (erase to EOL), `ESC[nC`/`ESC[nD` (cursor right/left); other sequences ignored.

Cursor:
- `drawCursor()` / `eraseCursor()` (internal) — draw/erase the underline (bottom 2 pixel rows) at the current cell.
- `cursorBlinkTick()` — called from the shell loop; uses `pic.ticks()` to toggle the cursor every `BLINK_TICKS` (50 ticks).

Public API:
- `init(info)` — set up the console over a given `FramebufferInfo`: compute the text grid, set colors, clear, mark ready, log via serial, and draw a banner.
- `writeString(s)` — write a string to the console (no-op until initialized).
- `print(fmt, args)` — printf-style output via a `std.io.Writer`.

## Depends on / used by
- **Imports:** `std` (`std.fmt`, `std.mem.copyForwards`), `serial.zig` (logging during init), `../arch/pic.zig` (`ticks()` to pace the blink), `../sched/sync.zig` (print lock for atomic updates), and the embedded `../fonts/Tamzen8x16.psf`.
- **Used by:** Initialized during boot once Limine hands over the framebuffer. Typically registered as `serial.setMirror` target so all logging is mirrored to screen; `cursorBlinkTick()` is driven by the shell loop.

## Notes
- Assumes 32 bits per pixel; `putpixel` writes a single `u32`.
- The blinking cursor is an underline drawn in the next (always-empty) character cell, so drawing/erasing it never disturbs existing text.
- `writeString`, `cursorBlinkTick`, and the cursor draws disable preemption to stay atomic w.r.t. other threads drawing; the cursor is erased before text is drawn and reappears on the next blink.
- `cursorBlinkTick` is called from the shell loop, not from IRQ context, and uses the timer tick count so the blink rate stays time-accurate regardless of call frequency.
- Includes `zig build test` unit tests verifying the embedded font parses to 8x16 / 256+ glyphs and that a synthetic PSF2 header decodes correctly.
