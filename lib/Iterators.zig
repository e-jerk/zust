const std = @import("std");
const Box = @import("Box.zig").Box;
const Slice = @import("Slice.zig").Slice;
const ArrayList = @import("ArrayList.zig").ArrayList;
const VecDeque = @import("VecDeque.zig").VecDeque;
const String = @import("String.zig").String;

// ============================================================
// Iterator Adapter Structs
// ============================================================

/// Map each value from an iterator through a transform function.
///
/// Parameters:
///   - Iter:     the source iterator type
///   - Context:  the type of the closure context passed to `map_fn`
///   - T:        the item type yielded by the source iterator
///   - U:        the mapped item type
///
/// Usage:
///   var mapped = MapIter(RangeIter(u32), u32, u32, u32).init(range, 2, multiply);
pub fn MapIter(comptime Iter: type, comptime Context: type, comptime T: type, comptime U: type) type {
    return struct {
        iter: Iter,
        context: Context,
        map_fn: *const fn (Context, T) U,

        const Self = @This();

        pub fn init(iter: Iter, context: Context, comptime map_fn: fn (Context, T) U) Self {
            return .{
                .iter = iter,
                .context = context,
                .map_fn = map_fn,
            };
        }

        pub fn next(self: *Self) ?U {
            const val = self.iter.next() orelse return null;
            return self.map_fn(self.context, val);
        }
    };
}

/// Filter values from an iterator using a predicate.
///
/// Parameters:
///   - Iter:     the source iterator type
///   - Context:  the type of the closure context passed to `pred`
///   - T:        the item type
///
/// Usage:
///   var filtered = FilterIter(RangeIter(u32), void, u32).init(range, {}, is_even);
pub fn FilterIter(comptime Iter: type, comptime Context: type, comptime T: type) type {
    return struct {
        iter: Iter,
        context: Context,
        pred: *const fn (Context, *const T) bool,

        const Self = @This();

        pub fn init(iter: Iter, context: Context, comptime pred: fn (Context, *const T) bool) Self {
            return .{
                .iter = iter,
                .context = context,
                .pred = pred,
            };
        }

        pub fn next(self: *Self) ?T {
            while (self.iter.next()) |val| {
                if (self.pred(self.context, &val)) return val;
            }
            return null;
        }
    };
}

/// Enumerate values with their zero-based index.
///
/// Yields `struct { index: usize, value: T }` for each item.
pub fn EnumerateIter(comptime Iter: type, comptime T: type) type {
    return struct {
        iter: Iter,
        index: usize,

        const Self = @This();
        pub const Item = struct { index: usize, value: T };

        pub fn init(iter: Iter) Self {
            return .{
                .iter = iter,
                .index = 0,
            };
        }

        pub fn next(self: *Self) ?Item {
            const val = self.iter.next() orelse return null;
            const result = Item{ .index = self.index, .value = val };
            self.index += 1;
            return result;
        }
    };
}

/// Take only the first `n` values from an iterator.
pub fn TakeIter(comptime Iter: type, comptime T: type) type {
    return struct {
        iter: Iter,
        remaining: usize,

        const Self = @This();

        pub fn init(iter: Iter, n: usize) Self {
            return .{
                .iter = iter,
                .remaining = n,
            };
        }

        pub fn next(self: *Self) ?T {
            if (self.remaining == 0) return null;
            self.remaining -= 1;
            return self.iter.next();
        }
    };
}

/// Skip the first `n` values from an iterator.
pub fn SkipIter(comptime Iter: type, comptime T: type) type {
    return struct {
        iter: Iter,
        remaining: usize,

        const Self = @This();

        pub fn init(iter: Iter, n: usize) Self {
            var self = Self{
                .iter = iter,
                .remaining = n,
            };
            while (self.remaining > 0) {
                _ = self.iter.next() orelse break;
                self.remaining -= 1;
            }
            return self;
        }

        pub fn next(self: *Self) ?T {
            return self.iter.next();
        }
    };
}

