const std = @import("std");

// ============================================================================
// SIMD bulk-operation helpers (process 4 u64 words = 256 bits at a time)
// ============================================================================

const SimdChunk = struct {
    const Vec4 = @Vector(4, u64);
    const len = 4;
    const zero: Vec4 = @splat(0);
    const ones: Vec4 = @splat(~@as(u64, 0));
};

inline fn simdCount(words: []const u64) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i + SimdChunk.len <= words.len) {
        const chunk: SimdChunk.Vec4 = words[i..][0..SimdChunk.len].*;
        inline for (0..SimdChunk.len) |j| {
            total += @popCount(chunk[j]);
        }
        i += SimdChunk.len;
    }
    while (i < words.len) {
        total += @popCount(words[i]);
        i += 1;
    }
    return total;
}

inline fn simdAny(words: []const u64) bool {
    var i: usize = 0;
    while (i + SimdChunk.len <= words.len) {
        const chunk: SimdChunk.Vec4 = words[i..][0..SimdChunk.len].*;
        if (@reduce(.Or, chunk != SimdChunk.zero)) return true;
        i += SimdChunk.len;
    }
    while (i < words.len) {
        if (words[i] != 0) return true;
        i += 1;
    }
    return false;
}

inline fn simdAll(words: []const u64) bool {
    var i: usize = 0;
    while (i + SimdChunk.len <= words.len) {
        const chunk: SimdChunk.Vec4 = words[i..][0..SimdChunk.len].*;
        if (!@reduce(.And, chunk == SimdChunk.ones)) return false;
        i += SimdChunk.len;
    }
    while (i < words.len) {
        if (words[i] != ~@as(u64, 0)) return false;
        i += 1;
    }
    return true;
}

inline fn simdEq(a: []const u64, b: []const u64) bool {
    var i: usize = 0;
    while (i + SimdChunk.len <= a.len) {
        const va: SimdChunk.Vec4 = a[i..][0..SimdChunk.len].*;
        const vb: SimdChunk.Vec4 = b[i..][0..SimdChunk.len].*;
        if (!@reduce(.And, va == vb)) return false;
        i += SimdChunk.len;
    }
    while (i < a.len) {
        if (a[i] != b[i]) return false;
        i += 1;
    }
    return true;
}

inline fn simdUnion(dst: []u64, a: []const u64, b: []const u64) void {
    var i: usize = 0;
    while (i + SimdChunk.len <= dst.len) {
        const va: SimdChunk.Vec4 = a[i..][0..SimdChunk.len].*;
        const vb: SimdChunk.Vec4 = b[i..][0..SimdChunk.len].*;
        dst[i..][0..SimdChunk.len].* = va | vb;
        i += SimdChunk.len;
    }
    while (i < dst.len) {
        dst[i] = a[i] | b[i];
        i += 1;
    }
}

inline fn simdIntersection(dst: []u64, a: []const u64, b: []const u64) void {
    var i: usize = 0;
    while (i + SimdChunk.len <= dst.len) {
        const va: SimdChunk.Vec4 = a[i..][0..SimdChunk.len].*;
        const vb: SimdChunk.Vec4 = b[i..][0..SimdChunk.len].*;
        dst[i..][0..SimdChunk.len].* = va & vb;
        i += SimdChunk.len;
    }
    while (i < dst.len) {
        dst[i] = a[i] & b[i];
        i += 1;
    }
}

inline fn simdXor(dst: []u64, a: []const u64, b: []const u64) void {
    var i: usize = 0;
    while (i + SimdChunk.len <= dst.len) {
        const va: SimdChunk.Vec4 = a[i..][0..SimdChunk.len].*;
        const vb: SimdChunk.Vec4 = b[i..][0..SimdChunk.len].*;
        dst[i..][0..SimdChunk.len].* = va ^ vb;
        i += SimdChunk.len;
    }
    while (i < dst.len) {
        dst[i] = a[i] ^ b[i];
        i += 1;
    }
}

inline fn simdComplement(dst: []u64, src: []const u64) void {
    var i: usize = 0;
    while (i + SimdChunk.len <= dst.len) {
        const v: SimdChunk.Vec4 = src[i..][0..SimdChunk.len].*;
        dst[i..][0..SimdChunk.len].* = ~v;
        i += SimdChunk.len;
    }
    while (i < dst.len) {
        dst[i] = ~src[i];
        i += 1;
    }
}

