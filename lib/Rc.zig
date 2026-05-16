const std = @import("std");
const Box = @import("Box.zig").Box;

/// Single-threaded reference-counted ownership of a heap value.
/// Similar to Rust's `Rc<T>` — cheaper than `Arc<T>` when thread-safety is not needed.
///
/// When the last reference is dropped, the value is freed.
pub fn Rc(comptime T: type) type {
    return struct {
        ptr: *T,
        refcount: *usize,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, value: T) !Self {
            const ptr = try allocator.create(T);
            ptr.* = value;
            const refcount = try allocator.create(usize);
            refcount.* = 1;
            return .{
                .ptr = ptr,
                .refcount = refcount,
                .allocator = allocator,
            };
        }

        pub fn clone(self: Self) Self {
            self.refcount.* += 1;
            return .{
                .ptr = self.ptr,
                .refcount = self.refcount,
                .allocator = self.allocator,
            };
        }

        pub fn drop(self: Self) void {
            self.refcount.* -= 1;
            if (self.refcount.* == 0) {
                self.allocator.destroy(self.ptr);
                self.allocator.destroy(self.refcount);
            }
        }

        pub fn get(self: Self) *const T {
            return self.ptr;
        }

        pub fn getMut(self: Self) *T {
            // Only allow mutable access if refcount == 1 (unique ownership)
            if (self.refcount.* > 1) {
                @panic("cannot get mutable reference: Rc has multiple active references");
            }
            return self.ptr;
        }

        pub fn strongCount(self: Self) usize {
            return self.refcount.*;
        }

        /// Consume the Rc and return the inner value as a Box if this is the only reference.
        /// Returns null if there are other references.
        pub fn tryUnwrap(self: Self) ?Box(T, 0, 0, 0) {
            if (self.refcount.* == 1) {
                const ptr = self.allocator.create(T) catch return null;
                ptr.* = self.ptr.*;
                self.allocator.destroy(self.ptr);
                self.allocator.destroy(self.refcount);
                return Box(T, 0, 0, 0){ .ptr = ptr, .allocator = self.allocator };
            }
            return null;
        }

        /// Get a mutable reference to the value.
        /// If there are multiple references, clones the value into a new unique Rc first.
        pub fn makeMut(self: *Self) !*T {
            if (self.refcount.* > 1) {
                const new_rc = try Rc(T).init(self.allocator, self.ptr.*);
                self.drop();
                self.* = new_rc;
            }
            return self.ptr;
        }

        /// Return true if this Rc holds the only reference.
        pub fn isUnique(self: *const Self) bool {
            return self.refcount.* == 1;
        }
    };
}
