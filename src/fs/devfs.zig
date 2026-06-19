// Device filesystem (devfs): an in-memory tree of "device nodes".
//
// On Unix, special files like /dev/null and /dev/zero are not real files on a
// disk — they are kernel-provided endpoints that behave like files but route to
// driver code. /dev/null swallows whatever you write and reads as instantly
// empty; /dev/zero hands back an endless stream of zero bytes; /dev/console
// forwards writes to the terminal. devfs is the tiny filesystem that exposes
// these as openable paths.
//
// Why this module exists: the VFS layer (see ../fs/vfs.zig) was built to support
// MORE than one kind of filesystem behind one naming scheme. FAT32 was the first
// backend; devfs is the SECOND, and it deliberately looks nothing like a disk —
// no clusters, no sectors, just a fixed table of named behaviours. Getting devfs
// to plug into the exact same backend vtable proves the VFS abstraction is real
// and not accidentally FAT32-shaped.
//
// Design for a freestanding kernel: NO heap. The set of device nodes is a small
// fixed array known at compile time, and an "open file" carries only a tag saying
// which device it is — no per-open allocation. Mount it with
//   vfs.mount("/dev", devfs.backend());
// after which vfs.open("/dev/zero") routes here (the VFS strips the "/dev"
// prefix, so this code always sees paths relative to its own root, e.g. "/zero").

const std = @import("std");
const serial = @import("../drivers/serial.zig"); // /dev/console writes go to serial.print
const vfs = @import("vfs.zig"); // the Backend/Vnode/OpenFile types we conform to

// Which device a node is. The behaviour of read/write is chosen by this tag, so
// we never need per-node function pointers — a small switch does the routing.
const DeviceKind = enum {
    null_dev, // discards writes; reads return 0 bytes (EOF)
    zero_dev, // writes discarded; reads fill the buffer with zero bytes forever
    console_dev, // writes go to the serial console; reads return EOF (no input yet)
};

// One entry in the device table: the name as it appears under /dev (relative to
// the devfs root, so "/null") and which behaviour it has.
const Device = struct {
    name: []const u8, // path relative to the mount root, e.g. "/null"
    kind: DeviceKind, // what read/write should do
};

// The complete, fixed set of device nodes devfs serves. Adding a device is just
// another row here — no allocation, no registration dance.
const devices = [_]Device{
    .{ .name = "/null", .kind = .null_dev },
    .{ .name = "/zero", .kind = .zero_dev },
    .{ .name = "/console", .kind = .console_dev },
};

// devfs holds no per-filesystem state (the device table is comptime-constant), so
// like the FAT32 backend its opaque context is just a dummy address to hand out.
var dummy_ctx: u8 = 0;

// The per-open cursor devfs stores inside vfs.OpenFile.inner. All a devfs open
// needs to remember is WHICH device it is — there is no file position to track
// (null/console are always EOF; zero is endless), so this is a single tag. A
// comptime assert in `open` guarantees it fits inside OpenFile's scratch area.
const DevReader = struct {
    kind: DeviceKind,
};

// Find a device by its devfs-relative path, or null if no such node exists.
fn find(path: []const u8) ?Device {
    for (devices) |d| {
        if (std.mem.eql(u8, d.name, path)) return d; // exact name match
    }
    return null; // not a known device node
}

// --- VFS backend vtable -------------------------------------------------------
// These four functions match vfs.Backend.VTable EXACTLY. The VFS calls them with
// the "/dev" prefix already stripped, so `path` is relative to the devfs root.

// Look up a device node and describe it as a Vnode. Every device is a zero-byte
// "file" (it has no fixed length — null/console are empty, zero is infinite, so
// reporting 0 is the honest, conventional answer). `handle` is unused here.
fn resolve(_: *anyopaque, path: []const u8) ?vfs.Vnode {
    _ = find(path) orelse return null; // unknown name -> doesn't exist
    return .{ .kind = .file, .size = 0, .handle = 0 };
}

