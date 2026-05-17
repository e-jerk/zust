const std = @import("std");
const Box = @import("Box.zig").Box;
const Rc = @import("Rc.zig").Rc;
const Arc = @import("Arc.zig").Arc;
const String = @import("String.zig").String;
const ArrayList = @import("ArrayList.zig").ArrayList;
const VecDeque = @import("VecDeque.zig").VecDeque;
const HashMap = @import("HashMap.zig").HashMap;
const LinkedList = @import("LinkedList.zig").LinkedList;
const Mutex = @import("Mutex.zig").Mutex;
const RwLock = @import("Mutex.zig").RwLock;
const Channel = @import("Channel.zig").Channel;
const BinaryHeap = @import("BinaryHeap.zig").BinaryHeap;
const Arena = @import("Arena.zig").Arena;
const BTreeMap = @import("BTreeMap.zig").BTreeMap;
const HashSet = @import("HashSet.zig").HashSet;

/// Wraps any `std.mem.Allocator` and provides zust-friendly allocation methods.
/// All methods return zust ownership types (Box, Rc, Arc) instead of raw pointers.
pub const ZustAllocator = struct {
    inner: std.mem.Allocator,

    /// Allocate a single T, returning an owned Box.
    pub fn box(self: ZustAllocator, comptime T: type, value: T) !Box(T) {
        return try Box(T).init(self.inner, value);
    }

    /// Allocate an Rc (single-threaded refcounted).
    pub fn rc(self: ZustAllocator, comptime T: type, value: T) !Rc(T) {
        return try Rc(T).init(self.inner, value);
    }

    /// Allocate an Arc (thread-safe refcounted).
    pub fn arc(self: ZustAllocator, comptime T: type, value: T) !Arc(T) {
        return try Arc(T).init(self.inner, value);
    }

    /// Allocate an empty String.
    pub fn string(self: ZustAllocator) String {
        return String.init(self.inner);
    }

    /// Allocate an ArrayList.
    pub fn arrayList(self: ZustAllocator, comptime T: type) ArrayList(T) {
        return ArrayList(T).init(self.inner);
    }

    /// Allocate a VecDeque.
    pub fn vecDeque(self: ZustAllocator, comptime T: type) !VecDeque(T) {
        return try VecDeque(T).init(self.inner);
    }

    /// Allocate a HashMap.
    pub fn hashMap(self: ZustAllocator, comptime T: type) HashMap(T) {
        return HashMap(T).init(self.inner);
    }

    /// Allocate a LinkedList.
    pub fn linkedList(self: ZustAllocator, comptime T: type) LinkedList(T) {
        return LinkedList(T).init(self.inner);
    }

    /// Allocate a Mutex.
    pub fn mutex(self: ZustAllocator, comptime T: type, value: T) !Mutex(T) {
        return try Mutex(T).init(self.inner, value);
    }

    /// Allocate a RwLock.
    pub fn rwLock(self: ZustAllocator, comptime T: type, value: T) !RwLock(T) {
        return try RwLock(T).init(self.inner, value);
    }

    /// Allocate a Channel with the given capacity.
    pub fn channel(self: ZustAllocator, comptime T: type, capacity: usize) !Channel(T) {
        return try Channel(T).init(self.inner, capacity);
    }

    /// Allocate a BinaryHeap with the given comparison function.
    pub fn binaryHeap(self: ZustAllocator, comptime T: type, compare: *const fn (*const T, *const T) bool) BinaryHeap(T) {
        return BinaryHeap(T).init(self.inner, compare);
    }

    /// Create an Arena allocator.
    pub fn arena(self: ZustAllocator, comptime T: type) Arena(T) {
        return Arena(T).init(self.inner);
    }

    /// Create a BTreeMap.
    pub fn bTreeMap(self: ZustAllocator, comptime T: type) BTreeMap(T) {
        return BTreeMap(T).init(self.inner);
    }

    /// Create a HashSet.
    pub fn hashSet(self: ZustAllocator) HashSet {
        return HashSet.init(self.inner);
    }

    /// Raw allocation (fallback, returns raw pointer — NOT recommended).
    pub fn rawCreate(self: ZustAllocator, comptime T: type) !*T {
        return try self.inner.create(T);
    }

    /// Raw free (fallback — NOT recommended).
    pub fn rawDestroy(self: ZustAllocator, ptr: anytype) void {
        self.inner.destroy(ptr);
    }

    /// Slice allocation (returns owned slice, NOT a Box).
    pub fn allocSlice(self: ZustAllocator, comptime T: type, n: usize) ![]T {
        return try self.inner.alloc(T, n);
    }

    /// Free a slice.
    pub fn freeSlice(self: ZustAllocator, slice: anytype) void {
        self.inner.free(slice);
    }
};

