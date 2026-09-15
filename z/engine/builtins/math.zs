// Math: constants and the functions of the C math library, plus a
// xorshift random source seeded per runtime.
import { thread } from "std/thread";
import { Value, undefinedValue, booleanValue, int32Value, doubleValue, cellValue, isNumber, isInt32, asInt32 } from "../value.zs";
import { PROP_METHOD, PROP_NONE, PROP_CONFIGURABLE } from "../heap.zs";
import { Runtime, toNumber, toInt32, toUint32, isIntegralDouble, truncateDouble } from "../runtime.zs";

function nativeMath1(op: i32, x: f64): f64 = raw c {
  switch (op) {
    case 0: return __builtin_fabs(x);
    case 1: return __builtin_floor(x);
    case 2: return __builtin_ceil(x);
    case 3: return __builtin_sqrt(x);
    case 4: return __builtin_sin(x);
    case 5: return __builtin_cos(x);
    case 6: return __builtin_tan(x);
    case 7: return __builtin_asin(x);
    case 8: return __builtin_acos(x);
    case 9: return __builtin_atan(x);
    case 10: return __builtin_exp(x);
    case 11: return __builtin_log(x);
    case 12: return __builtin_log2(x);
    case 13: return __builtin_log10(x);
    case 14: return __builtin_log1p(x);
    case 15: return __builtin_expm1(x);
    case 16: return __builtin_sinh(x);
    case 17: return __builtin_cosh(x);
    case 18: return __builtin_tanh(x);
    case 19: return __builtin_asinh(x);
    case 20: return __builtin_acosh(x);
    case 21: return __builtin_atanh(x);
    case 22: return __builtin_cbrt(x);
    case 23: return __builtin_trunc(x);
    case 24: return (double)(float)x;
    default: return x;
  }
}
function nativeMath2(op: i32, x: f64, y: f64): f64 = raw c {
  switch (op) {
    case 0: return __builtin_pow(x, y);
    case 1: return __builtin_atan2(x, y);
    case 2: return __builtin_hypot(x, y);
    default: return x;
  }
}
function nativeNan(): f64 = raw c { return __builtin_nan(""); }
// One xorshift64 step; the left shift discards the bits that leave
// the word.
function nativeXorshift(state: u64): u64 {
  let next = state ^ (state >> 12);
  next = next ^ next.wrappingShiftLeft(25);
  next = next ^ (next >> 27);
  return next;
}

const MATH_ABS: i32 = 0;
const MATH_FLOOR: i32 = 1;
const MATH_CEIL: i32 = 2;
const MATH_SQRT: i32 = 3;
const MATH_SIN: i32 = 4;
const MATH_COS: i32 = 5;
const MATH_TAN: i32 = 6;
const MATH_ASIN: i32 = 7;
const MATH_ACOS: i32 = 8;
const MATH_ATAN: i32 = 9;
const MATH_EXP: i32 = 10;
const MATH_LOG: i32 = 11;
const MATH_LOG2: i32 = 12;
const MATH_LOG10: i32 = 13;
const MATH_LOG1P: i32 = 14;
const MATH_EXPM1: i32 = 15;
const MATH_SINH: i32 = 16;
const MATH_COSH: i32 = 17;
const MATH_TANH: i32 = 18;
const MATH_ASINH: i32 = 19;
const MATH_ACOSH: i32 = 20;
const MATH_ATANH: i32 = 21;
const MATH_CBRT: i32 = 22;
const MATH_TRUNC: i32 = 23;
const MATH_FROUND: i32 = 24;

// A result as the engine represents numbers: int32 when exact.
function numberValue(number: f64): Value {
  if (number >= -2147483648.0 && number <= 2147483647.0 && isIntegralDouble(number)) {
    if (number == 0.0 && 1.0 / number < 0.0) return doubleValue(number);
    return int32Value(i32(number));
  }
  return doubleValue(number);
}

function numberArgument(inout runtime: Runtime, argsBase: u32, argc: u32, index: u32): f64 {
  return runtime.toNumberValue(runtime.argument(argsBase, argc, index));
}

// The one-argument functions share a body; slot 0 of the callee holds the
// operation.
function mathUnary(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const op = asInt32(runtime.heap.slot(callee, 0));
  const x = numberArgument(inout runtime, argsBase, argc, 0);
  if (runtime.pendingThrow) return undefinedValue();
  return numberValue(nativeMath1(op, x));
}

function mathRound(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const x = numberArgument(inout runtime, argsBase, argc, 0);
  if (runtime.pendingThrow) return undefinedValue();
  if (x != x || x == 1.0 / 0.0 || x == -1.0 / 0.0 || x == 0.0) return doubleValue(x);
  // Round half toward +Infinity without adding 0.5, which rounds wrongly
  // near 2^52; -0 for values in (-0.5, -0].
  const floored = nativeMath1(MATH_FLOOR, x);
  const rounded = x - floored >= 0.5 ? floored + 1.0 : floored;
  if (rounded == 0.0 && x < 0.0) return doubleValue(-0.0);
  return numberValue(rounded);
}

