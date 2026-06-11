const std = @import("std"); // Zig build system API

// `zig build` calls this function to describe how to compile the kernel.
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{}); // -Doptimize=... (Debug/Release*)

    // Bare-metal x86_64: disable SSE/AVX/MMX (not usable before the FPU is
    // configured) and use software floating point. Emitting any SSE instruction
    // before enabling it faults at boot, so this is mandatory.
    const Target = std.Target.x86; // x86 feature definitions namespace
    var query: std.Target.Query = .{
        .cpu_arch = .x86_64, // 64-bit x86
        .os_tag = .freestanding, // no OS underneath us — we ARE the OS
        .abi = .none, // no libc / ABI conventions to honor
    };
    // Add: popcnt (handy) and soft_float (do floating point in software).
    query.cpu_features_add = Target.featureSet(&.{ .popcnt, .soft_float });
    // Remove the vector/FPU feature families so the compiler never emits them.
    query.cpu_features_sub = Target.featureSet(&.{ .avx, .avx2, .sse, .sse2, .mmx });

    const target = b.resolveTargetQuery(query); // resolve the query into a target

    // Create the kernel's root module from main.zig with our target + optimize.
    const kernel_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"), // entry source file
        .target = target,
        .optimize = optimize,
    });
    kernel_module.red_zone = false; // no red zone: interrupts would corrupt it
    kernel_module.code_model = .kernel; // higher-half code model (top 2 GiB)

    // Pull in the Limine bindings dependency, selecting API revision 3.
    const limine = b.dependency("limine", .{ .api_revision = 3 });
    kernel_module.addImport("limine", limine.module("limine")); // import as "limine"

    // Build the kernel ELF executable from that module.
    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = kernel_module,
    });

    // Use our custom linker script (higher-half layout + Limine sections).
    kernel.setLinkerScript(b.path("linker-x86_64.lds"));

    b.installArtifact(kernel); // copy kernel.elf into zig-out/bin on `zig build`

    // Unit tests: compiled for the HOST (so they actually run on the dev machine)
    // rather than the freestanding kernel target. `zig build test` runs them.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.resolveTargetQuery(.{}), // native host target
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run host unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
