const std = @import("std");

/// Interned string handle. Just a pointer to the shared string data.
/// Equality is pointer comparison (O(1)).
pub const InternedString = struct {
    ptr: []const u8,

    pub fn eql(a: InternedString, b: InternedString) bool {
        return a.ptr.ptr == b.ptr.ptr;
    }

    pub fn slice(self: InternedString) []const u8 {
        return self.ptr;
    }

    pub fn hash(self: InternedString) u64 {
        return std.hash.Fnv1a_64.hash(self.ptr);
    }
};

/// String interner: deduplicates strings for fast comparison.
pub const StringInterner = struct {
    // Hash map: string content -> InternedString
    map: std.StringHashMap(InternedString),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .map = std.StringHashMap(InternedString).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free all interned strings
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.ptr);
            self.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit();
    }

    /// Intern a string. If it already exists, return existing handle.
    /// Otherwise, copy and store it.
    pub fn intern(self: *Self, str: []const u8) !InternedString {
        if (self.map.get(str)) |existing| {
            return existing;
        }

        // Copy string
        const copy = try self.allocator.dupe(u8, str);
        errdefer self.allocator.free(copy);

        const key_copy = try self.allocator.dupe(u8, str);
        errdefer self.allocator.free(key_copy);

        const interned = InternedString{ .ptr = copy };
        try self.map.put(key_copy, interned);

        return interned;
    }

    /// Check if a string is already interned.
    pub fn get(self: *Self, str: []const u8) ?InternedString {
        return self.map.get(str);
    }

    pub fn count(self: *Self) usize {
        return self.map.count();
    }
};

// === Tests ===

test "StringInterner basic intern and equality" {
    var interner = StringInterner.init(std.testing.allocator);
    defer interner.deinit();

    const s1 = try interner.intern("hello");
    const s2 = try interner.intern("hello");

    try std.testing.expect(s1.eql(s2));
    try std.testing.expectEqualStrings(s1.slice(), "hello");
}

test "StringInterner same string returns same pointer" {
    var interner = StringInterner.init(std.testing.allocator);
    defer interner.deinit();

    const s1 = try interner.intern("world");
    const s2 = try interner.intern("world");

    try std.testing.expectEqual(s1.ptr.ptr, s2.ptr.ptr);
}

test "StringInterner different strings return different pointers" {
    var interner = StringInterner.init(std.testing.allocator);
    defer interner.deinit();

    const s1 = try interner.intern("foo");
    const s2 = try interner.intern("bar");

    try std.testing.expect(s1.ptr.ptr != s2.ptr.ptr);
}

test "StringInterner count tracks unique strings" {
    var interner = StringInterner.init(std.testing.allocator);
    defer interner.deinit();

    try std.testing.expectEqual(interner.count(), 0);

    _ = try interner.intern("a");
    try std.testing.expectEqual(interner.count(), 1);

    _ = try interner.intern("b");
    try std.testing.expectEqual(interner.count(), 2);

    _ = try interner.intern("a"); // duplicate
    try std.testing.expectEqual(interner.count(), 2);
}
