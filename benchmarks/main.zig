const std = @import("std");
const safe = @import("safe");

const Benchmark = struct {
    name: []const u8,
    iterations: u64,
    func: *const fn (std.mem.Allocator) anyerror!void,
};

fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

fn runBenchmark(b: Benchmark, allocator: std.mem.Allocator) !i128 {
    const start = nanoTimestamp();
    try b.func(allocator);
    const end = nanoTimestamp();
    const ns = end - start;
    const ns_per_op = @divFloor(ns, @as(i128, b.iterations));
    std.debug.print("{s:40} {d:>10} iterations  {d:>10} ns/op\n", .{ b.name, b.iterations, ns_per_op });
    return ns;
}

inline fn mix(acc: u64, v: u64, i: u64) u64 {
    return acc +% (v *% (i | 1));
}

// ─── 1. Box vs raw allocation ───

fn benchBox(allocator: std.mem.Allocator) !void {
    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        const box = try safe.Box(i32, 0, 0, 0).init(allocator, @intCast(i));
        acc = mix(acc, @intCast(box.ptr.*), i);
        const dead = box.deinit();
        _ = dead;
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchRawAlloc(allocator: std.mem.Allocator) !void {
    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        const ptr = try allocator.create(i32);
        ptr.* = @intCast(i);
        acc = mix(acc, @intCast(ptr.*), i);
        allocator.destroy(ptr);
    }
    std.mem.doNotOptimizeAway(acc);
}

// ─── 2. ArrayList vs std.ArrayList ───

fn benchSafeArrayList(allocator: std.mem.Allocator) !void {
    var list = safe.ArrayList(i32).init(allocator);
    defer list.deinit();
    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        const box = try safe.Box(i32, 0, 0, 0).init(allocator, @intCast(i));
        try list.append(box);
    }
    for (0..1_000_000) |i| {
        if (list.pop()) |box| {
            acc = mix(acc, @intCast(box.ptr.*), i);
            const dead = box.deinit();
            _ = dead;
        }
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchStdArrayList(allocator: std.mem.Allocator) !void {
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(allocator);
    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        try list.append(allocator, @intCast(i));
    }
    for (0..1_000_000) |i| {
        if (list.pop()) |v| {
            acc = mix(acc, @intCast(v), i);
        }
    }
    std.mem.doNotOptimizeAway(acc);
}

// ─── 3. HashMap vs std.HashMap ───

fn benchSafeHashMap(allocator: std.mem.Allocator) !void {
    var map = safe.HashMap(i32).init(allocator);
    defer map.deinit();
    var acc: u64 = 0;
    for (0..100_000) |i| {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d}", .{i});
        const box = try safe.Box(i32, 0, 0, 0).init(allocator, @intCast(i));
        try map.put(key, box);
    }
    for (0..100_000) |i| {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d}", .{i});
        if (map.get(key)) |box| {
            acc = mix(acc, @intCast(box.ptr.*), i);
            const dead = box.deinit();
            _ = dead;
        }
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchStdHashMap(allocator: std.mem.Allocator) !void {
    var map = std.StringHashMap(i32).init(allocator);
    defer {
        var it = map.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
        }
        map.deinit();
    }
    var acc: u64 = 0;
    for (0..100_000) |i| {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d}", .{i});
        const key_copy = try allocator.dupe(u8, key);
        try map.put(key_copy, @intCast(i));
    }
    for (0..100_000) |i| {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d}", .{i});
        if (map.get(key)) |v| {
            acc = mix(acc, @intCast(v), i);
        }
    }
    std.mem.doNotOptimizeAway(acc);
}

// ─── 4. Mutex vs std.atomic.Mutex ───

fn benchSafeMutexSingle(allocator: std.mem.Allocator) !void {
    var mtx = try safe.Mutex(i32).init(allocator, 0);
    defer mtx.deinit();
    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        mtx.lock();
        acc = mix(acc, 1, i);
        mtx.unlock();
    }
    std.mem.doNotOptimizeAway(acc);
}

