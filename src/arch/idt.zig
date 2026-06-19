// Interrupt Descriptor Table + CPU exception handlers for x86-64.
//
// This is the single most valuable debugging tool in the kernel: without it, a
// CPU exception (page fault, #GP, etc.) with no handler escalates to a double
// fault, then to a triple fault, then the machine resets — silently. With it,
// the offending vector, error code, and full register state are dumped to
// serial so a crash is *readable*.
//
// Mechanism: 256 vectors each get a tiny comptime-generated stub. Vectors that
// don't push a hardware error code get a dummy 0 pushed so every stub presents
// an identical stack layout. Each stub pushes its vector number and jumps to a
// single common trampoline (`isrCommon`) that saves all GP registers, calls the
// Zig handler with a pointer to the frame, restores, and `iretq`s.

const std = @import("std"); // for comptimePrint when generating stubs (+ inline tests)
const serial = @import("../drivers/serial.zig"); // logging
const config = @import("config"); // build-time flags (debug_log)
const gdt = @import("gdt.zig"); // for the KERNEL_CODE selector used in gates
const pic = @import("pic.zig"); // hardware IRQs (vectors 32-47) dispatch here

// When true, init() deliberately executes `int3` to exercise the full
// dump+recover path. Tied to debug_log: only do this noisy self-test (it prints
// a full CPU-exception dump on purpose) when built with -Ddebug-log=true, so a
// normal boot stays quiet. Real exceptions still dump always — that path is
// unconditional; this only controls the deliberate test trigger.
const selftest_breakpoint = config.debug_log;

// --- Saved CPU state ---------------------------------------------------------
// Layout matches exactly what the stubs + isrCommon + CPU leave on the stack,
// in ascending memory order. extern struct (all u64) => no padding. The Zig
// handler receives a pointer to this, so it can read/print every register.
pub const InterruptFrame = extern struct {
    // Pushed by isrCommon, in reverse (r15 ends up lowest in memory).
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    // Pushed by the per-vector stub.
    vector: u64, // which interrupt fired (0..255)
    error_code: u64, // CPU error code, or the dummy 0 we pushed
    // Pushed by the CPU automatically on exception entry.
    rip: u64, // instruction that faulted (or the one after, for traps)
    cs: u64, // code segment at fault time
    rflags: u64, // flags at fault time
    rsp: u64, // stack pointer at fault time
    ss: u64, // stack segment at fault time
};

// --- IDT gate descriptor (16 bytes) -----------------------------------------
// One per vector. The 64-bit handler address is split across three fields.
const IdtEntry = packed struct {
    offset_low: u16, // handler address bits 0..15
    selector: u16, // code segment selector (KERNEL_CODE)
    ist: u8, // bits 0-2 select an IST stack; 0 = use current stack
    type_attr: u8, // 0x8E = present, DPL 0, 64-bit interrupt gate
    offset_mid: u16, // handler address bits 16..31
    offset_high: u32, // handler address bits 32..63
    reserved: u32, // must be zero
};

// The operand for `lidt`: limit (size-1) then base address.
const Idtr = packed struct {
    limit: u16,
    base: u64,
};

var idt: [256]IdtEntry = undefined; // the table (256 gates)
var idtr: Idtr = undefined; // the pointer we feed to lidt

// Optional CPU-exception hook. A subsystem may install this to intercept a fault
// before the default dump-and-halt — e.g. the ring-3 self-test catches the #GP a
// user-mode privileged instruction raises and redirects iretq back into kernel
// code. The hook returns true if it handled the fault (the frame may be rewritten
// to change where iretq resumes); false to fall through to the normal dump.
pub var fault_hook: ?*const fn (*InterruptFrame) bool = null;

// Optional USER-fault hook: how to terminate the *current* ring-3 process when it
// triggers a fatal CPU fault (page fault / #GP / illegal opcode / divide error).
// The scheduler installs this (via main.zig) to mark the faulting process finished
// and return to the shell — the kernel must not halt just because a *user* program
// misbehaved. It takes the conventional exit code (128 + signal number) and never
// returns (control resumes in the launcher thread). Left null before user mode is
// live, in which case a CPL3 fault falls through to the normal dump path.
pub var user_fault_hook: ?*const fn (u64) noreturn = null;

// Vectors that push a hardware error code onto the stack. For all others we push
// a dummy 0 so the stack frame is uniform.
fn hasErrorCode(vector: u8) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

