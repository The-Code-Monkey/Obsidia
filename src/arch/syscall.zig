// SYSCALL/SYSRET — the fast ring-3 <-> ring-0 transition the userspace arc rides on.
//
// `syscall` (executed in ring 3) jumps to the address in LSTAR at ring 0 with
// interrupts masked (per SFMASK), saving the user RIP in RCX and RFLAGS in R11.
// It does NOT switch the stack, so our entry stub swaps to a kernel stack first.
// `sysretq` returns to ring 3: RIP from RCX, RFLAGS from R11, and CS/SS derived
// from STAR[63:48]. SYSRET fixes the user selectors at base+16 (code) / base+8
// (data) — which is exactly why the GDT now lists user DATA before user CODE
// (see gdt.zig). With KERNEL_CODE=0x08, KERNEL_DATA=0x10 and the user descriptors
// at 0x18 (data) / 0x20 (code), a sysret base of 0x10 yields user CS 0x23 / SS 0x1b.
//
// Stage 1 wires the full round trip and proves it with one test syscall; the real
// syscall table (write/exit/yield) lands next.

const serial = @import("../drivers/serial.zig");
const gdt = @import("gdt.zig");
const cpu = @import("cpu.zig");
const scheduler = @import("../sched/scheduler.zig"); // SYS_yield hands off the CPU + per-process fd table
const vmm = @import("../mm/vmm.zig"); // validate user pointers against the page tables
const fat32 = @import("../fs/fat32.zig"); // self-test: gate on the FAT32 disk being mounted
const vfs = @import("../fs/vfs.zig"); // file syscalls route through the VFS (any backend)

// A dedicated ring-0 stack the entry stub switches to (`syscall` doesn't load one
// for us). A single static stack is safe for now because the handler runs with
// interrupts masked on a single core; Stage 4 gives each process its own kernel
// stack via TSS.rsp0.
const SYSCALL_STACK_SIZE = 0x4000; // 16 KiB
var syscall_stack: [SYSCALL_STACK_SIZE]u8 align(16) = undefined;
export var syscall_kernel_rsp: u64 = 0; // kernel stack the entry stub switches to
export var syscall_user_rsp: u64 = 0; // scratch: the user RSP saved on entry

// Point the syscall entry at a specific kernel stack. The scheduler calls this on
// every switch so a `syscall` from the running user process lands on ITS kernel
// stack (mirrors gdt.setKernelStack for the interrupt path). The default static
// stack set in init() serves the boot self-test, before processes exist.
pub fn setKernelStack(top: u64) void {
    syscall_kernel_rsp = top;
}

// --- The syscall table -------------------------------------------------------
// Numbers the user passes in RAX. Small values so a user stub can load them with
// a plain `mov eax, imm32`.
pub const SYS_write: u64 = 1; // write(fd, ptr, len) -> bytes written
pub const SYS_yield: u64 = 2; // yield() -> 0 (hand the CPU to another thread)
pub const SYS_exit: u64 = 3; // exit(code) -> does not return
pub const SYS_open: u64 = 4; // open(path, len) -> fd (lowest free, >= 3) or -errno
pub const SYS_close: u64 = 5; // close(fd) -> 0, or -errno
pub const SYS_read: u64 = 6; // read(fd, ptr, len) -> bytes read (0 = EOF) or -errno
pub const SYS_lseek: u64 = 7; // lseek(fd, off, whence) -> new offset or -errno
pub const SYS_dup: u64 = 8; // dup(fd) -> new fd (lowest free) or -errno
pub const SYS_wait: u64 = 9; // wait(status_ptr) -> pid of the reaped child, or -ECHILD

const ENOSYS: u64 = @bitCast(@as(i64, -38)); // unknown syscall
const EBADF: u64 = @bitCast(@as(i64, -9)); // bad file descriptor
const EFAULT: u64 = @bitCast(@as(i64, -14)); // bad (out-of-bounds) user address
const EINVAL: u64 = @bitCast(@as(i64, -22)); // invalid argument (e.g. bad whence)
const EMFILE: u64 = @bitCast(@as(i64, -24)); // too many open files (fd table full)
const ENOENT: u64 = @bitCast(@as(i64, -2)); // no such file or directory
const ECHILD: u64 = @bitCast(@as(i64, -10)); // wait() with no child to wait for
const ESPIPE: u64 = @bitCast(@as(i64, -29)); // lseek on an unseekable fd (e.g. /dev/zero)

