## Phase 6 slice 2 — native (host) built-in functions + realm install.
##
## Ports the reference realm's value/function globals into the VM's global
## slot array, at the FIXED slots from `builtins_globals.nim` (the Zen-c
## registration order, USER_GLOBAL_BASE=108). A native builtin is a Nim proc
## (`NativeFn`) boxed into a HostFnCell GC value living in its global slot; the
## VM's Invoke / InvokeGlobal / MethodInvoke handlers dispatch to it. Each new
## intrinsic is an additive registration here.
##
## Bail discipline (CRITICAL): a native may `bail(msg)` for an arg shape
## outside its supported subset (e.g. an object arg needing valueOf coercion)
## — a clean VmBail (empty stdout, nonzero exit), NEVER a wrong value.

import std/strutils
import value, gc, vm
import builtins_globals

# --- number coercion helper --------------------------------------------
# The globals `isNaN` / `isFinite` both do `d = ToNumber(arg)` then a
# float predicate (src/context.zc host_is_nan ~26781 / host_is_finite ~26789).
# We reuse the VM's `vmToNumber` (the validated Phase-4 ToNumber ladder:
# number passthrough, "5"→5, true→1, null→0, undefined→NaN) which BAILS on an
# object / function operand — exactly the deferred "needs valueOf" case. The
# result is always a numeric ZjsValue (int32 or double); collapse it to a
# float64 for the isnan / isfinite test.

proc argToDouble(x: VmVal): float64 =
  let n = vmToNumber(x)   # numeric ZjsValue; bails on object/function operand
  if isInt32(n): float64(asInt32(n)) else: asDouble(n)

# --- global isNaN (src/context.zc host_is_nan ~26781) ------------------

proc nativeIsNaN(heap: var GcHeap, args: openArray[VmVal],
                 thisv: VmVal): VmVal {.nimcall.} =
  ## isNaN(x): ToNumber(x) then test NaN. No args → ToNumber(undefined)=NaN →
  ## true (the reference short-circuits argc==0 to true; same result).
  if args.len == 0: return vv(boolVal(true))
  let d = argToDouble(args[0])
  vv(boolVal(d != d))                 # d != d  <=>  d is NaN

# --- global isFinite (src/context.zc host_is_finite ~26789) ------------

proc nativeIsFinite(heap: var GcHeap, args: openArray[VmVal],
                    thisv: VmVal): VmVal {.nimcall.} =
  ## isFinite(x): ToNumber(x) then test isfinite (not NaN, not ±Infinity).
  ## No args → false (the reference short-circuits argc==0 to false).
  if args.len == 0: return vv(boolVal(false))
  let d = argToDouble(args[0])
  vv(boolVal(d == d and d != Inf and d != NegInf))

# --- console (src/context.zc console_log / write_value_json ~) ---------
# `console.log(...)` (and its info/error/warn aliases) formats each argument
# and joins them with a single space, then writes one line (trailing '\n').
# Argument formatting has TWO regimes, matching the reference:
#   * TOP-LEVEL arg — a bare string prints RAW (unquoted); a number uses
#     Number::toString (NaN/Infinity/-Infinity/-0 spelled literally, via the
#     validated `vmToString`); bool/null/undefined print their keywords; a
#     function value prints "[function]"; an object/array uses the JSON form
#     below.
#   * NESTED value (inside an object/array) — PURE JSON.stringify semantics:
#     strings are double-quoted + JSON-escaped; a non-finite number prints
#     `null`; -0 prints `0`; `undefined` / a function value is DROPPED from an
#     object and becomes `null` in an array; nested objects/arrays recurse.
# Keys are own enumerable names in INSERTION ORDER (the reference does NOT
# reorder integer keys — probed: `{2:..,1:..}` stays 2,1). A circular
# structure is BAILED (the reference emits a broken partial + a thrown
# TypeError; not faithfully reproducible) — a clean bail, never a wrong line.

const CONSOLE_MAX_DEPTH = 1000
  ## Recursion cap for the JSON walk. Path-based `seen` already bails true
  ## cycles; this guards pathological finite nesting from a native-stack
  ## overflow before the cycle check (parity with nim_eval's inspect cap).

