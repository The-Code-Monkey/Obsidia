// Virtual memory manager: build our own x86-64 4-level page tables and take
// over paging from Limine by loading CR3.
//
// Limine leaves us in long mode with its own tables: the kernel mapped in the
// higher half and all of physical RAM mapped through the HHDM. To own our
// address space we construct a fresh PML4 (frames from the PMM, accessed via the
// HHDM), replicate the two mappings we cannot run without, and switch CR3:
//
//   1. The HHDM  - so the stack (which lives in the HHDM), the PMM bitmap, and
//      MMIO below 4 GiB stay reachable. Mapped with 2 MiB pages.
//   2. The kernel image - so RIP keeps pointing at valid code. Mapped 4 KiB.
//
// The instant CR3 loads, the MMU uses our tables; if either mapping is wrong we
// fault immediately - but the IDT from step 2 turns that into a readable dump
// instead of a triple fault.
//
// Permissions enforce W^X (write XOR execute): .text is executable + read-only,
// everything else (data, rodata, HHDM, heap) is non-executable. The NX bit is
// unlocked via EFER.NXE before any NX entry is used.

const pmm = @import("pmm.zig"); // frames for page tables + HHDM translation
const serial = @import("../drivers/serial.zig"); // logging

const PAGE_SIZE: u64 = 4096; // 4 KiB page
const TWO_MIB: u64 = 0x200000; // 2 MiB huge page (used for the HHDM)
const FOUR_GIB: u64 = 0x100000000; // minimum HHDM span (covers RAM + MMIO)

// Page-table entry flags (bit positions in a 64-bit entry).
const PRESENT: u64 = 1 << 0; // entry is valid
const WRITE: u64 = 1 << 1; // writes allowed
const USER: u64 = 1 << 2; // U/S: accessible from ring 3 (CPL 3) when set
const PWT: u64 = 1 << 3; // Page Write-Through (PAT index bit 0)
const PCD: u64 = 1 << 4; // Page Cache Disable (PAT index bit 1) -> UC with default PAT
const HUGE: u64 = 1 << 7; // PS bit (2 MiB page when set at PD level)
const NX: u64 = 1 << 63; // No-eXecute (usable only once EFER.NXE is set)
const ADDR_MASK: u64 = 0x000FFFFFFFFFF000; // bits 12..51 hold the physical address

// Extended Feature Enable Register: bit 11 (NXE) unlocks the NX page-table bit.
const IA32_EFER: u32 = 0xC0000080; // the EFER model-specific register number
const EFER_NXE: u64 = 1 << 11; // the NXE bit within EFER

// Kernel image + per-section bounds, provided by the linker script. Each is
// page-aligned, so [start, end) ranges map cleanly with no partial pages.
extern var __kernel_start: u8; // start of the whole image (.limine_requests)
extern var __kernel_end: u8; // end of the whole image (after .bss)
extern var __text_start: u8; // start of .text
extern var __text_end: u8; // end of .text
extern var __rodata_start: u8; // start of .rodata
extern var __rodata_end: u8; // end of .rodata
extern var __data_start: u8; // start of .data (.data + .bss run to __kernel_end)

var pml4_phys: u64 = 0; // physical address of our top-level page table

// Print a fatal message and halt — used when a mapping can't be built.
fn fail(comptime msg: []const u8) noreturn {
    serial.print("[VMM] FATAL: " ++ msg ++ "\n", .{});
    while (true) asm volatile ("cli; hlt");
}

// Round an address up / down to a multiple of `a` (a must be a power of two).
fn alignUp(x: u64, a: u64) u64 {
    return (x + a - 1) & ~(a - 1);
}
fn alignDown(x: u64, a: u64) u64 {
    return x & ~(a - 1);
}

// Read CR4 (we check the LA57 bit to confirm 4-level paging).
fn readCr4() u64 {
    return asm volatile ("mov %cr4, %[r]"
        : [r] "=r" (-> u64),
    );
}

// Read a model-specific register: rdmsr returns the 64-bit value in EDX:EAX.
fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined; // low 32 bits (EAX)
    var hi: u32 = undefined; // high 32 bits (EDX)
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo), // capture EAX
          [hi] "={edx}" (hi), // capture EDX
        : [msr] "{ecx}" (msr), // MSR number goes in ECX
    );
    return (@as(u64, hi) << 32) | @as(u64, lo); // recombine into 64 bits
}

