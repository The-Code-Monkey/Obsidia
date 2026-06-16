// PCI (Peripheral Component Interconnect) bus enumeration.
//
// Every PCI device exposes a 256-byte CONFIGURATION SPACE whose first 64 bytes
// (the "header") identify it: vendor/device id, class code, and up to six Base
// Address Registers (BARs) naming the MMIO/IO regions its driver talks to. This
// module walks the bus, records what it finds, and is the foundation later
// drivers (audio, AHCI, NIC) use to locate their hardware.
//
// We use the legacy CONFIGURATION ACCESS MECHANISM #1: a 32-bit ADDRESS port
// (0xCF8) selects a device + register, and a DATA port (0xCFC) reads/writes that
// register. It's universal on PC-class hardware (and QEMU's i440fx and q35), and
// needs no ACPI MCFG table — unlike the newer memory-mapped PCIe ECAM, which is a
// later upgrade. Config registers are 32-bit aligned; byte/word reads extract the
// relevant slice of the enclosing dword.

const serial = @import("serial.zig"); // logging + the inl/outl port helpers

const CONFIG_ADDRESS: u16 = 0xCF8; // write the (enable|bus|slot|func|offset) selector here
const CONFIG_DATA: u16 = 0xCFC; // then read/write the selected 32-bit register here

// Build the value mechanism #1 expects in CONFIG_ADDRESS: bit 31 enables config
// access, then the bus (23:16), slot/device (15:11), function (10:8), and the
// dword-aligned register offset (7:2 — the low two bits are forced to 0).
fn address(bus: u8, slot: u5, func: u3, offset: u8) u32 {
    return 0x8000_0000 |
        (@as(u32, bus) << 16) |
        (@as(u32, slot) << 11) |
        (@as(u32, func) << 8) |
        (offset & 0xFC);
}

// Read a 32-bit configuration register. `offset` is a byte offset into the 256-
// byte config space; address() masks it to dword alignment.
pub fn readDword(bus: u8, slot: u5, func: u3, offset: u8) u32 {
    serial.outl(CONFIG_ADDRESS, address(bus, slot, func, offset)); // select the register
    return serial.inl(CONFIG_DATA); // read it back
}

// Write a 32-bit configuration register (used for BAR sizing).
pub fn writeDword(bus: u8, slot: u5, func: u3, offset: u8, value: u32) void {
    serial.outl(CONFIG_ADDRESS, address(bus, slot, func, offset)); // select the register
    serial.outl(CONFIG_DATA, value); // write it
}

// 16-bit / 8-bit reads: pull the right slice out of the enclosing dword.
pub fn readWord(bus: u8, slot: u5, func: u3, offset: u8) u16 {
    const shift: u5 = @intCast((offset & 2) * 8); // 0 or 16
    return @truncate(readDword(bus, slot, func, offset) >> shift);
}
pub fn readByte(bus: u8, slot: u5, func: u3, offset: u8) u8 {
    const shift: u5 = @intCast((offset & 3) * 8); // 0, 8, 16, or 24
    return @truncate(readDword(bus, slot, func, offset) >> shift);
}

// --- Config-space header field offsets (type-0 header) -----------------------
const OFF_VENDOR: u8 = 0x00; // u16 vendor id (0xFFFF = no device) + u16 device id
const OFF_CLASS: u8 = 0x08; // u8 revision, u8 prog-if, u8 subclass, u8 class (high byte)
const OFF_HEADER_TYPE: u8 = 0x0E; // bit 7 = multifunction; bits 0-6 = header layout

// A device we discovered, with the identity fields a driver needs to recognize it
// and reach its config space again (bus/slot/func address it uniquely).
pub const Device = struct {
    bus: u8,
    slot: u5,
    func: u3,
    vendor: u16, // who made it (e.g. 0x8086 = Intel)
    device: u16, // which part
    class: u8, // broad category (see className)
    subclass: u8, // finer category within the class
    prog_if: u8, // programming interface (e.g. AHCI vs IDE within storage)
    header_type: u8, // header layout + multifunction bit
};

const MAX_DEVICES: usize = 32; // plenty for the machines we target; static (no allocator)
var devices: [MAX_DEVICES]Device = undefined;
var device_count: usize = 0;

