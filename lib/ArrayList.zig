const std = @import("std");
const Box = @import("Box.zig").Box;
const SimdUtils = @import("SimdUtils.zig");

/// A growable array that owns `Box(T, 0, 0, 0)` values.
/// All items are stored in Owned state. Accessing an item borrows it
/// from the list. The list tracks how many outstanding borrows exist.
pub fn ArrayList(comptime T: type) type {
    return struct {
        items: std.ArrayList(Box(T, 0, 0, 0)),
        allocator: std.mem.Allocator,
        // Track outstanding borrows to prevent deinit while borrowed
        outstanding_imm: u32 = 0,
        outstanding_mut: u32 = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .items = std.ArrayList(Box(T, 0, 0, 0)).empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            // Must not have outstanding borrows
            if (self.outstanding_imm > 0) {
                @panic("cannot deinit ArrayList while active immutable borrows exist");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot deinit ArrayList while active mutable borrow exists");
            }

            // Deinit all owned boxes
            for (self.items.items) |box| {
                const dead = box.deinit();
                _ = dead;
            }
            self.items.deinit(self.allocator);
        }

        pub fn append(self: *Self, box: Box(T, 0, 0, 0)) !void {
            // Must not be mutably borrowed
            if (self.outstanding_mut > 0) {
                @panic("cannot append while ArrayList is mutably borrowed");
            }
            try self.items.append(self.allocator, box);
        }

        pub fn len(self: *const Self) usize {
            return self.items.items.len;
        }

        /// Get an item by value (transfers ownership OUT of the list).
        /// Panics if the list has active borrows.
        pub fn get(self: *Self, index: usize) ?Box(T, 0, 0, 0) {
            if (self.outstanding_imm > 0) {
                @panic("cannot get while ArrayList has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot get while ArrayList has active mutable borrow");
            }
            if (index >= self.items.items.len) return null;
            // Remove the item from the list so the list no longer owns it
            const box = self.items.items[index];
            // Shift remaining items left
            const shift_len = self.items.items.len - index - 1;
            if (@sizeOf(T) == 1 and shift_len >= 16) {
                const src = @as([*]u8, @ptrCast(&self.items.items[index + 1]));
                const dst = @as([*]u8, @ptrCast(&self.items.items[index]));
                SimdUtils.copy(dst[0..shift_len], src[0..shift_len]);
            } else {
                for (index..self.items.items.len - 1) |i| {
                    self.items.items[i] = self.items.items[i + 1];
                }
            }
            _ = self.items.pop();
            return box;
        }

        /// Get a mutable reference to an item (borrows mutably from the list).
        /// Returns null if index is out of bounds.
        pub fn getMut(self: *Self, index: usize) ?struct {
            box: Box(T, 2, 0, 1),
            list: *Self,
            index: usize,

            const Borrow = @This();

            pub fn releaseMut(b: Borrow) void {
                b.list.outstanding_mut -= 1;
            }
        } {
            if (self.outstanding_imm > 0) {
                @panic("cannot getMut while ArrayList has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot getMut while ArrayList is already mutably borrowed");
            }
            if (index >= self.items.items.len) return null;
            self.outstanding_mut += 1;
            const box = self.items.items[index].borrowMut();
            return .{
                .box = box,
                .list = self,
                .index = index,
            };
        }

        pub fn pop(self: *Self) ?Box(T, 0, 0, 0) {
            if (self.outstanding_imm > 0) {
                @panic("cannot pop while ArrayList has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot pop while ArrayList is mutably borrowed");
            }
            return self.items.pop();
        }

        /// Pop the front value from the list.
        pub fn popFront(self: *Self) ?Box(T, 0, 0, 0) {
            if (self.outstanding_imm > 0) {
                @panic("cannot popFront while ArrayList has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot popFront while ArrayList is mutably borrowed");
            }
            if (self.items.items.len == 0) return null;
            const box = self.items.items[0];
            const shift_len = self.items.items.len - 1;
            if (@sizeOf(T) == 1 and shift_len >= 16) {
                const src = @as([*]u8, @ptrCast(&self.items.items[1]));
                const dst = @as([*]u8, @ptrCast(&self.items.items[0]));
                SimdUtils.copy(dst[0..shift_len], src[0..shift_len]);
            } else {
                for (0..self.items.items.len - 1) |i| {
                    self.items.items[i] = self.items.items[i + 1];
                }
            }
            _ = self.items.pop();
            return box;
        }

        pub fn borrowImm(self: *Self, index: usize) ?struct {
            box: Box(T, 1, 1, 0),
            list: *Self,
            index: usize,

            const Borrow = @This();

            pub fn releaseImm(b: Borrow) void {
                b.list.outstanding_imm -= 1;
            }
        } {
            if (self.outstanding_mut > 0) {
                @panic("cannot borrow immutably: active mutable borrow on ArrayList");
            }
            if (index >= self.items.items.len) return null;

            self.outstanding_imm += 1;
            const box = self.items.items[index].borrowImm();
            return .{
                .box = box,
                .list = self,
                .index = index,
            };
        }

        pub fn borrowMut(self: *Self, index: usize) ?struct {
            box: Box(T, 2, 0, 1),
            list: *Self,
            index: usize,

            const Borrow = @This();

            pub fn releaseMut(b: Borrow) void {
                b.list.outstanding_mut -= 1;
            }
        } {
            if (self.outstanding_imm > 0) {
                @panic("cannot borrow mutably: active immutable borrows on ArrayList");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot borrow mutably: already mutably borrowed");
            }
            if (index >= self.items.items.len) return null;

            self.outstanding_mut += 1;
            const box = self.items.items[index].borrowMut();
            return .{
                .box = box,
                .list = self,
                .index = index,
            };
        }

        pub fn withImm(self: *Self, index: usize, context: anytype, comptime cb: fn (@TypeOf(context), *const T) void) void {
            const maybe_borrow = self.borrowImm(index);
            if (maybe_borrow) |b| {
                cb(context, b.box.ptr);
                b.releaseImm();
            }
        }

        pub fn withMut(self: *Self, index: usize, context: anytype, comptime cb: fn (@TypeOf(context), *T) void) void {
            const maybe_borrow = self.borrowMut(index);
            if (maybe_borrow) |b| {
                cb(context, b.box.ptr);
                b.releaseMut();
            }
        }

        pub fn swapRemove(self: *Self, index: usize) ?Box(T, 0, 0, 0) {
            if (self.outstanding_imm > 0) {
                @panic("cannot swapRemove while ArrayList has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot swapRemove while ArrayList is mutably borrowed");
            }
            if (index >= self.items.items.len) return null;

            const last_index = self.items.items.len - 1;
            if (index != last_index) {
                const temp = self.items.items[index];
                self.items.items[index] = self.items.items[last_index];
                self.items.items[last_index] = temp;
            }
            return self.items.pop();
        }

        pub fn retain(self: *Self, context: anytype, comptime pred: fn (@TypeOf(context), *const T) bool) void {
            if (self.outstanding_imm > 0) {
                @panic("cannot retain while ArrayList has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot retain while ArrayList is mutably borrowed");
            }

            var write_idx: usize = 0;
            for (self.items.items) |box| {
                if (pred(context, box.ptr)) {
                    self.items.items[write_idx] = box;
                    write_idx += 1;
                } else {
                    const dead = box.deinit();
                    _ = dead;
                }
            }
            self.items.shrinkRetainingCapacity(write_idx);
        }

        pub fn resize(self: *Self, new_len: usize) !void {
            if (self.outstanding_imm > 0) {
                @panic("cannot resize while ArrayList has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot resize while ArrayList is mutably borrowed");
            }

            const old_len = self.items.items.len;
            if (new_len < old_len) {
                var i: usize = new_len;
                while (i < old_len) : (i += 1) {
                    const box = self.items.items[i];
                    const dead = box.deinit();
                    _ = dead;
                }
                self.items.shrinkRetainingCapacity(new_len);
            } else if (new_len > old_len) {
                try self.items.resize(self.allocator, new_len);
            }
        }

        pub fn clear(self: *Self) void {
            if (self.outstanding_imm > 0) {
                @panic("cannot clear while ArrayList has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot clear while ArrayList is mutably borrowed");
            }

            for (self.items.items) |box| {
                const dead = box.deinit();
                _ = dead;
            }
            self.items.shrinkRetainingCapacity(0);
        }

        pub fn ensureCapacity(self: *Self, capacity: usize) !void {
            try self.items.ensureTotalCapacity(self.allocator, capacity);
        }

        pub fn sort(self: *Self, context: anytype, comptime lessThan: fn (@TypeOf(context), *const T, *const T) bool) void {
            if (self.outstanding_imm > 0) {
                @panic("cannot sort while ArrayList has active immutable borrows");
            }
            if (self.outstanding_mut > 0) {
                @panic("cannot sort while ArrayList is mutably borrowed");
            }
            if (self.items.items.len <= 1) return;
            quickSort(self.items.items, context, lessThan, 0, self.items.items.len - 1);
        }

        fn quickSort(items: []Box(T, 0, 0, 0), context: anytype, comptime lessThan: fn (@TypeOf(context), *const T, *const T) bool, left: usize, right: usize) void {
            if (left >= right) return;
            const pivot = partition(items, context, lessThan, left, right);
            if (pivot > 0) quickSort(items, context, lessThan, left, pivot - 1);
            quickSort(items, context, lessThan, pivot + 1, right);
        }

        fn partition(items: []Box(T, 0, 0, 0), context: anytype, comptime lessThan: fn (@TypeOf(context), *const T, *const T) bool, left: usize, right: usize) usize {
            const pivot_val = items[right];
            var i = left;
            var j = left;
            while (j < right) : (j += 1) {
                if (lessThan(context, items[j].ptr, pivot_val.ptr)) {
                    const tmp = items[i];
                    items[i] = items[j];
                    items[j] = tmp;
                    i += 1;
                }
            }
            const tmp = items[i];
            items[i] = items[right];
            items[right] = tmp;
            return i;
        }

        /// Return a consuming iterator over the list.
        /// Each call to next() removes and returns the last item.
        pub fn iterator(self: *Self) Iter {
            return .{ .list = self };
        }

        /// Iterator for ArrayList<T>.
        /// Removes and returns each Box (consumes the list).
        pub const Iter = struct {
            list: *Self,

            pub fn next(self: *Iter) ?Box(T, 0, 0, 0) {
                return self.list.pop();
            }
        };

        /// Return a consuming reverse iterator over the list.
        /// Each call to next() removes and returns the first item (FIFO order).
        pub fn rev(self: *Self) RevIter {
            return .{ .list = self };
        }

        /// Reverse iterator for ArrayList<T>.
        /// Removes and returns each Box from the front (consumes the list).
        pub const RevIter = struct {
            list: *Self,

            pub fn next(self: *RevIter) ?Box(T, 0, 0, 0) {
                return self.list.popFront();
            }
        };
    };
}

