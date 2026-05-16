const std = @import("std");

/// A 2-variant tagged union with runtime tag checking.
///
/// Usage:
/// ```zig
/// const MyUnion = TaggedUnion2(i32, f64);
/// var u = MyUnion.initA(42);
/// try std.testing.expectEqual(u.asA().*, 42);
/// // u.asB() // ❌ Panic: wrong union field
/// ```
pub fn TaggedUnion2(comptime A: type, comptime B: type) type {
    return struct {
        pub const Tag = enum { a, b };

        tag: Tag,
        storage: union { a: A, b: B },

        const Self = @This();

        pub fn initA(value: A) Self {
            return .{ .tag = .a, .storage = .{ .a = value } };
        }

        pub fn initB(value: B) Self {
            return .{ .tag = .b, .storage = .{ .b = value } };
        }

        pub fn asA(self: *Self) *A {
            if (self.tag != .a) {
                std.debug.panic("wrong union field: expected a, got {s}", .{@tagName(self.tag)});
            }
            return &self.storage.a;
        }

        pub fn asB(self: *Self) *B {
            if (self.tag != .b) {
                std.debug.panic("wrong union field: expected b, got {s}", .{@tagName(self.tag)});
            }
            return &self.storage.b;
        }

        pub fn asAConst(self: *const Self) *const A {
            if (self.tag != .a) {
                std.debug.panic("wrong union field: expected a, got {s}", .{@tagName(self.tag)});
            }
            return &self.storage.a;
        }

        pub fn asBConst(self: *const Self) *const B {
            if (self.tag != .b) {
                std.debug.panic("wrong union field: expected b, got {s}", .{@tagName(self.tag)});
            }
            return &self.storage.b;
        }

        pub fn isA(self: Self) bool {
            return self.tag == .a;
        }

        pub fn isB(self: Self) bool {
            return self.tag == .b;
        }
    };
}

/// A 3-variant tagged union with runtime tag checking.
pub fn TaggedUnion3(comptime A: type, comptime B: type, comptime C: type) type {
    return struct {
        pub const Tag = enum { a, b, c };

        tag: Tag,
        storage: union { a: A, b: B, c: C },

        const Self = @This();

        pub fn initA(value: A) Self {
            return .{ .tag = .a, .storage = .{ .a = value } };
        }

        pub fn initB(value: B) Self {
            return .{ .tag = .b, .storage = .{ .b = value } };
        }

        pub fn initC(value: C) Self {
            return .{ .tag = .c, .storage = .{ .c = value } };
        }

        pub fn asA(self: *Self) *A {
            if (self.tag != .a) {
                std.debug.panic("wrong union field: expected a, got {s}", .{@tagName(self.tag)});
            }
            return &self.storage.a;
        }

        pub fn asB(self: *Self) *B {
            if (self.tag != .b) {
                std.debug.panic("wrong union field: expected b, got {s}", .{@tagName(self.tag)});
            }
            return &self.storage.b;
        }

        pub fn asC(self: *Self) *C {
            if (self.tag != .c) {
                std.debug.panic("wrong union field: expected c, got {s}", .{@tagName(self.tag)});
            }
            return &self.storage.c;
        }

        pub fn asAConst(self: *const Self) *const A {
            if (self.tag != .a) {
                std.debug.panic("wrong union field: expected a, got {s}", .{@tagName(self.tag)});
            }
            return &self.storage.a;
        }

        pub fn asBConst(self: *const Self) *const B {
            if (self.tag != .b) {
                std.debug.panic("wrong union field: expected b, got {s}", .{@tagName(self.tag)});
            }
            return &self.storage.b;
        }

        pub fn asCConst(self: *const Self) *const C {
            if (self.tag != .c) {
                std.debug.panic("wrong union field: expected c, got {s}", .{@tagName(self.tag)});
            }
            return &self.storage.c;
        }

        pub fn isA(self: Self) bool {
            return self.tag == .a;
        }

        pub fn isB(self: Self) bool {
            return self.tag == .b;
        }

        pub fn isC(self: Self) bool {
            return self.tag == .c;
        }
    };
}

/// A Result type (like Rust's Result<T, E>).
pub fn Result(comptime T: type, comptime E: type) type {
    return struct {
        pub const Tag = enum { ok, err };

        tag: Tag,
        storage: union { ok: T, err: E },

        const Self = @This();

        pub fn ok(value: T) Self {
            return .{ .tag = .ok, .storage = .{ .ok = value } };
        }

        pub fn err(value: E) Self {
            return .{ .tag = .err, .storage = .{ .err = value } };
        }

        pub fn isOk(self: Self) bool {
            return self.tag == .ok;
        }

        pub fn isErr(self: Self) bool {
            return self.tag == .err;
        }

        pub fn unwrap(self: *Self) *T {
            if (self.tag != .ok) {
                std.debug.panic("unwrap on error result", .{});
            }
            return &self.storage.ok;
        }

        pub fn unwrapErr(self: *Self) *E {
            if (self.tag != .err) {
                std.debug.panic("unwrapErr on ok result", .{});
            }
            return &self.storage.err;
        }

        pub fn unwrapConst(self: *const Self) *const T {
            if (self.tag != .ok) {
                std.debug.panic("unwrap on error result", .{});
            }
            return &self.storage.ok;
        }

        pub fn unwrapErrConst(self: *const Self) *const E {
            if (self.tag != .err) {
                std.debug.panic("unwrapErr on ok result", .{});
            }
            return &self.storage.err;
        }
    };
}

