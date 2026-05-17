const std = @import("std");
const Box = @import("Box.zig").Box;
const BoxStateful = @import("Box.zig").BoxStateful;

/// Non-lexical lifetime (NLL) scope guards.
///
/// These types automatically release borrows when they go out of scope,
/// providing RAII-style resource management.
///
/// Usage:
/// ```zig
/// const box = try Box(u32).init(allocator, 42);
/// {
///     const scope = Scope.borrowImm(&box);
///     std.debug.print("{d}\n", .{scope.ptr.*});
/// } // borrow automatically released here
/// const dead = box.deinit(); // OK!
/// ```
/// Immutable borrow scope. Releases when deinitialized.
pub fn ScopeImm(comptime T: type) type {
    return struct {
        box: BoxStateful(T, 1, 1, 0),
        owner: ?*Box(T),

        const Self = @This();

        /// Borrow from an owned box.
        pub fn borrow(box: Box(T)) struct {
            scope: Self,
            owner: Box(T),
        } {
            const borrowed = box.borrowImm();
            return .{
                .scope = .{ .box = borrowed, .owner = null },
                .owner = box,
            };
        }

        /// Release the borrow.
        pub fn release(self: *Self) Box(T) {
            const back = self.box.releaseImm();
            self.owner = null;
            return back;
        }

        pub fn ptr(self: Self) *const T {
            return self.box.ptr;
        }
    };
}

/// Mutable borrow scope. Releases when deinitialized.
pub fn ScopeMut(comptime T: type) type {
    return struct {
        box: BoxStateful(T, 2, 0, 1),
        owner: ?*Box(T),

        const Self = @This();

        /// Borrow mutably from an owned box.
        pub fn borrow(box: Box(T)) struct {
            scope: Self,
            owner: Box(T),
        } {
            const borrowed = box.borrowMut();
            return .{
                .scope = .{ .box = borrowed, .owner = null },
                .owner = box,
            };
        }

        /// Release the borrow.
        pub fn release(self: *Self) Box(T) {
            const back = self.box.releaseMut();
            self.owner = null;
            return back;
        }

        pub fn ptr(self: Self) *T {
            return self.box.ptr;
        }
    };
}
