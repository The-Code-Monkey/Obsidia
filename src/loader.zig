// Program loader: read a flat "init" binary off the FAT32 disk, make it
// executable in memory, run it, and tear it back down.
//
// THE BINARY CONTRACT (flat binary, "version 0" — deliberately the simplest
// format that can possibly work; a real ELF loader can replace this later
// without changing the load pipeline below):
//
//   - The file is raw x86-64 machine code. No header, no sections, no
//     relocations: byte 0 of the file is the first instruction executed.
//   - It is loaded at the fixed virtual address LOAD_BASE, so even position-
//     dependent code works (RIP-relative code is still encouraged).
//   - It runs in ring 0 (kernel privilege — we have no user mode yet) on the
//     caller's stack, interrupts enabled, and is called like a C function:
//     it must preserve callee-saved registers and finish with `ret`.
//   - It returns a u64 in rax. A well-behaved init returns INIT_MAGIC, which
//     lets the kernel tell "ran to completion" apart from "crashed into a
//     stray ret with garbage in rax".
//
// W^X is preserved at every instant: the destination pages are mapped
// WRITABLE + NO-EXECUTE while the file bytes are copied in, then flipped to
// READ-ONLY + EXECUTABLE before we jump. No page is ever writable and
// executable at the same time.

const std = @import("std");
const serial = @import("drivers/serial.zig"); // logging
const fat32 = @import("fs/fat32.zig"); // readFile: the disk -> memory path
const pmm = @import("mm/pmm.zig"); // physical frames backing the image
const vmm = @import("mm/vmm.zig"); // mapping those frames at LOAD_BASE

// Where the binary is loaded and entered. This is PML4 slot 416 (0xffffd...):
// a top-level slot of its own, comfortably away from the HHDM (slots 256+),
// the kernel heap (slot 384, 0xffffc...) and the kernel image (slot 511).
pub const LOAD_BASE: u64 = 0xffffd00000000000;

// The "ran to completion" value an init binary returns in rax.
pub const INIT_MAGIC: u64 = 0xB017B007;

const PAGE_SIZE: u64 = pmm.PAGE_SIZE; // 4 KiB, same as the PMM's frames
const MAX_PAGES: usize = 256; // 1 MiB cap — plenty for a bare-metal init

// The physical frame behind each mapped page, remembered so teardown can give
// them back. Static (not heap) so the loader has no allocator dependency.
var frames: [MAX_PAGES]u64 = undefined;

// Unmap the first `n` pages of the image and return their frames to the PMM.
// Used both for normal teardown and to unwind a half-built failed load.
fn teardown(n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        vmm.unmap(LOAD_BASE + i * PAGE_SIZE); // drop the mapping (+ its TLB entry)
        pmm.free(frames[i]); // give the frame back
    }
}