/// Chain two iterators of the same item type together.
///
/// Yields all items from `first`, then all items from `second`.
pub fn ChainIter(comptime IterA: type, comptime IterB: type, comptime T: type) type {
    return struct {
        first: IterA,
        second: IterB,
        first_exhausted: bool,

        const Self = @This();

        pub fn init(first: IterA, second: IterB) Self {
            return .{
                .first = first,
                .second = second,
                .first_exhausted = false,
            };
        }

        pub fn next(self: *Self) ?T {
            if (!self.first_exhausted) {
                if (self.first.next()) |val| return val;
                self.first_exhausted = true;
            }
            return self.second.next();
        }
    };
}

// ============================================================
// Consumer Functions
// ============================================================

/// Reduce an iterator to a single value.
///
/// `f` is called as `f(context, accumulator, item)` and must return
/// the new accumulator value.
pub fn fold(comptime Iter: type, comptime T: type, comptime Acc: type, iter: *Iter, init: Acc, context: anytype, comptime f: fn (@TypeOf(context), Acc, T) Acc) Acc {
    var acc = init;
    while (iter.next()) |val| {
        acc = f(context, acc, val);
    }
    return acc;
}

/// Collect all remaining items into a `std.ArrayList(T)`.
pub fn collectArrayList(comptime Iter: type, comptime T: type, iter: *Iter, allocator: std.mem.Allocator) !std.ArrayList(T) {
    var result: std.ArrayList(T) = .empty;
    errdefer result.deinit(allocator);
    while (iter.next()) |val| {
        try result.append(allocator, val);
    }
    return result;
}

/// Count the remaining items in an iterator.
pub fn count(comptime Iter: type, comptime T: type, iter: *Iter) usize {
    _ = T;
    var n: usize = 0;
    while (iter.next()) |val| {
        _ = val;
        n += 1;
    }
    return n;
}

/// Check if any remaining item satisfies the predicate.
///
/// Stops at the first match.
pub fn any(comptime Iter: type, comptime T: type, iter: *Iter, context: anytype, comptime pred: fn (@TypeOf(context), *const T) bool) bool {
    while (iter.next()) |val| {
        if (pred(context, &val)) return true;
    }
    return false;
}

/// Find the first item matching the predicate.
///
/// Returns the matching item, or null if none found.
pub fn find(comptime Iter: type, comptime T: type, iter: *Iter, context: anytype, comptime pred: fn (@TypeOf(context), *const T) bool) ?T {
    while (iter.next()) |val| {
        if (pred(context, &val)) return val;
    }
    return null;
}

/// Find the zero-based index of the first matching item.
///
/// Returns the index, or null if none found.
pub fn position(comptime Iter: type, comptime T: type, iter: *Iter, context: anytype, comptime pred: fn (@TypeOf(context), *const T) bool) ?usize {
    var idx: usize = 0;
    while (iter.next()) |val| {
        if (pred(context, &val)) return idx;
        idx += 1;
    }
    return null;
}

/// Check if all remaining items satisfy the predicate.
///
/// Returns true for an empty iterator.
pub fn all(comptime Iter: type, comptime T: type, iter: *Iter, context: anytype, comptime pred: fn (@TypeOf(context), *const T) bool) bool {
    while (iter.next()) |val| {
        if (!pred(context, &val)) return false;
    }
    return true;
}

/// Sum all remaining items.
///
/// T must support the `+` operator. Starts from 0.
pub fn sum(comptime Iter: type, comptime T: type, iter: *Iter) T {
    comptime if (@typeInfo(T) != .int and @typeInfo(T) != .float)
        @compileError("sum requires T to be a numeric type");
    var total: T = 0;
    while (iter.next()) |val| {
        total += val;
    }
    return total;
}

/// Find the minimum item according to the given `lessThan` function.
///
/// `lessThan(context, a, b)` should return true when `a < b`.
pub fn min(comptime Iter: type, comptime T: type, iter: *Iter, context: anytype, comptime lessThan: fn (@TypeOf(context), *const T, *const T) bool) ?T {
    var result: ?T = null;
    while (iter.next()) |val| {
        if (result == null or lessThan(context, &val, &result.?)) {
            result = val;
        }
    }
    return result;
}

/// Find the maximum item according to the given `lessThan` function.
///
/// `lessThan(context, a, b)` should return true when `a < b`.
pub fn max(comptime Iter: type, comptime T: type, iter: *Iter, context: anytype, comptime lessThan: fn (@TypeOf(context), *const T, *const T) bool) ?T {
    var result: ?T = null;
    while (iter.next()) |val| {
        if (result == null or lessThan(context, &result.?, &val)) {
            result = val;
        }
    }
    return result;
}