inline fn lastWordMask(size: usize) u64 {
    const last_bits = size % 64;
    if (last_bits == 0) return ~@as(u64, 0);
    return (@as(u64, 1) << @as(u6, @intCast(last_bits))) - 1;
}

// ============================================================================
// FixedBitSet — comptime-known size, inline storage, zero allocation
// ============================================================================

pub fn FixedBitSet(comptime size: usize) type {
    const num_words = (size + 63) / 64;

    return struct {
        bits: [num_words]u64,

        const Self = @This();

        pub fn init() Self {
            return .{ .bits = [_]u64{0} ** num_words };
        }

        pub fn set(self: *Self, index: usize) void {
            std.debug.assert(index < size);
            const word = index / 64;
            const bit = @as(u6, @intCast(index % 64));
            self.bits[word] |= (@as(u64, 1) << bit);
        }

        pub fn unset(self: *Self, index: usize) void {
            std.debug.assert(index < size);
            const word = index / 64;
            const bit = @as(u6, @intCast(index % 64));
            self.bits[word] &= ~(@as(u64, 1) << bit);
        }

        pub fn isSet(self: *const Self, index: usize) bool {
            std.debug.assert(index < size);
            const word = index / 64;
            const bit = @as(u6, @intCast(index % 64));
            return (self.bits[word] >> bit) & 1 != 0;
        }

        pub fn toggle(self: *Self, index: usize) void {
            std.debug.assert(index < size);
            const word = index / 64;
            const bit = @as(u6, @intCast(index % 64));
            self.bits[word] ^= (@as(u64, 1) << bit);
        }

        pub fn count(self: *const Self) usize {
            if (num_words == 0) return 0;
            return simdCount(&self.bits);
        }

        pub fn any(self: *const Self) bool {
            if (num_words == 0) return false;
            return simdAny(&self.bits);
        }

        pub fn all(self: *const Self) bool {
            if (num_words == 0) return true;
            // Check all full words are all 1s.
            const full_words = if (size % 64 == 0) num_words else num_words - 1;
            if (full_words > 0 and !simdAll(self.bits[0..full_words])) return false;
            // Last word may be partial.
            if (size % 64 != 0) {
                const mask = lastWordMask(size);
                return (self.bits[num_words - 1] & mask) == mask;
            }
            return true;
        }

        pub fn none(self: *const Self) bool {
            return !self.any();
        }

        pub fn reset(self: *Self) void {
            @memset(&self.bits, 0);
        }

        pub fn eq(self: *const Self, other: *const Self) bool {
            if (num_words == 0) return true;
            return simdEq(&self.bits, &other.bits);
        }

        pub fn unionWith(self: *const Self, other: *const Self) Self {
            var result = init();
            if (num_words == 0) return result;
            simdUnion(&result.bits, &self.bits, &other.bits);
            return result;
        }

        pub fn intersection(self: *const Self, other: *const Self) Self {
            var result = init();
            if (num_words == 0) return result;
            simdIntersection(&result.bits, &self.bits, &other.bits);
            return result;
        }

        pub fn xorWith(self: *const Self, other: *const Self) Self {
            var result = init();
            if (num_words == 0) return result;
            simdXor(&result.bits, &self.bits, &other.bits);
            return result;
        }

        pub fn complement(self: *const Self) Self {
            var result = init();
            if (num_words == 0) return result;
            simdComplement(&result.bits, &self.bits);
            // Mask last partial word.
            if (size % 64 != 0) {
                const mask = lastWordMask(size);
                result.bits[num_words - 1] &= mask;
            }
            return result;
        }

        pub fn findFirstSet(self: *const Self) ?usize {
            for (0..num_words) |i| {
                if (self.bits[i] != 0) {
                    return i * 64 + @ctz(self.bits[i]);
                }
            }
            return null;
        }

        pub fn findFirstUnset(self: *const Self) ?usize {
            for (0..num_words) |i| {
                const inverted = ~self.bits[i];
                if (inverted != 0) {
                    const idx = i * 64 + @ctz(inverted);
                    if (idx < size) return idx;
                }
            }
            return null;
        }
    };
}

// ============================================================================
// BitSet — runtime-known size, heap-allocated
// ============================================================================

