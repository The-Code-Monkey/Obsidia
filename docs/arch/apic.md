# `src/arch/apic.zig`

> Brings up the modern APIC interrupt controller (Local APIC + I/O APIC) to replace the legacy 8259 PIC, and calibrates the LAPIC timer against the PIT.

## What it does
The Local APIC is per-CPU: this file enables it, sets its spurious-interrupt vector, and uses it to acknowledge interrupts (EOI). The I/O APIC routes external device IRQs (as global system interrupts, GSIs) to LAPIC vectors, replacing the PIC's routing. The existing vector layout (device IRQ N → vector 32+N) and the handler registry in `pic.zig` are kept unchanged — this module just hooks `pic.zig` to EOI at the LAPIC and unmask IRQs at the I/O APIC, using ACPI MADT data (LAPIC address, I/O APICs, interrupt source overrides). It also calibrates and runs the LAPIC timer in periodic mode, retiring the PIT.

## Key components

Constants and state:
- `VECTOR_OFFSET` (32), `SPURIOUS_VECTOR` (`0xFF`), `IA32_APIC_BASE` MSR, and LAPIC register offsets (`LAPIC_ID`, `LAPIC_EOI`, `LAPIC_TPR`, `LAPIC_SVR`).
- LAPIC timer registers/bits: `LVT_TIMER`, `TIMER_INIT`, `TIMER_CUR`, `TIMER_DIV`, `TIMER_PERIODIC`, `TIMER_MASKED`, `TIMER_VECTOR`.
- `lapic` (MMIO base via HHDM), `bsp_id` (boot CPU APIC ID), `active`.

Register access:
- `rdmsr(msr)` / `wrmsr(msr, value)` — model-specific register access.
- `lapicRead(reg)` / `lapicWrite(reg, val)` — LAPIC MMIO access.
- `ioRegs` / `ioRead` / `ioWrite` — I/O APIC indirect register access via IOREGSEL/IOWIN.
- `ioApicForGsi(gsi)` — find the I/O APIC covering a given GSI.

Routing and timer:
- `eoi()` — acknowledge an interrupt at the LAPIC (installed as `pic.eoi_hook`).
- `routeIrq(irq)` — program an I/O APIC redirection entry for a legacy ISA IRQ, applying ACPI source overrides (GSI remap, polarity/trigger), targeting the BSP and unmasking (installed as `pic.route_hook`).
- `maskIrq(irq)` — mask an IRQ at the I/O APIC (used to silence the PIT).
- `waitForTick()` — bounded spin until the PIT tick counter advances.
- `initTimer(hz)` — calibrate the LAPIC timer against 10 PIT ticks, then run it periodically on the timer vector and retire the PIT (falls back to the PIT if calibration fails).
- `pauseTimer()` / `resumeTimer()` — mask/unmask the LAPIC timer LVT entry (a "full-system sleep" that stops preemption + timekeeping; init count is preserved).
- `init()` — disables the PIC, enables the LAPIC, installs the `pic` hooks, re-routes registered IRQs, and re-enables interrupts via the APIC.

## Depends on / used by
- **Imports:** `../acpi/acpi.zig` (MADT: LAPIC address, I/O APICs, ISOs), `../mm/pmm.zig` (`physToVirt` for MMIO mapping), `pic.zig` (hooks, PIC disable, tick counter), `../drivers/serial.zig` (logging).
- **Used by:** Brought up after the PIC and ACPI are ready; `pauseTimer`/`resumeTimer` and `initTimer` are driven by higher-level kernel logic (e.g. sleep/power and timekeeping setup).

## Notes
- `init()` is a no-op (stays on the PIC) if `acpi.isReady()` is false; many functions early-out unless `active`.
- The LAPIC timer deliberately fires the *same* vector the PIT used (`VECTOR_OFFSET`/32) so the existing `pic.timerTick` handler and uptime counter are reused unchanged.
- LAPIC/I/O APIC registers are memory-mapped through the HHDM. On real hardware these pages should be mapped uncacheable; under QEMU all MMIO is trapped regardless, so the HHDM mapping suffices.
- Calibration is bounded by a `guard` counter and treats an implausibly small (`< 1000`) elapsed count as failure, keeping the PIT in that case.
