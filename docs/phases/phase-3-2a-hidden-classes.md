# zjs Phase 3.2a — Hidden Classes (Transition Trees)

> Decision 6 from the Phase 1 design study. Replaces dictionary-mode
> object property storage with a transition-tree shape model — every
> object carries a `HiddenClass*`, properties transition along atom-keyed
> edges, and value storage moves to a fixed-size `slots` array indexed
> by `(class, slot)`.
>
> By itself this is a wash perf-wise. The payoff lands in Phase 3.2b
> when inline caches use `{HiddenClass*, slot}` as a per-call-site
> cache key — at which point property access becomes one pointer
> compare + one indexed load on the hot path.

## Scope

In scope:
- New cell type `ZjsHiddenClass` (`TAG_HIDDEN_CLASS = 5`)
- Each `ZjsContext` holds a root **empty class** shared by every fresh `{}`
- Transition tree:
  - Each class records `parent`, `transition_name` (atom), `transition_slot`, `prop_count`
  - Each class has parallel `trans_names[]` + `trans_children[]` arrays — the outgoing edges
- `ZjsObject` redesigned: `{ cls, slots, slot_cap }` (dropping the old `props/prop_count/prop_cap`)
- `object_get(obj, name)` — walks the parent chain comparing atom pointers; returns `obj.slots[slot]` on hit, `undefined` on miss
- `object_set(obj, name, value)` — fast path: existing property, just write the slot. New property: follow or create a transition, grow slots if needed, update `obj.cls`
- GC integration: hidden classes are reachable through objects; classes mark their parent + child transitions; once allocated, classes live as long as any object holds them (or any parent of those does)
- `ctx_new_object` initializes with the root empty class and no slots

Out of scope (later):
- **Inline caches** — Phase 3.2b
- **Dictionary-mode fallback** when an object accumulates many properties or sees a delete — fine for now; we don't implement `delete obj.x`
- **Hash table on classes for O(1) transition lookup** — linear search for now (transition counts are small)
- **Class merging / shape sharing across contexts** — each context has its own root class
- **Iteration in insertion order** for `for-in` — would need to reverse the parent-chain walk; deferred until for-in/of execution lands

## Walk-through

```js
let o1 = {};            // o1.cls = empty_class
o1.a = 1;               // empty.transitions["a"] -> C1 (slot 0, prop_count 1)
                        // o1.slots[0] = 1, o1.cls = C1
o1.b = 2;               // C1.transitions["b"] -> C2 (slot 1, prop_count 2)
                        // o1.slots[1] = 2, o1.cls = C2

let o2 = {};            // o2.cls = empty_class
o2.a = 10;              // empty.transitions["a"] exists -> C1 (reuse!)
                        // o2.slots[0] = 10, o2.cls = C1
o2.b = 20;              // C1.transitions["b"] exists -> C2 (reuse!)
                        // o2.slots[1] = 20, o2.cls = C2

// o1.cls == o2.cls now. The IC machinery in 3.2b will exploit this.
```

Read: walking the chain leaf→root finds the slot.
- `o1.a`: walk C2 (transition_name="b") → C1 (transition_name="a", match!) → slot 0 → o1.slots[0] = 1.

If the property doesn't exist, the walk reaches the root (`parent == NULL`) and returns undefined.

## Storage model

```c
struct ZjsHiddenClass {
    CellHeader        header;        // { type_tag = TAG_HIDDEN_CLASS }
    ZjsHiddenClass*   parent;        // NULL for the root empty class
    ZjsString*        transition_name;   // atom added going parent -> this; NULL for root
    uint32_t          transition_slot;   // slot index for transition_name; 0 for root
    uint32_t          prop_count;        // total props in this class (= parent.prop_count + 1)

    // Outgoing transition edges. Parallel arrays so we don't need a
    // ClassTrans struct (Zen-c forward decls are awkward).
    ZjsString**       trans_names;
    ZjsHiddenClass**  trans_children;
    uint32_t          trans_count;
    uint32_t          trans_cap;
};

struct ZjsObject {
    CellHeader        header;        // { type_tag = TAG_OBJECT }
    ZjsHiddenClass*   cls;
    ZjsValue*         slots;
    uint32_t          slot_cap;
};
```

Object's effective `prop_count` is `obj.cls->prop_count`. We grow `slots` geometrically; `slot_cap` may exceed `prop_count`.

## GC

`gc_mark_value` extended for `TAG_HIDDEN_CLASS`: walk parent + every child. Atom names are pinned via the atom-table root walk, so we don't need to re-mark them.

`gc_sweep` dispatches on tag like before; a new `hidden_class_free_void` releases the transitions arrays + the class struct.

## Verification

Behavior should be identical to dict-mode for every existing test.
Plus new tests:
- Two `{a, b}` literals share a class (observable: cell count grows by fewer per-object after the first)
- Property access still produces correct values
- Reassigning a property doesn't churn classes
- Property addition order matters (`{a: 1, b: 2}` ≠ `{b: 2, a: 1}` in class identity, but same in lookup result)
- Nested objects work
- GC keeps live classes alive

## What's next

Phase 3.2b — inline caches. The `LoadElem` opcode gains a per-call-site cache: `{HiddenClass*, slot_idx}` stashed in a per-CodeBlock metadata table. On hit (class matches), the access is one pointer compare + one indexed load. On miss, fall through to `object_get` and update the cache.

That's where hidden classes become a perf win.
