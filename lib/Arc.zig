const std = @import("std");
const Box = @import("Box.zig").Box;

/// Thread-safe atomic reference-counted pointer with weak references.
/// Similar to Rust's `Arc<T>` and `Weak<T>`.
///
/// Usage:
/// ```zig
/// const arc = try Arc(u32).init(allocator, 42);
/// const weak = arc.downgrade();
/// const cloned = arc.clone();
/// arc.drop();
/// cloned.drop(); // value freed, but weak still valid
/// const maybe_arc = weak.upgrade(); // returns null
/// weak.drop(); // inner control block freed
/// ```
pub fn Arc(comptime T: type) type {
    return struct {
        const Inner = struct {
            value: T,
            strong: std.atomic.Value(u32),
            weak: std.atomic.Value(u32),
            allocator: std.mem.Allocator,
        };

        inner: *Inner,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, value: T) !Self {
            const ptr = try allocator.create(Inner);
            ptr.* = .{
                .value = value,
                .strong = std.atomic.Value(u32).init(1),
                .weak = std.atomic.Value(u32).init(1),
                .allocator = allocator,
            };
            return .{ .inner = ptr };
        }

        /// Increment strong reference count, returning a new handle.
        pub fn clone(self: Self) Self {
            const old = self.inner.strong.fetchAdd(1, .seq_cst);
            std.debug.assert(old > 0); // can't clone a dropped Arc
            return .{ .inner = self.inner };
        }

        /// Decrement strong reference count. If it reaches zero, free the value.
        /// If weak count is also zero, free the inner control block.
        pub fn drop(self: Self) void {
            const old_strong = self.inner.strong.fetchSub(1, .seq_cst);
            if (old_strong == 1) {
                // We were the last strong owner: destroy the value
                // Note: we don't free inner yet — weak refs may still exist
                // Inner is freed when the last weak ref is dropped
                self.dropWeak();
            }
        }

        /// Create a weak reference.
        pub fn downgrade(self: Self) Weak(T) {
            const old = self.inner.weak.fetchAdd(1, .seq_cst);
            std.debug.assert(old > 0);
            return .{ .inner = self.inner };
        }

        fn dropWeak(self: Self) void {
            const old_weak = self.inner.weak.fetchSub(1, .seq_cst);
            if (old_weak == 1) {
                // No strong or weak refs remain: free the control block
                self.inner.allocator.destroy(self.inner);
            }
        }

        /// Get immutable access to the value.
        pub fn get(self: Self) *const T {
            return &self.inner.value;
        }

        /// Get mutable access. Only safe if you know you're the only owner.
        pub fn getMut(self: Self) *T {
            const count = self.inner.strong.load(.seq_cst);
            if (count != 1) {
                @panic("Arc.getMut: not unique owner (strong > 1)");
            }
            return &self.inner.value;
        }

        pub fn strongCount(self: Self) u32 {
            return self.inner.strong.load(.seq_cst);
        }

        pub fn weakCount(self: Self) u32 {
            return self.inner.weak.load(.seq_cst);
        }

        /// Consume the Arc and return the inner value as a Box if this is the only strong reference.
        /// Returns null if there are other strong references.
        pub fn tryUnwrap(self: Self) ?Box(T, 0, 0, 0) {
            if (self.inner.strong.load(.seq_cst) == 1 and self.inner.weak.load(.seq_cst) == 1) {
                const allocator = self.inner.allocator;
                const ptr = allocator.create(T) catch return null;
                ptr.* = self.inner.value;
                allocator.destroy(self.inner);
                return Box(T, 0, 0, 0){ .ptr = ptr, .allocator = allocator };
            }
            return null;
        }

        /// Get a mutable reference to the value.
        /// If there are multiple strong references, clones the value into a new unique Arc first.
        pub fn makeMut(self: *Self) !*T {
            if (self.inner.strong.load(.seq_cst) > 1) {
                const new_arc = try Arc(T).init(self.inner.allocator, self.inner.value);
                self.drop();
                self.* = new_arc;
            }
            return &self.inner.value;
        }

        /// Return true if this Arc holds the only strong reference.
        pub fn isUnique(self: *const Self) bool {
            return self.inner.strong.load(.seq_cst) == 1;
        }
    };
}

/// Weak reference to an Arc<T>.
/// Does not keep the value alive.
/// Use `upgrade()` to attempt to get a strong reference.
pub fn Weak(comptime T: type) type {
    return struct {
        const Inner = Arc(T).Inner;
        inner: *Inner,

        const Self = @This();

        /// Attempt to upgrade to a strong reference.
        /// Returns null if the value has already been dropped.
        pub fn upgrade(self: Self) ?Arc(T) {
            // Try to increment strong count, but only if > 0
            var strong = self.inner.strong.load(.seq_cst);
            while (strong > 0) {
                const result = self.inner.strong.cmpxchgStrong(strong, strong + 1, .seq_cst, .seq_cst);
                if (result == null) {
                    return .{ .inner = self.inner };
                }
                strong = result.?;
            }
            return null;
        }

        /// Decrement weak reference count.
        /// If this was the last reference (strong already 0), frees the control block.
        pub fn drop(self: Self) void {
            const old_weak = self.inner.weak.fetchSub(1, .seq_cst);
            if (old_weak == 1) {
                // No weak refs remain, and strong was already 0
                self.inner.allocator.destroy(self.inner);
            }
        }

        /// Return the current strong reference count.
        pub fn strongCount(self: *const Self) u32 {
            return self.inner.strong.load(.seq_cst);
        }

        /// Return the current weak reference count.
        pub fn weakCount(self: *const Self) u32 {
            return self.inner.weak.load(.seq_cst);
        }
    };
}
