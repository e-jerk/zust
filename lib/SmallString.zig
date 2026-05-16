const std = @import("std");
const SimdUtils = @import("SimdUtils.zig");

/// Small String Optimized (SSO) string.
/// Stores up to `inline_capacity` bytes inline on the stack.
/// Only allocates on the heap for larger strings.
///
/// Similar to Rust's `smallvec` or C++'s SSO `std::string`.
pub fn SmallString(comptime inline_capacity: usize) type {
    return struct {
        // Inline storage (stack)
        inline_buf: [inline_capacity]u8,
        inline_len: u8,

        // Heap storage (for strings > inline_capacity)
        heap_ptr: ?[]u8,
        heap_len: usize,
        heap_cap: usize,

        allocator: ?std.mem.Allocator,

        const Self = @This();

        pub fn init() Self {
            return .{
                .inline_buf = undefined,
                .inline_len = 0,
                .heap_ptr = null,
                .heap_len = 0,
                .heap_cap = 0,
                .allocator = null,
            };
        }

        pub fn initFromSlice(data: []const u8) Self {
            var self = init();
            if (data.len <= inline_capacity) {
                @memcpy(self.inline_buf[0..data.len], data);
                self.inline_len = @intCast(data.len);
            } else {
                // Would need allocator for heap — can't do in init without allocator param
                // Just store what fits inline
                @memcpy(self.inline_buf[0..inline_capacity], data[0..inline_capacity]);
                self.inline_len = inline_capacity;
            }
            return self;
        }

        pub fn initWithAlloc(allocator: std.mem.Allocator, data: []const u8) !Self {
            var self = init();
            self.allocator = allocator;
            if (data.len <= inline_capacity) {
                @memcpy(self.inline_buf[0..data.len], data);
                self.inline_len = @intCast(data.len);
            } else {
                const heap = try allocator.alloc(u8, data.len);
                @memcpy(heap, data);
                self.heap_ptr = heap;
                self.heap_len = data.len;
                self.heap_cap = data.len;
                self.inline_len = inline_capacity + 1; // Signal: using heap
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.heap_ptr) |ptr| {
                if (self.allocator) |alloc| {
                    alloc.free(ptr);
                }
                self.heap_ptr = null;
            }
        }

        pub fn isHeap(self: *Self) bool {
            return self.inline_len > inline_capacity;
        }

        pub fn isInline(self: *Self) bool {
            return self.inline_len <= inline_capacity;
        }

        pub fn len(self: *Self) usize {
            if (self.isInline()) {
                return self.inline_len;
            }
            return self.heap_len;
        }

        pub fn slice(self: *Self) []const u8 {
            if (self.isInline()) {
                return self.inline_buf[0..self.inline_len];
            }
            if (self.heap_ptr) |ptr| {
                return ptr[0..self.heap_len];
            }
            return &[_]u8{};
        }

        pub fn append(self: *Self, bytes: []const u8) !void {
            const current_len = self.len();
            const new_len = current_len + bytes.len;

            if (new_len <= inline_capacity) {
                // Stay inline
                @memcpy(self.inline_buf[current_len..new_len], bytes);
                self.inline_len = @intCast(new_len);
            } else {
                // Move to heap
                if (self.allocator) |alloc| {
                    const new_cap = new_len * 2;
                    const new_heap = try alloc.alloc(u8, new_cap);

                    // Copy existing
                    @memcpy(new_heap[0..current_len], self.slice());
                    @memcpy(new_heap[current_len..new_len], bytes);

                    // Free old heap if any
                    if (self.heap_ptr) |old| alloc.free(old);

                    self.heap_ptr = new_heap;
                    self.heap_len = new_len;
                    self.heap_cap = new_cap;
                    self.inline_len = inline_capacity + 1;
                } else {
                    return error.NoAllocator;
                }
            }
        }

        pub fn appendChar(self: *Self, char: u8) !void {
            try self.append(&[_]u8{char});
        }

        pub fn clone(self: *Self, allocator: std.mem.Allocator) !Self {
            return try initWithAlloc(allocator, self.slice());
        }

        pub fn clear(self: *Self) void {
            if (self.isHeap()) {
                // Keep heap allocation, just zero length
                self.heap_len = 0;
            }
            self.inline_len = 0;
        }

        pub fn startsWith(self: *Self, prefix: []const u8) bool {
            return SimdUtils.startsWith(self.slice(), prefix);
        }

        pub fn endsWith(self: *Self, suffix: []const u8) bool {
            return SimdUtils.endsWith(self.slice(), suffix);
        }

        pub fn contains(self: *Self, needle: []const u8) bool {
            if (needle.len == 1) {
                return SimdUtils.findByte(self.slice(), needle[0]) != null;
            }
            return std.mem.indexOf(u8, self.slice(), needle) != null;
        }
    };
}

/// Type alias: SmallString with 23-byte inline capacity (common SSO size)
pub const SmallString23 = SmallString(23);

/// Type alias: SmallString with 15-byte inline capacity
pub const SmallString15 = SmallString(15);

// === Tests ===

test "SmallString inline storage (no allocation)" {
    var s = SmallString(23).initFromSlice("hello");
    try std.testing.expect(s.isInline());
    try std.testing.expect(!s.isHeap());
    try std.testing.expectEqual(s.len(), 5);
    try std.testing.expectEqualStrings(s.slice(), "hello");
}

test "SmallString heap promotion when growing" {
    var s = try SmallString(5).initWithAlloc(std.testing.allocator, "hello");
    defer s.deinit();

    try std.testing.expect(s.isInline());
    try std.testing.expectEqualStrings(s.slice(), "hello");

    // Append to trigger heap promotion
    try s.append(" world");
    try std.testing.expect(s.isHeap());
    try std.testing.expectEqual(s.len(), 11);
    try std.testing.expectEqualStrings(s.slice(), "hello world");
}

test "SmallString append and slice" {
    var s = SmallString(23).init();
    try std.testing.expectEqual(s.len(), 0);
    try std.testing.expectEqualStrings(s.slice(), "");

    try s.append("hel");
    try s.appendChar('l');
    try s.append("o");
    try std.testing.expectEqualStrings(s.slice(), "hello");
    try std.testing.expectEqual(s.len(), 5);
}

test "SmallString startsWith/endsWith/contains" {
    var s = try SmallString(23).initWithAlloc(std.testing.allocator, "hello world");
    defer s.deinit();

    try std.testing.expect(s.startsWith("hello"));
    try std.testing.expect(!s.startsWith("world"));

    try std.testing.expect(s.endsWith("world"));
    try std.testing.expect(!s.endsWith("hello"));

    try std.testing.expect(s.contains("lo wo"));
    try std.testing.expect(!s.contains("xyz"));
}

test "SmallString15 alias works" {
    var s = SmallString15.initFromSlice("hi");
    try std.testing.expect(s.isInline());
    try std.testing.expectEqual(s.len(), 2);
    try std.testing.expectEqualStrings(s.slice(), "hi");

    var s2 = try SmallString15.initWithAlloc(std.testing.allocator, "this is a long string");
    defer s2.deinit();
    try std.testing.expect(s2.isHeap());
    try std.testing.expectEqualStrings(s2.slice(), "this is a long string");
}
