// Boolean, Number, and String: constructors, wrappers, and prototypes.
//
// Strings are UTF-16 code units, as the specification says: `length`,
// indexing, and every method here count units.
import { thread } from "std/thread";
import { Value, undefinedValue, booleanValue, int32Value, doubleValue, cellValue, asCell, isCell, isUndefined, isNull, isDeleted, isNumber, isBoolean, isTrue, isInt32, asInt32, asDouble } from "../value.zs";
import { Runtime, ERROR_KIND_RANGE, toNumber, toInt32, isIntegralDouble, truncateDouble, int32ToString, doubleToString, stringToNumber } from "../runtime.zs";
import { bytesOf, PROP_METHOD, PROP_NONE } from "../heap.zs";
import { unitsOf, pushCodePoint, codePointAt, isJsSpace, isHighSurrogate, isLowSurrogate, upperUnit, lowerUnit, sliceUnits, copyUnits } from "../text.zs";

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

function bytesOfText(in text: String): Array<u16> {
  return unitsOf(in text);
}

function textValue(inout runtime: Runtime, in text: String): Value {
  return runtime.newStringUtf8(bytesOf(in text));
}

// Read a formatted native buffer back as ASCII bytes.
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
function thisString(inout runtime: Runtime, thisValue: Value, in method: String): Array<u16> {
  if (isUndefined(thisValue) || isNull(thisValue)) {
    const message: String = `String.prototype.${method} called on null or undefined`;
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return Array<u16>();
  }
  const primitive = thisPrimitive(in runtime, thisValue);
  const source = isDeleted(primitive) ? thisValue : primitive;
  const text = runtime.toStringValue(source);
  if (runtime.pendingThrow) return Array<u16>();
  return runtime.heap.stringUnits(asCell(text));
}

// The same, as the string cell itself (0 after a throw), for methods
// that can read units in place instead of copying them all.
function thisStringHandle(inout runtime: Runtime, thisValue: Value, in method: String): u32 {
  if (isUndefined(thisValue) || isNull(thisValue)) {
    const message: String = `String.prototype.${method} called on null or undefined`;
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return 0;
  }
  const primitive = thisPrimitive(in runtime, thisValue);
  const source = isDeleted(primitive) ? thisValue : primitive;
  const text = runtime.toStringValue(source);
  if (runtime.pendingThrow) return 0;
  return asCell(text);
}

function thisStringValue(inout runtime: Runtime, thisValue: Value, in method: String): Value {
  const handle = thisStringHandle(inout runtime, thisValue, in method);
  if (runtime.pendingThrow) return undefinedValue();
  return cellValue(handle);
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
  let digits = Array<u16>();
  if (integerPart == 0.0) {
    digits.push(48);
  } else {
    let reversed = Array<u16>();
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
  let joined = Array<u16>();
  if (negative) joined.push(45);
  let i: usize = 0;
  while (i < digits.length) {
    joined.push(digits[i]);
    i = i + 1;
  }
  return runtime.newStringUnits(move joined);
}

function digitChar(digit: i32): u16 {
  if (digit < 10) return u16(48 + digit);
  return u16(87 + digit);
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
  return runtime.newStringLatin1(move bytes);
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
  let value = runtime.internLatin1Value(Array<u8>());
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
  let bytes = Array<u16>();
  let index: u32 = 0;
  while (index < argc) {
    const number = runtime.toNumberValue(runtime.argument(argsBase, argc, index));
    if (runtime.pendingThrow) return undefinedValue();
    const unit = u32(toInt32(doubleValue(number)).toBits() & 0xFFFF);
    bytes.push(u16(unit));
    index = index + 1;
  }
  return runtime.newStringUnits(move bytes);
}

// String.fromCodePoint: each argument an integral code point, else a
// RangeError.
function stringFromCodePoint(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  let bytes = Array<u16>();
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
    pushCodePoint(inout bytes, u32(number));
    index = index + 1;
  }
  return runtime.newStringUnits(move bytes);
}

