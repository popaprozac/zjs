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
import std/tables
import bytecode, value, gc, dtoa

# C strtod for the ECMA-262 StringToNumber path (value.zc ~217): ported
# verbatim so hex ("0x1F"→31), decimals, and whitespace-trim match the
# oracle exactly rather than being re-approximated in Nim.
proc c_strtod(s: cstring, endp: ptr cstring): float64 {.importc: "strtod", header: "<stdlib.h>".}
proc c_snprintf_ll(buf: cstring, n: csize_t, fmt: cstring, v: clonglong): cint {.importc: "snprintf", header: "<stdio.h>", varargs.}
# "%.0f" for integral doubles in [1e15, 1e21): exact-integer print that
# respects IEEE rounding past 2^53, mirroring zjs_to_string (context.zc
# ~33680). MUST use libc snprintf, not js_double_to_chars — the oracle
# prints the exact integer digits here, not the shortest-round-trip form.
proc c_snprintf_f(buf: cstring, n: csize_t, fmt: cstring, v: cdouble): cint {.importc: "snprintf", header: "<stdio.h>", varargs.}

type
  VmValKind* = enum
    vkVal       ## a plain NaN-boxed ZjsValue (number / bool / null / undefined)
    vkString    ## a string constant (from LoadConst ckString); print-only
    vkFunction  ## a callable function value: a bare Function* from a
                ## function-constant LoadConst, or a closure from MakeClosure
                ## carrying a captured `env` (slice B2). `env` is a ZjsValue —
                ## an ObjectCell for a real closure, or `undefined` for a
                ## non-capturing function. The env is a GC root (markVmVal).

  VmVal* = object
    case kind*: VmValKind
    of vkVal:      v*: ZjsValue
    of vkString:   s*: string
    of vkFunction:
      fn*:  Function
      env*: ZjsValue   ## captured environment object, or undefined = none

  VmBail* = object of CatchableError
    ## Raised when the VM hits an op or value shape it can't faithfully
    ## execute. The CLI must then print NOTHING and exit nonzero.

  JsThrow* = object of CatchableError
    ## A JavaScript exception in flight (the `throw` completion). Carries the
    ## thrown value and unwinds the Nim call stack (through natives / callbacks /
    ## callFunction) to the nearest frame with an active try-region. Distinct
    ## from VmBail: a JS try/catch catches JsThrow but NOT VmBail (an
    ## unimplemented op still aborts the whole eval, never becomes catchable).
    val*: VmVal

  NativeFn* = proc(heap: var GcHeap, args: openArray[VmVal],
                   thisv: VmVal): VmVal {.nimcall.}
    ## A Nim-implemented (native/host) builtin — the Nim analogue of the
    ## reference `(ctx, args, argc) -> ZjsValue` (src/context.zc host_*). The
    ## `{.nimcall.}` convention makes it a plain function pointer (no closure
    ## env), so it is storable as a raw `pointer` in a HostFnCell and cast back
    ## here to dispatch. `heap` is threaded for natives that allocate; `args`
    ## are the argument registers; `thisv` the receiver (undefined for plain /
    ## global calls, the receiver for a method call). A native MAY `bail(msg)`
    ## for arg shapes outside its subset (e.g. an object arg needing valueOf
    ## coercion) — a clean VmBail, never a wrong value.

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

proc vv*(v: ZjsValue): VmVal {.inline.} = VmVal(kind: vkVal, v: v)
proc vs*(s: string): VmVal {.inline.} = VmVal(kind: vkString, s: s)
proc vf(f: Function): VmVal {.inline.} =
  ## A non-capturing function value (env = none).
  VmVal(kind: vkFunction, fn: f, env: undefinedVal())
proc vf(f: Function, env: ZjsValue): VmVal {.inline.} =
  ## A closure value carrying its captured env object (or `undefined`).
  VmVal(kind: vkFunction, fn: f, env: env)

proc bail*(msg: string) {.noreturn.} =
  raise newException(VmBail, msg)

proc raiseJs(v: VmVal) {.noreturn.} =
  ## Raise a JavaScript exception carrying `v` (a `throw` propagating to the
  ## nearest enclosing try-region, across frames via the Nim call stack).
  var e = newException(JsThrow, "js exception")
  e.val = v
  raise e

# --- GC frame rooting ---------------------------------------------------
# The GC scans `heap.frameRoots` (seq[ptr seq[ZjsValue]]) natively, but a
# VM register file is a `seq[VmVal]` — the GC module can't name that type
# without importing vm.nim (circular). So the VM keeps its OWN stack of
# active frame register files here and marks the cell-holding `vkVal`
# registers via `heap.customMark`, installed once by the top-level run.
# Only vkVal registers can hold a heap cell; vkString / vkFunction are
# Nim-managed (skipped). LIFO: runFrame pushes on entry, pops on exit.
#
# Correctness: EVERY value that flows into a register goes through this
# scan, so a cell held in any active frame's regs (or in globals) is a
# root and survives a collect() triggered mid-execution (e.g. by an
# allocating NewObject inside a loop). This is what makes the object model
# safe under GC pressure — no live object reachable from a register is
# ever freed.
# A frame contributes THREE root sources: its register file (the seq the
# handlers write), plus the frame's `env` and `thisVal` — which live as
# runFrame locals (NOT necessarily in a register) and hold GC cells that
# must survive a collect triggered mid-frame. env is only copied into a
# register by a LoadEnv the body may not have reached yet, so rooting it
# here is what keeps a captured env / `this` receiver alive.
type FrameRoot = object
  regs*:  ptr seq[VmVal]
  env*:   VmVal
  thisv*: VmVal

var vmFrames {.threadvar.}: seq[FrameRoot]
var vmGlobals {.threadvar.}: ptr seq[VmVal]
var vmHeap {.threadvar.}: ptr GcHeap   ## the heap the customMark hook reads
var vmNativeRoots {.threadvar.}: seq[ZjsValue]
  ## GC roots held by an in-flight native method (Array map/filter/reduce build a
  ## result array / carry an accumulator across callbacks that can allocate and
  ## trigger a collect). Marked by vmMarkFrames; LIFO push/pop by the native.

proc pushNativeRoot*(v: ZjsValue) = vmNativeRoots.add(v)
proc popNativeRoot*() =
  if vmNativeRoots.len > 0: vmNativeRoots.setLen(vmNativeRoots.len - 1)

# --- per-function runtime state (slice B3) ------------------------------
# A function VALUE gets an associated `.prototype` OBJECT and (for a class
# `extends`) a parent constructor. In the reference these are FIELDS on the
# `Function*` cell (`f.prototype`, `f.parent_ctor`); here the `Function` is an
# ARC-managed ref shared by every VmVal that carries it (LoadConst of one
# const-pool entry + Mov copies), so the state is keyed by the ref's stable
# address. Both tables are GC ROOTS (marked in vmMarkFrames): a lazily-created
# `.prototype` (and everything on it) must not be freed while the function is
# usable, even in a momentary window where no register holds the function
# value. Bounded — one entry per distinct function in the program. Reset per
# top-level run so a reused Function address can't read a prior run's state.
var fnProtos {.threadvar.}: Table[pointer, ZjsValue]      ## fn -> .prototype obj
var fnParentCtors {.threadvar.}: Table[pointer, VmVal]    ## child ctor -> parent
var funcProps {.threadvar.}: Table[pointer, ZjsValue]
  ## Function EXPANDO properties (`fn.x = v`), keyed by the shared Function ref
  ## address → a props ObjectCell. Correct for distinct top-level functions (one
  ## closure per Function ref — e.g. test262's `assert` / `Test262Error`); two
  ## closures of the SAME source fn would alias (a rare pattern). Pinned as a GC
  ## root in vmMarkFrames; reset per top-level run.
var vmObjectProto {.threadvar.}: ZjsValue
  ## The realm's `Object.prototype` cell, installed by `installBuiltins` via
  ## `setObjectProto`. `NewObject` links every plain object literal's
  ## [[Prototype]] to it, so inherited Object.prototype methods (hasOwnProperty,
  ## toString, …) resolve through `protoChainLookup`. A non-cell default (before
  ## install) leaves plain objects proto-less — the pre-builtins fallback where
  ## an inherited-name access bails rather than returning a wrong value. The cell
  ## is rooted via `globals` (Object's bag holds it as `.prototype`), so this
  ## cached pointer stays live; the collector is non-moving so it stays valid.

