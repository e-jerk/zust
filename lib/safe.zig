//! zust: zero-cost ownership via comptime typestate.

const std = @import("std");
pub const Box = @import("Box.zig").Box;
pub const LinkedList = @import("LinkedList.zig").LinkedList;
pub const ArrayList = @import("ArrayList.zig").ArrayList;
pub const Arc = @import("Arc.zig").Arc;
pub const Weak = @import("Arc.zig").Weak;
pub const Mutex = @import("Mutex.zig").Mutex;
pub const RwLock = @import("Mutex.zig").RwLock;
pub const MutexGuard = @import("Mutex.zig").MutexGuard;
pub const RwLockReadGuard = @import("Mutex.zig").RwLockReadGuard;
pub const RwLockWriteGuard = @import("Mutex.zig").RwLockWriteGuard;
pub const Slice = @import("Slice.zig").Slice;
pub const ScopeImm = @import("Scope.zig").ScopeImm;
pub const ScopeMut = @import("Scope.zig").ScopeMut;
pub const AsyncBox = @import("Async.zig").AsyncBox;
pub const HashMap = @import("HashMap.zig").HashMap;
pub const Rc = @import("Rc.zig").Rc;
pub const Cell = @import("Cell.zig").Cell;
pub const RefCell = @import("Cell.zig").RefCell;
pub const Ref = @import("Cell.zig").Ref;
pub const RefMut = @import("Cell.zig").RefMut;
pub const Arena = @import("Arena.zig").Arena;
pub const ArenaBox = @import("Arena.zig").ArenaBox;
pub const VecDeque = @import("VecDeque.zig").VecDeque;
pub const RingBuffer = @import("RingBuffer.zig").RingBuffer;
pub const Stack = @import("Stack.zig").Stack;
pub const Queue = @import("Stack.zig").Queue;
pub const String = @import("String.zig").String;
pub const SmallString = @import("SmallString.zig").SmallString;
pub const SmallString23 = @import("SmallString.zig").SmallString23;
pub const SmallString15 = @import("SmallString.zig").SmallString15;
pub const Cow = @import("Cow.zig").Cow;
pub const OnceCell = @import("OnceCell.zig").OnceCell;
pub const LazyCell = @import("OnceCell.zig").LazyCell;
pub const OnceBox = @import("OnceCell.zig").OnceBox;
pub const LazyStatic = @import("LazyStatic.zig").LazyStatic;
pub const LazyStaticAlloc = @import("LazyStatic.zig").LazyStaticAlloc;
pub const Iterators = @import("Iterators.zig");
pub const ManuallyDrop = @import("ManuallyDrop.zig").ManuallyDrop;
pub const MaybeUninit = @import("MaybeUninit.zig").MaybeUninit;
pub const Pin = @import("Pin.zig").Pin;
pub const BTreeMap = @import("BTreeMap.zig").BTreeMap;
pub const HashSet = @import("HashSet.zig").HashSet;
pub const BinaryHeap = @import("BinaryHeap.zig").BinaryHeap;
pub const UnsafeCell = @import("UnsafeCell.zig").UnsafeCell;
pub const PhantomData = @import("PhantomData.zig").PhantomData;
pub const Channel = @import("Channel.zig").Channel;
pub const Oneshot = @import("Channel.zig").Oneshot;
pub const Pool = @import("Pool.zig").Pool;
pub const PoolBox = @import("Pool.zig").PoolBox;
pub const FixedVec = @import("Pool.zig").FixedVec;
comptime { _ = Pool; }
comptime { _ = FixedVec; }
pub const ZustAllocator = @import("Allocator.zig").ZustAllocator;
pub const TrackingAllocator = @import("Allocator.zig").TrackingAllocator;
pub const wrap = @import("Allocator.zig").wrap;
comptime { _ = ZustAllocator; }
pub const SimdUtils = @import("SimdUtils.zig");
comptime { _ = SimdUtils; }
pub const SendSync = @import("SendSync.zig");
comptime { _ = SendSync; }
pub const StackRef = @import("Lifetime.zig").StackRef;
pub const ScopeGuard = @import("Lifetime.zig").ScopeGuard;
pub const ScopeId = @import("Lifetime.zig").ScopeId;
pub const enterScope = @import("Lifetime.zig").enterScope;
pub const currentScope = @import("Lifetime.zig").currentScope;
pub const NonNull = @import("Lifetime.zig").NonNull;
pub const TaggedUnion2 = @import("TaggedUnion.zig").TaggedUnion2;
pub const TaggedUnion3 = @import("TaggedUnion.zig").TaggedUnion3;
pub const Result = @import("TaggedUnion.zig").Result;
pub const Option = @import("TaggedUnion.zig").Option;
pub const FileGuard = @import("Resources.zig").FileGuard;
pub const DirGuard = @import("Resources.zig").DirGuard;
pub const MappedFileGuard = @import("Resources.zig").MappedFileGuard;
pub const ArenaGuard = @import("Resources.zig").ArenaGuard;
pub const ThreadPool = @import("ThreadPool.zig").ThreadPool;
pub const Semaphore = @import("Semaphore.zig").Semaphore;
pub const Barrier = @import("Barrier.zig").Barrier;
pub const LockFreeQueue = @import("LockFreeQueue.zig").LockFreeQueue;
pub const AtomicCounter = @import("AtomicCounter.zig").AtomicCounter;
pub const TimedMutex = @import("TimedLock.zig").TimedMutex;
pub const TimedMutexGuard = @import("TimedLock.zig").TimedMutexGuard;
comptime { _ = ThreadPool; }
comptime { _ = Semaphore; }
comptime { _ = Barrier; }
comptime { _ = LockFreeQueue; }
comptime { _ = AtomicCounter; }
comptime { _ = TimedMutex; }

test "Box init and deinit" {
    const box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    const dead = box.deinit();
    _ = dead;
}

test "Box immutable borrow and release" {
    const box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    const b1 = box.borrowImm();
    const b2 = b1.borrowImm();
    const b1_back = b2.releaseImm();
    const box_back = b1_back.releaseImm();
    const dead = box_back.deinit();
    _ = dead;
}

test "Box mutable borrow and release" {
    const box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    const borrowed = box.borrowMut();
    borrowed.ptr.* = 100;
    const box_back = borrowed.releaseMut();
    const dead = box_back.deinit();
    _ = dead;
}

test "Box ownership transfer by parameter passing" {
    const box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    takeOwnership(box);
}

fn takeOwnership(b: Box(u32, 0, 0, 0)) void {
    const dead = b.deinit();
    _ = dead;
}

test "Box withImm closure" {
    const box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    var sum: u32 = 0;
    box.withImm(&sum, struct {
        fn f(ctx: *u32, val: *const u32) void {
            ctx.* += val.*;
        }
    }.f);
    try std.testing.expectEqual(sum, 42);
    const dead = box.deinit();
    _ = dead;
}

test "Box withMut closure" {
    var box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    box.withMut(&box, struct {
        fn f(_: *Box(u32, 0, 0, 0), val: *u32) void {
            val.* = 100;
        }
    }.f);
    try std.testing.expectEqual(box.ptr.*, 100);
    const dead = box.deinit();
    _ = dead;
}

