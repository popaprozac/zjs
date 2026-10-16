# WeakMap / WeakSet: weak semantics in the collector

Status: implemented (`heap.zs`, Weak records; `builtins/collections.zs`).
Scope: `WeakMap` and `WeakSet` keys held weakly with ephemeron semantics.
Not in scope: `WeakRef`, `FinalizationRegistry`, generational or
concurrent collection, or any promise about when a collection happens.

## Representation

A weak collection's record is a `TAG_WEAK_RECORD` cell of five slots: the
keys and values arrays, an open-addressed index from key hash (the key's
cell handle, mixed) to entry position, the live count, and the kind. The
keys and values arrays are `TAG_WEAK_ARRAY` cells. `Map` and `Set` keep
their `TAG_ARRAY` records and pay nothing.

Private backing-storage invariant: the two weak arrays are reachable only
from their record. The collector never traces a `TAG_WEAK_ARRAY` cell's
elements, whatever path marked the cell, so even a stray strong reference
to one could not retain entries; and nothing hands them out -- the
builtins reach entries only through the heap's `weakFind` / `weakGet` /
`weakPut` / `weakDelete`, and `recordOf` returns the record. The heap's
`weakRecords` worklist exists only during a collection: it is filled by
`drainMarks` as records are reached and emptied by `clearDeadWeakEntries`;
it is never marked as a root.

## Collection order

`Runtime.collectGarbage`:

1. strong roots (registers, globals, frames, temporary roots, prototypes,
   atoms the compiled code and hidden classes hold), each drained. While
   draining, a weak record that is reached registers its entries: a
   value whose key is already marked is marked at once; the others wait
   in the pending table, indexed by key. When a key with waiting values
   is popped from the mark stack, its values are marked and traced in
   turn, and records reached through them register the same way. So the
   drain itself completes the ephemeron closure, in one visit per entry.
2. `markEphemerons`: a verification scan over the records reached; it
   marks nothing when the pending table did its job, and would continue
   to a fixpoint if it ever found something, so the collection is right
   either way.
3. `clearDeadWeakEntries`: entries whose key is unmarked are retired,
   each touched record compacted and its index rebuilt in place.
4. `rebuildAtoms`: the weak atom table, after the ephemeron work because
   values reached through it can hold interned strings.
5. `sweep`.

Clearing removes the record's references; a value with other references
survives. Steps 2 and 3 allocate nothing.

The pending table is collection-local Z-owned scratch (a chained hash
table over key handles: keys, values, next links, buckets), never a root:
a value waiting in it is not reachable through it, so a value that points
back at its own unmarked key stays unmarked and both are collected. It
grows only with the number of waiting entries -- nothing is added to cell
headers or to ordinary objects -- and is emptied at the end of every
collection, its capacity kept while under 256 KiB and released otherwise.
A Z allocation failure traps, as everywhere in the engine; marking is
never skipped.

## Storage

`weakPut` appends; a retired entry (explicit delete, or a dead key) leaves
the deleted marker in both arrays and a tombstone in the index. When the
index would pass three quarters full and retired entries are the larger
part, the arrays compact in place and the index rebuilds in the same
array; otherwise the index doubles (an allocation, only ever on
insertion). After a collection drops entries, the record compacts and
rebuilds at once. So a long-lived record's storage follows its live
count: the heap tests hold one record through 200 insert-50 / collect
cycles (keys array length back to 1 each time, index at most 128 slots,
10,000 entries cleared) and 100 rounds of explicit inserts and deletes
without a collection (arrays and index at most 64 slots).

## CanBeHeldWeakly

A key is an object or a symbol not in the global registry; well-known
symbols qualify, `Symbol.for` symbols do not (the registry flags them at
creation). `set`, `add`, `getOrInsert`, `getOrInsertComputed`, and the
constructors' iterables throw a TypeError for anything else; `get`
returns undefined and `has` / `delete` return false.

## Forced collection

`zjsz --expose-gc` defines `gc()`. It is a host function, so it runs at a
call site: the arguments and every register of the calling frames are
roots, the same state an ordinary collection sees at a return or a loop
back edge. Builtins that call back into the program (`getOrInsertComputed`,
the constructors' iterables) keep their key and receiver in the call's
registers and their iterator on the temporary-root stack, so a collection
inside the callback finds them. One property of a register machine
without liveness maps shows up in tests: a stale temporary in a still-open
frame (the array a loop indexed, say) is a root until the register is
reused, so a test that expects reclamation builds its garbage inside a
function and calls `gc()` after it returns.

## Evidence

Correctness: ten heap unit tests with explicit mark / sweep (rooted and
dropped keys, value-to-key cycle, value rooted elsewhere, both discovery
orders, a record discovered through a value, a 40-link reverse chain,
shared keys across records, an unreachable record, handle reuse, storage
across cycles); `tests/expect/weak-collections.js` (node-recorded) and
`weak-upsert.js` (from the proposal text; node 25 lacks the methods);
`gc-check.sh` on the engine's counters; test262 A/B for WeakMap,
WeakSet, Map, Set, and Symbol against the previous build: 0 regressions,
8 fixes.

Cost, `tests/gc/weak-pressure.js` (400,000 keys inserted and dropped
across a WeakMap and a WeakSet, 100 held, ordinary collections only):

| build | wall | live cells at exit | entries cleared |
|---|---|---|---|
| before | 0.075 s | 601,026 | (kept forever) |
| weak | 0.042 s | 3,769 | 398,170 |

Cost, an adversarial chain: record i maps key i to a holder of key i + 1,
only key 0 rooted, records discovered in reverse (the natural order when
they sit in an array, since marking pops its children last-first). The
first implementation rescanned every record per pass; the pending table
visits each entry once at registration and once in the verification scan.

| links | 1d4d5c9 passes | 1d4d5c9 gc() | pending passes | pending gc() | entry visits | scratch peak |
|---|---|---|---|---|---|---|
| 1,000 | 1,001 | 4 ms | 1 | 0 ms | 2,000 | 24 KiB |
| 10,000 | 10,001 | 310 ms | 1 | 2 ms | 20,000 | 384 KiB |
| 30,000 | 30,001 | 2,925 ms | 1 | 5 ms | 60,000 | 768 KiB |

The favourable order (1d4d5c9: 2 passes) costs the same in both. One key
across 100,000 records: 13 ms against 14 ms, 300,000 visits, 3 MiB of
scratch during the collection and none retained. 100,000 value-to-key
cycles, none rooted, clear in one pass either way. A chain of 10,000
records each reached through the previous one's value: 1 ms in both.
Ordinary workloads without weak collections are unchanged (integer loop,
calls, property access, arrays, strings, closures: within 1 percent, the
same allocator calls); the churn test (400,000 dropped keys under ordinary
collections) is 0.039 s against 0.040 s with ten more allocator calls for
the scratch. The binary is the same 735,544 bytes.
