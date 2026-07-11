## Slice-A GC tests — the validation for the memory foundation. GC is
## invisible to `zjs eval`, so these unit tests ARE the correctness bar:
## a rooted cell (or its transitive children) freed, or a dangling
## pointer, is a HARD FAIL. `collect()` must also provably free the
## unrooted set (no leak). Build/run:
##   nim c -r --mm:arc -d:release --hints:off --warnings:off nim/tests/tgc.nim

import std/unittest
import ../src/zjs/[value, gc, bytecode]

suite "cell encode/decode round-trip":
  test "cellFromPtr / cellAsPtr round-trip and isCell":
    var heap = newGcHeap()
    let o = allocObjCell(heap, 0)
    let p = cast[pointer](o)
    let v = cellFromPtr(p)
    check cellAsPtr(v) == p                 # exact pointer preserved
    check isCell(v)                         # boxed pointer reads as a cell
    check cellHeader(v).typeTag == TAG_OBJ  # header reachable through v
    destroyHeap(heap)

  test "immediates are NOT cells":
    check not isCell(int32Val(5))
    check not isCell(doubleVal(3.5))
    check not isCell(boolVal(true))
    check not isCell(nullVal())
    check not isCell(undefinedVal())

  test "leaf cell round-trips":
    var heap = newGcHeap()
    let v = allocLeafCell(heap)
    check isCell(v)
    check cellHeader(v).typeTag == TAG_LEAF
    destroyHeap(heap)

suite "survive vs free":
  test "rooted 10 of 100 survive; children survive; unrooted freed":
    var heap = newGcHeap()
    # Alloc 100 ObjCells (2 fields each). Root every 10th one.
    var roots: seq[Rooted] = @[]
    var rootedCells: seq[ptr ObjCell] = @[]
    for i in 0 ..< 100:
      let o = allocObjCell(heap, 2)
      setField(o, 0, int32Val(int32(i)))     # a primitive field
      if i mod 10 == 0:
        # Give this rooted cell a CHILD cell in field 1 → interior mark.
        let child = allocObjCell(heap, 1)
        setField(child, 0, int32Val(int32(1000 + i)))
        setField(o, 1, cellFromPtr(child))
        roots.add(rooted(heap, cellFromPtr(o)))
        rootedCells.add(o)

    # 100 parents + 10 children = 110 cells before collect.
    check liveCellCount(heap) == 110
    let allocBefore = heap.totalAllocated

    let freed = collect(heap)
    # Survivors: 10 rooted parents + their 10 children = 20.
    check liveCellCount(heap) == 20
    check freed == 90                        # 90 unrooted parents freed
    check heap.totalAllocated == allocBefore # collect allocates nothing

    # Rooted cells + their children survive with CORRECT field contents.
    for k in 0 ..< rootedCells.len:
      let o = rootedCells[k]
      check cellHeader(cellFromPtr(o)).typeTag == TAG_OBJ
      check asInt32(getField(o, 0)) == int32(k * 10)
      let cv = getField(o, 1)
      check isCell(cv)
      let child = cast[ptr ObjCell](cellAsPtr(cv))
      check asInt32(getField(child, 0)) == int32(1000 + k * 10)

    # A second collect with the SAME roots frees nothing (idempotent).
    check collect(heap) == 0
    check liveCellCount(heap) == 20

    roots.setLen(0)          # drop the Rooteds (=destroy pops LIFO)
    check collect(heap) == 20  # now everything is unreachable
    check liveCellCount(heap) == 0
    destroyHeap(heap)

  test "chain root -> field -> cell keeps the whole chain":
    var heap = newGcHeap()
    # a -> b -> c, only a is rooted. All three must survive.
    let c = allocObjCell(heap, 1)
    setField(c, 0, int32Val(42))
    let b = allocObjCell(heap, 1)
    setField(b, 0, cellFromPtr(c))
    let a = allocObjCell(heap, 1)
    setField(a, 0, cellFromPtr(b))
    # Some unrooted noise.
    for i in 0 ..< 50: discard allocObjCell(heap, 0)
    block:
      let r = rooted(heap, cellFromPtr(a))
      let freed = collect(heap)
      check freed == 50
      check liveCellCount(heap) == 3
      # Walk the chain and confirm the leaf value.
      let av = r.value
      let bo = cast[ptr ObjCell](cellAsPtr(getField(cast[ptr ObjCell](cellAsPtr(av)), 0)))
      let co = cast[ptr ObjCell](cellAsPtr(getField(bo, 0)))
      check asInt32(getField(co, 0)) == 42
    # r destroyed here → chain now collectable.
    check collect(heap) == 3
    check liveCellCount(heap) == 0
    destroyHeap(heap)

  test "cyclic fields do not loop the marker":
    var heap = newGcHeap()
    let x = allocObjCell(heap, 1)
    let y = allocObjCell(heap, 1)
    setField(x, 0, cellFromPtr(y))
    setField(y, 0, cellFromPtr(x))          # cycle x <-> y
    block:
      let r = rooted(heap, cellFromPtr(x))
      check collect(heap) == 0               # both reachable, marker terminates
      check liveCellCount(heap) == 2
      check cellHeader(r.value).typeTag == TAG_OBJ
    # r popped at block exit.
    check collect(heap) == 2                  # cycle collected once unrooted
    destroyHeap(heap)