// ============================================================
// Additional Iterator Adapter Structs
// ============================================================

/// Zip two iterators together, yielding pairs of items.
///
/// Stops when either iterator is exhausted.
pub fn ZipIter(comptime IterA: type, comptime IterB: type, comptime T: type, comptime U: type) type {
    return struct {
        iter_a: IterA,
        iter_b: IterB,

        const Self = @This();
        pub const Item = struct { first: T, second: U };

        pub fn init(iter_a: IterA, iter_b: IterB) Self {
            return .{
                .iter_a = iter_a,
                .iter_b = iter_b,
            };
        }

        pub fn next(self: *Self) ?Item {
            const a = self.iter_a.next() orelse return null;
            const b = self.iter_b.next() orelse return null;
            return Item{ .first = a, .second = b };
        }
    };
}

/// Clone values from an iterator that yields `*const T`.
///
/// T must be `Copy` (i.e. pass-by-value types like integers).
pub fn ClonedIter(comptime Iter: type, comptime T: type) type {
    // T should be a copy-by-value type (e.g. integer, float, bool, enum, pointer)
    return struct {
        iter: Iter,

        const Self = @This();

        pub fn init(iter: Iter) Self {
            return .{ .iter = iter };
        }

        pub fn next(self: *Self) ?T {
            const ptr = self.iter.next() orelse return null;
            return ptr.*;
        }
    };
}

// ============================================================
// Collection Iterators (consuming)
// ============================================================

/// Consuming iterator over `Slice(T)` elements.
/// Yields elements by value (Copy-compatible types).
/// The iterator takes ownership of the slice borrow.
pub fn SliceIter(comptime T: type) type {
    return struct {
        slice: Slice(T),
        index: usize,

        const Self = @This();

        pub fn init(slice: Slice(T)) Self {
            return .{ .slice = slice, .index = 0 };
        }

        pub fn next(self: *Self) ?T {
            if (self.index >= self.slice.len()) return null;
            const val = self.slice.get(self.index).?;
            self.index += 1;
            return val;
        }

        pub fn len(self: *const Self) usize {
            return self.slice.len() - self.index;
        }

        pub fn deinit(self: *Self) void {
            self.slice.release();
        }
    };
}

/// Consuming iterator over `ArrayList(T)` elements.
/// Yields `Box(T, 0, 0, 0)` values by popping from the back (LIFO).
/// The iterator owns the list; do not deinit the original after passing it in.
pub fn ArrayListIter(comptime T: type) type {
    return struct {
        list: ArrayList(T),

        const Self = @This();

        pub fn init(list: ArrayList(T)) Self {
            return .{ .list = list };
        }

        pub fn next(self: *Self) ?Box(T, 0, 0, 0) {
            return self.list.pop();
        }

        pub fn len(self: *const Self) usize {
            return self.list.len();
        }

        pub fn deinit(self: *Self) void {
            self.list.deinit();
        }
    };
}

/// Consuming iterator over `VecDeque(T)` elements.
/// Yields `Box(T, 0, 0, 0)` values by popping from the front (FIFO).
/// The iterator owns the deque; do not deinit the original after passing it in.
pub fn VecDequeIter(comptime T: type) type {
    return struct {
        dq: VecDeque(T),

        const Self = @This();

        pub fn init(dq: VecDeque(T)) Self {
            return .{ .dq = dq };
        }

        pub fn next(self: *Self) ?Box(T, 0, 0, 0) {
            return self.dq.popFront();
        }

        pub fn len(self: *const Self) usize {
            return self.dq.count();
        }

        pub fn deinit(self: *Self) void {
            self.dq.deinit();
        }
    };
}

/// Consuming iterator over `String` bytes.
/// Yields each byte as a `u8`.
/// The iterator owns the string; do not deinit the original after passing it in.
pub const StringIter = struct {
    string: String,
    index: usize,

    const Self = @This();

    pub fn init(string: String) Self {
        return .{ .string = string, .index = 0 };
    }

    pub fn next(self: *Self) ?u8 {
        if (self.index >= self.string.len()) return null;
        const b = self.string.slice()[self.index];
        self.index += 1;
        return b;
    }

    pub fn len(self: *const Self) usize {
        return self.string.len() - self.index;
    }

    pub fn deinit(self: *Self) void {
        self.string.deinit();
    }
};

