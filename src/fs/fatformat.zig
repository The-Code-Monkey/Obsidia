// FAT32 formatter (mkfs) — lays a fresh, empty FAT32 volume into a disk region.
//
// The in-kernel installer partitions a blank disk (see gpt.zig) and then needs a
// filesystem inside the ESP for the firmware and Limine to read. This writes that
// filesystem from scratch: the boot sector / BPB describing the geometry, the
// FSInfo sector, a backup copy of both, two zeroed File Allocation Tables with
// their reserved entries, and an empty root-directory cluster.
//
// A FAT32 volume is laid out, relative to its first sector, as:
//
//   sector 0            boot sector + BPB (geometry; ends in 0x55AA)
//   sector 1            FSInfo (free-cluster hints)
//   sector 6            backup boot sector
//   sector 7            backup FSInfo
//   sectors 0..R-1      reserved region (R = RESERVED, the rest is zero)
//   then NUM_FATS x FAT (each FATSz sectors)
//   then the data region; cluster 2 is the (empty) root directory
//
// Like gpt.zig, the layout writes through an `anytype` block sink so the host
// unit test drives the exact same bytes against a RAM buffer. The sink must
// expose `writeSector(lba, *const [512]u8) bool` and `zeroSectors(lba, n) bool`
// (the FATs are mostly zeros, so a bulk zero-fill keeps the kernel's slow PIO
// writes from formatting one zero sector at a time).

const std = @import("std");

pub const SECTOR = 512; // bytes per sector (we only support 512-byte disks)
const RESERVED = 32; // reserved sectors before the FATs (the FAT32 norm)
const NUM_FATS = 2; // two FAT copies (the standard redundancy)
const SEC_PER_CLUS = 1; // 1 sector/cluster: for our ~64 MiB ESP this yields
// ~129k clusters — comfortably above FAT32's 65525-cluster floor — and keeps the
// cluster math trivial.
const BK_BOOT = 6; // backup boot sector lives at sector 6 (the convention)
const ROOT_CLUSTER = 2; // first data cluster; FAT32 puts the root directory here
const VOL_ID = 0x0B51D1A0; // volume serial number (arbitrary but fixed)
const EOC = 0x0FFFFFF8; // end-of-cluster-chain marker value

// --- Little-endian field writers --------------------------------------------
fn wr16(b: []u8, o: usize, v: u16) void {
    b[o] = @truncate(v);
    b[o + 1] = @truncate(v >> 8);
}
fn wr32(b: []u8, o: usize, v: u32) void {
    b[o] = @truncate(v);
    b[o + 1] = @truncate(v >> 8);
    b[o + 2] = @truncate(v >> 16);
    b[o + 3] = @truncate(v >> 24);
}

// Sectors per FAT, via the fatgen reference formula. Each FAT must hold one
// 4-byte entry per cluster, but the cluster count itself depends on the FAT
// size (the FATs eat into the data region), so the spec solves the circularity
// with this closed form (which rounds slightly generous — always safe).
fn fatSize(total_sectors: u32) u32 {
    const tmp1 = total_sectors - RESERVED; // sectors available for FATs + data
    const tmp2 = (256 * @as(u32, SEC_PER_CLUS) + NUM_FATS) / 2; // FAT32 variant
    return (tmp1 + tmp2 - 1) / tmp2; // ceil(tmp1 / tmp2)
}

// Build the boot sector / BPB into `out` for a volume of `total_sectors` sectors
// starting `hidden` sectors into the disk, with FATs of `fat_size` each.
fn fillBootSector(out: *[SECTOR]u8, total_sectors: u32, hidden: u32, fat_size: u32) void {
    @memset(out, 0);
    out[0] = 0xEB; // jump instruction (jmp short +0x58) the spec mandates...
    out[1] = 0x58;
    out[2] = 0x90; // ...followed by a NOP
    @memcpy(out[3..11], "OBSIDIA "); // OEM name (8 bytes)
    wr16(out, 11, SECTOR); // BPB_BytsPerSec
    out[13] = SEC_PER_CLUS; // BPB_SecPerClus
    wr16(out, 14, RESERVED); // BPB_RsvdSecCnt
    out[16] = NUM_FATS; // BPB_NumFATs
    wr16(out, 17, 0); // BPB_RootEntCnt = 0 on FAT32
    wr16(out, 19, 0); // BPB_TotSec16 = 0 (use the 32-bit count)
    out[21] = 0xF8; // BPB_Media = fixed disk
    wr16(out, 22, 0); // BPB_FATSz16 = 0 on FAT32
    wr16(out, 24, 32); // BPB_SecPerTrk (geometry; cosmetic here)
    wr16(out, 26, 64); // BPB_NumHeads (geometry; cosmetic here)
    wr32(out, 28, hidden); // BPB_HiddSec = sectors before this partition
    wr32(out, 32, total_sectors); // BPB_TotSec32
    wr32(out, 36, fat_size); // BPB_FATSz32 (sectors per FAT)
    wr16(out, 40, 0); // BPB_ExtFlags (FAT mirroring on, FAT0 active)
    wr16(out, 42, 0); // BPB_FSVer = 0.0
    wr32(out, 44, ROOT_CLUSTER); // BPB_RootClus
    wr16(out, 48, 1); // BPB_FSInfo (sector 1)
    wr16(out, 50, BK_BOOT); // BPB_BkBootSec (sector 6)
    out[64] = 0x80; // BS_DrvNum (first hard disk)
    out[66] = 0x29; // BS_BootSig (extended boot signature present)
    wr32(out, 67, VOL_ID); // BS_VolID (volume serial number)
    @memcpy(out[71..82], "OBSIDIA    "); // BS_VolLab (11 bytes, space-padded)
    @memcpy(out[82..90], "FAT32   "); // BS_FilSysType (informational)
    out[510] = 0x55; // boot signature...
    out[511] = 0xAA;
}

