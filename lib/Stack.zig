const std = @import("std");

/// A LIFO stack with ownership transfer.
/// Push owns the value, pop transfers ownership out.
pub fn Stack(comptime T: type) type {
    return struct {
        items: std.ArrayList(T),
        _allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .items = std.ArrayList(T).empty,
                ._allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self._allocator);
        }

        pub fn push(self: *Self, value: T) !void {
            try self.items.append(self._allocator, value);
        }

        pub fn pop(self: *Self) ?T {
            return self.items.pop();
        }

        pub fn peek(self: *Self) ?*T {
            if (self.items.items.len == 0) return null;
            return &self.items.items[self.items.items.len - 1];
        }

        pub fn len(self: *Self) usize {
            return self.items.items.len;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.items.items.len == 0;
        }

        pub fn clear(self: *Self) void {
            self.items.clearAndFree(self._allocator);
        }

        pub fn shrinkToFit(self: *Self) !void {
            try self.items.ensureTotalCapacityPrecise(self._allocator, self.items.items.len);
        }
    };
}

/// A FIFO queue with ownership transfer.
/// Enqueue owns the value, dequeue transfers ownership out.
pub fn Queue(comptime T: type) type {
    return struct {
        items: std.ArrayList(T),
        head: usize,
        _allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .items = std.ArrayList(T).empty,
                .head = 0,
                ._allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self._allocator);
        }

        pub fn enqueue(self: *Self, value: T) !void {
            try self.items.append(self._allocator, value);
        }

        pub fn dequeue(self: *Self) ?T {
            if (self.head >= self.items.items.len) return null;
            const value = self.items.items[self.head];
            self.head += 1;

            // Reset if queue becomes empty to reclaim space
            if (self.head >= self.items.items.len) {
                self.items.items.len = 0;
                self.head = 0;
            }

            return value;
        }

        pub fn peek(self: *Self) ?*T {
            if (self.head >= self.items.items.len) return null;
            return &self.items.items[self.head];
        }

        pub fn len(self: *Self) usize {
            return self.items.items.len - self.head;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.head >= self.items.items.len;
        }

        pub fn clear(self: *Self) void {
            self.items.clearAndFree(self._allocator);
            self.head = 0;
        }

        /// Compact the queue by moving elements to the front
        pub fn compact(self: *Self) !void {
            if (self.head == 0) return;
            const count = self.items.items.len - self.head;
            std.mem.copyForwards(T, self.items.items[0..count], self.items.items[self.head..]);
            self.items.items.len = count;
            self.head = 0;
            try self.items.ensureTotalCapacityPrecise(self._allocator, count);
        }
    };
}

// ─── Tests ───

test "Stack push and pop" {
    var stack = Stack(u32).init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(10);
    try stack.push(20);
    try stack.push(30);

    try std.testing.expectEqual(stack.pop(), 30);
    try std.testing.expectEqual(stack.pop(), 20);
    try std.testing.expectEqual(stack.pop(), 10);
    try std.testing.expectEqual(stack.pop(), null);
}

test "Stack peek" {
    var stack = Stack(u32).init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(42);
    try std.testing.expectEqual(stack.peek().?.*, 42);

    try stack.push(100);
    try std.testing.expectEqual(stack.peek().?.*, 100);

    _ = stack.pop();
    try std.testing.expectEqual(stack.peek().?.*, 42);
}

test "Stack clear and isEmpty" {
    var stack = Stack(u32).init(std.testing.allocator);
    defer stack.deinit();

    try std.testing.expect(stack.isEmpty());
    try stack.push(1);
    try stack.push(2);
    try std.testing.expect(!stack.isEmpty());
    try std.testing.expectEqual(stack.len(), 2);

    stack.clear();
    try std.testing.expect(stack.isEmpty());
    try std.testing.expectEqual(stack.len(), 0);
    try std.testing.expectEqual(stack.pop(), null);
}

test "Queue enqueue and dequeue" {
    var queue = Queue(u32).init(std.testing.allocator);
    defer queue.deinit();

    try queue.enqueue(10);
    try queue.enqueue(20);
    try queue.enqueue(30);

    try std.testing.expectEqual(queue.dequeue(), 10);
    try std.testing.expectEqual(queue.dequeue(), 20);
    try std.testing.expectEqual(queue.dequeue(), 30);
    try std.testing.expectEqual(queue.dequeue(), null);
}

test "Queue FIFO order" {
    var queue = Queue(u32).init(std.testing.allocator);
    defer queue.deinit();

    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);
    try queue.enqueue(4);

    try std.testing.expectEqual(queue.dequeue(), 1);
    try std.testing.expectEqual(queue.dequeue(), 2);
    try std.testing.expectEqual(queue.dequeue(), 3);
    try std.testing.expectEqual(queue.dequeue(), 4);
    try std.testing.expect(queue.isEmpty());
}

test "Queue compact" {
    var queue = Queue(u32).init(std.testing.allocator);
    defer queue.deinit();

    try queue.enqueue(10);
    try queue.enqueue(20);
    try queue.enqueue(30);

    // Dequeue some to advance head
    try std.testing.expectEqual(queue.dequeue(), 10);
    try std.testing.expectEqual(queue.dequeue(), 20);
    try std.testing.expectEqual(queue.len(), 1);
    try std.testing.expectEqual(queue.head, 2);

    // Compact moves remaining elements to front
    try queue.compact();
    try std.testing.expectEqual(queue.head, 0);
    try std.testing.expectEqual(queue.len(), 1);
    try std.testing.expectEqual(queue.peek().?.*, 30);
    try std.testing.expectEqual(queue.dequeue(), 30);
    try std.testing.expect(queue.isEmpty());
}
