# Allocation and collection: what an operation costs, and what the floor buys

Status: **measured**. Everything here is Stage 0 evidence: the engine built
by the TypeScript compiler run under bun, at z-lang `ad43b117`, on macOS
arm64. No native compiler build was used.

The workloads, the runner, the attribution tool, and the results behind
every figure are in the tree:

| What | Where |
|---|---|
| Workloads, with their operation counts on the first line | `z/bench/alloc/workloads/` |
| Runner: builds a stage from its commit, runs every child under a timeout, writes JSON | `z/bench/alloc/run.py` |
| Stages: name, engine commit, what changed, compiler revision | `z/bench/alloc/stages.json` |
| Results: the matrix, per-workload figures, cells, policy sweep, the burst | `z/bench/alloc/results/*.json` |
| The tables below, rendered from those results | `z/bench/alloc/tables.py` |
| Allocator attribution by calling site, calls and bytes | `z/tools/alloc-attr.c` |
| Engine figures | `zjsz run --gc-stats --mem-stats` |

Method. Timing is wall time of `zjsz run <workload>` with no measurement
flag, the median of seven runs interleaved across the binaries being
compared, less the same median for an empty script (the startup figure,
recorded beside each result). Collection figures, storage figures, and
allocator attribution come from separate instrumented runs and are never
used for timing. A figure "per operation" divides by the count on the
workload's first line.

## Where an await's allocator calls came from

In the first stage an `await` made about four allocator calls and a value
through an async generator fifteen. None of them was engine storage:
cells live in arenas the collector manages and cost the allocator nothing
until an arena grows. By calling site (`figures-base.json`):

| Site | Per primitive await | What it was |
|---|---|---|
| `bytesOf` under `createIterResult` | 2 | `"value"` and `"done"` copied out of string literals to be interned again |
| `bytesOf` under `asyncStep` | 2 | the same two names, to read the result back |
| argument vectors (`callValue`) | 0 here; 1 per handler call, executor, or settlement; 2 per combinator element | a heap vector built to carry one or two arguments into registers |
| the collector | 0.11 reallocations | the compacted arena and the atom table grown by doubling from nothing at every collection |

## The stages, and the incremental effect of each

Each stage is the engine at one commit (`stages.json`) and differs from
the stage before it by that commit only. A column is therefore the effect
of its change **on top of all the earlier ones, in this order**. It is not
what that change would do alone, or first, or in another order: the
stages interact (fewer cells mean fewer collections, which changes what
the arena work is worth), and no other ordering was measured.

Nanoseconds per operation:

| Workload | base | atoms | calls | arenas | promise | suspend | plain | ints | table | queue | report | first to last |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| await of a primitive | 361 | 257 | 264 | 247 | 189 | 131 | 90 | 87 | 88 | 90 | 92 | -75% |
| await of one settled promise | 288 | 185 | 194 | 176 | 178 | 117 | 113 | 116 | 113 | 122 | 120 | -58% |
| await of a fresh settled promise | 422 | 312 | 313 | 300 | 240 | 175 | 173 | 183 | 183 | 180 | 181 | -57% |
| await of a pending promise | 926 | 728 | 711 | 678 | 545 | 423 | 366 | 371 | 371 | 365 | 370 | -60% |
| async generator value | 1345 | 949 | 953 | 915 | 712 | 500 | 410 | 411 | 407 | 413 | 419 | -69% |
| then-link on a pending chain | 491 | 457 | 434 | 370 | 200 | 196 | 192 | 198 | 208 | 205 | 199 | -60% |
| settle loop (new Promise + then) | 517 | 528 | 505 | 477 | 343 | 349 | 348 | 345 | 365 | 361 | 353 | -32% |
| combinator element (all, race) | 1056 | 946 | 842 | 813 | 560 | 563 | 555 | 559 | 539 | 555 | 550 | -48% |
| small-live-set churn | 98 | 98 | 99 | 97 | 97 | 99 | 97 | 72 | 70 | 71 | 72 | -27% |
| churn against 300,000 retained | 192 | 190 | 191 | 188 | 190 | 186 | 187 | 188 | 187 | 188 | 189 | -2% |

Startup subtracted, ms: base 3.1, atoms 3.1, calls 2.8, arenas 3.0, promise 3.0, suspend 2.8, plain 2.9, ints 3.2, table 3.0, queue 2.9, report 2.8.

- **atoms** (`a408dbd`): the names the engine looks up constantly (`done`,
  `value`, `then`, `next`, `return`, `throw`, `resolve`) are atoms it holds.
- **calls** (`0ed992b`): a call from the engine with up to two arguments
  writes them into the registers directly.
