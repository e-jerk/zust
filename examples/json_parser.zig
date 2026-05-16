//! Safe JSON parser using zust ownership types.
//!
//! Demonstrates:
//! - safe.String — JSON string values
//! - safe.SmallString(255) — keys, type tags
//! - safe.ArrayList — arrays of values
//! - safe.HashMap — objects (key → value)
//! - safe.Box — owned AST nodes
//!
//! Uses a std.heap.ArenaAllocator for per-parse allocation
//! (safe.Arena(T) is type-specific; an untyped arena fits a
//! heterogeneous AST better). All nodes are freed in one shot.

const std = @import("std");
const safe = @import("safe");

const BoxValue = safe.Box(Value, 0, 0, 0);

const ParseError = error{
    UnexpectedEof,
    InvalidCharacter,
    InvalidNull,
    InvalidBool,
    InvalidEscape,
    ExpectedComma,
    ExpectedStringKey,
    ExpectedColon,
    OutOfMemory,
};

const Value = union(enum) {
    Null,
    Bool: bool,
    Number: f64,
    String: safe.String,
    Array: safe.ArrayList(Value),
    Object: safe.HashMap(Value),
};

const Parser = struct {
    input: []const u8,
    pos: usize,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return .{
            .input = input,
            .pos = 0,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    pub fn parse(self: *Parser) ParseError!BoxValue {
        self.skipWhitespace();
        return try self.parseValue();
    }

    fn parseValue(self: *Parser) ParseError!BoxValue {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.UnexpectedEof;

        const ch = self.input[self.pos];
        switch (ch) {
            'n' => return try self.parseNull(),
            't', 'f' => return try self.parseBool(),
            '"' => return try self.parseString(),
            '[' => return try self.parseArray(),
            '{' => return try self.parseObject(),
            '-', '0'...'9' => return try self.parseNumber(),
            else => return error.InvalidCharacter,
        }
    }

    fn parseNull(self: *Parser) ParseError!BoxValue {
        if (!std.mem.startsWith(u8, self.input[self.pos..], "null")) return error.InvalidNull;
        self.pos += 4;
        return try BoxValue.init(self.arena.allocator(), .Null);
    }

    fn parseBool(self: *Parser) ParseError!BoxValue {
        if (std.mem.startsWith(u8, self.input[self.pos..], "true")) {
            self.pos += 4;
            return try BoxValue.init(self.arena.allocator(), .{ .Bool = true });
        } else if (std.mem.startsWith(u8, self.input[self.pos..], "false")) {
            self.pos += 5;
            return try BoxValue.init(self.arena.allocator(), .{ .Bool = false });
        }
        return error.InvalidBool;
    }

    fn parseNumber(self: *Parser) ParseError!BoxValue {
        const start = self.pos;
        if (self.input[self.pos] == '-') self.pos += 1;
        while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) self.pos += 1;
        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) self.pos += 1;
        }
        const num_str = self.input[start..self.pos];
        const num = try std.fmt.parseFloat(f64, num_str);
        return try BoxValue.init(self.arena.allocator(), .{ .Number = num });
    }

    fn parseString(self: *Parser) ParseError!BoxValue {
        std.debug.assert(self.input[self.pos] == '"');
        self.pos += 1;
        var str = safe.String.init(self.arena.allocator());
        errdefer str.deinit();

        while (self.pos < self.input.len and self.input[self.pos] != '"') {
            if (self.input[self.pos] == '\\') {
                self.pos += 1;
                if (self.pos >= self.input.len) return error.UnexpectedEof;
                switch (self.input[self.pos]) {
                    'n' => try str.append("\n"),
                    't' => try str.append("\t"),
                    'r' => try str.append("\r"),
                    '"' => try str.append("\""),
                    '\\' => try str.append("\\"),
                    else => return error.InvalidEscape,
                }
            } else {
                try str.appendChar(self.input[self.pos]);
            }
            self.pos += 1;
        }

        if (self.pos >= self.input.len) return error.UnexpectedEof;
        self.pos += 1; // skip closing quote

        return try BoxValue.init(self.arena.allocator(), .{ .String = str });
    }

    fn parseArray(self: *Parser) ParseError!BoxValue {
        std.debug.assert(self.input[self.pos] == '[');
        self.pos += 1;
        var arr = safe.ArrayList(Value).init(self.arena.allocator());
        errdefer arr.deinit();

        self.skipWhitespace();
        if (self.pos < self.input.len and self.input[self.pos] == ']') {
            self.pos += 1;
            return try BoxValue.init(self.arena.allocator(), .{ .Array = arr });
        }

        while (true) {
            const val = try self.parseValue();
            try arr.append(val);
            self.skipWhitespace();
            if (self.pos >= self.input.len) return error.UnexpectedEof;
            if (self.input[self.pos] == ']') {
                self.pos += 1;
                break;
            }
            if (self.input[self.pos] != ',') return error.ExpectedComma;
            self.pos += 1;
        }

        return try BoxValue.init(self.arena.allocator(), .{ .Array = arr });
    }

    fn parseObject(self: *Parser) ParseError!BoxValue {
        std.debug.assert(self.input[self.pos] == '{');
        self.pos += 1;
        var obj = safe.HashMap(Value).init(self.arena.allocator());
        errdefer obj.deinit();

        self.skipWhitespace();
        if (self.pos < self.input.len and self.input[self.pos] == '}') {
            self.pos += 1;
            return try BoxValue.init(self.arena.allocator(), .{ .Object = obj });
        }

        while (true) {
            self.skipWhitespace();
            if (self.input[self.pos] != '"') return error.ExpectedStringKey;
            const key_box = try self.parseString();
            const key_str = key_box.ptr.String;
            var small_key = safe.SmallString(255).initFromSlice(key_str.slice());
            const dead_key_box = key_box.deinit();
            _ = dead_key_box;

            self.skipWhitespace();
            if (self.pos >= self.input.len or self.input[self.pos] != ':') return error.ExpectedColon;
            self.pos += 1;

            const val = try self.parseValue();
            try obj.put(small_key.slice(), val);

            self.skipWhitespace();
            if (self.pos >= self.input.len) return error.UnexpectedEof;
            if (self.input[self.pos] == '}') {
                self.pos += 1;
                break;
            }
            if (self.input[self.pos] != ',') return error.ExpectedComma;
            self.pos += 1;
        }

        return try BoxValue.init(self.arena.allocator(), .{ .Object = obj });
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }
    }
};

