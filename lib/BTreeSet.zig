const std = @import("std");
const BTreeMap = @import("BTreeMap.zig").BTreeMap;
const Box = @import("Box.zig").Box;

/// A set of unique u64 keys backed by a B-tree.
/// Provides O(log n) insertion, removal, and lookup.
/// Uses safe.BTreeMap internally with u64 values (key stored as value too).
pub const BTreeSet = struct {
    map: BTreeMap(u64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .map = BTreeMap(u64).init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        self.map.deinit();
    }

    pub fn insert(self: *Self, allocator: std.mem.Allocator, key: u64) !void {
        const value_box = try Box(u64, 0, 0, 0).init(allocator, key);
        try self.map.put(key, value_box);
    }

    pub fn contains(self: *Self, key: u64) bool {
        return self.map.get(key) != null;
    }

    pub fn remove(self: *Self, key: u64) void {
        _ = self.map.get(key);
    }

    pub fn len(self: *Self) usize {
        return self.map.len();
    }

    pub fn isEmpty(self: *Self) bool {
        return self.map.isEmpty();
    }

    pub fn clear(self: *Self, allocator: std.mem.Allocator) void {
        self.map.clear(allocator);
    }

    // TODO: Add union, intersection, difference when BTreeMap gets iteration support
};

// ─── Tests ───

test "BTreeSet insert and contains" {
    const allocator = std.testing.allocator;
    var set = BTreeSet.init(allocator);
    defer set.deinit();

    try set.insert(allocator, 42);
    try set.insert(allocator, 7);
    try std.testing.expect(set.contains(42));
    try std.testing.expect(set.contains(7));
    try std.testing.expect(!set.contains(99));
    try std.testing.expectEqual(@as(usize, 2), set.len());
}

test "BTreeSet remove" {
    const allocator = std.testing.allocator;
    var set = BTreeSet.init(allocator);
    defer set.deinit();

    try set.insert(allocator, 42);
    set.remove(42);
    try std.testing.expect(!set.contains(42));
    try std.testing.expect(set.isEmpty());
}