// ============================================================
// Test Helpers
// ============================================================

fn RangeIter(comptime T: type) type {
    return struct {
        current: T,
        end: T,

        const Self = @This();

        pub fn init(start: T, end: T) Self {
            return .{
                .current = start,
                .end = end,
            };
        }

        pub fn next(self: *Self) ?T {
            if (self.current >= self.end) return null;
            const val = self.current;
            self.current += 1;
            return val;
        }
    };
}

fn TestSliceIter(comptime T: type) type {
    return struct {
        slice: []const T,
        index: usize,

        const Self = @This();

        pub fn init(slice: []const T) Self {
            return .{
                .slice = slice,
                .index = 0,
            };
        }

        pub fn next(self: *Self) ?T {
            if (self.index >= self.slice.len) return null;
            const val = self.slice[self.index];
            self.index += 1;
            return val;
        }
    };
}

fn TestPtrSliceIter(comptime T: type) type {
    return struct {
        slice: []const T,
        index: usize,

        const Self = @This();

        pub fn init(slice: []const T) Self {
            return .{
                .slice = slice,
                .index = 0,
            };
        }

        pub fn next(self: *Self) ?*const T {
            if (self.index >= self.slice.len) return null;
            const ptr = &self.slice[self.index];
            self.index += 1;
            return ptr;
        }
    };
}

// ============================================================
// Tests: MapIter
// ============================================================

test "MapIter doubles values" {
    const range = RangeIter(u32).init(1, 4);
    var mapped = MapIter(RangeIter(u32), u32, u32, u32).init(range, 2, struct {
        fn f(ctx: u32, val: u32) u32 {
            return val * ctx;
        }
    }.f);

    try std.testing.expectEqual(mapped.next().?, 2);
    try std.testing.expectEqual(mapped.next().?, 4);
    try std.testing.expectEqual(mapped.next().?, 6);
    try std.testing.expect(mapped.next() == null);
}

test "MapIter adds offset" {
    const range = RangeIter(u32).init(10, 13);
    var mapped = MapIter(RangeIter(u32), u32, u32, u32).init(range, 100, struct {
        fn f(ctx: u32, val: u32) u32 {
            return val + ctx;
        }
    }.f);

    try std.testing.expectEqual(mapped.next().?, 110);
    try std.testing.expectEqual(mapped.next().?, 111);
    try std.testing.expectEqual(mapped.next().?, 112);
    try std.testing.expect(mapped.next() == null);
}

// ============================================================
// Tests: FilterIter
// ============================================================

test "FilterIter keeps evens" {
    const range = RangeIter(u32).init(0, 6);
    var filtered = FilterIter(RangeIter(u32), void, u32).init(range, {}, struct {
        fn f(_: void, val: *const u32) bool {
            return val.* % 2 == 0;
        }
    }.f);

    try std.testing.expectEqual(filtered.next().?, 0);
    try std.testing.expectEqual(filtered.next().?, 2);
    try std.testing.expectEqual(filtered.next().?, 4);
    try std.testing.expect(filtered.next() == null);
}

test "FilterIter keeps values above threshold" {
    const range = RangeIter(u32).init(0, 10);
    var filtered = FilterIter(RangeIter(u32), u32, u32).init(range, 5, struct {
        fn f(ctx: u32, val: *const u32) bool {
            return val.* > ctx;
        }
    }.f);

    try std.testing.expectEqual(filtered.next().?, 6);
    try std.testing.expectEqual(filtered.next().?, 7);
    try std.testing.expectEqual(filtered.next().?, 8);
    try std.testing.expectEqual(filtered.next().?, 9);
    try std.testing.expect(filtered.next() == null);
}

// ============================================================
// Tests: EnumerateIter
// ============================================================

