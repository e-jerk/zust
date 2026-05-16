const std = @import("std");

/// A fixed-size pool of pre-allocated objects.
/// When you "allocate", you get an existing slot.
/// When you "free", the slot goes back to the pool.
///
/// O(1) acquire and release. Prevents memory fragmentation
/// by reusing a fixed set of objects.
pub fn Pool(comptime T: type) type {
    return struct {
        buffer: []Slot,
        free_list: std.ArrayList(usize),
        allocator: std.mem.Allocator,

        const Slot = struct {
            value: T,
            in_use: bool,
        };

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, cap: usize) !Self {
            const buf = try allocator.alloc(Slot, cap);
            @memset(buf, .{ .value = undefined, .in_use = false });

            var free_list: std.ArrayList(usize) = .empty;
            try free_list.ensureTotalCapacity(allocator, cap);
            for (0..cap) |i| {
                try free_list.append(allocator, i);
            }

            return .{
                .buffer = buf,
                .free_list = free_list,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            self.free_list.deinit(self.allocator);
        }

        /// Acquire a slot from the pool. Returns null if pool is exhausted.
        pub fn acquire(self: *Self) ?PoolBox(T) {
            if (self.free_list.items.len == 0) return null;
            const idx = self.free_list.pop().?;
            self.buffer[idx].in_use = true;
            return PoolBox(T).init(&self.buffer[idx].value, idx, self);
        }

        /// Release a slot back to the pool.
        pub fn release(self: *Self, box: PoolBox(T)) void {
            if (self.buffer[box.index].in_use) {
                self.buffer[box.index].in_use = false;
                self.free_list.append(self.allocator, box.index) catch {};
            }
        }

        pub fn available(self: *Self) usize {
            return self.free_list.items.len;
        }

        pub fn capacity(self: *Self) usize {
            return self.buffer.len;
        }
    };
}

/// A reference to a pooled object. Automatically returns to pool on deinit.
pub fn PoolBox(comptime T: type) type {
    return struct {
        ptr: *T,
        index: usize,
        pool: *Pool(T),

        const Self = @This();

        pub fn init(ptr: *T, index: usize, pool: *Pool(T)) Self {
            return .{ .ptr = ptr, .index = index, .pool = pool };
        }

        pub fn deinit(self: Self) void {
            self.pool.release(self);
        }

        pub fn get(self: Self) *T {
            return self.ptr;
        }

        pub fn getMut(self: Self) *T {
            return self.ptr;
        }
    };
}

/// A growable vector with a maximum capacity.
/// Never allocates after initialization. Prevents unbounded growth.
pub fn FixedVec(comptime T: type) type {
    return struct {
        buffer: []T,
        len: usize,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, cap: usize) !Self {
            const buf = try allocator.alloc(T, cap);
            return .{ .buffer = buf, .len = 0 };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
        }

        pub fn append(self: *Self, value: T) !void {
            if (self.len >= self.buffer.len) return error.OutOfMemory;
            self.buffer[self.len] = value;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.buffer[self.len];
        }

        pub fn get(self: *Self, index: usize) ?T {
            if (index >= self.len) return null;
            return self.buffer[index];
        }

        pub fn slice(self: *Self) []T {
            return self.buffer[0..self.len];
        }

        pub fn capacity(self: *Self) usize {
            return self.buffer.len;
        }

        pub fn isFull(self: *Self) bool {
            return self.len >= self.buffer.len;
        }
    };
}

// ─── Tests ───

test "Pool acquire and release" {
    var pool = try Pool(u32).init(std.testing.allocator, 4);
    defer pool.deinit();

    // Acquire a slot and write to it
    const box1 = pool.acquire().?;
    box1.getMut().* = 42;
    try std.testing.expectEqual(box1.get().*, 42);
    try std.testing.expectEqual(pool.available(), 3);

    // Release the slot back to the pool
    box1.deinit();
    try std.testing.expectEqual(pool.available(), 4);
}

test "Pool exhaust and null" {
    var pool = try Pool(u32).init(std.testing.allocator, 2);
    defer pool.deinit();

    // Exhaust the pool
    const box1 = pool.acquire().?;
    const box2 = pool.acquire().?;
    try std.testing.expectEqual(pool.available(), 0);

    // Third acquire should return null
    const box3 = pool.acquire();
    try std.testing.expect(box3 == null);

    // Release one slot and acquire again
    box1.deinit();
    try std.testing.expectEqual(pool.available(), 1);

    const box4 = pool.acquire().?;
    box4.deinit();
    box2.deinit();
}

test "FixedVec append and pop" {
    var vec = try FixedVec(u32).init(std.testing.allocator, 4);
    defer vec.deinit(std.testing.allocator);

    try vec.append(10);
    try vec.append(20);
    try vec.append(30);
    try std.testing.expectEqual(vec.len, 3);

    const val = vec.pop();
    try std.testing.expectEqual(val.?, 30);
    try std.testing.expectEqual(vec.len, 2);

    const first = vec.get(0);
    try std.testing.expectEqual(first.?, 10);
}

test "FixedVec capacity limit" {
    var vec = try FixedVec(u32).init(std.testing.allocator, 2);
    defer vec.deinit(std.testing.allocator);

    try vec.append(1);
    try vec.append(2);
    try std.testing.expect(vec.isFull());

    // Third append should fail
    const result = vec.append(3);
    try std.testing.expectError(error.OutOfMemory, result);
}
