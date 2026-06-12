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

// Where a *flat* binary is loaded and entered. This is PML4 slot 416
// (0xffffd...): a top-level slot of its own, comfortably away from the HHDM
// (slots 256+), the kernel heap (slot 384, 0xffffc...) and the kernel image
// (slot 511). An ELF, by contrast, is loaded at whatever virtual addresses its
// program headers name — our test ELF is linked into this same slot so it lands
// in the same safely-unused region.
pub const LOAD_BASE: u64 = 0xffffd00000000000;

// The "ran to completion" value an init binary returns in rax.
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
// half-built image on any error — so a failed load leaks nothing.
fn teardown() void {
    var i: usize = 0;
    while (i < mapped_count) : (i += 1) {
        vmm.unmap(mapped_virt[i]); // drop the mapping (+ flush its TLB entry)
        pmm.free(mapped_frame[i]); // give the frame back
    }
    mapped_count = 0; // armed clean for the next exec
}

// Allocate a fresh zeroed frame and map it at `virt` as WRITABLE + NO-EXECUTE —
// the W^X-safe state for a page we are about to write bytes into. Records it for
// teardown. Returns false (after unwinding everything mapped so far) on OOM.
fn mapWritable(virt: u64) bool {
    const frame = pmm.allocZeroed() orelse { // a zeroed frame guarantees a zeroed .bss tail
        serial.print("[LOADER] out of physical memory mapping 0x{x}.\n", .{virt});
        teardown(); // unwind the whole partially-built image
        return false;
    };
    vmm.map(virt, frame, vmm.FLAG_WRITE | vmm.FLAG_NX); // present + writable + non-exec
    track(virt, frame);
    return true;
}

// === Public entry point ======================================================
// Load the binary at `path` and run it. Returns true only if it loaded, ran, and
// came back with INIT_MAGIC. Safe to call repeatedly: each call builds a fresh
// image and tears it down again afterwards. Picks the ELF or flat path by the
// file's first bytes.
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
    if (node.size > file_buf.len) {
        serial.print("[LOADER] {s} is too big ({d} bytes; cap is {d}).\n", .{ path, node.size, file_buf.len });
        return false;
    }

    // Slurp the whole file into the scratch buffer. Both loaders work from this
    // copy: the flat loader copies it straight to LOAD_BASE; the ELF loader
    // parses it and scatters its segments to their linked addresses.
    const got = fat32.readFile(path, file_buf[0..node.size]) orelse {
        serial.print("[LOADER] disk read failed for {s}.\n", .{path});
        return false;
    };
    const file = file_buf[0..got];
    serial.print("[LOADER] Loading {s}: {d} bytes read from disk.\n", .{ path, got });

    // Sniff the format: an ELF starts with the 4-byte magic "\x7fELF".
    if (got >= 4 and file[0] == 0x7f and file[1] == 'E' and file[2] == 'L' and file[3] == 'F') {
        return execElf(file);
    }
    return execFlat(file);
}