// lseek `whence` values (POSIX): the offset is interpreted relative to the start
// of the file, the current cursor, or the end of the file respectively.
pub const SEEK_SET: u64 = 0; // absolute offset from the beginning
pub const SEEK_CUR: u64 = 1; // relative to the current position
pub const SEEK_END: u64 = 2; // relative to end-of-file

// First address above the canonical low half: every user buffer must lie below
// it, so a syscall can never be tricked into reading higher-half kernel memory.
const USER_LIMIT: u64 = 0x0000_8000_0000_0000;

// exit() has no real meaning until processes exist (Stage 4/5). For now a caller
// (the self-test, later the loader) installs a handler that returns control to
// the kernel; this mirrors idt.fault_hook. noreturn — it never comes back here.
pub var exit_handler: ?*const fn (code: u64) callconv(.c) noreturn = null;

// The C-ABI dispatcher the entry stub calls: syscall number in RDI, then up to
// three args (a1..a3) marshalled from the user's RDI/RSI/RDX. Returns the result
// (or a negative errno) in RAX.
export fn syscallDispatch(num: u64, a1: u64, a2: u64, a3: u64) callconv(.c) u64 {
    return switch (num) {
        SYS_write => sysWrite(a1, a2, a3),
        SYS_yield => sysYield(),
        SYS_exit => sysExit(a1),
        SYS_open => sysOpen(a1, a2),
        SYS_close => sysClose(a1),
        SYS_read => sysRead(a1, a2, a3),
        SYS_lseek => sysLseek(a1, a2, a3),
        SYS_dup => sysDup(a1),
        SYS_wait => sysWait(a1),
        else => ENOSYS,
    };
}

// A user file descriptor is valid only if it indexes the table and names an open
// file. Returns a pointer to the slot's OpenFile, or null for a bad descriptor
// (so callers can map that to EBADF). fd 0/1/2 are reserved and never hold a file.
fn openFileFor(fd: u64) ?*scheduler.OpenFile {
    if (fd >= scheduler.FD_MAX) return null; // out of table range
    const table = scheduler.currentFdTable();
    if (table[fd]) |*f| return f; // an open file lives here
    return null; // empty slot -> bad descriptor
}

// write(fd, ptr, len): copy `len` bytes from the user buffer to serial (the only
// sink for now). fd 1 (stdout) / 2 (stderr) only — any other descriptor is EBADF.
// The order of checks matters: a bad descriptor is reported (EBADF) before the
// buffer is even looked at, matching POSIX (and the behavior this syscall had
// before the fd table existed).
fn sysWrite(fd: u64, ptr: u64, len: u64) u64 {
    // Validate the descriptor FIRST (EBADF before EFAULT, like POSIX): fd 1 (stdout)
    // / 2 (stderr) go to the serial console (the only terminal sink we have); any
    // other fd must name a file the process opened, or it's a bad descriptor.
    // Write-to-file isn't a streaming append yet: the FAT32 write path (writeFile)
    // overwrites a whole file at once, so a file-fd write here would be a
    // no-op-or-clobber. We therefore reject file-fd writes for now (EBADF) and keep
    // fd 1/2 -> serial; the read/seek/dup side is this milestone. (A buffered
    // file-append write is a clean follow-up.)
    if (fd != 1 and fd != 2) return EBADF;
    if (len == 0) return 0;
    const n = @min(len, 4096);
    // Validate the user buffer in two steps so a hostile or buggy caller can never
    // make the kernel touch memory it shouldn't: first a RANGE check (the whole
    // buffer lies in the user half, below USER_LIMIT — not the kernel's higher
    // half), then a PAGE check (every page is actually mapped + user-accessible in
    // the caller's address space). Without the page check an in-range but unmapped
    // pointer would fault the kernel mid-deref; with it we return EFAULT instead.
    if (ptr >= USER_LIMIT or n > USER_LIMIT - ptr) return EFAULT; // buffer escapes user space
    if (!vmm.userRangeAccessible(vmm.activeSpace(), ptr, n)) return EFAULT; // unmapped / kernel-only page
    // This is one of the few places the kernel dereferences a raw user pointer.
    // With SMAP on, a ring-0 access to a U=1 page faults unless we lift the guard:
    // STAC sets RFLAGS.AC (access allowed), CLAC clears it again. We re-arm via
    // defer so the window is exactly the buffer copy below and nothing more —
    // leaving AC set would silently disable SMAP for the rest of this syscall.
    asm volatile ("stac");
    defer asm volatile ("clac");
    const buf = @as([*]const u8, @ptrFromInt(ptr))[0..n];
    serial.print("{s}", .{buf});
    return n;
}