// --- Comptime stub generation -----------------------------------------------
// Produce a distinct naked function per vector. Each normalizes the stack (dummy
// error code if the CPU didn't push one), pushes the vector, and jumps to the
// shared trampoline. Vector immediates are 0..255, which encode as positive
// imm8/imm32, so the pushed 64-bit value equals the vector exactly.
fn makeStub(comptime vector: u8) *const fn () callconv(.Naked) void {
    const has_err = hasErrorCode(vector); // does the CPU push an error code?
    return &struct {
        // A "naked" function has no compiler-generated prologue/epilogue — just
        // the assembly we write. Built as a comptime string per vector.
        fn stub() callconv(.Naked) void {
            asm volatile ((if (has_err) "" else "pushq $0\n") ++ // dummy error code if needed
                std.fmt.comptimePrint("pushq ${d}\njmp isrCommon\n", .{vector})); // push vector, jump to trampoline
        }
    }.stub;
}

// Build the 256-entry table of stub pointers at compile time.
const stub_table = blk: {
    var table: [256]*const fn () callconv(.Naked) void = undefined;
    for (0..256) |i| table[i] = makeStub(@intCast(i)); // one stub per vector
    break :blk table;
};

// Common trampoline: save all GP registers (so InterruptFrame is complete),
// pass the frame pointer in rdi, call the handler, restore, drop the
// vector+error_code, and return from the interrupt. The push order is the exact
// reverse of InterruptFrame's field order, so after the pushes RSP points at a
// fully-populated InterruptFrame.
export fn isrCommon() callconv(.Naked) void {
    asm volatile (
        \\ push %rax
        \\ push %rbx
        \\ push %rcx
        \\ push %rdx
        \\ push %rsi
        \\ push %rdi
        \\ push %rbp
        \\ push %r8
        \\ push %r9
        \\ push %r10
        \\ push %r11
        \\ push %r12
        \\ push %r13
        \\ push %r14
        \\ push %r15
        \\ mov %rsp, %rdi
        \\ call isrHandler
        \\ pop %r15
        \\ pop %r14
        \\ pop %r13
        \\ pop %r12
        \\ pop %r11
        \\ pop %r10
        \\ pop %r9
        \\ pop %r8
        \\ pop %rbp
        \\ pop %rdi
        \\ pop %rsi
        \\ pop %rdx
        \\ pop %rcx
        \\ pop %rbx
        \\ pop %rax
        \\ add $16, %rsp
        \\ iretq
        // mov %rsp,%rdi : pass the frame pointer as the 1st C argument.
        // add $16,%rsp  : discard the pushed vector + error_code.
        // iretq         : pop RIP/CS/RFLAGS/RSP/SS and resume.
    );
}

// --- Control register reads --------------------------------------------------
// CR0/CR2/CR3/CR4 hold paging + fault state we want in the crash dump.
fn readCr0() u64 {
    return asm volatile ("mov %cr0, %[ret]"
        : [ret] "=r" (-> u64), // read CR0 into any register, return it
    );
}
fn readCr2() u64 {
    return asm volatile ("mov %cr2, %[ret]" // CR2 = faulting address on a #PF
        : [ret] "=r" (-> u64),
    );
}
fn readCr3() u64 {
    return asm volatile ("mov %cr3, %[ret]" // CR3 = active page-table root
        : [ret] "=r" (-> u64),
    );
}
fn readCr4() u64 {
    return asm volatile ("mov %cr4, %[ret]" // CR4 = paging/feature flags
        : [ret] "=r" (-> u64),
    );
}

// Map a vector number to a human-readable exception name for the dump.
fn exceptionName(v: u64) []const u8 {
    return switch (v) {
        0 => "#DE Divide Error",
        1 => "#DB Debug",
        2 => "NMI",
        3 => "#BP Breakpoint",
        4 => "#OF Overflow",
        5 => "#BR BOUND Range Exceeded",
        6 => "#UD Invalid Opcode",
        7 => "#NM Device Not Available",
        8 => "#DF Double Fault",
        10 => "#TS Invalid TSS",
        11 => "#NP Segment Not Present",
        12 => "#SS Stack-Segment Fault",
        13 => "#GP General Protection Fault",
        14 => "#PF Page Fault",
        16 => "#MF x87 Floating-Point",
        17 => "#AC Alignment Check",
        18 => "#MC Machine Check",
        19 => "#XM SIMD Floating-Point",
        20 => "#VE Virtualization",
        21 => "#CP Control Protection",
        else => "Reserved/Unknown",
    };
}

