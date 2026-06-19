// Virtual File System (VFS) layer.
//
// A real operating system can have several filesystems live at once: a FAT32
// disk at "/", a RAM disk at "/tmp", a device tree at "/dev", and so on. Code
// that wants to open a file should NOT have to know which one a path lives on —
// it should just say `open("/dev/null")` and have the right driver handle it.
//
// This module is that indirection. It keeps a small table mapping a path PREFIX
// (e.g. "/") to a "backend": a bundle of function pointers (a vtable) that knows
// how to resolve, open, read, and stat files for one filesystem. When you call
// `vfs.open("/HELLO.TXT")`, the VFS finds the longest-matching mount, strips the
// prefix, and forwards the request to that backend's functions.
//
// Right now the only backend is FAT32 (see `fat32Backend` below), and it simply
// forwards to the existing `fat32` driver — so the VFS adds a layer of naming
// over hardware that already works. It is deliberately STANDALONE: nothing else
// in the kernel is rewired to go through it yet. A LATER change will point the
// file syscalls (and add a /dev and /tmp backend) at this layer; this is the
// foundation those build on.
//
// Design notes for a freestanding kernel: no heap is used. The mount table is a
// fixed-size static array, and a backend's per-filesystem state is passed around
// as an opaque `*anyopaque` context pointer (the idiomatic Zig vtable pattern),
// so adding a backend never needs an allocator.

const std = @import("std");
const serial = @import("../drivers/serial.zig"); // COM1 logging (log = debug-only)
const config = @import("config"); // build-time flags (debug_log)
const fat32 = @import("fat32.zig"); // the one filesystem backend we wrap today

// What kind of thing a path points at. The VFS only needs this coarse split;
// permissions, symlinks, etc. are out of scope for this foundation.
pub const Kind = enum {
    file,
    dir,
};

// A "vnode": the VFS's filesystem-independent handle to one file or directory.
// `size` is the byte length (0 for directories). `handle` is an OPAQUE number
// whose meaning is private to the backend that produced it — for FAT32 it is the
// starting cluster, but VFS callers must never interpret it; they just hand it
// back to the same backend's `open`/`read`.
pub const Vnode = struct {
    kind: Kind, // file or directory
    size: u64, // byte length (0 for a directory)
    handle: u64, // backend-private locator (e.g. FAT32 start cluster)
};

// The backend interface: a vtable of function pointers plus the opaque context
// each one receives. A filesystem implements these four operations; the VFS
// calls them with paths that have already had the mount prefix stripped (so the
// backend always sees a path relative to ITS own root, e.g. "/HELLO.TXT").
pub const Backend = struct {
    // Per-backend state, handed back to each call. For FAT32 there is no state
    // (the driver is a singleton), so this is unused but kept for generality.
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Look up a path and fill in a Vnode, or return null if it doesn't exist.
        resolve: *const fn (ctx: *anyopaque, path: []const u8) ?Vnode,
        // Open a file for streaming reads, returning a backend-owned reader stored
        // in `out` on success. Returns false if the path is missing or a directory.
        open: *const fn (ctx: *anyopaque, path: []const u8, out: *OpenFile) bool,
        // Copy up to dst.len bytes from an open file into dst; returns the count
        // read (0 = end of file or error). Advances the reader's cursor.
        read: *const fn (ctx: *anyopaque, file: *OpenFile, dst: []u8) usize,
        // Same as resolve, but named for callers that only want metadata.
        stat: *const fn (ctx: *anyopaque, path: []const u8) ?Vnode,
        // OPTIONAL: reposition an open file's cursor to absolute byte `abs_pos`
        // and return true. Backends that can't seek (character devices like
        // /dev/zero) leave this null — the VFS then reports the file as
        // unseekable (lseek -> ESPIPE), matching how POSIX treats a pipe/tty.
        // The default null means a backend opts in only if it implements it.
        seek: ?*const fn (ctx: *anyopaque, file: *OpenFile, abs_pos: u64) bool = null,
    };
};

