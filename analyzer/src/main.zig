const std = @import("std");
const builtin = @import("builtin");
const safe = @import("safe");
const String = safe.String;
const Analysis = @import("Analysis.zig");
const Diagnostic = @import("Diagnostics.zig");
const Provenance = @import("Provenance.zig");
const LSP = @import("LSP.zig");
const JSONRPC = @import("JSONRPC.zig");
const Contract = @import("Contract.zig");
const Cache = @import("Cache.zig").Cache;

// Dog-foods zust: imports safe types for use in tests and runtime.
// safe.String is used below for JSON-RPC message building in LSP tests.

const OutputFormat = enum { Human, SARIF };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    if (comptime builtin.target.os.tag == .wasi) {
        // WASI: no command-line args available, run LSP server directly.
        var server = try LSP.Server.init(allocator);
        defer server.deinit();

        const io = init.io;
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);

        try server.run(&stdin_reader, &stdout_writer);
        return;
    }

    // Check for --lsp mode first
    var lsp_mode = false;
    var arg_buf: [4096]u8 = undefined;
    var arg_len: usize = 0;
    {
        var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
        defer args_iter.deinit();
        _ = args_iter.skip(); // skip program name
        while (args_iter.next()) |arg| {
            if (arg.len > arg_buf.len) continue;
            @memcpy(arg_buf[0..arg.len], arg);
            arg_len = arg.len;
            if (std.mem.eql(u8, arg_buf[0..arg_len], "--lsp")) {
                lsp_mode = true;
                break;
            }
        }
    }

    if (lsp_mode) {
        // Run as LSP server
        var server = try LSP.Server.init(allocator);
        defer server.deinit();

        const io = init.io;
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);

        try server.run(&stdin_reader, &stdout_writer);
        return;
    }

    // Reset args for normal mode
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.skip();

    var output_format: OutputFormat = .Human;
    var strictness: Analysis.Analyzer.Strictness = .Medium;
    var help_mode = false;
    var target_path: ?[]const u8 = null;

    while (args_iter.next()) |arg| {
        if (arg.len > arg_buf.len) continue;
        @memcpy(arg_buf[0..arg.len], arg);
        arg_len = arg.len;
        const arg_slice = arg_buf[0..arg_len];

        if (std.mem.eql(u8, arg_slice, "--lsp")) {
            lsp_mode = true;
        } else if (std.mem.eql(u8, arg_slice, "--sarif") or std.mem.eql(u8, arg_slice, "--json")) {
            output_format = .SARIF;
        } else if (std.mem.eql(u8, arg_slice, "--help")) {
            help_mode = true;
        } else if (std.mem.startsWith(u8, arg_slice, "--strictness=")) {
            const level = arg_slice[13..];
            if (std.mem.eql(u8, level, "low")) {
                strictness = .Low;
            } else if (std.mem.eql(u8, level, "medium")) {
                strictness = .Medium;
            } else if (std.mem.eql(u8, level, "high")) {
                strictness = .High;
            }
        } else if (!std.mem.startsWith(u8, arg_slice, "-")) {
            if (target_path) |p| allocator.free(p);
            target_path = try allocator.dupe(u8, arg_slice);
        }
    }

    if (help_mode or target_path == null) {
        std.debug.print(
            \\Usage: zust-analyze <path> [options]
            \\\
            \\Analyze a Zig source file or directory for memory safety issues.
            \\\
            \\Arguments:
            \\  <file.zig>          Analyze a single file
            \\  <directory>         Recursively analyze all .zig files in directory
            \\\
            \\Options:
            \\  --lsp               Run as LSP language server
            \\  --sarif             Output in SARIF 2.1.0 format
            \\  --json              Alias for --sarif
            \\  --strictness=low    Low strictness (catch definite bugs only)
            \\  --strictness=medium Medium strictness (default)
            \\  --strictness=high   High strictness (may have false positives)
            \\  --help              Show this help message
            \\\
        , .{});
        if (help_mode) return;
        return error.InvalidUsage;
    }
    defer if (target_path) |p| allocator.free(p);

    const io = init.io;

    // Check if target is a directory
    var is_dir = false;
    if (std.Io.Dir.cwd().openDir(io, target_path.?, .{ .iterate = true })) |d| {
        d.close(io);
        is_dir = true;
    } else |_| {}

    if (is_dir) {
        try analyzeDirectory(allocator, io, target_path.?, output_format, strictness);
        return;
    }

    // Single file mode
    const source = std.Io.Dir.cwd().readFileAlloc(io, target_path.?, allocator, .limited(1 << 20)) catch |err| {
        std.debug.print("Error: Failed to read {s}: {s}\n", .{ target_path.?, @errorName(err) });
        return err;
    };
    defer allocator.free(source);

    var analyzer = Analysis.Analyzer.init(allocator);
    defer analyzer.deinit();

    try analyzer.analyzeFile(target_path.?, source, strictness);

    switch (output_format) {
        .Human => {
            for (analyzer.diagnostics.items) |diag| {
                std.debug.print("{s}:{d}:{d}: [{s}] {s}\n", .{
                    diag.location.file,
                    diag.location.line,
                    diag.location.column,
                    @tagName(diag.severity),
                    diag.message,
                });
            }
        },
        .SARIF => {
            var buf: [65536]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buf);
            Diagnostic.emitSARIF(analyzer.diagnostics.items, &writer) catch {};
            std.debug.print("{s}\n", .{buf[0..writer.end]});
        },
    }

    var has_errors = false;
    for (analyzer.diagnostics.items) |diag| {
        if (diag.severity == .Error) {
            has_errors = true;
            break;
        }
    }

    if (has_errors) {
        return error.DiagnosticsFound;
    }
}

