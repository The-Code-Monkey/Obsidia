// FAT32 long-file-name (LFN) encoding — the pure, hardware-free half of writing
// a file whose name doesn't fit the old 8.3 short form (e.g. "limine.conf", whose
// 4-char extension has no 8.3 representation).
//
// On disk a long name is stored as a run of 32-byte "LFN" entries (attribute
// 0x0F) placed *immediately before* the real 8.3 entry, each holding 13 UTF-16
// characters at scattered offsets. They are written highest-sequence-first; the
// first one has bit 0x40 set to mark the end of the name. A one-byte checksum of
// the 8.3 short name links the LFN entries to their short entry, so a short-name-
// only reader still sees a valid (alias) file and an LFN-aware reader recovers the
// full name.
//
// This module is the encoding logic only — building the short alias, the
// checksum, and one LFN entry's bytes — so it has no disk dependency and is
// exercised on the host by `zig build test`. fat32.zig handles placing the
// entries into a directory's free slots.

const std = @import("std");

pub const ATTR_LFN = 0x0F; // attribute byte marking an entry as an LFN component
pub const CHARS_PER_ENTRY = 13; // UTF-16 chars one LFN entry carries

// The (scattered) byte offsets within a 32-byte LFN entry where its 13 UTF-16
// characters live — the same layout the read path (fat32.accumulateLfn) decodes.
pub const OFFSETS = [CHARS_PER_ENTRY]u8{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };

// Number of LFN entries needed to hold a name of `len` characters (at least 1).
pub fn entryCount(len: usize) usize {
    return (len + CHARS_PER_ENTRY - 1) / CHARS_PER_ENTRY;
}

// The LFN checksum of an 11-byte 8.3 short name: a rotate-right-then-add over the
// raw name field. Every LFN entry stores this so it can be tied to its short
// entry (a mismatch makes a reader discard the long name).
pub fn checksum(sfn: *const [11]u8) u8 {
    var sum: u8 = 0;
    for (sfn) |c| {
        sum = (sum >> 1) | (sum << 7); // rotate right by 1
        sum +%= c; // wrapping add
    }
    return sum;
}

// True for characters we keep when deriving a short alias (a conservative subset
// of the legal 8.3 set — uppercase letters and digits cover our installer names).
fn validShortChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

// Build an 8.3 short-name *alias* for a long name into `out` (11 bytes, space-
// padded), of the form "BASE~n" + extension, e.g. "limine.conf" with n=1 ->
// "LIMINE~1CON". `n` is the disambiguation digit (1..9). Uppercases and drops
// characters that aren't legal in a short name.
pub fn buildAlias(longname: []const u8, n: u8, out: *[11]u8) void {
    @memset(out, ' ');
    const dot = std.mem.lastIndexOfScalar(u8, longname, '.');
    const base = longname[0..(dot orelse longname.len)];
    const ext = if (dot) |d| longname[d + 1 ..] else "";
    var bi: usize = 0; // up to 6 base chars, leaving room for "~n"
    for (base) |c| {
        if (bi >= 6) break;
        const u = std.ascii.toUpper(c);
        if (validShortChar(u)) {
            out[bi] = u;
            bi += 1;
        }
    }
    out[6] = '~';
    out[7] = '0' + n; // n is 1..9
    var ei: usize = 0; // up to 3 extension chars
    for (ext) |c| {
        if (ei >= 3) break;
        const u = std.ascii.toUpper(c);
        if (validShortChar(u)) {
            out[8 + ei] = u;
            ei += 1;
        }
    }
}

// Fill one 32-byte LFN entry `out` for sequence number `seq` (1-based) of
// `longname`: its 13-char slice, the attribute/checksum bookkeeping, and (when
// `is_last`) the 0x40 end-of-name marker. Characters past the name end are a
// single 0x0000 terminator followed by 0xFFFF padding, per the spec.
pub fn fillEntry(out: *[32]u8, seq: u8, is_last: bool, cksum: u8, longname: []const u8) void {
    @memset(out, 0);
    out[0] = seq | (if (is_last) @as(u8, 0x40) else 0); // sequence (+ end marker)
    out[11] = ATTR_LFN; // attribute: this is an LFN component
    out[12] = 0; // type (reserved, always 0)
    out[13] = cksum; // checksum tying us to the short entry
    // bytes 26..28 (the legacy first-cluster field) stay 0
    const start = (@as(usize, seq) - 1) * CHARS_PER_ENTRY; // this chunk's first char
    var i: usize = 0;
    while (i < CHARS_PER_ENTRY) : (i += 1) {
        const o = OFFSETS[i];
        const idx = start + i;
        var ch: u16 = 0xFFFF; // padding beyond the terminator
        if (idx < longname.len) {
            ch = longname[idx]; // ASCII -> UTF-16 (high byte 0)
        } else if (idx == longname.len) {
            ch = 0x0000; // the name terminator
        }
        out[o] = @truncate(ch);
        out[o + 1] = @truncate(ch >> 8);
    }
}

// --- Host unit tests (zig build test) ----------------------------------------
test "entryCount rounds up to whole 13-char entries" {
    try std.testing.expectEqual(@as(usize, 1), entryCount(1));
    try std.testing.expectEqual(@as(usize, 1), entryCount(13));
    try std.testing.expectEqual(@as(usize, 2), entryCount(14));
    try std.testing.expectEqual(@as(usize, 2), entryCount(26));
    try std.testing.expectEqual(@as(usize, 3), entryCount(27));
}

test "buildAlias derives an 8.3 alias from a long name" {
    var out: [11]u8 = undefined;
    buildAlias("limine.conf", 1, &out);
    try std.testing.expectEqualSlices(u8, "LIMINE~1CON", &out);
}

test "checksum matches a hand-computed value" {
    var sfn: [11]u8 = undefined;
    buildAlias("limine.conf", 1, &sfn); // "LIMINE~1CON"
    try std.testing.expectEqual(@as(u8, 0x86), checksum(&sfn));
}

test "fillEntry round-trips through the read-path decode" {
    const name = "limine.conf"; // 11 chars -> a single LFN entry
    var sfn: [11]u8 = undefined;
    buildAlias(name, 1, &sfn);
    var ent: [32]u8 = undefined;
    fillEntry(&ent, 1, true, checksum(&sfn), name);

    // The entry must be flagged as the last (0x40) sequence 1, an LFN, with our
    // checksum and a zero cluster field.
    try std.testing.expectEqual(@as(u8, 0x41), ent[0]); // seq 1 | 0x40
    try std.testing.expectEqual(@as(u8, ATTR_LFN), ent[11]);
    try std.testing.expectEqual(checksum(&sfn), ent[13]);
    try std.testing.expectEqual(@as(u8, 0), ent[26]);
    try std.testing.expectEqual(@as(u8, 0), ent[27]);

    // Decode the 13 char slots back the way fat32's reader does and confirm the
    // name, its 0x0000 terminator, and 0xFFFF padding.
    var decoded: [13]u16 = undefined;
    for (OFFSETS, 0..) |o, i| decoded[i] = @as(u16, ent[o]) | (@as(u16, ent[o + 1]) << 8);
    for (name, 0..) |c, i| try std.testing.expectEqual(@as(u16, c), decoded[i]);
    try std.testing.expectEqual(@as(u16, 0x0000), decoded[name.len]); // terminator
    try std.testing.expectEqual(@as(u16, 0xFFFF), decoded[name.len + 1]); // padding
}
