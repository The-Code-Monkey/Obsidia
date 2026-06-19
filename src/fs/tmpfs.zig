// tmpfs / ramfs — a tiny WRITABLE filesystem that lives entirely in RAM.
//
// Every filesystem we've had so far (FAT32) is READ-ONLY: it reflects bytes that
// already exist on a disk. A real system also needs a place it can CREATE and
// WRITE files at runtime — think "/tmp" for scratch files, or the writable early
// root an initramfs provides before any disk is mounted. That's what this module
// is: an in-memory filesystem. There is no disk behind it; the file contents are
// just bytes sitting in a fixed static array. When the machine powers off, they
// vanish — exactly the semantics you want for "/tmp".
//
// It plugs into the EXISTING VFS layer (src/fs/vfs.zig) as a "backend": a bundle
// of function pointers (a vtable) the VFS calls after it has stripped the mount
// prefix from a path. So once we `vfs.mount("/tmp", tmpfs.backend())`, a caller
// that does `vfs.open("/tmp/scratch")` is routed here automatically — the caller
// never has to know the file lives in RAM rather than on a disk.
//
// IMPORTANT design constraints for a freestanding kernel (no operating system
// under us): there is NO heap here. Storage is a fixed static array of entries,
// each owning its own small inline byte buffer. This is deliberately tiny — a
// handful of small files — because its first job is just to be the writable
// scratch area for the boot self-test and the foundation a real initramfs builds
// on. Growing it later is a one-line capacity bump.
//
// On the VFS vtable being READ-ONLY today: the VFS's `Backend.VTable` exposes
// resolve/open/read/stat but NO write slot. Rather than widen that shared
// interface (and risk every other backend), tmpfs exposes its WRITE path as its
// own module-level helpers — `create()` and `write()` — that callers use
// directly. Reads still flow through the standard VFS read path, so we prove the
// round-trip "write here, read it back THROUGH the VFS" without touching vfs.zig.

const std = @import("std");
const serial = @import("../drivers/serial.zig"); // COM1 logging (log = debug-only)
const config = @import("config"); // build-time flags (debug_log)
const vfs = @import("vfs.zig"); // the VFS layer we register as a backend of

// --- Static storage ----------------------------------------------------------
// How many files tmpfs can hold at once, and how big each one's contents can be.
// Small on purpose: this is scratch space, not a disk. Both are static arrays so
// no allocator is ever needed.
const MAX_FILES = 8; // a handful of files is plenty for /tmp + the self-test
const MAX_FILE_SIZE = 4096; // 4 KiB of contents per file (one page's worth)
const MAX_NAME_LEN = 64; // longest file name we store (bytes, no NUL needed)

