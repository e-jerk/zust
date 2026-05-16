/// Interior mutability for non-Copy types.
/// Unlike Cell<T> which requires Copy, UnsafeCell<T> allows mutation through shared references.
/// This is the building block for RefCell, Mutex, etc.
pub fn UnsafeCell(comptime T: type) type {
    return struct {
        value: T,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{ .value = value };
        }

        /// Get a mutable pointer to the inner value.
        /// Safe because we track borrows at the higher level (RefCell, Mutex).
        pub fn getMut(self: *Self) *T {
            return &self.value;
        }

        /// Get a const pointer.
        pub fn get(self: *const Self) *const T {
            return &self.value;
        }

        /// Replace the value and return the old one.
        pub fn replace(self: *Self, new_value: T) T {
            const old = self.value;
            self.value = new_value;
            return old;
        }

        pub fn intoInner(self: Self) T {
            return self.value;
        }
    };
}

// ─── Tests ───

test "UnsafeCell init and getMut" {
    var cell = UnsafeCell(u32).init(42);
    try @import("std").testing.expectEqual(@as(u32, 42), cell.get().*);
    cell.getMut().* = 100;
    try @import("std").testing.expectEqual(@as(u32, 100), cell.get().*);
}

test "UnsafeCell replace" {
    var cell = UnsafeCell(u32).init(42);
    const old = cell.replace(100);
    try @import("std").testing.expectEqual(@as(u32, 42), old);
    try @import("std").testing.expectEqual(@as(u32, 100), cell.intoInner());
}

test "UnsafeCell intoInner" {
    var cell = UnsafeCell(u32).init(42);
    const inner = cell.intoInner();
    try @import("std").testing.expectEqual(@as(u32, 42), inner);
}