suite "Rooted scope semantics":
  test "inner-block cell is collectable after the block":
    var heap = newGcHeap()
    block:
      let inner = allocObjCell(heap, 0)
      let r = rooted(heap, cellFromPtr(inner))
      check collect(heap) == 0
      check liveCellCount(heap) == 1
      check cellHeader(r.value).typeTag == TAG_OBJ
    # r popped at block exit → the cell is now unrooted.
    check collect(heap) == 1
    check liveCellCount(heap) == 0
    destroyHeap(heap)

  test "rooted-across-collect survives; nested LIFO":
    var heap = newGcHeap()
    let keep = allocObjCell(heap, 0)
    block outer:
      let r1 = rooted(heap, cellFromPtr(keep))   # outer root
      block inner:
        let tmp = allocObjCell(heap, 0)
        let r2 = rooted(heap, cellFromPtr(tmp))   # inner root (LIFO on top)
        # A bunch of garbage across a collect while both are rooted.
        for i in 0 ..< 20: discard allocObjCell(heap, 0)
        check collect(heap) == 20
        check liveCellCount(heap) == 2            # keep + tmp
        check cellHeader(r2.value).typeTag == TAG_OBJ
      # r2 popped at `inner` exit; keep still rooted across THIS collect.
      check collect(heap) == 1                    # only tmp goes
      check liveCellCount(heap) == 1
      check cellHeader(r1.value).typeTag == TAG_OBJ
    # r1 popped at `outer` exit → keep now collectable.
    check collect(heap) == 1
    check liveCellCount(heap) == 0
    destroyHeap(heap)

suite "reassign through the root slot":
  test "r[] = other retargets what survives":
    var heap = newGcHeap()
    let first  = allocObjCell(heap, 1)
    setField(first, 0, int32Val(1))
    let other = allocObjCell(heap, 1)
    setField(other, 0, int32Val(2))
    block:
      var r = rooted(heap, cellFromPtr(first))
      # Retarget the root to `other`; `first` is now unrooted.
      r[] = cellFromPtr(other)
      check asInt32(getField(cast[ptr ObjCell](cellAsPtr(r[])), 0)) == 2
      let freed = collect(heap)
      check freed == 1                            # `first` collected
      check liveCellCount(heap) == 1
      # `other` survived with its field intact.
      let ov = cast[ptr ObjCell](cellAsPtr(r.value))
      check asInt32(getField(ov, 0)) == 2
    # r popped → `other` now collectable.
    check collect(heap) == 1
    destroyHeap(heap)

suite "free-list reuse does not corrupt live cells":
  test "reused block gets a fresh tenant; rooted survivor stays intact":
    var heap = newGcHeap()
    # Root ONE cell with a distinctive field value, then churn: alloc many
    # cells, collect (freeing them into the reuse list), alloc many more
    # (reusing those exact blocks). The rooted survivor's identity and its
    # child must be untouched throughout — proves reuse never hands a live
    # block to a new tenant, and the survivor is never dangling.
    let child = allocObjCell(heap, 1)
    setField(child, 0, int32Val(0x5A5A))
    let keep = allocObjCell(heap, 2)
    setField(keep, 0, int32Val(0x1234))
    setField(keep, 1, cellFromPtr(child))
    block:
      let r = rooted(heap, cellFromPtr(keep))
      for round in 0 ..< 10:
        for i in 0 ..< 200:
          let g = allocObjCell(heap, 2)          # same size class as keep
          setField(g, 0, int32Val(int32(-round)))
        discard collect(heap)                     # frees the 200 garbage
        # keep + child are the only survivors, values intact.
        check liveCellCount(heap) == 2
        let ko = cast[ptr ObjCell](cellAsPtr(r.value))
        check asInt32(getField(ko, 0)) == 0x1234
        let co = cast[ptr ObjCell](cellAsPtr(getField(ko, 1)))
        check asInt32(getField(co, 0)) == 0x5A5A
    check collect(heap) == 2
    destroyHeap(heap)

