const std = @import("std");

/// A hash set of u64 values.
/// Backed by std.AutoHashMap(u64, void).
/// Pattern: Similar to Rust's HashSet<T>.
pub const HashSet = struct {
    map: std.AutoHashMap(u64, void),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .map = std.AutoHashMap(u64, void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.map.deinit();
    }

    pub fn insert(self: *Self, key: u64) !void {
        try self.map.put(key, {});
    }

    pub fn remove(self: *Self, key: u64) bool {
        return self.map.remove(key);
    }

    pub fn contains(self: *const Self, key: u64) bool {
        return self.map.contains(key);
    }

    pub fn len(self: *const Self) usize {
        return self.map.count();
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.map.count() == 0;
    }

    pub fn unionWith(self: *const Self, other: *const Self, allocator: std.mem.Allocator) !Self {
        var result = Self.init(allocator);
        errdefer result.deinit();

        var it = self.map.keyIterator();
        while (it.next()) |key_ptr| {
            try result.insert(key_ptr.*);
        }

        it = other.map.keyIterator();
        while (it.next()) |key_ptr| {
            try result.insert(key_ptr.*);
        }

        return result;
    }

    pub fn intersection(self: *const Self, other: *const Self, allocator: std.mem.Allocator) !Self {
        var result = Self.init(allocator);
        errdefer result.deinit();

        var it = self.map.keyIterator();
        while (it.next()) |key_ptr| {
            if (other.contains(key_ptr.*)) {
                try result.insert(key_ptr.*);
            }
        }

        return result;
    }

    pub fn iterator(self: *Self) Iter {
        return .{ .set = self };
    }

    pub const Iter = struct {
        set: *Self,

        pub fn next(self: *Iter) ?u64 {
            var it = self.set.map.iterator();
            const entry = it.next() orelse return null;
            const key = entry.key_ptr.*;
            _ = self.set.map.remove(key);
            return key;
        }
    };
};

// ─── Tests ───

test "HashSet basic operations" {
    var set = HashSet.init(std.testing.allocator);
    defer set.deinit();

    try set.insert(1);
    try set.insert(2);
    try set.insert(3);

    try std.testing.expectEqual(@as(usize, 3), set.len());
    try std.testing.expect(set.contains(1));
    try std.testing.expect(!set.contains(4));

    try std.testing.expect(set.remove(2));
    try std.testing.expect(!set.contains(2));
    try std.testing.expectEqual(@as(usize, 2), set.len());

    try std.testing.expect(!set.remove(99));
}

test "HashSet union and intersection" {
    var a = HashSet.init(std.testing.allocator);
    defer a.deinit();
    var b = HashSet.init(std.testing.allocator);
    defer b.deinit();

    try a.insert(1);
    try a.insert(2);
    try b.insert(2);
    try b.insert(3);

    var u = try a.unionWith(&b, std.testing.allocator);
    defer u.deinit();
    try std.testing.expectEqual(@as(usize, 3), u.len());
    try std.testing.expect(u.contains(1));
    try std.testing.expect(u.contains(2));
    try std.testing.expect(u.contains(3));

    var i = try a.intersection(&b, std.testing.allocator);
    defer i.deinit();
    try std.testing.expectEqual(@as(usize, 1), i.len());
    try std.testing.expect(i.contains(2));
}

test "HashSet iterator" {
    var set = HashSet.init(std.testing.allocator);
    defer set.deinit();

    try set.insert(10);
    try set.insert(20);
    try set.insert(30);

    var iter = set.iterator();
    var count: usize = 0;
    while (iter.next() != null) {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect(set.isEmpty());
}
