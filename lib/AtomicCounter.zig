const std = @import("std");

/// Generic atomic counter.
///
/// Wraps `std.atomic.Value(T)` with convenient fetch-and-op methods.
pub fn AtomicCounter(comptime T: type) type {
    return struct {
        value: std.atomic.Value(T),

        const Self = @This();

        pub fn init(initial_value: T) Self {
            return .{ .value = std.atomic.Value(T).init(initial_value) };
        }

        pub fn load(self: *const Self, comptime ordering: std.builtin.AtomicOrder) T {
            return self.value.load(ordering);
        }

        pub fn store(self: *Self, val: T, comptime ordering: std.builtin.AtomicOrder) void {
            self.value.store(val, ordering);
        }

        pub fn fetchAdd(self: *Self, val: T, comptime ordering: std.builtin.AtomicOrder) T {
            return self.value.fetchAdd(val, ordering);
        }

        pub fn fetchSub(self: *Self, val: T, comptime ordering: std.builtin.AtomicOrder) T {
            return self.value.fetchSub(val, ordering);
        }

        pub fn fetchAnd(self: *Self, val: T, comptime ordering: std.builtin.AtomicOrder) T {
            return self.value.fetchAnd(val, ordering);
        }

        pub fn fetchOr(self: *Self, val: T, comptime ordering: std.builtin.AtomicOrder) T {
            return self.value.fetchOr(val, ordering);
        }

        pub fn fetchXor(self: *Self, val: T, comptime ordering: std.builtin.AtomicOrder) T {
            return self.value.fetchXor(val, ordering);
        }

        pub fn compareExchange(
            self: *Self,
            expected: T,
            desired: T,
            comptime success_order: std.builtin.AtomicOrder,
            comptime failure_order: std.builtin.AtomicOrder,
        ) ?T {
            return self.value.cmpxchgStrong(expected, desired, success_order, failure_order);
        }
    };
}

// ─── Tests ───

test "AtomicCounter init load store" {
    var counter = AtomicCounter(u32).init(42);
    try std.testing.expectEqual(counter.load(.seq_cst), 42);
    counter.store(100, .seq_cst);
    try std.testing.expectEqual(counter.load(.seq_cst), 100);
}

test "AtomicCounter fetchAdd and fetchSub" {
    var counter = AtomicCounter(u32).init(10);
    try std.testing.expectEqual(counter.fetchAdd(5, .seq_cst), 10);
    try std.testing.expectEqual(counter.load(.seq_cst), 15);
    try std.testing.expectEqual(counter.fetchSub(3, .seq_cst), 15);
    try std.testing.expectEqual(counter.load(.seq_cst), 12);
}

test "AtomicCounter fetchAnd fetchOr fetchXor" {
    var counter = AtomicCounter(u8).init(0b1010);
    try std.testing.expectEqual(counter.fetchAnd(0b1100, .seq_cst), 0b1010);
    try std.testing.expectEqual(counter.load(.seq_cst), 0b1000);
    try std.testing.expectEqual(counter.fetchOr(0b0011, .seq_cst), 0b1000);
    try std.testing.expectEqual(counter.load(.seq_cst), 0b1011);
    try std.testing.expectEqual(counter.fetchXor(0b1011, .seq_cst), 0b1011);
    try std.testing.expectEqual(counter.load(.seq_cst), 0b0000);
}

test "AtomicCounter compareExchange" {
    var counter = AtomicCounter(u32).init(42);
    const failed = counter.compareExchange(0, 100, .seq_cst, .seq_cst);
    try std.testing.expect(failed != null);
    try std.testing.expectEqual(failed.?, 42);

    const success = counter.compareExchange(42, 100, .seq_cst, .seq_cst);
    try std.testing.expect(success == null);
    try std.testing.expectEqual(counter.load(.seq_cst), 100);
}

test "AtomicCounter concurrent increments" {
    var counter = AtomicCounter(u32).init(0);

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn f(c: *AtomicCounter(u32)) void {
                var i: u32 = 0;
                while (i < 100) : (i += 1) {
                    _ = c.fetchAdd(1, .seq_cst);
                }
            }
        }.f, .{&counter});
    }

    for (&threads) |*t| {
        t.join();
    }

    try std.testing.expectEqual(counter.load(.seq_cst), 400);
}
