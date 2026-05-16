const std = @import("std");
const SimdUtils = @import("SimdUtils.zig");

/// A fixed-capacity ring buffer (circular buffer).
/// Producer writes, consumer reads. Overwrite mode or blocking mode.
///
/// Usage:
/// ```zig
/// var rb = try RingBuffer(u8).init(allocator, 1024);
/// defer rb.deinit(allocator);
/// try rb.write(&[_]u8{1, 2, 3});
/// const data = rb.read(2).?; // returns 2 bytes
/// ```
pub fn RingBuffer(comptime T: type) type {
    return struct {
        buffer: []T,
        head: usize, // Read position
        tail: usize, // Write position
        count: usize, // Number of items in buffer

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, cap: usize) !Self {
            const buf = try allocator.alloc(T, cap);
            return .{
                .buffer = buf,
                .head = 0,
                .tail = 0,
                .count = 0,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
        }

        pub fn capacity(self: *Self) usize {
            return self.buffer.len;
        }

        pub fn len(self: *Self) usize {
            return self.count;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.count == 0;
        }

        pub fn isFull(self: *Self) bool {
            return self.count >= self.buffer.len;
        }

        pub fn available(self: *Self) usize {
            return self.buffer.len - self.count;
        }

        /// Write a single item. Returns error.BufferFull if no space.
        pub fn write(self: *Self, value: T) !void {
            if (self.isFull()) return error.BufferFull;
            self.buffer[self.tail] = value;
            self.tail = (self.tail + 1) % self.buffer.len;
            self.count += 1;
        }

        /// Write a slice. Returns number of items written.
        pub fn writeSlice(self: *Self, values: []const T) !usize {
            // SIMD fast path: non-wrapping contiguous byte region
            if (@sizeOf(T) == 1 and values.len <= self.available() and self.tail + values.len <= self.buffer.len) {
                const dst = @as([*]u8, @ptrCast(self.buffer.ptr))[self.tail .. self.tail + values.len];
                const src = @as([*]const u8, @ptrCast(values.ptr))[0..values.len];
                SimdUtils.copy(dst, src);
                self.tail += values.len;
                self.count += values.len;
                return values.len;
            }

            var written: usize = 0;
            for (values) |v| {
                if (self.isFull()) break;
                try self.write(v);
                written += 1;
            }
            return written;
        }

        /// Read a single item. Returns null if empty.
        pub fn read(self: *Self) ?T {
            if (self.isEmpty()) return null;
            const value = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.count -= 1;
            return value;
        }

        /// Read up to `n` items into caller-provided buffer.
        /// Returns number of items read.
        pub fn readInto(self: *Self, dest: []T) usize {
            // SIMD fast path: non-wrapping contiguous byte region
            if (@sizeOf(T) == 1 and self.head < self.tail) {
                const copy_len = @min(dest.len, self.count);
                const src = @as([*]const u8, @ptrCast(self.buffer.ptr))[self.head .. self.head + copy_len];
                const dst = @as([*]u8, @ptrCast(dest.ptr))[0..copy_len];
                SimdUtils.copy(dst, src);
                self.head += copy_len;
                self.count -= copy_len;
                return copy_len;
            }

            var read_count: usize = 0;
            for (dest) |*slot| {
                if (self.isEmpty()) break;
                slot.* = self.read().?;
                read_count += 1;
            }
            return read_count;
        }

        /// Peek at the next item without removing it.
        pub fn peek(self: *Self) ?T {
            if (self.isEmpty()) return null;
            return self.buffer[self.head];
        }

        /// Clear all items.
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.count = 0;
        }

        /// Overwrite mode: if full, overwrite oldest item.
        pub fn writeOverwrite(self: *Self, value: T) void {
            self.buffer[self.tail] = value;
            self.tail = (self.tail + 1) % self.buffer.len;
            if (self.isFull()) {
                self.head = (self.head + 1) % self.buffer.len;
            } else {
                self.count += 1;
            }
        }

        /// Get a contiguous slice of readable data (may be shorter than count if wrapped).
        /// Returns a slice into the internal buffer — valid until next write.
        pub fn readableSlice(self: *Self) []T {
            if (self.isEmpty()) return &[_]T{};
            if (self.head < self.tail) {
                return self.buffer[self.head..self.tail];
            }
            // Wrapped case: return from head to end
            return self.buffer[self.head..self.buffer.len];
        }
    };
}

