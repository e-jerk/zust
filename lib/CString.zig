const std = @import("std");

/// A safe C-style string (null-terminated) with length tracking.
/// Prevents buffer overflows in C interop.
pub const CString = struct {
    buf: []u8,
    len: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        const buf = allocator.alloc(u8, 1) catch &[_]u8{0};
        buf[0] = 0;
        return .{ .buf = buf, .len = 0, .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buf);
    }

    pub fn fromSlice(allocator: std.mem.Allocator, slice: []const u8) !Self {
        const buf = try allocator.alloc(u8, slice.len + 1);
        @memcpy(buf[0..slice.len], slice);
        buf[slice.len] = 0;
        return .{ .buf = buf, .len = slice.len, .allocator = allocator };
    }

    pub fn asPtr(self: *Self) [*c]const u8 {
        return self.buf.ptr;
    }

    pub fn asSlice(self: *Self) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn append(self: *Self, ch: u8) !void {
        const new_buf = try self.allocator.realloc(self.buf, self.len + 2);
        new_buf[self.len] = ch;
        new_buf[self.len + 1] = 0;
        self.buf = new_buf;
        self.len += 1;
    }

    pub fn clone(self: *Self) !Self {
        return try fromSlice(self.allocator, self.asSlice());
    }
};

// ─── Tests ───

test "CString fromSlice and asPtr" {
    const allocator = std.testing.allocator;
    var cs = try CString.fromSlice(allocator, "hello");
    defer cs.deinit();

    try std.testing.expectEqualStrings("hello", cs.asSlice());
    try std.testing.expect(cs.asPtr()[5] == 0);
}

test "CString append" {
    const allocator = std.testing.allocator;
    var cs = try CString.fromSlice(allocator, "hel");
    defer cs.deinit();

    try cs.append('l');
    try cs.append('o');
    try std.testing.expectEqualStrings("hello", cs.asSlice());
    try std.testing.expect(cs.asPtr()[5] == 0);
}