// An open-file cursor as seen by VFS callers. The backend owns the bytes inside
// `inner` (a fixed-size scratch area); the VFS never looks in here. We use an
// inline byte buffer rather than a heap allocation so `open` needs no allocator
// and the caller can keep the OpenFile on its own stack. The buffer is sized to
// hold the largest backend reader (FAT32's `FileReader`); a comptime assert in
// the FAT32 backend guards against it ever growing past this.
pub const OpenFile = struct {
    backend: *const Backend, // which backend's `read` to call
    // The current absolute byte position, tracked HERE (not in the backend) so
    // that lseek's SEEK_CUR/SEEK_END work the same for every backend. `read`
    // advances it; `seek` sets it. `size` is the file's byte length, captured at
    // open time, so SEEK_END has a base without re-stat'ing.
    offset: u64 = 0,
    size: u64 = 0,
    inner: [INNER_SIZE]u8 align(INNER_ALIGN) = undefined, // backend-private reader bytes

    // Forward a read to the owning backend AND advance our absolute offset by the
    // number of bytes actually delivered, so `offset` always tracks the cursor.
    pub fn read(self: *OpenFile, dst: []u8) usize {
        const n = self.backend.vtable.read(self.backend.ctx, self, dst);
        self.offset += n;
        return n;
    }
};

// Capacity (bytes + alignment) of OpenFile.inner. Generous enough for FAT32's
// FileReader; the backend statically asserts its reader fits.
const INNER_SIZE = 1024;
const INNER_ALIGN = 16;

// --- Mount table -------------------------------------------------------------
// A path prefix bound to a backend. `prefix` is matched at the FRONT of a path;
// the longest matching prefix wins (so "/dev" can sit under a "/" mount later).
const Mount = struct {
    prefix: []const u8,
    backend: Backend,
};

const MAX_MOUNTS = 8; // plenty for /, /dev, /tmp, ... with room to spare
var mounts: [MAX_MOUNTS]Mount = undefined; // fixed-size: no heap needed
var mount_count: usize = 0; // how many slots in `mounts` are live

// Reset the mount table. Mainly here so the boot self-test starts from a clean
// slate even if it runs more than once; ordinary boot calls it via init().
pub fn init() void {
    mount_count = 0;
    serial.log("[VFS] virtual filesystem layer initialized.\n", .{});
}

// Bind `prefix` (e.g. "/") to `backend`. Returns false if the table is full.
// Later lookups for a path under this prefix are forwarded to the backend.
pub fn mount(prefix: []const u8, backend: Backend) bool {
    if (mount_count >= MAX_MOUNTS) return false; // table full
    mounts[mount_count] = .{ .prefix = prefix, .backend = backend };
    mount_count += 1;
    return true;
}

// Find the mount whose prefix is the LONGEST prefix of `path`, returning the
// mount plus the path with that prefix stripped (always starting with '/', so
// the backend sees a path relative to its own root). Null if nothing matches.
const Resolved = struct {
    mount: *const Mount,
    rel: []const u8, // path relative to the mount root, leading '/'
};
fn findMount(path: []const u8) ?Resolved {
    var best: ?*const Mount = null;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < mount_count) : (i += 1) {
        const p = mounts[i].prefix;
        // A prefix matches only at a path-SEGMENT boundary: `path` must start
        // with `p` AND the byte right after `p` must be a '/' or the end of the
        // string. Without that boundary check, prefix "/dev" would wrongly match
        // the sibling file "/development.txt" (which merely starts with "dev")
        // and strip it mid-segment to "elopment.txt". The root prefix "/" ends in
        // '/', so it still matches every absolute path (the intended fallback).
        if (!std.mem.startsWith(u8, path, p)) continue;
        const after = path[p.len..];
        const boundary = p.len == 0 or p[p.len - 1] == '/' or after.len == 0 or after[0] == '/';
        if (boundary and p.len >= best_len) {
            best = &mounts[i];
            best_len = p.len;
        }
    }
    const m = best orelse return null;
    // Strip the matched prefix. We want the remainder to start with '/', so the
    // backend always gets an absolute-looking path. For a "/" mount, `rel` is the
    // whole path. For a longer prefix like "/dev", strip it but keep the slash.
    var rel = path[m.prefix.len..];
    if (rel.len == 0 or rel[0] != '/') {
        if (m.prefix.len > 0 and m.prefix[m.prefix.len - 1] == '/') {
            // The prefix itself ended in '/', so the remainder lost its leading
            // slash. Back up one byte into the original path to restore it.
            rel = path[m.prefix.len - 1 ..];
        } else if (rel.len == 0) {
            rel = "/"; // path exactly equals the prefix -> the mount root
        }
    }
    return .{ .mount = m, .rel = rel };
}