// --- Fault -> signal mapping -------------------------------------------------
// A user (CPL3) process that takes a fatal CPU fault is terminated as if it were
// killed by the conventional POSIX signal for that fault, whose default action is
// to kill the process. The exit code a shell reports for a signal-killed process
// is 128 + the signal number, so we map each handled vector straight to that code:
//   #DE  (vector 0)  divide error    -> SIGFPE (8)  -> exit 136
//   #UD  (vector 6)  invalid opcode   -> SIGILL (4)  -> exit 132
//   #GP  (vector 13) protection fault -> SIGSEGV(11) -> exit 139
//   #PF  (vector 14) page fault       -> SIGSEGV(11) -> exit 139
// Any other vector returns null (we don't deliver a default-action signal for it
// from user mode — it falls through to the normal dump path).
const UserSignal = struct { name: []const u8, code: u64 };
fn userFaultSignal(vector: u64) ?UserSignal {
    return switch (vector) {
        0 => .{ .name = "SIGFPE", .code = 136 }, // #DE: 128 + 8
        6 => .{ .name = "SIGILL", .code = 132 }, // #UD: 128 + 4
        13, 14 => .{ .name = "SIGSEGV", .code = 139 }, // #GP / #PF: 128 + 11
        else => null,
    };
}

// Print the full machine state for a CPU exception to serial.
fn dumpException(f: *InterruptFrame) void {
    serial.print("\n", .{});
    serial.print("==================== CPU EXCEPTION ====================\n", .{});
    serial.print(" Vector {d}: {s}\n", .{ f.vector, exceptionName(f.vector) }); // which fault
    serial.print(" Error code: 0x{x}\n", .{f.error_code});
    if (f.vector == 14) { // #PF gets extra decoding
        // Page fault: CR2 holds the faulting linear address; decode the bits.
        serial.print(" Faulting address (CR2): 0x{x:0>16}\n", .{readCr2()});
        serial.print("   cause: {s}, {s}, {s}{s}{s}\n", .{
            if (f.error_code & 1 != 0) "protection-violation" else "page-not-present", // bit 0
            if (f.error_code & 2 != 0) "write" else "read", // bit 1
            if (f.error_code & 4 != 0) "user-mode" else "kernel-mode", // bit 2
            if (f.error_code & 8 != 0) ", reserved-bit-set" else "", // bit 3
            if (f.error_code & 16 != 0) ", instruction-fetch" else "", // bit 4 (NX violation)
        });
    }
    // Dump the saved instruction pointer, segments, flags, stack, then all GPRs.
    serial.print(" RIP=0x{x:0>16}  CS=0x{x:0>4}  RFLAGS=0x{x:0>8}\n", .{ f.rip, f.cs, f.rflags });
    serial.print(" RSP=0x{x:0>16}  SS=0x{x:0>4}\n", .{ f.rsp, f.ss });
    serial.print(" RAX=0x{x:0>16}  RBX=0x{x:0>16}\n", .{ f.rax, f.rbx });
    serial.print(" RCX=0x{x:0>16}  RDX=0x{x:0>16}\n", .{ f.rcx, f.rdx });
    serial.print(" RSI=0x{x:0>16}  RDI=0x{x:0>16}\n", .{ f.rsi, f.rdi });
    serial.print(" RBP=0x{x:0>16}  R8 =0x{x:0>16}\n", .{ f.rbp, f.r8 });
    serial.print(" R9 =0x{x:0>16}  R10=0x{x:0>16}\n", .{ f.r9, f.r10 });
    serial.print(" R11=0x{x:0>16}  R12=0x{x:0>16}\n", .{ f.r11, f.r12 });
    serial.print(" R13=0x{x:0>16}  R14=0x{x:0>16}\n", .{ f.r13, f.r14 });
    serial.print(" R15=0x{x:0>16}\n", .{f.r15});
    serial.print(" CR0=0x{x}  CR2=0x{x}  CR3=0x{x}  CR4=0x{x}\n", .{ readCr0(), readCr2(), readCr3(), readCr4() });
    serial.print("=======================================================\n", .{});
}

// Stop forever with interrupts disabled — used for unrecoverable exceptions.
fn hang() noreturn {
    while (true) asm volatile ("cli; hlt");
}

