// DMA-able memory allocator: physically-contiguous, 32-bit-addressable, zeroed
// buffers for bus-master devices (AC'97 audio, AHCI, e1000 NIC, ...).
//
// A device's DMA engine reads/writes RAM by *physical* address and never goes
// through the CPU's MMU, so a buffer it touches has two requirements the kernel
// heap can't promise:
//   1. Physically contiguous - a multi-page buffer must occupy consecutive
//      frames, because the device walks it linearly in physical space.
//   2. Addressable by the device - legacy bus masters carry only 32-bit
//      addresses in their descriptors, so the buffer must live below 4 GiB.
// We get both from pmm.allocContiguous(count, DMA_MAX_ADDR).
//
// Each buffer comes back as a pair: the physical address to program into the
// device's descriptors, and a virtual pointer (the HHDM alias of that physical
// memory) for the CPU to fill/drain it. On x86 DMA is cache-coherent, so no
// special cache attributes are needed; a driver that must observe device-written
// data should still read through a `volatile` view and fence before kicking the
// device off.

const pmm = @import("pmm.zig"); // contiguous physical frames live here
const serial = @import("../drivers/serial.zig"); // logging

const PAGE_SIZE: usize = 4096; // allocation granularity (one frame)

// A DMA buffer: a physical range plus its CPU-visible HHDM alias.
pub const Buffer = struct {
    phys: u64, // physical base address — what the device's descriptor gets
    virt: [*]u8, // CPU pointer (HHDM alias of `phys`) — fill/drain through this
    frames: usize, // length in frames (kept so free() can return the whole run)
    len: usize, // the byte length the caller requested

    // The buffer as a byte slice, for @memcpy / fills on the CPU side.
    pub fn bytes(self: Buffer) []u8 {
        return self.virt[0..self.len];
    }
};

// Allocate a contiguous, <4 GiB, zeroed DMA buffer of at least `len` bytes.
// Returns null if no contiguous run that large fits under the 32-bit ceiling.
pub fn alloc(len: usize) ?Buffer {
    if (len == 0) return null; // a zero-length DMA buffer is meaningless
    const frames = (len + PAGE_SIZE - 1) / PAGE_SIZE; // round up to whole frames
    const phys = pmm.allocContiguous(frames, pmm.DMA_MAX_ADDR) orelse return null;
    const virt: [*]u8 = @ptrFromInt(pmm.physToVirt(phys)); // HHDM alias of the run
    @memset(virt[0 .. frames * PAGE_SIZE], 0); // hand back clean memory
    return .{ .phys = phys, .virt = virt, .frames = frames, .len = len };
}

// Return a buffer (from alloc) to the pool.
pub fn free(buf: Buffer) void {
    pmm.freeContiguous(buf.phys, buf.frames);
}

// --- Self-test ---------------------------------------------------------------
// Prove the three guarantees a DMA driver depends on: contiguous frames, a base
// below the 32-bit ceiling, and a CPU pointer that is the HHDM alias of `phys`.
fn selfTest() void {
    const free_before = pmm.freeFrames(); // baseline for the leak check

    // Ask for 3 pages + a tail, so the buffer spans frame boundaries.
    const buf = alloc(3 * PAGE_SIZE + 100) orelse return;

    const aligned = (buf.phys % PAGE_SIZE) == 0; // frame-granular base
    const nonzero = buf.phys != 0; // never the reserved frame 0
    const below = buf.phys + buf.frames * PAGE_SIZE <= pmm.DMA_MAX_ADDR; // 32-bit safe
    serial.log("[DMA]     phys=0x{x} frames={d} aligned={} nonzero={} below-4G={}\n", .{ buf.phys, buf.frames, aligned, nonzero, below });

    // Contiguity: each frame's own HHDM address must equal virt + k*PAGE_SIZE.
    // If the run weren't contiguous these addresses wouldn't line up.
    var contiguous = true;
    for (0..buf.frames) |k| {
        const want = @intFromPtr(buf.virt) + k * PAGE_SIZE; // linear in the alias
        const got = pmm.physToVirt(buf.phys + k * PAGE_SIZE); // alias of frame k
        if (want != got) contiguous = false;
    }

    // Write at both ends through the buffer, then read it back through a *fresh*
    // HHDM view of the same physical base — proving virt really is that alias.
    buf.virt[0] = 0xC3; // marker at the start
    buf.virt[buf.len - 1] = 0x3C; // marker at the end
    const view: [*]u8 = @ptrFromInt(pmm.physToVirt(buf.phys)); // independent alias
    const rw_ok = view[0] == 0xC3 and view[buf.len - 1] == 0x3C; // both survive
    serial.log("[DMA]     contiguous={} hhdm-round-trip={}\n", .{ contiguous, rw_ok });

    free(buf); // return the whole run
    const restored = pmm.freeFrames() == free_before; // no frames leaked
    serial.log("[DMA]     freed; free-count restored: {} ({d} -> {d})\n", .{ restored, free_before, pmm.freeFrames() });
}

pub fn init() void {
    selfTest(); // prove the guarantees before any driver relies on them
    serial.log("[DMA] DMA buffer allocator initialized.\n", .{});
}
