// Kernel heap: a std.mem.Allocator backed by the VMM.
//
// We reserve a dedicated virtual region and grow it on demand by mapping fresh
// physical frames (pmm.allocZeroed) into it (vmm.map). Over that region we run a
// sorted free-list allocator with coalescing.
//
// The std.mem.Allocator interface hands callers an arbitrarily-aligned pointer
// and, on free, gives back the slice but not the original block bounds. We
// bridge that by over-allocating a raw block, placing the aligned payload inside
// it, and stashing a small AllocHeader immediately before the payload that
// records the raw block's start and size. free() reads that header to return the
// exact block to the free list; resize()/remap() read it to see if the block has
// slack to grow in place.

const std = @import("std"); // std.mem.Allocator + containers in the self-test
const pmm = @import("pmm.zig"); // physical frames to back the heap
const vmm = @import("vmm.zig"); // to map those frames into the heap region
const serial = @import("../drivers/serial.zig"); // logging

const PAGE_SIZE: usize = 4096; // mapping granularity
const HEAP_BASE: usize = 0xffffc00000000000; // PML4 slot 384: clear of HHDM/kernel
const HEAP_MAX: usize = HEAP_BASE + 0x100000000; // 4 GiB cap on heap growth
const INITIAL_HEAP: usize = 0x10000; // map 64 KiB up front
const GROW_MIN: usize = 0x10000; // grow at least 64 KiB at a time

// A free block; its header lives in the free memory itself.
const Node = struct {
    size: usize, // total bytes of this block, including this header
    next: ?*Node, // next free block (list is sorted by address)
};

// Written just before each returned allocation so free() can recover the block.
const AllocHeader = struct {
    block: usize, // start address of the raw block this allocation came from
    block_size: usize, // size of that raw block (to return to the free list)
};

var head: Node = .{ .size = 0, .next = null }; // dummy list head (head.next = first free block)
var heap_end: usize = HEAP_BASE; // current mapped extent (grows upward)
var total_mapped: usize = 0; // total bytes mapped into the heap region
var heap_ctx: u8 = 0; // a stable, non-null vtable context pointer

// Round `x` up to a multiple of `a` (a is a power of two).
fn alignUp(x: usize, a: usize) usize {
    return (x + a - 1) & ~(a - 1);
}

// --- Growing the mapped region ----------------------------------------------
// Map more physical frames at the top of the heap and donate them to the free list.
fn grow(min_bytes: usize) bool {
    const bytes = alignUp(@max(min_bytes, GROW_MIN), PAGE_SIZE); // at least GROW_MIN, page-rounded
    if (heap_end + bytes > HEAP_MAX) return false; // would exceed the cap
    var off: usize = 0; // offset within the new region
    while (off < bytes) : (off += PAGE_SIZE) { // map it a page at a time
        const frame = pmm.allocZeroed() orelse return false; // get a physical frame
        vmm.map(heap_end + off, frame, vmm.FLAG_WRITE | vmm.FLAG_NX); // map it RW + non-exec (data)
    }
    rawFree(heap_end, bytes); // hand the new region to the free list
    heap_end += bytes; // advance the mapped extent
    total_mapped += bytes; // track total mapped
    return true;
}

// --- Raw block free list (alignment-agnostic) -------------------------------
const Block = struct { addr: usize, size: usize }; // an allocated raw block

// First-fit allocate a raw block of at least `size` bytes from the free list.
fn rawAlloc(size: usize) ?Block {
    const need = alignUp(@max(size, @sizeOf(Node)), @alignOf(Node)); // min block size, aligned
    var prev: *Node = &head; // node before `curr` (starts at dummy head)
    var curr = head.next; // first real free block
    while (curr) |c| { // walk the free list
        if (c.size >= need) { // big enough?
            if (c.size - need >= @sizeOf(Node)) {
                // Split: allocate the front `need` bytes, keep the remainder.
                const addr = @intFromPtr(c); // start of the block we hand out
                const rem: *Node = @ptrFromInt(addr + need); // remainder node sits after it
                rem.size = c.size - need; // remainder size
                rem.next = c.next; // remainder takes c's place in the list
                prev.next = rem;
                return .{ .addr = addr, .size = need };
            }
            // Remainder too small to track: hand out the whole block.
            prev.next = c.next; // unlink c entirely
            return .{ .addr = @intFromPtr(c), .size = c.size };
        }
        prev = c; // advance
        curr = c.next;
    }
    return null; // nothing big enough
}

// Return a raw block to the free list, coalescing with neighbours.
fn rawFree(addr: usize, size: usize) void {
    const node: *Node = @ptrFromInt(addr); // write a Node header into the freed block
    node.size = size;

    // Insert keeping the list sorted by address.
    var prev: *Node = &head; // last node with address < addr
    var curr = head.next; // first node with address > addr (eventually)
    while (curr) |c| {
        if (@intFromPtr(c) > addr) break; // found the insertion point
        prev = c;
        curr = c.next;
    }
    node.next = curr; // link node between prev and curr
    prev.next = node;

    // Coalesce forward (node + next) if they're physically adjacent.
    if (curr) |c| {
        if (addr + size == @intFromPtr(c)) { // node ends exactly where c begins
            node.size += c.size; // absorb c
            node.next = c.next;
        }
    }
    // Coalesce backward (prev + node), but never into the dummy head.
    if (prev != &head and @intFromPtr(prev) + prev.size == addr) { // prev ends where node begins
        prev.size += node.size; // absorb node into prev
        prev.next = node.next;
    }
}