test "LinkedList push and pop" {
    var list = LinkedList(u32).init(std.testing.allocator);
    try list.push(10);
    try list.push(20);
    try list.push(30);

    try std.testing.expectEqual(list.pop(), 30);
    try std.testing.expectEqual(list.pop(), 20);
    try std.testing.expectEqual(list.pop(), 10);
    try std.testing.expectEqual(list.pop(), null);
}

test "LinkedList deinit" {
    var list = LinkedList(u32).init(std.testing.allocator);
    try list.push(1);
    try list.push(2);
    list.deinit();
}

test "LinkedList len" {
    var list = LinkedList(u32).init(std.testing.allocator);
    try std.testing.expectEqual(list.len(), 0);
    try list.push(1);
    try std.testing.expectEqual(list.len(), 1);
    try list.push(2);
    try std.testing.expectEqual(list.len(), 2);
    _ = list.pop();
    try std.testing.expectEqual(list.len(), 1);
    list.deinit();
}

test "LinkedList forEach" {
    var list = LinkedList(u32).init(std.testing.allocator);
    try list.push(10);
    try list.push(20);
    try list.push(30);

    var sum: u32 = 0;
    list.forEach(&sum, struct {
        fn f(ctx: *u32, val: *const u32) void {
            ctx.* += val.*;
        }
    }.f);
    try std.testing.expectEqual(sum, 60);
    list.deinit();
}

test "LinkedList forEachMut" {
    var list = LinkedList(u32).init(std.testing.allocator);
    try list.push(1);
    try list.push(2);
    try list.push(3);

    list.forEachMut(&list, struct {
        fn f(_: *LinkedList(u32), val: *u32) void {
            val.* *= 10;
        }
    }.f);

    try std.testing.expectEqual(list.pop(), 30);
    try std.testing.expectEqual(list.pop(), 20);
    try std.testing.expectEqual(list.pop(), 10);
    list.deinit();
}

test "LinkedList retain" {
    var list = LinkedList(u32).init(std.testing.allocator);
    try list.push(4);
    try list.push(3);
    try list.push(2);
    try list.push(1);

    list.retain({}, struct {
        fn f(_: void, val: *const u32) bool {
            return val.* % 2 == 0;
        }
    }.f);

    try std.testing.expectEqual(list.len(), 2);
    try std.testing.expectEqual(list.pop(), 2);
    try std.testing.expectEqual(list.pop(), 4);
    list.deinit();
}

test "LinkedList reverse" {
    var list = LinkedList(u32).init(std.testing.allocator);
    defer list.deinit();

    try list.push(30);
    try list.push(20);
    try list.push(10);

    list.reverse();

    try std.testing.expectEqual(list.pop(), 30);
    try std.testing.expectEqual(list.pop(), 20);
    try std.testing.expectEqual(list.pop(), 10);
    try std.testing.expectEqual(list.pop(), null);
}

// === ArrayList Tests ===

test "ArrayList append and get" {
    var list = ArrayList(u32).init(std.testing.allocator);
    defer list.deinit();

    const b1 = try Box(u32, 0, 0, 0).init(std.testing.allocator, 10);
    const b2 = try Box(u32, 0, 0, 0).init(std.testing.allocator, 20);
    const b3 = try Box(u32, 0, 0, 0).init(std.testing.allocator, 30);

    try list.append(b1);
    try list.append(b2);
    try list.append(b3);

    try std.testing.expectEqual(list.len(), 3);

    // get() removes the item from the list
    const got = list.get(1);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(got.?.ptr.*, 20);
    try std.testing.expectEqual(list.len(), 2); // Item removed

    const dead = got.?.deinit();
    _ = dead;
}

test "ArrayList getMut" {
    var list = ArrayList(u32).init(std.testing.allocator);
    defer list.deinit();

    const b = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    try list.append(b);

    const maybe_borrow = list.getMut(0);
    try std.testing.expect(maybe_borrow != null);

    const borrow = maybe_borrow.?;
    borrow.box.ptr.* = 100;
    borrow.releaseMut();

    // Verify the mutation stuck
    const got = list.get(0);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(got.?.ptr.*, 100);
    const dead = got.?.deinit();
    _ = dead;
}

test "ArrayList borrowImm and releaseImm" {
    var list = ArrayList(u32).init(std.testing.allocator);
    defer list.deinit();

    const b = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    try list.append(b);

    const maybe_borrow = list.borrowImm(0);
    try std.testing.expect(maybe_borrow != null);

    const borrow = maybe_borrow.?;
    try std.testing.expectEqual(borrow.box.ptr.*, 42);
    borrow.releaseImm();
}

test "ArrayList pop" {
    var list = ArrayList(u32).init(std.testing.allocator);
    defer list.deinit();

    const b = try Box(u32, 0, 0, 0).init(std.testing.allocator, 100);
    try list.append(b);

    const popped = list.pop();
    try std.testing.expect(popped != null);
    try std.testing.expectEqual(popped.?.ptr.*, 100);

    const dead = popped.?.deinit();
    _ = dead;
}

test "ArrayList withImm closure" {
    var list = ArrayList(u32).init(std.testing.allocator);
    defer list.deinit();

    const b = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    try list.append(b);

    var sum: u32 = 0;
    list.withImm(0, &sum, struct {
        fn f(ctx: *u32, val: *const u32) void {
            ctx.* += val.*;
        }
    }.f);
    try std.testing.expectEqual(sum, 42);
}

test "ArrayList swapRemove" {
    var list = ArrayList(u32).init(std.testing.allocator);
    defer list.deinit();

    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 10));
    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 20));
    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 30));

    const removed = list.swapRemove(0);
    try std.testing.expect(removed != null);
    try std.testing.expectEqual(removed.?.ptr.*, 10); // original first element, swapped to end and popped
    const dead = removed.?.deinit();
    _ = dead;

    try std.testing.expectEqual(list.len(), 2);
    const first = list.get(0);
    try std.testing.expect(first != null);
    try std.testing.expectEqual(first.?.ptr.*, 30); // last element moved to front
    const dead2 = first.?.deinit();
    _ = dead2;
}

test "ArrayList retain" {
    var list = ArrayList(u32).init(std.testing.allocator);
    defer list.deinit();

    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 1));
    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 2));
    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 3));
    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 4));

    list.retain({}, struct {
        fn f(_: void, val: *const u32) bool {
            return val.* % 2 == 0;
        }
    }.f);

    try std.testing.expectEqual(list.len(), 2);
    const a = list.get(0);
    try std.testing.expect(a != null);
    try std.testing.expectEqual(a.?.ptr.*, 2);
    const dead_a = a.?.deinit();
    _ = dead_a;
    const b = list.get(0);
    try std.testing.expect(b != null);
    try std.testing.expectEqual(b.?.ptr.*, 4);
    const dead_b = b.?.deinit();
    _ = dead_b;
}

test "ArrayList resize shrink" {
    var list = ArrayList(u32).init(std.testing.allocator);
    defer list.deinit();

    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 10));
    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 20));
    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 30));

    try list.resize(1);
    try std.testing.expectEqual(list.len(), 1);

    const got = list.get(0);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(got.?.ptr.*, 10);
    const dead = got.?.deinit();
    _ = dead;
}

