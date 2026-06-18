// Program loader: read an "init" binary off the FAT32 disk, make it executable
// in memory, run it, and tear it back down. Two formats are understood, chosen
// automatically by sniffing the first four bytes of the file:
//
//   * ELF64  — a real linked executable (\x7fELF...). We parse its header,
//     walk its program headers, and lay each PT_LOAD segment down at the exact
//     virtual address the linker chose, with the segment's own permissions.
//     This is the format produced by a normal toolchain (zig/clang/ld).
//   * flat   — the "version 0" raw-machine-code format: no header, byte 0 is
//     the first instruction, loaded at a fixed LOAD_BASE. Kept as a fallback so
//     hand-assembled blobs (and the original /INIT) still run unchanged.
//
// THE BINARY CONTRACT (shared by both formats — deliberately the simplest thing
// that is verifiable end-to-end before we have user mode):
//
//   - The program runs in ring 0 (kernel privilege — we have no user mode yet)
//     on the caller's stack, interrupts enabled, and is entered like a C
//     function: it must preserve callee-saved registers and finish with `ret`.
//   - It returns a u64 in rax. A well-behaved init returns INIT_MAGIC, which
//     lets the kernel tell "ran to completion" apart from "crashed into a stray
//     ret with garbage in rax". (User mode + a syscall-based exit are a later
//     task; for now the return value IS the exit status.)
//
// W^X (write XOR execute) is preserved at every instant, for BOTH formats:
// every destination page is mapped WRITABLE + NO-EXECUTE while bytes are copied
// in, then flipped to its final permissions before we jump. No page is ever
// writable and executable at the same time — this is a hard kernel rule.

const std = @import("std");
const serial = @import("drivers/serial.zig"); // logging
const fat32 = @import("fs/fat32.zig"); // readFile: the disk -> memory path
const pmm = @import("mm/pmm.zig"); // physical frames backing the image
const vmm = @import("mm/vmm.zig"); // mapping those frames into the address space
const scheduler = @import("sched/scheduler.zig"); // run a user image as a ring-3 process

// Where a *flat* binary is loaded and entered in the RING-0 path. This is PML4
// slot 416 (0xffffd...): a top-level slot of its own, comfortably away from the
// HHDM (slots 256+), the kernel heap (slot 384, 0xffffc...) and the kernel image
// (slot 511). An ELF, by contrast, is loaded at whatever virtual addresses its
// program headers name — the ring-0 test ELF is linked into this same slot so it
// lands in the same safely-unused region.
pub const LOAD_BASE: u64 = 0xffffd00000000000;

// === Ring-3 (user-process) load layout =======================================
// A binary run via execUser() lives in the *low half* of its own address space
// (PML4 slots 0..255, the user range), reached from ring 3 via USER-flagged
// pages. The flat user base mirrors LOAD_BASE's role but in the low half; the
// user ELF is linked just above it (its program headers name the real addresses).
pub const USER_LOAD_BASE: u64 = 0x0000000000400000; // 4 MiB — flat user entry
const USER_STACK_TOP: u64 = 0x0000000000800000; // 8 MiB — top of the user stack
const USER_STACK_PAGES: usize = 4; // 16 KiB user stack (grows down from the top)

// The "ran to completion" value a RING-0 init binary returns in rax. (Ring-3
// processes signal completion with the exit() syscall instead, so this magic is
// only used by the legacy ring-0 path.)
pub const INIT_MAGIC: u64 = 0xB017B007;

const PAGE_SIZE: u64 = pmm.PAGE_SIZE; // 4 KiB, same as the PMM's frames
const MAX_PAGES: usize = 256; // 1 MiB cap — plenty for a bare-metal init