// One in-memory file: its name, its byte contents, and how many of those bytes
// are actually valid. The name and data buffers are fixed-size and live INLINE
// in the entry (so the whole table is one static blob with no pointers to chase).
const Entry = struct {
    used: bool = false, // is this slot occupied by a live file?
    name_buf: [MAX_NAME_LEN]u8 = undefined, // the file name's bytes...
    name_len: usize = 0, // ...and how many of them are valid
    data: [MAX_FILE_SIZE]u8 = undefined, // the file's contents...
    len: usize = 0, // ...and how many bytes are valid (the file size)

    // The live name as a slice (so callers can compare/print it directly).
    fn name(self: *const Entry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

// The whole filesystem: a fixed array of entry slots. `undefined` is fine because
// every field that matters (`used`, the lengths) is set before it's ever read;
// init() below stamps `used = false` across the board to be explicit and so a
// second mount (e.g. a re-run self-test) starts clean.
var files: [MAX_FILES]Entry = undefined;

// Reset tmpfs to empty. Safe to call more than once (the boot path and the
// self-test both call it); marking every slot free is all that's needed.
pub fn init() void {
    var i: usize = 0;
    while (i < MAX_FILES) : (i += 1) {
        files[i].used = false;
    }
    serial.log("[TMPFS] in-memory filesystem initialized.\n", .{});
}

// --- Name handling -----------------------------------------------------------
// The VFS hands a backend a path RELATIVE to its mount root, always starting with
// '/', e.g. "/scratch". tmpfs is flat (no subdirectories), so we store files by
// their bare name. Strip exactly one leading '/' to turn the VFS path into the
// name we keyed on. (A path of just "/" — the mount root — becomes the empty
// name, which never matches a real file, so resolving the root reports "missing"
// rather than crashing; tmpfs has no directory listing yet.)
fn pathToName(path: []const u8) []const u8 {
    if (path.len > 0 and path[0] == '/') return path[1..];
    return path;
}

// Find the live entry whose name equals `name`, or null if there's no such file.
fn find(name: []const u8) ?*Entry {
    var i: usize = 0;
    while (i < MAX_FILES) : (i += 1) {
        if (files[i].used and std.mem.eql(u8, files[i].name(), name)) {
            return &files[i];
        }
    }
    return null;
}

// --- Write path (tmpfs-specific helpers, NOT part of the VFS vtable) ----------
// The VFS vtable is read-only, so the kernel reaches tmpfs's write side through
// these two functions directly. They are the only way bytes get INTO the fs.

// Possible failures when creating or writing a file. Returning an explicit error
// (rather than a bool) lets the caller log exactly what went wrong.
pub const Error = error{
    NoSpace, // the file table is full (no free slot for a new file)
    NameTooLong, // the requested name exceeds MAX_NAME_LEN
    FileTooBig, // the bytes to write exceed MAX_FILE_SIZE
    NotFound, // write() on a name that was never created
};

// Create an empty file named `name`. If a file with that name already exists,
// this is a no-op that returns the existing one (so create-then-write is safe to
// repeat). Fails if the name is too long or the table is full.
pub fn create(name: []const u8) Error!void {
    if (name.len > MAX_NAME_LEN) return Error.NameTooLong;
    if (find(name) != null) return; // already exists -> nothing to do
    // Find a free slot and claim it as a zero-length file.
    var i: usize = 0;
    while (i < MAX_FILES) : (i += 1) {
        if (!files[i].used) {
            files[i].used = true;
            files[i].name_len = name.len;
            @memcpy(files[i].name_buf[0..name.len], name); // copy the name in
            files[i].len = 0; // brand-new file is empty
            return;
        }
    }
    return Error.NoSpace; // no free slot
}

// Replace the contents of the file named `name` with `bytes`. The file must have
// been create()d first. Overwrites (does not append) — the new length is exactly
// `bytes.len`. Fails if the file doesn't exist or the bytes don't fit.
pub fn write(name: []const u8, bytes: []const u8) Error!void {
    if (bytes.len > MAX_FILE_SIZE) return Error.FileTooBig;
    const e = find(name) orelse return Error.NotFound;
    @memcpy(e.data[0..bytes.len], bytes); // store the bytes in RAM
    e.len = bytes.len; // the file is now exactly this long
}

// --- VFS backend vtable ------------------------------------------------------
// These four functions match `vfs.Backend.VTable` EXACTLY and are what the VFS
// calls on our behalf. tmpfs holds all its state in module-level statics, so the
// opaque `ctx` pointer is unused (we still accept it to satisfy the signature).

// Map an Entry (by its slot index) to a VFS Vnode. tmpfs only stores files (no
// directories yet), so the kind is always `.file`. The `handle` is the entry's
// index in `files`, which is opaque to the VFS — the caller just hands it back to
// our `read`.
fn entryToVnode(index: usize) vfs.Vnode {
    return .{
        .kind = .file,
        .size = files[index].len,
        .handle = index, // tmpfs-private locator (slot index)
    };
}

// Look up a path's metadata, or null if no such file. Used for both resolve and
// stat (they're identical for a flat read source).
fn tmpfsResolve(_: *anyopaque, path: []const u8) ?vfs.Vnode {
    const name = pathToName(path);
    var i: usize = 0;
    while (i < MAX_FILES) : (i += 1) {
        if (files[i].used and std.mem.eql(u8, files[i].name(), name)) {
            return entryToVnode(i);
        }
    }
    return null;
}

// An open-file cursor for tmpfs: which slot we're reading and how far in we are.
// It's small enough to live inside the VFS's OpenFile scratch area (asserted at
// comptime in tmpfsOpen below).
const Reader = struct {
    index: usize, // which `files` slot this reader streams from
    pos: usize, // byte offset of the next read within that file
};

// Open a file for streaming reads. Stashes a Reader in the caller-owned scratch
// area (out.inner) and returns true; returns false if the path doesn't name a
// live file.
fn tmpfsOpen(_: *anyopaque, path: []const u8, out: *vfs.OpenFile) bool {
    // Our reader must fit in the VFS's inline scratch buffer (out.inner), and its
    // alignment must be no stricter than that buffer's. The buffer is a plain u8
    // array whose alignment is widened by the field's `align(...)` attribute, so
    // we read that declared field alignment off the OpenFile struct rather than
    // the array element's (which would just be 1). The Reader is tiny (two
    // usizes), so both checks always hold; the asserts just document the
    // dependency on the VFS's OpenFile.inner layout.
    const inner_field = std.meta.fieldInfo(vfs.OpenFile, .inner);
    comptime std.debug.assert(@sizeOf(Reader) <= @sizeOf(inner_field.type));
    comptime std.debug.assert(@alignOf(Reader) <= inner_field.alignment);
    const name = pathToName(path);
    const e = find(name) orelse return false; // missing -> can't open
    // Compute the slot index from the entry pointer (so read() can find it again).
    const index = (@intFromPtr(e) - @intFromPtr(&files[0])) / @sizeOf(Entry);
    const slot: *Reader = @ptrCast(@alignCast(&out.inner));
    slot.* = .{ .index = index, .pos = 0 }; // start at the beginning of the file
    return true;
}

// Copy up to dst.len bytes from the open file into dst, advancing the cursor.
// Returns the number of bytes copied (0 means end-of-file).
fn tmpfsRead(_: *anyopaque, file: *vfs.OpenFile, dst: []u8) usize {
    const slot: *Reader = @ptrCast(@alignCast(&file.inner));
    const e = &files[slot.index];
    if (slot.pos >= e.len) return 0; // already at (or past) end of file
    const remaining = e.len - slot.pos; // bytes left in the file
    const n = @min(remaining, dst.len); // don't overrun dst or the file
    @memcpy(dst[0..n], e.data[slot.pos .. slot.pos + n]); // hand the bytes back
    slot.pos += n; // advance the cursor for the next read
    return n;
}

// Reposition the read cursor to an absolute byte offset. tmpfs files are just a
// flat byte array, so seeking is a one-line assignment of `pos`. The VFS has
// already clamped abs_pos into [0, size], so it always lands inside the file.
fn tmpfsSeek(_: *anyopaque, file: *vfs.OpenFile, abs_pos: u64) bool {
    const slot: *Reader = @ptrCast(@alignCast(&file.inner));
    slot.pos = @intCast(abs_pos);
    return true;
}

// Copy bytes from `src` INTO the open file at the handle's current `pos`, the WRITE
// mirror of tmpfsRead. Stores as many bytes as fit before the per-file cap
// (MAX_FILE_SIZE), advances `pos` past them, and grows the file's length if the
// write extended past the old end. Returns how many bytes were actually stored
// (which may be FEWER than src.len if the write would overflow the file's fixed
// buffer — the caller learns it could only place a prefix). A write that starts at
// or past the cap stores nothing and returns 0.
fn tmpfsWrite(_: *anyopaque, file: *vfs.OpenFile, src: []const u8) usize {
    const slot: *Reader = @ptrCast(@alignCast(&file.inner));
    const e = &files[slot.index];
    if (slot.pos >= MAX_FILE_SIZE) return 0; // no room left in this file's buffer
    const room = MAX_FILE_SIZE - slot.pos; // bytes that still fit before the cap
    const n = @min(room, src.len); // store at most what fits / what was asked
    @memcpy(e.data[slot.pos .. slot.pos + n], src[0..n]); // land the bytes in RAM
    slot.pos += n; // advance the cursor past what we wrote
    if (slot.pos > e.len) e.len = slot.pos; // grow the file if we wrote past its end
    return n; // bytes actually stored (may be < src.len at the cap)
}

// The vtable wiring tmpfs's operations into the shape the VFS expects. resolve and
// stat are the same function (metadata lookup is identical for both). tmpfs files
// are seekable, so we provide the optional `seek` slot.
const tmpfs_vtable = vfs.Backend.VTable{
    .resolve = tmpfsResolve,
    .open = tmpfsOpen,
    .read = tmpfsRead,
    .stat = tmpfsResolve,
    .seek = tmpfsSeek,
    .write = tmpfsWrite, // tmpfs is WRITABLE: streaming fd writes land in RAM
};

var tmpfs_dummy_ctx: u8 = 0; // a real address to hand out as the opaque ctx

// Build a Backend value bound to tmpfs. Callers do
// `vfs.mount("/tmp", tmpfs.backend())`.
pub fn backend() vfs.Backend {
    return .{ .ctx = &tmpfs_dummy_ctx, .vtable = &tmpfs_vtable };
}

// === Boot self-test ==========================================================
// Debug-log-gated proof that the WHOLE loop works: create a file in RAM, write a
// known string into it via tmpfs's write helper, then open + read it back
// THROUGH the VFS (not by reaching into `files` directly) and confirm the bytes
// match. This is the writable analogue of the VFS's read-only FAT32 self-test.
// Quiet unless built with -Ddebug-log=true, so a normal boot stays silent.
//
// NOTE: this assumes the caller has already done `vfs.mount("/tmp", backend())`
// (main.zig does it right after mounting FAT32), so the "/tmp/..." path routes
// here. It uses the path "/tmp/hello.txt".
pub fn selfTest() void {
    if (!config.debug_log) return; // normal boot stays silent

    const contents = "Hello from tmpfs in RAM!"; // the bytes we'll round-trip
    const name = "hello.txt"; // tmpfs-relative name (mounted at /tmp)
    const vfs_path = "/tmp/hello.txt"; // full path as a VFS caller sees it

    // 1) Create the (empty) file in RAM.
    create(name) catch |err| {
        serial.log("[TMPFS] self-test: create failed: {s}\n", .{@errorName(err)});
        return;
    };
    // 2) Write the known string into it (this is the WRITE path the VFS lacks).
    write(name, contents) catch |err| {
        serial.log("[TMPFS] self-test: write failed: {s}\n", .{@errorName(err)});
        return;
    };
    serial.log("[TMPFS] self-test: wrote {d} bytes to {s}.\n", .{ contents.len, vfs_path });

    // 3) stat the file THROUGH the VFS to confirm it's visible at /tmp/...
    const st = vfs.stat(vfs_path) orelse {
        serial.log("[TMPFS] self-test: stat {s} via VFS failed.\n", .{vfs_path});
        return;
    };
    serial.log("[TMPFS] self-test: stat {s} -> {s}, {d} bytes.\n", .{ vfs_path, @tagName(st.kind), st.size });

    // 4) Open + read it back THROUGH the VFS read path.
    var f: vfs.OpenFile = undefined;
    if (!vfs.open(vfs_path, &f)) {
        serial.log("[TMPFS] self-test: open {s} via VFS failed.\n", .{vfs_path});
        return;
    }
    var buf: [64]u8 = undefined;
    const n = f.read(&buf);

    // 5) Confirm the bytes we read back are exactly what we wrote.
    if (n != contents.len or !std.mem.eql(u8, buf[0..n], contents)) {
        serial.log("[TMPFS] self-test: MISMATCH (read {d} bytes via VFS).\n", .{n});
        return;
    }
    // The harness greps this marker AND the known contents to prove the written
    // bytes flowed back out through the VFS read path.
    serial.log("[TMPFS] self-test: read {d} bytes via VFS: {s}\n", .{ n, buf[0..n] });
    serial.log("[TMPFS] self-test OK: wrote a file to RAM and read it back through the VFS.\n", .{});
}

// --- Inline unit tests (host, via src/tests.zig) -----------------------------
// These run on the host under `zig build test`. They exercise tmpfs's storage
// and read logic directly (no VFS routing, no hardware), so they're fast and
// freestanding-independent. The VFS-routing path is proven by the boot self-test.

const testing = std.testing;

test "create then write then resolve sees the right size" {
    init(); // clean fs
    try create("a.txt");
    try write("a.txt", "hello");
    // resolve via the vtable function (the VFS would call exactly this).
    const v = tmpfsResolve(&tmpfs_dummy_ctx, "/a.txt");
    try testing.expect(v != null);
    try testing.expectEqual(vfs.Kind.file, v.?.kind);
    try testing.expectEqual(@as(u64, 5), v.?.size);
}

test "open then read returns exactly the written bytes" {
    init();
    try create("greet");
    try write("greet", "hi there");
    var f: vfs.OpenFile = undefined;
    f.backend = undefined; // read() below calls tmpfsRead directly, not via vtable
    try testing.expect(tmpfsOpen(&tmpfs_dummy_ctx, "/greet", &f));
    var buf: [32]u8 = undefined;
    const n = tmpfsRead(&tmpfs_dummy_ctx, &f, &buf);
    try testing.expectEqualStrings("hi there", buf[0..n]);
    // A second read at end-of-file returns 0 (no more bytes).
    try testing.expectEqual(@as(usize, 0), tmpfsRead(&tmpfs_dummy_ctx, &f, &buf));
}

test "read in small chunks reassembles the whole file" {
    init();
    try create("chunked");
    try write("chunked", "abcdef");
    var f: vfs.OpenFile = undefined;
    f.backend = undefined;
    try testing.expect(tmpfsOpen(&tmpfs_dummy_ctx, "/chunked", &f));
    var out: [6]u8 = undefined;
    var total: usize = 0;
    var small: [2]u8 = undefined; // force multiple reads (2 bytes at a time)
    while (true) {
        const n = tmpfsRead(&tmpfs_dummy_ctx, &f, &small);
        if (n == 0) break;
        @memcpy(out[total .. total + n], small[0..n]);
        total += n;
    }
    try testing.expectEqualStrings("abcdef", out[0..total]);
}

test "write overwrites previous contents (length shrinks)" {
    init();
    try create("ow");
    try write("ow", "longer text");
    try write("ow", "tiny"); // shorter overwrite
    const v = tmpfsResolve(&tmpfs_dummy_ctx, "/ow").?;
    try testing.expectEqual(@as(u64, 4), v.size); // size reflects the new write
}

test "resolving a missing file returns null" {
    init();
    try testing.expect(tmpfsResolve(&tmpfs_dummy_ctx, "/nope") == null);
    var f: vfs.OpenFile = undefined;
    try testing.expect(!tmpfsOpen(&tmpfs_dummy_ctx, "/nope", &f));
}

test "write before create reports NotFound" {
    init();
    try testing.expectError(Error.NotFound, write("ghost", "x"));
}

test "create is idempotent and does not wipe contents" {
    init();
    try create("keep");
    try write("keep", "data");
    try create("keep"); // second create on the same name is a no-op
    const v = tmpfsResolve(&tmpfs_dummy_ctx, "/keep").?;
    try testing.expectEqual(@as(u64, 4), v.size); // contents survived
}

test "the file table fills up and then reports NoSpace" {
    init();
    var i: usize = 0;
    var namebuf: [8]u8 = undefined;
    while (i < MAX_FILES) : (i += 1) {
        const nm = std.fmt.bufPrint(&namebuf, "f{d}", .{i}) catch unreachable;
        try create(nm);
    }
    // One more than the table holds must fail.
    try testing.expectError(Error.NoSpace, create("overflow"));
}

test "an over-long name is rejected" {
    init();
    const long = "x" ** (MAX_NAME_LEN + 1);
    try testing.expectError(Error.NameTooLong, create(long));
}

test "writing more than the per-file cap is rejected" {
    init();
    try create("big");
    const toobig = [_]u8{0} ** (MAX_FILE_SIZE + 1);
    try testing.expectError(Error.FileTooBig, write("big", &toobig));
}

// --- Streaming fd write path (tmpfsWrite via the VFS vtable) ------------------
// These exercise the new vtable write slot directly (the VFS would call exactly
// this), driving it through an open handle just like the syscall path does.

test "tmpfsWrite stores bytes at the cursor and grows the file length" {
    init();
    try create("w.txt");
    var f: vfs.OpenFile = undefined;
    f.backend = undefined; // we call the vtable fns directly, not via the backend
    try testing.expect(tmpfsOpen(&tmpfs_dummy_ctx, "/w.txt", &f));
    // Write a string into the empty file; it should store all of it and grow len.
    const n = tmpfsWrite(&tmpfs_dummy_ctx, &f, "hello world");
    try testing.expectEqual(@as(usize, 11), n);
    const v = tmpfsResolve(&tmpfs_dummy_ctx, "/w.txt").?;
    try testing.expectEqual(@as(u64, 11), v.size); // file grew to the written length
}

test "tmpfsWrite then read back returns exactly the written bytes" {
    init();
    try create("rt");
    var f: vfs.OpenFile = undefined;
    f.backend = undefined;
    try testing.expect(tmpfsOpen(&tmpfs_dummy_ctx, "/rt", &f));
    _ = tmpfsWrite(&tmpfs_dummy_ctx, &f, "round-trip");
    // Rewind the reader to the start and read the bytes back out.
    try testing.expect(tmpfsSeek(&tmpfs_dummy_ctx, &f, 0));
    var buf: [32]u8 = undefined;
    const r = tmpfsRead(&tmpfs_dummy_ctx, &f, &buf);
    try testing.expectEqualStrings("round-trip", buf[0..r]);
}

test "tmpfsWrite mid-file overwrites in place without shrinking the file" {
    init();
    try create("mid");
    var f: vfs.OpenFile = undefined;
    f.backend = undefined;
    try testing.expect(tmpfsOpen(&tmpfs_dummy_ctx, "/mid", &f));
    _ = tmpfsWrite(&tmpfs_dummy_ctx, &f, "AAAAAAAA"); // 8 bytes, len = 8
    try testing.expect(tmpfsSeek(&tmpfs_dummy_ctx, &f, 2)); // cursor at byte 2
    _ = tmpfsWrite(&tmpfs_dummy_ctx, &f, "BB"); // overwrite bytes 2..4, len stays 8
    const v = tmpfsResolve(&tmpfs_dummy_ctx, "/mid").?;
    try testing.expectEqual(@as(u64, 8), v.size); // an in-place write didn't shrink it
    try testing.expect(tmpfsSeek(&tmpfs_dummy_ctx, &f, 0));
    var buf: [8]u8 = undefined;
    const r = tmpfsRead(&tmpfs_dummy_ctx, &f, &buf);
    try testing.expectEqualStrings("AABBAAAA", buf[0..r]);
}

test "tmpfsWrite caps at MAX_FILE_SIZE and reports the bytes that fit" {
    init();
    try create("cap");
    var f: vfs.OpenFile = undefined;
    f.backend = undefined;
    try testing.expect(tmpfsOpen(&tmpfs_dummy_ctx, "/cap", &f));
    // Start one byte before the cap, then ask to write 4: only one byte fits.
    try testing.expect(tmpfsSeek(&tmpfs_dummy_ctx, &f, MAX_FILE_SIZE - 1));
    try testing.expectEqual(@as(usize, 1), tmpfsWrite(&tmpfs_dummy_ctx, &f, "ABCD"));
    // Now the cursor sits exactly at the cap: a further write stores nothing.
    try testing.expectEqual(@as(usize, 0), tmpfsWrite(&tmpfs_dummy_ctx, &f, "X"));
}
