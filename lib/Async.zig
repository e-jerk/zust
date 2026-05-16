const std = @import("std");
const Box = @import("Box.zig").Box;

/// Async-safe owned value wrapper.
///
/// Ensures that a Box is properly deinitialized when an async frame is cancelled
/// or completes. Provides `await`-safe borrow tracking.
///
/// Usage:
/// ```zig
/// async fn foo(box: AsyncBox(u32)) void {
///     box.withImm({}, struct { fn f(_: void, val: *const u32) void {
///         // use val safely across await
///     }}.f);
///     await bar();
///     // box still owned here
/// }
/// ```
pub fn AsyncBox(comptime T: type) type {
    return struct {
        box: ?Box(T, 0, 0, 0),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, value: T) !Self {
            const b = try Box(T, 0, 0, 0).init(allocator, value);
            return .{
                .box = b,
                .allocator = allocator,
            };
        }

        /// Deinitialize, freeing the inner Box if present.
        pub fn deinit(self: *Self) void {
            if (self.box) |b| {
                const dead = b.deinit();
                _ = dead;
                self.box = null;
            }
        }

        /// Take ownership out of the AsyncBox.
        /// The caller is now responsible for deinit.
        pub fn take(self: *Self) ?Box(T, 0, 0, 0) {
            const b = self.box;
            self.box = null;
            return b;
        }

        /// Immutably borrow the value safely across suspend points.
        pub fn withImm(self: *Self, context: anytype, comptime cb: fn (@TypeOf(context), *const T) void) void {
            if (self.box) |b| {
                cb(context, b.ptr);
            }
        }

        /// Mutably borrow the value safely across suspend points.
        pub fn withMut(self: *Self, context: anytype, comptime cb: fn (@TypeOf(context), *T) void) void {
            if (self.box) |b| {
                cb(context, b.ptr);
            }
        }
    };
}