// Write a model-specific register: wrmsr takes the value in EDX:EAX, number in ECX.
fn wrmsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr), // MSR number
          [lo] "{eax}" (@as(u32, @truncate(value))), // low 32 bits -> EAX
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))), // high 32 bits -> EDX
    );
}

// Enable NX before any NX-bearing page-table entry is used for translation,
// otherwise the NX bit is reserved and using it faults.
fn enableNxe() void {
    wrmsr(IA32_EFER, rdmsr(IA32_EFER) | EFER_NXE); // read EFER, set NXE, write back
}

// Invalidate one page's cached translation after we change its mapping.
fn flushTlb(virt: u64) void {
    asm volatile ("invlpg (%[v])"
        :
        : [v] "r" (virt), // the address whose TLB entry to drop
        : "memory"
    );
}

// View a physical table frame through the HHDM (valid under both Limine's CR3
// and ours, since both map the HHDM identically).
fn tableAt(phys: u64) [*]u64 {
    return @ptrFromInt(pmm.physToVirt(phys)); // 512 u64 entries per table
}

// Descend one level, allocating and linking a fresh table if absent. `user` is
// USER when the page being mapped is user-accessible, 0 otherwise: every level
// from the PML4 down must have the U/S bit set or the CPU denies ring-3 access
// to the leaf, so we set it on new intermediate tables and upgrade existing ones.
// (Setting U/S on an intermediate is safe for kernel pages under it — the leaf's
// own U/S bit still gates actual ring-3 access.)
fn nextTable(table: [*]u64, index: usize, user: u64) [*]u64 {
    const entry = table[index]; // the entry at this level
    if (entry & PRESENT != 0) { // already points to a table?
        if (user != 0 and entry & USER == 0) table[index] = entry | USER; // upgrade to allow user
        return tableAt(entry & ADDR_MASK); // follow it
    }
    const frame = pmm.allocZeroed() orelse fail("out of memory building page tables"); // make a new table
    table[index] = frame | PRESENT | WRITE | user; // link it in (intermediate tables are RW, +USER if needed)
    return tableAt(frame);
}

// Extract the 9-bit page-table index at the given shift from a virtual address.
fn idx(virt: u64, comptime shift: u6) usize {
    return @intCast((virt >> shift) & 0x1FF); // shifts: 39=PML4, 30=PDPT, 21=PD, 12=PT
}

// Map a single 4 KiB page virt -> phys with the given flags.
fn mapPage(pml4: [*]u64, virt: u64, phys: u64, flags: u64) void {
    const user = flags & USER; // propagate user-accessibility up the table hierarchy
    const pdpt = nextTable(pml4, idx(virt, 39), user); // level 4 -> 3
    const pd = nextTable(pdpt, idx(virt, 30), user); // level 3 -> 2
    const pt = nextTable(pd, idx(virt, 21), user); // level 2 -> 1
    pt[idx(virt, 12)] = (phys & ADDR_MASK) | flags | PRESENT; // leaf entry
}

// Map a single 2 MiB huge page (used for the HHDM, where 4 KiB would be wasteful).
fn map2MiB(pml4: [*]u64, virt: u64, phys: u64, flags: u64) void {
    const user = flags & USER; // (the HHDM is kernel-only, so this is 0 in practice)
    const pdpt = nextTable(pml4, idx(virt, 39), user); // level 4 -> 3
    const pd = nextTable(pdpt, idx(virt, 30), user); // level 3 -> 2
    pd[idx(virt, 21)] = (phys & ADDR_MASK) | flags | PRESENT | HUGE; // PD entry, HUGE = stop here
}

// Clear the leaf entry for `virt` (a non-creating walk; bails if unmapped).
fn unmapPage(pml4: [*]u64, virt: u64) void {
    if (pml4[idx(virt, 39)] & PRESENT == 0) return; // no PDPT
    const pdpt = tableAt(pml4[idx(virt, 39)] & ADDR_MASK);
    if (pdpt[idx(virt, 30)] & PRESENT == 0) return; // no PD
    const pd = tableAt(pdpt[idx(virt, 30)] & ADDR_MASK);
    if (pd[idx(virt, 21)] & PRESENT == 0) return; // no PT
    const pt = tableAt(pd[idx(virt, 21)] & ADDR_MASK);
    pt[idx(virt, 12)] = 0; // clear the leaf
}

