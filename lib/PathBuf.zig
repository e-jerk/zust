const std = @import("std");
const String = @import("String.zig").String;

/// A safe filesystem path buffer.
/// Prevents path traversal attacks and provides safe path manipulation.
pub const PathBuf = struct {
    path: String,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .path = String.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.path.deinit();
    }

    /// Create from a string slice.
    pub fn fromSlice(allocator: std.mem.Allocator, slice: []const u8) !Self {
        var self = init(allocator);
        try self.path.append(slice);
        return self;
    }

    /// Append a path component (adds separator if needed).
    pub fn push(self: *Self, component: []const u8) !void {
        const current = self.path.slice();
        if (current.len > 0 and !std.mem.endsWith(u8, current, "/") and !std.mem.endsWith(u8, current, "\\")) {
            try self.path.append("/");
        }
        // Prevent path traversal
        if (std.mem.eql(u8, component, "..") or std.mem.eql(u8, component, ".")) {
            return error.InvalidPathComponent;
        }
        try self.path.append(component);
    }

    pub fn asSlice(self: *Self) []const u8 {
        return self.path.slice();
    }

    pub fn eql(self: *Self, other: *Self) bool {
        return std.mem.eql(u8, self.asSlice(), other.asSlice());
    }
};

// ─── Tests ───

test "PathBuf basic" {
    const allocator = std.testing.allocator;
    var path = try PathBuf.fromSlice(allocator, "/home");
    defer path.deinit();

    try path.push("user");
    try path.push("docs");
    try std.testing.expectEqualStrings("/home/user/docs", path.asSlice());
}

test "PathBuf rejects traversal" {
    const allocator = std.testing.allocator;
    var path = try PathBuf.fromSlice(allocator, "/home");
    defer path.deinit();

    try std.testing.expectError(error.InvalidPathComponent, path.push(".."));
}
