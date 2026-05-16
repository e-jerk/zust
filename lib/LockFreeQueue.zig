const std = @import("std");

/// A simple lock-free queue using atomic operations.
///
/// Educational/naive implementation based on a linked list with
/// atomic CAS on head and tail pointers.
///
/// Uses a sentinel node so head and tail are never null after init.
pub fn LockFreeQueue(comptime T: type) type {
    return struct {
        const Node = struct {
            value: ?T,
            next: std.atomic.Value(?*Node),
        };

        sentinel: *Node,
        head: std.atomic.Value(?*Node),
        tail: std.atomic.Value(?*Node),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            const node = try allocator.create(Node);
            node.* = .{
                .value = null,
                .next = std.atomic.Value(?*Node).init(null),
            };
            return .{
                .sentinel = node,
                .head = std.atomic.Value(?*Node).init(node),
                .tail = std.atomic.Value(?*Node).init(node),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            var current: ?*Node = self.sentinel;
            while (current) |node| {
                const next = node.next.load(.seq_cst);
                self.allocator.destroy(node);
                current = next;
            }
        }

        /// Lock-free push using CAS on tail.
        pub fn enqueue(self: *Self, value: T) !void {
            const node = try self.allocator.create(Node);
            node.* = .{
                .value = value,
                .next = std.atomic.Value(?*Node).init(null),
            };

            while (true) {
                const tail = self.tail.load(.seq_cst);
                const next = tail.?.next.load(.seq_cst);

                if (next == null) {
                    if (tail.?.next.cmpxchgStrong(null, node, .seq_cst, .seq_cst) == null) {
                        _ = self.tail.cmpxchgStrong(tail, node, .seq_cst, .seq_cst);
                        return;
                    }
                } else {
                    _ = self.tail.cmpxchgStrong(tail, next, .seq_cst, .seq_cst);
                }
            }
        }

        /// Lock-free pop using CAS on head.
        pub fn dequeue(self: *Self) ?T {
            while (true) {
                const head = self.head.load(.seq_cst);
                const tail = self.tail.load(.seq_cst);
                const next = head.?.next.load(.seq_cst);

                if (head == tail) {
                    if (next == null) return null;
                    _ = self.tail.cmpxchgStrong(tail, next, .seq_cst, .seq_cst);
                } else {
                    const value = next.?.value.?;
                    if (self.head.cmpxchgStrong(head, next, .seq_cst, .seq_cst) == null) {
                        return value;
                    }
                }
            }
        }

        /// Atomic check for emptiness.
        pub fn isEmpty(self: *Self) bool {
            const head = self.head.load(.seq_cst);
            const tail = self.tail.load(.seq_cst);
            if (head == tail) {
                const next = head.?.next.load(.seq_cst);
                return next == null;
            }
            return false;
        }
    };
}

// ─── Tests ───

test "LockFreeQueue init and deinit" {
    var q = try LockFreeQueue(u32).init(std.testing.allocator);
    q.deinit();
}

test "LockFreeQueue enqueue and dequeue" {
    var q = try LockFreeQueue(u32).init(std.testing.allocator);
    defer q.deinit();

    try q.enqueue(42);
    try std.testing.expect(!q.isEmpty());
    const val = q.dequeue();
    try std.testing.expectEqual(val.?, 42);
    try std.testing.expect(q.isEmpty());
}

test "LockFreeQueue FIFO order" {
    var q = try LockFreeQueue(u32).init(std.testing.allocator);
    defer q.deinit();

    try q.enqueue(1);
    try q.enqueue(2);
    try q.enqueue(3);

    try std.testing.expectEqual(q.dequeue().?, 1);
    try std.testing.expectEqual(q.dequeue().?, 2);
    try std.testing.expectEqual(q.dequeue().?, 3);
    try std.testing.expect(q.isEmpty());
}

test "LockFreeQueue isEmpty" {
    var q = try LockFreeQueue(u32).init(std.testing.allocator);
    defer q.deinit();

    try std.testing.expect(q.isEmpty());
    try q.enqueue(1);
    try std.testing.expect(!q.isEmpty());
    _ = q.dequeue();
    try std.testing.expect(q.isEmpty());
}

test "LockFreeQueue concurrent operations" {
    var q = try LockFreeQueue(u32).init(std.testing.allocator);
    defer q.deinit();

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn f(ctx: *LockFreeQueue(u32)) void {
                var i: u32 = 0;
                while (i < 25) : (i += 1) {
                    ctx.enqueue(i) catch @panic("enqueue failed");
                }
            }
        }.f, .{&q});
    }

    for (&threads) |*t| {
        t.join();
    }

    var count: usize = 0;
    while (q.dequeue() != null) {
        count += 1;
    }
    try std.testing.expectEqual(count, 100);
}
