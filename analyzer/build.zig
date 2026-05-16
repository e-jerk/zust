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
