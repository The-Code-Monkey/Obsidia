// GUID Partition Table (GPT) writer — lays out a single-partition disk.
//
// A UEFI-bootable disk is partitioned with GPT, not the old MBR scheme. GPT's
// on-disk shape is:
//
//   LBA 0            protective MBR (one 0xEE partition spanning the disk, so
//                    legacy MBR tools see "something" and don't clobber it)
//   LBA 1            primary GPT header ("EFI PART")
//   LBA 2..33        primary partition-entry array (128 entries x 128 bytes)
//   LBA 34..N-34     usable space (our one ESP partition lives here)
//   LBA N-33..N-2    backup partition-entry array
//   LBA N-1          backup GPT header
//
// We write exactly one partition: an EFI System Partition (ESP), the FAT volume
// the firmware boots from. Both the header and the entry array carry a CRC-32 the
// firmware verifies, so we compute those the same way the spec mandates.
//
// The layout code takes an `anytype` block sink (a value with a `writeSector`
// method) rather than calling the ATA driver directly: the kernel backs it with
// the real disk, and the host unit test backs it with a RAM buffer, so the exact
// same byte layout is exercised on the dev machine by `zig build test`.

const std = @import("std");

pub const SECTOR = 512; // bytes per sector (we only support 512-byte disks)
pub const ENTRY_COUNT = 128; // partition entries in the array (the GPT default)
pub const ENTRY_SIZE = 128; // bytes per partition entry (the GPT default)
const ARRAY_SECTORS = ENTRY_COUNT * ENTRY_SIZE / SECTOR; // = 32 sectors of entries
pub const FIRST_USABLE_LBA = 2 + ARRAY_SECTORS; // first LBA past the primary array (34)

// The standard EFI System Partition type GUID, C12A7328-F81F-11D2-BA4B-
// 00A0C93EC93B, in the on-disk mixed-endian byte order (first three GUID fields
// little-endian, last two big-endian). Firmware looks for exactly this to know a
// partition is an ESP it can boot from.
pub const ESP_TYPE_GUID = [16]u8{
    0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
    0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B,
};

// Fixed GUIDs for the disk and the partition. A real tool randomizes these per
// install so two disks never collide; for a single-disk hobby installer a stable
// value is fine and keeps the kernel free of an entropy source. (Distinct from
// each other and from the ESP *type* GUID above.)
const DISK_GUID = [16]u8{
    0x0B, 0x51, 0x4D, 0x0B, 0x51, 0x4D, 0x51, 0x4D, // "OBSIDIA"-flavored, arbitrary
    0xAB, 0xCD, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
};
const PART_GUID = [16]u8{
    0x0B, 0x51, 0x4D, 0x0B, 0x51, 0x4D, 0x51, 0x4D,
    0xAB, 0xCD, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60,
};

// GPT and protective-MBR CRCs use the standard CRC-32 (the same polynomial as
// zlib / Ethernet), which is exactly std's Crc32.
const Crc32 = std.hash.crc.Crc32;

// --- Little-endian field writers --------------------------------------------
fn wr32(b: []u8, o: usize, v: u32) void {
    b[o] = @truncate(v);
    b[o + 1] = @truncate(v >> 8);
    b[o + 2] = @truncate(v >> 16);
    b[o + 3] = @truncate(v >> 24);
}
fn wr64(b: []u8, o: usize, v: u64) void {
    wr32(b, o, @truncate(v));
    wr32(b, o + 4, @truncate(v >> 32));
}

// Build the one ESP partition entry (128 bytes) into `out`: type + unique GUIDs,
// the first/last LBA span, no attribute flags, and a UTF-16LE "ESP" name.
fn fillEspEntry(out: *[ENTRY_SIZE]u8, first_lba: u64, last_lba: u64) void {
    @memset(out, 0);
    @memcpy(out[0..16], &ESP_TYPE_GUID); // partition type = EFI System Partition
    @memcpy(out[16..32], &PART_GUID); // this partition's unique GUID
    wr64(out, 32, first_lba); // starting LBA (inclusive)
    wr64(out, 40, last_lba); // ending LBA (inclusive)
    wr64(out, 48, 0); // attribute flags: none
    const name = "ESP"; // partition name, stored as UTF-16LE in the 72-byte field
    for (name, 0..) |ch, i| out[56 + i * 2] = ch; // ASCII -> UTF-16LE (high byte 0)
}

