// Physical memory manager: a bitmap frame allocator over Limine's memory map.
//
// Limine hands us a memory map (an array of base/length/type regions) and a
// Higher-Half Direct Map (HHDM): a region of virtual address space where all of
// physical RAM is linearly mapped at `hhdm_offset + phys`. Since paging is
// already on, we can only touch physical memory *through* the HHDM.
//
// We manage RAM in 4 KiB frames with one bit each (0 = free, 1 = used). The
// bitmap itself needs storage before we can allocate anything, so we bootstrap
// it into the first usable region large enough to hold it, then immediately
// mark those frames used.

const limine = @import("limine"); // memory-map types
const serial = @import("../drivers/serial.zig"); // logging

pub const PAGE_SIZE: usize = 4096; // one physical frame = 4 KiB

// 32-bit DMA ceiling: legacy bus-master devices (AC'97, e1000, many AHCI) carry
// only 32-bit physical addresses in their descriptors, so any buffer they touch
// must live below 4 GiB. DMA buffers are allocated with this as the max address.
pub const DMA_MAX_ADDR: u64 = 0x100000000; // 4 GiB

var hhdm: u64 = 0; // HHDM offset (virtual = hhdm + physical)
var bitmap: [*]u8 = undefined; // the allocation bitmap (1 bit per frame)
var bitmap_size: usize = 0; // bitmap length in bytes
var bitmap_phys: u64 = 0; // physical address the bitmap lives at
var total_frames: usize = 0; // number of frames the bitmap covers
var used_frames: usize = 0; // how many frames are currently allocated/reserved
var highest_addr: u64 = 0; // top of the highest usable region
var next_hint: usize = 0; // where the next alloc scan starts (a small speedup)
var ready: bool = false; // true once init succeeded

// Bootloader-reclaimable regions, recorded at init. We can't re-read the memory
// map later (it lives in this very memory), so we save the regions now and free
// them in reclaimBootloader() once nothing depends on them anymore.
const Region = struct { base: u64, length: u64 };
const MAX_RECLAIM = 64;
var reclaim_regions: [MAX_RECLAIM]Region = undefined;
var reclaim_count: usize = 0;

// Translate a physical address to its HHDM virtual address.
pub inline fn physToVirt(phys: u64) u64 {
    return hhdm + phys;
}

// --- Bitmap primitives -------------------------------------------------------
// Frame N is bit (N % 8) of byte (N / 8).
fn bitTest(frame: usize) bool {
    return (bitmap[frame / 8] & (@as(u8, 1) << @intCast(frame % 8))) != 0; // is the bit set?
}
fn bitSet(frame: usize) void {
    bitmap[frame / 8] |= (@as(u8, 1) << @intCast(frame % 8)); // mark used
}
fn bitClear(frame: usize) void {
    bitmap[frame / 8] &= ~(@as(u8, 1) << @intCast(frame % 8)); // mark free
}

// Free/reserve a single frame, keeping the used-frame count consistent and
// idempotent (so overlapping passes don't double-count).
fn markFree(frame: usize) void {
    if (bitTest(frame)) { // only act if currently used
        bitClear(frame);
        used_frames -= 1;
    }
}
fn markUsed(frame: usize) void {
    if (!bitTest(frame)) { // only act if currently free
        bitSet(frame);
        used_frames += 1;
    }
}

// --- Allocation --------------------------------------------------------------
// Returns a physical frame address, or null on out-of-memory. Never returns 0
// (frame 0 is permanently reserved so a valid result can't look like null).
pub fn alloc() ?u64 {
    if (!ready) return null; // PMM not initialized
    var i = next_hint; // start scanning from the hint (a frame index)
    var scanned: usize = 0; // how many frames we've examined (caps at one sweep)
    // Scan a BYTE (8 frames) at a time instead of bit-by-bit. A byte equal to
    // 0xFF means all 8 of its frames are used, so we skip it with a single
    // comparison; otherwise we locate the first free frame inside it with a
    // bit-twiddle (@ctz on the inverted byte = index of the lowest 0 bit). This
    // turns long runs of allocated frames from 8 bit-tests into one byte read.
    while (scanned < total_frames) { // at most one full sweep over every frame
        if (i >= total_frames) i = 0; // wrap around to the start
        // Try to fast-path a whole byte only when `i` sits on a byte boundary
        // AND the entire byte's 8 frames are in range. The final partial byte
        // at `total_frames` (and any mid-byte hint) falls through to per-bit.
        if (i % 8 == 0 and i + 8 <= total_frames) {
            const byte = bitmap[i / 8]; // the 8 frames starting at `i`
            if (byte == 0xFF) { // all 8 used: skip the whole byte at once
                i += 8;
                scanned += 8; // examined 8 frames' worth
                continue;
            }
            // At least one bit is 0 (free). ~byte sets those free bits; @ctz
            // gives the index of the lowest set bit = first free frame in range.
            const bit: usize = @ctz(~byte); // 0..7, guaranteed valid since byte != 0xFF
            const frame = i + bit; // absolute frame index of that free frame
            bitSet(frame); // claim it
            used_frames += 1;
            next_hint = frame + 1; // next search starts just past it
            return @as(u64, frame) * PAGE_SIZE; // frame index -> physical address
        }
        // Slow path: not byte-aligned, or the final partial byte near
        // total_frames. Test this single frame.
        if (!bitTest(i)) { // found a free frame
            bitSet(i); // claim it
            used_frames += 1;
            next_hint = i + 1; // next search starts just past it
            return @as(u64, i) * PAGE_SIZE; // frame index -> physical address
        }
        i += 1; // this frame was used — try the next one
        scanned += 1; // examined one more frame
    }
    return null; // swept everything, none free
}