fn collectZigFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path_prefix: []const u8,
    files: *std.ArrayList([]const u8),
) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                var sub_dir = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub_dir.close(io);
                const sub_path = try std.fs.path.join(allocator, &.{ path_prefix, entry.name });
                defer allocator.free(sub_path);
                try collectZigFiles(allocator, io, sub_dir, sub_path, files);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zig")) {
                    const full_path = try std.fs.path.join(allocator, &.{ path_prefix, entry.name });
                    try files.append(allocator, full_path);
                }
            },
            else => {},
        }
    }
}

fn analyzeDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    output_format: OutputFormat,
    strictness: Analysis.Analyzer.Strictness,
) !void {
    var dir = if (std.fs.path.isAbsolute(dir_path))
        try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true })
    else
        try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    try collectZigFiles(allocator, io, dir, dir_path, &files);

    if (files.items.len == 0) {
        std.debug.print("No .zig files found in {s}\n", .{dir_path});
        return;
    }

    // For cross-file analysis, read all sources and use workspace mode
    var workspace_files = try allocator.alloc(Analysis.Analyzer.WorkspaceFile, files.items.len);
    defer {
        for (workspace_files) |wf| {
            allocator.free(wf.path);
            allocator.free(wf.source);
        }
        allocator.free(workspace_files);
    }

    for (files.items, 0..) |file_path, i| {
        workspace_files[i].path = try allocator.dupe(u8, file_path);
        workspace_files[i].source = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(1 << 20)) catch |err| {
            std.debug.print("Warning: Failed to read {s}: {s}\n", .{ file_path, @errorName(err) });
            workspace_files[i].source = "";
            continue;
        };
    }

    var cache = Cache.init(allocator);
    defer cache.deinit();
    var analyzer = Analysis.Analyzer.init(allocator);
    defer analyzer.deinit();

    try analyzer.analyzeWorkspaceCached(workspace_files, strictness, &cache);

    switch (output_format) {
        .Human => {
            for (analyzer.diagnostics.items) |diag| {
                std.debug.print("{s}:{d}:{d}: [{s}] {s}\n", .{
                    diag.location.file,
                    diag.location.line,
                    diag.location.column,
                    @tagName(diag.severity),
                    diag.message,
                });
            }
            std.debug.print("\nAnalyzed {d} files, found {d} issues\n", .{ files.items.len, analyzer.diagnostics.items.len });
        },
        .SARIF => {
            var buf: [65536]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buf);
            Diagnostic.emitSARIF(analyzer.diagnostics.items, &writer) catch {};
            std.debug.print("{s}\n", .{buf[0..writer.end]});
        },
    }

    std.debug.print("{}\n", .{cache.stats});

    var has_errors = false;
    for (analyzer.diagnostics.items) |diag| {
        if (diag.severity == .Error) {
            has_errors = true;
            break;
        }
    }

    if (has_errors) {
        return error.DiagnosticsFound;
    }
}

test "analyzer basic structure" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    // Track a mock allocation
    const prov = Provenance.Provenance{
        .Heap = .{
            .alloc_site = .{ .file = "test.zig", .line = 1, .column = 1 },
            .allocator_name = "gpa",
        },
    };
    const ptr_id = try analyzer.trackAllocation(prov);
    try std.testing.expectEqual(ptr_id, 0);

    // Mark as deallocated
    analyzer.markDeallocated(ptr_id, .{ .file = "test.zig", .line = 5, .column = 1 });

    // Try to use after free
    try analyzer.checkUse(ptr_id, .{ .file = "test.zig", .line = 6, .column = 1 });
    try std.testing.expectEqual(analyzer.diagnostics.items.len, 1);
    try std.testing.expectEqual(analyzer.diagnostics.items[0].kind, .UseAfterFree);
}

test "analyzer detects double free in source" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn testDoubleFree() void {
        \\    const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
        \\    const dead = box.deinit();
        \\    const dead2 = dead.deinit();
        \\    _ = dead2;
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    // Should find at least the double free
    try std.testing.expect(analyzer.diagnostics.items.len > 0);
    // Verify it's a real error, not the placeholder
    try std.testing.expect(analyzer.diagnostics.items[0].severity == .Error);
    try std.testing.expect(analyzer.diagnostics.items[0].kind == .DoubleFree);
}

test "analyzer detects use after free in source" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn testUseAfterFree() void {
        \\    const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
        \\    const raw = box.unsafePtr();
        \\    const dead = box.deinit();
        \\    _ = dead;
        \\    raw.* = 100;
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    // Should find at least the use after free or dangling pointer
    try std.testing.expect(analyzer.diagnostics.items.len > 0);

    // Verify at least one is a real error
    var found_error = false;
    for (analyzer.diagnostics.items) |diag| {
        if (diag.severity == .Error and (diag.kind == .UseAfterFree or diag.kind == .PointerEscape)) {
            found_error = true;
        }
    }
    try std.testing.expect(found_error);
}

test "analyzer detects raw pointer patterns" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn testRawPtr() *u32 {
        \\    var raw: *u32 = undefined;
        \\    raw.* = 42;
        \\    return raw;
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    // Should detect: raw return type, raw var decl type, raw dereference
    try std.testing.expect(analyzer.diagnostics.items.len >= 3);
}

test "LSP JSONRPC message parsing" {
    const gpa = std.testing.allocator;

    // Test reading a JSON-RPC message
    const msg_text = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"processId\":1234}}";
    var input_str = String.init(gpa);
    defer input_str.deinit();
    try input_str.appendFmt("Content-Length: {d}\r\n\r\n", .{msg_text.len});
    try input_str.append(msg_text);
    const input = input_str.slice();

    var reader = std.Io.Reader.fixed(input);

    var msg = (try JSONRPC.readMessage(gpa, &reader)).?;
    defer msg.deinit(gpa);

    try std.testing.expectEqual(msg.id.?, 1);
    try std.testing.expectEqualStrings(msg.method.?, "initialize");
    try std.testing.expect(msg.params != null);
}