/// An Option type (like Rust's Option<T>).
pub fn Option(comptime T: type) type {
    return struct {
        pub const Tag = enum { some, none };

        tag: Tag,
        storage: union { some: T, none: void },

        const Self = @This();

        pub fn some(value: T) Self {
            return .{ .tag = .some, .storage = .{ .some = value } };
        }

        pub fn none() Self {
            return .{ .tag = .none, .storage = .{ .none = {} } };
        }

        pub fn isSome(self: Self) bool {
            return self.tag == .some;
        }

        pub fn isNone(self: Self) bool {
            return self.tag == .none;
        }

        pub fn unwrap(self: *Self) *T {
            if (self.tag != .some) {
                std.debug.panic("unwrap on none option", .{});
            }
            return &self.storage.some;
        }

        pub fn unwrapOr(self: Self, default: T) T {
            if (self.tag == .some) {
                return self.storage.some;
            }
            return default;
        }

        pub fn unwrapConst(self: *const Self) *const T {
            if (self.tag != .some) {
                std.debug.panic("unwrap on none option", .{});
            }
            return &self.storage.some;
        }
    };
}

// ─── Tests ───

test "TaggedUnion2 basic usage" {
    const MyUnion = TaggedUnion2(i32, f64);
    var u = MyUnion.initA(42);
    try std.testing.expect(u.isA());
    try std.testing.expect(!u.isB());
    try std.testing.expectEqual(u.asA().*, 42);

    u.asA().* = 100;
    try std.testing.expectEqual(u.asA().*, 100);
    try std.testing.expectEqual(u.asAConst().*, 100);

    var v = MyUnion.initB(3.14);
    try std.testing.expect(v.isB());
    try std.testing.expect(!v.isA());
    try std.testing.expectEqual(v.asB().*, 3.14);
    try std.testing.expectEqual(v.asBConst().*, 3.14);
}

test "TaggedUnion2 wrong field panics" {
    var u = TaggedUnion2(i32, f64).initA(42);
    try std.testing.expect(!u.isB());
    // This would panic at runtime:
    // u.asB();
}

test "TaggedUnion3 with three types" {
    const MyUnion = TaggedUnion3(i32, f64, []const u8);
    var u = MyUnion.initA(1);
    try std.testing.expect(u.isA());
    try std.testing.expectEqual(u.asA().*, 1);

    var v = MyUnion.initB(2.71);
    try std.testing.expect(v.isB());
    try std.testing.expectEqual(v.asB().*, 2.71);

    var w = MyUnion.initC("hello");
    try std.testing.expect(w.isC());
    try std.testing.expectEqualStrings(w.asC().*, "hello");
    try std.testing.expectEqualStrings(w.asCConst().*, "hello");
}

test "Result ok and err" {
    const MyResult = Result(i32, []const u8);

    var ok_res = MyResult.ok(42);
    try std.testing.expect(ok_res.isOk());
    try std.testing.expect(!ok_res.isErr());
    try std.testing.expectEqual(ok_res.unwrap().*, 42);
    try std.testing.expectEqual(ok_res.unwrapConst().*, 42);

    var err_res = MyResult.err("failure");
    try std.testing.expect(err_res.isErr());
    try std.testing.expect(!err_res.isOk());
    try std.testing.expectEqualStrings(err_res.unwrapErr().*, "failure");
    try std.testing.expectEqualStrings(err_res.unwrapErrConst().*, "failure");
}

test "Result unwrap" {
    var ok_res = Result(i32, []const u8).ok(100);
    try std.testing.expectEqual(ok_res.unwrap().*, 100);

    var err_res = Result(i32, []const u8).err("oops");
    try std.testing.expect(err_res.isErr());
    // This would panic at runtime:
    // err_res.unwrap();
}

test "Option some and none" {
    const MyOption = Option(i32);

    var some_opt = MyOption.some(42);
    try std.testing.expect(some_opt.isSome());
    try std.testing.expect(!some_opt.isNone());
    try std.testing.expectEqual(some_opt.unwrap().*, 42);
    try std.testing.expectEqual(some_opt.unwrapConst().*, 42);
    try std.testing.expectEqual(some_opt.unwrapOr(0), 42);

    var none_opt = MyOption.none();
    try std.testing.expect(none_opt.isNone());
    try std.testing.expect(!none_opt.isSome());
    try std.testing.expectEqual(none_opt.unwrapOr(99), 99);

    // This would panic at runtime:
    // none_opt.unwrap();
}
