// ATA PIO disk driver (primary bus, master drive, 28-bit LBA): read and write.
//
// This is the simplest possible way to talk to a hard disk: "Programmed I/O"
// means the CPU itself moves every word of data through an I/O port (no DMA).
// It's slow, but tiny and easy to reason about — the right first block device.
//
// We talk to the legacy ATA controller through two register blocks of x86 I/O
// ports: the "command block" at 0x1F0..0x1F7 and the "control block" at 0x3F6.
// NOTE: these legacy ports only exist on a PATA controller (QEMU's i440fx /
// `-M pc`); the q35 machine has only AHCI/SATA, where this driver finds nothing.

const std = @import("std"); // sliceAsBytes for the sector copy
const serial = @import("serial.zig"); // logging + the inb/outb port helpers

const inb = serial.inb; // read one byte from a port
const outb = serial.outb; // write one byte to a port

// --- Command-block registers (offsets from the primary base 0x1F0) -----------
const IO_BASE = 0x1F0; // primary ATA bus command-block base
const DATA = IO_BASE + 0; // 0x1F0: 16-bit data port (sector words flow here)
const FEATURES = IO_BASE + 1; // 0x1F1: features (write) / error (read)
const SECCOUNT = IO_BASE + 2; // 0x1F2: number of sectors for the next command
const LBA_LOW = IO_BASE + 3; // 0x1F3: LBA bits 0..7
const LBA_MID = IO_BASE + 4; // 0x1F4: LBA bits 8..15
const LBA_HIGH = IO_BASE + 5; // 0x1F5: LBA bits 16..23
const DRIVE_HEAD = IO_BASE + 6; // 0x1F6: drive select + LBA mode + LBA bits 24..27
const STATUS = IO_BASE + 7; // 0x1F7: status (read)
const COMMAND = IO_BASE + 7; // 0x1F7: command (write) — same port, different direction
const ALT_STATUS = 0x3F6; // control block: alt status (read) / device control (write)

// --- Status register bits (read from 0x1F7) ----------------------------------
const SR_BSY = 0x80; // busy: the controller owns the registers, don't touch them
const SR_DRDY = 0x40; // device ready
const SR_DF = 0x20; // device fault
const SR_DRQ = 0x08; // data request: a sector's worth of words is ready to move
const SR_ERR = 0x01; // error: check the error register

// --- Commands ----------------------------------------------------------------
const CMD_READ_PIO = 0x20; // READ SECTORS (PIO, 28-bit LBA)
const CMD_WRITE_PIO = 0x30; // WRITE SECTORS (PIO, 28-bit LBA)
const CMD_FLUSH = 0xE7; // FLUSH CACHE (commit written sectors to the medium)
const CMD_IDENTIFY = 0xEC; // IDENTIFY DEVICE (returns 256 words of disk info)

pub const SECTOR_SIZE = 512; // bytes per sector (fixed for ATA disks)

var present: bool = false; // did we find a usable disk on the primary master?
var total_sectors: u32 = 0; // capacity in 512-byte sectors (from IDENTIFY)

// Is a disk present and usable? The filesystem layer checks this before reading.
pub fn isPresent() bool {
    return present;
}

// Disk capacity in sectors (0 if no disk).
pub fn sectorCount() u32 {
    return total_sectors;
}

// Read `words` 16-bit words from a port into `buf` using the string instruction
// `rep insw` (the CPU repeats the IN, auto-incrementing the destination). `cld`
// first so the destination index counts UP. This moves a whole sector at once.
inline fn repInsw(port: u16, buf: [*]u16, words: usize) void {
    asm volatile ("cld; rep insw"
        :
        : [port] "{dx}" (port), // source port in DX
          [buf] "{rdi}" (buf), // destination pointer in RDI (auto-incremented)
          [cnt] "{rcx}" (words), // repeat count in RCX (counts down to 0)
        : "rcx", "rdi", "memory", "cc" // all clobbered by the instruction
    );
}

// Write `words` 16-bit words from `buf` out to a port with `rep outsw` (the CPU
// repeats the OUT, auto-incrementing the source). The mirror image of repInsw.
inline fn repOutsw(port: u16, buf: [*]const u16, words: usize) void {
    asm volatile ("cld; rep outsw"
        :
        : [port] "{dx}" (port), // destination port in DX
          [buf] "{rsi}" (buf), // source pointer in RSI (auto-incremented)
          [cnt] "{rcx}" (words), // repeat count in RCX (counts down to 0)
        : "rcx", "rsi", "cc" // clobbered by the instruction
    );
}

