// FAT32 filesystem — read-only.
//
// FAT32 lays a disk out as: [reserved sectors | FAT(s) | data region]. The very
// first sector (the "boot sector" / BPB) describes the geometry. Files and
// directories live in "clusters" (groups of sectors); each cluster points to the
// next via the File Allocation Table, forming a singly linked chain. A directory
// is just a file whose data is an array of 32-byte entries.
//
// This module mounts a raw FAT32 volume (no partition table — the whole disk is
// one filesystem), walks paths, lists directories (short 8.3 + long names), and
// reads file contents. It reads sectors through the ATA PIO driver.

const std = @import("std");
const serial = @import("../drivers/serial.zig");
const ata = @import("../drivers/ata.zig");
const lfnenc = @import("lfn.zig"); // long-name (LFN) entry encoding for the write path

const SECTOR = 512; // bytes per sector (we only support 512-byte-sector disks)
const EOC = 0x0FFFFFF8; // FAT entries >= this mark the end of a cluster chain
const ATTR_DIRECTORY = 0x10; // directory-entry attribute bit
const ATTR_VOLUME_ID = 0x08; // volume-label entry (skip these)
const ATTR_LFN = 0x0F; // a "long file name" component entry (RO|HID|SYS|VOL)

// Geometry read from the boot sector, plus the derived first-data-sector.
const BootInfo = struct {
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sectors: u16,
    num_fats: u8,
    fat_size: u32, // sectors per FAT
    root_cluster: u32,
    total_sectors: u32,
    first_data_sector: u32, // where the data region (cluster 2) begins (relative)
    volume_start: u32, // disk LBA where the volume begins (0 = whole-disk mount;
    // nonzero when the volume lives in a partition, e.g. an ESP at LBA 2048).
    // Every absolute LBA we compute is offset by this, so the same read/write
    // code serves both a raw FAT32 disk and a partition.
};

var bi: BootInfo = undefined;
var mounted: bool = false;

// One resolved directory entry, handed to scan callbacks. `name` points into a
// caller-owned stack buffer that is only valid for the duration of the callback.
const Entry = struct {
    name: []const u8,
    first_cluster: u32,
    size: u32,
    is_dir: bool,
};

// A resolved path: which cluster its data starts at, its size, and whether it's
// a directory. The root directory is {root_cluster, 0, dir}.
pub const Node = struct {
    cluster: u32,
    size: u32,
    is_dir: bool,
};

// --- Little-endian field readers --------------------------------------------
// FAT structures store multi-byte numbers little-endian (low byte first).
fn rd16(b: []const u8, o: usize) u16 {
    return @as(u16, b[o]) | (@as(u16, b[o + 1]) << 8);
}
fn rd32(b: []const u8, o: usize) u32 {
    return @as(u32, b[o]) | (@as(u32, b[o + 1]) << 8) |
        (@as(u32, b[o + 2]) << 16) | (@as(u32, b[o + 3]) << 24);
}

pub fn isMounted() bool {
    return mounted;
}

// --- One-sector FAT cache ----------------------------------------------------
// Following a cluster chain re-reads the FAT a lot; caching the last FAT sector
// makes walking a chain that stays within one FAT sector free after the first.
var fat_cache_sector: u32 = 0xFFFFFFFF; // which FAT sector is cached (invalid = none)
var fat_cache: [SECTOR]u8 = undefined; // the cached FAT sector bytes

// Look up the next cluster after `cluster` in the chain (or >= EOC at the end).
fn nextCluster(cluster: u32) u32 {
    const fat_offset = cluster * 4; // each FAT32 entry is 4 bytes
    const fat_sector = bi.volume_start + bi.reserved_sectors + (fat_offset / @as(u32, bi.bytes_per_sector));
    const entry_offset = fat_offset % @as(u32, bi.bytes_per_sector);
    if (fat_sector != fat_cache_sector) { // not cached -> fetch it
        if (!ata.read(fat_sector, 1, &fat_cache)) return EOC; // read error: stop the chain
        fat_cache_sector = fat_sector;
    }
    return rd32(&fat_cache, entry_offset) & 0x0FFFFFFF; // top 4 bits are reserved
}

// The first (absolute) LBA sector of a given cluster's data.
fn clusterToSector(c: u32) u32 {
    return bi.volume_start + bi.first_data_sector + (c - 2) * bi.sectors_per_cluster;
}

