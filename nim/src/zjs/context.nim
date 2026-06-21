## Engine context. Phase 0: minimal — just enough for the C ABI to
## allocate/free a handle and track the uncaught-error flag. Grows in
## later phases (heap, globals, GC, frames).

type
  Context* = object
    hadError*: bool

proc newContext*(): ptr Context =
  ## Allocate a zeroed Context on the manual (non-Nim-GC) heap. The JS
  ## runtime heap is always manual; see the design doc's two-heap rule.
  result = cast[ptr Context](alloc0(sizeof(Context)))

proc freeContext*(c: ptr Context) =
  if c != nil: dealloc(c)
