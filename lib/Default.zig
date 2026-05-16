const std = @import("std");

/// Return the default value for type `T` using comptime introspection.
///
/// Supported types:
/// - integers → 0
/// - floats → 0.0
/// - bools → false
/// - structs → recursive Default on each field
/// - unions → first variant with Default of its type
/// - enums → first enum value
/// - arrays → each element set to Default of child type
/// - optionals → null
/// - vectors → all lanes set to Default of child type
/// - void → {}
/// - string slices → ""
pub fn Default(comptime T: type) T {
    const info = @typeInfo(T);
    switch (info) {
        .int => return 0,
        .float => return 0.0,
        .bool => return false,
        .@"struct" => |s| {
            var val: T = undefined;
            inline for (s.fields) |field| {
                @field(val, field.name) = Default(field.type);
            }
            return val;
        },
        .@"union" => |u| {
            if (u.fields.len == 0) {
                @compileError("Cannot Default an empty union: " ++ @typeName(T));
            }
            return @unionInit(T, u.fields[0].name, Default(u.fields[0].type));
        },
        .@"enum" => |e| {
            if (e.fields.len == 0) {
                @compileError("Cannot Default an empty enum: " ++ @typeName(T));
            }
            return @enumFromInt(e.fields[0].value);
        },
        .array => |a| {
            var val: T = undefined;
            for (0..a.len) |i| {
                val[i] = Default(a.child);
            }
            return val;
        },
        .optional => return null,
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                return "";
            }
            @compileError("Cannot Default non-string slice pointer type: " ++ @typeName(T));
        },
        .void => return {},
        .vector => |v| {
            return @splat(Default(v.child));
        },
        else => @compileError("Default not implemented for type: " ++ @typeName(T)),
    }
}

// ─── Tests ───

test "Default integers" {
    try std.testing.expectEqual(@as(u8, 0), Default(u8));
    try std.testing.expectEqual(@as(i32, 0), Default(i32));
    try std.testing.expectEqual(@as(usize, 0), Default(usize));
}

test "Default floats" {
    try std.testing.expectEqual(@as(f32, 0.0), Default(f32));
    try std.testing.expectEqual(@as(f64, 0.0), Default(f64));
}

test "Default bool" {
    try std.testing.expectEqual(false, Default(bool));
}

test "Default struct" {
    const Point = struct {
        x: i32,
        y: i32,
    };
    const p = Default(Point);
    try std.testing.expectEqual(@as(i32, 0), p.x);
    try std.testing.expectEqual(@as(i32, 0), p.y);
}

test "Default nested struct" {
    const Inner = struct {
        val: f32,
    };
    const Outer = struct {
        inner: Inner,
        flag: bool,
    };
    const o = Default(Outer);
    try std.testing.expectEqual(@as(f32, 0.0), o.inner.val);
    try std.testing.expectEqual(false, o.flag);
}

test "Default union" {
    const MyUnion = union {
        int: i32,
        float: f64,
    };
    const u = Default(MyUnion);
    try std.testing.expectEqual(@as(i32, 0), u.int);
}

test "Default enum" {
    const Color = enum { red, green, blue };
    const c = Default(Color);
    try std.testing.expectEqual(Color.red, c);
}

test "Default array" {
    const arr = Default([3]i32);
    try std.testing.expectEqual(@as(i32, 0), arr[0]);
    try std.testing.expectEqual(@as(i32, 0), arr[1]);
    try std.testing.expectEqual(@as(i32, 0), arr[2]);
}

test "Default optional" {
    const maybe = Default(?i32);
    try std.testing.expectEqual(@as(?i32, null), maybe);
}

test "Default vector" {
    const v = Default(@Vector(4, f32));
    try std.testing.expectEqual(@as(f32, 0.0), v[0]);
    try std.testing.expectEqual(@as(f32, 0.0), v[3]);
}

test "Default void" {
    const v = Default(void);
    _ = v;
}

test "Default string slice" {
    const s = Default([]const u8);
    try std.testing.expectEqualStrings("", s);
}
