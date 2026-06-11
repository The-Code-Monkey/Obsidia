// Global Descriptor Table + Task State Segment for x86-64 long mode.
//
// Limine hands us a working GDT, but we replace it with our own so the kernel
// owns its segmentation state (and so we control the TSS, which the IDT step
// needs for interrupt stacks). In long mode segmentation is mostly flat: the
// code/data descriptors carry no real base/limit, they only set the privilege
// level and the long-mode (L) bit. The piece that actually matters going
// forward is the TSS, which supplies RSP0 (the stack the CPU switches to on a
// privilege change) and the IST entries (dedicated stacks selectable per IDT
// gate — we'll point the double-fault handler at IST1 in the next step).

const serial = @import("../drivers/serial.zig"); // for logging

// --- Segment selectors (byte offsets into the GDT) -------------------------
// A selector is an index into the GDT, in bytes: entry N lives at offset N*8.
// Exported so other subsystems (e.g. the IDT, whose gates reference the kernel
// code selector) can use them by name.
pub const KERNEL_CODE: u16 = 0x08; // GDT index 1 (ring 0 code)
pub const KERNEL_DATA: u16 = 0x10; // GDT index 2 (ring 0 data)
pub const USER_CODE: u16 = 0x18 | 3; // GDT index 3, low 2 bits = RPL 3 -> 0x1B
pub const USER_DATA: u16 = 0x20 | 3; // GDT index 4, RPL 3 -> 0x23
pub const TSS_SELECTOR: u16 = 0x28; // GDT index 5 (the TSS descriptor spans 5 and 6)

// --- 64-bit Task State Segment ---------------------------------------------
// MUST be a packed struct: the hardware layout places the 8-byte RSP/IST fields
// at 4-byte-aligned (not 8-byte-aligned) offsets, e.g. RSP0 at byte 4. An
// `extern struct` would pad and silently misplace every field after reserved0.
const Tss = packed struct {
    reserved0: u32 = 0, // bytes 0..3, must be zero
    rsp0: u64 = 0, // stack loaded on privilege change to ring 0
    rsp1: u64 = 0, // ring 1 stack (unused)
    rsp2: u64 = 0, // ring 2 stack (unused)
    reserved1: u64 = 0, // reserved
    ist1: u64 = 0, // interrupt stack table entry 1 (used by #DF)
    ist2: u64 = 0, // IST 2 (unused)
    ist3: u64 = 0, // IST 3 (unused)
    ist4: u64 = 0, // IST 4 (unused)
    ist5: u64 = 0, // IST 5 (unused)
    ist6: u64 = 0, // IST 6 (unused)
    ist7: u64 = 0, // IST 7 (unused)
    reserved2: u64 = 0, // reserved
    reserved3: u16 = 0, // reserved
    iopb_offset: u16 = 0, // offset to the I/O permission bitmap
};

comptime {
    // Tripwires: if Zig ever lays this out differently, fail at compile time
    // rather than triple-faulting at runtime. Byte offsets per Intel SDM:
    // RSP0 @ 0x04 (bit 32), IST1 @ 0x24 (bit 288), IOPB @ 0x66 (bit 816).
    if (@bitOffsetOf(Tss, "rsp0") != 32) @compileError("Tss.rsp0 misaligned");
    if (@bitOffsetOf(Tss, "ist1") != 288) @compileError("Tss.ist1 misaligned");
    if (@bitOffsetOf(Tss, "iopb_offset") != 816) @compileError("Tss.iopb_offset misaligned");
}

// --- GDTR operand for the lgdt instruction ---------------------------------
// The lgdt instruction reads a 10-byte operand: a 2-byte limit then an 8-byte
// base. Packed so the fields are adjacent; an extern struct would pad `base`
// out to offset 8 and lgdt would read garbage.
const Gdtr = packed struct {
    limit: u16, // size of the GDT in bytes, minus 1
    base: u64, // linear address of the GDT
};

// --- Storage ----------------------------------------------------------------
// 7 entries: null, kcode, kdata, ucode, udata, tss_low, tss_high.
var gdt: [7]u64 align(8) = undefined; // the table itself (filled in init)
var gdtr: Gdtr = undefined; // the pointer we feed to lgdt
var tss: Tss = .{}; // our single Task State Segment

// Dedicated kernel stacks referenced by the TSS. 16 KiB each, in .bss.
const STACK_SIZE = 0x4000; // 16 KiB
var ring0_stack: [STACK_SIZE]u8 align(16) = undefined; // RSP0 stack
var ist1_stack: [STACK_SIZE]u8 align(16) = undefined; // IST1 stack (for #DF)

// --- Descriptor encoders ----------------------------------------------------
// Build a standard 8-byte code/data descriptor as a u64. In long mode base/limit
// are ignored by the CPU for these, but we fill the conventional flat values.
//   access: P|DPL|S|E|DC|RW|A   flags(4 bits): G|D/B|L|AVL
fn makeEntry(base: u64, limit: u32, access: u8, flags: u4) u64 {
    var d: u64 = 0; // accumulate the 64-bit descriptor field by field
    d |= @as(u64, limit & 0xFFFF); // limit[15:0]   -> bits 0..15
    d |= (base & 0xFFFF) << 16; // base[15:0]    -> bits 16..31
    d |= ((base >> 16) & 0xFF) << 32; // base[23:16]   -> bits 32..39
    d |= @as(u64, access) << 40; // access byte   -> bits 40..47
    d |= (@as(u64, limit >> 16) & 0xF) << 48; // limit[19:16]  -> bits 48..51
    d |= @as(u64, flags) << 52; // flags nibble  -> bits 52..55
    d |= ((base >> 24) & 0xFF) << 56; // base[31:24]   -> bits 56..63
    return d;
}

