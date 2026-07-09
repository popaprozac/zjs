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
  of vkFunction:
    raise newException(VmBail, "function value")
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

suite "vm function calls (slice 2)":
  test "declared function + InvokeGlobal":
    check ev("function add(a,b){return a+b;} add(3,4)") == "7"
    check ev("function id(x){return x;} id(99)") == "99"
    check ev("function f(a,b,c){return a*100+b*10+c;} f(1,2,3)") == "123"
  test "function expression assigned to var":
    check ev("var f=function(x){return x*x;}; f(5)") == "25"
  test "IIFE":
    check ev("(function(){return 42;})()") == "42"
  test "recursion":
    check ev("function fib(n){ return n<2 ? n : fib(n-1)+fib(n-2); } fib(10)") == "55"
    check ev("function fac(n){ return n<=1?1:n*fac(n-1); } fac(5)") == "120"
    check ev("function fib(n){ return n<2 ? n : fib(n-1)+fib(n-2); } fib(15)") == "610"
  test "zero-arg calls + combining results":
    check ev("function k(){return 7;} k()+k()") == "14"
    check ev("function noret(){} noret()") == "undefined"
  test "tail call (return f())":
    check ev("function outer(){ return inner(); } function inner(){ return 5; } outer()") == "5"
  test "nested calls f(g(x))":
    check ev("function g(x){return x+1;} function f(x){return x*2;} f(g(10))") == "22"
  test "multi-statement body with locals":
    check ev("function f(n){ let a=n+1; let b=a*2; return a+b; } f(3)") == "12"
  test "extra args dropped, missing params undefined":
    check ev("function f(a){return a;} f(1,2,3)") == "1"
    check ev("function f(a,b){return b;} f(7)") == "undefined"

suite "vm string operations (slice 3)":
  test "string concat":
    check ev("\"a\"+\"b\"") == "ab"
    check ev("\"x\"+1") == "x1"
    check ev("1+\"x\"") == "1x"
    check ev("\"num=\"+10") == "num=10"
    check ev("\"a\"+1+2") == "a12"       # left-assoc: ("a"+1)+2
    check ev("1+2+\"a\"") == "3a"        # (1+2)+"a" — numeric then concat
    check ev("\"a\"+(1+2)") == "a3"
  test "ToString in concat (int / bool / null / undefined)":
    check ev("\"\"+42") == "42"
    check ev("\"\"+0") == "0"
    check ev("\"\"+(-5)") == "-5"
    check ev("\"\"+123456789012") == "123456789012"   # integral double
    check ev("\"\"+true") == "true"
    check ev("\"\"+false") == "false"
    check ev("\"\"+null") == "null"
    check ev("\"\"+undefined") == "undefined"
    check ev("\"x\"+true") == "xtrue"
    check ev("\"x\"+null") == "xnull"
  test "ToNumber in arithmetic":
    check ev("\"5\"*2") == "10"
    check ev("\"7\"-2") == "5"
    check ev("\"10\"/2") == "5"
    check ev("\"6\"%4") == "2"
    check ev("\"2\"**3") == "8"
    check ev("\"0x1F\"*1") == "31"       # strtod hex
    check ev("\"  42  \"-0") == "42"     # whitespace trim
    check ev("\"\"-0") == "0"            # empty string → 0
  test "unary plus (ToNumber)":
    check ev("+\"42\"") == "42"
    check ev("+\"  17  \"") == "17"
    check ev("+true") == "1"
    check ev("+false") == "0"
    check ev("+null") == "0"
  test "bool / null arithmetic coercion":
    check ev("true+1") == "2"
    check ev("1+true") == "2"
    check ev("false+1") == "1"
    check ev("null+1") == "1"
    check ev("true-1") == "0"
    check ev("null*3") == "0"
    check ev("~true") == "-2"
    check ev("true|0") == "1"
  test "typeof":
    check ev("typeof 5") == "number"
    check ev("typeof (1+1)") == "number"
    check ev("typeof \"s\"") == "string"
    check ev("typeof \"\"") == "string"
    check ev("typeof true") == "boolean"
    check ev("typeof undefined") == "undefined"
    check ev("typeof null") == "object"
  test "string comparison (lexicographic)":
    check ev("\"a\"<\"b\"") == "true"
    check ev("\"b\"<\"a\"") == "false"
    check ev("\"a\"<=\"a\"") == "true"
    check ev("\"b\">\"a\"") == "true"
    check ev("\"z\"<\"aa\"") == "false"  # 'z'(122) > 'a'(97)
    check ev("\"aa\"<\"z\"") == "true"
  test "string equality":
    check ev("\"abc\"===\"abc\"") == "true"
    check ev("\"abc\"===\"abd\"") == "false"
    check ev("\"a\"!==\"b\"") == "true"
    check ev("\"a\"==\"a\"") == "true"
    check ev("\"a\"!=\"b\"") == "true"
    check ev("\"5\"===5") == "false"     # different type
    check ev("\"5\"==5") == "true"       # loose: ToNumber
    check ev("5==\"5\"") == "true"
    check ev("\"0\"==false") == "true"
  test "mixed string/number comparison (ToNumber)":
    check ev("\"5\"<3") == "false"
    check ev("\"2\"<3") == "true"
    check ev("\"abc\"<5") == "false"     # NaN → false
    check ev("\"5\">3") == "true"
  test "ToBoolean over strings":
    check ev("!\"\"") == "true"
    check ev("!\"x\"") == "false"
    check ev("\"\"?1:2") == "2"
    check ev("\"x\"?1:2") == "1"
    check ev("\"\"||3") == "3"
    check ev("\"x\"||3") == "x"
    check ev("\"x\"&&5") == "5"
    check ev("\"x\"??3") == "x"
  test "template literals":
    check ev("`hello`") == "hello"
    check ev("`a${1+1}b`") == "a2b"
    check ev("`x${\"y\"}z`") == "xyz"
    check ev("`${1}${2}`") == "12"
    check ev("`a${1}b${2}c`") == "a1b2c"
    check ev("`${true}`") == "true"
    check ev("`${null}`") == "null"
    check ev("`n=${10}`") == "n=10"

suite "vm bail discipline":
  test "built-in globals bail (out of slice-1 scope)":
    check bails("NaN")           # LoadGlobal of a built-in slot
    check bails("Infinity")
  test "non-integer-double ToString bails (dtoa deferred)":
    # CRITICAL: must NOT emit "0.333333" — the shortest-round-trip dtoa is
    # a later slice; a wrong result is far worse than a bail.
    check bails("\"\"+(1/3)")
    check bails("\"\"+0.5")
    check bails("0.1+\"\"")
    check bails("`${1/3}`")
    check bails("\"\"+(0.1+0.2)")
  test "property access / built-ins bail":
    check bails("\"foo\".length")   # object model = Phase 5
  test "capturing closures bail (need object model)":
    # inner fn references outer local `x` → needsEnv → resolveCallee bails.
    check bails("function outer(){ var x=1; function inner(){ return x; } return inner(); } outer()")
  test "arrow calls bail (lexical this/env)":
    check bails("var f=()=>1; f()")
  test "method / object calls bail (no object model)":
    check bails("var o={m:function(){return 1;}}; o.m()")
  test "calling a non-function bails":
    check bails("var x=5; x()")
