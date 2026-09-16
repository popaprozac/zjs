// Global functions: eval and the number-parsing conveniences.
import { Value, undefinedValue, booleanValue, doubleValue, int32Value, cellValue, asCell, isNumber } from "../value.zs";
import { thread } from "std/thread";
import { Runtime, ERROR_KIND_SYNTAX, stringToNumber, toNumber, toInt32, isIntegralDouble } from "../runtime.zs";
import { isJsSpace, codePointAt, isHighSurrogate, isLowSurrogate, pushCodePoint, utf8Length } from "../text.zs";
import { parseProgram } from "../parser.zs";
import { compileProgram } from "../compiler.zs";

// eval(source): global evaluation of a string; anything else returns
// as-is. The program runs in the global scope -- a direct eval does not
// see the caller's locals yet -- and its completion value is the result.
function evalSource(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const first = runtime.argument(argsBase, argc, 0);
  if (!runtime.isStringValue(first)) return first;
  // The source boundary: the parser reads UTF-8 bytes; a lone surrogate
  // travels in its generalized three-byte form and comes back as itself.
  const source = runtime.heap.stringWtf8(asCell(first));
  const parsed = parseProgram(move source, false);
  if (parsed.hadError) {
    const message: String = "parse error";
    const error = runtime.syntaxError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const functionIndex = compileProgram(in parsed.parser, parsed.root, inout runtime);
  if (functionIndex < 0) {
    const message: String = "compile error";
    const error = runtime.syntaxError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const outcome = runtime.run(u32(functionIndex));
  if (outcome.isThrow) {
    runtime.raise(outcome.value);
    return undefinedValue();
  }
  return outcome.value;
}

function isNaNGlobal(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const number = runtime.toNumberValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  return booleanValue(number != number);
}

function isFiniteGlobal(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const number = runtime.toNumberValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  return booleanValue(number == number && number != 1.0 / 0.0 && number != -1.0 / 0.0);
}

// parseFloat: the longest prefix that is a decimal literal (with an
// optional sign, or Infinity), after leading whitespace; NaN if none.
function parseFloatGlobal(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const bytes = runtime.heap.stringUnits(asCell(text));
  let start: usize = 0;
  while (start < bytes.length && isJsSpace(bytes[start])) { start = start + 1; }
  let end = start;
  if (end < bytes.length && (bytes[end] == 43 || bytes[end] == 45)) end = end + 1;
  const digitsStart = end;
  // Infinity
  const infinity: String = "Infinity";
  if (matchesAt(in bytes, end, infinity)) {
    const negative = digitsStart > start && bytes[start] == 45;
    return doubleValue(negative ? -1.0 / 0.0 : 1.0 / 0.0);
  }
  let sawDigit = false;
  while (end < bytes.length && bytes[end] >= 48 && bytes[end] <= 57) { end = end + 1; sawDigit = true; }
  if (end < bytes.length && bytes[end] == 46) {
    let after = end + 1;
    let fractionDigits = false;
    while (after < bytes.length && bytes[after] >= 48 && bytes[after] <= 57) { after = after + 1; fractionDigits = true; }
    if (sawDigit || fractionDigits) {
      end = after;
      sawDigit = true;
    }
  }
  if (!sawDigit) return doubleValue(toNumber(undefinedValue()));
  if (end < bytes.length && (bytes[end] == 101 || bytes[end] == 69)) {
    let after = end + 1;
    if (after < bytes.length && (bytes[after] == 43 || bytes[after] == 45)) after = after + 1;
    let exponentDigits = false;
    while (after < bytes.length && bytes[after] >= 48 && bytes[after] <= 57) { after = after + 1; exponentDigits = true; }
    if (exponentDigits) end = after;
  }
  let prefix = Array<u8>();
  let index = start;
  while (index < end) {
    prefix.push(u8(bytes[index]));
    index = index + 1;
  }
  return numberResult(stringToNumber(in prefix));
}

// parseInt(string, radix): digits of the radix after whitespace and an
// optional sign; a 0x prefix selects 16 when the radix allows it.
function parseIntGlobal(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const radixNumber = runtime.toNumberValue(runtime.argument(argsBase, argc, 1));
  if (runtime.pendingThrow) return undefinedValue();
  let radix = toInt32(doubleValue(radixNumber));
  const bytes = runtime.heap.stringUnits(asCell(text));
  let index: usize = 0;
  while (index < bytes.length && isJsSpace(bytes[index])) { index = index + 1; }
  let negative = false;
  if (index < bytes.length && (bytes[index] == 43 || bytes[index] == 45)) {
    negative = bytes[index] == 45;
    index = index + 1;
  }
  let stripPrefix = true;
  if (radix != 0) {
    if (radix < 2 || radix > 36) return doubleValue(toNumber(undefinedValue()));
    if (radix != 16) stripPrefix = false;
  } else {
    radix = 10;
  }
  if (stripPrefix && index + 1 < bytes.length && bytes[index] == 48 && (bytes[index + 1] == 120 || bytes[index + 1] == 88)) {
    index = index + 2;
    radix = 16;
  }
  let value: f64 = 0.0;
  let sawDigit = false;
  while (index < bytes.length) {
    const digit = digitValue(bytes[index]);
    if (digit < 0 || digit >= radix) break;
    value = value * f64(radix) + f64(digit);
    sawDigit = true;
    index = index + 1;
  }
  if (!sawDigit) return doubleValue(toNumber(undefinedValue()));
  return numberResult(negative ? -value : value);
}

function digitValue(unit: u16): i32 {
  if (unit >= 48 && unit <= 57) return i32(unit - 48);
  if (unit >= 97 && unit <= 122) return i32(unit - 97) + 10;
  if (unit >= 65 && unit <= 90) return i32(unit - 65) + 10;
  return -1;
}

function matchesAt(in bytes: Array<u16>, at: usize, word: String): boolean {
  const wordBytes = word.copyBytes(0, word.byteLength);
  const length = wordBytes.byteLength;
  if (at + length > bytes.length) return false;
  let index: usize = 0;
  while (index < length) {
    if (bytes[at + index] != u16(wordBytes.byteAt(index))) return false;
    index = index + 1;
  }
  return true;
}

// An int32 when the double is one, as the engine's arithmetic does.
function numberResult(value: f64): Value {
  if (value >= -2147483648.0 && value <= 2147483647.0 && isIntegralDouble(value)) {
    if (value == 0.0 && 1.0 / value < 0.0) return doubleValue(value);
    return int32Value(i32(value));
  }
  return doubleValue(value);
}

// --- URI encoding ---
//
// Encoding takes code points (a surrogate pair combined; a lone
// surrogate is a URIError), writes their UTF-8 bytes as percent escapes,
// and yields ASCII. Decoding reads the escapes back as bytes, which must
// form well-formed UTF-8, and yields the code points' units.

function isUriUnreserved(unit: u16): boolean {
  if (unit >= 65 && unit <= 90) return true;
  if (unit >= 97 && unit <= 122) return true;
  if (unit >= 48 && unit <= 57) return true;
  return unit == 45 || unit == 95 || unit == 46 || unit == 33 || unit == 126 || unit == 42 || unit == 39 || unit == 40 || unit == 41;
}

function isUriReserved(unit: u16): boolean {
  return unit == 59 || unit == 47 || unit == 63 || unit == 58 || unit == 64 || unit == 38 || unit == 61 || unit == 43 || unit == 36 || unit == 44 || unit == 35;
}

function hexDigit(value: u8): u8 {
  return value < 10 ? 48 + value : 55 + value;
}

function hexValue(unit: u16): i32 {
  if (unit >= 48 && unit <= 57) return i32(unit - 48);
  if (unit >= 65 && unit <= 70) return i32(unit - 55);
  if (unit >= 97 && unit <= 102) return i32(unit - 87);
  return -1;
}

function malformed(inout runtime: Runtime): Value {
  const message: String = "URI malformed";
  const error = runtime.uriError(in message);
  runtime.raise(error);
  return undefinedValue();
}

function pushEscapedUtf8(inout encoded: Array<u8>, codePoint: u32): void {
  let sequence = Array<u8>();
  if (codePoint < 0x80) {
    sequence.push(u8(codePoint));
  } else if (codePoint < 0x800) {
    sequence.push(u8(0xC0 | (codePoint >> 6)));
    sequence.push(u8(0x80 | (codePoint & 0x3F)));
  } else if (codePoint < 0x10000) {
    sequence.push(u8(0xE0 | (codePoint >> 12)));
    sequence.push(u8(0x80 | ((codePoint >> 6) & 0x3F)));
    sequence.push(u8(0x80 | (codePoint & 0x3F)));
  } else {
    sequence.push(u8(0xF0 | (codePoint >> 18)));
    sequence.push(u8(0x80 | ((codePoint >> 12) & 0x3F)));
    sequence.push(u8(0x80 | ((codePoint >> 6) & 0x3F)));
    sequence.push(u8(0x80 | (codePoint & 0x3F)));
  }
  let k: usize = 0;
  while (k < sequence.length) {
    encoded.push(37);
    encoded.push(hexDigit(sequence[k] >> 4));
    encoded.push(hexDigit(sequence[k] & 15));
    k = k + 1;
  }
}

function uriEncode(inout runtime: Runtime, argsBase: u32, argc: u32, keepReserved: boolean): Value {
  const text = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const units = runtime.heap.stringUnits(asCell(text));
  let encoded = Array<u8>();
  let index: usize = 0;
  while (index < units.length) {
    const unit = units[index];
    if (isUriUnreserved(unit) || (keepReserved && isUriReserved(unit))) {
      encoded.push(u8(unit));
      index = index + 1;
      continue;
    }
    if (isLowSurrogate(unit)) return malformed(inout runtime);
    if (isHighSurrogate(unit) && (index + 1 >= units.length || !isLowSurrogate(units[index + 1]))) return malformed(inout runtime);
    const codePoint = codePointAt(in units, index);
    pushEscapedUtf8(inout encoded, codePoint);
    index = index + (codePoint >= 0x10000 ? 2 : 1);
  }
  return runtime.newStringLatin1(move encoded);
}

function uriDecode(inout runtime: Runtime, argsBase: u32, argc: u32, keepReserved: boolean): Value {
  const text = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const units = runtime.heap.stringUnits(asCell(text));
  let decoded = Array<u16>();
  let index: usize = 0;
  while (index < units.length) {
    const unit = units[index];
    if (unit != 37) {
      decoded.push(unit);
      index = index + 1;
      continue;
    }
    // One escape, then the rest of its UTF-8 sequence, all escaped.
    let sequence = Array<u8>();
    let cursor = index;
    let needed: usize = 1;
    while (sequence.length < needed) {
      if (cursor + 2 >= units.length || units[cursor] != 37) return malformed(inout runtime);
      const high = hexValue(units[cursor + 1]);
      const low = hexValue(units[cursor + 2]);
      if (high < 0 || low < 0) return malformed(inout runtime);
      const value = u8(high * 16 + low);
      if (sequence.length == 0 && value >= 0x80) {
        if (value >= 0xC2 && value <= 0xDF) {
          needed = 2;
        } else if (value >= 0xE0 && value <= 0xEF) {
          needed = 3;
        } else if (value >= 0xF0 && value <= 0xF4) {
          needed = 4;
        } else {
          return malformed(inout runtime);
        }
      }
      sequence.push(value);
      cursor = cursor + 3;
    }
    if (needed > 1) {
      if (utf8Length(in sequence, 0) != needed) return malformed(inout runtime);
      let codePoint: u32 = u32(sequence[0]) & u32(0x3F >> (needed - 1));
      let k: usize = 1;
      while (k < needed) {
        codePoint = (codePoint << 6) | u32(sequence[k] & 0x3F);
        k = k + 1;
      }
      pushCodePoint(inout decoded, codePoint);
    } else if (keepReserved && (isUriReserved(u16(sequence[0])) || sequence[0] == 35)) {
      // decodeURI leaves a reserved character's escape as written.
      let k: usize = 0;
      while (k < 3) {
        decoded.push(units[index + k]);
        k = k + 1;
      }
    } else {
      decoded.push(u16(sequence[0]));
    }
    index = cursor;
  }
  return runtime.newStringUnits(move decoded);
}

function encodeURIFunction(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return uriEncode(inout runtime, argsBase, argc, true);
}
function encodeURIComponentFunction(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return uriEncode(inout runtime, argsBase, argc, false);
}
function decodeURIFunction(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return uriDecode(inout runtime, argsBase, argc, true);
}
function decodeURIComponentFunction(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return uriDecode(inout runtime, argsBase, argc, false);
}

export function installGlobals(inout runtime: Runtime): void {
  const encodeText: String = "encodeURI";
  const encodeFn = runtime.defineHostFunction(encodeURIFunction, undefinedValue(), 1, in encodeText);
  runtime.setGlobal("encodeURI", cellValue(encodeFn));
  const encodeComponentText: String = "encodeURIComponent";
  const encodeComponentFn = runtime.defineHostFunction(encodeURIComponentFunction, undefinedValue(), 1, in encodeComponentText);
  runtime.setGlobal("encodeURIComponent", cellValue(encodeComponentFn));
  const decodeText: String = "decodeURI";
  const decodeFn = runtime.defineHostFunction(decodeURIFunction, undefinedValue(), 1, in decodeText);
  runtime.setGlobal("decodeURI", cellValue(decodeFn));
  const decodeComponentText: String = "decodeURIComponent";
  const decodeComponentFn = runtime.defineHostFunction(decodeURIComponentFunction, undefinedValue(), 1, in decodeComponentText);
  runtime.setGlobal("decodeURIComponent", cellValue(decodeComponentFn));
  const globalObject = runtime.globalObject;
  const evalText: String = "eval";
  const evalFn = runtime.defineHostFunction(evalSource, undefinedValue(), 1, in evalText);
  runtime.setGlobal("eval", cellValue(evalFn));
  const isNaNText: String = "isNaN";
  runtime.setGlobal("isNaN", cellValue(runtime.defineHostFunction(isNaNGlobal, undefinedValue(), 1, in isNaNText)));
  const isFiniteText: String = "isFinite";
  runtime.setGlobal("isFinite", cellValue(runtime.defineHostFunction(isFiniteGlobal, undefinedValue(), 1, in isFiniteText)));
  const parseFloatText: String = "parseFloat";
  runtime.setGlobal("parseFloat", cellValue(runtime.defineHostFunction(parseFloatGlobal, undefinedValue(), 1, in parseFloatText)));
  const parseIntText: String = "parseInt";
  runtime.setGlobal("parseInt", cellValue(runtime.defineHostFunction(parseIntGlobal, undefinedValue(), 2, in parseIntText)));
}
