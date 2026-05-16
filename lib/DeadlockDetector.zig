const std = @import("std");

/// Global deadlock detection system that tracks lock acquisition order
/// and detects cycles in the wait-for graph.
///
/// This is a debugging/tooling type — do not use on production hot paths.
pub const DeadlockDetector = struct {
    const LockId = u64;
    const ThreadId = u64;

    // Adjacency list: thread -> [locks waiting for]
    waiting_graph: std.AutoHashMap(ThreadId, std.ArrayList(LockId)),
    // lock -> holding thread
    lock_owners: std.AutoHashMap(LockId, ThreadId),

    allocator: std.mem.Allocator,
    lock: std.atomic.Mutex,

    pub fn init(allocator: std.mem.Allocator) DeadlockDetector {
        return .{
            .waiting_graph = std.AutoHashMap(ThreadId, std.ArrayList(LockId)).init(allocator),
            .lock_owners = std.AutoHashMap(LockId, ThreadId).init(allocator),
            .allocator = allocator,
            .lock = .unlocked,
        };
    }

    pub fn deinit(self: *DeadlockDetector) void {
        var it = self.waiting_graph.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.waiting_graph.deinit();
        self.lock_owners.deinit();
    }

    /// Called before acquiring a lock.
    /// Returns error.DeadlockDetected if this would create a cycle.
    pub fn beforeLock(self: *DeadlockDetector, thread_id: ThreadId, lock_id: LockId) !void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        defer self.lock.unlock();

        // Record that this thread is waiting for this lock
        var entry = try self.waiting_graph.getOrPut(thread_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        }
        try entry.value_ptr.append(self.allocator, lock_id);

        // Check if acquiring this lock would create a cycle
        if (self.lock_owners.get(lock_id)) |owner| {
            var visited = std.AutoHashMap(ThreadId, void).init(self.allocator);
            defer visited.deinit();
            if (self.wouldDeadlock(thread_id, owner, &visited)) {
                return error.DeadlockDetected;
            }
        }
    }

    /// Called after successfully acquiring a lock.
    pub fn afterLock(self: *DeadlockDetector, thread_id: ThreadId, lock_id: LockId) !void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        defer self.lock.unlock();

        // Remove from waiting
        if (self.waiting_graph.getPtr(thread_id)) |waiting| {
            for (waiting.items, 0..) |l, i| {
                if (l == lock_id) {
                    _ = waiting.orderedRemove(i);
                    break;
                }
            }
            // Clean up empty entry to keep graph tidy
            if (waiting.items.len == 0) {
                waiting.deinit(self.allocator);
                _ = self.waiting_graph.remove(thread_id);
            }
        }

        // Record ownership
        try self.lock_owners.put(lock_id, thread_id);
    }

    /// Called when releasing a lock.
    pub fn releaseLock(self: *DeadlockDetector, lock_id: LockId) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        defer self.lock.unlock();

        _ = self.lock_owners.remove(lock_id);
    }

    /// Check if waiting_thread waiting would cause a cycle involving lock_owner.
    fn wouldDeadlock(self: *DeadlockDetector, waiting_thread: ThreadId, lock_owner: ThreadId, visited: *std.AutoHashMap(ThreadId, void)) bool {
        if (waiting_thread == lock_owner) return true;
        if (visited.contains(lock_owner)) return false;

        // OOM in debug tool: conservatively assume no deadlock to avoid panic
        visited.put(lock_owner, {}) catch return false;

        if (self.waiting_graph.get(lock_owner)) |owner_waiting| {
            for (owner_waiting.items) |lock_id| {
                if (self.lock_owners.get(lock_id)) |next_owner| {
                    if (self.wouldDeadlock(waiting_thread, next_owner, visited)) {
                        return true;
                    }
                }
            }
        }
        return false;
    }
};

// ─── Tests ───