// The physical frame behind each mapped page, paired with the virtual address it
// was mapped at, so teardown can both unmap and free it. The flat loader maps a
// contiguous run at LOAD_BASE; the ELF loader scatters pages across each
// segment's virtual range — so we must remember the virtual address explicitly
// rather than recomputing it. Static (not heap) so the loader has no allocator
// dependency, mirroring the rest of this module.
var mapped_virt: [MAX_PAGES]u64 = undefined; // virtual address of each mapped page
var mapped_frame: [MAX_PAGES]u64 = undefined; // physical frame backing that page
var mapped_count: usize = 0; // how many entries above are live

// The address space the current load builds into. 0 selects the RING-0 path:
// pages are mapped live in the kernel's own space (vmm.map) and the image runs in
// ring 0. A non-zero value is a process PML4 from vmm.createAddressSpace(): pages
// are mapped USER into that (not-yet-active) space (vmm.mapInto), and the image
// runs in ring 3. Every mapping/copy/teardown primitive below branches on this so
// the two paths share one body of parse+map logic.
var target_space: u64 = 0;

// A scratch buffer holding the raw file bytes. The ELF loader needs random
// access to the whole file (header at offset 0, program headers at e_phoff,
// segment data at arbitrary p_offset) BEFORE it knows where anything will be
// mapped, so we slurp the file here first. Static, so no allocator is needed and
// there is no allocation-failure path to unwind. 1 MiB matches MAX_PAGES.
var file_buf: [MAX_PAGES * PAGE_SIZE]u8 = undefined;

// Round an address down to the start of its page.
fn pageDown(x: u64) u64 {
    return x & ~(PAGE_SIZE - 1);
}

// Record one freshly-mapped page so teardown() can later reverse it.
fn track(virt: u64, frame: u64) void {
    mapped_virt[mapped_count] = virt;
    mapped_frame[mapped_count] = frame;
    mapped_count += 1;
}

// Unmap every page we mapped and return its frame to the PMM, then reset the
// bookkeeping. Used both for normal teardown after a run and to unwind a
// half-built image on any error — so a failed load leaks nothing. Unmaps from
// whichever space this load built into (live kernel space, or a process space).
fn teardown() void {
    var i: usize = 0;
    while (i < mapped_count) : (i += 1) {
        if (target_space == 0) {
            vmm.unmap(mapped_virt[i]); // ring-0: drop the live mapping (+ flush its TLB entry)
        } else {
            vmm.unmapInto(target_space, mapped_virt[i]); // user: drop it in the process space
        }
        pmm.free(mapped_frame[i]); // give the frame back
    }
    mapped_count = 0; // armed clean for the next exec
}

// Allocate a fresh zeroed frame and map it at `virt` as WRITABLE + NO-EXECUTE —
// the W^X-safe state for a page we are about to write bytes into. Records it for
// teardown. Returns false (after unwinding everything mapped so far) on OOM.
// Ring-0 maps live in the kernel space; the user path maps USER into the process
// space (which isn't active yet, so no TLB flush is needed — the CR3 load on the
// first switch to the process flushes everything).
fn mapWritable(virt: u64) bool {
    const frame = pmm.allocZeroed() orelse { // a zeroed frame guarantees a zeroed .bss tail
        teardown(); // unwind the whole partially-built image
        return false;
    };
    if (target_space == 0) {
        vmm.map(virt, frame, vmm.FLAG_WRITE | vmm.FLAG_NX); // present + writable + non-exec
    } else {
        vmm.mapInto(target_space, virt, frame, vmm.FLAG_USER | vmm.FLAG_WRITE | vmm.FLAG_NX);
    }
    track(virt, frame);
    return true;
}

// Re-map an already-tracked page to its FINAL permissions (the W^X stage-3 flip).
// `flags` is the kernel-style permission set (0 = RX read-only, FLAG_WRITE/FLAG_NX
// as needed); the user path ORs in FLAG_USER so ring 3 can reach the page.
fn remap(virt: u64, frame: u64, flags: u64) void {
    if (target_space == 0) {
        vmm.map(virt, frame, flags);
    } else {
        vmm.mapInto(target_space, virt, frame, flags | vmm.FLAG_USER);
    }
}

