const std = @import("std");
const safe = @import("safe");
const SimdUtils = safe.SimdUtils;

// =============================================================================
// Scalar reference implementations (for SIMD correctness verification)
// =============================================================================

fn scalarFindByte(haystack: []const u8, needle: u8) ?usize {
    for (haystack, 0..) |b, i| {
        if (b == needle) return i;
    }
    return null;
}

fn scalarCountByte(haystack: []const u8, needle: u8) usize {
    var count: usize = 0;
    for (haystack) |b| {
        if (b == needle) count += 1;
    }
    return count;
}

fn scalarEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn scalarStartsWith(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    for (0..prefix.len) |i| {
        if (haystack[i] != prefix[i]) return false;
    }
    return true;
}

fn scalarEndsWith(haystack: []const u8, suffix: []const u8) bool {
    if (suffix.len > haystack.len) return false;
    const start = haystack.len - suffix.len;
    for (0..suffix.len) |i| {
        if (haystack[start + i] != suffix[i]) return false;
    }
    return true;
}

// =============================================================================
// 1. Box Fuzzer
// =============================================================================

test "fuzz: Box lifecycle" {
    var rng = std.Random.DefaultPrng.init(0x12345678);
    const allocator = std.testing.allocator;

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const action = rng.random().int(u8) % 5;
        const value: i32 = @intCast(rng.random().int(i32));

        switch (action) {
            0 => { // Create and immediately destroy
                const box = try safe.Box(i32).init(allocator, value);
                const dead = box.deinit();
                _ = dead;
            },
            1 => { // Create, borrow imm, release, destroy
                const box = try safe.Box(i32).init(allocator, value);
                const b = box.borrowImm();
                const back = b.releaseImm();
                const dead = back.deinit();
                _ = dead;
            },
            2 => { // Create, borrow mut, modify, release, destroy
                const box = try safe.Box(i32).init(allocator, value);
                const b = box.borrowMut();
                b.ptr.* = value +% 1;
                const back = b.releaseMut();
                const dead = back.deinit();
                _ = dead;
            },
            3 => { // Create, withImm closure, destroy
                const box = try safe.Box(i32).init(allocator, value);
                var sum: i32 = 0;
                box.withImm(&sum, struct {
                    fn f(ctx: *i32, val: *const i32) void {
                        ctx.* +%= val.*;
                    }
                }.f);
                const dead = box.deinit();
                _ = dead;
            },
            4 => { // Create, withMut closure, destroy
                var box = try safe.Box(i32).init(allocator, value);
                box.withMut(&box, struct {
                    fn f(_: *safe.Box(i32), val: *i32) void {
                        val.* = val.* *% 2;
                    }
                }.f);
                const dead = box.deinit();
                _ = dead;
            },
            else => unreachable,
        }
    }
}

// =============================================================================
// 2. String Fuzzer
// =============================================================================

test "fuzz: String operations" {
    var rng = std.Random.DefaultPrng.init(0xabcdef);
    const allocator = std.testing.allocator;

    var str = safe.String.init(allocator);
    defer str.deinit();

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const action = rng.random().int(u8) % 5;
        switch (action) {
            0 => { // Append random bytes
                const len = rng.random().int(u8) % 64;
                var buf: [64]u8 = undefined;
                for (0..len) |j| buf[j] = rng.random().int(u8);
                try str.append(buf[0..@as(usize, len)]);
            },
            1 => { // Find random byte
                if (str.len() > 0) {
                    const needle = rng.random().int(u8);
                    _ = str.find(&[_]u8{needle});
                }
            },
            2 => { // Trim
                var trimmed = str.trim();
                trimmed.deinit();
            },
            3 => { // Clone and compare
                var cloned = try str.clone();
                defer cloned.deinit();
                try std.testing.expectEqualStrings(str.slice(), cloned.slice());
            },
            4 => { // Replace random byte
                if (str.len() > 0) {
                    const from = rng.random().int(u8);
                    const to = rng.random().int(u8);
                    try str.replace(&[_]u8{from}, &[_]u8{to});
                }
            },
            else => unreachable,
        }
    }
}

// =============================================================================
// 3. HashMap Fuzzer
// =============================================================================

