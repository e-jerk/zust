const std = @import("std");
const Box = @import("Box.zig").Box;

/// Thread-safe mutual exclusion wrapper around an owned value.
/// Similar to Rust's `Mutex<T>`.
///
/// Uses std.atomic.Mutex for simple spin-lock behavior.
///
/// Usage:
/// ```zig
/// const mutex = try Mutex(u32).init(allocator, 42);
/// mutex.lock();
/// mutex.ptr.* += 1;
/// mutex.unlock();
/// mutex.deinit();
/// ```
pub fn Mutex(comptime T: type) type {
    return struct {
        box: Box(T, 0, 0, 0),
        inner_mutex: std.atomic.Mutex,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, value: T) !Self {
            return .{
                .box = try Box(T, 0, 0, 0).init(allocator, value),
                .inner_mutex = .unlocked,
            };
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

        pub fn deinit(self: *Self) void {
            // Ensure we own the lock before deiniting
            spinLock(&self.inner_mutex);
            const dead = self.box.deinit();
            _ = dead;
            self.inner_mutex.unlock();
        }

        /// Acquire the lock (spin until available).
        pub fn lock(self: *Self) void {
            spinLock(&self.inner_mutex);
        }

        /// Release the lock.
        pub fn unlock(self: *Self) void {
            self.inner_mutex.unlock();
        }

        /// Access the value immutably (requires lock held).
        pub fn get(self: *Self) *const T {
            return self.box.ptr;
        }

        /// Access the value mutably (requires lock held).
        pub fn getMut(self: *Self) *T {
            return self.box.ptr;
        }

        /// Perform an operation with the lock held.
        pub fn withLock(self: *Self, context: anytype, comptime cb: fn (@TypeOf(context), *T) void) void {
            spinLock(&self.inner_mutex);
            defer self.inner_mutex.unlock();
            cb(context, self.box.ptr);
        }

        /// Acquire the lock and return an RAII guard.
        /// The guard unlocks automatically when it goes out of scope.
        pub fn acquire(self: *Self) MutexGuard(T) {
            spinLock(&self.inner_mutex);
            return .{ .mutex = self };
        }
    };
}

/// RAII guard for Mutex<T>.
/// Automatically unlocks the mutex when the guard is dropped.
pub fn MutexGuard(comptime T: type) type {
    return struct {
        mutex: *Mutex(T),

        const Self = @This();

        pub fn deinit(self: Self) void {
            self.mutex.unlock();
        }

        /// Access the value immutably.
        pub fn get(self: Self) *const T {
            return self.mutex.get();
        }

        /// Access the value mutably.
        pub fn getMut(self: Self) *T {
            return self.mutex.getMut();
        }
    };
}

/// Thread-safe read-write lock wrapper.
/// Similar to Rust's `RwLock<T>`.
///
/// Multiple readers OR one writer at a time.
/// Uses a simple mutex-based implementation.
pub fn RwLock(comptime T: type) type {
    return struct {
        box: Box(T, 0, 0, 0),
        inner_mutex: std.atomic.Mutex,
        readers: std.atomic.Value(u32),
        writers_waiting: std.atomic.Value(u32),

        const Self = @This();

        fn spinLock(mutex: *std.atomic.Mutex) void {
            var spins: u32 = 0;
            while (!mutex.tryLock()) {
                std.atomic.spinLoopHint();
                spins += 1;
                if (spins > 1000) {
                    // Yield to OS scheduler to prevent burning CPU on long waits
                    std.Thread.yield() catch {};
                    spins = 0;
                }
            }
        }

        pub fn init(allocator: std.mem.Allocator, value: T) !Self {
            return .{
                .box = try Box(T, 0, 0, 0).init(allocator, value),
                .inner_mutex = .unlocked,
                .readers = std.atomic.Value(u32).init(0),
                .writers_waiting = std.atomic.Value(u32).init(0),
            };
        }

        pub fn deinit(self: *Self) void {
            spinLock(&self.inner_mutex);
            const dead = self.box.deinit();
            _ = dead;
            self.inner_mutex.unlock();
        }

        pub fn readLock(self: *Self) void {
            // Writer-preference: if writers are waiting, block until they finish
            while (self.writers_waiting.load(.seq_cst) > 0) {
                std.atomic.spinLoopHint();
            }
            spinLock(&self.inner_mutex);
            _ = self.readers.fetchAdd(1, .seq_cst);
            self.inner_mutex.unlock();
        }

        pub fn readUnlock(self: *Self) void {
            _ = self.readers.fetchSub(1, .seq_cst);
        }

        pub fn writeLock(self: *Self) void {
            // Signal that a writer is waiting (prevents new readers)
            _ = self.writers_waiting.fetchAdd(1, .seq_cst);
            spinLock(&self.inner_mutex);
            // Wait for all readers to finish
            while (self.readers.load(.seq_cst) > 0) {
                std.atomic.spinLoopHint();
            }
            // Keep writers_waiting incremented while we hold the lock
        }

        pub fn writeUnlock(self: *Self) void {
            _ = self.writers_waiting.fetchSub(1, .seq_cst);
            self.inner_mutex.unlock();
        }

        pub fn get(self: *Self) *const T {
            return self.box.ptr;
        }

        pub fn getMut(self: *Self) *T {
            return self.box.ptr;
        }

        /// Acquire a read lock and return an RAII guard.
        pub fn acquireRead(self: *Self) RwLockReadGuard(T) {
            self.readLock();
            return .{ .rwlock = self };
        }

        /// Acquire a write lock and return an RAII guard.
        pub fn acquireWrite(self: *Self) RwLockWriteGuard(T) {
            self.writeLock();
            return .{ .rwlock = self };
        }
    };
}

/// RAII guard for RwLock<T> read access.
/// Automatically decrements the reader count when dropped.
pub fn RwLockReadGuard(comptime T: type) type {
    return struct {
        rwlock: *RwLock(T),

        const Self = @This();

        pub fn deinit(self: Self) void {
            self.rwlock.readUnlock();
        }

        /// Access the value immutably.
        pub fn get(self: Self) *const T {
            return self.rwlock.get();
        }
    };
}

/// RAII guard for RwLock<T> write access.
/// Automatically unlocks the mutex and decrements writers_waiting when dropped.
pub fn RwLockWriteGuard(comptime T: type) type {
    return struct {
        rwlock: *RwLock(T),

        const Self = @This();

        pub fn deinit(self: Self) void {
            self.rwlock.writeUnlock();
        }

        /// Access the value immutably.
        pub fn get(self: Self) *const T {
            return self.rwlock.get();
        }

        /// Access the value mutably.
        pub fn getMut(self: Self) *T {
            return self.rwlock.getMut();
        }
    };
}