// Copy `src` to virtual address `virt` within the image being built. For the
// ring-0 path the destination pages are live in the current CR3, so a straight
// copy works. For the user path the pages live in a not-yet-active address space,
// so we reach each one through its physical frame's HHDM alias instead, copying
// page by page (consecutive user pages are NOT contiguous in the HHDM). Both rely
// on the destination pages already being mapped+tracked (stage 1).
fn copyInto(virt: u64, src: []const u8) void {
    if (target_space == 0) {
        const dst = @as([*]u8, @ptrFromInt(virt))[0..src.len];
        @memcpy(dst, src);
        return;
    }
    var done: usize = 0;
    while (done < src.len) {
        const va = virt + done;
        const page = pageDown(va);
        const frame = findFrame(page) orelse return; // mapped in stage 1; missing = caller bug
        const off = va - page; // how far into the page this chunk starts
        const n = @min(src.len - done, @as(usize, @intCast(PAGE_SIZE - off)));
        const dst = @as([*]u8, @ptrFromInt(pmm.physToVirt(frame) + off))[0..n];
        @memcpy(dst, src[done .. done + n]);
        done += n;
    }
}

// === File loading ============================================================
// Read the file at `path` off the FAT32 disk into the scratch buffer and return
// it as a slice, or null (having logged why) if it can't be run. Shared by both
// the ring-0 exec() and the ring-3 execUser(); it touches no page tables, so
// there is never anything to unwind on its failure paths.
fn readImage(path: []const u8) ?[]const u8 {
    if (!fat32.isMounted()) {
        return null;
    }
    const node = fat32.resolve(path) orelse { // does the file exist?
        return null;
    };
    if (node.is_dir) {
        return null;
    }
    if (node.size == 0) { // nothing to run
        return null;
    }
    if (node.size > file_buf.len) {
        return null;
    }

    // Slurp the whole file into the scratch buffer. Both loaders work from this
    // copy: the flat loader copies it straight to the load base; the ELF loader
    // parses it and scatters its segments to their linked addresses.
    const got = fat32.readFile(path, file_buf[0..node.size]) orelse {
        return null;
    };
    // A short read means the cluster chain ended before the file's declared
    // size (a truncated or corrupt file); readFile reports this as a byte count
    // below node.size rather than an error. Loading a partial image would run
    // garbage, so refuse here — nothing is mapped yet (we've only slurped the
    // file into the scratch buffer), so there is nothing to unwind.
    if (got != node.size) {
        return null;
    }
    return file_buf[0..got];
}

// Parse `file` (auto-detecting ELF vs flat) and lay it out into the address space
// selected by `target_space`. `flat_base` is where a flat image loads (an ELF
// uses its own program-header addresses). Returns the entry point to run, or null
// (with the partial image torn down) on any error. Does NOT run anything — the
// caller runs and then tears down, so the same layout works for both ring 0
// (call + return) and ring 3 (spawn a process).
fn loadImage(file: []const u8, flat_base: u64) ?u64 {
    // Sniff the format: an ELF starts with the 4-byte magic "\x7fELF".
    if (file.len >= 4 and file[0] == 0x7f and file[1] == 'E' and file[2] == 'L' and file[3] == 'F') {
        return loadElf(file);
    }
    return loadFlat(file, flat_base);
}

// === Public entry points =====================================================
// Ring-0 path: load the binary at `path`, run it in KERNEL mode at LOAD_BASE
// under the legacy binary contract (entered like a C function, returns a magic in
// rax), then tear it down. Returns true only if it ran and came back with
// INIT_MAGIC. Kept for hand-assembled ring-0 blobs; user programs use execUser().
pub fn exec(path: []const u8) bool {
    const file = readImage(path) orelse return false;
    target_space = 0; // ring-0: build live in the kernel's own space
    const entry = loadImage(file, LOAD_BASE) orelse return false;
    return runAndTeardown(entry);
}