fn spinLock(mutex: *std.atomic.Mutex) void {
    var spins: u32 = 0;
    while (!mutex.tryLock()) {
        std.atomic.spinLoopHint();
        spins += 1;
        if (spins > 1000) {
            std.Thread.yield() catch {};
            spins = 0;
        }
    }
}

fn benchStdMutexSingle(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var mtx: std.atomic.Mutex = .unlocked;
    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        spinLock(&mtx);
        acc = mix(acc, 1, i);
        mtx.unlock();
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchSafeMutexConcurrent(allocator: std.mem.Allocator) !void {
    var mtx = try safe.Mutex(u64).init(allocator, 0);
    defer mtx.deinit();

    const ops_per_thread = 250_000;

    var accs: [4]u64 = .{ 0, 0, 0, 0 };
    var threads: [4]std.Thread = undefined;
    for (&threads, &accs) |*t, *acc| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn f(m: *safe.Mutex(u64), n: usize, out: *u64) void {
                var local: u64 = 0;
                for (0..n) |i| {
                    m.lock();
                    m.getMut().* += 1;
                    local = mix(local, 1, i);
                    m.unlock();
                }
                out.* = local;
            }
        }.f, .{ &mtx, ops_per_thread, acc });
    }
    for (&threads) |*t| t.join();
    var total_acc: u64 = 0;
    for (accs) |a| total_acc +%= a;
    std.mem.doNotOptimizeAway(total_acc);
}

fn benchStdMutexConcurrent(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var value: u64 = 0;
    var mtx: std.atomic.Mutex = .unlocked;

    const ops_per_thread = 250_000;

    var accs: [4]u64 = .{ 0, 0, 0, 0 };
    var threads: [4]std.Thread = undefined;
    for (&threads, &accs) |*t, *acc| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn f(v: *u64, m: *std.atomic.Mutex, n: usize, out: *u64) void {
                var local: u64 = 0;
                for (0..n) |i| {
                    spinLock(m);
                    v.* += 1;
                    local = mix(local, 1, i);
                    m.unlock();
                }
                out.* = local;
            }
        }.f, .{ &value, &mtx, ops_per_thread, acc });
    }
    for (&threads) |*t| t.join();
    var total_acc: u64 = 0;
    for (accs) |a| total_acc +%= a;
    std.mem.doNotOptimizeAway(total_acc);
}

// ─── 5. SmallString vs String vs raw []u8 ───

const test_string = "hello world 12345";

