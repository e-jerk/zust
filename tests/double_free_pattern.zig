fn testDoubleFree() void {
    const box = Box(u32, 0, 0, 0).init(std.heap.page_allocator, 42) catch unreachable;
    const dead = box.deinit();
    const dead2 = dead.deinit();
    _ = dead2;
}
