const std = @import("std");
const Box = @import("Box.zig").Box;

/// A max-heap priority queue that owns Box(T) values.
/// Heap property: parent >= children.
/// The caller provides a `compare` function that returns true when the first
/// argument has higher priority than the second (i.e. should be closer to the root).
/// Pattern: Similar to Rust's BinaryHeap<T>.
pub fn BinaryHeap(comptime T: type) type {
    return struct {
        items: std.ArrayList(Box(T)),
        allocator: std.mem.Allocator,
        compare: *const fn (*const T, *const T) bool,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, compare: *const fn (*const T, *const T) bool) Self {
            return .{
                .items = std.ArrayList(Box(T)).empty,
                .allocator = allocator,
                .compare = compare,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.items.items) |box| {
                const dead = box.deinit();
                _ = dead;
            }
            self.items.deinit(self.allocator);
        }

        pub fn push(self: *Self, box: Box(T)) !void {
            try self.items.append(self.allocator, box);
            siftUp(self, self.items.items.len - 1);
        }

        pub fn pop(self: *Self) ?Box(T) {
            const n = self.items.items.len;
            if (n == 0) return null;
            if (n == 1) {
                return self.items.pop();
            }
            const result = self.items.items[0];
            self.items.items[0] = self.items.items[n - 1];
            _ = self.items.pop();
            siftDown(self, 0);
            return result;
        }

        pub fn peek(self: *const Self) ?*const T {
            if (self.items.items.len == 0) return null;
            return self.items.items[0].unsafePtr();
        }

        pub fn len(self: *const Self) usize {
            return self.items.items.len;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.items.items.len == 0;
        }

        pub fn peekMut(self: *Self) ?*T {
            if (self.items.items.len == 0) return null;
            return self.items.items[0].unsafePtr();
        }

        pub fn drainSorted(self: *Self, allocator: std.mem.Allocator) !std.ArrayList(Box(T)) {
            var result: std.ArrayList(Box(T)) = .empty;
            errdefer {
                for (result.items) |box| {
                    const dead = box.deinit();
                    _ = dead;
                }
                result.deinit(allocator);
            }
            while (self.pop()) |box| {
                try result.append(allocator, box);
            }
            return result;
        }

        fn siftUp(self: *Self, idx: usize) void {
            var i = idx;
            while (i > 0) {
                const parent = (i - 1) / 2;
                if (self.compare(self.items.items[i].unsafePtr(), self.items.items[parent].unsafePtr())) {
                    const tmp = self.items.items[i];
                    self.items.items[i] = self.items.items[parent];
                    self.items.items[parent] = tmp;
                    i = parent;
                } else {
                    break;
                }
            }
        }

        fn siftDown(self: *Self, idx: usize) void {
            var i = idx;
            const n = self.items.items.len;
            while (true) {
                var largest = i;
                const left = 2 * i + 1;
                const right = 2 * i + 2;
                if (left < n and self.compare(self.items.items[left].unsafePtr(), self.items.items[largest].unsafePtr())) {
                    largest = left;
                }
                if (right < n and self.compare(self.items.items[right].unsafePtr(), self.items.items[largest].unsafePtr())) {
                    largest = right;
                }
                if (largest == i) break;
                const tmp = self.items.items[i];
                self.items.items[i] = self.items.items[largest];
                self.items.items[largest] = tmp;
                i = largest;
            }
        }
    };
}

// ─── Tests ───

fn u64Greater(a: *const u64, b: *const u64) bool {
    return a.* > b.*;
}

test "BinaryHeap basic operations" {
    var heap = BinaryHeap(u64).init(std.testing.allocator, u64Greater);
    defer heap.deinit();

    try std.testing.expect(heap.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), heap.len());

    try heap.push(try Box(u64).init(std.testing.allocator, 10));
    try heap.push(try Box(u64).init(std.testing.allocator, 30));
    try heap.push(try Box(u64).init(std.testing.allocator, 20));

    try std.testing.expectEqual(@as(usize, 3), heap.len());
    try std.testing.expect(!heap.isEmpty());

    const peek = heap.peek().?;
    try std.testing.expectEqual(@as(u64, 30), peek.*);

    const max = heap.pop().?;
    try std.testing.expectEqual(@as(u64, 30), max.unsafePtr().*);
    const dead = max.deinit();
    _ = dead;
    try std.testing.expectEqual(@as(usize, 2), heap.len());
}

test "BinaryHeap ordering" {
    var heap = BinaryHeap(u64).init(std.testing.allocator, u64Greater);
    defer heap.deinit();

    const values = [_]u64{ 5, 1, 9, 3, 7 };
    for (values) |v| {
        try heap.push(try Box(u64).init(std.testing.allocator, v));
    }

    var sorted: [5]u64 = undefined;
    var i: usize = 0;
    while (heap.pop()) |box| {
        sorted[i] = box.unsafePtr().*;
        const dead = box.deinit();
        _ = dead;
        i += 1;
    }

    try std.testing.expectEqualSlices(u64, &[_]u64{ 9, 7, 5, 3, 1 }, &sorted);
}

test "BinaryHeap empty pop" {
    var heap = BinaryHeap(u64).init(std.testing.allocator, u64Greater);
    defer heap.deinit();

    try std.testing.expect(heap.pop() == null);
    try std.testing.expect(heap.peek() == null);
}

test "BinaryHeap peekMut" {
    var heap = BinaryHeap(u64).init(std.testing.allocator, u64Greater);
    defer heap.deinit();

    try heap.push(try Box(u64).init(std.testing.allocator, 10));
    try heap.push(try Box(u64).init(std.testing.allocator, 30));
    try heap.push(try Box(u64).init(std.testing.allocator, 20));

    const peek = heap.peekMut().?;
    try std.testing.expectEqual(@as(u64, 30), peek.*);
    peek.* = 50;

    const max = heap.pop().?;
    try std.testing.expectEqual(@as(u64, 50), max.unsafePtr().*);
    const dead = max.deinit();
    _ = dead;
}

test "BinaryHeap drainSorted" {
    var heap = BinaryHeap(u64).init(std.testing.allocator, u64Greater);
    defer heap.deinit();

    try heap.push(try Box(u64).init(std.testing.allocator, 5));
    try heap.push(try Box(u64).init(std.testing.allocator, 1));
    try heap.push(try Box(u64).init(std.testing.allocator, 9));
    try heap.push(try Box(u64).init(std.testing.allocator, 3));

    var sorted = try heap.drainSorted(std.testing.allocator);
    defer {
        for (sorted.items) |box| {
            const dead = box.deinit();
            _ = dead;
        }
        sorted.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 4), sorted.items.len);
    try std.testing.expectEqual(@as(u64, 9), sorted.items[0].unsafePtr().*);
    try std.testing.expectEqual(@as(u64, 5), sorted.items[1].unsafePtr().*);
    try std.testing.expectEqual(@as(u64, 3), sorted.items[2].unsafePtr().*);
    try std.testing.expectEqual(@as(u64, 1), sorted.items[3].unsafePtr().*);
    try std.testing.expect(heap.isEmpty());
}
