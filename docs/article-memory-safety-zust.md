# Memory Safety in Zust: What It Prevents and How

Zust is a zero-cost comptime library for Zig that prevents common memory errors at compile time by encoding ownership state in type parameters. It provides compile-time safety guarantees comparable to Rust's borrow checker, implemented as a library rather than a language feature.

This article describes each class of memory error zust prevents, the mechanism it uses, and the limitations that remain.

---

## Architecture

Zust has two layers:

**Layer 1: Comptime library (`lib/`)**
Core primitive: `Box(T, state_tag, imm_count, mut_count)`
- `state_tag`: ownership state (owned, borrowed, moved, freed)
- `imm_count`: number of active immutable borrows
- `mut_count`: number of active mutable borrows (0 or 1)

Every state transition returns a different type. Invalid states are unrepresentable and produce `@compileError`.

**Layer 2: Static analyzer (`analyzer/`)**
Intraprocedural and interprocedural pointer provenance tracking, lifetime validation, and LSP integration for IDE diagnostics.

---

## Tool Integration

Zust provides three tools that work together: a transpiler, a static analyzer, and an LSP server.

### Transpiler (`zust-transpile`)

The transpiler converts unsafe Zig code to zust-safe Zig. It operates on single files or entire projects.

**Input:** Raw Zig source with `std.ArrayList`, `allocator.create`, raw pointers.
**Output:** Zust-safe equivalent with `safe.ArrayList`, `safe.Box`, `safe.CheckedInt`.

The transpiler uses a set of pattern-based rules:
1. Parse the Zig AST
2. Identify unsafe patterns (raw allocations, null unwraps, unchecked casts)
3. Apply type substitutions from the mapping table
4. Insert ownership transitions where required (e.g., `deinit` returns must be captured)
5. Generate the transformed source

It does not perform semantic analysis. It is a syntactic transformer that handles the mechanical 80% of migration. The remaining 20% requires manual review or analyzer feedback.

### Static Analyzer (`zust-analyze`)

The analyzer performs deeper analysis that the transpiler cannot do:

- **Pointer provenance tracking:** Traces where pointers originate (stack, heap, borrow) and where they flow
- **Lifetime validation:** Detects use-after-free, dangling pointers, and escape of stack references across function boundaries
- **Pattern detection:** Flags raw `*T` and `[]T` usage and suggests `safe.Box` replacements
- **SARIF 2.1.0 output:** Structured JSON for CI integration

The analyzer is intraprocedural by default and can be run in interprocedural mode for cross-function analysis. It operates on the Zig AST and builds a control flow graph to track pointer state through branches and loops.

### LSP Server (`zust-lsp`)

The LSP server wraps the analyzer for real-time IDE integration:

- `textDocument/publishDiagnostics` — pushes analyzer findings as you type
- `textDocument/completion` — suggests zust-safe replacements
- `textDocument/hover` — shows ownership state and borrow status
- `textDocument/definition` — navigates to type definitions
- `textDocument/codeAction` — offers quick fixes for detected issues
- Incremental sync — only re-analyzes changed functions

The server runs as a background process. The editor sends file change events; the server runs the analyzer on affected regions and pushes diagnostics back.

### How the Tools Connect

```
┌─────────────────────────────────────────────┐
│  Migration Workflow                          │
├─────────────────────────────────────────────┤
│  1. Run zust-transpile on codebase          │
│     → Mechanical type replacements            │
│                                              │
│  2. Run zust-analyze on transpiled code     │
│     → Detect remaining unsafe patterns       │
│     → Identify ownership transition errors    │
│                                              │
│  3. Fix analyzer findings                    │
│     → Manual edits or code actions via LSP   │
│                                              │
│  4. Enable zust-lsp in editor                │
│     → Real-time diagnostics as you code      │
│     → Prevents new unsafe patterns           │
└─────────────────────────────────────────────┘
```

The transpiler handles bulk conversion. The analyzer verifies correctness. The LSP server maintains safety during ongoing development. All three read from and write to standard Zig source files. No intermediate representation or build system integration is required.

---

## Memory Errors Prevented

### 1. Double-Free

**Problem:** Calling `free` on the same memory twice causes undefined behavior.

```zig
// Unsafe Zig
var ptr = try allocator.create(u32);
allocator.destroy(ptr);
allocator.destroy(ptr); // UB
```

**Zust mechanism:** `deinit()` consumes the box by value and returns a dead-state type. The original binding is no longer valid.

```zig
var box = try Box(u32).init(allocator, 42);
const dead = box.deinit();
_ = dead;
// box.deinit(); // compile error: undeclared identifier
```

The dead-state type has no `deinit` method. Double-free is impossible because the type system cannot express it.

**Comparison to Rust:** Rust's `Drop` runs automatically; calling `drop()` twice requires explicit unsafe code. Zust uses explicit state transitions instead of automatic destruction.

---

### 2. Use-After-Free

**Problem:** Accessing memory after deallocation.

```zig
// Unsafe Zig
var ptr = try allocator.create(u32);
allocator.destroy(ptr);
ptr.* = 42; // UB
```