// ─── Tests ───

test "ArrayList iterator" {
    var list = ArrayList(i32).init(std.testing.allocator);
    defer list.deinit();

    try list.append(try Box(i32, 0, 0, 0).init(std.testing.allocator, 10));
    try list.append(try Box(i32, 0, 0, 0).init(std.testing.allocator, 20));
    try list.append(try Box(i32, 0, 0, 0).init(std.testing.allocator, 30));

    var iter = list.iterator();
    const v1 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 30), v1.unsafePtr().*);
    const dead1 = v1.deinit();
    _ = dead1;

    const v2 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 20), v2.unsafePtr().*);
    const dead2 = v2.deinit();
    _ = dead2;

    const v3 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 10), v3.unsafePtr().*);
    const dead3 = v3.deinit();
    _ = dead3;

    try std.testing.expect(iter.next() == null);
}

test "ArrayList rev iterator" {
    var list = ArrayList(i32).init(std.testing.allocator);
    defer list.deinit();

    try list.append(try Box(i32, 0, 0, 0).init(std.testing.allocator, 10));
    try list.append(try Box(i32, 0, 0, 0).init(std.testing.allocator, 20));
    try list.append(try Box(i32, 0, 0, 0).init(std.testing.allocator, 30));

    var iter = list.rev();
    const v1 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 10), v1.unsafePtr().*);
    const dead1 = v1.deinit();
    _ = dead1;

    const v2 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 20), v2.unsafePtr().*);
    const dead2 = v2.deinit();
    _ = dead2;

    const v3 = iter.next().?;
    try std.testing.expectEqual(@as(i32, 30), v3.unsafePtr().*);
    const dead3 = v3.deinit();
    _ = dead3;

    try std.testing.expect(iter.next() == null);
}

test "ArrayList sort" {
    var list = ArrayList(u32).init(std.testing.allocator);
    defer list.deinit();

    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 30));
    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 10));
    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 20));

    list.sort({}, struct {
        fn f(_: void, a: *const u32, b: *const u32) bool {
            return a.* < b.*;
        }
    }.f);

    try std.testing.expectEqual(list.items.items[0].ptr.*, 10);
    try std.testing.expectEqual(list.items.items[1].ptr.*, 20);
    try std.testing.expectEqual(list.items.items[2].ptr.*, 30);
}