// Build the protective MBR (LBA 0): an empty boot-code area, a single type-0xEE
// partition covering the whole disk (capped at 32 bits per the spec), and the
// 0x55AA signature. Its only job is to stop legacy tools from seeing the disk as
// unpartitioned and overwriting the GPT.
fn fillProtectiveMbr(out: *[SECTOR]u8, total_sectors: u64) void {
    @memset(out, 0);
    const p = out[446..][0..16]; // the first MBR partition entry
    p[0] = 0x00; // not bootable (UEFI ignores this)
    p[1] = 0x00; // CHS first sector: head 0...
    p[2] = 0x02; // ...sector 2...
    p[3] = 0x00; // ...cylinder 0
    p[4] = 0xEE; // partition type 0xEE = "GPT protective"
    p[5] = 0xFF; // CHS last: maxed out (CHS is meaningless on a modern disk)
    p[6] = 0xFF;
    p[7] = 0xFF;
    wr32(p, 8, 1); // first LBA = 1 (the GPT header that follows)
    // sector count = whole disk minus the MBR, capped at the 32-bit field max.
    const span = @min(total_sectors - 1, @as(u64, 0xFFFFFFFF));
    wr32(p, 12, @intCast(span));
    out[510] = 0x55; // boot signature
    out[511] = 0xAA;
}

// Build a GPT header (LBA `my_lba`, with its partner at `alt_lba` and its entry
// array at `entries_lba`) into `out`, then stamp its CRC. `array_crc` is the
// CRC-32 of the partition-entry array (identical for the primary and backup).
fn fillHeader(
    out: *[SECTOR]u8,
    my_lba: u64,
    alt_lba: u64,
    entries_lba: u64,
    first_usable: u64,
    last_usable: u64,
    array_crc: u32,
) void {
    @memset(out, 0);
    @memcpy(out[0..8], "EFI PART"); // signature
    wr32(out, 8, 0x00010000); // revision 1.0
    wr32(out, 12, 92); // header size in bytes
    wr32(out, 16, 0); // header CRC-32 — zeroed while we compute it
    wr32(out, 20, 0); // reserved (must be zero)
    wr64(out, 24, my_lba); // the LBA of this header
    wr64(out, 32, alt_lba); // the LBA of the other (backup/primary) header
    wr64(out, 40, first_usable); // first LBA usable by partitions
    wr64(out, 48, last_usable); // last LBA usable by partitions
    @memcpy(out[56..72], &DISK_GUID); // disk GUID
    wr64(out, 72, entries_lba); // LBA where this header's entry array starts
    wr32(out, 80, ENTRY_COUNT); // number of partition entries
    wr32(out, 84, ENTRY_SIZE); // bytes per partition entry
    wr32(out, 88, array_crc); // CRC-32 of the entry array
    // Header CRC is computed over the first 92 bytes with the CRC field zeroed
    // (which it currently is), then written back into that field.
    wr32(out, 16, Crc32.hash(out[0..92]));
}

// CRC-32 of the whole 128-entry array, of which only the first entry is non-zero.
// Computed incrementally (the one entry, then the trailing zeros in a chunk) so
// we never materialize the 16 KiB array in memory.
fn arrayCrc(entry0: *const [ENTRY_SIZE]u8) u32 {
    var c = Crc32.init();
    c.update(entry0); // the one real partition entry
    const zeros = [_]u8{0} ** ENTRY_SIZE; // a single zero entry...
    var i: usize = 1;
    while (i < ENTRY_COUNT) : (i += 1) c.update(&zeros); // ...folded in ENTRY_COUNT-1 times
    return c.final();
}

// Write a GPT to `dev` describing one ESP that starts at `part_first_lba` and
// runs to the last usable sector. `dev` must expose
// `writeSector(lba: u64, buf: *const [SECTOR]u8) bool`. Returns false on the
// first failed sector write or if the geometry doesn't fit the disk.
pub fn write(dev: anytype, total_sectors: u64, part_first_lba: u64) bool {
    // We need room for both metadata copies plus at least one partition sector.
    if (total_sectors < FIRST_USABLE_LBA * 2 + 1) return false;
    const last_usable = total_sectors - FIRST_USABLE_LBA; // mirror of first_usable
    if (part_first_lba < FIRST_USABLE_LBA or part_first_lba > last_usable) return false;

    const backup_header_lba = total_sectors - 1; // last sector
    const backup_array_lba = total_sectors - 1 - ARRAY_SECTORS; // 32 sectors before it

    // The single partition entry, and the array CRC both headers will carry.
    var entry0: [ENTRY_SIZE]u8 = undefined;
    fillEspEntry(&entry0, part_first_lba, last_usable);
    const acrc = arrayCrc(&entry0);

    var sec: [SECTOR]u8 = undefined;

    // LBA 0: protective MBR.
    fillProtectiveMbr(&sec, total_sectors);
    if (!dev.writeSector(0, &sec)) return false;

    // LBA 1: primary header (its array is at LBA 2; backup header at the end).
    fillHeader(&sec, 1, backup_header_lba, 2, FIRST_USABLE_LBA, last_usable, acrc);
    if (!dev.writeSector(1, &sec)) return false;

    // LBA `backup_header_lba`: backup header (mirror; its array precedes it).
    fillHeader(&sec, backup_header_lba, 1, backup_array_lba, FIRST_USABLE_LBA, last_usable, acrc);
    if (!dev.writeSector(backup_header_lba, &sec)) return false;

    // The first sector of each entry array holds entry 0 (and three zero entries);
    // the remaining 31 sectors are entirely zero. Write both copies.
    @memset(&sec, 0);
    @memcpy(sec[0..ENTRY_SIZE], &entry0);
    if (!dev.writeSector(2, &sec)) return false; // primary array, sector 0
    if (!dev.writeSector(backup_array_lba, &sec)) return false; // backup array, sector 0
    @memset(&sec, 0); // the rest of both arrays is zero
    var i: u64 = 1;
    while (i < ARRAY_SECTORS) : (i += 1) {
        if (!dev.writeSector(2 + i, &sec)) return false; // primary array tail
        if (!dev.writeSector(backup_array_lba + i, &sec)) return false; // backup array tail
    }
    return true;
}

