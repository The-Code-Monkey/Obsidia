// pipefs — anonymous in-kernel pipes.
//
// A "pipe" is a one-way byte conduit: a thread writes bytes into one end and
// another thread reads them out the other. The classic Unix `cmd1 | cmd2` is
// exactly this — cmd1's stdout is the WRITE end of a pipe whose READ end is
// cmd2's stdin. We model each pipe with a fixed in-kernel ring buffer (a
// circular byte queue): the writer drops bytes in at the "write position", the
// reader takes them out at the "read position", and the two chase each other
// around the buffer.
//
// The clever part is that we don't need a brand-new kind of file handle. A pipe
// END is just an anonymous VFS open-file — an `OpenFile` whose `backend` points
// at the one static pipefs backend below. Because of that, the SAME fd table,
// the SAME read()/write()/close()/dup() syscalls, and the SAME `OpenFile` plumbing
// that already serve FAT32/tmpfs/devfs files transparently serve pipe ends too.
// `SYS_pipe` just hands the caller two fds (a read end + a write end) over one
// shared ring; everything else is the existing machinery.
//
// Blocking is what makes a pipe useful for producer/consumer: a reader that
// finds the pipe EMPTY parks on a wait queue until a writer wakes it (or until
// every write end is closed, which it reads as end-of-file); a writer that finds
// the pipe FULL parks until a reader drains some space and wakes it. We reuse the
// scheduler's WaitQueue (the block-on-event primitive) for both directions.
//
// Freestanding, no heap: a fixed static pool of pipe objects, each a fixed ring
// buffer. `create` grabs a free slot; `close` frees it once both ends are gone.

const std = @import("std");
const serial = @import("../drivers/serial.zig"); // COM1 logging (log = debug-only)
const config = @import("config"); // build-time flags (debug_log)
const vfs = @import("vfs.zig"); // pipe ends are anonymous vfs.OpenFiles
const scheduler = @import("../sched/scheduler.zig"); // spawn() for the self-test producer
const waitqueue = @import("../sched/waitqueue.zig"); // block a reader/writer until the other side acts

// Bytes per pipe. POSIX guarantees at least PIPE_BUF (512) of atomic capacity;
// 4 KiB (one page's worth) is a comfortable, conventional choice and keeps each
// pipe object small enough that a static pool of them is cheap .bss.
const PIPE_CAP: usize = 4096;

// How many pipes can be live at once. Small: a handful is plenty for this kernel,
// and each pipe is ~4 KiB, so the whole pool is a few tens of KiB of static .bss.
const MAX_PIPES: usize = 8;

// One pipe: a ring buffer plus the bookkeeping that turns it into a blocking,
// reference-counted conduit. All fields are touched only with interrupts masked
// (read/write/close run under the scheduler's single-core, masked discipline),
// so no extra locking is needed beyond what the WaitQueue already does.
const Pipe = struct {
    buf: [PIPE_CAP]u8 = undefined, // the circular byte store
    read_pos: usize = 0, // next byte to hand to a reader (index into buf)
    write_pos: usize = 0, // next free slot for a writer (index into buf)
    count: usize = 0, // bytes currently buffered (0 = empty, PIPE_CAP = full)
    readers: waitqueue.WaitQueue = .{}, // a writer signals this to wake a blocked reader
    writers: waitqueue.WaitQueue = .{}, // a reader signals this to wake a blocked writer
    // How many open ends reference this pipe. create() sets it to 2 (one read end +
    // one write end); dup() bumps it; close() drops it; the slot is freed at 0.
    refcount: u32 = 0,
    // How many of those ends are WRITE ends still open. A reader hits end-of-file
    // (read returns 0) only when the buffer is empty AND this is 0 — i.e. no writer
    // can ever produce more. Tracked separately from refcount so a read end closing
    // doesn't fool a writer, and a write end closing wakes a blocked reader for EOF.
    writers_open: u32 = 0,
    in_use: bool = false, // is this pool slot allocated?
};

