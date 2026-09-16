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
   atoms the compiled code and hidden classes hold), each drained;
2. `markEphemerons`: to a fixpoint over `weakRecords`, a value is marked
   once its key is marked; marking a value can reach further keys and
   further weak records (which `drainMarks` appends to the worklist and
   the same fixpoint then covers);
3. `clearDeadWeakEntries`: entries whose key is unmarked are retired,
   each touched record compacted and its index rebuilt in place;
4. `rebuildAtoms`: the weak atom table, after the ephemeron pass because
   values reached through it can hold interned strings;
5. `sweep`.

Clearing removes the record's references; a value with other references
survives. Nothing allocates during steps 2 and 3.

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
across cycles); `z/tests/expect/weak-collections.js` (node-recorded) and
`weak-upsert.js` (from the proposal text; node 25 lacks the methods);
`z/gc-check.sh` on the engine's counters; test262 A/B for WeakMap,
WeakSet, Map, Set, and Symbol against the previous build: 0 regressions,
8 fixes.

Cost, `z/tests/gc/weak-pressure.js` (400,000 keys inserted and dropped
across a WeakMap and a WeakSet, 100 held, ordinary collections only):

| build | wall | live cells at exit | entries cleared |
|---|---|---|---|
| before | 0.075 s | 601,026 | (kept forever) |
| weak | 0.042 s | 3,769 | 398,170 |

The repeated scan is quadratic on an adversarial chain: record i maps key
i to a holder of key i + 1, only key 0 rooted, records discovered in
reverse (the natural order when they sit in an array, since marking pops
its children last-first). Each pass frees one more link:

| links | passes | gc() |
|---|---|---|
| 200 | 201 | 1 ms |
| 1,000 | 1,001 | 5 ms |
| 3,000 | 3,001 | 32 ms |
| 10,000 | 10,001 | 367 ms |
| 30,000 | 30,001 | 3.4 s |

The same chain discovered in the favourable order takes 2 passes, and
with nothing rooted every entry clears in 1. A worklist keyed by newly
marked keys would make the adversarial case linear; it is not needed for
any real workload seen and is left as a follow-up.