// --- Allocator bridge --------------------------------------------------------
// Recover the header stashed just before a payload pointer.
fn headerOf(payload: usize) *AllocHeader {
    return @ptrFromInt(payload - @sizeOf(AllocHeader));
}

// How many bytes are available from the payload to the end of its raw block.
fn capacityOf(memory: []u8) usize {
    const payload = @intFromPtr(memory.ptr); // the returned pointer
    const hdr = headerOf(payload); // its header
    return hdr.block + hdr.block_size - payload; // bytes from payload to block end
}

// Allocator.alloc: get a raw block, place an aligned payload inside it, stash a header.
fn vtAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const req = alignment.toByteUnits(); // requested alignment in bytes
    // Overflow guard: an absurd `len` (or `req`) could make the header+align+len
    // sum below wrap around the usize space and produce a tiny `need`, handing
    // out a block far smaller than asked. Reject anything that cannot possibly
    // fit in the heap region BEFORE doing the arithmetic that could wrap. The
    // heap can never serve a block larger than its whole span, so this rejects
    // no real allocation. The comparisons are written so the check itself can't
    // overflow: each subtraction's left side is proven >= its right side first.
    const HEAP_SPAN: usize = HEAP_MAX - HEAP_BASE; // largest a block could ever be
    if (len > HEAP_SPAN) return null; // payload alone won't fit
    if (req > HEAP_SPAN - len) return null; // payload + worst-case padding won't fit
    if (@sizeOf(AllocHeader) > HEAP_SPAN - len - req) return null; // + header won't fit
    const need = @sizeOf(AllocHeader) + req + len; // worst-case raw size (header + padding + data)
    var blk = rawAlloc(need); // try the free list
    if (blk == null) { // out of free space?
        if (!grow(need)) return null; // map more, or give up
        blk = rawAlloc(need); // retry
    }
    const b = blk orelse return null; // the raw block
    const payload = alignUp(b.addr + @sizeOf(AllocHeader), req); // aligned payload after the header
    const hdr = headerOf(payload); // header sits just before the payload
    hdr.block = b.addr; // record block bounds so free() can reconstruct
    hdr.block_size = b.size;
    return @ptrFromInt(payload); // hand back the aligned pointer
}

// Allocator.resize: can the existing block hold new_len bytes in place?
fn vtResize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    return capacityOf(memory) >= new_len;
}

// Allocator.remap: like resize, but returns the pointer (same one) if it fits, else null.
fn vtRemap(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    return if (capacityOf(memory) >= new_len) memory.ptr else null;
}

// Allocator.free: return the original raw block (from the header) to the free list.
fn vtFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    const hdr = headerOf(@intFromPtr(memory.ptr)); // recover block bounds
    rawFree(hdr.block, hdr.block_size); // free the whole raw block
}

// The vtable wiring our four functions into the std allocator interface.
const vtable = std.mem.Allocator.VTable{
    .alloc = vtAlloc,
    .resize = vtResize,
    .remap = vtRemap,
    .free = vtFree,
};

// Hand out a std.mem.Allocator that any std code can use.
pub fn allocator() std.mem.Allocator {
    return .{ .ptr = &heap_ctx, .vtable = &vtable };
}

// --- Self-test ---------------------------------------------------------------
// Exercise the real std.mem.Allocator paths: create/destroy, a slice, and an
// ArrayList (which drives alloc -> resize/remap -> free).
fn selfTest() void {
    const a = allocator(); // our allocator

    const node = a.create(u64) catch return; // single-object allocation
    node.* = 0xDEADBEEFCAFEBABE; // write through it
    const c1 = node.* == 0xDEADBEEFCAFEBABE; // read it back
    a.destroy(node); // free it

    const buf = a.alloc(u8, 4096) catch return; // a 4 KiB slice
    @memset(buf, 0xAB); // fill it
    const c2 = buf[0] == 0xAB and buf[4095] == 0xAB; // check both ends
    a.free(buf); // free it

    var list = std.ArrayList(u32).init(a); // a growable list using our allocator
    defer list.deinit(); // free it when we return
    var sum: u64 = 0; // expected sum 0+1+...+999
    for (0..1000) |i| {
        list.append(@intCast(i)) catch return; // grows the backing buffer as needed
        sum += i;
    }
    var got: u64 = 0; // actual sum of stored items
    for (list.items) |v| got += v;
    const c3 = list.items.len == 1000 and got == sum; // length + contents correct

    serial.log("[HEAP]     create/destroy={}, slice={}, ArrayList={}\n", .{ c1, c2, c3 });
}

pub fn init() void {
    head.next = null; // empty free list
    heap_end = HEAP_BASE; // nothing mapped yet
    total_mapped = 0;

    if (!grow(INITIAL_HEAP)) { // map the initial 64 KiB
        while (true) asm volatile ("cli; hlt");
    }

    selfTest(); // prove the allocator works with real std containers

    serial.log("[HEAP] Kernel heap initialized.\n", .{});
}