// Open a device node for reading. Stashes the device's kind into the caller-owned
// OpenFile scratch area so `read` knows which behaviour to run. Returns false for
// an unknown name (there are no directories in devfs to reject).
fn open(_: *anyopaque, path: []const u8, out: *vfs.OpenFile) bool {
    // Our reader is tiny, but assert it fits OpenFile.inner anyway so a future
    // change that grows DevReader fails loudly at compile time, not at runtime.
    comptime std.debug.assert(@sizeOf(DevReader) <= @sizeOf(@FieldType(vfs.OpenFile, "inner")));
    comptime std.debug.assert(@alignOf(DevReader) <= @alignOf(@FieldType(vfs.OpenFile, "inner")));
    const d = find(path) orelse return false; // unknown device -> open fails
    const slot: *DevReader = @ptrCast(@alignCast(&out.inner));
    slot.* = .{ .kind = d.kind }; // remember which device for later reads
    return true;
}

// Read from an open device node into `dst`, returning how many bytes were produced.
//   null/console -> 0 (end of file): nothing to read.
//   zero         -> dst.len: the whole buffer is filled with zero bytes.
fn read(_: *anyopaque, file: *vfs.OpenFile, dst: []u8) usize {
    const slot: *DevReader = @ptrCast(@alignCast(&file.inner));
    return switch (slot.kind) {
        .null_dev, .console_dev => 0, // EOF: no readable data
        .zero_dev => blk: {
            @memset(dst, 0); // fill the caller's buffer with zero bytes
            break :blk dst.len; // ...and report we produced that many
        },
    };
}

// The vtable bound to devfs's four operations. stat == resolve (both just look up
// metadata), mirroring how the FAT32 backend wires them.
const vtable = vfs.Backend.VTable{
    .resolve = resolve,
    .open = open,
    .read = read,
    .stat = resolve,
};

// Build a Backend value for devfs. Callers do `vfs.mount("/dev", devfs.backend())`.
pub fn backend() vfs.Backend {
    return .{ .ctx = &dummy_ctx, .vtable = &vtable };
}

// --- Write path ---------------------------------------------------------------
// The VFS backend vtable has NO write slot today (it is a read-only abstraction),
// and the task says not to widen VFS just for devfs. So device WRITES go through
// this small helper instead, addressed by FULL VFS path (e.g. "/dev/console").
// It is the natural place writes will live once the VFS grows a write op; for now
// only the boot self-test uses it, to demonstrate the console-write behaviour.
//
//   /dev/null    -> discard the bytes, report them all "written".
//   /dev/zero    -> same (writing to zero is a no-op sink, like null).
//   /dev/console -> forward the bytes to the serial console (serial.print), so
//                   they appear on the user's terminal.
// Returns the number of bytes accepted, or null if the path is not a device node.
pub fn write(path: []const u8, bytes: []const u8) ?usize {
    // Accept the full "/dev/..." path; strip the mount prefix to get the node name.
    const prefix = "/dev";
    if (!std.mem.startsWith(u8, path, prefix)) return null; // not under /dev
    const rel = path[prefix.len..]; // remainder after "/dev", e.g. "/console"
    const d = find(rel) orelse return null; // unknown device node
    switch (d.kind) {
        .null_dev, .zero_dev => {}, // sink: silently discard, but count as written
        .console_dev => serial.print("{s}", .{bytes}), // route to the terminal
    }
    return bytes.len; // every device here accepts the whole buffer
}

