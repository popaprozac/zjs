// JSON.parse and JSON.stringify over byte strings.
import { unitsOf, isHighSurrogate, isLowSurrogate } from "../text.zs";
import { thread } from "std/thread";
import { Value, undefinedValue, nullValue, booleanValue, int32Value, doubleValue, cellValue, asCell, isCell, isUndefined, isNull, isBoolean, isTrue, isNumber } from "../value.zs";
import { Runtime, ERROR_KIND_SYNTAX, toNumber, isIntegralDouble, truncateDouble, stringToNumber } from "../runtime.zs";
import { bytesOf, PROP_ENUMERABLE, PROP_CONFIGURABLE } from "../heap.zs";

// --- parse ---

struct JsonParser {
  bytes: Array<u16>;
  position: usize;
  failed: boolean;
}

function skipSpace(inout parser: JsonParser): void {
  while (parser.position < parser.bytes.length) {
    const byte = parser.bytes[parser.position];
    if (byte != 32 && byte != 9 && byte != 10 && byte != 13) return;
    parser.position = parser.position + 1;
  }
}

function peekByte(in parser: JsonParser): i32 {
  if (parser.position >= parser.bytes.length) return -1;
  return i32(parser.bytes[parser.position]);
}

function expectWord(inout parser: JsonParser, in word: String): boolean {
  const wordBytes = unitsOf(in word);
  let index: usize = 0;
  while (index < wordBytes.length) {
    if (parser.position + index >= parser.bytes.length || parser.bytes[parser.position + index] != wordBytes[index]) {
      parser.failed = true;
      return false;
    }
    index = index + 1;
  }
  parser.position = parser.position + wordBytes.length;
  return true;
}

function hexDigit(byte: i32): i32 {
  if (byte >= 48 && byte <= 57) return byte - 48;
  if (byte >= 97 && byte <= 102) return byte - 97 + 10;
  if (byte >= 65 && byte <= 70) return byte - 65 + 10;
  return -1;
}


function parseHex4(inout parser: JsonParser): u32 {
  let value: u32 = 0;
  let count: u32 = 0;
  while (count < 4) {
    const digit = hexDigit(peekByte(in parser));
    if (digit < 0) {
      parser.failed = true;
      return 0;
    }
    value = value * 16 + u32(digit);
    parser.position = parser.position + 1;
    count = count + 1;
  }
  return value;
}

// A JSON string body after the opening quote; escapes decoded, surrogate
// pairs combined.
function parseStringBody(inout parser: JsonParser): Array<u16> {
  let text = Array<u16>();
  while (true) {
    const byte = peekByte(in parser);
    if (byte < 0) {
      parser.failed = true;
      return text;
    }
    parser.position = parser.position + 1;
    if (byte == 34) return text;
    if (byte < 32) {
      parser.failed = true;
      return text;
    }
    if (byte != 92) {
      text.push(u16(byte));
      continue;
    }
    const escape = peekByte(in parser);
    parser.position = parser.position + 1;
    if (escape == 34) {
      text.push(34);
    } else if (escape == 92) {
      text.push(92);
    } else if (escape == 47) {
      text.push(47);
    } else if (escape == 98) {
      text.push(8);
    } else if (escape == 102) {
      text.push(12);
    } else if (escape == 110) {
      text.push(10);
    } else if (escape == 114) {
      text.push(13);
    } else if (escape == 116) {
      text.push(9);
    } else if (escape == 117) {
      // One escape is one unit; a pair written as two escapes is a pair.
      const unit = parseHex4(inout parser);
      if (parser.failed) return text;
      text.push(u16(unit));
    } else {
      parser.failed = true;
      return text;
    }
  }
  return text;
}

function numberValue(number: f64): Value {
  if (number >= -2147483648.0 && number <= 2147483647.0 && isIntegralDouble(number)) {
    if (number == 0.0 && 1.0 / number < 0.0) return doubleValue(number);
    return int32Value(i32(number));
  }
  return doubleValue(number);
}