// ─── Tests ───

test "RingBuffer write and read" {
    var rb = try RingBuffer(u8).init(std.testing.allocator, 4);
    defer rb.deinit(std.testing.allocator);

    try rb.write(1);
    try rb.write(2);
    try rb.write(3);

    try std.testing.expectEqual(rb.len(), 3);
    try std.testing.expectEqual(rb.read().?, 1);
    try std.testing.expectEqual(rb.read().?, 2);
    try std.testing.expectEqual(rb.read().?, 3);
    try std.testing.expect(rb.read() == null);
}

test "RingBuffer wrap-around" {
    var rb = try RingBuffer(u8).init(std.testing.allocator, 4);
    defer rb.deinit(std.testing.allocator);

    // Fill buffer
    try rb.write(10);
    try rb.write(20);
    try rb.write(30);
    try rb.write(40);

    // Read two, freeing space at front
    try std.testing.expectEqual(rb.read().?, 10);
    try std.testing.expectEqual(rb.read().?, 20);

    // Write two more, causing wrap-around
    try rb.write(50);
    try rb.write(60);

    // Read remaining in order
    try std.testing.expectEqual(rb.read().?, 30);
    try std.testing.expectEqual(rb.read().?, 40);
    try std.testing.expectEqual(rb.read().?, 50);
    try std.testing.expectEqual(rb.read().?, 60);
    try std.testing.expect(rb.read() == null);
}

test "RingBuffer isFull and isEmpty" {
    var rb = try RingBuffer(u8).init(std.testing.allocator, 2);
    defer rb.deinit(std.testing.allocator);

    try std.testing.expect(rb.isEmpty());
    try std.testing.expect(!rb.isFull());

    try rb.write(1);
    try std.testing.expect(!rb.isEmpty());
    try std.testing.expect(!rb.isFull());

    try rb.write(2);
    try std.testing.expect(!rb.isEmpty());
    try std.testing.expect(rb.isFull());

    _ = rb.read();
    try std.testing.expect(!rb.isEmpty());
    try std.testing.expect(!rb.isFull());

    _ = rb.read();
    try std.testing.expect(rb.isEmpty());
    try std.testing.expect(!rb.isFull());
}

test "RingBuffer writeOverwrite" {
    var rb = try RingBuffer(u8).init(std.testing.allocator, 3);
    defer rb.deinit(std.testing.allocator);

    rb.writeOverwrite(1);
    rb.writeOverwrite(2);
    rb.writeOverwrite(3);
    try std.testing.expectEqual(rb.len(), 3);

    // Overwrite oldest
    rb.writeOverwrite(4);
    try std.testing.expectEqual(rb.len(), 3);

    // Read: oldest (1) should be overwritten by 4
    try std.testing.expectEqual(rb.read().?, 2);
    try std.testing.expectEqual(rb.read().?, 3);
    try std.testing.expectEqual(rb.read().?, 4);
    try std.testing.expect(rb.read() == null);
}

test "RingBuffer readableSlice" {
    var rb = try RingBuffer(u8).init(std.testing.allocator, 8);
    defer rb.deinit(std.testing.allocator);

    // Empty
    try std.testing.expectEqual(rb.readableSlice().len, 0);

    // Non-wrapped
    try rb.write(1);
    try rb.write(2);
    try rb.write(3);
    const s1 = rb.readableSlice();
    try std.testing.expectEqual(s1.len, 3);
    try std.testing.expectEqual(s1[0], 1);
    try std.testing.expectEqual(s1[1], 2);
    try std.testing.expectEqual(s1[2], 3);

    // Wrapped: read one, write past end
    _ = rb.read();
    try rb.write(4);
    try rb.write(5);
    try rb.write(6);
    try rb.write(7);
    try rb.write(8);

    // Now head is at 1, tail wrapped around
    const s2 = rb.readableSlice();
    // readableSlice returns contiguous data from head to end of buffer
    try std.testing.expect(s2.len >= 1);
    try std.testing.expectEqual(s2[0], 2);
}