- **arenas** (`f7eb0b7`): a sweep sizes the arena it compacts into once,
  from the slots counted while marking plus the next cycle's expected
  allocation; small heaps flip between two kept arenas.
- **promise** (`39bc925`): a promise is two cells instead of four, settling
  makes none, a reaction carries both handlers in one cell, and a job is
  four values in the queue rather than a cell.
- **suspend** (`7b35c70`): an async body hands its driver a value and a flag
  instead of an iterator result; a suspension reuses the register array
  the last one filled and makes no handler array for no handlers.
- **plain** (`1e9cbe1`): awaiting a value that is not an object queues the
  continuation directly. The promise the specification wraps it in is
  unreachable and the job lands in the same place in the queue.
- **ints** (`81cd092`): an int32 becomes a string in the allocation the
  string keeps.
- **table** (`06dbbd2`): the handle table has an extent a sweep can cut
  back (see the burst below). By design it does nothing on these workloads.
- **queue** (`f42d6d5`): the job queue reuses its own storage. It changes
  allocator bytes, not time.
- **report** (`8a2a8e3`): `--mem-stats`, and the heap reads its arrays'
  capacity where it had estimated it. No engine behaviour changes; it is
  the stage the storage figures below come from.

First stage to last, per operation (`figures-base.json`,
`figures-final.json`; cells and slots from `cells-before.json`, which is
the arenas stage built with `cell-counters.patch` since the counters did
not exist yet, and `cells-after.json`):

| Workload | Cells | Slots | Allocator calls | Allocator bytes requested | Collections | Collecting, ms | Pause p50 / p99 / max, us | Peak resident, MB |
|---|---|---|---|---|---|---|---|---|
| await of a primitive | 11 to 1 | 49 to 5 | 4.12 to 0.01 | 1630 to 10 | 536 to 49 | 11.6 to 0.9 | 20 / 51 / 92 to 16 / 40 / 40 | 3.3 to 3.0 |
| await of one settled promise | 5 to 1 | 24 to 5 | 4.06 to 0.01 | 762 to 10 | 244 to 49 | 5.3 to 0.9 | 19 / 63 / 138 to 17 / 34 / 34 | 3.3 to 3.0 |
| await of a fresh settled promise | 11 to 3 | 49 to 13 | 4.12 to 0.01 | 1630 to 8 | 536 to 146 | 11.3 to 2.9 | 19 / 59 / 131 to 18 / 57 / 99 | 3.5 to 3.0 |
| await of a pending promise | 25 to 7 | 111 to 32 | 9.26 to 0.02 | 3761 to 18 | 609 to 171 | 14.3 to 3.2 | 22 / 67 / 109 to 18 / 39 / 90 | 3.2 to 3.0 |
| async generator value | 36 to 8 | 163 to 35 | 15.35 to 0.01 | 5328 to 10 | 1754 to 390 | 45.5 to 7.6 | 24 / 56 / 217 to 18 / 42 / 98 | 3.4 to 3.0 |
| then-link on a pending chain | 9 to 3 | 37 to 13 | 1.02 to 0.01 | 1880 to 561 | 6 to 5 | 26.1 to 7.6 | 1512 / 16813 / 16813 to 483 / 5411 / 5411 | 210.3 to 69.8 |
| settle loop (new Promise + then) | 21 to 11 | 83 to 42 | 2.20 to 0.01 | 3120 to 11 | 1023 to 537 | 21.8 to 11.1 | 20 / 38 / 104 to 20 / 39 / 95 | 3.4 to 3.0 |
| combinator element (all, race) | 32 to 13 | 139 to 60 | 10.87 to 0.02 | 4854 to 20 | 769 to 303 | 19.6 to 7.3 | 24 / 61 / 154 to 23 / 46 / 59 | 3.6 to 3.0 |
| small-live-set churn | 1 to 1 | 3 to 3 | 1.35 to 0.67 | 121 to 6 | 976 to 976 | 34.6 to 31.0 | 33 / 69 / 173 to 31 / 47 / 107 | 3.2 to 2.9 |
| churn against 300,000 retained | 2 to 2 | 10 to 10 | 0.00 to 0.00 | 456 to 342 | 8 to 8 | 32.4 to 28.1 | 6465 / 9518 / 9518 to 4822 / 8249 / 8249 | 157.2 to 130.6 |

Small-heap pauses did not move. The allocator calls that remain in the
churn loop are the contents of the strings it makes.

Nothing a program can observe moved. The node-recorded traces of promise
identities, constructor and species reads, and microtask turns are
unchanged, a trace added with the plain-await stage covers awaits of
every kind of non-object value against promises, thenables, and tickers,
and the forced and pressure collection gates pass. Completed jobs are
released as before: the settle-loop gate holds about 3,700 cells however
long it runs.