// --- Boot self-test -----------------------------------------------------------
// Debug-log-gated proof that devfs is a working SECOND VFS backend: mount it at
// "/dev", then exercise each node THROUGH the VFS (not by calling devfs directly).
//   1. open /dev/zero and confirm a read fills the buffer with zero bytes.
//   2. open /dev/null and confirm a read returns 0 (EOF).
//   3. write a string to /dev/console and confirm it is accepted.
// Prints a marker the test harness asserts. Quiet unless built -Ddebug-log=true.
pub fn selfTest() void {
    if (!@import("config").debug_log) return; // normal boot stays silent

    // devfs is mounted at "/dev" unconditionally at boot (see main.zig), so
    // "/dev/zero" etc. already route here — the self-test just exercises them.

    // (1) /dev/zero: a read must fill the WHOLE buffer with zero bytes. Pre-poison
    // the buffer with 0xAA so we can tell zeroing actually happened (rather than
    // the buffer merely having been zero already).
    var f: vfs.OpenFile = undefined;
    if (!vfs.open("/dev/zero", &f)) {
        serial.log("[DEVFS] self-test: open /dev/zero failed.\n", .{});
        return;
    }
    var buf: [16]u8 = [_]u8{0xAA} ** 16; // non-zero sentinel
    const nz = f.read(&buf);
    var all_zero = nz == buf.len; // expect a full-buffer read
    for (buf[0..nz]) |b| {
        if (b != 0) all_zero = false; // any non-zero byte => zeroing failed
    }
    serial.log("[DEVFS] self-test: /dev/zero read {d} bytes, all-zero={}.\n", .{ nz, all_zero });

    // (2) /dev/null: a read must return 0 (immediate EOF).
    if (!vfs.open("/dev/null", &f)) {
        serial.log("[DEVFS] self-test: open /dev/null failed.\n", .{});
        return;
    }
    const nn = f.read(&buf);
    serial.log("[DEVFS] self-test: /dev/null read {d} bytes (EOF expected).\n", .{nn});

    // (3) /dev/console: a write must be accepted and forwarded to the terminal.
    // (Uses the devfs.write helper since the VFS has no write op yet.)
    const wrote = write("/dev/console", "[DEVFS] hello from /dev/console\n") orelse 0;
    serial.log("[DEVFS] self-test: /dev/console accepted {d} bytes.\n", .{wrote});

    // Overall verdict the harness greps: all three behaviours held.
    if (all_zero and nz == buf.len and nn == 0 and wrote > 0) {
        serial.log("[DEVFS] self-test OK: zero/null/console served through the VFS.\n", .{});
    } else {
        serial.log("[DEVFS] self-test FAILED.\n", .{});
    }
}

// --- Inline unit tests (host, via src/tests.zig) -----------------------------
// These run on the host under `zig build test`. They drive the backend vtable
// directly (no VFS mount table, no hardware) to check each device's behaviour.

const testing = std.testing;

test "resolve recognizes the device nodes and rejects unknown names" {
    const b = backend();
    try testing.expect(b.vtable.resolve(b.ctx, "/null") != null);
    try testing.expect(b.vtable.resolve(b.ctx, "/zero") != null);
    try testing.expect(b.vtable.resolve(b.ctx, "/console") != null);
    try testing.expect(b.vtable.resolve(b.ctx, "/nope") == null);
    // Devices report as zero-byte files.
    const v = b.vtable.resolve(b.ctx, "/zero").?;
    try testing.expectEqual(vfs.Kind.file, v.kind);
    try testing.expectEqual(@as(u64, 0), v.size);
}

test "/dev/zero fills the destination with zero bytes" {
    const b = backend();
    var f: vfs.OpenFile = undefined;
    f.backend = &b;
    try testing.expect(b.vtable.open(b.ctx, "/zero", &f));
    var buf: [8]u8 = [_]u8{0xFF} ** 8; // poison with non-zero
    const n = b.vtable.read(b.ctx, &f, &buf);
    try testing.expectEqual(@as(usize, 8), n); // filled the whole buffer
    for (buf) |byte| try testing.expectEqual(@as(u8, 0), byte);
}

test "/dev/null reads as EOF (zero bytes)" {
    const b = backend();
    var f: vfs.OpenFile = undefined;
    f.backend = &b;
    try testing.expect(b.vtable.open(b.ctx, "/null", &f));
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), b.vtable.read(b.ctx, &f, &buf));
}

test "/dev/console reads as EOF" {
    const b = backend();
    var f: vfs.OpenFile = undefined;
    f.backend = &b;
    try testing.expect(b.vtable.open(b.ctx, "/console", &f));
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), b.vtable.read(b.ctx, &f, &buf)); // no input
    // NB: the console WRITE path is not exercised on the host because it calls
    // serial.print, which does real x86 port I/O (outb) and would fault off-target.
    // It is proven instead by the debug-gated boot self-test under QEMU.
}

test "open and write reject unknown device names" {
    const b = backend();
    var f: vfs.OpenFile = undefined;
    f.backend = &b;
    try testing.expect(!b.vtable.open(b.ctx, "/ghost", &f));
    try testing.expect(write("/dev/ghost", "x") == null); // unknown node
    try testing.expect(write("/etc/passwd", "x") == null); // not under /dev at all
}

test "writes to null and zero are silently discarded but counted" {
    try testing.expectEqual(@as(?usize, 3), write("/dev/null", "abc"));
    try testing.expectEqual(@as(?usize, 4), write("/dev/zero", "abcd"));
}