// --- Public operations -------------------------------------------------------
// Each forwards to the backend owning `path`'s mount, after prefix-stripping.

// Resolve a path's metadata into a Vnode, or null if no mount owns it / it's
// missing. (stat() is an alias kept for callers that read like `stat`.)
pub fn stat(path: []const u8) ?Vnode {
    const r = findMount(path) orelse return null;
    const b = &r.mount.backend;
    return b.vtable.stat(b.ctx, r.rel);
}

// Open a file for streaming, writing the cursor into `out`. Returns false if no
// mount owns the path, or the backend's open failed (missing / a directory).
pub fn open(path: []const u8, out: *OpenFile) bool {
    const r = findMount(path) orelse return false;
    const b = &r.mount.backend;
    if (!b.vtable.open(b.ctx, r.rel, out)) return false;
    out.backend = b;
    out.offset = 0; // a fresh handle starts at the beginning of the file
    // Capture the size now (for SEEK_END). Devices report 0, which is fine — they
    // are unseekable anyway (no seek vtable slot), so the size is never used.
    out.size = if (b.vtable.stat(b.ctx, r.rel)) |v| v.size else 0;
    return true;
}

// Read from an already-opened file. Thin pass-through to OpenFile.read (which also
// advances `file.offset`) so callers can use either `vfs.read(&f, buf)` or `f.read(buf)`.
pub fn read(file: *OpenFile, dst: []u8) usize {
    return file.read(dst);
}

// How lseek interprets its offset argument: from the start, the current position,
// or the end of the file. Same numeric values as POSIX SEEK_SET/CUR/END.
pub const SEEK_SET: u64 = 0;
pub const SEEK_CUR: u64 = 1;
pub const SEEK_END: u64 = 2;

// Reposition an open file's cursor. `whence` picks the base (start / current /
// end) and `delta` is a signed byte offset from it. Returns the new absolute
// offset, or null if the file is unseekable (its backend has no seek slot — e.g.
// /dev/zero) or `whence` is invalid. The target is clamped to [0, size]; the math
// is done in i128 so a hostile `delta` (e.g. lseek(fd, INT64_MAX, SEEK_END)) can't
// overflow before clamping.
pub fn seek(file: *OpenFile, whence: u64, delta: i64) ?u64 {
    const seek_fn = file.backend.vtable.seek orelse return null; // unseekable backend
    const base: i128 = switch (whence) {
        SEEK_SET => 0,
        SEEK_CUR => @intCast(file.offset),
        SEEK_END => @intCast(file.size),
        else => return null, // unknown whence
    };
    var target: i128 = base + @as(i128, delta); // wide enough never to overflow
    if (target < 0) target = 0; // can't seek before the start
    if (target > @as(i128, @intCast(file.size))) target = @intCast(file.size); // clamp at EOF
    const abs: u64 = @intCast(target);
    if (!seek_fn(file.backend.ctx, file, abs)) return null; // backend rejected it
    file.offset = abs; // keep our absolute offset in lock-step with the backend
    return abs;
}

// === FAT32 backend ===========================================================
// Forwards the four operations to the existing FAT32 driver. It holds NO state
// of its own (the driver is a global singleton), so its context is a dummy.
// IMPORTANT: this does not modify fat32.zig — it only calls its public API.

var fat32_dummy_ctx: u8 = 0; // a real address to hand out as the opaque ctx

// Map a FAT32 Node to a VFS Vnode (cluster -> opaque handle).
fn fat32NodeToVnode(node: fat32.Node) Vnode {
    return .{
        .kind = if (node.is_dir) .dir else .file,
        .size = node.size,
        .handle = node.cluster, // opaque to VFS callers; FAT32-private meaning
    };
}

