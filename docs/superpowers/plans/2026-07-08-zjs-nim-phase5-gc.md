# ZJS Nim Phase 5 — GC + `Rooted[T]` (runtime memory foundation)

> **For agentic workers:** Port the proven Zen-c non-moving generational collector to Nim,
> with a RAII `Rooted[T]` rooting scheme. The object model (Phase-4 slice 4) is built ON this.
> All work on `nim-phase4` (→ `nim`); **never touch `main`**. Only add `nim/`, `docs/`, additive
> Makefile targets. Owner-endorsed approach (see memory `project_nim_gc_rootset`) — this is a
> PORT of the shipped design, not a redesign.

**Goal:** a per-`ctx` non-moving heap for JS cells with a mark/sweep collector, `Rooted[T]`
RAII rooting, and register-file + ctx root scanning — the memory foundation the object model,
closures, methods, and `new` allocate into. Chosen sequencing (owner, 2026-07-08):
**A = foundation (mark/sweep + nursery + Rooted[T]) → B = object model on it → C = generational.**

## Settled design (from the owner endorsement + recon)
- **Cell = raw `ptr`, NOT Nim `ref`.** Every heap cell begins with `CellHeader { typeTag, mark,
  age, inRem: uint8 }` (4 bytes, mirrors `src/value.zc:898`). A `ZjsValue` NaN-boxes the pointer
  (`cellFromPtr`/`cellAsPtr`, `src/value.zc:2926/2932`; `isCell` = `NOT_CELL_MASK`). Cells are
  **manually allocated from the JS-heap arena and collected by our GC** — `--mm:arc` governs only
  HOST code (seqs/strings/parser/compiler). **Non-moving** is mandatory (raw cell ptrs cross the
  C ABI to embedders; a moving GC can't relocate embedder-held cells).
- **Allocator = per-`ctx` (thread-local), non-moving chunked nursery** (64 KB chunks / 64 B slots,
  `NURSERY_CHUNK_SIZE`/`NURSERY_SLOT_SIZE`, `src/context.zc:292/293`), bump-allocate young,
  **promote in place** (set `AGE_OLD`, keep `AGE_IN_CHUNK`; cells never move). Size-class pools for
  larger cells. NO global bump state (that was the multi-worker segfault) — `ctx.nursery*`.
- **Root set:** primary = the **VM register file** (frame-precise scan; every active frame's regs
  are roots) + ctx roots (global object, realm intrinsics, pending exception, microtask queue) +
  the **`Rooted[T]` shadow-stack**. `Rooted` pushes a root slot on construction, pops it via
  `=destroy` → Nim locals holding `ZjsValue`s across allocating calls are safe BY CONSTRUCTION
  (V8 `Local` / SpiderMonkey `Rooted<T>`). This is what makes `collectMinor()` safe from the alloc
  fast path — the thing Zen-c deferred and hit the unrooted-C-local bug class on.
- **Collector:** mark (from all roots, following each cell's children per its `typeTag`) + sweep
  (free unmarked). Slice C adds generational: minor (nursery only, remembered-set roots from
  old→young), major (full), the ~54 write-barrier sites, `inRem` dedup. NO tri-color/incremental
  (the #1 GC bug class; revisit only if major-pause is measured-dominant — it isn't).

## Slice A — foundation (THIS SLICE)
1. **`nim/src/zjs/gc.nim`** (or extend value.nim): `CellHeader`; a `Ctx`/heap object holding the
   nursery (chunk list + bump ptr), the free/sweep list, the root structures. `allocCell(ctx,
   typeTag, size): pointer` — bump from the nursery chunk (new chunk when full); returns a zeroed
   cell with its header set. `cellFromPtr`/`cellAsPtr`/`isCell`/`cellHeader(v)` on `ZjsValue`.
2. **A minimal cell type to exercise it — `ObjCell`** (CellHeader + a small `seq`/inline array of
   `ZjsValue` fields). This is the SEED of the object model (slice B extends it with property
   semantics), so it is NOT throwaway. Fields hold `ZjsValue`s (some cells) → exercises interior
   marking. Plus verify a leaf cell (no children).
3. **`Rooted[T]`**: `ctx.rootStack: seq[ZjsValue]` (or a growable slot array). `rooted(ctx, v):
   Rooted` pushes a slot, `Rooted.value`/`[]` accesses the (possibly-updated) slot, `=destroy`
   pops. Nested scopes push/pop in LIFO order — assert on mismatch in debug. A `RootScope`/handle-
   scope batch variant is optional.
4. **Root scan** (`markRoots`): mark every `ZjsValue` in the VM's active frame register files
   (thread the frames so the GC can reach them — a `ctx.frames` stack the VM pushes/pops, or
   register the regs seqs), the ctx roots, and the `rootStack`. `markCell` recurses per `typeTag`
   (ObjCell → mark each field). Grey/black via the `mark` byte.
5. **`collect(ctx)`**: markRoots → sweep (walk all allocated cells, free `mark==0`, clear `mark==1`
   → 0 for survivors). For slice A, non-generational (full mark/sweep every time). Trigger: on
   alloc when the nursery is full (or an explicit `collect()` for tests).
6. **Integration + tests** `nim/tests/tgc.nim`: allocate N ObjCells, root a subset via `Rooted[T]`
   + a fake register file, `collect()`, assert the rooted set + their transitive children survive
   and the unrooted are freed (use a freed-cell canary / alloc-count). Stress: alloc in a loop
   forcing many collections, assert no crash + rooted survivors intact + memory bounded. Confirm
   the existing tvm/tcompiler/tparser suites still pass (host code unaffected).

## Validation
- Slice A is validated by **GC unit tests** (alloc/root/collect/survive-vs-free/stress) — GC is
  invisible to `zjs eval`, so the differential resumes in slice B. wrong-behavior (a rooted cell
  freed, or a dangling pointer) is a hard fail; leaking is acceptable in A only if `collect()`
  provably frees the unrooted set in the tests.
- Slice B (object model): objects/arrays as `typeTag` cell types on this heap; NewObject/LoadProp/
  StoreProp/LoadElem/etc.; differential vs `zjs eval` resumes (`({a:1}).a`, `[1,2,3][0]`,
  `"x".length`, capturing closures via env cells, methods, `new`).
- Slice C: promotion + minor/major + remembered set + write barriers; validated by the object
  differential holding under GC pressure (alloc-churn programs) + no crash.
