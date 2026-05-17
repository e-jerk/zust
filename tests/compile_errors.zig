const safe = @import("../lib/safe.zig");
const Box = safe.Box;

// This file tests compile-time error detection.
// Each test is a standalone function that should fail to compile.
// We test by attempting to compile and verifying the expected error.

// Test 1: Double-free
test "compile_error: double_free" {
    const box = try Box(u32).init(std.testing.allocator, 42);
    box.deinit();
    box.deinit(); // @compileError: double free detected
}

// Test 2: Use-after-move (via parameter passing)
test "compile_error: use_after_move" {
    var box = try Box(u32).init(std.testing.allocator, 42);
    takeOwnership(box);
    box.deinit(); // @compileError: use of moved value
}

fn takeOwnership(b: Box(u32)) void {
    b.deinit();
}

// Test 3: Borrow mutably while immutable borrows active
test "compile_error: borrow_mut_while_imm_active" {
    const box = try Box(u32).init(std.testing.allocator, 42);
    const b1 = box.borrowImm();
    const b2 = b1.borrowImm();
    const mut = b2.borrowMut(); // @compileError: cannot borrow mutably: active immutable borrows exist
    _ = mut;
}

// Test 4: Free while active borrows exist
test "compile_error: free_with_active_borrows" {
    const box = try Box(u32).init(std.testing.allocator, 42);
    const b1 = box.borrowImm();
    b1.deinit(); // @compileError: cannot free: value is not in Owned state
}

// Test 5: Release wrong borrow type
test "compile_error: release_wrong_type" {
    const box = try Box(u32).init(std.testing.allocator, 42);
    const b1 = box.borrowMut();
    const back = b1.releaseImm(); // @compileError: cannot release immutable borrow: not in borrowed state
    _ = back;
}

// Test 6: Use borrow after release
test "compile_error: use_borrow_after_release" {
    const box = try Box(u32).init(std.testing.allocator, 42);
    const b1 = box.borrowImm();
    const back = b1.releaseImm();
    const b2 = back.borrowImm(); // This should work
    const back2 = b2.releaseImm();
    back2.deinit();
}