test "EnumerateIter adds indices" {
    const range = RangeIter(u32).init(100, 103);
    var enumerated = EnumerateIter(RangeIter(u32), u32).init(range);

    const first = enumerated.next().?;
    try std.testing.expectEqual(first.index, 0);
    try std.testing.expectEqual(first.value, 100);

    const second = enumerated.next().?;
    try std.testing.expectEqual(second.index, 1);
    try std.testing.expectEqual(second.value, 101);

    const third = enumerated.next().?;
    try std.testing.expectEqual(third.index, 2);
    try std.testing.expectEqual(third.value, 102);

    try std.testing.expect(enumerated.next() == null);
}

test "EnumerateIter over slice" {
    const items = [_]u32{ 10, 20, 30 };
    const slice_it = TestSliceIter(u32).init(&items);
    var enumerated = EnumerateIter(TestSliceIter(u32), u32).init(slice_it);

    const first = enumerated.next().?;
    try std.testing.expectEqual(first.index, 0);
    try std.testing.expectEqual(first.value, 10);

    const second = enumerated.next().?;
    try std.testing.expectEqual(second.index, 1);
    try std.testing.expectEqual(second.value, 20);

    try std.testing.expect(enumerated.next() != null);
    try std.testing.expect(enumerated.next() == null);
}

// ============================================================
// Tests: TakeIter
// ============================================================

test "TakeIter takes first n" {
    const range = RangeIter(u32).init(0, 100);
    var taken = TakeIter(RangeIter(u32), u32).init(range, 3);

    try std.testing.expectEqual(taken.next().?, 0);
    try std.testing.expectEqual(taken.next().?, 1);
    try std.testing.expectEqual(taken.next().?, 2);
    try std.testing.expect(taken.next() == null);
}

test "TakeIter with fewer items available" {
    const range = RangeIter(u32).init(0, 2);
    var taken = TakeIter(RangeIter(u32), u32).init(range, 5);

    try std.testing.expectEqual(taken.next().?, 0);
    try std.testing.expectEqual(taken.next().?, 1);
    try std.testing.expect(taken.next() == null);
}

// ============================================================
// Tests: SkipIter
// ============================================================

test "SkipIter skips first n" {
    const range = RangeIter(u32).init(0, 6);
    var skipped = SkipIter(RangeIter(u32), u32).init(range, 3);

    try std.testing.expectEqual(skipped.next().?, 3);
    try std.testing.expectEqual(skipped.next().?, 4);
    try std.testing.expectEqual(skipped.next().?, 5);
    try std.testing.expect(skipped.next() == null);
}

test "SkipIter skips more than available" {
    const range = RangeIter(u32).init(0, 2);
    var skipped = SkipIter(RangeIter(u32), u32).init(range, 5);

    try std.testing.expect(skipped.next() == null);
}

// ============================================================
// Tests: ChainIter
// ============================================================

test "ChainIter chains two ranges" {
    const first = RangeIter(u32).init(0, 3);
    const second = RangeIter(u32).init(10, 13);
    var chained = ChainIter(RangeIter(u32), RangeIter(u32), u32).init(first, second);

    try std.testing.expectEqual(chained.next().?, 0);
    try std.testing.expectEqual(chained.next().?, 1);
    try std.testing.expectEqual(chained.next().?, 2);
    try std.testing.expectEqual(chained.next().?, 10);
    try std.testing.expectEqual(chained.next().?, 11);
    try std.testing.expectEqual(chained.next().?, 12);
    try std.testing.expect(chained.next() == null);
}

test "ChainIter with empty first" {
    const first = RangeIter(u32).init(0, 0);
    const second = RangeIter(u32).init(5, 7);
    var chained = ChainIter(RangeIter(u32), RangeIter(u32), u32).init(first, second);

    try std.testing.expectEqual(chained.next().?, 5);
    try std.testing.expectEqual(chained.next().?, 6);
    try std.testing.expect(chained.next() == null);
}

// ============================================================
// Tests: fold
// ============================================================

test "fold sums values" {
    var range = RangeIter(u32).init(1, 5);
    const total = fold(RangeIter(u32), u32, u32, &range, 0, {}, struct {
        fn f(_: void, acc: u32, val: u32) u32 {
            return acc + val;
        }
    }.f);
    try std.testing.expectEqual(total, 10);
}

