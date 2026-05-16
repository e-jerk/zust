const std = @import("std");

pub fn BloomFilter() type {
    return struct {
        bits: []u8,
        num_bits: usize,
        num_hashes: u32,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, capacity: usize, fp_rate: f64) !Self {
            const num_bits_f = -@as(f64, @floatFromInt(capacity)) * @log(fp_rate) / (@log(@as(f64, 2.0)) * @log(@as(f64, 2.0)));
            const num_bits = @max(64, @as(usize, @intFromFloat(@ceil(num_bits_f))));
            const num_hashes_f = @as(f64, @floatFromInt(num_bits)) / @as(f64, @floatFromInt(capacity)) * @log(@as(f64, 2.0));
            const num_hashes: u32 = @max(1, @as(u32, @intFromFloat(@ceil(num_hashes_f))));

            const bits = try allocator.alloc(u8, num_bits);
            @memset(bits, 0);

            return .{
                .bits = bits,
                .num_bits = num_bits,
                .num_hashes = num_hashes,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.bits);
        }

        pub fn add(self: *Self, item: []const u8) void {
            var hash1 = std.hash.Fnv1a_64.hash(item);
            const hash2 = std.hash.Crc32.hash(item);

            var i: u32 = 0;
            while (i < self.num_hashes) : (i += 1) {
                const idx = @mod(hash1, self.num_bits);
                self.bits[idx] = 1;
                hash1 = hash1 +% hash2;
            }
        }

        pub fn contains(self: *Self, item: []const u8) bool {
            var hash1 = std.hash.Fnv1a_64.hash(item);
            const hash2 = std.hash.Crc32.hash(item);

            var i: u32 = 0;
            while (i < self.num_hashes) : (i += 1) {
                const idx = @mod(hash1, self.num_bits);
                if (self.bits[idx] == 0) return false;
                hash1 = hash1 +% hash2;
            }
            return true;
        }

        pub fn reset(self: *Self) void {
            @memset(self.bits, 0);
        }

        pub fn estimatedCount(self: *Self) usize {
            const set_bits = self.countSetBits();
            if (set_bits == 0) return 0;
            if (set_bits == self.num_bits) return 0;

            const m_f = @as(f64, @floatFromInt(self.num_bits));
            const x_f = @as(f64, @floatFromInt(set_bits));
            const k_f = @as(f64, @floatFromInt(self.num_hashes));
            const count = -m_f * @log(1.0 - x_f / m_f) / (k_f * @log(2));
            return @as(usize, @intFromFloat(@ceil(count)));
        }

        fn countSetBits(self: *Self) usize {
            var count: usize = 0;
            for (self.bits) |b| {
                if (b != 0) count += 1;
            }
            return count;
        }
    };
}

test "BloomFilter basic add/contains" {
    var bf = try BloomFilter().init(std.testing.allocator, 1000, 0.01);
    defer bf.deinit();

    bf.add("hello");
    bf.add("world");

    try std.testing.expect(bf.contains("hello"));
    try std.testing.expect(bf.contains("world"));
}

test "BloomFilter false positive rate within expected bounds" {
    const capacity = 10000;
    const fp_rate = 0.01;
    var bf = try BloomFilter().init(std.testing.allocator, capacity, fp_rate);
    defer bf.deinit();

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < capacity) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "item_{d}", .{i}) catch unreachable;
        bf.add(key);
    }

    var false_positives: usize = 0;
    const check_count = 10000;
    var j: usize = 0;
    while (j < check_count) : (j += 1) {
        const key = std.fmt.bufPrint(&buf, "notadded_{d}", .{j}) catch unreachable;
        if (bf.contains(key)) {
            false_positives += 1;
        }
    }

    const actual_fp_rate = @as(f64, @floatFromInt(false_positives)) / @as(f64, @floatFromInt(check_count));
    try std.testing.expect(actual_fp_rate < fp_rate * 2.0);
}

test "BloomFilter contains returns false for never-added items" {
    var bf = try BloomFilter().init(std.testing.allocator, 1000, 0.01);
    defer bf.deinit();

    bf.add("present");

    try std.testing.expect(bf.contains("present"));
    try std.testing.expect(!bf.contains("absent"));
    try std.testing.expect(!bf.contains(""));
}

test "BloomFilter reset clears all bits" {
    var bf = try BloomFilter().init(std.testing.allocator, 1000, 0.01);
    defer bf.deinit();

    bf.add("one");
    bf.add("two");

    try std.testing.expect(bf.contains("one"));
    try std.testing.expect(bf.contains("two"));

    bf.reset();

    try std.testing.expect(!bf.contains("one"));
    try std.testing.expect(!bf.contains("two"));
}