// Public mapping API for later subsystems (e.g. the heap).
pub fn map(virt: u64, phys: u64, flags: u64) void {
    mapPage(tableAt(pml4_phys), virt, phys, flags); // map into the live tables
    flushTlb(virt); // drop any stale TLB entry
}
pub fn unmap(virt: u64) void {
    unmapPage(tableAt(pml4_phys), virt); // remove the mapping
    flushTlb(virt);
}

// True if `virt` has a present mapping in the live tables — a non-creating walk
// (same descent as unmapPage). Used to verify invariants without faulting, e.g.
// that a stack's guard page is unmapped while the stack itself is mapped.
pub fn isMapped(virt: u64) bool {
    const pml4 = tableAt(pml4_phys);
    if (pml4[idx(virt, 39)] & PRESENT == 0) return false; // no PDPT
    const pdpt = tableAt(pml4[idx(virt, 39)] & ADDR_MASK);
    const pdpte = pdpt[idx(virt, 30)];
    if (pdpte & PRESENT == 0) return false; // no PD
    if (pdpte & HUGE != 0) return true; // a present 1 GiB leaf covers virt
    const pd = tableAt(pdpte & ADDR_MASK);
    const pde = pd[idx(virt, 21)];
    if (pde & PRESENT == 0) return false; // no PT (or 2 MiB hole)
    if (pde & HUGE != 0) return true; // a present 2 MiB leaf covers virt
    const pt = tableAt(pde & ADDR_MASK);
    return pt[idx(virt, 12)] & PRESENT != 0; // the 4 KiB leaf
}

// Map a single 4 KiB page as UNCACHEABLE (UC) — the mapping device drivers use
// for MMIO. Identical to map() but forces the leaf PTE's PCD (Page Cache Disable)
// bit on. With the PAT left at its reset default, the (PAT,PCD,PWT) = (0,1,0)
// encoding selects memory type UC (strong uncacheable): no PAT MSR reprogramming
// is needed, so this is the simplest correct way to get UC pages.
//
// Why MMIO must be uncacheable: a BAR window is device registers, not RAM. If the
// CPU were allowed to cache it, reads could return a stale cached copy instead of
// the live hardware state, writes could sit in a write-back line and never reach
// the device (or reach it coalesced / reordered), and a status register that the
// device updates on its own would never appear to change. UC forces every access
// straight through to the device in program order, which is what register I/O
// (and memory-mapped doorbells / DMA descriptors that must be observed) require.
pub fn mapUncacheable(virt: u64, phys: u64, flags: u64) void {
    mapPage(tableAt(pml4_phys), virt, phys, flags | PCD); // PCD -> UC leaf
    flushTlb(virt); // drop any stale (possibly cacheable) TLB entry
}
pub const FLAG_WRITE = WRITE; // re-exported so callers can request writable pages
pub const FLAG_NX = NX; // ...and non-executable pages
pub const FLAG_USER = USER; // ...and pages reachable from ring 3 (user mode)
pub const FLAG_UC = PCD; // ...and uncacheable (PCD) pages, for MMIO

// --- Per-process address spaces ----------------------------------------------
// The kernel lives entirely in the higher half (PML4 entries 256..511: HHDM,
// heap, kernel image). A process address space is a fresh PML4 that SHARES those
// kernel entries (so the kernel — its code, stack, HHDM — stays mapped after a
// CR3 switch) and owns the low half (0..255) for its user mappings.

const KHALF_FIRST: usize = 256; // first PML4 index covering the higher (kernel) half

// The kernel's own address space (the PML4 built in init), for switching back to.
pub fn kernelSpace() u64 {
    return pml4_phys;
}

// Create a new address space: a zeroed PML4 with the kernel's higher-half entries
// copied in (sharing the kernel's lower-level tables). Returns its physical
// address, or null if out of memory. The low half starts empty.
pub fn createAddressSpace() ?u64 {
    const frame = pmm.allocZeroed() orelse return null;
    const new = tableAt(frame);
    const kernel = tableAt(pml4_phys);
    var i: usize = KHALF_FIRST;
    while (i < 512) : (i += 1) new[i] = kernel[i]; // share the kernel half
    return frame;
}

// Make `space` the active address space (load CR3). Caller ensures the code and
// stack it returns to are mapped there — always true for a space from
// createAddressSpace(), which shares the entire kernel half.
pub fn switchTo(space: u64) void {
    asm volatile ("mov %[p], %cr3"
        :
        : [p] "r" (space),
        : "memory"
    );
}