// Build the FSInfo sector into `out`: the two magic signatures, the free-cluster
// count, and the next-free hint. Firmware treats these as hints and tolerates
// inaccuracy, but we fill them correctly for a freshly formatted volume.
fn fillFsInfo(out: *[SECTOR]u8, free_count: u32) void {
    @memset(out, 0);
    wr32(out, 0, 0x41615252); // FSI_LeadSig
    wr32(out, 484, 0x61417272); // FSI_StrucSig
    wr32(out, 488, free_count); // FSI_Free_Count (clusters still free)
    wr32(out, 492, ROOT_CLUSTER + 1); // FSI_Nxt_Free (search hint: cluster 3)
    wr32(out, 508, 0xAA550000); // FSI_TrailSig (00 00 55 AA on disk)
}

// Format the `total_sectors`-sector region beginning at `volume_lba` as FAT32.
// `dev` must expose writeSector(lba,buf) and zeroSectors(lba,n). Returns false on
// a too-small region or the first failed write.
pub fn run(dev: anytype, volume_lba: u64, total_sectors: u32) bool {
    if (total_sectors < RESERVED + NUM_FATS + 1) return false; // can't even hold metadata
    const fat_size = fatSize(total_sectors);
    const first_data = RESERVED + @as(u32, NUM_FATS) * fat_size; // relative to volume
    if (first_data + SEC_PER_CLUS > total_sectors) return false; // no room for a root cluster
    const cluster_count = (total_sectors - first_data) / SEC_PER_CLUS;

    // Zero the whole reserved region first, then drop the real sectors on top, so
    // sectors 2..5 / 8..31 are cleanly zero regardless of the disk's prior state.
    if (!dev.zeroSectors(volume_lba, RESERVED)) return false;

    var sec: [SECTOR]u8 = undefined;

    // Boot sector + FSInfo, plus their backup copies at sector 6 / 7.
    fillBootSector(&sec, total_sectors, @intCast(volume_lba), fat_size);
    if (!dev.writeSector(volume_lba, &sec)) return false; // sector 0
    if (!dev.writeSector(volume_lba + BK_BOOT, &sec)) return false; // sector 6 (backup)
    fillFsInfo(&sec, cluster_count - 1); // root uses one cluster, so one fewer free
    if (!dev.writeSector(volume_lba + 1, &sec)) return false; // sector 1
    if (!dev.writeSector(volume_lba + BK_BOOT + 1, &sec)) return false; // sector 7 (backup)

    // Each FAT: a first sector holding the three reserved entries (media byte in
    // entry 0, EOC in entry 1, and the root directory's end-of-chain in entry 2),
    // then the remaining FAT sectors zeroed (every other cluster is free).
    @memset(&sec, 0);
    wr32(&sec, 0, 0x0FFFFFF8); // FAT[0]: media descriptor in the low byte
    wr32(&sec, 4, 0x0FFFFFFF); // FAT[1]: end-of-chain / "clean" flags
    wr32(&sec, 8, EOC); // FAT[2]: the root directory is a single-cluster chain
    var f: u32 = 0;
    while (f < NUM_FATS) : (f += 1) {
        const fat_start = volume_lba + RESERVED + @as(u64, f) * fat_size;
        if (!dev.writeSector(fat_start, &sec)) return false; // first FAT sector
        if (!dev.zeroSectors(fat_start + 1, fat_size - 1)) return false; // the rest is free
    }

    // The root directory cluster starts empty (all zero = no entries yet).
    const root_sector = volume_lba + first_data + (ROOT_CLUSTER - 2) * SEC_PER_CLUS;
    if (!dev.zeroSectors(root_sector, SEC_PER_CLUS)) return false;
    return true;
}