// A 64-bit TSS descriptor is 16 bytes and spans two GDT slots. This builds the
// low 8 bytes; access 0x89 = present, type 9 (available 64-bit TSS).
fn makeTssLow(base: u64, limit: u32) u64 {
    var d: u64 = 0; // low qword of the system descriptor
    d |= @as(u64, limit & 0xFFFF); // limit[15:0]
    d |= (base & 0xFFFF) << 16; // base[15:0]
    d |= ((base >> 16) & 0xFF) << 32; // base[23:16]
    d |= @as(u64, 0x89) << 40; // access byte: present, 64-bit TSS
    d |= (@as(u64, limit >> 16) & 0xF) << 48; // limit[19:16]
    // flags nibble = 0 (byte granularity, G=0)
    d |= ((base >> 24) & 0xFF) << 56; // base[31:24]
    return d;
}

// The high 8 bytes of the TSS descriptor: just base[63:32] in the low 32 bits.
fn makeTssHigh(base: u64) u64 {
    return (base >> 32) & 0xFFFFFFFF;
}

// --- Low-level loads --------------------------------------------------------
// lgdt to install the table, then reload CS via a far return (you cannot mov
// into CS) and the data segment registers via plain movs.
fn load(ptr: *const Gdtr) void {
    asm volatile (
        \\ lgdt (%[gdtr])
        \\ pushq %[code]
        \\ leaq 1f(%rip), %rax
        \\ pushq %rax
        \\ lretq
        \\ 1:
        \\ movw %[data], %ax
        \\ movw %ax, %ds
        \\ movw %ax, %es
        \\ movw %ax, %fs
        \\ movw %ax, %gs
        \\ movw %ax, %ss
        : // no outputs
          // lgdt loads the GDTR; we then push the kernel CS selector and the
          // address of label 1, and `lretq` pops both -> reloads CS and jumps
          // to 1. Finally we load the data segment registers with KERNEL_DATA.
        : [gdtr] "r" (ptr), // pointer to the GDTR struct
          [code] "i" (@as(u32, KERNEL_CODE)), // immediate kernel code selector
          [data] "i" (@as(u16, KERNEL_DATA)), // immediate kernel data selector
        : "rax", "memory" // we clobber RAX and touch memory
    );
}

// Load the task register (TR) with the TSS selector, activating the TSS.
fn loadTss(selector: u16) void {
    asm volatile ("ltr %[sel]" // ltr = load task register
        : // no outputs
        : [sel] "r" (selector), // the TSS selector in any register
        : "memory"
    );
}

// --- Public init ------------------------------------------------------------
pub fn init() void {
    serial.print("[GDT] Initializing GDT...\n", .{});

    gdt[0] = 0; // null descriptor (required to be entry 0)
    gdt[1] = makeEntry(0, 0xFFFFF, 0x9A, 0xA); // kernel code (ring 0, 64-bit: L bit set)
    gdt[2] = makeEntry(0, 0xFFFFF, 0x92, 0xC); // kernel data (ring 0)
    gdt[3] = makeEntry(0, 0xFFFFF, 0xFA, 0xA); // user code   (ring 3, 64-bit)
    gdt[4] = makeEntry(0, 0xFFFFF, 0xF2, 0xC); // user data   (ring 3)

    // Point the TSS at its stacks (tops, since the stack grows down) and
    // disable the I/O permission bitmap by pointing past the TSS limit.
    tss.rsp0 = @intFromPtr(&ring0_stack) + ring0_stack.len; // top of the ring-0 stack
    tss.ist1 = @intFromPtr(&ist1_stack) + ist1_stack.len; // top of the IST1 stack
    tss.iopb_offset = @sizeOf(Tss); // >= limit => no I/O bitmap

    const tss_base = @intFromPtr(&tss); // linear address of the TSS
    const tss_limit: u32 = @sizeOf(Tss) - 1; // size - 1
    gdt[5] = makeTssLow(tss_base, tss_limit); // low half of the 16-byte descriptor
    gdt[6] = makeTssHigh(tss_base); // high half (base[63:32])

    gdtr = .{
        .limit = @sizeOf(@TypeOf(gdt)) - 1, // 7*8 - 1 = 55 bytes
        .base = @intFromPtr(&gdt), // address of the table
    };

    serial.print("[GDT]   GDT base=0x{x} limit=0x{x}\n", .{ gdtr.base, gdtr.limit });
    serial.print("[GDT]   TSS base=0x{x} limit=0x{x}\n", .{ tss_base, tss_limit });
    serial.print("[GDT]   rsp0=0x{x} ist1=0x{x}\n", .{ tss.rsp0, tss.ist1 });

    load(&gdtr); // install the GDT and reload all segment registers
    serial.print("[GDT]   lgdt done; CS=0x{x}, data segs=0x{x}.\n", .{ KERNEL_CODE, KERNEL_DATA });

    loadTss(TSS_SELECTOR); // activate the TSS
    serial.print("[GDT]   ltr done; TSS selector=0x{x}.\n", .{TSS_SELECTOR});

    serial.print("[GDT] GDT initialized.\n", .{});
}
