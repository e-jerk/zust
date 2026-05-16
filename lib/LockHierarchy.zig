const std = @import("std");
const safe = @import("safe.zig");

// Module-level threadlocal tracking for OrderedMutex ordering enforcement.
// Each thread maintains its own stack of currently held lock orders.
threadlocal var held_orders: [16]u32 = undefined;
threadlocal var held_count: usize = 0;

/// A mutex with a compile-time lock order. Enforces that locks are acquired
/// in monotonically non-decreasing order within a single thread, preventing
/// circular deadlocks at compile/run time.
///
/// Same-order nested locks are allowed (useful for read-lock patterns).
pub fn OrderedMutex(comptime order: u32, comptime T: type) type {
    return struct {
        mutex: safe.Mutex(T),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, value: T) !Self {
            return .{
                .mutex = try safe.Mutex(T).init(allocator, value),
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.deinit();
        }

        /// Acquire the lock, verifying that this thread holds no locks with
        /// a strictly greater order. Returns an error if acquiring this lock
        /// would violate the established hierarchy.
        pub fn acquire(self: *Self) !OrderedMutexGuard(order, T) {
            // Check ordering: new order must be >= all currently held orders.
            // (allow same-order for nested / read-lock patterns)
            for (0..held_count) |i| {
                if (order < held_orders[i]) {
                    return error.LockOrderViolation;
                }
            }

            const guard = self.mutex.acquire();

            // Record this lock as held
            if (held_count < held_orders.len) {
                held_orders[held_count] = order;
                held_count += 1;
            } else {
                // Too many nested locks — release and error
                guard.deinit();
                return error.LockOrderOverflow;
            }

            return .{ .inner = guard };
        }
    };
}

/// RAII guard for OrderedMutex. Automatically removes the order from the
/// thread-local held set when dropped.
pub fn OrderedMutexGuard(comptime order: u32, comptime T: type) type {
    return struct {
        inner: safe.MutexGuard(T),

        const Self = @This();

        pub fn deinit(self: Self) void {
            // Remove one instance of this order from held_orders (swap-remove).
            var found = false;
            for (0..held_count) |i| {
                if (held_orders[i] == order) {
                    held_orders[i] = held_orders[held_count - 1];
                    held_count -= 1;
                    found = true;
                    break;
                }
            }
            if (!found) {
                @panic("OrderedMutexGuard deinit: order not found in held_orders");
            }
            self.inner.deinit();
        }

        pub fn get(self: Self) *const T {
            return self.inner.get();
        }

        pub fn getMut(self: Self) *T {
            return self.inner.getMut();
        }
    };
}

/// A mutex that panics (returns error) if the same thread tries to lock it
/// twice, preventing recursive deadlock bugs.
pub fn NonReentrantMutex(comptime T: type) type {
    return struct {
        mutex: safe.Mutex(T),
        owner: std.atomic.Value(u64),

        const Self = @This();
        const NO_OWNER: u64 = std.math.maxInt(u64);

        pub fn init(allocator: std.mem.Allocator, value: T) !Self {
            return .{
                .mutex = try safe.Mutex(T).init(allocator, value),
                .owner = std.atomic.Value(u64).init(NO_OWNER),
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.deinit();
        }

        /// Acquire the lock. Returns `error.RecursiveLock` if the current
        /// thread already owns this mutex.
        pub fn acquire(self: *Self) !NonReentrantMutexGuard(T) {
            const current = @as(u64, @intCast(std.Thread.getCurrentId()));

            // Pre-check: if we already own this mutex, it's recursive.
            if (self.owner.load(.acquire) == current) {
                return error.RecursiveLock;
            }

            const guard = self.mutex.acquire();
            self.owner.store(current, .release);
            return .{ .inner = guard, .mutex = self };
        }
    };
}

/// RAII guard for NonReentrantMutex. Clears the owner field on drop so
/// another thread (or the same thread later) may acquire the lock.
pub fn NonReentrantMutexGuard(comptime T: type) type {
    return struct {
        inner: safe.MutexGuard(T),
        mutex: *NonReentrantMutex(T),

        const Self = @This();

        pub fn deinit(self: Self) void {
            self.mutex.owner.store(std.math.maxInt(u64), .release);
            self.inner.deinit();
        }

        pub fn get(self: Self) *const T {
            return self.inner.get();
        }

        pub fn getMut(self: Self) *T {
            return self.inner.getMut();
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "OrderedMutex allows ordered locking" {
    var mtx1 = try OrderedMutex(1, u32).init(std.testing.allocator, 10);
    defer mtx1.deinit();
    var mtx2 = try OrderedMutex(2, u32).init(std.testing.allocator, 20);
    defer mtx2.deinit();

    const g1 = try mtx1.acquire();
    const g2 = try mtx2.acquire();
    try std.testing.expectEqual(g1.get().*, 10);
    try std.testing.expectEqual(g2.get().*, 20);
    g2.deinit();
    g1.deinit();
}

test "OrderedMutex rejects out-of-order lock" {
    var mtx1 = try OrderedMutex(1, u32).init(std.testing.allocator, 10);
    defer mtx1.deinit();
    var mtx2 = try OrderedMutex(2, u32).init(std.testing.allocator, 20);
    defer mtx2.deinit();

    const g2 = try mtx2.acquire();
    defer g2.deinit();

    const result = mtx1.acquire();
    try std.testing.expectError(error.LockOrderViolation, result);
}

test "OrderedMutex allows nested same-order" {
    var mtx1a = try OrderedMutex(1, u32).init(std.testing.allocator, 10);
    defer mtx1a.deinit();
    var mtx1b = try OrderedMutex(1, u32).init(std.testing.allocator, 20);
    defer mtx1b.deinit();

    const g1 = try mtx1a.acquire();
    const g2 = try mtx1b.acquire();
    try std.testing.expectEqual(g1.get().*, 10);
    try std.testing.expectEqual(g2.get().*, 20);
    g2.deinit();
    g1.deinit();
}

test "NonReentrantMutex allows normal lock" {
    var mtx = try NonReentrantMutex(u32).init(std.testing.allocator, 42);
    defer mtx.deinit();

    const g = try mtx.acquire();
    try std.testing.expectEqual(g.get().*, 42);
    g.deinit();
}

test "NonReentrantMutex rejects recursive lock" {
    var mtx = try NonReentrantMutex(u32).init(std.testing.allocator, 42);
    defer mtx.deinit();

    const g = try mtx.acquire();
    defer g.deinit();

    const result = mtx.acquire();
    try std.testing.expectError(error.RecursiveLock, result);
}

test "NonReentrantMutex different threads can lock" {
    var mtx = try NonReentrantMutex(u32).init(std.testing.allocator, 100);
    defer mtx.deinit();

    const g = try mtx.acquire();
    try std.testing.expectEqual(g.get().*, 100);
    g.deinit();

    var thread_got_lock = false;
    const thread = try std.Thread.spawn(.{}, struct {
        fn f(m: *NonReentrantMutex(u32), got_lock: *bool) void {
            const g2 = m.acquire() catch return;
            got_lock.* = true;
            g2.deinit();
        }
    }.f, .{ &mtx, &thread_got_lock });
    thread.join();

    try std.testing.expect(thread_got_lock);
}