// Allocate a frame and zero it through the HHDM. Page tables (VMM step) require
// freshly-zeroed frames, so this is the form they'll use.
pub fn allocZeroed() ?u64 {
    const frame = alloc() orelse return null; // get a frame (or fail)
    const ptr: [*]u8 = @ptrFromInt(physToVirt(frame)); // view it via the HHDM
    @memset(ptr[0..PAGE_SIZE], 0); // zero all 4 KiB
    return frame;
}

// Return a frame to the pool.
pub fn free(phys: u64) void {
    const frame = phys / PAGE_SIZE; // address -> frame index
    if (frame >= total_frames) return; // out of range, ignore
    if (bitTest(frame)) { // only if it was actually used
        bitClear(frame);
        used_frames -= 1;
    }
    if (frame < next_hint) next_hint = frame; // bias the next scan toward freed space
}

// --- Contiguous allocation (for DMA) ----------------------------------------
// A device's bus-master DMA engine reads/writes memory by *physical* address
// without going through the MMU, so a multi-page buffer it touches must occupy
// physically-contiguous frames. The single-frame alloc() above gives no such
// guarantee, so DMA drivers come through here instead.
//
// Allocate `count` consecutive free frames, all strictly below `max_phys`
// (pass DMA_MAX_ADDR for the 32-bit ceiling). Returns the base physical address
// of the run, or null if no run that long fits under the ceiling. The frames are
// NOT zeroed — the DMA wrapper does that through the HHDM.
pub fn allocContiguous(count: usize, max_phys: u64) ?u64 {
    if (!ready or count == 0) return null; // PMM down or nonsense request
    // Highest frame index we may hand out: the lower of "what RAM exists" and
    // "what the device can address". A run must end at or before this.
    const ceiling = @min(total_frames, max_phys / PAGE_SIZE);
    var base: usize = 1; // never start a run at frame 0 (permanently reserved)
    while (base + count <= ceiling) { // room for a full run below the ceiling?
        var i: usize = 0; // probe the candidate run frame by frame
        while (i < count) : (i += 1) {
            if (bitTest(base + i)) break; // hit a used frame: this run is dead
        }
        if (i == count) { // all `count` frames were free — claim the whole run
            for (0..count) |k| bitSet(base + k); // mark each frame used
            used_frames += count; // keep the count consistent
            return @as(u64, base) * PAGE_SIZE; // base frame index -> physical addr
        }
        base += i + 1; // restart just past the used frame we tripped on
    }
    return null; // no contiguous run of that size fits under the ceiling
}

// Return a contiguous run (as handed out by allocContiguous) to the pool.
pub fn freeContiguous(phys: u64, count: usize) void {
    const start = phys / PAGE_SIZE; // address -> first frame index
    for (0..count) |i| { // free each frame in the run
        const frame = start + i;
        if (frame >= total_frames) break; // out of range, stop
        if (bitTest(frame)) { // only if it was actually used
            bitClear(frame);
            used_frames -= 1;
        }
    }
    if (start < next_hint) next_hint = start; // bias the next scan toward freed space
}

// Stats accessors used for logging / the VMM.
pub fn freeFrames() usize {
    return total_frames - used_frames;
}
pub fn totalFrames() usize {
    return total_frames;
}
pub fn highestAddress() u64 {
    return highest_addr;
}

