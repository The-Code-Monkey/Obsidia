// APIC: the modern interrupt controller, replacing the legacy 8259 PIC.
//
// Two pieces:
//   - Local APIC (LAPIC): per-CPU. We enable it, set its spurious-interrupt
//     vector, and use it to acknowledge interrupts (EOI).
//   - I/O APIC: routes external device IRQs (as "global system interrupts",
//     GSIs) to LAPIC vectors. It replaces the PIC's IRQ routing.
//
// We keep the existing vector layout (device IRQ N -> vector 32+N) and the
// existing handler registry in pic.zig, so the IDT dispatch is unchanged. We
// just hook pic.zig to (a) send EOI to the LAPIC and (b) unmask IRQs by
// programming the I/O APIC instead of the PIC. The ACPI MADT tells us the LAPIC
// address, the I/O APICs, and the interrupt source overrides (e.g. ISA IRQ0 is
// wired to GSI 2).
//
// LAPIC/I/O APIC registers are memory-mapped; we reach them through the HHDM.
// (On real hardware these pages should be mapped uncacheable; on QEMU all MMIO
// accesses are trapped regardless, so the HHDM mapping is fine here.)

const acpi = @import("../acpi/acpi.zig");
const pmm = @import("../mm/pmm.zig");
const pic = @import("pic.zig");
const serial = @import("../drivers/serial.zig");

const VECTOR_OFFSET: u8 = 32; // device IRQ N -> vector 32+N
pub const SPURIOUS_VECTOR: u8 = 0xFF; // LAPIC spurious-interrupt vector

// LAPIC register byte offsets.
const LAPIC_ID = 0x20;
const LAPIC_EOI = 0xB0;
const LAPIC_TPR = 0x80;
const LAPIC_SVR = 0xF0;

const IA32_APIC_BASE = 0x1B; // MSR: bit 11 = LAPIC global enable

// LAPIC timer registers + LVT bits.
const LVT_TIMER = 0x320; // Local Vector Table entry for the timer
const TIMER_INIT = 0x380; // initial count
const TIMER_CUR = 0x390; // current count (read-only)
const TIMER_DIV = 0x3E0; // divide configuration
const TIMER_PERIODIC = 1 << 17; // LVT: periodic mode
const TIMER_MASKED = 1 << 16; // LVT: masked
const TIMER_VECTOR: u8 = VECTOR_OFFSET; // fire the same vector the PIT timer used (32)

var lapic: [*]volatile u32 = undefined; // LAPIC MMIO (via HHDM)
var bsp_id: u32 = 0; // APIC ID of the boot CPU
var active = false;

// --- MSR access --------------------------------------------------------------
fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, hi) << 32) | @as(u64, lo);
}
fn wrmsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [lo] "{eax}" (@as(u32, @truncate(value))),
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))),
    );
}

// --- LAPIC register access ---------------------------------------------------
fn lapicRead(reg: u32) u32 {
    return lapic[reg / 4];
}
fn lapicWrite(reg: u32, val: u32) void {
    lapic[reg / 4] = val;
}

// Acknowledge an interrupt at the LAPIC (replaces the PIC's EOI).
pub fn eoi() void {
    lapicWrite(LAPIC_EOI, 0);
}

// --- I/O APIC register access ------------------------------------------------
// The I/O APIC has two MMIO registers: IOREGSEL (offset 0) selects an indirect
// register, IOWIN (offset 0x10) reads/writes it.
fn ioRegs(io: *const acpi.IoApic) [*]volatile u32 {
    return @ptrFromInt(pmm.physToVirt(io.address));
}
fn ioRead(io: *const acpi.IoApic, reg: u32) u32 {
    const b = ioRegs(io);
    b[0] = reg; // IOREGSEL
    return b[4]; // IOWIN (offset 0x10 = index 4)
}
fn ioWrite(io: *const acpi.IoApic, reg: u32, val: u32) void {
    const b = ioRegs(io);
    b[0] = reg;
    b[4] = val;
}

