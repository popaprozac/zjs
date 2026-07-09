## ZJS Nim Phase 5 — Slice A: GC memory foundation.
##
## A per-heap, NON-MOVING cell allocator + mark/sweep collector + a
## RAII `Rooted` rooting scheme. This is a PORT of the shipped Zen-c
## design (src/value.zc CellHeader ~898, src/context.zc nursery ~292),
## trimmed to the foundation: full mark/sweep, no generational split,
## no promotion / remembered-set / write-barriers (that is slice C).
##
## Golden rules that make this correct:
##   * Cells NEVER move. A `ZjsValue` NaN-boxes a raw `ptr`; embedders may
##     hold that pointer across the C ABI, so relocation is forbidden.
##   * Host memory (seqs/strings) is `--mm:arc`-managed. Only the JS CELL
##     heap is manual (`alloc0` / `dealloc`, raw `ptr`).
##   * A rooted cell — or anything transitively reachable from a root —
##     MUST survive `collect()`. The unrooted set MUST be freed.
##
## Root sources scanned by `markRoots`:
##   (a) the `Rooted` shadow-stack (`heap.rootStack`), a slot per live
##       `Rooted`; the slot holds the CURRENT value, so reassigning
##       through a `Rooted` retargets what stays alive;
##   (b) registered VM frame register files (`heap.frameRoots`); the VM
##       wires real frames in slice B — the tests populate these directly;
##   (c) stubbed ctx roots (`heap.ctxRoots`) — global object, intrinsics,
##       pending exception, microtask queue land here in slice B.

import value
import std/tables

# =====================================================================
# CellHeader — the first 4 bytes of every heap cell. Mirrors
# src/value.zc:898 field-for-field so the layout is portable to the
# C ABI later. {.packed.} guarantees the 4-byte, no-padding shape.
# =====================================================================

const
  NURSERY_CHUNK_SIZE* = 65536   ## src/context.zc:292 — 64 KB nursery chunks
  NURSERY_SLOT_SIZE*  = 64      ## src/context.zc:293 — 64 B slot granularity

type
  CellHeader* {.packed.} = object
    typeTag*: uint8   ## which cell kind — drives the mark recursion
    mark*:    uint8   ## GC mark bit; 0 = white (unreachable), 1 = reachable
    age*:     uint8   ## AGE_OLD / AGE_IN_CHUNK bitmask (unused in slice A)
    inRem*:   uint8   ## remembered-set dedup flag (unused in slice A)

# Cell type tags. Slice A only needs a couple; the real object model
# extends this in slice B. Values are local to Nim (no need to match the
# Zen-c TAG_* numbering yet — cells are GC-internal until the C ABI).
const
  TAG_OBJ*  = 1'u8    ## ObjCell: header + nfields + inline ZjsValue[]
  TAG_LEAF* = 2'u8    ## a childless cell (mark recursion terminates)

# =====================================================================
# cellHeader — reinterpret a boxed cell value as its header. UB (as in
# Zen-c) if `v` is not a cell; callers gate on isCell first.
# =====================================================================

proc cellHeader*(v: ZjsValue): ptr CellHeader {.inline.} =
  cast[ptr CellHeader](cellAsPtr(v))

# =====================================================================
# ObjCell — the SEED of the object model (slice B grows property
# semantics on top). Layout:
#
#   [ CellHeader (4) ][ nfields: uint32 (4) ][ ZjsValue fields[nfields] ]
#
# Fields are INLINE (one allocation, no separate fields buffer) so a
# cell is a single contiguous block the sweep frees with one `dealloc`.
# =====================================================================

type
  ObjCell* {.packed.} = object
    header*:  CellHeader
    nfields*: uint32
    ## fields follow immediately in memory; addressed via `fieldPtr`.

proc fieldsBase(o: ptr ObjCell): ptr UncheckedArray[ZjsValue] {.inline.} =
  ## Address of the inline fields array (right after the fixed prefix).
  cast[ptr UncheckedArray[ZjsValue]](
    cast[uint](o) + uint(sizeof(ObjCell)))

proc objCellByteSize(nfields: uint32): int {.inline.} =
  sizeof(ObjCell) + int(nfields) * sizeof(ZjsValue)

# =====================================================================
# GcHeap — standalone heap object (later hangs off ctx). Owns the
# non-moving chunked nursery, the all-cells list for sweep, and every
# root structure.
# =====================================================================

type
  NurseryChunk = object
    mem:  pointer   ## a 64 KB block from alloc0
    used: int       ## bytes consumed by the bump pointer

  CellRec = object
    p:    pointer   ## the cell block
    size: int       ## its rounded byte size (free-list bucket key)

  GcHeap* = object
    chunks:     seq[NurseryChunk]        ## non-moving nursery chunks
    allCells:   seq[CellRec]             ## every live cell, for sweep
    ## Free list of reclaimed slots, keyed by rounded byte-size. Sweep
    ## pushes each dead cell's block here; allocCell pops a same-size
    ## block before bumping. Reuse (not chunk growth) is what keeps live
    ## memory BOUNDED across the stress test — cells still never move,
    ## the block just gets a new tenant.
    freeBySize: Table[int, seq[pointer]]
    rootStack*: seq[ZjsValue]            ## the Rooted shadow-stack (a)
    frameRoots*: seq[ptr seq[ZjsValue]]  ## registered VM frames (b)
    ctxRoots*:  seq[ZjsValue]            ## stubbed ctx roots (c)
    totalAllocated*: int                 ## lifetime cells handed out
    totalFreed*:     int                 ## lifetime cells swept