// Map / unmap a page in a specific address space (vs. map()/unmap(), which act on
// the live kernel space). No TLB flush: a new space isn't active yet, and the CR3
// load in switchTo() flushes everything anyway.
pub fn mapInto(space: u64, virt: u64, phys: u64, flags: u64) void {
    mapPage(tableAt(space), virt, phys, flags);
}
pub fn unmapInto(space: u64, virt: u64) void {
    unmapPage(tableAt(space), virt);
}

// Free a table frame and, for PDPT/PD levels, its present non-huge children first.
// Leaf (PT) entries point at the caller's DATA frames and are left untouched.
fn freeSubtree(table: u64, level: u8) void {
    if (level >= 2) { // PDPT (3) or PD (2): recurse into child tables
        const t = tableAt(table);
        var i: usize = 0;
        while (i < 512) : (i += 1) {
            const e = t[i];
            if (e & PRESENT == 0 or e & HUGE != 0) continue; // empty, or a huge data page
            freeSubtree(e & ADDR_MASK, level - 1);
        }
    }
    pmm.free(table); // free this table frame itself
}

// Destroy an address space created by createAddressSpace(): free its low-half
// (user) page tables and the PML4 frame. The shared kernel half is left alone;
// data frames the user mapped are the caller's to free (e.g. via unmapInto first).
pub fn destroyAddressSpace(space: u64) void {
    const pml4 = tableAt(space);
    var i: usize = 0;
    while (i < KHALF_FIRST) : (i += 1) { // low (user) half only
        const e = pml4[i];
        if (e & PRESENT == 0) continue;
        freeSubtree(e & ADDR_MASK, 3); // free the PDPT subtree under this entry
        pml4[i] = 0;
    }
    pmm.free(space); // free the PML4 frame
}

// Walk to the leaf entry mapping `virt` (stopping at a huge page), or null if
// unmapped. Used to verify applied permissions without triggering a fault.
fn queryEntry(pml4: [*]u64, virt: u64) ?u64 {
    if (pml4[idx(virt, 39)] & PRESENT == 0) return null; // unmapped at PML4
    const pdpt = tableAt(pml4[idx(virt, 39)] & ADDR_MASK);
    if (pdpt[idx(virt, 30)] & PRESENT == 0) return null; // unmapped at PDPT
    if (pdpt[idx(virt, 30)] & HUGE != 0) return pdpt[idx(virt, 30)]; // 1 GiB leaf
    const pd = tableAt(pdpt[idx(virt, 30)] & ADDR_MASK);
    if (pd[idx(virt, 21)] & PRESENT == 0) return null; // unmapped at PD
    if (pd[idx(virt, 21)] & HUGE != 0) return pd[idx(virt, 21)]; // 2 MiB leaf
    const pt = tableAt(pd[idx(virt, 21)] & ADDR_MASK);
    if (pt[idx(virt, 12)] & PRESENT == 0) return null; // unmapped at PT
    return pt[idx(virt, 12)]; // 4 KiB leaf
}

// Physical address of the currently-loaded address space (CR3), low flag bits
// masked off. A syscall runs on the calling process's CR3, so this names the
// tables a user pointer must be validated against.
pub fn activeSpace() u64 {
    return asm volatile ("mov %%cr3, %[ret]"
        : [ret] "=r" (-> u64),
    ) & ADDR_MASK;
}

// Verify that every page of [virt, virt+len) is mapped and reachable from ring 3
// (PRESENT + USER) in address space `space`. Syscalls call this before touching a
// user buffer so a bad pointer returns an error instead of faulting the kernel on
// the user's behalf — a minimal copy_from_user-style probe. The caller is
// responsible for the bounds (that the range stays within the user half).
pub fn userRangeAccessible(space: u64, virt: u64, len: u64) bool {
    if (len == 0) return true;
    const pml4 = tableAt(space);
    var addr = virt & ~(PAGE_SIZE - 1); // page containing the first byte
    const end = virt + len; // exclusive; no overflow — caller bounds it below USER_LIMIT
    while (addr < end) : (addr += PAGE_SIZE) {
        const entry = queryEntry(pml4, addr) orelse return false; // unmapped page
        if (entry & USER == 0) return false; // present but kernel-only — not user-reachable
    }
    return true;
}

