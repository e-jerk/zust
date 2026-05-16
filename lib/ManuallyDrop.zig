const std = @import("std");
const Box = @import("Box.zig").Box;

/// Wraps a value and prevents automatic drop.
///
/// Pattern: Similar to Rust's `std::mem::ManuallyDrop<T>`.
/// The inner value is only dropped when `drop` or `deinit` is explicitly
/// called, or when `take` moves the value out.
pub fn Type(comptime T: type) type {
    return struct {
        value: T,
        taken: bool = false,

        const Self = @This();

        /// Wrap a value.
        pub fn init(value: T) Self {
            return .{ .value = value };
        }

        /// Immutably borrow the inner value.
        pub fn get(self: *Self) *T {
            std.debug.assert(!self.taken);
            return &self.value;
        }

        /// Mutably borrow the inner value.
        pub fn getMut(self: *Self) *T {
            std.debug.assert(!self.taken);
            return &self.value;
        }

        /// Move the inner value out without dropping it.
        /// After this call the wrapper is considered empty.
        pub fn take(self: *Self) T {
            std.debug.assert(!self.taken);
            self.taken = true;
            return self.value;
        }

        /// Explicitly drop the inner value if it has not been taken.
        pub fn drop(self: *Self) void {
            if (self.taken) return;
            self.taken = true;

            switch (@typeInfo(T)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => {
                    if (@hasDecl(T, "deinit")) {
                        _ = self.value.deinit();
                    }
                },
                else => {},
            }
        }

        /// Standard cleanup – explicitly drops the inner value.
        pub fn deinit(self: *Self) void {
            self.drop();
        }
    };
}

// ─── Tests ───

test "ManuallyDrop basic usage" {
    var md = Type(i32).init(42);
    try std.testing.expectEqual(@as(i32, 42), md.get().*);
    try std.testing.expectEqual(@as(i32, 42), md.getMut().*);
    md.drop();
}

test "ManuallyDrop take" {
    var md = Type(i32).init(42);
    const value = md.take();
    try std.testing.expectEqual(@as(i32, 42), value);
    // After take, drop should be a no-op and not crash.
    md.drop();
}

test "ManuallyDrop with Box" {
    const allocator = std.testing.allocator;
    const box = try Box(i32, 0, 0, 0).init(allocator, 100);
    var md = Type(Box(i32, 0, 0, 0)).init(box);

    // Access the inner Box.
    try std.testing.expectEqual(@as(i32, 100), md.get().ptr.*);

    // Take the Box out.
    var inner_box = md.take();
    defer _ = inner_box.deinit();

    try std.testing.expectEqual(@as(i32, 100), inner_box.ptr.*);

    // ManuallyDrop can now be safely dropped (nothing to drop since taken).
    md.drop();
}

test "ManuallyDrop deinit" {
    var md = Type(i32).init(10);
    md.deinit();
    // deinit after deinit should be harmless.
    md.deinit();
}
