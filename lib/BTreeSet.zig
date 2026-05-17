const std = @import("std");
const Box = @import("Box.zig").Box;

/// A set of unique u64 keys backed by a binary search tree.
/// Provides O(log n) insertion, removal, and lookup on average.
/// Not self-balancing; worst case is O(n) for skewed input.
pub const BTreeSet = struct {
    root: ?Box(Node),
    _allocator: std.mem.Allocator,
    count: usize,

    const Node = struct {
        key: u64,
        left: ?Box(Node),
        right: ?Box(Node),
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .root = null, ._allocator = allocator, .count = 0 };
    }

    pub fn deinit(self: *Self) void {
        if (self.root) |r| {
            deinitNode(r);
        }
        self.count = 0;
    }

    fn deinitNode(node_box: Box(Node)) void {
        const node = node_box.unsafePtr();
        if (node.left) |l| deinitNode(l);
        if (node.right) |r| deinitNode(r);
        _ = node_box.deinit();
    }

    pub fn insert(self: *Self, key: u64) !void {
        self.root = try insertNode(self._allocator, self.root, key, &self.count);
    }

    fn insertNode(allocator: std.mem.Allocator, maybe_node: ?Box(Node), key: u64, count: *usize) !?Box(Node) {
        const node_box = maybe_node orelse {
            const ptr = try allocator.create(Node);
            ptr.* = .{ .key = key, .left = null, .right = null };
            count.* += 1;
            return Box(Node){ .ptr = ptr, .allocator = allocator };
        };

        const node = node_box.unsafePtr();
        if (key == node.key) {
            return node_box; // already present
        } else if (key < node.key) {
            node.left = try insertNode(allocator, node.left, key, count);
            return node_box;
        } else {
            node.right = try insertNode(allocator, node.right, key, count);
            return node_box;
        }
    }

    pub fn contains(self: *const Self, key: u64) bool {
        var current = self.root;
        while (current) |node_box| {
            const node = node_box.unsafePtr();
            if (key == node.key) return true;
            if (key < node.key) {
                current = node.left;
            } else {
                current = node.right;
            }
        }
        return false;
    }

    pub fn remove(self: *Self, key: u64) void {
        self.root = removeNode(self._allocator, self.root, key, &self.count);
    }

    fn removeNode(allocator: std.mem.Allocator, maybe_node: ?Box(Node), key: u64, count: *usize) ?Box(Node) {
        const node_box = maybe_node orelse return null;
        const node = node_box.unsafePtr();

        if (key == node.key) {
            count.* -= 1;
            // Case 1: no children
            if (node.left == null and node.right == null) {
                _ = node_box.deinit();
                return null;
            }
            // Case 2: one child
            if (node.left == null) {
                const right = node.right;
                _ = node_box.deinit();
                return right;
            }
            if (node.right == null) {
                const left = node.left;
                _ = node_box.deinit();
                return left;
            }
            // Case 3: two children — replace with minimum of right subtree
            const min_right = findMin(node.right.?);
            node.key = min_right;
            node.right = removeNode(allocator, node.right, min_right, count);
            // We already decremented count for the original key, but removing the min
            // will decrement again. Compensate:
            count.* += 1;
            return node_box;
        } else if (key < node.key) {
            node.left = removeNode(allocator, node.left, key, count);
            return node_box;
        } else {
            node.right = removeNode(allocator, node.right, key, count);
            return node_box;
        }
    }

    fn findMin(node_box: Box(Node)) u64 {
        const node = node_box.unsafePtr();
        if (node.left) |l| {
            return findMin(l);
        }
        return node.key;
    }

    pub fn len(self: *const Self) usize {
        return self.count;
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.count == 0;
    }

    pub fn clear(self: *Self) void {
        if (self.root) |r| {
            deinitNode(r);
        }
        self.root = null;
        self.count = 0;
    }

    /// Collect all keys into a newly allocated slice (sorted order).
    pub fn keys(self: *const Self) ![]u64 {
        var result = std.ArrayList(u64).empty;
        errdefer result.deinit(self._allocator);
        if (self.root) |r| {
            try collectKeys(r, &result, self._allocator);
        }
        return result.toOwnedSlice(self._allocator);
    }

    fn collectKeys(node_box: Box(Node), list: *std.ArrayList(u64), allocator: std.mem.Allocator) !void {
        const node = node_box.unsafePtr();
        if (node.left) |l| {
            try collectKeys(l, list, allocator);
        }
        try list.append(allocator, node.key);
        if (node.right) |r| {
            try collectKeys(r, list, allocator);
        }
    }
};

// ─── Tests ───

test "BTreeSet insert and contains" {
    const allocator = std.testing.allocator;
    var set = BTreeSet.init(allocator);
    defer set.deinit();

    try set.insert(42);
    try set.insert(7);
    try std.testing.expect(set.contains(42));
    try std.testing.expect(set.contains(7));
    try std.testing.expect(!set.contains(99));
    try std.testing.expectEqual(@as(usize, 2), set.len());
}

test "BTreeSet remove leaf" {
    const allocator = std.testing.allocator;
    var set = BTreeSet.init(allocator);
    defer set.deinit();

    try set.insert(42);
    set.remove(42);
    try std.testing.expect(!set.contains(42));
    try std.testing.expect(set.isEmpty());
}

test "BTreeSet remove with children" {
    const allocator = std.testing.allocator;
    var set = BTreeSet.init(allocator);
    defer set.deinit();

    try set.insert(50);
    try set.insert(30);
    try set.insert(70);
    try set.insert(20);
    try set.insert(40);
    try set.insert(60);
    try set.insert(80);

    set.remove(50); // remove root with two children
    try std.testing.expect(!set.contains(50));
    try std.testing.expect(set.contains(30));
    try std.testing.expect(set.contains(70));
    try std.testing.expectEqual(@as(usize, 6), set.len());
}

test "BTreeSet sorted keys" {
    const allocator = std.testing.allocator;
    var set = BTreeSet.init(allocator);
    defer set.deinit();

    try set.insert(3);
    try set.insert(1);
    try set.insert(2);

    const k = try set.keys();
    defer allocator.free(k);

    try std.testing.expectEqualSlices(u64, &[_]u64{ 1, 2, 3 }, k);
}

test "BTreeSet clear" {
    const allocator = std.testing.allocator;
    var set = BTreeSet.init(allocator);
    defer set.deinit();

    try set.insert(1);
    try set.insert(2);
    set.clear();
    try std.testing.expect(set.isEmpty());
    try std.testing.expect(!set.contains(1));
}
