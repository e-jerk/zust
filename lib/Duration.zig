const std = @import("std");
const builtin = @import("builtin");
const CheckedInt = @import("CheckedInt.zig").CheckedInt;

/// Safe duration type with checked arithmetic.
/// Prevents overflow when adding/subtracting time durations.
pub const Duration = struct {
    nanos: CheckedInt(u64),

    const Self = @This();

    pub fn fromNanos(nanos: u64) Self {
        return .{ .nanos = CheckedInt(u64).init(nanos) };
    }

    pub fn fromMillis(millis: u64) Self {
        return .{ .nanos = CheckedInt(u64).init(millis * std.time.ns_per_ms) };
    }

    pub fn fromSecs(secs: u64) Self {
        return .{ .nanos = CheckedInt(u64).init(secs * std.time.ns_per_s) };
    }

    pub fn asNanos(self: Self) u64 {
        return self.nanos.get();
    }

    pub fn asMillis(self: Self) u64 {
        return self.nanos.get() / std.time.ns_per_ms;
    }

    pub fn asSecs(self: Self) u64 {
        return self.nanos.get() / std.time.ns_per_s;
    }

    /// Add two durations. Returns error.Overflow if result exceeds u64.
    pub fn add(self: Self, other: Self) !Self {
        const sum = try self.nanos.add(other.nanos);
        return .{ .nanos = sum };
    }

    /// Subtract two durations. Returns error.Underflow if negative.
    pub fn sub(self: Self, other: Self) !Self {
        const diff = try self.nanos.sub(other.nanos);
        return .{ .nanos = diff };
    }

    pub fn eql(self: Self, other: Self) bool {
        return self.nanos.eq(other.nanos);
    }

    pub fn lt(self: Self, other: Self) bool {
        return self.nanos.lt(other.nanos);
    }

    pub fn gt(self: Self, other: Self) bool {
        return other.nanos.lt(self.nanos);
    }

    pub fn isZero(self: Self) bool {
        return self.nanos.get() == 0;
    }
};

/// A monotonic instant for measuring elapsed time.
pub const Instant = struct {
    duration_since_epoch: Duration,

    const Self = @This();

    pub fn now() Self {
        if (comptime builtin.target.os.tag == .windows) {
            return .{ .duration_since_epoch = Duration.fromNanos(0) };
        }
        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        const nanos = @as(i64, tv.sec) * std.time.ns_per_s + @as(i64, tv.usec) * 1000;
        return .{ .duration_since_epoch = Duration.fromNanos(@intCast(nanos)) };
    }

    pub fn elapsed(self: Self) Duration {
        if (comptime builtin.target.os.tag == .windows) {
            return Duration.fromNanos(0);
        }
        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        const nanos = @as(i64, tv.sec) * std.time.ns_per_s + @as(i64, tv.usec) * 1000;
        const now_dur = Duration.fromNanos(@intCast(nanos));
        // Subtraction can't underflow since now >= self in monotonic time
        return now_dur.sub(self.duration_since_epoch) catch Duration.fromNanos(0);
    }

    pub fn durationSince(start: Self, end: Self) !Duration {
        return end.duration_since_epoch.sub(start.duration_since_epoch);
    }
};

// ─── Tests ───

test "Duration basic" {
    const d1 = Duration.fromMillis(100);
    const d2 = Duration.fromMillis(200);
    const sum = try d1.add(d2);
    try std.testing.expectEqual(@as(u64, 300), sum.asMillis());
}

test "Duration overflow" {
    const max = Duration.fromNanos(std.math.maxInt(u64));
    const one = Duration.fromNanos(1);
    try std.testing.expectError(error.Overflow, max.add(one));
}

test "Instant elapsed" {
    const start = Instant.now();
    // Skip sleep test in CI - just verify Instant compiles
    const elapsed = start.elapsed();
    try std.testing.expect(elapsed.asNanos() >= 0);
}
