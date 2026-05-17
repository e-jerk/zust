const std = @import("std");
const Box = @import("Box.zig").Box;
const BoxStateful = @import("Box.zig").BoxStateful;

/// A simple binary search tree map (not self-balancing).
/// Stores key-value pairs where keys are u64 and values are owned Box(T).
/// For a production-grade ordered map, use a self-balancing tree (e.g. AVL, Red-Black).
pub fn BTreeMap(comptime T: type) type {
    return struct {
        root: ?Box(Node),
        _allocator: std.mem.Allocator,
        count: usize,
        outstanding_imm: u32 = 0,
        outstanding_mut: u32 = 0,

        const Self = @This();

        const Node = struct {
            key: u64,
            value: Box(T),
            left: ?Box(Node),
            right: ?Box(Node),
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .root = null,
                ._allocator = allocator,
                .count = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.outstanding_imm > 0) {
                @panic("cannot deinit BTreeMap while active immutable borrows exist");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot deinit BTreeMap while active mutable borrow exists");
            }
            if (self.root) |root| {
                deinitNode(root);
            }
        }

        fn deinitNode(box: Box(Node)) void {
            const node = box.unsafePtr();
            const left = node.left;
            const right = node.right;
            const value = node.value;
            const dead = box.deinit();
            _ = dead;
            if (left) |l| deinitNode(l);
            if (right) |r| deinitNode(r);
            const dead_val = value.deinit();
            _ = dead_val;
        }

        pub fn put(self: *Self, key: u64, value_box: Box(T)) !void {
            if (self.outstanding_mut > 0) {
                @panic("cannot put while BTreeMap is mutably borrowed");
            }
            self.root = try insertNode(self._allocator, self.root, key, value_box, &self.count);
        }

        fn insertNode(allocator: std.mem.Allocator, maybe_box: ?Box(Node), key: u64, value: Box(T), count: *usize) !?Box(Node) {
            const box = maybe_box orelse {
                const node_ptr = try allocator.create(Node);
                node_ptr.* = Node{ .key = key, .value = value, .left = null, .right = null };
                count.* += 1;
                return Box(Node){ .ptr = node_ptr, .allocator = allocator };
            };
            const node = box.unsafePtr();
            if (key == node.key) {
                const dead = node.value.deinit();
                _ = dead;
                node.value = value;
                return box;
            } else if (key < node.key) {
                node.left = try insertNode(allocator, node.left, key, value, count);
                return box;
            } else {
                node.right = try insertNode(allocator, node.right, key, value, count);
                return box;
            }
        }

        pub fn get(self: *Self, key: u64) ?Box(T) {
            if (self.outstanding_imm > 0) {
                @panic("cannot get while BTreeMap has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot get while BTreeMap has active mutable borrow");
            }
            const result = removeNode(&self.root, key);
            if (result != null) {
                self.count -= 1;
            }
            return result;
        }

        pub fn getMut(self: *Self, key: u64) ?struct {
            box: BoxStateful(T, 2, 0, 1),
            map: *Self,

            const Borrow = @This();

            pub fn releaseMut(b: Borrow) void {
                b.map.outstanding_mut -= 1;
            }
        } {
            if (self.outstanding_imm > 0) {
                @panic("cannot getMut while BTreeMap has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot getMut while BTreeMap is already mutably borrowed");
            }
            const root = self.root orelse return null;
            const node = findNode(root, key) orelse return null;
            self.outstanding_mut += 1;
            return .{
                .box = node.value.borrowMut(),
                .map = self,
            };
        }

        pub fn remove(self: *Self, key: u64) bool {
            if (self.outstanding_imm > 0) {
                @panic("cannot remove while BTreeMap has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot remove while BTreeMap is mutably borrowed");
            }
            const maybe_box = self.get(key);
            if (maybe_box) |b| {
                const dead = b.deinit();
                _ = dead;
                return true;
            }
            return false;
        }

        pub fn contains(self: *const Self, key: u64) bool {
            const root = self.root orelse return false;
            return findNode(root, key) != null;
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        pub fn min(self: *const Self) ?u64 {
            const root = self.root orelse return null;
            return findMinKey(root);
        }

        pub fn max(self: *const Self) ?u64 {
            const root = self.root orelse return null;
            return findMaxKey(root);
        }

        pub fn iterator(self: *Self) Iter {
            return .{ .map = self };
        }

        pub fn rangeKeys(self: *const Self, range_min: u64, range_max: u64) !std.ArrayList(u64) {
            var result: std.ArrayList(u64) = .empty;
            errdefer result.deinit(self._allocator);
            if (self.root) |root| {
                try rangeKeysNode(root, range_min, range_max, self._allocator, &result);
            }
            return result;
        }

        fn rangeKeysNode(box: Box(Node), range_min: u64, range_max: u64, allocator: std.mem.Allocator, result: *std.ArrayList(u64)) !void {
            const node = box.unsafePtr();
            if (node.left) |left| {
                try rangeKeysNode(left, range_min, range_max, allocator, result);
            }
            if (node.key >= range_min and node.key <= range_max) {
                try result.append(allocator, node.key);
            }
            if (node.right) |right| {
                try rangeKeysNode(right, range_min, range_max, allocator, result);
            }
        }

        pub fn lowerBound(self: *const Self, key: u64) ?u64 {
            const root = self.root orelse return null;
            return lowerBoundNode(root, key);
        }

        fn lowerBoundNode(box: Box(Node), key: u64) ?u64 {
            const node = box.unsafePtr();
            if (node.key >= key) {
                const left_best = if (node.left) |left| lowerBoundNode(left, key) else null;
                return left_best orelse node.key;
            } else {
                return if (node.right) |right| lowerBoundNode(right, key) else null;
            }
        }

        pub fn upperBound(self: *const Self, key: u64) ?u64 {
            const root = self.root orelse return null;
            return upperBoundNode(root, key);
        }

        fn upperBoundNode(box: Box(Node), key: u64) ?u64 {
            const node = box.unsafePtr();
            if (node.key > key) {
                const left_best = if (node.left) |left| upperBoundNode(left, key) else null;
                return left_best orelse node.key;
            } else {
                return if (node.right) |right| upperBoundNode(right, key) else null;
            }
        }

        pub const Iter = struct {
            map: *Self,

            pub fn next(self: *Iter) ?Box(T) {
                const key = self.map.min() orelse return null;
                return self.map.get(key);
            }
        };

        pub fn rev(self: *Self) RevIter {
            return .{ .map = self };
        }

        pub const RevIter = struct {
            map: *Self,

            pub fn next(self: *RevIter) ?Box(T) {
                const key = self.map.max() orelse return null;
                return self.map.get(key);
            }
        };

        fn findNode(box: Box(Node), key: u64) ?*Node {
            const node = box.unsafePtr();
            if (key == node.key) {
                return node;
            } else if (key < node.key) {
                const left = node.left orelse return null;
                return findNode(left, key);
            } else {
                const right = node.right orelse return null;
                return findNode(right, key);
            }
        }

        fn findMinKey(box: Box(Node)) u64 {
            var current = box;
            while (true) {
                const node = current.unsafePtr();
                if (node.left) |left| {
                    current = left;
                } else {
                    return node.key;
                }
            }
        }

        fn findMaxKey(box: Box(Node)) u64 {
            var current = box;
            while (true) {
                const node = current.unsafePtr();
                if (node.right) |right| {
                    current = right;
                } else {
                    return node.key;
                }
            }
        }

        fn removeNode(maybe_box: *?Box(Node), key: u64) ?Box(T) {
            const box = maybe_box.* orelse return null;
            const node = box.unsafePtr();
            if (key == node.key) {
                const value = node.value;
                if (node.left == null and node.right == null) {
                    const dead = box.deinit();
                    _ = dead;
                    maybe_box.* = null;
                    return value;
                } else if (node.left == null) {
                    const right = node.right.?;
                    const dead = box.deinit();
                    _ = dead;
                    maybe_box.* = right;
                    return value;
                } else if (node.right == null) {
                    const left = node.left.?;
                    const dead = box.deinit();
                    _ = dead;
                    maybe_box.* = left;
                    return value;
                } else {
                    const succ_key = findMinKey(node.right.?);
                    const succ_value = removeNode(&node.right, succ_key).?;
                    node.key = succ_key;
                    node.value = succ_value;
                    return value;
                }
            } else if (key < node.key) {
                return removeNode(&node.left, key);
            } else {
                return removeNode(&node.right, key);
            }
        }
    };
}

