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
    const io = ioApicForGsi(gsi) orelse {
        serial.print("[APIC]   no I/O APIC handles GSI {d}\n", .{gsi});
        return;
    };
    const idx = gsi - io.gsi_base; // redirection entry index

    // Build the 64-bit redirection entry: fixed delivery, physical destination,
    // unmasked, to the boot CPU's LAPIC. Polarity/trigger come from the ISO.
    var low: u32 = vector;
    if ((flags & 0x3) == 0x3) low |= (1 << 13); // active-low
    if (((flags >> 2) & 0x3) == 0x3) low |= (1 << 15); // level-triggered
    const high: u32 = bsp_id << 24; // destination APIC ID (bits 56-63)

    ioWrite(io, 0x10 + idx * 2 + 1, high); // high half first (dest)
    ioWrite(io, 0x10 + idx * 2, low); // low half (unmasks the line)
    serial.print("[APIC]   IRQ{d} -> GSI{d} -> vector {d} (IOAPIC {d}, entry {d})\n", .{ irq, gsi, vector, io.id, idx });
}

pub fn init() void {
    if (!acpi.isReady()) { // need the MADT data
        serial.print("[APIC] ACPI not available; staying on the PIC.\n", .{});
        return;
    }
    serial.print("[APIC] Initializing APIC...\n", .{});
    asm volatile ("cli"); // configure with interrupts masked

    // 1. Disable the legacy 8259 PIC so it can't deliver anything.
    pic.disable();
    serial.print("[APIC]   8259 PIC disabled.\n", .{});

    // 2. Enable the Local APIC.
    lapic = @ptrFromInt(pmm.physToVirt(acpi.lapicAddress()));
    wrmsr(IA32_APIC_BASE, rdmsr(IA32_APIC_BASE) | (1 << 11)); // global enable
    bsp_id = lapicRead(LAPIC_ID) >> 24; // boot CPU's APIC ID
    lapicWrite(LAPIC_TPR, 0); // accept all interrupt priorities
    lapicWrite(LAPIC_SVR, 0x100 | @as(u32, SPURIOUS_VECTOR)); // bit 8 = enable, + spurious vector
    serial.print("[APIC]   LAPIC @ 0x{x} enabled (BSP id {d}).\n", .{ acpi.lapicAddress(), bsp_id });

    active = true;

    // 3. Hook pic's dispatch to use the LAPIC EOI and I/O APIC routing, then
    //    re-route the IRQs already registered (the timer).
    pic.eoi_hook = &eoi;
    pic.route_hook = &routeIrq;
    pic.rerouteRegistered();

    asm volatile ("sti"); // interrupts back on, now via the APIC
    serial.print("[APIC] APIC initialized.\n", .{});
}
