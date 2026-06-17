// Kernel entry point. Limine (the bootloader) loads us in 64-bit long mode with
// paging already on, then jumps to `_start`. This file declares the Limine
// requests we need, then brings up each subsystem in order, logging as it goes.

const builtin = @import("builtin"); // compile-time target info (CPU arch, etc.)
const std = @import("std"); // for the panic-handler wiring
const limine = @import("limine"); // Limine boot-protocol bindings (48cf/limine-zig)
const serial = @import("drivers/serial.zig"); // COM1 logging
const cpu = @import("arch/cpu.zig"); // CPUID, CR4 (SMEP/SMAP), RDRAND
const gdt = @import("arch/gdt.zig"); // segment descriptors + TSS
const idt = @import("arch/idt.zig"); // interrupt/exception handlers
const pic = @import("arch/pic.zig"); // legacy interrupt controller + timer
const apic = @import("arch/apic.zig"); // modern interrupt controller (LAPIC + IO APIC)
const pmm = @import("mm/pmm.zig"); // physical frame allocator
const vmm = @import("mm/vmm.zig"); // page tables / virtual memory
const heap = @import("mm/heap.zig"); // kernel heap (std.mem.Allocator)
const dma = @import("mm/dma.zig"); // contiguous <4 GiB buffers for bus-master DMA
const console = @import("drivers/console.zig"); // on-screen framebuffer text console
const keyboard = @import("drivers/keyboard.zig"); // PS/2 keyboard input
const mouse = @import("drivers/mouse.zig"); // PS/2 mouse (scroll wheel -> scrollback)
const pci = @import("drivers/pci.zig"); // PCI bus enumeration (config mechanism #1)
const ac97 = @import("drivers/ac97.zig"); // AC'97 audio (PCM playback over DMA)
const ata = @import("drivers/ata.zig"); // ATA PIO disk (block device)
const ahci = @import("drivers/ahci.zig"); // AHCI/SATA disk (DMA block device, read-only)
const fat32 = @import("fs/fat32.zig"); // FAT32 filesystem (read-only)
const loader = @import("loader.zig"); // ELF64/flat program loader (runs the init binary)
const acpi = @import("acpi/acpi.zig"); // ACPI table parsing
const scheduler = @import("sched/scheduler.zig"); // cooperative kernel threads
const kstack = @import("sched/kstack.zig"); // guarded kernel-stack region (init before address-space clones)
const usermode = @import("arch/usermode.zig"); // ring 3 (user mode) entry
const syscall = @import("arch/syscall.zig"); // syscall/sysret ABI (STAR/LSTAR/SFMASK)
const install = @import("install.zig"); // in-guest installer (clones the system image)
const shell = @import("shell.zig"); // interactive serial command shell

// Limine scans the kernel for "requests": structs (tagged by magic IDs) that ask
// the bootloader for information. They must live in the .limine_requests section.
// These two markers bracket the request list so Limine can find it quickly.
export var start_marker: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var end_marker: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

// Declare which boot-protocol revision we speak (3). Limine fills .response.
export var base_revision: limine.BaseRevision linksection(".limine_requests") = .init(3);
// Ask for a linear framebuffer to draw to.
export var framebuffer_request: limine.FramebufferRequest linksection(".limine_requests") = .{};
// Ask for the physical memory map (which regions are usable RAM).
export var memmap_request: limine.MemoryMapRequest linksection(".limine_requests") = .{};
// Ask for the HHDM offset (where all physical RAM is mirrored in virtual space).
export var hhdm_request: limine.HhdmRequest linksection(".limine_requests") = .{};
// Ask where our kernel was physically/virtually loaded (for the VMM's mappings).
export var executable_address_request: limine.ExecutableAddressRequest linksection(".limine_requests") = .{};
// Ask for the RSDP (root pointer to the ACPI tables).
export var rsdp_request: limine.RsdpRequest linksection(".limine_requests") = .{};
// Ask Limine to load the modules listed in limine.conf (the login credential
// and, on the installer medium, the system image). Limine reads them off the
// ESP/ISO for us, so the kernel needs no GPT/FAT parsing to find these files.
export var module_request: limine.ModuleRequest linksection(".limine_requests") = .{};
// Force 4-level paging so the VMM's table walk is correct regardless of CPU.
export var paging_mode_request: limine.PagingModeRequest linksection(".limine_requests") = .{
    .mode = .@"4lvl", // preferred mode
    .max_mode = .@"4lvl", // never give us 5-level
    .min_mode = .@"4lvl", // never give us less than 4-level
};