fn printValue(value: *Value, indent: usize) void {
    switch (value.*) {
        .Null => std.debug.print("null", .{}),
        .Bool => |b| std.debug.print("{}", .{b}),
        .Number => |n| std.debug.print("{d}", .{n}),
        .String => |s| std.debug.print("\"{s}\"", .{s.slice()}),
        .Array => |*arr| {
            std.debug.print("[\n", .{});
            for (0..arr.len()) |i| {
                if (arr.borrowImm(i)) |borrow| {
                    defer borrow.releaseImm();
                    for (0..indent + 2) |_| std.debug.print(" ", .{});
                    printValue(borrow.box.ptr, indent + 2);
                    if (i + 1 < arr.len()) std.debug.print(",", .{});
                    std.debug.print("\n", .{});
                }
            }
            for (0..indent) |_| std.debug.print(" ", .{});
            std.debug.print("]", .{});
        },
        .Object => |*obj| {
            std.debug.print("{{\n", .{});
            var it = obj.map.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) std.debug.print(",\n", .{});
                first = false;
                for (0..indent + 2) |_| std.debug.print(" ", .{});
                std.debug.print("\"{s}\": ", .{entry.key_ptr.*});
                printValue(&entry.value_ptr.ptr.*, indent + 2);
            }
            std.debug.print("\n", .{});
            for (0..indent) |_| std.debug.print(" ", .{});
            std.debug.print("}}", .{});
        },
    }
}

fn queryValue(value: *Value, path: []const u8) ?*Value {
    var current = value;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |segment| {
        switch (current.*) {
            .Object => |*obj| {
                const maybe_borrow = obj.borrowImm(segment);
                if (maybe_borrow) |borrow| {
                    defer borrow.releaseImm();
                    current = borrow.box.ptr;
                } else {
                    return null;
                }
            },
            else => return null,
        }
    }
    return current;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const json =
        \\{
        \\  "name": "Alice",
        \\  "age": 30,
        \\  "active": true,
        \\  "address": {
        \\    "city": "Wonderland",
        \\    "zip": 12345
        \\  },
        \\  "tags": ["zig", "json", "safe"]
        \\}
    ;

    var parser = Parser.init(allocator, json);
    defer parser.deinit();

    const value = try parser.parse();
    defer {
        const dead = value.deinit();
        _ = dead;
    }

    std.debug.print("=== Parsed JSON ===\n", .{});
    printValue(value.ptr, 0);
    std.debug.print("\n\n", .{});

    std.debug.print("=== Path Queries ===\n", .{});
    if (queryValue(value.ptr, "name")) |v| {
        std.debug.print("name = ", .{});
        printValue(v, 0);
        std.debug.print("\n", .{});
    }
    if (queryValue(value.ptr, "address.city")) |v| {
        std.debug.print("address.city = ", .{});
        printValue(v, 0);
        std.debug.print("\n", .{});
    }
    if (queryValue(value.ptr, "tags")) |v| {
        std.debug.print("tags = ", .{});
        printValue(v, 0);
        std.debug.print("\n", .{});
    }
    if (queryValue(value.ptr, "nonexistent")) |v| {
        printValue(v, 0);
    } else {
        std.debug.print("nonexistent = null\n", .{});
    }
}
