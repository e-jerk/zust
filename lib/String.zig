const std = @import("std");
const SimdUtils = @import("SimdUtils.zig");

/// A growable UTF-8 string that owns its buffer.
/// Similar to Rust's `String`.
pub const String = struct {
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create an empty string.
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .buffer = std.ArrayList(u8).empty,
            .allocator = allocator,
        };
    }

    /// Create an empty string (same as `init`).
    pub fn initDefault(allocator: std.mem.Allocator) Self {
        return init(allocator);
    }

    /// Create a string from an existing byte slice.
    pub fn initFromSlice(allocator: std.mem.Allocator, data: []const u8) !Self {
        var self = init(allocator);
        try self.buffer.appendSlice(allocator, data);
        return self;
    }

    /// Free the owned buffer.
    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    /// Append a byte slice to the end of the string.
    pub fn append(self: *Self, data: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, data);
    }

    /// Append a single byte to the end of the string.
    pub fn appendChar(self: *Self, char: u8) !void {
        try self.buffer.append(self.allocator, char);
    }

    /// Return the byte length of the string.
    pub fn len(self: *const Self) usize {
        return self.buffer.items.len;
    }

    /// Return true if the string has zero length.
    pub fn isEmpty(self: *const Self) bool {
        return self.buffer.items.len == 0;
    }

    /// Return an immutable view of the string contents.
    pub fn slice(self: *const Self) []const u8 {
        return self.buffer.items;
    }

    /// Clear the string, retaining the allocated capacity.
    pub fn clear(self: *Self) void {
        self.buffer.clearRetainingCapacity();
    }

    /// Create a deep copy of this string using the given allocator.
    pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
        return try initFromSlice(allocator, self.slice());
    }

    /// Return true if the string starts with the given prefix.
    pub fn startsWith(self: *const Self, prefix: []const u8) bool {
        return SimdUtils.startsWith(self.slice(), prefix);
    }

    /// Return true if the string ends with the given suffix.
    pub fn endsWith(self: *const Self, suffix: []const u8) bool {
        return SimdUtils.endsWith(self.slice(), suffix);
    }

    /// Return true if the string contains the given substring.
    pub fn contains(self: *const Self, needle: []const u8) bool {
        return SimdUtils.contains(self.slice(), needle);
    }

    /// Return the index of the first occurrence of the substring, or null.
    pub fn find(self: *const Self, needle: []const u8) ?usize {
        if (needle.len == 1) {
            return SimdUtils.findByte(self.slice(), needle[0]);
        }
        return std.mem.indexOf(u8, self.slice(), needle);
    }

    /// Return the index of the last occurrence of a byte, or null.
    pub fn findLast(self: *const Self, byte: u8) ?usize {
        return SimdUtils.findByteReverse(self.slice(), byte);
    }

    /// Return the count of non-overlapping occurrences of a substring.
    pub fn count(self: *const Self, needle: []const u8) u64 {
        return SimdUtils.countSubstring(self.slice(), needle);
    }

    /// Return a new string with leading chars from the set removed.
    pub fn trimLeft(self: *const Self, chars: []const u8) Self {
        return initFromSlice(self.allocator, SimdUtils.trimLeft(self.slice(), chars)) catch unreachable;
    }

    /// Return a new string with trailing chars from the set removed.
    pub fn trimRight(self: *const Self, chars: []const u8) Self {
        return initFromSlice(self.allocator, SimdUtils.trimRight(self.slice(), chars)) catch unreachable;
    }

    /// Return true if the string equals another string, case-insensitively (ASCII only).
    pub fn eqlIgnoreCase(self: *const Self, other: []const u8) bool {
        return SimdUtils.eqlIgnoreCase(self.slice(), other);
    }

    /// Replace all occurrences of `from` with `to` in place.
    pub fn replace(self: *Self, from: []const u8, to: []const u8) !void {
        const s = self.slice();
        var i: usize = 0;
        var new_buffer = std.ArrayList(u8).empty;
        errdefer new_buffer.deinit(self.allocator);

        while (i < s.len) {
            if (std.mem.indexOf(u8, s[i..], from)) |idx| {
                try new_buffer.appendSlice(self.allocator, s[i .. i + idx]);
                try new_buffer.appendSlice(self.allocator, to);
                i += idx + from.len;
            } else {
                try new_buffer.appendSlice(self.allocator, s[i..]);
                break;
            }
        }

        self.buffer.deinit(self.allocator);
        self.buffer = new_buffer;
    }

    /// Replace a byte range [start, end) with replacement text.
    pub fn replaceRange(self: *Self, start: usize, end: usize, replacement: []const u8) !void {
        const old_len = self.buffer.items.len;

        var new_buffer = std.ArrayList(u8).empty;
        errdefer new_buffer.deinit(self.allocator);

        try new_buffer.appendSlice(self.allocator, self.buffer.items[0..start]);
        try new_buffer.appendSlice(self.allocator, replacement);
        try new_buffer.appendSlice(self.allocator, self.buffer.items[end..old_len]);

        self.buffer.deinit(self.allocator);
        self.buffer = new_buffer;
    }

    /// Return a new string with leading and trailing whitespace removed.
    pub fn trim(self: *const Self) Self {
        return initFromSlice(self.allocator, std.mem.trim(u8, self.slice(), &std.ascii.whitespace)) catch unreachable;
    }

    /// Return a new string with leading whitespace removed.
    /// Return a new string with leading whitespace removed.
    pub fn trimStart(self: *const Self) Self {
        return initFromSlice(self.allocator, std.mem.trimStart(u8, self.slice(), &std.ascii.whitespace)) catch unreachable;
    }

    /// Return a new string with trailing whitespace removed.
    pub fn trimEnd(self: *const Self) Self {
        return initFromSlice(self.allocator, std.mem.trimEnd(u8, self.slice(), &std.ascii.whitespace)) catch unreachable;
    }

    pub const SplitIter = struct {
        slice: []const u8,
        delimiter: u8,
        index: usize,

        pub fn next(self: *SplitIter) ?[]const u8 {
            if (self.index >= self.slice.len) return null;
            const start = self.index;
            while (self.index < self.slice.len and self.slice[self.index] != self.delimiter) {
                self.index += 1;
            }
            const end = self.index;
            if (self.index < self.slice.len and self.slice[self.index] == self.delimiter) {
                self.index += 1;
            }
            return self.slice[start..end];
        }
    };

    /// Return an iterator that splits the string by the given delimiter.
    pub fn split(self: *const Self, delimiter: u8) SplitIter {
        return .{
            .slice = self.slice(),
            .delimiter = delimiter,
            .index = 0,
        };
    }

    /// Parse the string as a base-10 signed integer.
    pub fn toInt(self: *const Self) !i64 {
        return std.fmt.parseInt(i64, self.slice(), 10);
    }

    /// Append a formatted string to the end.
    pub fn appendFmt(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        const formatted = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(formatted);
        try self.append(formatted);
    }

    /// Iterator over lines (split by '\n').
    pub const LinesIter = struct {
        slice: []const u8,
        index: usize,

        pub fn next(self: *LinesIter) ?[]const u8 {
            if (self.index >= self.slice.len) return null;
            const start = self.index;
            while (self.index < self.slice.len and self.slice[self.index] != '\n') {
                self.index += 1;
            }
            const end = self.index;
            if (self.index < self.slice.len and self.slice[self.index] == '\n') {
                self.index += 1;
            }
            return self.slice[start..end];
        }
    };

    pub fn lines(self: *const Self) LinesIter {
        return .{ .slice = self.slice(), .index = 0 };
    }

    /// Iterator over bytes.
    pub const BytesIter = struct {
        slice: []const u8,
        index: usize,

        pub fn next(self: *BytesIter) ?u8 {
            if (self.index >= self.slice.len) return null;
            const b = self.slice[self.index];
            self.index += 1;
            return b;
        }
    };

    pub fn bytes(self: *const Self) BytesIter {
        return .{ .slice = self.slice(), .index = 0 };
    }

    pub const StringIterator = struct {
        bytes: []const u8,
        pos: usize,

        pub fn next(self: *StringIterator) ?u21 {
            if (self.pos >= self.bytes.len) return null;

            const seq_len = std.unicode.utf8ByteSequenceLength(self.bytes[self.pos]) catch {
                self.pos += 1;
                return self.next();
            };

            if (self.pos + seq_len > self.bytes.len) {
                self.pos = self.bytes.len;
                return null;
            }

            const cp = std.unicode.utf8Decode(self.bytes[self.pos .. self.pos + seq_len]) catch {
                self.pos += 1;
                return self.next();
            };

            self.pos += seq_len;
            return cp;
        }
    };

    pub fn iterator(self: *const Self) StringIterator {
        return .{
            .bytes = self.slice(),
            .pos = 0,
        };
    }
};

