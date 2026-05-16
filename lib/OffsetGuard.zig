const std = @import("std");

/// A pointer with bounds information, preventing out-of-bounds access.
/// Wraps a pointer and tracks its parent slice, so all offset operations
/// are bounds-checked.
pub fn OffsetPtr(comptime T: type) type {
    return struct {
        ptr: *T,
        base: [*]T,
        len: usize,

        const Self = @This();

        /// Create from a slice element
        pub fn fromSlice(slice: []T, index: usize) ?Self {
            if (index >= slice.len) return null;
            return .{
                .ptr = &slice[index],
                .base = slice.ptr,
                .len = slice.len,
            };
        }

        /// Offset by n elements. Returns null if out of bounds.
        pub fn offset(self: Self, n: isize) ?Self {
            const current_idx = @intFromPtr(self.ptr) - @intFromPtr(self.base);
            const new_idx = @as(isize, @intCast(current_idx / @sizeOf(T))) + n;
            if (new_idx < 0 or new_idx >= @as(isize, @intCast(self.len))) return null;
            return .{
                .ptr = self.base + @as(usize, @intCast(new_idx)),
                .base = self.base,
                .len = self.len,
            };
        }

        pub fn get(self: Self) *T {
            return self.ptr;
        }

        pub fn getConst(self: Self) *const T {
            return self.ptr;
        }

        /// Check if pointer is within bounds
        pub fn isValid(self: Self) bool {
            const idx = (@intFromPtr(self.ptr) - @intFromPtr(self.base)) / @sizeOf(T);
            return idx >= 0 and idx < self.len;
        }
    };
}

/// A slice with bounds tracking.
/// All sub-slicing operations are checked.
pub fn GuardedSlice(comptime T: type) type {
    return struct {
        ptr: [*]T,
        len: usize,
        capacity: usize,

        const Self = @This();

        pub fn init(buffer: []T) Self {
            return .{
                .ptr = buffer.ptr,
                .len = 0,
                .capacity = buffer.len,
            };
        }

        pub fn fromSlice(data: []T) Self {
            return .{
                .ptr = data.ptr,
                .len = data.len,
                .capacity = data.len,
            };
        }

        pub fn append(self: *Self, value: T) !void {
            if (self.len >= self.capacity) return error.OutOfMemory;
            self.ptr[self.len] = value;
            self.len += 1;
        }

        pub fn get(self: *Self, index: usize) ?T {
            if (index >= self.len) return null;
            return self.ptr[index];
        }

        pub fn getPtr(self: *Self, index: usize) ?*T {
            if (index >= self.len) return null;
            return &self.ptr[index];
        }

        pub fn slice(self: *Self) []T {
            return self.ptr[0..self.len];
        }

        pub fn subSlice(self: *Self, start: usize, end: usize) ?[]T {
            if (start > end or end > self.len) return null;
            return self.ptr[start..end];
        }

        pub fn isFull(self: *Self) bool {
            return self.len >= self.capacity;
        }
    };
}

// ─── Tests ───

test "OffsetPtr fromSlice and offset" {
    const arr = [_]u32{ 10, 20, 30, 40, 50 };
    const slice = arr[0..];

    var op = OffsetPtr(u32).fromSlice(slice, 2);
    try std.testing.expect(op != null);
    try std.testing.expectEqual(op.?.get().*, 30);

    const op_plus1 = op.?.offset(1);
    try std.testing.expect(op_plus1 != null);
    try std.testing.expectEqual(op_plus1.?.get().*, 40);

    const op_minus1 = op.?.offset(-1);
    try std.testing.expect(op_minus1 != null);
    try std.testing.expectEqual(op_minus1.?.get().*, 20);
}

test "OffsetPtr out-of-bounds returns null" {
    const arr = [_]u32{ 10, 20, 30 };
    const slice = arr[0..];

    // fromSlice with out-of-bounds index
    try std.testing.expectEqual(@as(?OffsetPtr(u32), null), OffsetPtr(u32).fromSlice(slice, 5));

    var op = OffsetPtr(u32).fromSlice(slice, 1).?;

    // Positive offset out of bounds
    try std.testing.expectEqual(@as(?OffsetPtr(u32), null), op.offset(3));

    // Negative offset out of bounds
    try std.testing.expectEqual(@as(?OffsetPtr(u32), null), op.offset(-2));
}

test "GuardedSlice append and get" {
    var buffer = [_]u32{ 0, 0, 0 };
    var gs = GuardedSlice(u32).init(&buffer);

    try std.testing.expectEqual(gs.len, 0);
    try std.testing.expectEqual(gs.capacity, 3);

    try gs.append(10);
    try gs.append(20);
    try gs.append(30);

    try std.testing.expectEqual(gs.len, 3);
    try std.testing.expect(gs.isFull());

    // get valid elements
    try std.testing.expectEqual(gs.get(0).?, 10);
    try std.testing.expectEqual(gs.get(1).?, 20);
    try std.testing.expectEqual(gs.get(2).?, 30);

    // get out of bounds
    try std.testing.expectEqual(@as(?u32, null), gs.get(3));

    // append when full fails
    const result = gs.append(40);
    try std.testing.expectError(error.OutOfMemory, result);
}

test "GuardedSlice subSlice bounds checking" {
    var buffer = [_]u32{ 10, 20, 30, 40, 50 };
    var gs = GuardedSlice(u32).fromSlice(&buffer);

    // Valid sub-slice
    const sub = gs.subSlice(1, 4);
    try std.testing.expect(sub != null);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 20, 30, 40 }, sub.?);

    // start > end returns null
    try std.testing.expectEqual(@as(?[]u32, null), gs.subSlice(4, 1));

    // end > len returns null
    try std.testing.expectEqual(@as(?[]u32, null), gs.subSlice(0, 10));

    // Empty sub-slice is valid
    const empty = gs.subSlice(2, 2);
    try std.testing.expect(empty != null);
    try std.testing.expectEqual(@as(usize, 0), empty.?.len);
}
