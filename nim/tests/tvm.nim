## Slice-1 VM tests -- execute a compiled top-level Function and assert
## the printed completion value matches the expected string (the same
## bytes `nim-eval` / `build/zjs eval` would emit). Mirrors the
## tcompiler.nim style (parse+compile), then runs the VM.

import std/[unittest, strformat]
import ../src/zjs/[parser, compiler, vm, value]

# Local copy of printValue (nim_eval.nim) so tests can assert on the
# string. Kept in sync with tools/nim_eval.nim.
proc render(x: VmVal): string =
  case x.kind
  of vkString:
    return x.s
  of vkVal:
    let v = x.v
    if isInt32(v): return $asInt32(v)
    if isDouble(v):
      let d = asDouble(v)
      if d != d: return "NaN"
      if d == Inf: return "Infinity"
      if d == NegInf: return "-Infinity"
      return &"{d:g}"
    if isBool(v): return (if asBool(v) != 0: "true" else: "false")
    if isNull(v): return "null"
    if isUndefined(v): return "undefined"
    raise newException(VmBail, "non-primitive")

proc ev(src: string): string =
  ## Parse+compile+execute `src`, return the rendered completion value.
  var p = initParser(src)
  let root = p.parseProgram()
  check (not p.hadError)
  let f = compileProgram(src, root)
  check f != nil
  var globals: seq[VmVal] = @[]
  render(runFunction(f, globals))

proc bails(src: string): bool =
  ## True if executing `src` raises VmBail (the honest can't-run signal).
  var p = initParser(src)
  let root = p.parseProgram()
  if p.hadError: return true
  let f = compileProgram(src, root)
  if f == nil: return true
  var globals: seq[VmVal] = @[]
  try:
    discard render(runFunction(f, globals))
    return false
  except VmBail:
    return true

suite "vm arithmetic":
  test "integer add/sub/mul":
    check ev("1+2") == "3"
    check ev("40+2") == "42"
    check ev("2*3+4") == "10"
    check ev("(1+2)*3") == "9"
    check ev("100-1") == "99"
  test "division and modulo":
    check ev("10/2") == "5"
    check ev("1/3") == "0.333333"
    check ev("10%3") == "1"
    check ev("-5%3") == "-2"
    check ev("5%-3") == "2"
  test "power":
    check ev("2**53") == "9.0072e+15"
    check ev("3**2") == "9"
    check ev("2**-1") == "0.5"
  test "negation and -0":
    check ev("-5") == "-5"
    check ev("-0") == "-0"
    check ev("0*-1") == "0"
  test "int32 overflow promotes to double":
    check ev("2147483647+1") == "2.14748e+09"
    check ev("1000000*1000000") == "1e+12"
    check ev("-2147483648-1") == "-2.14748e+09"
  test "double literals and special values":
    check ev("1.5") == "1.5"
    check ev("0.1+0.2") == "0.3"
    check ev("1/0") == "Infinity"
    check ev("1/0*-1") == "-Infinity"

suite "vm comparison":
  test "relational":
    check ev("1<2") == "true"
    check ev("5>3") == "true"
    check ev("10>=10") == "true"
    check ev("10<=9") == "false"
  test "equality":
    check ev("1===1") == "true"
    check ev("1!==2") == "true"
    check ev("5!=5") == "false"
    check ev("5!==5.0") == "false"
    check ev("0.5===0.5") == "true"

suite "vm bitwise / logical":
  test "bitwise ops":
    check ev("~5") == "-6"
    check ev("1&3") == "1"
    check ev("8>>1") == "4"
    check ev("1<<31") == "-2147483648"
    check ev("3.9|0") == "3"
    check ev("-1>>>0") == "4.29497e+09"
  test "logical not":
    check ev("!true") == "false"
    check ev("!0") == "true"

suite "vm literals":
  test "primitives":
    check ev("true") == "true"
    check ev("false") == "false"
    check ev("null") == "null"
    check ev("undefined") == "undefined"
  test "string constant prints unquoted":
    check ev("\"hi\"") == "hi"
  test "large int constant":
    check ev("100000") == "100000"

suite "vm control flow":
  test "conditional expression":
    check ev("1?2:3") == "2"
    check ev("0?2:3") == "3"
    check ev("5>3?1:0") == "1"
    check ev("1<2?3<4?10:20:30") == "10"
  test "logical short-circuit":
    check ev("1&&2") == "2"
    check ev("0||5") == "5"
    check ev("null??3") == "3"
    check ev("1??2") == "1"
  test "while loop":
    check ev("var i=0; while(i<5){i=i+1} i") == "5"
  test "for loop (fused compare-and-branch)":
    check ev("var s=0; for(var k=0;k<10;k=k+1){s=s+k} s") == "45"
    check ev("var n=0; for(var k=0;k<100;k=k+1){ if(k%2===0){n=n+1} } n") == "50"

suite "vm bindings":
  test "let and var":
    check ev("let x=40; x+2") == "42"
    check ev("var a=1; a=a+1; a") == "2"
    check ev("let a=1,b=2,c=3; a+b*c") == "7"

suite "vm bail discipline":
  test "built-in globals bail (out of slice-1 scope)":
    check bails("NaN")           # LoadGlobal of a built-in slot
    check bails("Infinity")
  test "string operations bail":
    check bails("\"a\"+\"b\"")   # string concat = slice 3
