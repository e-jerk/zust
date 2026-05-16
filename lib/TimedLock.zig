const std = @import("std");
const builtin = @import("builtin");

fn nanoTimestamp() i128 {
    if (comptime builtin.target.os.tag == .windows) {
        return 0;
    }
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(i128, tv.sec) * std.time.ns_per_s + @as(i128, tv.usec) * std.time.ns_per_us;
}

/// Mutex with timeout support.
///
/// Wraps `std.atomic.Mutex` with a spin-loop for blocking and
/// timeout checking via wall-clock timestamp.
pub const TimedMutex = struct {
    mutex: std.atomic.Mutex,

    const Self = @This();

    pub fn init() Self {
        return .{ .mutex = .unlocked };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Block until the mutex is acquired.
    pub fn lock(self: *Self) void {
        var spins: u32 = 0;
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
            spins += 1;
            if (spins > 1000) {
                std.Thread.yield() catch {};
                spins = 0;
            }
        }
    }

    /// Non-blocking attempt to acquire.
    pub fn tryLock(self: *Self) bool {
        return self.mutex.tryLock();
    }

    /// Try to acquire within the given timeout (nanoseconds).
    /// Returns `error.Timeout` if not acquired in time.
    pub fn lockTimeout(self: *Self, nanoseconds: i128) error{Timeout}!void {
        const start = nanoTimestamp();
        var spins: u32 = 0;
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
            spins += 1;
            if (spins > 1000) {
                std.Thread.yield() catch {};
                spins = 0;
            }
            if (nanoTimestamp() - start >= nanoseconds) {
                return error.Timeout;
            }
        }
    }

    /// Release the mutex.
    pub fn unlock(self: *Self) void {
        self.mutex.unlock();
    }

    /// Acquire and return an RAII guard.
    pub fn acquire(self: *Self) TimedMutexGuard {
        self.lock();
        return .{ .mutex = self };
    }

    /// Try to acquire and return a guard, or null if unavailable.
    pub fn tryAcquire(self: *Self) ?TimedMutexGuard {
        if (self.tryLock()) {
            return .{ .mutex = self };
        }
        return null;
    }

    /// Try to acquire within the given timeout and return a guard.
    pub fn acquireTimeout(self: *Self, nanoseconds: i128) error{Timeout}!TimedMutexGuard {
        try self.lockTimeout(nanoseconds);
        return .{ .mutex = self };
    }
};

/// RAII guard for TimedMutex.
/// Automatically unlocks the mutex when dropped.
pub const TimedMutexGuard = struct {
    mutex: *TimedMutex,

    pub fn deinit(self: TimedMutexGuard) void {
        self.mutex.unlock();
    }
};

// ─── Tests ───

test "TimedMutex init and deinit" {
    var mtx = TimedMutex.init();
    mtx.deinit();
}

test "TimedMutex lock and unlock" {
    var mtx = TimedMutex.init();
    defer mtx.deinit();

    mtx.lock();
    try std.testing.expect(true);
    mtx.unlock();
}

test "TimedMutex tryLock" {
    var mtx = TimedMutex.init();
    defer mtx.deinit();

    try std.testing.expect(mtx.tryLock());
    try std.testing.expect(!mtx.tryLock());
    mtx.unlock();
}

test "TimedMutex lockTimeout success" {
    var mtx = TimedMutex.init();
    defer mtx.deinit();

    try mtx.lockTimeout(1_000_000_000);
    mtx.unlock();
}

test "TimedMutex lockTimeout times out" {
    var mtx = TimedMutex.init();
    defer mtx.deinit();

    mtx.lock();
    defer mtx.unlock();

    const result = mtx.lockTimeout(10 * std.time.ns_per_ms);
    try std.testing.expectError(error.Timeout, result);
}

test "TimedMutexGuard acquire and auto-release" {
    var mtx = TimedMutex.init();
    defer mtx.deinit();

    {
        const guard = mtx.acquire();
        defer guard.deinit();
        try std.testing.expect(true);
    }

    // Should be able to acquire again after guard dropped
    const guard2 = mtx.acquire();
    defer guard2.deinit();
    try std.testing.expect(true);
}