// --- Limine modules ----------------------------------------------------------
// Files Limine loaded for us, kept as slices into module memory (type
// executable_and_modules, which the PMM never reclaims, so they stay valid).
var auth_module: ?[]const u8 = null; // /OBSIDIA/AUTH credential (installed boot)
var system_module: ?[]const u8 = null; // system disk image (Option A installer medium)
// Option B installer payload: the pieces the in-kernel installer lays onto a disk.
var kernel_module: ?[]const u8 = null; // kernel.elf to copy to /boot/kernel.elf
var bootx64_module: ?[]const u8 = null; // Limine BOOTX64.EFI to copy to /EFI/BOOT
var installed_conf_module: ?[]const u8 = null; // installed-system limine.conf

// True if `haystack` ends with `needle`, case-insensitively (FAT paths vary).
fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - needle.len ..], needle);
}

// Find the modules we care about by path suffix and stash their byte slices.
fn readModules() void {
    const resp = module_request.response orelse return;
    for (resp.getModules()) |file| {
        const path = std.mem.span(file.path);
        const bytes = @as([*]const u8, @ptrCast(file.address))[0..file.size];
        if (endsWithIgnoreCase(path, "AUTH")) {
            auth_module = bytes;
            serial.print("[OBSIDIA] module: auth credential ({d} bytes)\n", .{file.size});
        } else if (endsWithIgnoreCase(path, "SYSTEM.IMG")) {
            system_module = bytes;
            serial.print("[OBSIDIA] module: system image ({d} bytes)\n", .{file.size});
        } else if (endsWithIgnoreCase(path, "BOOTX64.EFI")) {
            bootx64_module = bytes;
            serial.print("[OBSIDIA] module: bootloader BOOTX64.EFI ({d} bytes)\n", .{file.size});
        } else if (endsWithIgnoreCase(path, "INSTALLED.CONF")) {
            installed_conf_module = bytes;
            serial.print("[OBSIDIA] module: installed limine.conf ({d} bytes)\n", .{file.size});
        } else if (endsWithIgnoreCase(path, "KERNEL.ELF")) {
            kernel_module = bytes;
            serial.print("[OBSIDIA] module: kernel image ({d} bytes)\n", .{file.size});
        }
    }
}

// Accessors for other subsystems (the shell's login; the installer).
pub fn authModule() ?[]const u8 {
    return auth_module;
}
pub fn systemModule() ?[]const u8 {
    return system_module;
}
pub fn kernelModule() ?[]const u8 {
    return kernel_module;
}
pub fn bootx64Module() ?[]const u8 {
    return bootx64_module;
}
pub fn installedConfModule() ?[]const u8 {
    return installed_conf_module;
}

// --- Entropy for std.crypto.random ------------------------------------------
// std's CSPRNG seeds itself from the OS (getrandom), which doesn't exist
// freestanding. std exposes `cryptoRandomSeed` precisely so a freestanding kernel
// can supply its own entropy; with `crypto_always_getrandom` every draw routes
// straight here. We seed an xorshift from the CPU timestamp counter — weak by
// crypto standards, but enough to give the installer's scrypt credential a unique
// salt (scrypt's strength is in the KDF, not the salt's unpredictability).
pub const std_options: std.Options = .{
    .cryptoRandomSeed = cryptoRandomSeed,
    .crypto_always_getrandom = true,
};