fn benchSmallString(_: std.mem.Allocator) !void {
    var acc: u64 = 0;
    for (0..100_000) |i| {
        var s = safe.SmallString(23).initFromSlice(test_string);
        acc = mix(acc, s.slice()[i % test_string.len], i);
        s.deinit();
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchSafeString(allocator: std.mem.Allocator) !void {
    var acc: u64 = 0;
    for (0..100_000) |i| {
        var s = try safe.String.initFromSlice(allocator, test_string);
        defer s.deinit();
        acc = mix(acc, s.slice()[i % test_string.len], i);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchRawString(allocator: std.mem.Allocator) !void {
    var acc: u64 = 0;
    for (0..100_000) |i| {
        const s = try allocator.dupe(u8, test_string);
        acc = mix(acc, s[i % test_string.len], i);
        defer allocator.free(s);
    }
    std.mem.doNotOptimizeAway(acc);
}

// ─── 6. Pool vs allocator ───

fn benchPool(allocator: std.mem.Allocator) !void {
    var pool = try safe.Pool(i32).init(allocator, 1_000_001);
    defer pool.deinit();
    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        const box = pool.acquire().?;
        box.getMut().* = @intCast(i);
        acc = mix(acc, @intCast(box.get().*), i);
        box.deinit();
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchRawPool(allocator: std.mem.Allocator) !void {
    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        const ptr = try allocator.create(i32);
        ptr.* = @intCast(i);
        acc = mix(acc, @intCast(ptr.*), i);
        allocator.destroy(ptr);
    }
    std.mem.doNotOptimizeAway(acc);
}

// ─── 7. Stack vs VecDeque (as stack) ───

fn benchStack(allocator: std.mem.Allocator) !void {
    var stack = safe.Stack(i32).init(allocator);
    defer stack.deinit(allocator);
    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        try stack.push(allocator, @intCast(i));
    }
    for (0..1_000_000) |i| {
        if (stack.pop()) |v| {
            acc = mix(acc, @intCast(v), i);
        }
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchVecDequeStack(allocator: std.mem.Allocator) !void {
    var dq = try safe.VecDeque(i32).init(allocator);
    defer dq.deinit();
    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        const box = try safe.Box(i32, 0, 0, 0).init(allocator, @intCast(i));
        try dq.pushBack(box);
    }
    for (0..1_000_000) |i| {
        if (dq.popBack()) |box| {
            acc = mix(acc, @intCast(box.ptr.*), i);
            const dead = box.deinit();
            _ = dead;
        }
    }
    std.mem.doNotOptimizeAway(acc);
}

// ─── 8. Queue vs VecDeque (as queue) ───

fn benchQueue(allocator: std.mem.Allocator) !void {
    var queue = safe.Queue(i32).init(allocator);
    defer queue.deinit(allocator);
    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        try queue.enqueue(allocator, @intCast(i));
    }
    for (0..1_000_000) |i| {
        if (queue.dequeue()) |v| {
            acc = mix(acc, @intCast(v), i);
        }
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchVecDequeQueue(allocator: std.mem.Allocator) !void {
    var dq = try safe.VecDeque(i32).init(allocator);
    defer dq.deinit();
    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        const box = try safe.Box(i32, 0, 0, 0).init(allocator, @intCast(i));
        try dq.pushBack(box);
    }
    for (0..1_000_000) |i| {
        if (dq.popFront()) |box| {
            acc = mix(acc, @intCast(box.ptr.*), i);
            const dead = box.deinit();
            _ = dead;
        }
    }
    std.mem.doNotOptimizeAway(acc);
}

// ─── 9. RingBuffer vs ArrayList circular ───

fn benchRingBuffer(allocator: std.mem.Allocator) !void {
    var rb = try safe.RingBuffer(u8).init(allocator, 1024 * 1024);
    defer rb.deinit(allocator);
    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        try rb.write(@intCast(i % 256));
    }
    for (0..1_000_000) |i| {
        if (rb.read()) |v| {
            acc = mix(acc, v, i);
        }
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchArrayListCircular(allocator: std.mem.Allocator) !void {
    var arr: std.ArrayList(u8) = .empty;
    defer arr.deinit(allocator);
    try arr.resize(allocator, 1024 * 1024);
    var head: usize = 0;
    var tail: usize = 0;
    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        arr.items[tail] = @intCast(i % 256);
        tail = (tail + 1) % arr.items.len;
    }
    for (0..1_000_000) |i| {
        acc = mix(acc, arr.items[head], i);
        head = (head + 1) % arr.items.len;
    }
    std.mem.doNotOptimizeAway(acc);
}

// ─── 10. SIMD String.find 1MB ───

fn benchSimdStringFindScalar(allocator: std.mem.Allocator) !void {
    const haystack = try allocator.alloc(u8, 1_000_000);
    defer allocator.free(haystack);
    for (0..haystack.len) |i| haystack[i] = @intCast(i % 256);
    haystack[500_000] = 'y';

    var acc: usize = 0;
    for (0..100) |_| {
        var pos: ?usize = null;
        for (haystack, 0..) |c, i| {
            if (c == 'y') {
                pos = i;
                break;
            }
        }
        if (pos) |p| acc +%= p;
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchSimdStringFindSimd(allocator: std.mem.Allocator) !void {
    const haystack = try allocator.alloc(u8, 1_000_000);
    defer allocator.free(haystack);
    for (0..haystack.len) |i| haystack[i] = @intCast(i % 256);
    haystack[500_000] = 'y';

    var acc: usize = 0;
    for (0..100) |_| {
        if (safe.SimdUtils.findByte(haystack, 'y')) |pos| acc +%= pos;
    }
    std.mem.doNotOptimizeAway(acc);
}

// ─── 11. SIMD String.startsWith ───

fn benchSimdStartsWithScalar(_: std.mem.Allocator) !void {
    const prefix = "prefix_test_1234567890abcdefghijklmnopqrs";
    var haystack: [10240]u8 = undefined;
    for (0..haystack.len) |i| haystack[i] = @intCast(i % 256);
    @memcpy(haystack[0..prefix.len], prefix);

    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        const byte = @as(*const volatile u8, &haystack[i % haystack.len]).*;
        std.mem.doNotOptimizeAway(byte);
        var match = true;
        for (0..prefix.len) |j| {
            const a = haystack[j];
            const b = prefix[j];
            std.mem.doNotOptimizeAway(a);
            std.mem.doNotOptimizeAway(b);
            if (a != b) {
                match = false;
                break;
            }
        }
        if (match) acc = mix(acc, 1, i);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchSimdStartsWithSimd(_: std.mem.Allocator) !void {
    const prefix = "prefix_test_1234567890abcdefghijklmnopqrs";
    var haystack: [10240]u8 = undefined;
    for (0..haystack.len) |i| haystack[i] = @intCast(i % 256);
    @memcpy(haystack[0..prefix.len], prefix);

    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        const byte = @as(*const volatile u8, &haystack[i % haystack.len]).*;
        std.mem.doNotOptimizeAway(byte);
        if (safe.SimdUtils.startsWith(&haystack, prefix)) acc = mix(acc, 1, i);
    }
    std.mem.doNotOptimizeAway(acc);
}

// ─── 12. SIMD SmallString.contains ───

fn benchSimdSmallStringScalar(_: std.mem.Allocator) !void {
    const text = "hello world 1234567890ab";
    var s = safe.SmallString(23).initFromSlice(text);

    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        const slice = s.slice();
        const byte = @as(*const volatile u8, &slice[i % slice.len]).*;
        std.mem.doNotOptimizeAway(byte);
        var found = false;
        for (slice) |c| {
            if (c == 'b') {
                found = true;
                break;
            }
        }
        if (found) acc = mix(acc, 1, i);
    }
    std.mem.doNotOptimizeAway(acc);
    s.deinit();
}

fn benchSimdSmallStringSimd(_: std.mem.Allocator) !void {
    const text = "hello world 1234567890ab";
    var s = safe.SmallString(23).initFromSlice(text);

    var acc: u64 = 0;
    for (0..1_000_000) |i| {
        const slice = s.slice();
        const byte = @as(*const volatile u8, &slice[i % slice.len]).*;
        std.mem.doNotOptimizeAway(byte);
        if (safe.SimdUtils.findByte(slice, 'b') != null) acc = mix(acc, 1, i);
    }
    std.mem.doNotOptimizeAway(acc);
    s.deinit();
}

// ─── 13. SIMD ArrayList copy ───

fn benchSimdArrayListCopyScalar(allocator: std.mem.Allocator) !void {
    var src = try allocator.alloc(u8, 10_000);
    defer allocator.free(src);
    for (0..src.len) |i| src[i] = @intCast(i % 256);
    const dst = try allocator.alloc(u8, 10_000);
    defer allocator.free(dst);

    var acc: u64 = 0;
    for (0..10_000) |i| {
        for (0..dst.len) |j| {
            dst[j] = src[j];
        }
        acc = mix(acc, dst[5000], i);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchSimdArrayListCopySimd(allocator: std.mem.Allocator) !void {
    var src = try allocator.alloc(u8, 10_000);
    defer allocator.free(src);
    for (0..src.len) |i| src[i] = @intCast(i % 256);
    const dst = try allocator.alloc(u8, 10_000);
    defer allocator.free(dst);

    var acc: u64 = 0;
    for (0..10_000) |i| {
        safe.SimdUtils.copy(dst, src);
        acc = mix(acc, dst[5000], i);
    }
    std.mem.doNotOptimizeAway(acc);
}

fn printSimdComparison(name: []const u8, scalar_ns: i128, simd_ns: i128) void {
    const speedup = @as(f64, @floatFromInt(scalar_ns)) / @as(f64, @floatFromInt(simd_ns));
    std.debug.print("{s:30} scalar={d:>10}ns  simd={d:>10}ns  speedup={d:.1}x\n", .{ name, scalar_ns, simd_ns, speedup });
}

fn benchmarkSimdStringFind(allocator: std.mem.Allocator) !void {
    const haystack = try allocator.alloc(u8, 1_000_000);
    defer allocator.free(haystack);
    for (0..haystack.len) |i| haystack[i] = @intCast(i % 256);
    haystack[500_000] = 'y';

    var scalar_acc: usize = 0;
    const scalar_start = nanoTimestamp();
    for (0..1000) |_| {
        std.mem.doNotOptimizeAway(haystack);
        var pos: ?usize = null;
        for (haystack, 0..) |c, j| {
            if (c == 'y') {
                pos = j;
                break;
            }
        }
        if (pos) |p| scalar_acc +%= p;
    }
    const scalar_end = nanoTimestamp();
    std.mem.doNotOptimizeAway(scalar_acc);

    var simd_acc: usize = 0;
    const simd_start = nanoTimestamp();
    for (0..1000) |_| {
        std.mem.doNotOptimizeAway(haystack);
        if (safe.SimdUtils.findByte(haystack, 'y')) |pos| simd_acc +%= pos;
    }
    const simd_end = nanoTimestamp();
    std.mem.doNotOptimizeAway(simd_acc);

    const scalar_ns = @divFloor(scalar_end - scalar_start, 1000);
    const simd_ns = @divFloor(simd_end - simd_start, 1000);
    printSimdComparison("String.find 1MB", scalar_ns, simd_ns);
}

fn benchmarkSimdStartsWith(_: std.mem.Allocator) !void {
    const prefix = "prefix_test_1234567890abcdefghijklmnopqrs";
    var haystack: [10240]u8 = undefined;
    for (0..haystack.len) |i| haystack[i] = @intCast(i % 256);
    @memcpy(haystack[0..prefix.len], prefix);

    var scalar_acc: u64 = 0;
    const scalar_start = nanoTimestamp();
    for (0..10_000_000) |i| {
        const byte = @as(*const volatile u8, &haystack[i % haystack.len]).*;
        std.mem.doNotOptimizeAway(byte);
        var match = true;
        for (0..prefix.len) |j| {
            const a = haystack[j];
            const b = prefix[j];
            std.mem.doNotOptimizeAway(a);
            std.mem.doNotOptimizeAway(b);
            if (a != b) {
                match = false;
                break;
            }
        }
        if (match) scalar_acc +%= 1;
    }
    const scalar_end = nanoTimestamp();
    std.mem.doNotOptimizeAway(scalar_acc);

    var simd_acc: u64 = 0;
    const simd_start = nanoTimestamp();
    for (0..10_000_000) |i| {
        const byte = @as(*const volatile u8, &haystack[i % haystack.len]).*;
        std.mem.doNotOptimizeAway(byte);
        const match = safe.SimdUtils.startsWith(&haystack, prefix);
        if (match) simd_acc +%= 1;
    }
    const simd_end = nanoTimestamp();
    std.mem.doNotOptimizeAway(simd_acc);

    const scalar_ns = @divFloor(scalar_end - scalar_start, 10_000_000);
    const simd_ns = @divFloor(simd_end - simd_start, 10_000_000);
    printSimdComparison("String.startsWith 10KB", scalar_ns, simd_ns);
}

fn benchmarkSimdSmallString(_: std.mem.Allocator) !void {
    const text = "hello world 1234567890ab";
    var s = safe.SmallString(23).initFromSlice(text);

    var scalar_acc: u64 = 0;
    const scalar_start = nanoTimestamp();
    for (0..10_000_000) |_| {
        std.mem.doNotOptimizeAway(s.slice().ptr);
        var found = false;
        for (s.slice()) |c| {
            if (c == 'b') {
                found = true;
                break;
            }
        }
        if (found) scalar_acc +%= 1;
    }
    const scalar_end = nanoTimestamp();
    std.mem.doNotOptimizeAway(scalar_acc);

    var simd_acc: u64 = 0;
    const simd_start = nanoTimestamp();
    for (0..10_000_000) |_| {
        std.mem.doNotOptimizeAway(s.slice().ptr);
        const found = safe.SimdUtils.findByte(s.slice(), 'b') != null;
        if (found) simd_acc +%= 1;
    }
    const simd_end = nanoTimestamp();
    std.mem.doNotOptimizeAway(simd_acc);

    const scalar_ns = @divFloor(scalar_end - scalar_start, 10_000_000);
    const simd_ns = @divFloor(simd_end - simd_start, 10_000_000);
    printSimdComparison("SmallString.contains", scalar_ns, simd_ns);
    s.deinit();
}

fn benchmarkSimdArrayListCopy(allocator: std.mem.Allocator) !void {
    var src = try allocator.alloc(u8, 10_000);
    defer allocator.free(src);
    for (0..src.len) |i| src[i] = @intCast(i % 256);
    const dst_scalar = try allocator.alloc(u8, 10_000);
    defer allocator.free(dst_scalar);

    const scalar_start = nanoTimestamp();
    for (0..10_000) |_| {
        std.mem.doNotOptimizeAway(src);
        for (0..dst_scalar.len) |j| {
            dst_scalar[j] = src[j];
        }
        std.mem.doNotOptimizeAway(dst_scalar[5000]);
    }
    const scalar_end = nanoTimestamp();

    const dst_simd = try allocator.alloc(u8, 10_000);
    defer allocator.free(dst_simd);

    const simd_start = nanoTimestamp();
    for (0..10_000) |_| {
        std.mem.doNotOptimizeAway(src);
        safe.SimdUtils.copy(dst_simd, src);
        std.mem.doNotOptimizeAway(dst_simd[5000]);
    }
    const simd_end = nanoTimestamp();

    const scalar_ns = @divFloor(scalar_end - scalar_start, 10_000);
    const simd_ns = @divFloor(simd_end - simd_start, 10_000);
    printSimdComparison("ArrayList copy 10K", scalar_ns, simd_ns);
}

// ─── Main ───

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    std.debug.print("\n=== zust Benchmark Suite ===\n\n", .{});
    std.debug.print("{s:40} {s:>10}             {s:>10}\n", .{ "Benchmark", "Iterations", "ns/op" });
    std.debug.print("{s}\n", .{"-" ** 70});

    const benchmarks = [_]Benchmark{
        .{ .name = "1. Box(i32).init + deinit", .iterations = 1_000_000, .func = benchBox },
        .{ .name = "1. raw allocator.create/destroy", .iterations = 1_000_000, .func = benchRawAlloc },
        .{ .name = "2. ArrayList append + pop", .iterations = 1_000_000, .func = benchSafeArrayList },
        .{ .name = "2. std.ArrayList append + pop", .iterations = 1_000_000, .func = benchStdArrayList },
        .{ .name = "3. HashMap put + get", .iterations = 100_000, .func = benchSafeHashMap },
        .{ .name = "3. std.HashMap put + get", .iterations = 100_000, .func = benchStdHashMap },
        .{ .name = "4. Mutex lock/unlock (single)", .iterations = 1_000_000, .func = benchSafeMutexSingle },
        .{ .name = "4. std.atomic.Mutex (single)", .iterations = 1_000_000, .func = benchStdMutexSingle },
        .{ .name = "4. Mutex concurrent (4 threads)", .iterations = 1_000_000, .func = benchSafeMutexConcurrent },
        .{ .name = "4. std.atomic.Mutex concurrent", .iterations = 1_000_000, .func = benchStdMutexConcurrent },
        .{ .name = "5. SmallString(23) init", .iterations = 100_000, .func = benchSmallString },
        .{ .name = "5. String initFromSlice", .iterations = 100_000, .func = benchSafeString },
        .{ .name = "5. raw []u8 dupe", .iterations = 100_000, .func = benchRawString },
        .{ .name = "6. Pool acquire/release", .iterations = 1_000_000, .func = benchPool },
        .{ .name = "6. raw create/destroy", .iterations = 1_000_000, .func = benchRawPool },
        .{ .name = "7. Stack push/pop", .iterations = 1_000_000, .func = benchStack },
        .{ .name = "7. VecDeque pushBack/popBack", .iterations = 1_000_000, .func = benchVecDequeStack },
        .{ .name = "8. Queue enqueue/dequeue", .iterations = 1_000_000, .func = benchQueue },
        .{ .name = "8. VecDeque pushBack/popFront", .iterations = 1_000_000, .func = benchVecDequeQueue },
        .{ .name = "9. RingBuffer write/read", .iterations = 1_000_000, .func = benchRingBuffer },
        .{ .name = "9. ArrayList circular write/read", .iterations = 1_000_000, .func = benchArrayListCircular },
        .{ .name = "10. SIMD String.find 1MB", .iterations = 100, .func = benchSimdStringFindSimd },
        .{ .name = "10. SIMD String.find 1MB (scalar)", .iterations = 100, .func = benchSimdStringFindScalar },
        .{ .name = "11. SIMD startsWith 10KB", .iterations = 1_000_000, .func = benchSimdStartsWithSimd },
        .{ .name = "11. SIMD startsWith 10KB (scalar)", .iterations = 1_000_000, .func = benchSimdStartsWithScalar },
        .{ .name = "12. SIMD SmallString.contains", .iterations = 1_000_000, .func = benchSimdSmallStringSimd },
        .{ .name = "12. SIMD SmallString.contains (scalar)", .iterations = 1_000_000, .func = benchSimdSmallStringScalar },
        .{ .name = "13. SIMD ArrayList copy 10K", .iterations = 10_000, .func = benchSimdArrayListCopySimd },
        .{ .name = "13. SIMD ArrayList copy 10K (scalar)", .iterations = 10_000, .func = benchSimdArrayListCopyScalar },
    };

    var total_ns: i128 = 0;
    for (benchmarks) |b| {
        total_ns += try runBenchmark(b, allocator);
    }

    std.debug.print("{s}\n", .{"-" ** 70});

    // Run SIMD speedup comparison benchmarks
    std.debug.print("\n=== SIMD Speedup Comparisons ===\n\n", .{});
    try benchmarkSimdStringFind(allocator);
    try benchmarkSimdStartsWith(allocator);
    try benchmarkSimdSmallString(allocator);
    try benchmarkSimdArrayListCopy(allocator);

    std.debug.print("{s}\n", .{"-" ** 70});
    const total_ms = @divFloor(total_ns, 1_000_000);
    std.debug.print("Total runtime: {d} ms\n\n", .{total_ms});
}