// === Tests ===

test "String init and deinit" {
    var s = String.init(std.testing.allocator);
    defer s.deinit();
    try std.testing.expect(s.isEmpty());
    try std.testing.expectEqual(s.len(), 0);
}

test "String initFromSlice and slice" {
    var s = try String.initFromSlice(std.testing.allocator, "hello");
    defer s.deinit();
    try std.testing.expectEqual(s.len(), 5);
    try std.testing.expectEqualStrings(s.slice(), "hello");
}

test "String append and appendChar" {
    var s = String.init(std.testing.allocator);
    defer s.deinit();

    try s.append("hel");
    try s.appendChar('l');
    try s.append("o");
    try std.testing.expectEqualStrings(s.slice(), "hello");
    try std.testing.expectEqual(s.len(), 5);
}

test "String clear" {
    var s = try String.initFromSlice(std.testing.allocator, "hello");
    defer s.deinit();

    s.clear();
    try std.testing.expect(s.isEmpty());
    try std.testing.expectEqual(s.len(), 0);
}

test "String clone" {
    var s = try String.initFromSlice(std.testing.allocator, "hello");
    defer s.deinit();

    var copy = try s.clone(std.testing.allocator);
    defer copy.deinit();

    try std.testing.expectEqualStrings(copy.slice(), "hello");
    try std.testing.expectEqual(copy.len(), 5);

    // Ensure they are independent
    try s.append(" world");
    try std.testing.expectEqualStrings(s.slice(), "hello world");
    try std.testing.expectEqualStrings(copy.slice(), "hello");
}

