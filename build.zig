const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
    });

    // Attach the higher-half linker script
    kernel.setLinkerScript(b.path("linker.ld"));

    // Freestanding kernels must not assume a red zone
    kernel.root_module.red_zone = false;

    // Limine bindings, compiled against API revision 3
    const limine = b.dependency("limine", .{
        .api_revision = 3,
        .allow_deprecated = false,
        .no_pointers = false,
    });
    kernel.root_module.addImport("limine", limine.module("limine"));

    b.installArtifact(kernel);
}
