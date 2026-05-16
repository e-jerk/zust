const std = @import("std");
const Box = @import("Box.zig").Box;

/// A singly-linked list where each node's `next` pointer is an owned Box.
/// The list head is an optional owned Box.
/// All operations respect the typestate borrow rules.
pub fn LinkedList(comptime T: type) type {
    return struct {
        const Node = struct {
            value: T,
            next: ?Box(Node, 0, 0, 0) = null,
        };

        head: ?Box(Node, 0, 0, 0) = null,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .head = null };
        }

        /// Push a value onto the front of the list.
        /// The new node takes ownership of the current head as its `next`.
        pub fn push(self: *Self, value: T) !void {
            const new_node = try Box(Node, 0, 0, 0).init(self.allocator, .{
                .value = value,
                .next = self.head,
            });
            self.head = new_node;
        }

        /// Pop the front value from the list.
        /// The head node is deallocated; its `next` becomes the new head.
        pub fn pop(self: *Self) ?T {
            if (self.head) |head_box| {
                // Borrow mutably to read the node and extract next
                const borrowed = head_box.borrowMut();
                const node = borrowed.ptr.*;
                const value = node.value;
                const next = node.next;

                // Release borrow and deallocate the node
                const box_after = borrowed.releaseMut();
                const dead = box_after.deinit();
                _ = dead;

                self.head = next;
                return value;
            }
            return null;
        }

        /// Deallocate all nodes in the list.
        pub fn deinit(self: *Self) void {
            while (self.pop()) |_| {}
        }

        /// Get the length by traversing the list.
        /// This uses explicit borrows and releases for each node.
        pub fn len(self: *const Self) usize {
            var count: usize = 0;
            var current = self.head;
            while (current) |box| {
                const borrowed = box.borrowImm();
                const node = borrowed.ptr.*;
                count += 1;
                current = node.next;
                const released = borrowed.releaseImm();
                _ = released;
            }
            return count;
        }

        /// Iterate over the list immutably.
        /// Uses explicit borrows and releases for each node.
        pub fn forEach(self: *const Self, context: anytype, comptime cb: fn (@TypeOf(context), *const T) void) void {
            var current = self.head;
            while (current) |box| {
                const borrowed = box.borrowImm();
                const node = borrowed.ptr.*;
                cb(context, &node.value);
                current = node.next;
                const released = borrowed.releaseImm();
                _ = released;
            }
        }

        /// Iterate over the list mutably.
        /// Uses explicit borrows and releases for each node.
        pub fn forEachMut(self: *Self, context: anytype, comptime cb: fn (@TypeOf(context), *T) void) void {
            var current = self.head;
            while (current) |box| {
                const borrowed = box.borrowMut();
                cb(context, &borrowed.ptr.*.value);
                current = borrowed.ptr.*.next;
                const released = borrowed.releaseMut();
                _ = released;
            }
        }

        pub fn retain(self: *Self, context: anytype, comptime pred: fn (@TypeOf(context), *const T) bool) void {
            var current = &self.head;
            while (current.*) |box| {
                const borrowed_imm = box.borrowImm();
                const keep = pred(context, &borrowed_imm.ptr.*.value);
                const box_after_imm = borrowed_imm.releaseImm();
                _ = box_after_imm;

                if (keep) {
                    const borrowed_mut = box.borrowMut();
                    current = &borrowed_mut.ptr.*.next;
                    const box_after_mut = borrowed_mut.releaseMut();
                    _ = box_after_mut;
                } else {
                    const borrowed_mut = box.borrowMut();
                    const next = borrowed_mut.ptr.*.next;
                    const box_after_mut = borrowed_mut.releaseMut();
                    const dead = box_after_mut.deinit();
                    _ = dead;
                    current.* = next;
                }
            }
        }

        pub fn reverse(self: *Self) void {
            var prev: ?Box(Node, 0, 0, 0) = null;
            var current = self.head;

            while (current) |box| {
                const borrowed = box.borrowMut();
                const next = borrowed.ptr.*.next;
                borrowed.ptr.*.next = prev;
                const released = borrowed.releaseMut();
                _ = released;

                prev = box;
                current = next;
            }

            self.head = prev;
        }

        /// Return a consuming iterator over the list.
        /// Each call to next() removes and returns the first item.
        pub fn iterator(self: *Self) Iter {
            return .{ .list = self };
        }

        /// Iterator for LinkedList<T>.
        /// Removes and returns each value (consumes the list).
        pub const Iter = struct {
            list: *Self,

            pub fn next(self: *Iter) ?T {
                return self.list.pop();
            }
        };
    };
}