// Read the 64-bit CPU timestamp counter (cycles since reset) — our entropy tap.
fn rdtsc() u64 {
    var hi: u32 = undefined;
    var lo: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

var rng_state: u64 = 0x9E3779B97F4A7C15; // golden-ratio seed, stirred per call

// Fill `buffer` with random bytes. Prefer the CPU's hardware RNG (RDRAND, an
// on-die entropy source) when present and willing; if RDRAND is absent or its
// entropy pool is momentarily drained (CF=0 past the retry budget), fall back to
// the existing TSC-stirred xorshift64. Freestanding-safe (no std.Thread/OS).
fn cryptoRandomSeed(buffer: []u8) void {
    if (cpu.rdrandFill(buffer)) {
        serial.print("[OBSIDIA] RNG: rdrand\n", .{});
        return;
    }
    serial.print("[OBSIDIA] RNG: rdtsc\n", .{});
    for (buffer) |*b| {
        rng_state ^= rdtsc() *% 0x2545F4914F6CDD1D; // mix in fresh cycle counts
        rng_state ^= rng_state << 13; // xorshift64 scramble
        rng_state ^= rng_state >> 7;
        rng_state ^= rng_state << 17;
        b.* = @truncate(rng_state >> 24);
    }
}

// Custom panic handler. The Zig compiler routes all safety-check panics (index
// out of bounds, integer overflow in Debug, reaching `unreachable`, `@panic`,
// etc.) here. Instead of the default trap, we print a clear message + the
// faulting address to serial (mirrored to the framebuffer) and halt.
pub const panic = std.debug.FullPanic(kernelPanic);

fn kernelPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold); // tell the optimizer this path is rarely taken
    asm volatile ("cli"); // no interrupts while we report and stop
    serial.print("\n==================== KERNEL PANIC ====================\n", .{});
    serial.print(" {s}\n", .{msg}); // the panic message
    if (first_trace_addr) |addr| serial.print(" at 0x{x}\n", .{addr}); // where it happened
    serial.print("=====================================================\n", .{});
    while (true) asm volatile ("hlt"); // stop forever
}

// Our own kernel stack. Limine's boot stack lives in bootloader-reclaimable
// memory, so we switch to this one before reclaiming that memory.
const KERNEL_STACK_SIZE = 0x10000; // 64 KiB
var kernel_stack: [KERNEL_STACK_SIZE]u8 align(16) = undefined;

// "Halt and Catch Fire": stop the CPU forever. Used after a fatal error or once
// initialization is complete and there's nothing left to do.
fn hcf() noreturn {
    while (true) { // loop forever
        switch (builtin.cpu.arch) { // pick the right idle instruction per arch
            .x86_64 => asm volatile ("hlt"), // halt until the next interrupt
            .aarch64 => asm volatile ("wfi"), // wait for interrupt
            .riscv64 => asm volatile ("wfi"), // wait for interrupt
            .loongarch64 => asm volatile ("idle 0"), // idle
            else => unreachable, // we only build for the arches above
        }
    }
}