## Five different things called memory

`--mem-stats` reads these at one moment, at the end of the script and
before anything is torn down, so they can be set against each other:

| Figure | What it is |
|---|---|
| alive at the last collection | headers and slots of the cells that collection traced |
| in use | that plus everything allocated since, garbage included |
| held | the capacity of every array behind the heap and the runtime, used or not: the active arena, the spare arena, the handle table with its free list and mark stack, the string table, the rest |
| allocator in use, reserved | what the system allocator reports the process holds in blocks, and what it has reserved in its zones |
| resident now, footprint now | the task's resident size and physical footprint at that moment |
| resident peak | the high-water mark, which says nothing about now |

Last stage, KiB (`figures-final.json`):

| Workload | Alive at last collection | In use | Held: arena | spare arena | table | strings | other | Allocator in use | Allocator reserved | Resident now | Footprint now | Resident peak |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| await of a primitive | 37 | 126 | 449 | 288 | 176 | 15 | 82 | 1074 | 24576 | 3184 | 2272 | 3184 |
| await of one settled promise | 38 | 126 | 450 | 288 | 176 | 15 | 82 | 1090 | 16384 | 3184 | 2272 | 3184 |
| await of a fresh settled promise | 38 | 217 | 288 | 225 | 192 | 15 | 83 | 864 | 20480 | 3088 | 2176 | 3088 |
| await of a pending promise | 38 | 129 | 225 | 288 | 192 | 15 | 116 | 897 | 20480 | 3152 | 2224 | 3152 |
| async generator value | 38 | 252 | 288 | 225 | 176 | 15 | 86 | 851 | 20480 | 3152 | 2240 | 3152 |
| then-link on a pending chain | 19073 | 34610 | 45354 | 0 | 20480 | 15 | 81 | 65986 | 94512 | 70976 | 70128 | 70976 |
| settle loop (new Promise + then) | 37 | 136 | 184 | 288 | 192 | 15 | 90 | 834 | 16384 | 3168 | 2240 | 3168 |
| combinator element (all, race) | 43 | 171 | 228 | 288 | 192 | 15 | 118 | 899 | 20480 | 3184 | 2256 | 3184 |
| small-live-set churn | 37 | 180 | 144 | 143 | 176 | 118 | 58 | 702 | 16384 | 2992 | 2096 | 2992 |
| churn against 300,000 retained | 21051 | 38601 | 50869 | 0 | 25088 | 15 | 50 | 89666 | 121808 | 134672 | 133888 | 134672 |

A small heap holds about a megabyte by capacity for a live set of 40 KiB:
two arenas sized for the next cycle, and the table. That is the price of
not asking the allocator for anything between collections.

## After a burst

The handle table never shrank and a sweep walked all of it. Two million
objects held and then dropped left every later collection of a tiny live
set taking 3 ms, and with the threshold back at its floor there was one
every 4,096 allocations.

The table now has an extent. When a large table's survivors all sit in
its lowest quarter, a sweep cuts the extent back to the highest of them,
takes the handles above it off the free list, and rebuilds a table left
under a quarter of the size its storage was made for. Sweeping from the
top down lists freed handles highest first, so allocation reuses the
lowest and survivors gather low. A table under 32,768 handles is walked
whole: its top survivor moves at every collection and its walk is cheap.

`spike.json`, the ints stage against the last:

| | Before (`ints`) | After (last) |
|---|---|---|
| The run | 1,408 ms | 664 ms |
| Collecting | 947 ms | 122 ms |
| Median pause | 3,425 us | 16 us |
| Longest pause (during the burst itself) | 44 ms | 47 ms |

What holds the memory afterwards, read at the end of the run
(`--mem-stats`) and while a copy of the workload idles after the burst
(`vmmap --summary`, four seconds in). These are present-state figures,
not high-water marks:

| | Before | After |
|---|---|---|
| Engine: alive at the last collection | not reported by that stage | 37 KiB |
| Engine: in use | 171 MB | 179 KiB |
| Engine: held by capacity, all arrays | not reported by that stage | 741 KiB |
| Allocator: in use | not reported by that stage | 814 KiB |
| Allocator: default zone, allocated (`vmmap`) | 408.6M | 871K |
| `MALLOC_LARGE`, in use (resident) | 201.6M | none |
| `MALLOC_LARGE (empty)` (resident, dirty) | 528.3M | 852.3M |
| `MALLOC_REALLOC` (resident) | 10.4M | none |
| Physical footprint, idling after the burst | 748.2M | 859.4M |
| Resident now, at the end of the run | not reported by that stage | 799 MB |
| Resident peak | not reported by that stage | 800 MB |

