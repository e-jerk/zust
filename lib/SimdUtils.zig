const std = @import("std");

pub fn findByte(haystack: []const u8, needle: u8) ?usize {
    if (haystack.len < 16) {
        for (0..haystack.len) |i| {
            if (haystack[i] == needle) return i;
        }
        return null;
    }

    var i: usize = 0;

    const Vec32 = @Vector(32, u8);
    const needle_vec32: Vec32 = @splat(needle);
    while (i + 32 <= haystack.len) {
        const chunk: Vec32 = haystack[i..][0..32].*;
        const cmp = chunk == needle_vec32;
        if (@reduce(.Or, cmp)) {
            const mask = @as(u32, @bitCast(cmp));
            const trailing = @ctz(mask);
            return i + trailing;
        }
        i += 32;
    }

    const Vec16 = @Vector(16, u8);
    const needle_vec16: Vec16 = @splat(needle);
    while (i + 16 <= haystack.len) {
        const chunk: Vec16 = haystack[i..][0..16].*;
        const cmp = chunk == needle_vec16;
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

    var i: usize = 0;
    const Vec32 = @Vector(32, u8);
    while (i + 32 <= a.len) {
        const va: Vec32 = a[i..][0..32].*;
        const vb: Vec32 = b[i..][0..32].*;
        if (!@reduce(.And, va == vb)) return false;
        i += 32;
    }

    const Vec16 = @Vector(16, u8);
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

    var i: usize = 0;
    const Vec32 = @Vector(32, u8);
    while (i + 32 <= prefix.len) {
        const vh: Vec32 = haystack[i..][0..32].*;
        const vp: Vec32 = prefix[i..][0..32].*;
        if (!@reduce(.And, vh == vp)) return false;
        i += 32;
    }

    const Vec16 = @Vector(16, u8);
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

    const Vec32 = @Vector(32, u8);
    const start = haystack.len - suffix.len;
    var i: usize = 0;
    while (i + 32 <= suffix.len) {
        const vh: Vec32 = haystack[start + i ..][0..32].*;
        const vs: Vec32 = suffix[i..][0..32].*;
        if (!@reduce(.And, vh == vs)) return false;
        i += 32;
    }

    const Vec16 = @Vector(16, u8);
    while (i + 16 <= suffix.len) {
        const vh: Vec16 = haystack[start + i ..][0..16].*;
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

    const Vec32 = @Vector(32, u8);
    var i: usize = 0;
    while (i + 32 <= src.len) {
        const chunk: Vec32 = src[i..][0..32].*;
        dst[i..][0..32].* = chunk;
        i += 32;
    }

    const Vec16 = @Vector(16, u8);
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

    const Vec32 = @Vector(32, u8);
    const val_vec32: Vec32 = @splat(value);
    var i: usize = 0;
    while (i + 32 <= dst.len) {
        dst[i..][0..32].* = val_vec32;
        i += 32;
    }

    const Vec16 = @Vector(16, u8);
    const val_vec16: Vec16 = @splat(value);
    while (i + 16 <= dst.len) {
        dst[i..][0..16].* = val_vec16;
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

    const Vec32 = @Vector(32, u8);
    var needle_vecs32: [4]Vec32 = undefined;
    for (needles, 0..) |n, idx| {
        needle_vecs32[idx] = @splat(n);
    }

    var i: usize = 0;
    while (i + 32 <= haystack.len) {
        const chunk: Vec32 = haystack[i..][0..32].*;
        var found: bool = false;
        inline for (0..4) |idx| {
            if (idx < needles.len) {
                const cmp = chunk == needle_vecs32[idx];
                if (@reduce(.Or, cmp)) found = true;
            }
        }
        if (found) {
            for (haystack[i .. i + 32], i..) |b, j| {
                for (needles) |n| {
                    if (b == n) return j;
                }
            }
        }
        i += 32;
    }

    const Vec16 = @Vector(16, u8);
    var needle_vecs16: [4]Vec16 = undefined;
    for (needles, 0..) |n, idx| {
        needle_vecs16[idx] = @splat(n);
    }

    while (i + 16 <= haystack.len) {
        const chunk: Vec16 = haystack[i..][0..16].*;
        var found: bool = false;
        inline for (0..4) |idx| {
            if (idx < needles.len) {
                const cmp = chunk == needle_vecs16[idx];
                if (@reduce(.Or, cmp)) found = true;
            }
        }
        if (found) {
            for (haystack[i .. i + 16], i..) |b, j| {
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

    var total: usize = 0;
    var i: usize = 0;

    const Vec32 = @Vector(32, u8);
    const needle_vec32: Vec32 = @splat(needle);
    while (i + 32 <= haystack.len) {
        const chunk: Vec32 = haystack[i..][0..32].*;
        const cmp = chunk == needle_vec32;
        const mask = @as(u32, @bitCast(cmp));
        total += @popCount(mask);
        i += 32;
    }

    const Vec16 = @Vector(16, u8);
    const needle_vec16: Vec16 = @splat(needle);
    while (i + 16 <= haystack.len) {
        const chunk: Vec16 = haystack[i..][0..16].*;
        const cmp = chunk == needle_vec16;
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

/// Find the last occurrence of a byte in a haystack, scanning backwards with SIMD.
pub fn findByteReverse(haystack: []const u8, needle: u8) ?usize {
    if (haystack.len == 0) return null;
    if (haystack.len < 16) {
        var i: usize = haystack.len;
        while (i > 0) {
            i -= 1;
            if (haystack[i] == needle) return i;
        }
        return null;
    }

    var i: usize = haystack.len;

    const Vec32 = @Vector(32, u8);
    const needle_vec32: Vec32 = @splat(needle);
    while (i >= 32) {
        i -= 32;
        const chunk: Vec32 = haystack[i..][0..32].*;
        const cmp = chunk == needle_vec32;
        if (@reduce(.Or, cmp)) {
            var j: usize = 32;
            while (j > 0) {
                j -= 1;
                if (haystack[i + j] == needle) return i + j;
            }
        }
    }

    const Vec16 = @Vector(16, u8);
    const needle_vec16: Vec16 = @splat(needle);
    while (i >= 16) {
        i -= 16;
        const chunk: Vec16 = haystack[i..][0..16].*;
        const cmp = chunk == needle_vec16;
        if (@reduce(.Or, cmp)) {
            var j: usize = 16;
            while (j > 0) {
                j -= 1;
                if (haystack[i + j] == needle) return i + j;
            }
        }
    }

    while (i > 0) {
        i -= 1;
        if (haystack[i] == needle) return i;
    }

    return null;
}

/// Find the first occurrence of any byte from a set (like `strcspn`).
/// Supports up to 4 bytes in the set for SIMD fast path.
pub fn findByteSet(haystack: []const u8, needles: []const u8) ?usize {
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

    const Vec32 = @Vector(32, u8);
    var needle_vecs32: [4]Vec32 = undefined;
    for (needles, 0..) |n, idx| {
        needle_vecs32[idx] = @splat(n);
    }

    var i: usize = 0;
    while (i + 32 <= haystack.len) {
        const chunk: Vec32 = haystack[i..][0..32].*;
        var found: bool = false;
        inline for (0..4) |idx| {
            if (idx < needles.len) {
                const cmp = chunk == needle_vecs32[idx];
                if (@reduce(.Or, cmp)) found = true;
            }
        }
        if (found) {
            for (haystack[i .. i + 32], i..) |b, j| {
                for (needles) |n| {
                    if (b == n) return j;
                }
            }
        }
        i += 32;
    }

    const Vec16 = @Vector(16, u8);
    var needle_vecs16: [4]Vec16 = undefined;
    for (needles, 0..) |n, idx| {
        needle_vecs16[idx] = @splat(n);
    }

    while (i + 16 <= haystack.len) {
        const chunk: Vec16 = haystack[i..][0..16].*;
        var found: bool = false;
        inline for (0..4) |idx| {
            if (idx < needles.len) {
                const cmp = chunk == needle_vecs16[idx];
                if (@reduce(.Or, cmp)) found = true;
            }
        }
        if (found) {
            for (haystack[i .. i + 16], i..) |b, j| {
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

/// Case-insensitive equality for ASCII strings using SIMD.
/// Only A-Z and a-z are handled; other bytes are compared literally.
pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.len < 16) {
        for (0..a.len) |i| {
            if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[i])) return false;
        }
        return true;
    }

    const lower_mask: u8 = 0x20;
    const Vec32 = @Vector(32, u8);
    const lower_vec32: Vec32 = @splat(lower_mask);
    const A_vec32: Vec32 = @splat('A');
    const Z_vec32: Vec32 = @splat('Z');

    var i: usize = 0;
    while (i + 32 <= a.len) {
        var va: Vec32 = a[i..][0..32].*;
        var vb: Vec32 = b[i..][0..32].*;

        const mask_a = (va >= A_vec32) & (va <= Z_vec32);
        const mask_b = (vb >= A_vec32) & (vb <= Z_vec32);

        va = @select(u8, mask_a, va | lower_vec32, va);
        vb = @select(u8, mask_b, vb | lower_vec32, vb);

        if (!@reduce(.And, va == vb)) return false;
        i += 32;
    }

    const Vec16 = @Vector(16, u8);
    const lower_vec16: Vec16 = @splat(lower_mask);
    const A_vec16: Vec16 = @splat('A');
    const Z_vec16: Vec16 = @splat('Z');

    while (i + 16 <= a.len) {
        var va: Vec16 = a[i..][0..16].*;
        var vb: Vec16 = b[i..][0..16].*;

        const mask_a = (va >= A_vec16) & (va <= Z_vec16);
        const mask_b = (vb >= A_vec16) & (vb <= Z_vec16);

        va = @select(u8, mask_a, va | lower_vec16, va);
        vb = @select(u8, mask_b, vb | lower_vec16, vb);

        if (!@reduce(.And, va == vb)) return false;
        i += 16;
    }

    while (i < a.len) {
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[i])) return false;
        i += 1;
    }
    return true;
}

/// Case-insensitive `startsWith` for ASCII strings.
pub fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    return eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

/// Substring search using Boyer-Moore-Horspool with SIMD-accelerated verification.
pub fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    if (needle.len == 1) return findByte(haystack, needle[0]) != null;

    // BMH skip table
    var skip_table: [256]usize = undefined;
    @memset(&skip_table, needle.len);
    for (0..needle.len - 1) |j| {
        skip_table[needle[j]] = needle.len - 1 - j;
    }

    var pos: usize = needle.len - 1;
    while (pos < haystack.len) {
        if (haystack[pos] == needle[needle.len - 1]) {
            const start = pos - (needle.len - 1);
            if (eql(haystack[start .. pos + 1], needle)) return true;
        }
        pos += skip_table[haystack[pos]];
    }
    return false;
}

/// Count non-overlapping occurrences of a substring.
pub fn countSubstring(haystack: []const u8, needle: []const u8) u64 {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return 0;
    if (needle.len == 1) return @intCast(countByte(haystack, needle[0]));

    // BMH skip table
    var skip_table: [256]usize = undefined;
    @memset(&skip_table, needle.len);
    for (0..needle.len - 1) |j| {
        skip_table[needle[j]] = needle.len - 1 - j;
    }

    var count: u64 = 0;
    var pos: usize = needle.len - 1;
    while (pos < haystack.len) {
        if (haystack[pos] == needle[needle.len - 1]) {
            const start = pos - (needle.len - 1);
            if (eql(haystack[start .. pos + 1], needle)) {
                count += 1;
                pos += needle.len;
                continue;
            }
        }
        pos += skip_table[haystack[pos]];
    }
    return count;
}

/// Remove leading bytes that are present in `chars`.
/// `chars` must have length > 0 and <= 4.
pub fn trimLeft(text: []const u8, chars: []const u8) []const u8 {
    if (text.len == 0 or chars.len == 0) return text;
    std.debug.assert(chars.len <= 4);

    if (text.len < 16) {
        var i: usize = 0;
        while (i < text.len) {
            var found = false;
            for (chars) |c| {
                if (text[i] == c) {
                    found = true;
                    break;
                }
            }
            if (!found) return text[i..];
            i += 1;
        }
        return text[text.len..];
    }

    const Vec32 = @Vector(32, u8);
    var char_vecs32: [4]Vec32 = undefined;
    for (chars, 0..) |c, idx| {
        char_vecs32[idx] = @splat(c);
    }

    var i: usize = 0;
    while (i + 32 <= text.len) {
        const chunk: Vec32 = text[i..][0..32].*;
        var combined: @Vector(32, bool) = @splat(false);
        inline for (0..4) |idx| {
            if (idx < chars.len) {
                combined = combined | (chunk == char_vecs32[idx]);
            }
        }
        if (!@reduce(.And, combined)) {
            for (text[i .. i + 32], i..) |b, j| {
                var found = false;
                for (chars) |c| {
                    if (b == c) {
                        found = true;
                        break;
                    }
                }
                if (!found) return text[j..];
            }
        }
        i += 32;
    }

    const Vec16 = @Vector(16, u8);
    var char_vecs16: [4]Vec16 = undefined;
    for (chars, 0..) |c, idx| {
        char_vecs16[idx] = @splat(c);
    }

    while (i + 16 <= text.len) {
        const chunk: Vec16 = text[i..][0..16].*;
        var combined: @Vector(16, bool) = @splat(false);
        inline for (0..4) |idx| {
            if (idx < chars.len) {
                combined = combined | (chunk == char_vecs16[idx]);
            }
        }
        if (!@reduce(.And, combined)) {
            for (text[i .. i + 16], i..) |b, j| {
                var found = false;
                for (chars) |c| {
                    if (b == c) {
                        found = true;
                        break;
                    }
                }
                if (!found) return text[j..];
            }
        }
        i += 16;
    }

    while (i < text.len) {
        var found = false;
        for (chars) |c| {
            if (text[i] == c) {
                found = true;
                break;
            }
        }
        if (!found) return text[i..];
        i += 1;
    }

    return text[text.len..];
}

/// Remove trailing bytes that are present in `chars`.
/// `chars` must have length > 0 and <= 4.
pub fn trimRight(text: []const u8, chars: []const u8) []const u8 {
    if (text.len == 0 or chars.len == 0) return text;
    std.debug.assert(chars.len <= 4);

    if (text.len < 16) {
        var i: usize = text.len;
        while (i > 0) {
            i -= 1;
            var found = false;
            for (chars) |c| {
                if (text[i] == c) {
                    found = true;
                    break;
                }
            }
            if (!found) return text[0 .. i + 1];
        }
        return text[0..0];
    }

    var i: usize = text.len;

    const Vec32 = @Vector(32, u8);
    var char_vecs32: [4]Vec32 = undefined;
    for (chars, 0..) |c, idx| {
        char_vecs32[idx] = @splat(c);
    }

    while (i >= 32) {
        i -= 32;
        const chunk: Vec32 = text[i..][0..32].*;
        var combined: @Vector(32, bool) = @splat(false);
        inline for (0..4) |idx| {
            if (idx < chars.len) {
                combined = combined | (chunk == char_vecs32[idx]);
            }
        }
        if (!@reduce(.And, combined)) {
            var j: usize = 32;
            while (j > 0) {
                j -= 1;
                var found = false;
                for (chars) |c| {
                    if (text[i + j] == c) {
                        found = true;
                        break;
                    }
                }
                if (!found) return text[0 .. i + j + 1];
            }
        }
    }

    const Vec16 = @Vector(16, u8);
    var char_vecs16: [4]Vec16 = undefined;
    for (chars, 0..) |c, idx| {
        char_vecs16[idx] = @splat(c);
    }

    while (i >= 16) {
        i -= 16;
        const chunk: Vec16 = text[i..][0..16].*;
        var combined: @Vector(16, bool) = @splat(false);
        inline for (0..4) |idx| {
            if (idx < chars.len) {
                combined = combined | (chunk == char_vecs16[idx]);
            }
        }
        if (!@reduce(.And, combined)) {
            var j: usize = 16;
            while (j > 0) {
                j -= 1;
                var found = false;
                for (chars) |c| {
                    if (text[i + j] == c) {
                        found = true;
                        break;
                    }
                }
                if (!found) return text[0 .. i + j + 1];
            }
        }
    }

    while (i > 0) {
        i -= 1;
        var found = false;
        for (chars) |c| {
            if (text[i] == c) {
                found = true;
                break;
            }
        }
        if (!found) return text[0 .. i + 1];
    }

    return text[0..0];
}

// =============================================================================
// Tests for new primitives
// =============================================================================

test "findByteReverse: empty" {
    try std.testing.expectEqual(@as(?usize, null), findByteReverse("", 'a'));
}

test "findByteReverse: single match" {
    try std.testing.expectEqual(@as(?usize, 0), findByteReverse("x", 'x'));
}

test "findByteReverse: single no-match" {
    try std.testing.expectEqual(@as(?usize, null), findByteReverse("x", 'y'));
}

test "findByteReverse: multiple matches" {
    try std.testing.expectEqual(@as(?usize, 4), findByteReverse("ababa", 'a'));
}

test "findByteReverse: 1000 bytes" {
    var haystack: [1000]u8 = undefined;
    @memset(&haystack, 'x');
    haystack[500] = 'y';
    try std.testing.expectEqual(@as(?usize, 500), findByteReverse(&haystack, 'y'));
    try std.testing.expectEqual(@as(?usize, null), findByteReverse(&haystack, 'z'));
}

test "findByteReverse: needle at boundaries" {
    var haystack: [64]u8 = undefined;
    @memset(&haystack, 'x');
    haystack[0] = 'y';
    haystack[31] = 'y';
    haystack[32] = 'y';
    haystack[63] = 'y';
    try std.testing.expectEqual(@as(?usize, 63), findByteReverse(&haystack, 'y'));
}

test "findByteSet: single needle" {
    try std.testing.expectEqual(@as(?usize, 1), findByteSet("hello", "e"));
}

test "findByteSet: multi-needle" {
    try std.testing.expectEqual(@as(?usize, 1), findByteSet("hello", "eo"));
}

test "findByteSet: no match" {
    try std.testing.expectEqual(@as(?usize, null), findByteSet("abcdef", "xyz"));
}

test "findByteSet: 1000 bytes" {
    var haystack: [1000]u8 = undefined;
    @memset(&haystack, 'x');
    haystack[500] = 'y';
    try std.testing.expectEqual(@as(?usize, 500), findByteSet(&haystack, "yz"));
}

test "eqlIgnoreCase: empty" {
    try std.testing.expect(eqlIgnoreCase("", ""));
}

test "eqlIgnoreCase: exact match" {
    try std.testing.expect(eqlIgnoreCase("hello", "hello"));
}

test "eqlIgnoreCase: case difference" {
    try std.testing.expect(eqlIgnoreCase("Hello", "hello"));
    try std.testing.expect(eqlIgnoreCase("HELLO", "hello"));
    try std.testing.expect(eqlIgnoreCase("HeLLo", "hEllO"));
}

test "eqlIgnoreCase: mismatch" {
    try std.testing.expect(!eqlIgnoreCase("hello", "world"));
}

test "eqlIgnoreCase: different lengths" {
    try std.testing.expect(!eqlIgnoreCase("a", "ab"));
}

test "eqlIgnoreCase: 32 bytes" {
    try std.testing.expect(eqlIgnoreCase("ABCDEFGHIJKLMNOPQRSTUVWXYZ123456", "abcdefghijklmnopqrstuvwxyz123456"));
}

test "startsWithIgnoreCase: match" {
    try std.testing.expect(startsWithIgnoreCase("Hello world", "hello"));
}

test "startsWithIgnoreCase: no match" {
    try std.testing.expect(!startsWithIgnoreCase("Hello world", "world"));
}

test "startsWithIgnoreCase: longer prefix" {
    try std.testing.expect(!startsWithIgnoreCase("hi", "hello"));
}

test "contains: empty needle" {
    try std.testing.expect(contains("hello", ""));
}

test "contains: single byte" {
    try std.testing.expect(contains("hello", "l"));
    try std.testing.expect(!contains("hello", "z"));
}

test "contains: substring" {
    try std.testing.expect(contains("hello world", "lo wo"));
    try std.testing.expect(!contains("hello world", "xyz"));
}

test "contains: overlapping" {
    try std.testing.expect(contains("aaaa", "aa"));
}

test "contains: 1000 bytes" {
    var haystack: [1000]u8 = undefined;
    @memset(&haystack, 'x');
    haystack[500] = 'y';
    haystack[501] = 'z';
    try std.testing.expect(contains(&haystack, "yz"));
    try std.testing.expect(!contains(&haystack, "zy"));
}

test "countSubstring: empty needle" {
    try std.testing.expectEqual(@as(u64, 0), countSubstring("hello", ""));
}

test "countSubstring: single byte" {
    try std.testing.expectEqual(@as(u64, 2), countSubstring("hello", "l"));
}

test "countSubstring: non-overlapping" {
    try std.testing.expectEqual(@as(u64, 2), countSubstring("aaaa", "aa"));
}

test "countSubstring: no match" {
    try std.testing.expectEqual(@as(u64, 0), countSubstring("hello", "xyz"));
}

test "countSubstring: 1000 bytes" {
    var haystack: [1000]u8 = undefined;
    @memset(&haystack, 'x');
    haystack[100] = 'y';
    haystack[101] = 'z';
    haystack[500] = 'y';
    haystack[501] = 'z';
    try std.testing.expectEqual(@as(u64, 2), countSubstring(&haystack, "yz"));
}

test "trimLeft: basic" {
    try std.testing.expectEqualStrings("hello", trimLeft("xxhello", "x"));
}

test "trimLeft: multi-char" {
    try std.testing.expectEqualStrings("hello", trimLeft(" \t\nhello", " \t\n"));
}

test "trimLeft: all match" {
    try std.testing.expectEqualStrings("", trimLeft("xxx", "x"));
}

test "trimLeft: none match" {
    try std.testing.expectEqualStrings("hello", trimLeft("hello", "x"));
}

test "trimRight: basic" {
    try std.testing.expectEqualStrings("hello", trimRight("helloxx", "x"));
}

test "trimRight: multi-char" {
    try std.testing.expectEqualStrings("hello", trimRight("hello \t\n", " \t\n"));
}

test "trimRight: all match" {
    try std.testing.expectEqualStrings("", trimRight("xxx", "x"));
}

test "trimRight: none match" {
    try std.testing.expectEqualStrings("hello", trimRight("hello", "x"));
}