test "ArrayList resize grow" {
    var list = ArrayList(u32).init(std.testing.allocator);
    defer list.deinit();

    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 42));
    try list.resize(3);
    try std.testing.expectEqual(list.len(), 3);

    // Overwrite undefined new slots with valid boxes so deinit is safe
    list.items.items[1] = try Box(u32, 0, 0, 0).init(std.testing.allocator, 1);
    list.items.items[2] = try Box(u32, 0, 0, 0).init(std.testing.allocator, 2);

    const got = list.get(0);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(got.?.ptr.*, 42);
    const dead = got.?.deinit();
    _ = dead;
}

test "ArrayList clear" {
    var list = ArrayList(u32).init(std.testing.allocator);
    defer list.deinit();

    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 10));
    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 20));
    list.clear();
    try std.testing.expectEqual(list.len(), 0);
}

test "ArrayList ensureCapacity" {
    var list = ArrayList(u32).init(std.testing.allocator);
    defer list.deinit();

    try list.ensureCapacity(10);
    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 1));
    try std.testing.expectEqual(list.len(), 1);
}

// === Arc Tests ===

test "Arc init and drop" {
    const arc = try Arc(u32).init(std.testing.allocator, 42);
    arc.drop();
}

test "Arc clone and drop" {
    const arc1 = try Arc(u32).init(std.testing.allocator, 100);
    const arc2 = arc1.clone();

    try std.testing.expectEqual(arc1.get().*, 100);
    try std.testing.expectEqual(arc2.get().*, 100);

    arc1.drop();
    // arc2 still valid
    try std.testing.expectEqual(arc2.get().*, 100);
    arc2.drop();
}

test "Arc getMut unique" {
    const arc = try Arc(u32).init(std.testing.allocator, 5);
    arc.getMut().* = 10;
    try std.testing.expectEqual(arc.get().*, 10);
    arc.drop();
}

test "Arc tryUnwrap success" {
    const arc = try Arc(u32).init(std.testing.allocator, 42);
    const maybe_box = arc.tryUnwrap();
    try std.testing.expect(maybe_box != null);
    try std.testing.expectEqual(maybe_box.?.ptr.*, 42);
    const dead = maybe_box.?.deinit();
    _ = dead;
}

test "Arc tryUnwrap fails when shared" {
    const arc = try Arc(u32).init(std.testing.allocator, 42);
    const arc2 = arc.clone();
    const maybe_box = arc.tryUnwrap();
    try std.testing.expect(maybe_box == null);
    arc.drop();
    arc2.drop();
}

test "Arc makeMut unique" {
    var arc = try Arc(u32).init(std.testing.allocator, 5);
    const ptr = try arc.makeMut();
    ptr.* = 10;
    try std.testing.expectEqual(arc.get().*, 10);
    arc.drop();
}

test "Arc makeMut clones when shared" {
    var arc = try Arc(u32).init(std.testing.allocator, 5);
    const arc2 = arc.clone();
    const ptr = try arc.makeMut();
    ptr.* = 10;
    try std.testing.expectEqual(arc.get().*, 10);
    try std.testing.expectEqual(arc2.get().*, 5);
    arc.drop();
    arc2.drop();
}

test "Arc isUnique" {
    const arc = try Arc(u32).init(std.testing.allocator, 42);
    try std.testing.expect(arc.isUnique());
    const arc2 = arc.clone();
    try std.testing.expect(!arc.isUnique());
    try std.testing.expect(!arc2.isUnique());
    arc2.drop();
    try std.testing.expect(arc.isUnique());
    arc.drop();
}

test "Arc strongCount and weakCount" {
    const arc = try Arc(u32).init(std.testing.allocator, 42);
    try std.testing.expectEqual(arc.strongCount(), 1);
    try std.testing.expectEqual(arc.weakCount(), 1);
    const weak = arc.downgrade();
    try std.testing.expectEqual(arc.strongCount(), 1);
    try std.testing.expectEqual(arc.weakCount(), 2);
    try std.testing.expectEqual(weak.strongCount(), 1);
    try std.testing.expectEqual(weak.weakCount(), 2);
    weak.drop();
    arc.drop();
}

// === Mutex Tests ===

test "Mutex init and deinit" {
    var mtx = try Mutex(u32).init(std.testing.allocator, 0);
    mtx.deinit();
}

test "Mutex withLock" {
    var mtx = try Mutex(u32).init(std.testing.allocator, 0);
    defer mtx.deinit();

    var ctx: u32 = 0;
    mtx.withLock(&ctx, struct {
        fn f(c: *u32, val: *u32) void {
            c.* = 42;
            val.* = 42;
        }
    }.f);

    mtx.lock();
    try std.testing.expectEqual(mtx.get().*, 42);
    mtx.unlock();
}

// === Scope Tests ===

test "ScopeImm borrow and release" {
    const box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    var borrowed = ScopeImm(u32).borrow(box);
    try std.testing.expectEqual(borrowed.scope.ptr().*, 42);
    const back = borrowed.scope.release();
    const dead = back.deinit();
    _ = dead;
}

test "ScopeMut borrow and release" {
    const box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    var borrowed = ScopeMut(u32).borrow(box);
    borrowed.scope.ptr().* = 100;
    const back = borrowed.scope.release();
    try std.testing.expectEqual(back.ptr.*, 100);
    const dead = back.deinit();
    _ = dead;
}

// === AsyncBox Tests ===

test "AsyncBox init and deinit" {
    var abox = try AsyncBox(u32).init(std.testing.allocator, 42);
    abox.deinit();
}

test "AsyncBox take" {
    var abox = try AsyncBox(u32).init(std.testing.allocator, 42);
    const box = abox.take();
    try std.testing.expect(box != null);
    try std.testing.expectEqual(box.?.ptr.*, 42);
    const dead = box.?.deinit();
    _ = dead;
}

test "AsyncBox withImm" {
    var abox = try AsyncBox(u32).init(std.testing.allocator, 42);
    var val: u32 = 0;
    abox.withImm(&val, struct {
        fn f(ctx: *u32, v: *const u32) void {
            ctx.* = v.*;
        }
    }.f);
    try std.testing.expectEqual(val, 42);
    abox.deinit();
}

// === Slice Tests ===

test "Slice from stack array" {
    const arr = [_]u32{ 10, 20, 30 };
    const s = Slice(u32).fromStack(&arr);
    try std.testing.expectEqual(s.len(), 3);
    try std.testing.expectEqual(s.get(0).?, 10);
    try std.testing.expectEqual(s.get(1).?, 20);
    try std.testing.expectEqual(s.get(2).?, 30);
    try std.testing.expectEqual(s.get(3), null);
    s.release();
}

// === RwLock Tests ===

test "RwLock init and deinit" {
    var rw = try RwLock(u32).init(std.testing.allocator, 0);
    rw.deinit();
}

test "RwLock read and write" {
    var rw = try RwLock(u32).init(std.testing.allocator, 42);
    defer rw.deinit();

    rw.readLock();
    try std.testing.expectEqual(rw.get().*, 42);
    rw.readUnlock();

    rw.writeLock();
    rw.getMut().* = 100;
    rw.writeUnlock();

    rw.readLock();
    try std.testing.expectEqual(rw.get().*, 100);
    rw.readUnlock();
}

// === Guard Tests ===