test "String empty after init" {
    var s = String.init(std.testing.allocator);
    defer s.deinit();
    try std.testing.expect(s.isEmpty());
    try std.testing.expectEqual(s.len(), 0);
    try std.testing.expectEqualStrings(s.slice(), "");
}

test "String initDefault" {
    var s = String.initDefault(std.testing.allocator);
    defer s.deinit();
    try std.testing.expect(s.isEmpty());
    try std.testing.expectEqual(s.len(), 0);
}

test "String startsWith" {
    var s = try String.initFromSlice(std.testing.allocator, "hello world");
    defer s.deinit();
    try std.testing.expect(s.startsWith("hello"));
    try std.testing.expect(!s.startsWith("world"));
}

test "String endsWith" {
    var s = try String.initFromSlice(std.testing.allocator, "hello world");
    defer s.deinit();
    try std.testing.expect(s.endsWith("world"));
    try std.testing.expect(!s.endsWith("hello"));
}

test "String contains" {
    var s = try String.initFromSlice(std.testing.allocator, "hello world");
    defer s.deinit();
    try std.testing.expect(s.contains("lo wo"));
    try std.testing.expect(!s.contains("xyz"));
}

test "String find" {
    var s = try String.initFromSlice(std.testing.allocator, "hello world");
    defer s.deinit();
    try std.testing.expectEqual(s.find("world"), 6);
    try std.testing.expectEqual(s.find("xyz"), null);
}

test "String findLast" {
    var s = try String.initFromSlice(std.testing.allocator, "hello world");
    defer s.deinit();
    try std.testing.expectEqual(s.findLast('l'), 9);
    try std.testing.expectEqual(s.findLast('z'), null);
}

test "String count" {
    var s = try String.initFromSlice(std.testing.allocator, "hello world");
    defer s.deinit();
    try std.testing.expectEqual(s.count("l"), 3);
    try std.testing.expectEqual(s.count("xyz"), 0);
}

test "String trimLeft" {
    var s = try String.initFromSlice(std.testing.allocator, "xxhello");
    defer s.deinit();
    var t = s.trimLeft("x");
    defer t.deinit();
    try std.testing.expectEqualStrings(t.slice(), "hello");
}

test "String trimRight" {
    var s = try String.initFromSlice(std.testing.allocator, "helloxx");
    defer s.deinit();
    var t = s.trimRight("x");
    defer t.deinit();
    try std.testing.expectEqualStrings(t.slice(), "hello");
}

test "String eqlIgnoreCase" {
    var s = try String.initFromSlice(std.testing.allocator, "Hello");
    defer s.deinit();
    try std.testing.expect(s.eqlIgnoreCase("hello"));
    try std.testing.expect(!s.eqlIgnoreCase("world"));
}

