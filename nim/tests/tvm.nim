## Slice-1 VM tests -- execute a compiled top-level Function and assert
## the printed completion value matches the expected string (the same
## bytes `nim-eval` / `build/zjs eval` would emit). Mirrors the
## tcompiler.nim style (parse+compile), then runs the VM.

import std/[unittest, strformat]
import ../src/zjs/[parser, compiler, vm, value, gc, builtins]

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

proc evB(src: string): string =
  ## Like `ev`, but installs the realm's native built-ins (isNaN/isFinite +
  ## value globals NaN/Infinity) first — Phase 6 slice 2. Threads its own heap
  ## so the native cells stay rooted via `globals` for the run.
  var p = initParser(src)
  let root = p.parseProgram()
  check (not p.hadError)
  let f = compileProgram(src, root)
  check f != nil
  var globals: seq[VmVal] = @[]
  var heap = newGcHeap()
  installBuiltins(globals, heap)
  result = render(runFunction(f, globals, heap, 0))
  destroyHeap(heap)

proc bailsB(src: string): bool =
  ## True if `src` bails WITH built-ins installed (an unimplemented builtin or
  ## a deferred arg shape — a clean bail, never a wrong value).
  var p = initParser(src)
  let root = p.parseProgram()
  if p.hadError: return true
  let f = compileProgram(src, root)
  if f == nil: return true
  var globals: seq[VmVal] = @[]
  var heap = newGcHeap()
  installBuiltins(globals, heap)
  try:
    discard render(runFunction(f, globals, heap, 0))
    destroyHeap(heap)
    return false
  except VmBail:
    destroyHeap(heap)
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

suite "vm object model (slice B1)":
  test "object literal property read":
    check ev("({a:1}).a") == "1"
    check ev("({a:1,b:2}).b") == "2"
    check ev("({a:{b:7}}).a.b") == "7"
  test "object property store then read":
    check ev("var o={}; o.x=5; o.x") == "5"
    check ev("var o={a:1}; o.a=o.a+1; o.a") == "2"
    check ev("var o={a:1,b:2,c:3}; o.a+o.b+o.c") == "6"
  test "missing property is undefined":
    check ev("({x:1}).y") == "undefined"
  test "array literal indexed read":
    check ev("[10,20,30][1]") == "20"
    check ev("[[1],[2]][1][0]") == "2"
  test "array length":
    check ev("var a=[1,2,3]; a.length") == "3"
  test "array element store then read":
    check ev("var a=[]; a[0]=9; a[0]") == "9"
    check ev("var a=[5]; a[0]=a[0]*2; a[0]") == "10"
  test "out-of-range array read is undefined":
    check ev("[1,2,3][5]") == "undefined"
  test "objects survive allocation churn (GC under eval)":
    # `o` is held in a var while 100k throwaway objects are allocated in a
    # loop — o.a must still read 1 (o was never freed while live).
    check ev("var o={a:1}; for(let i=0;i<100000;i=i+1){ var t={x:i}; } o.a") == "1"
    # Same for an array held across churn.
    check ev("var a=[7]; for(let i=0;i<100000;i=i+1){ var t=[i,i+1]; } a[0]") == "7"

suite "vm bail discipline":
  test "built-in globals bail (out of slice-1 scope)":
    check bails("NaN")           # LoadGlobal of a built-in slot
    check bails("Infinity")
  test "non-integer-double ToString: shortest-round-trip dtoa (Phase 6 slice 3)":
    # js_double_to_chars port: full-precision shortest round-trip, NOT
    # "%g"'s "0.333333". Byte-identical to the oracle (see the fuzz sweep).
    check ev("\"\"+(1/3)") == "0.3333333333333333"
    check ev("\"\"+0.5") == "0.5"
    check ev("0.1+\"\"") == "0.1"
    check ev("`${1/3}`") == "0.3333333333333333"
    check ev("\"\"+(0.1+0.2)") == "0.30000000000000004"
    # fixed-vs-exponential boundaries + JS-shaped exponent
    check ev("\"\"+1e21") == "1e+21"
    check ev("\"\"+0.0000001") == "1e-7"
    check ev("\"\"+1e20") == "100000000000000000000"
    # integral double past the %lld window prints exact (%.0f), not
    # shortest-round-trip: 86161958985030656 stays exact.
    check ev("\"\"+86161958985030656") == "86161958985030656"
  test "string property access + methods resolve (Phase 6 String)":
    check evB("\"foo\".length") == "3"
    check evB("\"foo\".toUpperCase()") == "FOO"
    check evB("\"a,b,c\".split(\",\").length") == "3"
  test "arrow calls bail (lexical this/env)":
    check bails("var f=()=>1; f()")
  test "calling a non-function bails":
    check bails("var x=5; x()")