fn fat32Resolve(_: *anyopaque, path: []const u8) ?Vnode {
    const node = fat32.resolve(path) orelse return null;
    return fat32NodeToVnode(node);
}

fn fat32Open(_: *anyopaque, path: []const u8, out: *OpenFile) bool {
    // The FAT32 reader fits inside OpenFile.inner (asserted at comptime below).
    // Place it there and remember we did, so reads can find it.
    comptime std.debug.assert(@sizeOf(fat32.FileReader) <= INNER_SIZE);
    comptime std.debug.assert(@alignOf(fat32.FileReader) <= INNER_ALIGN);
    const reader = fat32.open(path) orelse return false; // missing / a directory
    const slot: *fat32.FileReader = @ptrCast(@alignCast(&out.inner));
    slot.* = reader; // copy the cursor into the caller-owned scratch area
    return true;
}

fn fat32Read(_: *anyopaque, file: *OpenFile, dst: []u8) usize {
    const slot: *fat32.FileReader = @ptrCast(@alignCast(&file.inner));
    return slot.read(dst);
}

fn fat32Seek(_: *anyopaque, file: *OpenFile, abs_pos: u64) bool {
    // FAT32's FileReader already knows how to jump to an absolute byte offset
    // (forward = skip; backward = rewind to the first cluster + skip). The VFS has
    // already clamped abs_pos into [0, size], so the @intCast is safe.
    const slot: *fat32.FileReader = @ptrCast(@alignCast(&file.inner));
    slot.seekTo(@intCast(abs_pos));
    return true;
}

const fat32_vtable = Backend.VTable{
    .resolve = fat32Resolve,
    .open = fat32Open,
    .read = fat32Read,
    .stat = fat32Resolve, // stat is identical to resolve here
    .seek = fat32Seek, // FAT32 files are seekable
};

// Build a Backend value bound to the FAT32 driver. Callers do
// `vfs.mount("/", vfs.fat32Backend())`.
pub fn fat32Backend() Backend {
    return .{ .ctx = &fat32_dummy_ctx, .vtable = &fat32_vtable };
}

// === Boot self-test ==========================================================
// Debug-log-gated proof that a file can be opened + read THROUGH the VFS (not by
// calling FAT32 directly). Mounts the FAT32 backend at "/", opens "/HELLO.TXT"
// (seeded on the test disk by tests/run.sh), reads its first bytes, and prints a
// marker the harness asserts. Quiet unless built with -Ddebug-log=true.
pub fn selfTest() void {
    if (!config.debug_log) return; // normal boot stays silent
    if (!fat32.isMounted()) {
        serial.log("[VFS] self-test skipped (no filesystem mounted).\n", .{});
        return;
    }
    // "/" is mounted to the FAT32 backend unconditionally at boot (see main.zig),
    // so "/HELLO.TXT" already routes here — the self-test just exercises it.
    // stat the file through the abstraction first (metadata path).
    const st = stat("/HELLO.TXT") orelse {
        serial.log("[VFS] self-test: stat /HELLO.TXT failed.\n", .{});
        return;
    };
    serial.log("[VFS] self-test: stat /HELLO.TXT -> {s}, {d} bytes.\n", .{ @tagName(st.kind), st.size });
    // Open + read the file through the abstraction (data path).
    var f: OpenFile = undefined;
    if (!open("/HELLO.TXT", &f)) {
        serial.log("[VFS] self-test: open /HELLO.TXT failed.\n", .{});
        return;
    }
    var buf: [64]u8 = undefined;
    const n = f.read(&buf);
    // The harness greps this marker AND the file's known contents to prove the
    // bytes actually flowed through the VFS read path.
    serial.log("[VFS] self-test: read {d} bytes via VFS: {s}", .{ n, buf[0..n] });
    serial.log("[VFS] self-test OK: opened + read /HELLO.TXT through the VFS.\n", .{});
}

