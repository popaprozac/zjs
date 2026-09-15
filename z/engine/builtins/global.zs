// Global functions: eval and the number-parsing conveniences.
import { Value, undefinedValue, booleanValue, doubleValue, int32Value, cellValue, asCell, isNumber } from "../value.zs";
import { thread } from "std/thread";
import { Runtime, ERROR_KIND_SYNTAX, stringToNumber, toNumber, toInt32, isIntegralDouble, utf8SequenceLength } from "../runtime.zs";
import { parseProgram } from "../parser.zs";
import { compileProgram } from "../compiler.zs";

// eval(source): global evaluation of a string; anything else returns
// as-is. The program runs in the global scope -- a direct eval does not
// see the caller's locals yet -- and its completion value is the result.
function evalSource(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const first = runtime.argument(argsBase, argc, 0);
  if (!runtime.isStringValue(first)) return first;
  const source = runtime.heap.stringBytes(asCell(first));
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
  const bytes = runtime.heap.stringBytes(asCell(text));
  let start: usize = 0;
  while (start < bytes.length && isJsWhitespace(bytes[start])) { start = start + 1; }
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
    prefix.push(bytes[index]);
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
  const bytes = runtime.heap.stringBytes(asCell(text));
  let index: usize = 0;
  while (index < bytes.length && isJsWhitespace(bytes[index])) { index = index + 1; }
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

function digitValue(byte: u8): i32 {
  if (byte >= 48 && byte <= 57) return i32(byte - 48);
  if (byte >= 97 && byte <= 122) return i32(byte - 97) + 10;
  if (byte >= 65 && byte <= 90) return i32(byte - 65) + 10;
  return -1;
}

function isJsWhitespace(byte: u8): boolean {
  return byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 11 || byte == 12;
}

function matchesAt(in bytes: Array<u8>, at: usize, word: String): boolean {
  const wordBytes = word.copyBytes(0, word.byteLength);
  const length = wordBytes.byteLength;
  if (at + length > bytes.length) return false;
  let index: usize = 0;
  while (index < length) {
    if (bytes[at + index] != wordBytes.byteAt(index)) return false;
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
// Strings are bytes, so the encoding is percent-escaping of bytes and
// the decoding is the reverse; the multi-byte sequences must be
// well-formed UTF-8 either way, else a URIError.

function isUriUnreserved(byte: u8): boolean {
  if (byte >= 65 && byte <= 90) return true;
  if (byte >= 97 && byte <= 122) return true;
  if (byte >= 48 && byte <= 57) return true;
  return byte == 45 || byte == 95 || byte == 46 || byte == 33 || byte == 126 || byte == 42 || byte == 39 || byte == 40 || byte == 41;
}

function isUriReserved(byte: u8): boolean {
  return byte == 59 || byte == 47 || byte == 63 || byte == 58 || byte == 64 || byte == 38 || byte == 61 || byte == 43 || byte == 36 || byte == 44 || byte == 35;
}

function hexDigit(value: u8): u8 {
  return value < 10 ? 48 + value : 55 + value;
}

function hexValue(byte: u8): i32 {
  if (byte >= 48 && byte <= 57) return i32(byte - 48);
  if (byte >= 65 && byte <= 70) return i32(byte - 55);
  if (byte >= 97 && byte <= 102) return i32(byte - 87);
  return -1;
}

function uriEncode(inout runtime: Runtime, argsBase: u32, argc: u32, keepReserved: boolean): Value {
  const text = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const bytes = runtime.heap.stringBytes(asCell(text));
  let encoded = Array<u8>();
  let index: usize = 0;
  while (index < bytes.length) {
    const byte = bytes[index];
    if (isUriUnreserved(byte) || (keepReserved && isUriReserved(byte))) {
      encoded.push(byte);
      index = index + 1;
      continue;
    }
    let length: usize = 1;
    if (byte >= 0x80) {
      const sequence = utf8SequenceLength(in bytes, index);
      if (sequence <= 0) {
        const message: String = "URI malformed";
        const error = runtime.uriError(in message);
        runtime.raise(error);
        return undefinedValue();
      }
      length = usize(sequence);
    }
    let k: usize = 0;
    while (k < length) {
      const escaped = bytes[index + k];
      encoded.push(37);
      encoded.push(hexDigit(escaped >> 4));
      encoded.push(hexDigit(escaped & 15));
      k = k + 1;
    }
    index = index + length;
  }
  return runtime.newString(move encoded);
}

function uriDecode(inout runtime: Runtime, argsBase: u32, argc: u32, keepReserved: boolean): Value {
  const text = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const bytes = runtime.heap.stringBytes(asCell(text));
  let decoded = Array<u8>();
  let index: usize = 0;
  while (index < bytes.length) {
    const byte = bytes[index];
    if (byte != 37) {
      decoded.push(byte);
      index = index + 1;
      continue;
    }
    // One escape, then the rest of its UTF-8 sequence, all escaped.
    let sequence = Array<u8>();
    let cursor = index;
    let needed: usize = 1;
    while (sequence.length < needed) {
      if (cursor + 2 >= bytes.length || bytes[cursor] != 37) {
        const message: String = "URI malformed";
        const error = runtime.uriError(in message);
        runtime.raise(error);
        return undefinedValue();
      }
      const high = hexValue(bytes[cursor + 1]);
      const low = hexValue(bytes[cursor + 2]);
      if (high < 0 || low < 0) {
        const message: String = "URI malformed";
        const error = runtime.uriError(in message);
        runtime.raise(error);
        return undefinedValue();
      }
      const value = u8(high * 16 + low);
      if (sequence.length == 0 && value >= 0x80) {
        if (value >= 0xC2 && value <= 0xDF) { needed = 2; } else if (value >= 0xE0 && value <= 0xEF) { needed = 3; } else if (value >= 0xF0 && value <= 0xF4) { needed = 4; } else {
          const message: String = "URI malformed";
          const error = runtime.uriError(in message);
          runtime.raise(error);
          return undefinedValue();
        }
      }
      sequence.push(value);
      cursor = cursor + 3;
    }
    if (needed > 1 && utf8SequenceLength(in sequence, 0) != i32(needed)) {
      const message: String = "URI malformed";
      const error = runtime.uriError(in message);
      runtime.raise(error);
      return undefinedValue();
    }
    if (needed == 1 && keepReserved && (isUriReserved(sequence[0]) || sequence[0] == 35)) {
      // decodeURI leaves a reserved character's escape as written.
      let k: usize = 0;
      while (k < 3) {
        decoded.push(bytes[index + k]);
        k = k + 1;
      }
    } else {
      let k: usize = 0;
      while (k < sequence.length) {
        decoded.push(sequence[k]);
        k = k + 1;
      }
    }
    index = cursor;
  }
  return runtime.newString(move decoded);
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