proc jsonEscape(s: string): string =
  ## JSON string escaping (ECMA-262 JSON.stringify QuoteJSONString): escape
  ## `"` `\` and the C0 control chars (short forms \b \f \n \r \t, else
  ## \u00XX lowercase); every other byte (incl. UTF-8 >= 0x80) passes RAW.
  result = newStringOfCap(s.len + 2)
  const hexd = "0123456789abcdef"
  for ch in s:
    case ch
    of '"':  result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\b': result.add("\\b")
    of '\f': result.add("\\f")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else:
      let b = uint8(ch)
      if b < 0x20'u8:
        result.add("\\u00")
        result.add(hexd[int(b shr 4)])
        result.add(hexd[int(b and 0x0f'u8)])
      else:
        result.add(ch)

proc jsonNested(heap: GcHeap, x: VmVal, seen: var seq[pointer],
                depth: int): tuple[rep: bool, s: string] =
  ## Serialize a NESTED value (JSON.stringify SerializeJSONProperty). `rep`
  ## is false when the value is JSON-unrepresentable (undefined / function) —
  ## the caller then drops it (object) or emits `null` (array).
  if depth > CONSOLE_MAX_DEPTH: bail("console.log nesting too deep")
  case x.kind
  of vkString:
    return (true, "\"" & jsonEscape(x.s) & "\"")
  of vkFunction:
    return (false, "")                     # function → unrepresentable
  of vkVal:
    let v = x.v
    if isInt32(v): return (true, $asInt32(v))
    if isDouble(v):
      let d = asDouble(v)
      if d != d or d == Inf or d == NegInf: return (true, "null")
      return (true, vmToString(x))         # finite → Number::toString (-0→"0")
    if isBool(v):      return (true, (if asBool(v) != 0: "true" else: "false"))
    if isNull(v):      return (true, "null")
    if isUndefined(v): return (false, "")  # undefined → unrepresentable
    if isHole(v):      return (false, "")  # array hole → treated as undefined
    if not isCell(v) or cellAsPtr(v) == nil:
      bail("console.log unrepresentable nested value")
    let p = cellAsPtr(v)
    case cellHeader(v).typeTag
    of TAG_STRING:
      return (true, "\"" & jsonEscape(strCellVal(heap, v)) & "\"")
    of TAG_FUNCTION, TAG_HOSTFN:
      return (false, "")                   # function value → unrepresentable
    of TAG_OBJECT:
      if p in seen: bail("console.log circular structure")
      seen.add(p)
      let o = cast[ptr ObjectCell](p)
      var parts: seq[string] = @[]
      for name in objKeys(heap, o):
        let child = unboxLoaded(heap, objGet(heap, o, name))
        let r = jsonNested(heap, child, seen, depth + 1)
        if r.rep:                          # undefined / function props dropped
          parts.add("\"" & jsonEscape(name) & "\":" & r.s)
      discard seen.pop()
      return (true, "{" & parts.join(",") & "}")
    of TAG_ARRAY:
      if p in seen: bail("console.log circular structure")
      seen.add(p)
      let a = cast[ptr ArrayCell](p)
      var parts: seq[string] = @[]
      for i in 0 ..< arrLength(heap, a):
        let child = unboxLoaded(heap, arrGet(heap, a, i))  # holes → undefined
        let r = jsonNested(heap, child, seen, depth + 1)
        parts.add(if r.rep: r.s else: "null")   # undefined / function → null
      discard seen.pop()
      return (true, "[" & parts.join(",") & "]")
    else:
      bail("console.log unknown cell in container")

proc consoleFormat(heap: GcHeap, x: VmVal): string =
  ## Format ONE top-level console argument (see the regime notes above).
  case x.kind
  of vkString:   return x.s               # raw, unquoted at top level
  of vkFunction: return "[function]"
  of vkVal:
    let v = x.v
    if isCell(v) and cellAsPtr(v) != nil:
      case cellHeader(v).typeTag
      of TAG_OBJECT, TAG_ARRAY:
        var seen: seq[pointer] = @[]
        let r = jsonNested(heap, x, seen, 0)
        if not r.rep: bail("console.log top-level container unrepresentable")
        return r.s
      of TAG_STRING:               return strCellVal(heap, v)   # raw
      of TAG_FUNCTION, TAG_HOSTFN: return "[function]"
      else: bail("console.log unknown top-level cell")
    else:
      # Primitive: number (Number::toString incl NaN/Infinity/-Infinity/-0),
      # bool, null, or undefined (top-level undefined IS printed).
      return vmToString(x)

proc consoleWriteLine(heap: GcHeap, args: openArray[VmVal], toErr: bool) =
  ## Join the formatted args with a single space and write one line. log/info
  ## → stdout; error/warn → stderr (probed: the reference routes error/warn to
  ## stderr, so they never appear on the stdout the oracle compares).
  var parts = newSeq[string](args.len)
  for i in 0 ..< args.len:
    parts[i] = consoleFormat(heap, args[i])
  let line = parts.join(" ") & "\n"
  if toErr: stderr.write(line)
  else:     stdout.write(line)

proc nativeConsoleLog(heap: var GcHeap, args: openArray[VmVal],
                      thisv: VmVal): VmVal {.nimcall.} =
  ## console.log / console.info — format args to STDOUT, return undefined.
  consoleWriteLine(heap, args, toErr = false)
  vv(undefinedVal())

proc nativeConsoleError(heap: var GcHeap, args: openArray[VmVal],
                        thisv: VmVal): VmVal {.nimcall.} =
  ## console.error / console.warn — format args to STDERR, return undefined.
  consoleWriteLine(heap, args, toErr = true)
  vv(undefinedVal())

# --- realm install -----------------------------------------------------

const USER_GLOBAL_BASE = 108
  ## Slots 0..107 are the built-in realm globals; user globals begin here.
  ## Reserve the whole built-in range so every fixed slot is present (matching
  ## the reference realm), then seed the ones this slice implements.

proc installBuiltins*(globals: var seq[VmVal], heap: var GcHeap) =
  ## Seed the built-in global slots into `globals`, allocating native cells on
  ## `heap` (the SAME heap threaded into runFunction, so the cells are rooted
  ## via globals and survive collects). Additive: unimplemented built-in slots
  ## stay zero-bits placeholders (referencing them bails — correct for an
  ## unimplemented builtin).
  if globals.len < USER_GLOBAL_BASE:
    globals.setLen(USER_GLOBAL_BASE)
  # Value globals referenced by the isNaN/isFinite battery: `NaN` (g2) and
  # `Infinity` (g3) are plain numeric realm globals (the compiler emits
  # `LoadGlobal g2` / `g3` for the identifiers), so they MUST hold real values
  # or the load bails. Exact IEEE NaN / +Infinity — never a wrong value.
  globals[builtinSlot("NaN")]      = vv(doubleVal(NaN))
  globals[builtinSlot("Infinity")] = vv(doubleVal(Inf))
  # Native function globals (this slice's deliverable): isNaN (g5), isFinite
  # (g6). Each is a HostFnCell boxed as a ZjsValue in its fixed slot.
  globals[builtinSlot("isNaN")] =
    vv(cellValue(allocHostFunction(heap, cast[pointer](nativeIsNaN), "isNaN", 1)))
  globals[builtinSlot("isFinite")] =
    vv(cellValue(allocHostFunction(heap, cast[pointer](nativeIsFinite), "isFinite", 1)))
  # console (g60) — the first native-as-object-PROPERTY: an ObjectCell whose
  # `log`/`info`/`error`/`warn` properties are HostFnCell values. The whole
  # object is boxed into slot g60, so `console.log(...)` (compiled to
  # LoadGlobal g60 + LoadProp .log + MethodInvoke) dispatches to the native.
  # Allocated on the SAME heap threaded into runFunction; reachable via
  # globals → markRoots keeps the console object and its native cells alive.
  block installConsole:
    let console = allocObject(heap)
    let logFn = cellValue(
      allocHostFunction(heap, cast[pointer](nativeConsoleLog), "log", 0))
    let errFn = cellValue(
      allocHostFunction(heap, cast[pointer](nativeConsoleError), "error", 0))
    # log + info share the stdout native; error + warn share the stderr native.
    objSet(heap, console, "log", logFn)
    objSet(heap, console, "info", logFn)
    objSet(heap, console, "error", errFn)
    objSet(heap, console, "warn", errFn)
    globals[builtinSlot("console")] = vv(cellValue(console))