// Ring-3 path: load the binary at `path` as a real USER PROCESS — its own address
// space, USER pages in the low half, a user stack — then schedule it and wait for
// it to exit() (the user ABI's "done" signal, replacing the ring-0 return magic).
// Returns true if it ran and exited with code 0. Tears the address space down
// afterwards. Builds the image with the same loadImage() core as exec(). This is
// the form the shell's `exec` calls — it runs as a real scheduler thread.
pub fn execUser(path: []const u8) bool {
    return execUserCtx(path, false);
}

// Shared body for the ring-3 path. `standalone` picks how the process is run:
//   false — the caller is already a scheduler thread (the shell); use runUser.
//   true  — the caller predates the scheduler (the boot self-test); use
//           runUserStandalone, which adopts a throwaway main-thread context first.
fn execUserCtx(path: []const u8, standalone: bool) bool {
    const file = readImage(path) orelse return false;

    // A fresh address space for the process: the kernel half is shared in, the low
    // half (where the image and stack go) starts empty.
    const space = vmm.createAddressSpace() orelse {
        return false;
    };
    target_space = space; // route every mapping/copy/teardown into this space
    mapped_count = 0; // start the per-image page log clean

    // Build the image (flat -> USER_LOAD_BASE; ELF -> its own low-half addresses),
    // then add a user stack. Any failure tears down what was mapped + the space.
    const entry = loadImage(file, USER_LOAD_BASE) orelse {
        vmm.destroyAddressSpace(space);
        target_space = 0;
        return false;
    };
    if (!mapUserStack()) { // mapWritable already tore the image down on OOM
        vmm.destroyAddressSpace(space);
        target_space = 0;
        return false;
    }
    serial.print("[LOADER]   user image ready: entry 0x{x}, stack top 0x{x}.\n", .{ entry, USER_STACK_TOP });

    // Schedule it in ring 3 and block until it exits. From the shell (a real
    // thread) the live scheduler hosts it; at boot we adopt a standalone context.
    const code = if (standalone)
        scheduler.runUserStandalone("uinit", entry, USER_STACK_TOP, space)
    else
        scheduler.runUser("uinit", entry, USER_STACK_TOP, space);
    serial.print("[LOADER]   user process exited with code {d}.\n", .{code});

    // Tear the process down: unmap + free every image/stack page, then free the
    // page tables and the PML4. (Leaves the kernel half, which is shared, alone.)
    teardown();
    vmm.destroyAddressSpace(space);
    target_space = 0;
    return code == 0;
}

// Map the ring-3 user stack: USER_STACK_PAGES writable+NX USER pages directly
// below USER_STACK_TOP. mapWritable already maps RW+NX (+USER) and tracks each
// page for teardown, and the stack stays writable (never remapped RX) — exactly
// what a stack needs. Returns false (image already unwound) on OOM.
fn mapUserStack() bool {
    var i: usize = 0;
    while (i < USER_STACK_PAGES) : (i += 1) {
        if (!mapWritable(USER_STACK_TOP - (i + 1) * PAGE_SIZE)) return false;
    }
    return true;
}

// === Flat binary path ========================================================
// The original "version 0" format: raw machine code, entered at byte 0, loaded at
// `base` (LOAD_BASE for ring 0, USER_LOAD_BASE for ring 3). Returns the entry
// point (== base) or null on error; the caller runs it. Kept so hand-assembled
// blobs keep working — including the ring-3 user init, whose code is also flat.
fn loadFlat(file: []const u8, base: u64) ?u64 {
    const pages: usize = (file.len + @as(usize, PAGE_SIZE) - 1) / @as(usize, PAGE_SIZE); // round up
    if (pages > MAX_PAGES) {
        return null;
    }
    serial.print("[LOADER]   flat binary -> {d} page(s) at 0x{x}.\n", .{ pages, base });

    // Stage 1: back the image with fresh zeroed frames, mapped WRITABLE + NX —
    // we're about to write file bytes into them, and W^X forbids a writable page
    // from also being executable.
    var i: usize = 0;
    while (i < pages) : (i += 1) {
        if (!mapWritable(base + i * PAGE_SIZE)) return null; // mapWritable unwinds on OOM
    }

    // Stage 2: copy the file bytes into the mapped pages (the tail of the last
    // page stays zero, which is harmless for flat code).
    copyInto(base, file);

    // Stage 3: flip every page to READ-ONLY + EXECUTABLE. flags=0 means present,
    // not writable, and (no NX bit) executable — i.e. RX (the user path also ORs
    // in USER). remap overwrites the existing leaf (+ TLB flush in the live case).
    i = 0;
    while (i < pages) : (i += 1) {
        remap(base + i * PAGE_SIZE, mapped_frame[i], 0); // RX read-only
    }

    return base; // flat entry is always byte 0 == base
}

