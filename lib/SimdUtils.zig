const std = @import("std");

pub fn findByte(haystack: []const u8, needle: u8) ?usize {
    if (haystack.len < 16) {
        for (0..haystack.len) |i| {
            if (haystack[i] == needle) return i;
        }
        return null;
    }

    const Vec16 = @Vector(16, u8);
    const needle_vec: Vec16 = @splat(needle);

    var i: usize = 0;
    while (i + 16 <= haystack.len) {
        const chunk: Vec16 = haystack[i..][0..16].*;
        const cmp = chunk == needle_vec;
        if (@reduce(.Or, cmp)) {
            const mask = @as(u16, @bitCast(cmp));
            const trailing = @ctz(mask);
            return i + trailing;
        }
        i += 16;
    }

    while (i < haystack.len) {
        if (haystack[i] == needle) return i;
        i += 1;
    }

    return null;
}

pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.len < 16) {
        for (0..a.len) |i| {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    const Vec16 = @Vector(16, u8);
    var i: usize = 0;
    while (i + 16 <= a.len) {
        const va: Vec16 = a[i..][0..16].*;
        const vb: Vec16 = b[i..][0..16].*;
        if (!@reduce(.And, va == vb)) return false;
        i += 16;
    }

    while (i < a.len) {
        if (a[i] != b[i]) return false;
        i += 1;
    }
    return true;
}

pub fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    if (prefix.len < 16) {
        for (0..prefix.len) |i| {
            if (haystack[i] != prefix[i]) return false;
        }
        return true;
    }

    const Vec16 = @Vector(16, u8);
    var i: usize = 0;
    while (i + 16 <= prefix.len) {
        const vh: Vec16 = haystack[i..][0..16].*;
        const vp: Vec16 = prefix[i..][0..16].*;
        if (!@reduce(.And, vh == vp)) return false;
        i += 16;
    }

    while (i < prefix.len) {
        if (haystack[i] != prefix[i]) return false;
        i += 1;
    }
    return true;
}

pub fn endsWith(haystack: []const u8, suffix: []const u8) bool {
    if (suffix.len > haystack.len) return false;
    if (suffix.len < 16) {
        const start = haystack.len - suffix.len;
        for (0..suffix.len) |i| {
            if (haystack[start + i] != suffix[i]) return false;
        }
        return true;
    }

    const Vec16 = @Vector(16, u8);
    const start = haystack.len - suffix.len;
    var i: usize = 0;
    while (i + 16 <= suffix.len) {
        const vh: Vec16 = haystack[start + i..][0..16].*;
        const vs: Vec16 = suffix[i..][0..16].*;
        if (!@reduce(.And, vh == vs)) return false;
        i += 16;
    }

    while (i < suffix.len) {
        if (haystack[start + i] != suffix[i]) return false;
        i += 1;
    }
    return true;
}

pub fn copy(dst: []u8, src: []const u8) void {
    std.debug.assert(dst.len >= src.len);
    if (src.len < 16) {
        for (0..src.len) |i| {
            dst[i] = src[i];
        }
        return;
    }

    const Vec16 = @Vector(16, u8);
    var i: usize = 0;
    while (i + 16 <= src.len) {
        const chunk: Vec16 = src[i..][0..16].*;
        dst[i..][0..16].* = chunk;
        i += 16;
    }

    while (i < src.len) {
        dst[i] = src[i];
        i += 1;
    }
}

pub fn fill(dst: []u8, value: u8) void {
    if (dst.len < 16) {
        for (0..dst.len) |i| {
            dst[i] = value;
        }
        return;
    }

    const Vec16 = @Vector(16, u8);
    const val_vec: Vec16 = @splat(value);
    var i: usize = 0;
    while (i + 16 <= dst.len) {
        dst[i..][0..16].* = val_vec;
        i += 16;
    }

    while (i < dst.len) {
        dst[i] = value;
        i += 1;
    }
}

pub fn findAnyByte(haystack: []const u8, needles: []const u8) ?usize {
    if (needles.len == 0) return null;
    std.debug.assert(needles.len <= 4);
    if (haystack.len < 16) {
        for (0..haystack.len) |i| {
            for (needles) |n| {
                if (haystack[i] == n) return i;
            }
        }
        return null;
    }

    const Vec16 = @Vector(16, u8);
    var needle_vecs: [4]Vec16 = undefined;
    for (needles, 0..) |n, idx| {
        needle_vecs[idx] = @splat(n);
    }

    var i: usize = 0;
    while (i + 16 <= haystack.len) {
        const chunk: Vec16 = haystack[i..][0..16].*;
        var found: bool = false;
        inline for (0..4) |idx| {
            if (idx < needles.len) {
                const cmp = chunk == needle_vecs[idx];
                if (@reduce(.Or, cmp)) found = true;
            }
        }
        if (found) {
            for (haystack[i..i + 16], i..) |b, j| {
                for (needles) |n| {
                    if (b == n) return j;
                }
            }
        }
        i += 16;
    }

    while (i < haystack.len) {
        for (needles) |n| {
            if (haystack[i] == n) return i;
        }
        i += 1;
    }

    return null;
}

pub fn countByte(haystack: []const u8, needle: u8) usize {
    if (haystack.len < 16) {
        var count: usize = 0;
        for (haystack) |b| {
            if (b == needle) count += 1;
        }
        return count;
    }

    const Vec16 = @Vector(16, u8);
    const needle_vec: Vec16 = @splat(needle);
    var total: usize = 0;
    var i: usize = 0;

    while (i + 16 <= haystack.len) {
        const chunk: Vec16 = haystack[i..][0..16].*;
        const cmp = chunk == needle_vec;
        const mask = @as(u16, @bitCast(cmp));
        total += @popCount(mask);
        i += 16;
    }

    while (i < haystack.len) {
        if (haystack[i] == needle) total += 1;
        i += 1;
    }

    return total;
}