proc setObjectProto*(v: ZjsValue) =
  ## Register the realm's Object.prototype cell (called by installBuiltins each
  ## run, before any NewObject executes).
  vmObjectProto = v

proc getObjectProto*(): ZjsValue = vmObjectProto
  ## The realm's Object.prototype (for natives that build plain objects, e.g.
  ## JSON.parse, so they inherit the standard proto chain). Undefined if unset.

var vmArrayProto {.threadvar.}: ZjsValue
  ## The realm's `Array.prototype` cell (an ObjectCell whose props are the array
  ## method natives; its own proto = Object.prototype). ArrayCells carry no inline
  ## proto link, so LoadProp on an array resolves an inherited method by looking
  ## the name up here directly. Installed by installBuiltins via setArrayProto;
  ## rooted via globals (Array's bag holds it as `.prototype`).

proc setArrayProto*(v: ZjsValue) =
  ## Register the realm's Array.prototype cell (called by installBuiltins).
  vmArrayProto = v

var vmStringProto {.threadvar.}: ZjsValue
  ## The realm's `String.prototype` cell (methods as natives; proto = Object.
  ## prototype). String primitives (vkString) carry no proto, so LoadProp on a
  ## string resolves an inherited method by looking the name up here. zjs strings
  ## are UTF-8 BYTE sequences (length/charAt/charCodeAt/slice are byte-indexed),
  ## which nim's `string` mirrors — so String methods are plain byte ops.

proc setStringProto*(v: ZjsValue) =
  ## Register the realm's String.prototype cell (called by installBuiltins).
  vmStringProto = v

var vmNumberProto {.threadvar.}: ZjsValue
  ## The realm's `Number.prototype` cell (toFixed/toString/valueOf natives; proto
  ## = Object.prototype). Number primitives carry no proto, so LoadProp on a
  ## number resolves an inherited method by looking the name up here.

proc setNumberProto*(v: ZjsValue) =
  ## Register the realm's Number.prototype cell (called by installBuiltins).
  vmNumberProto = v

var vmErrorProto {.threadvar.}: ZjsValue
  ## The realm's `Error.prototype` cell (its toString reads this.name/.message).
  ## Every error object (Error / TypeError / …) links to it so `.toString()`
  ## resolves; the per-subtype `name` own-prop makes one shared toString correct.

proc setErrorProto*(v: ZjsValue) = vmErrorProto = v
proc getErrorProto*(): ZjsValue = vmErrorProto

proc markVmVal(heap: GcHeap, x: VmVal) {.inline.} =
  ## Mark any GC cell a VmVal can hold: a vkVal's cell, OR a closure's
  ## captured env (a vkFunction's env is an ObjectCell that must survive
  ## while the closure is reachable). vkString is Nim-managed (skipped).
  case x.kind
  of vkVal:      markCell(heap, x.v)
  of vkFunction: markCell(heap, x.env)
  of vkString:   discard

proc vmMarkFrames() =
  ## Mark every cell held in an active frame's registers, its env / this,
  ## and in globals. Reads the current heap from the threadvar so the
  ## closure captures nothing (Nim forbids capturing a `var GcHeap` param).
  if vmHeap == nil: return
  let heap = vmHeap
  if vmGlobals != nil:
    for x in vmGlobals[]:
      markVmVal(heap[], x)
  for fr in vmFrames:
    if fr.regs != nil:
      for x in fr.regs[]:
        markVmVal(heap[], x)
    markVmVal(heap[], fr.env)
    markVmVal(heap[], fr.thisv)
  # slice B3: pin every function's `.prototype` object (and thus the methods
  # installed on it) and any recorded parent-ctor value. See fnProtos above.
  for pv in fnProtos.values:
    markCell(heap[], pv)
  for pc in fnParentCtors.values:
    markVmVal(heap[], pc)
  for fp in funcProps.values:
    markCell(heap[], fp)
  # Native-method accumulator roots (Array.prototype map/filter/reduce build a
  # result / carry an accumulator across callbacks that can allocate + collect).
  for r in vmNativeRoots:
    markCell(heap[], r)

# --- object-model op helpers -------------------------------------------
# Slice B1 has NO prototype chain: a receiver must be a plain object or
# array cell for property/element access to be faithful. Anything else (a
# string with `.length`, a number, an inherited-only prop like `.toString`
# on a bare object) is out of scope → BAIL, never a wrong result.

const
  ## Names present on Object.prototype (from the live oracle). A LoadProp /
  ## LoadElem that MISSES an own property but whose name is here would, in a
  ## real run, resolve through the prototype chain to an inherited value
  ## (e.g. `({}).toString` → a function) — machinery B1 lacks. So a missing
  ## own property with one of these names BAILS (never the wrong `undefined`).
  OBJECT_PROTO_NAMES = [
    "hasOwnProperty", "isPrototypeOf", "propertyIsEnumerable", "toString",
    "valueOf", "__defineGetter__", "__defineSetter__", "__lookupGetter__",
    "__lookupSetter__", "toLocaleString", "__proto__", "constructor"]
  ## Names present on Array.prototype (the array proto chain also includes
  ## Object.prototype, checked separately).
  ARRAY_PROTO_NAMES = [
    "push", "pop", "indexOf", "map", "forEach", "fill", "copyWithin", "join",
    "toString", "slice", "concat", "every", "some", "find", "findIndex",
    "filter", "reduce", "reduceRight", "includes", "lastIndexOf", "at", "flat",
    "flatMap", "reverse", "sort", "splice", "shift", "unshift", "findLast",
    "findLastIndex", "toReversed", "toSorted", "toSpliced", "with", "keys",
    "values", "entries", "constructor", "length"]

proc isObjectInherited(name: string): bool =
  for n in OBJECT_PROTO_NAMES:
    if n == name: return true
  false

proc isArrayInherited(name: string): bool =
  ## The array proto chain = Array.prototype -> Object.prototype.
  for n in ARRAY_PROTO_NAMES:
    if n == name: return true
  isObjectInherited(name)

const GC_TRIGGER_INTERVAL = 4096
  ## Force a collect every N cell allocations so a long allocating loop
  ## (e.g. `for(...) { var t={x:i}; }`) actually EXERCISES the mid-
  ## execution collect + frame rooting, keeping live memory bounded — and
  ## proving no register/globals-held object is freed while live.

proc asObjectCell(x: VmVal): ptr ObjectCell {.inline.} =
  ## The receiver as a plain ObjectCell, or nil if it isn't one.
  if x.kind == vkVal and isCell(x.v) and cellHeader(x.v).typeTag == TAG_OBJECT:
    cast[ptr ObjectCell](cellAsPtr(x.v))
  else:
    nil

proc asArrayCell(x: VmVal): ptr ArrayCell {.inline.} =
  ## The receiver as a plain ArrayCell, or nil if it isn't one.
  if x.kind == vkVal and isCell(x.v) and cellHeader(x.v).typeTag == TAG_ARRAY:
    cast[ptr ArrayCell](cellAsPtr(x.v))
  else:
    nil

proc arrayIndex(key: ZjsValue): int =
  ## An array-index integer from a key value (non-negative int32), else -1
  ## (a non-index key routes to the object property path or bails).
  if isInt32(key):
    let i = asInt32(key)
    if i >= 0: return int(i)
  elif isDouble(key):
    let d = asDouble(key)
    if d == d and d >= 0.0 and d <= 2147483647.0 and d == d.int.float64:
      return int(d)
  -1

proc boxForStore*(heap: var GcHeap, x: VmVal): ZjsValue =
  ## Convert a VmVal into a ZjsValue for storage in an object side table
  ## (which holds ZjsValues, not the VM's function variant). A vkFunction is
  ## boxed into a FunctionCell so a closure VALUE can live as a property and
  ## round-trip on load; a vkVal passes through. A vkString has no cell
  ## representation yet → bail (never a wrong stored value).
  case x.kind
  of vkVal:      x.v
  of vkFunction: cellValue(allocFunction(heap, x.fn, x.env))
  of vkString:   cellValue(allocStringCell(heap, x.s))  # Phase 6: string cell

proc unboxLoaded*(heap: GcHeap, v: ZjsValue): VmVal =
  ## Convert a stored ZjsValue back into a VmVal: a FunctionCell → the
  ## vkFunction closure it boxes (fn + env); a StringCell → the vkString it
  ## boxes; anything else → a plain vkVal.
  if isFunctionCell(heap, v):
    return vf(funcCellFn(heap, v), funcCellEnv(heap, v))
  if isStringCell(heap, v):
    return vs(strCellVal(heap, v))
  vv(v)

