// Authentication: real password hashing with scrypt, a memory-hard KDF.
//
// The installer and the kernel use the SAME algorithm and the SAME PHC string
// format ("$scrypt$ln=...,r=...,p=...$salt$hash"), so a credential created at
// install time verifies at login. scrypt is integer-only (no FPU) and, unlike
// Argon2's std implementation, is single-threaded — so it compiles for the
// freestanding kernel (Argon2's parallel lanes pull in std.Thread, which has no
// freestanding backend). std reads the cost parameters out of the stored PHC
// string on verify, so the kernel hard-codes no cost values to check a password.
//
// This module takes a std.mem.Allocator rather than importing the kernel heap,
// which keeps it free of the Limine build-module — so the same code is exercised
// by a host unit test (`zig build test`) as runs in the kernel.

const std = @import("std");
const scrypt = std.crypto.pwhash.scrypt;

// Cost parameters for hashes WE create. ln=14 -> N=2^14, with r=8,p=1 that's the
// classic "interactive" scrypt cost (~16 MiB working set) — a real memory-hard
// barrier that stays responsive on a hobby kernel. Verification honors whatever
// the stored hash embeds, so raising this later won't break existing credentials.
pub const PARAMS = scrypt.Params{ .ln = 14, .r = 8, .p = 1 };

// Largest PHC string we read/write (scrypt PHC is ~100 bytes; 256 is headroom).
pub const MAX_HASH = 256;

// Check `password` against a stored PHC-format scrypt hash. True on match.
pub fn verify(allocator: std.mem.Allocator, phc: []const u8, password: []const u8) bool {
    scrypt.strVerify(phc, password, .{ .allocator = allocator }) catch return false;
    return true;
}

// Produce a PHC-format scrypt hash of `password` into `out`; null on error.
pub fn hash(allocator: std.mem.Allocator, password: []const u8, out: []u8) ?[]const u8 {
    return scrypt.strHash(
        password,
        .{ .allocator = allocator, .params = PARAMS, .encoding = .phc },
        out,
    ) catch null;
}

// --- Host unit test (zig build test) -----------------------------------------
test "scrypt hash verifies the right password and rejects the wrong one" {
    const a = std.testing.allocator;
    var buf: [MAX_HASH]u8 = undefined;
    const phc = hash(a, "correct horse battery staple", &buf) orelse return error.HashFailed;
    try std.testing.expect(std.mem.startsWith(u8, phc, "$scrypt$"));
    try std.testing.expect(verify(a, phc, "correct horse battery staple"));
    try std.testing.expect(!verify(a, phc, "Tr0ub4dor&3"));
}
