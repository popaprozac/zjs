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