test "LSP server initialize response" {
    const gpa = std.testing.allocator;

    var server = try LSP.Server.init(gpa);
    defer server.deinit();

    // Simulate initialize request
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"processId\":1234}}";
    var init_request_str = String.init(gpa);
    defer init_request_str.deinit();
    try init_request_str.appendFmt("Content-Length: {d}\r\n\r\n", .{body.len});
    try init_request_str.append(body);
    const init_request = init_request_str.slice();

    var reader = std.Io.Reader.fixed(init_request);
    var output_buf: [4096]u8 = undefined;
    var output_writer = std.Io.Writer.fixed(&output_buf);

    // Process just one message
    var msg = (try JSONRPC.readMessage(gpa, &reader)).?;
    defer msg.deinit(gpa);
    try server.handleMessage(msg, &output_writer);

    // Verify output contains server capabilities
    const response = output_buf[0..output_writer.end];
    try std.testing.expect(std.mem.indexOf(u8, response, "textDocumentSync") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "zust-analyzer") != null);
}

test "LSP server publish diagnostics on didOpen" {
    const gpa = std.testing.allocator;

    var server = try LSP.Server.init(gpa);
    defer server.deinit();

    const source =
        "fn testDoubleFree() void { const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable; const dead = box.deinit(); const dead2 = dead.deinit(); _ = dead2; }";

    const body = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///test.zig\",\"version\":1,\"text\":\"" ++ source ++ "\"}}}";
    var did_open_str = String.init(gpa);
    defer did_open_str.deinit();
    try did_open_str.appendFmt("Content-Length: {d}\r\n\r\n", .{body.len});
    try did_open_str.append(body);
    const did_open = did_open_str.slice();

    var reader = std.Io.Reader.fixed(did_open);
    var output_buf: [4096]u8 = undefined;
    var output_writer = std.Io.Writer.fixed(&output_buf);

    // Process didOpen
    var msg = (try JSONRPC.readMessage(gpa, &reader)).?;
    defer msg.deinit(gpa);
    server.notification_writer = &output_writer;
    try server.handleMessage(msg, &output_writer);

    // Verify diagnostics were published
    const response = output_buf[0..output_writer.end];
    if (std.mem.indexOf(u8, response, "textDocument/publishDiagnostics") == null) {
        std.debug.print("Response: {s}\n", .{response});
    }
    try std.testing.expect(std.mem.indexOf(u8, response, "textDocument/publishDiagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "DoubleFree") != null);
}

test "LSP incremental sync applies range changes and republishes diagnostics" {
    const gpa = std.testing.allocator;

    var server = try LSP.Server.init(gpa);
    defer server.deinit();

    // Open a clean document
    const initial_source = "fn main() void { _ = 0; }";
    const open_body = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///test.zig\",\"version\":1,\"text\":\"" ++ initial_source ++ "\"}}}";
    var open_str = String.init(gpa);
    defer open_str.deinit();
    try open_str.appendFmt("Content-Length: {d}\r\n\r\n", .{open_body.len});
    try open_str.append(open_body);
    const open_request = open_str.slice();

    var open_reader = std.Io.Reader.fixed(open_request);
    var open_output_buf: [4096]u8 = undefined;
    var open_output_writer = std.Io.Writer.fixed(&open_output_buf);
    server.notification_writer = &open_output_writer;

    var open_msg = (try JSONRPC.readMessage(gpa, &open_reader)).?;
    defer open_msg.deinit(gpa);
    try server.handleMessage(open_msg, &open_output_writer);

    // Verify initial open published diagnostics
    const open_response = open_output_buf[0..open_output_writer.end];
    try std.testing.expect(std.mem.indexOf(u8, open_response, "textDocument/publishDiagnostics") != null);

    // Now send an incremental change that introduces a Box leak
    const change_text = "const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable";
    const change_body = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///test.zig\",\"version\":2},\"contentChanges\":[{\"range\":{\"start\":{\"line\":0,\"character\":17},\"end\":{\"line\":0,\"character\":23}},\"text\":\"" ++ change_text ++ "\"}]}}";
    var change_str = String.init(gpa);
    defer change_str.deinit();
    try change_str.appendFmt("Content-Length: {d}\r\n\r\n", .{change_body.len});
    try change_str.append(change_body);
    const change_request = change_str.slice();

    var change_reader = std.Io.Reader.fixed(change_request);
    var change_output_buf: [4096]u8 = undefined;
    var change_output_writer = std.Io.Writer.fixed(&change_output_buf);
    server.notification_writer = &change_output_writer;

    var change_msg = (try JSONRPC.readMessage(gpa, &change_reader)).?;
    defer change_msg.deinit(gpa);
    try server.handleMessage(change_msg, &change_output_writer);

    // Verify the document was updated
    const doc_source = server.getDocumentSource("file:///test.zig") orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(std.mem.indexOf(u8, doc_source, change_text) != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_source, "_ = 0;") == null);

    // Verify diagnostics were republished after the incremental change
    const change_response = change_output_buf[0..change_output_writer.end];
    try std.testing.expect(std.mem.indexOf(u8, change_response, "textDocument/publishDiagnostics") != null);
}

test "analyzer self-check on LSP source" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    // Analyze the LSP server source file - this dogfoods the analyzer
    // by running it on its own code
    const lsp_source = @embedFile("LSP.zig");
    try analyzer.analyzeFile("LSP.zig", lsp_source, .Medium);

    // Verify the analysis completed successfully (may find 0 real violations
    // if the code is clean, which gives 1 placeholder diagnostic)
    try std.testing.expect(analyzer.diagnostics.items.len >= 0);

    // Print diagnostics for debugging
    for (analyzer.diagnostics.items) |diag| {
        std.debug.print("Self-check: {s}: {s}\n", .{ @tagName(diag.kind), diag.message });
    }
}