// Which I/O APIC handles a given GSI? (Each covers gsi_base .. gsi_base+count.)
fn ioApicForGsi(gsi: u32) ?*const acpi.IoApic {
    for (acpi.ioApics()) |*io| {
        const version = ioRead(io, 0x01);
        const max_entries = ((version >> 16) & 0xFF) + 1; // redirection entries
        if (gsi >= io.gsi_base and gsi < io.gsi_base + max_entries) return io;
    }
    return null;
}

// Route a legacy ISA IRQ to its vector via the I/O APIC, applying any ACPI
// source override (GSI remap + polarity/trigger). Unmasks the line.
pub fn routeIrq(irq: u8) void {
    if (!active) return;
    var gsi: u32 = irq; // default: identity mapping
    var flags: u16 = 0;
    for (acpi.isos()) |iso| { // honor any override for this IRQ
        if (iso.source == irq) {
            gsi = iso.gsi;
            flags = iso.flags;
        }
    }
    const vector: u32 = VECTOR_OFFSET + irq;
    const io = ioApicForGsi(gsi) orelse return;
    const idx = gsi - io.gsi_base; // redirection entry index

    // Build the 64-bit redirection entry: fixed delivery, physical destination,
    // unmasked, to the boot CPU's LAPIC. Polarity/trigger come from the ISO.
    var low: u32 = vector;
    if ((flags & 0x3) == 0x3) low |= (1 << 13); // active-low
    if (((flags >> 2) & 0x3) == 0x3) low |= (1 << 15); // level-triggered
    const high: u32 = bsp_id << 24; // destination APIC ID (bits 56-63)

    ioWrite(io, 0x10 + idx * 2 + 1, high); // high half first (dest)
    ioWrite(io, 0x10 + idx * 2, low); // low half (unmasks the line)
    serial.log("[APIC]   IRQ{d} -> GSI{d} -> vector {d} (IOAPIC {d}, entry {d})\n", .{ irq, gsi, vector, io.id, idx });
}

// Route a PCI INTx line to its vector via the I/O APIC. PCI interrupts differ
// from the ISA IRQs routeIrq handles: they are LEVEL-triggered and ACTIVE-LOW
// (and may be shared between devices). Device drivers (e.g. AC'97) call this for
// their interrupt line. Honors an ACPI GSI override if one exists, then forces
// the PCI polarity/trigger. Unmasks the line.
pub fn routeIrqPci(irq: u8) void {
    if (!active) return;
    var gsi: u32 = irq; // default: identity mapping
    for (acpi.isos()) |iso| { // a remap override still applies (rare for PCI)
        if (iso.source == irq) gsi = iso.gsi;
    }
    const vector: u32 = VECTOR_OFFSET + irq;
    const io = ioApicForGsi(gsi) orelse return;
    const idx = gsi - io.gsi_base;
    const low: u32 = vector | (1 << 13) | (1 << 15); // active-low (13) + level-triggered (15)
    const high: u32 = bsp_id << 24; // destination APIC ID
    ioWrite(io, 0x10 + idx * 2 + 1, high); // high half (dest) first
    ioWrite(io, 0x10 + idx * 2, low); // low half unmasks the line
}

pub fn init() void {
    if (!acpi.isReady()) { // need the MADT data
        return;
    }
    asm volatile ("cli"); // configure with interrupts masked

    // 1. Disable the legacy 8259 PIC so it can't deliver anything.
    pic.disable();
    serial.log("[APIC]   8259 PIC disabled.\n", .{});

    // 2. Enable the Local APIC.
    lapic = @ptrFromInt(pmm.physToVirt(acpi.lapicAddress()));
    wrmsr(IA32_APIC_BASE, rdmsr(IA32_APIC_BASE) | (1 << 11)); // global enable
    bsp_id = lapicRead(LAPIC_ID) >> 24; // boot CPU's APIC ID
    lapicWrite(LAPIC_TPR, 0); // accept all interrupt priorities
    lapicWrite(LAPIC_SVR, 0x100 | @as(u32, SPURIOUS_VECTOR)); // bit 8 = enable, + spurious vector

    active = true;

    // 3. Hook pic's dispatch to use the LAPIC EOI and I/O APIC routing, then
    //    re-route the IRQs already registered (the timer).
    pic.eoi_hook = &eoi;
    pic.route_hook = &routeIrq;
    pic.rerouteRegistered();

    asm volatile ("sti"); // interrupts back on, now via the APIC
    serial.log("[APIC] APIC initialized.\n", .{});
}

