const std = @import("std");

/// Thread-safe lazy-initialized global value.
/// Prevents the "static initialization order fiasco" by deferring
/// initialization until first access, with safe one-time init.
///
/// Uses an atomic flag for the fast path and a mutex for the slow path
/// (double-checked locking pattern).
///
/// Usage:
/// ```zig
/// var GLOBAL_CONFIG = LazyStatic(Config).init(initConfig);
/// const cfg = GLOBAL_CONFIG.get(); // Initializes on first call
/// ```
pub fn LazyStatic(comptime T: type) type {
    return struct {
        value: T,
        initialized: std.atomic.Value(bool),
        init_fn: *const fn () T,
        lock: std.atomic.Mutex,

        const Self = @This();

        pub fn init(init_fn: *const fn () T) Self {
            return .{
                .value = undefined,
                .initialized = std.atomic.Value(bool).init(false),
                .init_fn = init_fn,
                .lock = .unlocked,
            };
        }

        /// Initialize (if needed) and return a pointer to the value.
        /// Thread-safe: concurrent calls synchronize via mutex.
        pub fn get(self: *Self) *T {
            // Fast path: already initialized
            if (self.initialized.load(.acquire)) {
                return &self.value;
            }

            // Slow path: acquire lock and initialize
            spinLock(&self.lock);
            defer self.lock.unlock();

            // Double-check after acquiring lock
            if (!self.initialized.load(.acquire)) {
                self.value = self.init_fn();
                self.initialized.store(true, .release);
            }

            return &self.value;
        }

        /// Initialize (if needed) and return an immutable pointer.
        pub fn getConst(self: *Self) *const T {
            return self.get();
        }

        pub fn isInitialized(self: *const Self) bool {
            return self.initialized.load(.acquire);
        }

        fn spinLock(mutex: *std.atomic.Mutex) void {
            var spins: u32 = 0;
            while (!mutex.tryLock()) {
                std.atomic.spinLoopHint();
                spins += 1;
                if (spins > 1000) {
                    std.Thread.yield() catch {};
                    spins = 0;
                }
            }
        }
    };
}

/// A variant that uses an external allocator for heap-allocated types.
/// For when T itself contains pointers/allocations.
pub fn LazyStaticAlloc(comptime T: type) type {
    return struct {
        value: T,
        initialized: std.atomic.Value(bool),
        init_fn: *const fn (std.mem.Allocator) anyerror!T,
        allocator: ?std.mem.Allocator,
        lock: std.atomic.Mutex,

        const Self = @This();

        pub fn init(init_fn: *const fn (std.mem.Allocator) anyerror!T) Self {
            return .{
                .value = undefined,
                .initialized = std.atomic.Value(bool).init(false),
                .init_fn = init_fn,
                .allocator = null,
                .lock = .unlocked,
            };
        }

        pub fn initWithAlloc(init_fn: *const fn (std.mem.Allocator) anyerror!T, allocator: std.mem.Allocator) Self {
            var self = init(init_fn);
            self.allocator = allocator;
            return self;
        }

        /// Initialize (if needed) and return a pointer to the value.
        /// Thread-safe: concurrent calls synchronize via mutex.
        pub fn get(self: *Self) !*T {
            // Fast path: already initialized
            if (self.initialized.load(.acquire)) {
                return &self.value;
            }

            // Slow path: acquire lock and initialize
            spinLock(&self.lock);
            defer self.lock.unlock();

            // Double-check after acquiring lock
            if (!self.initialized.load(.acquire)) {
                if (self.allocator) |alloc| {
                    self.value = try self.init_fn(alloc);
                } else {
                    return error.NoAllocator;
                }
                self.initialized.store(true, .release);
            }

            return &self.value;
        }

        pub fn isInitialized(self: *const Self) bool {
            return self.initialized.load(.acquire);
        }

        fn spinLock(mutex: *std.atomic.Mutex) void {
            var spins: u32 = 0;
            while (!mutex.tryLock()) {
                std.atomic.spinLoopHint();
                spins += 1;
                if (spins > 1000) {
                    std.Thread.yield() catch {};
                    spins = 0;
                }
            }
        }
    };
}

// ─── Tests ───

test "LazyStatic initializes on first get" {
    var lazy = LazyStatic(u32).init(struct {
        fn f() u32 {
            return 42;
        }
    }.f);

    try std.testing.expect(!lazy.isInitialized());
    const ptr = lazy.get();
    try std.testing.expectEqual(ptr.*, 42);
    try std.testing.expect(lazy.isInitialized());
}

test "LazyStatic returns same pointer on subsequent gets" {
    var lazy = LazyStatic(u32).init(struct {
        fn f() u32 {
            return 99;
        }
    }.f);

    const ptr1 = lazy.get();
    ptr1.* = 100;

    const ptr2 = lazy.get();
    try std.testing.expectEqual(ptr1, ptr2);
    try std.testing.expectEqual(ptr2.*, 100);
}

test "LazyStatic thread-safe" {
    var lazy = LazyStatic(u32).init(struct {
        fn f() u32 {
            return 123;
        }
    }.f);

    var threads: [4]std.Thread = undefined;
    var results: [4]*u32 = undefined;

    for (&threads, &results) |*t, *r| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn f(ctx: *LazyStatic(u32), out: **u32) void {
                out.* = ctx.get();
            }
        }.f, .{ &lazy, r });
    }

    for (&threads) |*t| {
        t.join();
    }

    // All threads should have received the same pointer
    for (&results) |r| {
        try std.testing.expectEqual(r, results[0]);
        try std.testing.expectEqual(r.*, 123);
    }
}

test "LazyStaticAlloc with allocator" {
    const Config = struct {
        name: []const u8,
    };

    var lazy = LazyStaticAlloc(Config).initWithAlloc(struct {
        fn f(allocator: std.mem.Allocator) !Config {
            const name = try allocator.dupe(u8, "test");
            return .{ .name = name };
        }
    }.f, std.testing.allocator);

    const ptr = try lazy.get();
    try std.testing.expectEqualStrings(ptr.name, "test");

    // Same pointer on second get
    const ptr2 = try lazy.get();
    try std.testing.expectEqual(ptr, ptr2);

    // Clean up
    std.testing.allocator.free(ptr.name);
}