// --- Inline unit tests (host, via src/tests.zig) -----------------------------
// These run on the host under `zig build test`. They exercise the pure routing
// logic (findMount / prefix stripping) with a fake backend — no FAT32, no disk —
// so they are freestanding-independent and fast.

const testing = std.testing;

// A fake backend that records the relative path it last saw, so a test can check
// the VFS stripped the mount prefix correctly before forwarding.
const FakeState = struct {
    last_rel: []const u8 = "",
    exists: bool = true, // whether resolve/open should "find" the file
};

fn fakeResolve(ctx: *anyopaque, path: []const u8) ?Vnode {
    const s: *FakeState = @ptrCast(@alignCast(ctx));
    s.last_rel = path; // remember what relative path the VFS handed us
    if (!s.exists) return null;
    return .{ .kind = .file, .size = 7, .handle = 42 };
}
fn fakeOpen(ctx: *anyopaque, path: []const u8, out: *OpenFile) bool {
    const s: *FakeState = @ptrCast(@alignCast(ctx));
    s.last_rel = path;
    _ = out;
    return s.exists;
}
fn fakeRead(_: *anyopaque, _: *OpenFile, _: []u8) usize {
    return 0;
}
const fake_vtable = Backend.VTable{
    .resolve = fakeResolve,
    .open = fakeOpen,
    .read = fakeRead,
    .stat = fakeResolve,
};

test "root mount forwards the whole path to the backend" {
    init(); // clean table
    var state = FakeState{};
    try testing.expect(mount("/", .{ .ctx = &state, .vtable = &fake_vtable }));
    const v = stat("/hello.txt");
    try testing.expect(v != null);
    try testing.expectEqual(@as(u64, 7), v.?.size);
    // A "/" mount passes the path through unchanged.
    try testing.expectEqualStrings("/hello.txt", state.last_rel);
}

test "longest-prefix wins and the prefix is stripped" {
    init();
    var root = FakeState{};
    var dev = FakeState{};
    try testing.expect(mount("/", .{ .ctx = &root, .vtable = &fake_vtable }));
    try testing.expect(mount("/dev", .{ .ctx = &dev, .vtable = &fake_vtable }));
    // "/dev/null" should route to the /dev mount, with prefix stripped to "/null".
    _ = stat("/dev/null");
    try testing.expectEqualStrings("/null", dev.last_rel);
    try testing.expectEqualStrings("", root.last_rel); // root never saw it
    // "/etc/x" has no /etc mount, so it falls back to "/" with the full path.
    _ = stat("/etc/x");
    try testing.expectEqualStrings("/etc/x", root.last_rel);
}

test "a non-root prefix only matches at a segment boundary (not a name prefix)" {
    init();
    var root = FakeState{};
    var dev = FakeState{};
    try testing.expect(mount("/", .{ .ctx = &root, .vtable = &fake_vtable }));
    try testing.expect(mount("/dev", .{ .ctx = &dev, .vtable = &fake_vtable }));
    // "/development.txt" merely starts with "/dev" but is NOT inside it: it must
    // fall back to the "/" mount with its full path, NOT route to /dev.
    _ = stat("/development.txt");
    try testing.expectEqualStrings("/development.txt", root.last_rel);
    try testing.expectEqualStrings("", dev.last_rel); // /dev never saw it
}

test "a path equal to a non-root prefix resolves the mount root" {
    init();
    var dev = FakeState{};
    try testing.expect(mount("/dev", .{ .ctx = &dev, .vtable = &fake_vtable }));
    _ = stat("/dev");
    // Exactly the prefix -> the backend sees its own root "/".
    try testing.expectEqualStrings("/", dev.last_rel);
}

test "no mount owns the path -> null / false" {
    init(); // empty table
    var f: OpenFile = undefined;
    try testing.expect(stat("/anything") == null);
    try testing.expect(!open("/anything", &f));
}

test "missing file reports null even when a mount owns the path" {
    init();
    var state = FakeState{ .exists = false };
    try testing.expect(mount("/", .{ .ctx = &state, .vtable = &fake_vtable }));
    try testing.expect(stat("/ghost") == null);
}

