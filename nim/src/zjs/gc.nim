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
import bytecode          # `Function` — a FunctionCell's payload (ARC side table)
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
  TAG_OBJ*      = 1'u8 ## ObjCell: header + nfields + inline ZjsValue[]
  TAG_LEAF*     = 2'u8 ## a childless cell (mark recursion terminates)
  TAG_OBJECT*   = 3'u8 ## ObjectCell: header only; props live in heap.objTable
  TAG_ARRAY*    = 4'u8 ## ArrayCell:  header only; elems live in heap.arrTable
  TAG_FUNCTION* = 5'u8 ## FunctionCell (slice B2): header only; the Function
                       ## ref + captured env live in heap.funcTable. This is
                       ## how a closure VALUE round-trips through an object
                       ## property (the side table stores ZjsValues, not the
                       ## VM's vkFunction variant) — box on store, unbox on
                       ## load. Its `env` is a GC root (marked below).
  TAG_STRING*   = 6'u8 ## StringCell (Phase 6 slice 1): header only; the UTF-8
                       ## bytes live in heap.strTable (ARC-managed host string).
                       ## This is how a STRING VALUE round-trips through an
                       ## object/array side table (which holds ZjsValues, not
                       ## the VM's vkString variant) — box on store, unbox on
                       ## load. A leaf (no cell children); marked reachable by
                       ## the generic mark bit so a string held by a live
                       ## object/array survives collect.
  TAG_HOSTFN*   = 7'u8 ## HostFnCell (Phase 6 slice 2): a Nim-implemented
                       ## native/host function boxed as a GC cell (mirrors the
                       ## reference TAG_HOST_FUNCTION, src/context.zc:3993). The
                       ## cell is a pure header; the native proc pointer, name,
                       ## and arity live in heap.hostFnTable (ARC-managed host
                       ## memory). Because it is a boxed ZjsValue it lives
                       ## uniformly in a global slot AND as an object property.
                       ## A leaf: the proc pointer and name are host memory, not
                       ## GC children — marked reachable by the generic mark bit
                       ## so a native held by a live global/object survives.

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

  ## Slice B1 property table for an ObjectCell. Parallel arrays keep
  ## INSERTION ORDER (needed for future enumeration + the write_value
  ## printer). `names[i]` is the property key, `values[i]` its ZjsValue.
  ## The seqs are ARC-managed HOST memory kept in `heap.objTable` keyed by
  ## the cell block pointer — so the raw GC cell stays a pure header (safe
  ## to zeroMem/recycle on sweep) while the value contents are still
  ## reachable-marked via markCell.
  ObjProps* = object
    names*:  seq[string]
    values*: seq[ZjsValue]

  ## Payload of a FunctionCell (slice B2): the compiled `Function` and the
  ## captured environment object (a ZjsValue — an ObjectCell for a real
  ## closure, or `undefined` for a non-capturing function). Kept in an
  ## ARC-managed side table keyed by the cell block pointer.
  FuncRec* = object
    fn*:  Function
    env*: ZjsValue

  ## Payload of a HostFnCell (Phase 6 slice 2): the native proc pointer
  ## (stored as a raw `pointer` so gc.nim stays agnostic of the VM's
  ## `NativeFn` proc type — the VM casts it back before calling), plus the
  ## function's `name` and declared `arity` (`.length`). Kept in an
  ## ARC-managed side table keyed by the cell block pointer. A leaf — no
  ## GC children — so nothing here is marked.
  HostFnData* = object
    fn*:    pointer
    name*:  string
    arity*: int

  GcHeap* = object
    chunks:     seq[NurseryChunk]        ## non-moving nursery chunks
    allCells:   seq[CellRec]             ## every live cell, for sweep
    ## Side tables for the object-model cells. Keyed by the cell block
    ## pointer (cells never move, so the key is stable). Sweep DELETES the
    ## entry when the cell is freed, releasing the ARC seqs and preventing
    ## a reused block from reading a previous tenant's data.
    objTable*: Table[pointer, ObjProps]  ## ObjectCell -> its properties
    arrTable*: Table[pointer, seq[ZjsValue]]  ## ArrayCell -> its elements
    ## FunctionCell -> (Function, captured env). The Function ref lives HERE
    ## (ARC-managed host memory), so the raw GC cell stays a pure header and
    ## the ref is never held in manually-managed cell memory. The `env`
    ## ZjsValue is interior-marked via markCell (TAG_FUNCTION).
    funcTable*: Table[pointer, FuncRec]
    ## StringCell -> its UTF-8 bytes (Phase 6 slice 1). ARC-managed host
    ## string keyed by the cell block pointer; sweep DELETES the entry when
    ## the cell is freed. A string cell is a leaf, so nothing here is marked.
    strTable*: Table[pointer, string]
    ## HostFnCell -> its native proc pointer + name + arity (Phase 6 slice 2).
    ## ARC-managed host memory keyed by the cell block pointer; sweep DELETES
    ## the entry when the cell is freed. A host-fn cell is a leaf (the proc
    ## pointer and name are host memory), so nothing here is marked.
    hostFnTable*: Table[pointer, HostFnData]
    ## Free list of reclaimed slots, keyed by rounded byte-size. Sweep
    ## pushes each dead cell's block here; allocCell pops a same-size
    ## block before bumping. Reuse (not chunk growth) is what keeps live
    ## memory BOUNDED across the stress test — cells still never move,
    ## the block just gets a new tenant.
    freeBySize: Table[int, seq[pointer]]
    rootStack*: seq[ZjsValue]            ## the Rooted shadow-stack (a)
    frameRoots*: seq[ptr seq[ZjsValue]]  ## registered VM frames (b)
    ctxRoots*:  seq[ZjsValue]            ## stubbed ctx roots (c)
    ## An extra root-marking hook the VM installs to mark its own frame
    ## register files (`seq[VmVal]`), which the GC module can't name
    ## without importing vm.nim (circular). Called at the end of markRoots.
    customMark*: proc() {.closure.}
    totalAllocated*: int                 ## lifetime cells handed out
    totalFreed*:     int                 ## lifetime cells swept
    lastCollectAt*:  int                  ## totalAllocated at the last VM-
                                          ## triggered collect (alloc-interval
                                          ## GC trigger; see vm.nim)

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
# ObjectCell / ArrayCell — the slice-B1 object model. The GC cell is a
# pure CellHeader (a leaf block); its property / element data lives in an
# ARC-managed side table in the heap, keyed by the cell block pointer.
# `cellValue` boxes a cell block pointer as a ZjsValue.
# =====================================================================