test "fuzz: HashMap operations" {
    var rng = std.Random.DefaultPrng.init(0x987654);
    const allocator = std.testing.allocator;

    var map = safe.HashMap(u32).init(allocator);
    defer map.deinit();

    var keys: [50][16]u8 = undefined;
    var key_lens: [50]usize = undefined;
    var num_keys: usize = 0;

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const action = rng.random().int(u8) % 4;
        switch (action) {
            0 => { // Insert
                if (num_keys < keys.len) {
                    const value = rng.random().int(u32);
                    // Generate random key string
                    const key_len = 1 + (rng.random().int(u8) % 15);
                    for (0..key_len) |j| {
                        keys[num_keys][j] = 'a' + (rng.random().int(u8) % 26);
                    }
                    key_lens[num_keys] = key_len;
                    const key = keys[num_keys][0..key_len];
                    const box = try safe.Box(u32).init(allocator, value);
                    try map.put(key, box);
                    num_keys += 1;
                }
            },
            1 => { // Remove random
                if (num_keys > 0) {
                    const idx = rng.random().int(usize) % num_keys;
                    const key = keys[idx][0..key_lens[idx]];
                    const removed = map.remove(key);
                    if (removed) |box| {
                        const dead = box.deinit();
                        _ = dead;
                    }
                    // Swap remove from tracking arrays
                    keys[idx] = keys[num_keys - 1];
                    key_lens[idx] = key_lens[num_keys - 1];
                    num_keys -= 1;
                }
            },
            2 => { // Get random (removes from map)
                if (num_keys > 0) {
                    const idx = rng.random().int(usize) % num_keys;
                    const key = keys[idx][0..key_lens[idx]];
                    const got = map.get(key);
                    if (got) |box| {
                        const dead = box.deinit();
                        _ = dead;
                        // Swap remove from tracking arrays since get removes
                        keys[idx] = keys[num_keys - 1];
                        key_lens[idx] = key_lens[num_keys - 1];
                        num_keys -= 1;
                    }
                }
            },
            3 => { // borrowImm random
                if (num_keys > 0) {
                    const idx = rng.random().int(usize) % num_keys;
                    const key = keys[idx][0..key_lens[idx]];
                    const maybe_borrow = map.borrowImm(key);
                    if (maybe_borrow) |borrow| {
                        _ = borrow.box.ptr.*;
                        borrow.releaseImm();
                    }
                }
            },
            else => unreachable,
        }
    }

    // Clean up any remaining entries so the defer map.deinit() doesn't panic
    var j: usize = 0;
    while (j < num_keys) : (j += 1) {
        const key = keys[j][0..key_lens[j]];
        const got = map.get(key);
        if (got) |box| {
            const dead = box.deinit();
            _ = dead;
        }
    }
}

// =============================================================================
// 4. SimdUtils vs Scalar Fuzzer
// =============================================================================

test "fuzz: SimdUtils correctness" {
    var rng = std.Random.DefaultPrng.init(0x55555555);
    var allocator = std.testing.allocator;

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const len = rng.random().int(usize) % 2048;
        const haystack = try allocator.alloc(u8, len);
        defer allocator.free(haystack);
        for (haystack) |*b| {
            b.* = rng.random().int(u8);
        }

        const needle = rng.random().int(u8);

        // Compare findByte
        const simd_result = SimdUtils.findByte(haystack, needle);
        const scalar_result = scalarFindByte(haystack, needle);
        try std.testing.expectEqual(scalar_result, simd_result);

        // Compare countByte
        const simd_count = SimdUtils.countByte(haystack, needle);
        const scalar_count = scalarCountByte(haystack, needle);
        try std.testing.expectEqual(scalar_count, simd_count);

        // Also fuzz eql with random second haystack
        const len2 = rng.random().int(usize) % 2048;
        const haystack2 = try allocator.alloc(u8, len2);
        defer allocator.free(haystack2);
        for (haystack2) |*b| {
            b.* = rng.random().int(u8);
        }

        const simd_eql = SimdUtils.eql(haystack, haystack2);
        const scalar_eql = scalarEql(haystack, haystack2);
        try std.testing.expectEqual(scalar_eql, simd_eql);

        // Also fuzz startsWith and endsWith
        if (haystack2.len <= haystack.len) {
            const simd_sw = SimdUtils.startsWith(haystack, haystack2);
            const scalar_sw = scalarStartsWith(haystack, haystack2);
            try std.testing.expectEqual(scalar_sw, simd_sw);
        }

        if (haystack2.len <= haystack.len) {
            const simd_ew = SimdUtils.endsWith(haystack, haystack2);
            const scalar_ew = scalarEndsWith(haystack, haystack2);
            try std.testing.expectEqual(scalar_ew, simd_ew);
        }
    }
}
