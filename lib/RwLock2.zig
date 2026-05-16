const std = @import("std");

/// A read-write lock that supports atomically upgrading a read lock to a write lock.
///
/// States tracked in a single `u32` atomic:
/// - `0` = unlocked
/// - `1..READ_MASK` = number of active readers
/// - `WRITE_LOCK` = exclusively write-locked
/// - `UPGRADE_FLAG` = a reader is trying to upgrade (blocks new readers/writers)
pub fn RwLockUpgrade(comptime T: type) type {
    return struct {
        state: std.atomic.Value(u32), // 0=unlocked, 1-READ_MASK=readers, WRITE_LOCK=write locked
        writer_waiting: std.atomic.Value(bool),
        value: T,

        const Self = @This();
        const WRITE_LOCK: u32 = 0x80000000;
        const UPGRADE_FLAG: u32 = 0x40000000;
        const READ_MASK: u32 = 0x3FFFFFFF;

        pub fn init(value: T) Self {
            return .{
                .state = std.atomic.Value(u32).init(0),
                .writer_waiting = std.atomic.Value(bool).init(false),
                .value = value,
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Acquire a read lock. Spins until successful.
        pub fn read(self: *Self) RwLockUpgradeReadGuard(T) {
            while (true) {
                const current = self.state.load(.acquire);
                if (current & WRITE_LOCK != 0 or current & UPGRADE_FLAG != 0) {
                    std.atomic.spinLoopHint();
                    continue;
                }
                const new = current + 1;
                if (self.state.cmpxchgStrong(current, new, .acquire, .monotonic)) |_| {
                    continue;
                }
                return RwLockUpgradeReadGuard(T).init(self);
            }
        }

        /// Acquire a write lock. Spins until successful.
        pub fn write(self: *Self) RwLockUpgradeWriteGuard(T) {
            self.writer_waiting.store(true, .release);
            defer self.writer_waiting.store(false, .release);

            while (true) {
                const current = self.state.load(.acquire);
                if (current != 0) {
                    std.atomic.spinLoopHint();
                    continue;
                }
                if (self.state.cmpxchgStrong(0, WRITE_LOCK, .acquire, .monotonic)) |_| {
                    continue;
                }
                return RwLockUpgradeWriteGuard(T).init(self);
            }
        }

        /// Try to upgrade a read lock to a write lock atomically.
        /// Returns `error.UpgradeFailed` if other readers exist.
        pub fn tryUpgrade(self: *Self, guard: RwLockUpgradeReadGuard(T)) error{UpgradeFailed}!RwLockUpgradeWriteGuard(T) {
            _ = guard; // Consumed by this function

            while (true) {
                const current = self.state.load(.acquire);
                // We should be the only reader (count == 1)
                if ((current & READ_MASK) != 1) {
                    return error.UpgradeFailed;
                }
                // Try to transition from 1 reader to write lock
                if (self.state.cmpxchgStrong(current, WRITE_LOCK, .acquire, .monotonic)) |_| {
                    continue;
                }
                return RwLockUpgradeWriteGuard(T).init(self);
            }
        }
    };
}

/// RAII read guard for RwLockUpgrade.
pub fn RwLockUpgradeReadGuard(comptime T: type) type {
    return struct {
        lock: *RwLockUpgrade(T),

        const Self = @This();

        pub fn init(lock: *RwLockUpgrade(T)) Self {
            return .{ .lock = lock };
        }
        pub fn deinit(self: Self) void {
            _ = self.lock.state.fetchSub(1, .release);
        }
        pub fn get(self: Self) *const T {
            return &self.lock.value;
        }
    };
}

/// RAII write guard for RwLockUpgrade.
pub fn RwLockUpgradeWriteGuard(comptime T: type) type {
    return struct {
        lock: *RwLockUpgrade(T),

        const Self = @This();

        pub fn init(lock: *RwLockUpgrade(T)) Self {
            return .{ .lock = lock };
        }
        pub fn deinit(self: Self) void {
            self.lock.state.store(0, .release);
        }
        pub fn get(self: Self) *T {
            return &self.lock.value;
        }
        pub fn getConst(self: Self) *const T {
            return &self.lock.value;
        }
    };
}

/// A mutex that allows the same thread to lock it multiple times (recursive locking).
pub fn ReentrantMutex(comptime T: type) type {
    return struct {
        mutex: std.atomic.Mutex,
        owner: std.atomic.Value(u64),
        count: std.atomic.Value(u32),
        value: T,

        const Self = @This();
        const NO_OWNER: u64 = std.math.maxInt(u64);

        pub fn init(value: T) Self {
            return .{
                .mutex = .unlocked,
                .owner = std.atomic.Value(u64).init(NO_OWNER),
                .count = std.atomic.Value(u32).init(0),
                .value = value,
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Acquire the lock, allowing recursive acquisition by the same thread.
        pub fn lock(self: *Self) ReentrantMutexGuard(T) {
            const me = std.Thread.getCurrentId();
            const current_owner = self.owner.load(.acquire);

            if (current_owner == me) {
                // Already owned by us, increment count
                _ = self.count.fetchAdd(1, .acquire);
                return ReentrantMutexGuard(T).init(self, false);
            }

            // Need to acquire
            while (!self.mutex.tryLock()) {
                std.atomic.spinLoopHint();
            }

            self.owner.store(me, .release);
            self.count.store(1, .release);
            return ReentrantMutexGuard(T).init(self, true);
        }
    };
}

/// RAII guard for ReentrantMutex.
pub fn ReentrantMutexGuard(comptime T: type) type {
    return struct {
        lock: *ReentrantMutex(T),
        is_outer: bool, // true if this lock acquisition was the outer one

        const Self = @This();

        pub fn init(mtx: *ReentrantMutex(T), is_outer: bool) Self {
            return .{ .lock = mtx, .is_outer = is_outer };
        }
        pub fn deinit(self: Self) void {
            const new_count = self.lock.count.fetchSub(1, .acquire);
            if (new_count == 1 and self.is_outer) {
                // Last recursive unlock, release mutex
                self.lock.owner.store(std.math.maxInt(u64), .release);
                self.lock.mutex.unlock();
            }
        }
        pub fn get(self: Self) *T {
            return &self.lock.value;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "RwLockUpgrade basic read/write" {
    var rw = RwLockUpgrade(u32).init(42);
    defer rw.deinit();

    {
        const rguard = rw.read();
        defer rguard.deinit();
        try std.testing.expectEqual(rguard.get().*, 42);
    }

    {
        const wguard = rw.write();
        defer wguard.deinit();
        wguard.get().* = 100;
    }

    {
        const rguard = rw.read();
        defer rguard.deinit();
        try std.testing.expectEqual(rguard.get().*, 100);
    }
}

test "RwLockUpgrade tryUpgrade succeeds with single reader" {
    var rw = RwLockUpgrade(u32).init(0);
    defer rw.deinit();

    const rguard = rw.read();
    try std.testing.expectEqual(rguard.get().*, 0);

    const wguard = try rw.tryUpgrade(rguard);
    wguard.get().* = 99;
    wguard.deinit();

    // After upgrade+write, read again
    const rguard2 = rw.read();
    defer rguard2.deinit();
    try std.testing.expectEqual(rguard2.get().*, 99);
}

test "RwLockUpgrade tryUpgrade fails with multiple readers" {
    var rw = RwLockUpgrade(u32).init(0);
    defer rw.deinit();

    const r1 = rw.read();
    const r2 = rw.read();
    defer r2.deinit();

    const result = rw.tryUpgrade(r1);
    try std.testing.expectError(error.UpgradeFailed, result);

    // Clean up r1 since upgrade failed
    r1.deinit();
}

test "RwLockUpgrade write while upgrade pending" {
    var rw = RwLockUpgrade(u32).init(0);
    defer rw.deinit();

    // Hold a read lock so upgrade can be attempted
    const rguard = rw.read();

    // Spawn a thread that tries to write (should block until we release)
    var wrote = false;
    const thread = try std.Thread.spawn(.{}, struct {
        fn f(lock: *RwLockUpgrade(u32), flag: *bool) void {
            const w = lock.write();
            w.get().* = 77;
            flag.* = true;
            w.deinit();
        }
    }.f, .{ &rw, &wrote });

    // Give the writer time to start waiting
    const req1 = std.c.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&req1, null);

    // Upgrade should succeed (we are the only reader)
    const wguard = try rw.tryUpgrade(rguard);
    wguard.get().* = 55;
    wguard.deinit();

    thread.join();
    try std.testing.expect(wrote);

    const r2 = rw.read();
    defer r2.deinit();
    // The writer set it last because it ran after our upgrade released
    try std.testing.expectEqual(r2.get().*, 77);
}

test "ReentrantMutex basic lock" {
    var mtx = ReentrantMutex(u32).init(42);
    defer mtx.deinit();

    const guard = mtx.lock();
    defer guard.deinit();
    try std.testing.expectEqual(guard.get().*, 42);
    guard.get().* = 100;
    try std.testing.expectEqual(guard.get().*, 100);
}

test "ReentrantMutex recursive lock (same thread)" {
    var mtx = ReentrantMutex(u32).init(0);
    defer mtx.deinit();

    const g1 = mtx.lock();
    g1.get().* = 1;

    const g2 = mtx.lock();
    g2.get().* = 2;

    g2.deinit();
    g1.deinit();

    // After full unlock, another thread or same thread can lock again
    const g3 = mtx.lock();
    defer g3.deinit();
    try std.testing.expectEqual(g3.get().*, 2);
}

test "ReentrantMutex 3 levels deep" {
    var mtx = ReentrantMutex(u32).init(10);
    defer mtx.deinit();

    const g1 = mtx.lock();
    const g2 = mtx.lock();
    const g3 = mtx.lock();

    g3.get().* = 99;
    try std.testing.expectEqual(g1.get().*, 99);
    try std.testing.expectEqual(g2.get().*, 99);
    try std.testing.expectEqual(g3.get().*, 99);

    g3.deinit();
    g2.deinit();
    g1.deinit();
}

test "ReentrantMutex different threads block" {
    var mtx = ReentrantMutex(u32).init(0);
    defer mtx.deinit();

    const g1 = mtx.lock();
    try std.testing.expectEqual(g1.get().*, 0);

    var other_got_lock = false;
    const thread = try std.Thread.spawn(.{}, struct {
        fn f(m: *ReentrantMutex(u32), flag: *bool) void {
            const g = m.lock();
            flag.* = true;
            g.deinit();
        }
    }.f, .{ &mtx, &other_got_lock });

    // Give the other thread time to try (and block)
    const req2 = std.c.timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&req2, null);
    try std.testing.expect(!other_got_lock);

    // Release outer lock
    g1.deinit();

    thread.join();
    try std.testing.expect(other_got_lock);
}
