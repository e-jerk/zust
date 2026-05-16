const std = @import("std");

/// Documentation generator for zust.
/// Scans lib/ directory and generates static HTML documentation.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create output directory
    try std.fs.cwd().makePath("docs/out");

    // Generate index.html
    const index = try generateIndex(allocator);
    defer allocator.free(index);
    try std.fs.cwd().writeFile(.{ .sub_path = "docs/out/index.html", .data = index });

    // Generate page for each type
    var lib_dir = try std.fs.cwd().openDir("lib", .{ .iterate = true });
    defer lib_dir.close();

    var iter = lib_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig") and !std.mem.eql(u8, entry.name, "safe.zig")) {
            const content = try generateTypePage(allocator, entry.name);
            defer allocator.free(content);
            const out_name = try std.fmt.allocPrint(allocator, "docs/out/{s}.html", .{entry.name});
            defer allocator.free(out_name);
            try std.fs.cwd().writeFile(.{ .sub_path = out_name, .data = content });
        }
    }

    std.debug.print("Documentation generated in docs/out/\n", .{});
}

fn generateIndex(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <title>zust Documentation</title>
        \\    <style>
        \\        body {{ font-family: -apple-system, sans-serif; max-width: 900px; margin: 40px auto; padding: 20px; }}
        \\        h1 {{ color: #333; }}
        \\        .stats {{ background: #f5f5f5; padding: 15px; border-radius: 8px; margin: 20px 0; }}
        \\        ul {{ list-style: none; padding: 0; }}
        \\        li {{ margin: 8px 0; }}
        \\        a {{ color: #0066cc; text-decoration: none; }}
        \\        a:hover {{ text-decoration: underline; }}
        \\    </style>
        \\</head>
        \\<body>
        \\    <h1>zust — Memory-Safe Zig</h1>
        \\    <p>Zero-cost memory safety for Zig, inspired by Rust.</p>
        \\    <div class="stats">
        \\        <strong>Stats:</strong> 51 types | 25 analyzer detections | 442 tests | SIMD-accelerated
        \\    </div>
        \\    <h2>Library Types</h2>
        \\    <ul>
        \\        <li><a href="Box.zig.html">Box</a> — Heap allocation with compile-time ownership</li>
        \\        <li><a href="Rc.zig.html">Rc</a> — Single-threaded reference counting</li>
        \\        <li><a href="Arc.zig.html">Arc</a> — Thread-safe reference counting</li>
        \\        <li><a href="Mutex.zig.html">Mutex</a> — Mutual exclusion with borrow checking</li>
        \\        <li><a href="String.zig.html">String</a> — Growable string with SSO</li>
        \\        <li><a href="ArrayList.zig.html">ArrayList</a> — Dynamic array with ownership</li>
        \\        <li><a href="HashMap.zig.html">HashMap</a> — Hash map with ownership tracking</li>
        \\        <li><a href="VecDeque.zig.html">VecDeque</a> — Double-ended queue</li>
        \\        <li><a href="Slice.zig.html">Slice</a> — Borrow-checked slice reference</li>
        \\        <li><a href="Cell.zig.html">Cell</a> — Interior mutability for Copy types</li>
        \\        <li><a href="RefCell.zig.html">RefCell</a> — Runtime borrow checking</li>
        \\        <li><a href="Channel.zig.html">Channel</a> — MPMC queue</li>
        \\        <li><a href="ThreadPool.zig.html">ThreadPool</a> — Work-stealing thread pool</li>
        \\        <li><a href="SmallString.zig.html">SmallString</a> — Small String Optimization</li>
        \\        <li><a href="RingBuffer.zig.html">RingBuffer</a> — Circular buffer</li>
        \\        <li><a href="BitSet.zig.html">BitSet</a> — SIMD-accelerated bit operations</li>
        \\        <li><a href="BloomFilter.zig.html">BloomFilter</a> — Probabilistic membership</li>
        \\        <li><a href="CheckedInt.zig.html">CheckedInt</a> — Overflow protection</li>
        \\        <li><a href="SimdUtils.zig.html">SimdUtils</a> — SIMD primitives</li>
        \\    </ul>
        \\    <h2>More Information</h2>
        \\    <ul>
        \\        <li><a href="https://github.com/e-jerk/zust">GitHub Repository</a></li>
        \\    </ul>
        \\</body>
        \\</html>
    , .{});
}

fn generateTypePage(allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
    const filepath = try std.fmt.allocPrint(allocator, "lib/{s}", .{filename});
    defer allocator.free(filepath);

    const source = try std.fs.cwd().readFileAlloc(allocator, filepath, 1024 * 1024);
    defer allocator.free(source);

    // Extract the first doc comment block as description
    var desc: []const u8 = "No description available.";
    if (std.mem.indexOf(u8, source, "///")) |idx| {
        const end = std.mem.indexOf(u8, source[idx..], "\npub ") orelse source.len - idx;
        desc = source[idx .. idx + end];
    }

    return std.fmt.allocPrint(allocator,
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <title>{s} — zust</title>
        \\    <style>
        \\        body {{ font-family: -apple-system, sans-serif; max-width: 900px; margin: 40px auto; padding: 20px; }}
        \\        h1 {{ color: #333; }}
        \\        pre {{ background: #f5f5f5; padding: 15px; overflow-x: auto; border-radius: 8px; }}
        \\        a {{ color: #0066cc; text-decoration: none; }}
        \\    </style>
        \\</head>
        \\<body>
        \\    <a href="index.html">← Back to index</a>
        \\    <h1>{s}</h1>
        \\    <pre>{s}</pre>
        \\    <h2>Source</h2>
        \\    <pre><code>{s}</code></pre>
        \\</body>
        \\</html>
    , .{ filename, filename, desc, source });
}