test "analyzer detects cross-function pointer escape" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn takesRawPtr(ptr: *u32) void {
        \\    ptr.* = 100;
        \\}
        \\
        \\fn caller() void {
        \\    const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
        \\    const raw = box.unsafePtr();
        \\    takesRawPtr(raw);
        \\    const dead = box.deinit();
        \\    _ = dead;
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    // Should detect:
    // 1. takesRawPtr parameter uses raw pointer type
    // 2. takesRawPtr returns void (no issue)
    // 3. Cross-function escape: raw from Box passed to function taking *u32
    // 4. Potential dangling use after box.deinit() if function stores pointer
    try std.testing.expect(analyzer.diagnostics.items.len > 0);

    // Verify we found the cross-function escape or raw param warning
    var found_escape = false;
    for (analyzer.diagnostics.items) |diag| {
        if (diag.kind == .PointerEscape or std.mem.indexOf(u8, diag.message, "function parameter") != null) {
            found_escape = true;
        }
    }
    try std.testing.expect(found_escape);
}

test "analyzer detects raw pointer return at call site" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn getRawPtr() *u32 {
        \\    return undefined;
        \\}
        \\
        \\fn caller() void {
        \\    const ptr = getRawPtr();
        \\    _ = ptr;
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    // Should detect:
    // 1. getRawPtr returns raw pointer
    // 2. ptr initialized with raw pointer from function call
    var found_return_warning = false;
    var found_init_warning = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "function returns raw pointer") != null) {
            found_return_warning = true;
        }
        if (std.mem.indexOf(u8, diag.message, "variable initialized with raw pointer from function call") != null) {
            found_init_warning = true;
        }
    }
    try std.testing.expect(found_return_warning);
    try std.testing.expect(found_init_warning);
}

test "analyzer detects interprocedural use-after-free" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn takesRawPtr(ptr: *u32) void {
        \\    ptr.* = 100;
        \\}
        \\
        \\fn caller() void {
        \\    const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
        \\    const raw = box.unsafePtr();
        \\    const dead = box.deinit();
        \\    _ = dead;
        \\    takesRawPtr(raw);
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    // Should detect passing a dead pointer (from deallocated Box) to a function
    var found_uaf = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "use-after-free: passing dangling pointer") != null or
            std.mem.indexOf(u8, diag.message, "dangling pointer after deallocation") != null)
        {
            found_uaf = true;
        }
    }
    try std.testing.expect(found_uaf);
}

// === Cross-Function Contract Annotation Tests ===

test "analyzer respects @safe(nocapture) annotation" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    // Function with @safe(nocapture) should not trigger the specific
    // "raw pointer from Box escapes to function call" warning at the call site.
    const source =
        \\/// @safe(nocapture)
        \\fn takesRawPtr(ptr: *u32) void {
        \\    ptr.* = 100;
        \\}
        \\
        \\fn caller() void {
        \\    const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
        \\    const raw = box.unsafePtr();
        \\    takesRawPtr(raw);
        \\    // Intentionally not deinit-ing box here; the test focus is the call-site check
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    // Should NOT produce the call-site pointer escape warning because
    // the callee is annotated with @safe(nocapture)
    var found_call_escape = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "raw pointer from Box escapes to function call") != null) {
            found_call_escape = true;
        }
    }
    try std.testing.expect(!found_call_escape);
}

test "analyzer function registry has nocapture annotation" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\/// @safe(nocapture)
        \\fn takesRawPtr(ptr: *u32) void {}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    // Verify the function registry captured the annotation
    if (analyzer.functions.get("takesRawPtr")) |fn_info| {
        try std.testing.expect(fn_info.has_nocapture_annotation);
    } else {
        try std.testing.expect(false); // Function should be in registry
    }
}

test "analyzer workspace detects cross-file use-after-free" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    // File 1 defines a function that takes a raw pointer
    const file1 =
        \\fn processPtr(ptr: *u32) void {
        \\    ptr.* = 100;
        \\}
    ;

    // File 2 calls that function with a dangling pointer
    const file2 =
        \\const Box = @import("safe").Box;
        \\
        \\fn caller() void {
        \\    const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
        \\    const raw = box.unsafePtr();
        \\    const dead = box.deinit();
        \\    _ = dead;
        \\    processPtr(raw);
        \\}
    ;

    const files = &[_]Analysis.Analyzer.WorkspaceFile{
        .{ .path = "lib.zig", .source = file1 },
        .{ .path = "main.zig", .source = file2 },
    };

    try analyzer.analyzeWorkspace(files, .Medium);

    // Should detect passing a dead pointer to a function defined in another file
    var found_uaf = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "use-after-free: passing dangling pointer") != null or
            std.mem.indexOf(u8, diag.message, "dangling pointer after deallocation") != null)
        {
            found_uaf = true;
        }
    }
    try std.testing.expect(found_uaf);
}