// Is `c` a valid in-use data cluster (not free, not end-of-chain, not bad)?
fn isDataCluster(c: u32) bool {
    return c >= 2 and c < EOC;
}

// --- Mount -------------------------------------------------------------------
// Mount the whole disk as one FAT32 volume (the volume begins at LBA 0). This is
// the common case (run.sh's dev disk); the installer uses mountAt() for an ESP.
pub fn mount() bool {
    return mountAt(0);
}

// Read and validate the boot sector at disk LBA `start`, then compute the
// geometry we need, recording `start` so every later LBA is offset by it. Safe to
// call with no disk or an unformatted volume: it reports why and returns false.
pub fn mountAt(start: u32) bool {
    if (!ata.isPresent()) {
        serial.print("[FAT32] no disk present — nothing to mount.\n", .{});
        return false;
    }
    var bs: [SECTOR]u8 = undefined;
    if (!ata.read(start, 1, &bs)) {
        serial.print("[FAT32] failed to read the boot sector.\n", .{});
        return false;
    }
    if (rd16(&bs, 510) != 0xAA55) { // the boot-sector signature every FAT volume has
        serial.print("[FAT32] no boot signature (disk not formatted FAT?).\n", .{});
        return false;
    }
    bi.bytes_per_sector = rd16(&bs, 11);
    bi.sectors_per_cluster = bs[13];
    bi.reserved_sectors = rd16(&bs, 14);
    bi.num_fats = bs[16];
    bi.fat_size = rd32(&bs, 36); // BPB_FATSz32
    bi.root_cluster = rd32(&bs, 44); // BPB_RootClus
    bi.total_sectors = rd32(&bs, 32); // BPB_TotSec32

    if (bi.bytes_per_sector != SECTOR) {
        serial.print("[FAT32] unsupported sector size {d} (need 512).\n", .{bi.bytes_per_sector});
        return false;
    }
    if (bi.sectors_per_cluster == 0 or bi.fat_size == 0) {
        serial.print("[FAT32] not a FAT32 volume (cluster/FAT size zero).\n", .{});
        return false;
    }
    // Data region begins after the reserved sectors and all FAT copies (relative
    // to the volume start; clusterToSector adds volume_start for absolute LBAs).
    bi.first_data_sector = bi.reserved_sectors + @as(u32, bi.num_fats) * bi.fat_size;
    bi.volume_start = start; // remember where the volume lives on the disk
    fat_cache_sector = 0xFFFFFFFF; // invalidate the FAT cache for the new volume
    mounted = true;
    serial.print("[FAT32] mounted: {d}-byte sectors, {d} sec/cluster, {d} FAT(s), root cluster {d}, data @ sector {d}.\n", .{ bi.bytes_per_sector, bi.sectors_per_cluster, bi.num_fats, bi.root_cluster, bi.first_data_sector });
    return true;
}

// --- Directory scanning ------------------------------------------------------
// Long file names are stored as a run of ATTR_LFN entries that PRECEDE the real
// 8.3 entry, ordered from the last name-chunk to the first. Each holds 13 UTF-16
// chars at these (scattered) byte offsets within the 32-byte entry.
const LFN_OFFSETS = [_]u8{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };

// Fold one LFN entry's 13 chars into the assembly buffer at its sequenced slot.
fn accumulateLfn(ent: []const u8, lfn: *[256]u8, lfn_len: *usize) void {
    const seq = ent[0] & 0x1F; // 1-based position of this chunk in the name
    if (seq == 0 or seq > 19) return; // ignore odd sequences (cap ~247 chars)
    const base = (@as(usize, seq) - 1) * 13; // where this chunk's chars start
    var i: usize = 0;
    while (i < 13) : (i += 1) {
        const o = LFN_OFFSETS[i];
        const ch = @as(u16, ent[o]) | (@as(u16, ent[o + 1]) << 8);
        if (ch == 0x0000 or ch == 0xFFFF) continue; // name terminator / padding
        const pos = base + i;
        if (pos < lfn.len) {
            lfn[pos] = if (ch < 0x80) @intCast(ch) else '?'; // we only render ASCII
            if (pos + 1 > lfn_len.*) lfn_len.* = pos + 1;
        }
    }
}