// --- Host unit tests (zig build test) ----------------------------------------
// A RAM-backed block sink so the layout runs on the host exactly as in the kernel.
const RamDisk = struct {
    data: []u8,
    fn writeSector(self: RamDisk, lba: u64, buf: *const [SECTOR]u8) bool {
        const off = lba * SECTOR;
        if (off + SECTOR > self.data.len) return false;
        @memcpy(self.data[off..][0..SECTOR], buf);
        return true;
    }
};

fn rd32(b: []const u8, o: usize) u32 {
    return @as(u32, b[o]) | (@as(u32, b[o + 1]) << 8) |
        (@as(u32, b[o + 2]) << 16) | (@as(u32, b[o + 3]) << 24);
}
fn rd64(b: []const u8, o: usize) u64 {
    return @as(u64, rd32(b, o)) | (@as(u64, rd32(b, o + 4)) << 32);
}

test "Crc32 matches the standard check value" {
    // The canonical CRC-32 of "123456789" is 0xCBF43926 — proves we're using the
    // exact algorithm GPT's CRC fields expect, not merely a self-consistent one.
    try std.testing.expectEqual(@as(u32, 0xCBF43926), Crc32.hash("123456789"));
}

test "GPT writer produces a valid, self-consistent single-ESP layout" {
    const total: u64 = 64 * 1024 * 1024 / SECTOR; // a 64 MiB disk
    const part_first: u64 = 2048; // ESP at 1 MiB, like install.sh
    const buf = try std.testing.allocator.alloc(u8, total * SECTOR);
    defer std.testing.allocator.free(buf);
    @memset(buf, 0);

    try std.testing.expect(write(RamDisk{ .data = buf }, total, part_first));

    // Protective MBR: a 0xEE partition and the 0x55AA signature.
    try std.testing.expectEqual(@as(u8, 0xEE), buf[446 + 4]);
    try std.testing.expectEqual(@as(u8, 0x55), buf[510]);
    try std.testing.expectEqual(@as(u8, 0xAA), buf[511]);

    // Primary header: signature, and a header CRC that re-validates when the CRC
    // field is zeroed and recomputed over the 92-byte header.
    const hdr = buf[SECTOR..][0..SECTOR];
    try std.testing.expectEqualSlices(u8, "EFI PART", hdr[0..8]);
    const stored_hdr_crc = rd32(hdr, 16);
    var tmp: [92]u8 = undefined;
    @memcpy(&tmp, hdr[0..92]);
    wr32(&tmp, 16, 0);
    try std.testing.expectEqual(stored_hdr_crc, Crc32.hash(&tmp));

    // The entry-array CRC in the header must match a fresh CRC of the array bytes.
    const arr = buf[2 * SECTOR ..][0 .. ENTRY_COUNT * ENTRY_SIZE];
    try std.testing.expectEqual(rd32(hdr, 88), Crc32.hash(arr));

    // The one partition entry: ESP type GUID and the LBA span we asked for.
    try std.testing.expectEqualSlices(u8, &ESP_TYPE_GUID, arr[0..16]);
    try std.testing.expectEqual(part_first, rd64(arr, 32));
    try std.testing.expectEqual(total - FIRST_USABLE_LBA, rd64(arr, 40));

    // Backup header at the last LBA mirrors the primary (same array CRC) and
    // points back at LBA 1.
    const bhdr = buf[(total - 1) * SECTOR ..][0..SECTOR];
    try std.testing.expectEqualSlices(u8, "EFI PART", bhdr[0..8]);
    try std.testing.expectEqual(@as(u64, 1), rd64(bhdr, 32)); // alternate LBA = primary
    try std.testing.expectEqual(rd32(hdr, 88), rd32(bhdr, 88)); // same entry-array CRC
}

test "GPT writer rejects a disk that is too small" {
    var small: [8 * SECTOR]u8 = undefined; // 8 sectors: can't hold two GPT copies
    try std.testing.expect(!write(RamDisk{ .data = &small }, 8, 2048));
}