// The static pool. `pipes[id]` is addressed by the `pipe_id` stored in each end.
var pipes: [MAX_PIPES]Pipe = [_]Pipe{.{}} ** MAX_PIPES;

// What a pipe END stores in its vfs.OpenFile.inner: just which pipe it belongs to
// and which direction it is. Tiny — fits the 1024-byte inner with room to spare
// (a comptime assert below guards that).
const PipeEnd = struct {
    pipe_id: u32, // index into `pipes`
    is_write: bool, // true = the write end, false = the read end
};

comptime {
    // The end descriptor must FIT inside OpenFile.inner and be reachable at its
    // alignment. endOf() does @alignCast(&file.inner) to *PipeEnd. OpenFile declares
    // inner with align(16), and a struct's own alignment is at least that of its most-
    // aligned field, so @alignOf(vfs.OpenFile) >= the inner buffer's alignment — assert
    // PipeEnd's alignment fits within that (so lowering vfs's inner alignment below
    // @alignOf(PipeEnd) trips a compile error here, not a misaligned UB pointer at run
    // time). @sizeOf(OpenFile) likewise bounds the inner buffer's capacity.
    std.debug.assert(@sizeOf(PipeEnd) <= @sizeOf(vfs.OpenFile));
    std.debug.assert(@alignOf(PipeEnd) <= @alignOf(vfs.OpenFile));
}

// Pull the PipeEnd back out of an OpenFile's inner scratch area.
fn endOf(file: *vfs.OpenFile) *PipeEnd {
    return @ptrCast(@alignCast(&file.inner));
}

// Allocate a free pipe pool slot, initialize it as empty with refcount 2 (one read
// end + one write end) and one open writer, and return its id — or null if every
// slot is in use.
fn allocPipe() ?u32 {
    var i: usize = 0;
    while (i < MAX_PIPES) : (i += 1) {
        if (!pipes[i].in_use) {
            // Reset every field so a reused slot starts clean (no stale bytes/positions
            // and FRESH wait queues — a leftover `pending` from a previous life would
            // make the first wait() return spuriously).
            pipes[i] = .{
                .in_use = true,
                .refcount = 2, // two ends: one reader + one writer
                .writers_open = 1, // exactly one write end open at creation
            };
            return @intCast(i);
        }
    }
    return null; // pool exhausted
}

// === The pipefs backend (vtable) =============================================
// One static Backend value shared by every pipe end. Its ctx is unused (each end
// carries its own pipe_id in `inner`), so we hand out a dummy address.

var pipefs_dummy_ctx: u8 = 0;

// --- Pure ring-buffer primitives (no blocking, no signalling) ----------------
// These are the heart of the conduit, split out from the blocking read/write below
// so they can be unit-tested on the host. They ONLY move bytes + advance the ring
// positions — they never touch a wait queue (whose cli/sti would fault outside ring
// 0), so the host tests can call them directly. The blocking wrappers add the
// park-until-ready + wake-the-other-side logic around them.

// Copy out up to dst.len bytes from `p`'s ring into dst, advancing read_pos around
// the wrap and shrinking count. Returns the byte count actually copied.
fn copyOut(p: *Pipe, dst: []u8) usize {
    var copied: usize = 0;
    while (copied < dst.len and p.count > 0) {
        dst[copied] = p.buf[p.read_pos];
        p.read_pos = (p.read_pos + 1) % PIPE_CAP;
        p.count -= 1;
        copied += 1;
    }
    return copied;
}

// Copy in up to src.len bytes into `p`'s ring at write_pos, advancing it around the
// wrap and growing count (stopping when the ring is full). Returns the count stored.
fn copyIn(p: *Pipe, src: []const u8) usize {
    var stored: usize = 0;
    while (stored < src.len and p.count < PIPE_CAP) {
        p.buf[p.write_pos] = src[stored];
        p.write_pos = (p.write_pos + 1) % PIPE_CAP;
        p.count += 1;
        stored += 1;
    }
    return stored;
}