test "fold computes product" {
    var range = RangeIter(u32).init(1, 5);
    const product = fold(RangeIter(u32), u32, u32, &range, 1, {}, struct {
        fn f(_: void, acc: u32, val: u32) u32 {
            return acc * val;
        }
    }.f);
    try std.testing.expectEqual(product, 24);
}

// ============================================================
// Tests: collectArrayList
// ============================================================

test "collectArrayList from range" {
    var range = RangeIter(u32).init(0, 3);
    var list = try collectArrayList(RangeIter(u32), u32, &range, std.testing.allocator);
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(list.items.len, 3);
    try std.testing.expectEqual(list.items[0], 0);
    try std.testing.expectEqual(list.items[1], 1);
    try std.testing.expectEqual(list.items[2], 2);
}

test "collectArrayList from slice" {
    const items = [_]u32{ 10, 20, 30 };
    var slice_it = TestSliceIter(u32).init(&items);
    var list = try collectArrayList(TestSliceIter(u32), u32, &slice_it, std.testing.allocator);
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(list.items.len, 3);
    try std.testing.expectEqual(list.items[0], 10);
    try std.testing.expectEqual(list.items[1], 20);
    try std.testing.expectEqual(list.items[2], 30);
}

// ============================================================
// Tests: count
// ============================================================

test "count range" {
    var range = RangeIter(u32).init(0, 10);
    try std.testing.expectEqual(count(RangeIter(u32), u32, &range), 10);
}

test "count taken values" {
    const range = RangeIter(u32).init(0, 100);
    var taken = TakeIter(RangeIter(u32), u32).init(range, 5);
    try std.testing.expectEqual(count(TakeIter(RangeIter(u32), u32), u32, &taken), 5);
}

// ============================================================
// Tests: any
// ============================================================

test "any finds match" {
    var range = RangeIter(u32).init(1, 5);
    try std.testing.expect(any(RangeIter(u32), u32, &range, {}, struct {
        fn f(_: void, val: *const u32) bool {
            return val.* == 3;
        }
    }.f));
}

test "any returns false when no match" {
    var range = RangeIter(u32).init(1, 5);
    try std.testing.expect(!any(RangeIter(u32), u32, &range, {}, struct {
        fn f(_: void, val: *const u32) bool {
            return val.* > 10;
        }
    }.f));
}

// ============================================================
// Tests: ZipIter
// ============================================================

test "ZipIter pairs two ranges" {
    const a = RangeIter(u32).init(1, 4);
    const b = RangeIter(u32).init(10, 13);
    var zipped = ZipIter(RangeIter(u32), RangeIter(u32), u32, u32).init(a, b);

    const first = zipped.next().?;
    try std.testing.expectEqual(first.first, 1);
    try std.testing.expectEqual(first.second, 10);

    const second = zipped.next().?;
    try std.testing.expectEqual(second.first, 2);
    try std.testing.expectEqual(second.second, 11);

    const third = zipped.next().?;
    try std.testing.expectEqual(third.first, 3);
    try std.testing.expectEqual(third.second, 12);

    try std.testing.expect(zipped.next() == null);
}

test "ZipIter stops at shorter iterator" {
    const a = RangeIter(u32).init(1, 3);
    const b = RangeIter(u32).init(100, 102);
    var zipped = ZipIter(RangeIter(u32), RangeIter(u32), u32, u32).init(a, b);

    const first = zipped.next().?;
    try std.testing.expectEqual(first.first, 1);
    try std.testing.expectEqual(first.second, 100);

    const second = zipped.next().?;
    try std.testing.expectEqual(second.first, 2);
    try std.testing.expectEqual(second.second, 101);

    try std.testing.expect(zipped.next() == null);
}

// ============================================================
// Tests: ClonedIter
// ============================================================

test "ClonedIter clones integer pointers" {
    const items = [_]u32{ 10, 20, 30 };
    const ptr_iter = TestPtrSliceIter(u32).init(&items);
    var cloned = ClonedIter(TestPtrSliceIter(u32), u32).init(ptr_iter);

    try std.testing.expectEqual(cloned.next().?, 10);
    try std.testing.expectEqual(cloned.next().?, 20);
    try std.testing.expectEqual(cloned.next().?, 30);
    try std.testing.expect(cloned.next() == null);
}