test "MutexGuard acquire and auto-release" {
    var mtx = try Mutex(u32).init(std.testing.allocator, 42);
    defer mtx.deinit();

    {
        const guard = mtx.acquire();
        defer guard.deinit();
        try std.testing.expectEqual(guard.get().*, 42);
        guard.getMut().* = 100;
        // guard automatically releases via defer
    }

    // Can acquire again after guard dropped
    const guard2 = mtx.acquire();
    defer guard2.deinit();
    try std.testing.expectEqual(guard2.get().*, 100);
}

test "RwLockReadGuard acquire and auto-release" {
    var rw = try RwLock(u32).init(std.testing.allocator, 42);
    defer rw.deinit();

    {
        const guard = rw.acquireRead();
        defer guard.deinit();
        try std.testing.expectEqual(guard.get().*, 42);
        // Read guard auto-releases via defer
    }

    // Can acquire write after read guard dropped
    const wguard = rw.acquireWrite();
    defer wguard.deinit();
    wguard.getMut().* = 100;
}

test "RwLockWriteGuard acquire and auto-release" {
    var rw = try RwLock(u32).init(std.testing.allocator, 42);
    defer rw.deinit();

    {
        const guard = rw.acquireWrite();
        defer guard.deinit();
        guard.getMut().* = 200;
        // Write guard auto-releases via defer
    }

    const rguard = rw.acquireRead();
    defer rguard.deinit();
    try std.testing.expectEqual(rguard.get().*, 200);
}

// Compile-error verification tests
// Uncomment one at a time to verify @compileError

// test "compile_error: double_free" {
//     const box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
//     const dead = box.deinit();
//     const dead2 = dead.deinit(); // Expected: "double free detected"
//     _ = dead2;
// }

// test "compile_error: free_with_active_borrows" {
//     const box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
//     const b1 = box.borrowImm();
//     b1.deinit(); // Expected: "cannot free: value is not in Owned state"
// }

// test "compile_error: borrow_mut_while_imm_active" {
//     const box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
//     const b1 = box.borrowImm();
//     const mut = b1.borrowMut(); // Expected: "cannot borrow mutably: active immutable borrows exist"
//     _ = mut;
// }

// === HashMap Tests ===

test "HashMap put and get" {
    var map = HashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    const b1 = try Box(u32, 0, 0, 0).init(std.testing.allocator, 100);
    try map.put("key1", b1);

    try std.testing.expect(map.contains("key1"));
    try std.testing.expectEqual(map.len(), 1);

    // get() removes the item from the map
    const got = map.get("key1");
    try std.testing.expect(got != null);
    try std.testing.expectEqual(got.?.ptr.*, 100);
    try std.testing.expect(!map.contains("key1")); // Removed
    try std.testing.expectEqual(map.len(), 0);

    const dead = got.?.deinit();
    _ = dead;
}

test "HashMap getMut" {
    var map = HashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    const b = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    try map.put("key1", b);

    const maybe_borrow = map.getMut("key1");
    try std.testing.expect(maybe_borrow != null);
    maybe_borrow.?.box.ptr.* = 100;
    maybe_borrow.?.releaseMut();

    // Verify mutation stuck
    const got = map.get("key1");
    try std.testing.expect(got != null);
    try std.testing.expectEqual(got.?.ptr.*, 100);
    const dead = got.?.deinit();
    _ = dead;
}

test "HashMap remove" {
    var map = HashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    const b = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    try map.put("key1", b);

    const removed = map.remove("key1");
    try std.testing.expect(removed != null);
    try std.testing.expectEqual(removed.?.ptr.*, 42);

    // Clean up the removed box
    const dead = removed.?.deinit();
    _ = dead;

    try std.testing.expect(!map.contains("key1"));
    try std.testing.expectEqual(map.len(), 0);
}

test "HashMap borrowImm" {
    var map = HashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    const b = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    try map.put("key1", b);

    const maybe_borrow = map.borrowImm("key1");
    try std.testing.expect(maybe_borrow != null);
    try std.testing.expectEqual(maybe_borrow.?.box.ptr.*, 42);
    maybe_borrow.?.releaseImm();
}

test "HashMap replace existing" {
    var map = HashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    const b1 = try Box(u32, 0, 0, 0).init(std.testing.allocator, 10);
    try map.put("key1", b1);

    const b2 = try Box(u32, 0, 0, 0).init(std.testing.allocator, 20);
    try map.put("key1", b2);

    const got = map.get("key1");
    try std.testing.expect(got != null);
    try std.testing.expectEqual(got.?.ptr.*, 20);
    const dead = got.?.deinit();
    _ = dead;
}

test "HashMap Entry orInsert" {
    var map = HashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    // Insert new value via entry
    const box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    const e = map.entry("key1");
    try std.testing.expect(!e.isOccupied());
    try std.testing.expectEqual(e.getKey(), "key1");
    const ptr = try e.orInsert(box);
    try std.testing.expectEqual(ptr.ptr.*, 42);
    try std.testing.expect(map.contains("key1"));
    try std.testing.expectEqual(map.len(), 1);

    // Existing entry - orInsert returns existing, deinits unused box
    const box2 = try Box(u32, 0, 0, 0).init(std.testing.allocator, 100);
    const e2 = map.entry("key1");
    try std.testing.expect(e2.isOccupied());
    const ptr2 = try e2.orInsert(box2);
    try std.testing.expectEqual(ptr2.ptr.*, 42); // Still 42, not 100
    try std.testing.expectEqual(map.len(), 1);
}

test "HashMap Entry orInsertWith" {
    var map = HashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    const e = map.entry("key1");
    const ptr = try e.orInsertWith(10, struct {
        fn f(ctx: u32) !Box(u32, 0, 0, 0) {
            return Box(u32, 0, 0, 0).init(std.testing.allocator, ctx);
        }
    }.f);
    try std.testing.expectEqual(ptr.ptr.*, 10);
    try std.testing.expect(map.contains("key1"));
    try std.testing.expectEqual(map.len(), 1);

    // Existing entry - factory not called, returns existing
    const e2 = map.entry("key1");
    const ptr2 = try e2.orInsertWith(99, struct {
        fn f(ctx: u32) !Box(u32, 0, 0, 0) {
            return Box(u32, 0, 0, 0).init(std.testing.allocator, ctx);
        }
    }.f);
    try std.testing.expectEqual(ptr2.ptr.*, 10); // Still 10
}

test "HashMap Entry andModify" {
    var map = HashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    const box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    try map.put("key1", box);

    const e = map.entry("key1");
    try std.testing.expect(e.isOccupied());
    e.andModify(&map, struct {
        fn f(_: *HashMap(u32), val: *u32) void {
            val.* = 100;
        }
    }.f);

    const got = map.get("key1");
    try std.testing.expect(got != null);
    try std.testing.expectEqual(got.?.ptr.*, 100);
    const dead = got.?.deinit();
    _ = dead;
}

test "HashMap Entry andModify on vacant" {
    var map = HashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    const e = map.entry("missing");
    try std.testing.expect(!e.isOccupied());
    // Should be a no-op on vacant entry
    e.andModify(&map, struct {
        fn f(_: *HashMap(u32), val: *u32) void {
            val.* = 999;
        }
    }.f);

    try std.testing.expect(!map.contains("missing"));
}

