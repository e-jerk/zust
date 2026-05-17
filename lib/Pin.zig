const std = @import("std");
const Box = @import("Box.zig").Box;
const BoxStateful = @import("Box.zig").BoxStateful;

/// Prevents moving values in memory.
///
/// Pattern: Similar to Rust's `std::pin::Pin<Box<T>>`.
/// Wraps a heap-allocated `Box(T)` and guarantees the pointee
/// will not be relocated.  Mutable access is still allowed – only moving
/// is prevented.
pub fn Pin(comptime T: type) type {
    return struct {
        ptr: *T,
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Take ownership of a `Box`.
        pub fn init(box: Box(T)) Self {
            return .{
                .ptr = box.ptr,
                .allocator = box.allocator,
            };
        }

        /// Destroy the owned heap value and return a dead-box token.
        pub fn deinit(self: *Self) BoxStateful(T, 4, 0, 0) {
            self.allocator.destroy(self.ptr);
            return .{
                .ptr = undefined,
                .allocator = self.allocator,
            };
        }

        /// Immutable access to the pinned value.
        pub fn get(self: *Self) *const T {
            return self.ptr;
        }

        /// Mutable access to the pinned value.
        pub fn getMut(self: *Self) *T {
            return self.ptr;
        }

        /// Reborrow as a pinned immutable reference.
        pub fn asRef(self: *Self) *const T {
            return self.ptr;
        }
    };
}

// ─── Tests ───

test "Pin basic usage" {
    const allocator = std.testing.allocator;
    const box = try Box(i32).init(allocator, 42);
    var pin = Pin(i32).init(box);

    try std.testing.expectEqual(@as(i32, 42), pin.get().*);
    try std.testing.expectEqual(@as(i32, 42), pin.getMut().*);

    _ = pin.deinit();
}

test "Pin mutable access" {
    const allocator = std.testing.allocator;
    const box = try Box(i32).init(allocator, 10);
    var pin = Pin(i32).init(box);

    pin.getMut().* = 20;
    try std.testing.expectEqual(@as(i32, 20), pin.get().*);

    _ = pin.deinit();
}

test "Pin asRef" {
    const allocator = std.testing.allocator;
    const box = try Box(i32).init(allocator, 99);
    var pin = Pin(i32).init(box);

    const ref = pin.asRef();
    try std.testing.expectEqual(@as(i32, 99), ref.*);

    _ = pin.deinit();
}

test "Pin with struct" {
    const Point = struct {
        x: i32,
        y: i32,
    };

    const allocator = std.testing.allocator;
    const box = try Box(Point).init(allocator, .{ .x = 1, .y = 2 });
    var pin = Pin(Point).init(box);

    try std.testing.expectEqual(@as(i32, 1), pin.get().x);
    pin.getMut().x = 10;
    try std.testing.expectEqual(@as(i32, 10), pin.get().x);

    _ = pin.deinit();
}
