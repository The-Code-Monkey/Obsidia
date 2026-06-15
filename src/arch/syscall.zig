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

// A dedicated ring-0 stack the entry stub switches to (`syscall` doesn't load one
// for us). A single static stack is safe for now because the handler runs with
// interrupts masked on a single core; Stage 4 gives each process its own kernel
// stack via TSS.rsp0.
const SYSCALL_STACK_SIZE = 0x4000; // 16 KiB
var syscall_stack: [SYSCALL_STACK_SIZE]u8 align(16) = undefined;
export var syscall_kernel_rsp: u64 = 0; // top of syscall_stack (set in init)
export var syscall_user_rsp: u64 = 0; // scratch: the user RSP saved on entry

// The Stage-1 test syscall number ("TST\0"), and a flag the dispatcher sets when
// it runs — so the ring-3 self-test can prove the call reached the kernel. Fits in
// 32 bits so the user stub can load it with a plain `mov eax, imm32`.
pub const TEST_NUM: u64 = 0x5453_5400;
pub var test_seen: bool = false;

// The C-ABI dispatcher the entry stub calls with the syscall number in RDI.
// Stage 1 only recognises the test number; Stage 2 turns this into a real table.
export fn syscallDispatch(num: u64) callconv(.c) u64 {
    if (num == TEST_NUM) {
        test_seen = true;
        serial.print("[SYS]   test syscall received (num=0x{x}).\n", .{num});
        return num +% 1; // an arbitrary, checkable result
    }
    serial.print("[SYS]   unknown syscall num=0x{x}.\n", .{num});
    return @bitCast(@as(i64, -1)); // ENOSYS-ish
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
        \\  movq %rax, %rdi                        // arg1 = syscall number (passed in RAX)
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