type
  ObjectCell* = object
    header*: CellHeader     ## a pure header; props are in heap.objTable
    proto*:  ZjsValue       ## [[Prototype]] link (slice B3). Another
                            ## ObjectCell (a ctor.prototype), or `undefined` =
                            ## no proto. Lives INLINE in the cell (mirrors the
                            ## reference `ZjsObject.proto`); marked in
                            ## markCell(TAG_OBJECT) so an instance keeps its
                            ## whole prototype chain (and the methods on it)
                            ## alive. Sweep's zeroMem clears it on recycle.
  ArrayCell* = object
    header*: CellHeader     ## a pure header; elems are in heap.arrTable
  FunctionCell* = object
    header*: CellHeader     ## a pure header; fn/env are in heap.funcTable
  StringCell* = object
    header*: CellHeader     ## a pure header; the bytes are in heap.strTable
  HostFnCell* = object
    header*: CellHeader     ## a pure header; fn/name/arity are in heap.hostFnTable

proc cellValue*(o: ptr ObjectCell): ZjsValue {.inline.} =
  cellFromPtr(cast[pointer](o))
proc cellValue*(a: ptr ArrayCell): ZjsValue {.inline.} =
  cellFromPtr(cast[pointer](a))
proc cellValue*(fc: ptr FunctionCell): ZjsValue {.inline.} =
  cellFromPtr(cast[pointer](fc))
proc cellValue*(sc: ptr StringCell): ZjsValue {.inline.} =
  cellFromPtr(cast[pointer](sc))
proc cellValue*(hc: ptr HostFnCell): ZjsValue {.inline.} =
  cellFromPtr(cast[pointer](hc))

# --- ObjectCell ------------------------------------------------------

proc allocObject*(heap: var GcHeap): ptr ObjectCell =
  ## Allocate an empty ObjectCell. Its (empty) property table is created
  ## eagerly so the side-table entry exists for the lifetime of the cell.
  let p = allocCell(heap, TAG_OBJECT, sizeof(ObjectCell))
  heap.objTable[p] = ObjProps()
  let o = cast[ptr ObjectCell](p)
  o.proto = undefinedVal()          # no [[Prototype]] until SetProto / NewInvoke
  o

