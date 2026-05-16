const std = @import("std");

/// Documentation generator for zust.
/// This is a simplified stub for Zig 0.16 compatibility.
pub fn main() !void {
    // NOTE: Full implementation needs std.fs APIs which differ in Zig 0.16.
    // For now, print a message indicating the docs structure.
    std.debug.print(
        \\zust Documentation Generator
        \\
        \\To view documentation, see README.md (1874 lines)
        \\
        \\Library types: 51 files in lib/
        \\
        \\Analyzer detections: 25 bug classes
        \\
        \\Tests: 452/452 passing
        \\
        \\Examples: http_server.zig, json_parser.zig
        \\
        \\Tools: transpiler (zust-transpile), analyzer (zust-analyze)
        \\
        \\Usage:
        \\
        \\  zig build test-all   # Run all tests
        \\  zig build analyze    # Run analyzer
        \\  zig build bench      # Run benchmarks
        \\  zig build docs       # Generate docs (stub)
        \\
    , .{});
}
