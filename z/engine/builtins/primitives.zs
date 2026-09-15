// Boolean, Number, and String: constructors, wrappers, and prototypes.
//
// Strings are byte strings, as in the reference: `length`, indexing, and
// every method here count bytes.
import { thread } from "std/thread";
import { Value, undefinedValue, booleanValue, int32Value, doubleValue, cellValue, asCell, isCell, isUndefined, isNull, isDeleted, isNumber, isBoolean, isTrue, isInt32, asInt32, asDouble } from "../value.zs";
import { Runtime, ERROR_KIND_RANGE, toNumber, toInt32, isIntegralDouble, truncateDouble, int32ToString, doubleToString, stringToNumber, utf8SequenceLength } from "../runtime.zs";
import { bytesOf, PROP_METHOD, PROP_NONE } from "../heap.zs";

function nativeAlloc(count: usize): usize = raw c { return (uintptr_t)calloc(count, 1); }
function nativeFree(buffer: usize): void = raw c { free((void *)buffer); }
function nativeReadByte(buffer: usize, index: usize): u8 = raw c { return ((const uint8_t *)buffer)[index]; }
function nativeFormatFixed(buffer: usize, value: f64, digits: i32): i32 = raw c {
  return snprintf((char *)buffer, 400, "%.*f", (int)digits, value);
}
function nativeFormatExponent(buffer: usize, value: f64, digits: i32): i32 = raw c {
  return snprintf((char *)buffer, 400, "%.*e", (int)digits, value);
}
function nativeFloor(value: f64): f64 = raw c { return __builtin_floor(value); }
function nativeNan(): f64 = raw c { return __builtin_nan(""); }

function bytesOfText(in text: String): Array<u8> {
  return bytesOf(in text);
}

function textValue(inout runtime: Runtime, in text: String): Value {
  return runtime.newString(bytesOf(in text));
}

// Read a formatted native buffer back as bytes.
function bufferBytes(buffer: usize, count: i32): Array<u8> {
  let bytes = Array<u8>();
  let index: usize = 0;
  while (index < usize(count)) {
    bytes.push(nativeReadByte(buffer, index));
    index = index + 1;
  }
  return bytes;
}

// --- this-value coercion ---

// The primitive behind `this`: itself, or a wrapper's content. The deleted
// marker means neither.
function thisPrimitive(in runtime: Runtime, thisValue: Value): Value {
  if (isCell(thisValue) && asCell(thisValue) != 0 && runtime.heap.isObject(asCell(thisValue))) {
    return runtime.wrappedPrimitive(asCell(thisValue));
  }
  return thisValue;
}

function thisNumber(inout runtime: Runtime, thisValue: Value, in method: String): f64 {
  const primitive = thisPrimitive(in runtime, thisValue);
  if (isNumber(primitive)) return toNumber(primitive);
  const message: String = `Number.prototype.${method} requires that 'this' be a Number`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return 0.0;
}

function thisBoolean(inout runtime: Runtime, thisValue: Value, in method: String): Value {
  const primitive = thisPrimitive(in runtime, thisValue);
  if (isBoolean(primitive)) return primitive;
  const message: String = `Boolean.prototype.${method} requires that 'this' be a Boolean`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return undefinedValue();
}

// String.prototype methods accept any coercible this; null and undefined
// throw.
function thisString(inout runtime: Runtime, thisValue: Value, in method: String): Array<u8> {
  if (isUndefined(thisValue) || isNull(thisValue)) {
    const message: String = `String.prototype.${method} called on null or undefined`;
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return Array<u8>();
  }
  const primitive = thisPrimitive(in runtime, thisValue);
  const source = isDeleted(primitive) ? thisValue : primitive;
  const text = runtime.toStringValue(source);
  if (runtime.pendingThrow) return Array<u8>();
  return runtime.heap.stringBytes(asCell(text));
}

// An integer argument: ToIntegerOrInfinity clamped to i32, `fallback`
// when undefined.
function integerArgument(inout runtime: Runtime, value: Value, fallback: i32): i32 {
  if (isUndefined(value)) return fallback;
  const number = runtime.toNumberValue(value);
  if (runtime.pendingThrow) return 0;
  if (number != number) return 0;
  if (number <= -2147483648.0) return -2147483648;
  if (number >= 2147483647.0) return 2147483647;
  return i32(truncateDouble(number));
}

// A position argument clamped into [0, length]: negatives are 0.
function clampPosition(index: i32, length: i32): i32 {
  if (index < 0) return 0;
  return index > length ? length : index;
}

function clampIndex(index: i32, length: i32): i32 {
  if (index < 0) {
    const fromEnd = length + index;
    return fromEnd < 0 ? 0 : fromEnd;
  }
  return index > length ? length : index;
}

function numberValue(number: f64): Value {
  if (number >= -2147483648.0 && number <= 2147483647.0 && isIntegralDouble(number)) {
    if (number == 0.0 && 1.0 / number < 0.0) return doubleValue(number);
    return int32Value(i32(number));
  }
  return doubleValue(number);
}

// --- Boolean ---

function constructBoolean(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const value = booleanValue(runtime.toBooleanValue(runtime.argument(argsBase, argc, 0)));
  if (runtime.isObjectLike(thisValue)) {
    const atomPrimitive = runtime.atomPrimitive;
    runtime.heap.objectSet(asCell(thisValue), atomPrimitive, value);
    return thisValue;
  }
  return value;
}

function booleanToString(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "toString";
  const value = thisBoolean(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  return runtime.toStringValue(value);
}

function booleanValueOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "valueOf";
  return thisBoolean(inout runtime, thisValue, in text);
}

// --- Number ---

function constructNumber(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  let value = int32Value(0);
  if (argc > 0) {
    const number = runtime.toNumberValue(runtime.argument(argsBase, argc, 0));
    if (runtime.pendingThrow) return undefinedValue();
    value = numberValue(number);
  }
  if (runtime.isObjectLike(thisValue)) {
    const atomPrimitive = runtime.atomPrimitive;
    runtime.heap.objectSet(asCell(thisValue), atomPrimitive, value);
    return thisValue;
  }
  return value;
}

function numberValueOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "valueOf";
  const number = thisNumber(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  return numberValue(number);
}

// toString(radix): base 10 is the engine's own formatting; other bases
// spell the integer part and up to 20 fraction digits.
function numberToString(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "toString";
  const number = thisNumber(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const radix = integerArgument(inout runtime, runtime.argument(argsBase, argc, 0), 10);
  if (runtime.pendingThrow) return undefinedValue();
  if (radix < 2 || radix > 36) {
    const message: String = "toString() radix must be between 2 and 36";
    const error = runtime.makeError(ERROR_KIND_RANGE, bytesOf(in message));
    runtime.raise(error);
    return undefinedValue();
  }
  if (radix == 10) return runtime.toStringValue(numberValue(number));
  if (number != number) {
    const nanText: String = "NaN";
    return textValue(inout runtime, in nanText);
  }
  if (number == 1.0 / 0.0) {
    const infinityText: String = "Infinity";
    return textValue(inout runtime, in infinityText);
  }
  if (number == -1.0 / 0.0) {
    const negativeInfinityText: String = "-Infinity";
    return textValue(inout runtime, in negativeInfinityText);
  }
  const negative = number < 0.0;
  const magnitude = negative ? -number : number;
  let integerPart = nativeFloor(magnitude);
  let fraction = magnitude - integerPart;
  let digits = Array<u8>();
  if (integerPart == 0.0) {
    digits.push(48);
  } else {
    let reversed = Array<u8>();
    let n = integerPart;
    while (n >= 1.0) {
      const quotient = nativeFloor(n / f64(radix));
      const remainder = i32(n - quotient * f64(radix));
      reversed.push(digitChar(remainder));
      n = quotient;
    }
    let index = reversed.length;
    while (index > 0) {
      index = index - 1;
      digits.push(reversed[index]);
    }
  }
  if (fraction > 0.0) {
    digits.push(46);
    let count: u32 = 0;
    while (fraction > 0.0 && count < 20) {
      fraction = fraction * f64(radix);
      const digit = i32(nativeFloor(fraction));
      digits.push(digitChar(digit));
      fraction = fraction - f64(digit);
      count = count + 1;
    }
  }
  let joined = Array<u8>();
  if (negative) joined.push(45);
  let i: usize = 0;
  while (i < digits.length) {
    joined.push(digits[i]);
    i = i + 1;
  }
  return runtime.newString(move joined);
}

function digitChar(digit: i32): u8 {
  if (digit < 10) return u8(48 + digit);
  return u8(87 + digit);
}

function numberToFixed(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "toFixed";
  const number = thisNumber(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const digits = integerArgument(inout runtime, runtime.argument(argsBase, argc, 0), 0);
  if (runtime.pendingThrow) return undefinedValue();
  if (digits < 0 || digits > 100) {
    const message: String = "toFixed() digits argument must be between 0 and 100";
    const error = runtime.makeError(ERROR_KIND_RANGE, bytesOf(in message));
    runtime.raise(error);
    return undefinedValue();
  }
  if (number != number || number >= 1e21 || number <= -1e21) return runtime.toStringValue(numberValue(number));
  const buffer = nativeAlloc(400);
  const count = nativeFormatFixed(buffer, number, digits);
  const bytes = bufferBytes(buffer, count);
  nativeFree(buffer);
  return runtime.newString(move bytes);
}

function numberIsNaN(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const value = runtime.argument(argsBase, argc, 0);
  return booleanValue(isNumber(value) && toNumber(value) != toNumber(value));
}

function numberIsFinite(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const value = runtime.argument(argsBase, argc, 0);
  if (!isNumber(value)) return booleanValue(false);
  const number = toNumber(value);
  return booleanValue(number == number && number != 1.0 / 0.0 && number != -1.0 / 0.0);
}

function numberIsInteger(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const value = runtime.argument(argsBase, argc, 0);
  if (!isNumber(value)) return booleanValue(false);
  const number = toNumber(value);
  return booleanValue(number == number && number != 1.0 / 0.0 && number != -1.0 / 0.0 && isIntegralDouble(number));
}

function numberIsSafeInteger(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const value = runtime.argument(argsBase, argc, 0);
  if (!isNumber(value)) return booleanValue(false);
  const number = toNumber(value);
  return booleanValue(isIntegralDouble(number) && number <= 9007199254740991.0 && number >= -9007199254740991.0);
}

// --- String ---

function constructString(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  let value = runtime.internValue(Array<u8>());
  if (argc > 0) {
    const first = runtime.argument(argsBase, argc, 0);
    if (runtime.isSymbolValue(first) && !runtime.isObjectLike(thisValue)) {
      value = runtime.symbolDescriptiveString(asCell(first));
    } else {
      value = runtime.toStringValue(first);
      if (runtime.pendingThrow) return undefinedValue();
    }
  }
  if (runtime.isObjectLike(thisValue)) {
    const atomPrimitive = runtime.atomPrimitive;
    runtime.heap.objectSet(asCell(thisValue), atomPrimitive, value);
    return thisValue;
  }
  return value;
}

function stringFromCharCode(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  let bytes = Array<u8>();
  let index: u32 = 0;
  while (index < argc) {
    const number = runtime.toNumberValue(runtime.argument(argsBase, argc, index));
    if (runtime.pendingThrow) return undefinedValue();
    const unit = u32(toInt32(doubleValue(number)).toBits() & 0xFFFF);
    pushUtf8(inout bytes, unit);
    index = index + 1;
  }
  return runtime.newString(move bytes);
}

function pushUtf8(inout bytes: Array<u8>, codePoint: u32): void {
  if (codePoint < 0x80) {
    bytes.push(u8(codePoint));
  } else if (codePoint < 0x800) {
    bytes.push(u8(0xC0 | (codePoint >> 6)));
    bytes.push(u8(0x80 | (codePoint & 0x3F)));
  } else if (codePoint < 0x10000) {
    bytes.push(u8(0xE0 | (codePoint >> 12)));
    bytes.push(u8(0x80 | ((codePoint >> 6) & 0x3F)));
    bytes.push(u8(0x80 | (codePoint & 0x3F)));
  } else {
    bytes.push(u8(0xF0 | (codePoint >> 18)));
    bytes.push(u8(0x80 | ((codePoint >> 12) & 0x3F)));
    bytes.push(u8(0x80 | ((codePoint >> 6) & 0x3F)));
    bytes.push(u8(0x80 | (codePoint & 0x3F)));
  }
}

// String.fromCodePoint: each argument an integral code point, else a
// RangeError.
function stringFromCodePoint(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  let bytes = Array<u8>();
  let index: u32 = 0;
  while (index < argc) {
    const number = runtime.toNumberValue(runtime.argument(argsBase, argc, index));
    if (runtime.pendingThrow) return undefinedValue();
    if (!isIntegralDouble(number) || number < 0.0 || number > 1114111.0) {
      const message: String = "Invalid code point";
      const error = runtime.rangeError(in message);
      runtime.raise(error);
      return undefinedValue();
    }
    pushUtf8(inout bytes, u32(number));
    index = index + 1;
  }
  return runtime.newString(move bytes);
}

// codePointAt(position): the code point whose encoding starts at the
// byte position, else that byte's value.
function stringCodePointAt(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "codePointAt";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const index = integerArgument(inout runtime, runtime.argument(argsBase, argc, 0), 0);
  if (runtime.pendingThrow) return undefinedValue();
  if (index < 0 || usize(index) >= bytes.length) return undefinedValue();
  const at = usize(index);
  const length = utf8SequenceLength(in bytes, at);
  if (length <= 1) return int32Value(i32(bytes[at]));
  let codePoint: u32 = 0;
  if (length == 2) {
    codePoint = (u32(bytes[at]) & 0x1F) << 6 | (u32(bytes[at + 1]) & 0x3F);
  } else if (length == 3) {
    codePoint = (u32(bytes[at]) & 0x0F) << 12 | (u32(bytes[at + 1]) & 0x3F) << 6 | (u32(bytes[at + 2]) & 0x3F);
  } else {
    codePoint = (u32(bytes[at]) & 0x07) << 18 | (u32(bytes[at + 1]) & 0x3F) << 12 | (u32(bytes[at + 2]) & 0x3F) << 6 | (u32(bytes[at + 3]) & 0x3F);
  }
  return int32Value(i32(codePoint));
}

// String.raw(template, ...substitutions): the template's raw strings
// interleaved with the substitutions.
function stringRaw(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const template = runtime.toObjectValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(template);
  const rawText: String = "raw";
  const rawKey = runtime.internText(in rawText);
  const rawValue = runtime.getProperty(template, rawKey);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  const raw = runtime.toObjectValue(rawValue);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  runtime.pushTempRoot(raw);
  const atomLength = runtime.atomLength;
  const lengthValue = runtime.getProperty(raw, cellValue(atomLength));
  let joined = Array<u8>();
  let failed = runtime.pendingThrow;
  if (!failed) {
    const count = runtime.toLength(lengthValue);
    failed = runtime.pendingThrow;
    let index: u32 = 0;
    while (!failed && index < count) {
      const segment = runtime.getProperty(raw, int32Value(i32(index)));
      if (runtime.pendingThrow) { failed = true; break; }
      const segmentText = runtime.toStringValue(segment);
      if (runtime.pendingThrow) { failed = true; break; }
      const segmentBytes = runtime.heap.stringBytes(asCell(segmentText));
      let k: usize = 0;
      while (k < segmentBytes.length) {
        joined.push(segmentBytes[k]);
        k = k + 1;
      }
      if (index + 1 < count && index + 1 < argc) {
        const substitution = runtime.toStringValue(runtime.argument(argsBase, argc, index + 1));
        if (runtime.pendingThrow) { failed = true; break; }
        const substitutionBytes = runtime.heap.stringBytes(asCell(substitution));
        k = 0;
        while (k < substitutionBytes.length) {
          joined.push(substitutionBytes[k]);
          k = k + 1;
        }
      }
      index = index + 1;
    }
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (failed) return undefinedValue();
  return runtime.newString(move joined);
}

function stringToStringMethod(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const primitive = thisPrimitive(in runtime, thisValue);
  if (runtime.isStringValue(primitive)) return primitive;
  const message: String = "String.prototype.toString requires that 'this' be a String";
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return undefinedValue();
}

function stringCharAt(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "charAt";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const index = integerArgument(inout runtime, runtime.argument(argsBase, argc, 0), 0);
  if (runtime.pendingThrow) return undefinedValue();
  let joined = Array<u8>();
  if (index >= 0 && usize(index) < bytes.length) joined.push(bytes[usize(index)]);
  return runtime.newString(move joined);
}

function stringCharCodeAt(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "charCodeAt";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const index = integerArgument(inout runtime, runtime.argument(argsBase, argc, 0), 0);
  if (runtime.pendingThrow) return undefinedValue();
  if (index < 0 || usize(index) >= bytes.length) return doubleValue(nativeNan());
  return int32Value(i32(bytes[usize(index)]));
}

function stringAt(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "at";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  let index = integerArgument(inout runtime, runtime.argument(argsBase, argc, 0), 0);
  if (runtime.pendingThrow) return undefinedValue();
  if (index < 0) index = index + i32(bytes.length);
  if (index < 0 || usize(index) >= bytes.length) return undefinedValue();
  let joined = Array<u8>();
  joined.push(bytes[usize(index)]);
  return runtime.newString(move joined);
}

// The byte offset of `needle` in `haystack` at or after `startAt`, or -1.
function findBytes(in haystack: Array<u8>, in needle: Array<u8>, startAt: usize): i32 {
  if (needle.length == 0) return startAt <= haystack.length ? i32(startAt) : i32(haystack.length);
  if (needle.length > haystack.length) return -1;
  let start = startAt;
  while (start + needle.length <= haystack.length) {
    let matched = true;
    let k: usize = 0;
    while (matched && k < needle.length) {
      if (haystack[start + k] != needle[k]) matched = false;
      k = k + 1;
    }
    if (matched) return i32(start);
    start = start + 1;
  }
  return -1;
}

function argumentBytes(inout runtime: Runtime, value: Value): Array<u8> {
  const text = runtime.toStringValue(value);
  if (runtime.pendingThrow) return Array<u8>();
  return runtime.heap.stringBytes(asCell(text));
}

function stringIndexOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "indexOf";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const needle = argumentBytes(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const startAt = clampIndex(integerArgument(inout runtime, runtime.argument(argsBase, argc, 1), 0), i32(bytes.length));
  if (runtime.pendingThrow) return undefinedValue();
  return int32Value(findBytes(in bytes, in needle, usize(startAt < 0 ? 0 : startAt)));
}

function stringLastIndexOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "lastIndexOf";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const needle = argumentBytes(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  let limit = i32(bytes.length);
  const given = runtime.argument(argsBase, argc, 1);
  if (!isUndefined(given)) {
    const number = runtime.toNumberValue(given);
    if (runtime.pendingThrow) return undefinedValue();
    if (number == number) limit = integerArgument(inout runtime, given, limit);
  }
  if (needle.length > bytes.length) return int32Value(-1);
  let start = i32(bytes.length - needle.length);
  if (limit < start) start = limit;
  while (start >= 0) {
    let matched = true;
    let k: usize = 0;
    while (matched && k < needle.length) {
      if (bytes[usize(start) + k] != needle[k]) matched = false;
      k = k + 1;
    }
    if (matched) return int32Value(start);
    start = start - 1;
  }
  return int32Value(-1);
}

function stringIncludes(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "includes";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const needle = argumentBytes(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const startAt = clampPosition(integerArgument(inout runtime, runtime.argument(argsBase, argc, 1), 0), i32(bytes.length));
  if (runtime.pendingThrow) return undefinedValue();
  return booleanValue(findBytes(in bytes, in needle, usize(startAt)) >= 0);
}

function stringStartsWith(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "startsWith";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const needle = argumentBytes(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const startAt = clampPosition(integerArgument(inout runtime, runtime.argument(argsBase, argc, 1), 0), i32(bytes.length));
  if (runtime.pendingThrow) return undefinedValue();
  if (usize(startAt) + needle.length > bytes.length) return booleanValue(false);
  let k: usize = 0;
  while (k < needle.length) {
    if (bytes[usize(startAt) + k] != needle[k]) return booleanValue(false);
    k = k + 1;
  }
  return booleanValue(true);
}

function stringEndsWith(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "endsWith";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const needle = argumentBytes(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const end = clampPosition(integerArgument(inout runtime, runtime.argument(argsBase, argc, 1), i32(bytes.length)), i32(bytes.length));
  if (runtime.pendingThrow) return undefinedValue();
  if (needle.length > usize(end)) return booleanValue(false);
  const start = usize(end) - needle.length;
  let k: usize = 0;
  while (k < needle.length) {
    if (bytes[start + k] != needle[k]) return booleanValue(false);
    k = k + 1;
  }
  return booleanValue(true);
}

function copyAll(in bytes: Array<u8>): Array<u8> {
  let copied = Array<u8>();
  let index: usize = 0;
  while (index < bytes.length) {
    copied.push(bytes[index]);
    index = index + 1;
  }
  return copied;
}

function sliceFrom(in bytes: Array<u8>, start: usize): Array<u8> {
  let copied = Array<u8>();
  let index = start;
  while (index < bytes.length) {
    copied.push(bytes[index]);
    index = index + 1;
  }
  return copied;
}

function sliceBytes(in bytes: Array<u8>, start: usize, end: usize): Array<u8> {
  let joined = Array<u8>();
  let index = start;
  while (index < end) {
    joined.push(bytes[index]);
    index = index + 1;
  }
  return joined;
}

function stringSlice(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "slice";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const length = i32(bytes.length);
  const start = clampIndex(integerArgument(inout runtime, runtime.argument(argsBase, argc, 0), 0), length);
  if (runtime.pendingThrow) return undefinedValue();
  const end = clampIndex(integerArgument(inout runtime, runtime.argument(argsBase, argc, 1), length), length);
  if (runtime.pendingThrow) return undefinedValue();
  if (end <= start) return runtime.internValue(Array<u8>());
  return runtime.newString(sliceBytes(in bytes, usize(start), usize(end)));
}

function stringSubstring(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "substring";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const length = i32(bytes.length);
  let start = integerArgument(inout runtime, runtime.argument(argsBase, argc, 0), 0);
  if (runtime.pendingThrow) return undefinedValue();
  let end = integerArgument(inout runtime, runtime.argument(argsBase, argc, 1), length);
  if (runtime.pendingThrow) return undefinedValue();
  if (start < 0) start = 0;
  if (start > length) start = length;
  if (end < 0) end = 0;
  if (end > length) end = length;
  if (start > end) {
    const swapped = start;
    start = end;
    end = swapped;
  }
  return runtime.newString(sliceBytes(in bytes, usize(start), usize(end)));
}

function stringSubstr(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "substr";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const length = i32(bytes.length);
  const start = clampIndex(integerArgument(inout runtime, runtime.argument(argsBase, argc, 0), 0), length);
  if (runtime.pendingThrow) return undefinedValue();
  let count = integerArgument(inout runtime, runtime.argument(argsBase, argc, 1), length - start);
  if (runtime.pendingThrow) return undefinedValue();
  if (count < 0) count = 0;
  let end = start + count;
  if (end > length) end = length;
  return runtime.newString(sliceBytes(in bytes, usize(start), usize(end)));
}

function stringConcat(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "concat";
  let bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  let index: u32 = 0;
  while (index < argc) {
    const more = argumentBytes(inout runtime, runtime.argument(argsBase, argc, index));
    if (runtime.pendingThrow) return undefinedValue();
    let k: usize = 0;
    while (k < more.length) {
      bytes.push(more[k]);
      k = k + 1;
    }
    index = index + 1;
  }
  return runtime.newString(move bytes);
}

// The byte length of the WhiteSpace or LineTerminator encoded at
// `index`, or 0: the ASCII set, NBSP, U+1680, U+2000-U+200A, U+2028,
// U+2029, U+202F, U+205F, U+3000, and the BOM.
function spaceLengthAt(in bytes: Array<u8>, index: usize, end: usize): usize {
  const byte = bytes[index];
  if (byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 11 || byte == 12) return 1;
  if (byte < 0x80 || index + 1 >= end) return 0;
  const second = bytes[index + 1];
  if (byte == 0xC2 && second == 0xA0) return 2;
  if (index + 2 >= end) return 0;
  const third = bytes[index + 2];
  if (byte == 0xE1 && second == 0x9A && third == 0x80) return 3;
  if (byte == 0xE2 && second == 0x80 && (third >= 0x80 && third <= 0x8A || third == 0xA8 || third == 0xA9 || third == 0xAF)) return 3;
  if (byte == 0xE2 && second == 0x81 && third == 0x9F) return 3;
  if (byte == 0xE3 && second == 0x80 && third == 0x80) return 3;
  if (byte == 0xEF && second == 0xBB && third == 0xBF) return 3;
  return 0;
}

function trimBytes(in bytes: Array<u8>, leading: boolean, trailing: boolean): Array<u8> {
  let start: usize = 0;
  let end = bytes.length;
  if (leading) {
    while (start < end) {
      const length = spaceLengthAt(in bytes, start, end);
      if (length == 0) break;
      start = start + length;
    }
  }
  if (trailing) {
    while (end > start) {
      // A space ending at `end` starts one to three bytes before it.
      let stepped = false;
      let back: usize = 1;
      while (back <= 3 && end >= start + back) {
        if (spaceLengthAt(in bytes, end - back, end) == back) {
          end = end - back;
          stepped = true;
          break;
        }
        back = back + 1;
      }
      if (!stepped) break;
    }
  }
  return sliceBytes(in bytes, start, end);
}

// GetSubstitution for a string pattern: $$, $&, $` and $' expand; other
// dollar forms stay as written.
function expandReplacement(in replacement: Array<u8>, in matched: Array<u8>, position: usize, in subject: Array<u8>): Array<u8> {
  let joined = Array<u8>();
  let k: usize = 0;
  while (k < replacement.length) {
    const byte = replacement[k];
    if (byte == 36 && k + 1 < replacement.length) {
      const next = replacement[k + 1];
      if (next == 36) {
        joined.push(36);
        k = k + 2;
        continue;
      }
      if (next == 38) {
        let m: usize = 0;
        while (m < matched.length) { joined.push(matched[m]); m = m + 1; }
        k = k + 2;
        continue;
      }
      if (next == 96) {
        let m: usize = 0;
        while (m < position) { joined.push(subject[m]); m = m + 1; }
        k = k + 2;
        continue;
      }
      if (next == 39) {
        let m = position + matched.length;
        while (m < subject.length) { joined.push(subject[m]); m = m + 1; }
        k = k + 2;
        continue;
      }
    }
    joined.push(byte);
    k = k + 1;
  }
  return joined;
}

// The replacement for one match: the function's result, or the
// replacement string expanded.
function replacementFor(inout runtime: Runtime, replaceValue: Value, in matched: Array<u8>, position: usize, in subject: Array<u8>): Array<u8> {
  if (runtime.isCallable(replaceValue)) {
    let args = Array<Value>();
    args.push(runtime.newString(copyAll(in matched)));
    args.push(int32Value(i32(position)));
    args.push(runtime.newString(copyAll(in subject)));
    const produced = runtime.callValue(replaceValue, undefinedValue(), move args);
    if (runtime.pendingThrow) return Array<u8>();
    return argumentBytes(inout runtime, produced);
  }
  const replacement = argumentBytes(inout runtime, replaceValue);
  if (runtime.pendingThrow) return Array<u8>();
  return expandReplacement(in replacement, in matched, position, in subject);
}

// replaceAll(pattern, replacement) with a string pattern: every match,
// an empty pattern matching between every byte.
function stringReplaceAll(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "replaceAll";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const pattern = argumentBytes(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const replaceValue = runtime.argument(argsBase, argc, 1);
  // The replacement string converts once, before any match.
  let fixedReplacement = Array<u8>();
  const isFunction = runtime.isCallable(replaceValue);
  if (!isFunction) {
    fixedReplacement = argumentBytes(inout runtime, replaceValue);
    if (runtime.pendingThrow) return undefinedValue();
  }
  let positions = Array<usize>();
  const advance: usize = pattern.length == 0 ? 1 : pattern.length;
  let searchFrom: usize = 0;
  while (searchFrom <= bytes.length) {
    const found = findBytes(in bytes, in pattern, searchFrom);
    if (found < 0) break;
    positions.push(usize(found));
    searchFrom = usize(found) + advance;
  }
  let joined = Array<u8>();
  let copied: usize = 0;
  let i: usize = 0;
  while (i < positions.length) {
    const position = positions[i];
    while (copied < position) {
      joined.push(bytes[copied]);
      copied = copied + 1;
    }
    let replacement = Array<u8>();
    if (isFunction) {
      replacement = replacementFor(inout runtime, replaceValue, in pattern, position, in bytes);
      if (runtime.pendingThrow) return undefinedValue();
    } else {
      replacement = expandReplacement(in fixedReplacement, in pattern, position, in bytes);
    }
    let r: usize = 0;
    while (r < replacement.length) {
      joined.push(replacement[r]);
      r = r + 1;
    }
    copied = position + pattern.length;
    i = i + 1;
  }
  while (copied < bytes.length) {
    joined.push(bytes[copied]);
    copied = copied + 1;
  }
  return runtime.newString(move joined);
}

// normalize(form): the bytes as they are; the form must be a known one.
function stringNormalize(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "normalize";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const formValue = runtime.argument(argsBase, argc, 0);
  if (!isUndefined(formValue)) {
    const form = argumentBytes(inout runtime, formValue);
    if (runtime.pendingThrow) return undefinedValue();
    const nfc: String = "NFC";
    const nfd: String = "NFD";
    const nfkc: String = "NFKC";
    const nfkd: String = "NFKD";
    const known = sameBytes(in form, bytesOfText(in nfc)) || sameBytes(in form, bytesOfText(in nfd)) || sameBytes(in form, bytesOfText(in nfkc)) || sameBytes(in form, bytesOfText(in nfkd));
    if (!known) {
      const message: String = "The normalization form should be one of NFC, NFD, NFKC, NFKD";
      const error = runtime.rangeError(in message);
      runtime.raise(error);
      return undefinedValue();
    }
  }
  return runtime.newString(copyAll(in bytes));
}

function sameBytes(in a: Array<u8>, b: Array<u8>): boolean {
  if (a.length != b.length) return false;
  let i: usize = 0;
  while (i < a.length) {
    if (a[i] != b[i]) return false;
    i = i + 1;
  }
  return true;
}

// isWellFormed / toWellFormed: whether the bytes are well-formed UTF-8,
// and a copy with each malformed subpart replaced by U+FFFD.
function stringIsWellFormed(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "isWellFormed";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  let index: usize = 0;
  while (index < bytes.length) {
    const length = utf8SequenceLength(in bytes, index);
    if (length <= 0) return booleanValue(false);
    index = index + usize(length);
  }
  return booleanValue(true);
}

function stringToWellFormed(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "toWellFormed";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  let joined = Array<u8>();
  let index: usize = 0;
  while (index < bytes.length) {
    const length = utf8SequenceLength(in bytes, index);
    if (length > 0) {
      let k: usize = 0;
      while (k < usize(length)) {
        joined.push(bytes[index + k]);
        k = k + 1;
      }
      index = index + usize(length);
    } else {
      joined.push(0xEF);
      joined.push(0xBF);
      joined.push(0xBD);
      index = index + usize(0 - length);
    }
  }
  return runtime.newString(move joined);
}

function stringTrim(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "trim";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  return runtime.newString(trimBytes(in bytes, true, true));
}

function stringTrimStart(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "trimStart";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  return runtime.newString(trimBytes(in bytes, true, false));
}

function stringTrimEnd(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "trimEnd";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  return runtime.newString(trimBytes(in bytes, false, true));
}

function stringToUpperCase(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "toUpperCase";
  let bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  let index: usize = 0;
  while (index < bytes.length) {
    if (bytes[index] >= 97 && bytes[index] <= 122) bytes[index] = bytes[index] - 32;
    index = index + 1;
  }
  return runtime.newString(move bytes);
}

function stringToLowerCase(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "toLowerCase";
  let bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  let index: usize = 0;
  while (index < bytes.length) {
    if (bytes[index] >= 65 && bytes[index] <= 90) bytes[index] = bytes[index] + 32;
    index = index + 1;
  }
  return runtime.newString(move bytes);
}

function stringRepeat(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "repeat";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const countNumber = runtime.toNumberValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  if (countNumber < 0.0 || countNumber == 1.0 / 0.0) {
    const message: String = "Invalid count value";
    const error = runtime.makeError(ERROR_KIND_RANGE, bytesOf(in message));
    runtime.raise(error);
    return undefinedValue();
  }
  const count: u32 = countNumber != countNumber ? 0 : u32(truncateDouble(countNumber));
  let joined = Array<u8>();
  let repeat: u32 = 0;
  while (repeat < count) {
    let k: usize = 0;
    while (k < bytes.length) {
      joined.push(bytes[k]);
      k = k + 1;
    }
    repeat = repeat + 1;
  }
  return runtime.newString(move joined);
}

function padBytes(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, atStart: boolean, in method: String): Value {
  const bytes = thisString(inout runtime, thisValue, in method);
  if (runtime.pendingThrow) return undefinedValue();
  const target = runtime.toLength(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  let filler = Array<u8>();
  const given = runtime.argument(argsBase, argc, 1);
  if (isUndefined(given)) {
    filler.push(32);
  } else {
    filler = argumentBytes(inout runtime, given);
    if (runtime.pendingThrow) return undefinedValue();
  }
  if (usize(target) <= bytes.length || filler.length == 0) return runtime.newString(copyAll(in bytes));
  const missing = usize(target) - bytes.length;
  let padding = Array<u8>();
  while (padding.length < missing) {
    padding.push(filler[padding.length % filler.length]);
  }
  let joined = Array<u8>();
  if (atStart) {
    let k: usize = 0;
    while (k < padding.length) { joined.push(padding[k]); k = k + 1; }
    k = 0;
    while (k < bytes.length) { joined.push(bytes[k]); k = k + 1; }
  } else {
    let k: usize = 0;
    while (k < bytes.length) { joined.push(bytes[k]); k = k + 1; }
    k = 0;
    while (k < padding.length) { joined.push(padding[k]); k = k + 1; }
  }
  return runtime.newString(move joined);
}

function stringPadStart(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "padStart";
  return padBytes(inout runtime, thisValue, argsBase, argc, true, in text);
}

function stringPadEnd(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "padEnd";
  return padBytes(inout runtime, thisValue, argsBase, argc, false, in text);
}

// split(separator, limit) with a string separator; regular expressions
// come later.
function stringSplit(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "split";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const result = runtime.heap.allocateArray(0);
  const separatorValue = runtime.argument(argsBase, argc, 0);
  const limitValue = runtime.argument(argsBase, argc, 1);
  const limit: u32 = isUndefined(limitValue) ? 4294967295 : runtime.toLength(limitValue);
  if (runtime.pendingThrow) return undefinedValue();
  if (limit == 0) return cellValue(result);
  if (isUndefined(separatorValue)) {
    runtime.heap.arraySet(result, 0, runtime.newString(copyAll(in bytes)));
    return cellValue(result);
  }
  const separator = argumentBytes(inout runtime, separatorValue);
  if (runtime.pendingThrow) return undefinedValue();
  if (separator.length == 0) {
    let index: usize = 0;
    while (index < bytes.length && runtime.heap.arrayLength(result) < limit) {
      let one = Array<u8>();
      one.push(bytes[index]);
      const count = runtime.heap.arrayLength(result);
      runtime.heap.arraySet(result, count, runtime.newString(move one));
      index = index + 1;
    }
    return cellValue(result);
  }
  let start: usize = 0;
  while (runtime.heap.arrayLength(result) < limit) {
    const found = findBytes(in bytes, in separator, start);
    if (found < 0) {
      const count = runtime.heap.arrayLength(result);
      runtime.heap.arraySet(result, count, runtime.newString(sliceFrom(in bytes, start)));
      return cellValue(result);
    }
    const count = runtime.heap.arrayLength(result);
    runtime.heap.arraySet(result, count, runtime.newString(sliceBytes(in bytes, start, usize(found))));
    start = usize(found) + separator.length;
  }
  return cellValue(result);
}

// replace(pattern, replacement) with a string pattern: the first match.
function stringReplace(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "replace";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const pattern = argumentBytes(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const found = findBytes(in bytes, in pattern, 0);
  if (found < 0) return runtime.newString(copyAll(in bytes));
  const replacementValue = runtime.argument(argsBase, argc, 1);
  const replacement = replacementFor(inout runtime, replacementValue, in pattern, usize(found), in bytes);
  if (runtime.pendingThrow) return undefinedValue();
  let joined = sliceBytes(in bytes, 0, usize(found));
  let k: usize = 0;
  while (k < replacement.length) {
    joined.push(replacement[k]);
    k = k + 1;
  }
  const rest = sliceFrom(in bytes, usize(found) + pattern.length);
  k = 0;
  while (k < rest.length) {
    joined.push(rest[k]);
    k = k + 1;
  }
  return runtime.newString(move joined);
}

function stringLocaleCompare(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "localeCompare";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const other = argumentBytes(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  let index: usize = 0;
  while (index < bytes.length && index < other.length) {
    if (bytes[index] < other[index]) return int32Value(-1);
    if (bytes[index] > other[index]) return int32Value(1);
    index = index + 1;
  }
  if (bytes.length < other.length) return int32Value(-1);
  if (bytes.length > other.length) return int32Value(1);
  return int32Value(0);
}

// --- Installation ---

function defineConstant(inout runtime: Runtime, target: u32, in name: String, value: Value): void {
  const atom = runtime.atomOf(in name);
  runtime.defineOwnAttr(target, atom, value, PROP_NONE);
}

export function installPrimitives(inout runtime: Runtime): void {
  const atomConstructor = runtime.atomConstructor;

  const booleanProto = runtime.booleanProto;
  const booleanText: String = "Boolean";
  const booleanCtor = runtime.defineConstructor(constructBoolean, undefinedValue(), 1, in booleanText);
  runtime.heap.setLink(booleanCtor, booleanProto);
  runtime.defineOwnAttr(booleanProto, atomConstructor, cellValue(booleanCtor), PROP_METHOD);
  const atomPrimitive = runtime.atomPrimitive;
  runtime.defineOwnAttr(booleanProto, atomPrimitive, booleanValue(false), PROP_NONE);
  runtime.setGlobal("Boolean", cellValue(booleanCtor));
  const toStringText: String = "toString";
  const valueOfText: String = "valueOf";
  runtime.defineMethod(booleanProto, in toStringText, booleanToString, 0);
  runtime.defineMethod(booleanProto, in valueOfText, booleanValueOf, 0);

  const numberProto = runtime.numberProto;
  const numberText: String = "Number";
  const numberCtor = runtime.defineConstructor(constructNumber, undefinedValue(), 1, in numberText);
  runtime.heap.setLink(numberCtor, numberProto);
  runtime.defineOwnAttr(numberProto, atomConstructor, cellValue(numberCtor), PROP_METHOD);
  runtime.defineOwnAttr(numberProto, atomPrimitive, int32Value(0), PROP_NONE);
  runtime.setGlobal("Number", cellValue(numberCtor));
  runtime.defineMethod(numberProto, in toStringText, numberToString, 1);
  runtime.defineMethod(numberProto, in valueOfText, numberValueOf, 0);
  const toFixedText: String = "toFixed";
  runtime.defineMethod(numberProto, in toFixedText, numberToFixed, 1);
  const isNaNText: String = "isNaN";
  runtime.defineMethod(numberCtor, in isNaNText, numberIsNaN, 1);
  const isFiniteText: String = "isFinite";
  runtime.defineMethod(numberCtor, in isFiniteText, numberIsFinite, 1);
  const isIntegerText: String = "isInteger";
  runtime.defineMethod(numberCtor, in isIntegerText, numberIsInteger, 1);
  const isSafeIntegerText: String = "isSafeInteger";
  runtime.defineMethod(numberCtor, in isSafeIntegerText, numberIsSafeInteger, 1);
  const maxSafeText: String = "MAX_SAFE_INTEGER";
  defineConstant(inout runtime, numberCtor, in maxSafeText, doubleValue(9007199254740991.0));
  const minSafeText: String = "MIN_SAFE_INTEGER";
  defineConstant(inout runtime, numberCtor, in minSafeText, doubleValue(-9007199254740991.0));
  const maxValueText: String = "MAX_VALUE";
  defineConstant(inout runtime, numberCtor, in maxValueText, doubleValue(1.7976931348623157e308));
  const minValueText: String = "MIN_VALUE";
  defineConstant(inout runtime, numberCtor, in minValueText, doubleValue(5e-324));
  const epsilonText: String = "EPSILON";
  defineConstant(inout runtime, numberCtor, in epsilonText, doubleValue(2.220446049250313e-16));
  const nanText: String = "NaN";
  defineConstant(inout runtime, numberCtor, in nanText, doubleValue(nativeNan()));
  const positiveInfinityText: String = "POSITIVE_INFINITY";
  defineConstant(inout runtime, numberCtor, in positiveInfinityText, doubleValue(1.0 / 0.0));
  const negativeInfinityText: String = "NEGATIVE_INFINITY";
  defineConstant(inout runtime, numberCtor, in negativeInfinityText, doubleValue(-1.0 / 0.0));
  // Number.parseFloat / parseInt are the globals of the same name.
  const parseFloatText: String = "parseFloat";
  const parseFloatSlot = runtime.globalSlot("parseFloat");
  const parseFloatValue = runtime.globals[usize(parseFloatSlot)].value;
  defineConstant(inout runtime, numberCtor, in parseFloatText, parseFloatValue);
  const parseIntText: String = "parseInt";
  const parseIntSlot = runtime.globalSlot("parseInt");
  const parseIntValue = runtime.globals[usize(parseIntSlot)].value;
  defineConstant(inout runtime, numberCtor, in parseIntText, parseIntValue);

  const stringProto = runtime.stringProto;
  const stringText: String = "String";
  const stringCtor = runtime.defineConstructor(constructString, undefinedValue(), 1, in stringText);
  runtime.heap.setLink(stringCtor, stringProto);
  runtime.defineOwnAttr(stringProto, atomConstructor, cellValue(stringCtor), PROP_METHOD);
  runtime.defineOwnAttr(stringProto, atomPrimitive, runtime.internValue(Array<u8>()), PROP_NONE);
  runtime.setGlobal("String", cellValue(stringCtor));
  const fromCharCodeText: String = "fromCharCode";
  runtime.defineMethod(stringCtor, in fromCharCodeText, stringFromCharCode, 1);
  const fromCodePointText: String = "fromCodePoint";
  runtime.defineMethod(stringCtor, in fromCodePointText, stringFromCodePoint, 1);
  const rawText: String = "raw";
  runtime.defineMethod(stringCtor, in rawText, stringRaw, 1);
  const codePointAtText: String = "codePointAt";
  runtime.defineMethod(stringProto, in codePointAtText, stringCodePointAt, 1);
  const replaceAllText: String = "replaceAll";
  runtime.defineMethod(stringProto, in replaceAllText, stringReplaceAll, 2);
  const normalizeText: String = "normalize";
  runtime.defineMethod(stringProto, in normalizeText, stringNormalize, 0);
  const isWellFormedText: String = "isWellFormed";
  runtime.defineMethod(stringProto, in isWellFormedText, stringIsWellFormed, 0);
  const toWellFormedText: String = "toWellFormed";
  runtime.defineMethod(stringProto, in toWellFormedText, stringToWellFormed, 0);
  const toLocaleUpperCaseText: String = "toLocaleUpperCase";
  runtime.defineMethod(stringProto, in toLocaleUpperCaseText, stringToUpperCase, 0);
  const toLocaleLowerCaseText: String = "toLocaleLowerCase";
  runtime.defineMethod(stringProto, in toLocaleLowerCaseText, stringToLowerCase, 0);
  runtime.defineMethod(stringProto, in toStringText, stringToStringMethod, 0);
  runtime.defineMethod(stringProto, in valueOfText, stringToStringMethod, 0);
  const charAtText: String = "charAt";
  runtime.defineMethod(stringProto, in charAtText, stringCharAt, 1);
  const charCodeAtText: String = "charCodeAt";
  runtime.defineMethod(stringProto, in charCodeAtText, stringCharCodeAt, 1);
  const atText: String = "at";
  runtime.defineMethod(stringProto, in atText, stringAt, 1);
  const indexOfText: String = "indexOf";
  runtime.defineMethod(stringProto, in indexOfText, stringIndexOf, 1);
  const lastIndexOfText: String = "lastIndexOf";
  runtime.defineMethod(stringProto, in lastIndexOfText, stringLastIndexOf, 1);
  const includesText: String = "includes";
  runtime.defineMethod(stringProto, in includesText, stringIncludes, 1);
  const startsWithText: String = "startsWith";
  runtime.defineMethod(stringProto, in startsWithText, stringStartsWith, 1);
  const endsWithText: String = "endsWith";
  runtime.defineMethod(stringProto, in endsWithText, stringEndsWith, 1);
  const sliceText: String = "slice";
  runtime.defineMethod(stringProto, in sliceText, stringSlice, 2);
  const substringText: String = "substring";
  runtime.defineMethod(stringProto, in substringText, stringSubstring, 2);
  const substrText: String = "substr";
  runtime.defineMethod(stringProto, in substrText, stringSubstr, 2);
  const concatText: String = "concat";
  runtime.defineMethod(stringProto, in concatText, stringConcat, 1);
  const trimText: String = "trim";
  runtime.defineMethod(stringProto, in trimText, stringTrim, 0);
  const trimStartText: String = "trimStart";
  runtime.defineMethod(stringProto, in trimStartText, stringTrimStart, 0);
  const trimEndText: String = "trimEnd";
  runtime.defineMethod(stringProto, in trimEndText, stringTrimEnd, 0);
  const toUpperCaseText: String = "toUpperCase";
  runtime.defineMethod(stringProto, in toUpperCaseText, stringToUpperCase, 0);
  const toLowerCaseText: String = "toLowerCase";
  runtime.defineMethod(stringProto, in toLowerCaseText, stringToLowerCase, 0);
  const repeatText: String = "repeat";
  runtime.defineMethod(stringProto, in repeatText, stringRepeat, 1);
  const padStartText: String = "padStart";
  runtime.defineMethod(stringProto, in padStartText, stringPadStart, 1);
  const padEndText: String = "padEnd";
  runtime.defineMethod(stringProto, in padEndText, stringPadEnd, 1);
  const splitText: String = "split";
  runtime.defineMethod(stringProto, in splitText, stringSplit, 2);
  const replaceText: String = "replace";
  runtime.defineMethod(stringProto, in replaceText, stringReplace, 2);
  const localeCompareText: String = "localeCompare";
  runtime.defineMethod(stringProto, in localeCompareText, stringLocaleCompare, 1);
}