// read from a READ end. If the buffer is empty and a writer might still produce,
// BLOCK on the reader wait queue until a writer signals (or every write end has
// closed, signalling EOF). Then copy out whatever is available, wake any blocked
// writer (we just freed space), and return the count. Returns 0 ONLY when the
// buffer is empty AND no write end remains — POSIX end-of-file.
fn pipeRead(_: *anyopaque, file: *vfs.OpenFile, dst: []u8) usize {
    const end = endOf(file);
    const p = &pipes[end.pipe_id];
    // Wait until there is something to read OR end-of-file. We loop because wait()
    // can return for reasons other than "data is now here" (a timeout safety net),
    // and because after waking we must re-check under the same masked discipline.
    while (p.count == 0) {
        if (p.writers_open == 0) return 0; // empty AND no writer can ever come -> EOF
        // Empty but writers remain: park until a writer puts bytes in (or the last
        // writer closes, which signals this same queue so we re-check and see EOF).
        // The finite timeout is a safety net: with the preemption timer running (the
        // normal syscall path) a missed signal degrades to latency rather than a hang.
        // Correctness never depends on it — every wakeup also comes from an explicit
        // signal() — which is why the cooperative self-test (timer off) still works.
        _ = p.readers.wait(100);
    }
    const copied = copyOut(p, dst); // there is at least one byte; drain what fits
    // We freed space, so a writer blocked on a full pipe can now make progress.
    p.writers.signal();
    return copied;
}

// write to a WRITE end. If the buffer is full, BLOCK on the writer wait queue until
// a reader drains space and signals. Then copy in as much as fits, wake any blocked
// reader (there is now data), and keep going until all of `src` is written (looping
// over block/copy). Returns how many bytes were stored (== src.len unless every
// reader has gone — then it stops early rather than block on a conduit no one drains).
fn pipeWrite(_: *anyopaque, file: *vfs.OpenFile, src: []const u8) usize {
    const end = endOf(file);
    const p = &pipes[end.pipe_id];
    var written: usize = 0;
    while (written < src.len) {
        // If every READ end is gone, no one will ever drain this pipe, so writing more
        // is pointless: a real OS raises SIGPIPE / returns EPIPE here. We have no signals
        // on this path, so we stop and report what we managed to write. We check this on
        // EVERY iteration (not only when the buffer is full): bytes copied into a ring no
        // reader will drain are silently lost, so the moment the last reader leaves we must
        // refuse — even if free space remains. refcount counts ALL ends and writers_open
        // counts the write ends, so refcount == writers_open means no read end is left.
        if (p.refcount <= p.writers_open) return written;
        // Block while the buffer is completely full (no reader has made room yet). Re-check
        // the dead-reader condition each time we wake, so a reader that closes WHILE we're
        // parked here (which signals this queue) breaks us out instead of looping forever.
        while (p.count == PIPE_CAP) {
            if (p.refcount <= p.writers_open) return written; // last reader left while we waited
            _ = p.writers.wait(100); // park until a reader frees space (or closes)
        }
        written += copyIn(p, src[written..]); // store up to the rest of src or the free space
        // We added data, so a reader blocked on an empty pipe can now proceed.
        p.readers.signal();
    }
    return written;
}

// The pure refcount core of close, split out so the host tests can exercise the
// exact decrement / writers_open / free-at-zero logic without the wait-queue
// signalling (whose cli/sti would fault outside ring 0). Drops the open-writer
// count for a write end, drops the refcount, and frees the slot at 0.
fn closeEnd(p: *Pipe, is_write: bool) void {
    if (is_write and p.writers_open > 0) p.writers_open -= 1;
    if (p.refcount > 0) p.refcount -= 1;
    if (p.refcount == 0) p.in_use = false; // both ends gone -> the slot is reusable
}

