// Kernel entry point. Limine (the bootloader) loads us in 64-bit long mode with
// paging already on, then jumps to `_start`. This file declares the Limine
// requests we need, then brings up each subsystem in order, logging as it goes.

const builtin = @import("builtin"); // compile-time target info (CPU arch, etc.)
const std = @import("std"); // for the panic-handler wiring
const limine = @import("limine"); // Limine boot-protocol bindings (48cf/limine-zig)
const serial = @import("drivers/serial.zig"); // COM1 logging
const gdt = @import("arch/gdt.zig"); // segment descriptors + TSS
const idt = @import("arch/idt.zig"); // interrupt/exception handlers
const pic = @import("arch/pic.zig"); // legacy interrupt controller + timer
const apic = @import("arch/apic.zig"); // modern interrupt controller (LAPIC + IO APIC)
const pmm = @import("mm/pmm.zig"); // physical frame allocator
const vmm = @import("mm/vmm.zig"); // page tables / virtual memory
const heap = @import("mm/heap.zig"); // kernel heap (std.mem.Allocator)
const console = @import("drivers/console.zig"); // on-screen framebuffer text console
const keyboard = @import("drivers/keyboard.zig"); // PS/2 keyboard input
const acpi = @import("acpi/acpi.zig"); // ACPI table parsing
const scheduler = @import("sched/scheduler.zig"); // cooperative kernel threads
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
// Force 4-level paging so the VMM's table walk is correct regardless of CPU.
export var paging_mode_request: limine.PagingModeRequest linksection(".limine_requests") = .{
    .mode = .@"4lvl", // preferred mode
    .max_mode = .@"4lvl", // never give us 5-level
    .min_mode = .@"4lvl", // never give us less than 4-level
};

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

    shell.init(); // enable serial-RX interrupts (IRQ4)
    keyboard.init(); // enable the PS/2 keyboard (IRQ1)
    keyboard.setSink(&shell.feed); // route keystrokes into the shell
    shell.run(); // the command loop (never returns)
}
