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
const scheduler = @import("../sched/scheduler.zig"); // SYS_yield hands off the CPU

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

const ENOSYS: u64 = @bitCast(@as(i64, -38)); // unknown syscall
const EBADF: u64 = @bitCast(@as(i64, -9)); // bad file descriptor
const EFAULT: u64 = @bitCast(@as(i64, -14)); // bad (out-of-bounds) user address

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
        else => blk: {
            serial.print("[SYS]   unknown syscall num={d}.\n", .{num});
            break :blk ENOSYS;
        },
    };
}

// write(fd, ptr, len): copy `len` bytes from the user buffer to serial (the only
// sink for now). fd 1 (stdout) / 2 (stderr) only. The buffer must lie wholly in
// user space so a caller can't make the kernel read its own memory. (This is a
// range check only; full per-page validation with fault handling — copy_from_user
// — comes with the process model.)
fn sysWrite(fd: u64, ptr: u64, len: u64) u64 {
    if (fd != 1 and fd != 2) return EBADF;
    if (len == 0) return 0;
    const n = @min(len, 4096);
    if (ptr >= USER_LIMIT or n > USER_LIMIT - ptr) return EFAULT; // buffer escapes user space
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
    serial.print("[SYS]   exit({d}).\n", .{code});
    if (exit_handler) |h| h(code); // noreturn
    // No handler installed: this is a kernel bug (one is always set before user
    // code runs), so say so loudly rather than silently letting the user resume.
    serial.print("[SYS]   WARNING: exit() with no handler installed — cannot terminate caller.\n", .{});
    return ENOSYS;
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
    serial.print("[SYS] Initializing syscall path...\n", .{});

    // EFER.SCE turns on the syscall/sysret instructions (preserving NXE etc.).
    cpu.wrmsr(cpu.IA32_EFER, cpu.rdmsr(cpu.IA32_EFER) | cpu.EFER_SCE);

    // STAR: bits 47:32 = kernel CS base (syscall sets CS=base, SS=base+8);
    //       bits 63:48 = sysret base   (sysret sets CS=base+16, SS=base+8, RPL 3).
    const star: u64 = (@as(u64, 0x10) << 48) | (@as(u64, gdt.KERNEL_CODE) << 32);
    cpu.wrmsr(cpu.IA32_STAR, star);

    // LSTAR: where `syscall` jumps. SFMASK: clear IF/DF/TF on entry (handler runs
    // with interrupts off, a defined direction flag, and no single-step trap).
    cpu.wrmsr(cpu.IA32_LSTAR, @intFromPtr(&syscallEntry));
    cpu.wrmsr(cpu.IA32_FMASK, 0x700);

    syscall_kernel_rsp = @intFromPtr(&syscall_stack) + syscall_stack.len;
    serial.print("[SYS]   EFER.SCE on; STAR=0x{x}; entry=0x{x}.\n", .{ star, @intFromPtr(&syscallEntry) });
    serial.print("[SYS] Syscall path initialized.\n", .{});
}
