/// Zero-sized marker type that carries type information.
/// Similar to Rust's `std::marker::PhantomData<T>`.
/// Used to tell the compiler about logical ownership when the type doesn't naturally contain T.
pub fn PhantomData(comptime T: type) type {
    _ = T;
    return struct {
        const Self = @This();

        pub fn init() Self {
            return .{};
        }
    };
}

// ─── Tests ───

// A struct that logically owns T but doesn't store it directly.
// PhantomData tells the type system about this logical ownership.
fn Owner(comptime T: type) type {
    return struct {
        handle: usize,
        _phantom: PhantomData(T),

        const Self = @This();

        pub fn init(handle: usize) Self {
            return .{
                .handle = handle,
                ._phantom = PhantomData(T).init(),
            };
        }
    };
}

test "PhantomData usage" {
    const std = @import("std");

    const owner = Owner(u32).init(7);
    try std.testing.expectEqual(@as(usize, 7), owner.handle);
}
