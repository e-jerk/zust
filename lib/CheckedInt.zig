//! CheckedInt and SaturatingInt: safe integer arithmetic wrappers.
//! CheckedInt returns errors on overflow/underflow.
//! SaturatingInt clamps to max/min on overflow/underflow.

const std = @import("std");

pub const OverflowError = error{ Overflow, Underflow, DivisionByZero };

pub fn CheckedInt(comptime T: type) type {
    comptime std.debug.assert(@typeInfo(T) == .int);

    return struct {
        value: T,

        const Self = @This();

        pub fn init(v: T) Self {
            return .{ .value = v };
        }

        pub fn add(self: Self, other: Self) OverflowError!Self {
            const result, const overflow = @addWithOverflow(self.value, other.value);
            if (overflow != 0) return error.Overflow;
            return init(result);
        }

        pub fn sub(self: Self, other: Self) OverflowError!Self {
            const result, const overflow = @subWithOverflow(self.value, other.value);
            if (overflow != 0) return error.Underflow;
            return init(result);
        }

        pub fn mul(self: Self, other: Self) OverflowError!Self {
            const result, const overflow = @mulWithOverflow(self.value, other.value);
            if (overflow != 0) return error.Overflow;
            return init(result);
        }

        pub fn div(self: Self, other: Self) OverflowError!Self {
            if (other.value == 0) return error.DivisionByZero;
            return init(@divTrunc(self.value, other.value));
        }

        pub fn get(self: Self) T {
            return self.value;
        }

        pub fn eq(self: Self, other: Self) bool {
            return self.value == other.value;
        }

        pub fn lt(self: Self, other: Self) bool {
            return self.value < other.value;
        }

        pub fn gt(self: Self, other: Self) bool {
            return self.value > other.value;
        }

        pub fn le(self: Self, other: Self) bool {
            return self.value <= other.value;
        }

        pub fn ge(self: Self, other: Self) bool {
            return self.value >= other.value;
        }
    };
}

pub fn SaturatingInt(comptime T: type) type {
    comptime std.debug.assert(@typeInfo(T) == .int);

    return struct {
        value: T,

        const Self = @This();

        pub fn init(v: T) Self {
            return .{ .value = v };
        }

        pub fn add(self: Self, other: Self) Self {
            const result, const overflow = @addWithOverflow(self.value, other.value);
            if (overflow != 0) {
                if (other.value > 0) {
                    return init(std.math.maxInt(T));
                } else {
                    return init(std.math.minInt(T));
                }
            }
            return init(result);
        }

        pub fn sub(self: Self, other: Self) Self {
            const result, const overflow = @subWithOverflow(self.value, other.value);
            if (overflow != 0) {
                if (other.value > 0) {
                    return init(std.math.minInt(T));
                } else {
                    return init(std.math.maxInt(T));
                }
            }
            return init(result);
        }

        pub fn mul(self: Self, other: Self) Self {
            const result, const overflow = @mulWithOverflow(self.value, other.value);
            if (overflow != 0) {
                const is_positive = (self.value > 0 and other.value > 0) or
                    (self.value < 0 and other.value < 0);
                if (is_positive) {
                    return init(std.math.maxInt(T));
                } else {
                    return init(std.math.minInt(T));
                }
            }
            return init(result);
        }

        pub fn div(self: Self, other: Self) Self {
            if (other.value == 0) {
                // Division by zero saturates to max int (same as Rust's saturating_div for unsigned,
                // but for signed we also handle it — here we return max as a safe clamp)
                return init(std.math.maxInt(T));
            }
            // Handle T_min / -1 overflow for signed types
            if (@typeInfo(T).int.signedness == .signed and
                self.value == std.math.minInt(T) and
                other.value == -1)
            {
                return init(std.math.maxInt(T));
            }
            return init(@divTrunc(self.value, other.value));
        }

        pub fn get(self: Self) T {
            return self.value;
        }

        pub fn eq(self: Self, other: Self) bool {
            return self.value == other.value;
        }

        pub fn lt(self: Self, other: Self) bool {
            return self.value < other.value;
        }

        pub fn gt(self: Self, other: Self) bool {
            return self.value > other.value;
        }

        pub fn le(self: Self, other: Self) bool {
            return self.value <= other.value;
        }

        pub fn ge(self: Self, other: Self) bool {
            return self.value >= other.value;
        }
    };
}

// ─── Tests ───

test "CheckedInt add overflow" {
    const C = CheckedInt(u8);
    const a = C.init(200);
    const b = C.init(100);
    const result = a.add(b);
    try std.testing.expectError(error.Overflow, result);
}

test "CheckedInt sub underflow" {
    const C = CheckedInt(i8);
    const a = C.init(-100);
    const b = C.init(50);
    const result = a.sub(b);
    try std.testing.expectError(error.Underflow, result);
}

test "CheckedInt div by zero" {
    const C = CheckedInt(u32);
    const a = C.init(42);
    const b = C.init(0);
    const result = a.div(b);
    try std.testing.expectError(error.DivisionByZero, result);
}

test "SaturatingInt add saturates at max" {
    const S = SaturatingInt(u8);
    const a = S.init(200);
    const b = S.init(100);
    const result = a.add(b);
    try std.testing.expectEqual(result.get(), std.math.maxInt(u8));
}

test "SaturatingInt sub saturates at min" {
    const S = SaturatingInt(u8);
    const a = S.init(10);
    const b = S.init(50);
    const result = a.sub(b);
    try std.testing.expectEqual(result.get(), std.math.minInt(u8));
}

test "SaturatingInt mul overflow" {
    const S = SaturatingInt(u8);
    const a = S.init(20);
    const b = S.init(20);
    const result = a.mul(b);
    try std.testing.expectEqual(result.get(), std.math.maxInt(u8));
}
