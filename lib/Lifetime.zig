const std = @import("std");
const Box = @import("Box.zig").Box;

/// Monotonically increasing scope counter. Each lexical scope gets a unique ID.
var global_scope_counter: std.atomic.Value(u32) = .init(0);

/// Unique identifier for a lexical scope.
pub const ScopeId = u32;

/// Get the current global scope counter value.
pub fn currentScope() ScopeId {
    return global_scope_counter.load(.seq_cst);
}

/// Enter a new scope. Returns the new scope ID.
pub fn enterScope() ScopeId {
    return global_scope_counter.fetchAdd(1, .seq_cst);
}

/// A reference to stack-allocated memory.
///
/// Safe to use ONLY within the same lexical scope where it was created,
/// or within enclosing scopes. If a `ScopeGuard` is used, this will
/// runtime-panic on use-after-scope-exit.
pub fn StackRef(comptime T: type) type {
    return struct {
        ptr: *T,
        scope_id: ScopeId,
        valid: bool,

        const Self = @This();

        /// Create a stack reference tied to the given scope.
        pub fn init(scope_id: ScopeId, ptr: *T) Self {
            return .{
                .ptr = ptr,
                .scope_id = scope_id,
                .valid = true,
            };
        }

        /// Access the referenced value. Panics if the scope has been exited.
        pub fn get(self: Self) *T {
            if (!self.valid) @panic("use of dangling stack reference: scope has exited");
            return self.ptr;
        }

        /// Access the referenced value immutably. Panics if the scope has been exited.
        pub fn getConst(self: Self) *const T {
            if (!self.valid) @panic("use of dangling stack reference: scope has exited");
            return self.ptr;
        }

        /// Mark this reference as invalid (called by ScopeGuard on scope exit).
        pub fn invalidate(self: *Self) void {
            self.valid = false;
        }

        /// Check whether the reference is still valid.
        pub fn isValid(self: Self) bool {
            return self.valid;
        }

        /// Safely convert to a heap Box by copying the value.
        pub fn toBox(self: Self, allocator: std.mem.Allocator) !Box(T) {
            return try Box(T).init(allocator, self.ptr.*);
        }
    };
}

/// RAII scope guard that invalidates tracked StackRefs on scope exit.
///
/// Usage:
/// ```zig
/// const scope = enterScope();
/// var guard = ScopeGuard(u32).init(scope);
/// defer guard.deinit(std.testing.allocator);
/// var ref = StackRef(u32).init(scope, &x);
/// try guard.track(std.testing.allocator, &ref);
/// ```
pub fn ScopeGuard(comptime T: type) type {
    return struct {
        refs: std.ArrayList(*StackRef(T)),
        scope_id: ScopeId,

        const Self = @This();

        pub fn init(scope_id: ScopeId) Self {
            return .{
                .refs = .empty,
                .scope_id = scope_id,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.refs.items) |ref| {
                ref.invalidate();
            }
            self.refs.deinit(allocator);
        }

        pub fn track(self: *Self, allocator: std.mem.Allocator, ref: *StackRef(T)) !void {
            try self.refs.append(allocator, ref);
        }
    };
}

/// A non-null pointer wrapper.
///
/// Encodes in the type system that the pointer is never null.
/// Similar to Rust's `std::ptr::NonNull<T>`.
pub fn NonNull(comptime T: type) type {
    return struct {
        ptr: *T,

        const Self = @This();

        pub fn new(ptr: *T) Self {
            return .{ .ptr = ptr };
        }

        pub fn asPtr(self: Self) *T {
            return self.ptr;
        }

        pub fn asOpt(self: Self) *T {
            return self.ptr;
        }

        pub fn asConst(self: Self) *const T {
            return self.ptr;
        }
    };
}

// ─── Tests ───

test "StackRef basic usage" {
    const scope = enterScope();
    var x: u32 = 42;
    var ref = StackRef(u32).init(scope, &x);
    try std.testing.expectEqual(ref.get().*, 42);
    try std.testing.expectEqual(ref.getConst().*, 42);
    try std.testing.expect(ref.isValid());
}

test "StackRef toBox" {
    const scope = enterScope();
    var x: u32 = 42;
    var ref = StackRef(u32).init(scope, &x);
    const box = try ref.toBox(std.testing.allocator);
    defer _ = box.deinit();
    try std.testing.expectEqual(box.ptr.*, 42);
}

test "ScopeGuard invalidates refs on deinit" {
    const scope = enterScope();
    var x: u32 = 42;

    var guard = ScopeGuard(u32).init(scope);
    defer guard.deinit(std.testing.allocator);

    var ref = StackRef(u32).init(scope, &x);
    try guard.track(std.testing.allocator, &ref);

    try std.testing.expectEqual(ref.get().*, 42);
    try std.testing.expect(ref.isValid());
}

test "ScopeGuard explicit deinit invalidates refs" {
    const scope = enterScope();
    var x: u32 = 42;

    var guard = ScopeGuard(u32).init(scope);
    var ref = StackRef(u32).init(scope, &x);
    try guard.track(std.testing.allocator, &ref);

    try std.testing.expectEqual(ref.get().*, 42);
    try std.testing.expect(ref.isValid());

    // Simulate scope exit by deiniting the guard explicitly
    guard.deinit(std.testing.allocator);

    try std.testing.expect(!ref.isValid());
}

test "NonNull basic usage" {
    var x: u32 = 42;
    const nn = NonNull(u32).new(&x);
    try std.testing.expectEqual(nn.asPtr().*, 42);
    try std.testing.expectEqual(nn.asConst().*, 42);
}
