const std = @import("std");

/// Documentation generator for zust.
/// Scans lib/*.zig, extracts public declarations and doc comments,
/// and writes a single docs/index.html file.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var html = std.ArrayList(u8).empty;
    defer html.deinit(allocator);

    // HTML header
    try html.appendSlice(
        allocator,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <title>zust Documentation</title>
        \\  <style>
        \\    body { font-family: -apple-system, sans-serif; max-width: 900px; margin: 40px auto; padding: 0 20px; background: #f5f5f5; }
        \\    h1 { color: #1a1a1a; border-bottom: 2px solid #e67e22; padding-bottom: 10px; }
        \\    h2 { color: #2c3e50; margin-top: 40px; border-bottom: 1px solid #ddd; padding-bottom: 6px; }
        \\    h3 { color: #34495e; margin-top: 24px; }
        \\    .module { background: white; border-radius: 8px; padding: 24px; margin: 20px 0; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        \\    .decl { margin: 12px 0; padding: 12px; background: #fafafa; border-left: 3px solid #e67e22; border-radius: 4px; }
        \\    .doc { color: #555; font-style: italic; margin: 6px 0; }
        \\    code { background: #eee; padding: 2px 6px; border-radius: 3px; font-family: monospace; }
        \\    .stats { background: #2c3e50; color: white; padding: 20px; border-radius: 8px; margin: 20px 0; }
        \\    a { color: #e67e22; text-decoration: none; }
        \\    a:hover { text-decoration: underline; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <h1>zust Documentation</h1>
        \\  <p>Zero-cost memory safety for Zig — Rust-inspired ownership, comptime typestate.</p>
        \\  <div class="stats">
        \\    <strong>Project Stats</strong><br>
        \\    Library types: 52 files | Analyzer detections: 30 bug classes | Tests: 462+ passing
        \\  </div>
        \\  <h2>Library Modules</h2>
        ,
    );

    // Scan lib/*.zig
    var dir = try std.Io.Dir.cwd().openDir(io, "lib", .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    var file_count: usize = 0;
    var decl_count: usize = 0;

    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "safe.zig")) continue; // root module, skip

        file_count += 1;
        const file_path = try std.fmt.allocPrint(allocator, "lib/{s}", .{entry.name});
        defer allocator.free(file_path);

        const source = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(1 << 20));
        defer allocator.free(source);
        const source_z = try allocator.dupeZ(u8, source);
        defer allocator.free(source_z);

        var ast = try std.zig.Ast.parse(allocator, source_z, .zig);
        defer ast.deinit(allocator);

        if (ast.errors.len > 0) continue;

        // Module header
        const module_name = entry.name[0 .. entry.name.len - 4]; // strip .zig
        const mod_html = try std.fmt.allocPrint(allocator, "  <div class=\"module\">\n    <h3>{s}</h3>\n", .{module_name});
        defer allocator.free(mod_html);
        try html.appendSlice(allocator, mod_html);

        // Extract public declarations
        const decls = ast.rootDecls();
        for (decls) |decl| {
            const tag = ast.nodes.items(.tag)[@intFromEnum(decl)];
            const main_token = ast.nodes.items(.main_token)[@intFromEnum(decl)];

            // Get doc comments
            var docs = std.ArrayList(u8).empty;
            defer docs.deinit(allocator);
            const doc_start = ast.nodes.items(.main_token)[@intFromEnum(decl)];
            for (0..5) |offset| {
                if (doc_start < offset) break;
                const tok_idx = doc_start - offset;
                const tok_tag = ast.tokens.items(.tag)[tok_idx];
                if (tok_tag == .doc_comment) {
                    const doc_text = ast.tokenSlice(@intCast(tok_idx));
                    const doc_line = try std.fmt.allocPrint(allocator, "{s}\n", .{doc_text});
                    defer allocator.free(doc_line);
                    try docs.appendSlice(allocator, doc_line);
                }
            }

            switch (tag) {
                .simple_var_decl, .local_var_decl, .global_var_decl, .aligned_var_decl => {
                    const decl_name = ast.tokenSlice(main_token + 1);
                    const is_pub = isPublic(ast, main_token);
                    if (is_pub) {
                        decl_count += 1;
                        const decl_html = try std.fmt.allocPrint(allocator, "    <div class=\"decl\">\n      <code>pub const {s}</code>\n", .{decl_name});
                        defer allocator.free(decl_html);
                        try html.appendSlice(allocator, decl_html);
                        if (docs.items.len > 0) {
                            const doc_html = try std.fmt.allocPrint(allocator, "      <div class=\"doc\">{s}</div>\n", .{docs.items});
                            defer allocator.free(doc_html);
                            try html.appendSlice(allocator, doc_html);
                        }
                        try html.appendSlice(allocator, "    </div>\n");
                    }
                },
                .fn_decl => {
                    var buf: [1]std.zig.Ast.Node.Index = undefined;
                    if (ast.fullFnProto(&buf, ast.nodes.items(.data)[@intFromEnum(decl)].node_and_node[0])) |proto| {
                        if (proto.name_token) |nt| {
                            const fn_name = ast.tokenSlice(nt);
                            const is_pub = isPublic(ast, ast.nodes.items(.main_token)[@intFromEnum(decl)]);
                            if (is_pub) {
                                decl_count += 1;
                                const decl_html = try std.fmt.allocPrint(allocator, "    <div class=\"decl\">\n      <code>pub fn {s}</code>\n", .{fn_name});
                                defer allocator.free(decl_html);
                                try html.appendSlice(allocator, decl_html);
                                if (docs.items.len > 0) {
                                    const doc_html = try std.fmt.allocPrint(allocator, "      <div class=\"doc\">{s}</div>\n", .{docs.items});
                                    defer allocator.free(doc_html);
                                    try html.appendSlice(allocator, doc_html);
                                }
                                try html.appendSlice(allocator, "    </div>\n");
                            }
                        }
                    }
                },
                else => {},
            }
        }

        try html.appendSlice(allocator, "  </div>\n");
    }

    // Footer
    const footer_html = try std.fmt.allocPrint(
        allocator,
        \\  <h2>Analyzer Detections</h2>
        \\  <div class="module">
        \\    <p>The zust analyzer detects <strong>30 bug classes</strong> including:</p>
        \\    <ul>
        \\      <li>Double-free, Use-after-free, Use-after-move</li>
        \\      <li>Mutable aliasing, Iterator invalidation, Data race</li>
        \\      <li>Buffer overflow, Null dereference, Uninitialized memory</li>
        \\      <li>Cross-function contract violation, Raw pattern detection</li>
        \\      <li>Division by zero, Shift overflow, PtrCast without align</li>
        \\    </ul>
        \\    <p>Run <code>zig build analyze</code> to analyze your project.</p>
        \\  </div>
        \\  <footer style="text-align:center; margin-top:40px; color:#999;">
        \\    Generated by zust docs generator | {d} modules | {d} public declarations
        \\  </footer>
        \\</body>
        \\</html>
    ,
        .{ file_count, decl_count },
    );
    defer allocator.free(footer_html);
    try html.appendSlice(allocator, footer_html);

    // Write output
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "docs/index.html",
        .data = html.items,
    });

    std.debug.print("Generated docs/index.html with {d} modules and {d} public declarations\n", .{ file_count, decl_count });
}

fn isPublic(ast: std.zig.Ast, main_token: u32) bool {
    // Check if there's a 'pub' keyword before the main token
    if (main_token == 0) return false;
    const prev_tag = ast.tokens.items(.tag)[main_token - 1];
    return prev_tag == .keyword_pub;
}
