const std = @import("std");
const limine = @import("limine");
const serial = @import("serial.zig");

// Request a framebuffer from the bootloader. 
// Limine will read this struct, set up the screen, and populate the response with the memory address.
export var framebuffer_request: limine.FramebufferRequest = .{};

// The entry point called by Limine. It must use the C calling convention.
export fn _start() callconv(.C) noreturn {

    // Initialize the COM1 serial port
    serial.init();

    // Send our first formatted log message out of the VM!
    serial.print("========================================\n", .{});
    serial.print("[OBSIDIA] Kernel initialized successfully.\n", .{});
    serial.print("[OBSIDIA] Running on modern x86_64 architecture.\n", .{});
    serial.print("========================================\n", .{});

    while (true) {
        // x86_64 specific instruction to halt the processor until the next interrupt
        asm volatile ("hlt");
    }
}