test "String replace single" {
    var s = try String.initFromSlice(std.testing.allocator, "hello world");
    defer s.deinit();
    try s.replace("world", "zig");
    try std.testing.expectEqualStrings(s.slice(), "hello zig");
}

test "String replace multiple" {
    var s = try String.initFromSlice(std.testing.allocator, "a,b,c");
    defer s.deinit();
    try s.replace(",", ";");
    try std.testing.expectEqualStrings(s.slice(), "a;b;c");
}

test "String trim" {
    var s = try String.initFromSlice(std.testing.allocator, "  hello  ");
    defer s.deinit();
    var t = s.trim();
    defer t.deinit();
    try std.testing.expectEqualStrings(t.slice(), "hello");
}

test "String trimStart" {
    var s = try String.initFromSlice(std.testing.allocator, "  hello");
    defer s.deinit();
    var t = s.trimStart();
    defer t.deinit();
    try std.testing.expectEqualStrings(t.slice(), "hello");
}

test "String trimEnd" {
    var s = try String.initFromSlice(std.testing.allocator, "hello  ");
    defer s.deinit();
    var t = s.trimEnd();
    defer t.deinit();
    try std.testing.expectEqualStrings(t.slice(), "hello");
}

test "String split" {
    var s = try String.initFromSlice(std.testing.allocator, "a,b,c");
    defer s.deinit();
    var it = s.split(',');
    try std.testing.expectEqualStrings(it.next().?, "a");
    try std.testing.expectEqualStrings(it.next().?, "b");
    try std.testing.expectEqualStrings(it.next().?, "c");
    try std.testing.expect(it.next() == null);
}

test "String split no delimiter" {
    var s = try String.initFromSlice(std.testing.allocator, "abc");
    defer s.deinit();
    var it = s.split(',');
    try std.testing.expectEqualStrings(it.next().?, "abc");
    try std.testing.expect(it.next() == null);
}

test "String toInt valid" {
    var s = try String.initFromSlice(std.testing.allocator, "-42");
    defer s.deinit();
    try std.testing.expectEqual(s.toInt(), -42);
}

test "String toInt invalid" {
    var s = try String.initFromSlice(std.testing.allocator, "not_a_number");
    defer s.deinit();
    try std.testing.expectError(error.InvalidCharacter, s.toInt());
}

test "String appendFmt" {
    var s = String.init(std.testing.allocator);
    defer s.deinit();
    try s.appendFmt("value={d}", .{42});
    try std.testing.expectEqualStrings(s.slice(), "value=42");
}

test "String appendFmt multiple" {
    var s = try String.initFromSlice(std.testing.allocator, "count: ");
    defer s.deinit();
    try s.appendFmt("{d} + {d} = {d}", .{ 1, 2, 3 });
    try std.testing.expectEqualStrings(s.slice(), "count: 1 + 2 = 3");
}

test "String lines" {
    var s = try String.initFromSlice(std.testing.allocator, "a\nb\nc");
    defer s.deinit();
    var it = s.lines();
    try std.testing.expectEqualStrings(it.next().?, "a");
    try std.testing.expectEqualStrings(it.next().?, "b");
    try std.testing.expectEqualStrings(it.next().?, "c");
    try std.testing.expect(it.next() == null);
}

test "String lines empty" {
    var s = String.init(std.testing.allocator);
    defer s.deinit();
    var it = s.lines();
    try std.testing.expect(it.next() == null);
}

test "String bytes" {
    var s = try String.initFromSlice(std.testing.allocator, "abc");
    defer s.deinit();
    var it = s.bytes();
    try std.testing.expectEqual(it.next().?, 'a');
    try std.testing.expectEqual(it.next().?, 'b');
    try std.testing.expectEqual(it.next().?, 'c');
    try std.testing.expect(it.next() == null);
}

test "String iterator UTF-8" {
    var s = try String.initFromSlice(std.testing.allocator, "Hello 世界");
    defer s.deinit();

    var it = s.iterator();
    try std.testing.expectEqual(it.next().?, 'H');
    try std.testing.expectEqual(it.next().?, 'e');
    try std.testing.expectEqual(it.next().?, 'l');
    try std.testing.expectEqual(it.next().?, 'l');
    try std.testing.expectEqual(it.next().?, 'o');
    try std.testing.expectEqual(it.next().?, ' ');
    try std.testing.expectEqual(it.next().?, '世');
    try std.testing.expectEqual(it.next().?, '界');
    try std.testing.expect(it.next() == null);
}
