const std = @import("std");
const Box = @import("Box.zig").Box;
const BoxStateful = @import("Box.zig").BoxStateful;

/// A hash map that owns `Box(T)` values keyed by strings.
/// All values are stored in Owned state. Accessing a value borrows it
/// from the map. The map tracks how many outstanding borrows exist.
pub fn HashMap(comptime T: type) type {
    return struct {
        map: std.StringHashMap(Box(T)),
        allocator: std.mem.Allocator,
        outstanding_imm: u32 = 0,
        outstanding_mut: u32 = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .map = std.StringHashMap(Box(T)).init(allocator),
                .allocator = allocator,
            };
        }

        /// Create an empty map (same as `init`).
        pub fn initDefault(allocator: std.mem.Allocator) Self {
            return init(allocator);
        }

        pub fn deinit(self: *Self) void {
            if (self.outstanding_imm > 0) {
                @panic("cannot deinit HashMap while active immutable borrows exist");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot deinit HashMap while active mutable borrow exists");
            }

            // Deinit all owned boxes
            var iter = self.map.iterator();
            while (iter.next()) |kv| {
                const dead = kv.value_ptr.deinit();
                _ = dead;
                self.allocator.free(kv.key_ptr.*);
            }
            self.map.deinit();
        }

        pub fn put(self: *Self, key: []const u8, box: Box(T)) !void {
            if (self.outstanding_mut > 0) {
                @panic("cannot put while HashMap is mutably borrowed");
            }
            const key_copy = try self.allocator.dupe(u8, key);
            const result = try self.map.getOrPut(key_copy);
            if (result.found_existing) {
                // Replace existing value: deinit old box and free the key copy
                const dead = result.value_ptr.deinit();
                _ = dead;
                self.allocator.free(key_copy);
                result.value_ptr.* = box;
            } else {
                result.value_ptr.* = box;
            }
        }

        /// Get a value by transferring ownership OUT of the map.
        /// Panics if the map has active borrows.
        pub fn get(self: *Self, key: []const u8) ?Box(T) {
            if (self.outstanding_imm > 0) {
                @panic("cannot get while HashMap has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot get while HashMap has active mutable borrow");
            }
            const ptr = self.map.getPtr(key) orelse return null;
            const box = ptr.*;
            // Remove from map and free key
            if (self.map.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
            }
            return box;
        }

        /// Get a mutable reference to a value (borrows mutably from the map).
        pub fn getMut(self: *Self, key: []const u8) ?struct {
            box: BoxStateful(T, 2, 0, 1),
            map: *Self,

            const Borrow = @This();

            pub fn releaseMut(b: Borrow) void {
                b.map.outstanding_mut -= 1;
            }
        } {
            if (self.outstanding_imm > 0) {
                @panic("cannot getMut while HashMap has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot getMut while HashMap is already mutably borrowed");
            }
            const ptr = self.map.getPtr(key) orelse return null;
            self.outstanding_mut += 1;
            return .{
                .box = ptr.borrowMut(),
                .map = self,
            };
        }

        pub fn remove(self: *Self, key: []const u8) ?Box(T) {
            if (self.outstanding_imm > 0) {
                @panic("cannot remove while HashMap has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot remove while HashMap is mutably borrowed");
            }
            const ptr = self.map.getPtr(key) orelse return null;
            const box = ptr.*;
            // Free the key and remove the entry
            if (self.map.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
            }
            return box;
        }

        pub fn retain(self: *Self, context: anytype, comptime pred: fn (@TypeOf(context), []const u8, *const T) bool) void {
            if (self.outstanding_imm > 0) {
                @panic("cannot retain while HashMap has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot retain while HashMap is mutably borrowed");
            }

            var iter = self.map.iterator();
            while (iter.next()) |map_entry| {
                if (!pred(context, map_entry.key_ptr.*, &map_entry.value_ptr.ptr.*)) {
                    const dead = map_entry.value_ptr.deinit();
                    _ = dead;
                    const key = map_entry.key_ptr.*;
                    if (self.map.fetchRemove(key)) |kv| {
                        self.allocator.free(kv.key);
                    }
                }
            }
        }

        pub fn drain(self: *Self) DrainIter {
            return .{ .map = self };
        }

        pub const DrainIter = struct {
            map: *Self,

            pub fn next(self: *DrainIter) ?struct { key: []const u8, value: Box(T) } {
                var iter = self.map.map.iterator();
                const map_entry = iter.next() orelse return null;
                const key = map_entry.key_ptr.*;
                const value = map_entry.value_ptr.*;
                _ = self.map.map.remove(key);
                return .{ .key = key, .value = value };
            }
        };

        pub fn clear(self: *Self) void {
            if (self.outstanding_imm > 0) {
                @panic("cannot clear while HashMap has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot clear while HashMap is mutably borrowed");
            }

            var iter = self.map.iterator();
            while (iter.next()) |map_entry| {
                const dead = map_entry.value_ptr.deinit();
                _ = dead;
                self.allocator.free(map_entry.key_ptr.*);
            }
            self.map.clearRetainingCapacity();
        }

        pub fn contains(self: *const Self, key: []const u8) bool {
            return self.map.contains(key);
        }

        pub fn len(self: *const Self) usize {
            return self.map.count();
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.map.count() == 0;
        }

        pub fn borrowImm(self: *Self, key: []const u8) ?struct {
            box: BoxStateful(T, 1, 1, 0),
            map: *Self,

            const Borrow = @This();

            pub fn releaseImm(b: Borrow) void {
                b.map.outstanding_imm -= 1;
            }
        } {
            if (self.outstanding_mut > 0) {
                @panic("cannot borrow immutably: active mutable borrow on HashMap");
            }
            const ptr = self.map.getPtr(key) orelse return null;
            self.outstanding_imm += 1;
            return .{
                .box = ptr.borrowImm(),
                .map = self,
            };
        }

        pub fn borrowMut(self: *Self, key: []const u8) ?struct {
            box: BoxStateful(T, 2, 0, 1),
            map: *Self,

            const Borrow = @This();

            pub fn releaseMut(b: Borrow) void {
                b.map.outstanding_mut -= 1;
            }
        } {
            if (self.outstanding_imm > 0) {
                @panic("cannot borrow mutably: active immutable borrows on HashMap");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot borrow mutably: already mutably borrowed");
            }
            const ptr = self.map.getPtr(key) orelse return null;
            self.outstanding_mut += 1;
            return .{
                .box = ptr.borrowMut(),
                .map = self,
            };
        }

        /// Return a consuming iterator over the map.
        /// Each call to next() removes and returns an arbitrary entry.
        pub fn iterator(self: *Self) Iter {
            return .{ .map = self };
        }

        /// Consuming iterator for HashMap<T>.
        pub const Iter = struct {
            map: *Self,

            pub fn next(self: *Iter) ?Box(T) {
                if (self.map.outstanding_imm > 0) {
                    @panic("cannot iterate while HashMap has active immutable borrows");
                }
                if (self.map.outstanding_mut > 0) {
                    @panic("cannot iterate while HashMap is mutably borrowed");
                }
                var it = self.map.map.iterator();
                const kv = it.next() orelse return null;
                const key = kv.key_ptr.*;
                return self.map.remove(key);
            }
        };

        /// Return a consuming reverse iterator over the map.
        /// For hash maps, order is arbitrary; this is equivalent to `iterator()`.
        pub fn rev(self: *Self) RevIter {
            return .{ .inner = self.iterator() };
        }

        /// Reverse iterator for HashMap<T>.
        /// Same as Iter since hash maps have no defined order.
        pub const RevIter = struct {
            inner: Iter,

            pub fn next(self: *RevIter) ?Box(T) {
                return self.inner.next();
            }
        };

        // ─── Entry API ───

        pub fn entry(self: *Self, key: []const u8) Entry {
            return .{
                .map = self,
                .key = key,
                .occupied = self.map.contains(key),
            };
        }

        pub fn getOrPut(self: *Self, key: []const u8, box: Box(T)) !*Box(T) {
            return self.entry(key).orInsert(box);
        }

        pub const Entry = struct {
            map: *Self,
            key: []const u8,
            occupied: bool,

            pub fn orInsert(self_entry: Entry, box: Box(T)) !*Box(T) {
                if (self_entry.map.outstanding_mut > 0) {
                    @panic("cannot orInsert while HashMap is mutably borrowed");
                }
                if (self_entry.occupied) {
                    const dead = box.deinit();
                    _ = dead;
                    const ptr = self_entry.map.map.getPtr(self_entry.key) orelse unreachable;
                    return ptr;
                }
                const key_copy = try self_entry.map.allocator.dupe(u8, self_entry.key);
                const result = try self_entry.map.map.getOrPut(key_copy);
                if (result.found_existing) {
                    self_entry.map.allocator.free(key_copy);
                    const dead = box.deinit();
                    _ = dead;
                    return result.value_ptr;
                }
                result.value_ptr.* = box;
                return result.value_ptr;
            }

            pub fn orInsertWith(self_entry: Entry, context: anytype, comptime f: anytype) !*Box(T) {
                if (self_entry.map.outstanding_mut > 0) {
                    @panic("cannot orInsertWith while HashMap is mutably borrowed");
                }
                if (self_entry.occupied) {
                    const ptr = self_entry.map.map.getPtr(self_entry.key) orelse unreachable;
                    return ptr;
                }
                const box = try f(context);
                const key_copy = try self_entry.map.allocator.dupe(u8, self_entry.key);
                const result = try self_entry.map.map.getOrPut(key_copy);
                if (result.found_existing) {
                    self_entry.map.allocator.free(key_copy);
                    const dead = box.deinit();
                    _ = dead;
                    return result.value_ptr;
                }
                result.value_ptr.* = box;
                return result.value_ptr;
            }

            pub fn andModify(self_entry: Entry, context: anytype, comptime f: fn (@TypeOf(context), *T) void) void {
                if (!self_entry.occupied) return;
                const ptr = self_entry.map.map.getPtr(self_entry.key) orelse return;
                f(context, ptr.ptr);
            }

            pub fn getKey(self_entry: Entry) []const u8 {
                return self_entry.key;
            }

            pub fn isOccupied(self_entry: Entry) bool {
                return self_entry.occupied;
            }
        };
    };
}

