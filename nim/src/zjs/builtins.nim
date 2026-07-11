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

# --- Math (src/context.zc host_math_* ~4357; realm install ~32692) -----
# The Math namespace object (g56): an ObjectCell whose properties are the
# static-method HostFnCells + the numeric constant data properties. Each
# method ToNumbers every arg via `argToDouble` (vmToNumber) — which BAILS on
# an object/function operand needing valueOf (the reference routes those
# through zjs_to_primitive; deferred here — a clean bail, never a wrong value).
#
# libm bit-exactness: the transcendentals MUST be byte-identical to zjs, which
# calls C libm directly. So we bind the SAME libm functions via `importc`
# (mirroring dtoa's snprintf / vm's c_fmod importc pattern) rather than trust
# Nim's std/math — importc removes all doubt about which routine runs.

proc c_sqrt(x: float64): float64  {.importc: "sqrt",  header: "<math.h>".}
proc c_pow(x, y: float64): float64 {.importc: "pow",  header: "<math.h>".}
proc c_sin(x: float64): float64   {.importc: "sin",   header: "<math.h>".}
proc c_cos(x: float64): float64   {.importc: "cos",   header: "<math.h>".}
proc c_tan(x: float64): float64   {.importc: "tan",   header: "<math.h>".}
proc c_asin(x: float64): float64  {.importc: "asin",  header: "<math.h>".}
proc c_acos(x: float64): float64  {.importc: "acos",  header: "<math.h>".}
proc c_atan(x: float64): float64  {.importc: "atan",  header: "<math.h>".}
proc c_atan2(y, x: float64): float64 {.importc: "atan2", header: "<math.h>".}
proc c_exp(x: float64): float64   {.importc: "exp",   header: "<math.h>".}
proc c_log(x: float64): float64   {.importc: "log",   header: "<math.h>".}
proc c_log2(x: float64): float64  {.importc: "log2",  header: "<math.h>".}
proc c_log10(x: float64): float64 {.importc: "log10", header: "<math.h>".}
proc c_log1p(x: float64): float64 {.importc: "log1p", header: "<math.h>".}
proc c_expm1(x: float64): float64 {.importc: "expm1", header: "<math.h>".}
proc c_sinh(x: float64): float64  {.importc: "sinh",  header: "<math.h>".}
proc c_cosh(x: float64): float64  {.importc: "cosh",  header: "<math.h>".}
proc c_tanh(x: float64): float64  {.importc: "tanh",  header: "<math.h>".}
proc c_asinh(x: float64): float64 {.importc: "asinh", header: "<math.h>".}
proc c_acosh(x: float64): float64 {.importc: "acosh", header: "<math.h>".}
proc c_atanh(x: float64): float64 {.importc: "atanh", header: "<math.h>".}
proc c_cbrt(x: float64): float64  {.importc: "cbrt",  header: "<math.h>".}
proc c_hypot(x, y: float64): float64 {.importc: "hypot", header: "<math.h>".}
proc c_floor(x: float64): float64 {.importc: "floor", header: "<math.h>".}
proc c_ceil(x: float64): float64  {.importc: "ceil",  header: "<math.h>".}
proc c_trunc(x: float64): float64 {.importc: "trunc", header: "<math.h>".}
proc c_fabs(x: float64): float64  {.importc: "fabs",  header: "<math.h>".}
proc c_rand(): cint {.importc: "rand", header: "<stdlib.h>".}
let C_RAND_MAX {.importc: "RAND_MAX", header: "<stdlib.h>".}: cint

# clz32 / imul do a C-truncating cast `(int32_t)(int64_t)d` that is UB/
# implementation-defined out of int64 range; reproduce the EXACT reference
# expressions in emitted C so the bytes match even on odd inputs (and so a
# huge argument can't trip a Nim float→int RangeDefect).
{.emit: """
#include <math.h>
#include <stdint.h>
static int32_t zjs_nim_math_clz32(double d) {
  uint32_t v;
  if (isnan(d) || isinf(d)) v = 0;
  else v = (uint32_t)((int64_t)d & 0xFFFFFFFFLL);
  if (v == 0) return 32;
  return (int32_t)__builtin_clz(v);
}
static int32_t zjs_nim_math_imul(double a, double b) {
  int32_t ai = (int32_t)(int64_t)a;
  int32_t bi = (int32_t)(int64_t)b;
  return (int32_t)((uint32_t)ai * (uint32_t)bi);
}
""".}
proc nimMathClz32(d: float64): int32 {.importc: "zjs_nim_math_clz32", nodecl.}
proc nimMathImul(a, b: float64): int32 {.importc: "zjs_nim_math_imul", nodecl.}

proc argAt(args: openArray[VmVal], i: int, dflt: float64): float64 {.inline.} =
  ## ToNumber(args[i]) as a float64, or the reference's argc-underflow default
  ## (NaN for floor/ceil/sqrt/round/pow; 0.0 for the libm wrappers/atan2/imul).
  if i < args.len: argToDouble(args[i]) else: dflt

