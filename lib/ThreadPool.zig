const std = @import("std");

/// A work-stealing thread pool.
///
/// Spawns a fixed number of worker threads that process tasks
/// submitted via `spawn()`. Tasks are stored in an ArrayList and
/// each worker thread runs a loop checking for tasks.
pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    workers: []std.Thread,
    tasks: std.ArrayList(Task),
    shutdown: std.atomic.Value(bool),
    pending: std.atomic.Value(usize),
    mutex: std.atomic.Mutex,

    const Task = struct {
        func: *const fn (?*anyopaque) void,
        context: ?*anyopaque,
    };

    const Self = @This();

    /// Spawn `num_threads` worker threads.
    /// Returns a heap-allocated ThreadPool; call `deinit()` to clean up.
    pub fn init(allocator: std.mem.Allocator, num_threads: usize) !*Self {
        var self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .workers = try allocator.alloc(std.Thread, num_threads),
            .tasks = .empty,
            .shutdown = std.atomic.Value(bool).init(false),
            .pending = std.atomic.Value(usize).init(0),
            .mutex = .unlocked,
        };
        errdefer allocator.destroy(self);

        var spawned: usize = 0;
        errdefer {
            self.shutdown.store(true, .seq_cst);
            for (0..spawned) |j| {
                self.workers[j].join();
            }
            allocator.free(self.workers);
            self.tasks.deinit(allocator);
            allocator.destroy(self);
        }

        for (0..num_threads) |i| {
            self.workers[i] = try std.Thread.spawn(.{}, workerLoop, .{self});
            spawned += 1;
        }

        return self;
    }

    /// Shutdown all threads and free resources.
    pub fn deinit(self: *Self) void {
        self.shutdown.store(true, .seq_cst);
        for (self.workers) |*worker| {
            worker.join();
        }
        const allocator = self.allocator;
        allocator.free(self.workers);
        self.tasks.deinit(allocator);
        allocator.destroy(self);
    }

    /// Submit a task to the pool.
    /// `task_fn` receives a copy of `context`.
    pub fn spawn(self: *Self, comptime task_fn: anytype, context: anytype) !void {
        const Context = @TypeOf(context);
        const Wrapper = struct {
            fn run(ctx: ?*anyopaque) void {
                const c = @as(Context, @ptrCast(@alignCast(ctx.?)));
                task_fn(c);
            }
        };

        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.unlock();
        try self.tasks.append(self.allocator, .{
            .func = Wrapper.run,
            .context = @ptrCast(@constCast(context)),
        });
        _ = self.pending.fetchAdd(1, .seq_cst);
    }

    /// Block until all submitted tasks have completed.
    pub fn wait(self: *Self) void {
        while (true) {
            const pending = self.pending.load(.seq_cst);
            while (!self.mutex.tryLock()) {
                std.atomic.spinLoopHint();
            }
            const empty = self.tasks.items.len == 0;
            self.mutex.unlock();
            if (empty and pending == 0) break;
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
    }

    fn workerLoop(self: *Self) void {
        while (!self.shutdown.load(.seq_cst)) {
            while (!self.mutex.tryLock()) {
                std.atomic.spinLoopHint();
            }
            if (self.tasks.items.len > 0) {
                const task = self.tasks.pop().?;
                self.mutex.unlock();
                _ = self.pending.fetchSub(1, .seq_cst);
                task.func(task.context);
            } else {
                self.mutex.unlock();
                std.Thread.yield() catch {};
            }
        }
    }
};

// ─── Tests ───

test "ThreadPool init and deinit" {
    var pool = try ThreadPool.init(std.testing.allocator, 2);
    pool.deinit();
}

test "ThreadPool spawn single task" {
    var pool = try ThreadPool.init(std.testing.allocator, 2);
    defer pool.deinit();

    var value: u32 = 0;
    try pool.spawn(struct {
        fn f(ctx: *u32) void {
            ctx.* = 42;
        }
    }.f, &value);

    pool.wait();
    try std.testing.expectEqual(value, 42);
}

test "ThreadPool spawn multiple tasks" {
    var pool = try ThreadPool.init(std.testing.allocator, 4);
    defer pool.deinit();

    var counter = std.atomic.Value(u32).init(0);
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try pool.spawn(struct {
            fn f(ctx: *std.atomic.Value(u32)) void {
                _ = ctx.fetchAdd(1, .seq_cst);
            }
        }.f, &counter);
    }

    pool.wait();
    try std.testing.expectEqual(counter.load(.seq_cst), 10);
}

test "ThreadPool wait blocks until complete" {
    var pool = try ThreadPool.init(std.testing.allocator, 2);
    defer pool.deinit();

    var counter = std.atomic.Value(u32).init(0);
    try pool.spawn(struct {
        fn f(ctx: *std.atomic.Value(u32)) void {
            _ = ctx.fetchAdd(1, .seq_cst);
        }
    }.f, &counter);

    pool.wait();
    try std.testing.expectEqual(counter.load(.seq_cst), 1);
}

test "ThreadPool multiple thread execution" {
    var pool = try ThreadPool.init(std.testing.allocator, 4);
    defer pool.deinit();

    var sum = std.atomic.Value(u32).init(0);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try pool.spawn(struct {
            fn f(ctx: *std.atomic.Value(u32)) void {
                _ = ctx.fetchAdd(1, .seq_cst);
            }
        }.f, &sum);
    }

    pool.wait();
    try std.testing.expectEqual(sum.load(.seq_cst), 100);
}