proc objGet*(heap: GcHeap, o: ptr ObjectCell, name: string): ZjsValue =
  ## Own-property get by name (interpreter.zc LoadProp own-slot semantics):
  ## the value if present, else `undefined`. NO prototype chain here.
  let p = cast[pointer](o)
  if heap.objTable.hasKey(p):
    let props = heap.objTable[p]
    for i in 0 ..< props.names.len:
      if props.names[i] == name:
        return props.values[i]
  undefinedVal()

proc objHas*(heap: GcHeap, o: ptr ObjectCell, name: string): bool =
  ## Whether `o` has an OWN property named `name`.
  let p = cast[pointer](o)
  if heap.objTable.hasKey(p):
    for n in heap.objTable[p].names:
      if n == name: return true
  false

proc objSet*(heap: var GcHeap, o: ptr ObjectCell, name: string, v: ZjsValue) =
  ## Own-property set (interpreter.zc InitObjData / StoreProp): update in
  ## place if the key exists, else append (insertion order preserved for
  ## future enumeration).
  let p = cast[pointer](o)
  var props = heap.objTable.mgetOrPut(p, ObjProps())
  for i in 0 ..< props.names.len:
    if props.names[i] == name:
      props.values[i] = v
      heap.objTable[p] = props
      return
  props.names.add(name)
  props.values.add(v)
  heap.objTable[p] = props

proc objGetProto*(o: ptr ObjectCell): ZjsValue {.inline.} =
  ## The object's [[Prototype]] link (slice B3): another ObjectCell, or
  ## `undefined` when it has none.
  o.proto

proc objSetProto*(o: ptr ObjectCell, v: ZjsValue) {.inline.} =
  ## Wire the object's [[Prototype]] (interpreter.zc SetProto / the NewInvoke
  ## instance-alloc). `v` is an ObjectCell (a ctor.prototype) or a non-cell
  ## sentinel (undefined / null) = no proto.
  o.proto = v

proc objKeys*(heap: GcHeap, o: ptr ObjectCell): seq[string] =
  ## Own-property names in insertion order.
  let p = cast[pointer](o)
  if heap.objTable.hasKey(p):
    return heap.objTable[p].names
  @[]

proc objTableLen*(heap: GcHeap): int {.inline.} = heap.objTable.len

# --- ArrayCell -------------------------------------------------------

proc allocArray*(heap: var GcHeap, elems: openArray[ZjsValue]): ptr ArrayCell =
  ## Allocate an ArrayCell seeded with `elems` (in order). The empty case
  ## (`allocArray(heap, [])`) yields a length-0 array.
  let p = allocCell(heap, TAG_ARRAY, sizeof(ArrayCell))
  var s: seq[ZjsValue] = @[]
  for e in elems: s.add(e)
  heap.arrTable[p] = s
  cast[ptr ArrayCell](p)

proc arrLength*(heap: GcHeap, a: ptr ArrayCell): int =
  ## Element count (interpreter.zc ArrayLength / `arr.length`).
  let p = cast[pointer](a)
  if heap.arrTable.hasKey(p): heap.arrTable[p].len else: 0

proc arrGet*(heap: GcHeap, a: ptr ArrayCell, i: int): ZjsValue =
  ## Indexed element get (interpreter.zc LoadElem): the element if `0 <= i
  ## < length` AND it is not a hole, else `undefined`.
  let p = cast[pointer](a)
  if heap.arrTable.hasKey(p):
    let s = heap.arrTable[p]
    if i >= 0 and i < s.len:
      let v = s[i]
      if v.bits != VALUE_DELETED:      # holes read back as undefined
        return v
  undefinedVal()

proc arrSet*(heap: var GcHeap, a: ptr ArrayCell, i: int, v: ZjsValue) =
  ## Indexed element set (interpreter.zc StoreElem): write element `i`,
  ## growing the backing seq with HOLES (which read back as undefined) for
  ## any intervening slots. Negative indices are ignored here (the VM
  ## routes non-array-index keys to the object path).
  if i < 0: return
  let p = cast[pointer](a)
  var s = heap.arrTable.mgetOrPut(p, @[])
  while s.len <= i:
    s.add(deletedVal())                # hole sentinel; arrGet → undefined
  s[i] = v
  heap.arrTable[p] = s

proc arrElems*(heap: GcHeap, a: ptr ArrayCell): seq[ZjsValue] =
  ## The whole backing element seq (a copy; holes are VALUE_DELETED sentinels
  ## which read back as undefined). For bulk reads (join/indexOf/slice) and as
  ## the basis for structural mutations via arrReplace.
  let p = cast[pointer](a)
  if heap.arrTable.hasKey(p): heap.arrTable[p] else: @[]

