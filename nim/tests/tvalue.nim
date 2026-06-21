import std/unittest
import ../src/zjs/value

suite "value constructors":
  test "int32 round-trips through encode/decode":
    check isInt32(int32Val(5'i32))
    check asInt32(int32Val(5'i32)) == 5'i32
    check asInt32(int32Val(-1'i32)) == -1'i32
    check asInt32(int32Val(high(int32))) == high(int32)
    check asInt32(int32Val(low(int32))) == low(int32)

  test "double round-trips and is distinct from int32":
    check isDouble(doubleVal(3.5))
    check asDouble(doubleVal(3.5)) == 3.5
    check not isInt32(doubleVal(3.5))
    # A double whose raw bits resemble the int32 tag must NOT decode as int32:
    check not isInt32(doubleVal(-1.7e308))

  test "singletons":
    check isNull(nullVal())
    check isUndefined(undefinedVal())
    check isBool(boolVal(true))
    check isBool(boolVal(false))
    check asBool(boolVal(true)) == 1
    check asBool(boolVal(false)) == 0

suite "value non-aliasing":
  test "NaN double round-trips and does not read as int32":
    let nan = doubleVal(0.0/0.0)
    check isDouble(nan)
    check not isInt32(nan)
    check asDouble(nan) != asDouble(nan)   # NaN != NaN

  test "+Inf / -Inf round-trip":
    check asDouble(doubleVal(1.0/0.0)) == 1.0/0.0
    check asDouble(doubleVal(-1.0/0.0)) == -1.0/0.0

  test "zero and negative-zero":
    check asDouble(doubleVal(0.0)) == 0.0
    check asDouble(doubleVal(-0.0)) == 0.0
    # sign bit preserved on -0.0
    check cast[uint64](asDouble(doubleVal(-0.0))) == cast[uint64](-0.0)

  test "singletons are mutually distinct and not numbers/cells":
    for v in [nullVal(), undefinedVal(), boolVal(true), boolVal(false)]:
      check not isNumber(v)
      check not isCell(v)
    check nullVal().bits != undefinedVal().bits
    check boolVal(true).bits != boolVal(false).bits

  test "every int32 boundary decodes exactly":
    for i in [0'i32, 1'i32, -1'i32, high(int32), low(int32), 1234567'i32, -7654321'i32]:
      check isInt32(int32Val(i))
      check asInt32(int32Val(i)) == i
      check not isDouble(int32Val(i))