// yield(): cooperatively hand the CPU to the next ready thread.
fn sysYield() u64 {
    scheduler.yield();
    return 0;
}

// exit(code): terminate the caller. Routes to the installed handler (which longjmps
// back to whoever launched the user code); becomes real process teardown later.
fn sysExit(code: u64) u64 {
    if (exit_handler) |h| h(code); // noreturn
    // No handler installed: this is a kernel bug (one is always set before user
    // code runs). Nothing we can do but refuse to terminate the caller.
    return ENOSYS;
}

// --- File syscalls -----------------------------------------------------------
// Longest path the kernel will accept from a user open(). FAT32 paths are short;
// a fixed kernel buffer means we never allocate (or trust a user length blindly).
const PATH_MAX = 256;

// open(path, len): resolve the NUL-free path string at user address `path` (with
// length `len`) on the FAT32 disk and, if it names a regular file, install it in
// the lowest free descriptor (>= 3) of the calling process. Returns that fd, or a
// negative errno. The user pointer is validated exactly like sysWrite's buffer —
// range check (whole string in the user half) then page check — before the single
// guarded (STAC/CLAC) copy into a kernel buffer; nothing past that touches user
// memory, so resolve()/open() run on a trusted copy.
fn sysOpen(path: u64, len: u64) u64 {
    if (len == 0 or len > PATH_MAX) return EINVAL; // empty or implausibly long path
    if (path >= USER_LIMIT or len > USER_LIMIT - path) return EFAULT; // escapes user space
    if (!vmm.userRangeAccessible(vmm.activeSpace(), path, len)) return EFAULT; // unmapped / kernel-only

    // Copy the path out of user memory into a kernel buffer under the SMAP guard,
    // so the rest of this syscall never re-touches the (possibly racing) user page.
    var kbuf: [PATH_MAX]u8 = undefined;
    {
        asm volatile ("stac");
        defer asm volatile ("clac");
        const ubuf = @as([*]const u8, @ptrFromInt(path))[0..len];
        @memcpy(kbuf[0..len], ubuf);
    }
    const name = kbuf[0..len];

    // Route through the VFS, so `name` can live on ANY mounted backend — the FAT32
    // disk at "/", tmpfs at "/tmp", or devfs at "/dev" — not just the FAT32 disk.
    // stat() distinguishes "missing" (ENOENT) from "is a directory" (EINVAL); open()
    // returns false for either, so we stat first to give a precise errno.
    const node = vfs.stat(name) orelse return ENOENT;
    if (node.kind == .dir) return EINVAL; // can't open a directory as a readable file
    var handle: vfs.OpenFile = undefined;
    if (!vfs.open(name, &handle)) return ENOENT; // (re-checks mount/path)
    return scheduler.allocFd(.{ .file = handle }) orelse EMFILE; // table full -> EMFILE
}

// close(fd): drop the descriptor, freeing its slot for a future open/dup. Reading
// or writing a closed fd afterwards returns EBADF. Closing a non-open fd is EBADF.
fn sysClose(fd: u64) u64 {
    if (fd >= scheduler.FD_MAX) return EBADF; // out of table range
    const table = scheduler.currentFdTable();
    if (table[fd] == null) return EBADF; // wasn't open
    table[fd] = null; // free the slot (the VFS handle holds no resources to release)
    return 0;
}