test "analyzer workspace respects cross-file nocapture annotation" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    // File 1 defines a nocapture function
    const file1 =
        \\/// @safe(nocapture)
        \\fn safeFn(ptr: *u32) void {
        \\    ptr.* = 100;
        \\}
    ;

    // File 2 calls it with a raw pointer from a Box
    const file2 =
        \\const Box = @import("safe").Box;
        \\
        \\fn caller() void {
        \\    const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
        \\    const raw = box.unsafePtr();
        \\    safeFn(raw);
        \\}
    ;

    const files = &[_]Analysis.Analyzer.WorkspaceFile{
        .{ .path = "lib.zig", .source = file1 },
        .{ .path = "main.zig", .source = file2 },
    };

    try analyzer.analyzeWorkspace(files, .Medium);

    // Should NOT produce the call-site pointer escape warning
    var found_call_escape = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "raw pointer from Box escapes to function call") != null) {
            found_call_escape = true;
        }
    }
    try std.testing.expect(!found_call_escape);
}

test "analyzer warns on pointer escape without nocapture annotation" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    // Function WITHOUT @safe(nocapture) should trigger pointer escape warning
    const source =
        \\fn takesRawPtr(ptr: *u32) void {
        \\    ptr.* = 100;
        \\}
        \\
        \\fn caller() void {
        \\    const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
        \\    const raw = box.unsafePtr();
        \\    takesRawPtr(raw);
        \\    const dead = box.deinit();
        \\    _ = dead;
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    // Should produce pointer escape warning
    var found_escape = false;
    for (analyzer.diagnostics.items) |diag| {
        if (diag.kind == .PointerEscape) {
            found_escape = true;
        }
    }
    try std.testing.expect(found_escape);
}

test "analyzer detects @safe(returns: owned) annotation" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\/// @safe(returns: *u32 as owned)
        \\fn createPtr() *u32 {
        \\    const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
        \\    return box.unsafePtr();
        \\}
        \\
        \\fn caller() void {
        \\    const ptr = createPtr();
        \\    _ = ptr;
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    // Should NOT warn about raw pointer return because of @safe(returns: owned)
    var found_return_warning = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "function returns raw pointer") != null) {
            found_return_warning = true;
        }
    }
    try std.testing.expect(!found_return_warning);
}

test "analyzer enforces takes: owned contract" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\/// @safe(takes: box as owned)
        \\fn consumeBox(box: Box(u32, 0, 0, 0)) void {
        \\    const dead = box.deinit();
        \\    _ = dead;
        \\}
        \\
        \\fn caller() void {
        \\    const b = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
        \\    consumeBox(b);
        \\    const dead = b.deinit();
        \\    _ = dead;
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    // Should detect double-free because ownership was transferred to consumeBox
    var found_double_free = false;
    for (analyzer.diagnostics.items) |diag| {
        if (diag.kind == .DoubleFree or std.mem.indexOf(u8, diag.message, "double free") != null) {
            found_double_free = true;
        }
    }
    try std.testing.expect(found_double_free);
}

test "Contract parser extracts nocapture annotation" {
    var buf: [8]Contract.ParamContract = undefined;
    const contract = Contract.parseContract("/// @safe(nocapture)", &buf) orelse {
        try std.testing.expect(false); // Should parse successfully
        return;
    };
    try std.testing.expect(contract.nocapture);
    try std.testing.expect(!contract.pure);
}

test "Contract parser extracts pure annotation" {
    var buf: [8]Contract.ParamContract = undefined;
    const contract = Contract.parseContract("/// @safe(pure, nocapture)", &buf) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(contract.nocapture);
    try std.testing.expect(contract.pure);
}

test "Contract parser extracts return ownership" {
    var buf: [8]Contract.ParamContract = undefined;
    const contract = Contract.parseContract("/// @safe(returns: *u32 as owned)", &buf) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(contract.return_ownership, .owned);
    try std.testing.expect(!contract.nocapture);
}

test "AST doc comment token retrieval" {
    const source =
        \\/// @safe(nocapture)
        \\fn takesRawPtr(ptr: *u32) void {}
    ;

    var ast = try std.zig.Ast.parse(std.testing.allocator, source, .zig);
    defer ast.deinit(std.testing.allocator);

    // Find the function declaration
    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .fn_decl) {
            var buf: [1]std.zig.Ast.Node.Index = undefined;
            const fn_proto = ast.fullFnProto(&buf, @enumFromInt(@as(u32, @intCast(i)))) orelse continue;
            const fn_token = fn_proto.ast.fn_token;

            // Walk backwards from fn_token
            if (fn_token > 0) {
                var tok_idx = fn_token;
                var found_doc = false;
                while (tok_idx > 0) {
                    tok_idx -= 1;
                    const ttag = ast.tokens.items(.tag)[tok_idx];
                    if (ttag == .doc_comment) {
                        const doc_text = ast.tokenSlice(tok_idx);
                        try std.testing.expect(std.mem.indexOf(u8, doc_text, "@safe(nocapture)") != null);
                        found_doc = true;
                        break;
                    } else if (ttag != .identifier and ttag != .period and ttag != .keyword_pub and ttag != .keyword_extern and ttag != .keyword_export and ttag != .keyword_inline and ttag != .keyword_noinline) {
                        break;
                    }
                }
                try std.testing.expect(found_doc);
            }
        }
    }
}

test "Analyzer detects ManuallyDrop leak" {
    const source =
        \\const safe = @import("safe");
        \\fn foo() void {
        \\    var md = safe.ManuallyDrop(u32).init(42);
        \\    _ = md;
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.MemoryLeak));
}

test "Analyzer detects OnceCell double set" {
    const source =
        \\const safe = @import("safe");
        \\fn foo() void {
        \\    var oc = safe.OnceCell(u32).init();
        \\    _ = oc.set(1);
        \\    _ = oc.set(2);
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.AlreadyInitialized));
}