proc isNegZero(d: float64): bool {.inline.} =
  d == 0.0 and (cast[uint64](d) and 0x8000000000000000'u64) != 0'u64

# One-arg libm wrapper family (host_math_sin/… ~4636): `d = argc>=1 ?
# ToNumber(arg0) : 0.0` (NOTE: the transcendentals default the missing arg to
# 0.0, NOT NaN — so `Math.sin()` → sin(0.0) → 0), then delegate to libm.
template mathUnary0(procname, cfn: untyped) =
  proc procname(heap: var GcHeap, args: openArray[VmVal],
                thisv: VmVal): VmVal {.nimcall.} =
    vv(doubleVal(cfn(argAt(args, 0, 0.0))))

mathUnary0(nativeMathSin,   c_sin)
mathUnary0(nativeMathCos,   c_cos)
mathUnary0(nativeMathTan,   c_tan)
mathUnary0(nativeMathAsin,  c_asin)
mathUnary0(nativeMathAcos,  c_acos)
mathUnary0(nativeMathAtan,  c_atan)
mathUnary0(nativeMathExp,   c_exp)
mathUnary0(nativeMathLog,   c_log)
mathUnary0(nativeMathLog2,  c_log2)
mathUnary0(nativeMathLog10, c_log10)
mathUnary0(nativeMathLog1p, c_log1p)
mathUnary0(nativeMathExpm1, c_expm1)
mathUnary0(nativeMathSinh,  c_sinh)
mathUnary0(nativeMathCosh,  c_cosh)
mathUnary0(nativeMathTanh,  c_tanh)
mathUnary0(nativeMathAsinh, c_asinh)
mathUnary0(nativeMathAcosh, c_acosh)
mathUnary0(nativeMathAtanh, c_atanh)
mathUnary0(nativeMathCbrt,  c_cbrt)
mathUnary0(nativeMathTrunc, c_trunc)

# floor / ceil / sqrt: explicit argc==0 → NaN (host_math_floor ~4375 etc.).
proc nativeMathFloor(heap: var GcHeap, args: openArray[VmVal],
                     thisv: VmVal): VmVal {.nimcall.} =
  if args.len == 0: return vv(doubleVal(NaN))
  vv(doubleVal(c_floor(argToDouble(args[0]))))

proc nativeMathCeil(heap: var GcHeap, args: openArray[VmVal],
                    thisv: VmVal): VmVal {.nimcall.} =
  if args.len == 0: return vv(doubleVal(NaN))
  vv(doubleVal(c_ceil(argToDouble(args[0]))))

proc nativeMathSqrt(heap: var GcHeap, args: openArray[VmVal],
                    thisv: VmVal): VmVal {.nimcall.} =
  if args.len == 0: return vv(doubleVal(NaN))
  vv(doubleVal(c_sqrt(argToDouble(args[0]))))

proc nativeMathRound(heap: var GcHeap, args: openArray[VmVal],
                     thisv: VmVal): VmVal {.nimcall.} =
  ## host_math_round ~4490: half toward +∞ via floor(x+0.5), with the -0
  ## exceptions. NaN→NaN; ±Inf→x; ±0→x; x∈(-0.5,0)→-0; else floor(x+0.5).
  if args.len == 0: return vv(doubleVal(NaN))
  let x = argToDouble(args[0])
  if x != x: return vv(doubleVal(NaN))
  if x == Inf or x == NegInf: return vv(doubleVal(x))
  if x == 0.0: return vv(doubleVal(x))          # preserves ±0
  if x < 0.0 and x >= -0.5: return vv(doubleVal(-0.0))
  vv(doubleVal(c_floor(x + 0.5)))

proc nativeMathAbs(heap: var GcHeap, args: openArray[VmVal],
                   thisv: VmVal): VmVal {.nimcall.} =
  ## host_math_abs ~4357: argc==0 → NaN; -0 → +0; NaN → NaN; else |x|.
  if args.len == 0: return vv(doubleVal(NaN))
  let d = argToDouble(args[0])
  if d == 0.0: return vv(doubleVal(0.0))         # -0 → +0
  if d < 0.0: return vv(doubleVal(-d))
  vv(doubleVal(d))                               # incl. NaN passthrough

proc nativeMathSign(heap: var GcHeap, args: openArray[VmVal],
                    thisv: VmVal): VmVal {.nimcall.} =
  ## host_math_sign ~4742: NaN→NaN; +0→+0; -0→-0; >0→1(int32); <0→-1(int32).
  let d = argAt(args, 0, 0.0)
  if d != d: return vv(doubleVal(d))
  if d > 0.0: return vv(int32Val(1))
  if d < 0.0: return vv(int32Val(-1))
  vv(doubleVal(d))                               # signed zero preserved

proc nativeMathFround(heap: var GcHeap, args: openArray[VmVal],
                      thisv: VmVal): VmVal {.nimcall.} =
  ## host_math_fround ~4813: (double)(float)d — round to float32 precision.
  vv(doubleVal(float64(float32(argAt(args, 0, 0.0)))))

proc nativeMathPow(heap: var GcHeap, args: openArray[VmVal],
                   thisv: VmVal): VmVal {.nimcall.} =
  ## host_math_pow ~4522: base/exp default NaN; |base|==1 && exp==±Inf → NaN
  ## (libm returns 1 there, spec mandates NaN); else pow(base, exp).
  let base = argAt(args, 0, NaN)
  let exp  = argAt(args, 1, NaN)
  if (exp == Inf or exp == NegInf) and c_fabs(base) == 1.0:
    return vv(doubleVal(NaN))
  vv(doubleVal(c_pow(base, exp)))

proc nativeMathAtan2(heap: var GcHeap, args: openArray[VmVal],
                     thisv: VmVal): VmVal {.nimcall.} =
  ## host_math_atan2 ~4666: y/x default 0.0.
  vv(doubleVal(c_atan2(argAt(args, 0, 0.0), argAt(args, 1, 0.0))))

proc nativeMathMax(heap: var GcHeap, args: openArray[VmVal],
                   thisv: VmVal): VmVal {.nimcall.} =
  ## host_math_max ~4540: empty → -Inf; any NaN → NaN; +0 ranks above -0.
  if args.len == 0: return vv(doubleVal(NegInf))
  var anyNan = false
  var sawPosZero = false
  var best = NegInf
  for a in args:
    let d = argToDouble(a)
    if d != d: anyNan = true
    else:
      if d == 0.0 and not isNegZero(d): sawPosZero = true
      if d > best: best = d
  if anyNan: return vv(doubleVal(NaN))
  if best == 0.0 and sawPosZero: return vv(doubleVal(0.0))
  vv(doubleVal(best))

proc nativeMathMin(heap: var GcHeap, args: openArray[VmVal],
                   thisv: VmVal): VmVal {.nimcall.} =
  ## host_math_min ~4587: empty → +Inf; any NaN → NaN; -0 ranks below +0.
  if args.len == 0: return vv(doubleVal(Inf))
  var anyNan = false
  var sawNegZero = false
  var best = Inf
  for a in args:
    let d = argToDouble(a)
    if d != d: anyNan = true
    else:
      if isNegZero(d): sawNegZero = true
      if d < best: best = d
  if anyNan: return vv(doubleVal(NaN))
  if best == 0.0 and sawNegZero: return vv(doubleVal(-0.0))
  vv(doubleVal(best))

proc nativeMathHypot(heap: var GcHeap, args: openArray[VmVal],
                     thisv: VmVal): VmVal {.nimcall.} =
  ## host_math_hypot ~4752: ToNumber all args; any ±Inf → +Inf; else any NaN
  ## → NaN; argc==1 → |x|; argc==2 → hypot(x,y); else sqrt(Σ xᵢ²).
  if args.len == 0: return vv(doubleVal(0.0))
  var pre = newSeq[float64](args.len)
  for i in 0 ..< args.len: pre[i] = argToDouble(args[i])
  var anyInf = false
  var anyNan = false
  for d in pre:
    if d == Inf or d == NegInf: anyInf = true
    if d != d: anyNan = true
  if anyInf: return vv(doubleVal(Inf))
  if anyNan: return vv(doubleVal(NaN))
  if pre.len == 1: return vv(doubleVal(c_fabs(pre[0])))
  if pre.len == 2: return vv(doubleVal(c_hypot(pre[0], pre[1])))
  var sum = 0.0
  for d in pre: sum = sum + d * d
  vv(doubleVal(c_sqrt(sum)))

proc nativeMathClz32(heap: var GcHeap, args: openArray[VmVal],
                     thisv: VmVal): VmVal {.nimcall.} =
  ## host_math_clz32 ~4819.
  vv(int32Val(nimMathClz32(argAt(args, 0, 0.0))))

proc nativeMathImul(heap: var GcHeap, args: openArray[VmVal],
                    thisv: VmVal): VmVal {.nimcall.} =
  ## host_math_imul ~4831: 32-bit integer multiply.
  vv(int32Val(nimMathImul(argAt(args, 0, 0.0), argAt(args, 1, 0.0))))

proc nativeMathRandom(heap: var GcHeap, args: openArray[VmVal],
                      thisv: VmVal): VmVal {.nimcall.} =
  ## host_math_random ~4842: rand()/(RAND_MAX+1.0) ∈ [0,1). Same coarse libc
  ## PRNG as the reference (value is unobservable to the diff oracle).
  vv(doubleVal(float64(c_rand()) / (float64(C_RAND_MAX) + 1.0)))

proc nativeMathSumPrecise(heap: var GcHeap, args: openArray[VmVal],
                          thisv: VmVal): VmVal {.nimcall.} =
  ## host_math_sum_precise ~4386 (TC39 proposal: iterator drain + Shewchuk
  ## correctly-rounded summation). Installed so `typeof Math.sumPrecise` is
  ## "function" (matching the oracle), but the computation is DEFERRED — it
  ## BAILS (clean, never a wrong value) rather than approximate.
  bail("Math.sumPrecise not implemented")

# --- Object (src/context.zc host_object_* ; realm install g57) ----------
# The `Object` global is a native CONSTRUCTOR: `typeof Object` is "function"
# (NOT "object" like Math), so it is installed as a HostFnCell — a callable
# whose native BAILS (constructor form deferred) — that ALSO carries its
# static methods in an objTable property bag. The compiler emits
# `LoadGlobal g57 + LoadProp .keys + MethodInvoke` for `Object.keys(o)`; the
# VM's LoadProp reads the static off that bag (see vm.nim), MethodInvoke
# dispatches to the native. This is the first "native that allocates and
# returns a new array/object" pattern: keys/values/entries/fromEntries/
# getOwnPropertyNames build fresh cells on the SAME heap threaded into
# runFunction (rooted via the return register / caller frame). The model has
# no non-enumerable / symbol / accessor properties, so own-enumerable = own =
# getOwnPropertyNames for a plain object.
#
# Bail discipline: everything outside the plain-object model — a primitive /
# array / string-wrapper receiver needing ToObject, descriptor flags,
# prototype-chain identity, the constructor form — BAILS (empty stdout, exit
# 1), never a wrong value.

proc objArg(x: VmVal): ptr ObjectCell {.inline.} =
  ## The arg as a plain ObjectCell, or nil if it isn't one (a primitive /
  ## array / function / string wrapper → the caller BAILS: outside the model).
  if x.kind == vkVal and isCell(x.v) and cellAsPtr(x.v) != nil and
     cellHeader(x.v).typeTag == TAG_OBJECT:
    cast[ptr ObjectCell](cellAsPtr(x.v))
  else:
    nil

proc argArrayCell(x: VmVal): ptr ArrayCell {.inline.} =
  ## The arg as a plain ArrayCell, or nil otherwise.
  if x.kind == vkVal and isCell(x.v) and cellAsPtr(x.v) != nil and
     cellHeader(x.v).typeTag == TAG_ARRAY:
    cast[ptr ArrayCell](cellAsPtr(x.v))
  else:
    nil

proc strAsArrayIndex(s: string): int64 =
  ## Port of context.zc string_as_array_index: the numeric value if `s` is a
  ## CanonicalNumericIndexString for a non-negative integer in u32 range (no
  ## leading zero except the singleton "0"), else -1. Drives the
  ## OrdinaryOwnPropertyKeys integer-key ordering below.
  let n = s.len
  if n == 0 or n > 10: return -1
  if s[0] == '0':
    if n == 1: return 0
    return -1
  if s[0] < '1' or s[0] > '9': return -1
  var v: uint64 = 0
  for ch in s:
    if ch < '0' or ch > '9': return -1
    v = v * 10 + uint64(ord(ch) - ord('0'))
  if v > 4294967295'u64: return -1
  int64(v)

proc orderedOwnKeys(heap: GcHeap, o: ptr ObjectCell): seq[string] =
  ## ECMA-262 OrdinaryOwnPropertyKeys over the model's own string keys:
  ## integer-index keys FIRST in ascending numeric order, then the remaining
  ## string keys in insertion order (context.zc object_keys_impl's two-pass).
  ## Probed byte-identical: `{2:3,1:4,x:5}` → ["1","2","x"], `{10:1,2:2,1:3}`
  ## → ["1","2","10"], `{b:1,a:2,c:3}` → ["b","a","c"] (pure string keys stay
  ## insertion order). Object keys are unique, so the index order is total.
  let names = objKeys(heap, o)
  var idxVals: seq[uint64] = @[]
  var idxNames: seq[string] = @[]
  var strNames: seq[string] = @[]
  for nm in names:
    let ix = strAsArrayIndex(nm)
    if ix >= 0:
      # insertion-sort (idxVals, idxNames) ascending by numeric value.
      var pos = idxVals.len
      idxVals.add(0'u64); idxNames.add("")
      while pos > 0 and idxVals[pos-1] > uint64(ix):
        idxVals[pos] = idxVals[pos-1]; idxNames[pos] = idxNames[pos-1]
        dec pos
      idxVals[pos] = uint64(ix); idxNames[pos] = nm
    else:
      strNames.add(nm)
  result = @[]
  for nm in idxNames: result.add(nm)
  for nm in strNames: result.add(nm)

proc nativeObjectKeys(heap: var GcHeap, args: openArray[VmVal],
                      thisv: VmVal): VmVal {.nimcall.} =
  ## Object.keys(o) — new Array of own enumerable string keys in
  ## OrdinaryOwnPropertyKeys order (context.zc host_object_keys). null /
  ## undefined → the reference throws a TypeError (empty stdout); a non-plain
  ## object receiver needs ToObject we don't model → both BAIL.
  if args.len == 0: bail("Object.keys with no argument")
  let o = objArg(args[0])
  if o == nil: bail("Object.keys on non-plain-object")
  var elems: seq[ZjsValue] = @[]
  for nm in orderedOwnKeys(heap, o):
    elems.add(cellValue(allocStringCell(heap, nm)))
  vv(cellValue(allocArray(heap, elems)))

proc nativeObjectValues(heap: var GcHeap, args: openArray[VmVal],
                        thisv: VmVal): VmVal {.nimcall.} =
  ## Object.values(o) — new Array of the corresponding own-enumerable values,
  ## in the same key order (context.zc host_object_values).
  if args.len == 0: bail("Object.values with no argument")
  let o = objArg(args[0])
  if o == nil: bail("Object.values on non-plain-object")
  var elems: seq[ZjsValue] = @[]
  for nm in orderedOwnKeys(heap, o):
    elems.add(objGet(heap, o, nm))      # stored ZjsValue passes through
  vv(cellValue(allocArray(heap, elems)))

proc nativeObjectEntries(heap: var GcHeap, args: openArray[VmVal],
                         thisv: VmVal): VmVal {.nimcall.} =
  ## Object.entries(o) — new Array of 2-element [key, value] Arrays
  ## (context.zc host_object_entries). No collect fires between the child
  ## allocations and the outer allocArray (allocCell never collects), so the
  ## fresh pair cells are safe until the outer array roots them.
  if args.len == 0: bail("Object.entries with no argument")
  let o = objArg(args[0])
  if o == nil: bail("Object.entries on non-plain-object")
  var elems: seq[ZjsValue] = @[]
  for nm in orderedOwnKeys(heap, o):
    let keyV = cellValue(allocStringCell(heap, nm))
    let valV = objGet(heap, o, nm)
    elems.add(cellValue(allocArray(heap, [keyV, valV])))
  vv(cellValue(allocArray(heap, elems)))

proc nativeObjectAssign(heap: var GcHeap, args: openArray[VmVal],
                        thisv: VmVal): VmVal {.nimcall.} =
  ## Object.assign(target, ...sources) — copy own-enumerable props from each
  ## source into target (later sources overwrite), return target (context.zc
  ## host_object_assign). target must be a plain object (a primitive target
  ## needs ToObject; null/undefined throws → BAIL). Sources: null/undefined
  ## AND number/boolean/string PRIMITIVES contribute no own enumerable string
  ## keys (the reference's Object.keys on them yields [] — probed:
  ## `Object.assign({a:1},5)`→ a=1, `Object.assign({a:1},"xy")`→ {"a":1}), so
  ## they are SKIPPED. A plain-object source's keys are copied in
  ## OrdinaryOwnPropertyKeys order. Array / function / string-object sources
  ## need index / .props enumeration we don't model → BAIL.
  if args.len == 0: bail("Object.assign with no target")
  let target = objArg(args[0])
  if target == nil: bail("Object.assign target is not a plain object")
  for i in 1 ..< args.len:
    let src = args[i]
    case src.kind
    of vkString: discard                # primitive string → no own keys → skip
    of vkFunction: bail("Object.assign function source (unmodeled own keys)")
    of vkVal:
      let sv = src.v
      if isUndefined(sv) or isNull(sv):
        discard                         # skipped per spec
      elif isInt32(sv) or isDouble(sv) or isBool(sv):
        discard                         # primitive wrapper has no own enum keys
      elif isCell(sv) and cellAsPtr(sv) != nil:
        case cellHeader(sv).typeTag
        of TAG_OBJECT:
          let so = cast[ptr ObjectCell](cellAsPtr(sv))
          for nm in orderedOwnKeys(heap, so):
            objSet(heap, target, nm, objGet(heap, so, nm))
        of TAG_STRING:
          discard                       # primitive string cell → no own keys
        else:
          bail("Object.assign source needs unmodeled enumeration")
      else:
        bail("Object.assign unrepresentable source")
  args[0]                               # return the (mutated) target

proc vmStringVal(heap: GcHeap, x: VmVal, s: var string): bool =
  ## True (and binds `s`) if `x` is a string value — a vkString or a StringCell.
  if x.kind == vkString:
    s = x.s; return true
  if x.kind == vkVal and isCell(x.v) and cellAsPtr(x.v) != nil and
     cellHeader(x.v).typeTag == TAG_STRING:
    s = strCellVal(heap, x.v); return true
  false

proc objectSameValue(heap: GcHeap, a, b: VmVal): bool =
  ## ECMA-262 SameValue (context.zc host_object_is): NaN≡NaN; +0≢-0; strings
  ## by value; objects/arrays by cell identity; else strict-equal. A function
  ## operand needs stable value identity the model doesn't give (a vkFunction
  ## has no cell) → BAIL (never a wrong true/false).
  if a.kind == vkFunction or b.kind == vkFunction:
    bail("Object.is on function operand")
  var sa, sb: string
  let aStr = vmStringVal(heap, a, sa)
  let bStr = vmStringVal(heap, b, sb)
  if aStr and bStr: return sa == sb
  if aStr or bStr: return false          # string vs non-string
  # Both are vkVal (non-string) here.
  let va = a.v
  let vb = b.v
  template isFnCell(v: ZjsValue): bool =
    isCell(v) and cellAsPtr(v) != nil and
      (cellHeader(v).typeTag == TAG_FUNCTION or cellHeader(v).typeTag == TAG_HOSTFN)
  if isFnCell(va) or isFnCell(vb):
    bail("Object.is on function operand")
  let aNum = isInt32(va) or isDouble(va)
  let bNum = isInt32(vb) or isDouble(vb)
  if aNum and bNum:
    let da = (if isInt32(va): float64(asInt32(va)) else: asDouble(va))
    let db = (if isInt32(vb): float64(asInt32(vb)) else: asDouble(vb))
    if da != da and db != db: return true          # NaN, NaN
    if da != da or db != db: return false
    if da == 0.0 and db == 0.0:
      return isNegZero(da) == isNegZero(db)         # +0 ≢ -0
    return da == db
  if aNum or bNum: return false
  if isBool(va) and isBool(vb): return asBool(va) == asBool(vb)
  if isBool(va) or isBool(vb): return false
  if isNull(va) and isNull(vb): return true
  if isNull(va) or isNull(vb): return false
  if isUndefined(va) and isUndefined(vb): return true
  if isUndefined(va) or isUndefined(vb): return false
  # Remaining: object / array cells → identity (same cell pointer).
  if isCell(va) and cellAsPtr(va) != nil and isCell(vb) and cellAsPtr(vb) != nil:
    return cellAsPtr(va) == cellAsPtr(vb)
  bail("Object.is on unsupported operands")

proc nativeObjectIs(heap: var GcHeap, args: openArray[VmVal],
                    thisv: VmVal): VmVal {.nimcall.} =
  ## Object.is(a, b) — SameValue. Pure value comparison, no allocation.
  let a = if args.len >= 1: args[0] else: vv(undefinedVal())
  let b = if args.len >= 2: args[1] else: vv(undefinedVal())
  vv(boolVal(objectSameValue(heap, a, b)))

proc nativeObjectFromEntries(heap: var GcHeap, args: openArray[VmVal],
                             thisv: VmVal): VmVal {.nimcall.} =
  ## Object.fromEntries(iterable) — new object from an Array of [k,v] pairs
  ## (context.zc host_object_from_entries ARRAY fast path). A non-array
  ## argument would need the iterator protocol (GetIterator) → BAIL. Matching
  ## the reference's MVP, a non-array ENTRY is silently skipped (probed:
  ## `Object.fromEntries([1,2])` → {}). Keys via ToString.
  let outObj = allocObject(heap)
  if args.len == 0: return vv(cellValue(outObj))
  let a = argArrayCell(args[0])
  if a == nil: bail("Object.fromEntries non-array iterable")
  let n = arrLength(heap, a)
  for i in 0 ..< n:
    let elem = arrGet(heap, a, i)
    if isCell(elem) and cellAsPtr(elem) != nil and
       cellHeader(elem).typeTag == TAG_ARRAY:
      let pair = cast[ptr ArrayCell](cellAsPtr(elem))
      if arrLength(heap, pair) >= 2:
        let keyStr = vmToString(unboxLoaded(heap, arrGet(heap, pair, 0)))
        objSet(heap, outObj, keyStr, arrGet(heap, pair, 1))
  vv(cellValue(outObj))

proc nativeObjectHasOwn(heap: var GcHeap, args: openArray[VmVal],
                        thisv: VmVal): VmVal {.nimcall.} =
  ## Object.hasOwn(o, key) — own-property presence, key via ToString
  ## (context.zc host_object_has_own). null/undefined receiver throws → BAIL;
  ## a non-plain-object receiver (array / function / string wrapper) is
  ## outside the model → BAIL.
  if args.len == 0: bail("Object.hasOwn with no argument")
  let o = objArg(args[0])
  if o == nil: bail("Object.hasOwn on non-plain-object")
  let key = if args.len >= 2: args[1] else: vv(undefinedVal())
  vv(boolVal(objHas(heap, o, vmToString(key))))

proc nativeObjectGetOwnPropertyNames(heap: var GcHeap, args: openArray[VmVal],
                                     thisv: VmVal): VmVal {.nimcall.} =
  ## Object.getOwnPropertyNames(o) — own string keys in OrdinaryOwnPropertyKeys
  ## order (context.zc host_object_get_own_property_names). The model has no
  ## non-enumerable string keys, so this equals Object.keys for a plain object.
  ## argc==0 → [] (the reference returns an empty array); non-plain-object → BAIL.
  if args.len == 0:
    var empty: seq[ZjsValue] = @[]
    return vv(cellValue(allocArray(heap, empty)))
  let o = objArg(args[0])
  if o == nil: bail("Object.getOwnPropertyNames on non-plain-object")
  var elems: seq[ZjsValue] = @[]
  for nm in orderedOwnKeys(heap, o):
    elems.add(cellValue(allocStringCell(heap, nm)))
  vv(cellValue(allocArray(heap, elems)))

proc protoCellOf(v: ZjsValue): ptr ObjectCell {.inline.} =
  ## `v` as a plain ObjectCell pointer, or nil (used to walk / validate a
  ## [[Prototype]] link, which is stored as a ZjsValue).
  if isCell(v) and cellAsPtr(v) != nil and cellHeader(v).typeTag == TAG_OBJECT:
    cast[ptr ObjectCell](cellAsPtr(v))
  else:
    nil

# --- Object.prototype methods (src/context.zc host_object_proto_*) ------
# Installed on the single Object.prototype cell (the root of the plain-object
# [[Prototype]] chain). Each receives the receiver as `thisv`; a non-plain-
# object receiver (array / primitive / wrapper needing ToObject) BAILS.

proc nativeObjProtoHasOwnProperty(heap: var GcHeap, args: openArray[VmVal],
                                  thisv: VmVal): VmVal {.nimcall.} =
  ## Object.prototype.hasOwnProperty(key) — OWN property presence on `this`
  ## (NOT the chain); ToString(key). Inherited names → false.
  let o = objArg(thisv)
  if o == nil: bail("hasOwnProperty on non-plain-object receiver")
  let key = vmToString(if args.len >= 1: args[0] else: vv(undefinedVal()))
  vv(boolVal(objHas(heap, o, key)))

proc nativeObjProtoIsPrototypeOf(heap: var GcHeap, args: openArray[VmVal],
                                 thisv: VmVal): VmVal {.nimcall.} =
  ## Object.prototype.isPrototypeOf(V) — true if `this` occurs in V's
  ## [[Prototype]] chain (starting ABOVE V). Non-object V → false.
  let self = objArg(thisv)
  if self == nil: bail("isPrototypeOf on non-plain-object receiver")
  if args.len == 0: return vv(boolVal(false))
  let start = objArg(args[0])
  if start == nil: return vv(boolVal(false))
  let selfPtr = cast[pointer](self)
  var node = protoCellOf(objGetProto(start))
  while node != nil:
    if cast[pointer](node) == selfPtr: return vv(boolVal(true))
    node = protoCellOf(objGetProto(node))
  vv(boolVal(false))

proc nativeObjProtoPropertyIsEnumerable(heap: var GcHeap, args: openArray[VmVal],
                                        thisv: VmVal): VmVal {.nimcall.} =
  ## Object.prototype.propertyIsEnumerable(key) — own AND enumerable. Every own
  ## property is enumerable in this model → equivalent to hasOwnProperty.
  let o = objArg(thisv)
  if o == nil: bail("propertyIsEnumerable on non-plain-object receiver")
  let key = vmToString(if args.len >= 1: args[0] else: vv(undefinedVal()))
  vv(boolVal(objHas(heap, o, key)))

proc nativeObjProtoToString(heap: var GcHeap, args: openArray[VmVal],
                            thisv: VmVal): VmVal {.nimcall.} =
  ## Object.prototype.toString() — "[object Object]" for a plain object.
  ## (Array/Function/wrapper builtinTag + Symbol.toStringTag variants deferred.)
  let o = objArg(thisv)
  if o == nil: bail("Object.prototype.toString on non-plain-object receiver")
  vs("[object Object]")

proc nativeObjProtoValueOf(heap: var GcHeap, args: openArray[VmVal],
                           thisv: VmVal): VmVal {.nimcall.} =
  ## Object.prototype.valueOf() — ToObject(this); for a plain object, itself.
  let o = objArg(thisv)
  if o == nil: bail("Object.prototype.valueOf on non-plain-object receiver")
  thisv

proc nativeObjProtoToLocaleString(heap: var GcHeap, args: openArray[VmVal],
                                  thisv: VmVal): VmVal {.nimcall.} =
  ## Object.prototype.toLocaleString() — this.toString(); "[object Object]".
  let o = objArg(thisv)
  if o == nil: bail("toLocaleString on non-plain-object receiver")
  vs("[object Object]")

# --- Object statics that require the prototype chain --------------------

proc nativeObjectGetPrototypeOf(heap: var GcHeap, args: openArray[VmVal],
                                thisv: VmVal): VmVal {.nimcall.} =
  ## Object.getPrototypeOf(o) — o's [[Prototype]] (Object.prototype for a plain
  ## object literal, the class prototype for an instance, null for a null-proto
  ## object). Primitive / null / undefined arg → ToObject/throws → BAIL.
  if args.len == 0: bail("Object.getPrototypeOf with no argument")
  let o = objArg(args[0])
  if o == nil: bail("Object.getPrototypeOf on non-plain-object")
  vv(objGetProto(o))

proc nativeObjectSetPrototypeOf(heap: var GcHeap, args: openArray[VmVal],
                                thisv: VmVal): VmVal {.nimcall.} =
  ## Object.setPrototypeOf(o, proto) — set o's [[Prototype]] (object or null),
  ## return o. Non-plain-object o or a non-object/non-null proto → BAIL.
  if args.len < 2: bail("Object.setPrototypeOf needs 2 arguments")
  let o = objArg(args[0])
  if o == nil: bail("Object.setPrototypeOf on non-plain-object")
  let p = args[1]
  if p.kind == vkVal and (isNull(p.v) or protoCellOf(p.v) != nil):
    objSetProto(o, p.v)
  else:
    bail("Object.setPrototypeOf proto is not object-or-null")
  args[0]

proc nativeObjectCreate(heap: var GcHeap, args: openArray[VmVal],
                        thisv: VmVal): VmVal {.nimcall.} =
  ## Object.create(proto[, propsDescriptors]) — new object with the given
  ## [[Prototype]] (object or null). The 2nd (descriptor) arg needs descriptor
  ## machinery → BAIL when present. proto undefined/primitive → throws → BAIL.
  if args.len == 0: bail("Object.create with no argument")
  if args.len >= 2 and not (args[1].kind == vkVal and isUndefined(args[1].v)):
    bail("Object.create with property descriptors (deferred)")
  let proto = args[0]
  let newO = allocObject(heap)
  if proto.kind == vkVal and isNull(proto.v):
    objSetProto(newO, nullVal())
  elif proto.kind == vkVal and protoCellOf(proto.v) != nil:
    objSetProto(newO, proto.v)
  else:
    bail("Object.create proto is not object-or-null")
  vv(cellValue(newO))

proc nativeObjectCtor(heap: var GcHeap, args: openArray[VmVal],
                      thisv: VmVal): VmVal {.nimcall.} =
  ## `Object(value)` / `new Object()` — the constructor form (context.zc
  ## host_object_ctor). Needs Object.prototype identity + ToObject wrapper
  ## materialization the model lacks → BAIL (never a wrong value). Installed
  ## only so `typeof Object` is "function" and `Object.<static>` resolves off
  ## its property bag.
  bail("Object constructor not implemented")

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
  # Math (g56) — a namespace object of static-method HostFnCells + numeric
  # constant data properties (src/context.zc ~32692). Same allocate-on-the-
  # threaded-heap + reachable-via-globals rooting story as console.
  block installMath:
    let math = allocObject(heap)
    template setM(nm: string, fn: NativeFn, arity: int) =
      objSet(heap, math, nm,
             cellValue(allocHostFunction(heap, cast[pointer](fn), nm, arity)))
    setM("abs",    nativeMathAbs,    1)
    setM("floor",  nativeMathFloor,  1)
    setM("ceil",   nativeMathCeil,   1)
    setM("round",  nativeMathRound,  1)
    setM("sqrt",   nativeMathSqrt,   1)
    setM("pow",    nativeMathPow,    2)
    setM("max",    nativeMathMax,    2)
    setM("min",    nativeMathMin,    2)
    setM("sin",    nativeMathSin,    1)
    setM("cos",    nativeMathCos,    1)
    setM("tan",    nativeMathTan,    1)
    setM("asin",   nativeMathAsin,   1)
    setM("acos",   nativeMathAcos,   1)
    setM("atan",   nativeMathAtan,   1)
    setM("atan2",  nativeMathAtan2,  2)
    setM("exp",    nativeMathExp,    1)
    setM("log",    nativeMathLog,    1)
    setM("log2",   nativeMathLog2,   1)
    setM("log10",  nativeMathLog10,  1)
    setM("log1p",  nativeMathLog1p,  1)
    setM("expm1",  nativeMathExpm1,  1)
    setM("sinh",   nativeMathSinh,   1)
    setM("cosh",   nativeMathCosh,   1)
    setM("tanh",   nativeMathTanh,   1)
    setM("asinh",  nativeMathAsinh,  1)
    setM("acosh",  nativeMathAcosh,  1)
    setM("atanh",  nativeMathAtanh,  1)
    setM("cbrt",   nativeMathCbrt,   1)
    setM("trunc",  nativeMathTrunc,  1)
    setM("sign",   nativeMathSign,   1)
    setM("hypot",  nativeMathHypot,  2)
    setM("fround", nativeMathFround, 1)
    setM("clz32",  nativeMathClz32,  1)
    setM("imul",   nativeMathImul,   2)
    setM("random", nativeMathRandom, 0)
    setM("sumPrecise", nativeMathSumPrecise, 1)
    # Numeric constants — ECMA-262 §21.3.1, the exact IEEE-754 doubles the
    # reference installs (M_* / Math::PI()/E()). Nim's float-literal parser is
    # correct-rounding, so these decimals reproduce the exact bit patterns
    # (verified byte-identical via `''+Math.PI` … in the surface battery).
    objSet(heap, math, "PI",      doubleVal(3.141592653589793))
    objSet(heap, math, "E",       doubleVal(2.718281828459045))
    objSet(heap, math, "LN2",     doubleVal(0.6931471805599453))
    objSet(heap, math, "LN10",    doubleVal(2.302585092994046))
    objSet(heap, math, "LOG2E",   doubleVal(1.4426950408889634))
    objSet(heap, math, "LOG10E",  doubleVal(0.4342944819032518))
    objSet(heap, math, "SQRT2",   doubleVal(1.4142135623730951))
    objSet(heap, math, "SQRT1_2", doubleVal(0.7071067811865476))
    globals[builtinSlot("Math")] = vv(cellValue(math))
  # Object (g57) — a native CONSTRUCTOR (typeof → "function", so a HostFnCell,
  # NOT an ObjectCell like Math) whose native BAILS (the `Object(x)` /
  # `new Object()` form is deferred) but which carries its static methods in an
  # objTable property bag. The VM's LoadProp reads a static off that bag; a
  # missing static (freeze / getPrototypeOf / defineProperty / .name / …) BAILS
  # there (never a wrong `undefined`). markCell(TAG_HOSTFN) traverses this bag,
  # so the boxed method cells survive a collect (same rooting story as Math /
  # console). Object.keys/values/entries/fromEntries/getOwnPropertyNames build
  # fresh arrays/objects on this heap, rooted via the caller's return register.
  block installObject:
    let objectFn = allocHostFunction(
      heap, cast[pointer](nativeObjectCtor), "Object", 1)
    # objSet/objGet key the objTable by cell-pointer identity only (they never
    # dereference ObjectCell fields), so a HostFnCell can carry a property bag.
    let objectBag = cast[ptr ObjectCell](objectFn)
    template setO(nm: string, fn: NativeFn, arity: int) =
      objSet(heap, objectBag, nm,
             cellValue(allocHostFunction(heap, cast[pointer](fn), nm, arity)))
    setO("keys",                nativeObjectKeys,                1)
    setO("values",              nativeObjectValues,              1)
    setO("entries",             nativeObjectEntries,             1)
    setO("assign",              nativeObjectAssign,              2)
    setO("is",                  nativeObjectIs,                  2)
    setO("fromEntries",         nativeObjectFromEntries,         1)
    setO("hasOwn",              nativeObjectHasOwn,              2)
    setO("getOwnPropertyNames", nativeObjectGetOwnPropertyNames, 1)
    setO("getPrototypeOf",      nativeObjectGetPrototypeOf,      1)
    setO("setPrototypeOf",      nativeObjectSetPrototypeOf,      2)
    setO("create",              nativeObjectCreate,              2)
    # Object.prototype — the single cell at the root of every plain object's
    # [[Prototype]] chain. Its native methods resolve through protoChainLookup
    # for any `{}`.method(). Reachable via the Object bag (`.prototype`), so
    # markCell(TAG_HOSTFN)->bag->this object->its method cells keeps it alive;
    # its own proto stays undefined (the chain terminates here).
    block installObjectProto:
      let objectProto = allocObject(heap)
      template setP(nm: string, fn: NativeFn, arity: int) =
        objSet(heap, objectProto, nm,
               cellValue(allocHostFunction(heap, cast[pointer](fn), nm, arity)))
      setP("hasOwnProperty",       nativeObjProtoHasOwnProperty,       1)
      setP("isPrototypeOf",        nativeObjProtoIsPrototypeOf,        1)
      setP("propertyIsEnumerable", nativeObjProtoPropertyIsEnumerable, 1)
      setP("toString",             nativeObjProtoToString,             0)
      setP("valueOf",              nativeObjProtoValueOf,              0)
      setP("toLocaleString",       nativeObjProtoToLocaleString,       0)
      let protoVal = cellValue(objectProto)
      objSet(heap, objectBag, "prototype", protoVal)   # Object.prototype
      setObjectProto(protoVal)                          # NewObject default proto
    globals[builtinSlot("Object")] = vv(cellValue(objectFn))