// close ONE end. First drop this end's counts (closeEnd: writers_open for a write end,
// then refcount, freeing the slot at 0). THEN WAKE the other side's blocked waiter so
// it RE-CHECKS the now-updated state: closing a WRITE end wakes a reader parked on an
// empty pipe so it sees end-of-file (no writers left); closing a READ end wakes a writer
// parked on a full pipe so it sees no reader and stops. We only signal while the slot is
// still in use (refcount > 0): if this close took refcount to 0 then BOTH ends are gone,
// so no one can be blocked on this pipe and the slot has just been freed — signalling it
// would touch a reclaimable slot (and could, on a future multi-core port where the slot
// is reused between the free and the signal, mutate a different pipe's wait queue). The
// updates happen before the wake so the woken thread reads the post-close counts.
fn pipeClose(_: *anyopaque, file: *vfs.OpenFile) void {
    const end = endOf(file);
    const p = &pipes[end.pipe_id];
    closeEnd(p, end.is_write); // writers_open (if write) --, refcount --, free at 0
    if (!p.in_use) return; // refcount hit 0: both ends gone, nobody waits, slot freed
    // The other end is still open: wake whoever might be blocked on it so it re-checks.
    if (end.is_write) {
        p.readers.signal(); // a blocked reader wakes and sees EOF (no writers left)
    } else {
        p.writers.signal(); // a blocked writer wakes and sees no reader, then stops
    }
}

// clone: a second descriptor now refers to this same end (dup copies the OpenFile,
// so both share one pipe). Bump the refcount so the pipe isn't freed until BOTH
// descriptors are closed. A dup of a WRITE end also adds a live writer, so a reader
// won't see EOF until every duplicated write end is closed too.
fn pipeClone(_: *anyopaque, file: *vfs.OpenFile) void {
    const end = endOf(file);
    const p = &pipes[end.pipe_id];
    p.refcount += 1;
    if (end.is_write) p.writers_open += 1;
}

// resolve/stat: pipes are anonymous (no path), so there's nothing to look up by
// name. These exist only to satisfy the vtable shape; they always report "missing"
// because you can't open a pipe end by a path — you get one from SYS_pipe.
fn pipeResolve(_: *anyopaque, _: []const u8) ?vfs.Vnode {
    return null;
}

// open: same story — a pipe end is never reached through vfs.open(path), so this
// path can't be hit. Return false to be safe.
fn pipeOpen(_: *anyopaque, _: []const u8, _: *vfs.OpenFile) bool {
    return false;
}

const pipefs_vtable = vfs.Backend.VTable{
    .resolve = pipeResolve,
    .open = pipeOpen,
    .read = pipeRead,
    .stat = pipeResolve, // stat == resolve (both "missing" — anonymous)
    // .seek stays null: a pipe is a stream, not a file with positions, so lseek on a
    // pipe fd returns ESPIPE (exactly POSIX behavior) via the VFS's null-seek path.
    .write = pipeWrite,
    .close = pipeClose,
    .clone = pipeClone,
};

// The single static backend every pipe end points at.
const pipefs_backend = vfs.Backend{ .ctx = &pipefs_dummy_ctx, .vtable = &pipefs_vtable };

// Fill `out` as a pipe end (read or write) for pipe `id`. Points its backend at the
// static pipefs backend and stamps the PipeEnd into its inner scratch area. Size 0
// (pipes have no fixed length) and offset 0 (unused — a stream has no position).
fn makeEnd(out: *vfs.OpenFile, id: u32, is_write: bool) void {
    out.* = .{ .backend = &pipefs_backend, .offset = 0, .size = 0 };
    endOf(out).* = .{ .pipe_id = id, .is_write = is_write };
}

// Allocate a fresh pipe (refcount 2 = one read end + one write end) and fill the
// two output ends. Returns false if the pool is exhausted (the caller maps that to
// EMFILE / ENFILE). On success `read_out` is the read end and `write_out` the write
// end, both backed by the same ring; closing both frees the pipe.
pub fn create(read_out: *vfs.OpenFile, write_out: *vfs.OpenFile) bool {
    const id = allocPipe() orelse return false; // pool full
    makeEnd(read_out, id, false); // the read end
    makeEnd(write_out, id, true); // the write end
    return true;
}

