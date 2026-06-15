// Low-level CPU access: model-specific registers (MSRs).
//
// `rdmsr`/`wrmsr` are needed in several places — the VMM enables EFER.NXE, the
// APIC enables the LAPIC, and the syscall path programs STAR/LSTAR/SFMASK and
// EFER.SCE. This is the shared home for the instruction wrappers and the MSR
// numbers so a new consumer (the syscall ABI) doesn't hand-roll yet another copy.
// (vmm.zig and apic.zig still carry their own private copies from before this
// module existed; they can migrate here in a later cleanup.)

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
