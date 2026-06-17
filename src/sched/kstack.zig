// Guarded kernel stacks.
//
// Each thread needs a kernel stack (for its own execution, and — since
// applyContext points TSS.rsp0 / the syscall stack at it — for the traps and
// syscalls it takes). Previously these came from the heap, packed against other
// heap objects: a stack overflow silently scribbled over a neighbour and the
// corruption surfaced later, somewhere unrelated.
//
// Instead we give every thread its own slot in a dedicated virtual region, laid
// out as one UNMAPPED guard page immediately below STACK_SIZE of mapped stack:
//
//     slot i:  [ guard page (unmapped) ][ STACK_SIZE mapped, RW + NX ]
//              ^REGION + i*SLOT          ^bottom                       ^top
//
// The stack grows DOWN from `top`. If it overflows past `bottom` it runs into the
// guard page, which has no mapping, so the very next push faults (#PF) — the IDT
// turns that into a readable register dump + halt, right at the overflow, instead
// of corrupting the heap or the adjacent thread. There is no free path: a slot
// maps lazily on first use and stays mapped for the rest of the boot; alloc() is
// idempotent, so a reused thread id hands back the same stack rather than leaking
// the old frames.

const pmm = @import("../mm/pmm.zig"); // physical frames for the stack pages
const vmm = @import("../mm/vmm.zig"); // map the pages / verify the guard
const serial = @import("../drivers/serial.zig"); // self-test logging

const PAGE: usize = 4096;
pub const STACK_SIZE: usize = 32 * 1024; // mapped stack bytes per thread (matches the old heap size)
const GUARD: usize = PAGE; // one unmapped page below each stack
const SLOT: usize = GUARD + STACK_SIZE; // total VA reserved per thread
// PML4 slot 448 — clear of the HHDM (256), heap (384, 0xffffc...), loader (416,
// 0xffffd...), and the kernel image (511, 0xffffffff8...).
const REGION: usize = 0xffffe00000000000;
pub const MAX_STACKS: usize = 16; // must match the scheduler's MAX_THREADS

// A guarded stack: `top` is the highest mapped address (the initial rsp grows
// down from here); `bottom` is the lowest mapped address (guard sits just below).
pub const Stack = struct { top: usize, bottom: usize };

// Force the stack region's page-table path (PML4 -> ... -> PT) to exist now, in
// the live kernel tables, by mapping then unmapping one probe page. Why it
// matters: a user process runs in its own address space (its own CR3) but takes
// its syscalls/traps on a kernel stack in THIS region. createAddressSpace() clones
// the kernel half by copying PML4 entries, so as long as this region's PML4 entry
// already points at a shared table here, every later per-slot map (into that same
// shared subtree) is visible in every address space. We must therefore populate
// the PML4 entry BEFORE any address space is cloned — main calls this once, right
// after vmm.init(), ahead of the first createAddressSpace()/spawn. unmap clears
// only the leaf, so the intermediate tables (and the PML4 entry) stay linked.
pub fn init() void {
    const frame = pmm.allocZeroed() orelse {
        serial.print("[KSTACK] WARN: could not pre-touch the stack region\n", .{});
        return;
    };
    vmm.map(REGION, frame, vmm.FLAG_WRITE | vmm.FLAG_NX); // builds PML4->PDPT->PD->PT
    vmm.unmap(REGION); // clear the leaf (keeps the tables); REGION stays unmapped (slot 0 guard)
    pmm.free(frame); // the probe frame is no longer referenced
    serial.print("[KSTACK] guarded kernel-stack region ready @0x{x} ({d} slots, {d} KiB each + guard)\n", .{ REGION, MAX_STACKS, STACK_SIZE / 1024 });
}

// The (unmapped) guard-page address for slot `i`.
fn guardAddr(i: usize) usize {
    return REGION + i * SLOT;
}

var self_tested = false; // run the guard self-test once, on the first allocation

// Allocate the guarded kernel stack for slot `i` (0..MAX_STACKS), returning its
// {top, bottom}, or null when out of slots / out of memory. Maps STACK_SIZE of
// fresh, zeroed frames with the page below left unmapped as the guard.
//
// Idempotent: the scheduler reuses thread ids (setupMain resets thread_count
// between its self-test phases), so the same slot is requested more than once per
// boot. If the slot is already mapped we hand back the same stack instead of
// mapping new frames over the old ones (which would orphan the old frames). A
// reused stack isn't re-zeroed — like the old heap stacks, spawn() rebuilds the
// initial frame at the top and the rest is overwritten as the stack grows down.
pub fn alloc(i: usize) ?Stack {
    if (i >= MAX_STACKS) return null; // out of slots
    const bottom = guardAddr(i) + GUARD; // first mapped byte (guard is the page below)
    const s = Stack{ .top = bottom + STACK_SIZE, .bottom = bottom };
    if (vmm.isMapped(bottom)) return s; // slot already mapped (reused thread id): reuse it

    var frames: [STACK_SIZE / PAGE]u64 = undefined; // remember frames so OOM can free them
    var off: usize = 0;
    while (off < STACK_SIZE) : (off += PAGE) {
        const frame = pmm.allocZeroed() orelse { // out of memory: undo what we mapped
            var done: usize = 0;
            while (done < off) : (done += PAGE) {
                vmm.unmap(bottom + done); // clear the leaf...
                pmm.free(frames[done / PAGE]); // ...and return the frame (unmap doesn't)
            }
            return null;
        };
        frames[off / PAGE] = frame;
        vmm.map(bottom + off, frame, vmm.FLAG_WRITE | vmm.FLAG_NX); // RW data, never executable
    }
    if (!self_tested) { // prove the guard invariant once, on the first real stack
        self_tested = true;
        selfTest(i, s);
    }
    return s;
}

// One-time check (on the first guarded stack) that the layout is correct: the
// guard page is unmapped, the stack's first and last pages are mapped, and the
// stack is writable. Runs against a genuinely-allocated stack (no extra slot).
fn selfTest(i: usize, s: Stack) void {
    const guard_unmapped = !vmm.isMapped(guardAddr(i));
    const stack_mapped = vmm.isMapped(s.bottom) and vmm.isMapped(s.top - PAGE);
    const p: *volatile u8 = @ptrFromInt(s.bottom); // lowest byte: safe to poke pre-use
    p.* = 0x5A;
    const rw = p.* == 0x5A;
    serial.print("[KSTACK] guarded-stack self-test: guard-unmapped={} stack-mapped={} rw={} (slot {d}, guard@0x{x})\n", .{ guard_unmapped, stack_mapped, rw, i, guardAddr(i) });
}