function isDigitAt(in parser: JsonParser): boolean {
  const byte = peekByte(in parser);
  return byte >= 48 && byte <= 57;
}

function parseNumber(inout parser: JsonParser): Value {
  const start = parser.position;
  if (peekByte(in parser) == 45) parser.position = parser.position + 1;
  const first = peekByte(in parser);
  if (first == 48) {
    parser.position = parser.position + 1;
  } else if (first >= 49 && first <= 57) {
    while (isDigitAt(in parser)) { parser.position = parser.position + 1; }
  } else {
    parser.failed = true;
    return undefinedValue();
  }
  if (peekByte(in parser) == 46) {
    parser.position = parser.position + 1;
    if (!isDigitAt(in parser)) {
      parser.failed = true;
      return undefinedValue();
    }
    while (isDigitAt(in parser)) { parser.position = parser.position + 1; }
  }
  if (peekByte(in parser) == 101 || peekByte(in parser) == 69) {
    parser.position = parser.position + 1;
    if (peekByte(in parser) == 43 || peekByte(in parser) == 45) parser.position = parser.position + 1;
    if (!isDigitAt(in parser)) {
      parser.failed = true;
      return undefinedValue();
    }
    while (isDigitAt(in parser)) { parser.position = parser.position + 1; }
  }
  let digits = Array<u8>();
  let index = start;
  while (index < parser.position) {
    digits.push(u8(parser.bytes[index]));
    index = index + 1;
  }
  return numberValue(stringToNumber(in digits));
}

function parseValue(inout runtime: Runtime, inout parser: JsonParser, depth: u32): Value {
  if (depth > 512) {
    parser.failed = true;
    return undefinedValue();
  }
  skipSpace(inout parser);
  const byte = peekByte(in parser);
  if (byte == 123) {
    parser.position = parser.position + 1;
    const objectProto = runtime.objectProto;
    const object = runtime.heap.allocateObject(objectProto);
    runtime.pushTempRoot(cellValue(object));
    skipSpace(inout parser);
    if (peekByte(in parser) == 125) {
      parser.position = parser.position + 1;
      runtime.popTempRoot();
      return cellValue(object);
    }
    while (true) {
      skipSpace(inout parser);
      if (peekByte(in parser) != 34) {
        parser.failed = true;
        runtime.popTempRoot();
        return undefinedValue();
      }
      parser.position = parser.position + 1;
      const key = parseStringBody(inout parser);
      if (parser.failed) {
        runtime.popTempRoot();
        return undefinedValue();
      }
      skipSpace(inout parser);
      if (peekByte(in parser) != 58) {
        parser.failed = true;
        runtime.popTempRoot();
        return undefinedValue();
      }
      parser.position = parser.position + 1;
      const value = parseValue(inout runtime, inout parser, depth + 1);
      if (parser.failed) {
        runtime.popTempRoot();
        return undefinedValue();
      }
      const atom = runtime.internUnits(move key);
      runtime.heap.objectSet(object, atom, value);
      skipSpace(inout parser);
      const next = peekByte(in parser);
      parser.position = parser.position + 1;
      if (next == 125) break;
      if (next != 44) {
        parser.failed = true;
        runtime.popTempRoot();
        return undefinedValue();
      }
    }
    runtime.popTempRoot();
    return cellValue(object);
  }
  if (byte == 91) {
    parser.position = parser.position + 1;
    const array = runtime.heap.allocateArray(0);
    runtime.pushTempRoot(cellValue(array));
    skipSpace(inout parser);
    if (peekByte(in parser) == 93) {
      parser.position = parser.position + 1;
      runtime.popTempRoot();
      return cellValue(array);
    }
    while (true) {
      const element = parseValue(inout runtime, inout parser, depth + 1);
      if (parser.failed) {
        runtime.popTempRoot();
        return undefinedValue();
      }
      const count = runtime.heap.arrayLength(array);
      runtime.heap.arraySet(array, count, element);
      skipSpace(inout parser);
      const next = peekByte(in parser);
      parser.position = parser.position + 1;
      if (next == 93) break;
      if (next != 44) {
        parser.failed = true;
        runtime.popTempRoot();
        return undefinedValue();
      }
    }
    runtime.popTempRoot();
    return cellValue(array);
  }
  if (byte == 34) {
    parser.position = parser.position + 1;
    const text = parseStringBody(inout parser);
    if (parser.failed) return undefinedValue();
    return runtime.newStringUnits(move text);
  }
  if (byte == 116) {
    const word: String = "true";
    if (!expectWord(inout parser, in word)) return undefinedValue();
    return booleanValue(true);
  }
  if (byte == 102) {
    const word: String = "false";
    if (!expectWord(inout parser, in word)) return undefinedValue();
    return booleanValue(false);
  }
  if (byte == 110) {
    const word: String = "null";
    if (!expectWord(inout parser, in word)) return undefinedValue();
    return nullValue();
  }
  if (byte == 45 || (byte >= 48 && byte <= 57)) return parseNumber(inout parser);
  parser.failed = true;
  return undefinedValue();
}