// === Self-test ===============================================================
// Debug-log-gated proof that a pipe carries bytes from a WRITER to a READER across
// threads, that the reader BLOCKS on an empty pipe and is woken by the writer (and
// by the last-writer-close EOF), and that the pipe slot is reclaimed when both ends
// close. A kernel-thread producer writes N bytes; the main thread reads them all,
// verifies the exact byte sequence, then reads once more to confirm EOF after the
// writer closes its end. Runs cooperatively: blocking on either side yields the CPU
// to the other thread, and each side's signal() readies the other — so the two
// ping-pong to completion with NO preemption, and a same-thread leftover never
// deadlocks (the producer fills, the consumer drains, alternating via the queues).

const SELFTEST_N: usize = 9000; // > PIPE_CAP (4096), so the ring wraps AND the
// writer must BLOCK at least once (proving the writer-side wait/wake), and the
// reader drains in several rounds (proving the reader-side wait/wake).

// Shared handles for the self-test producer/consumer. The producer thread writes
// through `st_write`; the main thread reads through `st_read`. Static so the spawned
// kernel thread (which takes no args) can reach them.
var st_read: vfs.OpenFile = undefined;
var st_write: vfs.OpenFile = undefined;

// The producer kernel thread: write SELFTEST_N bytes (each byte = its index mod 256
// so the reader can verify the exact sequence), then CLOSE the write end so the
// reader sees EOF. Writing more than the buffer holds forces it to block until the
// reader drains space — exercising the writer wait queue.
fn stProducer() void {
    var i: usize = 0;
    while (i < SELFTEST_N) {
        // Hand the bytes over in chunks so the ring keeps cycling (fill, block, drain).
        var chunk: [256]u8 = undefined;
        const this = @min(chunk.len, SELFTEST_N - i);
        var k: usize = 0;
        while (k < this) : (k += 1) chunk[k] = @truncate((i + k) & 0xFF);
        const n = pipeWrite(&pipefs_dummy_ctx, &st_write, chunk[0..this]);
        // A short write (n < this) means every reader has gone — pipeWrite refuses to
        // store into a pipe no one drains. Stop rather than spin: without this guard a
        // returned 0 would leave `i` unchanged and busy-loop forever (no yield, no block).
        i += n;
        if (n < this) break;
    }
    // Close the write end so the reader's drain eventually returns 0 (EOF).
    pipeClose(&pipefs_dummy_ctx, &st_write);
    // falls through to threadExit
}

pub fn selfTest() void {
    if (!config.debug_log) return; // normal boot stays silent

    scheduler.setupMainForTest(); // adopt the boot context as thread 0 (like the other demos)

    if (!create(&st_read, &st_write)) {
        serial.log("[PIPE] self-test: could not allocate a pipe.\n", .{});
        return;
    }
    const pipe_id = endOf(&st_read).pipe_id; // remember the slot to confirm it's freed

    // Spawn the producer; it writes SELFTEST_N bytes then closes its end. No
    // preemption is needed: blocking yields cooperatively and each signal() readies
    // the other side, so the producer and this reader hand off until done.
    scheduler.spawn("pipeprod", &stProducer);

    // Drain the pipe from the read end. read() BLOCKS when the buffer is empty and
    // wakes when the producer writes; a final read after the writer closes returns 0.
    var total: usize = 0;
    var ok = true;
    var buf: [512]u8 = undefined;
    while (true) {
        const n = pipeRead(&pipefs_dummy_ctx, &st_read, &buf);
        if (n == 0) break; // EOF: empty AND the write end is closed
        // Verify each byte equals its absolute index mod 256 (the producer's pattern).
        var j: usize = 0;
        while (j < n) : (j += 1) {
            if (buf[j] != @as(u8, @truncate((total + j) & 0xFF))) ok = false;
        }
        total += n;
    }

    // Close the read end too. Both ends are now closed, so the pipe must be freed
    // (its pool slot returned for reuse) — confirmed by a fresh create() landing in
    // the SAME slot.
    pipeClose(&pipefs_dummy_ctx, &st_read);
    const freed = !pipes[pipe_id].in_use;
    var r2: vfs.OpenFile = undefined;
    var w2: vfs.OpenFile = undefined;
    const reused = create(&r2, &w2) and endOf(&r2).pipe_id == pipe_id;
    if (reused) { // tidy up the probe pipe (close both ends) so the slot is free again
        pipeClose(&pipefs_dummy_ctx, &w2);
        pipeClose(&pipefs_dummy_ctx, &r2);
    }

    if (ok and total == SELFTEST_N and freed and reused) {
        serial.log("[PIPE] self-test OK: wrote + read {d} bytes through a pipe, both ends closed\n", .{total});
    } else {
        serial.log("[PIPE] self-test FAILED (total={d} expected={d} ok={} freed={} reused={}).\n", .{ total, SELFTEST_N, ok, freed, reused });
    }
}

