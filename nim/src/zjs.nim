## C-ABI entry module. Exposes the zjs.h surface via {.cabi.}.
## This is the ONLY file aware of the C ABI; everything else is
## idiomatic Nim. The static lib is built with --noMain, so we init the
## Nim runtime lazily on first context creation (keeps test262_runner.c
## unchanged across the Zen-c and Nim builds).

import zjs/context
import zjs/value   # ZjsValue + the idiomatic core

proc NimMain() {.importc, cdecl.}

# Every C-ABI export needs default symbol visibility so it survives in a
# shared lib (.dylib/.so) for embedding — plain {.exportc, cdecl.} emits
# hidden-visibility symbols that get stripped. `dynlib` marks them
# exported (N_LIB_EXPORT); harmless for the static-lib build. (Verified.)
{.pragma: cabi, exportc, cdecl, dynlib.}

# NOTE: single-threaded assumption. `runtimeReady` is a process global,
# so a second thread calling zjs_new_context would skip NimMain(). The
# engine's model is one-ctx-per-thread with TLS globals; when --threads:on
# lands, per-thread Nim runtime init must be revisited.
var runtimeReady {.global.} = false
proc ensureRuntime() {.inline.} =
  if not runtimeReady:
    runtimeReady = true
    NimMain()

# --- The 4 functions test262_runner.c needs ---

proc zjs_new_context(): ptr Context {.cabi.} =
  ensureRuntime()
  newContext()

proc zjs_free_context(c: ptr Context) {.cabi.} =
  freeContext(c)

proc zjs_had_error(c: ptr Context): cint {.cabi.} =
  if c != nil and c.hadError: 1 else: 0

proc zjs_eval(c: ptr Context, source: cstring): ZjsValue {.cabi.} =
  ## Phase 0 stub: nothing is implemented yet, so every program is
  ## treated as "failed to run" (hadError = 1). This makes the test262
  ## loop report ~0 passing — the honest baseline. Real eval arrives in
  ## Phase 4. `source` is intentionally unused here.
  # TODO(phase 4): the real eval must reset c.hadError at entry/success
  # to match Zen-c (a reused context recovers after a failed eval).
  if c != nil: c.hadError = true
  undefinedVal()

# --- Immediate value constructors (C ABI) ---
proc zjs_int32(i: cint): ZjsValue {.cabi.} = int32Val(int32(i))
proc zjs_double(d: cdouble): ZjsValue {.cabi.} = doubleVal(float64(d))
proc zjs_bool(b: cint): ZjsValue {.cabi.} = boolVal(b != 0)
proc zjs_null(): ZjsValue {.cabi.} = nullVal()
proc zjs_undefined(): ZjsValue {.cabi.} = undefinedVal()

# --- Predicates (C ABI: return cint 0/1) ---
proc zjs_is_int32(v: ZjsValue): cint {.cabi.} = cint(isInt32(v))
proc zjs_is_double(v: ZjsValue): cint {.cabi.} = cint(isDouble(v))
proc zjs_is_number(v: ZjsValue): cint {.cabi.} = cint(isNumber(v))
proc zjs_is_bool(v: ZjsValue): cint {.cabi.} = cint(isBool(v))
proc zjs_is_null(v: ZjsValue): cint {.cabi.} = cint(isNull(v))
proc zjs_is_undefined(v: ZjsValue): cint {.cabi.} = cint(isUndefined(v))
proc zjs_is_cell(v: ZjsValue): cint {.cabi.} = cint(isCell(v))

# --- Unboxers (C ABI) ---
proc zjs_as_int32(v: ZjsValue): cint {.cabi.} = cint(asInt32(v))
proc zjs_as_double(v: ZjsValue): cdouble {.cabi.} = cdouble(asDouble(v))
proc zjs_as_bool(v: ZjsValue): cint {.cabi.} = asBool(v)