// InternalizeJSONProperty: the reviver walks the result bottom-up.
function revive(inout runtime: Runtime, holder: Value, key: Value, reviver: Value): Value {
  const value = runtime.getProperty(holder, key);
  if (runtime.pendingThrow) return undefinedValue();
  if (runtime.isObjectLike(value)) {
    runtime.pushTempRoot(value);
    const keys = runtime.ownKeys(value);
    let index: usize = 0;
    while (index < keys.length) {
      const childKey = keys[index];
      if (runtime.isStringValue(childKey)) {
        const desc = runtime.getOwnDescriptor(value, childKey);
        if (desc.present && (desc.attr & PROP_ENUMERABLE) != 0) {
          const revived = revive(inout runtime, value, childKey, reviver);
          if (runtime.pendingThrow) {
            runtime.popTempRoot();
            return undefinedValue();
          }
          if (isUndefined(revived)) {
            runtime.deleteProperty(value, childKey);
          } else {
            let change = runtime.emptyInput();
            change.hasValue = true;
            change.value = revived;
            change.hasWritable = true;
            change.writable = true;
            change.hasEnumerable = true;
            change.enumerable = true;
            change.hasConfigurable = true;
            change.configurable = true;
            runtime.defineOwnProperty(value, childKey, change);
          }
        }
      }
      index = index + 1;
    }
    runtime.popTempRoot();
  }
  return runtime.callValue2(reviver, holder, key, value);
}

function jsonParse(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  let parser = JsonParser({ bytes: runtime.heap.stringUnits(asCell(text)), position: 0, failed: false });
  const value = parseValue(inout runtime, inout parser, 0);
  skipSpace(inout parser);
  if (parser.failed || parser.position != parser.bytes.length) {
    const message: String = "Unexpected token in JSON";
    const error = runtime.makeError(ERROR_KIND_SYNTAX, bytesOf(in message));
    runtime.raise(error);
    return undefinedValue();
  }
  const reviver = runtime.argument(argsBase, argc, 1);
  if (!runtime.isCallable(reviver)) return value;
  const objectProto = runtime.objectProto;
  const holder = runtime.heap.allocateObject(objectProto);
  const emptyKey = runtime.internLatin1Value(Array<u8>());
  const emptyAtom = runtime.propertyKey(emptyKey);
  runtime.heap.objectSet(holder, emptyAtom, value);
  return revive(inout runtime, cellValue(holder), emptyKey, reviver);
}

// --- stringify ---

struct Stringifier {
  indent: Array<u16>;
  gap: Array<u16>;
  replacer: Value;
  allowed: Array<u32>;
  useAllowed: boolean;
  stack: Array<u32>;
  stackCount: usize;
}

function hexChar(digit: u32): u16 {
  if (digit < 10) return u16(48 + digit);
  return u16(87 + digit);
}