// === Inline unit tests (host, via src/tests.zig) =============================
// These exercise the pure ring-buffer + refcount logic on the host — no threads,
// no blocking (a single thread fills then drains, so neither side ever has to wait).
// They prove: create sets refcount 2 / one open writer; a same-thread fill-then-drain
// round-trips the exact bytes (including a wrap past the ring end); close decrements
// correctly and frees the slot at 0; clone (dup) bumps the count so the pipe survives;
// and EOF is reported only after the last write end closes.

const testing = std.testing;

// Reset the whole pool so each test starts from a clean slate (no leftover slots
// from a previous test, no stale wait-queue `pending`).
fn resetPoolForTest() void {
    pipes = [_]Pipe{.{}} ** MAX_PIPES;
}

// NOTE: the tests call the PURE cores (copyIn/copyOut/closeEnd/pipeClone) directly,
// NOT pipeRead/pipeWrite/pipeClose — those wrap the cores in WaitQueue signal/wait,
// whose cli/sti are privileged instructions that fault outside ring 0 (so they can't
// run on the host). The blocking wrappers add only the park/wake glue around these
// cores; the cores hold all the byte-moving + refcount logic worth unit-testing.

test "create allocates a pipe with refcount 2 and one open writer" {
    resetPoolForTest();
    var r: vfs.OpenFile = undefined;
    var w: vfs.OpenFile = undefined;
    try testing.expect(create(&r, &w));
    const id = endOf(&r).pipe_id;
    try testing.expectEqual(@as(u32, 2), pipes[id].refcount);
    try testing.expectEqual(@as(u32, 1), pipes[id].writers_open);
    try testing.expect(pipes[id].in_use);
    // The two ends share one pipe but point opposite directions.
    try testing.expectEqual(id, endOf(&w).pipe_id);
    try testing.expect(!endOf(&r).is_write);
    try testing.expect(endOf(&w).is_write);
}

test "same-thread fill then drain round-trips the exact bytes" {
    resetPoolForTest();
    var r: vfs.OpenFile = undefined;
    var w: vfs.OpenFile = undefined;
    try testing.expect(create(&r, &w));
    const p = &pipes[endOf(&r).pipe_id];
    // Fill then drain: copyIn stores the bytes, copyOut hands them straight back.
    const msg = "the quick brown fox jumps over the lazy dog";
    try testing.expectEqual(msg.len, copyIn(p, msg));
    var buf: [64]u8 = undefined;
    const rn = copyOut(p, &buf);
    try testing.expectEqual(msg.len, rn);
    try testing.expectEqualStrings(msg, buf[0..rn]);
    try testing.expectEqual(@as(usize, 0), p.count); // fully drained
}

test "copyIn stops at capacity and copyOut drains it all" {
    resetPoolForTest();
    var r: vfs.OpenFile = undefined;
    var w: vfs.OpenFile = undefined;
    try testing.expect(create(&r, &w));
    const p = &pipes[endOf(&r).pipe_id];
    // Asking to store MORE than the ring holds stores exactly PIPE_CAP and stops.
    var big: [PIPE_CAP + 100]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i & 0xFF);
    try testing.expectEqual(PIPE_CAP, copyIn(p, &big));
    try testing.expectEqual(PIPE_CAP, p.count);
    // A second store finds it full and adds nothing.
    try testing.expectEqual(@as(usize, 0), copyIn(p, "x"));
    // Drain it all back, verifying every byte.
    var out: [PIPE_CAP]u8 = undefined;
    try testing.expectEqual(PIPE_CAP, copyOut(p, &out));
    try testing.expectEqualSlices(u8, big[0..PIPE_CAP], &out);
}