// Load the flat binary at `path` and run it. Returns true only if it loaded,
// ran, and came back with INIT_MAGIC. Safe to call repeatedly: each call maps
// a fresh image and unmaps it again afterwards.
pub fn exec(path: []const u8) bool {
    if (!fat32.isMounted()) {
        serial.print("[LOADER] no filesystem mounted.\n", .{});
        return false;
    }
    const node = fat32.resolve(path) orelse { // does the file exist?
        serial.print("[LOADER] no such file: {s}\n", .{path});
        return false;
    };
    if (node.is_dir) {
        serial.print("[LOADER] {s} is a directory.\n", .{path});
        return false;
    }
    if (node.size == 0) { // nothing to run
        serial.print("[LOADER] {s} is empty.\n", .{path});
        return false;
    }
    const pages: usize = @intCast((node.size + PAGE_SIZE - 1) / PAGE_SIZE); // round up to whole pages
    if (pages > MAX_PAGES) {
        serial.print("[LOADER] {s} is too big ({d} bytes; cap is {d} pages).\n", .{ path, node.size, MAX_PAGES });
        return false;
    }
    serial.print("[LOADER] Loading {s}: {d} bytes -> {d} page(s) at 0x{x}.\n", .{ path, node.size, pages, LOAD_BASE });

    // Stage 1: back the image with fresh zeroed frames, mapped WRITABLE but
    // NO-EXECUTE — we're about to write file bytes into them, and W^X says a
    // page being written must not be executable.
    var i: usize = 0;
    while (i < pages) : (i += 1) {
        frames[i] = pmm.allocZeroed() orelse {
            serial.print("[LOADER] out of physical memory at page {d}.\n", .{i});
            teardown(i); // unwind the pages mapped so far
            return false;
        };
        vmm.map(LOAD_BASE + i * PAGE_SIZE, frames[i], vmm.FLAG_WRITE | vmm.FLAG_NX);
    }

    // Stage 2: read the file from disk straight into the mapped pages — the
    // whole point of the storage stack: sectors -> FAT chain -> these bytes.
    const dst = @as([*]u8, @ptrFromInt(LOAD_BASE))[0 .. pages * PAGE_SIZE];
    const got = fat32.readFile(path, dst) orelse {
        serial.print("[LOADER] disk read failed for {s}.\n", .{path});
        teardown(pages);
        return false;
    };
    // A short read means the cluster chain ended before the file's declared
    // size (a truncated or corrupt file); readFile reports this as a byte count
    // below node.size rather than an error. Running a partially-loaded image
    // would execute garbage, so refuse and unwind instead.
    if (got != node.size) {
        serial.print("[LOADER] short read for {s}: got {d} of {d} bytes.\n", .{ path, got, node.size });
        teardown(pages);
        return false;
    }
    serial.print("[LOADER]   copied {d} bytes (pages RW+NX while writing).\n", .{got});

    // Stage 3: flip every page to READ-ONLY + EXECUTABLE. vmm.map overwrites
    // the existing leaf entry and flushes its TLB entry; flags=0 means
    // present, not writable, and (no NX bit) executable.
    i = 0;
    while (i < pages) : (i += 1) {
        vmm.map(LOAD_BASE + i * PAGE_SIZE, frames[i], 0);
    }
    serial.print("[LOADER]   remapped RX read-only (W^X held at every step).\n", .{});

    // Stage 4: jump in. The contract says "entry at offset 0, C calling
    // convention, u64 result in rax" — so the load address, viewed as a
    // function pointer, IS the program. (Anything it prints goes straight to
    // the COM1 port, bypassing our serial driver and its framebuffer mirror.)
    serial.print("[LOADER]   calling entry point 0x{x}...\n", .{LOAD_BASE});
    const entry: *const fn () callconv(.C) u64 = @ptrFromInt(LOAD_BASE);
    const ret = entry(); // the init binary runs here, then rets back to us

    const ok = ret == INIT_MAGIC;
    if (ok) {
        serial.print("[LOADER]   init returned 0x{x} (magic OK).\n", .{ret});
    } else {
        serial.print("[LOADER]   init returned 0x{x} (expected magic 0x{x}).\n", .{ ret, INIT_MAGIC });
    }

    // Stage 5: the program is done — unmap the image and free its frames so
    // repeated execs don't leak memory.
    teardown(pages);
    serial.print("[LOADER]   image unmapped, {d} frame(s) freed.\n", .{pages});
    return ok;
}

// --- Boot self-test ----------------------------------------------------------
// If the mounted disk carries an /INIT binary, load and run it — proving the
// full pipeline (disk -> FAT32 -> mapped memory -> executed code -> clean
// return) end to end. Skips quietly when there's no disk or no /INIT, so
// disk-less boots are unaffected.
pub fn selfTest() void {
    serial.print("[LOADER] Init-loader self-test (exec /INIT)...\n", .{});
    if (!fat32.isMounted()) {
        serial.print("[LOADER] self-test skipped (no filesystem mounted).\n", .{});
        return;
    }
    if (fat32.resolve("/INIT") == null) {
        serial.print("[LOADER] self-test skipped (no /INIT on the disk).\n", .{});
        return;
    }
    if (exec("/INIT")) {
        serial.print("[LOADER] init ran and exited cleanly.\n", .{});
    } else {
        serial.print("[LOADER] init FAILED.\n", .{});
    }
}