// The devices found by the last init() scan, for other drivers to search.
pub fn list() []const Device {
    return devices[0..device_count];
}

// Find the first device matching a class (and subclass), or null. The hook future
// drivers use — e.g. AC'97 audio is class 0x04 (multimedia) subclass 0x01.
pub fn findByClass(class: u8, subclass: u8) ?*const Device {
    for (devices[0..device_count]) |*d| {
        if (d.class == class and d.subclass == subclass) return d;
    }
    return null;
}

// Human-readable name for a PCI base class code — makes the boot log legible.
fn className(class: u8) []const u8 {
    return switch (class) {
        0x00 => "Unclassified",
        0x01 => "Mass Storage Controller",
        0x02 => "Network Controller",
        0x03 => "Display Controller",
        0x04 => "Multimedia Controller",
        0x05 => "Memory Controller",
        0x06 => "Bridge",
        0x07 => "Communication Controller",
        0x08 => "Base System Peripheral",
        0x09 => "Input Device Controller",
        0x0C => "Serial Bus Controller",
        0x0D => "Wireless Controller",
        else => "Other",
    };
}

// Probe one (bus, slot, func). If a device lives there, record it (until the
// registry is full) and log a one-line summary.
fn checkFunction(bus: u8, slot: u5, func: u3) void {
    const id = readDword(bus, slot, func, OFF_VENDOR);
    const vendor: u16 = @truncate(id);
    if (vendor == 0xFFFF) return; // an absent function reads back all-ones
    const cls = readDword(bus, slot, func, OFF_CLASS);
    const dev = Device{
        .bus = bus,
        .slot = slot,
        .func = func,
        .vendor = vendor,
        .device = @truncate(id >> 16),
        .class = @truncate(cls >> 24),
        .subclass = @truncate(cls >> 16),
        .prog_if = @truncate(cls >> 8),
        .header_type = readByte(bus, slot, func, OFF_HEADER_TYPE),
    };

    if (device_count < MAX_DEVICES) {
        devices[device_count] = dev;
        device_count += 1;
    } else {
        serial.print("[PCI]   (registry full at {d}; not recording further devices)\n", .{MAX_DEVICES});
    }

    serial.print("[PCI]   {x:0>2}:{x:0>2}.{d}  {x:0>4}:{x:0>4}  class {x:0>2}.{x:0>2} prog-if {x:0>2}  {s}\n", .{ dev.bus, dev.slot, dev.func, dev.vendor, dev.device, dev.class, dev.subclass, dev.prog_if, className(dev.class) });
}

// Probe one slot. Function 0 must exist for the slot to be populated; only a
// MULTIFUNCTION device (header-type bit 7) has functions 1..7, so we avoid 7
// redundant probes per slot on the common single-function case.
fn checkSlot(bus: u8, slot: u5) void {
    if (@as(u16, @truncate(readDword(bus, slot, 0, OFF_VENDOR))) == 0xFFFF) return; // empty slot
    checkFunction(bus, slot, 0);
    if (readByte(bus, slot, 0, OFF_HEADER_TYPE) & 0x80 == 0) return; // single-function device
    var func: u8 = 1;
    while (func < 8) : (func += 1) checkFunction(bus, slot, @intCast(func));
}

// Enumerate the whole PCI space: every bus (0..255) × slot (0..31). A brute-force
// scan — simple and exhaustive; it finds devices behind bridges without having to
// walk the bridge topology, and the absent-slot fast path keeps it cheap (most
// (bus,slot) pairs read back 0xFFFF in a single config access).
pub fn init() void {
    serial.print("[PCI] Enumerating PCI bus (config mechanism #1, ports 0xCF8/0xCFC)...\n", .{});
    device_count = 0;
    var bus: u16 = 0; // u16 so the < 256 loop bound can't wrap
    while (bus < 256) : (bus += 1) {
        var slot: u8 = 0;
        while (slot < 32) : (slot += 1) checkSlot(@intCast(bus), @intCast(slot));
    }
    serial.print("[PCI] Enumeration complete: {d} device(s).\n", .{device_count});
}
