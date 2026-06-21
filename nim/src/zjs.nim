## C-ABI entry module. Exposes the zjs.h surface via {.exportc, cdecl.}.
## This is the ONLY file aware of the C ABI; everything else is
## idiomatic Nim. The static lib is built with --noMain, so we init the
## Nim runtime lazily on first context creation (keeps test262_runner.c
## unchanged across the Zen-c and Nim builds).

import zjs/context

proc NimMain() {.importc, cdecl.}

var runtimeReady {.global.} = false
proc ensureRuntime() {.inline.} =
  if not runtimeReady:
    runtimeReady = true
    NimMain()

# --- ZjsValue: ABI-identical to `struct { uint64_t bits; }` in zjs.h ---
type ZjsValue {.bycopy.} = object
  bits: uint64

# --- The 4 functions test262_runner.c needs ---

proc zjs_new_context(): ptr Context {.exportc, cdecl.} =
  ensureRuntime()
  newContext()

proc zjs_free_context(c: ptr Context) {.exportc, cdecl.} =
  freeContext(c)

proc zjs_had_error(c: ptr Context): cint {.exportc, cdecl.} =
  if c != nil and c.hadError: 1 else: 0

proc zjs_eval(c: ptr Context, source: cstring): ZjsValue {.exportc, cdecl.} =
  ## Phase 0 stub: nothing is implemented yet, so every program is
  ## treated as "failed to run" (hadError = 1). This makes the test262
  ## loop report ~0 passing — the honest baseline. Real eval arrives in
  ## Phase 4. `source` is intentionally unused here.
  if c != nil: c.hadError = true
  ZjsValue(bits: 10'u64)   # VALUE_UNDEFINED (see Phase 1)