proc arrReplace*(heap: var GcHeap, a: ptr ArrayCell, s: seq[ZjsValue]) =
  ## Replace the entire backing element seq (push/pop/shift/unshift/reverse/
  ## fill/…). The ArrayCell keeps its identity; only its elements change.
  heap.arrTable[cast[pointer](a)] = s

proc arrTableLen*(heap: GcHeap): int {.inline.} = heap.arrTable.len

# --- FunctionCell (slice B2) -----------------------------------------

proc allocFunction*(heap: var GcHeap, fn: Function, env: ZjsValue): ptr FunctionCell =
  ## Allocate a FunctionCell wrapping `fn` and its captured `env`. Used to
  ## box a closure VALUE for storage in an object/array side table (which
  ## holds ZjsValues, not the VM's function variant). The cell is a pure
  ## header; (fn, env) live in the ARC-managed funcTable.
  let p = allocCell(heap, TAG_FUNCTION, sizeof(FunctionCell))
  heap.funcTable[p] = FuncRec(fn: fn, env: env)
  cast[ptr FunctionCell](p)

proc isFunctionCell*(heap: GcHeap, v: ZjsValue): bool {.inline.} =
  ## Whether `v` boxes a live FunctionCell (used to unbox on load).
  isCell(v) and cellAsPtr(v) != nil and
    cellHeader(v).typeTag == TAG_FUNCTION and
    heap.funcTable.hasKey(cellAsPtr(v))

proc funcCellFn*(heap: GcHeap, v: ZjsValue): Function {.inline.} =
  heap.funcTable[cellAsPtr(v)].fn
proc funcCellEnv*(heap: GcHeap, v: ZjsValue): ZjsValue {.inline.} =
  heap.funcTable[cellAsPtr(v)].env

proc funcTableLen*(heap: GcHeap): int {.inline.} = heap.funcTable.len

# --- StringCell (Phase 6 slice 1) ------------------------------------

proc allocStringCell*(heap: var GcHeap, s: string): ptr StringCell =
  ## Allocate a StringCell wrapping `s`. Used to box a STRING VALUE for
  ## storage in an object/array side table (which holds ZjsValues, not the
  ## VM's vkString variant) — box on store, unbox on load. The cell is a
  ## pure header; the bytes live in the ARC-managed strTable.
  let p = allocCell(heap, TAG_STRING, sizeof(StringCell))
  heap.strTable[p] = s
  cast[ptr StringCell](p)

proc isStringCell*(heap: GcHeap, v: ZjsValue): bool {.inline.} =
  ## Whether `v` boxes a live StringCell (used to unbox on load / inspect).
  isCell(v) and cellAsPtr(v) != nil and
    cellHeader(v).typeTag == TAG_STRING and
    heap.strTable.hasKey(cellAsPtr(v))

proc strCellVal*(heap: GcHeap, v: ZjsValue): string {.inline.} =
  heap.strTable[cellAsPtr(v)]

proc strTableLen*(heap: GcHeap): int {.inline.} = heap.strTable.len

# --- HostFnCell (Phase 6 slice 2) ------------------------------------

proc allocHostFunction*(heap: var GcHeap, fn: pointer, name: string,
                        arity: int): ptr HostFnCell =
  ## Allocate a HostFnCell wrapping the native proc pointer `fn` (a VM
  ## `NativeFn` cast to `pointer`), its `name`, and `arity`. The cell is a
  ## pure header; the payload lives in the ARC-managed hostFnTable keyed by
  ## the cell block pointer. Used to box a native builtin as a callable JS
  ## VALUE that lives uniformly in a global slot AND as an object property.
  let p = allocCell(heap, TAG_HOSTFN, sizeof(HostFnCell))
  heap.hostFnTable[p] = HostFnData(fn: fn, name: name, arity: arity)
  cast[ptr HostFnCell](p)

proc isHostFunctionCell*(v: ZjsValue): bool {.inline.} =
  ## Whether `v` boxes a HostFnCell (used to dispatch a call to the native).
  ## Heap-agnostic: the typeTag is authoritative (a recycled block is re-tagged
  ## by allocCell and its table entry deleted on sweep). A zero-bits value
  ## passes isCell but has a nil cell pointer — guarded here.
  isCell(v) and cellAsPtr(v) != nil and cellHeader(v).typeTag == TAG_HOSTFN

