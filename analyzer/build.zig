const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Safe library module (dog-food our own library)
    const safe_module = b.createModule(.{
        .root_source_file = b.path("../lib/safe.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("safe", safe_module);

    const exe = b.addExecutable(.{
        .name = "zust-analyze",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the analyzer");
    run_step.dependOn(&run_cmd.step);

    // Wasm build step
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm_mod.addImport("safe", safe_module);
    const wasm_exe = b.addExecutable(.{
        .name = "zust-analyzer",
        .root_module = wasm_mod,
    });
    const wasm_step = b.step("wasm", "Build zust-analyzer as WebAssembly module");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{ .dest_dir = .{ .override = .bin } }).step);

    const test_step = b.step("test", "Run analyzer tests");
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("safe", safe_module);
    const tests = b.addTest(.{
        .name = "analyzer_tests",
        .root_module = test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