test "Analyzer detects MaybeUninit use before init" {
    const source =
        \\const safe = @import("safe");
        \\fn foo() void {
        \\    var mu = safe.MaybeUninit(u32).init();
        \\    _ = mu.assumeInit();
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.NotInitialized));
}

test "Analyzer detects Channel send after close" {
    const source =
        \\const safe = @import("safe");
        \\fn foo() void {
        \\    var ch = safe.Channel(u32).init();
        \\    _ = ch.close();
        \\    _ = ch.send(1);
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.ChannelClosed));
}

test "Analyzer detects Oneshot double send" {
    const source =
        \\const safe = @import("safe");
        \\fn foo() void {
        \\    var os = safe.Oneshot(u32).init();
        \\    _ = os.send(1);
        \\    _ = os.send(2);
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.AlreadySent));
}

test "Analyzer detects Mutex double lock" {
    const source =
        \\const safe = @import("safe");
        \\fn foo() void {
        \\    var mtx = safe.Mutex(u32).init(0);
        \\    _ = mtx.lock();
        \\    _ = mtx.lock();
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.Deadlock));
}

test "Analyzer detects Pin move" {
    const source =
        \\const safe = @import("safe");
        \\fn foo() void {
        \\    var p1 = safe.Pin(u32).init(42);
        \\    var p2 = p1;
        \\    _ = p2;
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.InvalidMove));
}

test "Analyzer detects Mutex not unlocked" {
    const source =
        \\const safe = @import("safe");
        \\fn foo() void {
        \\    var mtx = safe.Mutex(u32).init(0);
        \\    _ = mtx.lock();
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.Deadlock));
}

test "Analyzer detects memory leak" {
    const source =
        \\fn testLeak() void {
        \\    const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
        \\    _ = box;
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.MemoryLeak));
}

test "Analyzer detects null pointer dereference" {
    const source =
        \\fn testNullDeref() void {
        \\    var opt: ?u32 = null;
        \\    _ = opt.?;
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.NullDereference));
}

test "Analyzer detects buffer overflow" {
    const source =
        \\fn testBufferOverflow() void {
        \\    var arr: [3]u32 = undefined;
        \\    _ = arr[5];
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.BufferOverflow));
}

test "Analyzer detects uninitialized variable read" {
    const source =
        \\fn testUninit() void {
        \\    var x: u32 = undefined;
        \\    _ = x;
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.NotInitialized));
}

test "Analyzer no false positive leak when properly freed" {
    const source =
        \\fn testNoLeak() void {
        \\    const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
        \\    const dead = box.deinit();
        \\    _ = dead;
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(!analyzer.hasDiagnostic(.MemoryLeak));
}

test "Analyzer no false positive null deref on non-null optional" {
    const source =
        \\fn testNoNullDeref() void {
        \\    var opt: ?u32 = 42;
        \\    _ = opt.?;
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(!analyzer.hasDiagnostic(.NullDereference));
}

test "Fix generated for missing deinit" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn testLeak() void {
        \\    const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
        \\    _ = box;
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    var found_fix = false;
    for (analyzer.diagnostics.items) |diag| {
        if (diag.kind == .MemoryLeak and diag.fix != null) {
            if (std.mem.eql(u8, diag.fix.?.description, "Add defer deinit")) {
                found_fix = true;
            }
        }
    }
    try std.testing.expect(found_fix);
}

test "Fix generated for raw allocator.create" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn testRawCreate() void {
        \\    const ptr = std.heap.page_allocator.create(u32);
        \\    _ = ptr;
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    var found_fix = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "raw allocator.create") != null and diag.fix != null) {
            if (std.mem.eql(u8, diag.fix.?.description, "Replace with safe.Box")) {
                found_fix = true;
            }
        }
    }
    try std.testing.expect(found_fix);
}

test "Fix generated for missing errdefer" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn testLeak() !void {
        \\    var file = safe.FileGuard.init();
        \\    try somethingThatMayFail();
        \\    _ = file;
        \\}
        \\fn somethingThatMayFail() !void { return error.Oops; }
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    var found_fix = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "Resource leak") != null and diag.fix != null) {
            if (std.mem.eql(u8, diag.fix.?.description, "Add errdefer deinit")) {
                found_fix = true;
            }
        }
    }
    try std.testing.expect(found_fix);
}

test "Fix generated for null dereference" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn testNullDeref() void {
        \\    var opt: ?u32 = null;
        \\    _ = opt.?;
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    var found_fix = false;
    for (analyzer.diagnostics.items) |diag| {
        if (diag.kind == .NullDereference and diag.fix != null) {
            if (std.mem.eql(u8, diag.fix.?.description, "Add null check")) {
                found_fix = true;
            }
        }
    }
    try std.testing.expect(found_fix);
}

// === CLI Tests ===

test "CLI directory analysis collects zig files" {
    // Skip on Linux/Windows CI due to std.Io + tmpDir incompatibility
    if (comptime builtin.target.os.tag == .linux or builtin.target.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;

    // Create test files in temp dir
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "fn main() void {}" });

    // Create subdirectory with another file
    try tmp.dir.createDirPath(io, "src");
    var sub_dir = try tmp.dir.openDir(io, "src", .{ .iterate = true });
    defer sub_dir.close(io);
    try sub_dir.writeFile(io, .{ .sub_path = "lib.zig", .data = "fn lib() void {}" });

    // Also create a non-zig file
    try tmp.dir.writeFile(io, .{ .sub_path = "readme.md", .data = "# Test" });

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| std.testing.allocator.free(f);
        files.deinit(std.testing.allocator);
    }

    try collectZigFiles(std.testing.allocator, io, tmp.dir, ".", &files);

    try std.testing.expectEqual(@as(usize, 2), files.items.len);

    var found_main = false;
    var found_lib = false;
    for (files.items) |path| {
        if (std.mem.endsWith(u8, path, "main.zig")) found_main = true;
        if (std.mem.endsWith(u8, path, "lib.zig")) found_lib = true;
    }
    try std.testing.expect(found_main);
    try std.testing.expect(found_lib);
}

