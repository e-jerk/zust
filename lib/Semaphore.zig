const std = @import("std");
const builtin = @import("builtin");

/// Counting semaphore for limiting concurrent access.
///
/// Uses an atomic counter. The fast path is lock-free via CAS;
/// the slow path spins and yields to the OS scheduler.
pub const Semaphore = struct {
    count: std.atomic.Value(u32),

    const Self = @This();

    pub fn init(initial_count: u32) Self {
        return .{
            .count = std.atomic.Value(u32).init(initial_count),
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Block until count > 0, then decrement.
    pub fn wait(self: *Self) void {
        while (true) {
            const current = self.count.load(.seq_cst);
            if (current > 0) {
                if (self.count.cmpxchgStrong(current, current - 1, .seq_cst, .seq_cst) == null) {
                    return;
                }
                continue;
            }
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
    }

    /// Increment count.
    pub fn signal(self: *Self) void {
        _ = self.count.fetchAdd(1, .seq_cst);
    }

    /// Non-blocking attempt to decrement.
    /// Returns true if successful.
    pub fn tryWait(self: *Self) bool {
        while (true) {
            const current = self.count.load(.seq_cst);
            if (current == 0) return false;
            if (self.count.cmpxchgStrong(current, current - 1, .seq_cst, .seq_cst) == null) {
                return true;
            }
        }
    }
};

// ─── Tests ───

test "Semaphore init and deinit" {
    var sem = Semaphore.init(1);
    sem.deinit();
}

test "Semaphore wait and signal" {
    var sem = Semaphore.init(0);
    defer sem.deinit();

    var thread = try std.Thread.spawn(.{}, struct {
        fn f(s: *Semaphore) void {
            s.signal();
        }
    }.f, .{&sem});

    sem.wait();
    thread.join();
}

test "Semaphore tryWait" {
    var sem = Semaphore.init(1);
    defer sem.deinit();

    try std.testing.expect(sem.tryWait());
    try std.testing.expect(!sem.tryWait());
    sem.signal();
    try std.testing.expect(sem.tryWait());
}

test "Semaphore multiple signals and waits" {
    var sem = Semaphore.init(0);
    defer sem.deinit();

    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        sem.signal();
    }

    i = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expect(sem.tryWait());
    }
    try std.testing.expect(!sem.tryWait());
}

test "Semaphore limits concurrent access" {
    var sem = Semaphore.init(2);
    defer sem.deinit();

    const Ctx = struct {
        sem: *Semaphore,
        counter: *std.atomic.Value(u32),
        max: *std.atomic.Value(u32),
        current: *std.atomic.Value(u32),
    };

    var counter = std.atomic.Value(u32).init(0);
    var max_concurrent = std.atomic.Value(u32).init(0);
    var current = std.atomic.Value(u32).init(0);

    const ctx = Ctx{
        .sem = &sem,
        .counter = &counter,
        .max = &max_concurrent,
        .current = &current,
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn f(c: Ctx) void {
                c.sem.wait();
                const cur = c.current.fetchAdd(1, .seq_cst) + 1;
                const max = c.max.load(.seq_cst);
                if (cur > max) {
                    _ = c.max.cmpxchgStrong(max, cur, .seq_cst, .seq_cst);
                }
                _ = c.counter.fetchAdd(1, .seq_cst);
                if (comptime builtin.target.os.tag != .windows) {
                    const req = std.c.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
                    _ = std.c.nanosleep(&req, null);
                }
                _ = c.current.fetchSub(1, .seq_cst);
                c.sem.signal();
            }
        }.f, .{ctx});
    }

    for (&threads) |*t| {
        t.join();
    }

    try std.testing.expectEqual(counter.load(.seq_cst), 4);
    try std.testing.expect(max_concurrent.load(.seq_cst) <= 2);
}
