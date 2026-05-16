const std = @import("std");
const safe = @import("safe");
const SimdUtils = safe.SimdUtils;

// =============================================================================
// Scalar reference implementations
// =============================================================================

fn scalarFindByte(haystack: []const u8, needle: u8) ?usize {
    for (haystack, 0..) |b, i| {
        if (b == needle) return i;
    }
    return null;
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

fn scalarCopy(dst: []u8, src: []const u8) void {
    for (0..src.len) |i| {
        dst[i] = src[i];
    }
}

fn scalarFill(dst: []u8, value: u8) void {
    for (0..dst.len) |i| {
        dst[i] = value;
    }
}

fn scalarFindAnyByte(haystack: []const u8, needles: []const u8) ?usize {
    for (haystack, 0..) |b, i| {
        for (needles) |n| {
            if (b == n) return i;
        }
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

// =============================================================================
// Helper to ensure SIMD and scalar agree
// =============================================================================

fn expectSimdEqScalarFindByte(haystack: []const u8, needle: u8) !void {
    const simd_result = SimdUtils.findByte(haystack, needle);
    const scalar_result = scalarFindByte(haystack, needle);
    try std.testing.expectEqual(scalar_result, simd_result);
}

fn expectSimdEqScalarEql(a: []const u8, b: []const u8) !void {
    const simd_result = SimdUtils.eql(a, b);
    const scalar_result = scalarEql(a, b);
    try std.testing.expectEqual(scalar_result, simd_result);
}

fn expectSimdEqScalarStartsWith(haystack: []const u8, prefix: []const u8) !void {
    const simd_result = SimdUtils.startsWith(haystack, prefix);
    const scalar_result = scalarStartsWith(haystack, prefix);
    try std.testing.expectEqual(scalar_result, simd_result);
}

fn expectSimdEqScalarEndsWith(haystack: []const u8, suffix: []const u8) !void {
    const simd_result = SimdUtils.endsWith(haystack, suffix);
    const scalar_result = scalarEndsWith(haystack, suffix);
    try std.testing.expectEqual(scalar_result, simd_result);
}

fn expectSimdEqScalarFindAnyByte(haystack: []const u8, needles: []const u8) !void {
    const simd_result = SimdUtils.findAnyByte(haystack, needles);
    const scalar_result = scalarFindAnyByte(haystack, needles);
    try std.testing.expectEqual(scalar_result, simd_result);
}

fn expectSimdEqScalarCountByte(haystack: []const u8, needle: u8) !void {
    const simd_result = SimdUtils.countByte(haystack, needle);
    const scalar_result = scalarCountByte(haystack, needle);
    try std.testing.expectEqual(scalar_result, simd_result);
}

// =============================================================================
// findByte tests
// =============================================================================

test "findByte: empty haystack" {
    try expectSimdEqScalarFindByte(&[_]u8{}, 'a');
}

test "findByte: single byte match" {
    try expectSimdEqScalarFindByte(&[_]u8{'x'}, 'x');
}

test "findByte: single byte no-match" {
    try expectSimdEqScalarFindByte(&[_]u8{'x'}, 'y');
}

test "findByte: 15 bytes boundary" {
    const haystack = "abcdefghijklmno";
    try expectSimdEqScalarFindByte(haystack, 'a');
    try expectSimdEqScalarFindByte(haystack, 'o');
    try expectSimdEqScalarFindByte(haystack, 'z');
}

test "findByte: 16 bytes exact" {
    const haystack = "abcdefghijklmnop";
    try expectSimdEqScalarFindByte(haystack, 'a');
    try expectSimdEqScalarFindByte(haystack, 'p');
    try expectSimdEqScalarFindByte(haystack, 'z');
}

test "findByte: 17 bytes" {
    const haystack = "abcdefghijklmnopq";
    try expectSimdEqScalarFindByte(haystack, 'a');
    try expectSimdEqScalarFindByte(haystack, 'q');
    try expectSimdEqScalarFindByte(haystack, 'z');
}

test "findByte: 1000 bytes" {
    var haystack: [1000]u8 = undefined;
    @memset(&haystack, 'x');
    try expectSimdEqScalarFindByte(&haystack, 'x');
    try expectSimdEqScalarFindByte(&haystack, 'y');
}

test "findByte: needle at all boundaries" {
    var haystack: [64]u8 = undefined;
    @memset(&haystack, 'x');
    const positions = [_]usize{ 0, 15, 16, 31, 32, 63 };
    for (positions) |pos| {
        haystack[pos] = 'y';
        try expectSimdEqScalarFindByte(&haystack, 'y');
        haystack[pos] = 'x';
    }
}

// =============================================================================
// eql tests
// =============================================================================

test "eql: empty" {
    try expectSimdEqScalarEql("", "");
}

test "eql: different lengths" {
    try expectSimdEqScalarEql("a", "ab");
    try expectSimdEqScalarEql("ab", "a");
}

test "eql: exact match" {
    try expectSimdEqScalarEql("hello", "hello");
}

test "eql: mismatch" {
    try expectSimdEqScalarEql("hello", "world");
}

test "eql: 16 bytes match" {
    try expectSimdEqScalarEql("abcdefghijklmnop", "abcdefghijklmnop");
}

test "eql: 16 bytes mismatch" {
    try expectSimdEqScalarEql("abcdefghijklmnop", "abcdefghijklmnoq");
}

test "eql: 17 bytes match" {
    try expectSimdEqScalarEql("abcdefghijklmnopq", "abcdefghijklmnopq");
}

test "eql: 17 bytes mismatch" {
    try expectSimdEqScalarEql("abcdefghijklmnopq", "abcdefghijklmnopr");
}

test "eql: 1000 bytes match" {
    var a: [1000]u8 = undefined;
    var b: [1000]u8 = undefined;
    for (0..1000) |i| {
        a[i] = @intCast(i % 256);
        b[i] = @intCast(i % 256);
    }
    try expectSimdEqScalarEql(&a, &b);
}

test "eql: 1000 bytes mismatch" {
    var a: [1000]u8 = undefined;
    var b: [1000]u8 = undefined;
    for (0..1000) |i| {
        a[i] = @intCast(i % 256);
        b[i] = @intCast(i % 256);
    }
    b[999] = 255;
    try expectSimdEqScalarEql(&a, &b);
}

// =============================================================================
// startsWith tests
// =============================================================================

test "startsWith: empty prefix" {
    try expectSimdEqScalarStartsWith("hello", "");
    try expectSimdEqScalarStartsWith("", "");
}

test "startsWith: match" {
    try expectSimdEqScalarStartsWith("hello world", "hello");
}

test "startsWith: no match" {
    try expectSimdEqScalarStartsWith("hello world", "world");
}

test "startsWith: longer than haystack" {
    try expectSimdEqScalarStartsWith("hi", "hello");
}

test "startsWith: 16 byte prefix match" {
    try expectSimdEqScalarStartsWith("abcdefghijklmnopqrs", "abcdefghijklmnop");
}

test "startsWith: 16 byte prefix mismatch" {
    try expectSimdEqScalarStartsWith("abcdefghijklmnopqrs", "abcdefghijklmnoq");
}

// =============================================================================
// endsWith tests
// =============================================================================

test "endsWith: empty suffix" {
    try expectSimdEqScalarEndsWith("hello", "");
    try expectSimdEqScalarEndsWith("", "");
}

test "endsWith: match" {
    try expectSimdEqScalarEndsWith("hello world", "world");
}

test "endsWith: no match" {
    try expectSimdEqScalarEndsWith("hello world", "hello");
}

test "endsWith: longer than haystack" {
    try expectSimdEqScalarEndsWith("hi", "hello");
}

test "endsWith: 16 byte suffix match" {
    try expectSimdEqScalarEndsWith("rstuvwxyzabcdefghijklmnop", "abcdefghijklmnop");
}

test "endsWith: 16 byte suffix mismatch" {
    try expectSimdEqScalarEndsWith("rstuvwxyzabcdefghijklmnop", "abcdefghijklmnoq");
}

// =============================================================================
// copy tests
// =============================================================================

test "copy: basic 5 bytes" {
    var simd_dst: [5]u8 = undefined;
    var scalar_dst: [5]u8 = undefined;
    const src = "hello";
    SimdUtils.copy(&simd_dst, src);
    scalarCopy(&scalar_dst, src);
    try std.testing.expectEqualSlices(u8, &scalar_dst, &simd_dst);
}

test "copy: 1000 bytes with unique values" {
    var src: [1000]u8 = undefined;
    for (0..1000) |i| {
        src[i] = @intCast((i * 7 + 13) % 256);
    }
    var simd_dst: [1000]u8 = undefined;
    var scalar_dst: [1000]u8 = undefined;
    SimdUtils.copy(&simd_dst, &src);
    scalarCopy(&scalar_dst, &src);
    try std.testing.expectEqualSlices(u8, &scalar_dst, &simd_dst);
}

test "copy: 17 bytes" {
    var simd_dst: [17]u8 = undefined;
    var scalar_dst: [17]u8 = undefined;
    const src = "abcdefghijklmnopq";
    SimdUtils.copy(&simd_dst, src);
    scalarCopy(&scalar_dst, src);
    try std.testing.expectEqualSlices(u8, &scalar_dst, &simd_dst);
}

// =============================================================================
// fill tests
// =============================================================================

test "fill: basic 64 bytes" {
    var simd_dst: [64]u8 = undefined;
    var scalar_dst: [64]u8 = undefined;
    SimdUtils.fill(&simd_dst, 0xAB);
    scalarFill(&scalar_dst, 0xAB);
    try std.testing.expectEqualSlices(u8, &scalar_dst, &simd_dst);
}

test "fill: 1000 bytes" {
    var simd_dst: [1000]u8 = undefined;
    var scalar_dst: [1000]u8 = undefined;
    SimdUtils.fill(&simd_dst, 0x42);
    scalarFill(&scalar_dst, 0x42);
    try std.testing.expectEqualSlices(u8, &scalar_dst, &simd_dst);
}

test "fill: 17 bytes" {
    var simd_dst: [17]u8 = undefined;
    var scalar_dst: [17]u8 = undefined;
    SimdUtils.fill(&simd_dst, 0xFF);
    scalarFill(&scalar_dst, 0xFF);
    try std.testing.expectEqualSlices(u8, &scalar_dst, &simd_dst);
}

// =============================================================================
// findAnyByte tests
// =============================================================================

test "findAnyByte: single needle" {
    try expectSimdEqScalarFindAnyByte("hello world", "e");
}

test "findAnyByte: multi-needle" {
    try expectSimdEqScalarFindAnyByte("hello world", "eo");
}

test "findAnyByte: whitespace set" {
    const whitespace = " \t\n\r";
    try expectSimdEqScalarFindAnyByte("hello world", whitespace);
    try expectSimdEqScalarFindAnyByte("hello\tworld", whitespace);
    try expectSimdEqScalarFindAnyByte("hello\nworld", whitespace);
    try expectSimdEqScalarFindAnyByte("hello\rworld", whitespace);
    try expectSimdEqScalarFindAnyByte("helloworld", whitespace);
}

test "findAnyByte: empty haystack" {
    try expectSimdEqScalarFindAnyByte("", "x");
}

test "findAnyByte: no match" {
    try expectSimdEqScalarFindAnyByte("abcdef", "xyz");
}

test "findAnyByte: 1000 bytes" {
    var haystack: [1000]u8 = undefined;
    @memset(&haystack, 'x');
    try expectSimdEqScalarFindAnyByte(&haystack, "y");
    try expectSimdEqScalarFindAnyByte(&haystack, "xy");
}

// =============================================================================
// countByte tests
// =============================================================================

test "countByte: empty" {
    try expectSimdEqScalarCountByte("", 'a');
}

test "countByte: single" {
    try expectSimdEqScalarCountByte("a", 'a');
    try expectSimdEqScalarCountByte("a", 'b');
}

test "countByte: 1000 bytes with 3 matches" {
    var haystack: [1000]u8 = undefined;
    @memset(&haystack, 'x');
    haystack[100] = 'y';
    haystack[500] = 'y';
    haystack[900] = 'y';
    try expectSimdEqScalarCountByte(&haystack, 'y');
    try expectSimdEqScalarCountByte(&haystack, 'x');
    try expectSimdEqScalarCountByte(&haystack, 'z');
}

test "countByte: 64 bytes all same" {
    var haystack: [64]u8 = undefined;
    @memset(&haystack, 'x');
    try expectSimdEqScalarCountByte(&haystack, 'x');
    try expectSimdEqScalarCountByte(&haystack, 'y');
}

test "countByte: 17 bytes" {
    const haystack = "abcdefghijklmnopq";
    try expectSimdEqScalarCountByte(haystack, 'a');
    try expectSimdEqScalarCountByte(haystack, 'q');
    try expectSimdEqScalarCountByte(haystack, 'z');
}
