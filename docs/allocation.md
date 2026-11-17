# Allocation and collection

Cells live in a handle-based heap (`engine/heap.zs`): a handle is an index
into a table of headers, and a cell's slots sit in an arena of values
beside it. The collector is generational, and a full collection is spread
over the minor ones that follow its start.

## The heap and a full collection

Mark-sweep over the handle heap with stable handles. Marking walks from the
runtime's roots (registers, globals, frames, the realm, compiled code's
constants and property names); sweeping frees dead headers onto a free list
for reuse and compacts the live cells' slots in place, so an object that
outgrew its range leaves no permanent hole and nothing outside the heap
needs updating. Compaction slides: the survivors' slot ranges are sorted
into arena order (by buckets of eight slots, then a pass of insertion sort)
and each moves down over the dead ones, and the small strings' bytes the
same way once their arena holds twice what is live. No second arena is
made: on macOS the allocator keeps a freed large block resident, so a copy
into a fresh arena would cost the whole old one. For the same reason the
arena and the handle table grow four times at a step, not twice.

The handle table has an extent: when a large table's survivors all sit in
its lowest quarter a sweep cuts the extent back to the highest of them,
takes the handles above it off the free list, and rebuilds a table left far
larger than it needs, so a collection after a burst costs what is alive. A
table under 32,768 handles is walked whole. A sweep visits handles from the
top down, which lists what it frees highest first, so allocation reuses the
lowest handles and survivors gather low.

The atom table is weak. A collection runs at instruction boundaries only --
returns and loop back edges -- so no value is ever held only in a Z local
across a collection. The ABI smoke test runs a 200,000-iteration allocating
loop and checks the heap stays bounded.

## Generations

A cell is young until it survives a collection; between collections the
mark bit says which, since a sweep leaves its survivors marked. Most
collections are minor: every 16,384 cells allocated, marking from the same
roots stops at any old cell, and the sweep walks only the young cells (the
free list's entries taken since the last collection, then the handles past
the table's old extent, which is their allocation order), freeing the dead
and leaving the rest old. The slots and small-string bytes allocated since
the last collection sit above a base in their arenas, so a minor sweep
slides the ones still in use down and cuts both arenas back.

A store that gives an old cell a young one (a slot, a prototype or link, a
Map or Set entry) lists the old cell in a remembered set, or for a cell of
256 slots or more just the slot, and a minor collection traces those too.
Weak entries are held strongly by a minor collection; their dead keys go at
the next full one.

A minor collection costs what survives it. Its sweep leaves the dead young
cells alone: the free list's top moves back up over the handles they took,
the survivors' places in it are repaired, and the few young cells that own
storage outside the arenas, or are atoms, are listed when they come to, so
only those are visited. Its roots skip the functions and hidden classes an
earlier collection traced. When 60% or more of a young generation survives,
the next seven are made old untraced and the eighth is traced to see
whether that still holds.

## Full collections in slices

A full collection is spread over the collections that follow its start, a
slice after each minor collection, so the program stops for a minor
collection and a slice and never for the whole heap. First the marking: a
cell's mark says whether it is old and whether the collection has reached
it; the roots' old cells are queued when it begins and at every minor
collection, a cell made old meanwhile is reached, and the write barrier's
slow half queues an old cell stored into an old one, so a cell already
traced never holds one that is not reached. A run of values stored at once
(a suspended body's registers) settles the barrier once: a young cell takes
the run as it is, an old one is listed whole for the next minor collection,
and while a full collection marks each store takes the barrier as any
other. A number stored in a generator's record takes none, a collection
following nothing through it.

When a slice leaves nothing queued, right after a minor collection, what is
not reached is dead: the weak entries and atoms of dead cells go, and the
sweep walks the table a slice at a time, then the slide sorts and moves the
slot ranges a slice at a time. A handle never changes, so ranges move
between slices with nothing for the program to check. A slice traces 65,536
cells' worth, or more when the heap is large enough that the marking would
otherwise take over 64 steps. A heap one slice can mark is collected whole,
and so is every collection of `gc()` and of a heap with no young
generation. The cells made old while a collection runs wait for the next,
which costs up to 10% resident memory on most large heaps and 26 to 50% on
those with the highest turnover (`bench/gc`).

## When a collection is due

| Collection | Due when |
|---|---|
| Minor | 16,384 cells allocated since the last collection (`--gc-nursery`), or a megabyte gone into strings' own buffers |
| Full | minor collections have promoted twice what the last full one kept (`--gc-growth`, 200%) and at least the floor, 4,096 cells (`--gc-floor`); or, counted the same way, string-buffer bytes, with a floor of a megabyte |
| Whole, at once | `gc()` (`--expose-gc`), always |

A string longer than 256 bytes has a buffer of its own, which no count of
cells measures, so the buffers' bytes are counted beside the cells.
`tests/gc/string-bytes.js` (under `gc-check.sh`) checks that strings made
and dropped, some of them dying old, do not accumulate.

The defaults favor memory over throughput: for an engine meant to be
embedded small, a few megabytes resident on a small live set and pauses
near a tenth of a millisecond are worth more than a few percent of
throughput, and the multiple trades time for memory about one for one. Both are fields of the heap; `zjsz run --gc-floor N --gc-growth P`
sets them for measurement, and nothing in the frozen ABI reaches them.

## What `--mem-stats` reports

`zjsz run --mem-stats` reads these at one moment, at the end of the script
and before anything is torn down, so they can be set against each other:

| Figure | What it is |
|---|---|
| alive at the last collection | headers and slots of the cells that collection traced |
| in use | that plus everything allocated since, garbage included |
| held | the capacity of every array behind the heap and the runtime, used or not: the active arena, the spare arena, the handle table with its free list and mark stack, the string table, the rest |
| allocator in use, reserved | what the system allocator reports the process holds in blocks, and what it has reserved in its zones |
| resident now, footprint now | the task's resident size and physical footprint at that moment |
| resident peak | the high-water mark, which says nothing about now |

`--gc-stats` times every collection and prints the time in each of the
collector's phases (`bench/gc/README.md` lists them).

## Measuring

`bench/alloc` (allocator calls and cost per operation), `bench/gc`
(collector workloads against other engines), and `bench/memory` (peak
resident size on a large live heap); each README says how to run it.
