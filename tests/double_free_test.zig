const std = @import("std");
const Box = @import("../lib/Box.zig").Box;

pub fn main() !void {
    const box = try Box(u32).init(std.heap.page_allocator, 42);
    box.deinit();
    box.deinit();
}
