# WeakMap / WeakSet: weak semantics in the collector

`WeakMap` and `WeakSet` keys held weakly with ephemeron semantics
(`heap.zs`, Weak records; `builtins/collections.zs`). Not covered:
`WeakRef`, `FinalizationRegistry`, or any promise about when a collection
happens.

## Representation

A weak collection's record is a `TAG_WEAK_RECORD` cell of five slots: the
keys and values arrays, an open-addressed index from key hash (the key's
cell handle, mixed) to entry position, the live count, and the kind. The
keys and values arrays are `TAG_WEAK_ARRAY` cells. `Map` and `Set` are
`TAG_TABLE` cells and pay nothing.

Private backing-storage invariant: the two weak arrays are reachable only
from their record. The collector never traces a `TAG_WEAK_ARRAY` cell's
elements, whatever path marked the cell, so even a stray strong reference
to one could not retain entries; and nothing hands them out -- the
builtins reach entries only through the heap's `weakFind` / `weakGet` /
`weakPut` / `weakDelete`, and `recordOf` returns the record. The heap's
`weakRecords` worklist exists only during a full collection: `traceCell`
fills it as the marking reaches records, and `clearDeadWeakEntries`
empties it; it is never marked as a root.

## Collection order

Only a full collection clears weak entries. A minor collection holds the
young elements of a weak array as it holds any cell's, so a dead young
key waits for the next full collection.

A full collection's marking, whole or in slices, traces a weak record
like any cell (its index and counts, and its two weak arrays as cells),
lists it, and reaches nothing through a weak array's elements. When the
marking is done, `Runtime.dropDeadEntries` runs:

1. `markEphemerons`: each listed record registers its entries. A value
   whose key is marked is marked at once; the others wait in the pending
   table, indexed by key, and a key with waiting values that is traced
   later marks its values in turn. Records reached on the way are listed
   and registered the same way. Then a verification scan over the
   records marks the value of any marked key still unmarked, to a
   fixpoint; it marks nothing when the pending table did its job, so the
   collection is right either way.
2. `clearDeadWeakEntries`: entries whose key is unmarked are retired,
   each touched record compacted and its index rebuilt in place.
3. `rebuildAtoms`: the weak atom table, after the ephemeron work because
   values reached through it can hold interned strings.

The sweep follows: at once for a whole collection (`finishWhole`), in
slices after `endMark` otherwise.

Clearing removes the record's references; a value with other references
survives. Steps 1 and 2 allocate no cells; only the pending table's own
arrays grow.

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

`zjsz run --expose-gc` defines `gc()`. It is a host function, so it runs at a
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

Correctness: the heap's unit tests in `engine/heap.zs`, with explicit
mark and sweep (rooted and dropped keys, value-to-key cycle, value
rooted elsewhere, both discovery orders, a record discovered through a
value, a reverse chain, shared keys across records, an unreachable
record, handle reuse, storage across cycles);
`tests/expect/weak-collections.js` (recorded from node) and
`weak-upsert.js` (written from the proposal text); `gc-check.sh` on the
engine's counters, including `tests/gc/weak-pressure.js` (keys inserted
and dropped across a WeakMap and a WeakSet, some held, ordinary
collections only).

Cost: the pending table visits each entry once at registration and once
in the verification scan, so an adversarial chain (record i maps key i
to a holder of key i + 1, only key 0 rooted, records discovered in
reverse, the natural order when they sit in an array) clears in one
pass. Its scratch lives only during the collection.
