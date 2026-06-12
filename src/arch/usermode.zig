// Ring 3 (user mode) entry — the first time this kernel runs code at CPL 3.
//
// Everything so far has run in ring 0 (full privilege). Real programs run in
// ring 3, where privileged instructions (cli, hlt, I/O, loading CR3, ...) fault
// instead of executing, and only pages marked user-accessible are reachable. The
// CPU enters ring 3 by `iretq`-ing to a frame whose CS/SS selectors carry RPL 3.
//
// There is no clean way *back* yet — we have no syscalls (that's the next task),
// and a pure user loop would spin forever. So a user program returns control the
// only way it can pre-syscalls: by faulting. This module's self-test enters ring
// 3, has the user code prove it ran (writing a marker to a user page) and then
// execute a privileged instruction; the resulting #GP is caught by our IDT hook,
// which redirects iretq back into the kernel — demonstrating both that we reached
// CPL 3 and that privileged instructions fault cleanly there.
//
// THE LONGJMP: usermodeEnter saves the kernel's callee-saved registers + RSP,
// builds the ring-3 iretq frame, and drops to CPL 3. When the expected #GP fires,
// the fault hook rewrites the interrupt frame so its iretq lands at `usermodeResume`
// (kernel code, on the saved kernel RSP), which restores the registers and returns
// to usermodeEnter's caller — as if the call simply returned.

const serial = @import("../drivers/serial.zig");
const gdt = @import("gdt.zig"); // segment selectors (kernel/user)
const idt = @import("idt.zig"); // InterruptFrame + the fault hook we install
const pmm = @import("../mm/pmm.zig"); // frames for the user code/data/stack pages
const vmm = @import("../mm/vmm.zig"); // map those frames user-accessible (FLAG_USER)

// Selector sanity: the iretq frame in usermodeEnter hardcodes these (global asm
// can't reference Zig constants), so assert they still match the GDT.
comptime {
    if (gdt.USER_CODE != 0x1b) @compileError("usermode: USER_CODE selector changed; update usermodeEnter asm");
    if (gdt.USER_DATA != 0x23) @compileError("usermode: USER_DATA selector changed; update usermodeEnter asm");
    if (gdt.KERNEL_DATA != 0x10) @compileError("usermode: KERNEL_DATA selector changed; update usermodeResume asm");
}

const PAGE_SIZE: u64 = pmm.PAGE_SIZE;

// Where the self-test maps its user pages. These are LOW-half (canonical) virtual
// addresses — true user space, well clear of the higher-half kernel/HHDM — and
// the kernel maps nothing there otherwise, so the slots are free.
const U_CODE: u64 = 0x0000000000400000; // user code page (RX, user)
const U_DATA: u64 = 0x0000000000401000; // user data page (RW, user) — the result marker
const U_STACK_TOP: u64 = 0x0000000000501000; // top of a one-page user stack (RW, user)

// The value the user code writes to U_DATA — ASCII "RIN3", proof it ran at CPL 3.
const RING3_MAGIC: u64 = 0x52494E33;

// --- The ring-3 trampoline (global assembly) ---------------------------------
// usermodeEnter(entry, user_stack): args in rdi, rsi per the C ABI.
extern fn usermodeEnter(entry: u64, user_stack: u64) callconv(.c) void;
// usermodeResume: NOT called directly — its address is the recovery target the
// fault hook points iretq at. Declared extern so we can take its address.
extern fn usermodeResume() callconv(.c) void;
// The kernel RSP captured by usermodeEnter, where usermodeResume picks back up.
export var usermode_kernel_rsp: u64 = 0;

comptime {
    asm (
        \\.global usermodeEnter
        \\.type usermodeEnter, @function
        \\usermodeEnter:
        \\  push %rbp
        \\  push %rbx
        \\  push %r12
        \\  push %r13
        \\  push %r14
        \\  push %r15
        \\  mov %rsp, usermode_kernel_rsp(%rip)   // save resume point (points at saved r15)
        \\  movw $0x23, %ax                        // USER_DATA selector (RPL 3)
        \\  movw %ax, %ds                          // give user code user data segments
        \\  movw %ax, %es
        \\  pushq $0x23                            // iretq frame: SS  = USER_DATA
        \\  pushq %rsi                             //             RSP = user stack top
        \\  pushq $0x202                           //             RFLAGS = IF=1 + reserved bit 1
        \\  pushq $0x1b                            //             CS  = USER_CODE (RPL 3)
        \\  pushq %rdi                             //             RIP = entry
        \\  iretq                                  // drop to ring 3
        \\.global usermodeResume
        \\.type usermodeResume, @function
        \\usermodeResume:
        \\  movw $0x10, %ax                        // KERNEL_DATA: restore kernel data segments
        \\  movw %ax, %ds
        \\  movw %ax, %es
        \\  pop %r15                               // unwind the saved callee-saved registers
        \\  pop %r14
        \\  pop %r13
        \\  pop %r12
        \\  pop %rbx
        \\  pop %rbp
        \\  ret                                    // return to usermodeEnter's caller
    );
}

// --- Fault hook --------------------------------------------------------------
var test_active: bool = false; // true only while the self-test expects a ring-3 fault
var fault_cs: u64 = 0; // CS recorded at the fault (proves the privilege level)
var fault_vector: u64 = 0; // which exception the user instruction raised