/// Wrap an existing allocator into a ZustAllocator.
pub fn wrap(allocator: std.mem.Allocator) ZustAllocator {
    return .{ .inner = allocator };
}

/// Simple wrapper that counts allocations made through its methods.
///
/// NOTE: These are allocation counts, not live-object counts.
/// The wrapper cannot detect when the caller drops or deinits returned values.
pub const TrackingAllocator = struct {
    inner: ZustAllocator,
    active_boxes: u32,
    active_rcs: u32,
    active_arcs: u32,

    pub fn init(allocator: std.mem.Allocator) TrackingAllocator {
        return .{
            .inner = wrap(allocator),
            .active_boxes = 0,
            .active_rcs = 0,
            .active_arcs = 0,
        };
    }

    pub fn box(self: *TrackingAllocator, comptime T: type, value: T) !Box(T) {
        const b = try self.inner.box(T, value);
        self.active_boxes += 1;
        return b;
    }

    pub fn rc(self: *TrackingAllocator, comptime T: type, value: T) !Rc(T) {
        const r = try self.inner.rc(T, value);
        self.active_rcs += 1;
        return r;
    }

    pub fn arc(self: *TrackingAllocator, comptime T: type, value: T) !Arc(T) {
        const a = try self.inner.arc(T, value);
        self.active_arcs += 1;
        return a;
    }

    pub fn string(self: *TrackingAllocator) String {
        return self.inner.string();
    }

    pub fn arrayList(self: *TrackingAllocator, comptime T: type) ArrayList(T) {
        return self.inner.arrayList(T);
    }

    pub fn vecDeque(self: *TrackingAllocator, comptime T: type) !VecDeque(T) {
        return try self.inner.vecDeque(T);
    }

    pub fn hashMap(self: *TrackingAllocator, comptime T: type) HashMap(T) {
        return self.inner.hashMap(T);
    }

    pub fn linkedList(self: *TrackingAllocator, comptime T: type) LinkedList(T) {
        return self.inner.linkedList(T);
    }

    pub fn mutex(self: *TrackingAllocator, comptime T: type, value: T) !Mutex(T) {
        return try self.inner.mutex(T, value);
    }

    pub fn rwLock(self: *TrackingAllocator, comptime T: type, value: T) !RwLock(T) {
        return try self.inner.rwLock(T, value);
    }

    pub fn channel(self: *TrackingAllocator, comptime T: type, capacity: usize) !Channel(T) {
        return try self.inner.channel(T, capacity);
    }

    pub fn binaryHeap(self: *TrackingAllocator, comptime T: type, compare: *const fn (*const T, *const T) bool) BinaryHeap(T) {
        return self.inner.binaryHeap(T, compare);
    }

    pub fn arena(self: *TrackingAllocator, comptime T: type) Arena(T) {
        return self.inner.arena(T);
    }

    pub fn bTreeMap(self: *TrackingAllocator, comptime T: type) BTreeMap(T) {
        return self.inner.bTreeMap(T);
    }

    pub fn hashSet(self: *TrackingAllocator) HashSet {
        return self.inner.hashSet();
    }

    pub fn report(self: *TrackingAllocator) void {
        std.debug.print("TrackingAllocator report: {d} Box, {d} Rc, {d} Arc allocations\n", .{
            self.active_boxes,
            self.active_rcs,
            self.active_arcs,
        });
    }

    pub fn hasAllocations(self: *TrackingAllocator) bool {
        return self.active_boxes > 0 or self.active_rcs > 0 or self.active_arcs > 0;
    }

    pub fn totalAllocations(self: *TrackingAllocator) u32 {
        return self.active_boxes + self.active_rcs + self.active_arcs;
    }
};

// ─── Tests ───

test "ZustAllocator.box creates a Box" {
    const za = wrap(std.testing.allocator);
    const b = try za.box(u32, 42);
    try std.testing.expectEqual(b.ptr.*, 42);
    const dead = b.deinit();
    _ = dead;
}

test "ZustAllocator.rc creates an Rc" {
    const za = wrap(std.testing.allocator);
    const r = try za.rc(u32, 100);
    try std.testing.expectEqual(r.get().*, 100);
    r.drop();
}

test "ZustAllocator.arc creates an Arc" {
    const za = wrap(std.testing.allocator);
    const a = try za.arc(u32, 7);
    try std.testing.expectEqual(a.get().*, 7);
    a.drop();
}

test "ZustAllocator.string creates a String" {
    const za = wrap(std.testing.allocator);
    var s = za.string();
    defer s.deinit();
    try s.append("hello");
    try std.testing.expectEqualStrings(s.slice(), "hello");
}

test "ZustAllocator.arrayList creates an ArrayList" {
    const za = wrap(std.testing.allocator);
    var list = za.arrayList(u32);
    defer list.deinit();

    const b = try za.box(u32, 10);
    try list.append(b);
    try std.testing.expectEqual(list.len(), 1);
}

