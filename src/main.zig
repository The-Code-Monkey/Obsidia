// Kernel entry point. Limine (the bootloader) loads us in 64-bit long mode with
// paging already on, then jumps to `_start`. This file declares the Limine
// requests we need, then brings up each subsystem in order, logging as it goes.

const builtin = @import("builtin"); // compile-time target info (CPU arch, etc.)
const limine = @import("limine"); // Limine boot-protocol bindings (48cf/limine-zig)
const serial = @import("drivers/serial.zig"); // COM1 logging
const gdt = @import("arch/gdt.zig"); // segment descriptors + TSS
const idt = @import("arch/idt.zig"); // interrupt/exception handlers
const pic = @import("arch/pic.zig"); // legacy interrupt controller + timer
const pmm = @import("mm/pmm.zig"); // physical frame allocator
const vmm = @import("mm/vmm.zig"); // page tables / virtual memory
const heap = @import("mm/heap.zig"); // kernel heap (std.mem.Allocator)
const console = @import("drivers/console.zig"); // on-screen framebuffer text console
const keyboard = @import("drivers/keyboard.zig"); // PS/2 keyboard input
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
// Force 4-level paging so the VMM's table walk is correct regardless of CPU.
export var paging_mode_request: limine.PagingModeRequest linksection(".limine_requests") = .{
    .mode = .@"4lvl", // preferred mode
    .max_mode = .@"4lvl", // never give us 5-level
    .min_mode = .@"4lvl", // never give us less than 4-level
};

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

    serial.print("[OBSIDIA] Kernel initialized successfully.\n", .{});
    serial.print("BOOT_OK\n", .{}); // the marker our test harness greps for
    serial.print("========================================\n", .{});

    // Hand off to the interactive shell. It enables serial-RX interrupts and
    // loops forever processing typed commands, so it never returns. We also bring
    // up the PS/2 keyboard and point it at the shell's input, so commands can be
    // typed locally (on the framebuffer) as well as over serial.
    shell.init();
    keyboard.init();
    keyboard.setSink(&shell.feed);
    shell.run();
}
