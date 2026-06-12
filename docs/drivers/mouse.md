# `src/drivers/mouse.zig`

> PS/2 mouse driver — just enough to make the scroll wheel scroll the console.

## What it does
This driver enables the PS/2 mouse and uses its **scroll wheel** to move the
console's scrollback (see [`console.md`](console.md)). It deliberately ignores
movement and clicks — there is no on-screen pointer yet, only the wheel.

The mouse shares the 8042 controller with the keyboard, which makes setup
delicate, so the driver is built around two safeguards:

1. **Init runs with interrupts off.** Asking the controller for a byte fills the
   shared output buffer, which looks like a keystroke and fires the keyboard
   IRQ — which would steal the reply. Masking interrupts during the polling
   handshake prevents that race.
2. **The keyboard's settings are protected.** Enabling the mouse means
   read-modify-writing the controller's command byte, which also holds the
   keyboard's enable bits. The driver forces the keyboard's bits to known-good
   values (and bails without writing if it can't read the byte), so the mouse
   can never accidentally disable the keyboard.

It performs the "IntelliMouse" handshake (sample-rate sequence 200, 100, 80) to
switch the mouse into 4-byte packets that include a wheel byte, then routes
IRQ12.

## Key components
- `init()` — enable the aux device, set the command byte (keyboard kept alive,
  mouse IRQ on), run the wheel handshake, enable reporting, register IRQ12.
- `onIrq()` — assemble mouse packets; on a wheel notch, scroll the console up or
  down by a few lines (capped, so a fast flick doesn't jump pages).
- `MAX_WHEEL_LINES` — the per-notch scroll cap.

## Related
- [`console.md`](console.md) — `scrollUpBy` / `scrollDownBy`, driven by the wheel.
- [`keyboard.md`](keyboard.md) — shares the same 8042 controller.
