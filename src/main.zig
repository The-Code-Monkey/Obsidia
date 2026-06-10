const std = @import("std");
const limine = @import("limine");

// Request a framebuffer from the bootloader. 
// Limine will read this struct, set up the screen, and populate the response with the memory address.
export var framebuffer_request: limine.FramebufferRequest = .{};

// The entry point called by Limine. It must use the C calling convention.
export fn _start() callconv(.C) noreturn {
    
    // Here is where you will eventually initialize memory, GDT, IDT, and drivers.
    // For now, we secure the system state by halting the CPU.

    while (true) {
        // x86_64 specific instruction to halt the processor until the next interrupt
        asm volatile ("hlt");
    }
}