suite "frame-register roots":
  test "registered frame regs keep their cells alive":
    var heap = newGcHeap()
    var regs: seq[ZjsValue] = @[]
    let live = allocObjCell(heap, 0)
    let dead = allocObjCell(heap, 0)
    regs.add(cellFromPtr(live))
    regs.add(int32Val(7))                       # a non-cell reg is fine
    heap.frameRoots.add(addr regs)
    check collect(heap) == 1                     # `dead` freed, `live` kept
    check liveCellCount(heap) == 1
    check cellHeader(regs[0]).typeTag == TAG_OBJ
    heap.frameRoots.setLen(0)                     # "pop" the frame
    check collect(heap) == 1                      # now `live` collectable
    discard dead
    destroyHeap(heap)

suite "stress: rolling rooted window":
  test "100k allocs, rolling window, many collects, bounded memory":
    var heap = newGcHeap()
    const N = 100_000
    const Window = 64
    # The rolling window is a registered FRAME register file (exactly what
    # the VM wires in slice B): a fixed `seq[ZjsValue]` whose slots we
    # overwrite in place. Overwriting a slot un-roots its previous tenant
    # (making it collectable) and roots the new cell — a rolling window
    # WITHOUT any LIFO constraint. Each cell's field encodes its identity
    # `i`, re-checked after every collect to prove no window cell is ever
    # corrupted or freed while rooted.
    var regs = newSeq[ZjsValue](Window)
    for k in 0 ..< Window: regs[k] = undefinedVal()
    heap.frameRoots.add(addr regs)
    var maxReserved = 0
    for i in 0 ..< N:
      let o = allocObjCell(heap, 1)
      setField(o, 0, int32Val(int32(i)))
      regs[i mod Window] = cellFromPtr(o)       # root new, un-root evicted
      if i mod 500 == 0:
        discard collect(heap)
        # Every currently-rooted window cell must be intact.
        for s in 0 ..< Window:
          if isCell(regs[s]):
            let ov = cast[ptr ObjCell](cellAsPtr(regs[s]))
            check cellHeader(regs[s]).typeTag == TAG_OBJ
            check isInt32(getField(ov, 0))
        let r = reservedBytes(heap)
        if r > maxReserved: maxReserved = r

    discard collect(heap)
    # Only the Window rooted cells remain live (all slots filled after N
    # >> Window iterations).
    check liveCellCount(heap) == Window
    # Live memory stayed bounded: far below what N distinct 64 B cells
    # would need if nothing were ever reused (N*64 = 6.4 MB). A handful
    # of 64 KB chunks covers a 64-cell working set because freed blocks
    # are recycled.
    check maxReserved <= 8 * NURSERY_CHUNK_SIZE  # <= 512 KB
    check heap.totalAllocated == N

    # Drop the frame; the window cells become collectable.
    heap.frameRoots.setLen(0)
    check collect(heap) == Window
    check liveCellCount(heap) == 0
    destroyHeap(heap)

# =====================================================================
# Slice B1 — object model cells (ObjectCell / ArrayCell) on the GC.
# The property/element data lives in an ARC-managed side table hung off
# the cell; markCell must walk those GC-value contents so property /
# element values stay live. These tests are the correctness bar for the
# object-model rep BEFORE the VM wires it (the eval differential is the
# other bar).
# =====================================================================