proc newGcHeap*(): GcHeap =
  ## A fresh empty heap. `GcHeap` is a value; keep it in a `var` the
  ## whole program shares (the tests do), because its manual cells and
  ## chunks are freed only via `collect` / `destroyHeap`.
  result = GcHeap()

# --- nursery bump allocator ------------------------------------------

proc newChunk(): NurseryChunk =
  NurseryChunk(mem: alloc0(NURSERY_CHUNK_SIZE), used: 0)

proc roundUpToSlot(size: int): int {.inline.} =
  ## Round `size` up to the 64 B slot granularity.
  (size + (NURSERY_SLOT_SIZE - 1)) and not (NURSERY_SLOT_SIZE - 1)

proc bumpAlloc(heap: var GcHeap, need: int): pointer =
  ## Bump `need` (already slot-rounded) bytes from the current chunk,
  ## opening a new 64 KB chunk when the current one can't fit. Cells
  ## larger than a chunk get a dedicated oversize chunk sized to fit.
  if heap.chunks.len == 0:
    heap.chunks.add(newChunk())
  var cur = addr heap.chunks[^1]
  if cur.used + need > NURSERY_CHUNK_SIZE:
    if need > NURSERY_CHUNK_SIZE:
      # Oversize cell: give it its own exactly-sized chunk so the bump
      # invariant (one contiguous block per cell) still holds and it is
      # still freed as a chunk on destroyHeap.
      heap.chunks.add(NurseryChunk(mem: alloc0(need), used: need))
      return heap.chunks[^1].mem
    heap.chunks.add(newChunk())
    cur = addr heap.chunks[^1]
  let p = cast[pointer](cast[uint](cur.mem) + uint(cur.used))
  cur.used += need
  result = p

proc allocCell*(heap: var GcHeap, typeTag: uint8, size: int): pointer =
  ## Allocate a zeroed cell of at least `size` bytes, slot-rounded. Reuses
  ## a reclaimed same-size block when one is available (bounded memory),
  ## else bumps from the nursery. Sets header.typeTag, mark=0, age=0,
  ## inRem=0. Records it in the all-cells list. NEVER moves after return.
  let need = roundUpToSlot(max(size, sizeof(CellHeader)))
  var p: pointer
  if heap.freeBySize.hasKey(need) and heap.freeBySize[need].len > 0:
    p = heap.freeBySize[need].pop()
    # Reused block: wipe it so no stale field values leak into the new
    # tenant (fields the caller doesn't init would otherwise be garbage,
    # and a stale cell-looking ZjsValue would mis-mark).
    zeroMem(p, need)
  else:
    p = bumpAlloc(heap, need)   # alloc0'd, already zero
  let h = cast[ptr CellHeader](p)
  h.typeTag = typeTag
  h.mark = 0
  h.age = 0
  h.inRem = 0
  heap.allCells.add(CellRec(p: p, size: need))
  inc heap.totalAllocated
  result = p

# --- ObjCell allocation + field access -------------------------------

proc allocObjCell*(heap: var GcHeap, nfields: uint32): ptr ObjCell =
  ## Allocate an ObjCell with `nfields` fields, all initialized to
  ## `undefined`. A 0-field cell is a valid leaf (its mark recursion
  ## terminates immediately).
  let p = allocCell(heap, TAG_OBJ, objCellByteSize(nfields))
  let o = cast[ptr ObjCell](p)
  o.nfields = nfields
  if nfields > 0:
    let f = fieldsBase(o)
    for i in 0 ..< int(nfields):
      f[i] = undefinedVal()
  result = o

proc getField*(o: ptr ObjCell, i: uint32): ZjsValue {.inline.} =
  assert i < o.nfields
  fieldsBase(o)[int(i)]

proc setField*(o: ptr ObjCell, i: uint32, v: ZjsValue) {.inline.} =
  assert i < o.nfields
  fieldsBase(o)[int(i)] = v

proc allocLeafCell*(heap: var GcHeap): ZjsValue =
  ## A childless cell — exercises the recursion-terminating path.
  cellFromPtr(allocCell(heap, TAG_LEAF, sizeof(CellHeader)))

# =====================================================================
# Rooted — RAII rooting. Construction pushes a slot on the shadow-stack;
# `=destroy` pops it (LIFO, asserted). Because the slot lives in the
# root stack and holds the CURRENT value, a `let r = rooted(heap, cell)`
# keeps `cell` (and its children) alive across an intervening collect,
# and `r[] = other` retargets the root.
# =====================================================================

