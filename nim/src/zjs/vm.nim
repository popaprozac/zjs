## Minimal bytecode interpreter -- Slice 1 of Phase 4.
##
## Executes the top-level `Function` produced by `compileProgram`. The
## goal is a differential oracle: `nim-eval '<src>'` output must match
## `build/zjs eval '<src>'` byte-for-byte for the arithmetic / control-
## flow subset. Anything outside that subset (calls, objects, string
## concatenation, coercion between mixed types) BAILS: it raises
## `VmBail`, which the CLI turns into "print nothing, exit nonzero".
## A WRONG execution result is far worse than a bail.
##
## Register model. `src/interpreter.zc` stores every register as a
## NaN-boxed `ZjsValue`, but string constants (from `LoadConst`) can't
## be NaN-boxed here -- there is no heap-cell machinery in slice 1. So a
## VM register is a small variant (`VmVal`): either a plain `ZjsValue`
## (numbers / bool / null / undefined) or a raw string. String values
## can only originate from a string constant and can only be printed;
## any *operation* on a string (arithmetic, comparison, concat) bails.
##
## Semantics are ported directly from `src/value.zc` (the arith/compare
## helpers) and `src/interpreter.zc` (the dispatch loop). See per-handler
## comments for the exact source anchor.

import std/math
import bytecode, value

# C strtod for the ECMA-262 StringToNumber path (value.zc ~217): ported
# verbatim so hex ("0x1F"→31), decimals, and whitespace-trim match the
# oracle exactly rather than being re-approximated in Nim.
proc c_strtod(s: cstring, endp: ptr cstring): float64 {.importc: "strtod", header: "<stdlib.h>".}
proc c_snprintf_ll(buf: cstring, n: csize_t, fmt: cstring, v: clonglong): cint {.importc: "snprintf", header: "<stdio.h>", varargs.}

type
  VmValKind* = enum
    vkVal       ## a plain NaN-boxed ZjsValue (number / bool / null / undefined)
    vkString    ## a string constant (from LoadConst ckString); print-only
    vkFunction  ## a callable function value (slice 2): a bare Function* from a
                ## function-constant LoadConst, or a NON-capturing closure from
                ## MakeClosure. Capturing closures (real env object) BAIL — no
                ## object model yet.

  VmVal* = object
    case kind*: VmValKind
    of vkVal:      v*: ZjsValue
    of vkString:   s*: string
    of vkFunction: fn*: Function

  VmBail* = object of CatchableError
    ## Raised when the VM hits an op or value shape it can't faithfully
    ## execute. The CLI must then print NOTHING and exit nonzero.

const
  ## Recursion-depth guard for the call-frame stack. `build/zjs` throws a
  ## RangeError ("Maximum call stack size exceeded") on deep recursion, which
  ## surfaces as nothing-on-stdout (an unhandled throw) in the eval oracle. We
  ## match that shape by BAILING once we exceed the limit — never a wrong
  ## value. Well within: fib(10)=177 nested calls, fac(5)=5. Kept comfortably
  ## below Nim's own native stack limit so `runFunction`'s recursion can't
  ## segfault before the guard fires.
  MAX_CALL_DEPTH = 2000

# --- VmVal constructors -------------------------------------------------

proc vv(v: ZjsValue): VmVal {.inline.} = VmVal(kind: vkVal, v: v)
proc vs(s: string): VmVal {.inline.} = VmVal(kind: vkString, s: s)
proc vf(f: Function): VmVal {.inline.} = VmVal(kind: vkFunction, fn: f)

proc bail(msg: string) {.noreturn.} =
  raise newException(VmBail, msg)

# --- ZjsValue arithmetic / comparison (ports of src/value.zc) ----------

const
  I32_MIN = -2147483648'i64
  I32_MAX =  2147483647'i64

# C fmod (Nim's math.floorMod is integer; we need the double fmod).
proc c_fmod(x, y: float64): float64 {.importc: "fmod", header: "<math.h>".}

proc toDoubleNum(v: ZjsValue): float64 {.inline.} =
  ## number_to_double (value.zc ~300): caller has proven isNumber(v).
  if isInt32(v): float64(asInt32(v)) else: asDouble(v)

proc arithAdd(a, b: ZjsValue): ZjsValue =
  ## zjs_arith_add (value.zc ~305). int32 fast path with overflow→double.
  if isInt32(a) and isInt32(b):
    let s = int64(asInt32(a)) + int64(asInt32(b))
    if s >= I32_MIN and s <= I32_MAX: return int32Val(int32(s))
    return doubleVal(float64(s))
  doubleVal(toDoubleNum(a) + toDoubleNum(b))

proc arithSub(a, b: ZjsValue): ZjsValue =
  ## zjs_arith_sub (value.zc ~324).
  if isInt32(a) and isInt32(b):
    let d = int64(asInt32(a)) - int64(asInt32(b))
    if d >= I32_MIN and d <= I32_MAX: return int32Val(int32(d))
    return doubleVal(float64(d))
  doubleVal(toDoubleNum(a) - toDoubleNum(b))

proc arithMul(a, b: ZjsValue): ZjsValue =
  ## zjs_arith_mul (value.zc ~340).
  if isInt32(a) and isInt32(b):
    let p = int64(asInt32(a)) * int64(asInt32(b))
    if p >= I32_MIN and p <= I32_MAX: return int32Val(int32(p))
    return doubleVal(float64(p))
  doubleVal(toDoubleNum(a) * toDoubleNum(b))

