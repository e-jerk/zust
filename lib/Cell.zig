const std = @import("std");

/// Single-threaded interior mutability via copying.
/// Similar to Rust's `std::cell::Cell<T>`.
///
/// Enforces that `T` is `Copy` at compile time.
/// Provides zero-cost `get`/`set`/`replace` operations.
pub fn Cell(comptime T: type) type {
    comptime assertIsCopy(T);
    return struct {
        value: T,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{ .value = value };
        }

        /// Returns a copy of the value.
        pub fn get(self: Self) T {
            return self.value;
        }

        /// Overwrites the value.
        pub fn set(self: *Self, value: T) void {
            self.value = value;
        }

        /// Overwrites and returns the old value.
        pub fn replace(self: *Self, value: T) T {
            const old = self.value;
            self.value = value;
            return old;
        }

        /// Applies a function to the value.
        pub fn update(self: *Self, comptime f: fn (T) T) void {
            self.value = f(self.value);
        }
    };
}

/// Single-threaded runtime borrow checking.
/// Similar to Rust's `std::cell::RefCell<T>`.
///
/// Tracks outstanding borrows at runtime.
/// `borrow()` returns `Ref(T)` — panics if mutable borrow is active.
/// `borrowMut()` returns `RefMut(T)` — panics if any borrows are active.
pub fn RefCell(comptime T: type) type {
    return struct {
        value: T,
        borrow_count: u32 = 0,
        borrow_mut_active: bool = false,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{ .value = value };
        }

        /// Immutably borrow the value.
        /// Panics if a mutable borrow is active.
        pub fn borrow(self: *Self) Ref(T) {
            if (self.borrow_mut_active) {
                @panic("already mutably borrowed");
            }
            self.borrow_count += 1;
            return .{ .cell = self };
        }

        /// Mutably borrow the value.
        /// Panics if any borrows (mutable or immutable) are active.
        pub fn borrowMut(self: *Self) RefMut(T) {
            if (self.borrow_count > 0 or self.borrow_mut_active) {
                @panic("already borrowed");
            }
            self.borrow_mut_active = true;
            return .{ .cell = self };
        }

        /// Get a copy (requires T: Copy).
        pub fn get(self: Self) T {
            comptime assertIsCopy(T);
            return self.value;
        }

        /// Overwrite the value.
        pub fn set(self: *Self, value: T) void {
            self.value = value;
        }

        /// Overwrite and return old value (requires T: Copy).
        pub fn replace(self: *Self, value: T) T {
            comptime assertIsCopy(T);
            const old = self.value;
            self.value = value;
            return old;
        }
    };
}

/// Immutable borrow guard for RefCell<T>.
/// Decrements borrow count on drop.
pub fn Ref(comptime T: type) type {
    return struct {
        cell: *RefCell(T),

        const Self = @This();

        pub fn deinit(self: Self) void {
            self.cell.borrow_count -= 1;
        }

        pub fn get(self: Self) *const T {
            return &self.cell.value;
        }
    };
}

/// Mutable borrow guard for RefCell<T>.
/// Clears mutable borrow flag on drop.
pub fn RefMut(comptime T: type) type {
    return struct {
        cell: *RefCell(T),

        const Self = @This();

        pub fn deinit(self: Self) void {
            self.cell.borrow_mut_active = false;
        }

        pub fn get(self: Self) *const T {
            return &self.cell.value;
        }

        pub fn getMut(self: Self) *T {
            return &self.cell.value;
        }
    };
}

fn assertIsCopy(comptime T: type) void {
    // For simplicity, accept scalar types and arrays of scalars
    // A full Copy check would require recursive struct analysis
    const info = @typeInfo(T);
    const ok = switch (info) {
        .int, .float, .bool, .pointer => true,
        .array => |a| switch (@typeInfo(a.child)) {
            .int, .float, .bool => true,
            else => false,
        },
        .optional => |o| switch (@typeInfo(o.child)) {
            .int, .float, .bool, .pointer => true,
            else => false,
        },
        .void => true,
        .comptime_int, .comptime_float => true,
        else => false,
    };
    if (!ok) {
        @compileError("Cell requires Copy type, got: " ++ @typeName(T));
    }
}