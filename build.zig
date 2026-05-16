const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module — shared with analyzer so it can dog-food safe.Box
    const safe_module = b.addModule("safe", .{
        .root_source_file = b.path("lib/safe.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library tests
    const lib_test_step = b.step("test", "Run library tests");
    const lib_test_mod = b.createModule(.{
        .root_source_file = b.path("lib/safe.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_test_mod.link_libc = true;
    const lib_tests = b.addTest(.{
        .name = "safe_tests",
        .root_module = lib_test_mod,
    });
    lib_test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    // SIMD tests
    const simd_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/simd_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    simd_test_mod.addImport("safe", safe_module);
    simd_test_mod.link_libc = true;
    const simd_test = b.addTest(.{
        .name = "simd_tests",
        .root_module = simd_test_mod,
    });
    const run_simd_test = b.addRunArtifact(simd_test);
    lib_test_step.dependOn(&run_simd_test.step);

    // Fuzz tests
    const fuzz_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_test_mod.addImport("safe", safe_module);
    fuzz_test_mod.link_libc = true;
    const fuzz_test = b.addTest(.{
        .name = "fuzz_tests",
        .root_module = fuzz_test_mod,
    });
    const run_fuzz_test = b.addRunArtifact(fuzz_test);
    lib_test_step.dependOn(&run_fuzz_test.step);

    // Analyzer executable (dog-foods safe.Box)
    const analyzer_mod = b.createModule(.{
        .root_source_file = b.path("analyzer/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    analyzer_mod.addImport("safe", safe_module);
    analyzer_mod.link_libc = true;
    const analyzer_exe = b.addExecutable(.{
        .name = "zust-analyze",
        .root_module = analyzer_mod,
    });
    b.installArtifact(analyzer_exe);

    // Wasm build step for zust-analyzer
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("analyzer/src/main.zig"),
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

    // Analyzer tests
    const analyzer_test_step = b.step("test-analyzer", "Run analyzer tests");
    const analyzer_test_mod = b.createModule(.{
        .root_source_file = b.path("analyzer/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    analyzer_test_mod.addImport("safe", safe_module);
    analyzer_test_mod.link_libc = true;
    const analyzer_tests = b.addTest(.{
        .name = "analyzer_tests",
        .root_module = analyzer_test_mod,
    });
    analyzer_test_step.dependOn(&b.addRunArtifact(analyzer_tests).step);

    // All tests
    const all_test_step = b.step("test-all", "Run all tests");
    all_test_step.dependOn(lib_test_step);
    all_test_step.dependOn(analyzer_test_step);

    // ─── zust-analyzer build step ───
    // Creates `zig build analyze` which runs the analyzer on the library source.
    // This demonstrates dog-fooding: we use safe.Box inside the analyzer, then
    // run the analyzer on code that uses safe.Box.

    // Build options for the analyzer
    const strictness = b.option([]const u8, "strictness", "Analyzer strictness: low|medium|high (default: medium)") orelse "medium";
    const sarif = b.option(bool, "sarif", "Output SARIF 2.1.0 JSON instead of human-readable (default: false)") orelse false;

    const run_analyzer = b.addRunArtifact(analyzer_exe);
    // Library files
    run_analyzer.addFileArg(b.path("lib/Box.zig"));
    run_analyzer.addFileArg(b.path("lib/LinkedList.zig"));
    run_analyzer.addFileArg(b.path("lib/ArrayList.zig"));
    run_analyzer.addFileArg(b.path("lib/Arc.zig"));
    run_analyzer.addFileArg(b.path("lib/Arena.zig"));
    run_analyzer.addFileArg(b.path("lib/Mutex.zig"));
    run_analyzer.addFileArg(b.path("lib/Slice.zig"));
    run_analyzer.addFileArg(b.path("lib/Scope.zig"));
    run_analyzer.addFileArg(b.path("lib/Async.zig"));
    run_analyzer.addFileArg(b.path("lib/Rc.zig"));
    run_analyzer.addFileArg(b.path("lib/Cell.zig"));
    run_analyzer.addFileArg(b.path("lib/HashMap.zig"));
    run_analyzer.addFileArg(b.path("lib/OnceCell.zig"));
    run_analyzer.addFileArg(b.path("lib/LazyStatic.zig"));
    run_analyzer.addFileArg(b.path("lib/SmallString.zig"));
    run_analyzer.addFileArg(b.path("lib/String.zig"));
    run_analyzer.addFileArg(b.path("lib/Cow.zig"));
    run_analyzer.addFileArg(b.path("lib/DeadlockDetector.zig"));
    run_analyzer.addFileArg(b.path("lib/Iterators.zig"));
    run_analyzer.addFileArg(b.path("lib/ManuallyDrop.zig"));
    run_analyzer.addFileArg(b.path("lib/MaybeUninit.zig"));
    run_analyzer.addFileArg(b.path("lib/Pin.zig"));
    run_analyzer.addFileArg(b.path("lib/BTreeMap.zig"));
    run_analyzer.addFileArg(b.path("lib/HashSet.zig"));
    run_analyzer.addFileArg(b.path("lib/BinaryHeap.zig"));
    run_analyzer.addFileArg(b.path("lib/Channel.zig"));
    run_analyzer.addFileArg(b.path("lib/UnsafeCell.zig"));
    run_analyzer.addFileArg(b.path("lib/PhantomData.zig"));
    run_analyzer.addFileArg(b.path("lib/VecDeque.zig"));
    run_analyzer.addFileArg(b.path("lib/RingBuffer.zig"));
    run_analyzer.addFileArg(b.path("lib/Stack.zig"));
    run_analyzer.addFileArg(b.path("lib/Pool.zig"));
    run_analyzer.addFileArg(b.path("lib/SimdUtils.zig"));
    run_analyzer.addFileArg(b.path("lib/BitSet.zig"));
    run_analyzer.addFileArg(b.path("lib/OffsetGuard.zig"));
    run_analyzer.addFileArg(b.path("lib/Aligned.zig"));
    run_analyzer.addFileArg(b.path("lib/Allocator.zig"));
    run_analyzer.addFileArg(b.path("lib/Lifetime.zig"));
    run_analyzer.addFileArg(b.path("lib/TaggedUnion.zig"));
    run_analyzer.addFileArg(b.path("lib/ThreadPool.zig"));
    run_analyzer.addFileArg(b.path("lib/Semaphore.zig"));
    run_analyzer.addFileArg(b.path("lib/Barrier.zig"));
    run_analyzer.addFileArg(b.path("lib/LockFreeQueue.zig"));
    run_analyzer.addFileArg(b.path("lib/AtomicCounter.zig"));
    run_analyzer.addFileArg(b.path("lib/TimedLock.zig"));
    run_analyzer.addFileArg(b.path("lib/LockHierarchy.zig"));
    run_analyzer.addFileArg(b.path("lib/RwLock2.zig"));
    run_analyzer.addFileArg(b.path("lib/BloomFilter.zig"));
    run_analyzer.addFileArg(b.path("lib/BTreeSet.zig"));
    run_analyzer.addFileArg(b.path("lib/PathBuf.zig"));
    run_analyzer.addFileArg(b.path("lib/Duration.zig"));
    run_analyzer.addFileArg(b.path("lib/CString.zig"));
    run_analyzer.addFileArg(b.path("lib/Condvar.zig"));
    run_analyzer.addFileArg(b.path("lib/safe.zig"));
    // Analyzer files
    run_analyzer.addFileArg(b.path("analyzer/src/Analysis.zig"));
    run_analyzer.addFileArg(b.path("analyzer/src/main.zig"));
    run_analyzer.addFileArg(b.path("analyzer/src/Provenance.zig"));
    run_analyzer.addFileArg(b.path("analyzer/src/Diagnostics.zig"));
    run_analyzer.addFileArg(b.path("analyzer/src/LSP.zig"));
    run_analyzer.addFileArg(b.path("analyzer/src/JSONRPC.zig"));
    run_analyzer.addFileArg(b.path("analyzer/src/Contract.zig"));
    run_analyzer.addFileArg(b.path("tools/transpiler.zig"));

    // Pass options
    run_analyzer.addArg(b.fmt("--strictness={s}", .{strictness}));
    if (sarif) {
        run_analyzer.addArg("--sarif");
    }

    const analyze_step = b.step("analyze", "Run zust-analyzer on source files (dog-food check)");
    analyze_step.dependOn(&run_analyzer.step);

    // HTTP server example
    const http_example_mod = b.createModule(.{
        .root_source_file = b.path("examples/http_server.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    http_example_mod.addImport("safe", safe_module);
    http_example_mod.link_libc = true;
    const http_example = b.addExecutable(.{
        .name = "http_server",
        .root_module = http_example_mod,
    });
    const http_step = b.step("http-example", "Build HTTP server example");
    http_step.dependOn(&b.addInstallArtifact(http_example, .{}).step);

    // JSON parser example
    const json_example_mod = b.createModule(.{
        .root_source_file = b.path("examples/json_parser.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    json_example_mod.addImport("safe", safe_module);
    json_example_mod.link_libc = true;
    const json_example = b.addExecutable(.{
        .name = "json_parser",
        .root_module = json_example_mod,
    });
    const json_step = b.step("json-example", "Build JSON parser example");
    json_step.dependOn(&b.addInstallArtifact(json_example, .{}).step);

    // Benchmark suite
    const bench_step = b.step("bench", "Run benchmarks");
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("safe", safe_module);
    bench_mod.link_libc = true;
    const bench_exe = b.addExecutable(.{
        .name = "benchmarks",
        .root_module = bench_mod,
    });
    const bench_run = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_run.step);

    // Transpiler executable
    const transpiler_mod = b.createModule(.{
        .root_source_file = b.path("tools/transpiler.zig"),
        .target = target,
        .optimize = optimize,
    });
    transpiler_mod.addImport("safe", safe_module);
    transpiler_mod.link_libc = true;
    const transpiler_exe = b.addExecutable(.{
        .name = "zust-transpile",
        .root_module = transpiler_mod,
    });
    b.installArtifact(transpiler_exe);

    // Transpiler tests
    const transpiler_test_step = b.step("test-transpiler", "Run transpiler tests");
    const transpiler_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/transpiler.zig"),
        .target = target,
        .optimize = optimize,
    });
    transpiler_test_mod.addImport("safe", safe_module);
    transpiler_test_mod.link_libc = true;
    const transpiler_tests = b.addTest(.{
        .name = "transpiler_tests",
        .root_module = transpiler_test_mod,
    });
    transpiler_test_step.dependOn(&b.addRunArtifact(transpiler_tests).step);

    // Transpiler build step
    const transpile_step = b.step("transpile", "Build transpiler tool");
    transpile_step.dependOn(&b.addInstallArtifact(transpiler_exe, .{}).step);

    // Documentation generator
    const docs_step = b.step("docs", "Generate documentation site");
    const docs_mod = b.createModule(.{
        .root_source_file = b.path("docs/generate.zig"),
        .target = target,
        .optimize = optimize,
    });
    docs_mod.link_libc = true;
    const docs_exe = b.addExecutable(.{
        .name = "generate-docs",
        .root_module = docs_mod,
    });
    const docs_run = b.addRunArtifact(docs_exe);
    docs_step.dependOn(&docs_run.step);

    // Optional: make `zig build` also run the analyzer (uncomment to enable)
    // b.getInstallStep().dependOn(analyze_step);
}