proc maybeCollect(heap: var GcHeap) {.inline.} =
  ## Trigger a full collect once the allocation count crosses the interval.
  ## The frame regs + globals are roots (heap.customMark), so every live
  ## object survives; only unreachable throwaway cells are reclaimed.
  if heap.totalAllocated - heap.lastCollectAt >= GC_TRIGGER_INTERVAL:
    discard collect(heap)
    heap.lastCollectAt = heap.totalAllocated

# --- prototype / new helpers (slice B3) --------------------------------

proc objCellOfValue(v: ZjsValue): ptr ObjectCell {.inline.} =
  ## `v` as a plain ObjectCell pointer, or nil if it isn't one (used to walk
  ## the [[Prototype]] chain, whose links are stored as ZjsValues).
  if isCell(v) and cellAsPtr(v) != nil and cellHeader(v).typeTag == TAG_OBJECT:
    cast[ptr ObjectCell](cellAsPtr(v))
  else:
    nil

proc getOrCreateFnProto(heap: var GcHeap, fn: Function): ZjsValue =
  ## The function's `.prototype` OBJECT, created lazily on first access
  ## (interpreter.zc ~7663 / property_get ~1084: `if f.prototype == NULL { … }`).
  ## Keyed by the shared Function ref address and pinned in fnProtos (a GC
  ## root) so DefineMethod's installs, a later `new`, and every copy of the
  ## function value all see the SAME object. We omit the spec
  ## `.prototype.constructor` back-link: no target reads it, and a `.constructor`
  ## access harmlessly BAILS via the Object.prototype guard (never wrong).
  let key = cast[pointer](fn)
  if fnProtos.hasKey(key):
    return fnProtos[key]
  let protoObj = allocObject(heap)
  # A function's .prototype chains to Object.prototype (so instances inherit
  # Object.prototype methods and `instanceof Object` holds).
  if isCell(vmObjectProto) and cellAsPtr(vmObjectProto) != nil:
    objSetProto(protoObj, vmObjectProto)
  let proto = cellValue(protoObj)
  fnProtos[key] = proto
  proto

proc getOrCreateFuncProps(heap: var GcHeap, fn: Function): ptr ObjectCell =
  ## The function's expando-property bag (created on first `fn.x = v`), keyed by
  ## the shared Function ref address and pinned in funcProps (a GC root).
  let key = cast[pointer](fn)
  if funcProps.hasKey(key):
    return cast[ptr ObjectCell](cellAsPtr(funcProps[key]))
  let o = allocObject(heap)
  funcProps[key] = cellValue(o)
  o

proc isObjectResult(v: VmVal): bool {.inline.} =
  ## Whether a constructor's return value is an Object (ECMA-262 [[Construct]]
  ## step 13: an object return REPLACES the fresh instance; a primitive is
  ## ignored). A function value is an object; a string is a primitive.
  case v.kind
  of vkFunction: true
  of vkString:   false
  of vkVal:
    if isCell(v.v) and cellAsPtr(v.v) != nil:
      let t = cellHeader(v.v).typeTag
      t == TAG_OBJECT or t == TAG_ARRAY or t == TAG_FUNCTION
    else:
      false

proc protoChainLookup(heap: GcHeap, start: ptr ObjectCell, name: string,
                      found: var bool): ZjsValue =
  ## Resolve `name` on `start` then up its [[Prototype]] chain (property_get's
  ## `while cur != NULL { … cur = cur.proto }`, interpreter.zc ~964). Returns
  ## the OWN value at the first cell that has it; `found` reports a hit. The
  ## chain ends when a proto link is not an ObjectCell (undefined = no proto).
  var cur = start
  while cur != nil:
    if objHas(heap, cur, name):
      found = true
      return objGet(heap, cur, name)
    cur = objCellOfValue(objGetProto(cur))
  found = false
  undefinedVal()

# --- ZjsValue arithmetic / comparison (ports of src/value.zc) ----------

const
  I32_MIN = -2147483648'i64
  I32_MAX =  2147483647'i64

# C fmod (Nim's math.floorMod is integer; we need the double fmod).
proc c_fmod(x, y: float64): float64 {.importc: "fmod", header: "<math.h>".}

# libm for the specialized 1-arg Math ops (Op::MathSqrt/Abs/Floor/Ceil,
# interpreter.zc ~6759). Bind the SAME C routines the reference calls so the
# results are byte-identical (importc, not std/math — zero doubt).
proc c_sqrt(x: float64): float64  {.importc: "sqrt",  header: "<math.h>".}
proc c_fabs(x: float64): float64  {.importc: "fabs",  header: "<math.h>".}
proc c_floor(x: float64): float64 {.importc: "floor", header: "<math.h>".}
proc c_ceil(x: float64): float64  {.importc: "ceil",  header: "<math.h>".}

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

proc vmToNumber*(x: VmVal): ZjsValue =
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

proc vmToString*(x: VmVal): string =
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
      # Integral double past the %lld window but below 1e21: the oracle
      # prints the EXACT integer via %.0f (context.zc ~33680), NOT the
      # shortest-round-trip form — e.g. 86161958985030656 stays exact
      # rather than collapsing to 86161958985030660. Reproduce %.0f here.
      if d == floor(d) and abs(d) < 1e21:
        var buf: array[64, char]
        let n = c_snprintf_f(cast[cstring](addr buf[0]), csize_t(64),
                             cstring("%.0f"), cdouble(d))
        if n <= 0 or n >= 64: bail("ToString double overflow")
        var res = newString(n)
        for i in 0 ..< n: res[i] = buf[i]
        return res
      # Non-integral (or integral >= 1e21) double → dtoa: the ECMAScript
      # shortest-round-trip formatter (§6.1.6.1.20), ported verbatim from
      # js_double_to_chars for byte-identity with the oracle.
      return doubleToChars(d)
    if isBool(v):      return (if asBool(v) != 0: "true" else: "false")
    if isNull(v):      return "null"
    if isUndefined(v): return "undefined"
    bail("ToString on non-primitive")

proc vmToBool*(x: VmVal): bool =
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

proc vmStrictEq*(a, b: VmVal): bool =
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
              heap: var GcHeap, depth: int, thisVal: VmVal, env: VmVal): VmVal

proc callNative(heap: var GcHeap, cell: ZjsValue, args: openArray[VmVal],
                thisv: VmVal): VmVal =
  ## Dispatch a call to a boxed native builtin: cast the HostFnCell's stored
  ## proc pointer back to a `NativeFn` and call it with `args` + `thisv`. The
  ## native returns the result VmVal, or raises VmBail for an unsupported arg
  ## shape (never a wrong value). Caller has proven `isHostFunctionCell(cell)`.
  let fn = cast[NativeFn](hostFnPtr(heap, cell))
  fn(heap, args, thisv)

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
  if f.isArrow or f.isAsync or f.isGenerator or f.isClassCtor:
    # arrow: lexical this/env; async: must yield a Promise; generator: must
    # return an iterator; class-ctor: needs `new` — all deferred to later
    # slices. A `needsEnv` callee is NO LONGER bailed (slice B2): it carries
    # its captured env in the VmVal (from a capturing MakeClosure), which the
    # call site threads into the new frame. If a needsEnv function somehow
    # lacks its env, LoadEnv reads `undefined` and the ensuing LoadProp bails
    # — never a wrong result.
    bail("callee shape needs object model / new / async / generator")
  f

proc callFunction(callee: Function, args: openArray[VmVal],
                  globals: var seq[VmVal], heap: var GcHeap, depth: int,
                  thisVal: VmVal, env: VmVal): VmVal =
  ## Create a fresh frame for `callee`, bind `args` to its low registers
  ## r0..r(argc-1) (the params), run it from ip 0, and return its Return
  ## value. Mirrors push_call_frame + the Op::Invoke frame push
  ## (interpreter.zc ~5716-5731): a NEW register file sized
  ## callee.registerCount, args copied into the param slots, extras dropped,
  ## missing params left undefined. `thisVal` seeds the callee's `this`
  ## register (MethodInvoke receiver, else undefined); `env` is the callee
  ## closure's captured environment (LoadEnv reads it).
  if depth + 1 > MAX_CALL_DEPTH:
    bail("call stack depth exceeded")
  runFrame(callee, args, globals, heap, depth + 1, thisVal, env)