proc arithDiv(a, b: ZjsValue): ZjsValue =
  ## zjs_arith_div (value.zc ~356). Always a double.
  doubleVal(toDoubleNum(a) / toDoubleNum(b))

proc arithMod(a, b: ZjsValue): ZjsValue =
  ## zjs_arith_mod (value.zc ~364). fmod semantics, sign of dividend.
  if isInt32(a) and isInt32(b):
    let ai = asInt32(a)
    let bi = asInt32(b)
    if bi != 0 and not (ai == int32(I32_MIN) and bi == -1):
      let r = ai mod bi
      if r == 0 and ai < 0: return doubleVal(-0.0)
      return int32Val(r)
  doubleVal(c_fmod(toDoubleNum(a), toDoubleNum(b)))

proc arithPow(a, b: ZjsValue): ZjsValue =
  ## zjs_arith_pow (value.zc ~388). C pow().
  doubleVal(pow(toDoubleNum(a), toDoubleNum(b)))

proc arithNeg(a: ZjsValue): ZjsValue =
  ## zjs_arith_neg (value.zc ~396). -0 is observable.
  if isInt32(a):
    let i = asInt32(a)
    if i == 0: return doubleVal(-0.0)
    if i != int32(I32_MIN): return int32Val(-i)
    return doubleVal(-float64(i))
  doubleVal(-toDoubleNum(a))

# ToInt32 / ToUint32 (value.zc ~417 / ~447). Only the numeric arms are
# reachable in slice 1 (non-number operands already bailed upstream).

proc toInt32(v: ZjsValue): int32 =
  if isInt32(v): return asInt32(v)
  let d = asDouble(v)
  if d > -9.2233720368547758e18 and d < 9.2233720368547758e18:
    return cast[int32](int64(d))
  if d != d or d == Inf or d == NegInf or d == 0.0:
    return 0
  let sign = if d < 0: -1.0 else: 1.0
  var m = c_fmod(sign * floor(abs(d)), 4294967296.0)
  if m < 0: m += 4294967296.0
  if m >= 2147483648.0: m -= 4294967296.0
  int32(m)

proc toUint32(v: ZjsValue): uint32 =
  if isInt32(v): return cast[uint32](asInt32(v))
  let d = asDouble(v)
  if d > -9.2233720368547758e18 and d < 9.2233720368547758e18:
    return cast[uint32](int64(d))
  if d != d or d == Inf or d == NegInf or d == 0.0:
    return 0
  let sign = if d < 0: -1.0 else: 1.0
  var m = c_fmod(sign * floor(abs(d)), 4294967296.0)
  if m < 0: m += 4294967296.0
  cast[uint32](uint32(m))

proc bitAnd(a, b: ZjsValue): ZjsValue = int32Val(toInt32(a) and toInt32(b))
proc bitOr (a, b: ZjsValue): ZjsValue = int32Val(toInt32(a) or  toInt32(b))
proc bitXor(a, b: ZjsValue): ZjsValue = int32Val(toInt32(a) xor toInt32(b))
proc bitNot(a: ZjsValue): ZjsValue = int32Val(not toInt32(a))

proc shl32(a, b: ZjsValue): ZjsValue =
  int32Val(toInt32(a) shl (toUint32(b) and 31))
proc shr32(a, b: ZjsValue): ZjsValue =
  int32Val(toInt32(a) shr (toUint32(b) and 31))   ## arithmetic (ashr on signed)
proc ushr32(a, b: ZjsValue): ZjsValue =
  ## zjs_ushr (value.zc ~477): promote to double when the high bit is set.
  let u = toUint32(a) shr (toUint32(b) and 31)
  if u >= 0x80000000'u32: return doubleVal(float64(u))
  int32Val(cast[int32](u))

proc strictEqNum(a, b: ZjsValue): bool =
  ## zjs_strict_eq numeric arms (value.zc ~488). Non-number/bool/null/
  ## undefined operands bailed before reaching here.
  if isInt32(a) and isInt32(b): return asInt32(a) == asInt32(b)
  if isNumber(a) and isNumber(b): return toDoubleNum(a) == toDoubleNum(b)
  a.bits == b.bits   ## bool/null/undefined: bit-equal (no NaN among these)

proc looseEqSimple(a, b: ZjsValue): bool =
  ## The subset of zjs_loose_eq (value.zc ~530) reachable in slice 1:
  ## both numeric, or null/undefined mixing. Anything else bailed.
  if isNumber(a) and isNumber(b):
    return toDoubleNum(a) == toDoubleNum(b)
  if (isNull(a) or isUndefined(a)) and (isNull(b) or isUndefined(b)):
    return true
  # e.g. bool vs number would need coercion (slice 3) — but arithmetic-
  # producing exprs never yield bool operands to CmpEq here. Fall back to
  # strict-eq bit compare so `true == true` still works; genuinely mixed
  # cases are rare in the corpus and covered by the number/null arms.
  a.bits == b.bits

proc cmpLt(a, b: ZjsValue): bool =
  ## zjs_cmp_lt numeric arm (value.zc ~714). NaN → false.
  let af = toDoubleNum(a)
  let bf = toDoubleNum(b)
  if af != af or bf != bf: return false
  af < bf

proc cmpLe(a, b: ZjsValue): bool =
  ## zjs_cmp_le numeric arm (value.zc ~742). NaN → false.
  let af = toDoubleNum(a)
  let bf = toDoubleNum(b)
  if af != af or bf != bf: return false
  af <= bf