// Brief delay (~400 ns) by reading the alternate-status port four times. After
// selecting a drive the spec requires this settle time before status is valid;
// the read has no side effects, so it's a clean way to burn ~100 ns each.
fn delay400ns() void {
    var i: u8 = 0;
    while (i < 4) : (i += 1) _ = inb(ALT_STATUS);
}

// Spin until BSY clears. Capped so a misbehaving/absent controller can't hang
// the whole kernel — returns false on timeout instead of looping forever.
fn waitNotBusy() bool {
    var spins: u32 = 0;
    while (inb(STATUS) & SR_BSY != 0) {
        spins += 1;
        if (spins > 100_000_000) return false; // gave up
    }
    return true;
}

// Wait for the controller to be ready to transfer a sector: BSY clear and DRQ
// set. Returns false if it reports an error/fault or never becomes ready.
fn waitDataRequest() bool {
    var spins: u32 = 0;
    while (true) {
        const st = inb(STATUS);
        if (st & (SR_ERR | SR_DF) != 0) return false; // controller flagged a problem
        if (st & SR_BSY == 0 and st & SR_DRQ != 0) return true; // ready to move data
        spins += 1;
        if (spins > 100_000_000) return false; // gave up
    }
}

// Probe the primary master and learn its size via IDENTIFY DEVICE. Safe to call
// when no disk is attached: it detects that and leaves `present` false, so the
// rest of the kernel (and disk-less boots) carry on unaffected.
pub fn init() void {
    outb(DRIVE_HEAD, 0xA0); // select the master drive (0xA0), CHS/LBA bits zero for now
    delay400ns(); // let the selection settle

    // "Floating bus": with nothing attached the data lines float high, so the
    // status register reads 0xFF. That's the cheap no-disk check.
    if (inb(STATUS) == 0xFF) {
        serial.log("[ATA]   no device (floating bus 0xFF) — no disk on this machine.\n", .{});
        return;
    }

    // Issue IDENTIFY: zero the addressing registers, then write the command.
    outb(SECCOUNT, 0);
    outb(LBA_LOW, 0);
    outb(LBA_MID, 0);
    outb(LBA_HIGH, 0);
    outb(COMMAND, CMD_IDENTIFY);

    // Status 0 immediately after the command also means "no device here".
    if (inb(STATUS) == 0) {
        serial.log("[ATA]   no device (status 0).\n", .{});
        return;
    }
    if (!waitNotBusy()) {
        serial.log("[ATA]   timeout waiting for BSY to clear.\n", .{});
        return;
    }
    // A non-ATA device (ATAPI/SATA) signals itself by putting magic bytes in the
    // LBA mid/high registers — for a plain ATA disk these stay zero.
    if (inb(LBA_MID) != 0 or inb(LBA_HIGH) != 0) {
        serial.log("[ATA]   device is not plain ATA (ATAPI/SATA?) — skipping.\n", .{});
        return;
    }
    if (!waitDataRequest()) {
        serial.log("[ATA]   IDENTIFY failed (error or timeout).\n", .{});
        return;
    }

    var id: [256]u16 = undefined; // IDENTIFY returns exactly 256 words of info
    repInsw(DATA, &id, 256);
    // Words 60 and 61 together hold the total 28-bit LBA sector count.
    total_sectors = @as(u32, id[60]) | (@as(u32, id[61]) << 16);
    present = true;
    const mib = total_sectors / 2048; // 2048 sectors of 512 bytes = 1 MiB
    serial.log("[ATA]   primary master present: {d} sectors (~{d} MiB), 28-bit LBA PIO.\n", .{ total_sectors, mib });
}