// Map every page in [vstart, vend) to its kernel-slide physical address.
fn mapKernelRange(pml4: [*]u64, vstart: u64, vend: u64, flags: u64, virt_base: u64, phys_base: u64) usize {
    var v = vstart; // current virtual page
    var n: usize = 0; // count of pages mapped
    while (v < vend) : (v += PAGE_SIZE) {
        mapPage(pml4, v, v - virt_base + phys_base, flags); // phys = virt - slide
        n += 1;
    }
    return n;
}

// Confirm the W^X flags actually landed in the live tables, by reading the leaf
// entry for one address in each region. Non-faulting: it inspects bits, it does
// not try to execute/write anything illegal.
fn verifyWX(pml4: [*]u64) void {
    // For each region: is it writable (WRITE set) and is it executable (NX clear)?
    const text = queryEntry(pml4, @intFromPtr(&__text_start)) orelse 0; // a .text page
    const rodata = queryEntry(pml4, @intFromPtr(&__rodata_start)) orelse 0; // a .rodata page
    const data = queryEntry(pml4, @intFromPtr(&__data_start)) orelse 0; // a .data page
    const hhdm = queryEntry(pml4, pmm.physToVirt(0x1000)) orelse 0; // an HHDM page

    const text_x = text & NX == 0; // executable if NX is clear
    const text_w = text & WRITE != 0; // writable if WRITE is set
    const rodata_x = rodata & NX == 0;
    const data_x = data & NX == 0;
    const hhdm_x = hhdm & NX == 0;

    serial.print("[VMM]   W^X: .text(x={},w={}) .rodata(x={}) .data(x={}) hhdm(x={})\n", .{ text_x, text_w, rodata_x, data_x, hhdm_x });
    // Ideal: .text executable & not writable; everything else non-executable.
    const ok = text_x and !text_w and !rodata_x and !data_x and !hhdm_x;
    serial.print("[VMM]   W^X enforced: {s}\n", .{if (ok) "OK" else "FAIL"});
}

// --- Self-test: prove our live tables translate correctly --------------------
fn selfTest(pml4: [*]u64) void {
    serial.print("[VMM]   Self-test: mapping a scratch page...\n", .{});
    const scratch: u64 = 0xffffffffd0000000; // unused higher-half address
    const frame = pmm.allocZeroed() orelse { // a physical frame to back it
        serial.print("[VMM]     FAILED: no frame for scratch page\n", .{});
        return;
    };
    mapPage(pml4, scratch, frame, PRESENT | WRITE | NX); // map it RW + non-exec
    flushTlb(scratch); // ensure the new mapping is visible

    const p: [*]volatile u64 = @ptrFromInt(scratch); // access via the NEW mapping
    p[0] = 0xCAFEBABEDEADBEEF; // write two markers
    p[1] = 0x1234567890ABCDEF;
    const wrote_ok = p[0] == 0xCAFEBABEDEADBEEF and p[1] == 0x1234567890ABCDEF; // read back
    serial.print("[VMM]     wrote/read via new mapping 0x{x} -> phys 0x{x}: {s}\n", .{ scratch, frame, if (wrote_ok) "OK" else "MISMATCH" });

    // The same physical frame, viewed through the HHDM, must show the same data
    // - this proves our new virtual mapping really points where we think.
    const alias: [*]volatile u64 = @ptrFromInt(pmm.physToVirt(frame)); // HHDM alias of the frame
    const alias_ok = alias[0] == 0xCAFEBABEDEADBEEF; // same bytes?
    serial.print("[VMM]     HHDM alias of that frame agrees: {s}\n", .{if (alias_ok) "OK" else "MISMATCH"});

    unmapPage(pml4, scratch); // tear down the scratch mapping
    flushTlb(scratch);
    pmm.free(frame); // return the frame
    serial.print("[VMM]     unmapped scratch + freed frame.\n", .{});

    verifyWX(pml4); // finally, confirm the W^X permission bits
}