// Whether the unit at `index` is a surrogate without its partner.
function lone(in bytes: Array<u16>, index: usize): boolean {
  const unit = bytes[index];
  if (isHighSurrogate(unit)) return index + 1 >= bytes.length || !isLowSurrogate(bytes[index + 1]);
  if (isLowSurrogate(unit)) return index == 0 || !isHighSurrogate(bytes[index - 1]);
  return false;
}

function quote(inout text: Array<u16>, in bytes: Array<u16>): void {
  text.push(34);
  let index: usize = 0;
  while (index < bytes.length) {
    const byte = bytes[index];
    if (byte == 34 || byte == 92) {
      text.push(92);
      text.push(byte);
    } else if (byte == 8) {
      text.push(92);
      text.push(98);
    } else if (byte == 12) {
      text.push(92);
      text.push(102);
    } else if (byte == 10) {
      text.push(92);
      text.push(110);
    } else if (byte == 13) {
      text.push(92);
      text.push(114);
    } else if (byte == 9) {
      text.push(92);
      text.push(116);
    } else if (byte < 32 || lone(in bytes, index)) {
      // Control characters, and a lone surrogate (JSON text is
      // well-formed), as \uXXXX.
      text.push(92);
      text.push(117);
      text.push(hexChar(u32(byte) >> 12));
      text.push(hexChar((u32(byte) >> 8) & 15));
      text.push(hexChar((u32(byte) >> 4) & 15));
      text.push(hexChar(u32(byte) & 15));
    } else {
      text.push(byte);
    }
    index = index + 1;
  }
  text.push(34);
}

function appendAll(inout text: Array<u16>, in more: Array<u16>): void {
  let index: usize = 0;
  while (index < more.length) {
    text.push(more[index]);
    index = index + 1;
  }
}

function copyBytes(in bytes: Array<u16>): Array<u16> {
  let copied = Array<u16>.withCapacity(bytes.length);
  let index: usize = 0;
  while (index < bytes.length) {
    copied.push(bytes[index]);
    index = index + 1;
  }
  return copied;
}

function pushNull(inout text: Array<u16>): void {
  text.push(110);
  text.push(117);
  text.push(108);
  text.push(108);
}

