# zust Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a zero-cost comptime ownership library (`zust`) and a general-purpose static analyzer (`zust-analyzer`) for Zig.

**Architecture:** Two-layer system. Layer 1 is a comptime library using typestate `Box(T, tag, imm, mut)` with `@compileError` gating. Layer 2 is a standalone static analyzer linking against Zig's AST parser for interprocedural pointer provenance tracking.

**Tech Stack:** Zig 0.16.0, Zig compiler internals for AST parsing

---

## Phase 1: Core Library

### Task 1: Project Structure

**Files:**
- Create: `zust/build.zig`
- Create: `zust/lib/safe.zig`
- Create: `zust/lib/Box.zig`

**Step 1: Write build.zig**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addModule("safe", .{
        .root_source_file = b.path("lib/safe.zig"),
    });
    _ = lib;

    const test_step = b.step("test", "Run library tests");
    const tests = b.addTest(.{
        .root_source_file = b.path("tests/compile_errors.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
```

**Step 2: Create lib directory structure**

```bash
mkdir -p lib tests
```

**Step 3: Commit**

```bash
git add build.zig
```

### Task 2: Box Type with Typestate

**Files:**
- Create: `zust/lib/Box.zig`
- Create: `zust/lib/safe.zig`

**Step 1: Write Box.zig**

Implement `Box(T, state_tag, imm_count, mut_count)` with:
- `init` → `Box(T, 0, 0, 0)`
- `borrowImm` → checks state, returns `Box(T, 1, imm+1, mut)`
- `borrowMut` → checks state, returns `Box(T, 2, 0, 1)`
- `releaseImm` → returns `Box(T, if (imm==1) 0 else 1, imm-1, mut)`
- `releaseMut` → returns `Box(T, 0, 0, 0)`
- `move` → returns `Box(T, 3, 0, 0)`
- `deinit` → checks state, destroys pointer

**Step 2: Write safe.zig**

Re-export `Box`.

**Step 3: Write first test**

Test that `Box(u32, 0, 0, 0).init` compiles and creates a valid box.

**Step 4: Run test**

```bash
cd zust && zig build test
```

Expected: PASS

**Step 5: Commit**

```bash
git add lib/Box.zig lib/safe.zig tests/compile_errors.zig
```

### Task 3: Closure API

**Files:**
- Modify: `zust/lib/Box.zig`

**Step 1: Add withImm and withMut methods**

```zig
pub fn withImm(self: Self, context: anytype, comptime cb: fn (@TypeOf(context), *const T) void) void
pub fn withMut(self: *Self, context: anytype, comptime cb: fn (@TypeOf(context), *T) void) void
```

**Step 2: Test closure borrow**

Verify that `withMut` allows mutation inside closure and borrow ends after closure returns.

**Step 3: Run test**

Expected: PASS

**Step 4: Commit**

### Task 4: Compile-Error Test Suite

**Files:**
- Create: `zust/tests/compile_errors.zig`

**Step 1: Write tests for each bug class**

- Double-free
- Use-after-move
- Borrow during active mut
- Free with active borrows
- Double mutable borrow

**Step 2: Verify each test produces @compileError**

Use `zig test` and confirm each test fails with the expected error message.

**Step 3: Commit**

### Task 5: Safe LinkedList

**Files:**
- Create: `zust/lib/LinkedList.zig`
- Modify: `zust/lib/safe.zig`

**Step 1: Implement LinkedList using Box**

Nodes contain `Box(Node, 0, 0, 0)` for `next` pointer.

**Step 2: Test push/pop/deinit**

**Step 3: Commit**

## Phase 2: Static Analyzer Foundation

### Task 6: Analyzer Project Structure

**Files:**
- Create: `zust/analyzer/build.zig`
- Create: `zust/analyzer/src/main.zig`

**Step 1: Write analyzer build.zig**

Executable target with dependency on Zig compiler internals.

**Step 2: Write main.zig skeleton**

Command-line argument parsing.

**Step 3: Commit**

### Task 7: AST Integration

**Files:**
- Modify: `zust/analyzer/src/main.zig`
- Create: `zust/analyzer/src/AST.zig`

**Step 1: Link against Zig parser**

Use `zig.parse()` or equivalent from Zig compiler internals.

**Step 2: Parse a simple .zig file**

Test with a file containing `const x = 5;`.

**Step 3: Commit**

### Task 8: Control Flow Graph

**Files:**
- Create: `zust/analyzer/src/CFG.zig`

**Step 1: Define CFG structures**

Node, Edge, BasicBlock.

**Step 2: Build CFG from AST**

Handle blocks, if/else, loops, switch.

**Step 3: Test with sample functions**

**Step 4: Commit**

### Task 9: Provenance Tracking

**Files:**
- Create: `zust/analyzer/src/Provenance.zig`

**Step 1: Define Provenance union**

Stack, Heap, Borrow, Derived, Unknown.

**Step 2: Track provenance for pointer expressions**

&local, allocator.create(), box.unsafePtr(), field access.

**Step 3: Test intraprocedural tracking**

**Step 4: Commit**

### Task 10: Lifetime Validation

**Files:**
- Create: `zust/analyzer/src/Lifetime.zig`

**Step 1: Detect deallocation sites**

`allocator.destroy()`, `box.deinit()`.

**Step 2: Find derived pointers**

Walk provenance graph.

**Step 3: Check for post-dealloc use**

Report use-after-free.

**Step 4: Test with escape hatch examples**

**Step 5: Commit**

## Phase 3: Interprocedural + NLL

### Task 11: Function Summaries

**Files:**
- Create: `zust/analyzer/src/FunctionSummary.zig`

**Step 1: Define summary structure**

Params (provenance + escape flag), return provenance, side effects.

**Step 2: Generate summaries**

Analyze each function body once.

**Step 3: Test cross-function escape**

```zig
fn stash(ptr: *u32) void { global = ptr; }
```

**Step 4: Commit**

### Task 12: Non-Lexical Lifetimes

**Files:**
- Modify: `zust/analyzer/src/Lifetime.zig`

**Step 1: Compute last-use for each borrow**

Walk CFG backward from deallocation.

**Step 2: Allow reborrow after last-use**

Test:
```zig
var b = box.borrowMut();
b.write(1);
// b not used again
var b2 = box.borrowMut(); // Should be OK with NLL
```

**Step 3: Commit**

## Phase 4: Output + Integration

### Task 13: Diagnostic Output

**Files:**
- Create: `zust/analyzer/src/Diagnostics.zig`

**Step 1: Implement Zig-style output**

file:line:column: error: message

**Step 2: Implement SARIF output**

JSON format for CI.

**Step 3: Test both formats**

**Step 4: Commit**

### Task 14: LSP Server

**Files:**
- Create: `zust/analyzer/src/LSP.zig`

**Step 1: Implement JSON-RPC handler**

textDocument/didOpen, didChange, publishDiagnostics.

**Step 2: Integrate incremental analysis**

Re-analyze changed functions only.

**Step 3: Test with simple LSP client**

**Step 4: Commit**

## Final Verification

Run full test suite:
```bash
cd zust && zig build test
```

Expected: All library tests pass, all compile-error tests produce expected errors.
