# WeakMap / WeakSet: weak semantics in the collector

Status: proposal, for review before implementation. Scope: `WeakMap` and
`WeakSet` keys held weakly, with the specified ephemeron semantics. Not
in scope: `WeakRef`, `FinalizationRegistry`, or any observable timing.

## What exists

A collection is an ordinary object holding a record under a hidden key
(`builtins/collections.zs`): an array cell of five slots -- the keys
array, the values array, an open-addressed index from key hash to entry
position, the live count, and the kind. `WeakMap` and `WeakSet` are the
same structure with kinds of their own and a key check (objects and
symbols; a registered symbol from `Symbol.for` is accepted today but must
be refused, which the slice corrects).
The collector (`heap.zs`, `markHandle` / `drainMarks` / `sweep`) traces
every slot of every marked cell, so a weak collection keeps its keys and
values alive as long as it is reachable. A key that the program has
dropped stays, with its value, until the collection itself dies.

## Proposed model

### Representation

The record of a weak collection is allocated with its own cell tag,
`TAG_WEAK_RECORD`, instead of `TAG_ARRAY`. Slot access is unchanged (the
record is never exposed to programs, and `recordOf` reads it by slot);
only the collector distinguishes it. `Map` and `Set` records keep
`TAG_ARRAY` and pay nothing.

### Marking: ephemerons

When `drainMarks` pops a `TAG_WEAK_RECORD` cell it marks the index,
size, and kind slots as usual, marks the keys and values array *cells*
shallowly (header marked so the sweep keeps them, elements not traced),
and appends the record to a worklist `weakRecords` held by the heap for
the duration of the collection. Nothing reachable only through a weak
record's entries is marked by this step.

After the roots have been drained, `markEphemerons` runs to a fixpoint:

```
repeat
  progressed = false
  for each record in weakRecords
    for each live entry (key, value)
      if key is marked and value is a cell not yet marked
        mark value; drain; progressed = true
until not progressed
```

A key is marked only by something other than its table; a value is
marked only once its key is. Draining a value may mark keys of this or
other records, which is why the loop repeats until a pass marks nothing.

- Value-to-key cycle: `wm.set(k, { back: k })` with `k` otherwise
  unreachable. `k` is never marked, so the value is never marked, so the
  cycle is collected. (A model that marked values whenever the table was
  reachable would keep `k` forever.)
- Transitive reachability: table A holds `k1 -> { k2 }`, table B holds
  `k2 -> v2`, and only `k1` is rooted. Pass 1 marks A's value, which
  marks `k2`; pass 2 marks `v2`; pass 3 marks nothing and ends.
- A weak record that is itself unreachable is never discovered, so its
  entries contribute nothing: its keys live or die by their other
  references, exactly as if the table did not exist.
- Keys reachable only through the values of a dead table die with it.

### Clearing

Between marking and sweeping, `clearDeadEntries` walks `weakRecords`: an
entry whose key cell is unmarked has its key and value slots set to the
deleted marker and the size decremented; the index slot for it becomes a
tombstone (the existing deletion path, so lookups already skip it). This
runs while dead cells still have headers, so mark bits are readable; the
values of cleared entries were never marked and the sweep frees them.
`weakRecords` is emptied at the end of the collection.

### Rooting

Keys and values held anywhere else -- registers, globals, frames, the
temporary-root stack, other objects -- are marked through those paths
before the ephemeron pass, so an entry whose key the program can still
reach always survives. The record is reached only from its collection
object. Handle reuse is safe: a dead key's handle can be reallocated only
after the sweep, and its entry was cleared before the sweep.

### Cost

Only weak records take the worklist path; the fixpoint costs
O(passes x live weak entries), with passes bounded by the length of the
longest key-through-value dependency chain (one or two in practice) plus
the terminating pass. No change to the hot mark loop for other tags
beyond the tag dispatch it already does.

## Tests (deterministic)

Collection is triggered explicitly, never by allocation pressure, in two
layers:

1. Heap unit tests (`heap.zs`), building records by hand and calling
   `markHandle`, `markEphemerons`, and `sweep` directly:
   - rooted key: entry and value survive; dropped key: entry cleared,
     value freed (cell counts exact);
   - value-to-key cycle collected;
   - transitive chain across two records survives in the right order
     (the pass count observed, not assumed);
   - unreachable record: its keys are not kept by it;
   - `WeakSet` (key is the value) behaves the same;
   - a record whose entries were cleared still answers lookups for the
     surviving keys (index tombstones).
2. Expectation cases (`z/tests/expect`), run by `zjsz` with a `gc()`
   global exposed only under a new `--expose-gc` flag (as node's
   `--expose-gc`): scripts that drop keys, call `gc()`, and observe `has`
   / `get` on keys they still hold, plus `--stats` cell counts before and
   after for the dropped side. Recorded from node with the same flag.

## Not proposed

`WeakRef`, `FinalizationRegistry`, cleanup callbacks, or any promise about
when a collection happens. Symbol keys are cells like objects and take the
same marking path; nothing further is added for them.
