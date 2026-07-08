## NaN-boxed JS value. Idiomatic Nim core (systems register). Mirrors
## src/value.zc bit-for-bit; the golden rule permits perf re-tuning in
## Phase 7. ZjsValue is a single uint64 wrapped in a distinct-ish object
## so the C-ABI shim can hand it across the boundary unchanged.

type
  ZjsValue* {.bycopy.} = object
    bits*: uint64

const
  NUMBER_TAG*           = 0xfffe'u64 shl 48
  DOUBLE_ENCODE_OFFSET* = 1'u64 shl 49
  NOT_CELL_MASK*        = NUMBER_TAG or 2'u64
  VALUE_NULL*           = 2'u64
  VALUE_UNDEFINED*      = 10'u64
  VALUE_FALSE*          = 6'u64
  VALUE_TRUE*           = 7'u64
  VALUE_DELETED*        = 0x10002'u64   ## the "hole" sentinel (zjs_deleted)

# --- bit casts ---
proc doubleToBits(d: float64): uint64 {.inline.} = cast[uint64](d)
proc bitsToDouble(b: uint64): float64 {.inline.} = cast[float64](b)

# --- constructors ---
proc int32Val*(i: int32): ZjsValue {.inline.} =
  ZjsValue(bits: NUMBER_TAG or uint64(cast[uint32](i)))

proc doubleVal*(d: float64): ZjsValue {.inline.} =
  ZjsValue(bits: doubleToBits(d) + DOUBLE_ENCODE_OFFSET)

proc boolVal*(b: bool): ZjsValue {.inline.} =
  ZjsValue(bits: if b: VALUE_TRUE else: VALUE_FALSE)

proc nullVal*(): ZjsValue {.inline.} = ZjsValue(bits: VALUE_NULL)
proc undefinedVal*(): ZjsValue {.inline.} = ZjsValue(bits: VALUE_UNDEFINED)
proc deletedVal*(): ZjsValue {.inline.} = ZjsValue(bits: VALUE_DELETED)

# --- predicates ---
proc isInt32*(v: ZjsValue): bool {.inline.} =
  (v.bits and NUMBER_TAG) == NUMBER_TAG
proc isNumber*(v: ZjsValue): bool {.inline.} =
  (v.bits and NUMBER_TAG) != 0
proc isDouble*(v: ZjsValue): bool {.inline.} =
  isNumber(v) and not isInt32(v)
proc isBool*(v: ZjsValue): bool {.inline.} =
  (v.bits and not 1'u64) == VALUE_FALSE
proc isNull*(v: ZjsValue): bool {.inline.} = v.bits == VALUE_NULL
proc isUndefined*(v: ZjsValue): bool {.inline.} = v.bits == VALUE_UNDEFINED
proc isHole*(v: ZjsValue): bool {.inline.} = v.bits == VALUE_DELETED
proc isCell*(v: ZjsValue): bool {.inline.} =
  (v.bits and NOT_CELL_MASK) == 0

# --- unboxers (UB if the matching predicate is false, as in Zen-c) ---
proc asInt32*(v: ZjsValue): int32 {.inline.} = cast[int32](uint32(v.bits))
proc asDouble*(v: ZjsValue): float64 {.inline.} =
  bitsToDouble(v.bits - DOUBLE_ENCODE_OFFSET)
proc asBool*(v: ZjsValue): cint {.inline.} = cint(v.bits and 1'u64)