test "no false positives for sequential locking" {
    var dd = DeadlockDetector.init(std.testing.allocator);
    defer dd.deinit();

    // Thread 1 locks A then B
    try dd.beforeLock(1, 100);
    try dd.afterLock(1, 100);
    try dd.beforeLock(1, 200);
    try dd.afterLock(1, 200);
    dd.releaseLock(200);
    dd.releaseLock(100);

    // Thread 2 locks A then B (same order)
    try dd.beforeLock(2, 100);
    try dd.afterLock(2, 100);
    try dd.beforeLock(2, 200);
    try dd.afterLock(2, 200);
    dd.releaseLock(200);
    dd.releaseLock(100);
}

test "detects simple A->B->A cycle" {
    var dd = DeadlockDetector.init(std.testing.allocator);
    defer dd.deinit();

    // Thread 1 holds lock A
    try dd.beforeLock(1, 100);
    try dd.afterLock(1, 100);

    // Thread 2 holds lock B
    try dd.beforeLock(2, 200);
    try dd.afterLock(2, 200);

    // Thread 1 wants lock B
    try dd.beforeLock(1, 200);

    // Thread 2 wants lock A -> deadlock
    const result = dd.beforeLock(2, 100);
    try std.testing.expectError(error.DeadlockDetected, result);
}

test "detects complex A->B->C->A cycle" {
    var dd = DeadlockDetector.init(std.testing.allocator);
    defer dd.deinit();

    // T1 holds A, T2 holds B, T3 holds C
    try dd.beforeLock(1, 100);
    try dd.afterLock(1, 100);
    try dd.beforeLock(2, 200);
    try dd.afterLock(2, 200);
    try dd.beforeLock(3, 300);
    try dd.afterLock(3, 300);

    // T1 waits for B
    try dd.beforeLock(1, 200);

    // T2 waits for C
    try dd.beforeLock(2, 300);

    // T3 waits for A -> deadlock
    const result = dd.beforeLock(3, 100);
    try std.testing.expectError(error.DeadlockDetected, result);
}

test "works with multiple threads" {
    var dd = DeadlockDetector.init(std.testing.allocator);
    defer dd.deinit();

    const Context = struct {
        dd: *DeadlockDetector,
        t1_has_a: std.atomic.Value(bool),
        t2_has_b: std.atomic.Value(bool),
        deadlock_detected: std.atomic.Value(bool),
    };

    var ctx = Context{
        .dd = &dd,
        .t1_has_a = std.atomic.Value(bool).init(false),
        .t2_has_b = std.atomic.Value(bool).init(false),
        .deadlock_detected = std.atomic.Value(bool).init(false),
    };

    const t1 = try std.Thread.spawn(.{}, struct {
        fn f(c: *Context) void {
            c.dd.beforeLock(1, 100) catch return;
            c.dd.afterLock(1, 100) catch return;
            c.t1_has_a.store(true, .seq_cst);

            while (!c.t2_has_b.load(.seq_cst)) {
                std.atomic.spinLoopHint();
            }

            // T1 waits for B (held by T2)
            c.dd.beforeLock(1, 200) catch return;
        }
    }.f, .{&ctx});

    const t2 = try std.Thread.spawn(.{}, struct {
        fn f(c: *Context) void {
            while (!c.t1_has_a.load(.seq_cst)) {
                std.atomic.spinLoopHint();
            }
            c.dd.beforeLock(2, 200) catch return;
            c.dd.afterLock(2, 200) catch return;
            c.t2_has_b.store(true, .seq_cst);

            // Wait until T1 is recorded as waiting for lock 200
            while (!c.dd.waiting_graph.contains(1)) {
                std.atomic.spinLoopHint();
            }

            // T2 tries to acquire A (held by T1) -> deadlock
            const result = c.dd.beforeLock(2, 100);
            if (result == error.DeadlockDetected) {
                c.deadlock_detected.store(true, .seq_cst);
            }
        }
    }.f, .{&ctx});

    t1.join();
    t2.join();

    try std.testing.expect(ctx.deadlock_detected.load(.seq_cst));
}