// SerializeJSONProperty: returns false when the value has no JSON form
// (undefined, functions, symbols), leaving `text` untouched.
function serialize(inout runtime: Runtime, inout state: Stringifier, holder: Value, key: Value, inout text: Array<u16>): boolean {
  let value = runtime.getProperty(holder, key);
  if (runtime.pendingThrow) return false;
  if (runtime.isObjectLike(value)) {
    const toJSONText: String = "toJSON";
    const toJSONKey = runtime.internText(in toJSONText);
    const toJSON = runtime.getProperty(value, toJSONKey);
    if (runtime.pendingThrow) return false;
    if (runtime.isCallable(toJSON)) {
      let args = Array<Value>();
      args.push(runtime.toStringValue(key));
      value = runtime.callValue(toJSON, value, move args);
      if (runtime.pendingThrow) return false;
    }
  }
  if (runtime.isCallable(state.replacer)) {
    let args = Array<Value>();
    args.push(runtime.toStringValue(key));
    args.push(value);
    const replacer = state.replacer;
    value = runtime.callValue(replacer, holder, move args);
    if (runtime.pendingThrow) return false;
  }
  // Wrappers unwrap.
  if (runtime.isObjectLike(value) && runtime.heap.isObject(asCell(value))) {
    const wrapped = runtime.wrappedPrimitive(asCell(value));
    if (isNumber(wrapped)) {
      const number = runtime.toNumberValue(value);
      if (runtime.pendingThrow) return false;
      value = doubleValue(number);
    } else if (runtime.isStringValue(wrapped)) {
      value = runtime.toStringValue(value);
      if (runtime.pendingThrow) return false;
    } else if (isBoolean(wrapped)) {
      value = wrapped;
    }
  }
  if (isNull(value)) {
    pushNull(inout text);
    return true;
  }
  if (isBoolean(value)) {
    const boolText: String = isTrue(value) ? "true" : "false";
    const boolBytes = unitsOf(in boolText);
    appendAll(inout text, in boolBytes);
    return true;
  }
  if (runtime.isStringValue(value)) {
    const valueBytes = runtime.heap.stringUnits(asCell(value));
    quote(inout text, in valueBytes);
    return true;
  }
  if (isNumber(value)) {
    const number = toNumber(value);
    if (number != number || number == 1.0 / 0.0 || number == -1.0 / 0.0) {
      pushNull(inout text);
      return true;
    }
    const rendered = runtime.toStringValue(value);
    const renderedBytes = runtime.heap.stringUnits(asCell(rendered));
    appendAll(inout text, in renderedBytes);
    return true;
  }
  if (!runtime.isObjectLike(value) || runtime.isCallable(value)) return false;
  // Cycles.
  const handle = asCell(value);
  let depth: usize = 0;
  while (depth < state.stackCount) {
    if (state.stack[depth] == handle) {
      const message: String = "Converting circular structure to JSON";
      const error = runtime.typeError(in message);
      runtime.raise(error);
      return false;
    }
    depth = depth + 1;
  }
  if (state.stackCount < state.stack.length) {
    state.stack[state.stackCount] = handle;
  } else {
    state.stack.push(handle);
  }
  state.stackCount = state.stackCount + 1;
  const outerIndent = copyBytes(in state.indent);
  const gap = copyBytes(in state.gap);
  appendAll(inout state.indent, in gap);
  const isArray = runtime.heap.isArray(handle);
  const open: u16 = isArray ? 91 : 123;
  text.push(open);
  let wroteAny = false;
  if (isArray) {
    const length = runtime.heap.arrayLength(handle);
    let index: u32 = 0;
    while (index < length) {
      if (index > 0) text.push(44);
      if (state.gap.length > 0) {
        text.push(10);
        appendAll(inout text, in state.indent);
      }
      const wrote = serialize(inout runtime, inout state, value, int32Value(i32(index)), inout text);
      if (runtime.pendingThrow) return false;
      if (!wrote) pushNull(inout text);
      wroteAny = true;
      index = index + 1;
    }
  } else {
    let keys = Array<Value>();
    if (state.useAllowed) {
      let a: usize = 0;
      while (a < state.allowed.length) {
        keys.push(cellValue(state.allowed[a]));
        a = a + 1;
      }
    } else {
      const own = runtime.ownKeys(value);
      let k: usize = 0;
      while (k < own.length) {
        const candidate = own[k];
        if (runtime.isStringValue(candidate)) {
          const desc = runtime.getOwnDescriptor(value, candidate);
          if (desc.present && (desc.attr & PROP_ENUMERABLE) != 0) keys.push(candidate);
        }
        k = k + 1;
      }
    }
    let index: usize = 0;
    while (index < keys.length) {
      const propertyKey = keys[index];
      let piece = Array<u16>();
      const wrote = serialize(inout runtime, inout state, value, propertyKey, inout piece);
      if (runtime.pendingThrow) return false;
      if (wrote) {
        if (wroteAny) text.push(44);
        if (state.gap.length > 0) {
          text.push(10);
          appendAll(inout text, in state.indent);
        }
        const keyBytes = runtime.heap.stringUnits(asCell(propertyKey));
        quote(inout text, in keyBytes);
        text.push(58);
        if (state.gap.length > 0) text.push(32);
        appendAll(inout text, in piece);
        wroteAny = true;
      }
      index = index + 1;
    }
  }
  if (wroteAny && state.gap.length > 0) {
    text.push(10);
    appendAll(inout text, in outerIndent);
  }
  const close: u16 = isArray ? 93 : 125;
  text.push(close);
  state.indent = move outerIndent;
  state.stackCount = state.stackCount - 1;
  return true;
}

