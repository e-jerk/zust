const std = @import("std");
const Default = @import("Default.zig").Default;

/// Typestate-encoded owned heap value.
///
/// `state_tag`: 0=Owned, 1=BorrowedImm, 2=BorrowedMut, 3=Moved, 4=Freed
/// `imm_count`: number of active immutable borrows
/// `mut_count`: number of active mutable borrows (0 or 1)
pub fn Box(comptime T: type, comptime state_tag: u32, comptime imm_count: u32, comptime mut_count: u32) type {
    // Sanity-check state consistency at the type level.
    comptime {
        if (state_tag == 0) {
            if (mut_count > 0) @compileError("Owned state with active mutable borrow");
        } else if (state_tag == 1) {
            if (mut_count > 0) @compileError("BorrowedImm state with active mutable borrow");
            if (imm_count == 0) @compileError("BorrowedImm state with zero borrow count");
        } else if (state_tag == 2) {
            if (imm_count > 0) @compileError("BorrowedMut state with active immutable borrows");
            if (mut_count != 1) @compileError("BorrowedMut state without exactly one mutable borrow");
        } else if (state_tag == 3) {
            if (imm_count > 0 or mut_count > 0) @compileError("Moved state with active borrows");
        } else if (state_tag == 4) {
            if (imm_count > 0 or mut_count > 0) @compileError("Freed state with active borrows");
        }
    }

    return struct {
        ptr: *T,
        allocator: std.mem.Allocator,

        const Self = @This();

        // ─── Creation ───

        /// Allocate and wrap a value. Returns Box in Owned state.
        pub fn init(allocator: std.mem.Allocator, value: T) !Box(T, 0, 0, 0) {
            const ptr = try allocator.create(T);
            ptr.* = value;
            return .{ .ptr = ptr, .allocator = allocator };
        }

        /// Allocate and wrap the default value for `T`.
        pub fn initDefault(allocator: std.mem.Allocator) !Box(T, 0, 0, 0) {
            return init(allocator, Default(T));
        }

        // ─── Immutable borrow ───

        /// Acquire an immutable borrow. Returns a Box in BorrowedImm state.
        pub fn borrowImm(self: Self) Box(T, 1, imm_count + 1, mut_count) {
            comptime if (mut_count > 0)
                @compileError("cannot borrow immutably: active mutable borrow exists");
            comptime if (state_tag == 3)
                @compileError("cannot borrow: value has been moved");
            comptime if (state_tag == 4)
                @compileError("cannot borrow: value has been freed");

            return .{ .ptr = self.ptr, .allocator = self.allocator };
        }

        /// Release an immutable borrow. Returns a Box with decremented imm count.
        pub fn releaseImm(self: Self) Box(T, if (imm_count == 1) 0 else 1, imm_count - 1, mut_count) {
            comptime if (state_tag != 1)
                @compileError("cannot release immutable borrow: not in borrowed state");
            comptime if (imm_count == 0)
                @compileError("cannot release: no active immutable borrows");

            return .{ .ptr = self.ptr, .allocator = self.allocator };
        }

        // ─── Mutable borrow ───

        /// Acquire a mutable borrow. Returns a Box in BorrowedMut state.
        pub fn borrowMut(self: Self) Box(T, 2, 0, 1) {
            comptime if (imm_count > 0)
                @compileError("cannot borrow mutably: active immutable borrows exist");
            comptime if (mut_count > 0)
                @compileError("cannot borrow mutably: active mutable borrow exists");
            comptime if (state_tag != 0)
                @compileError("cannot borrow mutably: value is not in Owned state");

            return .{ .ptr = self.ptr, .allocator = self.allocator };
        }

        /// Release a mutable borrow. Returns a Box in Owned state.
        pub fn releaseMut(self: Self) Box(T, 0, 0, 0) {
            comptime if (state_tag != 2)
                @compileError("cannot release mutable borrow: not in mutable borrow state");
            comptime if (mut_count != 1)
                @compileError("cannot release: no active mutable borrow");

            return .{ .ptr = self.ptr, .allocator = self.allocator };
        }

        // ─── Deallocation ───

        /// Destroy the owned value. Returns Box in Freed state.
        /// The caller must assign the result to capture the state transition.
        pub fn deinit(self: Self) Box(T, 4, 0, 0) {
            comptime if (state_tag == 4)
                @compileError("double free detected");
            comptime if (state_tag != 0)
                @compileError("cannot free: value is not in Owned state");
            comptime if (imm_count > 0 or mut_count > 0)
                @compileError("cannot free while active borrows exist");

            self.allocator.destroy(self.ptr);
            return .{ .ptr = undefined, .allocator = self.allocator };
        }

        // ─── Closure API (zero-cost, borrow never escapes) ───

        /// Execute a callback with an immutable borrow. The borrow is lexical.
        pub fn withImm(self: Self, context: anytype, comptime cb: fn (@TypeOf(context), *const T) void) void {
            comptime if (state_tag == 3)
                @compileError("cannot borrow: value has been moved");
            comptime if (state_tag == 4)
                @compileError("cannot borrow: value has been freed");
            comptime if (mut_count > 0)
                @compileError("cannot borrow immutably: active mutable borrow exists");

            cb(context, self.ptr);
        }

        /// Execute a callback with a mutable borrow. The borrow is lexical.
        pub fn withMut(self: *Self, context: anytype, comptime cb: fn (@TypeOf(context), *T) void) void {
            comptime if (state_tag == 3)
                @compileError("cannot borrow: value has been moved");
            comptime if (state_tag == 4)
                @compileError("cannot borrow: value has been freed");
            comptime if (imm_count > 0 or mut_count > 0)
                @compileError("cannot borrow mutably: other borrows are active");
            comptime if (state_tag != 0)
                @compileError("cannot borrow mutably: value is not in Owned state");

            cb(context, self.ptr);
        }

        // ─── Escape hatch ───

        /// Unsafely extract the raw pointer. Safety boundary ends here.
        pub fn unsafePtr(self: Self) *T {
            comptime if (state_tag == 4)
                @compileError("cannot get pointer to freed value");
            return self.ptr;
        }

        /// Intentionally leak the Box and return a permanent reference.
        /// The memory will never be freed. After calling this, do NOT call deinit().
        /// Similar to Rust's `Box::leak()`.
        pub fn leak(self: Self) *T {
            comptime if (state_tag == 4)
                @compileError("cannot leak: value has been freed");
            return self.ptr;
        }
    };
}

// ─── Tests ───

test "Box leak" {
    const box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    const ptr = box.leak();
    try std.testing.expectEqual(ptr.*, 42);
    // In real usage the memory would be leaked; here we free manually
    // so the test allocator doesn't report a leak.
    std.testing.allocator.destroy(ptr);
}

test "Box initDefault" {
    const box = try Box(u32, 0, 0, 0).initDefault(std.testing.allocator);
    try std.testing.expectEqual(box.ptr.*, 0);
    const dead = box.deinit();
    _ = dead;
}
