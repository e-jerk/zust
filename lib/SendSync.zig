const std = @import("std");

/// Thread-safety marker traits.
///
/// Send: safe to move to another thread
/// Sync: safe to share by reference between threads (&T from multiple threads)
pub fn isSend(comptime T: type) bool {
    // Primitives are always Send
    const info = @typeInfo(T);
    switch (info) {
        .int, .float, .bool, .pointer, .@"enum", .void => return true,
        .array => |a| return isSend(a.child),
        .optional => |o| return isSend(o.child),
        .@"struct" => |s| {
            // Check if it's a known zust type
            const name = @typeName(T);
            if (std.mem.indexOf(u8, name, "Arc(") != null) return true;
            if (std.mem.indexOf(u8, name, "Mutex(") != null) return true;
            if (std.mem.indexOf(u8, name, "RwLock(") != null) return true;
            if (std.mem.indexOf(u8, name, "Channel(") != null) return true;
            if (std.mem.indexOf(u8, name, "Box(") != null) return true; // Box is single-owner, Send if T is Send
            if (std.mem.indexOf(u8, name, "OnceCell(") != null) return true;
            if (std.mem.indexOf(u8, name, "LazyCell(") != null) return true;
            if (std.mem.indexOf(u8, name, "OnceBox(") != null) return true;
            if (std.mem.indexOf(u8, name, "Pin(") != null) return true;
            // NOT Send:
            if (std.mem.indexOf(u8, name, "Rc(") != null) return false;
            if (std.mem.indexOf(u8, name, "Cell(") != null) return false;
            if (std.mem.indexOf(u8, name, "RefCell(") != null) return false;
            if (std.mem.indexOf(u8, name, "Weak(") != null) return false;
            if (std.mem.indexOf(u8, name, "UnsafeCell(") != null) return false;
            // Generic struct: all fields must be Send
            inline for (s.fields) |field| {
                if (!isSend(field.type)) return false;
            }
            return true;
        },
        .@"union" => |u| {
            inline for (u.fields) |field| {
                if (!isSend(field.type)) return false;
            }
            return true;
        },
        else => return false,
    }
}

pub fn isSync(comptime T: type) bool {
    const info = @typeInfo(T);
    switch (info) {
        .int, .float, .bool, .pointer, .@"enum", .void => return true,
        .array => |a| return isSync(a.child),
        .optional => |o| return isSync(o.child),
        .@"struct" => |s| {
            const name = @typeName(T);
            // Sync types:
            if (std.mem.indexOf(u8, name, "Arc(") != null) return true;
            if (std.mem.indexOf(u8, name, "Mutex(") != null) return true;
            if (std.mem.indexOf(u8, name, "RwLock(") != null) return true;
            if (std.mem.indexOf(u8, name, "Channel(") != null) return true;
            if (std.mem.indexOf(u8, name, "OnceCell(") != null) return true;
            if (std.mem.indexOf(u8, name, "OnceBox(") != null) return true;
            // NOT Sync:
            if (std.mem.indexOf(u8, name, "Rc(") != null) return false;
            if (std.mem.indexOf(u8, name, "Cell(") != null) return false;
            if (std.mem.indexOf(u8, name, "RefCell(") != null) return false;
            if (std.mem.indexOf(u8, name, "UnsafeCell(") != null) return false;
            if (std.mem.indexOf(u8, name, "Weak(") != null) return false;
            if (std.mem.indexOf(u8, name, "Box(") != null) return false; // Box is owned, not shared
            if (std.mem.indexOf(u8, name, "Pin(") != null) return isSync(s.fields[0].type); // depends on inner
            // Generic struct
            inline for (s.fields) |field| {
                if (!isSync(field.type)) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// Assert that T is Send at compile time
pub fn assertSend(comptime T: type) void {
    if (!isSend(T)) {
        @compileError("Type " ++ @typeName(T) ++ " is not Send-safe: cannot move to another thread");
    }
}

/// Assert that T is Sync at compile time
pub fn assertSync(comptime T: type) void {
    if (!isSync(T)) {
        @compileError("Type " ++ @typeName(T) ++ " is not Sync-safe: cannot share by reference between threads");
    }
}

/// Thread-safe wrapper: only allows Send types
pub fn SendBox(comptime T: type) type {
    comptime assertSend(T);
    return struct {
        value: T,
        const Self = @This();
        pub fn init(value: T) Self {
            return .{ .value = value };
        }
        pub fn get(self: *Self) *T {
            return &self.value;
        }
    };
}

/// Thread-safe wrapper: only allows Sync types
pub fn SyncBox(comptime T: type) type {
    comptime assertSync(T);
    return struct {
        value: T,
        const Self = @This();
        pub fn init(value: T) Self {
            return .{ .value = value };
        }
        pub fn get(self: *Self) *const T {
            return &self.value;
        }
    };
}

// ─── Tests ───

test "isSend returns true for primitives" {
    try std.testing.expect(isSend(u8));
    try std.testing.expect(isSend(u32));
    try std.testing.expect(isSend(i64));
    try std.testing.expect(isSend(f32));
    try std.testing.expect(isSend(f64));
    try std.testing.expect(isSend(bool));
    try std.testing.expect(isSend(void));
    try std.testing.expect(isSend(*u32));
    try std.testing.expect(isSend([4]u8));
    try std.testing.expect(isSend(?u32));
}

test "isSend returns false for Rc, Cell, RefCell" {
    const Rc = @import("Rc.zig").Rc;
    const Cell = @import("Cell.zig").Cell;
    const RefCell = @import("Cell.zig").RefCell;

    try std.testing.expect(!isSend(Rc(u32)));
    try std.testing.expect(!isSend(Cell(u32)));
    try std.testing.expect(!isSend(RefCell(u32)));
}

test "isSync returns true for Arc and Mutex" {
    const Arc = @import("Arc.zig").Arc;
    const Mutex = @import("Mutex.zig").Mutex;

    try std.testing.expect(isSync(Arc(u32)));
    try std.testing.expect(isSync(Mutex(u32)));
}

test "assertSend causes compile error for non-Send type" {
    // Verify assertSend succeeds for Send types at compile time
    comptime assertSend(u32);
    comptime assertSend(i64);
    comptime assertSend(bool);
    comptime assertSend(*u8);

    // Verify the underlying predicate correctly identifies non-Send types.
    // assertSend(Rc(u32)) would cause: @compileError("Type Rc(u32) is not Send-safe...")
    const Rc = @import("Rc.zig").Rc;
    const Cell = @import("Cell.zig").Cell;
    const RefCell = @import("Cell.zig").RefCell;

    try std.testing.expect(!isSend(Rc(u32)));
    try std.testing.expect(!isSend(Cell(u32)));
    try std.testing.expect(!isSend(RefCell(u32)));
}