// Render an 8.3 short name ("FOO     TXT") as "FOO.TXT" into `out`. Honors the
// Windows/NT "lowercase" flags in the reserved byte (offset 0x0C): bit 0x08
// means the base name is really lowercase, bit 0x10 means the extension is —
// that's how an all-lowercase name like "docs" is stored without a long-name.
fn shortName(ent: []const u8, out: *[256]u8) []const u8 {
    const flags = ent[0x0C];
    const base_lower = (flags & 0x08) != 0;
    const ext_lower = (flags & 0x10) != 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i < 8 and ent[i] != ' ') : (i += 1) { // base name, stop at padding space
        out[n] = if (base_lower) std.ascii.toLower(ent[i]) else ent[i];
        n += 1;
    }
    var ext_len: usize = 0; // count non-space extension chars
    while (ext_len < 3 and ent[8 + ext_len] != ' ') ext_len += 1;
    if (ext_len > 0) {
        out[n] = '.';
        n += 1;
        var j: usize = 0;
        while (j < ext_len) : (j += 1) {
            out[n] = if (ext_lower) std.ascii.toLower(ent[8 + j]) else ent[8 + j];
            n += 1;
        }
    }
    return out[0..n];
}

// Walk every entry in the directory chain starting at `start_cluster`, calling
// `onEntry(ctx, entry)` for each real file/subdirectory. The callback returns
// true to stop early. LFNs are assembled and used in place of the 8.3 name.
fn scanDir(start_cluster: u32, ctx: anytype, comptime onEntry: fn (@TypeOf(ctx), Entry) bool) void {
    var sector: [SECTOR]u8 = undefined; // one directory sector at a time
    var lfn: [256]u8 = undefined; // assembled long-name buffer
    var lfn_len: usize = 0; // current assembled long-name length (0 = none)
    var cluster = start_cluster;
    while (isDataCluster(cluster)) { // each cluster in the directory's chain
        var s: u32 = 0;
        while (s < bi.sectors_per_cluster) : (s += 1) { // each sector in the cluster
            if (!ata.read(clusterToSector(cluster) + s, 1, &sector)) return;
            var e: usize = 0;
            while (e < SECTOR / 32) : (e += 1) { // 16 entries per 512-byte sector
                const ent = sector[e * 32 .. e * 32 + 32];
                const first = ent[0];
                if (first == 0x00) return; // 0x00 = no entries follow, anywhere
                if (first == 0xE5) { // deleted entry: drop any pending LFN
                    lfn_len = 0;
                    continue;
                }
                const attr = ent[0x0B];
                if (attr == ATTR_LFN) { // part of a long name -> accumulate
                    accumulateLfn(ent, &lfn, &lfn_len);
                    continue;
                }
                if (attr & ATTR_VOLUME_ID != 0) { // volume label -> not a file
                    lfn_len = 0;
                    continue;
                }
                // Real 8.3 entry. Use the assembled long name if we have one.
                var shortbuf: [256]u8 = undefined;
                const name = if (lfn_len > 0) lfn[0..lfn_len] else shortName(ent, &shortbuf);
                const fc = (@as(u32, rd16(ent, 0x14)) << 16) | rd16(ent, 0x1A);
                const entry = Entry{
                    .name = name,
                    .first_cluster = fc,
                    .size = rd32(ent, 0x1C),
                    .is_dir = (attr & ATTR_DIRECTORY) != 0,
                };
                lfn_len = 0; // consume the long name
                if (onEntry(ctx, entry)) return; // callback asked to stop
            }
        }
        cluster = nextCluster(cluster); // advance to the next directory cluster
    }
}

// --- Path resolution ---------------------------------------------------------
const FindCtx = struct { target: []const u8, result: ?Node = null };
fn findCallback(ctx: *FindCtx, e: Entry) bool {
    if (std.ascii.eqlIgnoreCase(e.name, ctx.target)) { // FAT names are case-insensitive
        ctx.result = .{ .cluster = e.first_cluster, .size = e.size, .is_dir = e.is_dir };
        return true; // found it — stop scanning
    }
    return false;
}

// Find `name` directly inside the directory at `cluster`.
fn findInDir(cluster: u32, name: []const u8) ?Node {
    var ctx = FindCtx{ .target = name };
    scanDir(cluster, &ctx, findCallback);
    return ctx.result;
}

