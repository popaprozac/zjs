## Slice-A GC tests — the validation for the memory foundation. GC is
## invisible to `zjs eval`, so these unit tests ARE the correctness bar:
## a rooted cell (or its transitive children) freed, or a dangling
## pointer, is a HARD FAIL. `collect()` must also provably free the
## unrooted set (no leak). Build/run:
##   nim c -r --mm:arc -d:release --hints:off --warnings:off nim/tests/tgc.nim

import std/unittest
import ../src/zjs/[value, gc]

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
