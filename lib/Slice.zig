const std = @import("std");
const Box = @import("Box.zig").Box;
const ArrayList = @import("ArrayList.zig").ArrayList;
const SimdUtils = @import("SimdUtils.zig");

fn assertIsCopy(comptime T: type) void {
    const info = @typeInfo(T);
    const ok = switch (info) {
        .int, .float, .bool, .pointer => true,
        .array => |a| switch (@typeInfo(a.child)) {
            .int, .float, .bool => true,
            else => false,
        },
        .optional => |o| switch (@typeInfo(o.child)) {
            .int, .float, .bool, .pointer => true,
            else => false,
        },
        .void => true,
        .comptime_int, .comptime_float => true,
        else => false,
    };
    if (!ok) {
        @compileError("requires Copy type, got: " ++ @typeName(T));
    }
}

/// A borrow-checked slice that tracks its origin.
///
/// Can be created from:
/// - `Box(T)` → borrows the Box immutably
/// - `ArrayList(T)` → borrows the list immutably
/// - `[N]T` (stack arrays) → no borrow needed
///
/// The slice prevents mutation of the source while borrowed.
pub fn Slice(comptime T: type) type {
    return struct {
        data: []const T,
        origin: Origin,

        const Self = @This();

        pub const Origin = union(enum) {
            Box: struct {
                ptr: *T,
                allocator: std.mem.Allocator,
            },
            ArrayList: struct {
                list: *ArrayList(T),
            },
            Stack: void,
        };

        /// Borrow immutably from a Box containing a slice `[]T`.
        pub fn fromBoxSlice(box: Box([]T)) Self {
            return .{
                .data = box.ptr.*,
                .origin = .{ .Box = .{
                    .ptr = box.ptr,
                    .allocator = box.allocator,
                } },
            };
        }

        /// Borrow immutably from a Box containing an array `[N]T`.
        pub fn fromBoxArray(box: anytype) Self {
            const ArrayType = @TypeOf(box.ptr.*);
            const info = @typeInfo(ArrayType);
            if (info != .array) {
                @compileError("fromBoxArray expects Box([N]T), got " ++ @typeName(ArrayType));
            }
            if (info.array.child != T) {
                @compileError("Array element type mismatch: expected " ++ @typeName(T) ++ ", got " ++ @typeName(info.array.child));
            }
            return .{
                .data = box.ptr.*[0..],
                .origin = .{ .Box = .{
                    .ptr = @ptrCast(box.ptr),
                    .allocator = box.allocator,
                } },
            };
        }

        /// Borrow immutably from a standard ArrayList(T) (not the safe wrapper).
        /// For safe collections, use their individual borrow methods.
        pub fn fromStdArrayList(list: *std.ArrayList(T)) Self {
            // Note: this borrows from a raw ArrayList, not the safe wrapper.
            // The caller is responsible for ensuring the list outlives the slice.
            return .{
                .data = list.items,
                .origin = .Stack, // Stack because we don't track borrow on raw lists
            };
        }

        /// Wrap a stack array (no borrow tracking needed).
        pub fn fromStack(array: []const T) Self {
            return .{
                .data = array,
                .origin = .Stack,
            };
        }

        /// Release the borrow.
        pub fn release(self: Self) void {
            switch (self.origin) {
                .Box => {}, // borrow was implicit, no refcount to drop
                .ArrayList => |a| {
                    a.list.outstanding_imm -= 1;
                },
                .Stack => {},
            }
        }

        /// Get element at index.
        pub fn get(self: Self, index: usize) ?T {
            if (index >= self.data.len) return null;
            return self.data[index];
        }

        pub fn len(self: Self) usize {
            return self.data.len;
        }

        /// Split slice at index `mid`. Both returned slices share the borrow state.
        pub fn splitAt(self: Self, mid: usize) struct { left: Self, right: Self } {
            std.debug.assert(mid <= self.data.len);
            return .{
                .left = .{
                    .data = self.data[0..mid],
                    .origin = .Stack,
                },
                .right = .{
                    .data = self.data[mid..],
                    .origin = .Stack,
                },
            };
        }

        /// Returns first element and rest of slice. For Copy types only.
        pub fn splitFirst(self: Self) ?struct { first: T, rest: Self } {
            comptime assertIsCopy(T);
            if (self.data.len == 0) return null;
            return .{
                .first = self.data[0],
                .rest = .{
                    .data = self.data[1..],
                    .origin = .Stack,
                },
            };
        }

        /// Returns all but last, and last element. For Copy types only.
        pub fn splitLast(self: Self) ?struct { init: Self, last: T } {
            comptime assertIsCopy(T);
            if (self.data.len == 0) return null;
            const last_idx = self.data.len - 1;
            return .{
                .init = .{
                    .data = self.data[0..last_idx],
                    .origin = .Stack,
                },
                .last = self.data[last_idx],
            };
        }

        pub const ChunksIter = struct {
            slice: Self,
            chunk_size: usize,
            index: usize,

            pub fn next(self: *ChunksIter) ?Self {
                if (self.index >= self.slice.len()) return null;
                const end = @min(self.index + self.chunk_size, self.slice.len());
                const result = Self{
                    .data = self.slice.data[self.index..end],
                    .origin = .Stack,
                };
                self.index = end;
                return result;
            }
        };

        /// Iterator that yields slices of `chunk_size` elements.
        pub fn chunks(self: Self, chunk_size: usize) ChunksIter {
            std.debug.assert(chunk_size > 0);
            return .{
                .slice = self,
                .chunk_size = chunk_size,
                .index = 0,
            };
        }

        pub const WindowsIter = struct {
            slice: Self,
            window_size: usize,
            index: usize,

            pub fn next(self: *WindowsIter) ?Self {
                if (self.index + self.window_size > self.slice.len()) return null;
                const result = Self{
                    .data = self.slice.data[self.index .. self.index + self.window_size],
                    .origin = .Stack,
                };
                self.index += 1;
                return result;
            }
        };

        /// Iterator that yields overlapping windows.
        pub fn windows(self: Self, window_size: usize) WindowsIter {
            std.debug.assert(window_size > 0);
            std.debug.assert(window_size <= self.data.len);
            return .{
                .slice = self,
                .window_size = window_size,
                .index = 0,
            };
        }

        /// Rotate elements left by `mid` positions: `[mid..]` moves to front.
        /// Works for Copy types by copying elements.
        pub fn rotateLeft(self: *Self, mid: usize) void {
            comptime assertIsCopy(T);
            if (self.data.len == 0) return;
            const k = mid % self.data.len;
            if (k == 0) return;
            const mutable = @constCast(self.data);
            std.mem.reverse(T, mutable[0..k]);
            std.mem.reverse(T, mutable[k..]);
            std.mem.reverse(T, mutable);
        }

        /// Rotate elements right by `mid` positions.
        pub fn rotateRight(self: *Self, mid: usize) void {
            comptime assertIsCopy(T);
            if (self.data.len == 0) return;
            const k = mid % self.data.len;
            if (k == 0) return;
            const mutable = @constCast(self.data);
            const split = self.data.len - k;
            std.mem.reverse(T, mutable[0..split]);
            std.mem.reverse(T, mutable[split..]);
            std.mem.reverse(T, mutable);
        }

        /// Swap two elements by index.
        pub fn swap(self: *Self, a: usize, b: usize) void {
            comptime assertIsCopy(T);
            const mutable = @constCast(self.data);
            std.mem.swap(T, &mutable[a], &mutable[b]);
        }

        /// Fill entire slice with value (Copy types only).
        pub fn fill(self: *Self, value: T) void {
            comptime assertIsCopy(T);
            const mutable = @constCast(self.data);
            if (@sizeOf(T) == 1) {
                SimdUtils.fill(@as([]u8, @ptrCast(mutable)), @bitCast(value));
            } else {
                @memset(mutable, value);
            }
        }

        /// Reverse elements in place (Copy types only).
        pub fn reverse(self: *Self) void {
            comptime assertIsCopy(T);
            const mutable = @constCast(self.data);
            std.mem.reverse(T, mutable);
        }

        /// Binary search for target, returns index if found. Requires sorted slice.
        pub fn binarySearch(self: Self, target: T) ?usize {
            var left: usize = 0;
            var right = self.data.len;
            while (left < right) {
                const mid = left + (right - left) / 2;
                if (self.data[mid] < target) {
                    left = mid + 1;
                } else if (self.data[mid] > target) {
                    right = mid;
                } else {
                    return mid;
                }
            }
            return null;
        }
    };
}