test "HashMap getOrPut" {
    var map = HashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    const box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    const ptr = try map.getOrPut("key1", box);
    try std.testing.expectEqual(ptr.ptr.*, 42);
    try std.testing.expect(map.contains("key1"));

    // getOrPut on existing key returns existing, deinits unused box
    const box2 = try Box(u32, 0, 0, 0).init(std.testing.allocator, 100);
    const ptr2 = try map.getOrPut("key1", box2);
    try std.testing.expectEqual(ptr2.ptr.*, 42); // Still 42
    try std.testing.expectEqual(map.len(), 1);

    // Clean up inserted value
    const got = map.get("key1");
    try std.testing.expect(got != null);
    const dead = got.?.deinit();
    _ = dead;
}

test "HashMap retain" {
    var map = HashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    try map.put("a", try Box(u32, 0, 0, 0).init(std.testing.allocator, 1));
    try map.put("b", try Box(u32, 0, 0, 0).init(std.testing.allocator, 2));
    try map.put("c", try Box(u32, 0, 0, 0).init(std.testing.allocator, 3));
    try map.put("d", try Box(u32, 0, 0, 0).init(std.testing.allocator, 4));

    map.retain({}, struct {
        fn f(_: void, key: []const u8, val: *const u32) bool {
            _ = key;
            return val.* % 2 == 0;
        }
    }.f);

    try std.testing.expect(!map.contains("a"));
    try std.testing.expect(map.contains("b"));
    try std.testing.expect(!map.contains("c"));
    try std.testing.expect(map.contains("d"));
    try std.testing.expectEqual(map.len(), 2);
}

test "HashMap drain" {
    var map = HashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    try map.put("a", try Box(u32, 0, 0, 0).init(std.testing.allocator, 10));
    try map.put("b", try Box(u32, 0, 0, 0).init(std.testing.allocator, 20));

    var iter = map.drain();

    const first = iter.next();
    try std.testing.expect(first != null);
    const first_val = first.?.value.ptr.*;
    std.testing.allocator.free(first.?.key);
    const dead1 = first.?.value.deinit();
    _ = dead1;

    const second = iter.next();
    try std.testing.expect(second != null);
    const second_val = second.?.value.ptr.*;
    std.testing.allocator.free(second.?.key);
    const dead2 = second.?.value.deinit();
    _ = dead2;

    try std.testing.expect((first_val == 10 and second_val == 20) or (first_val == 20 and second_val == 10));
    try std.testing.expect(iter.next() == null);
    try std.testing.expectEqual(map.len(), 0);
}

test "HashMap clear" {
    var map = HashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    try map.put("a", try Box(u32, 0, 0, 0).init(std.testing.allocator, 10));
    try map.put("b", try Box(u32, 0, 0, 0).init(std.testing.allocator, 20));

    map.clear();
    try std.testing.expectEqual(map.len(), 0);
    try std.testing.expect(!map.contains("a"));
    try std.testing.expect(!map.contains("b"));
}

// === Rc Tests ===

test "Rc init and drop" {
    const rc = try Rc(u32).init(std.testing.allocator, 42);
    rc.drop();
}

test "Rc clone and drop" {
    const rc1 = try Rc(u32).init(std.testing.allocator, 100);
    const rc2 = rc1.clone();

    try std.testing.expectEqual(rc1.get().*, 100);
    try std.testing.expectEqual(rc2.get().*, 100);

    rc1.drop();
    // rc2 still valid
    try std.testing.expectEqual(rc2.get().*, 100);
    rc2.drop();
}

test "Rc getMut unique" {
    const rc = try Rc(u32).init(std.testing.allocator, 5);
    rc.getMut().* = 10;
    try std.testing.expectEqual(rc.get().*, 10);
    rc.drop();
}

test "Rc strongCount" {
    const rc1 = try Rc(u32).init(std.testing.allocator, 1);
    try std.testing.expectEqual(rc1.strongCount(), 1);

    const rc2 = rc1.clone();
    try std.testing.expectEqual(rc1.strongCount(), 2);
    try std.testing.expectEqual(rc2.strongCount(), 2);

    rc1.drop();
    try std.testing.expectEqual(rc2.strongCount(), 1);
    rc2.drop();
}

test "Rc tryUnwrap success" {
    const rc = try Rc(u32).init(std.testing.allocator, 42);
    const maybe_box = rc.tryUnwrap();
    try std.testing.expect(maybe_box != null);
    try std.testing.expectEqual(maybe_box.?.ptr.*, 42);
    const dead = maybe_box.?.deinit();
    _ = dead;
}

test "Rc tryUnwrap fails when shared" {
    const rc = try Rc(u32).init(std.testing.allocator, 42);
    const rc2 = rc.clone();
    const maybe_box = rc.tryUnwrap();
    try std.testing.expect(maybe_box == null);
    rc.drop();
    rc2.drop();
}

test "Rc makeMut unique" {
    var rc = try Rc(u32).init(std.testing.allocator, 5);
    const ptr = try rc.makeMut();
    ptr.* = 10;
    try std.testing.expectEqual(rc.get().*, 10);
    rc.drop();
}

test "Rc makeMut clones when shared" {
    var rc = try Rc(u32).init(std.testing.allocator, 5);
    const rc2 = rc.clone();
    const ptr = try rc.makeMut();
    ptr.* = 10;
    try std.testing.expectEqual(rc.get().*, 10);
    try std.testing.expectEqual(rc2.get().*, 5);
    rc.drop();
    rc2.drop();
}

test "Rc isUnique" {
    const rc = try Rc(u32).init(std.testing.allocator, 42);
    try std.testing.expect(rc.isUnique());
    const rc2 = rc.clone();
    try std.testing.expect(!rc.isUnique());
    try std.testing.expect(!rc2.isUnique());
    rc2.drop();
    try std.testing.expect(rc.isUnique());
    rc.drop();
}

// === Weak Tests ===

test "Arc downgrade and upgrade" {
    const arc = try Arc(u32).init(std.testing.allocator, 42);
    const weak = arc.downgrade();

    // Upgrade succeeds while strong ref exists
    const upgraded = weak.upgrade();
    try std.testing.expect(upgraded != null);
    try std.testing.expectEqual(upgraded.?.get().*, 42);
    upgraded.?.drop();

    arc.drop();

    // After last strong ref dropped, upgrade returns null
    const upgraded2 = weak.upgrade();
    try std.testing.expect(upgraded2 == null);

    weak.drop();
}

test "Arc weak persists after value dropped" {
    const arc = try Arc(u32).init(std.testing.allocator, 100);
    const weak = arc.downgrade();
    const arc2 = arc.clone();

    arc.drop();
    arc2.drop(); // value freed here

    // Weak ref still valid (control block alive)
    const upgraded = weak.upgrade();
    try std.testing.expect(upgraded == null);

    weak.drop(); // control block freed here
}

test "Weak strongCount and weakCount" {
    const arc = try Arc(u32).init(std.testing.allocator, 42);
    const weak = arc.downgrade();
    try std.testing.expectEqual(weak.strongCount(), 1);
    try std.testing.expectEqual(weak.weakCount(), 2);

    const arc2 = arc.clone();
    try std.testing.expectEqual(weak.strongCount(), 2);
    try std.testing.expectEqual(weak.weakCount(), 2);

    arc.drop();
    arc2.drop();

    try std.testing.expectEqual(weak.strongCount(), 0);
    try std.testing.expectEqual(weak.weakCount(), 1);

    weak.drop();
}