// ─── Tests ───

test "BTreeMap basic operations" {
    var map = BTreeMap(i32).init(std.testing.allocator);
    defer map.deinit();

    try map.put(3, try Box(i32).init(std.testing.allocator, 30));
    try map.put(1, try Box(i32).init(std.testing.allocator, 10));
    try map.put(2, try Box(i32).init(std.testing.allocator, 20));

    try std.testing.expectEqual(@as(usize, 3), map.len());
    try std.testing.expect(map.contains(1));
    try std.testing.expect(map.contains(2));
    try std.testing.expect(map.contains(3));
    try std.testing.expect(!map.contains(4));

    try std.testing.expectEqual(@as(?u64, 1), map.min());
    try std.testing.expectEqual(@as(?u64, 3), map.max());

    const val = map.get(2).?;
    try std.testing.expectEqual(@as(i32, 20), val.unsafePtr().*);
    const dead = val.deinit();
    _ = dead;

    try std.testing.expectEqual(@as(usize, 2), map.len());
    try std.testing.expect(!map.contains(2));

    const removed = map.remove(1);
    try std.testing.expect(removed);
    try std.testing.expect(!map.contains(1));
    try std.testing.expectEqual(@as(usize, 1), map.len());

    const not_removed = map.remove(99);
    try std.testing.expect(!not_removed);
}

