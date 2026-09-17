# Allocation and collection: what an operation costs, and what the floor buys

Status: **measured**, on the Z engine built with the Stage 0 compiler at
the pinned revision, macOS arm64. The figures come from `zjsz run
--gc-stats` for the engine's side and from an allocator interposer that
attributes every `malloc` / `calloc` / `realloc` to its calling site for
the allocator's. Timing is taken from builds with none of that enabled.

## Where an await's allocator calls came from

An `await` made about four allocator calls, and a value through an async
generator fifteen. None of them was engine storage: cells live in arenas
the collector manages and cost the allocator nothing until an arena
grows. By calling site they were:

| Site | Per primitive await | What it was |
|---|---|---|
| `bytesOf` under `createIterResult` | 2 | `"value"` and `"done"` copied out of string literals to be interned again |
| `bytesOf` under `asyncStep` | 2 | the same two names, to read the result back |
| argument vectors (`callValue`) | 0 here, 1 per handler call, executor, or settlement; 2 per combinator element | a heap vector built to carry one or two arguments into registers |
| collector | 0.11 reallocations | the compacted arena and the atom table grown by doubling from nothing at every collection |

Four kinds of cost are separate and are reported separately below:
allocator calls, allocator bytes requested, engine cells (and slots)
allocated, and what stays resident.

## What changed, and what each change did alone

Times are nanoseconds per operation with startup subtracted, every
stage binary run in turn on every workload and the median of seven
taken, so a column differs from the one before it by one change only.

| Workload | base | atoms | calls | arenas | promise | suspend | plain | ints | table | total |
|---|---|---|---|---|---|---|---|---|---|---|
| await of a primitive | 344 | 246 | 245 | 236 | 180 | 124 | 84 | 82 | 83 | -76% |
| await of one settled promise | 268 | 170 | 171 | 165 | 160 | 103 | 103 | 102 | 101 | -63% |
| await of a fresh settled promise | 385 | 285 | 286 | 277 | 224 | 163 | 161 | 160 | 162 | -58% |
| await of a pending promise | 865 | 663 | 653 | 627 | 501 | 381 | 340 | 336 | 342 | -60% |
| async generator value | 1243 | 872 | 878 | 854 | 656 | 456 | 375 | 377 | 377 | -70% |
| then-link on a pending chain | 375 | 362 | 355 | 320 | 174 | 171 | 172 | 169 | 177 | -53% |
| settle loop (new Promise + then) | 489 | 487 | 468 | 443 | 324 | 325 | 325 | 323 | 327 | -33% |
| combinator element (all, race) | 986 | 895 | 788 | 757 | 521 | 530 | 528 | 527 | 510 | -48% |
| small-live-set churn | 93 | 92 | 94 | 92 | 90 | 92 | 91 | 68 | 67 | -28% |
| churn against 300,000 retained | 179 | 177 | 177 | 173 | 175 | 175 | 176 | 177 | 176 | -2% |

- **atoms**: the names the engine looks up constantly (`done`, `value`,
  `then`, `next`, `return`, `throw`, `resolve`) are atoms it holds.
- **calls**: a call from the engine with up to two arguments writes them
  into the registers directly.
- **arenas**: a sweep sizes the arena it compacts into once, from the
  slots counted while marking plus the next cycle's expected allocation;
  small heaps flip between two kept arenas.
- **promise**: a promise is two cells instead of four (its reactions
  slot is nothing, one reaction, or a list), settling makes none, a
  reaction carries both handlers in one cell, and a job is four values
  in the queue rather than a cell.
- **suspend**: an async body hands its driver a value and a flag instead
  of an iterator result; a suspension reuses the register array the
  last one filled and makes no handler array when there are no handlers.
- **plain**: awaiting a value that is not an object queues the
  continuation directly. The promise the specification wraps it in is
  unreachable and the job lands in the same place in the queue.
- **ints**: an int32 becomes a string in the allocation the string keeps.
- **table**: the handle table has an extent that a sweep can cut back
  (next section). No effect on these workloads, by design.

The job queue reusing its own storage came after this table; it changes
allocator bytes, not time.

Per operation, first to last:

| Workload | Cells | Allocator calls | Allocator bytes | Collections | Collecting, ms | Peak resident, MB |
|---|---|---|---|---|---|---|
| await of a primitive | 11 to 1 | 4.1 to 0.01 | 1,630 to 10 | 536 to 49 | 10.6 to 0.9 | 3.0 to 3.0 |
| await of one settled promise | 5 to 1 | 4.1 to 0.01 | 763 to 10 | 244 to 49 | 4.5 to 0.8 | 3.0 to 3.0 |
| await of a fresh settled promise | 11 to 3 | 4.1 to 0.01 | 1,630 to 9 | 536 to 146 | 9.8 to 2.8 | 3.0 to 3.0 |
| await of a pending promise | 25 to 7 | 9.3 to 0.02 | 3,761 to 19 | 609 to 171 | 12.6 to 3.1 | 3.0 to 3.0 |
| async generator value | 36 to 8 | 15.4 to 0.01 | 5,328 to 10 | 1,754 to 390 | 39.6 to 7.3 | 3.0 to 2.9 |
| then-link on a pending chain | 9 to 3 | 1.0 to 0.01 | 1,880 to 561 | 6 to 5 | 21.5 to 6.9 | 205.6 to 67.9 |
| settle loop | 21 to 11 | 2.2 to 0.01 | 3,120 to 11 | 1,023 to 537 | 20.4 to 10.6 | 3.1 to 3.0 |
| combinator element | 32 to 13 | 10.9 to 0.02 | 4,855 to 20 | 769 to 303 | 17.3 to 6.9 | 3.4 to 3.1 |
| small-live-set churn | 1.3 to 1.3 | 1.35 to 0.67 | 121 to 6 | 976 to 976 | 31.2 to 31.4 | 3.0 to 2.8 |
| churn against 300,000 retained | 2.3 to 2.3 | 0 to 0 | 456 to 342 | 8 to 8 | 30.6 to 30.0 | 156.8 to 132.2 |

