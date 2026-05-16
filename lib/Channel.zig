const std = @import("std");

pub fn Channel(comptime T: type) type {
    return struct {
        buffer: []T,
        head: usize,
        tail: usize,
        count: usize,
        capacity: usize,
        mutex: std.atomic.Mutex,
        closed: bool,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const buf = try allocator.alloc(T, capacity);
            return .{
                .buffer = buf,
                .head = 0,
                .tail = 0,
                .count = 0,
                .capacity = capacity,
                .mutex = .unlocked,
                .closed = false,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            while (!self.mutex.tryLock()) {
                std.atomic.spinLoopHint();
            }
            self.allocator.free(self.buffer);
            self.mutex.unlock();
        }

        pub fn send(self: *Self, value: T) !void {
            while (true) {
                if (self.mutex.tryLock()) {
                    defer self.mutex.unlock();
                    if (self.closed) return error.ChannelClosed;
                    if (self.count < self.capacity) {
                        self.buffer[self.tail] = value;
                        self.tail = (self.tail + 1) % self.capacity;
                        self.count += 1;
                        return;
                    }
                }
                std.atomic.spinLoopHint();
                std.Thread.yield() catch {};
            }
        }

        pub fn trySend(self: *Self, value: T) !bool {
            if (self.mutex.tryLock()) {
                defer self.mutex.unlock();
                if (self.closed) return error.ChannelClosed;
                if (self.count < self.capacity) {
                    self.buffer[self.tail] = value;
                    self.tail = (self.tail + 1) % self.capacity;
                    self.count += 1;
                    return true;
                }
                return false;
            }
            return false;
        }

        pub fn recv(self: *Self) ?T {
            while (true) {
                if (self.mutex.tryLock()) {
                    defer self.mutex.unlock();
                    if (self.count > 0) {
                        const value = self.buffer[self.head];
                        self.head = (self.head + 1) % self.capacity;
                        self.count -= 1;
                        return value;
                    }
                    if (self.closed) return null;
                }
                std.atomic.spinLoopHint();
                std.Thread.yield() catch {};
            }
        }

        pub fn tryRecv(self: *Self) ?T {
            if (self.mutex.tryLock()) {
                defer self.mutex.unlock();
                if (self.count > 0) {
                    const value = self.buffer[self.head];
                    self.head = (self.head + 1) % self.capacity;
                    self.count -= 1;
                    return value;
                }
                return null;
            }
            return null;
        }

        pub fn close(self: *Self) void {
            while (!self.mutex.tryLock()) {
                std.atomic.spinLoopHint();
            }
            self.closed = true;
            self.mutex.unlock();
        }

        pub fn isClosed(self: *const Self) bool {
            return self.closed;
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }
    };
}

pub fn Oneshot(comptime T: type) type {
    return struct {
        value: ?T,
        mutex: std.atomic.Mutex,
        sent: bool,
        received: bool,

        const Self = @This();

        pub fn init() Self {
            return .{
                .value = null,
                .mutex = .unlocked,
                .sent = false,
                .received = false,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.value) |v| {
                _ = v;
            }
        }

        pub fn send(self: *Self, value: T) !void {
            while (!self.mutex.tryLock()) {
                std.atomic.spinLoopHint();
            }
            defer self.mutex.unlock();
            if (self.sent) return error.AlreadySent;
            if (self.received) return error.AlreadyReceived;
            self.value = value;
            self.sent = true;
        }

        pub fn recv(self: *Self) ?T {
            while (!self.mutex.tryLock()) {
                std.atomic.spinLoopHint();
            }
            defer self.mutex.unlock();
            if (self.received) return null;
            if (self.value) |v| {
                self.received = true;
                return v;
            }
            return null;
        }

        pub fn tryRecv(self: *Self) ?T {
            if (self.mutex.tryLock()) {
                defer self.mutex.unlock();
                if (self.received) return null;
                if (self.value) |v| {
                    self.received = true;
                    return v;
                }
                return null;
            }
            return null;
        }

        pub fn isSent(self: *const Self) bool {
            return self.sent;
        }

        pub fn isReceived(self: *const Self) bool {
            return self.received;
        }
    };
}

pub fn bounded(comptime T: type, allocator: std.mem.Allocator, capacity: usize) !Channel(T) {
    return try Channel(T).init(allocator, capacity);
}

pub fn unbounded(comptime T: type, allocator: std.mem.Allocator) !Channel(T) {
    return try Channel(T).init(allocator, 1024);
}

test "Channel send and recv" {
    var ch = try Channel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();
    
    try ch.send(42);
    const val = ch.recv();
    try std.testing.expectEqual(val.?, 42);
}

test "Oneshot send and recv" {
    var os = Oneshot(u32).init();
    
    try os.send(100);
    try std.testing.expect(os.isSent());
    
    const val = os.recv();
    try std.testing.expectEqual(val.?, 100);
    try std.testing.expect(os.isReceived());
    
    // Second recv returns null
    const val2 = os.recv();
    try std.testing.expect(val2 == null);
}

test "Channel close" {
    var ch = try Channel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();
    
    try ch.send(1);
    ch.close();
    
    try std.testing.expect(ch.isClosed());
    
    // Drain remaining
    const val = ch.recv();
    try std.testing.expectEqual(val.?, 1);
    
    // Empty after drain
    const val2 = ch.recv();
    try std.testing.expect(val2 == null);
}

test "Channel multiple values" {
    var ch = try Channel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();
    
    try ch.send(10);
    try ch.send(20);
    try ch.send(30);
    
    try std.testing.expectEqual(ch.len(), 3);
    
    try std.testing.expectEqual(ch.recv().?, 10);
    try std.testing.expectEqual(ch.recv().?, 20);
    try std.testing.expectEqual(ch.recv().?, 30);
    try std.testing.expect(ch.tryRecv() == null);
}