function mathSign(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const x = numberArgument(inout runtime, argsBase, argc, 0);
  if (runtime.pendingThrow) return undefinedValue();
  if (x != x || x == 0.0) return doubleValue(x);
  return int32Value(x > 0.0 ? 1 : -1);
}

function mathPow(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const x = numberArgument(inout runtime, argsBase, argc, 0);
  if (runtime.pendingThrow) return undefinedValue();
  const y = numberArgument(inout runtime, argsBase, argc, 1);
  if (runtime.pendingThrow) return undefinedValue();
  // ECMAScript: an exponent of NaN, or a base of +-1 with an infinite
  // exponent, is NaN where C says otherwise.
  if (y != y) return doubleValue(nativeNan());
  if ((x == 1.0 || x == -1.0) && (y == 1.0 / 0.0 || y == -1.0 / 0.0)) return doubleValue(nativeNan());
  return numberValue(nativeMath2(0, x, y));
}

function mathAtan2(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const y = numberArgument(inout runtime, argsBase, argc, 0);
  if (runtime.pendingThrow) return undefinedValue();
  const x = numberArgument(inout runtime, argsBase, argc, 1);
  if (runtime.pendingThrow) return undefinedValue();
  return numberValue(nativeMath2(1, y, x));
}

function mathHypot(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  // Every argument is coerced before any is judged.
  let numbers = Array<f64>();
  let index: u32 = 0;
  while (index < argc) {
    const x = numberArgument(inout runtime, argsBase, argc, index);
    if (runtime.pendingThrow) return undefinedValue();
    numbers.push(x);
    index = index + 1;
  }
  let sum: f64 = 0.0;
  let sawNaN = false;
  let i: usize = 0;
  while (i < numbers.length) {
    const x = numbers[i];
    if (x == 1.0 / 0.0 || x == -1.0 / 0.0) return doubleValue(1.0 / 0.0);
    if (x != x) sawNaN = true;
    sum = sum + x * x;
    i = i + 1;
  }
  if (sawNaN) return doubleValue(nativeNan());
  return numberValue(nativeMath1(MATH_SQRT, sum));
}

function mathMax(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  let best: f64 = -1.0 / 0.0;
  let index: u32 = 0;
  let sawNaN = false;
  while (index < argc) {
    const x = numberArgument(inout runtime, argsBase, argc, index);
    if (runtime.pendingThrow) return undefinedValue();
    if (x != x) sawNaN = true;
    if (x > best || (x == 0.0 && best == 0.0 && 1.0 / best < 0.0)) best = x;
    index = index + 1;
  }
  if (sawNaN) return doubleValue(nativeNan());
  return numberValue(best);
}

function mathMin(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  let best: f64 = 1.0 / 0.0;
  let index: u32 = 0;
  let sawNaN = false;
  while (index < argc) {
    const x = numberArgument(inout runtime, argsBase, argc, index);
    if (runtime.pendingThrow) return undefinedValue();
    if (x != x) sawNaN = true;
    if (x < best || (x == 0.0 && best == 0.0 && 1.0 / x < 0.0)) best = x;
    index = index + 1;
  }
  if (sawNaN) return doubleValue(nativeNan());
  return numberValue(best);
}

function mathClz32(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const x = numberArgument(inout runtime, argsBase, argc, 0);
  if (runtime.pendingThrow) return undefinedValue();
  let bits = toUint32(doubleValue(x));
  if (bits == 0) return int32Value(32);
  let count: i32 = 0;
  while ((bits & 0x80000000) == 0) {
    bits = bits << 1;
    count = count + 1;
  }
  return int32Value(count);
}

function mathImul(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const a = numberArgument(inout runtime, argsBase, argc, 0);
  if (runtime.pendingThrow) return undefinedValue();
  const b = numberArgument(inout runtime, argsBase, argc, 1);
  if (runtime.pendingThrow) return undefinedValue();
  const product = toUint32(doubleValue(a)).wrappingMultiply(toUint32(doubleValue(b)));
  return int32Value(i32.fromBits(product));
}

// xorshift64*: enough for Math.random; not a cryptographic source.
function mathRandom(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const state = nativeXorshift(runtime.randomState);
  runtime.randomState = state;
  const mixed = state.wrappingMultiply(0x2545F4914F6CDD1D);
  const mantissa = mixed >> 11;
  return doubleValue(f64(mantissa) / 9007199254740992.0);
}

function defineUnary(inout runtime: Runtime, target: u32, in name: String, op: i32): void {
  const handle = runtime.defineHostFunction(mathUnary, int32Value(op), 1, in name);
  const atom = runtime.atomOf(in name);
  runtime.defineOwnAttr(target, atom, cellValue(handle), PROP_METHOD);
}

function defineConstant(inout runtime: Runtime, target: u32, in name: String, value: f64): void {
  const atom = runtime.atomOf(in name);
  runtime.defineOwnAttr(target, atom, doubleValue(value), PROP_NONE);
}

