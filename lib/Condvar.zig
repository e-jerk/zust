const std = @import("std");

/// A condition variable for thread synchronization.
/// Allows threads to wait until a condition is signaled.
pub fn Condvar() type {
    return struct {
        waiters: std.atomic.Value(u32),
        signaled: std.atomic.Value(bool),
        lock: std.atomic.Mutex,

        const Self = @This();

        pub fn init() Self {
            return .{
                .waiters = std.atomic.Value(u32).init(0),
                .signaled = std.atomic.Value(bool).init(false),
                .lock = .unlocked,
            };
        }

        pub fn deinit(_: *Self) void {
            // Nothing to clean up
        }

        /// Wait until the condition is signaled.
        /// Caller must hold the associated mutex.
        pub fn wait(self: *Self) void {
            _ = self.waiters.fetchAdd(1, .acquire);
            defer _ = self.waiters.fetchSub(1, .release);

            // Release lock and wait for signal
            while (true) {
                if (self.signaled.load(.acquire)) {
                    return;
                }
                std.atomic.spinLoopHint();
            }
        }

        /// Signal one waiting thread.
        pub fn signal(self: *Self) void {
            while (!self.lock.tryLock()) {
                std.atomic.spinLoopHint();
            }
            defer self.lock.unlock();

            self.signaled.store(true, .release);
        }

        /// Reset the signaled state.
        pub fn reset(self: *Self) void {
            while (!self.lock.tryLock()) {
                std.atomic.spinLoopHint();
            }
            defer self.lock.unlock();

            self.signaled.store(false, .release);
        }

        /// Signal all waiting threads.
        pub fn broadcast(self: *Self) void {
            while (!self.lock.tryLock()) {
                std.atomic.spinLoopHint();
            }
            defer self.lock.unlock();

            self.signaled.store(true, .release);
        }

        /// Check if condition has been signaled.
        pub fn isSignaled(self: *Self) bool {
            return self.signaled.load(.acquire);
        }
    };
}

// ─── Tests ───

test "Condvar signal and wait" {
    var cv = Condvar().init();
    defer cv.deinit();

    cv.signal();
    try std.testing.expect(cv.isSignaled());
}

test "Condvar reset" {
    var cv = Condvar().init();
    defer cv.deinit();

    cv.signal();
    try std.testing.expect(cv.isSignaled());
    cv.reset();
    try std.testing.expect(!cv.isSignaled());
}

test "Condvar broadcast" {
    var cv = Condvar().init();
    defer cv.deinit();

    cv.broadcast();
    try std.testing.expect(cv.isSignaled());
}