// read(fd, ptr, len): copy up to `len` bytes from the open file at `fd` into the
// user buffer at `ptr`, advancing the file's cursor. Returns the byte count (0 at
// end of file), or a negative errno. The user buffer is validated like sysWrite's,
// and the copy into it happens under the SMAP guard.
fn sysRead(fd: u64, ptr: u64, len: u64) u64 {
    const file = openFileFor(fd) orelse return EBADF; // bad/closed descriptor
    if (len == 0) return 0;
    const n = @min(len, 4096); // bound a single read like sysWrite bounds a write
    if (ptr >= USER_LIMIT or n > USER_LIMIT - ptr) return EFAULT; // escapes user space
    if (!vmm.userRangeAccessible(vmm.activeSpace(), ptr, n)) return EFAULT; // unmapped / kernel-only
    // Drive the VFS reader straight into the validated user buffer (under STAC/CLAC).
    // The backend's read may itself do disk I/O while AC is set; that's fine — it only
    // writes to `dst`, which is the user page we just OK'd. vfs read also advances the
    // handle's absolute offset, keeping lseek's SEEK_CUR correct.
    asm volatile ("stac");
    defer asm volatile ("clac");
    const dst = @as([*]u8, @ptrFromInt(ptr))[0..n];
    return file.file.read(dst); // bytes copied (0 = EOF)
}

// lseek(fd, off, whence): move the open file's read cursor and return the new
// absolute offset. SEEK_SET sets it to `off`, SEEK_CUR adds `off` to the current
// position, SEEK_END sets it to (size + off). `off` is a SIGNED byte count (passed
// as a u64 bit pattern), so a negative SEEK_CUR/SEEK_END rewinds. Out-of-range
// results clamp to [0, size]. Returns the new offset, or a negative errno: EBADF for
// a bad fd, EINVAL for an unknown whence, ESPIPE for an unseekable backend (a
// character device like /dev/zero, whose VFS backend has no seek slot).
fn sysLseek(fd: u64, off: u64, whence: u64) u64 {
    const file = openFileFor(fd) orelse return EBADF;
    // The VFS owns the offset math (i128, clamped to [0, size]) and the per-backend
    // reposition. It returns null when the file can't seek (no seek slot). We can't
    // tell "unseekable" from "bad whence" through one null, so reject the only bad
    // whence up front (giving EINVAL) and treat any remaining null as ESPIPE.
    if (whence != SEEK_SET and whence != SEEK_CUR and whence != SEEK_END) return EINVAL;
    const landed = vfs.seek(&file.file, whence, @bitCast(off)) orelse return ESPIPE;
    return @intCast(landed); // report where we actually landed
}

// dup(fd): allocate the lowest free descriptor referring to the same open file as
// `fd`. We copy the VFS handle, so the new descriptor starts at the SAME cursor
// position but then advances independently (a simple model; shared offsets are a
// later refinement). Returns the new fd, or a negative errno.
fn sysDup(fd: u64) u64 {
    const file = openFileFor(fd) orelse return EBADF; // nothing to duplicate
    return scheduler.allocFd(file.*) orelse EMFILE; // copy the cursor into a new slot
}

