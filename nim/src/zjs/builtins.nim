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