pub const BitSet = struct {
    bits: []u64,
    size: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
        const num_words = (size + 63) / 64;
        const bits = try allocator.alloc(u64, num_words);
        @memset(bits, 0);
        return .{
            .bits = bits,
            .size = size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.bits);
    }

    pub fn clone(self: *const Self) !Self {
        const new_bits = try self.allocator.alloc(u64, self.bits.len);
        @memcpy(new_bits, self.bits);
        return .{
            .bits = new_bits,
            .size = self.size,
            .allocator = self.allocator,
        };
    }

    pub fn set(self: *Self, index: usize) void {
        std.debug.assert(index < self.size);
        const word = index / 64;
        const bit = @as(u6, @intCast(index % 64));
        self.bits[word] |= (@as(u64, 1) << bit);
    }

    pub fn unset(self: *Self, index: usize) void {
        std.debug.assert(index < self.size);
        const word = index / 64;
        const bit = @as(u6, @intCast(index % 64));
        self.bits[word] &= ~(@as(u64, 1) << bit);
    }

    pub fn isSet(self: *const Self, index: usize) bool {
        std.debug.assert(index < self.size);
        const word = index / 64;
        const bit = @as(u6, @intCast(index % 64));
        return (self.bits[word] >> bit) & 1 != 0;
    }

    pub fn toggle(self: *Self, index: usize) void {
        std.debug.assert(index < self.size);
        const word = index / 64;
        const bit = @as(u6, @intCast(index % 64));
        self.bits[word] ^= (@as(u64, 1) << bit);
    }

    pub fn count(self: *const Self) usize {
        if (self.bits.len == 0) return 0;
        return simdCount(self.bits);
    }

    pub fn any(self: *const Self) bool {
        if (self.bits.len == 0) return false;
        return simdAny(self.bits);
    }

    pub fn all(self: *const Self) bool {
        if (self.bits.len == 0) return true;
        const num_words = self.bits.len;
        const full_words = if (self.size % 64 == 0) num_words else num_words - 1;
        if (full_words > 0 and !simdAll(self.bits[0..full_words])) return false;
        if (self.size % 64 != 0) {
            const mask = lastWordMask(self.size);
            return (self.bits[num_words - 1] & mask) == mask;
        }
        return true;
    }

    pub fn none(self: *const Self) bool {
        return !self.any();
    }

    pub fn reset(self: *Self) void {
        @memset(self.bits, 0);
    }

    pub fn eq(self: *const Self, other: *const Self) bool {
        if (self.size != other.size) return false;
        if (self.bits.len == 0) return true;
        return simdEq(self.bits, other.bits);
    }

    pub fn unionWith(self: *const Self, other: *const Self) !Self {
        std.debug.assert(self.size == other.size);
        const result = try init(self.allocator, self.size);
        if (self.bits.len == 0) return result;
        simdUnion(result.bits, self.bits, other.bits);
        return result;
    }

    pub fn intersection(self: *const Self, other: *const Self) !Self {
        std.debug.assert(self.size == other.size);
        const result = try init(self.allocator, self.size);
        if (self.bits.len == 0) return result;
        simdIntersection(result.bits, self.bits, other.bits);
        return result;
    }

    pub fn xorWith(self: *const Self, other: *const Self) !Self {
        std.debug.assert(self.size == other.size);
        const result = try init(self.allocator, self.size);
        if (self.bits.len == 0) return result;
        simdXor(result.bits, self.bits, other.bits);
        return result;
    }

    pub fn complement(self: *const Self) !Self {
        const result = try init(self.allocator, self.size);
        if (self.bits.len == 0) return result;
        simdComplement(result.bits, self.bits);
        if (self.size % 64 != 0) {
            const mask = lastWordMask(self.size);
            result.bits[result.bits.len - 1] &= mask;
        }
        return result;
    }

    pub fn findFirstSet(self: *const Self) ?usize {
        for (0..self.bits.len) |i| {
            if (self.bits[i] != 0) {
                return i * 64 + @ctz(self.bits[i]);
            }
        }
        return null;
    }

    pub fn findFirstUnset(self: *const Self) ?usize {
        for (0..self.bits.len) |i| {
            const inverted = ~self.bits[i];
            if (inverted != 0) {
                const idx = i * 64 + @ctz(inverted);
                if (idx < self.size) return idx;
            }
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FixedBitSet set/isSet/unset" {
    var bs = FixedBitSet(128).init();
    try std.testing.expect(!bs.isSet(0));
    try std.testing.expect(!bs.isSet(63));
    try std.testing.expect(!bs.isSet(64));
    try std.testing.expect(!bs.isSet(127));

    bs.set(0);
    bs.set(63);
    bs.set(64);
    bs.set(127);

    try std.testing.expect(bs.isSet(0));
    try std.testing.expect(bs.isSet(63));
    try std.testing.expect(bs.isSet(64));
    try std.testing.expect(bs.isSet(127));
    try std.testing.expect(!bs.isSet(1));
    try std.testing.expect(!bs.isSet(62));

    bs.unset(63);
    try std.testing.expect(!bs.isSet(63));
    try std.testing.expect(bs.isSet(0));

    bs.toggle(0);
    try std.testing.expect(!bs.isSet(0));
    bs.toggle(0);
    try std.testing.expect(bs.isSet(0));
}

test "FixedBitSet count/any/all/none" {
    var bs = FixedBitSet(128).init();
    try std.testing.expectEqual(bs.count(), 0);
    try std.testing.expect(!bs.any());
    try std.testing.expect(bs.none());
    try std.testing.expect(!bs.all());

    bs.set(0);
    try std.testing.expectEqual(bs.count(), 1);
    try std.testing.expect(bs.any());
    try std.testing.expect(!bs.none());
    try std.testing.expect(!bs.all());

    bs.set(0);
    try std.testing.expectEqual(bs.count(), 1);
    try std.testing.expect(bs.any());
    try std.testing.expect(!bs.none());
    try std.testing.expect(!bs.all());

    bs.set(1);
    bs.set(2);
    try std.testing.expectEqual(bs.count(), 3);

    // Set every bit.
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        bs.set(i);
    }
    try std.testing.expectEqual(bs.count(), 128);
    try std.testing.expect(bs.all());
    try std.testing.expect(!bs.none());
}

