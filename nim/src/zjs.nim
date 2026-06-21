## C-ABI entry module. Exposes the zjs.h surface via {.exportc, cdecl.}.
## This is the ONLY file aware of the C ABI; everything else is
## idiomatic Nim. The static lib is built with --noMain, so we init the
## Nim runtime lazily on first context creation (keeps test262_runner.c
## unchanged across the Zen-c and Nim builds).

import zjs/context
import zjs/value   # ZjsValue + the idiomatic core

proc NimMain() {.importc, cdecl.}

var runtimeReady {.global.} = false
proc ensureRuntime() {.inline.} =
  if not runtimeReady:
    runtimeReady = true
    NimMain()

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
  undefinedVal()

# --- Immediate value constructors (C ABI) ---
proc zjs_int32(i: cint): ZjsValue {.exportc, cdecl.} = int32Val(int32(i))
proc zjs_double(d: cdouble): ZjsValue {.exportc, cdecl.} = doubleVal(float64(d))
proc zjs_bool(b: cint): ZjsValue {.exportc, cdecl.} = boolVal(b != 0)
proc zjs_null(): ZjsValue {.exportc, cdecl.} = nullVal()
proc zjs_undefined(): ZjsValue {.exportc, cdecl.} = undefinedVal()

# --- Predicates (C ABI: return cint 0/1) ---
proc zjs_is_int32(v: ZjsValue): cint {.exportc, cdecl.} = cint(isInt32(v))
proc zjs_is_double(v: ZjsValue): cint {.exportc, cdecl.} = cint(isDouble(v))
proc zjs_is_number(v: ZjsValue): cint {.exportc, cdecl.} = cint(isNumber(v))
proc zjs_is_bool(v: ZjsValue): cint {.exportc, cdecl.} = cint(isBool(v))
proc zjs_is_null(v: ZjsValue): cint {.exportc, cdecl.} = cint(isNull(v))
proc zjs_is_undefined(v: ZjsValue): cint {.exportc, cdecl.} = cint(isUndefined(v))
proc zjs_is_cell(v: ZjsValue): cint {.exportc, cdecl.} = cint(isCell(v))

# --- Unboxers (C ABI) ---
proc zjs_as_int32(v: ZjsValue): cint {.exportc, cdecl.} = cint(asInt32(v))
proc zjs_as_double(v: ZjsValue): cdouble {.exportc, cdecl.} = cdouble(asDouble(v))
proc zjs_as_bool(v: ZjsValue): cint {.exportc, cdecl.} = asBool(v)