// Return bootloader-reclaimable memory (Limine's structures, old page tables,
// boot stack, etc.) to the allocator. MUST be called only after the kernel no
// longer touches anything Limine left there — in particular, after switching
// off Limine's boot stack, which lives in this memory.
pub fn reclaimBootloader() void {
    if (!ready) return;
    serial.print("[PMM] Reclaiming bootloader-reclaimable memory...\n", .{});
    for (reclaim_regions[0..reclaim_count]) |r| { // free each recorded region
        const start = r.base / PAGE_SIZE;
        const count = r.length / PAGE_SIZE;
        for (0..count) |i| {
            const frame = start + i;
            if (frame < total_frames) markFree(frame); // (bounds guard, just in case)
        }
    }
    // Belt and braces: never hand out frame 0 or the bitmap's own frames (a
    // reclaim region shouldn't overlap them, but markUsed is idempotent).
    markUsed(0);
    const bm_start = bitmap_phys / PAGE_SIZE;
    const bm_frames = (bitmap_size + PAGE_SIZE - 1) / PAGE_SIZE;
    for (0..bm_frames) |i| markUsed(bm_start + i);
}

// --- Self-test ---------------------------------------------------------------
// Proves alloc/free bookkeeping and HHDM read/write before anything depends on
// the PMM.
fn selfTest() void {
    const free_before = freeFrames(); // remember the starting free count
    const a = alloc() orelse return; // first allocation
    const b = alloc().?; // second
    const c = alloc().?; // third

    // Write a pattern through the HHDM and read it back (exercises the HHDM alias).
    const p: [*]volatile u8 = @ptrFromInt(physToVirt(a)); // view frame `a` via HHDM
    p[0] = 0xA5; // write a marker at the start
    p[PAGE_SIZE - 1] = 0x5A; // and another at the end

    free(a); // return all three frames
    free(b);
    free(c);
    const restored = freeFrames() == free_before; // free count should be back to start
    serial.print("[PMM]     freed; free-count restored: {} ({d} -> {d})\n", .{ restored, free_before, freeFrames() });
}

pub fn init(memmap: *limine.MemoryMapResponse, hhdm_offset: u64) void {
    hhdm = hhdm_offset; // remember the HHDM offset

    const entries = memmap.getEntries(); // slice of memory-map regions
    for (entries) |e| { // walk every region
        // The bitmap must cover every frame we might ever hand out — that
        // includes bootloader-reclaimable regions, which we free later (and one
        // of which can sit ABOVE the highest usable region).
        if (e.type == .usable or e.type == .bootloader_reclaimable) {
            const top = e.base + e.length; // end of this region
            if (top > highest_addr) highest_addr = top; // track the highest
        }
        // Record reclaimable regions so reclaimBootloader() can free them later.
        if (e.type == .bootloader_reclaimable and reclaim_count < MAX_RECLAIM) {
            reclaim_regions[reclaim_count] = .{ .base = e.base, .length = e.length };
            reclaim_count += 1;
        }
    }

    total_frames = highest_addr / PAGE_SIZE; // frames the bitmap must cover
    bitmap_size = (total_frames + 7) / 8; // bytes needed (round up to whole bytes)

    // Bootstrap: place the bitmap in a usable region big enough. Prefer one at
    // or above 1 MiB to keep low memory free (and because a legitimate region
    // can start at physical 0, so we can't use 0 as a "not found" sentinel).
    var found = false;
    for (entries) |e| { // first pass: prefer >= 1 MiB
        if (e.type == .usable and e.base >= 0x100000 and e.length >= bitmap_size) {
            bitmap_phys = e.base;
            found = true;
            break;
        }
    }
    if (!found) {
        // Fall back to any usable region big enough, including low memory.
        for (entries) |e| {
            if (e.type == .usable and e.length >= bitmap_size) {
                bitmap_phys = e.base;
                found = true;
                break;
            }
        }
    }
    if (!found) { // no region can hold the bitmap (won't happen on real machines)
        return;
    }
    bitmap = @ptrFromInt(physToVirt(bitmap_phys)); // access the bitmap via the HHDM

    // Everything used, then free the usable regions.
    @memset(bitmap[0..bitmap_size], 0xFF); // start with all frames marked used
    used_frames = total_frames; // account for that
    for (entries) |e| { // now free every usable region
        if (e.type != .usable) continue; // skip non-RAM
        const start = e.base / PAGE_SIZE; // first frame of the region
        const count = e.length / PAGE_SIZE; // how many frames
        for (0..count) |i| markFree(start + i); // mark each one free
    }

    // Reserve the bitmap's own frames and frame 0.
    const bm_start = bitmap_phys / PAGE_SIZE; // first frame the bitmap occupies
    const bm_frames = (bitmap_size + PAGE_SIZE - 1) / PAGE_SIZE; // how many frames it spans
    for (0..bm_frames) |i| markUsed(bm_start + i); // don't hand out the bitmap's storage
    markUsed(0); // keep physical frame 0 reserved (so alloc never returns 0)

    ready = true; // the PMM is now usable

    selfTest(); // prove alloc/free + HHDM access work

    serial.print("[PMM] Physical memory manager initialized.\n", .{});
}