// Installed as idt.fault_hook. Returns true (and redirects iretq into the kernel)
// only for the fault we're expecting: one taken while at CPL 3 during the test.
fn faultHook(frame: *idt.InterruptFrame) bool {
    if (!test_active) return false; // not our fault to handle
    if (frame.cs & 3 != 3) return false; // not from ring 3 — leave it to the dumper
    test_active = false; // one-shot
    fault_cs = frame.cs; // remember the evidence for the self-test to report
    fault_vector = frame.vector;
    // Redirect this iretq back into the kernel at usermodeResume, on the saved
    // kernel stack, in the kernel code/data segments.
    frame.rip = @intFromPtr(&usermodeResume);
    frame.cs = gdt.KERNEL_CODE;
    frame.rflags = 0x202; // IF=1 + reserved bit 1
    frame.rsp = usermode_kernel_rsp;
    frame.ss = gdt.KERNEL_DATA;
    return true;
}

// --- Self-test ---------------------------------------------------------------
pub fn selfTest() void {
    serial.print("[USER] Ring-3 (user mode) self-test...\n", .{});

    // Back the three user pages with fresh frames.
    const code_frame = pmm.allocZeroed() orelse return failNoMem();
    const data_frame = pmm.allocZeroed() orelse return failNoMem();
    const stack_frame = pmm.allocZeroed() orelse return failNoMem();

    // Write the user stub into the code frame THROUGH ITS HHDM ALIAS (kernel RW),
    // so we never need the user page itself to be writable — it maps in as RX,
    // keeping W^X intact. The stub, hand-assembled:
    //   48 B8 <magic>     mov  rax, RING3_MAGIC
    //   48 A3 <U_DATA>    mov  [U_DATA], rax     ; a user write to a user page
    //   FA                cli                     ; privileged at CPL 3 -> #GP
    //   EB FE             jmp  $                  ; safety net (never reached)
    const code: [*]u8 = @ptrFromInt(pmm.physToVirt(code_frame));
    code[0] = 0x48; // REX.W
    code[1] = 0xB8; // mov rax, imm64
    writeU64(code + 2, RING3_MAGIC);
    code[10] = 0x48; // REX.W
    code[11] = 0xA3; // mov [moffs64], rax
    writeU64(code + 12, U_DATA);
    code[20] = 0xFA; // cli
    code[21] = 0xEB; // jmp rel8
    code[22] = 0xFE; // -2 (to itself)

    // Clear the marker (via the data frame's HHDM alias) so a stale value can't
    // masquerade as success.
    const marker_alias: *volatile u64 = @ptrFromInt(pmm.physToVirt(data_frame));
    marker_alias.* = 0;

    // Map the pages into user space: code RX, data + stack RW (non-exec).
    vmm.map(U_CODE, code_frame, vmm.FLAG_USER); // present + user, read-only, executable
    vmm.map(U_DATA, data_frame, vmm.FLAG_USER | vmm.FLAG_WRITE | vmm.FLAG_NX);
    vmm.map(U_STACK_TOP - PAGE_SIZE, stack_frame, vmm.FLAG_USER | vmm.FLAG_WRITE | vmm.FLAG_NX);

    // Arm the recovery hook and drop to ring 3. usermodeEnter returns (via the
    // longjmp) once the user code faults and faultHook redirects us back.
    idt.fault_hook = &faultHook;
    test_active = true;
    serial.print("[USER]   entering ring 3 at 0x{x} (user stack 0x{x})...\n", .{ U_CODE, U_STACK_TOP });
    usermodeEnter(U_CODE, U_STACK_TOP);
    idt.fault_hook = null; // back in ring 0; disarm

    // Verify both halves: the user code ran (marker written) AND it was genuinely
    // at CPL 3 (the fault came from a RPL-3 code segment).
    const wrote = marker_alias.* == RING3_MAGIC;
    const cpl3 = (fault_cs & 3) == 3;
    serial.print("[USER]   back in ring 0: marker=0x{x} (want 0x{x}); faulted vector {d} at CS 0x{x}.\n", .{ marker_alias.*, RING3_MAGIC, fault_vector, fault_cs });
    if (wrote and cpl3) {
        serial.print("[USER] Ring-3 self-test OK: ran user code at CPL3 and recovered from its #GP.\n", .{});
    } else {
        serial.print("[USER] Ring-3 self-test FAILED (ran={}, cpl3={}).\n", .{ wrote, cpl3 });
    }

    // Tear the mappings down and return the frames.
    vmm.unmap(U_CODE);
    vmm.unmap(U_DATA);
    vmm.unmap(U_STACK_TOP - PAGE_SIZE);
    pmm.free(code_frame);
    pmm.free(data_frame);
    pmm.free(stack_frame);
}

// Store a little-endian u64 at p[0..8].
fn writeU64(p: [*]u8, v: u64) void {
    var i: usize = 0;
    while (i < 8) : (i += 1) p[i] = @truncate(v >> @intCast(i * 8));
}

fn failNoMem() void {
    serial.print("[USER] self-test skipped: out of physical memory for user pages.\n", .{});
}