// --- Host unit tests (zig build test) ----------------------------------------
// A RAM-backed sink so the formatter runs on the host exactly as in the kernel.
const RamDisk = struct {
    data: []u8,
    fn writeSector(self: RamDisk, lba: u64, buf: *const [SECTOR]u8) bool {
        const off = lba * SECTOR;
        if (off + SECTOR > self.data.len) return false;
        @memcpy(self.data[off..][0..SECTOR], buf);
        return true;
    }
    fn zeroSectors(self: RamDisk, lba: u64, n: u64) bool {
        const off = lba * SECTOR;
        if (off + n * SECTOR > self.data.len) return false;
        @memset(self.data[off..][0 .. n * SECTOR], 0);
        return true;
    }
};

fn rd16(b: []const u8, o: usize) u16 {
    return @as(u16, b[o]) | (@as(u16, b[o + 1]) << 8);
}
fn rd32(b: []const u8, o: usize) u32 {
    return @as(u32, b[o]) | (@as(u32, b[o + 1]) << 8) |
        (@as(u32, b[o + 2]) << 16) | (@as(u32, b[o + 3]) << 24);
}

test "formats a valid empty FAT32 volume at an offset" {
    const total: u32 = 64 * 1024 * 1024 / SECTOR; // 64 MiB volume
    const volume_lba: u64 = 2048; // mimic an ESP at 1 MiB
    const disk_sectors: u64 = volume_lba + total; // disk holds the offset + volume
    const buf = try std.testing.allocator.alloc(u8, disk_sectors * SECTOR);
    defer std.testing.allocator.free(buf);
    @memset(buf, 0xCC); // pre-dirty so we prove reserved/FAT areas get cleared

    try std.testing.expect(run(RamDisk{ .data = buf }, volume_lba, total));

    const bs = buf[volume_lba * SECTOR ..][0..SECTOR]; // the boot sector
    // BPB geometry the kernel's mount() reads back.
    try std.testing.expectEqual(@as(u16, SECTOR), rd16(bs, 11));
    try std.testing.expectEqual(@as(u8, SEC_PER_CLUS), bs[13]);
    try std.testing.expectEqual(@as(u16, RESERVED), rd16(bs, 14));
    try std.testing.expectEqual(@as(u8, NUM_FATS), bs[16]);
    try std.testing.expectEqual(@as(u32, ROOT_CLUSTER), rd32(bs, 44));
    try std.testing.expectEqual(total, rd32(bs, 32));
    try std.testing.expectEqualSlices(u8, "FAT32   ", bs[82..90]);
    try std.testing.expectEqual(@as(u8, 0x55), bs[510]);
    try std.testing.expectEqual(@as(u8, 0xAA), bs[511]);
    // BPB_HiddSec records the partition's start.
    try std.testing.expectEqual(@as(u32, @intCast(volume_lba)), rd32(bs, 28));

    // The backup boot sector at sector 6 is an exact copy.
    const bk = buf[(volume_lba + BK_BOOT) * SECTOR ..][0..SECTOR];
    try std.testing.expectEqualSlices(u8, bs, bk);

    // FSInfo signatures.
    const fsi = buf[(volume_lba + 1) * SECTOR ..][0..SECTOR];
    try std.testing.expectEqual(@as(u32, 0x41615252), rd32(fsi, 0));
    try std.testing.expectEqual(@as(u32, 0x61417272), rd32(fsi, 484));
    try std.testing.expectEqual(@as(u32, 0xAA550000), rd32(fsi, 508));

    // FAT entries 0/1/2 in the first FAT sector.
    const fat_size = fatSize(total);
    const fat0 = buf[(volume_lba + RESERVED) * SECTOR ..][0..SECTOR];
    try std.testing.expectEqual(@as(u32, 0x0FFFFFF8), rd32(fat0, 0));
    try std.testing.expectEqual(@as(u32, 0x0FFFFFFF), rd32(fat0, 4));
    try std.testing.expectEqual(@as(u32, EOC), rd32(fat0, 8));
    // Entry 3 must be free (0) — proves the FAT tail was zeroed over the 0xCC.
    try std.testing.expectEqual(@as(u32, 0), rd32(fat0, 12));

    // FAT32 cluster-count floor: a real FAT32 volume has > 65525 clusters.
    const first_data = RESERVED + @as(u32, NUM_FATS) * fat_size;
    const clusters = (total - first_data) / SEC_PER_CLUS;
    try std.testing.expect(clusters > 65525);

    // The root cluster is empty (first directory byte is 0 = no entries).
    const root = buf[(volume_lba + first_data) * SECTOR ..][0..SECTOR];
    try std.testing.expectEqual(@as(u8, 0), root[0]);
}

test "rejects a region too small to format" {
    var small: [16 * SECTOR]u8 = undefined;
    try std.testing.expect(!run(RamDisk{ .data = &small }, 0, RESERVED)); // no data room
}