// === Slice Tests ===

test "Slice from Box array" {
    const box = try Box([3]u32, 0, 0, 0).init(std.testing.allocator, .{ 1, 2, 3 });
    const s = Slice(u32).fromBoxArray(box);
    try std.testing.expectEqual(s.len(), 3);
    try std.testing.expectEqual(s.get(0).?, 1);
    try std.testing.expectEqual(s.get(1).?, 2);
    s.release();
    const dead = box.deinit();
    _ = dead;
}

test "Slice from std ArrayList" {
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(std.testing.allocator);

    try list.append(std.testing.allocator, 100);
    try list.append(std.testing.allocator, 200);

    const s = Slice(u32).fromStdArrayList(&list);
    try std.testing.expectEqual(s.len(), 2);
    try std.testing.expectEqual(s.get(0).?, 100);
    try std.testing.expectEqual(s.get(1).?, 200);
    s.release();
}

// === Cell Tests ===

test "Cell get and set" {
    var cell = Cell(u32).init(42);
    try std.testing.expectEqual(cell.get(), 42);
    cell.set(100);
    try std.testing.expectEqual(cell.get(), 100);
}

test "Cell replace" {
    var cell = Cell(u32).init(42);
    const old = cell.replace(100);
    try std.testing.expectEqual(old, 42);
    try std.testing.expectEqual(cell.get(), 100);
}

// === RefCell Tests ===

test "RefCell borrow and release" {
    var rc = RefCell(u32).init(42);
    const b1 = rc.borrow();
    const b2 = rc.borrow();
    try std.testing.expectEqual(b1.get().*, 42);
    try std.testing.expectEqual(b2.get().*, 42);
    b1.deinit();
    b2.deinit();
}

test "RefCell borrowMut and release" {
    var rc = RefCell(u32).init(42);
    const b = rc.borrowMut();
    b.getMut().* = 100;
    b.deinit();
    try std.testing.expectEqual(rc.get(), 100);
}

test "RefCell borrow after borrowMut fails" {
    var rc = RefCell(u32).init(42);
    const b = rc.borrowMut();
    // This would panic at runtime:
    // const b2 = rc.borrow();
    b.deinit();
}

// === VecDeque Tests ===

test "VecDeque pushBack and popBack" {
    var dq = try VecDeque(u32).init(std.testing.allocator);
    defer dq.deinit();

    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 10));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 20));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 30));

    try std.testing.expectEqual(dq.count(), 3);

    const back = dq.popBack();
    try std.testing.expect(back != null);
    try std.testing.expectEqual(back.?.ptr.*, 30);
    const dead1 = back.?.deinit();
    _ = dead1;

    const front = dq.popFront();
    try std.testing.expect(front != null);
    try std.testing.expectEqual(front.?.ptr.*, 10);
    const dead2 = front.?.deinit();
    _ = dead2;

    try std.testing.expectEqual(dq.count(), 1);
}

test "VecDeque pushFront and popFront" {
    var dq = try VecDeque(u32).init(std.testing.allocator);
    defer dq.deinit();

    try dq.pushFront(try Box(u32, 0, 0, 0).init(std.testing.allocator, 30));
    try dq.pushFront(try Box(u32, 0, 0, 0).init(std.testing.allocator, 20));
    try dq.pushFront(try Box(u32, 0, 0, 0).init(std.testing.allocator, 10));

    try std.testing.expectEqual(dq.count(), 3);

    const first = dq.popFront();
    try std.testing.expect(first != null);
    try std.testing.expectEqual(first.?.ptr.*, 10);
    const dead = first.?.deinit();
    _ = dead;
}

test "VecDeque get" {
    var dq = try VecDeque(u32).init(std.testing.allocator);
    defer dq.deinit();

    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 100));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 200));

    const got = dq.get(1);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(got.?.ptr.*, 200);
}

test "VecDeque rotateLeft" {
    var dq = try VecDeque(u32).init(std.testing.allocator);
    defer dq.deinit();

    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 10));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 20));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 30));

    dq.rotateLeft(1);

    const first = dq.popFront();
    try std.testing.expect(first != null);
    try std.testing.expectEqual(first.?.ptr.*, 20);
    const dead = first.?.deinit();
    _ = dead;
}

test "VecDeque rotateRight" {
    var dq = try VecDeque(u32).init(std.testing.allocator);
    defer dq.deinit();

    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 10));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 20));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 30));

    dq.rotateRight(1);

    const first = dq.popFront();
    try std.testing.expect(first != null);
    try std.testing.expectEqual(first.?.ptr.*, 30);
    const dead = first.?.deinit();
    _ = dead;
}

test "VecDeque retain" {
    var dq = try VecDeque(u32).init(std.testing.allocator);
    defer dq.deinit();

    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 1));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 2));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 3));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 4));

    dq.retain({}, struct {
        fn f(_: void, val: *const u32) bool {
            return val.* % 2 == 0;
        }
    }.f);

    try std.testing.expectEqual(dq.count(), 2);
    const a = dq.popFront();
    try std.testing.expect(a != null);
    try std.testing.expectEqual(a.?.ptr.*, 2);
    const dead_a = a.?.deinit();
    _ = dead_a;
    const b = dq.popFront();
    try std.testing.expect(b != null);
    try std.testing.expectEqual(b.?.ptr.*, 4);
    const dead_b = b.?.deinit();
    _ = dead_b;
}

test "VecDeque resize grow" {
    var dq = try VecDeque(u32).init(std.testing.allocator);
    defer dq.deinit();

    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 10));
    const default = try Box(u32, 0, 0, 0).init(std.testing.allocator, 99);
    try dq.resize(3, default);
    try std.testing.expectEqual(dq.count(), 3);

    const first = dq.popFront();
    try std.testing.expect(first != null);
    try std.testing.expectEqual(first.?.ptr.*, 10);
    const dead = first.?.deinit();
    _ = dead;

    const second = dq.popFront();
    try std.testing.expect(second != null);
    try std.testing.expectEqual(second.?.ptr.*, 99);
    const dead2 = second.?.deinit();
    _ = dead2;
}

test "VecDeque resize shrink" {
    var dq = try VecDeque(u32).init(std.testing.allocator);
    defer dq.deinit();

    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 10));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 20));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 30));

    const default = try Box(u32, 0, 0, 0).init(std.testing.allocator, 0);
    try dq.resize(1, default);
    try std.testing.expectEqual(dq.count(), 1);

    const first = dq.popFront();
    try std.testing.expect(first != null);
    try std.testing.expectEqual(first.?.ptr.*, 10);
    const dead = first.?.deinit();
    _ = dead;
}

test "VecDeque truncate" {
    var dq = try VecDeque(u32).init(std.testing.allocator);
    defer dq.deinit();

    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 10));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 20));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 30));

    dq.truncate(1);
    try std.testing.expectEqual(dq.count(), 1);

    const first = dq.popFront();
    try std.testing.expect(first != null);
    try std.testing.expectEqual(first.?.ptr.*, 10);
    const dead = first.?.deinit();
    _ = dead;
}

// === Iterator Tests ===