proc invokeCallback*(heap: var GcHeap, fn: VmVal, thisArg: VmVal,
                     cbArgs: openArray[VmVal]): VmVal =
  ## Invoke an Array-method callback `fn(...cbArgs)` with `thisArg` as receiver,
  ## re-entering the interpreter. Uses the thread's globals and the CURRENT frame
  ## depth (vmFrames.len) so nested callbacks respect MAX_CALL_DEPTH. A host-fn
  ## callback dispatches the native directly. Bails on a non-callable callback
  ## (the array-method TypeError path — never a wrong value). The CALLER must root
  ## any accumulator across this call (the callback can allocate + trigger a
  ## collect; see pushNativeRoot).
  if vmGlobals == nil: bail("Array callback: no active globals")
  if fn.kind == vkVal and isCell(fn.v) and cellAsPtr(fn.v) != nil and
     cellHeader(fn.v).typeTag == TAG_HOSTFN:
    return callNative(heap, fn.v, cbArgs, thisArg)
  let callee = resolveCallee(fn)
  var a = newSeq[VmVal](cbArgs.len)
  for i in 0 ..< cbArgs.len: a[i] = cbArgs[i]
  callFunction(callee, a, vmGlobals[], heap, vmFrames.len, thisArg, vv(fn.env))

proc runFunction*(f: Function, globals: var seq[VmVal], heap: var GcHeap,
                  depth: int = 0): VmVal =
  ## Execute the top-level program `f` (public entry point). A program takes
  ## no arguments; see `runFrame` for the shared execution core. Installs the
  ## GC root hook (frame regs + globals) for the duration of the run so any
  ## collect() triggered by object/array allocation keeps live cells.
  let savedFrames = vmFrames
  let savedGlobals = vmGlobals
  let savedHeap = vmHeap
  # Reset the B3 per-function state (prototypes / parent ctors). Kept per-run
  # so a reused Function ref address from a PRIOR run (this heap/thread) can't
  # be mistaken for a live one and hand back a stale prototype (a wrong value).
  let savedProtos = fnProtos
  let savedParents = fnParentCtors
  let savedFuncProps = funcProps
  fnProtos = initTable[pointer, ZjsValue]()
  fnParentCtors = initTable[pointer, VmVal]()
  funcProps = initTable[pointer, ZjsValue]()
  vmFrames.setLen(0)
  vmGlobals = addr globals
  vmHeap = addr heap
  heap.customMark = vmMarkFrames
  try:
    # The top-level program has no receiver and no captured env.
    result = runFrame(f, [], globals, heap, depth,
                      vv(undefinedVal()), vv(undefinedVal()))
  except JsThrow as e:
    # An uncaught top-level throw: the eval CLI prints the thrown value as the
    # completion (`throw 1` → 1), so surface it as the result.
    result = e.val
  finally:
    heap.customMark = nil
    vmFrames = savedFrames
    vmGlobals = savedGlobals
    vmHeap = savedHeap
    fnProtos = savedProtos
    fnParentCtors = savedParents
    funcProps = savedFuncProps

proc runFunction*(f: Function, globals: var seq[VmVal]): VmVal =
  ## Backward-compatible entry that owns a private heap for the run (used by
  ## call sites that don't thread a heap). Cells are collected when the heap
  ## is destroyed at scope exit.
  var heap = newGcHeap()
  result = runFunction(f, globals, heap, 0)
  destroyHeap(heap)

