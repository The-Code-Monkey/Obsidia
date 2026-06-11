// ACPI table parsing.
//
// Firmware describes the hardware through ACPI tables. We find them via the
// RSDP (Root System Description Pointer, provided by Limine), which points at
// the RSDT (32-bit table pointers) or XSDT (64-bit). Each entry is a System
// Description Table with a common 36-byte header.
//
// We parse the MADT ("APIC" signature): it lists the Local APIC base address,
// the CPU cores, the I/O APIC(s), and the interrupt source overrides — exactly
// what the APIC driver needs next. All addresses are physical, reached through
// the HHDM. ACPI tables are byte-packed (fields can be unaligned), so we read
// every multi-byte field with std.mem.readInt rather than struct layout.

const std = @import("std");
const serial = @import("../drivers/serial.zig");
const pmm = @import("../mm/pmm.zig"); // physToVirt to reach physical tables

// --- Parsed results (filled by init, read by the APIC driver) ----------------
pub const IoApic = struct {
    id: u8, // I/O APIC ID
    address: u64, // its MMIO base (physical)
    gsi_base: u32, // first global system interrupt it handles
};

pub const Iso = struct {
    source: u8, // the legacy ISA IRQ
    gsi: u32, // the global system interrupt it actually maps to
    flags: u16, // polarity / trigger-mode flags
};

var lapic_addr: u64 = 0xFEE00000; // Local APIC MMIO base (default; MADT may override)
var ioapics: [16]IoApic = undefined;
var ioapic_count: usize = 0;
var iso_list: [48]Iso = undefined;
var iso_count: usize = 0;
var cpu_count: usize = 0;
var ready: bool = false;

pub fn lapicAddress() u64 {
    return lapic_addr;
}
pub fn ioApics() []const IoApic {
    return ioapics[0..ioapic_count];
}
pub fn isos() []const Iso {
    return iso_list[0..iso_count];
}
pub fn cpuCount() usize {
    return cpu_count;
}
pub fn isReady() bool {
    return ready;
}

// --- Helpers -----------------------------------------------------------------
// Read a little-endian integer at a byte offset (handles unaligned ACPI fields).
fn read(comptime T: type, ptr: [*]const u8, off: usize) T {
    const n = @sizeOf(T);
    return std.mem.readInt(T, ptr[off .. off + n][0..n], .little);
}

// 8-bit checksum: a valid ACPI structure's bytes sum to 0 (mod 256).
fn checksum(ptr: [*]const u8, len: usize) u8 {
    var sum: u8 = 0;
    for (0..len) |i| sum +%= ptr[i];
    return sum;
}

// Map a physical table address to a usable pointer via the HHDM.
fn at(phys: u64) [*]const u8 {
    return @ptrFromInt(pmm.physToVirt(phys));
}

// --- MADT parsing ------------------------------------------------------------
// The MADT body (after the 36-byte SDT header) is: u32 local_apic_address,
// u32 flags, then a stream of variable-length entries (type, length, payload).
fn parseMadt(madt: [*]const u8, len: u32) void {
    lapic_addr = read(u32, madt, 36); // 32-bit Local APIC address field
    var off: usize = 44; // first entry follows local_apic_address + flags
    while (off + 2 <= len) {
        const etype = madt[off]; // entry type
        const elen = madt[off + 1]; // entry length (including these 2 bytes)
        if (elen < 2) break; // malformed: avoid an infinite loop
        switch (etype) {
            0 => { // Processor Local APIC — one per CPU core
                const flags = read(u32, madt, off + 4);
                if (flags & 1 != 0) cpu_count += 1; // bit 0 = processor enabled
            },
            1 => { // I/O APIC
                if (ioapic_count < ioapics.len) {
                    ioapics[ioapic_count] = .{
                        .id = madt[off + 2],
                        .address = read(u32, madt, off + 4),
                        .gsi_base = read(u32, madt, off + 8),
                    };
                    ioapic_count += 1;
                }
            },
            2 => { // Interrupt Source Override (e.g. ISA IRQ0 -> GSI 2)
                if (iso_count < iso_list.len) {
                    iso_list[iso_count] = .{
                        .source = madt[off + 3],
                        .gsi = read(u32, madt, off + 4),
                        .flags = read(u16, madt, off + 8),
                    };
                    iso_count += 1;
                }
            },
            5 => { // Local APIC Address Override (64-bit base)
                lapic_addr = read(u64, madt, off + 4);
            },
            else => {}, // ignore other entry types for now
        }
        off += elen; // advance to the next entry
    }
}

// --- Init --------------------------------------------------------------------
// rsdp_phys is the physical address of the RSDP (from Limine's RSDP response).
pub fn init(rsdp_phys: u64) void {
    serial.print("[ACPI] Parsing ACPI tables...\n", .{});
    const r = at(rsdp_phys); // RSDP through the HHDM

    if (!std.mem.eql(u8, r[0..8], "RSD PTR ")) { // the RSDP signature
        serial.print("[ACPI]   ERROR: bad RSDP signature\n", .{});
        return;
    }
    const revision = r[15]; // 0 = ACPI 1.0, >= 2 = ACPI 2.0+
    serial.print("[ACPI]   RSDP @ 0x{x}, revision {d}, OEM '{s}'\n", .{ rsdp_phys, revision, r[9..15] });
    if (checksum(r, 20) != 0) serial.print("[ACPI]   WARN: RSDP checksum invalid\n", .{});

    // Prefer the XSDT (64-bit pointers) on ACPI 2.0+, else the RSDT.
    const xsdt_addr = read(u64, r, 24);
    const rsdt_addr: u64 = read(u32, r, 16);
    const use_xsdt = revision >= 2 and xsdt_addr != 0;
    const root_phys = if (use_xsdt) xsdt_addr else rsdt_addr;
    const root = at(root_phys);
    const root_len = read(u32, root, 4); // SDT header length field
    const entry_size: usize = if (use_xsdt) 8 else 4;
    const count = (root_len - 36) / entry_size; // pointers after the 36-byte header
    serial.print("[ACPI]   {s} @ 0x{x}, {d} tables:\n", .{ if (use_xsdt) "XSDT" else "RSDT", root_phys, count });

    for (0..count) |i| { // enumerate every table
        const table_phys = if (use_xsdt)
            read(u64, root, 36 + i * 8)
        else
            @as(u64, read(u32, root, 36 + i * 4));
        const h = at(table_phys);
        const sig = h[0..4]; // 4-character signature
        const len = read(u32, h, 4);
        serial.print("[ACPI]     {s} @ 0x{x} (len {d})\n", .{ sig, table_phys, len });
        if (std.mem.eql(u8, sig, "APIC")) parseMadt(h, len); // the MADT
    }

    ready = true;
    serial.print("[ACPI]   {d} CPU(s), {d} IO APIC(s), {d} override(s), LAPIC @ 0x{x}\n", .{ cpu_count, ioapic_count, iso_count, lapic_addr });
    serial.print("[ACPI] ACPI parsed.\n", .{});
}
