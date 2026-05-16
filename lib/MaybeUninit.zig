const std = @import("std");
const Box = @import("Box.zig").Box;

/// Handles possibly-uninitialized memory.
///
/// Pattern: Similar to Rust's `std::mem::MaybeUninit<T>`.
/// Tracks initialization state with a `bool` flag so that the inner value
/// is only dropped when it was actually written.
pub fn Type(comptime T: type) type {
    return struct {
        value: T = undefined,
        is_init: bool = false,

        const Self = @This();

        /// Create an uninitialized slot.
        pub fn init() Self {
            return .{};
        }

        /// Write a value into the slot, marking it initialized.
        pub fn write(self: *Self, value: T) void {
            self.value = value;
            self.is_init = true;
        }

        /// Obtain a pointer to the inner value.
        /// Caller must know the slot is initialized.
        pub fn assumeInit(self: *Self) *T {
            std.debug.assert(self.is_init);
            return &self.value;
        }

        /// Read the inner value (Copy types only, for safe read).
        /// Caller must know the slot is initialized.
        pub fn assumeInitRead(self: *Self) T {
            std.debug.assert(self.is_init);
            return self.value;
        }

        /// If initialized, drop the inner value.
        pub fn deinit(self: *Self) void {
            if (self.is_init) {
                switch (@typeInfo(T)) {
                    .@"struct", .@"union", .@"enum", .@"opaque" => {
                        if (@hasDecl(T, "deinit")) {
                            _ = self.value.deinit();
                        }
                    },
                    else => {},
                }
                self.is_init = false;
            }
        }
    };
}

// ─── Tests ───

test "MaybeUninit write and read" {
    var mu = Type(i32).init();
    mu.write(42);
    try std.testing.expectEqual(@as(i32, 42), mu.assumeInit().*);
    try std.testing.expectEqual(@as(i32, 42), mu.assumeInitRead());
    mu.deinit();
}

test "MaybeUninit with heap value" {
    const allocator = std.testing.allocator;
    var mu = Type(Box(i32, 0, 0, 0)).init();
    const box = try Box(i32, 0, 0, 0).init(allocator, 100);
    mu.write(box);

    try std.testing.expectEqual(@as(i32, 100), mu.assumeInit().ptr.*);

    // deinit should drop the inner Box.
    mu.deinit();
}

test "MaybeUninit deinit without init" {
    var mu = Type(i32).init();
    // Never initialized – deinit must be a no-op.
    mu.deinit();
}

test "MaybeUninit struct value" {
    const Point = struct {
        x: i32,
        y: i32,
    };

    var mu = Type(Point).init();
    mu.write(.{ .x = 1, .y = 2 });
    try std.testing.expectEqual(@as(i32, 1), mu.assumeInit().x);
    try std.testing.expectEqual(@as(i32, 2), mu.assumeInit().y);
    mu.deinit();
}