test "ClonedIter over empty slice" {
    const items = [_]u32{};
    const ptr_iter = TestPtrSliceIter(u32).init(&items);
    var cloned = ClonedIter(TestPtrSliceIter(u32), u32).init(ptr_iter);

    try std.testing.expect(cloned.next() == null);
}

// ============================================================
// Tests: find
// ============================================================

test "find finds matching element" {
    var range = RangeIter(u32).init(1, 6);
    const result = find(RangeIter(u32), u32, &range, {}, struct {
        fn f(_: void, val: *const u32) bool {
            return val.* == 3;
        }
    }.f);
    try std.testing.expectEqual(result.?, 3);
}

test "find returns null when no match" {
    var range = RangeIter(u32).init(1, 4);
    const result = find(RangeIter(u32), u32, &range, {}, struct {
        fn f(_: void, val: *const u32) bool {
            return val.* == 10;
        }
    }.f);
    try std.testing.expect(result == null);
}

// ============================================================
// Tests: position
// ============================================================

test "position finds index of match" {
    var range = RangeIter(u32).init(10, 15);
    const idx = position(RangeIter(u32), u32, &range, {}, struct {
        fn f(_: void, val: *const u32) bool {
            return val.* == 13;
        }
    }.f);
    try std.testing.expectEqual(idx.?, 3);
}

test "position returns null when no match" {
    var range = RangeIter(u32).init(1, 4);
    const idx = position(RangeIter(u32), u32, &range, {}, struct {
        fn f(_: void, val: *const u32) bool {
            return val.* == 100;
        }
    }.f);
    try std.testing.expect(idx == null);
}

// ============================================================
// Tests: all
// ============================================================

test "all returns true when all match" {
    var range = RangeIter(u32).init(2, 5);
    try std.testing.expect(all(RangeIter(u32), u32, &range, {}, struct {
        fn f(_: void, val: *const u32) bool {
            return val.* > 1;
        }
    }.f));
}

test "all returns false when one does not match" {
    var range = RangeIter(u32).init(1, 5);
    try std.testing.expect(!all(RangeIter(u32), u32, &range, {}, struct {
        fn f(_: void, val: *const u32) bool {
            return val.* > 2;
        }
    }.f));
}

// ============================================================
// Tests: sum
// ============================================================

test "sum of range" {
    var range = RangeIter(u32).init(1, 5);
    try std.testing.expectEqual(sum(RangeIter(u32), u32, &range), 10);
}

test "sum of empty iterator" {
    var range = RangeIter(u32).init(0, 0);
    try std.testing.expectEqual(sum(RangeIter(u32), u32, &range), 0);
}

// ============================================================
// Tests: min / max
// ============================================================

test "min finds smallest" {
    var range = RangeIter(u32).init(5, 9);
    const result = min(RangeIter(u32), u32, &range, {}, struct {
        fn f(_: void, a: *const u32, b: *const u32) bool {
            return a.* < b.*;
        }
    }.f);
    try std.testing.expectEqual(result.?, 5);
}

test "min returns null for empty" {
    var range = RangeIter(u32).init(0, 0);
    const result = min(RangeIter(u32), u32, &range, {}, struct {
        fn f(_: void, a: *const u32, b: *const u32) bool {
            return a.* < b.*;
        }
    }.f);
    try std.testing.expect(result == null);
}

test "max finds largest" {
    var range = RangeIter(u32).init(1, 5);
    const result = max(RangeIter(u32), u32, &range, {}, struct {
        fn f(_: void, a: *const u32, b: *const u32) bool {
            return a.* < b.*;
        }
    }.f);
    try std.testing.expectEqual(result.?, 4);
}

test "max returns null for empty" {
    var range = RangeIter(u32).init(0, 0);
    const result = max(RangeIter(u32), u32, &range, {}, struct {
        fn f(_: void, a: *const u32, b: *const u32) bool {
            return a.* < b.*;
        }
    }.f);
    try std.testing.expect(result == null);
}

// ============================================================
// Tests: SliceIter
// ============================================================

