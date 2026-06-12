// Host tool: print a credential line "username:phc" for /OBSIDIA/AUTH, where phc
// is a scrypt PHC hash of the password. Run with the same Zig std the kernel is
// built with, so the kernel's scrypt verify accepts the output.
//
//   zig run tools/mkpasswd.zig -- <username> <password>
//
// The cost parameters here mirror src/auth.zig's PARAMS; verification reads the
// parameters back out of the PHC string, so they need not be hard-coded there.

const std = @import("std");
const scrypt = std.crypto.pwhash.scrypt;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const args = try std.process.argsAlloc(a);
    if (args.len != 3) {
        std.debug.print("usage: mkpasswd <username> <password>\n", .{});
        std.process.exit(2);
    }

    var buf: [256]u8 = undefined;
    const phc = try scrypt.strHash(
        args[2],
        .{ .allocator = a, .params = .{ .ln = 12, .r = 8, .p = 1 }, .encoding = .phc },
        &buf,
    );

    var stdout = std.io.getStdOut().writer();
    try stdout.print("{s}:{s}\n", .{ args[1], phc });
}