test "FixedBitSet union/intersection/xor/complement" {
    var a = FixedBitSet(128).init();
    var b = FixedBitSet(128).init();

    a.set(0);
    a.set(1);
    a.set(2);

    b.set(2);
    b.set(3);
    b.set(4);

    const u = a.unionWith(&b);
    try std.testing.expect(u.isSet(0));
    try std.testing.expect(u.isSet(1));
    try std.testing.expect(u.isSet(2));
    try std.testing.expect(u.isSet(3));
    try std.testing.expect(u.isSet(4));
    try std.testing.expect(!u.isSet(5));

    const inter = a.intersection(&b);
    try std.testing.expect(!inter.isSet(0));
    try std.testing.expect(!inter.isSet(1));
    try std.testing.expect(inter.isSet(2));
    try std.testing.expect(!inter.isSet(3));

    const x = a.xorWith(&b);
    try std.testing.expect(x.isSet(0));
    try std.testing.expect(x.isSet(1));
    try std.testing.expect(!x.isSet(2));
    try std.testing.expect(x.isSet(3));
    try std.testing.expect(x.isSet(4));

    const c = a.complement();
    try std.testing.expect(!c.isSet(0));
    try std.testing.expect(!c.isSet(1));
    try std.testing.expect(!c.isSet(2));
    try std.testing.expect(c.isSet(3));
    try std.testing.expect(c.isSet(127));
}

test "FixedBitSet findFirstSet/findFirstUnset" {
    var bs = FixedBitSet(128).init();
    try std.testing.expect(bs.findFirstSet() == null);
    try std.testing.expectEqual(bs.findFirstUnset().?, 0);

    bs.set(5);
    bs.set(70);
    try std.testing.expectEqual(bs.findFirstSet().?, 5);
    try std.testing.expectEqual(bs.findFirstUnset().?, 0);

    bs.set(0);
    try std.testing.expectEqual(bs.findFirstSet().?, 0);
    try std.testing.expectEqual(bs.findFirstUnset().?, 1);

    // Fill everything.
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        bs.set(i);
    }
    try std.testing.expect(bs.findFirstUnset() == null);
}

test "BitSet dynamic init/deinit" {
    var bs = try BitSet.init(std.testing.allocator, 128);
    defer bs.deinit();

    try std.testing.expectEqual(bs.size, 128);
    try std.testing.expect(!bs.isSet(0));
    try std.testing.expect(!bs.isSet(127));

    bs.set(0);
    bs.set(63);
    bs.set(64);
    bs.set(127);

    try std.testing.expect(bs.isSet(0));
    try std.testing.expect(bs.isSet(63));
    try std.testing.expect(bs.isSet(64));
    try std.testing.expect(bs.isSet(127));

    bs.unset(63);
    try std.testing.expect(!bs.isSet(63));

    bs.toggle(0);
    try std.testing.expect(!bs.isSet(0));

    bs.reset();
    try std.testing.expect(!bs.isSet(64));
    try std.testing.expect(!bs.isSet(127));
    try std.testing.expect(!bs.any());
}