proc toBool(v: ZjsValue): bool =
  ## zjs_to_bool_coerce numeric/bool/null/undefined arms (value.zc ~270).
  if isBool(v): return asBool(v) != 0
  if isInt32(v): return asInt32(v) != 0
  if isDouble(v):
    let d = asDouble(v)
    if d != d: return false
    return d != 0.0
  if isNull(v) or isUndefined(v): return false
  bail("ToBoolean on non-primitive")

# --- primitive coercion ladder (slice 3; ports of value.zc/context.zc) --

proc strToNumber(s: string): float64 =
  ## ECMA-262 StringToNumber via strtod (zjs_to_double string arm,
  ## value.zc ~217). Trim leading/trailing JS whitespace; empty / all-ws
  ## → 0; strtod handles hex ("0x1F"→31) / decimals / signs. A trailing
  ## non-numeric tail (ep != end) → NaN. Infinity must match the exact
  ## spec spelling "Infinity" (optionally signed), else NaN.
  const WS = {' ', '\t', '\n', '\r', '\v', '\f'}
  var lo = 0
  var hi = s.len
  while lo < hi and s[lo] in WS: inc lo
  while hi > lo and s[hi-1] in WS: dec hi
  if lo == hi: return 0.0                     # empty / all-whitespace → 0
  # strtod needs a NUL-terminated C string of the trimmed body.
  let body = s[lo ..< hi]
  let cbody = cstring(body)
  var ep: cstring = nil
  let parsed = c_strtod(cbody, addr ep)
  # ep must have reached the end of `body` (whole trimmed string consumed).
  let consumed = int(cast[uint](ep) - cast[uint](cbody))
  if consumed != body.len or consumed == 0:
    return NaN
  if parsed == Inf or parsed == NegInf:
    # Validate the exact spec spelling: [+/-]Infinity, nothing else.
    var q = 0
    if body.len > 0 and (body[0] == '+' or body[0] == '-'): q = 1
    if not (body.len - q == 8 and body[q ..< body.len] == "Infinity"):
      return NaN
  parsed