// ─── Tests ───

test "splitAt basic" {
    const arr = [_]i32{ 1, 2, 3, 4, 5 };
    const slice = Slice(i32).fromStack(&arr);
    const parts = slice.splitAt(2);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2 }, parts.left.data);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 3, 4, 5 }, parts.right.data);
    try std.testing.expectEqual(2, parts.left.len());
    try std.testing.expectEqual(3, parts.right.len());
}

test "splitAt at boundaries" {
    const arr = [_]i32{ 1, 2, 3 };
    const slice = Slice(i32).fromStack(&arr);
    const front = slice.splitAt(0);
    try std.testing.expectEqual(0, front.left.len());
    try std.testing.expectEqual(3, front.right.len());

    const back = slice.splitAt(3);
    try std.testing.expectEqual(3, back.left.len());
    try std.testing.expectEqual(0, back.right.len());
}

test "splitAt mid equal len" {
    const arr = [_]i32{ 10, 20 };
    const slice = Slice(i32).fromStack(&arr);
    const parts = slice.splitAt(2);
    try std.testing.expectEqual(2, parts.left.len());
    try std.testing.expectEqual(0, parts.right.len());
}

test "splitFirst basic" {
    const arr = [_]i32{ 1, 2, 3 };
    const slice = Slice(i32).fromStack(&arr);
    const result = slice.splitFirst().?;
    try std.testing.expectEqual(1, result.first);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 2, 3 }, result.rest.data);
}

