# zust

[![CI](https://github.com/e-jerk/zust/actions/workflows/ci.yml/badge.svg)](https://github.com/e-jerk/zust/actions/workflows/ci.yml)
[![Release](https://github.com/e-jerk/zust/actions/workflows/release.yml/badge.svg)](https://github.com/e-jerk/zust/releases)

**Zero-cost ownership and memory safety for Zig via comptime typestate.**

Zust ("Zig + Rust") brings Rust's ownership model to Zig — a comptime library that prevents double-free, use-after-free, and mutable aliasing at compile time, with zero runtime overhead. Includes a companion static analyzer with LSP server for real-time IDE diagnostics.

```
┌─────────────────────────────────────────┐
│  zust = Zig + Rust ownership model      │
│  Zero-cost • Compile-time • No GC       │
└─────────────────────────────────────────┘
```

## Two-Layer Architecture

### Layer 1: Comptime Library (`lib/`)
A pure Zig library that encodes ownership state in type parameters. Zero runtime cost. All violations become `@compileError`.

- **`Box(T, state_tag, imm_count, mut_count)`** — Owned heap value with typestate transitions
- **`LinkedList(T)`** — Safe linked list built on `Box`
- **Closure API** — `withImm`/`withMut` for zero-cost lexical borrows
- **Explicit API** — `borrowImm`/`borrowMut`/`releaseImm`/`releaseMut` for cross-function borrows

### Layer 2: Static Analyzer (`analyzer/`)
A standalone tool for general-purpose analysis that dog-foods the library.

- **Intraprocedural** pointer provenance tracking (Box, raw pointers, borrows)
- **Pattern detection**: flags raw `*T`/`[]T` usage and suggests `safe.Box`
- **SARIF 2.1.0** output for CI integration
- **LSP server mode** with `textDocument/publishDiagnostics`

## Project Statistics

```
Library types:        52 files (50 types + safe.zig)
Tests:                462/462 passing
  - Library tests:   348
  - SIMD tests:      47
  - Fuzz tests:      4
  - Analyzer tests:  63
Analyzer detections:  30 bug classes
SIMD speedups:        up to 15x on bulk operations
Examples:             2 (HTTP server, JSON parser)
Tools:                2 (transpiler, CLI analyzer)
LSP features:         6 (diagnostics, completion, go-to-def, hover, code actions, incremental sync)
CI targets:           5 cross-compile + 3 native
```

## Quick Start

### Using the Library

```zig
const safe = @import("safe");
const Box = safe.Box;

// Create an owned value
const box = try Box(u32, 0, 0, 0).init(allocator, 42);

// Immutable borrow
const b1 = box.borrowImm();
const b2 = b1.borrowImm();
const b1_back = b2.releaseImm();
const box_back = b1_back.releaseImm();

// Deallocate (returns new state, must capture)
const dead = box_back.deinit();
_ = dead;
```

### Closure API

```zig
const box = try Box(u32, 0, 0, 0).init(allocator, 42);
var sum: u32 = 0;
box.withImm(&sum, struct {
    fn f(ctx: *u32, val: *const u32) void {
        ctx.* += val.*;
    }
}.f);
const dead = box.deinit();
_ = dead;
```

### Compile-Time Error Examples

```zig
// Double free
const dead = box.deinit();
const dead2 = dead.deinit(); // @compileError: "double free detected"

// Mutable aliasing
const b1 = box.borrowMut();
const b2 = box.borrowMut(); // @compileError: use of moved value

// Free with active borrows
const borrowed = box.borrowImm();
const dead = box.deinit(); // @compileError: "cannot free while active borrows exist"
```

## Rust Equivalents

Every zust type maps directly to a Rust `std` type. If you know Rust, you already know zust.

### Ownership Primitives

#### `Box<T>` → `Box(T)`

```rust
// Rust
let b = Box::new(42);
drop(b);
```

```zig
// zust
const b = try Box(u32, 0, 0, 0).init(allocator, 42);
const dead = b.deinit();
_ = dead;
```

#### `Rc<T>` → `Rc(T)`

```rust
// Rust
let rc = Rc::new(42);
let rc2 = Rc::clone(&rc);
drop(rc);
assert_eq!(Rc::strong_count(&rc2), 1);
```

```zig
// zust
var rc = try Rc(u32).init(allocator, 42);
var rc2 = rc.clone();
rc.drop();
try std.testing.expectEqual(rc2.strongCount(), 1);
rc2.drop();
```

#### `Arc<T>` → `Arc(T)`

```rust
// Rust
let arc = Arc::new(42);
let arc2 = Arc::clone(&arc);
```

```zig
// zust
var arc = try Arc(u32).init(allocator, 42);
var arc2 = arc.clone();
```

#### `Weak<T>` → `Weak(T)`

```rust
// Rust
let weak = Arc::downgrade(&arc);
if let Some(arc2) = weak.upgrade() { ... }
```

```zig
// zust
var weak = arc.downgrade();
if (weak.upgrade()) |arc2| { ... }
```

### Thread Safety

#### `Mutex<T>` → `Mutex(T)`

```rust
// Rust
let mtx = Mutex::new(0);
*mtx.lock().unwrap() = 42;
```

```zig
// zust
var mtx = try Mutex(u32).init(allocator, 0);
mtx.lock();
mtx.getMut().* = 42;
mtx.unlock();

// Or with RAII guard:
const guard = mtx.acquire();
guard.getMut().* = 42;
guard.deinit(); // auto-unlock
```

#### `RwLock<T>` → `RwLock(T)`

```rust
// Rust
let rw = RwLock::new(42);
let read_guard = rw.read().unwrap();
```

```zig
// zust
var rw = try RwLock(u32).init(allocator, 42);
rw.readLock();
try std.testing.expectEqual(rw.get().*, 42);
rw.readUnlock();
```

### Interior Mutability

#### `Cell<T>` → `Cell(T)`

```rust
// Rust
let cell = Cell::new(42);
cell.set(100);
```

```zig
// zust
var cell = Cell(u32).init(42);
cell.set(100);
```

#### `RefCell<T>` → `RefCell(T)`

```rust
// Rust
let rc = RefCell::new(42);
let b = rc.borrow();
let b2 = rc.borrow_mut(); // panic at runtime
```

```zig
// zust
var rc = RefCell(u32).init(42);
const b = rc.borrow();
// const b2 = rc.borrowMut(); // panic at runtime
b.deinit();
```

#### `UnsafeCell<T>` → `UnsafeCell(T)`

```rust
// Rust
let uc = UnsafeCell::new(42);
let ptr = uc.get();
```

```zig
// zust
var uc = UnsafeCell(u32).init(42);
const ptr = uc.getMut();
```

### Low-Level Primitives

#### `ManuallyDrop<T>` → `ManuallyDrop(T)`

```rust
// Rust
let md = ManuallyDrop::new(Box::new(42));
ManuallyDrop::drop(&mut md);
```

```zig
// zust
var md = ManuallyDrop(u32).init(42);
md.drop();
```

#### `MaybeUninit<T>` → `MaybeUninit(T)`

```rust
// Rust
let mut mu = MaybeUninit::<u32>::uninit();
mu.write(42);
let val = unsafe { mu.assume_init() };
```

```zig
// zust
var mu = MaybeUninit(u32).init();
mu.write(42);
const val = mu.assumeInit();
```

#### `Pin<Box<T>>` → `Pin(T)`

```rust
// Rust
let pin = Box::pin(42);
*pin.as_mut().get_mut() = 100;
```

```zig
// zust
var pin = try Pin(u32).init(try Box(u32, 0, 0, 0).init(allocator, 42));
pin.getMut().* = 100;
const dead = pin.deinit();
_ = dead;
```

#### `PhantomData<T>` → `PhantomData(T)`

```rust
// Rust
struct MyPtr<T> { ptr: *mut u8, _phantom: PhantomData<T> }
```

```zig
// zust
const PhantomU32 = PhantomData(u32);
var marker = PhantomU32.init();
```

### Lazy Initialization

#### `std::sync::OnceLock<T>` → `OnceCell(T)`

```rust
// Rust
static CELL: OnceLock<u32> = OnceLock::new();
CELL.set(42).unwrap();
```

```zig
// zust
var cell = OnceCell(u32).init();
try cell.set(42);
```

#### `std::cell::LazyCell<T>` → `LazyCell(T)`

```rust
// Rust
let lazy: LazyCell<u32> = LazyCell::new(|| 42);
*lazy.borrow_mut() = 100;
```

```zig
// zust
var lazy = LazyCell(u32).init(struct {
    fn init() u32 { return 42; }
}.init);
_ = lazy.getMut().* = 100;
```

### Collections

#### `Vec<T>` → `ArrayList(T)`

```rust
// Rust
let mut v = Vec::new();
v.push(10);
v.push(20);
```

```zig
// zust
var list = ArrayList(u32).init(allocator);
defer list.deinit();
try list.append(try Box(u32, 0, 0, 0).init(allocator, 10));
try list.append(try Box(u32, 0, 0, 0).init(allocator, 20));
```

#### `VecDeque<T>` → `VecDeque(T)`

```rust
// Rust
let mut dq = VecDeque::new();
dq.push_back(10);
dq.push_front(5);
```

```zig
// zust
var dq = try VecDeque(u32).init(allocator);
defer dq.deinit();
try dq.pushBack(try Box(u32, 0, 0, 0).init(allocator, 10));
try dq.pushFront(try Box(u32, 0, 0, 0).init(allocator, 5));
```

#### `LinkedList<T>` → `LinkedList(T)`

```rust
// Rust
let mut list = LinkedList::new();
list.push_front(10);
```

```zig
// zust
var list = LinkedList(u32).init(allocator);
defer list.deinit();
try list.push(10);
```

#### `HashMap<K,V>` → `HashMap(T)`

```rust
// Rust
let mut map = HashMap::new();
map.insert("key", 42);
```

```zig
// zust
var map = HashMap(u32).init(allocator);
defer map.deinit();
try map.put("key", try Box(u32, 0, 0, 0).init(allocator, 42));
```

#### `BTreeMap<K,V>` → `BTreeMap(T)`

```rust
// Rust
let mut map = BTreeMap::new();
map.insert(1, 42);
```

```zig
// zust
var map = BTreeMap(u32).init(allocator);
defer map.deinit();
try map.put(1, try Box(u32, 0, 0, 0).init(allocator, 42));
```

#### `HashSet<T>` → `HashSet(T)`

```rust
// Rust
let mut set = HashSet::new();
set.insert(42);
```

```zig
// zust
var set = HashSet.init(allocator);
defer set.deinit();
try set.insert(42);
```

#### `BinaryHeap<T>` → `BinaryHeap(T)`

```rust
// Rust
let mut heap = BinaryHeap::new();
heap.push(42);
let max = heap.pop().unwrap();
```

```zig
// zust
var heap = try BinaryHeap(u32).init(allocator, struct {
    fn cmp(_: void, a: *const u32, b: *const u32) bool { return a.* > b.*; }
}.cmp);
try heap.push(try Box(u32, 0, 0, 0).init(allocator, 42));
const max = heap.pop().?;
```

### String Types

#### `String` → `String`

```rust
// Rust
let mut s = String::new();
s.push_str("hello");
```

```zig
// zust
var s = String.init(allocator);
defer s.deinit();
try s.append("hello");
```

#### `Cow<'a, str>` → `Cow([]const u8)`

```rust
// Rust
let cow: Cow<'_, str> = Cow::Borrowed("hello");
let owned = cow.into_owned();
```

```zig
// zust
var cow = Cow([]const u8).initBorrowed("hello");
var owned = try cow.toOwned(allocator);
```

### Slices & Borrowing

#### `&[T]` / `&mut [T]` → `Slice(T)`

```rust
// Rust
let arr = [10, 20, 30];
let s: &[u32] = &arr;
```

```zig
// zust
const arr = [_]u32{ 10, 20, 30 };
const s = Slice(u32).fromStack(&arr);
s.release();
```

#### Scope Guards

```rust
// Rust (non-lexical lifetimes via drop)
{
    let b = Box::new(42);
    // b dropped here
}
```

```zig
// zust
{
    const box = try Box(u32, 0, 0, 0).init(allocator, 42);
    const borrowed = ScopeImm(u32).borrow(box);
    _ = borrowed.scope.release();
    const dead = box.deinit();
    _ = dead;
}
```

### Async

#### `AsyncBox<T>` → Async-safe Box

```zig
// zust
var abox = try AsyncBox(u32).init(allocator, 42);
const box = abox.take().?;
const dead = box.deinit();
_ = dead;
```

### Channels

#### `mpsc::channel<T>` → `Channel(T)`

```rust
// Rust
let (tx, rx) = mpsc::channel::<u32>();
tx.send(42).unwrap();
let val = rx.recv().unwrap();
```

```zig
// zust
var ch = try Channel(u32).init(allocator, 4);
defer ch.deinit();
try ch.send(42);
const val = ch.recv().?;
```

#### `oneshot::channel<T>` → `Oneshot(T)`

```rust
// Rust
let (tx, rx) = oneshot::channel::<u32>();
tx.send(42).unwrap();
```

```zig
// zust
var os = Oneshot(u32).init();
try os.send(42);
const val = os.recv().?;
```

### Iterators

zust provides iterator adapters and consumers inspired by Rust's `Iterator` trait. Unlike Rust's chained `.map().filter().collect()`, Zig's comptime generics require explicit type instantiation. All adapters are zero-cost — they compile down to simple loops.

#### Adapter: `MapIter`

Transform each element.

```rust
// Rust
let doubled: Vec<i32> = vec![1, 2, 3]
    .iter()
    .map(|x| x * 2)
    .collect();
```

```zig
// zust
const Iterators = safe.Iterators;

var range = Iterators.RangeIter(u32).init(1, 4);
var mapped = Iterators.MapIter(
    Iterators.RangeIter(u32), // source iterator type
    u32,                      // context type
    u32,                      // input item type
    u32                       // output item type
).init(range, 2, struct {
    fn f(ctx: u32, val: u32) u32 {
        return val * ctx;
    }
}.f);

try std.testing.expectEqual(mapped.next().?, 2);  // 1 * 2
try std.testing.expectEqual(mapped.next().?, 4);  // 2 * 2
try std.testing.expectEqual(mapped.next().?, 6);  // 3 * 2
try std.testing.expect(mapped.next() == null);
```

#### Adapter: `FilterIter`

Keep only elements matching a predicate.

```rust
// Rust
let evens: Vec<i32> = vec![0, 1, 2, 3, 4, 5]
    .into_iter()
    .filter(|x| x % 2 == 0)
    .collect();
```

```zig
// zust
var range = Iterators.RangeIter(u32).init(0, 6);
var filtered = Iterators.FilterIter(
    Iterators.RangeIter(u32),
    void,   // no context needed
    u32
).init(range, {}, struct {
    fn f(_: void, val: *const u32) bool {
        return val.* % 2 == 0;
    }
}.f);

try std.testing.expectEqual(filtered.next().?, 0);
try std.testing.expectEqual(filtered.next().?, 2);
try std.testing.expectEqual(filtered.next().?, 4);
try std.testing.expect(filtered.next() == null);
```

#### Adapter: `EnumerateIter`

Yield `(index, value)` pairs.

```rust
// Rust
for (i, val) in vec!["a", "b", "c"].iter().enumerate() {
    println!("{}: {}", i, val);
}
```

```zig
// zust
const items = [_][]const u8{ "a", "b", "c" };
var slice_it = Iterators.SliceIter([]const u8).init(&items);
var enumerated = Iterators.EnumerateIter(
    Iterators.SliceIter([]const u8),
    []const u8
).init(slice_it);

const first = enumerated.next().?;
try std.testing.expectEqual(first.index, 0);
try std.testing.expect(std.mem.eql(u8, first.value, "a"));

const second = enumerated.next().?;
try std.testing.expectEqual(second.index, 1);
try std.testing.expect(std.mem.eql(u8, second.value, "b"));
```

#### Adapter: `TakeIter`

Take only the first N elements.

```rust
// Rust
let first_3: Vec<i32> = vec![1, 2, 3, 4, 5]
    .into_iter()
    .take(3)
    .collect();
```

```zig
// zust
var range = Iterators.RangeIter(u32).init(0, 100);
var taken = Iterators.TakeIter(Iterators.RangeIter(u32), u32).init(range, 3);

try std.testing.expectEqual(taken.next().?, 0);
try std.testing.expectEqual(taken.next().?, 1);
try std.testing.expectEqual(taken.next().?, 2);
try std.testing.expect(taken.next() == null);
```

#### Adapter: `SkipIter`

Skip the first N elements.

```rust
// Rust
let rest: Vec<i32> = vec![1, 2, 3, 4, 5]
    .into_iter()
    .skip(2)
    .collect();
```

```zig
// zust
var range = Iterators.RangeIter(u32).init(0, 6);
var skipped = Iterators.SkipIter(Iterators.RangeIter(u32), u32).init(range, 3);

try std.testing.expectEqual(skipped.next().?, 3);
try std.testing.expectEqual(skipped.next().?, 4);
try std.testing.expectEqual(skipped.next().?, 5);
try std.testing.expect(skipped.next() == null);
```

#### Adapter: `ChainIter`

Concatenate two iterators.

```rust
// Rust
let chained: Vec<i32> = vec![1, 2, 3]
    .into_iter()
    .chain(vec![10, 11, 12])
    .collect();
```

```zig
// zust
const first = Iterators.RangeIter(u32).init(0, 3);
const second = Iterators.RangeIter(u32).init(10, 13);
var chained = Iterators.ChainIter(
    Iterators.RangeIter(u32),
    Iterators.RangeIter(u32),
    u32
).init(first, second);

try std.testing.expectEqual(chained.next().?, 0);
try std.testing.expectEqual(chained.next().?, 1);
try std.testing.expectEqual(chained.next().?, 2);
try std.testing.expectEqual(chained.next().?, 10);
try std.testing.expectEqual(chained.next().?, 11);
try std.testing.expectEqual(chained.next().?, 12);
try std.testing.expect(chained.next() == null);
```

#### Adapter: `ZipIter`

Pair elements from two iterators.

```rust
// Rust
let pairs: Vec<(i32, &str)> = vec![1, 2, 3]
    .into_iter()
    .zip(vec!["a", "b", "c"])
    .collect();
```

```zig
// zust
const nums = Iterators.RangeIter(u32).init(1, 4);
const letters = Iterators.SliceIter(u8).init("abc");
var zipped = Iterators.ZipIter(
    Iterators.RangeIter(u32),
    Iterators.SliceIter(u8),
    u32,
    u8
).init(nums, letters);

const first = zipped.next().?;
try std.testing.expectEqual(first.first, 1);
try std.testing.expectEqual(first.second, 'a');

const second = zipped.next().?;
try std.testing.expectEqual(second.first, 2);
try std.testing.expectEqual(second.second, 'b');
```

#### Consumer: `fold`

Reduce to a single value.

```rust
// Rust
let sum: i32 = vec![1, 2, 3, 4].iter().fold(0, |acc, x| acc + x);
let product: i32 = vec![1, 2, 3, 4].iter().fold(1, |acc, x| acc * x);
```

```zig
// zust
var range = Iterators.RangeIter(u32).init(1, 5);
const total = Iterators.fold(
    Iterators.RangeIter(u32), u32, u32,
    &range,
    0,                    // initial accumulator
    {},                   // no context
    struct {              // reducer function
        fn f(_: void, acc: u32, val: u32) u32 {
            return acc + val;
        }
    }.f
);
try std.testing.expectEqual(total, 10); // 1+2+3+4
```

#### Consumer: `collectArrayList`

Gather all elements into a `std.ArrayList`.

```rust
// Rust
let collected: Vec<i32> = (0..3).collect();
```

```zig
// zust
var range = Iterators.RangeIter(u32).init(0, 3);
var list = try Iterators.collectArrayList(
    Iterators.RangeIter(u32), u32,
    &range,
    std.testing.allocator
);
defer list.deinit(std.testing.allocator);

try std.testing.expectEqual(list.items.len, 3);
try std.testing.expectEqual(list.items[0], 0);
try std.testing.expectEqual(list.items[1], 1);
try std.testing.expectEqual(list.items[2], 2);
```

#### Consumer: `find` / `position` / `all` / `any`

Search and test predicates.

```rust
// Rust
let found = vec![1, 2, 3, 4].iter().find(|x| x > 2);
let idx = vec![10, 20, 30].iter().position(|x| x == 20);
let all_positive = vec![1, 2, 3].iter().all(|x| x > 0);
let any_big = vec![1, 2, 3].iter().any(|x| x > 10);
```

```zig
// zust
var range = Iterators.RangeIter(u32).init(1, 6);
const found = Iterators.find(
    Iterators.RangeIter(u32), u32, &range, {},
    struct { fn f(_: void, val: *const u32) bool { return val.* > 2; } }.f
);
try std.testing.expectEqual(found.?, 3);

var range2 = Iterators.RangeIter(u32).init(10, 16);
const idx = Iterators.position(
    Iterators.RangeIter(u32), u32, &range2, {},
    struct { fn f(_: void, val: *const u32) bool { return val.* == 13; } }.f
);
try std.testing.expectEqual(idx.?, 3);

var range3 = Iterators.RangeIter(u32).init(1, 4);
const all_positive = Iterators.all(
    Iterators.RangeIter(u32), u32, &range3, {},
    struct { fn f(_: void, val: *const u32) bool { return val.* > 0; } }.f
);
try std.testing.expect(all_positive);
```

#### Consumer: `sum` / `min` / `max`

Numeric aggregation.

```rust
// Rust
let total: i32 = vec![1, 2, 3, 4].iter().sum();
let smallest = vec![5, 2, 8, 1].iter().min();
let largest = vec![5, 2, 8, 1].iter().max();
```

```zig
// zust
var range = Iterators.RangeIter(u32).init(1, 5);
const total = Iterators.sum(Iterators.RangeIter(u32), u32, &range);
try std.testing.expectEqual(total, 10);

var vals = [_]u32{ 5, 2, 8, 1 };
var slice_it = Iterators.SliceIter(u32).init(&vals);
const smallest = Iterators.min(
    Iterators.SliceIter(u32), u32, &slice_it, {},
    struct { fn f(_: void, a: *const u32, b: *const u32) bool { return a.* < b.*; } }.f
);
try std.testing.expectEqual(smallest.?, 1);
```

#### Iterator Bug: Iterator Invalidation

```zig
// WITHOUT zust: Iterator invalidation
fn bad_iterator() void {
    var list = std.ArrayList(u32).init(std.testing.allocator);
    defer list.deinit();
    try list.append(1);
    try list.append(2);
    var it = list.iterator();
    _ = list.pop(); // 💥 INVALIDATES iterator
    const val = it.next(); // UB: iterator points to freed/relocated memory
    _ = val;
}
```

```zig
// WITH zust: Consuming iterators prevent invalidation
fn safe_iterator() void {
    var list = ArrayList(u32).init(std.testing.allocator);
    defer list.deinit();
    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 1));
    try list.append(try Box(u32, 0, 0, 0).init(std.testing.allocator, 2));

    var it = list.iterator();
    const first = it.next(); // ✅ Pops from list, takes ownership
    if (first) |box| {
        const dead = box.deinit();
        _ = dead;
    }
    // list is now empty; no invalidation possible
}
```

### Utility Functions

#### `std::mem::replace` / `std::mem::swap` / `std::mem::take`

```rust
// Rust
let old = std::mem::replace(&mut x, 100);
std::mem::swap(&mut a, &mut b);
let val = std::mem::take(&mut x); // requires Default
```

```zig
// zust
const old = safe.replace(u32, &x, 100);
safe.swap(u32, &a, &b);
const val = safe.take(u32, &x);
```

#### `todo!()` / `unreachable!()`

```rust
// Rust
todo!("implement this");
unreachable!();
```

```zig
// zust
safe.todo("implement this");
safe.unreachable_code();
```

## Practical Safety Examples

For every zust type, here's what goes wrong without it — and how zust prevents the bug.

### Ownership & Memory Management

#### Box — Preventing Double-Free

```zig
// WITHOUT zust: Double-free crash
fn bad_double_free() void {
    const ptr = std.testing.allocator.create(u32) catch return;
    ptr.* = 42;
    std.testing.allocator.destroy(ptr);
    std.testing.allocator.destroy(ptr); // 💥 CRASH: double-free
}
```

```zig
// WITH zust: Compile-time prevention
fn safe_with_box() void {
    const box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    const dead = box.deinit();
    // const dead2 = dead.deinit(); // ❌ @compileError: "double free detected"
    _ = dead;
}
```

#### Box — Preventing Use-After-Free

```zig
// WITHOUT zust: Use-after-free bug
fn bad_uaf() void {
    var ptr = std.testing.allocator.create(u32) catch return;
    ptr.* = 42;
    std.testing.allocator.destroy(ptr);
    std.debug.print("{d}\n", .{ptr.*}); // 💥 UAF: reading freed memory
}
```

```zig
// WITH zust: Compile-time prevention
fn safe_no_uaf() void {
    const box = try Box(u32, 0, 0, 0).init(std.testing.allocator, 42);
    const dead = box.deinit();
    // dead.ptr.* = 100; // ❌ @compileError: use of moved value
    _ = dead;
}
```

#### Rc — Preventing Use-After-Drop

```zig
// WITHOUT zust: Dangling reference after drop
fn bad_rc() void {
    const ptr = std.testing.allocator.create(u32) catch return;
    ptr.* = 42;
    var ptr2 = ptr; // "shared" ownership (not really)
    std.testing.allocator.destroy(ptr); // first owner frees
    ptr2.* = 100; // 💥 UAF: ptr2 is dangling
}
```

```zig
// WITH zust: Reference counting prevents premature drop
fn safe_rc() void {
    var rc = try Rc(u32).init(std.testing.allocator, 42);
    var rc2 = rc.clone(); // strong count = 2
    rc.drop();            // strong count = 1, NOT freed
    rc2.getMut().* = 100; // ✅ Safe: rc2 still owns it
    rc2.drop();           // strong count = 0, now freed
}
```

### Thread Safety

#### Mutex — Preventing Data Races

```zig
// WITHOUT zust: Data race
var global_counter: u32 = 0;

fn bad_race() void {
    global_counter += 1; // 💥 DATA RACE if called from multiple threads
}
```

```zig
// WITH zust: Compile-time error if accessed without lock
fn safe_mutex() void {
    var mtx = try Mutex(u32).init(std.testing.allocator, 0);
    defer mtx.deinit();

    // mtx.getMut().* = 100; // ❌ Runtime: must call lock() first

    mtx.lock();
    mtx.getMut().* += 1; // ✅ Safe: lock held
    mtx.unlock();        // Explicit unlock
}
```

#### Mutex — Preventing Deadlock

```zig
// WITHOUT zust: Accidental deadlock
fn bad_deadlock() void {
    var mtx: std.Thread.Mutex = .{};
    mtx.lock();
    // ... forget to unlock ...
    mtx.lock(); // 💥 DEADLOCK: already locked
}
```

```zig
// WITH zust: Analyzer detects double-lock
fn safe_no_deadlock() void {
    var mtx = try Mutex(u32).init(std.testing.allocator, 0);
    defer mtx.deinit();
    mtx.lock();
    // mtx.lock(); // ❌ Analyzer: "locking already-locked Mutex"
    mtx.unlock();
}
```

### Interior Mutability

#### RefCell — Preventing Aliasing Violations

```zig
// WITHOUT zust: Mutable aliasing
fn bad_aliasing() void {
    var x: u32 = 42;
    const p1 = &x;
    const p2 = &x;
    p1.* = 100;
    p2.* = 200; // 💥 UNDEFINED BEHAVIOR: two mutable pointers
}
```

```zig
// WITH zust: Runtime borrow checking
fn safe_refcell() void {
    var rc = RefCell(u32).init(42);
    const b1 = rc.borrowMut();
    // const b2 = rc.borrowMut(); // ❌ Panic: already borrowed mutably
    b1.deinit();
}
```

### Lazy Initialization

#### OnceCell — Preventing Double-Initialization

```zig
// WITHOUT zust: Race condition on initialization
var initialized: bool = false;
var value: u32 = 0;

fn bad_init() void {
    if (!initialized) {
        value = 42;      // 💥 RACE: two threads could both enter here
        initialized = true;
    }
}
```

```zig
// WITH zust: Panic on double set
fn safe_once() void {
    var cell = OnceCell(u32).init();
    try cell.set(42);     // ✅ First set succeeds
    // try cell.set(100); // ❌ Panic: "AlreadyInitialized"
    const v = cell.get().?.*; // ✅ Safe: guaranteed initialized
    _ = v;
}
```

### Low-Level Memory

#### ManuallyDrop — Preventing Memory Leaks

```zig
// WITHOUT zust: Memory leak
fn bad_leak() void {
    const ptr = std.testing.allocator.create(u32) catch return;
    ptr.* = 42;
    // forget to free... 💥 LEAK
}
```

```zig
// WITH zust: Analyzer detects missing drop
fn safe_manual_drop() void {
    var md = ManuallyDrop(u32).init(42);
    // md.drop(); // ❌ Analyzer at end-of-function: "ManuallyDrop not dropped"
    md.drop();     // ✅ Explicit drop required
}
```

#### MaybeUninit — Preventing Undefined Behavior

```zig
// WITHOUT zust: Reading uninitialized memory
fn bad_uninit() void {
    var x: u32 = undefined;
    std.debug.print("{d}\n", .{x}); // 💥 UB: reading undefined value
}
```

```zig
// WITH zust: Must write before read
fn safe_uninit() void {
    var mu = MaybeUninit(u32).init();
    // const val = mu.assumeInit(); // ❌ Analyzer: "uninitialized MaybeUninit"
    mu.write(42);
    const val = mu.assumeInit();   // ✅ Safe: initialized
    _ = val;
}
```

### Pin — Preventing Memory Movement

```zig
// WITHOUT zust: Self-referential struct breaks on move
const SelfRef = struct {
    data: [4]u8,
    ptr: []u8, // points to data field
};

fn bad_move() void {
    var s = SelfRef{ .data = .{1, 2, 3, 4}, .ptr = &s.data };
    var s2 = s; // 💥 ptr now points to s.data which was moved!
    s2.ptr[0] = 100; // UB: dangling self-reference
}
```

```zig
// WITH zust: Pin prevents moving
fn safe_pin() void {
    const box = try Box(SelfRef, 0, 0, 0).init(std.testing.allocator, undefined);
    var pin = Pin(SelfRef).init(box); // Pinned on heap
    pin.getMut().ptr = &pin.getMut().data;
    // var moved = pin; // ❌ Analyzer: "Pin value moved"
    const dead = pin.deinit();
    _ = dead;
}
```

### Collections

#### HashMap — Preventing Use-After-Remove

```zig
// WITHOUT zust: Iterator invalidation
fn bad_iter() void {
    var map = std.StringHashMap(u32).init(std.testing.allocator);
    defer map.deinit();
    try map.put("a", 1);
    var it = map.iterator();
    map.remove("a"); // 💥 INVALIDATES iterator
    const entry = it.next().?; // UB: iterator points to freed memory
    _ = entry;
}
```

```zig
// WITH zust: Ownership-aware iterator
fn safe_hashmap() void {
    var map = HashMap(u32).init(std.testing.allocator);
    defer map.deinit();
    try map.put("a", try Box(u32, 0, 0, 0).init(std.testing.allocator, 1));
    var entry = map.get("a"); // ✅ Ownership transfer: removed from map
    if (entry) |box| {
        const dead = box.deinit(); // ✅ Properly freed
        _ = dead;
    }
}
```

### Channels

#### Channel — Preventing Send-After-Close

```zig
// WITHOUT zust: Use-after-close
fn bad_channel() void {
    const allocator = std.testing.allocator;
    const cap: usize = 4;
    var buf = try allocator.alloc(u32, cap);
    defer allocator.free(buf);
    var closed = false;
    // ...close channel...
    closed = true;
    if (!closed) {
        buf[0] = 42; // But what if another thread closes it here?
    }
}
```

```zig
// WITH zust: Runtime close tracking
fn safe_channel() void {
    var ch = try Channel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();
    ch.close();
    // ch.send(42); // ❌ Panic: "ChannelClosed"
}
```

#### Oneshot — Preventing Double-Send

```zig
// WITHOUT zust: Overwriting a oneshot value
fn bad_oneshot() void {
    var value: ?u32 = null;
    value = 42;
    value = 100; // 💥 Silently overwrites previous value
    _ = value;
}
```

```zig
// WITH zust: Panic on double-send
fn safe_oneshot() void {
    var os = Oneshot(u32).init();
    try os.send(42);  // ✅ First send succeeds
    // try os.send(100); // ❌ Panic: "AlreadySent"
}
```

### String Handling

#### String — Preventing Buffer Overflows

```zig
// WITHOUT zust: Buffer overflow
fn bad_string() void {
    var buf: [5]u8 = .{0} ** 5;
    const msg = "hello world";
    @memcpy(&buf, msg); // 💥 BUFFER OVERFLOW: writes past end of buf
}
```

```zig
// WITH zust: Growable buffer with bounds checking
fn safe_string() void {
    var s = String.init(std.testing.allocator);
    defer s.deinit();
    try s.append("hello world"); // ✅ Grows automatically
    try std.testing.expectEqual(s.len(), 11);
}
```

### Slices

#### Slice — Preventing Out-of-Bounds Access

```zig
// WITHOUT zust: Out-of-bounds access
fn bad_slice() void {
    const arr = [_]u32{10, 20, 30};
    const s = arr[0..5]; // 💥 OOB in release mode, panic in debug
    _ = s;
}
```

```zig
// WITH zust: Bounds-checked access
fn safe_slice() void {
    const arr = [_]u32{10, 20, 30};
    const s = Slice(u32).fromStack(&arr);
    _ = s.get(5); // ✅ Returns null (not UB)
    s.release();
}
```

### Summary Table

| zust Type | Bug Without zust | How zust Prevents It |
|-----------|-----------------|----------------------|
| `Box` | Double-free, use-after-free | `@compileError` on misuse |
| `Rc`/`Arc` | Premature drop, UAF | Reference counting |
| `Mutex` | Data races | Must acquire lock |
| `RwLock` | Writer starvation | Writer-preference lock |
| `RefCell` | Mutable aliasing | Runtime borrow checking |
| `OnceCell` | Race on initialization | `AlreadyInitialized` panic |
| `ManuallyDrop` | Memory leak | Analyzer: "not dropped" |
| `MaybeUninit` | Reading undefined | `NotInitialized` error |
| `Pin` | Broken self-references | `InvalidMove` error |
| `HashMap` | Iterator invalidation | Ownership-transfer API |
| `Channel` | Send-after-close | `ChannelClosed` panic |
| `Oneshot` | Overwriting value | `AlreadySent` panic |
| `String` | Buffer overflow | Automatic growth |
| `Slice` | Out-of-bounds | Returns `null` |

## Analyzer: What Gets Detected

### Definite Bugs (Intraprocedural)

| Bug Class | Detection | Example |
|-----------|-----------|---------|
| Double-free | ✅ Error | `dead.deinit()` on already-freed Box |
| Use-after-free | ✅ Error | `raw.* = 100` after `box.deinit()` |
| Pointer escape | ✅ Error | `global_ptr = box.unsafePtr()` then `box.deinit()` |
| Dangling argument | ✅ Error | Passing raw pointer to function after deallocation |
| Raw allocation | ✅ Warning | `allocator.create(T)` → suggest `Box(T,0,0,0).init()` |
| Raw deallocation | ✅ Warning | `allocator.destroy(ptr)` → suggest `Box.deinit()` |
| Raw pointer types | ✅ Warning | `fn foo() *u32` → suggest returning `Box` |
| Raw pointer deref | ✅ Warning | `ptr.* = 42` → suggest `.withImm()`/`.withMut()` |

### Pattern Detection

The analyzer also flags patterns where you *should* be using `safe.Box` but aren't:

```zig
// Analyzer will flag this:
var raw: *u32 = undefined;
raw.* = 42;
allocator.destroy(raw);

// And suggest:
var box = try Box(u32, 0, 0, 0).init(allocator, 42);
box.withImm({}, struct { fn f(_: void, val: *const u32) void {
    // use val
}}.f);
const dead = box.deinit();
```

## Running Tests

```bash
cd zust
zig build test-all
```

## Running the Analyzer

### As a build step

```bash
# Run analyzer on the project's own source files (dog-food check)
cd zust
zig build analyze

# With options
zig build analyze -Dstrictness=high -Dsarif=true
```

### Standalone CLI

```bash
cd zust/analyzer
zig build run -- ../tests/example.zig
zig build run -- ../tests/example.zig --sarif
zig build run -- ../tests/example.zig --strictness=high
```

### LSP Server Mode

```bash
cd zust/analyzer
zig build run -- --lsp
```

The LSP server speaks JSON-RPC 2.0 over stdin/stdout. It supports:

- `initialize` / `initialized`
- `textDocument/didOpen` → runs analysis → `textDocument/publishDiagnostics`
- `textDocument/didChange` → re-runs analysis → publishes updated diagnostics
- `textDocument/didClose`
- `shutdown` / `exit`

Connect it to your editor by configuring the language server command:

```json
// VS Code settings.json example
{
  "zig.languageServer": {
    "command": "/path/to/zust-analyze",
    "args": ["--lsp"]
  }
}
```

## VS Code Extension

A reference VS Code extension is provided in `vscode-extension/`:

```bash
cd vscode-extension
npm install
npm run compile
# Press F5 in VS Code to launch the Extension Development Host
```

The extension auto-starts the zust analyzer in `--lsp` mode for all `.zig` files. Configure it via VS Code settings:

| Setting | Description | Default |
|---------|-------------|---------|
| `zust.enable` | Enable/disable analysis | `true` |
| `zust.serverPath` | Path to analyzer binary | `zust-analyzer` |
| `zust.strictness` | Analysis strictness | `Medium` |

## OpenCode Integration

zust includes first-class integration with [OpenCode](https://opencode.ai) via MCP (Model Context Protocol) and custom commands.

### Setup

1. Build the analyzer:
   ```bash
   zig build
   ```

2. OpenCode will auto-detect the project `opencode.json` when you work in the zust directory.

### Custom Commands

| Command | Description |
|---------|-------------|
| `/zust-check` | Run `zig build analyze` and report diagnostics |
| `/zust-test` | Run `zig build test-all` and report results |

### MCP Tools

The zust MCP server exposes these tools that OpenCode can call automatically:

- **`zust_analyze_file`** — Analyze a `.zig` file for memory safety issues
  ```json
  {
    "file_path": "src/main.zig",
    "strictness": "high"
  }
  ```

- **`zust_analyze_project`** — Run full project analysis (`zig build analyze`)

- **`zust_check_patterns`** — Check a code snippet for unsafe patterns
  ```json
  {
    "code": "var ptr = allocator.create(u32); ..."
  }
  ```

### How It Works

When you open the zust project in OpenCode:

1. The `opencode.json` registers the zust MCP server
2. The MCP server wraps `zust-analyze` as an MCP tool provider
3. When you edit Zig files, OpenCode can call `zust_analyze_file` to check for issues
4. The `/zust-check` command runs the full analyzer on demand

### Configuration

The project-level `opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "command": {
    "zust-check": {
      "description": "Run zust memory safety analyzer",
      "prompt": "Run `zig build analyze` and report diagnostics"
    }
  },
  "mcp": {
    "zust-analyzer": {
      "type": "local",
      "command": ["node", ".opencode/mcp/zust-mcp-server.js"],
      "enabled": true
    }
  }
}
```

### Manual MCP Server Testing

```bash
# Test the MCP server directly
cd zust
node .opencode/mcp/zust-mcp-server.js
# Then send MCP JSON-RPC messages via stdin
```

## Dog-Fooding

The analyzer eats its own dog food:

1. **Analyzer tracks pointers with `safe.LinkedList`**
   - Each `PointerValue` node is a `safe.Box` allocation
   - The list uses `borrowImm`/`borrowMut` for traversal

2. **Analyzer manages AST lifecycle with `safe.Box`**
   - Parsed `std.zig.Ast` lives in a `Box(std.zig.Ast, 0, 0, 0)`
   - Explicit `.deinit()` ensures single-owner cleanup

3. **LSP Server uses `safe.Box` for the analyzer**
   - `analyzer: Box(Analysis.Analyzer, 0, 0, 0)`
   - `unsafePtr()` to borrow and call methods
   - Explicit deinit order in `Server.deinit()`

4. **LSP Server uses `safe.LinkedList` for diagnostic history**
   - `diagnostic_history: LinkedList(Diagnostic.Diagnostic)`
   - Tracks all published diagnostics for debugging

## What the Library Catches (Compile-Time)

| Bug Class | Detection | Mechanism |
|-----------|-----------|-----------|
| Double-free | ✅ `@compileError` | Typestate: `deinit()` returns `Freed`, can't deinit `Freed` |
| Use-after-move | ✅ `@compileError` | Moved values have different type, can't access old binding |
| Mutable aliasing | ✅ `@compileError` | `borrowMut()` changes type to prevent second borrow |
| Mixed borrow | ✅ `@compileError` | `imm_count`/`mut_count` in type parameters |
| Free with active borrows | ✅ `@compileError` | `deinit()` requires `(0, 0, 0)` state |

## What the Analyzer Catches (Static Analysis)

| Bug Class | Detection | Mechanism |
|-----------|-----------|-----------|
| **Memory Errors** |||
| Use-after-free (raw ptr) | ✅ Error | Provenance: track raw pointers derived from Boxes |
| Double-free | ✅ Error | Track variable `is_live` state |
| Pointer escape | ✅ Error | Detect assignments to globals/fields from Boxes |
| Memory leak | ✅ Warning | Live zust types at scope/function exit |
| Resource leak (error paths) | ✅ Warning | Missing `errdefer` cleanup |
| Must-use return value | ✅ Warning | Discarded zust constructor result |
| **Ownership Violations** |||
| Use-after-move | ✅ Error | Track moved variable state |
| Mutable aliasing | ✅ Error | Detect simultaneous mutable borrows |
| Invalid move | ✅ Error | Moving non-Copy type without ownership |
| **Concurrency** |||
| Data race | ✅ Error | Shared mutable state across threads |
| Deadlock | ✅ Error | Circular lock dependencies |
| Lock order violation | ✅ Error | Out-of-order lock acquisition |
| Recursive lock | ✅ Error | Same thread re-locks mutex |
| Iterator invalidation | ✅ Error | Modifying collection during iteration |
| **Initialization** |||
| Uninitialized memory | ✅ Error | Read before write |
| Not initialized | ✅ Error | `MaybeUninit`/`OnceCell` used before init |
| Already initialized | ✅ Error | Double-init of `OnceCell`/`LazyStatic` |
| Null dereference | ✅ Error | `opt.?` without null check |
| **Bounds & Arithmetic** |||
| Buffer overflow | ✅ Error | Compile-time array index out of bounds |
| Unchecked index | ✅ Warning | Variable index without `if (i < len)` guard |
| Division by zero | ✅ Error | Literal zero divisor |
| Shift overflow | ✅ Error | Shift amount >= bit width |
| **Unsafe Patterns** |||
| Raw pointer arithmetic | ✅ Error | `ptr + n` on raw pointers |
| PtrCast without align | ✅ Warning | `@ptrCast` without `@alignCast` |
| Raw allocation | ✅ Warning | `allocator.create(T)` → suggest `Box` |
| Raw deallocation | ✅ Warning | `allocator.destroy(ptr)` → suggest `Box.deinit()` |
| Raw pointer types | ✅ Warning | `*T` in vars/params/returns → suggest `Box` |
| Raw pointer dereference | ✅ Warning | `ptr.*` → suggest `.withImm()`/`.withMut()` |
| **Zust-Specific** |||
| ManuallyDrop not dropped | ✅ Warning | Missing `.drop()` before scope exit |
| OnceCell double-set | ✅ Error | Second `.set()` call |
| Mutex not unlocked | ✅ Warning | `MutexGuard` not deinit'd |
| Pin moved | ✅ Error | Moving a pinned value |
| Channel send-after-close | ✅ Error | Send to closed channel |
| Already sent | ✅ Error | Second send on oneshot channel |

## What Neither Catches (Current Gaps)

These are known limitations. Contributions welcome.

### Cross-Function / Interprocedural

| Gap | Why | Priority |
|-----|-----|----------|
| Function return of raw pointer | Analyzer tracks only within single function body | High |
| Pointer passed into callee | No call-graph analysis; callees are opaque | High |
| Global pointer mutations | Globals are tracked as single entity, no points-to analysis | Medium |
| Send/Sync violations | Type-level thread safety (`Send`/`Sync` traits) not enforced | Medium |

### Array / Collection Safety

| Gap | Why | Priority |
|-----|-----|----------|
| Array of Boxes with different states | Each state transition produces different type; arrays require homogeneous types | High |
| `ArrayList(Box(T, ...))` | Same problem: can't store different types in one array | High |
| Dynamic slice bounds (full) | We detect missing `if (i < len)` but not complex range reasoning | Medium |
| HashMap values as Boxes | Requires homogeneous types | Medium |

### LSP / IDE Integration Gaps

| Gap | Why | Priority |
|-----|-----|----------|
| Workspace-wide analysis | Only open documents are analyzed; no project-wide call graph | Medium |
| Configurable strictness per-file | No `.zust.toml` or similar config yet | Low |
| VS Code extension | No extension package published | Low |
| Auto-fix application | Code actions are generated but not auto-applied on save | Medium |

### Standard Library Integration

| Gap | Why | Priority |
|-----|-----|----------|
| `std.mem.Allocator` integration | `Box` wraps allocator manually; no allocator vtable integration | Low |
| Async/await safety | No `@Frame` ownership tracking | Low |
| Comptime evaluation | Analyzer doesn't evaluate comptime code paths | Medium |

## Tools

### `zust-transpile` — Safe Mode Transpiler

Converts unsafe Zig code to zust-safe Zig via AST rewriting.

```bash
zig build transpile
./zig-out/bin/zust-transpile input.zig output.zig
```

**Patterns rewritten:**
| Unsafe Pattern | Safe Replacement |
|----------------|------------------|
| `allocator.create(T)` | `safe.Box(T, 0, 0, 0).init(allocator, undefined)` |
| `allocator.destroy(ptr)` | `defer _ = ptr.deinit()` |
| `std.ArrayList(T)` | `safe.ArrayList(T)` |
| `std.StringHashMap(T)` | `safe.HashMap(safe.String, T)` |
| `std.Thread.Mutex{}` | `safe.Mutex(void)` |
| `opt.?` | `if (opt) \|value\| { value } else { return error.NullPointer; }` |
| `var x: i32;` (uninit) | `var x: i32 = safe.CheckedInt(i32).init(0);` |

The transpiler is itself written with zust types (`safe.String` for buffers, `safe.ArrayList` for edit tracking) and is analyzed by zust.

### `zust-analyze` — CLI Analyzer

Analyzes any Zig project for memory safety issues.

```bash
zig build
./zig-out/bin/zust-analyze /path/to/project/src/

# JSON output
./zig-out/bin/zust-analyze --json /path/to/project/src/

# SARIF output for CI
./zig-out/bin/zust-analyze --sarif /path/to/project/src/ > results.sarif
```

Detects 30 bug classes including double-free, UAF, data races, null dereferences, buffer overflows, division by zero, and more.

### OpenCode Agent Skill

A `zust-transpile` skill is available for OpenCode agents at:
`~/.config/opencode/skills/superpowers/zust-transpile/SKILL.md`

Load it with: `Skill("zust-transpile")`

## Design Philosophy

1. **Zero hidden control flow** — No implicit drops, no runtime reference counting
2. **Explicit ownership** — Every transfer is visible in the type system
3. **Opt-in safety** — Raw pointers still work; safe types are wrappers
4. **Zero runtime cost** — All typestate checking happens at compile time
5. **Dog-food everything** — If the analyzer can't use `safe.Box`, it's a bug

## Limitations

- **Type-level state**: All `Box(T, 0, 0, 0)` instances share the same comptime state. The library tracks state per-value by returning new types on transitions.
- **Pointer escape**: If `unsafePtr()` is used, the library cannot track the raw pointer. The analyzer is needed for cross-API-boundary safety.
- **Arrays**: Storing multiple Boxes in a homogeneous array is difficult because each state transition produces a different type. A `safe.ArrayList` type is planned.
- **Compile-time cost**: Heavy monomorphization for complex borrow sequences.
- **No NLL**: Non-lexical lifetimes (borrows that end before scope exit) are not yet implemented.

## Implementation Status

### Library (`lib/`)
- [x] Core `Box` typestate with `@compileError` enforcement
- [x] Closure API (`withImm`/`withMut`)
- [x] Explicit borrow API (`borrowImm`/`borrowMut`/`releaseImm`/`releaseMut`)
- [x] `Rc(T)`, `Arc(T)`, `Weak(T)` with reference counting
- [x] `Mutex(T)`, `RwLock(T)` with RAII guards
- [x] `Cell(T)`, `RefCell(T)`, `UnsafeCell(T)` interior mutability
- [x] `ManuallyDrop(T)`, `MaybeUninit(T)`, `Pin(T)` low-level primitives
- [x] `OnceCell(T)`, `LazyCell(T)`, `OnceBox(T)` lazy initialization
- [x] `LinkedList(T)`, `ArrayList(T)`, `VecDeque(T)`, `HashMap(T)`, `BTreeMap(T)`, `HashSet(T)`, `BinaryHeap(T)`
- [x] `String`, `Cow(T)` string utilities
- [x] `Slice(T)` borrow-checked slices
- [x] `Channel(T)`, `Oneshot(T)` message passing
- [x] `Iterators` — map, filter, fold, collect, enumerate, take, skip, chain, zip, find, all, sum, min, max
- [x] `PhantomData(T)` zero-sized marker
- [x] 213 passing compile-time tests

### Analyzer (`analyzer/`)
- [x] AST parsing via `std.zig.Ast.parse`
- [x] Intraprocedural pointer provenance tracking
- [x] Detects double-free, use-after-free, pointer escape, dangling args
- [x] Detects raw pointer patterns (allocations, types, dereferences)
- [x] Cross-function analysis with ownership contracts
- [x] Detects all zust type misuse: ManuallyDrop leaks, OnceCell double-set, Mutex deadlocks, Channel send-after-close, Pin moves, etc.
- [x] Dog-foods `safe.Box` for AST lifecycle
- [x] Dog-foods `safe.LinkedList` for tracked_pointers
- [x] Dog-foods `safe.String` for LSP message building
- [x] Human-readable + SARIF 2.1.0 output
- [x] `zig build analyze` step with `-Dstrictness` and `-Dsarif`
- [x] LSP server: `initialize`, `didOpen`, `didChange`, `didClose`, `shutdown`
- [x] LSP `publishDiagnostics` notification
- [x] JSON-RPC 2.0 message framing
- [x] 30 analyzer tests

### Not Yet Implemented
- [ ] Non-lexical lifetimes (NLL) — partially implemented via `ScopeImm`/`ScopeMut`
- [ ] Full interprocedural call-graph analysis
- [ ] Async/await ownership tracking
- [ ] VS Code extension package (marketplace publish)
- [ ] Incremental document sync in LSP
- [ ] Generic `Default` trait equivalent for `take()`

## License

MIT