// --- Address-space self-test -------------------------------------------------
// Create a second address space, map a user page in it, switch CR3, write+read
// through that low-half VA, then switch back — proving a separate space works and
// that the page is isolated (mapped in the new space, absent from the kernel's).
pub fn selfTestAddressSpace() void {
    serial.print("[VMM] Address-space self-test...\n", .{});
    const as = createAddressSpace() orelse {
        serial.print("[VMM]   FAILED: no memory for a new address space\n", .{});
        return;
    };
    const frame = pmm.allocZeroed() orelse {
        destroyAddressSpace(as);
        return;
    };
    const va: u64 = 0x0000000000600000; // a low-half (user) address, only in `as`
    mapInto(as, va, frame, FLAG_USER | FLAG_WRITE | FLAG_NX);

    // The VA must resolve in the new space but not in the kernel space.
    const in_new = queryEntry(tableAt(as), va) != null;
    const in_kernel = queryEntry(tableAt(pml4_phys), va) != null;

    // Switch to `as`, write+read through the user VA, then switch back. Interrupts
    // off across the swap: everything the kernel touches is in the shared half, so
    // this is just for a clean, deterministic transition.
    const MAGIC: u64 = 0xA5A5_C0DE_1234_5678;
    asm volatile ("cli");
    switchTo(as);
    const p: *volatile u64 = @ptrFromInt(va);
    // `va` is mapped U=1, so a ring-0 access to it is exactly what SMAP blocks.
    // This self-test legitimately writes through a user mapping, so lift the
    // guard (STAC) for the access and re-arm it (CLAC) right after — mirroring
    // the syscall write path. Without this, SMAP #PFs on `p.* = MAGIC`.
    asm volatile ("stac");
    p.* = MAGIC;
    const readback = p.*;
    asm volatile ("clac");
    switchTo(pml4_phys); // back to the kernel address space
    asm volatile ("sti");

    // The write must have reached `frame` (confirm via its HHDM alias).
    const alias: *volatile u64 = @ptrFromInt(pmm.physToVirt(frame));
    const alias_ok = alias.* == MAGIC;

    serial.print("[VMM]   VA 0x{x}: in new AS={}, in kernel AS={}; readback ok={}, frame alias ok={}.\n", .{ va, in_new, in_kernel, readback == MAGIC, alias_ok });
    if (in_new and !in_kernel and readback == MAGIC and alias_ok) {
        serial.print("[VMM] Address-space self-test OK.\n", .{});
    } else {
        serial.print("[VMM] Address-space self-test FAILED.\n", .{});
    }

    pmm.free(frame); // the data frame is ours to free
    destroyAddressSpace(as); // free the space's tables + PML4
}

// --- Uncacheable-MMIO self-test ----------------------------------------------
// Prove mapUncacheable() works: allocate a frame, map it UC at a spare kernel VA,
// round-trip a pattern through the UC mapping (UC is uncached, NOT broken — plain
// loads/stores still work, they just bypass the cache), and confirm the leaf PTE
// actually carries the PCD bit. This exercises the exact path a future MMIO driver
// (AHCI/NIC BAR) will take, on ordinary RAM so we have a frame to read back.
pub fn selfTestUncacheable() void {
    serial.print("[VMM] uncacheable-MMIO self-test...\n", .{});
    const pml4 = tableAt(pml4_phys); // the live tables (for the PCD-bit check)
    // A spare higher-half VA: not HEAP_BASE (0xffffc...), LOAD_BASE (0xffffd...),
    // the selfTest scratch (0x...d0000000), the HHDM, or the kernel image.
    const va: u64 = 0xffffffffe0000000;
    const frame = pmm.allocZeroed() orelse { // a physical frame to back the UC page
        serial.print("[VMM]   FAILED: no frame for the UC page\n", .{});
        return;
    };

    mapUncacheable(va, frame, PRESENT | WRITE | NX); // map it UC, RW + non-exec

    // Round-trip a pattern through the UC mapping — UC bypasses the cache but
    // ordinary reads/writes must still land in the backing frame correctly.
    const p: [*]volatile u64 = @ptrFromInt(va); // access via the UC mapping
    p[0] = 0xC0DE_FACE_1234_5678; // write a marker through the UC page
    const round_trip = p[0] == 0xC0DE_FACE_1234_5678; // read it back

    // Read the leaf PTE back from the live tables and confirm PCD is set.
    const leaf = queryEntry(pml4, va) orelse 0; // the 4 KiB leaf entry
    const pcd_set = leaf & PCD != 0; // the cache-disable bit we OR'd in

    if (round_trip and pcd_set) {
        serial.print("[VMM] uncacheable-MMIO self-test: round-trip OK, PCD set\n", .{});
    } else {
        serial.print("[VMM] uncacheable-MMIO self-test FAILED (round-trip={}, PCD={})\n", .{ round_trip, pcd_set });
    }

    unmap(va); // tear down the UC mapping
    pmm.free(frame); // return the frame
}