// Resolve an absolute path like "/docs/notes.txt" to a Node, walking each
// component from the root directory. Returns null if any component is missing.
pub fn resolve(path: []const u8) ?Node {
    if (!mounted) return null;
    var node = Node{ .cluster = bi.root_cluster, .size = 0, .is_dir = true };
    var it = std.mem.tokenizeScalar(u8, path, '/'); // split on '/', skipping empties
    while (it.next()) |comp| {
        if (!node.is_dir) return null; // a path component under a non-directory
        node = findInDir(node.cluster, comp) orelse return null;
    }
    return node;
}

// --- Public operations -------------------------------------------------------
const ListCtx = struct {};
fn listCallback(_: *ListCtx, e: Entry) bool {
    if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) return false; // skip self/parent
    if (e.is_dir) {
        serial.print("  <DIR>          {s}\n", .{e.name});
    } else {
        serial.print("  {d:>10}  {s}\n", .{ e.size, e.name });
    }
    return false; // keep listing
}

// List a directory (or print a single file's size if `path` is a file).
pub fn ls(path: []const u8) void {
    if (!mounted) {
        serial.print("fat32: no filesystem mounted\n", .{});
        return;
    }
    const node = resolve(path) orelse {
        serial.print("ls: no such path: {s}\n", .{path});
        return;
    };
    if (!node.is_dir) {
        serial.print("  {d:>10}  {s}\n", .{ node.size, path });
        return;
    }
    var ctx = ListCtx{};
    scanDir(node.cluster, &ctx, listCallback);
}

// Stream a file's contents to serial (used by the shell's `cat`).
pub fn cat(path: []const u8) void {
    if (!mounted) {
        serial.print("fat32: no filesystem mounted\n", .{});
        return;
    }
    const node = resolve(path) orelse {
        serial.print("cat: no such file: {s}\n", .{path});
        return;
    };
    if (node.is_dir) {
        serial.print("cat: {s} is a directory\n", .{path});
        return;
    }
    var remaining = node.size;
    var cluster = node.cluster;
    var buf: [SECTOR]u8 = undefined;
    while (remaining > 0 and isDataCluster(cluster)) {
        var s: u32 = 0;
        while (s < bi.sectors_per_cluster and remaining > 0) : (s += 1) {
            if (!ata.read(clusterToSector(cluster) + s, 1, &buf)) return;
            const n = @min(remaining, @as(u32, bi.bytes_per_sector)); // don't print past EOF
            serial.print("{s}", .{buf[0..n]});
            remaining -= n;
        }
        cluster = nextCluster(cluster);
    }
}

// Read a whole file into `dst` (up to dst.len bytes). Returns the number of
// bytes read, or null on error / file-too-big-for-buffer. This is the primitive
// the next milestone (loading an init binary) will build on.
pub fn readFile(path: []const u8, dst: []u8) ?usize {
    if (!mounted) return null;
    const node = resolve(path) orelse return null;
    if (node.is_dir) return null;
    if (node.size > dst.len) return null; // caller's buffer is too small
    var remaining = node.size;
    var cluster = node.cluster;
    var written: usize = 0;
    var buf: [SECTOR]u8 = undefined;
    while (remaining > 0 and isDataCluster(cluster)) {
        var s: u32 = 0;
        while (s < bi.sectors_per_cluster and remaining > 0) : (s += 1) {
            if (!ata.read(clusterToSector(cluster) + s, 1, &buf)) return null;
            const n = @min(remaining, @as(u32, bi.bytes_per_sector));
            @memcpy(dst[written .. written + n], buf[0..n]);
            written += n;
            remaining -= n;
        }
        cluster = nextCluster(cluster);
    }
    return written;
}

// === Write path ==============================================================
// Enough FAT32 write support for a text editor to save: overwrite an existing
// file (growing/shrinking its cluster chain) or create a new one with an 8.3
// name. Long-name creation and subdirectory creation are not supported.

// Little-endian field writers (mirror rd16/rd32).
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

// Number of data clusters (valid clusters are 2 .. clusterCount()+1).
fn clusterCount() u32 {
    return (bi.total_sectors - bi.first_data_sector) / bi.sectors_per_cluster;
}