proc runFrame(f: Function, args: openArray[VmVal], globals: var seq[VmVal],
              heap: var GcHeap, depth: int, thisVal: VmVal, env: VmVal): VmVal =
  ## Execute `f`'s bytecode in a fresh register frame, returning the value in
  ## its `Return` operand register. `args` seed the callee's low param
  ## registers r0..; extras drop, missing params stay undefined (matching
  ## push_call_frame's arg-copy). `globals` is the shared slot array (indexed
  ## by the full u16 global slot, ≥ USER_GLOBAL_BASE). `depth` is the
  ## call-frame nesting. `thisVal` seeds the reserved `this` register
  ## (f.thisReg) — the receiver for a MethodInvoke, else undefined; no
  ## prologue op materializes it (interpreter.zc ~2125). `env` is the
  ## invoked closure's captured environment, read by LoadEnv. Raises
  ## `VmBail` on any op / value shape outside the supported subset.
  var regs = newSeq[VmVal](int(f.registerCount))
  for i in 0 ..< regs.len:
    regs[i] = vv(undefinedVal())
  # Register THIS frame's register file (plus its env / this) as GC roots
  # for its whole lifetime (LIFO push/pop). Every cell a register — or the
  # frame's env / receiver — holds is scanned by markRoots via
  # heap.customMark, so a collect() triggered by an allocating op inside
  # this frame keeps the live objects (a captured env survives even before
  # a LoadEnv copies it into a register). `defer` pops on EVERY exit path
  # (normal return, VmBail, deep-recursion).
  vmFrames.add(FrameRoot(regs: addr regs, env: env, thisv: thisVal))
  defer: vmFrames.setLen(vmFrames.len - 1)
  # Bind args into the callee's low registers r0..r(argc-1) — the param
  # slots (compileFunction lays params out at r0.. in declaration order).
  # min(args.len, registerCount) guards a malformed argc; extras are dropped.
  var na = args.len
  if na > regs.len: na = regs.len
  for i in 0 ..< na:
    regs[i] = args[i]
  # Seed `this` into its reserved register (compiler reserved it after the
  # params iff the body uses `this`). thisReg < 0 → the body never reads
  # `this`, so nothing to seed. No prologue op — the seed IS the mechanism.
  if f.thisReg >= 0 and f.thisReg < regs.len:
    regs[f.thisReg] = thisVal
  let code = f.code
  let codeLen = code.len
  var ip = 0
  # This frame's active try-regions (EnterTry pushes, LeaveTry pops). On a throw
  # — the Throw op OR a JsThrow propagating out of a call — the nearest region's
  # catch_ip receives control and the thrown value is bound into catch_reg.
  var tryStack: seq[tuple[catchIp: int, catchReg: int]]

  # Bind `thrownVal` to the nearest try-region in THIS frame if any: pop it, put
  # the value in its catch reg, jump ip to its catch handler → returns true (the
  # caller must `continue`). Else returns false (propagate to the caller frame).
  template catchHere(thrownVal: VmVal): bool =
    if tryStack.len > 0:
      let h = tryStack.pop()
      regs[h.catchReg] = thrownVal
      ip = h.catchIp
      true
    else:
      false

  # Run a call; a JsThrow propagating out of it is routed to this frame's
  # try-stack (jump to the catch handler, `continue` the dispatch loop) or
  # re-raised to propagate to the caller frame.
  template routeThrow(callBody: untyped) =
    try:
      callBody
    except JsThrow as jse:
      if catchHere(jse.val): continue
      raise

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
    of MathSqrt, MathAbs, MathFloor, MathCeil:
      # Specialized 1-arg Math.X(x) (interpreter.zc ~6759): the compiler
      # emits these instead of LoadGlobal+LoadProp+MethodInvoke when `Math`
      # statically resolves to the global object. b=arg reg, a=dst. Straight
      # ToNumber + libm — byte-identical to the host_math_* natives.
      let mv = regs[int(inst.b)]
      let mvInt32 = mv.kind == vkVal and isInt32(mv.v)
      var d: float64
      if mvInt32:
        d = float64(asInt32(mv.v))
      elif mv.kind == vkVal and isDouble(mv.v):
        d = asDouble(mv.v)
      else:
        # bool/null/undefined/string → ToNumber; object/function → bail
        # (reference routes objects through zjs_to_double's valueOf; deferred).
        let n = vmToNumber(mv)
        d = if isInt32(n): float64(asInt32(n)) else: asDouble(n)
      var r: float64
      if inst.op == MathSqrt:    r = c_sqrt(d)
      elif inst.op == MathAbs:   r = c_fabs(d)
      elif inst.op == MathFloor: r = c_floor(d)
      else:                      r = c_ceil(d)      # MathCeil
      # Abs/Floor/Ceil of an int32 that lands back in int32 range stays int32
      # (interpreter.zc ~6792: i=(i32)r; keep if (f64)i==r). r is integer-
      # valued here, so an in-range guard reproduces that exactly (and avoids
      # a Nim float→int RangeDefect on the abs(INT32_MIN) overflow → double).
      if inst.op != MathSqrt and mvInt32 and
         r >= -2147483648.0 and r <= 2147483647.0:
        regs[int(inst.a)] = vv(int32Val(int32(r)))
      else:
        regs[int(inst.a)] = vv(doubleVal(r))
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
          elif isCell(v) and cellAsPtr(v) != nil:
            # Heap cells (object model + Phase 6 natives): an object/array is
            # "object"; a function value — a JS closure (TAG_FUNCTION) or a
            # native builtin (TAG_HOSTFN, e.g. `typeof console.log`) — is
            # "function"; a boxed string is "string". Matches the oracle
            # (`typeof {}`/`typeof console` → "object"; `typeof console.log`
            # → "function"). Any other cell shape bails (never a wrong type).
            case cellHeader(v).typeTag
            of TAG_OBJECT, TAG_ARRAY:    "object"
            of TAG_FUNCTION, TAG_HOSTFN: "function"
            of TAG_STRING:               "string"
            else: bail("typeof on unknown cell")
          else: bail("typeof on non-primitive")
      regs[int(inst.a)] = vs(label)

    # --- control flow -------------------------------------------------
    of Jmp:
      ip = ip + 1 + int(instBcI16(inst))
      continue
    of EnterTry:
      # a=catch_reg; i16 = signed offset to the catch handler from ip+1
      # (interpreter.zc Op::EnterTry). Push the region; body runs next.
      tryStack.add((catchIp: ip + 1 + int(instBcI16(inst)), catchReg: int(inst.a)))
    of LeaveTry:
      # Normal exit from a try body — pop its region (interpreter.zc Op::LeaveTry).
      if tryStack.len > 0: discard tryStack.pop()
    of Throw:
      # Throw regs[a]: catch in this frame if a region is active, else propagate
      # to the caller frame via JsThrow (finally is compiler-encoded via nested
      # regions + a rethrow flag, so no special handling needed here).
      let tv = regs[int(inst.a)]
      if catchHere(tv): continue
      raiseJs(tv)
    of AssertCoercible:
      # a=x: RequireObjectCoercible (destructuring source / `with`). null or
      # undefined throws a TypeError; anything else is a no-op. Building that
      # exact TypeError from the VM isn't wired → BAIL on null/undefined (never a
      # wrong value); a coercible value passes through so object destructuring runs.
      let x = regs[int(inst.a)]
      if x.kind == vkVal and (isNull(x.v) or isUndefined(x.v)):
        bail("AssertCoercible on null/undefined (TypeError)")
    of BuildRestArgs:
      # a=dst, b=first_param_index: gather this call's args from index b onward
      # into a fresh Array (interpreter.zc BuildRestArgs) — the `...rest` param.
      let firstIdx = int(inst.b)
      var rest: seq[ZjsValue] = @[]
      var i = firstIdx
      while i < args.len:
        rest.add(boxForStore(heap, args[i]))
        inc i
      regs[int(inst.a)] = vv(cellValue(allocArray(heap, rest)))
      maybeCollect(heap)
    of DeleteElem:
      # a=dst, b=obj, c=key: `delete obj[key]` → true (every model prop is
      # configurable). Plain-object receiver + string key only; else bail.
      let o = asObjectCell(regs[int(inst.b)])
      let key = regs[int(inst.c)]
      if o == nil or key.kind != vkString:
        bail("DeleteElem on non-object receiver / non-string key")
      discard objDelete(heap, o, key.s)
      regs[int(inst.a)] = vv(boolVal(true))
    of Instanceof:
      # a=dst, b=lhs, c=rhs: `lhs instanceof rhs` — true iff rhs.prototype appears
      # in lhs's [[Prototype]] chain. rhs must be callable (a JS function or a
      # native constructor); else a TypeError in the oracle → bail.
      let lhs = regs[int(inst.b)]
      let rhs = regs[int(inst.c)]
      var rhsProto: ZjsValue = undefinedVal()
      if rhs.kind == vkFunction and rhs.fn != nil:
        rhsProto = getOrCreateFnProto(heap, rhs.fn)
      elif rhs.kind == vkVal and isHostFunctionCell(rhs.v) and
           heap.objTable.hasKey(cellAsPtr(rhs.v)) and
           objHas(heap, cast[ptr ObjectCell](cellAsPtr(rhs.v)), "prototype"):
        rhsProto = objGet(heap, cast[ptr ObjectCell](cellAsPtr(rhs.v)), "prototype")
      else:
        bail("instanceof RHS is not a constructor with a prototype")
      let rp = cellAsPtr(rhsProto)
      # Starting [[Prototype]] of lhs: an object's own proto link; an array's is
      # Array.prototype; a primitive is not a chain-instance → false.
      var curProto: ZjsValue = undefinedVal()
      if lhs.kind == vkVal and isCell(lhs.v) and cellAsPtr(lhs.v) != nil:
        case cellHeader(lhs.v).typeTag
        of TAG_OBJECT: curProto = objGetProto(cast[ptr ObjectCell](cellAsPtr(lhs.v)))
        of TAG_ARRAY:  curProto = vmArrayProto
        else: discard
      var found = false
      while isCell(curProto) and cellAsPtr(curProto) != nil and
            cellHeader(curProto).typeTag == TAG_OBJECT:
        if cellAsPtr(curProto) == rp:
          found = true; break
        curProto = objGetProto(cast[ptr ObjectCell](cellAsPtr(curProto)))
      regs[int(inst.a)] = vv(boolVal(found))
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
      # `MakeClosure r,r,r` (a==b==c) for a function that references no outer
      # scope: env == the function value itself, so the closure carries no
      # env (none). A CAPTURING closure uses distinct regs: env comes from
      # regs[c] — an ObjectCell built by the enclosing frame's NewObject +
      # StoreProp (slice B1), or a forwarded outer env from LoadEnv. The
      # closure carries that env ZjsValue so a later Invoke seeds the callee
      # frame's env with it (LoadEnv + LoadProp then read the captured vars).
      let src = regs[int(inst.b)]
      if src.kind != vkFunction:
        bail("MakeClosure on non-function")
      if inst.a == inst.b and inst.b == inst.c:
        # Non-capturing in-place form: no env.
        regs[int(inst.a)] = vf(src.fn)
      else:
        # Capturing form: env is the object cell (or forwarded env) at regs[c].
        let er = regs[int(inst.c)]
        let envv = if er.kind == vkVal: er.v else: undefinedVal()
        regs[int(inst.a)] = vf(src.fn, envv)
    of LoadEnv:
      # a=dst (interpreter.zc ~6470): load THIS frame's captured environment
      # object into a register. The env was threaded in at call time from the
      # invoked closure's `env` (a MakeClosure-captured ObjectCell, or
      # `undefined` for a non-capturing callee). The body then reads captured
      # variables via LoadProp on this reg (slice B1).
      regs[int(inst.a)] = env
    of LoadCallee:
      # a=dst (interpreter.zc ~6491): the function value currently invoking
      # this frame — used by a named FunctionExpr / a class ctor to bind its
      # own name inside the body, and emitted as the first op of a synthesized
      # (empty / default-derived) class constructor. We reconstruct the value
      # from this frame's `f` + captured `env` (equivalent to the invoked
      # closure). Our targets discard it (the synthesized ctor bodies never
      # read it back), so this is never observably wrong.
      let envZ = if env.kind == vkVal: env.v else: undefinedVal()
      regs[int(inst.a)] = vf(f, envZ)
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
      let calleeVal = regs[base]
      var callArgs = newSeq[VmVal](argc)
      for i in 0 ..< argc:
        callArgs[i] = regs[base + 1 + i]
      # A boxed native builtin (isNaN / isFinite / …) dispatches to its Nim
      # proc — `this` is undefined for a plain call. Otherwise a normal JS
      # function call: `this` is undefined (a non-method callee); env is the
      # invoked closure's captured environment.
      if calleeVal.kind == vkVal and isHostFunctionCell(calleeVal.v):
        routeThrow: regs[int(inst.a)] = callNative(heap, calleeVal.v, callArgs,
                                                   vv(undefinedVal()))
      else:
        let callee = resolveCallee(calleeVal)
        routeThrow: regs[int(inst.a)] = callFunction(callee, callArgs, globals, heap,
                                                     depth, vv(undefinedVal()), vv(calleeVal.env))
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
      var callArgs = newSeq[VmVal](argc)
      for i in 0 ..< argc:
        callArgs[i] = regs[base + 1 + i]
      # An INSTALLED native builtin (isNaN / isFinite / …) holds a real
      # HostFnCell value here (non-zero bits) and dispatches to its Nim proc;
      # `this` is undefined for a global call.
      if calleeVal.kind == vkVal and isHostFunctionCell(calleeVal.v):
        routeThrow: regs[int(inst.a)] = callNative(heap, calleeVal.v, callArgs,
                                                   vv(undefinedVal()))
      else:
        # An un-installed / undeclared slot (a zero-bits placeholder) is out of
        # scope — the reference would ObjectRecord-fallback to globalThis or
        # throw a ReferenceError; either way, not a value we can produce.
        if calleeVal.kind == vkVal and calleeVal.v.bits == 0'u64:
          bail("InvokeGlobal of undeclared slot")
        let callee = resolveCallee(calleeVal)
        routeThrow: regs[int(inst.a)] = callFunction(callee, callArgs, globals, heap,
                                                     depth, vv(undefinedVal()), vv(calleeVal.env))
    of MethodInvoke, TailMethodInvoke:
      # Method call (interpreter.zc ~5539 MethodInvoke): a=ret_dst, b=base,
      # c=argc. regs[base]=method, regs[base+1]=receiver, regs[base+2..]=args.
      # The receiver becomes the callee's `this`; env is the method closure's
      # captured environment. TailMethodInvoke shares the layout and runs as
      # a normal call (the trailing Return reads its result).
      let base = int(inst.b)
      let argc = int(inst.c)
      let methodVal = regs[base]
      let recv = regs[base + 1]
      var callArgs = newSeq[VmVal](argc)
      for i in 0 ..< argc:
        callArgs[i] = regs[base + 2 + i]
      # A native method (a HostFnCell loaded from a property) dispatches to its
      # Nim proc with `this` = the receiver. Otherwise a normal JS method call.
      if methodVal.kind == vkVal and isHostFunctionCell(methodVal.v):
        routeThrow: regs[int(inst.a)] = callNative(heap, methodVal.v, callArgs, recv)
      else:
        let callee = resolveCallee(methodVal)
        routeThrow: regs[int(inst.a)] = callFunction(callee, callArgs, globals, heap,
                                                     depth, recv, vv(methodVal.env))

    # --- object / array model (slice B1) ------------------------------
    of NewObject:
      # a=dst. Allocate an empty ObjectCell (interpreter.zc ~6802
      # ctx_new_object). The cell is boxed into a vkVal ZjsValue; it is a
      # root immediately (this frame's regs are scanned). Its [[Prototype]] is
      # Object.prototype (installed via setObjectProto) so inherited proto
      # methods resolve; before builtins install it, the object stays proto-less.
      let newObjCell = allocObject(heap)
      if isCell(vmObjectProto) and cellAsPtr(vmObjectProto) != nil:
        objSetProto(newObjCell, vmObjectProto)
      regs[int(inst.a)] = vv(cellValue(newObjCell))
      maybeCollect(heap)
    of InitObjData:
      # a=obj, b=keyReg (a string const), c=valReg. CreateDataProperty on
      # the object literal (interpreter.zc ~6933). The key came from a
      # LoadConst ckString, so regs[keyReg] is a vkString.
      let o = asObjectCell(regs[int(inst.a)])
      if o == nil: bail("InitObjData on non-object")
      let keyv = regs[int(inst.b)]
      if keyv.kind != vkString: bail("InitObjData non-string key")
      let valv = regs[int(inst.c)]
      # boxForStore represents a function VALUE as a FunctionCell (so a
      # method / stored closure round-trips on load); a plain value passes
      # through; a string value still bails (no string cell yet).
      objSet(heap, o, keyv.s, boxForStore(heap, valv))
    of StoreProp:
      # a=obj, b=ic, c=val. Own-property set by name f.ics[ic]
      # (interpreter.zc ~6678). Only plain object receivers are in scope;
      # a string / number / array-with-a-named-prop receiver bails.
      let name = f.ics[int(inst.b)]
      let sv = regs[int(inst.c)]
      let recv = regs[int(inst.a)]
      let o = asObjectCell(recv)
      # boxForStore boxes a function value into a FunctionCell; a plain value
      # passes through.
      if o != nil:
        objSet(heap, o, name, boxForStore(heap, sv))
      elif recv.kind == vkFunction and recv.fn != nil:
        if name == "prototype":
          # `fn.prototype = <object>` reassigns the function's [[Prototype]]
          # object (getOrCreateFnProto / LoadProp .prototype read it back; new
          # instances chain to it). A PRIMITIVE prototype value hits a
          # declaration-vs-expression writability quirk in the oracle we can't
          # faithfully replicate → bail (never a wrong value).
          if sv.kind == vkVal and isCell(sv.v) and cellAsPtr(sv.v) != nil and
             cellHeader(sv.v).typeTag in {TAG_OBJECT, TAG_ARRAY}:
            fnProtos[cast[pointer](recv.fn)] = sv.v
          else:
            bail("fn.prototype set to a non-object (oracle writability quirk)")
        else:
          # Function expando (`fn.x = v`) — stored on the function's props bag.
          objSet(heap, getOrCreateFuncProps(heap, recv.fn), name, boxForStore(heap, sv))
      else:
        bail("StoreProp on non-object / non-function receiver")
    of LoadProp:
      # a=dst, b=obj, c=ic. Own-property get by name f.ics[ic]
      # (interpreter.zc ~6503). Missing own prop → undefined. NO proto
      # chain: an array's `.length` returns the element count; any other
      # inherited-only name (.toString, .hasOwnProperty) or a non-object /
      # non-array receiver BAILS (never a wrong value).
      let name = f.ics[int(inst.c)]
      let recv = regs[int(inst.b)]
      let o = asObjectCell(recv)
      if o != nil:
        # Slice B3: walk own → [[Prototype]] chain (property_get ~964). An
        # instance's proto is a ctor.prototype object we built, so an
        # inherited METHOD resolves here. unboxLoaded turns a stored
        # FunctionCell back into a callable vkFunction closure.
        var found = false
        let v = protoChainLookup(heap, o, name, found)
        if found:
          regs[int(inst.a)] = unboxLoaded(heap, v)
        elif isObjectInherited(name):
          # Chain exhausted, but the name lives on Object.prototype (which we
          # have no built-in for) — the real run resolves an inherited value
          # B3 can't produce. Bail rather than a wrong `undefined`.
          bail("LoadProp inherited Object.prototype property")
        else:
          regs[int(inst.a)] = vv(undefinedVal())
      elif recv.kind == vkFunction:
        # `fn.prototype` — the constructor's prototype object (lazily created,
        # interpreter.zc property_get ~1084). Any OTHER name on a function
        # (.name / .length / .call / a static member) needs machinery B3
        # lacks → bail (never a wrong value).
        if name == "prototype":
          regs[int(inst.a)] = vv(getOrCreateFnProto(heap, recv.fn))
        elif recv.fn != nil and funcProps.hasKey(cast[pointer](recv.fn)) and
             objHas(heap, cast[ptr ObjectCell](cellAsPtr(funcProps[cast[pointer](recv.fn)])), name):
          # A function expando (`fn.x` previously set).
          let props = cast[ptr ObjectCell](cellAsPtr(funcProps[cast[pointer](recv.fn)]))
          regs[int(inst.a)] = unboxLoaded(heap, objGet(heap, props, name))
        else:
          # .length / .call / .apply / an unset expando — inherited Function.
          # prototype machinery we don't model → bail (never a wrong undefined).
          bail("LoadProp unmodeled function member")
      elif recv.kind == vkVal and isCell(recv.v) and cellAsPtr(recv.v) != nil and
           cellHeader(recv.v).typeTag == TAG_HOSTFN and
           heap.objTable.hasKey(cellAsPtr(recv.v)):
        # A native CONSTRUCTOR value (e.g. Object@g57) that carries its static
        # methods in an objTable property bag. Read its OWN static (Object.keys,
        # Object.is, …). A name we don't model — a deferred static (freeze /
        # getPrototypeOf / defineProperty / …), `.name` / `.length`, or an
        # inherited Function.prototype member — is a REAL reference property we
        # can't produce → BAIL (never a wrong `undefined`).
        let bag = cast[ptr ObjectCell](cellAsPtr(recv.v))
        if objHas(heap, bag, name):
          regs[int(inst.a)] = unboxLoaded(heap, objGet(heap, bag, name))
        elif name == "name":
          # `TypeError.name` → "TypeError" (the native's name).
          regs[int(inst.a)] = vs(hostFnName(heap, recv.v))
        else:
          bail("LoadProp unmodeled static/member on native constructor")
      elif recv.kind == vkString:
        # String primitive: `.length` is the BYTE count (zjs's UTF-8 model);
        # every other name resolves on String.prototype (→ Object.prototype),
        # bound to the string as `this` by MethodInvoke. A name absent from the
        # chain bails (a real string has many proto members we don't model) —
        # never a wrong undefined.
        if name == "length":
          regs[int(inst.a)] = vv(int32Val(int32(recv.s.len)))
        elif isCell(vmStringProto) and cellAsPtr(vmStringProto) != nil:
          let sp = cast[ptr ObjectCell](cellAsPtr(vmStringProto))
          var found = false
          let v = protoChainLookup(heap, sp, name, found)
          if found:
            regs[int(inst.a)] = unboxLoaded(heap, v)
          else:
            bail("LoadProp unmodeled String.prototype member")
        else:
          bail("LoadProp on string (String.prototype not installed)")
      elif recv.kind == vkVal and (isInt32(recv.v) or isDouble(recv.v)):
        # Number primitive: resolve an inherited method (toFixed/toString/…) on
        # Number.prototype (→ Object.prototype), bound to the number as `this`.
        # An absent name bails (never a wrong undefined).
        if isCell(vmNumberProto) and cellAsPtr(vmNumberProto) != nil:
          let np = cast[ptr ObjectCell](cellAsPtr(vmNumberProto))
          var found = false
          let v = protoChainLookup(heap, np, name, found)
          if found:
            regs[int(inst.a)] = unboxLoaded(heap, v)
          else:
            bail("LoadProp unmodeled Number.prototype member")
        else:
          bail("LoadProp on number (Number.prototype not installed)")
      else:
        let a = asArrayCell(recv)
        if a != nil:
          if name == "length":
            regs[int(inst.a)] = vv(int32Val(int32(arrLength(heap, a))))
          elif isCell(vmArrayProto) and cellAsPtr(vmArrayProto) != nil:
            # Resolve an inherited member off Array.prototype (→ Object.prototype).
            # ArrayCells have no inline proto, so we look the name up on the
            # fixed Array.prototype cell; a hit is the method (bound to the array
            # as `this` by MethodInvoke). A name on the proto chain we don't model
            # (isArrayInherited) bails; anything else is a genuinely-absent prop → undefined.
            let ap = cast[ptr ObjectCell](cellAsPtr(vmArrayProto))
            var found = false
            let v = protoChainLookup(heap, ap, name, found)
            if found:
              regs[int(inst.a)] = unboxLoaded(heap, v)
            elif isArrayInherited(name):
              bail("LoadProp inherited Array.prototype property (unmodeled)")
            else:
              regs[int(inst.a)] = vv(undefinedVal())
          else:
            bail("LoadProp named property on array (Array.prototype not installed)")
        else:
          bail("LoadProp on non-object/array receiver")
    of NewArray:
      # a=base(dst), b=base, c=count. Elements are in regs[base..base+count)
      # (interpreter.zc ~6817). Result reuses base.
      let base = int(inst.b)
      let count = int(inst.c)
      var elems = newSeq[ZjsValue](count)
      for i in 0 ..< count:
        # boxForStore represents a string element as a StringCell and a
        # function element as a FunctionCell (both round-trip on load), and
        # passes a plain ZjsValue (number/bool/null/undefined/object cell)
        # through. No collect fires inside this loop (allocCell never
        # collects; maybeCollect runs only after the array is in a register),
        # so the freshly-boxed cells are safe until the array roots them.
        elems[i] = boxForStore(heap, regs[base + i])
      regs[int(inst.a)] = vv(cellValue(allocArray(heap, elems)))
      maybeCollect(heap)
    of LoadElem:
      # a=dst, b=obj, c=idxReg. Array element by int index, or object
      # property by string key (interpreter.zc ~6830). Out-of-range /
      # absent → undefined.
      let recv = regs[int(inst.b)]
      let key = regs[int(inst.c)]
      let a = asArrayCell(recv)
      if a != nil:
        if key.kind != vkVal: bail("LoadElem array key is string/function")
        let idx = arrayIndex(key.v)
        if idx >= 0:
          # unboxLoaded turns a stored StringCell / FunctionCell back into a
          # vkString / vkFunction; a plain value passes through.
          regs[int(inst.a)] = unboxLoaded(heap, arrGet(heap, a, idx))
        else:
          # Non-index key on an array (e.g. a[-1], a["length"]) — needs the
          # property path / proto → bail.
          bail("LoadElem non-index key on array")
      elif recv.kind == vkString:
        # String index: `s[i]` → the 1-BYTE substring at i (zjs UTF-8 model),
        # or undefined out of range. A non-index key (s["length"]/s[-1]) bails.
        if key.kind == vkVal and (isInt32(key.v) or isDouble(key.v)):
          let idx = arrayIndex(key.v)
          if idx >= 0 and idx < recv.s.len:
            regs[int(inst.a)] = vs($recv.s[idx])
          else:
            regs[int(inst.a)] = vv(undefinedVal())
        else:
          bail("LoadElem non-index key on string")
      else:
        let o = asObjectCell(recv)
        if o == nil: bail("LoadElem on non-object/array receiver")
        # Object property by key: the key must ToString to a name. Only a
        # string key is in scope (a numeric key would need ToString digits
        # to match property_get) — bail otherwise.
        if key.kind == vkString:
          # Slice B3: own → [[Prototype]] chain, same as LoadProp.
          var found = false
          let v = protoChainLookup(heap, o, key.s, found)
          if found:
            regs[int(inst.a)] = unboxLoaded(heap, v)
          elif isObjectInherited(key.s):
            bail("LoadElem inherited Object.prototype property")
          else:
            regs[int(inst.a)] = vv(undefinedVal())
        else:
          bail("LoadElem non-string key on object")
    of StoreElem:
      # a=obj, b=idxReg, c=val. Array element / object property set
      # (interpreter.zc ~6875). Growing an array fills holes → undefined.
      let recv = regs[int(inst.a)]
      let value = regs[int(inst.c)]
      # boxForStore boxes a string / function value into a cell (round-trips
      # on load); a plain value passes through. No collect fires between here
      # and the arrSet/objSet, so the boxed cell is safe until the container
      # roots it.
      let stored = boxForStore(heap, value)
      let key = regs[int(inst.b)]
      let a = asArrayCell(recv)
      if a != nil:
        if key.kind != vkVal: bail("StoreElem array key is string/function")
        let idx = arrayIndex(key.v)
        if idx >= 0:
          arrSet(heap, a, idx, stored)
        else:
          bail("StoreElem non-index key on array")
      else:
        let o = asObjectCell(recv)
        if o == nil: bail("StoreElem on non-object/array receiver")
        if key.kind == vkString:
          objSet(heap, o, key.s, stored)
        else:
          bail("StoreElem non-string key on object")
    of ArrayLength:
      # a=dst, b=src. Element count of an array, else 0 (interpreter.zc
      # ~8371). Not emitted by the current Nim compiler (`.length` goes via
      # LoadProp), but handled for completeness / faithfulness.
      let a = asArrayCell(regs[int(inst.b)])
      if a == nil: bail("ArrayLength on non-array")
      regs[int(inst.a)] = vv(int32Val(int32(arrLength(heap, a))))

    # --- class machinery + `new` (slice B3) ---------------------------
    of DefineMethod:
      # a=target, b=nameIc, c=methodReg (interpreter.zc ~6095): install the
      # method (regs[c], a function value) as the property f.ics[b] on the
      # target. For instance methods the target is the ctor.prototype OBJECT;
      # for STATIC methods it is the constructor FUNCTION — deferred, so a
      # non-object target BAILS. boxForStore boxes the closure into a
      # FunctionCell so LoadProp can unbox it back to a callable value.
      let target = asObjectCell(regs[int(inst.a)])
      if target == nil:
        bail("DefineMethod on non-object target (static / other)")
      let mname = f.ics[int(inst.b)]
      let mv = regs[int(inst.c)]
      if mv.kind != vkFunction:
        bail("DefineMethod value is not a function")
      objSet(heap, target, mname, boxForStore(heap, mv))
    of SetProto:
      # a=proto, b=obj (interpreter.zc ~6168): wire obj.[[Prototype]] = proto.
      # Used by `extends` to chain Child.prototype.proto = Parent.prototype.
      # NOTE the operand order (a=proto, b=obj) — verified against the
      # reference and the disasm; a mixed-up order would build a wrong chain.
      let protoVal = regs[int(inst.a)]
      let obj = asObjectCell(regs[int(inst.b)])
      if obj == nil: bail("SetProto obj is not an object")
      if protoVal.kind == vkVal and objCellOfValue(protoVal.v) != nil:
        objSetProto(obj, protoVal.v)
      elif protoVal.kind == vkVal and isNull(protoVal.v):
        objSetProto(obj, nullVal())      # `extends null` (compiler bails; safe)
      else:
        bail("SetProto proto is not an object / null")
    of SetParentCtor:
      # a=ctor, b=parent (interpreter.zc ~6181): record the parent constructor
      # on the child ctor so a default-derived ctor's implicit super(...args)
      # can forward to it. Stored in fnParentCtors keyed by the child's shared
      # Function ref. Both must be function values (a non-function parent is a
      # "extends value is not a constructor" TypeError → bail here).
      let ctorVal = regs[int(inst.a)]
      let parentVal = regs[int(inst.b)]
      if ctorVal.kind != vkFunction or ctorVal.fn == nil:
        bail("SetParentCtor target is not a function")
      if parentVal.kind != vkFunction or parentVal.fn == nil:
        bail("SetParentCtor parent is not a function")
      fnParentCtors[cast[pointer](ctorVal.fn)] = parentVal
    of NewInvoke:
      # a=dst, b=base, c=argc (interpreter.zc ~7594): `new Ctor(args)`.
      # Allocate a fresh instance whose [[Prototype]] = Ctor.prototype, call
      # the ctor with `this` = the instance + args at base+1.., and return the
      # instance UNLESS the ctor returns an Object (then that object wins).
      let dst  = int(inst.a)
      let base = int(inst.b)
      let argc = int(inst.c)
      let calleeVal = regs[base]
      if calleeVal.kind == vkVal and isHostFunctionCell(calleeVal.v):
        # A native callee: only a real native CONSTRUCTOR (Error/TypeError/…) may
        # be `new`'d — it builds and returns the object (`new X(a)` == `X(a)`). A
        # non-constructor native (isNaN / Math.floor / …) `new`'d is a TypeError
        # in the oracle → BAIL (never call it, never a wrong value).
        if not hostFnIsCtor(heap, calleeVal.v):
          bail("NewInvoke on a non-constructor native")
        var natArgs = newSeq[VmVal](argc)
        for i in 0 ..< argc: natArgs[i] = regs[base + 1 + i]
        routeThrow: regs[dst] = callNative(heap, calleeVal.v, natArgs, vv(undefinedVal()))
        maybeCollect(heap)
      elif calleeVal.kind != vkFunction or calleeVal.fn == nil:
        bail("NewInvoke callee is not a constructable function")
      else:
        let ctorFn = calleeVal.fn
        # Arrow / async / generator are not constructors (TypeError in the
        # oracle → nothing on stdout). A class ctor / plain function / default-
        # derived ctor ARE allowed here (unlike resolveCallee, which bails on
        # isClassCtor because a class ctor needs `new`).
        if ctorFn.isArrow or ctorFn.isAsync or ctorFn.isGenerator:
          bail("NewInvoke on arrow / async / generator")
        # Instance: fresh object, [[Prototype]] = ctor.prototype (lazily made).
        let protoV = getOrCreateFnProto(heap, ctorFn)
        let instance = allocObject(heap)
        objSetProto(instance, protoV)
        let instanceVal = vv(cellValue(instance))
        # Args at base+1 .. base+argc.
        var callArgs = newSeq[VmVal](argc)
        for i in 0 ..< argc:
          callArgs[i] = regs[base + 1 + i]
        # Skip default-derived-ctor forwarders: they carry no body, only an
        # implicit super(...args), so we run the first REAL ancestor ctor with
        # `this` = the instance (interpreter.zc ~7739 / ctor_skip_default_forwarders).
        var runFn = ctorFn
        var runEnv = calleeVal.env
        while runFn.isDefaultDerivedCtor:
          let pk = cast[pointer](runFn)
          if not fnParentCtors.hasKey(pk):
            bail("default-derived ctor without a parent")
          let parent = fnParentCtors[pk]
          if parent.kind != vkFunction or parent.fn == nil:
            bail("parent ctor is not a function")
          if parent.fn.isArrow or parent.fn.isAsync or parent.fn.isGenerator:
            bail("parent ctor is arrow / async / generator")
          runFn = parent.fn
          runEnv = parent.env
        # The instance is rooted for the whole ctor call as that frame's `this`
        # (FrameRoot.thisv), so a collect triggered inside the ctor keeps it.
        var ctorResult: VmVal
        routeThrow: ctorResult = callFunction(runFn, callArgs, globals, heap, depth,
                                              instanceVal, vv(runEnv))
        # Object return replaces the instance (ECMA-262 [[Construct]] step 13);
        # a primitive / undefined return is ignored → the instance.
        if isObjectResult(ctorResult):
          regs[dst] = ctorResult
        else:
          regs[dst] = instanceVal
        maybeCollect(heap)
    of SuperCall:
      # a=dst, b=base, c=argc (interpreter.zc ~6244): explicit `super(args)`
      # in a derived-class constructor. Call the PARENT constructor with
      # `this` = the CURRENT frame's instance (thisVal — the object the outer
      # NewInvoke allocated and threaded in as this ctor's receiver) so the
      # parent's `this.x=...` initializes the SAME object; super() does NOT
      # allocate a new instance, it initializes the existing one. The parent
      # ctor value is regs[base] (the compiler loads it there via
      # LoadEnv+LoadProp / LoadGlobal); args are regs[base+1 .. base+argc].
      let dst  = int(inst.a)
      let base = int(inst.b)
      let argc = int(inst.c)
      # The instance under construction MUST be a live object cell. A derived
      # class ctor only ever runs via NewInvoke, which seeds `thisVal` with
      # the fresh instance (even when the ctor has no this-register, as in
      # `constructor(){ super(x); }` — the seed lives in the frame's thisVal,
      # not a register). `super` outside a derived ctor (no object `this`) is
      # out of scope → bail, never a wrong store target.
      if asObjectCell(thisVal) == nil:
        bail("SuperCall with no object `this` (super outside derived ctor)")
      let parentVal = regs[base]
      if parentVal.kind != vkFunction or parentVal.fn == nil:
        bail("SuperCall parent is not a constructable function")
      # Args at base+1 .. base+argc — held in this frame's regs (GC roots).
      var callArgs = newSeq[VmVal](argc)
      for i in 0 ..< argc:
        callArgs[i] = regs[base + 1 + i]
      let runFn = parentVal.fn
      let runEnv = parentVal.env
      # IMPORTANT: unlike NewInvoke's construct path, Op::SuperCall calls
      # regs[base] DIRECTLY (interpreter.zc ~6304 zjs_call_value_with_this) —
      # it does NOT skip default-derived forwarders for the call (that skip
      # only serves brand install). A default-derived parent has an empty body
      # (LoadCallee; Return) that never calls super, so the reference's
      # "must call super before return" gate THROWS. We don't model that throw
      # (and a normal one-level `extends RealCtor` never hits it), so a
      # default-derived DIRECT parent is out of scope → bail (never a wrong
      # value). A nested chain where each level has an EXPLICIT super still
      # works: each ctor's parent is a real ctor, resolved uniformly here.
      if runFn.isDefaultDerivedCtor:
        bail("SuperCall parent is a default-derived ctor (reference throws)")
      # Arrow / async / generator are not constructors → bail (a class ctor
      # or plain function is fine, matching NewInvoke's constructability rule).
      if runFn.isArrow or runFn.isAsync or runFn.isGenerator:
        bail("SuperCall parent is arrow / async / generator")
      # Call the parent ctor with `this` = the SHARED instance (thisVal). It
      # runs its body (this.x=... StoreProp / field inits) on the existing
      # object — no new allocation. thisVal is already this frame's rooted
      # receiver (FrameRoot.thisv), so it survives any collect the parent
      # ctor triggers; callArgs live in the callee frame's regs (also roots).
      var superResult: VmVal
      routeThrow: superResult = callFunction(runFn, callArgs, globals, heap, depth,
                                             thisVal, vv(runEnv))
      # ECMA-262 §13.3.7.1: super() evaluates to the `this` binding. Our
      # in-scope parent ctors return undefined (a primitive) → ignored; the
      # result register receives the instance. A parent that returns an
      # OBJECT would rebind `this` to it (not modeled here) → bail rather than
      # store the derived ctor's later fields on the wrong instance.
      if isObjectResult(superResult):
        bail("SuperCall parent ctor returned an object (this-rebind unsupported)")
      regs[dst] = thisVal
      maybeCollect(heap)

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