// wait(status_ptr): block until the calling thread's most-recently-spawned child
// process finishes, collect (reap) it, and return its PID. If `status_ptr` is
// non-null, the child's exit code is written there (so the parent learns both WHICH
// child ended and HOW). With no child to wait on we return ECHILD (POSIX), matching
// `waitpid` when the caller has no unwaited children. This is the syscall face of
// scheduler.waitForChild(): the scheduler does the block-until-zombie + reap; this
// handler just validates the user pointer and marshals the result.
//
// status_ptr is validated exactly like every other user pointer: a RANGE check (the
// 8-byte word lies in the user half, below USER_LIMIT) then a PAGE check (mapped +
// user-accessible), and the single store is bracketed by STAC/CLAC so SMAP stays
// armed everywhere else. status_ptr == 0 means "don't report the code" (POSIX NULL).
//
// Validation happens BEFORE we collect the child: waitForChild() reaps the zombie
// (the child is gone afterwards, its exit code unrecoverable), so a bad status_ptr
// must be rejected up front — otherwise wait(badptr) would silently consume the
// child and the parent could never learn how it ended. With the check first, an
// EFAULT leaves the child still waitable for a retry with a good pointer.
fn sysWait(status_ptr: u64) u64 {
    if (status_ptr != 0) { // the caller wants the exit code written back: vet the pointer first
        if (status_ptr >= USER_LIMIT or 8 > USER_LIMIT - status_ptr) return EFAULT; // escapes user space
        if (!vmm.userRangeAccessible(vmm.activeSpace(), status_ptr, 8)) return EFAULT; // unmapped / kernel-only
    }
    const result = scheduler.waitForChild(); // block-until-zombie -> read code -> reap
    if (result.pid == scheduler.noChild()) return ECHILD; // nothing to wait on
    if (status_ptr != 0) { // pointer already validated above; just do the guarded store
        asm volatile ("stac"); // lift SMAP for exactly this one store
        defer asm volatile ("clac");
        @as(*u64, @ptrFromInt(status_ptr)).* = result.code; // hand the exit code back to ring 3
    }
    return result.pid; // the reaped child's PID (its thread-table slot index)
}

// The `syscall` entry point (the LSTAR target). Global naked asm: switch to the
// kernel stack, preserve the user RIP (RCX) and RFLAGS (R11) across the dispatch,
// call the Zig dispatcher, then sysretq back to ring 3 with the result in RAX.
extern fn syscallEntry() callconv(.c) void;
comptime {
    asm (
        \\.global syscallEntry
        \\.type syscallEntry, @function
        \\syscallEntry:
        \\  movq %rsp, syscall_user_rsp(%rip)     // stash the user RSP
        \\  movq syscall_kernel_rsp(%rip), %rsp    // switch to the kernel stack
        \\  pushq %rcx                             // save user RIP (sysret restores it)
        \\  pushq %r11                             // save user RFLAGS (ditto)
        \\  // Marshal the user's syscall regs (num=RAX, args a1/a2/a3 = RDI/RSI/RDX)
        \\  // into the C ABI (RDI/RSI/RDX/RCX). Done back-to-front so no source is
        \\  // clobbered before it's read. RCX is free here (user RIP already saved).
        \\  movq %rdx, %rcx                        // C arg4 = a3
        \\  movq %rsi, %rdx                        // C arg3 = a2
        \\  movq %rdi, %rsi                        // C arg2 = a1
        \\  movq %rax, %rdi                        // C arg1 = syscall number
        \\  call syscallDispatch                   // result -> RAX
        \\  popq %r11                              // restore user RFLAGS
        \\  popq %rcx                              // restore user RIP
        \\  // Guard the return: a non-canonical RIP makes SYSRET #GP in RING 0
        \\  // (the classic CVE-2012-0217 footgun). If RCX isn't canonical, clamp it
        \\  // to 0 so the fault instead happens harmlessly in ring 3. RDX is dead
        \\  // here (caller-saved, clobbered by the syscall ABI), so use it as scratch.
        \\  movq %rcx, %rdx
        \\  sarq $47, %rdx                         // canonical -> 0 (low half) or -1 (high half)
        \\  incq %rdx                              //           -> 1 or 0
        \\  cmpq $1, %rdx
        \\  jbe 1f                                 // unsigned <= 1: canonical, proceed
        \\  xorq %rcx, %rcx                        // non-canonical: return to RIP 0 (a ring-3 fault)
        \\1:
        \\  movq syscall_user_rsp(%rip), %rsp      // restore the user RSP
        \\  sysretq                                // back to ring 3 (RIP=RCX, RFLAGS=R11)
    );
}