test "BitSet eq and clone" {
    var a = try BitSet.init(std.testing.allocator, 64);
    defer a.deinit();
    var b = try BitSet.init(std.testing.allocator, 64);
    defer b.deinit();

    a.set(0);
    a.set(1);
    b.set(0);
    b.set(1);
    try std.testing.expect(a.eq(&b));

    b.set(2);
    try std.testing.expect(!a.eq(&b));

    var c = try a.clone();
    defer c.deinit();
    try std.testing.expect(a.eq(&c));
    c.set(5);
    try std.testing.expect(!a.eq(&c));
}

test "FixedBitSet 1024 bits bulk operations" {
    var a = FixedBitSet(1024).init();
    var b = FixedBitSet(1024).init();

    // Set every even bit in a, every odd bit in b.
    var i: usize = 0;
    while (i < 1024) : (i += 2) {
        a.set(i);
    }
    i = 1;
    while (i < 1024) : (i += 2) {
        b.set(i);
    }

    try std.testing.expectEqual(a.count(), 512);
    try std.testing.expectEqual(b.count(), 512);

    const u = a.unionWith(&b);
    try std.testing.expect(u.all());
    try std.testing.expectEqual(u.count(), 1024);

    const inter = a.intersection(&b);
    try std.testing.expect(!inter.any());
    try std.testing.expectEqual(inter.count(), 0);

    const x = a.xorWith(&b);
    try std.testing.expect(x.all());
    try std.testing.expectEqual(x.count(), 1024);

    const ca = a.complement();
    try std.testing.expect(ca.eq(&b));

    const cb = b.complement();
    try std.testing.expect(cb.eq(&a));
}

test "BitSet edge cases (size 1, size 65, size 128)" {
    // size 1
    {
        var bs = try BitSet.init(std.testing.allocator, 1);
        defer bs.deinit();
        try std.testing.expect(!bs.isSet(0));
        try std.testing.expect(!bs.any());
        try std.testing.expect(bs.none());
        try std.testing.expect(!bs.all());
        try std.testing.expectEqual(bs.count(), 0);

        bs.set(0);
        try std.testing.expect(bs.isSet(0));
        try std.testing.expect(bs.any());
        try std.testing.expect(!bs.none());
        try std.testing.expect(bs.all());
        try std.testing.expectEqual(bs.count(), 1);
        try std.testing.expectEqual(bs.findFirstSet().?, 0);
        try std.testing.expect(bs.findFirstUnset() == null);
    }

    // size 65 (spans 2 words, last word partial)
    {
        var bs = try BitSet.init(std.testing.allocator, 65);
        defer bs.deinit();
        try std.testing.expect(!bs.any());

        bs.set(0);
        bs.set(64);
        try std.testing.expect(bs.isSet(0));
        try std.testing.expect(bs.isSet(64));
        try std.testing.expectEqual(bs.count(), 2);

        // all() should be false.
        try std.testing.expect(!bs.all());

        // Set every valid bit.
        var i: usize = 0;
        while (i < 65) : (i += 1) {
            bs.set(i);
        }
        try std.testing.expect(bs.all());
        try std.testing.expectEqual(bs.count(), 65);

        // Complement should zero everything out.
        var comp = try bs.complement();
        defer comp.deinit();
        try std.testing.expect(!comp.any());
    }

    // size 128 (exactly 2 full words)
    {
        var bs = try BitSet.init(std.testing.allocator, 128);
        defer bs.deinit();
        try std.testing.expect(!bs.any());

        bs.set(0);
        bs.set(63);
        bs.set(64);
        bs.set(127);
        try std.testing.expectEqual(bs.count(), 4);

        var i: usize = 0;
        while (i < 128) : (i += 1) {
            bs.set(i);
        }
        try std.testing.expect(bs.all());
        try std.testing.expectEqual(bs.count(), 128);

        var comp = try bs.complement();
        defer comp.deinit();
        try std.testing.expect(!comp.any());
    }

    // size 128 (exactly 2 full words)
    {
        var bs = try BitSet.init(std.testing.allocator, 128);
        defer bs.deinit();
        try std.testing.expect(!bs.any());

        bs.set(0);
        bs.set(63);
        bs.set(64);
        bs.set(127);
        try std.testing.expectEqual(bs.count(), 4);

        var i: usize = 0;
        while (i < 128) : (i += 1) {
            bs.set(i);
        }
        try std.testing.expect(bs.all());
        try std.testing.expectEqual(bs.count(), 128);

        var comp = try bs.complement();
        defer comp.deinit();
        try std.testing.expect(!comp.any());
    }
}
