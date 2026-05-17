//! Example demonstrating zust ownership patterns.

const std = @import("std");
const safe = @import("safe");
const Box = safe.Box;
const LinkedList = safe.LinkedList;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example 1: Basic ownership
    {
        const box = try Box(u32).init(allocator, 42);
        std.debug.print("Value: {d}\n", .{box.ptr.*});
        const dead = box.deinit();
        _ = dead;
    }

    // Example 2: Immutable borrows
    {
        const box = try Box(u32).init(allocator, 100);
        const b1 = box.borrowImm();
        const b2 = b1.borrowImm();
        std.debug.print("Borrowed: {d}\n", .{b2.ptr.*});
        const b1_back = b2.releaseImm();
        const box_back = b1_back.releaseImm();
        const dead = box_back.deinit();
        _ = dead;
    }

    // Example 3: Mutable borrow
    {
        const box = try Box(u32).init(allocator, 0);
        const borrowed = box.borrowMut();
        borrowed.ptr.* = 999;
        std.debug.print("Mutated: {d}\n", .{borrowed.ptr.*});
        const box_back = borrowed.releaseMut();
        const dead = box_back.deinit();
        _ = dead;
    }

    // Example 4: Closure API
    {
        const box = try Box(u32).init(allocator, 7);
        var sum: u32 = 0;
        box.withImm(&sum, struct {
            fn f(ctx: *u32, val: *const u32) void {
                ctx.* += val.*;
            }
        }.f);
        std.debug.print("Sum from closure: {d}\n", .{sum});
        const dead = box.deinit();
        _ = dead;
    }

    // Example 5: Safe LinkedList
    {
        var list = LinkedList(u32).init(allocator);
        try list.push(1);
        try list.push(2);
        try list.push(3);
        while (list.pop()) |value| {
            std.debug.print("Popped: {d}\n", .{value});
        }
        list.deinit();
    }

    std.debug.print("\nAll examples completed safely!\n", .{});
}