// codePointAt(position): a surrogate pair combined, else the unit.
function stringCodePointAt(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "codePointAt";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const index = integerArgument(inout runtime, runtime.argument(argsBase, argc, 0), 0);
  if (runtime.pendingThrow) return undefinedValue();
  if (index < 0 || usize(index) >= bytes.length) return undefinedValue();
  return int32Value(i32(codePointAt(in bytes, usize(index))));
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
  let joined = Array<u16>();
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
      const segmentBytes = runtime.heap.stringUnits(asCell(segmentText));
      let k: usize = 0;
      while (k < segmentBytes.length) {
        joined.push(segmentBytes[k]);
        k = k + 1;
      }
      if (index + 1 < count && index + 1 < argc) {
        const substitution = runtime.toStringValue(runtime.argument(argsBase, argc, index + 1));
        if (runtime.pendingThrow) { failed = true; break; }
        const substitutionBytes = runtime.heap.stringUnits(asCell(substitution));
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
  return runtime.newStringUnits(move joined);
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
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const index = integerArgument(inout runtime, runtime.argument(argsBase, argc, 0), 0);
  if (runtime.pendingThrow) return undefinedValue();
  const length = runtime.heap.stringLength(handle);
  if (index < 0 || usize(index) >= length) return runtime.internLatin1Value(Array<u8>());
  return runtime.substringValue(handle, usize(index), usize(index) + 1);
}

function stringCharCodeAt(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "charCodeAt";
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const index = integerArgument(inout runtime, runtime.argument(argsBase, argc, 0), 0);
  if (runtime.pendingThrow) return undefinedValue();
  const length = runtime.heap.stringLength(handle);
  if (index < 0 || usize(index) >= length) return doubleValue(nativeNan());
  return int32Value(i32(runtime.heap.stringUnit(handle, usize(index))));
}

function stringAt(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "at";
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  let index = integerArgument(inout runtime, runtime.argument(argsBase, argc, 0), 0);
  if (runtime.pendingThrow) return undefinedValue();
  const length = runtime.heap.stringLength(handle);
  if (index < 0) index = index + i32(length);
  if (index < 0 || usize(index) >= length) return undefinedValue();
  return runtime.substringValue(handle, usize(index), usize(index) + 1);
}

// --- Narrow fast paths ---
//
// A method whose receiver and arguments are all narrow works on their
// Latin-1 storage bytes and builds a narrow result directly; the same
// algorithms, generic over the element, serve the units path. The
// semantics are identical: a narrow string's bytes are its code units.

// The offset of `needle` in `haystack` at or after `startAt`, or -1.
function findBytes<T>(in haystack: Array<T>, in needle: Array<T>, startAt: usize): i32 {
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

// The last offset at or before `from` where `needle` occurs, or -1.
function findLastIn<T>(in haystack: Array<T>, in needle: Array<T>, limit: usize): i32 {
  if (needle.length > haystack.length) return -1;
  let start = limit;
  const last = haystack.length - needle.length;
  if (start > last) start = last;
  while (true) {
    let matched = true;
    let k: usize = 0;
    while (matched && k < needle.length) {
      if (haystack[start + k] != needle[k]) matched = false;
      k = k + 1;
    }
    if (matched) return i32(start);
    if (start == 0) return -1;
    start = start - 1;
  }
  return -1;
}

function endsWithIn<T>(in haystack: Array<T>, in needle: Array<T>, end: usize): boolean {
  if (needle.length > end) return false;
  const start = end - needle.length;
  let k: usize = 0;
  while (k < needle.length) {
    if (haystack[start + k] != needle[k]) return false;
    k = k + 1;
  }
  return true;
}

function appendAll<T>(inout target: Array<T>, in source: Array<T>): void {
  let k: usize = 0;
  while (k < source.length) {
    target.push(source[k]);
    k = k + 1;
  }
}

function argumentBytes(inout runtime: Runtime, value: Value): Array<u16> {
  const text = runtime.toStringValue(value);
  if (runtime.pendingThrow) return Array<u16>();
  return runtime.heap.stringUnits(asCell(text));
}

// An argument as a string cell (0 after a throw).
function argumentHandle(inout runtime: Runtime, value: Value): u32 {
  const text = runtime.toStringValue(value);
  if (runtime.pendingThrow) return 0;
  return asCell(text);
}

function narrow(in runtime: Runtime, handle: u32): boolean {
  return !runtime.heap.isWideString(handle);
}

function stringIndexOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "indexOf";
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(cellValue(handle));
  const needleHandle = argumentHandle(inout runtime, runtime.argument(argsBase, argc, 0));
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  if (narrow(in runtime, handle) && narrow(in runtime, needleHandle)) {
    const hay = runtime.heap.stringStorageBytes(handle);
    const key = runtime.heap.stringStorageBytes(needleHandle);
    const position = clampPosition(integerArgument(inout runtime, runtime.argument(argsBase, argc, 1), 0), i32(hay.length));
    if (runtime.pendingThrow) return undefinedValue();
    return int32Value(findBytes(in hay, in key, usize(position)));
  }
  const bytes = runtime.heap.stringUnits(handle);
  const needle = runtime.heap.stringUnits(needleHandle);
  const startAt = clampPosition(integerArgument(inout runtime, runtime.argument(argsBase, argc, 1), 0), i32(bytes.length));
  if (runtime.pendingThrow) return undefinedValue();
  return int32Value(findBytes(in bytes, in needle, usize(startAt)));
}

function stringLastIndexOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "lastIndexOf";
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(cellValue(handle));
  const needleHandle = argumentHandle(inout runtime, runtime.argument(argsBase, argc, 0));
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  const length = i32(runtime.heap.stringLength(handle));
  let limit = length;
  const given = runtime.argument(argsBase, argc, 1);
  if (!isUndefined(given)) {
    const number = runtime.toNumberValue(given);
    if (runtime.pendingThrow) return undefinedValue();
    if (number == number) limit = integerArgument(inout runtime, given, limit);
  }
  if (limit < 0) limit = 0;
  if (narrow(in runtime, handle) && narrow(in runtime, needleHandle)) {
    const hay = runtime.heap.stringStorageBytes(handle);
    const key = runtime.heap.stringStorageBytes(needleHandle);
    return int32Value(findLastIn(in hay, in key, usize(limit)));
  }
  const bytes = runtime.heap.stringUnits(handle);
  const needle = runtime.heap.stringUnits(needleHandle);
  return int32Value(findLastIn(in bytes, in needle, usize(limit)));
}

