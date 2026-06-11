const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Bare-metal x86_64: disable SSE/AVX/MMX (not usable before the FPU is
    // configured) and use software floating point. Emitting any SSE instruction
    // before enabling it faults at boot, so this is mandatory.
    const Target = std.Target.x86;
    var query: std.Target.Query = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };
    query.cpu_features_add = Target.featureSet(&.{ .popcnt, .soft_float });
    query.cpu_features_sub = Target.featureSet(&.{ .avx, .avx2, .sse, .sse2, .mmx });

    const target = b.resolveTargetQuery(query);

    const kernel_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    kernel_module.red_zone = false;
    kernel_module.code_model = .kernel;

    const limine = b.dependency("limine", .{ .api_revision = 3 });
    kernel_module.addImport("limine", limine.module("limine"));

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = kernel_module,
    });

    kernel.setLinkerScript(b.path("linker-x86_64.lds"));

    b.installArtifact(kernel);
}
