const std = @import("std");
const safe = @import("safe");
const Box = safe.Box;

fn useAfterFree() void {
    const box = Box(u32).init(std.heap.page_allocator, 42) catch unreachable;
    const raw = box.unsafePtr();
    const dead = box.deinit();
    _ = dead;
    raw.* = 100; // use after free
}

fn doubleFree() void {
    const box = Box(u32).init(std.heap.page_allocator, 42) catch unreachable;
    const dead = box.deinit();
    const dead2 = dead.deinit(); // double free
    _ = dead2;
}

fn danglingPointerEscape() void {
    var box = Box(u32).init(std.heap.page_allocator, 42) catch unreachable;
    const raw = box.unsafePtr();
    global_ptr = raw; // escape
    const dead = box.deinit();
    _ = dead;
}

var global_ptr: ?*u32 = null;

fn validUsage() void {
    const box = Box(u32).init(std.heap.page_allocator, 42) catch unreachable;
    const borrowed = box.borrowMut();
    borrowed.ptr.* = 100;
    const box_back = borrowed.releaseMut();
    const dead = box_back.deinit();
    _ = dead;
}