// A seekable fake backend: its reader hands out N bytes total, and `seek` records
// the absolute position. Used to test the VFS's offset tracking + seek math
// independent of any real filesystem.
const SEEK_FAKE_SIZE: u64 = 100;
const SeekFakeReader = struct { pos: u64 };
fn seekFakeResolve(_: *anyopaque, _: []const u8) ?Vnode {
    return .{ .kind = .file, .size = SEEK_FAKE_SIZE, .handle = 0 };
}
fn seekFakeOpen(_: *anyopaque, _: []const u8, out: *OpenFile) bool {
    const slot: *SeekFakeReader = @ptrCast(@alignCast(&out.inner));
    slot.* = .{ .pos = 0 };
    return true;
}
fn seekFakeRead(_: *anyopaque, file: *OpenFile, dst: []u8) usize {
    const slot: *SeekFakeReader = @ptrCast(@alignCast(&file.inner));
    const left = SEEK_FAKE_SIZE - slot.pos;
    const n = @min(@as(u64, dst.len), left);
    slot.pos += n;
    return @intCast(n);
}
fn seekFakeSeek(_: *anyopaque, file: *OpenFile, abs_pos: u64) bool {
    const slot: *SeekFakeReader = @ptrCast(@alignCast(&file.inner));
    slot.pos = abs_pos;
    return true;
}
const seek_fake_vtable = Backend.VTable{
    .resolve = seekFakeResolve,
    .open = seekFakeOpen,
    .read = seekFakeRead,
    .stat = seekFakeResolve,
    .seek = seekFakeSeek,
};

test "open captures size and read advances the absolute offset" {
    init();
    var st: u8 = 0;
    try testing.expect(mount("/", .{ .ctx = &st, .vtable = &seek_fake_vtable }));
    var f: OpenFile = undefined;
    try testing.expect(open("/file", &f));
    try testing.expectEqual(@as(u64, SEEK_FAKE_SIZE), f.size); // captured at open
    try testing.expectEqual(@as(u64, 0), f.offset);
    var buf: [10]u8 = undefined;
    _ = f.read(&buf);
    try testing.expectEqual(@as(u64, 10), f.offset); // read moved the cursor
}

test "seek SET/CUR/END land at the right absolute offset" {
    init();
    var st: u8 = 0;
    try testing.expect(mount("/", .{ .ctx = &st, .vtable = &seek_fake_vtable }));
    var f: OpenFile = undefined;
    try testing.expect(open("/file", &f));
    try testing.expectEqual(@as(?u64, 30), seek(&f, SEEK_SET, 30)); // absolute 30
    try testing.expectEqual(@as(u64, 30), f.offset);
    try testing.expectEqual(@as(?u64, 35), seek(&f, SEEK_CUR, 5)); // 30 + 5
    try testing.expectEqual(@as(?u64, 90), seek(&f, SEEK_END, -10)); // size 100 - 10
}

test "seek clamps to [0, size] and rejects a bad whence" {
    init();
    var st: u8 = 0;
    try testing.expect(mount("/", .{ .ctx = &st, .vtable = &seek_fake_vtable }));
    var f: OpenFile = undefined;
    try testing.expect(open("/file", &f));
    try testing.expectEqual(@as(?u64, 0), seek(&f, SEEK_SET, -50)); // clamps below 0
    try testing.expectEqual(@as(?u64, SEEK_FAKE_SIZE), seek(&f, SEEK_SET, 9999)); // clamps at EOF
    // A wildly negative delta from END must not overflow before clamping.
    try testing.expectEqual(@as(?u64, 0), seek(&f, SEEK_END, std.math.minInt(i64)));
    try testing.expect(seek(&f, 99, 0) == null); // unknown whence -> null
}

test "an unseekable backend (no seek slot) reports null from seek" {
    init();
    var state = FakeState{}; // fake_vtable has no .seek -> defaults to null
    try testing.expect(mount("/", .{ .ctx = &state, .vtable = &fake_vtable }));
    var f: OpenFile = undefined;
    try testing.expect(open("/x", &f));
    try testing.expect(seek(&f, SEEK_SET, 0) == null); // unseekable -> null (ESPIPE)
}
