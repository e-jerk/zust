const std = @import("std");

/// A pointer type that enforces alignment at compile time.
/// Prevents misaligned access UB.
pub fn AlignedPtr(comptime T: type, comptime align_bits: u29) type {
    return struct {
        ptr: *align(align_bits) T,

        const Self = @This();

        pub fn init(p: *align(align_bits) T) Self {
            return .{ .ptr = p };
        }

        /// Check alignment at runtime and wrap the pointer.
        /// Returns null if the raw pointer is not sufficiently aligned.
        pub fn fromRaw(raw: *T) ?Self {
            if (@intFromPtr(raw) % align_bits != 0) return null;
            return init(@ptrCast(@alignCast(raw)));
        }

        pub fn get(self: Self) *align(align_bits) T {
            return self.ptr;
        }

        pub fn getConst(self: Self) *align(align_bits) const T {
            return self.ptr;
        }

        pub fn read(self: Self) T {
            return self.ptr.*;
        }

        pub fn write(self: Self, value: T) void {
            self.ptr.* = value;
        }

        /// Offset by n elements. Returns null if the resulting
        /// address would no longer satisfy the required alignment.
        pub fn offset(self: Self, n: isize) ?Self {
            const base_addr = @intFromPtr(self.ptr);
            const byte_offset = @as(isize, n) * @as(isize, @intCast(@sizeOf(T)));
            const new_addr = @as(usize, @intCast(@as(isize, @intCast(base_addr)) + byte_offset));
            if (new_addr % align_bits != 0) return null;
            const raw_ptr: *align(1) T = @ptrFromInt(new_addr);
            return init(@ptrCast(@alignCast(raw_ptr)));
        }
    };
}

/// Wraps a value with cache-line padding to prevent false sharing between threads.
pub fn CacheAligned(comptime T: type) type {
    const CACHE_LINE_SIZE = 64;
    const padding_size = CACHE_LINE_SIZE - (@sizeOf(T) % CACHE_LINE_SIZE);
    const total_size = if (padding_size == CACHE_LINE_SIZE) @sizeOf(T) else @sizeOf(T) + padding_size;

    return struct {
        value: T,
        _padding: [total_size - @sizeOf(T)]u8 = undefined,

        const Self = @This();

        pub fn init(v: T) Self {
            return .{ .value = v };
        }

        pub fn get(self: *Self) *T {
            return &self.value;
        }

        pub fn getConst(self: *const Self) *const T {
            return &self.value;
        }

        pub fn load(self: *Self) T {
            return self.value;
        }

        pub fn store(self: *Self, v: T) void {
            self.value = v;
        }
    };
}

// ─── Tests ───

test "AlignedPtr basic read/write" {
    var x: u32 align(8) = 42;
    const raw: *u32 = &x;
    const aligned = AlignedPtr(u32, 8).fromRaw(raw).?;

    try std.testing.expectEqual(aligned.read(), 42);
    aligned.write(100);
    try std.testing.expectEqual(aligned.read(), 100);
}

test "AlignedPtr rejects misaligned pointer" {
    var buf: [4]u8 align(4) = undefined;
    const raw: *u8 = &buf[1];
    try std.testing.expectEqual(@as(?AlignedPtr(u8, 2), null), AlignedPtr(u8, 2).fromRaw(raw));
}

test "CacheAligned wraps value" {
    var ca = CacheAligned(u32).init(42);
    try std.testing.expectEqual(ca.load(), 42);
    ca.store(100);
    try std.testing.expectEqual(ca.load(), 100);
    try std.testing.expectEqual(ca.get().*, 100);
}

test "CacheAligned size is multiple of 64" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(CacheAligned(u32)));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(CacheAligned(u64)));
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(CacheAligned([65]u8)));
}

test "AlignedPtr offset maintains alignment" {
    var arr: [8]u32 align(16) = .{ 10, 20, 30, 40, 50, 60, 70, 80 };
    const raw: *u32 = &arr[0];
    const aligned = AlignedPtr(u32, 16).fromRaw(raw).?;

    // Offset by 1 element (4 bytes) crosses the 16-byte boundary → null
    try std.testing.expectEqual(@as(?AlignedPtr(u32, 16), null), aligned.offset(1));

    // Offset by 4 elements (16 bytes) stays on the 16-byte boundary → valid
    const shifted = aligned.offset(4);
    try std.testing.expect(shifted != null);
    try std.testing.expectEqual(shifted.?.read(), arr[4]);
}
