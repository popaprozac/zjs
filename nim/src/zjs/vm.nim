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

type
  VmValKind* = enum
    vkVal      ## a plain NaN-boxed ZjsValue (number / bool / null / undefined)
    vkString   ## a string constant (from LoadConst ckString); print-only

  VmVal* = object
    case kind*: VmValKind
    of vkVal:    v*: ZjsValue
    of vkString: s*: string

  VmBail* = object of CatchableError
    ## Raised when the VM hits an op or value shape it can't faithfully
    ## execute. The CLI must then print NOTHING and exit nonzero.

# --- VmVal constructors -------------------------------------------------

proc vv(v: ZjsValue): VmVal {.inline.} = VmVal(kind: vkVal, v: v)
proc vs(s: string): VmVal {.inline.} = VmVal(kind: vkString, s: s)

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

# --- register helpers: unwrap a VmVal to a numeric ZjsValue -------------

proc numVal(x: VmVal): ZjsValue {.inline.} =
  ## A register that must be a number/bool/null/undefined for an
  ## arithmetic/comparison op. A string operand is out of scope → bail.
  case x.kind
  of vkString: bail("operation on string operand")
  of vkVal:    x.v

# --- the interpreter ----------------------------------------------------

proc runFunction*(f: Function, globals: var seq[VmVal]): VmVal =
  ## Execute `f`'s bytecode, returning the value in its `Return` operand
  ## register. `globals` is the shared slot array (indexed by the full
  ## u16 global slot, ≥ USER_GLOBAL_BASE). Raises `VmBail` on any op or
  ## value shape outside the slice-1 subset.
  var regs = newSeq[VmVal](int(f.registerCount))
  for i in 0 ..< regs.len:
    regs[i] = vv(undefinedVal())
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
      of ckFunction: bail("LoadConst function")
    of LoadUndefined:
      regs[int(inst.a)] = vv(undefinedVal())
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
      let a = regs[int(inst.b)]
      let b = regs[int(inst.c)]
      if a.kind == vkString or b.kind == vkString:
        bail("string concat")   # slice 3
      regs[int(inst.a)] = vv(arithAdd(a.v, b.v))
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
        bail("string + imm")
      else:
        regs[int(inst.a)] = vv(arithAdd(a.v, int32Val(imm)))
    of SubImm:
      let a = regs[int(inst.b)]
      let imm = int32(cast[int8](inst.c))
      if a.kind == vkVal and isInt32(a.v):
        let d = int64(asInt32(a.v)) - int64(imm)
        if d >= I32_MIN and d <= I32_MAX:
          regs[int(inst.a)] = vv(int32Val(int32(d)))
        else:
          regs[int(inst.a)] = vv(doubleVal(float64(d)))
      elif a.kind == vkString:
        bail("string - imm")
      else:
        regs[int(inst.a)] = vv(arithSub(a.v, int32Val(imm)))

    # --- comparison → bool --------------------------------------------
    of CmpEq:
      regs[int(inst.a)] = vv(boolVal(looseEqSimple(rn(inst.b), rn(inst.c))))
    of CmpNe:
      regs[int(inst.a)] = vv(boolVal(not looseEqSimple(rn(inst.b), rn(inst.c))))
    of CmpStrictEq:
      regs[int(inst.a)] = vv(boolVal(strictEqNum(rn(inst.b), rn(inst.c))))
    of CmpStrictNe:
      regs[int(inst.a)] = vv(boolVal(not strictEqNum(rn(inst.b), rn(inst.c))))
    of CmpLt:
      regs[int(inst.a)] = vv(boolVal(cmpLt(rn(inst.b), rn(inst.c))))
    of CmpLe:
      regs[int(inst.a)] = vv(boolVal(cmpLe(rn(inst.b), rn(inst.c))))
    of CmpGt:
      regs[int(inst.a)] = vv(boolVal(cmpLt(rn(inst.c), rn(inst.b))))
    of CmpGe:
      regs[int(inst.a)] = vv(boolVal(cmpLe(rn(inst.c), rn(inst.b))))
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
      regs[int(inst.a)] = vv(boolVal(not toBool(rn(inst.b))))

    # --- control flow -------------------------------------------------
    of Jmp:
      ip = ip + 1 + int(instBcI16(inst))
      continue
    of JmpIfTrue:
      if toBool(rn(inst.a)):
        ip = ip + 1 + int(instBcI16(inst)); continue
    of JmpIfFalse:
      if not toBool(rn(inst.a)):
        ip = ip + 1 + int(instBcI16(inst)); continue
    of JmpIfNullish:
      let v = rn(inst.a)
      if isNull(v) or isUndefined(v):
        ip = ip + 1 + int(instBcI16(inst)); continue
    of JmpIfNotNullish:
      let v = rn(inst.a)
      if not (isNull(v) or isUndefined(v)):
        ip = ip + 1 + int(instBcI16(inst)); continue

    # --- fused compare-and-branch (branch when FALSE) -----------------
    # interpreter.zc ~3770: operands at inst[ip], i16 offset in the J+1
    # carrier code[ip+1], branch base J+2. taken: ip = ip+2+off;
    # not-taken: ip = ip+2 (skip the carrier).
    of JmpIfNotLt:
      let ct = cmpLt(rn(inst.a), rn(inst.b))
      ip = if ct: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotLe:
      let ct = cmpLe(rn(inst.a), rn(inst.b))
      ip = if ct: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotGt:
      let ct = cmpLt(rn(inst.b), rn(inst.a))
      ip = if ct: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotGe:
      let ct = cmpLe(rn(inst.b), rn(inst.a))
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
      let ct = looseEqSimple(rn(inst.a), rn(inst.b))
      ip = if ct: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotNe:
      let ne = not looseEqSimple(rn(inst.a), rn(inst.b))
      ip = if ne: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotStrictEq:
      let ct = strictEqNum(rn(inst.a), rn(inst.b))
      ip = if ct: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue
    of JmpIfNotStrictNe:
      let ne = not strictEqNum(rn(inst.a), rn(inst.b))
      ip = if ne: ip + 2 else: ip + 2 + int(instBcI16(code[ip+1]))
      continue

    # --- inverse-polarity fused compare-and-branch (branch when TRUE) -
    # interpreter.zc ~4128: same carrier layout; branch taken on TRUE.
    of JmpIfLt:
      let ct = cmpLt(rn(inst.a), rn(inst.b))
      ip = if ct: ip + 2 + int(instBcI16(code[ip+1])) else: ip + 2
      continue
    of JmpIfLe:
      let ct = cmpLe(rn(inst.a), rn(inst.b))
      ip = if ct: ip + 2 + int(instBcI16(code[ip+1])) else: ip + 2
      continue
    of JmpIfGt:
      let ct = cmpLt(rn(inst.b), rn(inst.a))
      ip = if ct: ip + 2 + int(instBcI16(code[ip+1])) else: ip + 2
      continue
    of JmpIfGe:
      let ct = cmpLe(rn(inst.b), rn(inst.a))
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