type
  Rooted* = object
    heap: ptr GcHeap
    idx:  int          ## this root's index in heap.rootStack

# =destroy / =copy declared IMMEDIATELY after the type so no implicit
# hooks are bound first (Nim errors if a proc constructs a Rooted before
# the user destroy is seen).
proc `=destroy`*(r: Rooted) =
  ## Pop this root. Rooteds MUST be destroyed in reverse construction
  ## order (Nim locals in a scope destroy LIFO, which this asserts).
  if r.heap != nil:
    assert r.idx == r.heap.rootStack.high,
      "Rooted popped out of LIFO order (idx " & $r.idx & " != top " &
        $r.heap.rootStack.high & ")"
    r.heap.rootStack.setLen(r.heap.rootStack.len - 1)

proc `=copy`*(dst: var Rooted, src: Rooted) {.error:
  "Rooted is a non-copyable RAII handle".}

proc rooted*(heap: var GcHeap, v: ZjsValue): Rooted =
  ## Push a root slot holding `v` and return the handle.
  heap.rootStack.add(v)
  Rooted(heap: addr heap, idx: heap.rootStack.high)

proc value*(r: Rooted): ZjsValue {.inline.} =
  ## Read the current value of the root slot.
  r.heap.rootStack[r.idx]

proc `[]`*(r: Rooted): ZjsValue {.inline.} =
  r.heap.rootStack[r.idx]

proc `[]=`*(r: Rooted, v: ZjsValue) {.inline.} =
  ## Retarget the root: GC now keeps `v` (not the old value) alive.
  r.heap.rootStack[r.idx] = v

# =====================================================================
# Marking. `markCell` follows a cell's children per its typeTag; the
# mark bit makes it cycle-safe (a cell already marked is not re-visited,
# so a fields-cycle terminates).
# =====================================================================

proc markCell*(v: ZjsValue) =
  if not isCell(v):
    return
  let h = cellHeader(v)
  if h.mark != 0:
    return                      # already reachable — cycle-safe stop
  h.mark = 1
  case h.typeTag
  of TAG_OBJ:
    let o = cast[ptr ObjCell](cellAsPtr(v))
    let f = fieldsBase(o)
    for i in 0 ..< int(o.nfields):
      markCell(f[i])            # interior marking of field values
  of TAG_LEAF:
    discard                     # no children
  else:
    discard                     # unknown tag: treat as leaf (safe)

proc markRoots*(heap: var GcHeap) =
  ## Mark from every root source. Order is irrelevant (mark is idempotent).
  for v in heap.rootStack:
    markCell(v)
  for fr in heap.frameRoots:
    if fr != nil:
      for v in fr[]:
        markCell(v)
  for v in heap.ctxRoots:
    markCell(v)

# =====================================================================
# collect — full mark/sweep. Returns the count of cells freed.
# =====================================================================

proc collect*(heap: var GcHeap): int =
  ## Mark from all roots, then sweep the all-cells list. Each unmarked
  ## (white) cell is "freed": its block is zeroed and returned to the
  ## same-size free list for reuse (cells never move; the block is
  ## chunk-backed, so we recycle rather than dealloc — that is what keeps
  ## live memory BOUNDED under churn). Survivors' mark bit is cleared for
  ## the next cycle. Returns the count freed. Full mark/sweep, every time.
  markRoots(heap)
  var survivors: seq[CellRec] = @[]
  var freed = 0
  for rec in heap.allCells:
    let h = cast[ptr CellHeader](rec.p)
    if h.mark == 0:
      # Unreachable. Zero the block (poisons any stale ZjsValue so a
      # dangling read fails an isCell/tag check loudly) and recycle it.
      zeroMem(rec.p, rec.size)
      heap.freeBySize.mgetOrPut(rec.size, @[]).add(rec.p)
      inc freed
    else:
      h.mark = 0                # reset for the next collection
      survivors.add(rec)
  heap.allCells = survivors
  heap.totalFreed += freed
  result = freed

proc liveCellCount*(heap: GcHeap): int {.inline.} =
  heap.allCells.len

proc reservedBytes*(heap: GcHeap): int =
  ## Total nursery memory reserved (sum of chunk capacities). The stress
  ## test asserts this stays BOUNDED — freed blocks are reused, so churn
  ## does not grow the chunk set without limit.
  for c in heap.chunks:
    result += (if c.used > NURSERY_CHUNK_SIZE: c.used else: NURSERY_CHUNK_SIZE)

proc destroyHeap*(heap: var GcHeap) =
  ## Release ALL cell memory (every nursery chunk) and clear the heap.
  ## Call at end of life; after this the heap holds no cells.
  for c in heap.chunks:
    dealloc(c.mem)
  heap.chunks.setLen(0)
  heap.allCells.setLen(0)
  heap.freeBySize.clear()
  heap.rootStack.setLen(0)
  heap.frameRoots.setLen(0)
  heap.ctxRoots.setLen(0)