// --- The RegExp protocol ---
//
// match / matchAll / replace / replaceAll / search / split hand the work
// to the argument's @@method when it has one; a plain string argument
// to match / matchAll / search becomes a RegExp first.

function requireCoercible(inout runtime: Runtime, thisValue: Value, in method: String): boolean {
  if (!isUndefined(thisValue) && !isNull(thisValue)) return true;
  const message: String = `String.prototype.${method} called on null or undefined`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return false;
}

// GetMethod(value, symbol): the callable, or undefined.
function symbolMethod(inout runtime: Runtime, value: Value, symbol: Value): Value {
  if (isUndefined(value) || isNull(value)) return undefinedValue();
  const method = runtime.getProperty(value, symbol);
  if (runtime.pendingThrow) return undefinedValue();
  if (isUndefined(method) || isNull(method)) return undefinedValue();
  if (!runtime.isCallable(method)) {
    const message: String = "Symbol method is not a function";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  return method;
}

// A RegExp argument to includes / startsWith / endsWith is a TypeError.
function rejectRegExpArgument(inout runtime: Runtime, value: Value, in method: String): boolean {
  const isRegExp = runtime.isRegExp(value);
  if (runtime.pendingThrow) return true;
  if (!isRegExp) return false;
  const message: String = `First argument to String.prototype.${method} must not be a regular expression`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return true;
}

// A global-flag check for matchAll and replaceAll on a RegExp argument.
function requireGlobalFlag(inout runtime: Runtime, value: Value, in method: String): boolean {
  const isRegExp = runtime.isRegExp(value);
  if (runtime.pendingThrow) return false;
  if (!isRegExp) return true;
  const flagsText: String = "flags";
  const flagsKey = runtime.internText(in flagsText);
  const flags = runtime.getProperty(value, flagsKey);
  if (runtime.pendingThrow) return false;
  if (isUndefined(flags) || isNull(flags)) {
    const message: String = `String.prototype.${method} called with a RegExp whose flags are undefined`;
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return false;
  }
  const flagsString = runtime.toStringValue(flags);
  if (runtime.pendingThrow) return false;
  const flagBytes = runtime.heap.stringUnits(asCell(flagsString));
  let i: usize = 0;
  while (i < flagBytes.length) {
    if (flagBytes[i] == 103) return true;
    i = i + 1;
  }
  const message: String = `String.prototype.${method} called with a non-global RegExp argument`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return false;
}

// match and search: the argument's @@method, else a RegExp made from it.
function stringMatchLike(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, symbol: Value, in method: String, flags: Value): Value {
  if (!requireCoercible(inout runtime, thisValue, in method)) return undefinedValue();
  const regexp = runtime.argument(argsBase, argc, 0);
  if (!isUndefined(regexp) && !isNull(regexp)) {
    const matcher = symbolMethod(inout runtime, regexp, symbol);
    if (runtime.pendingThrow) return undefinedValue();
    if (!isUndefined(matcher)) {
      let args = Array<Value>();
      args.push(thisValue);
      return runtime.callValue(matcher, regexp, move args);
    }
  }
  const text = runtime.toStringValue(thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(text);
  const regexProto = runtime.regexProto;
  const rx = runtime.regexpCreate(regexp, flags, regexProto);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  runtime.pushTempRoot(rx);
  const invoked = runtime.getProperty(rx, symbol);
  let result = undefinedValue();
  if (!runtime.pendingThrow) {
    if (!runtime.isCallable(invoked)) {
      const message: String = "RegExp method is not a function";
      const error = runtime.typeError(in message);
      runtime.raise(error);
    } else {
      let args = Array<Value>();
      args.push(text);
      result = runtime.callValue(invoked, rx, move args);
    }
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  return result;
}

function stringMatch(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "match";
  const symbolMatch = runtime.symbolMatch;
  return stringMatchLike(inout runtime, thisValue, argsBase, argc, symbolMatch, in method, undefinedValue());
}

function stringSearch(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "search";
  const symbolSearch = runtime.symbolSearch;
  return stringMatchLike(inout runtime, thisValue, argsBase, argc, symbolSearch, in method, undefinedValue());
}

function stringMatchAll(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "matchAll";
  const regexp = runtime.argument(argsBase, argc, 0);
  if (!requireCoercible(inout runtime, thisValue, in method)) return undefinedValue();
  if (!isUndefined(regexp) && !isNull(regexp)) {
    if (!requireGlobalFlag(inout runtime, regexp, in method)) return undefinedValue();
  }
  const globalText: String = "g";
  const globalFlag = runtime.internText(in globalText);
  const symbolMatchAll = runtime.symbolMatchAll;
  return stringMatchLike(inout runtime, thisValue, argsBase, argc, symbolMatchAll, in method, globalFlag);
}

function stringIncludes(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "includes";
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  if (rejectRegExpArgument(inout runtime, runtime.argument(argsBase, argc, 0), in text)) return undefinedValue();
  runtime.pushTempRoot(cellValue(handle));
  const needleHandle = argumentHandle(inout runtime, runtime.argument(argsBase, argc, 0));
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  const length = i32(runtime.heap.stringLength(handle));
  const position = clampPosition(integerArgument(inout runtime, runtime.argument(argsBase, argc, 1), 0), length);
  if (runtime.pendingThrow) return undefinedValue();
  if (narrow(in runtime, handle) && narrow(in runtime, needleHandle)) {
    const hay = runtime.heap.stringStorageBytes(handle);
    const key = runtime.heap.stringStorageBytes(needleHandle);
    return booleanValue(findBytes(in hay, in key, usize(position)) >= 0);
  }
  const bytes = runtime.heap.stringUnits(handle);
  const needle = runtime.heap.stringUnits(needleHandle);
  return booleanValue(findBytes(in bytes, in needle, usize(position)) >= 0);
}

function stringStartsWith(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "startsWith";
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  if (rejectRegExpArgument(inout runtime, runtime.argument(argsBase, argc, 0), in text)) return undefinedValue();
  runtime.pushTempRoot(cellValue(handle));
  const needleHandle = argumentHandle(inout runtime, runtime.argument(argsBase, argc, 0));
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  const length = i32(runtime.heap.stringLength(handle));
  const position = clampPosition(integerArgument(inout runtime, runtime.argument(argsBase, argc, 1), 0), length);
  if (runtime.pendingThrow) return undefinedValue();
  const needleLength = runtime.heap.stringLength(needleHandle);
  if (usize(position) + needleLength > usize(length)) return booleanValue(false);
  let k: usize = 0;
  while (k < needleLength) {
    if (runtime.heap.stringUnit(handle, usize(position) + k) != runtime.heap.stringUnit(needleHandle, k)) return booleanValue(false);
    k = k + 1;
  }
  return booleanValue(true);
}

function stringEndsWith(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "endsWith";
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  if (rejectRegExpArgument(inout runtime, runtime.argument(argsBase, argc, 0), in text)) return undefinedValue();
  runtime.pushTempRoot(cellValue(handle));
  const needleHandle = argumentHandle(inout runtime, runtime.argument(argsBase, argc, 0));
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  const length = i32(runtime.heap.stringLength(handle));
  const end = clampPosition(integerArgument(inout runtime, runtime.argument(argsBase, argc, 1), length), length);
  if (runtime.pendingThrow) return undefinedValue();
  const needleLength = runtime.heap.stringLength(needleHandle);
  if (needleLength > usize(end)) return booleanValue(false);
  const start = usize(end) - needleLength;
  let k: usize = 0;
  while (k < needleLength) {
    if (runtime.heap.stringUnit(handle, start + k) != runtime.heap.stringUnit(needleHandle, k)) return booleanValue(false);
    k = k + 1;
  }
  return booleanValue(true);
}

// The capacity to reserve for `count` copies of `length` units: the
// product, unless it is past what any result could be.
function repeatCapacity(length: usize, count: u32): usize {
  const total = length * usize(count);
  if (total > 268435456) return 0;
  return total;
}

function copyAll(in bytes: Array<u16>): Array<u16> {
  let copied = Array<u16>.withCapacity(bytes.length);
  let index: usize = 0;
  while (index < bytes.length) {
    copied.push(bytes[index]);
    index = index + 1;
  }
  return copied;
}

function sliceFrom(in bytes: Array<u16>, start: usize): Array<u16> {
  let count: usize = 0;
  if (bytes.length > start) count = bytes.length - start;
  let copied = Array<u16>.withCapacity(count);
  let index = start;
  while (index < bytes.length) {
    copied.push(bytes[index]);
    index = index + 1;
  }
  return copied;
}

function sliceBytes(in bytes: Array<u16>, start: usize, end: usize): Array<u16> {
  let count: usize = 0;
  if (end > start) count = end - start;
  let joined = Array<u16>.withCapacity(count);
  let index = start;
  while (index < end) {
    joined.push(bytes[index]);
    index = index + 1;
  }
  return joined;
}

function stringSlice(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "slice";
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const length = i32(runtime.heap.stringLength(handle));
  const start = clampIndex(integerArgument(inout runtime, runtime.argument(argsBase, argc, 0), 0), length);
  if (runtime.pendingThrow) return undefinedValue();
  const end = clampIndex(integerArgument(inout runtime, runtime.argument(argsBase, argc, 1), length), length);
  if (runtime.pendingThrow) return undefinedValue();
  if (end <= start) return runtime.internLatin1Value(Array<u8>());
  return runtime.substringValue(handle, usize(start), usize(end));
}

function stringSubstring(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "substring";
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const length = i32(runtime.heap.stringLength(handle));
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
  return runtime.substringValue(handle, usize(start), usize(end));
}

function stringSubstr(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "substr";
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  const length = i32(runtime.heap.stringLength(handle));
  const start = clampIndex(integerArgument(inout runtime, runtime.argument(argsBase, argc, 0), 0), length);
  if (runtime.pendingThrow) return undefinedValue();
  let count = integerArgument(inout runtime, runtime.argument(argsBase, argc, 1), length - start);
  if (runtime.pendingThrow) return undefinedValue();
  if (count < 0) count = 0;
  let end = start + count;
  if (end > length) end = length;
  return runtime.substringValue(handle, usize(start), usize(end));
}

function stringConcat(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "concat";
  let result = thisStringValue(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  let index: u32 = 0;
  while (index < argc) {
    runtime.pushTempRoot(result);
    const more = runtime.toStringValue(runtime.argument(argsBase, argc, index));
    runtime.popTempRoot();
    if (runtime.pendingThrow) return undefinedValue();
    result = runtime.concatStrings(result, more);
    index = index + 1;
  }
  return result;
}

// The trimmed bounds of a string cell.
function trimmedStart(in runtime: Runtime, handle: u32, end: usize): usize {
  let start: usize = 0;
  while (start < end && isJsSpace(runtime.heap.stringUnit(handle, start))) { start = start + 1; }
  return start;
}

function trimmedEnd(in runtime: Runtime, handle: u32, start: usize, length: usize): usize {
  let end = length;
  while (end > start && isJsSpace(runtime.heap.stringUnit(handle, end - 1))) { end = end - 1; }
  return end;
}

function trimString(inout runtime: Runtime, thisValue: Value, in method: String, leading: boolean, trailing: boolean): Value {
  const handle = thisStringHandle(inout runtime, thisValue, in method);
  if (runtime.pendingThrow) return undefinedValue();
  const length = runtime.heap.stringLength(handle);
  let start: usize = 0;
  if (leading) start = trimmedStart(in runtime, handle, length);
  let end = length;
  if (trailing) end = trimmedEnd(in runtime, handle, start, length);
  if (start == 0 && end == length) return cellValue(handle);
  return runtime.substringValue(handle, start, end);
}

// GetSubstitution for a string pattern: $$, $&, $` and $' expand; other
// dollar forms stay as written.
function expandReplacement<T>(in replacement: Array<T>, in matched: Array<T>, position: usize, in subject: Array<T>): Array<T> {
  let joined = Array<T>();
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
function replacementFor(inout runtime: Runtime, replaceValue: Value, in matched: Array<u16>, position: usize, in subject: Array<u16>): Array<u16> {
  if (runtime.isCallable(replaceValue)) {
    let args = Array<Value>();
    args.push(runtime.newStringUnits(copyAll(in matched)));
    args.push(int32Value(i32(position)));
    args.push(runtime.newStringUnits(copyAll(in subject)));
    const produced = runtime.callValue(replaceValue, undefinedValue(), move args);
    if (runtime.pendingThrow) return Array<u16>();
    return argumentBytes(inout runtime, produced);
  }
  const replacement = argumentBytes(inout runtime, replaceValue);
  if (runtime.pendingThrow) return Array<u16>();
  return expandReplacement(in replacement, in matched, position, in subject);
}

// replaceAll(pattern, replacement) with a string pattern: every match,
// an empty pattern matching between every byte.
function stringReplaceAll(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "replaceAll";
  if (!requireCoercible(inout runtime, thisValue, in text)) return undefinedValue();
  const searchArgument = runtime.argument(argsBase, argc, 0);
  if (!isUndefined(searchArgument) && !isNull(searchArgument)) {
    if (!requireGlobalFlag(inout runtime, searchArgument, in text)) return undefinedValue();
    const symbolReplace = runtime.symbolReplace;
    const replacer = symbolMethod(inout runtime, searchArgument, symbolReplace);
    if (runtime.pendingThrow) return undefinedValue();
    if (!isUndefined(replacer)) {
      let args = Array<Value>();
      args.push(thisValue);
      args.push(runtime.argument(argsBase, argc, 1));
      return runtime.callValue(replacer, searchArgument, move args);
    }
  }
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(cellValue(handle));
  const patternHandle = argumentHandle(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  runtime.pushTempRoot(cellValue(patternHandle));
  const replaceValue = runtime.argument(argsBase, argc, 1);
  // The replacement string converts once, before any match.
  let replacementHandle: u32 = 0;
  const isFunction = runtime.isCallable(replaceValue);
  if (!isFunction) {
    replacementHandle = argumentHandle(inout runtime, replaceValue);
    if (runtime.pendingThrow) {
      runtime.popTempRoot();
      runtime.popTempRoot();
      return undefinedValue();
    }
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (!isFunction && narrow(in runtime, handle) && narrow(in runtime, patternHandle) && narrow(in runtime, replacementHandle)) {
    const hay = runtime.heap.stringStorageBytes(handle);
    const key = runtime.heap.stringStorageBytes(patternHandle);
    const template = runtime.heap.stringStorageBytes(replacementHandle);
    const step: usize = key.length == 0 ? 1 : key.length;
    let joined = Array<u8>.withCapacity(hay.length);
    let copied: usize = 0;
    let searchFrom: usize = 0;
    while (searchFrom <= hay.length) {
      const found = findBytes(in hay, in key, searchFrom);
      if (found < 0) break;
      const position = usize(found);
      while (copied < position) {
        joined.push(hay[copied]);
        copied = copied + 1;
      }
      const replacement = expandReplacement(in template, in key, position, in hay);
      appendAll(inout joined, in replacement);
      copied = position + key.length;
      searchFrom = position + step;
    }
    while (copied < hay.length) {
      joined.push(hay[copied]);
      copied = copied + 1;
    }
    return runtime.newStringLatin1(move joined);
  }
  const bytes = runtime.heap.stringUnits(handle);
  const pattern = runtime.heap.stringUnits(patternHandle);
  let fixedReplacement = Array<u16>();
  if (!isFunction) fixedReplacement = runtime.heap.stringUnits(replacementHandle);
  let positions = Array<usize>();
  const advance: usize = pattern.length == 0 ? 1 : pattern.length;
  let searchFrom: usize = 0;
  while (searchFrom <= bytes.length) {
    const found = findBytes(in bytes, in pattern, searchFrom);
    if (found < 0) break;
    positions.push(usize(found));
    searchFrom = usize(found) + advance;
  }
  let joined = Array<u16>.withCapacity(bytes.length);
  let copied: usize = 0;
  let i: usize = 0;
  while (i < positions.length) {
    const position = positions[i];
    while (copied < position) {
      joined.push(bytes[copied]);
      copied = copied + 1;
    }
    let replacement = Array<u16>();
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
  return runtime.newStringUnits(move joined);
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
  return runtime.newStringUnits(copyAll(in bytes));
}

function sameBytes(in a: Array<u16>, b: Array<u16>): boolean {
  if (a.length != b.length) return false;
  let i: usize = 0;
  while (i < a.length) {
    if (a[i] != b[i]) return false;
    i = i + 1;
  }
  return true;
}

// isWellFormed / toWellFormed: whether every surrogate is paired, and a
// copy with each lone surrogate replaced by U+FFFD.
function stringIsWellFormed(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "isWellFormed";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  let index: usize = 0;
  while (index < bytes.length) {
    const unit = bytes[index];
    if (isHighSurrogate(unit)) {
      if (index + 1 >= bytes.length || !isLowSurrogate(bytes[index + 1])) return booleanValue(false);
      index = index + 2;
      continue;
    }
    if (isLowSurrogate(unit)) return booleanValue(false);
    index = index + 1;
  }
  return booleanValue(true);
}

function stringToWellFormed(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "toWellFormed";
  const bytes = thisString(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  let joined = Array<u16>.withCapacity(bytes.length);
  let index: usize = 0;
  while (index < bytes.length) {
    const unit = bytes[index];
    if (isHighSurrogate(unit) && index + 1 < bytes.length && isLowSurrogate(bytes[index + 1])) {
      joined.push(unit);
      joined.push(bytes[index + 1]);
      index = index + 2;
      continue;
    }
    if (isHighSurrogate(unit) || isLowSurrogate(unit)) {
      joined.push(0xFFFD);
    } else {
      joined.push(unit);
    }
    index = index + 1;
  }
  return runtime.newStringUnits(move joined);
}

function stringTrim(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "trim";
  return trimString(inout runtime, thisValue, in text, true, true);
}

function stringTrimStart(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "trimStart";
  return trimString(inout runtime, thisValue, in text, true, false);
}

function stringTrimEnd(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "trimEnd";
  return trimString(inout runtime, thisValue, in text, false, true);
}

function stringToUpperCase(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "toUpperCase";
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  if (narrow(in runtime, handle)) {
    // Bytes map to bytes, except the two Latin-1 letters whose capitals
    // lie above it (y with diaeresis, micro sign) and the sharp s, which
    // expands; those take the units path.
    let bytes = runtime.heap.stringStorageBytes(handle);
    let simple = true;
    let index: usize = 0;
    while (index < bytes.length) {
      const byte = bytes[index];
      if (byte == 0xFF || byte == 0xB5 || byte == 0xDF) {
        simple = false;
        break;
      }
      bytes[index] = u8(upperUnit(u16(byte)));
      index = index + 1;
    }
    if (simple) return runtime.newStringLatin1(move bytes);
  }
  const units = runtime.heap.stringUnits(handle);
  let joined = Array<u16>.withCapacity(units.length);
  let index: usize = 0;
  while (index < units.length) {
    const unit = units[index];
    if (unit == 0xDF) {
      joined.push(83);
      joined.push(83);
    } else {
      joined.push(upperUnit(unit));
    }
    index = index + 1;
  }
  return runtime.newStringUnits(move joined);
}

function stringToLowerCase(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "toLowerCase";
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  if (narrow(in runtime, handle)) {
    // Every Latin-1 lowercase letter is Latin-1.
    let bytes = runtime.heap.stringStorageBytes(handle);
    let index: usize = 0;
    while (index < bytes.length) {
      bytes[index] = u8(lowerUnit(u16(bytes[index])));
      index = index + 1;
    }
    return runtime.newStringLatin1(move bytes);
  }
  let units = runtime.heap.stringUnits(handle);
  let index: usize = 0;
  while (index < units.length) {
    units[index] = lowerUnit(units[index]);
    index = index + 1;
  }
  return runtime.newStringUnits(move units);
}

function stringRepeat(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "repeat";
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(cellValue(handle));
  const countNumber = runtime.toNumberValue(runtime.argument(argsBase, argc, 0));
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  if (countNumber < 0.0 || countNumber == 1.0 / 0.0) {
    const message: String = "Invalid count value";
    const error = runtime.makeError(ERROR_KIND_RANGE, bytesOf(in message));
    runtime.raise(error);
    return undefinedValue();
  }
  const count: u32 = countNumber != countNumber ? 0 : u32(truncateDouble(countNumber));
  if (narrow(in runtime, handle)) {
    const bytes = runtime.heap.stringStorageBytes(handle);
    let joined = Array<u8>.withCapacity(repeatCapacity(bytes.length, count));
    let repeat: u32 = 0;
    while (repeat < count) {
      appendAll(inout joined, in bytes);
      repeat = repeat + 1;
    }
    return runtime.newStringLatin1(move joined);
  }
  const units = runtime.heap.stringUnits(handle);
  let joined = Array<u16>.withCapacity(repeatCapacity(units.length, count));
  let repeat: u32 = 0;
  while (repeat < count) {
    appendAll(inout joined, in units);
    repeat = repeat + 1;
  }
  return runtime.newStringUnits(move joined);
}

function padBytes(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, atStart: boolean, in method: String): Value {
  const handle = thisStringHandle(inout runtime, thisValue, in method);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(cellValue(handle));
  const target = runtime.toLength(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  const given = runtime.argument(argsBase, argc, 1);
  let fillerHandle: u32 = 0;
  if (!isUndefined(given)) {
    fillerHandle = argumentHandle(inout runtime, given);
    if (runtime.pendingThrow) {
      runtime.popTempRoot();
      return undefinedValue();
    }
  }
  runtime.popTempRoot();
  const length = runtime.heap.stringLength(handle);
  let fillerLength: usize = 1;
  if (fillerHandle != 0) fillerLength = runtime.heap.stringLength(fillerHandle);
  if (usize(target) <= length || fillerLength == 0) return cellValue(handle);
  const missing = usize(target) - length;
  if (narrow(in runtime, handle) && (fillerHandle == 0 || narrow(in runtime, fillerHandle))) {
    let filler = Array<u8>();
    if (fillerHandle == 0) {
      filler.push(32);
    } else {
      filler = runtime.heap.stringStorageBytes(fillerHandle);
    }
    const bytes = runtime.heap.stringStorageBytes(handle);
    let joined = Array<u8>.withCapacity(usize(target));
    if (!atStart) appendAll(inout joined, in bytes);
    let k: usize = 0;
    while (k < missing) {
      joined.push(filler[k % filler.length]);
      k = k + 1;
    }
    if (atStart) appendAll(inout joined, in bytes);
    return runtime.newStringLatin1(move joined);
  }
  let filler = Array<u16>();
  if (fillerHandle == 0) {
    filler.push(32);
  } else {
    filler = runtime.heap.stringUnits(fillerHandle);
  }
  const units = runtime.heap.stringUnits(handle);
  let joined = Array<u16>.withCapacity(usize(target));
  if (!atStart) appendAll(inout joined, in units);
  let k: usize = 0;
  while (k < missing) {
    joined.push(filler[k % filler.length]);
    k = k + 1;
  }
  if (atStart) appendAll(inout joined, in units);
  return runtime.newStringUnits(move joined);
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
  if (!requireCoercible(inout runtime, thisValue, in text)) return undefinedValue();
  const separatorArgument = runtime.argument(argsBase, argc, 0);
  const symbolSplit = runtime.symbolSplit;
  const splitter = symbolMethod(inout runtime, separatorArgument, symbolSplit);
  if (runtime.pendingThrow) return undefinedValue();
  if (!isUndefined(splitter)) {
    let args = Array<Value>();
    args.push(thisValue);
    args.push(runtime.argument(argsBase, argc, 1));
    return runtime.callValue(splitter, separatorArgument, move args);
  }
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(cellValue(handle));
  const result = runtime.heap.allocateArray(0);
  runtime.pushTempRoot(cellValue(result));
  const separatorValue = runtime.argument(argsBase, argc, 0);
  const limitValue = runtime.argument(argsBase, argc, 1);
  const limit: u32 = isUndefined(limitValue) ? 4294967295 : runtime.toLength(limitValue);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    runtime.popTempRoot();
    return undefinedValue();
  }
  if (limit == 0) {
    runtime.popTempRoot();
    runtime.popTempRoot();
    return cellValue(result);
  }
  if (isUndefined(separatorValue)) {
    runtime.heap.arraySet(result, 0, cellValue(handle));
    runtime.popTempRoot();
    runtime.popTempRoot();
    return cellValue(result);
  }
  const separatorHandle = argumentHandle(inout runtime, separatorValue);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    runtime.popTempRoot();
    return undefinedValue();
  }
  const length = runtime.heap.stringLength(handle);
  const separatorLength = runtime.heap.stringLength(separatorHandle);
  // Every piece is a substring of the receiver, cut in storage form.
  if (separatorLength == 0) {
    let index: usize = 0;
    while (index < length && runtime.heap.arrayLength(result) < limit) {
      const count = runtime.heap.arrayLength(result);
      runtime.heap.arraySet(result, count, runtime.substringValue(handle, index, index + 1));
      index = index + 1;
    }
    runtime.popTempRoot();
    runtime.popTempRoot();
    return cellValue(result);
  }
  let cuts = Array<usize>();
  if (narrow(in runtime, handle) && narrow(in runtime, separatorHandle)) {
    const hay = runtime.heap.stringStorageBytes(handle);
    const key = runtime.heap.stringStorageBytes(separatorHandle);
    let searchFrom: usize = 0;
    while (true) {
      const found = findBytes(in hay, in key, searchFrom);
      if (found < 0) break;
      cuts.push(usize(found));
      searchFrom = usize(found) + separatorLength;
    }
  } else {
    const hay = runtime.heap.stringUnits(handle);
    const key = runtime.heap.stringUnits(separatorHandle);
    let searchFrom: usize = 0;
    while (true) {
      const found = findBytes(in hay, in key, searchFrom);
      if (found < 0) break;
      cuts.push(usize(found));
      searchFrom = usize(found) + separatorLength;
    }
  }
  let start: usize = 0;
  let cut: usize = 0;
  while (cut < cuts.length && runtime.heap.arrayLength(result) < limit) {
    const count = runtime.heap.arrayLength(result);
    runtime.heap.arraySet(result, count, runtime.substringValue(handle, start, cuts[cut]));
    start = cuts[cut] + separatorLength;
    cut = cut + 1;
  }
  if (runtime.heap.arrayLength(result) < limit) {
    const count = runtime.heap.arrayLength(result);
    runtime.heap.arraySet(result, count, runtime.substringValue(handle, start, length));
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  return cellValue(result);
}

// replace(pattern, replacement) with a string pattern: the first match.
function stringReplace(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "replace";
  if (!requireCoercible(inout runtime, thisValue, in text)) return undefinedValue();
  const searchArgument = runtime.argument(argsBase, argc, 0);
  const symbolReplace = runtime.symbolReplace;
  const replacer = symbolMethod(inout runtime, searchArgument, symbolReplace);
  if (runtime.pendingThrow) return undefinedValue();
  if (!isUndefined(replacer)) {
    let args = Array<Value>();
    args.push(thisValue);
    args.push(runtime.argument(argsBase, argc, 1));
    return runtime.callValue(replacer, searchArgument, move args);
  }
  const handle = thisStringHandle(inout runtime, thisValue, in text);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(cellValue(handle));
  const patternHandle = argumentHandle(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  runtime.pushTempRoot(cellValue(patternHandle));
  const replacementValue = runtime.argument(argsBase, argc, 1);
  // A string replacement converts before the search; a function is
  // called only on a match.
  let replacementHandle: u32 = 0;
  const functional = runtime.isCallable(replacementValue);
  if (!functional) {
    replacementHandle = argumentHandle(inout runtime, replacementValue);
    if (runtime.pendingThrow) {
      runtime.popTempRoot();
      runtime.popTempRoot();
      return undefinedValue();
    }
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (!functional && narrow(in runtime, handle) && narrow(in runtime, patternHandle) && narrow(in runtime, replacementHandle)) {
    const bytes = runtime.heap.stringStorageBytes(handle);
    const pattern = runtime.heap.stringStorageBytes(patternHandle);
    const found = findBytes(in bytes, in pattern, 0);
    if (found < 0) return cellValue(handle);
    const template = runtime.heap.stringStorageBytes(replacementHandle);
    const replacement = expandReplacement(in template, in pattern, usize(found), in bytes);
    let joined = Array<u8>.withCapacity(bytes.length + replacement.length);
    let k: usize = 0;
    while (k < usize(found)) {
      joined.push(bytes[k]);
      k = k + 1;
    }
    appendAll(inout joined, in replacement);
    k = usize(found) + pattern.length;
    while (k < bytes.length) {
      joined.push(bytes[k]);
      k = k + 1;
    }
    return runtime.newStringLatin1(move joined);
  }
  const bytes = runtime.heap.stringUnits(handle);
  const pattern = runtime.heap.stringUnits(patternHandle);
  const found = findBytes(in bytes, in pattern, 0);
  if (found < 0) return cellValue(handle);
  const replacement = replacementFor(inout runtime, replacementValue, in pattern, usize(found), in bytes);
  if (runtime.pendingThrow) return undefinedValue();
  let joined = sliceBytes(in bytes, 0, usize(found));
  appendAll(inout joined, in replacement);
  const rest = sliceFrom(in bytes, usize(found) + pattern.length);
  appendAll(inout joined, in rest);
  return runtime.newStringUnits(move joined);
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
  runtime.defineOwnAttr(stringProto, atomPrimitive, runtime.internLatin1Value(Array<u8>()), PROP_NONE);
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
  const matchText: String = "match";
  runtime.defineMethod(stringProto, in matchText, stringMatch, 1);
  const matchAllText: String = "matchAll";
  runtime.defineMethod(stringProto, in matchAllText, stringMatchAll, 1);
  const searchText: String = "search";
  runtime.defineMethod(stringProto, in searchText, stringSearch, 1);
  const replaceText: String = "replace";
  runtime.defineMethod(stringProto, in replaceText, stringReplace, 2);
  const localeCompareText: String = "localeCompare";
  runtime.defineMethod(stringProto, in localeCompareText, stringLocaleCompare, 1);
}