test "SliceIter iterates over Slice" {
    const arr = [_]u32{ 10, 20, 30 };
    const slice = Slice(u32).fromStack(&arr);
    var iter = SliceIter(u32).init(slice);

    try std.testing.expectEqual(iter.len(), 3);
    try std.testing.expectEqual(iter.next().?, 10);
    try std.testing.expectEqual(iter.len(), 2);
    try std.testing.expectEqual(iter.next().?, 20);
    try std.testing.expectEqual(iter.next().?, 30);
    try std.testing.expect(iter.next() == null);
    try std.testing.expectEqual(iter.len(), 0);
    iter.deinit();
}

test "SliceIter over empty slice" {
    const arr = [_]u32{};
    const slice = Slice(u32).fromStack(&arr);
    var iter = SliceIter(u32).init(slice);

    try std.testing.expectEqual(iter.len(), 0);
    try std.testing.expect(iter.next() == null);
    iter.deinit();
}

// ============================================================
// Tests: ArrayListIter
// ============================================================

test "ArrayListIter consumes list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var list = ArrayList(u32).init(allocator);
    try list.append(try Box(u32, 0, 0, 0).init(allocator, 10));
    try list.append(try Box(u32, 0, 0, 0).init(allocator, 20));
    try list.append(try Box(u32, 0, 0, 0).init(allocator, 30));

    var iter = ArrayListIter(u32).init(list);
    try std.testing.expectEqual(iter.len(), 3);

    const v1 = iter.next().?;
    try std.testing.expectEqual(v1.ptr.*, 30); // LIFO
    const dead1 = v1.deinit();
    _ = dead1;

    const v2 = iter.next().?;
    try std.testing.expectEqual(v2.ptr.*, 20);
    const dead2 = v2.deinit();
    _ = dead2;

    const v3 = iter.next().?;
    try std.testing.expectEqual(v3.ptr.*, 10);
    const dead3 = v3.deinit();
    _ = dead3;

    try std.testing.expect(iter.next() == null);
    try std.testing.expectEqual(iter.len(), 0);
    iter.deinit();
}

test "ArrayListIter empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const list = ArrayList(u32).init(allocator);
    var iter = ArrayListIter(u32).init(list);

    try std.testing.expect(iter.next() == null);
    try std.testing.expectEqual(iter.len(), 0);
    iter.deinit();
}

// ============================================================
// Tests: VecDequeIter
// ============================================================

test "VecDequeIter consumes deque" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var dq = try VecDeque(u32).init(allocator);
    try dq.pushBack(try Box(u32, 0, 0, 0).init(allocator, 10));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(allocator, 20));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(allocator, 30));

    var iter = VecDequeIter(u32).init(dq);
    try std.testing.expectEqual(iter.len(), 3);

    const v1 = iter.next().?;
    try std.testing.expectEqual(v1.ptr.*, 10); // FIFO
    const dead1 = v1.deinit();
    _ = dead1;

    const v2 = iter.next().?;
    try std.testing.expectEqual(v2.ptr.*, 20);
    const dead2 = v2.deinit();
    _ = dead2;

    const v3 = iter.next().?;
    try std.testing.expectEqual(v3.ptr.*, 30);
    const dead3 = v3.deinit();
    _ = dead3;

    try std.testing.expect(iter.next() == null);
    try std.testing.expectEqual(iter.len(), 0);
    iter.deinit();
}

test "VecDequeIter empty deque" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const dq = try VecDeque(u32).init(allocator);
    var iter = VecDequeIter(u32).init(dq);

    try std.testing.expect(iter.next() == null);
    try std.testing.expectEqual(iter.len(), 0);
    iter.deinit();
}

// ============================================================
// Tests: StringIter
// ============================================================

test "StringIter iterates over bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const s = try String.initFromSlice(allocator, "abc");
    var iter = StringIter.init(s);

    try std.testing.expectEqual(iter.len(), 3);
    try std.testing.expectEqual(iter.next().?, 'a');
    try std.testing.expectEqual(iter.len(), 2);
    try std.testing.expectEqual(iter.next().?, 'b');
    try std.testing.expectEqual(iter.next().?, 'c');
    try std.testing.expect(iter.next() == null);
    try std.testing.expectEqual(iter.len(), 0);
    iter.deinit();
}

test "StringIter empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const s = String.init(allocator);
    var iter = StringIter.init(s);

    try std.testing.expect(iter.next() == null);
    try std.testing.expectEqual(iter.len(), 0);
    iter.deinit();
}