proc hostFnPtr*(heap: GcHeap, v: ZjsValue): pointer {.inline.} =
  heap.hostFnTable[cellAsPtr(v)].fn
proc hostFnName*(heap: GcHeap, v: ZjsValue): string {.inline.} =
  heap.hostFnTable[cellAsPtr(v)].name
proc hostFnArity*(heap: GcHeap, v: ZjsValue): int {.inline.} =
  heap.hostFnTable[cellAsPtr(v)].arity

proc hostFnTableLen*(heap: GcHeap): int {.inline.} = heap.hostFnTable.len

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

proc markCell*(heap: GcHeap, v: ZjsValue) =
  if not isCell(v):
    return
  # A zero-bits value passes isCell (NOT_CELL_MASK==0) but is a NULL cell
  # pointer, not a live cell — it shows up wherever a VmVal seq was grown
  # by setLen (globals) or a register was left zeroed. Never dereference it.
  if cellAsPtr(v) == nil:
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
      markCell(heap, f[i])      # interior marking of field values
  of TAG_OBJECT:
    # The [[Prototype]] link (slice B3): keep the whole prototype chain (and
    # the methods installed on it) reachable while any instance is reachable.
    let oc = cast[ptr ObjectCell](cellAsPtr(v))
    markCell(heap, oc.proto)
    # Interior-mark every property VALUE (side table). The names are ARC
    # strings; only the ZjsValues can be cells.
    let p = cellAsPtr(v)
    if heap.objTable.hasKey(p):
      for pv in heap.objTable[p].values:
        markCell(heap, pv)
  of TAG_ARRAY:
    let p = cellAsPtr(v)
    if heap.arrTable.hasKey(p):
      for ev in heap.arrTable[p]:
        markCell(heap, ev)
  of TAG_FUNCTION:
    # A closure's captured env is a root: keep it (and anything reachable
    # from it) alive while the function value is reachable. The Function ref
    # is ARC-managed (side table), not a GC concern.
    let p = cellAsPtr(v)
    if heap.funcTable.hasKey(p):
      markCell(heap, heap.funcTable[p].env)
  of TAG_STRING:
    discard                     # a string cell is a leaf (bytes in strTable)
  of TAG_HOSTFN:
    # Normally a leaf (fn/name/arity live in hostFnTable), BUT a native
    # constructor object (e.g. Object@g57) carries its static methods in an
    # objTable property bag; mark those VALUES so the boxed method cells
    # survive a collect. Plain natives have no bag → hasKey is false → no-op.
    let p = cellAsPtr(v)
    if heap.objTable.hasKey(p):
      for pv in heap.objTable[p].values:
        markCell(heap, pv)
  of TAG_LEAF:
    discard                     # no children
  else:
    discard                     # unknown tag: treat as leaf (safe)

# `heap.customMark` lets a higher layer (the VM) contribute roots the GC
# module can't name without a circular import — e.g. the VM's frame
# register files, which are `seq[VmVal]`, not `seq[ZjsValue]`. The VM sets
# this closure (capturing `addr heap`) so markRoots reaches every active
# frame's cell-holding registers. See vm.nim's frame rooting.

proc markRoots*(heap: var GcHeap) =
  ## Mark from every root source. Order is irrelevant (mark is idempotent).
  for v in heap.rootStack:
    markCell(heap, v)
  for fr in heap.frameRoots:
    if fr != nil:
      for v in fr[]:
        markCell(heap, v)
  for v in heap.ctxRoots:
    markCell(heap, v)
  if heap.customMark != nil:
    heap.customMark()

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
      # Unreachable. Release any object-model side table FIRST (so ARC
      # frees the seqs and a reused block can't read stale props), then
      # zero the block (poisons any stale ZjsValue so a dangling read fails
      # an isCell/tag check loudly) and recycle it.
      case h.typeTag
      of TAG_OBJECT:   heap.objTable.del(rec.p)
      of TAG_ARRAY:    heap.arrTable.del(rec.p)
      of TAG_FUNCTION: heap.funcTable.del(rec.p)
      of TAG_STRING:   heap.strTable.del(rec.p)
      of TAG_HOSTFN:   heap.hostFnTable.del(rec.p)
      else: discard
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
  heap.objTable.clear()
  heap.arrTable.clear()
  heap.funcTable.clear()
  heap.strTable.clear()
  heap.hostFnTable.clear()
  heap.rootStack.setLen(0)
  heap.frameRoots.setLen(0)
  heap.ctxRoots.setLen(0)
  heap.customMark = nil