function jsonStringify(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const value = runtime.argument(argsBase, argc, 0);
  const replacer = runtime.argument(argsBase, argc, 1);
  let state = Stringifier({
    indent: Array<u16>(), gap: Array<u16>(), replacer: undefinedValue(),
    allowed: Array<u32>(), useAllowed: false, stack: Array<u32>(), stackCount: 0,
  });
  if (runtime.isCallable(replacer)) {
    state.replacer = replacer;
  } else if (isCell(replacer) && asCell(replacer) != 0 && runtime.heap.isArray(asCell(replacer))) {
    // A property allow-list: strings and numbers, each once.
    state.useAllowed = true;
    const list = asCell(replacer);
    const length = runtime.heap.arrayLength(list);
    let index: u32 = 0;
    while (index < length) {
      let item = runtime.heap.arrayGet(list, index);
      if (runtime.isObjectLike(item) && runtime.heap.isObject(asCell(item))) {
        const wrapped = runtime.wrappedPrimitive(asCell(item));
        if (isNumber(wrapped) || runtime.isStringValue(wrapped)) item = wrapped;
      }
      if (runtime.isStringValue(item) || isNumber(item)) {
        const atom = runtime.propertyKey(item);
        let seen = false;
        let a: usize = 0;
        while (a < state.allowed.length) {
          if (state.allowed[a] == atom) seen = true;
          a = a + 1;
        }
        if (!seen) state.allowed.push(atom);
      }
      index = index + 1;
    }
  }
  // Indentation: a number of spaces up to ten, or a string's first ten bytes.
  let space = runtime.argument(argsBase, argc, 2);
  if (runtime.isObjectLike(space) && runtime.heap.isObject(asCell(space))) {
    const wrapped = runtime.wrappedPrimitive(asCell(space));
    if (isNumber(wrapped)) {
      const number = runtime.toNumberValue(space);
      if (runtime.pendingThrow) return undefinedValue();
      space = doubleValue(number);
    } else if (runtime.isStringValue(wrapped)) {
      space = runtime.toStringValue(space);
      if (runtime.pendingThrow) return undefinedValue();
    }
  }
  if (isNumber(space)) {
    let count = toNumber(space);
    if (count > 10.0) count = 10.0;
    if (count >= 1.0) {
      let n = u32(truncateDouble(count));
      while (n > 0) {
        state.gap.push(32);
        n = n - 1;
      }
    }
  } else if (runtime.isStringValue(space)) {
    const bytes = runtime.heap.stringUnits(asCell(space));
    let index: usize = 0;
    while (index < bytes.length && index < 10) {
      state.gap.push(bytes[index]);
      index = index + 1;
    }
  }
  const objectProto = runtime.objectProto;
  const holder = runtime.heap.allocateObject(objectProto);
  const emptyKey = runtime.internLatin1Value(Array<u8>());
  const emptyAtom = runtime.propertyKey(emptyKey);
  runtime.heap.objectSet(holder, emptyAtom, value);
  runtime.pushTempRoot(cellValue(holder));
  let text = Array<u16>();
  const wrote = serialize(inout runtime, inout state, cellValue(holder), emptyKey, inout text);
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  if (!wrote) return undefinedValue();
  return runtime.newStringUnits(move text);
}

export function installJson(inout runtime: Runtime): void {
  const objectProto = runtime.objectProto;
  const json = runtime.heap.allocateObject(objectProto);
  runtime.setGlobal("JSON", cellValue(json));
  const parseText: String = "parse";
  runtime.defineMethod(json, in parseText, jsonParse, 2);
  const stringifyText: String = "stringify";
  runtime.defineMethod(json, in stringifyText, jsonStringify, 3);
  const symbolToStringTag = runtime.symbolToStringTag;
  const tagKey = runtime.propertyKey(symbolToStringTag);
  const jsonText: String = "JSON";
  const tagValue = runtime.internText(in jsonText);
  runtime.heap.objectDefine(json, tagKey, tagValue, PROP_CONFIGURABLE);
}
