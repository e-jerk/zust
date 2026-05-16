const std = @import("std");
const Box = @import("Box.zig").Box;

/// Arena allocator that tracks allocation scope.
/// All allocations are freed together on reset().
/// Pointers become invalid after reset — tracked via generation counter.
pub fn Arena(comptime T: type) type {
    return struct {
        inner: std.heap.ArenaAllocator,
        generation: u32, // Incremented on each reset

        const Self = @This();

        pub fn init(child_allocator: std.mem.Allocator) Self {
            return .{
                .inner = std.heap.ArenaAllocator.init(child_allocator),
                .generation = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit();
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return self.inner.allocator();
        }

        /// Reset all allocations. All ArenaBox(T) values from this arena become invalid.
        pub fn reset(self: *Self) void {
            _ = self.inner.reset(.retain_capacity);
            self.generation += 1;
        }

        /// Allocate a single T in the arena. Returns an ArenaBox that tracks generation.
        pub fn alloc(self: *Self, value: T) !ArenaBox(T) {
            const ptr = try self.inner.allocator().create(T);
            ptr.* = value;
            return ArenaBox(T).init(ptr, &self.generation);
        }

        /// Create a Box from arena-allocated memory (transfers ownership out of arena)
        pub fn allocBox(self: *Self, value: T) !Box(T, 0, 0, 0) {
            // Copy value out of arena into a real Box
            return try Box(T, 0, 0, 0).init(self.inner.child_allocator, value);
        }
    };
}

/// A pointer to arena-allocated memory.
/// Tracks the arena generation; panics if used after arena reset.
pub fn ArenaBox(comptime T: type) type {
    return struct {
        ptr: *T,
        generation: *const u32, // Points to arena's generation counter
        birth_generation: u32, // Generation when this box was created

        const Self = @This();

        pub fn init(ptr: *T, generation: *const u32) Self {
            return .{
                .ptr = ptr,
                .generation = generation,
                .birth_generation = generation.*,
            };
        }

        pub fn get(self: Self) *T {
            if (self.generation.* != self.birth_generation) {
                std.debug.panic("use of ArenaBox after arena reset: generation {d} != {d}", .{ self.generation.*, self.birth_generation });
            }
            return self.ptr;
        }

        pub fn getConst(self: Self) *const T {
            if (self.generation.* != self.birth_generation) {
                std.debug.panic("use of ArenaBox after arena reset", .{});
            }
            return self.ptr;
        }

        pub fn isValid(self: Self) bool {
            return self.generation.* == self.birth_generation;
        }

        /// Promote to a real Box (copies value out of arena)
        pub fn toBox(self: Self, allocator: std.mem.Allocator) !Box(T, 0, 0, 0) {
            return try Box(T, 0, 0, 0).init(allocator, self.ptr.*);
        }
    };
}

// ─── Tests ───

test "Arena alloc and ArenaBox access" {
    var arena = Arena(u32).init(std.testing.allocator);
    defer arena.deinit();

    const box = try arena.alloc(42);
    try std.testing.expectEqual(box.get().*, 42);
    try std.testing.expectEqual(box.getConst().*, 42);
    try std.testing.expect(box.isValid());
}

test "Arena reset invalidates ArenaBox" {
    var arena = Arena(u32).init(std.testing.allocator);
    defer arena.deinit();

    const box = try arena.alloc(42);
    try std.testing.expectEqual(box.get().*, 42);

    arena.reset();
    try std.testing.expect(!box.isValid());
}

test "ArenaBox isValid after reset" {
    var arena = Arena(u32).init(std.testing.allocator);
    defer arena.deinit();

    const box1 = try arena.alloc(10);
    const box2 = try arena.alloc(20);
    try std.testing.expect(box1.isValid());
    try std.testing.expect(box2.isValid());

    arena.reset();

    try std.testing.expect(!box1.isValid());
    try std.testing.expect(!box2.isValid());

    // New allocations after reset are valid again
    const box3 = try arena.alloc(30);
    try std.testing.expect(box3.isValid());
    try std.testing.expectEqual(box3.get().*, 30);
}

test "Arena deinit cleanup" {
    var arena = Arena(u32).init(std.testing.allocator);

    _ = try arena.alloc(1);
    _ = try arena.alloc(2);
    _ = try arena.alloc(3);

    // deinit frees all arena memory
    arena.deinit();
}
