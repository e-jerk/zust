const std = @import("std");

/// One-time initialization cell with inline storage.
/// Similar to Rust's `std::sync::OnceCell<T>` or `once_cell::unsync::OnceCell<T>`.
///
/// Stores the value inline (option a). For heap-allocated values, use `OnceBox(T)`.
pub fn OnceCell(comptime T: type) type {
    return struct {
        value: T = undefined,
        initialized: bool = false,

        const Self = @This();

        pub fn init() Self {
            return .{ .value = undefined, .initialized = false };
        }

        /// Mark the cell as uninitialized. Note: does not call a destructor on `T`
        /// since Zig has no automatic drop mechanism. For types owning resources,
        /// use `OnceBox(T)` which frees the heap allocation.
        pub fn deinit(self: *Self) void {
            self.initialized = false;
        }

        /// Set the value if not already initialized.
        /// Returns `error.AlreadyInitialized` if the cell already holds a value.
        pub fn set(self: *Self, value: T) !void {
            if (self.initialized) return error.AlreadyInitialized;
            self.value = value;
            self.initialized = true;
        }

        /// Get a pointer to the value if initialized.
        pub fn get(self: *const Self) ?*const T {
            if (!self.initialized) return null;
            return &self.value;
        }

        /// Get the value if initialized, otherwise initialize with `value`.
        pub fn getOrInit(self: *Self, value: T) *const T {
            if (!self.initialized) {
                self.value = value;
                self.initialized = true;
            }
            return &self.value;
        }

        pub fn isInitialized(self: *const Self) bool {
            return self.initialized;
        }

        /// Convenience that stores the value inline. For true heap allocation,
        /// use `OnceBox(T)` instead.
        pub fn initAlloc(_allocator: std.mem.Allocator, value: T) !Self {
            _ = _allocator;
            var self = Self{};
            self.value = value;
            self.initialized = true;
            return self;
        }
    };
}

/// Lazy initialization cell with inline storage.
/// Initializes the value on first access via a stored initializer function.
/// Similar to Rust's `std::cell::LazyCell<T>` or `once_cell::sync::Lazy<T>`.
pub fn LazyCell(comptime T: type) type {
    return struct {
        value: T = undefined,
        initialized: bool = false,
        init_fn: *const fn () T,

        const Self = @This();

        pub fn init(comptime f: fn () T) Self {
            return .{ .init_fn = f };
        }

        /// Mark the cell as uninitialized. Note: does not call a destructor on `T`.
        pub fn deinit(self: *Self) void {
            self.initialized = false;
        }

        /// Initialize (if needed) and return an immutable pointer.
        pub fn get(self: *Self) *const T {
            if (!self.initialized) {
                self.value = self.init_fn();
                self.initialized = true;
            }
            return &self.value;
        }

        /// Initialize (if needed) and return a mutable pointer.
        pub fn getMut(self: *Self) *T {
            if (!self.initialized) {
                self.value = self.init_fn();
                self.initialized = true;
            }
            return &self.value;
        }

        /// Force initialization without returning the value.
        pub fn force(self: *Self) void {
            _ = self.get();
        }

        pub fn isInitialized(self: *const Self) bool {
            return self.initialized;
        }
    };
}

/// Heap-allocated one-time initialization cell.
/// The value lives on the heap and is freed on `deinit`.
pub fn OnceBox(comptime T: type) type {
    return struct {
        ptr: ?*T = null,
        allocator: ?std.mem.Allocator = null,

        const Self = @This();

        pub fn init() Self {
            return .{ .ptr = null, .allocator = null };
        }

        /// Free the heap-allocated value if initialized.
        pub fn deinit(self: *Self) void {
            if (self.ptr) |p| {
                self.allocator.?.destroy(p);
                self.ptr = null;
                self.allocator = null;
            }
        }

        /// Allocate and set the value if not already initialized.
        /// Returns `error.AlreadyInitialized` if the box already holds a value.
        pub fn set(self: *Self, allocator: std.mem.Allocator, value: T) !void {
            if (self.ptr != null) return error.AlreadyInitialized;
            const p = try allocator.create(T);
            p.* = value;
            self.ptr = p;
            self.allocator = allocator;
        }

        /// Get a pointer to the value if initialized.
        pub fn get(self: *const Self) ?*const T {
            if (self.ptr) |p| return p;
            return null;
        }

        pub fn isInitialized(self: *const Self) bool {
            return self.ptr != null;
        }
    };
}
