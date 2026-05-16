const std = @import("std");
const String = @import("String.zig").String;

/// Clone-on-write wrapper.
///
/// Holds either a borrowed or owned value of type `T`.
/// For now supports `[]const u8` and `String`.
///
/// * Borrowed: no allocation; `deinit` does nothing.
/// * Owned: value was cloned; `deinit` frees the clone.
pub fn Cow(comptime T: type) type {
    const is_string = T == String;

    comptime {
        if (T != []const u8 and !is_string) {
            @compileError("Cow only supports []const u8 and String");
        }
    }

    return struct {
        value: T,
        allocator: ?std.mem.Allocator,
        owned: bool,

        const Self = @This();

        /// Wrap a borrowed value (no allocation, no clone).
        pub fn initBorrowed(value: T) Self {
            return .{
                .value = value,
                .allocator = null,
                .owned = false,
            };
        }

        /// Wrap an owned value (clones the input).
        pub fn initOwned(allocator: std.mem.Allocator, value: T) !Self {
            if (is_string) {
                const copy = try value.clone(allocator);
                return .{
                    .value = copy,
                    .allocator = allocator,
                    .owned = true,
                };
            } else {
                const copy = try allocator.dupe(u8, value);
                return .{
                    .value = copy,
                    .allocator = allocator,
                    .owned = true,
                };
            }
        }

        /// Free the owned value if we own it.
        pub fn deinit(self: *Self) void {
            if (self.owned) {
                if (self.allocator) |alloc| {
                    if (is_string) {
                        self.value.deinit();
                    } else {
                        alloc.free(self.value);
                    }
                }
            }
            self.owned = false;
        }

        /// Get the current value.
        pub fn get(self: *const Self) T {
            return self.value;
        }

        /// Ensure the value is owned, cloning if it was borrowed.
        /// Returns the owned value; the Cow is also updated to own it.
        pub fn toOwned(self: *Self, allocator: std.mem.Allocator) !T {
            if (self.owned) {
                return self.value;
            }

            if (is_string) {
                const copy = try self.value.clone(allocator);
                self.value = copy;
                self.allocator = allocator;
                self.owned = true;
                return copy;
            } else {
                const copy = try allocator.dupe(u8, self.value);
                self.value = copy;
                self.allocator = allocator;
                self.owned = true;
                return copy;
            }
        }

        /// Return true if the value is currently borrowed.
        pub fn isBorrowed(self: *const Self) bool {
            return !self.owned;
        }
    };
}

// === Tests ===

test "Cow([]const u8) borrowed lifecycle" {
    const original: []const u8 = "hello";
    var cow = Cow([]const u8).initBorrowed(original);
    defer cow.deinit();

    try std.testing.expect(cow.isBorrowed());
    try std.testing.expectEqualStrings(cow.get(), "hello");
}

test "Cow([]const u8) owned init and deinit" {
    const original: []const u8 = "hello";
    var cow = try Cow([]const u8).initOwned(std.testing.allocator, original);
    defer cow.deinit();

    try std.testing.expect(!cow.isBorrowed());
    try std.testing.expectEqualStrings(cow.get(), "hello");
}

test "Cow([]const u8) toOwned clones borrowed" {
    const original: []const u8 = "hello";
    var cow = Cow([]const u8).initBorrowed(original);
    defer cow.deinit();

    try std.testing.expect(cow.isBorrowed());

    const owned = try cow.toOwned(std.testing.allocator);
    // cow is now owned and will clean up in defer;
    // `owned` points to the same allocation, so don't free separately.
    try std.testing.expect(!cow.isBorrowed());
    try std.testing.expectEqualStrings(owned, "hello");
    try std.testing.expectEqualStrings(cow.get(), "hello");
}

test "Cow(String) owned init and deinit" {
    var original = try String.initFromSlice(std.testing.allocator, "hello");
    defer original.deinit();

    var cow = try Cow(String).initOwned(std.testing.allocator, original);
    defer cow.deinit();

    try std.testing.expect(!cow.isBorrowed());
    try std.testing.expectEqualStrings(cow.get().slice(), "hello");

    // Ensure independence from original
    try original.append(" world");
    try std.testing.expectEqualStrings(cow.get().slice(), "hello");
}

test "Cow(String) borrowed toOwned clones" {
    var original = try String.initFromSlice(std.testing.allocator, "hello");
    defer original.deinit();

    var cow = Cow(String).initBorrowed(original);
    defer cow.deinit();

    try std.testing.expect(cow.isBorrowed());

    const owned = try cow.toOwned(std.testing.allocator);
    _ = owned;

    try std.testing.expect(!cow.isBorrowed());
    try std.testing.expectEqualStrings(cow.get().slice(), "hello");

    // Ensure independence from original
    try original.append(" world");
    try std.testing.expectEqualStrings(cow.get().slice(), "hello");
}