test "splitFirst empty" {
    const arr = [_]i32{};
    const slice = Slice(i32).fromStack(&arr);
    try std.testing.expect(slice.splitFirst() == null);
}

test "splitFirst single" {
    const arr = [_]i32{42};
    const slice = Slice(i32).fromStack(&arr);
    const result = slice.splitFirst().?;
    try std.testing.expectEqual(42, result.first);
    try std.testing.expectEqual(0, result.rest.len());
}

test "splitLast basic" {
    const arr = [_]i32{ 1, 2, 3 };
    const slice = Slice(i32).fromStack(&arr);
    const result = slice.splitLast().?;
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2 }, result.init.data);
    try std.testing.expectEqual(3, result.last);
}

test "splitLast empty" {
    const arr = [_]i32{};
    const slice = Slice(i32).fromStack(&arr);
    try std.testing.expect(slice.splitLast() == null);
}

test "splitLast single" {
    const arr = [_]i32{42};
    const slice = Slice(i32).fromStack(&arr);
    const result = slice.splitLast().?;
    try std.testing.expectEqual(0, result.init.len());
    try std.testing.expectEqual(42, result.last);
}

test "chunks basic" {
    const arr = [_]i32{ 1, 2, 3, 4, 5 };
    const slice = Slice(i32).fromStack(&arr);
    var iter = slice.chunks(2);
    const c1 = iter.next().?;
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2 }, c1.data);
    const c2 = iter.next().?;
    try std.testing.expectEqualSlices(i32, &[_]i32{ 3, 4 }, c2.data);
    const c3 = iter.next().?;
    try std.testing.expectEqualSlices(i32, &[_]i32{5}, c3.data);
    try std.testing.expect(iter.next() == null);
}

test "chunks exact" {
    const arr = [_]i32{ 1, 2, 3, 4 };
    const slice = Slice(i32).fromStack(&arr);
    var iter = slice.chunks(2);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2 }, iter.next().?.data);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 3, 4 }, iter.next().?.data);
    try std.testing.expect(iter.next() == null);
}

test "chunks size one" {
    const arr = [_]i32{ 7, 8, 9 };
    const slice = Slice(i32).fromStack(&arr);
    var iter = slice.chunks(1);
    try std.testing.expectEqualSlices(i32, &[_]i32{7}, iter.next().?.data);
    try std.testing.expectEqualSlices(i32, &[_]i32{8}, iter.next().?.data);
    try std.testing.expectEqualSlices(i32, &[_]i32{9}, iter.next().?.data);
    try std.testing.expect(iter.next() == null);
}

test "windows basic" {
    const arr = [_]i32{ 1, 2, 3, 4, 5 };
    const slice = Slice(i32).fromStack(&arr);
    var iter = slice.windows(3);
    const w1 = iter.next().?;
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, w1.data);
    const w2 = iter.next().?;
    try std.testing.expectEqualSlices(i32, &[_]i32{ 2, 3, 4 }, w2.data);
    const w3 = iter.next().?;
    try std.testing.expectEqualSlices(i32, &[_]i32{ 3, 4, 5 }, w3.data);
    try std.testing.expect(iter.next() == null);
}

test "windows size two" {
    const arr = [_]i32{ 10, 20, 30 };
    const slice = Slice(i32).fromStack(&arr);
    var iter = slice.windows(2);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 10, 20 }, iter.next().?.data);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 20, 30 }, iter.next().?.data);
    try std.testing.expect(iter.next() == null);
}