// The Zig-side handler invoked by isrCommon. callconv(.C) + export so the asm
// trampoline can call it by a stable symbol name.
export fn isrHandler(frame: *InterruptFrame) callconv(.C) void {
    if (frame.vector < 32) { // vectors 0..31 are CPU exceptions
        // Give a registered hook first crack — it can recover from a fault it was
        // expecting (e.g. the ring-3 self-test's deliberate #GP) and redirect
        // where iretq resumes, so we neither dump nor halt.
        if (fault_hook) |hook| {
            if (hook(frame)) return;
        }
        // No hook handled it. If the fault came from RING 3 (CPL = CS & 3 == 3),
        // it's a *user* program crashing, not the kernel: deliver the default-action
        // signal for the fault (terminate the process) and return to the shell,
        // rather than halting the whole machine. Kernel-mode faults (CPL 0) skip
        // this and keep today's dump-and-halt — a kernel fault IS fatal to the box.
        if (frame.cs & 3 == 3) {
            if (userFaultSignal(frame.vector)) |sig| {
                if (user_fault_hook) |terminate| {
                    // Diagnostic only (debug-log-gated): which process, which fault,
                    // which signal, and the exit code the shell will see. Proves we
                    // terminated the process instead of dumping + halting.
                    serial.log("[IDT] user fault -> {s}, process terminated (code {d}) [vector {d} {s}]\n", .{ sig.name, sig.code, frame.vector, exceptionName(frame.vector) });
                    terminate(sig.code); // noreturn: marks the process finished + yields to the launcher
                }
            }
        }
        dumpException(frame); // print the crash dump
        // #BP (breakpoint) is recoverable and used as our self-test, so return
        // to the instruction after `int3`. Every other exception is fatal here:
        // we have no recovery yet, so halt with the dump left on screen.
        if (frame.vector == 3) return;
        serial.print(" Unrecoverable exception — halting.\n", .{});
        hang();
    } else if (frame.vector >= 32 and frame.vector <= 47) {
        // Hardware IRQ from the (remapped) PIC / I/O APIC: dispatch + EOI.
        pic.handleIrq(@intCast(frame.vector));
    } else if (frame.vector == 0xFF) {
        // LAPIC spurious interrupt: by definition it needs no handler and no EOI.
    } else {
        // Any other software interrupt: just log it.
        serial.print("[IDT] Unhandled interrupt vector {d}\n", .{frame.vector & 0xFF});
    }
}

// Fill one IDT gate: split the handler address, set the segment + attributes.
fn setEntry(vector: u8, handler: u64, ist: u8) void {
    idt[vector] = .{
        .offset_low = @truncate(handler), // bits 0..15
        .selector = gdt.KERNEL_CODE, // run the handler in kernel code segment
        .ist = ist & 0x7, // IST index (0 = current stack)
        .type_attr = 0x8E, // present, DPL 0, interrupt gate
        .offset_mid = @truncate(handler >> 16), // bits 16..31
        .offset_high = @truncate(handler >> 32), // bits 32..63
        .reserved = 0,
    };
}

pub fn init() void {
    for (0..256) |i| { // install a gate for every vector
        // Route the double fault (#DF, vector 8) to IST1 so it has a known-good
        // stack even if the kernel stack is corrupt.
        const ist: u8 = if (i == 8) 1 else 0;
        setEntry(@intCast(i), @intFromPtr(stub_table[i]), ist); // point at the stub
    }

    idtr = .{
        .limit = @sizeOf(@TypeOf(idt)) - 1, // 256*16 - 1 = 0xFFF
        .base = @intFromPtr(&idt), // address of the table
    };
    asm volatile ("lidt (%[ptr])" // load the IDT register
        :
        : [ptr] "r" (&idtr), // pointer to the IDTR struct
        : "memory"
    );

    if (selftest_breakpoint) { // exercise the whole dump+recover path once
        asm volatile ("int3"); // triggers #BP -> isrHandler dumps and returns
        serial.log("[IDT]   Self-test: recovered from #BP cleanly. Dump path works.\n", .{});
    }

    serial.log("[IDT] IDT initialized.\n", .{});
}

// --- Inline tests ------------------------------------------------------------
// The fault->signal mapping is pure data, so we can check it on the host: each
// terminating CPU vector must map to the conventional "128 + signal" exit code,
// and every non-terminating vector must map to null (so it never silently kills a
// user process). 128 + signal: SIGFPE=8 -> 136, SIGILL=4 -> 132, SIGSEGV=11 -> 139.
test "userFaultSignal maps the terminating vectors to 128+signal" {
    try std.testing.expectEqual(@as(u64, 136), userFaultSignal(0).?.code); // #DE -> SIGFPE
    try std.testing.expectEqualStrings("SIGFPE", userFaultSignal(0).?.name);
    try std.testing.expectEqual(@as(u64, 132), userFaultSignal(6).?.code); // #UD -> SIGILL
    try std.testing.expectEqualStrings("SIGILL", userFaultSignal(6).?.name);
    try std.testing.expectEqual(@as(u64, 139), userFaultSignal(13).?.code); // #GP -> SIGSEGV
    try std.testing.expectEqual(@as(u64, 139), userFaultSignal(14).?.code); // #PF -> SIGSEGV
    try std.testing.expectEqualStrings("SIGSEGV", userFaultSignal(14).?.name);
}

test "userFaultSignal returns null for vectors we don't default-kill on" {
    try std.testing.expectEqual(@as(?UserSignal, null), userFaultSignal(3)); // #BP (recoverable)
    try std.testing.expectEqual(@as(?UserSignal, null), userFaultSignal(8)); // #DF (kernel-fatal)
    try std.testing.expectEqual(@as(?UserSignal, null), userFaultSignal(1)); // #DB
    try std.testing.expectEqual(@as(?UserSignal, null), userFaultSignal(32)); // an IRQ vector
}
