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
