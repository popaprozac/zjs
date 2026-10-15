# Cells with their slots: a design note

Should a cell's slots sit beside its header, so a property read waits on
one load instead of two? Measured on 2026-10-15: not now. The most it
could save is about 3% on the property kernels, and it would mean
rebuilding the heap and the collector. This note records the case, the
measurement, and what would change the answer.

## What a read waits on

A cell is a handle: an index into a table of 20-byte headers, which holds
the cell's class and where its slots start in a separate arena of values
(`heap.zs`, `CellHeader`, `slots`). A cached property read loads the
header (class and slot start together), then the slot at slot start plus
the cached index. The second load waits for the first.

The engine retires about six instructions a cycle on these kernels
(json, calls), so instructions removed elsewhere have mostly filled idle
slots; what sets the cycle count is chains of loads that wait on each
other (`levers.md`, the call-protocol attempts of 2026-10-14 and
2026-10-15). If the slots followed the header in one arena, the slot's
address would depend only on the handle, and the class check and the
slot load would run side by side: one level instead of two.

## The measurement

Removing the level means rebuilding the heap, so the experiment adds one
instead: every slot read and write loads the header a second time, the
second load's address depending on the first (it cannot be removed),
and takes the slot start from it. One more level costs about what one
fewer saves. In cycles over eight placements, three runs
(`bench/speed/results/2026-10-15-slot-load-level.json`):

| Kernel | One more level |
|---|---|
| helpers | +3.5 to +4.0% |
| properties | +2.5 to +3.3% |
| closures | +2.0 to +2.1% |
| strings | +0.6 to +2.3% |
| arrays | +1.1 to +1.9% |
| polymorphic | +1.0 to +1.6% |
| calls | +0.7 to +1.4% |
| allocation | -0.3 to +1.7% |
| json, regexp, maps, long-strings | level |

So the redesign's latency gain is bounded by about 3% on properties and
4% on helpers, less elsewhere. Locality would not add much: the kernels'
headers and slots are already in cache (the 2026-09-26 note in
`levers.md`).

## What it would cost

Two layouts were considered.

**Moving: a handle is the cell's offset in one arena.** Compaction and a
young generation that evacuates would change handles, so everything
that holds one would need fixing up after each collection: the register
stack, frames, globals, temp roots, the job queue, the atom table, the
symbol registry, Map, Set, and weak tables hashed by handle, the
dictionary and element-attribute indices, constants and property names,
and the roughly sixty prototype and atom fields of the runtime. Worse,
builtins written in Z keep handles in locals across calls back into
JavaScript (about 210 temp-root sites, the JSON stringifier and parser,
set records), and those rely on a handle never changing. A moving design
would have to give every such site a fix-up path.

**Not moving: cells in size classes, the way JavaScriptCore keeps its
heap.** A handle stays stable, so nothing outside the heap changes. A
cell's first slots sit after its header; properties past them and array
elements go to a store of their own that can move, reached through one
field in the cell, so a read of those keeps two levels. Freed cells are
reused within their size class rather than compacted, so fragmentation
replaces sliding, and the young generation would have to become sticky
mark bits rather than a slide of young slots. This is the collector,
the allocator, slot growth, dictionary mode, and arrays rewritten.

Either way it is weeks of work against a gain of a few percent.

## What would change the answer

- A memory goal the current layout cannot meet: the 20-byte header and
  the separate slot range cost resident memory on large heaps, which a
  size-class layout with in-cell slots would cut.
- A kernel where header-then-slot chains dominate, which none of the
  twelve shows.
- A layout change already needed for another reason (a collector change
  for pause times, for one), which this could ride along with.

## Where the time goes instead

The kernels behind the fastest jit-less engine (`levers.md`, the gap,
2026-10-15) are json (2.1x JavaScriptCore), closures (1.4x Hermes),
calls (1.3x Hermes), regexp (1.3x V8), long-strings (1.2x), and strings
(1.1x). Calls and closures are bound by the dispatch loop's shape: every
change to its call and return arms moved its register allocation more
than the work it removed. Splitting the loop so each instruction's body
stands alone, chained by guaranteed tail calls, would end that, and needs
a language feature Z does not have.