// The kernel's entry point. `export` gives it the symbol name `_start` that the
// linker script names as ENTRY. It never returns.
export fn _start() noreturn {
    // Serial first, so we can see everything that follows — including failures.
    serial.init(); // bring up COM1
    serial.print("========================================\n", .{}); // banner
    serial.print("[OBSIDIA] Kernel entered _start.\n", .{});

    // Verify the bootloader supports the boot-protocol revision we asked for.
    if (!base_revision.isSupported()) {
        serial.print("[OBSIDIA] PANIC: base revision not supported\n", .{});
        hcf(); // unsupported -> we can't safely continue
    }
    serial.print("[OBSIDIA] Base revision OK.\n", .{});

    // Replace Limine's GDT with our own (segments + TSS).
    gdt.init();

    // Install the IDT so CPU exceptions become readable crash dumps.
    idt.init();

    // Program the syscall/sysret MSRs (needs the GDT's selectors; harmless this
    // early — the path isn't used until user code runs).
    syscall.init();

    // Remap the PIC, start the PIT, and enable hardware interrupts.
    pic.init();

    // Bring up the physical memory manager from Limine's memory map + HHDM.
    // `orelse { ... }` runs the block (which diverges via hcf) if the response
    // is null, otherwise unwraps the pointer.
    const hhdm_resp = hhdm_request.response orelse {
        serial.print("[OBSIDIA] PANIC: no HHDM response\n", .{});
        hcf();
    };
    const memmap_resp = memmap_request.response orelse {
        serial.print("[OBSIDIA] PANIC: no memory-map response\n", .{});
        hcf();
    };
    pmm.init(memmap_resp, hhdm_resp.offset); // parse the map, build the frame allocator

    // Record the modules Limine loaded (credential / system image). Their bytes
    // live in non-reclaimed module memory reachable via the HHDM, so the slices
    // stay valid after we switch page tables and reclaim bootloader memory.
    readModules();

    // Acquire the framebuffer BEFORE switching page tables, while Limine's
    // response pointers are still reachable under its mappings. We stash its
    // details and bring up the console after paging is ours.
    var fb_info: ?console.FramebufferInfo = null;
    if (framebuffer_request.response) |fb_response| { // got a framebuffer?
        const fb = fb_response.getFramebuffers()[0]; // take the first one
        fb_info = .{ // copy out everything the console needs
            .address = @intFromPtr(fb.address),
            .width = fb.width,
            .height = fb.height,
            .pitch = fb.pitch,
            .bpp = fb.bpp,
            .red_shift = fb.red_mask_shift,
            .green_shift = fb.green_mask_shift,
            .blue_shift = fb.blue_mask_shift,
        };
        serial.print("[OBSIDIA] Framebuffer acquired: {}x{} @ 0x{x}\n", .{ fb.width, fb.height, @intFromPtr(fb.address) });
    } else {
        serial.print("[OBSIDIA] WARN: no framebuffer response\n", .{});
    }

    // Take over paging: build our own page tables and load CR3. After this we
    // must not touch Limine response pointers again.
    const exec_resp = executable_address_request.response orelse {
        serial.print("[OBSIDIA] PANIC: no executable-address response\n", .{});
        hcf();
    };
    // Pass the kernel's physical + virtual load base (so we can re-map it) and
    // the HHDM offset (so we can re-map all of physical RAM).
    vmm.init(exec_resp.physical_base, exec_resp.virtual_base, hhdm_resp.offset);

    // Build the guarded kernel-stack region's page-table path now — BEFORE any
    // per-process address space is cloned (createAddressSpace copies the kernel
    // half by PML4 entry), so every process inherits the shared subtree the kernel
    // stacks live in (a process traps/syscalls onto one while its own CR3 is live).
    kstack.init();

    // Now that we run on OUR page tables (kernel pages S=0, user pages U=1),
    // turn on SMEP/SMAP: ring 0 can no longer execute (SMEP) or read/write
    // (SMAP) user pages, closing a whole class of privilege-escalation tricks.
    // Must follow vmm.init() — on Limine's tables a U/S mismatch could fault us.
    cpu.enableSmepSmap();

    // Kernel heap: a std.mem.Allocator backed by the VMM.
    heap.init();

    // Bring up the on-screen framebuffer console, then mirror all serial output
    // to it so the boot log and shell appear in the display window too.
    if (fb_info) |info| {
        console.init(info);
        serial.setMirror(&console.writeString);
    }

    // Parse the ACPI tables. Do this BEFORE reclaiming bootloader memory: the
    // RSDP *response* struct lives there (the tables themselves are in firmware
    // memory and survive). The parsed data feeds the APIC driver next.
    if (rsdp_request.response) |r| {
        acpi.init(r.address); // r.address is the RSDP's physical address
        // Retire the 8259 PIC and route interrupts through the LAPIC + I/O APIC.
        apic.init();
        // Calibrate + start the LAPIC timer (retires the PIT as the timer source).
        apic.initTimer(100); // 100 Hz, matching the old PIT rate
    } else {
        serial.print("[OBSIDIA] WARN: no RSDP response (ACPI unavailable, staying on PIC)\n", .{});
    }

    // DMA buffer allocator: physically-contiguous, <4 GiB, zeroed buffers for
    // the bus-master devices the PCI drivers below will drive (audio/AHCI/NIC).
    dma.init();

    // Enumerate the PCI bus: discover every device and its class. The foundation
    // later drivers (audio, AHCI, NIC) use to find and configure their hardware.
    pci.init();

    // AC'97 audio: find the codec (if any), bring it up, and play a short test
    // tone over bus-master DMA. No-ops when the machine has no AC'97 device.
    ac97.init();

    // Bring up the ATA PIO disk (block device). Probes the primary master; on a
    // machine without a legacy IDE disk (e.g. q35, or a disk-less boot) it simply
    // reports "no disk" and the kernel carries on.
    ata.init();
    ata.selfTest();

    // Bring up the AHCI/SATA disk (DMA block device, read-only: IDENTIFY + sector
    // read). Finds the SATA HBA on q35's ich9-ahci; on a machine without one
    // (e.g. i440fx / -M pc, or a disk-less boot) it reports "no controller" and
    // the kernel carries on.
    ahci.init();
    ahci.selfTest();

    // Mount the FAT32 filesystem on the disk (if any) and prove the read path.
    fat32.selfTest();

    serial.print("[OBSIDIA] Kernel initialized successfully.\n", .{});
    serial.print("BOOT_OK\n", .{}); // the marker our test harness greps for
    serial.print("========================================\n", .{});

    // Switch off Limine's boot stack (which lives in bootloader-reclaimable
    // memory) onto our own kernel stack, then reclaim that memory and start the
    // shell. runAfterReclaim never returns, so the old stack is never touched
    // again and its frames are safe to free.
    const stack_top = @intFromPtr(&kernel_stack) + kernel_stack.len;
    asm volatile (
        \\ movq %[sp], %rsp
        \\ callq *%[entry]
        :
        : [sp] "r" (stack_top), // new stack top (16-byte aligned)
          [entry] "r" (&runAfterReclaim), // function to run on the new stack
        : "memory"
    );
    unreachable; // runAfterReclaim never returns
}

