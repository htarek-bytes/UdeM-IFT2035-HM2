# Custom Allocators in Zig

Three memory allocators built from scratch against Zig's `std.mem.Allocator`
interface, each one adding a capability the previous one lacks. Written to
understand what a language runtime is actually doing when it hands you memory.

Coursework for IFT2035 (Programming Languages) at Université de Montréal, in a
pair with Mohammed Kamal Skhy.

## The three allocators

| File | Allocator | Frees? | Reuses freed blocks? |
| --- | --- | --- | --- |
| `1-pile.zig` | Bump / stack | No — `noFree` | No |
| `2-etiquette.zig` | Tagged, header per block | Marks free | No |
| `3-recycle.zig` | Recycling, first-fit | Marks free | Yes |

Each one plugs into the standard interface by building a `std.mem.Allocator`
with its own vtable, so ordinary Zig code (`allocator.create`, `allocator.alloc`)
works against them unmodified.

### 1. Bump allocator

The simplest thing that can work: hold a byte buffer and an index, and move the
index forward on every allocation.

```zig
const AllocateurPile = struct {
    buffer: []u8,
    next: usize,
};
```

There is no per-block free, and that is the point — `free` is wired to
`std.mem.Allocator.noFree`. A stack allocator releases everything or nothing.
Fast, and useless the moment lifetimes differ.

### 2. Tagged allocator

Adds a `Header` immediately before each block, storing the block's length and
whether it is free. `getHeader` walks backwards from a data pointer to recover
it, staying in typed-pointer arithmetic rather than casting through integers.

This makes `free` possible — but only as bookkeeping. A freed block is marked
and then never touched again, so the buffer still only grows.

### 3. Recycling allocator

Adds the missing half. Before allocating at the end of the buffer, it walks the
existing headers looking for a free block large enough:

```zig
if (header_ptr.free and header_ptr.len >= len) {
    header_ptr.free = false;
    return @ptrFromInt(header_addr + @sizeOf(Header));
}
```

First-fit, so it takes the first block that fits rather than the best one. The
tradeoff is deliberate: the search is O(blocks) and it leaves the tail of an
oversized block unused, but it needs no free list, no size classes, and no
coalescing pass.

## The bug worth reading about

The first version of the tagged allocator computed alignment from `self.next`,
an offset into the buffer, rather than from the buffer's real address in memory.

That passed on x86-64 Linux and panicked on macOS/ARM with
`panic: incorrect alignment`.

The reason is that a stack-allocated `[N]u8` is not guaranteed to *start* on an
8-byte boundary. Aligning an offset only aligns you relative to wherever the
buffer happens to begin — if the base address is odd, every derived address is
wrong by the same amount. The fix is to align the absolute address:

```zig
const header_addr = std.mem.alignForward(
    usize,
    base_addr + offset,
    header_alignment.toByteUnits(),
);
```

Aligning the offset is a mistake that only shows up on hardware that enforces
alignment, which is exactly the kind of bug that reaches production on one
platform and not another.

## Running the tests

Each file carries its own `std.testing` suite covering allocation, alignment,
buffer exhaustion and block reuse.

```sh
zig test 1-pile.zig
zig test 2-etiquette.zig
zig test 3-recycle.zig
```

Built against Zig 0.15.2.

## Attribution

Written with Mohammed Kamal Skhy. Sources consulted are listed in the header
comment of each file: the Zig standard library documentation and source, the
ziggit.dev allocator guide, course notes, and ChatGPT for clarification on
alignment rules and edge cases.
