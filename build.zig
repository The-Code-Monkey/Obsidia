const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    
    // Define the target architecture (x86_64, bare metal, none OS)
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // Create the kernel executable
    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Monolithic kernels need a custom linker script to place sections correctly in memory
        .code_model = .kernel, 
    });

    // Import the Limine module so the kernel can parse bootloader data
    const limine = b.dependency("limine", .{});
    kernel.root_module.addImport("limine", limine.module("limine"));

    // We want the kernel to be output to zig-out/bin/
    b.installArtifact(kernel);
}
