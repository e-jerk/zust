const std = @import("std");
const builtin = @import("builtin");

/// Synchronization barrier for N threads.
///
/// Blocks until all N threads call `wait()`, then all proceed.
/// Uses an atomic arrived counter and generation counter; waiting
/// threads spin-yield to the scheduler.
pub const Barrier = struct {
    count: u32,
    arrived: std.atomic.Value(u32),
    generation: std.atomic.Value(u32),

    const Self = @This();

    pub fn init(thread_count: u32) Self {
        return .{
            .count = thread_count,
            .arrived = std.atomic.Value(u32).init(0),
            .generation = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Block until all N threads have called wait().
    pub fn wait(self: *Self) void {
        const gen = self.generation.load(.seq_cst);
        const arr = self.arrived.fetchAdd(1, .seq_cst) + 1;

        if (arr == self.count) {
            // Last thread to arrive
            self.generation.store(gen + 1, .seq_cst);
            self.arrived.store(0, .seq_cst);
        } else {
            // Spin until generation changes
            while (self.generation.load(.seq_cst) == gen) {
                std.atomic.spinLoopHint();
                std.Thread.yield() catch {};
            }
        }
    }
};

// ─── Tests ───

test "Barrier init and deinit" {
    var b = Barrier.init(2);
    b.deinit();
}

test "Barrier single thread" {
    var b = Barrier.init(1);
    defer b.deinit();
    b.wait();
    try std.testing.expect(true);
}

test "Barrier multiple threads" {
    var b = Barrier.init(4);
    defer b.deinit();

    const Ctx = struct {
        barrier: *Barrier,
        results: *[4]bool,
        idx: usize,
    };

    var results = [4]bool{ false, false, false, false };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn f(c: Ctx) void {
                c.barrier.wait();
                c.results[c.idx] = true;
            }
        }.f, .{Ctx{
            .barrier = &b,
            .results = &results,
            .idx = i,
        }});
    }

    for (&threads) |*t| {
        t.join();
    }

    for (results) |r| {
        try std.testing.expect(r);
    }
}

test "Barrier reused across rounds" {
    var b = Barrier.init(4);
    defer b.deinit();

    const Ctx = struct {
        barrier: *Barrier,
        round1: *[4]bool,
        round2: *[4]bool,
        idx: usize,
    };

    var round1 = [4]bool{ false, false, false, false };
    var round2 = [4]bool{ false, false, false, false };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn f(c: Ctx) void {
                c.barrier.wait();
                c.round1[c.idx] = true;
                c.barrier.wait();
                c.round2[c.idx] = true;
            }
        }.f, .{Ctx{
            .barrier = &b,
            .round1 = &round1,
            .round2 = &round2,
            .idx = i,
        }});
    }

    for (&threads) |*t| {
        t.join();
    }

    for (round1) |r| {
        try std.testing.expect(r);
    }
    for (round2) |r| {
        try std.testing.expect(r);
    }
}

test "Barrier exact count" {
    var b = Barrier.init(2);
    defer b.deinit();

    var hit = std.atomic.Value(bool).init(false);

    const Ctx = struct {
        barrier: *Barrier,
        hit: *std.atomic.Value(bool),
    };

    var t1 = try std.Thread.spawn(.{}, struct {
        fn f(ctx: Ctx) void {
            ctx.barrier.wait();
            ctx.hit.store(true, .seq_cst);
        }
    }.f, .{Ctx{
        .barrier = &b,
        .hit = &hit,
    }});

    var t2 = try std.Thread.spawn(.{}, struct {
        fn f(ctx: Ctx) void {
            if (comptime builtin.target.os.tag != .windows) {
                const req = std.c.timespec{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&req, null);
            }
            ctx.barrier.wait();
        }
    }.f, .{Ctx{
        .barrier = &b,
        .hit = &hit,
    }});

    t1.join();
    t2.join();

    try std.testing.expect(hit.load(.seq_cst));
}