So the engine's part is settled by measurement: before the change it
still held 409 MB after the burst, and now it holds under a megabyte and
the allocator reports under a megabyte in use. What remains is in regions
`vmmap` labels `MALLOC_LARGE (empty)`: large blocks the engine has freed
that stay mapped. Whether they stay resident is not the engine's to
decide, and the recordings differ on it. Three readings of the same idle
copy, all four seconds in: standalone, 762 MB and 852 MB of those regions
resident and dirty (footprint 779 MB and 859 MB); taken straight after the
policy sweep in one batch (`spike-after-sweep.json`), none of it resident
(footprint 247 MB, 1.2 GB mapped), and the ints stage's own figure fell
the same way, from 748 MB to 214 MB. So the system does reclaim them, on
its schedule; when was not determined here, and nothing in the engine
refers to them. No allocator call or host interface is proposed.

## The floor

A collection is due after a number of cells allocated: the survivors of
the last one times a multiple, and never fewer than the floor. With small
live sets the floor is the policy; with large ones the multiple is.

Six small-live-set workloads, ranges across them (`policy.json`):

| Floor, cells | Wall time against 4,096 | Resident now | Median pause | Longest pause |
|---|---|---|---|---|
| 1,024 | +7% to +15% | 2.7 to 2.9 MB | 14 to 19 us | 34 to 109 us |
| 4,096 |  | 3.0 to 3.1 MB | 17 to 31 us | 35 to 147 us |
| 16,384 | -6% to +1% | 4.4 to 5.6 MB | 34 to 94 us | 68 to 218 us |
| 65,536 | -7% to +4% | 11.0 to 15.1 MB | 115 to 346 us | 147 to 431 us |

At the default floor collecting is 4 to 15% of these workloads, so that
is all a larger floor can win. 16,384 takes most of it for about two more
megabytes resident and median pauses two to three times as long; 65,536
wins nothing further and costs eight to twelve megabytes and pauses ten
times as long.

Survivors' multiple, large live sets:

| Multiple | 60,000 live cells | 300,000 retained |
|---|---|---|
| 150% | 70 collections, 100 ms collecting, 25.1 MB resident | 10 collections, 38 ms collecting, 106.2 MB resident |
| 200% | 53 collections, 84 ms collecting, 26.1 MB resident | 8 collections, 30 ms collecting, 130.6 MB resident |
| 300% | 36 collections, 67 ms collecting, 30.2 MB resident | 6 collections, 27 ms collecting, 159.0 MB resident |

The defaults stay at 4,096 cells and 200%. For an engine meant to be
embedded small, three megabytes resident and pauses near a tenth of a
millisecond are worth more than a few percent of throughput on
promise-heavy loops, and the multiple trades time for memory about one
for one. Both are fields of the heap, and `zjsz run --gc-floor N
--gc-growth P` sets them for measurement; nothing in the frozen ABI
reaches them.

## Reproducing

```
export Z_LANG=<a clone of z-lang at the revision in stages.json>
./z/build.sh                                            # once: the native backend and the tree's zjsz
./z/bench/alloc/run.py build-stages /tmp/stages         # one binary per stage, from its commit
./z/bench/alloc/run.py matrix /tmp/stages z/bench/alloc/results/matrix.json
./z/bench/alloc/run.py figures /tmp/stages/zjsz-base z/bench/alloc/results/figures-base.json
./z/bench/alloc/run.py figures /tmp/stages/zjsz-report z/bench/alloc/results/figures-final.json
./z/bench/alloc/run.py build-stage f7eb0b7 /tmp/stages/zjsz-arenas-counted z/bench/alloc/cell-counters.patch
./z/bench/alloc/run.py cells /tmp/stages/zjsz-arenas-counted z/bench/alloc/results/cells-before.json
./z/bench/alloc/run.py cells /tmp/stages/zjsz-report z/bench/alloc/results/cells-after.json
./z/bench/alloc/run.py policy /tmp/stages/zjsz-report z/bench/alloc/results/policy.json
./z/bench/alloc/run.py spike /tmp/stages/zjsz-ints /tmp/stages/zjsz-report z/bench/alloc/results/spike.json
./z/bench/alloc/tables.py                               # the tables above
./z/bench/alloc/run.py test                             # the runner's own checks
```

The runner builds a stage only from a clean compiler checkout at the
revision in `stages.json`; a child that fails or times out leaves its cell
without a figure rather than a wrong one. Each result embeds the
provenance of the binaries it was measured with (`z/bench/alloc/README.md`).