export function installMath(inout runtime: Runtime): void {
  const objectProto = runtime.objectProto;
  const math = runtime.heap.allocateObject(objectProto);
  runtime.setGlobal("Math", cellValue(math));
  const tagText: String = "Math";
  const tagValue = runtime.internText(in tagText);
  const symbolToStringTag = runtime.symbolToStringTag;
  const tagKey = runtime.propertyKey(symbolToStringTag);
  runtime.heap.objectDefine(math, tagKey, tagValue, PROP_CONFIGURABLE);
  const eText: String = "E";
  defineConstant(inout runtime, math, in eText, 2.718281828459045);
  const ln10Text: String = "LN10";
  defineConstant(inout runtime, math, in ln10Text, 2.302585092994046);
  const ln2Text: String = "LN2";
  defineConstant(inout runtime, math, in ln2Text, 0.6931471805599453);
  const log10eText: String = "LOG10E";
  defineConstant(inout runtime, math, in log10eText, 0.4342944819032518);
  const log2eText: String = "LOG2E";
  defineConstant(inout runtime, math, in log2eText, 1.4426950408889634);
  const piText: String = "PI";
  defineConstant(inout runtime, math, in piText, 3.141592653589793);
  const sqrt1_2Text: String = "SQRT1_2";
  defineConstant(inout runtime, math, in sqrt1_2Text, 0.7071067811865476);
  const sqrt2Text: String = "SQRT2";
  defineConstant(inout runtime, math, in sqrt2Text, 1.4142135623730951);
  const absText: String = "abs"; defineUnary(inout runtime, math, in absText, MATH_ABS);
  const floorText: String = "floor"; defineUnary(inout runtime, math, in floorText, MATH_FLOOR);
  const ceilText: String = "ceil"; defineUnary(inout runtime, math, in ceilText, MATH_CEIL);
  const sqrtText: String = "sqrt"; defineUnary(inout runtime, math, in sqrtText, MATH_SQRT);
  const sinText: String = "sin"; defineUnary(inout runtime, math, in sinText, MATH_SIN);
  const cosText: String = "cos"; defineUnary(inout runtime, math, in cosText, MATH_COS);
  const tanText: String = "tan"; defineUnary(inout runtime, math, in tanText, MATH_TAN);
  const asinText: String = "asin"; defineUnary(inout runtime, math, in asinText, MATH_ASIN);
  const acosText: String = "acos"; defineUnary(inout runtime, math, in acosText, MATH_ACOS);
  const atanText: String = "atan"; defineUnary(inout runtime, math, in atanText, MATH_ATAN);
  const expText: String = "exp"; defineUnary(inout runtime, math, in expText, MATH_EXP);
  const logText: String = "log"; defineUnary(inout runtime, math, in logText, MATH_LOG);
  const log2Text: String = "log2"; defineUnary(inout runtime, math, in log2Text, MATH_LOG2);
  const log10Text: String = "log10"; defineUnary(inout runtime, math, in log10Text, MATH_LOG10);
  const log1pText: String = "log1p"; defineUnary(inout runtime, math, in log1pText, MATH_LOG1P);
  const expm1Text: String = "expm1"; defineUnary(inout runtime, math, in expm1Text, MATH_EXPM1);
  const sinhText: String = "sinh"; defineUnary(inout runtime, math, in sinhText, MATH_SINH);
  const coshText: String = "cosh"; defineUnary(inout runtime, math, in coshText, MATH_COSH);
  const tanhText: String = "tanh"; defineUnary(inout runtime, math, in tanhText, MATH_TANH);
  const asinhText: String = "asinh"; defineUnary(inout runtime, math, in asinhText, MATH_ASINH);
  const acoshText: String = "acosh"; defineUnary(inout runtime, math, in acoshText, MATH_ACOSH);
  const atanhText: String = "atanh"; defineUnary(inout runtime, math, in atanhText, MATH_ATANH);
  const cbrtText: String = "cbrt"; defineUnary(inout runtime, math, in cbrtText, MATH_CBRT);
  const truncText: String = "trunc"; defineUnary(inout runtime, math, in truncText, MATH_TRUNC);
  const froundText: String = "fround"; defineUnary(inout runtime, math, in froundText, MATH_FROUND);
  const roundText: String = "round"; runtime.defineMethod(math, in roundText, mathRound, 1);
  const signText: String = "sign"; runtime.defineMethod(math, in signText, mathSign, 1);
  const powText: String = "pow"; runtime.defineMethod(math, in powText, mathPow, 2);
  const atan2Text: String = "atan2"; runtime.defineMethod(math, in atan2Text, mathAtan2, 2);
  const hypotText: String = "hypot"; runtime.defineMethod(math, in hypotText, mathHypot, 2);
  const maxText: String = "max"; runtime.defineMethod(math, in maxText, mathMax, 2);
  const minText: String = "min"; runtime.defineMethod(math, in minText, mathMin, 2);
  const clz32Text: String = "clz32"; runtime.defineMethod(math, in clz32Text, mathClz32, 1);
  const imulText: String = "imul"; runtime.defineMethod(math, in imulText, mathImul, 2);
  const randomText: String = "random"; runtime.defineMethod(math, in randomText, mathRandom, 0);
}