test "ZustAllocator.vecDeque creates a VecDeque" {
    const za = wrap(std.testing.allocator);
    var dq = try za.vecDeque(u32);
    defer dq.deinit();

    const b = try za.box(u32, 20);
    try dq.pushBack(b);
    try std.testing.expectEqual(dq.count(), 1);
}

test "ZustAllocator.hashMap creates a HashMap" {
    const za = wrap(std.testing.allocator);
    var map = za.hashMap(u32);
    defer map.deinit();

    const b = try za.box(u32, 30);
    try map.put("key", b);
    try std.testing.expect(map.contains("key"));
}

test "ZustAllocator.linkedList creates a LinkedList" {
    const za = wrap(std.testing.allocator);
    var list = za.linkedList(u32);
    defer list.deinit();

    try list.push(1);
    try list.push(2);
    try std.testing.expectEqual(list.len(), 2);
}

test "ZustAllocator.mutex creates a Mutex" {
    const za = wrap(std.testing.allocator);
    var mtx = try za.mutex(u32, 0);
    defer mtx.deinit();

    mtx.withLock({}, struct {
        fn f(_: void, val: *u32) void {
            val.* = 42;
        }
    }.f);
    try std.testing.expectEqual(mtx.box.ptr.*, 42);
}

test "ZustAllocator.rwLock creates a RwLock" {
    const za = wrap(std.testing.allocator);
    var rw = try za.rwLock(u32, 5);
    defer rw.deinit();

    rw.readLock();
    try std.testing.expectEqual(rw.get().*, 5);
    rw.readUnlock();
}

test "ZustAllocator.channel creates a Channel" {
    const za = wrap(std.testing.allocator);
    var ch = try za.channel(u32, 4);
    defer ch.deinit();

    try ch.send(99);
    const val = ch.recv();
    try std.testing.expectEqual(val.?, 99);
}

test "ZustAllocator.binaryHeap creates a BinaryHeap" {
    const za = wrap(std.testing.allocator);
    var heap = za.binaryHeap(u32, struct {
        fn f(a: *const u32, b: *const u32) bool {
            return a.* > b.*;
        }
    }.f);
    defer heap.deinit();

    try heap.push(try za.box(u32, 10));
    try heap.push(try za.box(u32, 30));
    try heap.push(try za.box(u32, 20));

    const top = heap.pop().?;
    try std.testing.expectEqual(top.unsafePtr().*, 30);
    const dead = top.deinit();
    _ = dead;
}

test "ZustAllocator.arena creates an Arena" {
    const za = wrap(std.testing.allocator);
    var ar = za.arena(u32);
    defer ar.deinit();

    const box = try ar.alloc(42);
    try std.testing.expectEqual(box.get().*, 42);
}

test "ZustAllocator.bTreeMap creates a BTreeMap" {
    const za = wrap(std.testing.allocator);
    var map = za.bTreeMap(u32);
    defer map.deinit();

    try map.put(1, try za.box(u32, 100));
    try std.testing.expect(map.contains(1));
}

test "ZustAllocator.hashSet creates a HashSet" {
    const za = wrap(std.testing.allocator);
    var set = za.hashSet();
    defer set.deinit();

    try set.insert(7);
    try std.testing.expect(set.contains(7));
}

test "ZustAllocator.rawCreate and rawDestroy" {
    const za = wrap(std.testing.allocator);
    const ptr = try za.rawCreate(u32);
    ptr.* = 123;
    try std.testing.expectEqual(ptr.*, 123);
    za.rawDestroy(ptr);
}

test "ZustAllocator.allocSlice and freeSlice" {
    const za = wrap(std.testing.allocator);
    const slice = try za.allocSlice(u32, 4);
    slice[0] = 1;
    slice[1] = 2;
    slice[2] = 3;
    slice[3] = 4;
    try std.testing.expectEqual(slice[2], 3);
    za.freeSlice(slice);
}

test "TrackingAllocator counts allocations" {
    var ta = TrackingAllocator.init(std.testing.allocator);

    const b = try ta.box(u32, 1);
    const dead = b.deinit();
    _ = dead;

    const r = try ta.rc(u32, 2);
    r.drop();

    const a = try ta.arc(u32, 3);
    a.drop();

    try std.testing.expectEqual(ta.active_boxes, 1);
    try std.testing.expectEqual(ta.active_rcs, 1);
    try std.testing.expectEqual(ta.active_arcs, 1);
    try std.testing.expect(ta.hasAllocations());
    try std.testing.expectEqual(ta.totalAllocations(), 3);
}

test "wrap convenience function" {
    const za = wrap(std.testing.allocator);
    const b = try za.box(u32, 99);
    try std.testing.expectEqual(b.ptr.*, 99);
    const dead = b.deinit();
    _ = dead;
}
