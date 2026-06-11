const builtin = @import("builtin");
const limine = @import("limine");
const serial = @import("serial.zig");

export var start_marker: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var end_marker: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

export var base_revision: limine.BaseRevision linksection(".limine_requests") = .init(3);
export var framebuffer_request: limine.FramebufferRequest linksection(".limine_requests") = .{};

fn hcf() noreturn {
    while (true) {
        switch (builtin.cpu.arch) {
            .x86_64 => asm volatile ("hlt"),
            .aarch64 => asm volatile ("wfi"),
            .riscv64 => asm volatile ("wfi"),
            .loongarch64 => asm volatile ("idle 0"),
            else => unreachable,
        }
    }
}

export fn _start() noreturn {
    // Serial first, so we can see everything that follows — including failures.
    serial.init();
    serial.print("========================================\n", .{});
    serial.print("[OBSIDIA] Kernel entered _start.\n", .{});

    if (!base_revision.isSupported()) {
        serial.print("[OBSIDIA] PANIC: base revision not supported\n", .{});
        hcf();
    }
    serial.print("[OBSIDIA] Base revision OK.\n", .{});

    if (framebuffer_request.response) |fb_response| {
        const fb = fb_response.getFramebuffers()[0];
        serial.print("[OBSIDIA] Framebuffer acquired: {}x{}\n", .{ fb.width, fb.height });
    } else {
        serial.print("[OBSIDIA] WARN: no framebuffer response\n", .{});
    }

    serial.print("[OBSIDIA] Kernel initialized successfully.\n", .{});
    serial.print("BOOT_OK\n", .{});
    serial.print("========================================\n", .{});

    // Signal success to the CI harness and exit QEMU cleanly.
    serial.outb(0xf4, 0x10); // exits QEMU with status (0x10<<1)|1 = 33

    hcf();
}
}
