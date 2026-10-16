# zjs Phase 3.2b — Inline Caches

> Decision 5 from the Phase 1 design study. Per-call-site cache of
> `{HiddenClass*, slot_idx}` stashed in a per-Function metadata table.
> On hit (class matches), property access is **one pointer compare +
> one indexed load**. On miss, fall through to the existing
> `property_get` / `property_set` and patch the cache in place.
>
> This is where the hidden-class work from 3.2a pays off.
>
> No mprotect, no icache flush, no runtime codegen — the cache is
> data, not code. LLInt has shipped to billions of devices on this
> exact pattern.

## Scope

In scope:
- New cell type **stays inside `Function`** (no separate cell): each `Function` gains an `ics: ICEntry*` table sized at compile time
- `ICEntry { name: ZjsString*, class_: ZjsHiddenClass*, slot: u32 }`
- Two new opcodes:
  - `LoadProp dst, obj_reg, ic_slot`
  - `StoreProp obj_reg, ic_slot, val_reg`
- Compiler emits these for `Member` access (`obj.name`) and for `=`-form Member assignment (`obj.name = val`); compound forms (`obj.x += 1`) keep using LoadElem/StoreElem for now
- Each call site at compile time allocates a fresh IC slot, sets `ic.name` to the property atom, leaves `ic.class_ = NULL` (uninitialized — first execution warms it)
- Fast path:
  - `obj` is an object AND `obj.cls == ic.class_` → `regs[dst] = obj.slots[ic.slot]` (or the analogous store)
- Slow path:
  - Anything else → call into `property_get`/`property_set` and patch the IC if `obj` is now an object that has the property

Out of scope:
- **Polymorphic ICs** — we cache exactly one class per call site. A site that sees multiple shapes thrashes (each miss overwrites the entry). Real engines maintain a small PIC chain; we'll add that when profiling says it matters.
- **Computed access ICs** (`obj[expr]` where expr is dynamic) — stays on the LoadElem path
- **Array index ICs** — same; arrays don't use hidden classes anyway
- **Method-binding caching** for calls through a member (`obj.method()`)

## Format

```c
struct ICEntry {
    ZjsString*       name;    /* the atom this site queries; set at compile time */
    ZjsHiddenClass*  class_;  /* last-seen class, NULL = uninitialized          */
    uint32_t         slot;    /* slot index in that class                       */
};

struct Function {
    /* ... existing ... */
    ICEntry*   ics;
    uint32_t   ic_count;
};
```

`ic_slot` is a u8 in the bytecode encoding — max 256 IC sites per
function. That covers anything we'll generate from realistic source.
A function with >256 property-access sites is unusual; we'd fall back
to LoadElem when we exceed.

## Fast / slow split (LoadProp pseudocode)

```
ic = &f.ics[c]
if is_object(regs[b]) AND regs[b].obj.cls == ic.class_:
    regs[a] = regs[b].obj.slots[ic.slot]
else:
    regs[a] = property_get(ctx, regs[b], ic.name)
    if is_object(regs[b]):
        s = class_find_slot(regs[b].obj.cls, ic.name)
        if s >= 0:
            ic.class_ = regs[b].obj.cls
            ic.slot   = s
```

StoreProp is symmetric — fast-path writes the slot directly when the
class matches; slow path goes through `property_set` (which handles
class transitions for new properties) and then updates the IC against
the post-store class.

## GC

The IC table holds two pointer kinds:
- `name`: an atom — pinned via the atom-table root walk
- `class_`: a HiddenClass — must be marked when its owning Function
  is marked, so we don't sweep a class that an IC still points at

Marking extension: `gc_mark_value` on `TAG_FUNCTION` already walks
the constants pool; it now also walks `f.ics[i].class_` for each
non-NULL entry.

## Verification

Behaviorally identical to 3.2a. The full test suite passes. New
smoke checks:
- A `Member` access reading the same property repeatedly through the
  same source line should produce the same value each time (obvious
  but the IC's update logic could plausibly miscache)
- Two objects of the same shape, both accessed through the same call
  site, both work (IC matches the shared class)
- Two objects of different shapes through the same site both work
  (cache miss → slow path → cache is updated to the most-recent
  shape, with the older shape going slow next time)
- Reassigning a property uses the same IC slot
- A LoadProp / StoreProp pair on the same property warms the IC,
  then GC, then more accesses still work (cache survives GC because
  the class is reachable via the IC)

## What's next

This is the natural pause point for the perf-arc push. Possible
follow-on directions:
- **Polymorphic IC chains** (2-3 entries) when profiling shows
  thrashing
- **Hidden class for arrays** so `arr.length` (currently a
  hand-coded special case) caches like any property
- **Method binding cache** for `obj.foo()` patterns
- **More built-ins** to grow test262 (`Object.*`, `Array.prototype.*`,
  `String.prototype.*`)
- **Closures + for-in/for-of execution** to run more real-world JS
- **AOT bytecode bundles** (Decision 9 from the design study)
