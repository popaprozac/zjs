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

# --- Array (src/context.zc host_array_* ; Array.prototype + g9) ---------
# Array.prototype's methods dispatch via the VM's LoadProp array branch (which
# looks the name up on the registered Array.prototype cell). Each native gets
# the array as `thisv`. Tranche 1 = non-callback methods; the callback family
# (forEach/map/filter/reduce/…) needs native→JS re-entrancy → a later tranche.

proc arrThis(thisv: VmVal): ptr ArrayCell {.inline.} =
  ## The receiver as an ArrayCell (or nil).
  argArrayCell(thisv)

proc toIntArg(x: VmVal): int =
  ## ECMA ToIntegerOrInfinity, clamped to Nim int (NaN→0, truncate toward 0).
  ## Used for fromIndex / start / end / at index args.
  let d = argToDouble(x)
  if d != d: return 0
  if d >= 9.2e18: return high(int)
  if d <= -9.2e18: return low(int)
  int(d)

proc relStart(x: VmVal, n: int): int =
  ## Relative start index: negative counts from the end, clamp to [0, n].
  let i = toIntArg(x)
  if i < 0: max(n + i, 0) else: min(i, n)

proc sameValueZero(a, b: VmVal): bool =
  ## SameValueZero (Array.prototype.includes): === but NaN matches NaN.
  if vmStrictEq(a, b): return true
  if a.kind == vkVal and b.kind == vkVal:
    let av = a.v; let bv = b.v
    let an = isInt32(av) or isDouble(av)
    let bn = isInt32(bv) or isDouble(bv)
    if an and bn:
      let ad = (if isInt32(av): float64(asInt32(av)) else: asDouble(av))
      let bd = (if isInt32(bv): float64(asInt32(bv)) else: asDouble(bv))
      return ad != ad and bd != bd
  false

proc nativeArrayIsArray(heap: var GcHeap, args: openArray[VmVal],
                        thisv: VmVal): VmVal {.nimcall.} =
  ## Array.isArray(v) — true iff v is an Array exotic object.
  if args.len == 0: return vv(boolVal(false))
  vv(boolVal(argArrayCell(args[0]) != nil))