// Program the MSRs so `syscall`/`sysret` work: enable SCE, set the selector bases
// in STAR, the entry point in LSTAR, and the RFLAGS mask in SFMASK. Must run after
// gdt.init() (uses the GDT selectors) and before any user code executes.
pub fn init() void {
    // EFER.SCE turns on the syscall/sysret instructions (preserving NXE etc.).
    cpu.wrmsr(cpu.IA32_EFER, cpu.rdmsr(cpu.IA32_EFER) | cpu.EFER_SCE);

    // STAR: bits 47:32 = kernel CS base (syscall sets CS=base, SS=base+8);
    //       bits 63:48 = sysret base   (sysret sets CS=base+16, SS=base+8).
    // SYSRET forces CS.RPL=3 but does NOT force SS.RPL — SS's RPL comes straight
    // from the base. So the base MUST already carry RPL 3, or SYSRET returns to
    // ring 3 with SS at RPL 0 (e.g. 0x18 instead of 0x1b). That bad SS is harmless
    // until an interrupt is taken from ring 3 and its iretq reloads SS at CPL 3 —
    // RPL 0 vs CPL 3 then #GPs. We use USER_DATA-8 as the base: +8 = USER_DATA
    // (0x1b, the ring-3 SS) and +16 = USER_CODE (0x23, the ring-3 CS), both RPL 3.
    const sysret_base: u64 = gdt.USER_DATA - 8; // 0x13: +8=0x1b (SS), +16=0x23 (CS)
    const star: u64 = (sysret_base << 48) | (@as(u64, gdt.KERNEL_CODE) << 32);
    cpu.wrmsr(cpu.IA32_STAR, star);

    // LSTAR: where `syscall` jumps. SFMASK: clear IF/DF/TF on entry (handler runs
    // with interrupts off, a defined direction flag, and no single-step trap).
    cpu.wrmsr(cpu.IA32_LSTAR, @intFromPtr(&syscallEntry));
    cpu.wrmsr(cpu.IA32_FMASK, 0x700);

    syscall_kernel_rsp = @intFromPtr(&syscall_stack) + syscall_stack.len;
}