suite "vm closures + this (slice B2)":
  test "capturing closure reads an outer local through its env":
    # inner fn references outer local `x` → needsEnv closure carrying an env
    # object {x:1}; calling it seeds frame.env, LoadEnv+LoadProp read x.
    check ev("function outer(){ var x=1; function inner(){ return x; } return inner(); } outer()") == "1"
    check ev("function o(){ let x=10; return function(){ return x; }; } o()()") == "10"
    check ev("function mk(n){ return function(){ return n; }; } mk(7)()") == "7"
    check ev("function add(a){ return function(b){ return a+b; }; } add(3)(4)") == "7"
    check ev("function o(){ let x=1; let y=2; return function(){ return x+y; }; } o()()") == "3"
  test "closure mutates its captured var (shared env across calls)":
    check ev("function counter(){ let c=0; return function(){ c=c+1; return c; }; } var f=counter(); f(); f(); f()") == "3"
  test "method call binds `this` to the receiver":
    check ev("var o={m:function(){return 1;}}; o.m()") == "1"
    check ev("var o={x:5, f:function(){ return this.x; }}; o.f()") == "5"
    check ev("var o={a:2,b:3, sum:function(){ return this.a+this.b; }}; o.sum()") == "5"
    check ev("var o={n:10, inc:function(){ this.n=this.n+1; return this.n; }}; o.inc(); o.inc()") == "12"

suite "vm native builtins (Phase 6 slice 2)":
  test "isNaN over the primitive coercion ladder":
    check evB("isNaN(NaN)") == "true"
    check evB("isNaN(5)") == "false"
    check evB("isNaN(0)") == "false"
    check evB("isNaN(3.14)") == "false"
    check evB("isNaN(Infinity)") == "false"
    check evB("isNaN(\"x\")") == "true"
    check evB("isNaN(\"12\")") == "false"
    check evB("isNaN(\"\")") == "false"      # "" → 0 → not NaN
    check evB("isNaN(true)") == "false"
    check evB("isNaN(null)") == "false"
    check evB("isNaN(undefined)") == "true"
    check evB("isNaN()") == "true"           # no args → ToNumber(undefined)=NaN
  test "isFinite over the primitive coercion ladder":
    check evB("isFinite(5)") == "true"
    check evB("isFinite(Infinity)") == "false"
    check evB("isFinite(NaN)") == "false"
    check evB("isFinite(\"100\")") == "true"
    check evB("isFinite()") == "false"       # no args → false
    check evB("isFinite(-Infinity)") == "false"
  test "native called from a JS frame / a loop":
    check evB("var x = isNaN(NaN); x") == "true"
    check evB("function f(n){ return isNaN(n); } f(NaN)") == "true"
    check evB("var s=0; for(var i=0;i<3;i++){ if(!isNaN(i)) s=s+i; } s") == "3"
    check evB("isNaN(2+3)") == "false"
  test "native round-trips through an object property / array element":
    check evB("var o={f:isNaN}; o.f(NaN)") == "true"   # MethodInvoke native
    check evB("var a=[isNaN]; a[0](NaN)") == "true"    # Invoke after LoadElem
  test "value globals NaN / Infinity resolve":
    check evB("NaN") == "NaN"
    check evB("Infinity") == "Infinity"
  test "deferred / unimplemented shapes bail cleanly (never wrong)":
    check bailsB("isNaN({})")             # object arg needs valueOf coercion
    check bailsB("isNaN([])")             # array arg needs ToPrimitive
    check bailsB("Math.max(1,{})")        # object arg needs ToPrimitive
    check bailsB("Math.sumPrecise([1,2])")# TC39 proposal: iterator drain deferred
    check bailsB("\"abc\".replace(\"a\",\"z\")") # String.prototype.replace deferred
    check bailsB("new isNaN()")           # native constructor is a later slice

  # --- Math (Phase 6): namespace object @ g56 ------------------------
  # Fast-path fused ops (MathSqrt/Abs/Floor/Ceil), native methods via
  # MethodInvoke, and numeric constants. Full oracle parity is proven by the
  # eval battery + transcendental fuzz; these are the in-suite smoke checks.
  test "Math: fast-path ops + native methods + constants + edges":
    check evB("Math.floor(1.5)") == "1"          # MathFloor fusion
    check evB("Math.ceil(1.2)") == "2"           # MathCeil fusion
    check evB("Math.abs(-5)") == "5"             # MathAbs fusion, int32
    check evB("Math.sqrt(2)") == "1.41421"       # MathSqrt fusion (%g)
    check evB("Math.max(1,2,3)") == "3"          # native, identity=-Inf
    check evB("Math.max()") == "-Infinity"
    check evB("Math.min(-1,NaN,2)") == "NaN"     # NaN propagation
    check evB("Math.round(-2.5)") == "-2"        # half toward +Inf
    check evB("Math.round(-0.5)") == "-0"        # negative-zero result
    check evB("Math.sign(-3)") == "-1"
    check evB("Math.pow(2,10)") == "1024"
    check evB("Math.hypot(3,4)") == "5"
    check evB("Math.cbrt(27)") == "3"
    check evB("Math.clz32(1)") == "31"
    check evB("Math.imul(3,4)") == "12"
    check evB("''+Math.PI") == "3.141592653589793"
    check evB("''+Math.E") == "2.718281828459045"
    check evB("''+Math.SQRT2") == "1.4142135623730951"
    check evB("var s=0; for(var i=0;i<5;i++){ s+=Math.floor(i+0.5); } s") == "10"