// === ELF64 path ==============================================================
// We define just enough of the ELF64 format ourselves (with comments) rather
// than pulling in std.elf — it keeps the on-disk layout visible right here.
//
// An ELF64 file begins with a 64-byte header; for *loading* (as opposed to
// linking) all that matters is: the identification bytes, the type/machine, the
// entry point, and where the PROGRAM HEADER table is. The program header table
// is an array of e_phnum entries of e_phentsize bytes each, starting at e_phoff.
// Each program header describes one chunk the loader must place in memory; the
// ones we care about are PT_LOAD — "map p_filesz bytes from file offset p_offset
// to virtual address p_vaddr, then zero up to p_memsz, with permissions p_flags".

const PT_LOAD: u32 = 1; // a loadable segment (the only type a loader must honor)
const PF_X: u32 = 1; // p_flags: segment is executable
const PF_W: u32 = 2; // p_flags: segment is writable
// PF_R (4) is implied for everything we map; we never make a page unreadable.

// First address ABOVE the canonical low half (user space): every user mapping
// must lie strictly below it. Mirrors USER_LIMIT in src/arch/syscall.zig, which
// guards syscall buffers — here it guards where a PT_LOAD segment may land, so a
// crafted ELF can never map a segment over the kernel/HHDM (ring 0) or over the
// kernel half of a process space (ring 3).
const USER_LIMIT: u64 = 0x0000_8000_0000_0000;

const ET_EXEC: u16 = 2; // a position-DEPENDENT executable (fixed load addresses)
const ET_DYN: u16 = 3; // a position-INDEPENDENT executable / shared object
const EM_X86_64: u16 = 62; // the machine type for x86-64
const ELFCLASS64: u8 = 2; // e_ident[EI_CLASS]: 64-bit objects
const ELFDATA2LSB: u8 = 1; // e_ident[EI_DATA]: little-endian (x86 is LE)

// --- Little-endian field readers (the file is little-endian on x86) ----------
fn rd16(b: []const u8, o: usize) u16 {
    return @as(u16, b[o]) | (@as(u16, b[o + 1]) << 8);
}
fn rd32(b: []const u8, o: usize) u32 {
    return @as(u32, b[o]) | (@as(u32, b[o + 1]) << 8) |
        (@as(u32, b[o + 2]) << 16) | (@as(u32, b[o + 3]) << 24);
}
fn rd64(b: []const u8, o: usize) u64 {
    return @as(u64, rd32(b, o)) | (@as(u64, rd32(b, o + 4)) << 32);
}