suite "object cell — own-property semantics":
  test "set/get by name, insertion order, missing → undefined":
    var heap = newGcHeap()
    let o = allocObject(heap)
    objSet(heap, o, "a", int32Val(1))
    objSet(heap, o, "b", int32Val(2))
    check isInt32(objGet(heap, o, "a")) and asInt32(objGet(heap, o, "a")) == 1
    check asInt32(objGet(heap, o, "b")) == 2
    # A missing own property reads back as undefined (no proto chain here).
    check isUndefined(objGet(heap, o, "z"))
    # Re-setting an existing key UPDATES in place (does not append).
    objSet(heap, o, "a", int32Val(9))
    check asInt32(objGet(heap, o, "a")) == 9
    check objKeys(heap, o) == @["a", "b"]     # insertion order preserved
    destroyHeap(heap)

  test "property VALUES that are cells stay live across collect":
    var heap = newGcHeap()
    let parent = allocObject(heap)
    let child = allocObject(heap)
    objSet(heap, child, "leaf", int32Val(0x1234))
    objSet(heap, parent, "kid", cellValue(child))   # parent.kid -> child cell
    block:
      let r = rooted(heap, cellValue(parent))
      # Noise the child would be swept without interior marking.
      for i in 0 ..< 30: discard allocObject(heap)
      let freed = collect(heap)
      check freed == 30
      check liveCellCount(heap) == 2                 # parent + child survive
      # Walk parent.kid.leaf — proves the child value was not swept.
      let pv = r.value
      let cv = objGet(heap, cast[ptr ObjectCell](cellAsPtr(pv)), "kid")
      check isCell(cv)
      check asInt32(objGet(heap, cast[ptr ObjectCell](cellAsPtr(cv)), "leaf")) == 0x1234
    check collect(heap) == 2                          # unrooted now
    check liveCellCount(heap) == 0
    destroyHeap(heap)

suite "array cell — element semantics":
  test "length, indexed get, out-of-range → undefined, grow with holes":
    var heap = newGcHeap()
    let a = allocArray(heap, [int32Val(10), int32Val(20), int32Val(30)])
    check arrLength(heap, a) == 3
    check asInt32(arrGet(heap, a, 0)) == 10
    check asInt32(arrGet(heap, a, 2)) == 30
    check isUndefined(arrGet(heap, a, 5))             # out of range → undefined
    # Grow past the end: intervening slots are holes → undefined.
    arrSet(heap, a, 5, int32Val(99))
    check arrLength(heap, a) == 6
    check isUndefined(arrGet(heap, a, 4))             # hole
    check asInt32(arrGet(heap, a, 5)) == 99
    destroyHeap(heap)

  test "element cell values stay live across collect (nested arrays)":
    var heap = newGcHeap()
    let inner = allocArray(heap, [int32Val(7)])
    let outer = allocArray(heap, [cellValue(inner)])
    block:
      let r = rooted(heap, cellValue(outer))
      for i in 0 ..< 20: discard allocArray(heap, [])
      let freed = collect(heap)
      check freed == 20
      check liveCellCount(heap) == 2                  # outer + inner
      let ov = cast[ptr ArrayCell](cellAsPtr(r.value))
      let iv = arrGet(heap, ov, 0)
      check isCell(iv)
      check asInt32(arrGet(heap, cast[ptr ArrayCell](cellAsPtr(iv)), 0)) == 7
    check collect(heap) == 2
    destroyHeap(heap)

suite "object/array cell free releases its side table":
  test "swept object/array leave no side-table entry (no leak)":
    var heap = newGcHeap()
    for i in 0 ..< 50:
      let o = allocObject(heap)
      objSet(heap, o, "k", int32Val(int32(i)))
      let a = allocArray(heap, [int32Val(int32(i)), int32Val(int32(i))])
      discard a
    # None rooted → all swept; the side tables must be emptied so the
    # host seqs are released (ARC) and reused pointers can't read stale data.
    check collect(heap) == 100
    check liveCellCount(heap) == 0
    check objTableLen(heap) == 0
    check arrTableLen(heap) == 0
    destroyHeap(heap)