proc nativeArrayPush(heap: var GcHeap, args: openArray[VmVal],
                     thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.push(...items) — append, return the new length.
  let a = arrThis(thisv)
  if a == nil: bail("Array.prototype.push on non-array receiver")
  var s = arrElems(heap, a)
  for arg in args: s.add(boxForStore(heap, arg))
  arrReplace(heap, a, s)
  vv(int32Val(int32(s.len)))

proc nativeArrayPop(heap: var GcHeap, args: openArray[VmVal],
                    thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.pop() — remove & return the last element (undefined if empty).
  let a = arrThis(thisv)
  if a == nil: bail("Array.prototype.pop on non-array receiver")
  var s = arrElems(heap, a)
  if s.len == 0: return vv(undefinedVal())
  let last = s[^1]
  s.setLen(s.len - 1)
  arrReplace(heap, a, s)
  if last.bits == deletedVal().bits: return vv(undefinedVal())
  unboxLoaded(heap, last)

proc nativeArrayShift(heap: var GcHeap, args: openArray[VmVal],
                      thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.shift() — remove & return the first element.
  let a = arrThis(thisv)
  if a == nil: bail("Array.prototype.shift on non-array receiver")
  var s = arrElems(heap, a)
  if s.len == 0: return vv(undefinedVal())
  let first = s[0]
  s.delete(0)
  arrReplace(heap, a, s)
  if first.bits == deletedVal().bits: return vv(undefinedVal())
  unboxLoaded(heap, first)

proc nativeArrayUnshift(heap: var GcHeap, args: openArray[VmVal],
                        thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.unshift(...items) — prepend, return the new length.
  let a = arrThis(thisv)
  if a == nil: bail("Array.prototype.unshift on non-array receiver")
  let s = arrElems(heap, a)
  var prep: seq[ZjsValue] = @[]
  for arg in args: prep.add(boxForStore(heap, arg))
  arrReplace(heap, a, prep & s)
  vv(int32Val(int32(prep.len + s.len)))

proc nativeArrayIndexOf(heap: var GcHeap, args: openArray[VmVal],
                        thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.indexOf(search, fromIndex?) — strict-equal; skips holes;
  ## indexOf(NaN) = -1.
  let a = arrThis(thisv)
  if a == nil: bail("Array.prototype.indexOf on non-array receiver")
  let s = arrElems(heap, a)
  let search = (if args.len >= 1: args[0] else: vv(undefinedVal()))
  var start = 0
  if args.len >= 2:
    let f = toIntArg(args[1])
    start = (if f < 0: max(s.len + f, 0) else: f)
  var i = start
  while i < s.len:
    if s[i].bits != deletedVal().bits and vmStrictEq(search, unboxLoaded(heap, s[i])):
      return vv(int32Val(int32(i)))
    inc i
  vv(int32Val(-1'i32))

proc nativeArrayLastIndexOf(heap: var GcHeap, args: openArray[VmVal],
                            thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.lastIndexOf(search) — strict-equal, from the end; skips holes.
  let a = arrThis(thisv)
  if a == nil: bail("Array.prototype.lastIndexOf on non-array receiver")
  let s = arrElems(heap, a)
  let search = (if args.len >= 1: args[0] else: vv(undefinedVal()))
  var i = s.len - 1
  while i >= 0:
    if s[i].bits != deletedVal().bits and vmStrictEq(search, unboxLoaded(heap, s[i])):
      return vv(int32Val(int32(i)))
    dec i
  vv(int32Val(-1'i32))

proc nativeArrayIncludes(heap: var GcHeap, args: openArray[VmVal],
                         thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.includes(search, fromIndex?) — SameValueZero; holes read as
  ## undefined; includes(NaN) = true.
  let a = arrThis(thisv)
  if a == nil: bail("Array.prototype.includes on non-array receiver")
  let n = arrLength(heap, a)
  let search = (if args.len >= 1: args[0] else: vv(undefinedVal()))
  var start = 0
  if args.len >= 2:
    let f = toIntArg(args[1])
    start = (if f < 0: max(n + f, 0) else: f)
  var i = start
  while i < n:
    if sameValueZero(search, unboxLoaded(heap, arrGet(heap, a, i))):
      return vv(boolVal(true))
    inc i
  vv(boolVal(false))

proc nativeArrayJoin(heap: var GcHeap, args: openArray[VmVal],
                     thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.join(sep?) — sep defaults to ",". undefined/null/hole → "".
  let a = arrThis(thisv)
  if a == nil: bail("Array.prototype.join on non-array receiver")
  var sep = ","
  if args.len >= 1 and not (args[0].kind == vkVal and isUndefined(args[0].v)):
    sep = vmToString(args[0])
  let n = arrLength(heap, a)
  var res = ""
  var i = 0
  while i < n:
    if i > 0: res.add(sep)
    let ev = arrGet(heap, a, i)          # hole → undefined
    if not (isUndefined(ev) or isNull(ev)):
      res.add(vmToString(unboxLoaded(heap, ev)))
    inc i
  vs(res)

proc nativeArraySlice(heap: var GcHeap, args: openArray[VmVal],
                      thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.slice(start?, end?) — new Array of the [start,end) range
  ## (negative = from end); holes preserved.
  let a = arrThis(thisv)
  if a == nil: bail("Array.prototype.slice on non-array receiver")
  let s = arrElems(heap, a)
  let n = s.len
  var start = 0
  if args.len >= 1 and not (args[0].kind == vkVal and isUndefined(args[0].v)):
    start = relStart(args[0], n)
  var stop = n
  if args.len >= 2 and not (args[1].kind == vkVal and isUndefined(args[1].v)):
    stop = relStart(args[1], n)
  var outv: seq[ZjsValue] = @[]
  var i = start
  while i < stop:
    outv.add(s[i])
    inc i
  vv(cellValue(allocArray(heap, outv)))

proc nativeArrayConcat(heap: var GcHeap, args: openArray[VmVal],
                       thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.concat(...args) — new Array = this ++ (array args spread one
  ## level, other args appended).
  let a = arrThis(thisv)
  if a == nil: bail("Array.prototype.concat on non-array receiver")
  var outv = arrElems(heap, a)
  for arg in args:
    let ac = argArrayCell(arg)
    if ac != nil:
      for e in arrElems(heap, ac): outv.add(e)
    else:
      outv.add(boxForStore(heap, arg))
  vv(cellValue(allocArray(heap, outv)))

proc nativeArrayAt(heap: var GcHeap, args: openArray[VmVal],
                   thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.at(i) — element at i (negative from end), else undefined.
  let a = arrThis(thisv)
  if a == nil: bail("Array.prototype.at on non-array receiver")
  let n = arrLength(heap, a)
  var i = toIntArg(if args.len >= 1: args[0] else: vv(undefinedVal()))
  if i < 0: i = n + i
  if i < 0 or i >= n: return vv(undefinedVal())
  unboxLoaded(heap, arrGet(heap, a, i))

proc nativeArrayReverse(heap: var GcHeap, args: openArray[VmVal],
                        thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.reverse() — reverse in place, return this.
  let a = arrThis(thisv)
  if a == nil: bail("Array.prototype.reverse on non-array receiver")
  var s = arrElems(heap, a)
  var i = 0
  var j = s.len - 1
  while i < j:
    swap(s[i], s[j]); inc i; dec j
  arrReplace(heap, a, s)
  thisv

proc nativeArrayToString(heap: var GcHeap, args: openArray[VmVal],
                         thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.toString() — join with the default separator "," (the
  ## reference falls back to Object.prototype.toString only if join isn't
  ## callable, which it always is here).
  nativeArrayJoin(heap, [], thisv)

# --- Array.prototype callback methods (native → JS re-entrancy) ---------
# Each invokes a JS callback per element via invokeCallback (re-enters the
# interpreter). map/filter/reduce root their accumulator across callbacks (a
# callback can allocate + collect) via pushNativeRoot. Callbacks see element
# values fresh per iteration through arrGet (safe under a self-mutating callback,
# since the receiver array is rooted by the caller's frame).

proc isCallableVal(x: VmVal): bool {.inline.} =
  if x.kind == vkFunction: return true
  if x.kind == vkVal and isCell(x.v) and cellAsPtr(x.v) != nil:
    let t = cellHeader(x.v).typeTag
    return t == TAG_FUNCTION or t == TAG_HOSTFN
  false

template cbSetup(methodName: string) {.dirty.} =
  ## Bind `a` (the receiver array), `cb` (the callback), `thisArg`, `n` (length).
  let a = arrThis(thisv)
  if a == nil: bail("Array.prototype." & methodName & " on non-array receiver")
  if args.len == 0 or not isCallableVal(args[0]):
    bail("Array.prototype." & methodName & " callback is not a function")
  let cb = args[0]
  let thisArg = (if args.len >= 2: args[1] else: vv(undefinedVal()))
  let n = arrLength(heap, a)

proc nativeArrayForEach(heap: var GcHeap, args: openArray[VmVal],
                        thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.forEach(cb, thisArg?) — call cb for each present element;
  ## returns undefined. Skips holes.
  cbSetup("forEach")
  var i = 0
  while i < n:
    if arrHasIndex(heap, a, i):
      let v = unboxLoaded(heap, arrGet(heap, a, i))
      discard invokeCallback(heap, cb, thisArg, [v, vv(int32Val(int32(i))), thisv])
    inc i
  vv(undefinedVal())

proc nativeArraySome(heap: var GcHeap, args: openArray[VmVal],
                     thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.some(cb) — true iff cb is truthy for any present element.
  cbSetup("some")
  var i = 0
  while i < n:
    if arrHasIndex(heap, a, i):
      let v = unboxLoaded(heap, arrGet(heap, a, i))
      if vmToBool(invokeCallback(heap, cb, thisArg, [v, vv(int32Val(int32(i))), thisv])):
        return vv(boolVal(true))
    inc i
  vv(boolVal(false))

proc nativeArrayEvery(heap: var GcHeap, args: openArray[VmVal],
                      thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.every(cb) — true iff cb is truthy for every present element.
  cbSetup("every")
  var i = 0
  while i < n:
    if arrHasIndex(heap, a, i):
      let v = unboxLoaded(heap, arrGet(heap, a, i))
      if not vmToBool(invokeCallback(heap, cb, thisArg, [v, vv(int32Val(int32(i))), thisv])):
        return vv(boolVal(false))
    inc i
  vv(boolVal(true))

proc nativeArrayFind(heap: var GcHeap, args: openArray[VmVal],
                     thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.find(cb) — first element (via Get, holes→undefined) where
  ## cb is truthy, else undefined.
  cbSetup("find")
  var i = 0
  while i < n:
    let v = unboxLoaded(heap, arrGet(heap, a, i))
    if vmToBool(invokeCallback(heap, cb, thisArg, [v, vv(int32Val(int32(i))), thisv])):
      return v
    inc i
  vv(undefinedVal())

proc nativeArrayFindIndex(heap: var GcHeap, args: openArray[VmVal],
                          thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.findIndex(cb) — first index where cb is truthy, else -1.
  cbSetup("findIndex")
  var i = 0
  while i < n:
    let v = unboxLoaded(heap, arrGet(heap, a, i))
    if vmToBool(invokeCallback(heap, cb, thisArg, [v, vv(int32Val(int32(i))), thisv])):
      return vv(int32Val(int32(i)))
    inc i
  vv(int32Val(-1'i32))

proc nativeArrayMap(heap: var GcHeap, args: openArray[VmVal],
                    thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.map(cb) — new Array of cb results (holes preserved). The
  ## result is rooted across callbacks (each callback can allocate + collect).
  cbSetup("map")
  let resultCell = allocArray(heap, [])
  let resultVal = cellValue(resultCell)
  pushNativeRoot(resultVal)
  var i = 0
  while i < n:
    if arrHasIndex(heap, a, i):
      let v = unboxLoaded(heap, arrGet(heap, a, i))
      let r = invokeCallback(heap, cb, thisArg, [v, vv(int32Val(int32(i))), thisv])
      arrSet(heap, resultCell, i, boxForStore(heap, r))   # write into the rooted result
    inc i
  var built = arrElems(heap, resultCell)      # pad to length n (trailing holes)
  while built.len < n: built.add(deletedVal())
  arrReplace(heap, resultCell, built)
  popNativeRoot()
  vv(resultVal)

proc nativeArrayFilter(heap: var GcHeap, args: openArray[VmVal],
                       thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.filter(cb) — new (compacted) Array of elements where cb is
  ## truthy. Rooted across callbacks.
  cbSetup("filter")
  let resultCell = allocArray(heap, [])
  let resultVal = cellValue(resultCell)
  pushNativeRoot(resultVal)
  var i = 0
  var outIdx = 0
  while i < n:
    if arrHasIndex(heap, a, i):
      let v = unboxLoaded(heap, arrGet(heap, a, i))
      if vmToBool(invokeCallback(heap, cb, thisArg, [v, vv(int32Val(int32(i))), thisv])):
        arrSet(heap, resultCell, outIdx, boxForStore(heap, v))
        inc outIdx
    inc i
  popNativeRoot()
  vv(resultVal)

proc nativeArrayReduce(heap: var GcHeap, args: openArray[VmVal],
                       thisv: VmVal): VmVal {.nimcall.} =
  ## Array.prototype.reduce(cb, initialValue?) — cb(acc, cur, i, arr) left-to-
  ## right. No initialValue + empty → TypeError (BAIL). The accumulator is rooted
  ## across callbacks.
  let a = arrThis(thisv)
  if a == nil: bail("Array.prototype.reduce on non-array receiver")
  if args.len == 0 or not isCallableVal(args[0]):
    bail("Array.prototype.reduce callback is not a function")
  let cb = args[0]
  let n = arrLength(heap, a)
  var i = 0
  var acc: VmVal
  if args.len >= 2:
    acc = args[1]
  else:
    while i < n and not arrHasIndex(heap, a, i): inc i
    if i >= n: bail("Reduce of empty array with no initial value")
    acc = unboxLoaded(heap, arrGet(heap, a, i)); inc i
  pushNativeRoot(boxForStore(heap, acc))
  while i < n:
    if arrHasIndex(heap, a, i):
      let v = unboxLoaded(heap, arrGet(heap, a, i))
      let r = invokeCallback(heap, cb, vv(undefinedVal()),
                             [acc, v, vv(int32Val(int32(i))), thisv])
      popNativeRoot()
      acc = r
      pushNativeRoot(boxForStore(heap, acc))
    inc i
  popNativeRoot()
  acc

proc nativeArrayCtor(heap: var GcHeap, args: openArray[VmVal],
                     thisv: VmVal): VmVal {.nimcall.} =
  ## `Array(...)` / `new Array(...)` — the constructor form (length-arg vs
  ## element-list). Deferred → BAIL. Installed so `typeof Array` is "function"
  ## and `Array.isArray` / `Array.prototype` resolve off the property bag.
  bail("Array constructor not implemented")

# --- String.prototype methods (src/context.zc host_string_* ; g12) ------
# zjs strings are UTF-8 BYTE sequences: length/charAt/charCodeAt/slice index by
# byte, which nim's `string` mirrors — so these are plain byte ops, byte-
# identical to the reference. Each native gets the string primitive as `thisv`.

proc strThis(heap: GcHeap, thisv: VmVal): string =
  ## The receiver coerced to its string value (a vkString or a StringCell).
  var s: string
  if vmStringVal(heap, thisv, s): return s
  bail("String.prototype method on non-string receiver")

proc nativeStringCharAt(heap: var GcHeap, args: openArray[VmVal],
                        thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.charAt(i) — the 1-byte substring at i, or "".
  let s = strThis(heap, thisv)
  let i = toIntArg(if args.len >= 1: args[0] else: vv(int32Val(0)))
  if i >= 0 and i < s.len: vs($s[i]) else: vs("")

proc nativeStringCharCodeAt(heap: var GcHeap, args: openArray[VmVal],
                            thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.charCodeAt(i) — the byte value (0..255) at i, or NaN.
  let s = strThis(heap, thisv)
  let i = toIntArg(if args.len >= 1: args[0] else: vv(int32Val(0)))
  if i >= 0 and i < s.len: vv(int32Val(int32(ord(s[i])))) else: vv(doubleVal(NaN))

proc nativeStringAt(heap: var GcHeap, args: openArray[VmVal],
                    thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.at(i) — byte substring at i (negative from end), else undefined.
  let s = strThis(heap, thisv)
  var i = toIntArg(if args.len >= 1: args[0] else: vv(int32Val(0)))
  if i < 0: i = s.len + i
  if i >= 0 and i < s.len: vs($s[i]) else: vv(undefinedVal())

proc nativeStringIndexOf(heap: var GcHeap, args: openArray[VmVal],
                         thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.indexOf(search, from?) — byte substring index, or -1.
  let s = strThis(heap, thisv)
  let needle = vmToString(if args.len >= 1: args[0] else: vv(undefinedVal()))
  var start = 0
  if args.len >= 2: start = max(0, toIntArg(args[1]))
  if start > s.len: return vv(int32Val(if needle.len == 0: int32(s.len) else: -1'i32))
  vv(int32Val(int32(s.find(needle, start))))

proc nativeStringLastIndexOf(heap: var GcHeap, args: openArray[VmVal],
                             thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.lastIndexOf(search) — last byte substring index, or -1.
  let s = strThis(heap, thisv)
  let needle = vmToString(if args.len >= 1: args[0] else: vv(undefinedVal()))
  vv(int32Val(int32(s.rfind(needle))))

proc nativeStringIncludes(heap: var GcHeap, args: openArray[VmVal],
                          thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.includes(search, from?) — substring presence.
  let s = strThis(heap, thisv)
  let needle = vmToString(if args.len >= 1: args[0] else: vv(undefinedVal()))
  var start = 0
  if args.len >= 2: start = max(0, toIntArg(args[1]))
  vv(boolVal(s.find(needle, start) >= 0))

proc nativeStringStartsWith(heap: var GcHeap, args: openArray[VmVal],
                            thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.startsWith(search, pos?).
  let s = strThis(heap, thisv)
  let needle = vmToString(if args.len >= 1: args[0] else: vv(undefinedVal()))
  var pos = 0
  if args.len >= 2: pos = max(0, toIntArg(args[1]))
  if pos + needle.len > s.len: return vv(boolVal(false))
  vv(boolVal(s.continuesWith(needle, pos)))

proc nativeStringEndsWith(heap: var GcHeap, args: openArray[VmVal],
                          thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.endsWith(search, endPos?).
  let s = strThis(heap, thisv)
  let needle = vmToString(if args.len >= 1: args[0] else: vv(undefinedVal()))
  var endPos = s.len
  if args.len >= 2: endPos = min(max(0, toIntArg(args[1])), s.len)
  if needle.len > endPos: return vv(boolVal(false))
  vv(boolVal(s.continuesWith(needle, endPos - needle.len)))

proc nativeStringSlice(heap: var GcHeap, args: openArray[VmVal],
                       thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.slice(start?, end?) — byte range, negatives from the end.
  let s = strThis(heap, thisv)
  let n = s.len
  var start = 0
  if args.len >= 1 and not (args[0].kind == vkVal and isUndefined(args[0].v)):
    start = relStart(args[0], n)
  var stop = n
  if args.len >= 2 and not (args[1].kind == vkVal and isUndefined(args[1].v)):
    stop = relStart(args[1], n)
  if start >= stop: return vs("")
  vs(s[start ..< stop])

proc nativeStringSubstring(heap: var GcHeap, args: openArray[VmVal],
                           thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.substring(start, end?) — negatives clamp to 0; swap if start>end.
  let s = strThis(heap, thisv)
  let n = s.len
  var start = clamp(toIntArg(if args.len >= 1: args[0] else: vv(int32Val(0))), 0, n)
  var stop = n
  if args.len >= 2 and not (args[1].kind == vkVal and isUndefined(args[1].v)):
    stop = clamp(toIntArg(args[1]), 0, n)
  if start > stop: swap(start, stop)
  vs(s[start ..< stop])

proc nativeStringToUpperCase(heap: var GcHeap, args: openArray[VmVal],
                             thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.toUpperCase() — ASCII byte-wise upper (matches the
  ## reference's byte model for ASCII; non-ASCII bytes pass through).
  vs(strThis(heap, thisv).toUpperAscii())

proc nativeStringToLowerCase(heap: var GcHeap, args: openArray[VmVal],
                             thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.toLowerCase() — ASCII byte-wise lower.
  vs(strThis(heap, thisv).toLowerAscii())

proc nativeStringTrim(heap: var GcHeap, args: openArray[VmVal],
                      thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.trim() — strip leading/trailing ASCII whitespace.
  vs(strThis(heap, thisv).strip())

proc nativeStringRepeat(heap: var GcHeap, args: openArray[VmVal],
                        thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.repeat(count) — count copies. Negative → RangeError (BAIL).
  let s = strThis(heap, thisv)
  let count = toIntArg(if args.len >= 1: args[0] else: vv(int32Val(0)))
  if count < 0: bail("String.prototype.repeat count is negative (RangeError)")
  var res = newStringOfCap(s.len * count)
  for _ in 0 ..< count: res.add(s)
  vs(res)

proc nativeStringConcat(heap: var GcHeap, args: openArray[VmVal],
                        thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.concat(...args) — this ++ each ToString(arg).
  var res = strThis(heap, thisv)
  for arg in args: res.add(vmToString(arg))
  vs(res)

proc nativeStringSplit(heap: var GcHeap, args: openArray[VmVal],
                       thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.split(sep?) — no sep → [whole]; sep "" → per-byte; else
  ## byte split. (limit + regexp separators deferred.)
  let s = strThis(heap, thisv)
  if args.len == 0 or (args[0].kind == vkVal and isUndefined(args[0].v)):
    return vv(cellValue(allocArray(heap, [cellValue(allocStringCell(heap, s))])))
  let sep = vmToString(args[0])
  var parts: seq[ZjsValue] = @[]
  if sep.len == 0:
    for c in s: parts.add(cellValue(allocStringCell(heap, $c)))
  else:
    for part in s.split(sep):
      parts.add(cellValue(allocStringCell(heap, part)))
  vv(cellValue(allocArray(heap, parts)))

proc nativeStringToString(heap: var GcHeap, args: openArray[VmVal],
                          thisv: VmVal): VmVal {.nimcall.} =
  ## String.prototype.toString() / valueOf() — the primitive string value.
  vs(strThis(heap, thisv))

proc nativeStringCtor(heap: var GcHeap, args: openArray[VmVal],
                      thisv: VmVal): VmVal {.nimcall.} =
  ## `String(v)` — ToString(v); `new String(v)` (wrapper) deferred. The plain
  ## call form is common enough to implement (no wrapper identity needed).
  if args.len == 0: return vs("")
  vs(vmToString(args[0]))

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
  # Object.prototype value, captured in installObject so installArray can chain
  # Array.prototype → Object.prototype (undefined until installObject runs).
  var objectProtoVal = undefinedVal()
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
      objectProtoVal = protoVal                          # for Array.prototype chaining
    globals[builtinSlot("Object")] = vv(cellValue(objectFn))
  # Array (g9) — native constructor (typeof → "function"); its prototype carries
  # the method natives, dispatched via the VM's LoadProp array branch. Chain =
  # Array.prototype → Object.prototype (so `[].hasOwnProperty` resolves too).
  # Rooted via globals → Array bag → `.prototype` → the method cells.
  block installArray:
    let arrayProto = allocObject(heap)
    if isCell(objectProtoVal) and cellAsPtr(objectProtoVal) != nil:
      objSetProto(arrayProto, objectProtoVal)
    template setA(nm: string, fn: NativeFn, arity: int) =
      objSet(heap, arrayProto, nm,
             cellValue(allocHostFunction(heap, cast[pointer](fn), nm, arity)))
    setA("push",        nativeArrayPush,        1)
    setA("pop",         nativeArrayPop,         0)
    setA("shift",       nativeArrayShift,       0)
    setA("unshift",     nativeArrayUnshift,     1)
    setA("indexOf",     nativeArrayIndexOf,     1)
    setA("lastIndexOf", nativeArrayLastIndexOf, 1)
    setA("includes",    nativeArrayIncludes,    1)
    setA("join",        nativeArrayJoin,        1)
    setA("slice",       nativeArraySlice,       2)
    setA("concat",      nativeArrayConcat,      1)
    setA("at",          nativeArrayAt,          1)
    setA("reverse",     nativeArrayReverse,     0)
    setA("toString",    nativeArrayToString,    0)
    setA("forEach",     nativeArrayForEach,     1)
    setA("some",        nativeArraySome,        1)
    setA("every",       nativeArrayEvery,       1)
    setA("find",        nativeArrayFind,        1)
    setA("findIndex",   nativeArrayFindIndex,   1)
    setA("map",         nativeArrayMap,         1)
    setA("filter",      nativeArrayFilter,      1)
    setA("reduce",      nativeArrayReduce,      1)
    setArrayProto(cellValue(arrayProto))
    let arrayFn = allocHostFunction(heap, cast[pointer](nativeArrayCtor), "Array", 1)
    let arrayBag = cast[ptr ObjectCell](arrayFn)
    objSet(heap, arrayBag, "isArray",
           cellValue(allocHostFunction(heap, cast[pointer](nativeArrayIsArray), "isArray", 1)))
    objSet(heap, arrayBag, "prototype", cellValue(arrayProto))
    globals[builtinSlot("Array")] = vv(cellValue(arrayFn))
  # String (g12) — native constructor (typeof → "function"; String(v) coerces).
  # Its prototype carries the byte-based method natives, dispatched via the VM's
  # LoadProp vkString branch. Chain = String.prototype → Object.prototype.
  block installString:
    let stringProto = allocObject(heap)
    if isCell(objectProtoVal) and cellAsPtr(objectProtoVal) != nil:
      objSetProto(stringProto, objectProtoVal)
    template setS(nm: string, fn: NativeFn, arity: int) =
      objSet(heap, stringProto, nm,
             cellValue(allocHostFunction(heap, cast[pointer](fn), nm, arity)))
    setS("charAt",      nativeStringCharAt,      1)
    setS("charCodeAt",  nativeStringCharCodeAt,  1)
    setS("at",          nativeStringAt,          1)
    setS("indexOf",     nativeStringIndexOf,     1)
    setS("lastIndexOf", nativeStringLastIndexOf, 1)
    setS("includes",    nativeStringIncludes,    1)
    setS("startsWith",  nativeStringStartsWith,  1)
    setS("endsWith",    nativeStringEndsWith,    1)
    setS("slice",       nativeStringSlice,       2)
    setS("substring",   nativeStringSubstring,   2)
    setS("toUpperCase", nativeStringToUpperCase, 0)
    setS("toLowerCase", nativeStringToLowerCase, 0)
    setS("trim",        nativeStringTrim,        0)
    setS("repeat",      nativeStringRepeat,      1)
    setS("concat",      nativeStringConcat,      1)
    setS("split",       nativeStringSplit,       2)
    setS("toString",    nativeStringToString,    0)
    setS("valueOf",     nativeStringToString,    0)
    setStringProto(cellValue(stringProto))
    let stringFn = allocHostFunction(heap, cast[pointer](nativeStringCtor), "String", 1)
    let stringBag = cast[ptr ObjectCell](stringFn)
    objSet(heap, stringBag, "prototype", cellValue(stringProto))
    globals[builtinSlot("String")] = vv(cellValue(stringFn))