test "BTreeMap getMut" {
    var map = BTreeMap(i32).init(std.testing.allocator);
    defer map.deinit();

    try map.put(5, try Box(i32).init(std.testing.allocator, 50));

    const borrow = map.getMut(5).?;
    borrow.box.ptr.* = 55;
    borrow.releaseMut();

    const val = map.get(5).?;
    try std.testing.expectEqual(@as(i32, 55), val.unsafePtr().*);
    const dead = val.deinit();
    _ = dead;
}

test "BTreeMap iterator" {
    var map = BTreeMap(i32).init(std.testing.allocator);
    defer map.deinit();

    try map.put(3, try Box(i32).init(std.testing.allocator, 300));
    try map.put(1, try Box(i32).init(std.testing.allocator, 100));
    try map.put(2, try Box(i32).init(std.testing.allocator, 200));

    var iter = map.iterator();
    const v1 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 100), v1.unsafePtr().*);
    const dead1 = v1.deinit();
    _ = dead1;

    const v2 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 200), v2.unsafePtr().*);
    const dead2 = v2.deinit();
    _ = dead2;

    const v3 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 300), v3.unsafePtr().*);
    const dead3 = v3.deinit();
    _ = dead3;

    try std.testing.expect(iter.next() == null);
    try std.testing.expect(map.isEmpty());
}

test "BTreeMap rev iterator" {
    var map = BTreeMap(i32).init(std.testing.allocator);
    defer map.deinit();

    try map.put(3, try Box(i32).init(std.testing.allocator, 300));
    try map.put(1, try Box(i32).init(std.testing.allocator, 100));
    try map.put(2, try Box(i32).init(std.testing.allocator, 200));

    var iter = map.rev();
    const v1 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 300), v1.unsafePtr().*);
    const dead1 = v1.deinit();
    _ = dead1;

    const v2 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 200), v2.unsafePtr().*);
    const dead2 = v2.deinit();
    _ = dead2;

    const v3 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 100), v3.unsafePtr().*);
    const dead3 = v3.deinit();
    _ = dead3;

    try std.testing.expect(iter.next() == null);
    try std.testing.expect(map.isEmpty());
}

test "BTreeMap replace" {
    var map = BTreeMap(i32).init(std.testing.allocator);
    defer map.deinit();

    try map.put(1, try Box(i32).init(std.testing.allocator, 10));
    try map.put(1, try Box(i32).init(std.testing.allocator, 11));

    try std.testing.expectEqual(@as(usize, 1), map.len());
    const val = map.get(1).?;
    try std.testing.expectEqual(@as(i32, 11), val.unsafePtr().*);
    const dead = val.deinit();
    _ = dead;
}

test "BTreeMap rangeKeys" {
    var map = BTreeMap(i32).init(std.testing.allocator);
    defer map.deinit();

    try map.put(3, try Box(i32).init(std.testing.allocator, 300));
    try map.put(1, try Box(i32).init(std.testing.allocator, 100));
    try map.put(5, try Box(i32).init(std.testing.allocator, 500));
    try map.put(2, try Box(i32).init(std.testing.allocator, 200));
    try map.put(4, try Box(i32).init(std.testing.allocator, 400));

    var keys = try map.rangeKeys(2, 4);
    defer keys.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), keys.items.len);
    try std.testing.expectEqual(@as(u64, 2), keys.items[0]);
    try std.testing.expectEqual(@as(u64, 3), keys.items[1]);
    try std.testing.expectEqual(@as(u64, 4), keys.items[2]);
}

test "BTreeMap lowerBound" {
    var map = BTreeMap(i32).init(std.testing.allocator);
    defer map.deinit();

    try map.put(10, try Box(i32).init(std.testing.allocator, 100));
    try map.put(20, try Box(i32).init(std.testing.allocator, 200));
    try map.put(30, try Box(i32).init(std.testing.allocator, 300));

    try std.testing.expectEqual(@as(?u64, 10), map.lowerBound(5));
    try std.testing.expectEqual(@as(?u64, 20), map.lowerBound(20));
    try std.testing.expectEqual(@as(?u64, 30), map.lowerBound(25));
    try std.testing.expectEqual(@as(?u64, null), map.lowerBound(35));
}

test "BTreeMap upperBound" {
    var map = BTreeMap(i32).init(std.testing.allocator);
    defer map.deinit();

    try map.put(10, try Box(i32).init(std.testing.allocator, 100));
    try map.put(20, try Box(i32).init(std.testing.allocator, 200));
    try map.put(30, try Box(i32).init(std.testing.allocator, 300));

    try std.testing.expectEqual(@as(?u64, 10), map.upperBound(5));
    try std.testing.expectEqual(@as(?u64, 20), map.upperBound(10));
    try std.testing.expectEqual(@as(?u64, 30), map.upperBound(25));
    try std.testing.expectEqual(@as(?u64, null), map.upperBound(30));
    try std.testing.expectEqual(@as(?u64, null), map.upperBound(35));
}