test "the ring buffer wraps correctly around its end" {
    resetPoolForTest();
    var r: vfs.OpenFile = undefined;
    var w: vfs.OpenFile = undefined;
    try testing.expect(create(&r, &w));
    const p = &pipes[endOf(&r).pipe_id];
    // Pre-advance the positions to near the end of the ring so the next writes wrap.
    p.read_pos = PIPE_CAP - 4;
    p.write_pos = PIPE_CAP - 4;
    // Store 10 bytes: 4 land before the wrap, 6 after it.
    var src: [10]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);
    try testing.expectEqual(@as(usize, 10), copyIn(p, &src));
    try testing.expectEqual(@as(usize, 6), p.write_pos); // wrapped: (CAP-4 + 10) % CAP
    var buf: [10]u8 = undefined;
    try testing.expectEqual(@as(usize, 10), copyOut(p, &buf));
    try testing.expectEqualSlices(u8, &src, &buf); // bytes survived the wrap intact
}

test "close decrements the refcount and frees the slot at zero" {
    resetPoolForTest();
    var r: vfs.OpenFile = undefined;
    var w: vfs.OpenFile = undefined;
    try testing.expect(create(&r, &w));
    const id = endOf(&r).pipe_id;
    const p = &pipes[id];
    // Close the write end: refcount 2 -> 1, writers_open 1 -> 0, slot still in use.
    closeEnd(p, true);
    try testing.expectEqual(@as(u32, 1), p.refcount);
    try testing.expectEqual(@as(u32, 0), p.writers_open);
    try testing.expect(p.in_use);
    // Close the read end: refcount 1 -> 0, slot freed.
    closeEnd(p, false);
    try testing.expectEqual(@as(u32, 0), p.refcount);
    try testing.expect(!p.in_use);
}

test "clone (dup) bumps the refcount so the pipe survives an extra close" {
    resetPoolForTest();
    var r: vfs.OpenFile = undefined;
    var w: vfs.OpenFile = undefined;
    try testing.expect(create(&r, &w));
    const id = endOf(&w).pipe_id;
    const p = &pipes[id];
    // dup the write end: a second descriptor references it (refcount 2 -> 3, a second
    // open writer 1 -> 2). pipeClone touches no wait queue, so it's host-safe.
    var w2 = w; // dup copies the OpenFile...
    pipeClone(&pipefs_dummy_ctx, &w2); // ...then the syscall layer clones the new slot
    try testing.expectEqual(@as(u32, 3), p.refcount);
    try testing.expectEqual(@as(u32, 2), p.writers_open);
    // Closing ONE write end leaves a writer still open (writers_open 2 -> 1).
    closeEnd(p, true);
    try testing.expectEqual(@as(u32, 1), p.writers_open);
    try testing.expect(p.in_use); // not freed: a read end + two→one write end remain
}

test "EOF condition holds only after the last write end closes" {
    resetPoolForTest();
    var r: vfs.OpenFile = undefined;
    var w: vfs.OpenFile = undefined;
    try testing.expect(create(&r, &w));
    const p = &pipes[endOf(&r).pipe_id];
    // Buffer two bytes, then close the write end (writers_open -> 0).
    _ = copyIn(p, "hi");
    closeEnd(p, true);
    var buf: [8]u8 = undefined;
    // While bytes remain, read returns them (NOT EOF) — copyOut hands back the data.
    try testing.expectEqual(@as(usize, 2), copyOut(p, &buf));
    try testing.expectEqualStrings("hi", buf[0..2]);
    // Now the pipeRead EOF predicate (count == 0 AND writers_open == 0) is true, so a
    // further read would return 0 without blocking.
    try testing.expectEqual(@as(usize, 0), p.count);
    try testing.expectEqual(@as(u32, 0), p.writers_open);
}