pub fn init(phys_base: u64, virt_base: u64, hhdm_offset: u64) void {
    serial.print("[VMM] Initializing virtual memory manager...\n", .{});
    serial.print("[VMM]   kernel phys_base=0x{x} virt_base=0x{x}\n", .{ phys_base, virt_base });

    // Tripwire: we assume 4-level paging (CR4.LA57 == 0).
    if (readCr4() & (@as(u64, 1) << 12) != 0) fail("5-level paging active; VMM assumes 4-level");

    // Unlock the NX bit so the W^X mappings below are legal.
    enableNxe();
    serial.print("[VMM]   EFER.NXE enabled (NX bit usable).\n", .{});

    pml4_phys = pmm.allocZeroed() orelse fail("cannot allocate PML4"); // top-level table
    const pml4 = tableAt(pml4_phys); // its HHDM view
    serial.print("[VMM]   PML4 at phys 0x{x}\n", .{pml4_phys});

    // 1. HHDM: map [0, top) -> hhdm_offset + phys with 2 MiB pages. Pure data:
    //    writable, never executable.
    const hhdm_top = @max(FOUR_GIB, alignUp(pmm.highestAddress(), TWO_MIB)); // at least 4 GiB
    var p: u64 = 0; // current physical address
    while (p < hhdm_top) : (p += TWO_MIB) { // one 2 MiB page at a time
        map2MiB(pml4, hhdm_offset + p, p, PRESENT | WRITE | NX);
    }
    serial.print("[VMM]   Mapped HHDM: 0x{x} + [0, 0x{x}) ({d} MiB, 2 MiB pages, RW+NX)\n", .{ hhdm_offset, hhdm_top, hhdm_top / (1024 * 1024) });

    // 2. Kernel image, per section, enforcing W^X:
    //      .limine_requests : RW + NX (data the bootloader filled in)
    //      .text            : RX, read-only (executable, NOT writable)
    //      .rodata          : RO + NX (constants)
    //      .data + .bss     : RW + NX
    const rq_start = alignDown(@intFromPtr(&__kernel_start), PAGE_SIZE); // requests + image start
    const tx_start = @intFromPtr(&__text_start); // .text bounds
    const tx_end = @intFromPtr(&__text_end);
    const ro_start = @intFromPtr(&__rodata_start); // .rodata bounds
    const ro_end = @intFromPtr(&__rodata_end);
    const da_start = @intFromPtr(&__data_start); // .data start
    const kend = alignUp(@intFromPtr(&__kernel_end), PAGE_SIZE); // image end

    const n_rq = mapKernelRange(pml4, rq_start, tx_start, PRESENT | WRITE | NX, virt_base, phys_base); // requests: RW NX
    const n_tx = mapKernelRange(pml4, tx_start, tx_end, PRESENT, virt_base, phys_base); // text: RX read-only
    const n_ro = mapKernelRange(pml4, ro_start, ro_end, PRESENT | NX, virt_base, phys_base); // rodata: RO NX
    const n_da = mapKernelRange(pml4, da_start, kend, PRESENT | WRITE | NX, virt_base, phys_base); // data/bss: RW NX
    serial.print("[VMM]   Mapped kernel W^X: requests={d} text(RX)={d} rodata(RO)={d} data(RW)={d} pages\n", .{ n_rq, n_tx, n_ro, n_da });

    // 3. Switch CR3. Mask interrupts across the swap so a timer IRQ can't land
    //    in the middle; everything it touches is mapped in both table sets, but
    //    this keeps the transition clean.
    serial.print("[VMM]   Loading CR3 = 0x{x}...\n", .{pml4_phys});
    asm volatile ("cli"); // disable interrupts during the switch
    asm volatile ("mov %[p], %cr3" // load our PML4 -> MMU now uses our tables
        :
        : [p] "r" (pml4_phys),
        : "memory"
    );
    serial.print("[VMM]   CR3 loaded - now running on our own page tables.\n", .{});

    selfTest(pml4); // verify translation + W^X on the live tables
    asm volatile ("sti"); // re-enable interrupts

    serial.print("[VMM] Virtual memory manager initialized.\n", .{});
}
