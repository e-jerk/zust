const std = @import("std");
const Box = @import("Box.zig").Box;
const SimdUtils = @import("SimdUtils.zig");

/// A double-ended queue implemented with a growable ring buffer.
/// Similar to Rust's `std::collections::VecDeque<T>`.
///
/// O(1) push/pop at both ends.
/// Stores Box(T, 0, 0, 0) values.
pub fn VecDeque(comptime T: type) type {
    return struct {
        buffer: []Box(T, 0, 0, 0),
        head: usize,
        len: usize,
        allocator: std.mem.Allocator,

        const Self = @This();
        const initial_capacity = 4;

        pub fn init(allocator: std.mem.Allocator) !Self {
            const buf = try allocator.alloc(Box(T, 0, 0, 0), initial_capacity);
            @memset(buf, undefined);
            return .{
                .buffer = buf,
                .head = 0,
                .len = 0,
                .allocator = allocator,
            };
        }

        /// Create an empty deque (same as `init`).
        pub fn initDefault(allocator: std.mem.Allocator) !Self {
            return init(allocator);
        }

        pub fn deinit(self: *Self) void {
            // Deinit all owned boxes
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                const idx = self.wrap(self.head + i);
                const dead = self.buffer[idx].deinit();
                _ = dead;
            }
            self.allocator.free(self.buffer);
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        fn wrap(self: *const Self, index: usize) usize {
            return index % self.buffer.len;
        }

        fn grow(self: *Self) !void {
            const new_cap = self.buffer.len * 2;
            const new_buf = try self.allocator.alloc(Box(T, 0, 0, 0), new_cap);
            @memset(new_buf, undefined);

            if (@sizeOf(T) == 1 and self.len >= 16 and self.head + self.len <= self.buffer.len) {
                const byte_len = self.len * @sizeOf(Box(T, 0, 0, 0));
                const src = @as([*]const u8, @ptrCast(&self.buffer[self.head]))[0..byte_len];
                const dst = @as([*]u8, @ptrCast(new_buf))[0..byte_len];
                SimdUtils.copy(dst, src);
            } else {
                var i: usize = 0;
                while (i < self.len) : (i += 1) {
                    new_buf[i] = self.buffer[self.wrap(self.head + i)];
                }
            }

            self.allocator.free(self.buffer);
            self.buffer = new_buf;
            self.head = 0;
        }

        pub fn pushBack(self: *Self, box: Box(T, 0, 0, 0)) !void {
            if (self.len == self.buffer.len) {
                try self.grow();
            }
            const idx = self.wrap(self.head + self.len);
            self.buffer[idx] = box;
            self.len += 1;
        }

        pub fn pushFront(self: *Self, box: Box(T, 0, 0, 0)) !void {
            if (self.len == self.buffer.len) {
                try self.grow();
            }
            self.head = self.wrap(self.head + self.buffer.len - 1);
            self.buffer[self.head] = box;
            self.len += 1;
        }

        pub fn popBack(self: *Self) ?Box(T, 0, 0, 0) {
            if (self.len == 0) return null;
            self.len -= 1;
            const idx = self.wrap(self.head + self.len);
            return self.buffer[idx];
        }

        pub fn popFront(self: *Self) ?Box(T, 0, 0, 0) {
            if (self.len == 0) return null;
            const idx = self.head;
            self.head = self.wrap(self.head + 1);
            self.len -= 1;
            return self.buffer[idx];
        }

        pub fn get(self: *const Self, index: usize) ?Box(T, 0, 0, 0) {
            if (index >= self.len) return null;
            return self.buffer[self.wrap(self.head + index)];
        }

        pub fn getMut(self: *Self, index: usize) ?struct {
            box: Box(T, 2, 0, 1),
            deque: *Self,
            index: usize,

            const Borrow = @This();

            pub fn releaseMut(b: Borrow) void {
                _ = b;
            }
        } {
            if (index >= self.len) return null;
            const box = self.buffer[self.wrap(self.head + index)].borrowMut();
            return .{
                .box = box,
                .deque = self,
                .index = index,
            };
        }

        pub fn front(self: *Self) ?Box(T, 0, 0, 0) {
            return self.get(0);
        }

        pub fn back(self: *Self) ?Box(T, 0, 0, 0) {
            if (self.len == 0) return null;
            return self.get(self.len - 1);
        }

        pub fn rotateLeft(self: *Self, n: usize) void {
            if (self.len == 0) return;
            const k = n % self.len;
            var i: usize = 0;
            while (i < k) : (i += 1) {
                if (self.popFront()) |box| {
                    self.pushBack(box) catch @panic("VecDeque.rotateLeft allocation failed");
                }
            }
        }

        pub fn rotateRight(self: *Self, n: usize) void {
            if (self.len == 0) return;
            const k = n % self.len;
            var i: usize = 0;
            while (i < k) : (i += 1) {
                if (self.popBack()) |box| {
                    self.pushFront(box) catch @panic("VecDeque.rotateRight allocation failed");
                }
            }
        }

        pub fn retain(self: *Self, context: anytype, comptime pred: fn (@TypeOf(context), *const T) bool) void {
            if (self.len == 0) return;

            var write_idx: usize = 0;
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                const read_idx = self.wrap(self.head + i);
                const box = self.buffer[read_idx];
                if (pred(context, box.ptr)) {
                    self.buffer[write_idx] = box;
                    write_idx += 1;
                } else {
                    const dead = box.deinit();
                    _ = dead;
                }
            }
            self.head = 0;
            self.len = write_idx;
        }

        pub fn resize(self: *Self, new_len: usize, default: Box(T, 0, 0, 0)) !void {
            if (new_len > self.len) {
                const n = new_len - self.len;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const new_box = try Box(T, 0, 0, 0).init(self.allocator, default.ptr.*);
                    try self.pushBack(new_box);
                }
                const dead = default.deinit();
                _ = dead;
            } else if (new_len < self.len) {
                self.truncate(new_len);
                const dead = default.deinit();
                _ = dead;
            } else {
                const dead = default.deinit();
                _ = dead;
            }
        }

        pub fn truncate(self: *Self, len: usize) void {
            if (len >= self.len) return;
            while (self.len > len) {
                const box = self.popBack();
                if (box) |b| {
                    const dead = b.deinit();
                    _ = dead;
                }
            }
        }

        /// Realign the ring buffer so elements are contiguous starting at index 0.
        /// Returns a mutable slice of all elements.
        /// Similar to Rust's `VecDeque::make_contiguous`.
        pub fn makeContiguous(self: *Self) ![]Box(T, 0, 0, 0) {
            if (self.head == 0) return self.buffer[0..self.len];

            // Need to reallocate and copy in order
            const new_buf = try self.allocator.alloc(Box(T, 0, 0, 0), self.buffer.len);
            @memset(new_buf, undefined);

            if (@sizeOf(T) == 1 and self.len >= 16 and self.head + self.len <= self.buffer.len) {
                const byte_len = self.len * @sizeOf(Box(T, 0, 0, 0));
                const src = @as([*]const u8, @ptrCast(&self.buffer[self.head]))[0..byte_len];
                const dst = @as([*]u8, @ptrCast(new_buf))[0..byte_len];
                SimdUtils.copy(dst, src);
            } else {
                var i: usize = 0;
                while (i < self.len) : (i += 1) {
                    new_buf[i] = self.buffer[self.wrap(self.head + i)];
                }
            }

            self.allocator.free(self.buffer);
            self.buffer = new_buf;
            self.head = 0;
            return self.buffer[0..self.len];
        }

        /// Return a consuming iterator over the deque (front to back).
        pub fn iterator(self: *Self) Iter {
            return .{ .dq = self };
        }

        /// Iterator for VecDeque<T>.
        /// Removes and returns each Box from the front (consumes the deque).
        pub const Iter = struct {
            dq: *Self,

            pub fn next(self: *Iter) ?Box(T, 0, 0, 0) {
                return self.dq.popFront();
            }
        };

        /// Return a consuming reverse iterator over the deque (back to front).
        pub fn rev(self: *Self) RevIter {
            return .{ .dq = self };
        }

        /// Reverse iterator for VecDeque<T>.
        /// Removes and returns each Box from the back (consumes the deque).
        pub const RevIter = struct {
            dq: *Self,

            pub fn next(self: *RevIter) ?Box(T, 0, 0, 0) {
                return self.dq.popBack();
            }
        };
    };
}

