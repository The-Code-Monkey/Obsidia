====================
``src/arch/pic.zig``
====================

   Remaps the legacy 8259 PIC off the CPU exception vectors, sets up the 8254 PIT timer on IRQ0, and dispatches hardware IRQs to registered handlers.

What it does
============

The two cascaded 8259 PICs power on mapping IRQ0-7 to vectors 0x08-0x0F, which collide with the CPU exception vectors, so this module remaps master IRQ0-7 to vectors 32-39 and slave IRQ8-15 to vectors 40-47 — exactly the range the IDT populated with stubs. It also wires the PIT to a tick counter (proving asynchronous interrupts work), owns the ``sti`` that first enables maskable interrupts, and provides an IRQ registry plus hooks so the APIC driver can later take over EOI and routing.

Key components
==============

Masking and EOI:

- ``setMask(irq)`` / ``clearMask(irq)`` — disable/enable an individual IRQ line via the PIC's OCW1 mask.
- ``disable()`` — fully mask both PICs (used by the APIC driver to retire the PIC).
- ``eoi(irq)`` — send end-of-interrupt; routes to the ``eoi_hook`` (LAPIC) when set.
- ``readMasterIsr`` / ``readSlaveIsr`` — read the In-Service Register to detect spurious IRQs.

APIC takeover hooks:

- ``eoi_hook`` — optional LAPIC EOI function.
- ``route_hook`` — optional I/O APIC unmask/route function.
- ``rerouteRegistered()`` — re-route every already-registered IRQ through ``route_hook``.

Setup:

- ``remap()`` — reprograms the 8259s via the ICW1-ICW4 sequence (and masks all lines).
- ``pitInit(hz)`` — programs PIT channel 0 (mode 3, square wave) to fire IRQ0 at the given rate.
- ``VECTOR_OFFSET`` (32), ``TIMER_HZ`` (100), and the PIC/PIT port constants.

Timekeeping and dispatch:

- ``tick_count`` / ``ticks()`` — total timer interrupts since boot; ``ticks()`` is an atomic monotonic load safe for spin-wait readers.
- ``on_tick`` — optional per-tick hook (the scheduler sets this to preempt).
- ``timerTick()`` — the timer-IRQ handler; increments the tick count and calls ``on_tick``.
- ``register(irq, handler)`` — record an IRQ handler and unmask the line (via ``route_hook`` if APIC is active, else ``clearMask``).
- ``handleIrq(vector)`` — called by the IDT for vectors 32-47; filters spurious IRQ7/IRQ15, EOIs, then dispatches to the registered handler.
- ``init()`` — remaps, starts the 100 Hz PIT, registers the timer on IRQ0, and runs ``sti``.

Depends on / used by
====================

- **Imports:** ``../drivers/serial.zig`` (for ``outb``/``inb`` port I/O and logging).
- **Used by:** ``idt.zig``'s ``isrHandler`` calls ``handleIrq`` for vectors 32-47. ``apic.zig`` installs ``eoi_hook``/``route_hook``, calls ``disable()``, ``rerouteRegistered()``, ``register``, and reads ``ticks()`` for LAPIC-timer calibration. Called after ``idt.init()`` in the boot sequence.

Notes
=====

- The EOI is sent *before* running the handler: IRQs are edge-triggered and the timer handler may context-switch away, so the controller must already be acked or it won't deliver the next interrupt to the switched-to thread.
- Spurious master IRQ7 (ISR bit clear) gets no EOI; spurious slave IRQ15 EOIs only the master (which accepted the cascade).
- Using hooks rather than importing ``apic.zig`` avoids a ``pic``↔``apic`` dependency cycle.
- ``ioWait()`` writes the harmless POST port ``0x80`` to give older PICs time to settle between command writes.