// Set the FAT entry for `cluster` to `value` in every FAT copy. Invalidates the
// read cache so subsequent reads see the change.
fn writeFatEntry(cluster: u32, value: u32) bool {
    const fat_offset = cluster * 4;
    const ent_off = fat_offset % @as(u32, bi.bytes_per_sector);
    const within = fat_offset / @as(u32, bi.bytes_per_sector);
    var sec: [SECTOR]u8 = undefined;
    var fi: u8 = 0;
    while (fi < bi.num_fats) : (fi += 1) {
        const fat_sector = bi.volume_start + bi.reserved_sectors + @as(u32, fi) * bi.fat_size + within;
        if (!ata.read(fat_sector, 1, &sec)) return false;
        const top = rd32(&sec, ent_off) & 0xF0000000; // keep the 4 reserved high bits
        wr32(&sec, ent_off, top | (value & 0x0FFFFFFF));
        if (!ata.write(fat_sector, 1, &sec)) return false;
    }
    fat_cache_sector = 0xFFFFFFFF; // the cached FAT sector may now be stale
    return true;
}

// Overwrite every data sector of a cluster with zeros.
fn zeroCluster(c: u32) bool {
    const zero = [_]u8{0} ** SECTOR;
    var s: u32 = 0;
    while (s < bi.sectors_per_cluster) : (s += 1) {
        if (!ata.write(clusterToSector(c) + s, 1, &zero)) return false;
    }
    return true;
}

// Find a free cluster, mark it end-of-chain, zero it, and return it.
fn allocCluster() ?u32 {
    const count = clusterCount();
    var c: u32 = 2;
    while (c < count + 2) : (c += 1) {
        if (nextCluster(c) == 0) { // a 0 FAT entry means free
            if (!writeFatEntry(c, EOC)) return null;
            if (!zeroCluster(c)) return null;
            return c;
        }
    }
    return null; // disk full
}

// Free an entire cluster chain (mark every entry free).
fn freeChain(start: u32) void {
    var c = start;
    while (isDataCluster(c)) {
        const nxt = nextCluster(c);
        _ = writeFatEntry(c, 0);
        c = nxt;
    }
}

// On-disk location of a directory entry, plus the file fields we may rewrite.
const DirLoc = struct { lba: u32, off: usize, first_cluster: u32 };

// Locate the 32-byte directory entry for `name` inside the directory at
// `parent_cluster`, returning where it lives on disk (so we can rewrite its size
// and first-cluster fields). Matches assembled long names and 8.3 names.
fn findDirLoc(parent_cluster: u32, name: []const u8) ?DirLoc {
    var sector: [SECTOR]u8 = undefined;
    var lfn: [256]u8 = undefined;
    var lfn_len: usize = 0;
    var cluster = parent_cluster;
    while (isDataCluster(cluster)) {
        var s: u32 = 0;
        while (s < bi.sectors_per_cluster) : (s += 1) {
            const lba = clusterToSector(cluster) + s;
            if (!ata.read(lba, 1, &sector)) return null;
            var e: usize = 0;
            while (e < SECTOR / 32) : (e += 1) {
                const ent = sector[e * 32 .. e * 32 + 32];
                if (ent[0] == 0x00) return null; // no more entries anywhere
                if (ent[0] == 0xE5) {
                    lfn_len = 0;
                    continue;
                }
                const attr = ent[0x0B];
                if (attr == ATTR_LFN) {
                    accumulateLfn(ent, &lfn, &lfn_len);
                    continue;
                }
                if (attr & ATTR_VOLUME_ID != 0) {
                    lfn_len = 0;
                    continue;
                }
                var shortbuf: [256]u8 = undefined;
                const ename = if (lfn_len > 0) lfn[0..lfn_len] else shortName(ent, &shortbuf);
                if (std.ascii.eqlIgnoreCase(ename, name)) {
                    const fc = (@as(u32, rd16(ent, 0x14)) << 16) | rd16(ent, 0x1A);
                    return .{ .lba = lba, .off = e * 32, .first_cluster = fc };
                }
                lfn_len = 0;
            }
        }
        cluster = nextCluster(cluster);
    }
    return null;
}