// Parse and lay out a static ELF64 executable into the selected address space.
// `file` is the whole file. Returns the entry point (to run) or null on error;
// the caller runs it (ring 0: call; ring 3: spawn a process).
fn loadElf(file: []const u8) ?u64 {
    // --- Validate the ELF header -------------------------------------------
    // 64 bytes minimum just to read the header fields safely.
    if (file.len < 64) {
        return null;
    }
    // e_ident[4]=class, [5]=data, [6]=version. (The 4-byte magic was checked by
    // the caller.) We only run little-endian 64-bit objects.
    if (file[4] != ELFCLASS64) {
        return null;
    }
    if (file[5] != ELFDATA2LSB) {
        return null;
    }
    const e_type = rd16(file, 16); // ET_EXEC or ET_DYN
    const e_machine = rd16(file, 18); // must be x86-64
    const e_entry = rd64(file, 24); // virtual address of the first instruction
    const e_phoff = rd64(file, 32); // file offset of the program header table
    const e_phentsize = rd16(file, 54); // size of one program header entry
    const e_phnum = rd16(file, 56); // number of program header entries

    if (e_machine != EM_X86_64) {
        return null;
    }
    if (e_type != ET_EXEC and e_type != ET_DYN) {
        return null;
    }
    if (e_phnum == 0 or e_phentsize < 56) { // a 64-bit program header is 56 bytes
        return null;
    }
    // The whole program header table must lie within the file we read. Compute
    // its byte span with OVERFLOW-SAFE math (*%, +%) so a crafted e_phoff/e_phnum
    // can't wrap past file.len and slip the bounds check: if the table size itself
    // overflows a u64, or e_phoff + size wraps below e_phoff, the file is bogus.
    const phtab_size = @as(u64, e_phnum) *% @as(u64, e_phentsize); // entries * entry size
    if (phtab_size / @as(u64, e_phnum) != @as(u64, e_phentsize)) {
        // size * count overflowed u64 — impossible for a real table, so reject.
        // (e_phnum != 0 was already established above, so the divide is safe.)
        return null;
    }
    const phtab_end = e_phoff +% phtab_size; // first byte past the table
    if (phtab_end < e_phoff or phtab_end > file.len) { // wrapped, or runs past EOF
        return null;
    }
    serial.print("[LOADER]   ELF64 {s}, entry 0x{x}, {d} program header(s).\n", .{ if (e_type == ET_EXEC) "ET_EXEC" else "ET_DYN", e_entry, e_phnum });

    // Load bias. An ET_EXEC names absolute virtual addresses and must load
    // exactly where it says (bias 0). An ET_DYN (a PIE) is linked relative to 0
    // and may be placed anywhere — we slide it up to the load base for this mode
    // (USER_LOAD_BASE for a ring-3 process, so it lands in the low/user half;
    // LOAD_BASE for a ring-0 image, in the safely-unused higher-half slot). NOTE:
    // this is only correct for PIEs whose code is purely RIP-relative; we do NOT
    // apply R_X86_64_RELATIVE relocations, so a PIE that depends on absolute
    // pointers would need a relocation pass (a later task). ET_EXEC, our primary
    // format, is unaffected.
    const dyn_base: u64 = if (target_space == 0) LOAD_BASE else USER_LOAD_BASE;
    const bias: u64 = if (e_type == ET_DYN) dyn_base else 0;

    // --- Walk the program headers, mapping each PT_LOAD segment -------------
    var ph: usize = 0;
    var loaded: usize = 0; // count of PT_LOAD segments actually mapped
    while (ph < e_phnum) : (ph += 1) {
        const off = @as(usize, @intCast(e_phoff)) + ph * @as(usize, e_phentsize);
        const phdr = file[off .. off + e_phentsize];
        const p_type = rd32(phdr, 0); // segment type
        if (p_type != PT_LOAD) continue; // skip everything but loadable segments

        // The ELF64 program-header layout (offsets within the 56-byte entry):
        //   0  p_type (u32)   4  p_flags (u32)   8  p_offset (u64)
        //   16 p_vaddr (u64) 24  p_paddr  (u64) 32  p_filesz (u64)
        //   40 p_memsz (u64) 48  p_align  (u64)
        const p_flags = rd32(phdr, 4); // R/W/X permission bits
        const p_offset = rd64(phdr, 8); // where the bytes live in the file
        const p_vaddr = rd64(phdr, 16) + bias; // where they end up (slid by the load bias)
        const p_filesz = rd64(phdr, 32); // how many bytes come from the file
        const p_memsz = rd64(phdr, 40); // total in-memory size (>= filesz; tail is .bss)

        // --- Bounds-check the segment's virtual range BEFORE mapping anything ---
        // A crafted ELF can name any p_vaddr; without this, loadElf() would map a
        // segment wherever the header says — potentially over the kernel image,
        // the HHDM, or (in a process space) the shared kernel half. Reject any
        // segment whose [p_vaddr, p_vaddr+p_memsz) range escapes user space.
        const seg_end_check = p_vaddr +% p_memsz; // exclusive end (overflow-safe add)
        if (seg_end_check < p_vaddr) { // the add wrapped: p_memsz pushed past u64 max
            teardown();
            return null;
        }
        if (target_space != 0) {
            // Ring 3: the whole segment must live STRICTLY in the low (user) half.
            // p_vaddr below the limit and the exclusive end at-or-below it keeps
            // the entire range in user space (slot 0..255).
            if (!(p_vaddr < USER_LIMIT and seg_end_check <= USER_LIMIT)) {
                serial.print("[LOADER]   ELF rejected: segment {d} vaddr 0x{x} outside user space.\n", .{ ph, p_vaddr });
                teardown();
                return null;
            }
        } else {
            // Ring 0: a kernel image must live in the higher half. A segment whose
            // vaddr falls in the user range is a user binary mislabeled for kernel
            // execution — reject it rather than run user code at ring 0.
            if (p_vaddr < USER_LIMIT) {
                teardown();
                return null;
            }
        }

        if (p_memsz == 0) continue; // an empty segment maps nothing
        if (p_memsz < p_filesz) { // a malformed header — bss can't be negative
            teardown();
            return null;
        }
        const file_end = p_offset +% p_filesz; // overflow-safe end of the file region
        if (file_end < p_offset or file_end > file.len) { // wrapped, or past EOF
            teardown();
            return null;
        }

        // The segment occupies [p_vaddr, p_vaddr+p_memsz). Page tables work in
        // whole pages, so we map from the page CONTAINING p_vaddr up to the page
        // containing the last byte. `delta` is how far p_vaddr sits into its
        // first page — the file bytes start there, not at the page boundary.
        const seg_start = pageDown(p_vaddr);
        const seg_end = p_vaddr + p_memsz; // exclusive (overflow already ruled out above)
        if (seg_end < seg_start) { // belt-and-braces: never compute a wrapped page count
            teardown();
            return null;
        }
        const npages = (seg_end - seg_start + PAGE_SIZE - 1) / PAGE_SIZE;
        if (mapped_count + npages > MAX_PAGES) {
            teardown();
            return null;
        }

        // Stage 1 (per segment): map every page of the segment RW + NX. Each
        // frame comes back zeroed from the PMM, which means the .bss tail
        // (p_memsz beyond p_filesz) is already zero — no extra clearing needed.
        var pg: u64 = 0;
        while (pg < npages) : (pg += 1) {
            const virt = seg_start + pg * PAGE_SIZE;
            // A page can already be mapped if two segments share it (rare, but
            // legal). Reuse the existing frame instead of leaking the old one.
            if (findFrame(virt)) |_| {} else {
                if (!mapWritable(virt)) return null; // mapWritable tears down on OOM
            }
        }

        // Stage 2 (per segment): copy p_filesz file bytes to p_vaddr. The pages
        // are writable+NX right now, so this is W^X-safe. The bytes land at the
        // exact virtual address (delta into the first page); the remainder up to
        // p_memsz is the already-zeroed .bss tail. copyInto reaches the pages
        // correctly whether they're live (ring 0) or in a process space (ring 3).
        if (p_filesz > 0) {
            const src = file[@intCast(p_offset) .. @intCast(p_offset + p_filesz)];
            copyInto(p_vaddr, src);
        }

        // Stage 3 (per segment): remap every page to the segment's REAL
        // permissions, derived from p_flags. W^X is enforced here: a segment is
        // never both writable and executable — if a (broken) header asks for
        // both, we keep it writable and strip execute. flags=0 is RX read-only;
        // FLAG_WRITE adds write; FLAG_NX removes execute.
        const want_x = (p_flags & PF_X) != 0;
        const want_w = (p_flags & PF_W) != 0;
        var flags: u64 = 0; // start from present + RX read-only
        if (want_w) {
            flags |= vmm.FLAG_WRITE | vmm.FLAG_NX; // writable => non-executable (W^X)
        } else if (!want_x) {
            flags |= vmm.FLAG_NX; // read-only data => non-executable
        } // else: executable, read-only => flags stays 0 (RX)

        pg = 0;
        while (pg < npages) : (pg += 1) {
            const virt = seg_start + pg * PAGE_SIZE;
            const frame = findFrame(virt) orelse continue; // always present after stage 1
            remap(virt, frame, flags); // re-apply with final perms (user path ORs in USER)
        }

        const perm = if (want_x and !want_w) "R-X" else if (want_w) "RW-" else "R--";
        serial.print("[LOADER]   PT_LOAD seg {d}: vaddr 0x{x} filesz {d} memsz {d} -> {d} page(s) {s}.\n", .{ ph, p_vaddr, p_filesz, p_memsz, npages, perm });
        loaded += 1;
    }

    if (loaded == 0) { // an ELF with no loadable content can't be run
        teardown();
        return null;
    }

    // The entry point is e_entry slid by the same bias; the caller runs it.
    return e_entry + bias;
}