// ─── Tests ───

test "VecDeque iterator" {
    var dq = try VecDeque(i32).init(std.testing.allocator);
    defer dq.deinit();

    try dq.pushBack(try Box(i32, 0, 0, 0).init(std.testing.allocator, 10));
    try dq.pushBack(try Box(i32, 0, 0, 0).init(std.testing.allocator, 20));
    try dq.pushBack(try Box(i32, 0, 0, 0).init(std.testing.allocator, 30));

    var iter = dq.iterator();
    const v1 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 10), v1.unsafePtr().*);
    const dead1 = v1.deinit();
    _ = dead1;

    const v2 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 20), v2.unsafePtr().*);
    const dead2 = v2.deinit();
    _ = dead2;

    const v3 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 30), v3.unsafePtr().*);
    const dead3 = v3.deinit();
    _ = dead3;

    try std.testing.expect(iter.next() == null);
}

test "VecDeque rev iterator" {
    var dq = try VecDeque(i32).init(std.testing.allocator);
    defer dq.deinit();

    try dq.pushBack(try Box(i32, 0, 0, 0).init(std.testing.allocator, 10));
    try dq.pushBack(try Box(i32, 0, 0, 0).init(std.testing.allocator, 20));
    try dq.pushBack(try Box(i32, 0, 0, 0).init(std.testing.allocator, 30));

    var iter = dq.rev();
    const v1 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 30), v1.unsafePtr().*);
    const dead1 = v1.deinit();
    _ = dead1;

    const v2 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 20), v2.unsafePtr().*);
    const dead2 = v2.deinit();
    _ = dead2;

    const v3 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 10), v3.unsafePtr().*);
    const dead3 = v3.deinit();
    _ = dead3;

    try std.testing.expect(iter.next() == null);
}

test "VecDeque makeContiguous" {
    var dq = try VecDeque(u32).init(std.testing.allocator);
    defer dq.deinit();

    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 10));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 20));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 30));

    // Rotate to force non-contiguous layout
    dq.rotateLeft(1);

    const slice = try dq.makeContiguous();
    try std.testing.expectEqual(slice.len, 3);
    try std.testing.expectEqual(slice[0].ptr.*, 20);
    try std.testing.expectEqual(slice[1].ptr.*, 30);
    try std.testing.expectEqual(slice[2].ptr.*, 10);
}

test "VecDeque initDefault" {
    var dq = try VecDeque(u32).initDefault(std.testing.allocator);
    defer dq.deinit();
    try std.testing.expect(dq.isEmpty());
}