// Render `name` into an 11-byte 8.3 field (uppercased, space-padded). Returns
// false if it doesn't fit 8.3 (so we don't silently truncate a name).
fn to83(name: []const u8, out: *[11]u8) bool {
    @memset(out, ' ');
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const base = if (dot) |d| name[0..d] else name;
    const ext = if (dot) |d| name[d + 1 ..] else "";
    if (base.len == 0 or base.len > 8 or ext.len > 3) return false;
    for (base, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    for (ext, 0..) |c, i| out[8 + i] = std.ascii.toUpper(c);
    return true;
}

// 32-byte directory slots per sector (16) and per cluster.
fn slotsPerSector() usize {
    return SECTOR / 32;
}

// Write the 32-byte directory entry `ent` into the `slot_index`-th slot of the
// directory at `parent_cluster` (read-modify-write of its sector). The caller
// must have ensured the slot exists (see reserveDirSlots). False on a chain that
// ends before the slot or a disk error.
fn placeEntry(parent_cluster: u32, slot_index: usize, ent: *const [32]u8) bool {
    var sec_index = slot_index / slotsPerSector(); // which directory sector
    const off = (slot_index % slotsPerSector()) * 32; // byte offset within it
    var cluster = parent_cluster;
    while (sec_index >= bi.sectors_per_cluster) : (sec_index -= bi.sectors_per_cluster) {
        cluster = nextCluster(cluster); // step to the cluster holding this sector
        if (!isDataCluster(cluster)) return false;
    }
    const lba = clusterToSector(cluster) + @as(u32, @intCast(sec_index));
    var sector: [SECTOR]u8 = undefined;
    if (!ata.read(lba, 1, &sector)) return false;
    @memcpy(sector[off .. off + 32], ent);
    return ata.write(lba, 1, &sector);
}

// Ensure the directory at `parent_cluster` has a run of `need` consecutive free
// slots and return the index of the first. Reuses the free tail past the
// directory's end marker, growing the directory by whole clusters when that tail
// is too short. Returns null on disk-full or a read error.
fn reserveDirSlots(parent_cluster: u32, need: usize) ?usize {
    const per_cluster = @as(usize, bi.sectors_per_cluster) * slotsPerSector();
    var sector: [SECTOR]u8 = undefined;
    var idx: usize = 0; // running slot index
    var first_free: ?usize = null; // first end-marker (0x00) slot
    var cluster = parent_cluster;
    var last_cluster = parent_cluster; // tail of the chain, for growth
    while (isDataCluster(cluster)) {
        var s: u32 = 0;
        while (s < bi.sectors_per_cluster) : (s += 1) {
            if (!ata.read(clusterToSector(cluster) + s, 1, &sector)) return null;
            var e: usize = 0;
            while (e < slotsPerSector()) : (e += 1) {
                if (sector[e * 32] == 0x00 and first_free == null) first_free = idx;
                idx += 1;
            }
        }
        last_cluster = cluster;
        cluster = nextCluster(cluster);
    }
    const total = idx;
    const start = first_free orelse total; // a packed dir appends at its very end
    var free_tail = total - start; // free slots from `start` to the end
    while (free_tail < need) { // grow the directory a cluster at a time
        const nc = allocCluster() orelse return null; // new (zeroed) dir cluster
        if (!writeFatEntry(last_cluster, nc)) return null; // link it onto the chain
        last_cluster = nc;
        free_tail += per_cluster;
    }
    return start;
}

// Build a standard 8.3 short directory entry into `out`.
fn buildShortEntry(out: *[32]u8, sfn: *const [11]u8, attr: u8, first_cluster: u32, size: u32) void {
    @memset(out, 0);
    @memcpy(out[0..11], sfn);
    out[0x0B] = attr; // 0x20 archive (file) or 0x10 directory
    wr16(out, 0x14, @intCast(first_cluster >> 16));
    wr16(out, 0x1A, @intCast(first_cluster & 0xFFFF));
    wr32(out, 0x1C, size);
}

// Create an 8.3 directory entry for `name` (attr 0x20 file / 0x10 dir) in the
// directory at `parent_cluster`. Grows the directory if it's full. Fails only if
// the name isn't 8.3 or the disk is full.
fn createDirEntry(parent_cluster: u32, name: []const u8, attr: u8, first_cluster: u32, size: u32) bool {
    var sfn: [11]u8 = undefined;
    if (!to83(name, &sfn)) return false;
    const start = reserveDirSlots(parent_cluster, 1) orelse return false;
    var ent: [32]u8 = undefined;
    buildShortEntry(&ent, &sfn, attr, first_cluster, size);
    return placeEntry(parent_cluster, start, &ent);
}

// True if an 8.3 short-name field equal to `sfn` already exists in the directory
// (used to pick a non-colliding "~n" alias for a long name).
fn aliasExists(parent_cluster: u32, sfn: *const [11]u8) bool {
    var sector: [SECTOR]u8 = undefined;
    var cluster = parent_cluster;
    while (isDataCluster(cluster)) {
        var s: u32 = 0;
        while (s < bi.sectors_per_cluster) : (s += 1) {
            if (!ata.read(clusterToSector(cluster) + s, 1, &sector)) return false;
            var e: usize = 0;
            while (e < slotsPerSector()) : (e += 1) {
                const ent = sector[e * 32 .. e * 32 + 32];
                if (ent[0] == 0x00) return false; // end of directory
                if (ent[0] == 0xE5 or ent[0x0B] == ATTR_LFN) continue; // deleted / LFN part
                if (std.mem.eql(u8, ent[0..11], sfn)) return true;
            }
        }
        cluster = nextCluster(cluster);
    }
    return false;
}

// Create a directory entry for a long `name` (one that doesn't fit 8.3): a run of
// LFN entries holding the real name, followed by a short entry with a generated
// "BASE~n" alias. Grows the directory if needed. Fails on disk-full or if no free
// alias is available.
fn createLfnEntry(parent_cluster: u32, name: []const u8, attr: u8, first_cluster: u32, size: u32) bool {
    // Pick the first "~n" alias (n = 1..9) that doesn't collide.
    var sfn: [11]u8 = undefined;
    var n: u8 = 1;
    while (true) : (n += 1) {
        lfnenc.buildAlias(name, n, &sfn);
        if (!aliasExists(parent_cluster, &sfn)) break;
        if (n == 9) return false; // gave up finding a free alias
    }
    const cksum = lfnenc.checksum(&sfn);
    const count = lfnenc.entryCount(name.len); // number of LFN entries
    const start = reserveDirSlots(parent_cluster, count + 1) orelse return false;

    // LFN entries come first, written highest-sequence-first (the first one
    // carries the 0x40 end-of-name marker), then the short entry.
    var k: usize = 0;
    while (k < count) : (k += 1) {
        const seq: u8 = @intCast(count - k); // count, count-1, ..., 1
        var ent: [32]u8 = undefined;
        lfnenc.fillEntry(&ent, seq, seq == count, cksum, name);
        if (!placeEntry(parent_cluster, start + k, &ent)) return false;
    }
    var short: [32]u8 = undefined;
    buildShortEntry(&short, &sfn, attr, first_cluster, size);
    return placeEntry(parent_cluster, start + count, &short);
}

// Write the "." and ".." entries that every FAT32 subdirectory begins with into
// the freshly allocated cluster `dir_cluster`. "." points at the directory
// itself; ".." points at its parent (or 0 when the parent is the root, per the
// FAT convention). The cluster is already zeroed, so we only write its first
// sector; the remaining slots stay empty.
fn writeDotEntries(dir_cluster: u32, parent_cluster: u32) bool {
    var sector = [_]u8{0} ** SECTOR;
    const dot = sector[0..32]; // "."  entry -> this directory
    @memset(dot[0..11], ' ');
    dot[0] = '.';
    dot[0x0B] = ATTR_DIRECTORY;
    wr16(dot, 0x14, @intCast(dir_cluster >> 16));
    wr16(dot, 0x1A, @intCast(dir_cluster & 0xFFFF));
    const dd = sector[32..64]; // ".." entry -> the parent directory
    @memset(dd[0..11], ' ');
    dd[0] = '.';
    dd[1] = '.';
    dd[0x0B] = ATTR_DIRECTORY;
    // The root has no cluster number, so ".." in a top-level dir points at 0.
    const pc: u32 = if (parent_cluster == bi.root_cluster) 0 else parent_cluster;
    wr16(dd, 0x14, @intCast(pc >> 16));
    wr16(dd, 0x1A, @intCast(pc & 0xFFFF));
    return ata.write(clusterToSector(dir_cluster), 1, &sector);
}

// Create the directory `path` (e.g. "/EFI/BOOT"). The parent must already exist.
// Idempotent: succeeds if `path` already exists as a directory. Returns false on
// no FS, a missing/non-directory parent, an existing non-directory at `path`, a
// non-8.3 name, a full disk, or a full parent directory.
pub fn mkdir(path: []const u8) bool {
    if (!mounted) return false;
    if (resolve(path)) |node| return node.is_dir; // already there -> ok iff a dir
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return false;
    const parent_path = if (slash == 0) "/" else path[0..slash];
    const name = path[slash + 1 ..];
    if (name.len == 0) return false;
    const parent = resolve(parent_path) orelse return false;
    if (!parent.is_dir) return false;

    const dir_cluster = allocCluster() orelse return false; // the new dir's data
    if (!writeDotEntries(dir_cluster, parent.cluster)) return false; // "." and ".."
    // A directory's entry records cluster but size 0 (size is unused for dirs).
    return createDirEntry(parent.cluster, name, ATTR_DIRECTORY, dir_cluster, 0);
}

// Write `data` to `path`, creating or overwriting the file. Grows/shrinks the
// cluster chain to fit and updates the directory entry. Returns false on any
// error (no FS, bad path, disk full, non-8.3 new name, directory full).
pub fn writeFile(path: []const u8, data: []const u8) bool {
    if (!mounted) return false;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return false;
    const parent_path = if (slash == 0) "/" else path[0..slash];
    const name = path[slash + 1 ..];
    if (name.len == 0) return false;
    const parent = resolve(parent_path) orelse return false;
    if (!parent.is_dir) return false;

    const cluster_bytes = @as(usize, bi.sectors_per_cluster) * SECTOR;
    const needed = (data.len + cluster_bytes - 1) / cluster_bytes; // clusters to hold data

    const loc = findDirLoc(parent.cluster, name);
    const old_first: u32 = if (loc) |l| l.first_cluster else 0;

    // Build a chain of exactly `needed` clusters, reusing the file's existing one.
    var chain_first: u32 = old_first;
    if (needed == 0) {
        if (isDataCluster(old_first)) freeChain(old_first);
        chain_first = 0;
    } else {
        if (!isDataCluster(chain_first)) chain_first = allocCluster() orelse return false;
        var prev = chain_first;
        var have: usize = 1;
        while (have < needed) : (have += 1) {
            var nxt = nextCluster(prev);
            if (!isDataCluster(nxt)) {
                nxt = allocCluster() orelse return false;
                if (!writeFatEntry(prev, nxt)) return false;
            }
            prev = nxt;
        }
        const extra = nextCluster(prev); // clusters beyond what we need
        if (!writeFatEntry(prev, EOC)) return false;
        if (isDataCluster(extra)) freeChain(extra);
    }

    // Write the data into the chain, zero-padding the final sector.
    var cluster = chain_first;
    var written: usize = 0;
    while (written < data.len and isDataCluster(cluster)) {
        var s: u32 = 0;
        while (s < bi.sectors_per_cluster and written < data.len) : (s += 1) {
            var buf = [_]u8{0} ** SECTOR;
            const n = @min(data.len - written, @as(usize, SECTOR));
            @memcpy(buf[0..n], data[written .. written + n]);
            if (!ata.write(clusterToSector(cluster) + s, 1, &buf)) return false;
            written += n;
        }
        cluster = nextCluster(cluster);
    }

    // Update the existing directory entry, or create a new one.
    if (loc) |l| {
        var sec: [SECTOR]u8 = undefined;
        if (!ata.read(l.lba, 1, &sec)) return false;
        wr32(&sec, l.off + 0x1C, @intCast(data.len)); // file size
        wr16(&sec, l.off + 0x14, @intCast(chain_first >> 16)); // first cluster (high)
        wr16(&sec, l.off + 0x1A, @intCast(chain_first & 0xFFFF)); // first cluster (low)
        return ata.write(l.lba, 1, &sec);
    }
    // A new file: an 8.3 name gets a plain short entry; anything else (e.g.
    // "limine.conf", whose 4-char extension has no 8.3 form) gets an LFN run.
    var sfn: [11]u8 = undefined;
    if (to83(name, &sfn)) {
        return createDirEntry(parent.cluster, name, 0x20, chain_first, @intCast(data.len));
    }
    return createLfnEntry(parent.cluster, name, 0x20, chain_first, @intCast(data.len));
}

// --- Boot self-test ----------------------------------------------------------
// Mount the disk, list the root directory, and read a known file — proving the
// whole read path end to end. No-op (with a clear log line) if there's no disk
// or it isn't FAT32, so disk-less boots are unaffected.
pub fn selfTest() void {
    serial.print("[FAT32] Filesystem self-test...\n", .{});
    if (!mount()) {
        serial.print("[FAT32] self-test skipped (nothing to mount).\n", .{});
        return;
    }
    serial.print("[FAT32]   root directory:\n", .{});
    ls("/");
    serial.print("[FAT32]   contents of /HELLO.TXT:\n", .{});
    cat("/HELLO.TXT");
    serial.print("[FAT32] self-test complete.\n", .{});
}