// === Flat binary path ========================================================
// The original "version 0" format: raw machine code, entered at byte 0, loaded
// at the fixed LOAD_BASE. Kept verbatim so hand-assembled blobs keep working.
fn execFlat(file: []const u8) bool {
    const pages: usize = (file.len + @as(usize, PAGE_SIZE) - 1) / @as(usize, PAGE_SIZE); // round up
    if (pages > MAX_PAGES) {
        serial.print("[LOADER] flat image too big ({d} pages; cap is {d}).\n", .{ pages, MAX_PAGES });
        return false;
    }
    serial.print("[LOADER]   flat binary -> {d} page(s) at 0x{x}.\n", .{ pages, LOAD_BASE });

    // Stage 1: back the image with fresh zeroed frames, mapped WRITABLE + NX —
    // we're about to write file bytes into them, and W^X forbids a writable page
    // from also being executable.
    var i: usize = 0;
    while (i < pages) : (i += 1) {
        if (!mapWritable(LOAD_BASE + i * PAGE_SIZE)) return false; // mapWritable unwinds on OOM
    }

    // Stage 2: copy the file bytes into the mapped pages (the tail of the last
    // page stays zero, which is harmless for flat code).
    const dst = @as([*]u8, @ptrFromInt(LOAD_BASE))[0..file.len];
    @memcpy(dst, file);
    serial.print("[LOADER]   copied {d} bytes (pages RW+NX while writing).\n", .{file.len});

    // Stage 3: flip every page to READ-ONLY + EXECUTABLE. flags=0 means present,
    // not writable, and (no NX bit) executable — i.e. RX. vmm.map overwrites the
    // existing leaf and flushes its TLB entry.
    i = 0;
    while (i < pages) : (i += 1) {
        vmm.map(LOAD_BASE + i * PAGE_SIZE, mapped_frame[i], 0); // RX read-only
    }
    serial.print("[LOADER]   remapped RX read-only (W^X held at every step).\n", .{});

    return runAndTeardown(LOAD_BASE); // flat entry is always byte 0 == LOAD_BASE
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

// Parse, lay out, and run a static ELF64 executable. `file` is the whole file.
fn execElf(file: []const u8) bool {
    // --- Validate the ELF header -------------------------------------------
    // 64 bytes minimum just to read the header fields safely.
    if (file.len < 64) {
        serial.print("[LOADER]   ELF rejected: file shorter than its 64-byte header.\n", .{});
        return false;
    }
    // e_ident[4]=class, [5]=data, [6]=version. (The 4-byte magic was checked by
    // the caller.) We only run little-endian 64-bit objects.
    if (file[4] != ELFCLASS64) {
        serial.print("[LOADER]   ELF rejected: not ELFCLASS64 (e_ident[4]={d}).\n", .{file[4]});
        return false;
    }
    if (file[5] != ELFDATA2LSB) {
        serial.print("[LOADER]   ELF rejected: not little-endian (e_ident[5]={d}).\n", .{file[5]});
        return false;
    }
    const e_type = rd16(file, 16); // ET_EXEC or ET_DYN
    const e_machine = rd16(file, 18); // must be x86-64
    const e_entry = rd64(file, 24); // virtual address of the first instruction
    const e_phoff = rd64(file, 32); // file offset of the program header table
    const e_phentsize = rd16(file, 54); // size of one program header entry
    const e_phnum = rd16(file, 56); // number of program header entries

    if (e_machine != EM_X86_64) {
        serial.print("[LOADER]   ELF rejected: machine {d} is not x86-64 (62).\n", .{e_machine});
        return false;
    }
    if (e_type != ET_EXEC and e_type != ET_DYN) {
        serial.print("[LOADER]   ELF rejected: type {d} is not ET_EXEC/ET_DYN.\n", .{e_type});
        return false;
    }
    if (e_phnum == 0 or e_phentsize < 56) { // a 64-bit program header is 56 bytes
        serial.print("[LOADER]   ELF rejected: bad program header table ({d} x {d} bytes).\n", .{ e_phnum, e_phentsize });
        return false;
    }
    // The whole program header table must lie within the file we read.
    const phtab_end = e_phoff + @as(u64, e_phnum) * @as(u64, e_phentsize);
    if (phtab_end > file.len) {
        serial.print("[LOADER]   ELF rejected: program headers run past end of file.\n", .{});
        return false;
    }
    serial.print("[LOADER]   ELF64 {s}, entry 0x{x}, {d} program header(s).\n", .{ if (e_type == ET_EXEC) "ET_EXEC" else "ET_DYN", e_entry, e_phnum });

    // Load bias. An ET_EXEC names absolute virtual addresses and must load
    // exactly where it says (bias 0). An ET_DYN (a PIE) is linked relative to 0
    // and may be placed anywhere — we slide it up to LOAD_BASE so its low-half
    // p_vaddrs land in our safely-unused higher-half slot rather than in the
    // (unmapped) user range. NOTE: this is only correct for PIEs whose code is
    // purely RIP-relative; we do NOT apply R_X86_64_RELATIVE relocations, so a
    // PIE that depends on absolute pointers would need a relocation pass (a
    // later task). ET_EXEC, our primary format, is unaffected.
    const bias: u64 = if (e_type == ET_DYN) LOAD_BASE else 0;

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

        if (p_memsz == 0) continue; // an empty segment maps nothing
        if (p_memsz < p_filesz) { // a malformed header — bss can't be negative
            serial.print("[LOADER]   ELF rejected: segment {d} has memsz < filesz.\n", .{ph});
            teardown();
            return false;
        }
        if (p_offset + p_filesz > file.len) { // its file bytes must be present
            serial.print("[LOADER]   ELF rejected: segment {d} file bytes past end of file.\n", .{ph});
            teardown();
            return false;
        }

        // The segment occupies [p_vaddr, p_vaddr+p_memsz). Page tables work in
        // whole pages, so we map from the page CONTAINING p_vaddr up to the page
        // containing the last byte. `delta` is how far p_vaddr sits into its
        // first page — the file bytes start there, not at the page boundary.
        const seg_start = pageDown(p_vaddr);
        const seg_end = p_vaddr + p_memsz; // exclusive
        const npages = (seg_end - seg_start + PAGE_SIZE - 1) / PAGE_SIZE;
        if (mapped_count + npages > MAX_PAGES) {
            serial.print("[LOADER]   ELF rejected: segment {d} exceeds the {d}-page cap.\n", .{ ph, MAX_PAGES });
            teardown();
            return false;
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
                if (!mapWritable(virt)) return false; // mapWritable tears down on OOM
            }
        }

        // Stage 2 (per segment): copy p_filesz file bytes to p_vaddr. The pages
        // are writable+NX right now, so this is W^X-safe. The bytes land at the
        // exact virtual address (delta into the first page); the remainder up to
        // p_memsz is the already-zeroed .bss tail.
        if (p_filesz > 0) {
            const src = file[@intCast(p_offset) .. @intCast(p_offset + p_filesz)];
            const dst = @as([*]u8, @ptrFromInt(p_vaddr))[0..@intCast(p_filesz)];
            @memcpy(dst, src);
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
            vmm.map(virt, frame, flags); // re-apply with final perms (+ TLB flush)
        }

        const perm = if (want_x and !want_w) "R-X" else if (want_w) "RW-" else "R--";
        serial.print("[LOADER]   PT_LOAD seg {d}: vaddr 0x{x} filesz {d} memsz {d} -> {d} page(s) {s}.\n", .{ ph, p_vaddr, p_filesz, p_memsz, npages, perm });
        loaded += 1;
    }

    if (loaded == 0) { // an ELF with no loadable content can't be run
        serial.print("[LOADER]   ELF rejected: no PT_LOAD segments.\n", .{});
        teardown();
        return false;
    }
    serial.print("[LOADER]   {d} segment(s) mapped (per-segment W^X held).\n", .{loaded});

    // Hand control to e_entry (slid by the same bias); teardown afterwards no
    // matter how it returns.
    return runAndTeardown(e_entry + bias);
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
    } else {
        serial.print("[LOADER]   init returned 0x{x} (expected magic 0x{x}).\n", .{ ret, INIT_MAGIC });
    }

    const freed = mapped_count;
    teardown(); // unmap every page + free every frame, reset bookkeeping
    serial.print("[LOADER]   image unmapped, {d} frame(s) freed.\n", .{freed});
    return ok;
}

// --- Boot self-test ----------------------------------------------------------
// If the mounted disk carries an /INIT binary, load and run it — proving the
// full pipeline (disk -> FAT32 -> parsed/mapped memory -> executed code ->
// clean return) end to end. Prefers a real ELF at /INIT.ELF if present, then
// falls back to /INIT (which may itself be ELF or flat — exec auto-detects).
// Skips quietly when there's no disk or no init binary, so disk-less boots are
// unaffected.
pub fn selfTest() void {
    serial.print("[LOADER] Init-loader self-test...\n", .{});
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
    serial.print("[LOADER] self-test exec {s}...\n", .{path});
    if (exec(path)) {
        serial.print("[LOADER] init ran and exited cleanly.\n", .{});
    } else {
        serial.print("[LOADER] init FAILED.\n", .{});
    }
}