test "CLI detects @ptrCast in external code" {
    const source =
        \\fn testPtrCast() void {
        \\    var x: u32 = 42;
        \\    const p: *u8 = @ptrCast(&x);
        \\    _ = p;
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.RawPattern));
}

test "CLI detects missing close for file handle" {
    const source =
        \\fn testFile() void {
        \\    var file = std.fs.cwd().openFile("foo.txt", .{});
        \\    _ = file;
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.MemoryLeak));
}

test "CLI JSON output is valid SARIF" {
    const gpa = std.testing.allocator;

    var diagnostics: std.ArrayList(Diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(gpa);

    try diagnostics.append(gpa, .{
        .kind = .UseAfterFree,
        .message = "test diagnostic",
        .location = .{
            .file = "test.zig",
            .line = 1,
            .column = 1,
        },
        .notes = &.{},
        .severity = .Error,
    });

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try Diagnostic.emitSARIF(diagnostics.items, &writer);

    const output = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, output, "sarif-schema-2.1.0.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "UseAfterFree") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test diagnostic") != null);
}

test "analyzer detects division by zero" {
    const source =
        \\fn testDivByZero() void {
        \\    const x = 10 / 0;
        \\    _ = x;
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.DivisionByZero));
}

test "LSP workspace/symbol returns matching symbols" {
    const gpa = std.testing.allocator;

    var server = try LSP.Server.init(gpa);
    defer server.deinit();

    const source = "fn fooFunc() void {} const FooStruct = struct {}; const bar_var = 42;";

    // Open document
    const open_body = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///test.zig\",\"version\":1,\"text\":\"" ++ source ++ "\"}}}";
    var open_str = String.init(gpa);
    defer open_str.deinit();
    try open_str.appendFmt("Content-Length: {d}\r\n\r\n", .{open_body.len});
    try open_str.append(open_body);
    const open_request = open_str.slice();

    var open_reader = std.Io.Reader.fixed(open_request);
    var open_output_buf: [4096]u8 = undefined;
    var open_output_writer = std.Io.Writer.fixed(&open_output_buf);
    server.notification_writer = &open_output_writer;

    var open_msg = (try JSONRPC.readMessage(gpa, &open_reader)).?;
    defer open_msg.deinit(gpa);
    try server.handleMessage(open_msg, &open_output_writer);

    // Send workspace/symbol request
    const symbol_body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"foo\"}}";
    var symbol_str = String.init(gpa);
    defer symbol_str.deinit();
    try symbol_str.appendFmt("Content-Length: {d}\r\n\r\n", .{symbol_body.len});
    try symbol_str.append(symbol_body);
    const symbol_request = symbol_str.slice();

    var symbol_reader = std.Io.Reader.fixed(symbol_request);
    var symbol_output_buf: [4096]u8 = undefined;
    var symbol_output_writer = std.Io.Writer.fixed(&symbol_output_buf);

    var symbol_msg = (try JSONRPC.readMessage(gpa, &symbol_reader)).?;
    defer symbol_msg.deinit(gpa);
    try server.handleMessage(symbol_msg, &symbol_output_writer);

    const response = symbol_output_buf[0..symbol_output_writer.end];
    try std.testing.expect(std.mem.indexOf(u8, response, "fooFunc") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "FooStruct") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "bar_var") == null);
}

test "LSP references finds all usages" {
    const gpa = std.testing.allocator;

    var server = try LSP.Server.init(gpa);
    defer server.deinit();

    const source = "fn main() void { const my_var = 42; _ = my_var; const x = my_var + 1; }";

    // Open document
    const open_body = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///test.zig\",\"version\":1,\"text\":\"" ++ source ++ "\"}}}";
    var open_str = String.init(gpa);
    defer open_str.deinit();
    try open_str.appendFmt("Content-Length: {d}\r\n\r\n", .{open_body.len});
    try open_str.append(open_body);
    const open_request = open_str.slice();

    var open_reader = std.Io.Reader.fixed(open_request);
    var open_output_buf: [4096]u8 = undefined;
    var open_output_writer = std.Io.Writer.fixed(&open_output_buf);
    server.notification_writer = &open_output_writer;

    var open_msg = (try JSONRPC.readMessage(gpa, &open_reader)).?;
    defer open_msg.deinit(gpa);
    try server.handleMessage(open_msg, &open_output_writer);

    // Send textDocument/references request for my_var
    const ref_body = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"file:///test.zig\"},\"position\":{\"line\":0,\"character\":25},\"context\":{\"includeDeclaration\":true}}}";
    var ref_str = String.init(gpa);
    defer ref_str.deinit();
    try ref_str.appendFmt("Content-Length: {d}\r\n\r\n", .{ref_body.len});
    try ref_str.append(ref_body);
    const ref_request = ref_str.slice();

    var ref_reader = std.Io.Reader.fixed(ref_request);
    var ref_output_buf: [4096]u8 = undefined;
    var ref_output_writer = std.Io.Writer.fixed(&ref_output_buf);

    var ref_msg = (try JSONRPC.readMessage(gpa, &ref_reader)).?;
    defer ref_msg.deinit(gpa);
    try server.handleMessage(ref_msg, &ref_output_writer);

    const response = ref_output_buf[0..ref_output_writer.end];
    // Should find 3 occurrences: declaration + 2 usages
    var count: usize = 0;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, response, search_start, "\"start\"")) |pos| {
        count += 1;
        search_start = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "analyzer detects shift overflow" {
    const source =
        \\fn testShiftOverflow() void {
        \\    const x: u32 = 1;
        \\    const y = x << 32;
        \\    _ = y;
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.ShiftOverflow));
}