// Mask an IRQ at the I/O APIC (used to silence the PIT once the LAPIC timer
// drives the timer vector).
pub fn maskIrq(irq: u8) void {
    var gsi: u32 = irq;
    for (acpi.isos()) |iso| {
        if (iso.source == irq) gsi = iso.gsi;
    }
    const io = ioApicForGsi(gsi) orelse return;
    const idx = gsi - io.gsi_base;
    const low = ioRead(io, 0x10 + idx * 2);
    ioWrite(io, 0x10 + idx * 2, low | (1 << 16)); // set the mask bit
}

// Spin until the PIT tick counter advances once, bounded so we never hang if the
// PIT isn't ticking.
fn waitForTick() bool {
    const start = pic.ticks();
    var guard: u64 = 0;
    while (pic.ticks() == start) : (guard += 1) {
        if (guard > 4_000_000_000) return false;
    }
    return true;
}

// Calibrate the Local APIC timer against the PIT, then run it in periodic mode
// and retire the PIT. The LAPIC timer fires the SAME vector the PIT-driven timer
// used, so the existing handler (timerTick) and the uptime counter are reused.
pub fn initTimer(hz: u32) void {
    if (!active) return;
    lapicWrite(TIMER_DIV, 0x3); // divide bus clock by 16
    lapicWrite(LVT_TIMER, TIMER_MASKED); // masked while we measure

    // Count how far the LAPIC timer falls over 10 PIT ticks (= 100 ms @ 100 Hz).
    if (!waitForTick()) { // align to a PIT tick edge first
        return;
    }
    lapicWrite(TIMER_INIT, 0xFFFFFFFF); // start the LAPIC timer at max
    const t0 = pic.ticks();
    var guard: u64 = 0;
    while (pic.ticks() - t0 < 10) : (guard += 1) {
        if (guard > 4_000_000_000) break;
    }
    const elapsed = 0xFFFFFFFF - lapicRead(TIMER_CUR);
    lapicWrite(TIMER_INIT, 0); // stop

    if (elapsed < 1000) { // implausibly small -> calibration failed
        return;
    }
    // elapsed counts in 100 ms -> counts/sec = elapsed*10. The periodic initial
    // count for the requested frequency:
    const counts_per_sec = @as(u64, elapsed) * 10;
    const count: u32 = @intCast(counts_per_sec / hz);

    // Silence the PIT and run the LAPIC timer periodically on the timer vector.
    maskIrq(0);
    lapicWrite(TIMER_DIV, 0x3);
    lapicWrite(LVT_TIMER, TIMER_PERIODIC | @as(u32, TIMER_VECTOR));
    lapicWrite(TIMER_INIT, count);
    serial.log("[APIC]   PIT retired; LAPIC timer periodic @ {d} Hz (vector {d}).\n", .{ hz, TIMER_VECTOR });
}

// Pause the LAPIC timer by masking its LVT entry. This stops the periodic timer
// interrupt — which is the kernel's preemption + timekeeping source — so the
// system effectively goes quiet (a "full-system sleep"). resumeTimer() reverses
// it. The init count is left untouched, so the timer picks up where it left off.
pub fn pauseTimer() void {
    lapicWrite(LVT_TIMER, lapicRead(LVT_TIMER) | TIMER_MASKED); // set the mask bit
}

pub fn resumeTimer() void {
    lapicWrite(LVT_TIMER, lapicRead(LVT_TIMER) & ~@as(u32, TIMER_MASKED)); // clear it
}
