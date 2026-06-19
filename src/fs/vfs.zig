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
    inner: [INNER_SIZE]u8 align(INNER_ALIGN) = undefined, // backend-private reader bytes

    // Forward a read to the owning backend.
    pub fn read(self: *OpenFile, dst: []u8) usize {
        return self.backend.vtable.read(self.backend.ctx, self, dst);
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
    out.backend = &r.mount.backend;
    return r.mount.backend.vtable.open(r.mount.backend.ctx, r.rel, out);
}

// Read from an already-opened file. Thin pass-through to OpenFile.read so callers
// can use either `vfs.read(&f, buf)` or `f.read(buf)`.
pub fn read(file: *OpenFile, dst: []u8) usize {
    return file.read(dst);
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

const fat32_vtable = Backend.VTable{
    .resolve = fat32Resolve,
    .open = fat32Open,
    .read = fat32Read,
    .stat = fat32Resolve, // stat is identical to resolve here
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
    // Mount the FAT32 backend at the root so "/HELLO.TXT" routes to it.
    if (!mount("/", fat32Backend())) {
        serial.log("[VFS] self-test: mount table full.\n", .{});
        return;
    }
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