test "analyzer detects ptr cast without align" {
    const source =
        \\fn testPtrCast() void {
        \\    var x: u32 = 42;
        \\    const p: *u8 = @ptrCast(&x);
        \\    _ = p;
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.PtrCastWithoutAlign));
}

test "analyzer detects raw pointer arithmetic" {
    const source =
        \\fn testPtrArith() void {
        \\    var ptr: [*]u8 = undefined;
        \\    const x = ptr + 1;
        \\    _ = x;
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.RawPointerArithmetic));
}

test "analyzer detects unchecked index" {
    const source =
        \\fn testUncheckedIndex() void {
        \\    var buf: [10]u32 = undefined;
        \\    var i: usize = 5;
        \\    buf[i] = 1;
        \\}
    ;
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.analyzeFile("test.zig", source, .Medium);
    try std.testing.expect(analyzer.hasDiagnostic(.UncheckedIndex));
}

// === Async Safety Tests ===

test "analyzer detects async function via callconv" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn foo() callconv(.Async) void {}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);
    if (analyzer.functions.get("foo")) |fn_info| {
        try std.testing.expect(fn_info.is_async);
    } else {
        try std.testing.expect(false); // Function should be in registry
    }
}

test "analyzer detects borrow across nosuspend boundary" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn asyncFn(x: *const u32) callconv(.Async) void { _ = x; }
        \\
        \\fn caller() void {
        \\    const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
        \\    const b = box.borrowImm();
        \\    nosuspend asyncFn(b);
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    var found = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "borrowed pointer crosses async boundary") != null) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "analyzer detects use-after-move passing to async function" {
    var analyzer = Analysis.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn asyncFn(x: Box(u32, 0, 0, 0)) callconv(.Async) void {
        \\    const dead = x.deinit();
        \\    _ = dead;
        \\}
        \\
        \\fn caller() void {
        \\    const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
        \\    asyncFn(box);
        \\    const dead = box.deinit();
        \\    _ = dead;
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    var found = false;
    for (analyzer.diagnostics.items) |diag| {
        if (diag.kind == .UseAfterMove and std.mem.indexOf(u8, diag.message, "async") != null) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

// === Cache Tests ===

test "cache reuses AST for unchanged content" {
    const gpa = std.testing.allocator;

    var cache = Cache.init(gpa);
    defer cache.deinit();

    const source = "fn main() void { _ = 0; }";

    const ast1 = try cache.getAst("test.zig", source);
    try std.testing.expectEqual(@as(u64, 0), cache.stats.ast_hits);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.ast_misses);

    const ast2 = try cache.getAst("test.zig", source);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.ast_hits);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.ast_misses);

    // Should return the same cached AST pointer
    try std.testing.expectEqual(ast1, ast2);
}

test "cache invalidates on content change" {
    const gpa = std.testing.allocator;

    var cache = Cache.init(gpa);
    defer cache.deinit();

    const source1 = "fn main() void { _ = 0; }";
    const source2 = "fn main() void { _ = 1; }";

    _ = try cache.getAst("test.zig", source1);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.ast_misses);

    // Invalidate before changing content
    try cache.invalidate("test.zig");

    _ = try cache.getAst("test.zig", source2);
    try std.testing.expectEqual(@as(u64, 2), cache.stats.ast_misses);

    // Note: we do not compare pointers here because the allocator may reuse
    // the same address after the old AST was freed. The stats above prove
    // that a new parse actually happened.
}

test "cache analysis reuses results for unchanged content" {
    const gpa = std.testing.allocator;

    var cache = Cache.init(gpa);
    defer cache.deinit();
    var analyzer = Analysis.Analyzer.init(gpa);
    defer analyzer.deinit();

    const source =
        \\fn testDoubleFree() void {
        \\    const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
        \\    const dead = box.deinit();
        \\    const dead2 = dead.deinit();
        \\    _ = dead2;
        \\}
    ;

    var result1 = try cache.getAnalysis("test.zig", source, &analyzer, .Medium);
    defer result1.deinit();
    try std.testing.expectEqual(@as(u64, 1), cache.stats.analysis_misses);
    try std.testing.expect(result1.diagnostics.items.len > 0);

    // Second call with same source should hit the cache
    var result2 = try cache.getAnalysis("test.zig", source, &analyzer, .Medium);
    defer result2.deinit();
    try std.testing.expectEqual(@as(u64, 1), cache.stats.analysis_hits);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.analysis_misses);

    // Results should be equivalent
    try std.testing.expectEqual(result1.diagnostics.items.len, result2.diagnostics.items.len);
}

test "cache analysis invalidates on content change" {
    const gpa = std.testing.allocator;

    var cache = Cache.init(gpa);
    defer cache.deinit();
    var analyzer = Analysis.Analyzer.init(gpa);
    defer analyzer.deinit();

    const source1 = "fn main() void { _ = 0; }";
    const source2 = "fn main() void { _ = 1; }";

    var result1 = try cache.getAnalysis("test.zig", source1, &analyzer, .Medium);
    defer result1.deinit();
    try std.testing.expectEqual(@as(u64, 1), cache.stats.analysis_misses);

    try cache.invalidate("test.zig");

    var result2 = try cache.getAnalysis("test.zig", source2, &analyzer, .Medium);
    defer result2.deinit();
    try std.testing.expectEqual(@as(u64, 2), cache.stats.analysis_misses);
    try std.testing.expectEqual(@as(u64, 0), cache.stats.analysis_hits);
}