// Find the frame we mapped at virtual address `virt`, if any. Linear scan; the
// page count per image is tiny (<= MAX_PAGES), so this is cheap.
fn findFrame(virt: u64) ?u64 {
    var i: usize = 0;
    while (i < mapped_count) : (i += 1) {
        if (mapped_virt[i] == virt) return mapped_frame[i];
    }
    return null;
}

// === Shared run + teardown ===================================================
// Call the entry point under the binary contract, report the result, then unmap
// the whole image and free its frames so repeated execs don't leak. Returns
// whether the program came back with INIT_MAGIC.
fn runAndTeardown(entry_addr: u64) bool {
    serial.print("[LOADER]   calling entry point 0x{x}...\n", .{entry_addr});
    const entry: *const fn () callconv(.C) u64 = @ptrFromInt(entry_addr);
    const ret = entry(); // the init program runs here, then rets back to us

    const ok = ret == INIT_MAGIC;
    if (ok) {
        serial.print("[LOADER]   init returned 0x{x} (magic OK).\n", .{ret});
    }

    const freed = mapped_count;
    teardown(); // unmap every page + free every frame, reset bookkeeping
    serial.print("[LOADER]   image unmapped, {d} frame(s) freed.\n", .{freed});
    return ok;
}

// --- Boot self-test ----------------------------------------------------------
// If the mounted disk carries an /INIT binary, load and run it as a RING-3
// PROCESS — proving the full pipeline (disk -> FAT32 -> parsed/mapped into a
// fresh user address space -> executed at CPL3 -> exited via the exit syscall)
// end to end. Prefers a real ELF at /INIT.ELF if present, then falls back to
// /INIT (which may itself be ELF or flat — execUser auto-detects). Skips quietly
// when there's no disk or no init binary, so disk-less boots are unaffected.
//
// MUST run after gdt/idt/syscall init (so ring 3 works) but it can run before the
// scheduler is brought up: it uses the standalone runner, which adopts a throwaway
// thread context just long enough to run the one process.
pub fn selfTest() void {
    if (!fat32.isMounted()) {
        serial.print("[LOADER] self-test skipped (no filesystem mounted).\n", .{});
        return;
    }
    // Prefer the ELF init if it exists; otherwise the legacy /INIT.
    const path: []const u8 = if (fat32.resolve("/INIT.ELF") != null)
        "/INIT.ELF"
    else if (fat32.resolve("/INIT") != null)
        "/INIT"
    else {
        serial.print("[LOADER] self-test skipped (no /INIT.ELF or /INIT on the disk).\n", .{});
        return;
    };
    if (execUserCtx(path, true)) {
        serial.print("[LOADER] init ran and exited cleanly.\n", .{});
    }
}