**Zust mechanism:** `deinit()` is only defined for `Box(T, 0, 0, 0)` — the state with no active borrows. If borrows exist, the call is a `@compileError`.

```zig
var box = try Box(u32).init(allocator, 42);
const borrow = box.borrowImm();

// box.deinit(); // compile error: active borrows exist

const box_back = borrow.releaseImm();
const dead = box_back.deinit(); // valid
```

**Comparison to Rust:** Rust rejects this through lifetime analysis (`borrowed value does not live long enough`). Zust rejects it through typestate: the borrow type cannot be deallocated, and the owned type is consumed by `borrowImm()`.

---

### 3. Use-After-Move

**Problem:** Using a value after ownership has been transferred.

**Zust mechanism:** `move()` consumes the source box and returns a moved-state type. The original binding is no longer in scope.

```zig
var box = try Box(u32).init(allocator, 42);
const moved = box.move();
_ = moved;

// box.borrowImm(); // compile error: undeclared identifier
```

**Comparison to Rust:** Rust's move semantics consume the source binding at the language level. Zust replicates this by making `move()` consume `self` and return a type with no usable methods except deinitialization.

---

### 4. Mutable Aliasing / Data Races

**Problem:** Two mutable references to the same data, or a mutable and immutable reference simultaneously.

```zig
// Unsafe Zig
var x: u32 = 42;
var ptr1 = &x;
var ptr2 = &x;
ptr1.* = 1;
ptr2.* = 2; // data race
```

**Zust mechanism:** The type parameters enforce XOR:
- `borrowMut()` requires `imm_count == 0` and `mut_count == 0`
- `borrowImm()` requires `mut_count == 0`
- Only one mutable borrow is allowed at any time

```zig
var box = try Box(u32).init(allocator, 42);
const mut1 = box.borrowMut();

// box.borrowMut(); // compile error: active mutable borrow
// box.borrowImm(); // compile error: active mutable borrow

mut1.write(100);
const box_back = mut1.releaseMut();
const imm = box_back.borrowImm(); // valid
```

**Comparison to Rust:** This is the same rule Rust enforces: `&mut T` is exclusive, `&T` is shared. Rust's compiler infers this implicitly; zust makes it explicit through type transitions.

---

### 5. Null Pointer Dereference

**Problem:** Dereferencing a null pointer. In Zig, `opt.?` panics at runtime.

```zig
// Unsafe Zig
var opt: ?*u32 = null;
const val = opt.?; // panic
```

**Zust mechanism:** Safe wrappers require explicit null handling. The `.?` operator is discouraged; `if (opt) |v|` is required.

```zig
var opt: ?Box(u32) = null;

// opt.? // compile-time convention: discouraged

if (opt) |box| {
    // use box
} else {
    return error.NullPointer;
}
```

`CheckedInt` and `CheckedPtr` add runtime bounds and null checks where compile-time analysis is insufficient.

**Comparison to Rust:** Rust's `Option<T>` requires explicit `match` or `if let`. There is no implicit unwrapping.

---

### 6. Iterator Invalidation

**Problem:** Modifying a collection while iterating over it, invalidating the iterator.

```zig
// Unsafe Zig
var list = std.ArrayList(u32).init(allocator);
for (list.items) |*item| {
    list.append(42); // iterator invalidated
}
```

**Zust mechanism:** Iterators hold an immutable borrow on the collection, freezing it during iteration. Alternatively, consuming iterators take ownership of each element.

```zig
var list = safe.ArrayList(u32).init(allocator);

// Iterator borrows immutably
var it = list.iterator();
while (it.next()) |box| {
    const dead = box.deinit();
    _ = dead;
}

// Or borrow the collection first:
const borrow = list.borrowImm();
// iterate without consuming
```

**Comparison to Rust:** Rust prevents mutation of a `Vec` while an iterator exists. Zust enforces the same rule: mutation methods require `mut_count == 0`, and the iterator holds a borrow.

---

### 7. Stack References Escaping

**Problem:** Returning a pointer to a local variable that is deallocated when the function returns.

```zig
// Unsafe Zig
fn getPtr() *u32 {
    var x: u32 = 42;
    return &x; // dangling pointer
}
```

**Zust mechanism:** The static analyzer tracks pointer provenance and flags escapes. `OffsetPtr` provides safe encapsulation for relative addressing. Heap allocation via `Box` is the standard approach for returned values.

```zig
fn getValue(allocator: std.mem.Allocator) !Box(u32) {
    return try Box(u32).init(allocator, 42);
}
```

**Comparison to Rust:** Rust's borrow checker rejects this with `returns a value referencing data owned by the current function`. Zust's analyzer provides equivalent detection.

---

## Comparison with Rust

| | Rust | Zust |
|---|---|---|
| **Mechanism** | Language-level borrow checker | Comptime typestate library |
| **Integration** | Must use Rust | Library in any Zig project |
| **Learning curve** | Lifetimes, traits, macros | Type threading |
| **Ecosystem** | Mature | New |
| **Runtime cost** | Zero | Zero |
| **Interop** | `unsafe` blocks | `unsafePtr()` escape hatch |
| **Error detection** | Compile time | Compile time (library) + static analysis |