// Runs on the kernel-owned stack: reclaim Limine's boot memory, then bring up
// the PS/2 keyboard and the interactive shell. Never returns. Commands can be
// typed locally (on the framebuffer) as well as over serial.
fn runAfterReclaim() callconv(.C) noreturn {
    pmm.reclaimBootloader(); // safe now: we're off Limine's boot stack

    scheduler.selfTest(); // demo cooperative kernel-thread context switching
    scheduler.preemptDemo(); // demo timer-driven preemption (threads that never yield)
    scheduler.blockSleepDemo(); // demo blocking sleep (a thread sleeps, the timer wakes it)
    scheduler.mutexDemo(); // demo the blocking Mutex (two threads contend; mutual exclusion)
    usermode.selfTest(); // demo ring 3: run user code at CPL3 and recover from its #GP
    vmm.selfTestAddressSpace(); // demo a per-process address space (create/switch/destroy)
    vmm.selfTestUncacheable(); // demo an uncacheable (PCD/UC) MMIO-style mapping
    scheduler.userProcessDemo(); // demo a real ring-3 process scheduled with a kernel thread

    // Load and run the init binary off the disk (if present) as a RING-3 PROCESS
    // — an ELF64 at /INIT.ELF, else a flat /INIT. The first code this kernel runs
    // that came from a filesystem, and the first userland it runs at boot. Runs
    // here (after the reclaim + the scheduler demos) so it's in the same proven
    // environment the other ring-3 runs use.
    loader.selfTest();

    shell.init(); // enable serial-RX interrupts (IRQ4)
    shell.setAuthModule(authModule()); // credential from Limine (preferred over the disk file)
    install.setImage(systemModule()); // Option A: system image to clone if `install` is run
    install.setPayload(kernelModule(), bootx64Module(), installedConfModule()); // Option B: build a disk
    keyboard.init(); // enable the PS/2 keyboard (IRQ1)
    keyboard.setSink(&shell.feed); // route keystrokes into the shell
    mouse.init(); // enable the PS/2 mouse (IRQ12); the wheel drives scrollback

    // Make the shell a real scheduled thread. From here the kernel multitasks:
    // the timer preempts between the idle thread (this context) and the shell.
    scheduler.init(); // adopt this context as the idle thread (thread 0)
    scheduler.spawn("shell", &shellThread); // the shell runs as thread 1
    scheduler.startPreemption(); // permanent timer-driven preemption
    scheduler.idle(); // idle forever; the scheduler runs the shell. never returns
}

// The shell's command loop, wrapped so it can run as a kernel thread.
fn shellThread() void {
    shell.run();
}
