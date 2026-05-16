# Migrating to Zust — Agent Guide

> This guide is optimized for AI agents auto-migrating Zig projects. For human users, see README.md.

---

## Section 1: 30-Second Setup

### Prerequisites

- Zig 0.15+ installed
- zust cloned at `~/github.com/e-jerk/zust`

### Step 1: Run the init script

```bash
cd your-zig-project
/Users/barrett/github.com/e-jerk/zust/scripts/init-zust.sh
```

This prints a copy-paste snippet for your `build.zig`.

### Step 2: Copy-paste into build.zig

```zig
// --- zust integration ---
const safe_module = b.addModule("safe", .{
    .root_source_file = b.path("lib/safe.zig"),
});
```

Then after **every** `addExecutable`, `addTest`, or `createModule` call, add:

```zig
exe.root_module.addImport("safe", safe_module);
```

### Step 3: Copy the library

```bash
mkdir -p lib
cp /Users/barrett/github.com/e-jerk/zust/lib/safe.zig lib/
# Or all zust lib files if you need sub-modules
cp -r /Users/barrett/github.com/e-jerk/zust/lib/*.zig lib/
```

### Step 4: Verify

```bash
zig build
```

If it compiles, zust is integrated.

---

## Section 2: Type Mapping Cheat Sheet

Replace these types **everywhere** in your codebase:

| # | Was (Unsafe) | Use Instead (zust) | Notes |
|---|-------------|-------------------|-------|
| 1 | `std.ArrayList(T)` | `safe.ArrayList(T)` | Needs `allocator` in `deinit` |
| 2 | `std.StringHashMap(T)` | `safe.HashMap(safe.String, T)` | Keys are `safe.String`, not `[]const u8` |
| 3 | `std.AutoHashMap(K,V)` | `safe.HashMap(K, V)` | Generic over any key type |
| 4 | `std.Thread.Mutex` | `safe.Mutex(T)` | Wraps a value; must `lock()` before access |
| 5 | `std.Thread.RwLock` | `safe.RwLock(T)` | Writer-preference semantics |
| 6 | `allocator.create(T)` | `safe.Box(T,0,0,0).init(allocator, default)` | State tag `(0,0,0)` = fresh |
| 7 | `allocator.destroy(ptr)` | `defer _ = ptr.deinit()` | `.deinit()` returns dead state, must capture |
| 8 | `var x: i32;` (uninit) | `var x = safe.CheckedInt(i32).init(0);` | Or initialize to a real default |
| 9 | `opt.?` | `if (opt) \|v\| v else return error.Null` | Always check null; no `.?` |
| 10 | `while (true)` | `while (safe.Loop.withLimit(1_000_000))` | Or add a manual iteration counter |
| 11 | `const ptr = &local` | `safe.OffsetPtr.init(allocator, &local)` | No stack references escaping |
| 12 | `@intCast(T, val)` | `safe.CheckedInt(T).init(val)` | Runtime-checked cast |
| 13 | `std.mem.Allocator` | Same (pass through) | zust types take allocator explicitly |
| 14 | `defer list.deinit()` | `defer list.deinit(allocator)` | zust collections need allocator on cleanup |
| 15 | `list.append(x)` | `list.append(allocator, x)` | Most zust collections need allocator for ops |

---

## Section 3: Auto-Transpile Your Project

### Full-project migration

```bash
cd your-zig-project
/Users/barrett/github.com/e-jerk/zust/scripts/migrate.sh
```

This will:
1. Find all `.zig` files (excluding `zig-cache/`, `zig-out/`)
2. Run `zust-analyze` to collect diagnostics
3. Run `zust-transpile` on each file → writes to `.zust-migrate/`
4. Generate `.zust-migrate/REPORT.md`

### Review before applying

```bash
cat .zust-migrate/REPORT.md        # Summary and file list
cat .zust-migrate/diagnostics.txt  # Full analyzer output
```

### Apply transpiled files

```bash
# Copy all transpiled files back to project
find .zust-migrate -name "*.zig" | while read f; do
    orig="${f#.zust-migrate/}"
    cp "$f" "$orig"
done
```

Or use `rsync` for directories:

```bash
rsync -av .zust-migrate/src/ src/
```

### Single-file transpile

```bash
# Build the transpiler
cd /Users/barrett/github.com/e-jerk/zust
zig build transpile

# Run on one file
./zig-out/bin/zust-transpile src/main.zig src/main_safe.zig
```

---

## Section 4: Manual Migration Checklist

Use this when auto-transpile misses something (or for new code).

### Step 1: Fix imports

Every file that uses zust needs:

```zig
const safe = @import("safe");
```

### Step 2: Replace types