Rust integrates safety at the language level with automatic inference. Zust implements the same rules as an explicit library. Both achieve zero-cost memory safety; the trade-off is language lock-in vs. incremental adoption.

---

## Remaining Gaps

### Interprocedural Tracking

The comptime library is intraprocedural. Cross-function pointer escape requires the zust-analyzer, which is a separate tool, not integrated into the Zig compiler.

### Raw Pointer Escape Hatches

`box.unsafePtr()` returns a raw `*T` for FFI and hardware access. Once extracted, the pointer is outside zust's guarantees.

### Complex Data Structures

Arrays of `Box` are difficult because each element's state transitions produce different types. `ArrayList` and `LinkedList` are provided as alternatives.

### Async/Concurrency

Async ownership tracking is limited compared to Rust's async lifetimes. `Mutex(T)` and `RwLock(T)` work for basic cases, but complex async state machines may require runtime checks.

### Typestate Verbosity

Complex codebases require threading ownership types through function signatures. Every borrow and release changes the type. Safety is guaranteed, but code volume increases.

### Runtime Panics

`RefCell`-style types use runtime borrow checking where compile-time analysis is insufficient. A double `borrowMut` panics at runtime. This is safe (no undefined behavior), but not zero-cost for those cases.

---

## Agent-Driven Migration

An AI agent can migrate an existing Zig codebase to zust using the three tools in sequence. The process is automated, auditable, and reversible.

### Step 1: Initialization

Run the setup script in the target project:

```bash
cd your-zig-project
/path/to/zust/scripts/init-zust.sh
```

This copies the zust library into the project's `lib/` directory and prints a `build.zig` snippet. The agent inserts the snippet and adds `safe` as an import to all modules.

### Step 2: Bulk Transpile

Run the transpiler on the entire project:

```bash
cd your-zig-project
/path/to/zust/scripts/migrate.sh
```

The script:
1. Finds all `.zig` files (excluding `zig-cache/` and `zig-out/`)
2. Runs `zust-analyze` to collect baseline diagnostics
3. Runs `zust-transpile` on each file
4. Writes transpiled files to `.zust-migrate/`
5. Generates `.zust-migrate/REPORT.md`

The agent reviews `REPORT.md` to see which files were modified and which patterns were replaced.

### Step 3: Apply and Verify

Copy transpiled files back to the source tree:

```bash
find .zust-migrate -name "*.zig" | while read f; do
    orig="${f#.zust-migrate/}"
    cp "$f" "$orig"
done
```

Then run the analyzer on the updated codebase:

```bash
/path/to/zust/zig-out/bin/zust-analyze ./src/
```

The agent reads the analyzer output and fixes remaining issues:
- Raw pointer escapes that the transpiler missed
- Ownership transitions that require manual threading
- Complex data structures that need `ArrayList` or `LinkedList` instead of arrays of `Box`
- Async or concurrent code that needs `Mutex` or `RwLock` wrappers

### Step 4: Iterate with LSP

Enable `zust-lsp` in the development environment. The agent writes to files; the LSP server pushes diagnostics in real time. The agent consumes these diagnostics and applies fixes incrementally.

This loop continues until the analyzer reports zero issues and the project compiles.

### What the Agent Handles Automatically

- Type substitutions: `std.ArrayList(T)` → `safe.ArrayList(T)`
- Allocation patterns: `allocator.create(T)` → `safe.Box(T).init(allocator, default)`
- Deallocation patterns: `allocator.destroy(ptr)` → capture `ptr.deinit()` return value
- Null unwraps: `opt.?` → `if (opt) |v| v else return error.NullPointer`
- Unchecked casts: `@intCast(T, val)` → `safe.CheckedInt(T).init(val)`
- Mutex usage: raw lock/unlock → `safe.Mutex(T)` with RAII guards

### What Requires Manual Review

- FFI boundaries where `unsafePtr()` escape hatches are needed
- Custom data structures with complex ownership graphs
- Performance-critical paths where the agent should verify zero-cost claims
- Async state machines with non-trivial borrow patterns

The migration is non-destructive. The original code remains in git history. The `.zust-migrate/` directory contains the full transpilation output and diagnostic logs for audit.

---

## Summary

Zust prevents the following at compile time with zero runtime overhead:

- Double-free
- Use-after-free
- Use-after-move
- Mutable aliasing
- Null pointer dereference
- Iterator invalidation
- Stack reference escapes

Mechanism: ownership state encoded in comptime type parameters, with invalid states producing compile errors. A companion static analyzer provides interprocedural analysis.

The approach demonstrates that memory safety guarantees equivalent to Rust's borrow checker can be implemented as a library using Zig's comptime system, without language modifications.

The gaps are known and bounded: interprocedural analysis requires a separate tool, escape hatches exist for FFI, complex data structures require alternative types, and some edge cases use runtime checking.

---

*[Zust](https://github.com/e-jerk/zust) is open source. Auto-transpile existing Zig code with `zust-transpile` or integrate `safe.Box` incrementally.*