// ─── Tests ───

test "HashMap iterator" {
    var map = HashMap(i32).init(std.testing.allocator);
    defer map.deinit();

    try map.put("a", try Box(i32).init(std.testing.allocator, 10));
    try map.put("b", try Box(i32).init(std.testing.allocator, 20));
    try map.put("c", try Box(i32).init(std.testing.allocator, 30));

    try std.testing.expectEqual(@as(usize, 3), map.len());

    var iter = map.iterator();
    var count: usize = 0;
    while (iter.next()) |val| {
        count += 1;
        const v = val.unsafePtr().*;
        try std.testing.expect(v == 10 or v == 20 or v == 30);
        const dead = val.deinit();
        _ = dead;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(usize, 0), map.len());
}

test "HashMap rev iterator" {
    var map = HashMap(i32).init(std.testing.allocator);
    defer map.deinit();

    try map.put("x", try Box(i32).init(std.testing.allocator, 100));
    try map.put("y", try Box(i32).init(std.testing.allocator, 200));

    try std.testing.expectEqual(@as(usize, 2), map.len());

    var iter = map.rev();
    var count: usize = 0;
    while (iter.next()) |val| {
        count += 1;
        const v = val.unsafePtr().*;
        try std.testing.expect(v == 100 or v == 200);
        const dead = val.deinit();
        _ = dead;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 0), map.len());
}

test "HashMap initDefault" {
    var map = HashMap(u32).initDefault(std.testing.allocator);
    defer map.deinit();
    try std.testing.expect(map.isEmpty());
}