Pauses did not move for small heaps (median 16 to 31 us, 99th percentile
30 to 42 us, before and after); the longest pause of the 200,000-link
chain fell from 14.4 ms to 4.8 ms with the cells it no longer allocates.
The allocator calls that remain in the churn loop are the contents of
the strings it makes.

Nothing a program can observe moved. The node-recorded traces of
promise identities, constructor and species reads, and microtask turns
are unchanged, a new trace covers awaits of every kind of non-object
value against promises, thenables, and tickers, and the forced and
pressure collection gates pass. Completed jobs are released as before:
the settle-loop gate holds about 3,700 cells however long it runs.

## After a burst

The handle table never shrank and a sweep walked all of it. Two million
objects held and then dropped left every later collection of a tiny live
set taking 2.9 ms, and with the threshold back at its floor there was
one every 4,096 allocations: 0.85 s of collecting in a 1.4 s run.

The table now has an extent. When a large table's survivors all sit in
its lowest quarter, a sweep cuts the extent back to the highest of them,
takes the handles above it off the free list, and rebuilds a table left
under a quarter of the size its storage was made for. Sweeping from the
top down lists freed handles highest first, so allocation reuses the
lowest and survivors gather low. A table under 32,768 handles is walked
whole: its top survivor moves at every collection and its walk is cheap.

| After the burst | Before | After |
|---|---|---|
| The run | 1,384 ms | 656 ms |
| Collecting | 852 ms | 117 ms |
| Median pause | 2,860 us | 16 us |
| Twelve million more allocations | 15.7 s | 1.5 s |

The engine returns the burst's storage to the allocator (its live bytes
fall from 822 MB to under 1 MB during the run). On this macOS the
process footprint stays at its peak anyway: the system allocator keeps
the pages. Giving them back needs an allocator-level call, which is the
host's to make.

## The floor

A collection is due after a number of cells allocated: twice what
survived the last one, and never fewer than the floor. With small live
sets the floor is the policy; with large ones the survivors' multiple
is.

Floor, small live sets (six workloads; ranges across them):

| Floor, cells | Time against 4,096 | Peak resident | Median pause | Longest pause |
|---|---|---|---|---|
| 1,024 | +3% to +14% | 2.5 to 2.9 MB | 13 to 18 us | 24 to 114 us |
| 4,096 | | 2.8 to 3.2 MB | 16 to 31 us | 30 to 86 us |
| 16,384 | -2% to -7% | 4.4 to 5.4 MB | 33 to 91 us | 52 to 137 us |
| 65,536 | -3% to -7% | 10.9 to 15.0 MB | 102 to 332 us | 127 to 378 us |

After the allocation work above, collecting is 4 to 15% of these
workloads at the default floor, so that is all a larger floor can win.
16,384 takes most of it for two more megabytes resident and pauses two
to three times as long; 65,536 wins nothing further and costs ten
megabytes and pauses ten times as long. With a live set of 60,000 cells
or more the floor does nothing (the survivors' multiple governs), and
on the pending chain a larger floor is slower, since it delays the
collections that keep the chain's garbage small.

Survivors' multiple, large live sets:

| Multiple | 60,000 live cells | 300,000 retained |
|---|---|---|
| 150% | 70 collections, 87 ms collecting, 24.7 MB | 10 collections, 33 ms, 106 MB |
| 200% | 53 collections, 76 ms, 24.3 MB | 8 collections, 28 ms, 130 MB |
| 300% | 36 collections, 60 ms, 28.5 MB | 6 collections, 22 ms, 158 MB |

The defaults stay at 4,096 cells and 200%. For an engine meant to be
embedded small, three megabytes resident and pauses under a tenth of a
millisecond are worth more than 2 to 7% of throughput on promise-heavy
loops, and the multiple trades time for memory about one for one. Both
are fields of the heap, and `zjsz run --gc-floor N --gc-growth P` sets
them for measurement; nothing in the frozen ABI reaches them.

What dominated the floor's worst case was never the floor: it was the
sweep walking a table the size of the largest burst the heap had seen,
which the extent fixes.

## Reproducing

```
./z/build/zjsz run --gc-stats file.js     # collections, total, pause percentiles,
                                           # cells and slots allocated, storage in use
./z/build/zjsz run --gc-floor 16384 --gc-growth 300 file.js
```