# Slice B2: a closure VALUE stored in the object model is a FunctionCell
# carrying its captured env (an ObjectCell). The env — and anything
# reachable from it — must survive a collect while the closure is
# reachable, and be freed once the closure is not. This is the GC bar for
# capturing closures + `this` receivers held across a collection.
suite "function cell + captured env (slice B2)":
  test "rooted closure keeps its env (and env's children) alive":
    var heap = newGcHeap()
    let fn = Function()                       # opaque payload; GC ignores it
    # env = { cap: <inner object {v:42}> } — a closure that captured an object.
    let inner = allocObject(heap)
    objSet(heap, inner, "v", int32Val(42))
    let env = allocObject(heap)
    objSet(heap, env, "cap", cellValue(inner))
    let clo = allocFunction(heap, fn, cellValue(env))
    block:
      let r = rooted(heap, cellValue(clo))
      # A pile of unrooted garbage across a collect while the closure is rooted.
      for i in 0 ..< 30: discard allocObject(heap)
      let freed = collect(heap)
      check freed == 30
      # Survivors: the FunctionCell + its env + the env's captured inner obj.
      check liveCellCount(heap) == 3
      # Reach the captured value THROUGH the function cell's env — proves the
      # env pointer is still valid (not a dangling freed block).
      let envv = funcCellEnv(heap, r.value)
      let eo = cast[ptr ObjectCell](cellAsPtr(envv))
      let capv = objGet(heap, eo, "cap")
      check isCell(capv)
      let io = cast[ptr ObjectCell](cellAsPtr(capv))
      check asInt32(objGet(heap, io, "v")) == 42
    # r destroyed → the whole closure/env/inner chain is now collectable.
    check collect(heap) == 3
    check liveCellCount(heap) == 0
    check funcTableLen(heap) == 0             # side table released (no leak)
    destroyHeap(heap)

  test "closure-heavy stress: one live closure survives, memory bounded":
    var heap = newGcHeap()
    let fn = Function()
    # Build ONE closure we keep, capturing an env {id: 7}.
    let keepEnv = allocObject(heap)
    objSet(heap, keepEnv, "id", int32Val(7))
    let keep = allocFunction(heap, fn, cellValue(keepEnv))
    block:
      let r = rooted(heap, cellValue(keep))
      var reservedBaseline = 0
      # Churn: many throwaway closures each capturing their own throwaway env,
      # forcing collections. The kept closure's env must never be freed, and
      # reused blocks must keep the live memory BOUNDED (no unbounded growth).
      for i in 0 ..< 5000:
        let e = allocObject(heap)
        objSet(heap, e, "k", int32Val(int32(i)))
        discard allocFunction(heap, fn, cellValue(e))
        if i mod 500 == 0:
          discard collect(heap)
          if i == 500: reservedBaseline = reservedBytes(heap)
          # Steady state: reserved memory must not grow (blocks are reused).
          if i >= 1000: check reservedBytes(heap) <= reservedBaseline
      # The kept closure + its env are the only survivors after collect.
      discard collect(heap)
      check liveCellCount(heap) == 2
      let envv = funcCellEnv(heap, r.value)
      check asInt32(objGet(heap, cast[ptr ObjectCell](cellAsPtr(envv)), "id")) == 7
    # r destroyed at block exit → keep + env now collectable.
    check collect(heap) == 2
    check liveCellCount(heap) == 0
    check funcTableLen(heap) == 0
    destroyHeap(heap)

suite "class instances + [[Prototype]] chain (slice B3)":
  test "instance keeps its proto + methods alive; churn stays bounded":
    var heap = newGcHeap()
    let mfn = Function()
    # A prototype object carrying a method `m` (a FunctionCell), just like a
    # class value's `Ctor.prototype` after DefineMethod. Kept alive here ONLY
    # through the ONE instance we root — exercising markCell(TAG_OBJECT)'s new
    # proto-marking path (nothing else references the proto).
    let proto = allocObject(heap)
    objSet(heap, proto, "m", cellValue(allocFunction(heap, mfn, undefinedVal())))
    let protoV = cellValue(proto)
    # The instance we keep: a fresh object whose [[Prototype]] = proto.
    let keep = allocObject(heap)
    objSetProto(keep, protoV)
    objSet(heap, keep, "id", int32Val(99))
    block:
      let r = rooted(heap, cellValue(keep))
      var reservedBaseline = 0
      # Churn: many throwaway instances, each with proto = the shared proto,
      # forcing collections. The kept instance, its proto, and the method on
      # the proto must NEVER be freed; reused blocks keep memory BOUNDED.
      for i in 0 ..< 5000:
        let inst = allocObject(heap)
        objSetProto(inst, protoV)
        objSet(heap, inst, "id", int32Val(int32(i)))
        if i mod 500 == 0:
          discard collect(heap)
          if i == 500: reservedBaseline = reservedBytes(heap)
          if i >= 1000: check reservedBytes(heap) <= reservedBaseline
      discard collect(heap)
      # Survivors: the kept instance + its proto + the proto's method cell.
      check liveCellCount(heap) == 3
      # The instance's own prop survives, AND the method resolves through the
      # [[Prototype]] link (proto not dangling; method cell not freed).
      let ko = cast[ptr ObjectCell](cellAsPtr(r.value))
      check asInt32(objGet(heap, ko, "id")) == 99
      let pv = objGetProto(ko)
      check isCell(pv)
      let po = cast[ptr ObjectCell](cellAsPtr(pv))
      let mv = objGet(heap, po, "m")
      check isFunctionCell(heap, mv)
      check funcCellFn(heap, mv) == mfn
    # r destroyed → instance + proto + method now unreachable.
    check collect(heap) == 3
    check liveCellCount(heap) == 0
    check funcTableLen(heap) == 0             # method side table released
    destroyHeap(heap)