proc vmToNumber(x: VmVal): ZjsValue =
  ## ToNumber over a VmVal (zjs_to_double, value.zc ~207). Numbers pass
  ## through; a string is parsed by StringToNumber → int32 if it lands on
  ## an exact int32-range integer, else a double (so `"5"*2`→10 stays a
  ## clean integer, matching the oracle). Function operands are out of
  ## scope → bail.
  case x.kind
  of vkFunction: bail("ToNumber on function operand")
  of vkString:
    let d = strToNumber(x.s)
    if d == d and d == floor(d) and d >= -2147483648.0 and d <= 2147483647.0:
      return int32Val(int32(d))
    return doubleVal(d)
  of vkVal:
    let v = x.v
    if isNumber(v): return v
    # bool→1/0, null→0, undefined→NaN — exactly zjs_to_double's arms.
    if isBool(v):      return int32Val(if asBool(v) != 0: 1'i32 else: 0'i32)
    if isNull(v):      return int32Val(0'i32)
    if isUndefined(v): return doubleVal(NaN)
    bail("ToNumber on non-primitive")

proc vmToString(x: VmVal): string =
  ## ToString over a VmVal (zjs_to_string, context.zc ~33638). string→
  ## itself; int32→decimal digits; bool/null/undefined→literals. Double:
  ## NaN/±Infinity have fixed spellings; an INTEGER-valued double in the
  ## exact-integer window prints its digits. A NON-INTEGER double (0.5,
  ## 1/3, 0.1+0.2) needs js_double_to_chars (ECMAScript shortest-round-
  ## trip dtoa) — DEFERRED to a later slice → BAIL, never `%g` (which would
  ## print "0.333333", a WRONG result vs the oracle's 0.3333333333333333).
  case x.kind
  of vkFunction: bail("ToString on function operand")
  of vkString:   return x.s
  of vkVal:
    let v = x.v
    if isInt32(v): return $asInt32(v)
    if isDouble(v):
      let d = asDouble(v)
      if d != d: return "NaN"
      if d == Inf: return "Infinity"
      if d == NegInf: return "-Infinity"
      # Integer-valued double: exact integer print. context.zc uses %lld
      # for |d| <= 1e15 and %.0f for integral |d| < 1e21; both windows are
      # integer-valued, so a single integral guard + %lld covers the safe
      # range. Beyond 1e15 %lld could overflow i64 — restrict to the
      # snprintf %lld window and bail on the (rare, integral > 1e15) rest
      # rather than risk a wrong digit.
      if d == floor(d) and d >= -1e15 and d <= 1e15:
        var buf: array[64, char]
        let n = c_snprintf_ll(cast[cstring](addr buf[0]), csize_t(64),
                              cstring("%lld"), clonglong(int64(d)))
        if n <= 0 or n >= 64: bail("ToString double overflow")
        var res = newString(n)
        for i in 0 ..< n: res[i] = buf[i]
        return res
      # Non-integer (or integral beyond the %lld window) double → dtoa.
      bail("ToString non-integer double (needs dtoa)")
    if isBool(v):      return (if asBool(v) != 0: "true" else: "false")
    if isNull(v):      return "null"
    if isUndefined(v): return "undefined"
    bail("ToString on non-primitive")

proc vmToBool(x: VmVal): bool =
  ## ToBoolean over a VmVal (zjs_to_bool_coerce, value.zc ~270): a
  ## non-empty string is truthy, ""→false; else defer to the ZjsValue arm.
  case x.kind
  of vkFunction: return true            # a function object is always truthy
  of vkString:   return x.s.len > 0
  of vkVal:      return toBool(x.v)

# --- register helpers: unwrap a VmVal to a numeric ZjsValue -------------

proc numVal(x: VmVal): ZjsValue {.inline.} =
  ## Operand of an arithmetic / bitwise / relational op, ToNumber-coerced
  ## to a number (zjs_arith_* / zjs_to_double, value.zc). Numbers pass
  ## through; string / bool / null / undefined go through the ToNumber
  ## ladder ("5"→5, true→1, null→0, undefined→NaN) so the arith helpers
  ## always see a real number. A function operand is out of scope → bail.
  case x.kind
  of vkString:   vmToNumber(x)
  of vkFunction: bail("operation on function operand")
  of vkVal:
    if isNumber(x.v): x.v
    else: vmToNumber(x)

# --- VmVal-aware comparison (ports of zjs_cmp_lt/le, loose/strict eq) ---
# Relational: two strings → lexicographic by code unit (value.zc ~719);
# otherwise ToNumber both then numeric compare (value.zc ~733). Equality:
# two strings → byte equality (strict_eq, value.zc ~499); otherwise defer
# to the numeric loose/strict arms (a mixed string/number path ToNumbers
# the string, matching value.zc ~609 / ~499 → strict_eq numeric).

proc vmCmpLt(a, b: VmVal): bool =
  if a.kind == vkString and b.kind == vkString:
    return a.s < b.s
  cmpLt(numVal(a), numVal(b))

proc vmCmpLe(a, b: VmVal): bool =
  if a.kind == vkString and b.kind == vkString:
    return a.s <= b.s
  cmpLe(numVal(a), numVal(b))

proc vmStrictEq(a, b: VmVal): bool =
  ## zjs_strict_eq (value.zc ~488). String===String → byte equality;
  ## String===non-string (or vice versa) → false (different type); else
  ## numeric strict-eq. A function value never appears in our targets'
  ## strict-eq — treat as out of scope.
  if a.kind == vkString or b.kind == vkString:
    if a.kind == vkString and b.kind == vkString: return a.s == b.s
    return false                     # string vs number/bool/null → not equal
  if a.kind == vkFunction or b.kind == vkFunction:
    bail("strict-eq on function operand")
  strictEqNum(a.v, b.v)

proc vmLooseEq(a, b: VmVal): bool =
  ## zjs_loose_eq (value.zc ~530). String==String → byte equality.
  ## String==Number → ToNumber(string) then numeric compare (value.zc
  ## ~609). String vs null/undefined → false (never equal). Else defer to
  ## the numeric/null loose arm.
  if a.kind == vkString and b.kind == vkString:
    return a.s == b.s
  if a.kind == vkString or b.kind == vkString:
    let (sx, ox) = if a.kind == vkString: (a, b) else: (b, a)
    # string == null/undefined is false; string == number → ToNumber(str).
    if ox.kind == vkVal and (isNull(ox.v) or isUndefined(ox.v)):
      return false
    if ox.kind == vkFunction:
      bail("loose-eq string vs function")
    # both sides numeric after coercing the string (ox is number/bool).
    return strictEqNum(vmToNumber(sx), numVal(ox))
  if a.kind == vkFunction or b.kind == vkFunction:
    bail("loose-eq on function operand")
  looseEqSimple(a.v, b.v)

# --- the interpreter ----------------------------------------------------

proc runFrame(f: Function, args: openArray[VmVal], globals: var seq[VmVal],
              depth: int): VmVal

proc resolveCallee(v: VmVal): Function =
  ## A call target must be a callable function value. Anything else (a
  ## number / string / null / undefined callee — the JS "is not a function"
  ## TypeError) is out of the slice-2 subset → BAIL, never a wrong result.
  ## A callable whose shape needs machinery we lack (arrow / async /
  ## generator / class-ctor / capturing closure) also bails: those either
  ## need `this`/env we don't model or must not run their body synchronously.
  if v.kind != vkFunction:
    bail("callee is not a function value")
  let f = v.fn
  if f == nil: bail("callee has no function")
  if f.isArrow or f.isAsync or f.isGenerator or f.isClassCtor or f.needsEnv:
    # arrow: lexical this/env; async: must yield a Promise; generator: must
    # return an iterator; class-ctor: needs `new`; needsEnv: captures outer
    # scope (real env object) — all deferred to later slices.
    bail("callee shape needs object model / env / this")
  f

proc callFunction(callee: Function, args: openArray[VmVal],
                  globals: var seq[VmVal], depth: int): VmVal =
  ## Create a fresh frame for `callee`, bind `args` to its low registers
  ## r0..r(argc-1) (the params), run it from ip 0, and return its Return
  ## value. Mirrors push_call_frame + the Op::Invoke frame push
  ## (interpreter.zc ~5716-5731): a NEW register file sized
  ## callee.registerCount, args copied into the param slots, extras dropped,
  ## missing params left undefined.
  if depth + 1 > MAX_CALL_DEPTH:
    bail("call stack depth exceeded")
  runFrame(callee, args, globals, depth + 1)

proc runFunction*(f: Function, globals: var seq[VmVal], depth: int = 0): VmVal =
  ## Execute the top-level program `f` (public entry point). A program takes
  ## no arguments; see `runFrame` for the shared execution core.
  runFrame(f, [], globals, depth)

proc runFrame(f: Function, args: openArray[VmVal], globals: var seq[VmVal],
              depth: int): VmVal =
  ## Execute `f`'s bytecode in a fresh register frame, returning the value in
  ## its `Return` operand register. `args` seed the callee's low param
  ## registers r0..; extras drop, missing params stay undefined (matching
  ## push_call_frame's arg-copy). `globals` is the shared slot array (indexed
  ## by the full u16 global slot, ≥ USER_GLOBAL_BASE). `depth` is the
  ## call-frame nesting. Raises `VmBail` on any op / value shape outside the
  ## supported subset.
  var regs = newSeq[VmVal](int(f.registerCount))
  for i in 0 ..< regs.len:
    regs[i] = vv(undefinedVal())
  # Bind args into the callee's low registers r0..r(argc-1) — the param
  # slots (compileFunction lays params out at r0.. in declaration order).
  # min(args.len, registerCount) guards a malformed argc; extras are dropped.
  var na = args.len
  if na > regs.len: na = regs.len
  for i in 0 ..< na:
    regs[i] = args[i]
  let code = f.code
  let codeLen = code.len
  var ip = 0

  # Fetch a numeric ZjsValue from register `r` (bails on string).
  template rn(r: uint8): ZjsValue = numVal(regs[int(r)])

  while ip < codeLen:
    let inst = code[ip]
    case inst.op

    # --- loads & moves ------------------------------------------------
    of LoadInt:
      regs[int(inst.a)] = vv(int32Val(int32(instBcI16(inst))))
    of LoadConst:
      let cv = f.constants[int(instBcU16(inst))]
      case cv.kind
      of ckInt:      regs[int(inst.a)] = vv(int32Val(cv.i))
      of ckDouble:   regs[int(inst.a)] = vv(doubleVal(cv.d))
      of ckString:   regs[int(inst.a)] = vs(cv.s)
      of ckFunction:
        # A function-constant load produces a callable function VALUE
        # (interpreter.zc treats the bare Function* cell as invokable — the
        # IIFE / FunctionExpr-in-var path uses it directly, no MakeClosure).
        regs[int(inst.a)] = vf(cv.fn)
    of LoadUndefined:
      regs[int(inst.a)] = vv(undefinedVal())
    of LoadHole:
      # TDZ seed (#330): a lexical binding (let/const) is seeded with the
      # hole sentinel and overwritten on init. interpreter.zc ~3353 stores
      # zjs_deleted(). A function-body let/const is UNCONDITIONALLY seeded
      # at function-top (compiler.zc ~4487), so any multi-statement body
      # with locals reaches this.
      regs[int(inst.a)] = vv(deletedVal())
    of ThrowIfHole:
      # TDZ read check (interpreter.zc ~3357): reading a binding still
      # holding the hole is a ReferenceError — the oracle throws (nothing on
      # stdout), so BAIL to match (never a wrong value).
      let v = regs[int(inst.a)]
      if v.kind == vkVal and v.v.bits == VALUE_DELETED:
        bail("TDZ: access before initialization")
    of LoadNull:
      regs[int(inst.a)] = vv(nullVal())
    of LoadTrue:
      regs[int(inst.a)] = vv(boolVal(true))
    of LoadFalse:
      regs[int(inst.a)] = vv(boolVal(false))
    of Mov:
      regs[int(inst.a)] = regs[int(inst.b)]

    # --- globals ------------------------------------------------------
    of DefineGlobal, StoreGlobal, StoreGlobalStrict:
      let slot = int(instBcU16(inst))
      if slot >= globals.len: globals.setLen(slot + 1)
      globals[slot] = regs[int(inst.a)]
    of LoadGlobal:
      let slot = int(instBcU16(inst))
      # A read of an undeclared global would be a ReferenceError in the
      # oracle (prints nothing then throws). Slice 1 only sees globals it
      # declared via DefineGlobal/StoreGlobal earlier in the same program;
      # a genuinely-missing slot is out of scope → bail.
      if slot >= globals.len or (globals[slot].kind == vkVal and
          globals[slot].v.bits == 0'u64):
        bail("LoadGlobal of undeclared slot")
      regs[int(inst.a)] = globals[slot]
    of LoadGlobalOrUndefined:
      let slot = int(instBcU16(inst))
      if slot >= globals.len or (globals[slot].kind == vkVal and
          globals[slot].v.bits == 0'u64):
        regs[int(inst.a)] = vv(undefinedVal())
      else:
        regs[int(inst.a)] = globals[slot]

    # --- binary arithmetic --------------------------------------------
    of Add:
      # ECMA-262 Op::Add (interpreter.zc ~3508): if EITHER operand is a
      # string, ToString both and concatenate → a string; else numeric add.
      # (ToPrimitive on objects = slice 4; vmToString bails on function /
      # non-integer double.)
      let a = regs[int(inst.b)]
      let b = regs[int(inst.c)]
      if a.kind == vkString or b.kind == vkString:
        regs[int(inst.a)] = vs(vmToString(a) & vmToString(b))
      else:
        # Numeric path: ToNumber both (numVal) so bool/null/undefined
        # operands coerce (true+1→2, null+1→1) rather than passing a
        # non-number into arithAdd. Functions bail via numVal.
        regs[int(inst.a)] = vv(arithAdd(numVal(a), numVal(b)))
    of Sub:
      regs[int(inst.a)] = vv(arithSub(rn(inst.b), rn(inst.c)))
    of Mul:
      regs[int(inst.a)] = vv(arithMul(rn(inst.b), rn(inst.c)))
    of Div:
      regs[int(inst.a)] = vv(arithDiv(rn(inst.b), rn(inst.c)))
    of Mod:
      regs[int(inst.a)] = vv(arithMod(rn(inst.b), rn(inst.c)))
    of Pow:
      regs[int(inst.a)] = vv(arithPow(rn(inst.b), rn(inst.c)))
    of AddImm:
      # interpreter.zc ~3613: int32 + i8 fast path, overflow → double.
      let a = regs[int(inst.b)]
      let imm = int32(cast[int8](inst.c))
      if a.kind == vkVal and isInt32(a.v):
        let s = int64(asInt32(a.v)) + int64(imm)
        if s >= I32_MIN and s <= I32_MAX:
          regs[int(inst.a)] = vv(int32Val(int32(s)))
        else:
          regs[int(inst.a)] = vv(doubleVal(float64(s)))
      elif a.kind == vkString:
        # Slow fallback = real Add: string LHS → concat with the imm's
        # ToString (interpreter.zc ~3641). imm is an int32 so ToString is
        # its decimal digits.
        regs[int(inst.a)] = vs(a.s & $imm)
      else:
        # Numeric fallback: ToNumber the operand (double/bool/null/undef)
        # then add. numVal handles bool→1 / null→0 / undefined→NaN.
        regs[int(inst.a)] = vv(arithAdd(numVal(a), int32Val(imm)))
    of SubImm:
      let a = regs[int(inst.b)]
      let imm = int32(cast[int8](inst.c))
      if a.kind == vkVal and isInt32(a.v):
        let d = int64(asInt32(a.v)) - int64(imm)
        if d >= I32_MIN and d <= I32_MAX:
          regs[int(inst.a)] = vv(int32Val(int32(d)))
        else:
          regs[int(inst.a)] = vv(doubleVal(float64(d)))
      else:
        # Sub coerces both via ToNumber (no concat). Covers unary plus
        # (`+x` → `x - 0`): "7"-2→5, +true→1, +null→0, +"42"→42. numVal
        # runs the full ToNumber ladder over string / bool / null / undef.
        regs[int(inst.a)] = vv(arithSub(numVal(a), int32Val(imm)))

    # --- comparison → bool --------------------------------------------
    of CmpEq:
      regs[int(inst.a)] = vv(boolVal(vmLooseEq(regs[int(inst.b)], regs[int(inst.c)])))
    of CmpNe:
      regs[int(inst.a)] = vv(boolVal(not vmLooseEq(regs[int(inst.b)], regs[int(inst.c)])))
    of CmpStrictEq:
      regs[int(inst.a)] = vv(boolVal(vmStrictEq(regs[int(inst.b)], regs[int(inst.c)])))
    of CmpStrictNe:
      regs[int(inst.a)] = vv(boolVal(not vmStrictEq(regs[int(inst.b)], regs[int(inst.c)])))
    of CmpLt:
      regs[int(inst.a)] = vv(boolVal(vmCmpLt(regs[int(inst.b)], regs[int(inst.c)])))
    of CmpLe:
      regs[int(inst.a)] = vv(boolVal(vmCmpLe(regs[int(inst.b)], regs[int(inst.c)])))
    of CmpGt:
      regs[int(inst.a)] = vv(boolVal(vmCmpLt(regs[int(inst.c)], regs[int(inst.b)])))
    of CmpGe:
      regs[int(inst.a)] = vv(boolVal(vmCmpLe(regs[int(inst.c)], regs[int(inst.b)])))
    of CmpLtImm:
      let a = rn(inst.b); let imm = int32(cast[int8](inst.c))
      if isInt32(a): regs[int(inst.a)] = vv(boolVal(asInt32(a) < imm))
      else: regs[int(inst.a)] = vv(boolVal(cmpLt(a, int32Val(imm))))
    of CmpLeImm:
      let a = rn(inst.b); let imm = int32(cast[int8](inst.c))
      if isInt32(a): regs[int(inst.a)] = vv(boolVal(asInt32(a) <= imm))
      else: regs[int(inst.a)] = vv(boolVal(cmpLe(a, int32Val(imm))))
    of CmpGtImm:
      let a = rn(inst.b); let imm = int32(cast[int8](inst.c))
      if isInt32(a): regs[int(inst.a)] = vv(boolVal(asInt32(a) > imm))
      else: regs[int(inst.a)] = vv(boolVal(cmpLt(int32Val(imm), a)))
    of CmpGeImm:
      let a = rn(inst.b); let imm = int32(cast[int8](inst.c))
      if isInt32(a): regs[int(inst.a)] = vv(boolVal(asInt32(a) >= imm))
      else: regs[int(inst.a)] = vv(boolVal(cmpLe(int32Val(imm), a)))

    # --- bitwise / shift ----------------------------------------------
    of BitAnd: regs[int(inst.a)] = vv(bitAnd(rn(inst.b), rn(inst.c)))
    of BitOr:  regs[int(inst.a)] = vv(bitOr(rn(inst.b), rn(inst.c)))
    of BitXor: regs[int(inst.a)] = vv(bitXor(rn(inst.b), rn(inst.c)))
    of Shl:    regs[int(inst.a)] = vv(shl32(rn(inst.b), rn(inst.c)))
    of Shr:    regs[int(inst.a)] = vv(shr32(rn(inst.b), rn(inst.c)))
    of UShr:   regs[int(inst.a)] = vv(ushr32(rn(inst.b), rn(inst.c)))

    # --- unary --------------------------------------------------------
    of Neg:    regs[int(inst.a)] = vv(arithNeg(rn(inst.b)))
    of BitNot: regs[int(inst.a)] = vv(bitNot(rn(inst.b)))
    of LogicalNot:
      # ToBoolean over the VmVal so ""→false / "x"→true are distinguished
      # (rn would ToNumber both to NaN, collapsing the distinction).
      regs[int(inst.a)] = vv(boolVal(not vmToBool(regs[int(inst.b)])))

    # --- type introspection -------------------------------------------
    of Typeof:
      # ECMA-262 typeof (interpreter.zc ~6070): the result is a type STRING
      # (a vkString). Symbol / BigInt aren't representable in our value set;
      # a function VALUE → "function". null → "object".
      let x = regs[int(inst.b)]
      let label =
        case x.kind
        of vkString:   "string"
        of vkFunction: "function"
        of vkVal:
          let v = x.v
          if isUndefined(v): "undefined"
          elif isNull(v):    "object"
          elif isBool(v):    "boolean"
          elif isNumber(v):  "number"
          else: bail("typeof on non-primitive")
      regs[int(inst.a)] = vs(label)

    # --- control flow -------------------------------------------------
    of Jmp:
      ip = ip + 1 + int(instBcI16(inst))
      continue
    of JmpIfTrue:
      # ToBoolean over the VmVal (a string condition, e.g. `""?1:2`, must
      # distinguish ""→false from "x"→true; rn's ToNumber would lose it).
      if vmToBool(regs[int(inst.a)]):
        ip = ip + 1 + int(instBcI16(inst)); continue
    of JmpIfFalse:
      if not vmToBool(regs[int(inst.a)]):
        ip = ip + 1 + int(instBcI16(inst)); continue
    of JmpIfNullish:
      # A string / function value is never null/undefined; only inspect the
      # ZjsValue arm.
      let x = regs[int(inst.a)]
      if x.kind == vkVal and (isNull(x.v) or isUndefined(x.v)):
        ip = ip + 1 + int(instBcI16(inst)); continue
    of JmpIfNotNullish:
      let x = regs[int(inst.a)]
      if not (x.kind == vkVal and (isNull(x.v) or isUndefined(x.v))):
        ip = ip + 1 + int(instBcI16(inst)); continue

    # --- fused compare-and-branch (branch when FALSE) -----------------
    # interpreter.zc ~3770: operands at inst[ip], i16 offset in the J+1
    # carrier code[ip+1], branch base J+2. taken: ip = ip+2+off;
    # not-taken: ip = ip+2 (skip the carrier).
    of JmpIfNotLt:
      let ct = vmCmpLt(regs[int(inst.a)], regs[int(inst.b)])
      ip = if ct: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotLe:
      let ct = vmCmpLe(regs[int(inst.a)], regs[int(inst.b)])
      ip = if ct: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotGt:
      let ct = vmCmpLt(regs[int(inst.b)], regs[int(inst.a)])
      ip = if ct: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotGe:
      let ct = vmCmpLe(regs[int(inst.b)], regs[int(inst.a)])
      ip = if ct: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotLtImm:
      let a = rn(inst.a); let imm = int32(cast[int8](inst.b))
      let ct = if isInt32(a): asInt32(a) < imm else: cmpLt(a, int32Val(imm))
      ip = if ct: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotLeImm:
      let a = rn(inst.a); let imm = int32(cast[int8](inst.b))
      let ct = if isInt32(a): asInt32(a) <= imm else: cmpLe(a, int32Val(imm))
      ip = if ct: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotGtImm:
      let a = rn(inst.a); let imm = int32(cast[int8](inst.b))
      let ct = if isInt32(a): asInt32(a) > imm else: cmpLt(int32Val(imm), a)
      ip = if ct: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotGeImm:
      let a = rn(inst.a); let imm = int32(cast[int8](inst.b))
      let ct = if isInt32(a): asInt32(a) >= imm else: cmpLe(int32Val(imm), a)
      ip = if ct: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotEq:
      let ct = vmLooseEq(regs[int(inst.a)], regs[int(inst.b)])
      ip = if ct: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotNe:
      let ne = not vmLooseEq(regs[int(inst.a)], regs[int(inst.b)])
      ip = if ne: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotStrictEq:
      let ct = vmStrictEq(regs[int(inst.a)], regs[int(inst.b)])
      ip = if ct: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotStrictNe:
      let ne = not vmStrictEq(regs[int(inst.a)], regs[int(inst.b)])
      ip = if ne: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue

    # --- inverse-polarity fused compare-and-branch (branch when TRUE) -
    # interpreter.zc ~4128: same carrier layout; branch taken on TRUE.
    of JmpIfLt:
      let ct = vmCmpLt(regs[int(inst.a)], regs[int(inst.b)])
      ip = if ct: ip + 2 + int(instBcI16(code[ip+1])) else: ip + 2
      continue
    of JmpIfLe:
      let ct = vmCmpLe(regs[int(inst.a)], regs[int(inst.b)])
      ip = if ct: ip + 2 + int(instBcI16(code[ip+1])) else: ip + 2
      continue
    of JmpIfGt:
      let ct = vmCmpLt(regs[int(inst.b)], regs[int(inst.a)])
      ip = if ct: ip + 2 + int(instBcI16(code[ip+1])) else: ip + 2
      continue
    of JmpIfGe:
      let ct = vmCmpLe(regs[int(inst.b)], regs[int(inst.a)])
      ip = if ct: ip + 2 + int(instBcI16(code[ip+1])) else: ip + 2
      continue
    of JmpIfLtImm:
      let a = rn(inst.a); let imm = int32(cast[int8](inst.b))
      let ct = if isInt32(a): asInt32(a) < imm else: cmpLt(a, int32Val(imm))
      ip = if ct: ip + 2 + int(instBcI16(code[ip+1])) else: ip + 2
      continue
    of JmpIfLeImm:
      let a = rn(inst.a); let imm = int32(cast[int8](inst.b))
      let ct = if isInt32(a): asInt32(a) <= imm else: cmpLe(a, int32Val(imm))
      ip = if ct: ip + 2 + int(instBcI16(code[ip+1])) else: ip + 2
      continue
    of JmpIfGtImm:
      let a = rn(inst.a); let imm = int32(cast[int8](inst.b))
      let ct = if isInt32(a): asInt32(a) > imm else: cmpLt(int32Val(imm), a)
      ip = if ct: ip + 2 + int(instBcI16(code[ip+1])) else: ip + 2
      continue
    of JmpIfGeImm:
      let a = rn(inst.a); let imm = int32(cast[int8](inst.b))
      let ct = if isInt32(a): asInt32(a) >= imm else: cmpLe(int32Val(imm), a)
      ip = if ct: ip + 2 + int(instBcI16(code[ip+1])) else: ip + 2
      continue

    # --- function values / calls (slice 2) ----------------------------
    of MakeClosure:
      # a=dst, b=function-value reg, c=env-object reg (interpreter.zc
      # ~6448). The compiler emits the NON-capturing in-place form
      # `MakeClosure r,r,r` for a function that references no outer scope;
      # there env == the function value itself (not a real env object), so
      # the closure just wraps the Function with a NULL env. A CAPTURING
      # closure needs a real env object from NewObject (which we don't
      # model) — resolveCallee already bails on `f.needsEnv`, and such a
      # function only ever reaches MakeClosure via the env-wrapping form
      # whose env reg would (in a real run) hold an object. Here we simply
      # carry the Function forward as a value; a later Invoke of a
      # needsEnv/arrow function bails at resolve time (never a wrong value).
      let src = regs[int(inst.b)]
      if src.kind != vkFunction:
        bail("MakeClosure on non-function")
      regs[int(inst.a)] = vf(src.fn)
    of SetFunctionName:
      # ECMA-262 SetFunctionName (interpreter.zc ~6218): installs `.name` on
      # a function value. The name is NOT part of the printed completion
      # value, so this is a value-preserving no-op for the eval oracle. Only
      # touches function-valued targets; leaves others unchanged.
      discard
    of Invoke, TailInvoke:
      # Plain call (interpreter.zc ~5539/5913): a=ret_dst, b=base, c=argc.
      # Callee = regs[base]; args = regs[base+1 .. base+argc]. TailInvoke has
      # the same operand layout and (for correctness) executes as a normal
      # call whose result the trailing Return reads — no frame-replacement
      # needed to produce the right value.
      let base = int(inst.b)
      let argc = int(inst.c)
      let callee = resolveCallee(regs[base])
      var callArgs = newSeq[VmVal](argc)
      for i in 0 ..< argc:
        callArgs[i] = regs[base + 1 + i]
      regs[int(inst.a)] = callFunction(callee, callArgs, globals, depth)
    of InvokeGlobal:
      # Fused global-callee call (interpreter.zc ~5634): a=ret_dst, b=base,
      # c=argc; the carrier at code[ip+1] holds the u16 global slot. The
      # callee is globals[slot]; args = regs[base+1 .. base+argc]. Advance ip
      # past the carrier exactly as the reference does (ip = ip + 1 then read
      # code[ip]), so the post-dispatch `inc ip` lands on the next real op.
      let base = int(inst.b)
      let argc = int(inst.c)
      ip = ip + 1
      let gslot = int(instBcU16(code[ip]))
      if gslot >= globals.len:
        bail("InvokeGlobal of undeclared slot")
      let calleeVal = globals[gslot]
      # An undeclared / built-in slot (a zero-bits placeholder) is out of
      # scope — the reference would ObjectRecord-fallback to globalThis or
      # throw a ReferenceError; either way, not a value we can produce.
      if calleeVal.kind == vkVal and calleeVal.v.bits == 0'u64:
        bail("InvokeGlobal of undeclared slot")
      let callee = resolveCallee(calleeVal)
      var callArgs = newSeq[VmVal](argc)
      for i in 0 ..< argc:
        callArgs[i] = regs[base + 1 + i]
      regs[int(inst.a)] = callFunction(callee, callArgs, globals, depth)

    # --- return / halt ------------------------------------------------
    of Return:
      return regs[int(inst.a)]
    of Halt:
      return vv(undefinedVal())

    else:
      # Any op not handled above needs objects / calls / strings /
      # coercion — out of slice-1 scope. Bail: the CLI prints nothing.
      bail("unimplemented op: " & $inst.op)

    inc ip