// --- File-descriptor / file-syscall boot self-test ---------------------------
// Exercises the new open/read/lseek/dup/close path end to end against a known file
// on the FAT32 disk, through the REAL syscall dispatcher and the REAL user-pointer
// validation (a user-mapped page in a fresh address space, with SMAP armed). It
// proves: open() hands out the lowest free fd (3); read() copies file bytes into a
// validated ring-3 buffer; lseek() repositions the cursor (forward and backward);
// dup() makes an independent second descriptor (4) at the same offset; and close()
// frees a slot. Debug-log-gated (called from main only under -Ddebug-log) and a
// no-op with a clear log line when there's no FAT32 disk, so disk-less boots are
// unaffected. The harness greps the success marker on the FAT32-disk boot.
pub fn selfTest() void {
    const pmm = @import("../mm/pmm.zig"); // a frame for the user buffer page
    const PATH = "/HELLO.TXT"; // seeded by the test harness on the FAT32 disk
    const EXPECT = "Hello from FAT32 on Obsidia!"; // its contents (without the newline)

    if (!fat32.isMounted()) {
        serial.log("[FD] file-syscall self-test skipped (no FAT32 disk).\n", .{});
        return;
    }
    if (fat32.resolve(PATH) == null) {
        serial.log("[FD] file-syscall self-test skipped (no {s}).\n", .{PATH});
        return;
    }

    // Start from an empty descriptor table for the current thread, so open() hands
    // out fd 3 deterministically. (This boot self-test runs after the other demos,
    // which leave a valid thread 0; we only reset its file table, not the thread.)
    scheduler.resetCurrentFds();

    // Build a tiny address space with ONE user-readable/writable data page, and a
    // second page holding the path string the user passes to open(). Switching CR3
    // to it makes vmm.activeSpace() name these tables, so the syscalls' user-pointer
    // checks validate against real ring-3 mappings (exactly like a live process).
    const as = vmm.createAddressSpace() orelse {
        serial.log("[FD] file-syscall self-test: no memory for an address space.\n", .{});
        return;
    };
    // If either frame alloc fails, free everything already taken so the (debug-only,
    // run-once) self-test never leaks an address space or frame under memory pressure.
    const buf_frame = pmm.allocZeroed() orelse {
        vmm.destroyAddressSpace(as);
        return;
    };
    const path_frame = pmm.allocZeroed() orelse {
        pmm.free(buf_frame);
        vmm.destroyAddressSpace(as);
        return;
    };
    const U_BUF: u64 = 0x500000; // ring-3 read buffer
    const U_PATH: u64 = 0x501000; // ring-3 path string
    vmm.mapInto(as, U_BUF, buf_frame, vmm.FLAG_USER | vmm.FLAG_WRITE | vmm.FLAG_NX);
    vmm.mapInto(as, U_PATH, path_frame, vmm.FLAG_USER | vmm.FLAG_WRITE | vmm.FLAG_NX);

    // Seed the path string into the user page via its kernel (HHDM) alias before we
    // switch CR3 — simpler than reaching into the new space afterwards.
    const path_kalias: [*]u8 = @ptrFromInt(pmm.physToVirt(path_frame));
    @memcpy(path_kalias[0..PATH.len], PATH);

    const prev_space = vmm.activeSpace(); // restore the kernel space when we're done
    vmm.switchTo(as);

    // From here on the dispatcher sees CR3 = our test space, so U_BUF / U_PATH pass
    // the user-range checks. Call through syscallDispatch so the WHOLE path runs
    // (number -> handler -> validation -> fat32), just as a `syscall` instruction
    // would. Results come back in the return value (a fd or a -errno).
    const ok = blk: {
        // open("/HELLO.TXT") -> expect fd 3 (lowest free; 0/1/2 reserved).
        const fd = syscallDispatch(SYS_open, U_PATH, PATH.len, 0);
        if (fd != 3) {
            serial.log("[FD] FAIL: open returned {d} (expected fd 3).\n", .{@as(i64, @bitCast(fd))});
            break :blk false;
        }
        // read() the first 5 bytes ("Hello") into the user buffer and verify them.
        const r1 = syscallDispatch(SYS_read, fd, U_BUF, 5);
        if (r1 != 5 or !userBufEquals(U_BUF, EXPECT[0..5])) {
            serial.log("[FD] FAIL: first read got {d} bytes / wrong contents.\n", .{r1});
            break :blk false;
        }
        // lseek(fd, 0, SEEK_SET): rewind to the start (a BACKWARD seek -> re-open).
        const p0 = syscallDispatch(SYS_lseek, fd, 0, SEEK_SET);
        if (p0 != 0) {
            serial.log("[FD] FAIL: lseek SEEK_SET 0 -> {d} (expected 0).\n", .{@as(i64, @bitCast(p0))});
            break :blk false;
        }
        // dup(fd) -> expect fd 4, sharing the (just-rewound) offset 0 independently.
        const fd2 = syscallDispatch(SYS_dup, fd, 0, 0);
        if (fd2 != 4) {
            serial.log("[FD] FAIL: dup returned {d} (expected fd 4).\n", .{@as(i64, @bitCast(fd2))});
            break :blk false;
        }
        // lseek(fd, 6, SEEK_SET) then read 5: from offset 6 the file reads "from " —
        // proves an absolute forward seek lands where we asked (and that the dup'd
        // fd 4 is unaffected by moving fd 3's cursor).
        _ = syscallDispatch(SYS_lseek, fd, 6, SEEK_SET);
        const r2 = syscallDispatch(SYS_read, fd, U_BUF, 5);
        if (r2 != 5 or !userBufEquals(U_BUF, EXPECT[6..11])) {
            serial.log("[FD] FAIL: post-seek read got {d} bytes / wrong contents.\n", .{r2});
            break :blk false;
        }
        // The dup'd fd 4 still sits at offset 0: read 5 and confirm it sees "Hello".
        const r3 = syscallDispatch(SYS_read, fd2, U_BUF, 5);
        if (r3 != 5 or !userBufEquals(U_BUF, EXPECT[0..5])) {
            serial.log("[FD] FAIL: dup'd fd read got {d} bytes / wrong contents.\n", .{r3});
            break :blk false;
        }
        // close(fd): the slot frees; a second close of the same fd is EBADF.
        if (syscallDispatch(SYS_close, fd, 0, 0) != 0) break :blk false;
        if (syscallDispatch(SYS_close, fd, 0, 0) != EBADF) break :blk false;
        _ = syscallDispatch(SYS_close, fd2, 0, 0);

        // --- Prove a NON-FAT32 backend works through the SAME fd ABI -----------
        // Now that the fd syscalls route through the VFS, opening "/dev/zero" must
        // reach devfs, not the FAT32 disk. (devfs is mounted by devfs.selfTest(),
        // which runs before us under -Ddebug-log, so /dev exists on this boot.)
        const DEV = "/dev/zero";
        @memcpy(path_kalias[0..DEV.len], DEV); // overwrite U_PATH via its HHDM alias
        // Poison the read buffer with 0xFF so an all-zero result can only come from
        // /dev/zero actually writing zeros (not a stale empty page).
        const buf_kalias: [*]u8 = @ptrFromInt(pmm.physToVirt(buf_frame));
        @memset(buf_kalias[0..16], 0xFF);
        // open("/dev/zero") -> fd 3 again (the table is empty after the closes above).
        const dfd = syscallDispatch(SYS_open, U_PATH, DEV.len, 0);
        if (dfd != 3) {
            serial.log("[FD] FAIL: open /dev/zero returned {d} (expected fd 3).\n", .{@as(i64, @bitCast(dfd))});
            break :blk false;
        }
        // read 16 bytes: /dev/zero hands back 16 zero bytes through the VFS.
        const dr = syscallDispatch(SYS_read, dfd, U_BUF, 16);
        if (dr != 16 or !userBufAllZero(U_BUF, 16)) {
            serial.log("[FD] FAIL: /dev/zero read got {d} bytes / not all zero.\n", .{dr});
            break :blk false;
        }
        // lseek a character device is meaningless: devfs has no seek slot, so the
        // VFS reports it unseekable and the syscall returns ESPIPE (like a pipe/tty).
        const ds = syscallDispatch(SYS_lseek, dfd, 0, SEEK_SET);
        if (ds != ESPIPE) {
            serial.log("[FD] FAIL: lseek /dev/zero -> {d} (expected ESPIPE).\n", .{@as(i64, @bitCast(ds))});
            break :blk false;
        }
        _ = syscallDispatch(SYS_close, dfd, 0, 0);
        break :blk true;
    };

    vmm.switchTo(prev_space); // back to the kernel address space
    vmm.unmapInto(as, U_BUF);
    vmm.unmapInto(as, U_PATH);
    pmm.free(buf_frame);
    pmm.free(path_frame);
    vmm.destroyAddressSpace(as);

    if (ok) {
        serial.log("[FD] file-syscall self-test OK: open/read/lseek/dup/close on {s} via the syscall ABI.\n", .{PATH});
        serial.log("[FD] VFS-backed fd OK: a FAT32 file and /dev/zero opened+read through one fd ABI.\n", .{});
    } else {
        serial.log("[FD] file-syscall self-test FAILED.\n", .{});
    }
}

// Compare the first `want.len` bytes of the user buffer at `va` against `want`.
// Reads ring-3 memory from the kernel, so it brackets the load with STAC/CLAC
// (SMAP) just like the syscall handlers do.
fn userBufEquals(va: u64, want: []const u8) bool {
    asm volatile ("stac");
    defer asm volatile ("clac");
    const got = @as([*]const u8, @ptrFromInt(va))[0..want.len];
    return std_mem_eql(got, want);
}

// A tiny local byte-slice equality (avoids importing std just for this one use).
fn std_mem_eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

// True if the first `n` bytes of the user buffer at `va` are all zero. Like
// userBufEquals, it reads ring-3 memory under the SMAP guard.
fn userBufAllZero(va: u64, n: usize) bool {
    asm volatile ("stac");
    defer asm volatile ("clac");
    const got = @as([*]const u8, @ptrFromInt(va))[0..n];
    for (got) |b| if (b != 0) return false;
    return true;
}