test "LinkedList iterator" {
    var list = LinkedList(u32).init(std.testing.allocator);
    defer list.deinit();

    try list.push(30);
    try list.push(20);
    try list.push(10);

    var it = list.iterator();
    try std.testing.expectEqual(it.next().?, 10);
    try std.testing.expectEqual(it.next().?, 20);
    try std.testing.expectEqual(it.next().?, 30);
    try std.testing.expect(it.next() == null);
}

test "ArrayList iterator" {
    var list = ArrayList(u32).init(std.testing.allocator);
    defer list.deinit();

    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 10));
    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 20));
    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 30));

    var it = list.iterator();
    // pop() removes from the end, so iteration is LIFO
    const first = it.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqual(first.?.ptr.*, 30);
    _ = first.?.deinit();

    const second = it.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqual(second.?.ptr.*, 20);
    _ = second.?.deinit();

    const third = it.next();
    try std.testing.expect(third != null);
    try std.testing.expectEqual(third.?.ptr.*, 10);
    _ = third.?.deinit();

    try std.testing.expect(it.next() == null);
}

test "VecDeque iterator" {
    var dq = try VecDeque(u32).init(std.testing.allocator);
    defer dq.deinit();

    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 10));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 20));
    try dq.pushBack(try Box(u32, 0, 0, 0).init(std.testing.allocator, 30));

    var it = dq.iterator();
    const first = it.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqual(first.?.ptr.*, 10);
    _ = first.?.deinit();

    const second = it.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqual(second.?.ptr.*, 20);
    _ = second.?.deinit();

    const third = it.next();
    try std.testing.expect(third != null);
    try std.testing.expectEqual(third.?.ptr.*, 30);
    _ = third.?.deinit();

    try std.testing.expect(it.next() == null);
}

// === OnceCell Tests ===

test "OnceCell init and set" {
    var cell = OnceCell(u32).init();
    try std.testing.expect(!cell.isInitialized());
    try cell.set(42);
    try std.testing.expect(cell.isInitialized());
    try std.testing.expectEqual(cell.get().?.*, 42);
}

test "OnceCell double set fails" {
    var cell = OnceCell(u32).init();
    try cell.set(42);
    const result = cell.set(100);
    try std.testing.expectError(error.AlreadyInitialized, result);
    try std.testing.expectEqual(cell.get().?.*, 42);
}

test "OnceCell getOrInit" {
    var cell = OnceCell(u32).init();
    const ptr1 = cell.getOrInit(42);
    try std.testing.expectEqual(ptr1.*, 42);
    try std.testing.expect(cell.isInitialized());
    const ptr2 = cell.getOrInit(100);
    try std.testing.expectEqual(ptr2.*, 42); // still the original
}

test "OnceCell deinit" {
    var cell = OnceCell(u32).init();
    try cell.set(42);
    cell.deinit();
    try std.testing.expect(!cell.isInitialized());
    try std.testing.expect(cell.get() == null);
}

// === LazyCell Tests ===

fn makeLazy42() u32 {
    return 42;
}

test "LazyCell init and get" {
    var cell = LazyCell(u32).init(makeLazy42);
    try std.testing.expect(!cell.isInitialized());
    try std.testing.expectEqual(cell.get().*, 42);
    try std.testing.expect(cell.isInitialized());
    try std.testing.expectEqual(cell.get().*, 42);
}

test "LazyCell getMut" {
    var cell = LazyCell(u32).init(makeLazy42);
    const ptr = cell.getMut();
    ptr.* = 100;
    try std.testing.expectEqual(cell.get().*, 100);
}

test "LazyCell force" {
    var cell = LazyCell(u32).init(makeLazy42);
    try std.testing.expect(!cell.isInitialized());
    cell.force();
    try std.testing.expect(cell.isInitialized());
    try std.testing.expectEqual(cell.get().*, 42);
}

test "LazyCell deinit" {
    var cell = LazyCell(u32).init(makeLazy42);
    cell.force();
    try std.testing.expect(cell.isInitialized());
    cell.deinit();
    try std.testing.expect(!cell.isInitialized());
}

// === OnceBox Tests ===

test "OnceBox init and set" {
    var box = OnceBox(u32).init();
    try std.testing.expect(!box.isInitialized());
    try box.set(std.testing.allocator, 42);
    try std.testing.expect(box.isInitialized());
    try std.testing.expectEqual(box.get().?.*, 42);
    box.deinit();
}

test "OnceBox double set fails" {
    var box = OnceBox(u32).init();
    try box.set(std.testing.allocator, 42);
    const result = box.set(std.testing.allocator, 100);
    try std.testing.expectError(error.AlreadyInitialized, result);
    try std.testing.expectEqual(box.get().?.*, 42);
    box.deinit();
}

test "OnceBox deinit frees memory" {
    var box = OnceBox(u32).init();
    try box.set(std.testing.allocator, 42);
    box.deinit();
    try std.testing.expect(!box.isInitialized());
    try std.testing.expect(box.get() == null);
}

// === LazyStatic Tests ===

fn makeLazyStatic42() u32 {
    return 42;
}

test "LazyStatic init and get" {
    var lazy = LazyStatic(u32).init(makeLazyStatic42);
    try std.testing.expect(!lazy.isInitialized());
    try std.testing.expectEqual(lazy.get().*, 42);
    try std.testing.expect(lazy.isInitialized());
    try std.testing.expectEqual(lazy.get().*, 42);
}

test "LazyStatic getConst" {
    var lazy = LazyStatic(u32).init(makeLazyStatic42);
    const ptr = lazy.getConst();
    try std.testing.expectEqual(ptr.*, 42);
}

test "LazyStatic same pointer" {
    var lazy = LazyStatic(u32).init(makeLazyStatic42);
    const ptr1 = lazy.get();
    const ptr2 = lazy.get();
    try std.testing.expectEqual(ptr1, ptr2);
}

test "LazyStatic thread-safe" {
    var lazy = LazyStatic(u32).init(struct {
        fn f() u32 {
            return 123;
        }
    }.f);

    var threads: [4]std.Thread = undefined;
    var results: [4]*u32 = undefined;

    for (&threads, &results) |*t, *r| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn f(ctx: *LazyStatic(u32), out: **u32) void {
                out.* = ctx.get();
            }
        }.f, .{ &lazy, r });
    }

    for (&threads) |*t| {
        t.join();
    }

    for (&results) |r| {
        try std.testing.expectEqual(r, results[0]);
        try std.testing.expectEqual(r.*, 123);
    }
}

test "LazyStaticAlloc with allocator" {
    const Config = struct {
        name: []const u8,
    };

    var lazy = LazyStaticAlloc(Config).initWithAlloc(struct {
        fn f(allocator: std.mem.Allocator) anyerror!Config {
            const name = try allocator.dupe(u8, "test");
            return .{ .name = name };
        }
    }.f, std.testing.allocator);

    const ptr = try lazy.get();
    try std.testing.expectEqualStrings(ptr.name, "test");

    const ptr2 = try lazy.get();
    try std.testing.expectEqual(ptr, ptr2);

    std.testing.allocator.free(ptr.name);
}

// === String Tests ===

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

// === Cow Tests ===

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

/// Panic with "not yet implemented" message.
/// Similar to Rust's `todo!()` macro.
pub inline fn todo(comptime msg: []const u8) noreturn {
    @panic("not yet implemented: " ++ msg);
}

