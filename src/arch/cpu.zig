// Low-level CPU access: model-specific registers (MSRs).
//
// `rdmsr`/`wrmsr` are needed in several places — the VMM enables EFER.NXE, the
// APIC enables the LAPIC, and the syscall path programs STAR/LSTAR/SFMASK and
// EFER.SCE. This is the shared home for the instruction wrappers and the MSR
// numbers so a new consumer (the syscall ABI) doesn't hand-roll yet another copy.
// (vmm.zig and apic.zig still carry their own private copies from before this
// module existed; they can migrate here in a later cleanup.)

const serial = @import("../drivers/serial.zig"); // [CPU] feature-enable logging

// --- Model-specific register numbers -----------------------------------------
pub const IA32_EFER: u32 = 0xC0000080; // extended features (NXE, SCE, LME, ...)
pub const IA32_STAR: u32 = 0xC0000081; // syscall/sysret CS+SS selector bases
pub const IA32_LSTAR: u32 = 0xC0000082; // 64-bit `syscall` entry RIP
pub const IA32_FMASK: u32 = 0xC0000084; // RFLAGS bits cleared on `syscall` entry

// --- EFER bits ---------------------------------------------------------------
pub const EFER_SCE: u64 = 1 << 0; // System Call Extensions: enables syscall/sysret
pub const EFER_NXE: u64 = 1 << 11; // No-eXecute enable (the VMM sets this)

// Read a 64-bit MSR. The value arrives split across edx:eax (high:low).
pub fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, hi) << 32) | @as(u64, lo);
}

// Write a 64-bit MSR. The value is supplied split into edx:eax (high:low).
pub fn wrmsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [lo] "{eax}" (@as(u32, @truncate(value))),
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))),
    );
}

// --- CPUID -------------------------------------------------------------------
// The CPUID result registers (EAX/EBX/ECX/EDX) for a given leaf/subleaf.
pub const CpuidResult = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

// Execute CPUID with the given leaf (EAX) and subleaf (ECX). EBX must be saved
// and restored by hand: the compiler reserves it as the PIC base register under
// our build, so it can't appear as a clobber/output in inline asm. We xchg it
// through RDI (a scratch GPR) around the instruction to read it without telling
// the register allocator EBX moved.
pub fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
    var a: u32 = leaf;
    var b: u32 = undefined;
    var c: u32 = subleaf;
    var d: u32 = undefined;
    asm volatile (
        \\xchgq %%rbx, %%rdi
        \\cpuid
        \\xchgq %%rbx, %%rdi
        : [a] "={eax}" (a),
          [b] "={rdi}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ .eax = a, .ebx = b, .ecx = c, .edx = d };
}

// --- CR4 control-register bits ----------------------------------------------
pub const CR4_SMEP: u64 = 1 << 20; // Supervisor Mode Execution Prevention
pub const CR4_SMAP: u64 = 1 << 21; // Supervisor Mode Access Prevention

// Read CR4 (the control register holding SMEP/SMAP/PGE/... enable bits).
pub fn readCr4() u64 {
    return asm volatile ("movq %%cr4, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

// Write CR4.
pub fn writeCr4(value: u64) void {
    asm volatile ("movq %[val], %%cr4"
        :
        : [val] "r" (value),
        : "memory"
    );
}

// Turn on SMEP and SMAP if the CPU advertises them (CPUID leaf 7, subleaf 0:
// EBX bit 7 = SMEP, bit 20 = SMAP). SMEP makes ring 0 fault if it tries to
// *execute* a user (U=1) page — defeating the classic "jump into a user-mapped
// shellcode page" exploit. SMAP extends that to *data* accesses: ring 0 faults
// even reading/writing user pages unless it temporarily lifts the guard with
// STAC (and re-arms it with CLAC). Must run AFTER vmm.init(): once these are on,
// any ring-0 touch of a U=1 page faults, so we need our own page tables (with
// correct U/S bits — kernel pages S=0) loaded first, or the kernel would fault
// on its own code/data. The only legitimate kernel->user data access (sysWrite)
// brackets itself with STAC/CLAC.
pub fn enableSmepSmap() void {
    const feat = cpuid(7, 0);
    const has_smep = (feat.ebx & (1 << 7)) != 0;
    const has_smap = (feat.ebx & (1 << 20)) != 0;

    var cr4 = readCr4();
    if (has_smep) {
        cr4 |= CR4_SMEP;
        serial.print("[CPU] SMEP enabled\n", .{});
    }
    if (has_smap) {
        cr4 |= CR4_SMAP;
        serial.print("[CPU] SMAP enabled\n", .{});
    }
    writeCr4(cr4);
}

// Fill `buffer` with hardware random bytes from RDRAND if the CPU has it (CPUID
// leaf 1, ECX bit 30). RDRAND draws from an on-die entropy source seeded by
// thermal noise — genuinely random, not a PRNG. Returns false if RDRAND is
// absent, or if any draw's CF=0 (the entropy pool was momentarily drained) even
// after a retry budget, so the caller can fall back to a software source. We
// fill 64 bits at a time (RDRAND r64) and copy out as many bytes as fit.
pub fn rdrandFill(buffer: []u8) bool {
    const feat = cpuid(1, 0);
    if ((feat.ecx & (1 << 30)) == 0) return false; // no RDRAND on this CPU

    var i: usize = 0;
    while (i < buffer.len) {
        var value: u64 = undefined;
        var ok: u8 = 0;
        // RDRAND sets CF=1 on success, CF=0 if no entropy was ready. Intel
        // recommends retrying up to 10 times before giving up.
        var tries: u32 = 0;
        while (tries < 10) : (tries += 1) {
            asm volatile (
                \\rdrand %[val]
                \\setc %[ok]
                : [val] "=r" (value),
                  [ok] "=r" (ok),
            );
            if (ok != 0) break;
        }
        if (ok == 0) return false; // retry budget exhausted -> let caller fall back

        const take = @min(@as(usize, 8), buffer.len - i);
        var j: usize = 0;
        while (j < take) : (j += 1) {
            buffer[i + j] = @truncate(value >> @intCast(j * 8));
        }
        i += take;
    }
    return true;
}