// Read `count` sectors (1..256) starting at `lba` into `dst`. `dst` must be at
// least count*512 bytes. Returns false on no-disk, bad args, or a controller
// error. This is the one primitive the filesystem layer builds on.
pub fn read(lba: u32, count: u16, dst: []u8) bool {
    if (!present) return false; // no disk to read from
    if (count == 0 or count > 256) return false; // one command moves 1..256 sectors
    if (dst.len < @as(usize, count) * SECTOR_SIZE) return false; // buffer too small
    if (!waitNotBusy()) return false; // controller must be idle before we program it

    // Drive/head register: 0xE0 = master + LBA mode; low nibble = LBA bits 24..27.
    outb(DRIVE_HEAD, 0xE0 | @as(u8, @intCast((lba >> 24) & 0x0F)));
    delay400ns();
    outb(SECCOUNT, @intCast(count & 0xFF)); // sector count (256 wraps to 0, which means 256)
    outb(LBA_LOW, @intCast(lba & 0xFF)); // LBA 0..7
    outb(LBA_MID, @intCast((lba >> 8) & 0xFF)); // LBA 8..15
    outb(LBA_HIGH, @intCast((lba >> 16) & 0xFF)); // LBA 16..23
    outb(COMMAND, CMD_READ_PIO); // start the read

    // Each sector becomes available in turn: wait for DRQ, then move 256 words.
    var s: usize = 0;
    while (s < count) : (s += 1) {
        if (!waitDataRequest()) return false; // controller errored or stalled
        var tmp: [256]u16 = undefined; // one sector, word-aligned for the IN
        repInsw(DATA, &tmp, 256);
        // Copy the sector into the caller's (possibly unaligned) byte buffer.
        @memcpy(dst[s * SECTOR_SIZE ..][0..SECTOR_SIZE], std.mem.sliceAsBytes(tmp[0..]));
    }
    return true;
}

// Write `count` sectors (1..256) starting at `lba` from `src` (>= count*512
// bytes) to the disk, then flush the drive's cache. Returns false on no-disk,
// bad args, or a controller error. The mirror of read(); the installer uses it
// to lay a system image onto a blank disk.
pub fn write(lba: u32, count: u16, src: []const u8) bool {
    if (!present) return false; // no disk to write to
    if (count == 0 or count > 256) return false; // one command moves 1..256 sectors
    if (src.len < @as(usize, count) * SECTOR_SIZE) return false; // source too small
    if (!waitNotBusy()) return false; // controller must be idle before we program it

    outb(DRIVE_HEAD, 0xE0 | @as(u8, @intCast((lba >> 24) & 0x0F))); // master + LBA mode + LBA 24..27
    delay400ns();
    outb(SECCOUNT, @intCast(count & 0xFF)); // 256 wraps to 0, meaning 256
    outb(LBA_LOW, @intCast(lba & 0xFF));
    outb(LBA_MID, @intCast((lba >> 8) & 0xFF));
    outb(LBA_HIGH, @intCast((lba >> 16) & 0xFF));
    outb(COMMAND, CMD_WRITE_PIO); // start the write

    var s: usize = 0;
    while (s < count) : (s += 1) {
        if (!waitDataRequest()) return false; // wait for the drive to want this sector
        var tmp: [256]u16 = undefined; // one sector, word-aligned for the OUT
        @memcpy(std.mem.sliceAsBytes(tmp[0..]), src[s * SECTOR_SIZE ..][0..SECTOR_SIZE]);
        repOutsw(DATA, &tmp, 256); // push the sector's 256 words out the data port
    }
    outb(COMMAND, CMD_FLUSH); // ensure the data reaches the medium, not just a cache
    if (!waitNotBusy()) return false; // wait for the flush to complete
    return true;
}

// Boot self-test: read sector 0 and print its first 16 bytes (printable form),
// proving the PIO path works against the attached disk. No-op without a disk.
pub fn selfTest() void {
    if (!present) {
        serial.log("[ATA] self-test skipped: no disk attached.\n", .{});
        return;
    }
    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!read(0, 1, &buf)) {
        serial.log("[ATA] self-test: read of LBA 0 FAILED.\n", .{});
        return;
    }
    serial.log("[ATA]   self-test: LBA0[0..16]='", .{});
    for (buf[0..16]) |b| {
        const c: u8 = if (b >= 0x20 and b < 0x7f) b else '.'; // show printable, dot the rest
        serial.log("{c}", .{c});
    }
    serial.log("'\n", .{});
    serial.log("[ATA] self-test: read LBA 0 OK.\n", .{});

    // Non-destructive write test: save the last sector, write a known pattern,
    // read it back, verify, then restore the original bytes — so the write path
    // is exercised without disturbing any filesystem data.
    if (total_sectors > 1) {
        const last = total_sectors - 1;
        var orig: [SECTOR_SIZE]u8 = undefined;
        if (!read(last, 1, &orig)) return;
        var pat: [SECTOR_SIZE]u8 = undefined;
        for (&pat, 0..) |*b, i| b.* = @truncate(i ^ 0xA5);
        var rb: [SECTOR_SIZE]u8 = undefined;
        const ok = write(last, 1, &pat) and read(last, 1, &rb) and std.mem.eql(u8, &pat, &rb);
        _ = write(last, 1, &orig); // restore the original contents either way
        serial.log("[ATA] self-test: write/read-back last sector {s}.\n", .{if (ok) "OK (restored)" else "MISMATCH"});
    }
}