Go through the [Type Mapping Cheat Sheet](#section-2-type-mapping-cheat-sheet) top to bottom.

Search-and-replace order matters:
1. `std.ArrayList(` → `safe.ArrayList(`
2. `std.StringHashMap(` → `safe.HashMap(safe.String, `
3. `allocator.create(` → `safe.Box(T,0,0,0).init(allocator, `
4. `allocator.destroy(` → `_ = .deinit()` (manual review needed)
5. `opt.?` → `if (opt) |v| v else ...`

### Step 3: Fix deinit patterns

**Before:**
```zig
var list = std.ArrayList(u32).init(allocator);
defer list.deinit();
```

**After:**
```zig
var list = safe.ArrayList(u32).init(allocator);
defer list.deinit(allocator);
```

**Before:**
```zig
var box = try allocator.create(u32);
defer allocator.destroy(box);
```

**After:**
```zig
var box = try safe.Box(u32, 0, 0, 0).init(allocator, 0);
const dead = box.deinit();
_ = dead;
```

### Step 4: Fix append/insert patterns

**Before:**
```zig
try list.append(42);
try map.put("key", value);
```

**After:**
```zig
try list.append(allocator, 42);
try map.put(allocator, "key", value);
```

### Step 5: Fix optional unwrapping

**Before:**
```zig
const val = opt.?;
```

**After:**
```zig
const val = if (opt) |v| v else return error.NullPointer;
```

Or with a default:
```zig
const val = opt orelse 0;
```

### Step 6: Fix mutex usage

**Before:**
```zig
var mtx: std.Thread.Mutex = .{};
mtx.lock();
// ... access shared data ...
mtx.unlock();
```

**After:**
```zig
var mtx = try safe.Mutex(u32).init(allocator, 0);
defer mtx.deinit();

// Option A: manual lock/unlock
mtx.lock();
mtx.getMut().* = 42;
mtx.unlock();

// Option B: RAII guard (preferred)
const guard = mtx.acquire();
guard.getMut().* = 42;
guard.deinit(); // auto-unlock
```

### Step 7: Verify with analyzer

```bash
cd /Users/barrett/github.com/e-jerk/zust
./zig-out/bin/zust-analyze /path/to/your/project/src/
```

No errors = ready.

---

## Section 5: Common Pitfalls

### Pitfall 1: `defer` needs allocator

zust collections store the allocator in the struct, but some operations still require passing it explicitly.

**Wrong:**
```zig
var list = safe.ArrayList(u32).init(allocator);
defer list.deinit(); // ❌ missing allocator
```

**Right:**
```zig
var list = safe.ArrayList(u32).init(allocator);
defer list.deinit(allocator); // ✅
```

### Pitfall 2: Iterators consume elements

zust iterators take ownership of elements when you iterate. This prevents iterator invalidation but changes semantics.

**Before:**
```zig
var it = list.iterator();
while (it.next()) |item| {
    // item is a pointer to list's internal storage
}
// list still has all items
```

**After:**
```zig
var it = list.iterator();
while (it.next()) |box| {
    // box is owned by you now — removed from list!
    const dead = box.deinit();
    _ = dead;
}
// list is now empty
```

If you need non-consuming iteration, use `borrowImm` on the collection first.

### Pitfall 3: Box deinit returns a new type

You **must** capture the return value of `.deinit()`.

**Wrong:**
```zig
box.deinit(); // ❌ return value discarded — use-after-free possible
```

**Right:**
```zig
const dead = box.deinit();
_ = dead; // ✅ dead is Freed state, can't be used again
```

### Pitfall 4: `safe.String` vs `[]const u8`

`safe.String` is a growable buffer. For string literals, you can use `[]const u8` directly, but for map keys or stored strings, use `safe.String`.

**Wrong:**
```zig
var map = safe.HashMap([]const u8, u32).init(allocator); // ❌
```

**Right:**
```zig
var map = safe.HashMap(safe.String, u32).init(allocator); // ✅
```

### Pitfall 5: Cannot move a `Pin`

Pinned values cannot be moved. They must stay at the same memory address.

**Wrong:**
```zig
var pin = safe.Pin(u32).init(box);
var moved = pin; // ❌ compile error
```

### Pitfall 6: `OnceCell` can only be set once

**Wrong:**
```zig
var cell = safe.OnceCell(u32).init();
try cell.set(42);
try cell.set(100); // ❌ panic: AlreadyInitialized
```

### Pitfall 7: `RefCell` borrow at runtime

`RefCell` checks borrows at runtime (not compile time). A second `borrowMut` will panic.

```zig
var rc = safe.RefCell(u32).init(42);
const b1 = rc.borrowMut();
// const b2 = rc.borrowMut(); // ❌ panic!
b1.deinit();
```

### Pitfall 8: Arrays of `Box` are tricky

Each `Box` state transition produces a different type, so arrays of `Box` are hard. Use `safe.ArrayList(T)` or `safe.LinkedList(T)` instead.

**Wrong:**
```zig
var boxes: [3]safe.Box(u32, 0, 0, 0) = ...;
// Can't change state of one element independently
```

**Right:**
```zig
var list = safe.ArrayList(u32).init(allocator);
try list.append(allocator, try safe.Box(u32, 0, 0, 0).init(allocator, 1));
try list.append(allocator, try safe.Box(u32, 0, 0, 0).init(allocator, 2));
```

---

## Quick Reference

```zig
const safe = @import("safe");
const Box = safe.Box;
const ArrayList = safe.ArrayList;
const HashMap = safe.HashMap;
const String = safe.String;
const Mutex = safe.Mutex;

// Ownership
var box = try Box(u32, 0, 0, 0).init(allocator, 42);
const b1 = box.borrowImm();
const box_back = b1.releaseImm();
const dead = box_back.deinit();
_ = dead;

// Collections
var list = ArrayList(u32).init(allocator);
defer list.deinit(allocator);
try list.append(allocator, try Box(u32, 0, 0, 0).init(allocator, 10));

// String
var s = String.init(allocator);
defer s.deinit();
try s.append("hello");

// Mutex
var mtx = try Mutex(u32).init(allocator, 0);
defer mtx.deinit();
const guard = mtx.acquire();
guard.getMut().* = 42;
guard.deinit();
```