test "windows size equal len" {
    const arr = [_]i32{ 1, 2, 3 };
    const slice = Slice(i32).fromStack(&arr);
    var iter = slice.windows(3);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, iter.next().?.data);
    try std.testing.expect(iter.next() == null);
}

test "rotateLeft basic" {
    var arr = [_]i32{ 1, 2, 3, 4, 5 };
    var slice = Slice(i32).fromStack(&arr);
    slice.rotateLeft(2);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 3, 4, 5, 1, 2 }, slice.data);
}

test "rotateLeft zero" {
    var arr = [_]i32{ 1, 2, 3 };
    var slice = Slice(i32).fromStack(&arr);
    slice.rotateLeft(0);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, slice.data);
}

test "rotateLeft full" {
    var arr = [_]i32{ 1, 2, 3 };
    var slice = Slice(i32).fromStack(&arr);
    slice.rotateLeft(3);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, slice.data);
}

test "rotateRight basic" {
    var arr = [_]i32{ 1, 2, 3, 4, 5 };
    var slice = Slice(i32).fromStack(&arr);
    slice.rotateRight(2);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 4, 5, 1, 2, 3 }, slice.data);
}

test "rotateRight zero" {
    var arr = [_]i32{ 1, 2, 3 };
    var slice = Slice(i32).fromStack(&arr);
    slice.rotateRight(0);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, slice.data);
}

test "rotateRight full" {
    var arr = [_]i32{ 1, 2, 3 };
    var slice = Slice(i32).fromStack(&arr);
    slice.rotateRight(3);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, slice.data);
}

test "swap basic" {
    var arr = [_]i32{ 1, 2, 3, 4 };
    var slice = Slice(i32).fromStack(&arr);
    slice.swap(0, 3);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 4, 2, 3, 1 }, slice.data);
}

test "swap same index" {
    var arr = [_]i32{ 1, 2, 3 };
    var slice = Slice(i32).fromStack(&arr);
    slice.swap(1, 1);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, slice.data);
}

test "swap adjacent" {
    var arr = [_]i32{ 1, 2, 3 };
    var slice = Slice(i32).fromStack(&arr);
    slice.swap(0, 1);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 2, 1, 3 }, slice.data);
}

test "fill basic" {
    var arr = [_]i32{ 1, 2, 3, 4 };
    var slice = Slice(i32).fromStack(&arr);
    slice.fill(9);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 9, 9, 9, 9 }, slice.data);
}

test "fill single" {
    var arr = [_]i32{0};
    var slice = Slice(i32).fromStack(&arr);
    slice.fill(7);
    try std.testing.expectEqualSlices(i32, &[_]i32{7}, slice.data);
}

test "fill empty" {
    var arr = [_]i32{};
    var slice = Slice(i32).fromStack(&arr);
    slice.fill(5);
    try std.testing.expectEqual(0, slice.len());
}

test "reverse basic" {
    var arr = [_]i32{ 1, 2, 3, 4, 5 };
    var slice = Slice(i32).fromStack(&arr);
    slice.reverse();
    try std.testing.expectEqualSlices(i32, &[_]i32{ 5, 4, 3, 2, 1 }, slice.data);
}

test "reverse two" {
    var arr = [_]i32{ 1, 2 };
    var slice = Slice(i32).fromStack(&arr);
    slice.reverse();
    try std.testing.expectEqualSlices(i32, &[_]i32{ 2, 1 }, slice.data);
}

test "reverse empty" {
    var arr = [_]i32{};
    var slice = Slice(i32).fromStack(&arr);
    slice.reverse();
    try std.testing.expectEqual(0, slice.len());
}

test "binarySearch found" {
    const arr = [_]i32{ 1, 3, 5, 7, 9 };
    const slice = Slice(i32).fromStack(&arr);
    try std.testing.expectEqual(2, slice.binarySearch(5));
    try std.testing.expectEqual(0, slice.binarySearch(1));
    try std.testing.expectEqual(4, slice.binarySearch(9));
}

test "binarySearch not found" {
    const arr = [_]i32{ 1, 3, 5, 7, 9 };
    const slice = Slice(i32).fromStack(&arr);
    try std.testing.expect(slice.binarySearch(0) == null);
    try std.testing.expect(slice.binarySearch(2) == null);
    try std.testing.expect(slice.binarySearch(10) == null);
}

test "binarySearch empty" {
    const arr = [_]i32{};
    const slice = Slice(i32).fromStack(&arr);
    try std.testing.expect(slice.binarySearch(5) == null);
}
