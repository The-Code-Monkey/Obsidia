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

// --- FADT (Fixed ACPI Description Table, signature "FACP") --------------------
// The FADT exposes the fixed-hardware register blocks. For power management we
// care about the PM1 control registers (where we write SLP_TYP|SLP_EN to enter
// the S5 "soft off" sleep state) and, on ACPI 2.0+, the optional RESET_REG that
// lets us reboot by writing RESET_VALUE to a firmware-described port.
//
// We expose only what is parsed from the *table*. The actual S5 SLP_TYP values
// live in the DSDT's \_S5 package, which requires an AML interpreter to decode —
// that is out of scope here. So the caller supplies/assumes SLP_TYP (QEMU's
// well-known S5 value is 0), while we still drive the real FADT-described ports.
pub const Fadt = struct {
    pm1a_cnt: u32 = 0, // PM1a_CNT_BLK I/O port (FADT offset 64)
    pm1b_cnt: u32 = 0, // PM1b_CNT_BLK I/O port (FADT offset 68; 0 = absent)
    reset_supported: bool = false, // FADT flags bit 10 (RESET_REG_SUP)
    reset_is_io: bool = false, // RESET_REG GAS lives in I/O space (addr space id 1)
    reset_port: u16 = 0, // RESET_REG address (when it is an I/O port)
    reset_value: u8 = 0, // value to write to reset_port to trigger a reset
};

var fadt: Fadt = .{};
var fadt_found: bool = false;

// SLP_EN is bit 13 of PM1_CNT — writing it commits the sleep transition.
pub const SLP_EN: u16 = 1 << 13;
// SLP_TYP occupies bits 10..12 of PM1_CNT — selects which sleep state to enter.
pub const SLP_TYP_SHIFT: u4 = 10;

// Accessor for the power code: the parsed FADT, or null if no FADT was found.
pub fn fadtInfo() ?Fadt {
    return if (fadt_found) fadt else null;
}

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

// --- FADT parsing ------------------------------------------------------------
// The FADT body (after the 36-byte SDT header) uses fixed offsets. We read the
// three things power management needs: the two PM1_CNT I/O port addresses, and
// (on ACPI 2.0+, i.e. table length covering the field) the RESET_REG GAS plus
// RESET_VALUE. A GAS (Generic Address Structure) is 12 bytes:
//   +0  u8  address_space_id (0 = system memory, 1 = system I/O)
//   +1  u8  register_bit_width
//   +2  u8  register_bit_offset
//   +3  u8  access_size
//   +4  u64 address
fn parseFadt(f: [*]const u8, len: u32) void {
    var out: Fadt = .{};

    out.pm1a_cnt = read(u32, f, 64); // PM1a_CNT_BLK — always present
    out.pm1b_cnt = read(u32, f, 68); // PM1b_CNT_BLK — 0 when the chipset lacks it

    // FADT "Flags" field (offset 112, u32): bit 10 = RESET_REG_SUP, set when the
    // RESET_REG/RESET_VALUE fields below are valid. They only exist on ACPI 2.0+
    // FADTs, so guard on the table being long enough to actually contain them.
    if (len >= 129) { // RESET_VALUE ends at offset 128 -> need >=129 bytes
        const flags = read(u32, f, 112);
        if (flags & (1 << 10) != 0) { // RESET_REG_SUP
            const space_id = f[116]; // GAS address_space_id
            const reset_addr = read(u64, f, 120); // GAS address (offset 116+4)
            out.reset_value = f[128]; // RESET_VALUE byte
            out.reset_supported = true;
            if (space_id == 1) { // system I/O space -> an I/O port we can OUT to
                out.reset_is_io = true;
                out.reset_port = @truncate(reset_addr); // ports are 16-bit
            }
        }
    }

    fadt = out;
    fadt_found = true;
}

// --- Init --------------------------------------------------------------------
// rsdp_phys is the physical address of the RSDP (from Limine's RSDP response).
pub fn init(rsdp_phys: u64) void {
    const r = at(rsdp_phys); // RSDP through the HHDM

    if (!std.mem.eql(u8, r[0..8], "RSD PTR ")) { // the RSDP signature
        return;
    }
    const revision = r[15]; // 0 = ACPI 1.0, >= 2 = ACPI 2.0+

    // Prefer the XSDT (64-bit pointers) on ACPI 2.0+, else the RSDT.
    const xsdt_addr = read(u64, r, 24);
    const rsdt_addr: u64 = read(u32, r, 16);
    const use_xsdt = revision >= 2 and xsdt_addr != 0;
    const root_phys = if (use_xsdt) xsdt_addr else rsdt_addr;
    const root = at(root_phys);
    const root_len = read(u32, root, 4); // SDT header length field
    const entry_size: usize = if (use_xsdt) 8 else 4;
    const count = (root_len - 36) / entry_size; // pointers after the 36-byte header

    for (0..count) |i| { // enumerate every table
        const table_phys = if (use_xsdt)
            read(u64, root, 36 + i * 8)
        else
            @as(u64, read(u32, root, 36 + i * 4));
        const h = at(table_phys);
        const sig = h[0..4]; // 4-character signature
        const len = read(u32, h, 4);
        if (std.mem.eql(u8, sig, "APIC")) parseMadt(h, len); // the MADT
        if (std.mem.eql(u8, sig, "FACP")) parseFadt(h, len); // the FADT
    }

    ready = true;
    // Asserted boot marker — the test harness greps "APIC @ 0x" to confirm the
    // MADT was parsed (matches the "LAPIC @ 0x" substring). This summary line is
    // test logging, so it survives the "strip non-test logging" cleanup.
    serial.print("[ACPI]   {d} CPU(s), {d} IO APIC(s), {d} override(s), LAPIC @ 0x{x}\n", .{ cpu_count, ioapic_count, iso_count, lapic_addr });
    // Additive FADT summary: report the PM1 control ports and reset capability so
    // the power code's behaviour is visible in the boot log (purely informational;
    // safe to add — it does not replace any harness-asserted marker).
    if (fadt_found) {
        serial.print("[ACPI]   FADT: PM1a_CNT 0x{x}, PM1b_CNT 0x{x}, reset {s}\n", .{ fadt.pm1a_cnt, fadt.pm1b_cnt, if (fadt.reset_supported) "supported" else "n/a" });
    }
    serial.print("[ACPI] ACPI parsed.\n", .{});
}
