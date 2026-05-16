const std = @import("std");

/// RAII guard for std.Io.File.
/// Automatically closes the file when the guard is dropped.
pub fn FileGuard() type {
    return struct {
        file: std.Io.File,
        io: std.Io,
        closed: bool,
        read_buffer: [4096]u8,
        write_buffer: [4096]u8,

        const Self = @This();

        pub fn init(file: std.Io.File, io: std.Io) Self {
            return .{
                .file = file,
                .io = io,
                .closed = false,
                .read_buffer = undefined,
                .write_buffer = undefined,
            };
        }

        pub fn deinit(self: *Self) void {
            if (!self.closed) {
                self.file.close(self.io);
                self.closed = true;
            }
        }

        pub fn get(self: *Self) *std.Io.File {
            return &self.file;
        }

        pub fn close(self: *Self) void {
            self.deinit();
        }

        pub fn isClosed(self: *const Self) bool {
            return self.closed;
        }

        pub fn reader(self: *Self) std.Io.File.Reader {
            return self.file.reader(self.io, &self.read_buffer);
        }

        pub fn writer(self: *Self) std.Io.File.Writer {
            return self.file.writer(self.io, &self.write_buffer);
        }
    };
}

/// RAII guard for std.Io.Dir.
pub fn DirGuard() type {
    return struct {
        dir: std.Io.Dir,
        io: std.Io,
        closed: bool,

        const Self = @This();

        pub fn init(dir: std.Io.Dir, io: std.Io) Self {
            return .{
                .dir = dir,
                .io = io,
                .closed = false,
            };
        }

        pub fn deinit(self: *Self) void {
            if (!self.closed) {
                self.dir.close(self.io);
                self.closed = true;
            }
        }

        pub fn get(self: *Self) *std.Io.Dir {
            return &self.dir;
        }
    };
}

/// RAII guard for memory-mapped files.
pub fn MappedFileGuard() type {
    return struct {
        data: []align(std.heap.page_size_min) u8,
        file: ?std.Io.File,
        io: std.Io,

        const Self = @This();

        pub fn init(data: []align(std.heap.page_size_min) u8, file: ?std.Io.File, io: std.Io) Self {
            return .{
                .data = data,
                .file = file,
                .io = io,
            };
        }

        pub fn deinit(self: *Self) void {
            std.posix.munmap(self.data);
            if (self.file) |f| f.close(self.io);
        }

        pub fn slice(self: Self) []u8 {
            return self.data;
        }
    };
}

/// RAII guard for a memory allocator reset.
/// Tracks all allocations from an ArenaAllocator and can reset them at once.
pub fn ArenaGuard() type {
    return struct {
        arena: std.heap.ArenaAllocator,

        const Self = @This();

        pub fn init(child_allocator: std.mem.Allocator) Self {
            return .{ .arena = std.heap.ArenaAllocator.init(child_allocator) };
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return self.arena.allocator();
        }

        pub fn reset(self: *Self) void {
            _ = self.arena.reset(.retain_capacity);
        }
    };
}

// ─── Tests ───

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "FileGuard opens and auto-closes file" {
    const io = testIo();
    const tmp_path = "/tmp/zust_test_fileguard";
    {
        const file = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{ .read = true });
        var guard = FileGuard().init(file, io);
        defer guard.deinit();
        try std.testing.expect(!guard.isClosed());
    }
    // After scope exit, file should be closed; verify by deleting it
    try std.Io.Dir.deleteFileAbsolute(io, tmp_path);
}

test "DirGuard opens and auto-closes directory" {
    const io = testIo();
    const tmp_dir = "/tmp/zust_test_dirguard";
    try std.Io.Dir.createDirAbsolute(io, tmp_dir, .default_dir);
    {
        const dir = try std.Io.Dir.openDirAbsolute(io, tmp_dir, .{});
        var guard = DirGuard().init(dir, io);
        defer guard.deinit();
        try std.testing.expect(!guard.closed);
    }
    // After scope exit, dir should be closed; verify by deleting it
    try std.Io.Dir.deleteDirAbsolute(io, tmp_dir);
}

test "ArenaGuard allocates and resets" {
    var guard = ArenaGuard().init(std.testing.allocator);
    defer guard.deinit();
    const alloc = guard.allocator();

    const ptr = try alloc.alloc(u8, 100);
    @memset(ptr, 0xAA);
    try std.testing.expectEqual(ptr[0], 0xAA);

    guard.reset();

    const ptr2 = try alloc.alloc(u8, 50);
    try std.testing.expectEqual(ptr2.len, 50);
}

test "FileGuard explicit close before deinit is safe (no double-close)" {
    const io = testIo();
    const tmp_path = "/tmp/zust_test_fileguard_explicit";
    const file = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{ .read = true });
    var guard = FileGuard().init(file, io);
    guard.close();
    try std.testing.expect(guard.isClosed());
    guard.deinit(); // should not double-close
    try std.Io.Dir.deleteFileAbsolute(io, tmp_path);
}