/// Panic with "unreachable" message.
pub inline fn unreachable_code() noreturn {
    @panic("unreachable code executed");
}

/// Replace the value at `dest` with `src` and return the old value.
/// Similar to Rust's `std::mem::replace`.
pub fn replace(comptime T: type, dest: *T, src: T) T {
    const old = dest.*;
    dest.* = src;
    return old;
}

/// Swap two values.
/// Similar to Rust's `std::mem::swap`.
pub fn swap(comptime T: type, a: *T, b: *T) void {
    const tmp = a.*;
    a.* = b.*;
    b.* = tmp;
}

/// Take the value from `dest`, replacing it with `undefined`.
/// Similar to Rust's `std::mem::take` (but without Default trait).
pub fn take(comptime T: type, dest: *T) T {
    const val = dest.*;
    dest.* = undefined;
    return val;
}

// === UnsafeCell Tests ===

test "UnsafeCell get and set" {
    var cell = UnsafeCell(u32).init(42);
    try std.testing.expectEqual(cell.get().*, 42);
    cell.getMut().* = 100;
    try std.testing.expectEqual(cell.get().*, 100);
}

// === PhantomData Tests ===

test "PhantomData marker type" {
    const Marker = PhantomData(u32);
    const m = Marker.init();
    _ = m;
}

// === todo/unreachable Tests ===

test "todo function" {
    // We can't actually call todo() in a test because it panics,
    // but we verify it compiles by referencing it.
    const f = todo;
    _ = f;
}

test "unreachable_code function" {
    const f = unreachable_code;
    _ = f;
}

// === mem utility Tests ===

test "replace" {
    var x: u32 = 42;
    const old = replace(u32, &x, 100);
    try std.testing.expectEqual(old, 42);
    try std.testing.expectEqual(x, 100);
}

test "swap" {
    var a: u32 = 1;
    var b: u32 = 2;
    swap(u32, &a, &b);
    try std.testing.expectEqual(a, 2);
    try std.testing.expectEqual(b, 1);
}

test "take" {
    var x: u32 = 42;
    const val = take(u32, &x);
    try std.testing.expectEqual(val, 42);
}

// === BinaryHeap Tests ===

test "BinaryHeap peekMut" {
    var heap = BinaryHeap(u64).init(std.testing.allocator, struct {
        fn f(a: *const u64, b: *const u64) bool {
            return a.* > b.*;
        }
    }.f);
    defer heap.deinit();

    try heap.push(try Box(u64, 0, 0, 0).init(std.testing.allocator, 10));
    try heap.push(try Box(u64, 0, 0, 0).init(std.testing.allocator, 30));
    try heap.push(try Box(u64, 0, 0, 0).init(std.testing.allocator, 20));

    const peek = heap.peekMut().?;
    try std.testing.expectEqual(@as(u64, 30), peek.*);
    peek.* = 50;

    const max = heap.pop().?;
    try std.testing.expectEqual(@as(u64, 50), max.unsafePtr().*);
    const dead = max.deinit();
    _ = dead;
}

test "BinaryHeap drainSorted" {
    var heap = BinaryHeap(u64).init(std.testing.allocator, struct {
        fn f(a: *const u64, b: *const u64) bool {
            return a.* > b.*;
        }
    }.f);
    defer heap.deinit();

    try heap.push(try Box(u64, 0, 0, 0).init(std.testing.allocator, 5));
    try heap.push(try Box(u64, 0, 0, 0).init(std.testing.allocator, 1));
    try heap.push(try Box(u64, 0, 0, 0).init(std.testing.allocator, 9));
    try heap.push(try Box(u64, 0, 0, 0).init(std.testing.allocator, 3));

    var sorted = try heap.drainSorted(std.testing.allocator);
    defer {
        for (sorted.items) |box| {
            const dead = box.deinit();
            _ = dead;
        }
        sorted.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 4), sorted.items.len);
    try std.testing.expectEqual(@as(u64, 9), sorted.items[0].unsafePtr().*);
    try std.testing.expectEqual(@as(u64, 5), sorted.items[1].unsafePtr().*);
    try std.testing.expectEqual(@as(u64, 3), sorted.items[2].unsafePtr().*);
    try std.testing.expectEqual(@as(u64, 1), sorted.items[3].unsafePtr().*);
    try std.testing.expect(heap.isEmpty());
}

// === BTreeMap Tests ===

test "BTreeMap rangeKeys" {
    var map = BTreeMap(i32).init(std.testing.allocator);
    defer map.deinit();

    try map.put(3, try Box(i32, 0, 0, 0).init(std.testing.allocator, 300));
    try map.put(1, try Box(i32, 0, 0, 0).init(std.testing.allocator, 100));
    try map.put(5, try Box(i32, 0, 0, 0).init(std.testing.allocator, 500));
    try map.put(2, try Box(i32, 0, 0, 0).init(std.testing.allocator, 200));
    try map.put(4, try Box(i32, 0, 0, 0).init(std.testing.allocator, 400));

    var keys = try map.rangeKeys(2, 4, std.testing.allocator);
    defer keys.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), keys.items.len);
    try std.testing.expectEqual(@as(u64, 2), keys.items[0]);
    try std.testing.expectEqual(@as(u64, 3), keys.items[1]);
    try std.testing.expectEqual(@as(u64, 4), keys.items[2]);
}

test "BTreeMap lowerBound" {
    var map = BTreeMap(i32).init(std.testing.allocator);
    defer map.deinit();

    try map.put(10, try Box(i32, 0, 0, 0).init(std.testing.allocator, 100));
    try map.put(20, try Box(i32, 0, 0, 0).init(std.testing.allocator, 200));
    try map.put(30, try Box(i32, 0, 0, 0).init(std.testing.allocator, 300));

    try std.testing.expectEqual(@as(?u64, 10), map.lowerBound(5));
    try std.testing.expectEqual(@as(?u64, 20), map.lowerBound(20));
    try std.testing.expectEqual(@as(?u64, 30), map.lowerBound(25));
    try std.testing.expectEqual(@as(?u64, null), map.lowerBound(35));
}

test "BTreeMap upperBound" {
    var map = BTreeMap(i32).init(std.testing.allocator);
    defer map.deinit();

    try map.put(10, try Box(i32, 0, 0, 0).init(std.testing.allocator, 100));
    try map.put(20, try Box(i32, 0, 0, 0).init(std.testing.allocator, 200));
    try map.put(30, try Box(i32, 0, 0, 0).init(std.testing.allocator, 300));

    try std.testing.expectEqual(@as(?u64, 10), map.upperBound(5));
    try std.testing.expectEqual(@as(?u64, 20), map.upperBound(10));
    try std.testing.expectEqual(@as(?u64, 30), map.upperBound(25));
    try std.testing.expectEqual(@as(?u64, null), map.upperBound(30));
    try std.testing.expectEqual(@as(?u64, null), map.upperBound(35));
}

// === HashMap Tests ===

test "HashMap isEmpty" {
    var map = HashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expect(map.isEmpty());
    try std.testing.expectEqual(map.len(), 0);

    const b = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    try map.put("key1", b);

    try std.testing.expect(!map.isEmpty());
    try std.testing.expectEqual(map.len(), 1);
}

// === TaggedUnion Tests ===

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

