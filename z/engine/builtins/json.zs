// JSON.parse and JSON.stringify over byte strings.
import { isHighSurrogate, isLowSurrogate } from "../text.zs";
import { thread } from "std/thread";
import { TextBuilder, textBuilder, putByte, putUnit, putUnits, putString, textLength, truncateTo, finishText } from "./builder.zs";
import { Value, undefinedValue, nullValue, booleanValue, int32Value, doubleValue, cellValue, asCell, isCell, isUndefined, isNull, isBoolean, isTrue, isNumber, isInt32, asInt32, isDeleted } from "../value.zs";
import { Runtime, ERROR_KIND_SYNTAX, toNumber, isIntegralDouble, truncateDouble, stringToNumber, FEATURE_JSON } from "../runtime.zs";
import { bytesOf, PROP_ENUMERABLE, PROP_CONFIGURABLE, PROP_ACCESSOR, FLAG_INDEX_KEY, FLAG_HIDDEN } from "../heap.zs";

// --- parse ---

struct JsonParser {
  bytes: Array<u16>;
  position: usize;
  failed: boolean;
  // A string being read: its Latin-1 bytes while every unit fits in one,
  // its units once one does not. Reused from string to string.
  units: Array<u16>;
  wide: boolean;
  narrow: Array<u8>;
  // Recent class transitions, direct-mapped by (class, name): objects of
  // one shape, which a document repeats, move straight to their class.
  shapeFrom: Array<u32>;
  shapeName: Array<u32>;
  shapeTo: Array<u32>;
  shapeSlot: Array<u32>;
}

const SHAPE_CACHE: usize = 64;

// Define a parsed property on a fresh object, through the transition
// cache when it holds.
function defineParsed(inout runtime: Runtime, inout parser: JsonParser, object: u32, atom: u32, value: Value): void {
  const before = runtime.heap.objectClass(object);
  const at = usize(before.wrappingMultiply(31).wrappingAdd(atom)) & (SHAPE_CACHE - 1);
  if (parser.shapeFrom[at] == before && parser.shapeName[at] == atom && parser.shapeTo[at] != 0) {
    runtime.heap.transitionTo(object, parser.shapeTo[at], parser.shapeSlot[at], value);
    return;
  }
  runtime.heap.objectSet(object, atom, value);
  const after = runtime.heap.objectClass(object);
  if (after != before && !runtime.heap.isDictionary(object) && runtime.heap.isTransitionOf(after, before, atom)) {
    parser.shapeFrom[at] = before;
    parser.shapeName[at] = atom;
    parser.shapeTo[at] = after;
    parser.shapeSlot[at] = runtime.heap.classSlot(after);
  }
}

function zeros(count: usize): Array<u32> {
  let list = Array<u32>.withCapacity(count);
  list.appendRepeated(0, count);
  return list;
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

// The literal `word` (true, false, null) at the position, stepped over;
// compared in place, with nothing copied.
function expectWord(inout parser: JsonParser, in word: String): boolean {
  const length = usize(word.byteLength);
  if (parser.position + length > parser.bytes.length) {
    parser.failed = true;
    return false;
  }
  let index: usize = 0;
  while (index < length) {
    if (parser.bytes[parser.position + index] != u16(word.byteAt(index))) {
      parser.failed = true;
      return false;
    }
    index = index + 1;
  }
  parser.position = parser.position + length;
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
// The body of a string, after its opening quote, into parser.units (and
// parser.narrow when every unit is Latin-1).
function parseStringBody(inout parser: JsonParser): void {
  parser.narrow.clear();
  parser.units.clear();
  parser.wide = false;
  while (true) {
    const byte = peekByte(in parser);
    if (byte < 0) {
      parser.failed = true;
      return;
    }
    parser.position = parser.position + 1;
    if (byte == 34) return;
    if (byte < 32) {
      parser.failed = true;
      return;
    }
    if (byte != 92) {
      pushUnit(inout parser, u16(byte));
      continue;
    }
    const escape = peekByte(in parser);
    parser.position = parser.position + 1;
    if (escape == 34) {
      pushUnit(inout parser, 34);
    } else if (escape == 92) {
      pushUnit(inout parser, 92);
    } else if (escape == 47) {
      pushUnit(inout parser, 47);
    } else if (escape == 98) {
      pushUnit(inout parser, 8);
    } else if (escape == 102) {
      pushUnit(inout parser, 12);
    } else if (escape == 110) {
      pushUnit(inout parser, 10);
    } else if (escape == 114) {
      pushUnit(inout parser, 13);
    } else if (escape == 116) {
      pushUnit(inout parser, 9);
    } else if (escape == 117) {
      // One escape is one unit; a pair written as two escapes is a pair.
      const unit = parseHex4(inout parser);
      if (parser.failed) return;
      pushUnit(inout parser, u16(unit));
    } else {
      parser.failed = true;
      return;
    }
  }
}

function pushUnit(inout parser: JsonParser, unit: u16): void {
  if (!parser.wide) {
    if (unit <= 255) {
      parser.narrow.push(u8(unit));
      return;
    }
    // The first unit past a byte: the string so far becomes units.
    let index: usize = 0;
    while (index < parser.narrow.length) {
      parser.units.push(u16(parser.narrow[index]));
      index = index + 1;
    }
    parser.wide = true;
  }
  parser.units.push(unit);
}

// The string just read, as a fresh string value.
function parsedString(inout runtime: Runtime, in parser: JsonParser): Value {
  if (!parser.wide) return runtime.newStringLatin1Slice(parser.narrow);
  let units = Array<u16>.withCapacity(parser.units.length);
  let index: usize = 0;
  while (index < parser.units.length) {
    units.push(parser.units[index]);
    index = index + 1;
  }
  return runtime.newStringUnits(move units);
}

// The string just read, as a property name.
function parsedKey(inout runtime: Runtime, in parser: JsonParser): u32 {
  if (!parser.wide) return runtime.internLatin1Borrowed(in parser.narrow);
  let units = Array<u16>.withCapacity(parser.units.length);
  let index: usize = 0;
  while (index < parser.units.length) {
    units.push(parser.units[index]);
    index = index + 1;
  }
  return runtime.internUnits(move units);
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
  // An integer of up to 15 digits is exact as it is read.
  let index = start;
  const negative = parser.bytes[index] == 45;
  if (negative) index = index + 1;
  if (parser.position - index <= 15) {
    let magnitude: i64 = 0;
    let integral = true;
    while (index < parser.position) {
      const unit = parser.bytes[index];
      if (unit < 48 || unit > 57) {
        integral = false;
        break;
      }
      magnitude = magnitude * 10 + i64(unit - 48);
      index = index + 1;
    }
    if (integral) return numberValue(negative ? -f64(magnitude) : f64(magnitude));
  }
  let digits = Array<u8>();
  index = start;
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
      parseStringBody(inout parser);
      if (parser.failed) {
        runtime.popTempRoot();
        return undefinedValue();
      }
      // The name is interned now, since parsing the value reuses the
      // buffer; the intern table is weak, so it stays rooted until the
      // object holds it.
      const atom = parsedKey(inout runtime, in parser);
      runtime.pushTempRoot(cellValue(atom));
      skipSpace(inout parser);
      if (peekByte(in parser) != 58) {
        parser.failed = true;
        runtime.popTempRoot();
        runtime.popTempRoot();
        return undefinedValue();
      }
      parser.position = parser.position + 1;
      const value = parseValue(inout runtime, inout parser, depth + 1);
      if (parser.failed) {
        runtime.popTempRoot();
        runtime.popTempRoot();
        return undefinedValue();
      }
      defineParsed(inout runtime, inout parser, object, atom, value);
      runtime.popTempRoot();
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
    parseStringBody(inout parser);
    if (parser.failed) return undefinedValue();
    return parsedString(inout runtime, in parser);
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

// InternalizeJSONProperty: the reviver walks the result bottom-up. The
// holder, the key, the value, and the value's keys are rooted while the
// reviver runs, since a collection may come in any call.
function revive(inout runtime: Runtime, holder: Value, key: Value, reviver: Value): Value {
  const mark = runtime.tempRoots.length;
  runtime.pushTempRoot(holder);
  runtime.pushTempRoot(key);
  const value = runtime.getProperty(holder, key);
  if (runtime.pendingThrow) {
    runtime.popTempRootsTo(mark);
    return undefinedValue();
  }
  if (runtime.isObjectLike(value)) {
    runtime.pushTempRoot(value);
    const keys = runtime.ownKeys(value);
    let index: usize = 0;
    while (index < keys.length) {
      runtime.pushTempRoot(keys[index]);
      index = index + 1;
    }
    index = 0;
    while (index < keys.length) {
      const childKey = keys[index];
      if (runtime.isStringValue(childKey)) {
        const desc = runtime.getOwnDescriptor(value, childKey);
        if (desc.present && (desc.attr & PROP_ENUMERABLE) != 0) {
          const revived = revive(inout runtime, value, childKey, reviver);
          if (runtime.pendingThrow) {
            runtime.popTempRootsTo(mark);
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
  }
  const result = runtime.callValue2(reviver, holder, key, value);
  runtime.popTempRootsTo(mark);
  return result;
}

function jsonParse(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  let parser = JsonParser({ bytes: runtime.heap.stringUnits(asCell(text)), position: 0, failed: false, units: Array<u16>(), wide: false, narrow: Array<u8>(), shapeFrom: zeros(SHAPE_CACHE), shapeName: zeros(SHAPE_CACHE), shapeTo: zeros(SHAPE_CACHE), shapeSlot: zeros(SHAPE_CACHE) });
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
  // "toJSON" as a key, interned once per call.
  toJSONKey: Value;
  // The key lists of the objects being written, one on another: each
  // object pushes its names and value slots and pops them when done, so
  // no object allocates a list of its own.
  names: Array<u32>;
  slots: Array<u32>;
  // A chain of up to three ordinary objects in class mode, found to have
  // no toJSON anywhere: their classes, and the prototypes that link them
  // (0 past the end). An object whose chain has these classes has none
  // either -- a class fixes its properties -- and needs no lookup.
  plainClass: u32;
  plainProto: u32;
  plainProtoClass: u32;
  plainProto2: u32;
  plainProto2Class: u32;
  plainKnown: boolean;
}

function hexChar(digit: u32): u8 {
  if (digit < 10) return u8(48 + digit);
  return u8(87 + digit);
}

// A string's JSON form, read from the heap cell: nothing is copied out
// first. A narrow string's bytes are read straight from its storage and
// have no surrogates to check.
function quoteString(in runtime: Runtime, inout text: TextBuilder, handle: u32): void {
  putByte(inout text, 34);
  const length = runtime.heap.stringLength(handle);
  if (!runtime.heap.isWideString(handle) && !text.wide) {
    const arena = runtime.heap.isArenaString(handle);
    const start = runtime.heap.stringStorageStart(handle);
    const buffer = usize(runtime.heap.stringBuffer(handle));
    let index: usize = 0;
    while (index < length) {
      let byte: u8 = 0;
      if (arena) {
        byte = runtime.heap.smallBytes[start + index];
      } else {
        byte = runtime.heap.strings[buffer][index];
      }
      if (byte >= 32 && byte != 34 && byte != 92) {
        text.bytes.push(byte);
      } else {
        escapeUnit(inout text, u16(byte));
      }
      index = index + 1;
    }
    putByte(inout text, 34);
    return;
  }
  const wide = runtime.heap.isWideString(handle);
  let index: usize = 0;
  while (index < length) {
    const unit = wide ? runtime.heap.stringUnit(handle, index) : u16(runtime.heap.stringStorageByte(handle, index));
    if (unit >= 32 && unit != 34 && unit != 92 && (unit < 0xD800 || unit > 0xDFFF)) {
      putUnit(inout text, unit);
    } else if (unit >= 0xD800 && unit <= 0xDFFF && !loneAt(in runtime, handle, index, length)) {
      putUnit(inout text, unit);
    } else {
      escapeUnit(inout text, unit);
    }
    index = index + 1;
  }
  putByte(inout text, 34);
}

// A unit that does not go out as itself: a short escape, or \u and four
// hex digits (a control character, a lone surrogate).
function escapeUnit(inout text: TextBuilder, unit: u16): void {
  putByte(inout text, 92);
  if (unit == 34 || unit == 92) {
    putByte(inout text, u8(unit));
  } else if (unit == 8) {
    putByte(inout text, 98);
  } else if (unit == 12) {
    putByte(inout text, 102);
  } else if (unit == 10) {
    putByte(inout text, 110);
  } else if (unit == 13) {
    putByte(inout text, 114);
  } else if (unit == 9) {
    putByte(inout text, 116);
  } else {
    putByte(inout text, 117);
    putByte(inout text, hexChar(u32(unit) >> 12));
    putByte(inout text, hexChar((u32(unit) >> 8) & 15));
    putByte(inout text, hexChar((u32(unit) >> 4) & 15));
    putByte(inout text, hexChar(u32(unit) & 15));
  }
}

// Whether the surrogate at `index` of a wide string lacks its partner.
function loneAt(in runtime: Runtime, handle: u32, index: usize, length: usize): boolean {
  const unit = runtime.heap.stringUnit(handle, index);
  if (isHighSurrogate(unit)) return index + 1 >= length || !isLowSurrogate(runtime.heap.stringUnit(handle, index + 1));
  if (isLowSurrogate(unit)) return index == 0 || !isHighSurrogate(runtime.heap.stringUnit(handle, index - 1));
  return false;
}

// An int32's decimal digits.
function pushInt32(inout text: TextBuilder, value: i32): void {
  let magnitude: u32 = 0;
  if (value < 0) {
    putByte(inout text, 45);
    magnitude = value == -2147483648 ? 2147483648 : u32(0 - value);
  } else {
    magnitude = u32(value);
  }
  let digits: u8[10] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  let count: usize = 0;
  if (magnitude == 0) {
    digits[0] = 48;
    count = 1;
  }
  while (magnitude > 0) {
    digits[count] = u8(48 + magnitude % 10);
    magnitude = magnitude / 10;
    count = count + 1;
  }
  while (count > 0) {
    count = count - 1;
    putByte(inout text, digits[count]);
  }
}

function appendAll(inout target: Array<u16>, in more: Array<u16>): void {
  let index: usize = 0;
  while (index < more.length) {
    target.push(more[index]);
    index = index + 1;
  }
}

function copyBytes(in bytes: Array<u16>): Array<u16> {
  let copied = Array<u16>.withCapacity(bytes.length);
  copied.append(bytes);
  return copied;
}

function pushNull(inout text: TextBuilder): void {
  putByte(inout text, 110);
  putByte(inout text, 117);
  putByte(inout text, 108);
  putByte(inout text, 108);
}

// SerializeJSONProperty: returns false when the value has no JSON form
// (undefined, functions, symbols), leaving `text` untouched.
function serialize(inout runtime: Runtime, inout state: Stringifier, holder: Value, key: Value, inout text: TextBuilder): boolean {
  const value = runtime.getProperty(holder, key);
  if (runtime.pendingThrow) return false;
  return serializeValue(inout runtime, inout state, holder, key, value, inout text);
}

// An object's enumerable own string keys in property order, pushed on
// the stringifier's key stack with their slots, all before any value is
// read, as the specification takes its key list first; where they start,
// or -1 with nothing pushed when the object has an index key and needs
// the general order.
function pushPlainKeys(inout runtime: Runtime, inout state: Stringifier, handle: u32): i64 {
  const start = state.names.length;
  runtime.heap.appendOwnNamedSlots(handle, inout state.names, inout state.slots);
  let read = start;
  let write = start;
  while (read < state.names.length) {
    const name = state.names[read];
    const slot = state.slots[read];
    const flags = runtime.heap.flagsOf(name);
    if (runtime.heap.isString(name) && (flags & FLAG_INDEX_KEY) != 0) {
      popKeys(inout state, start);
      return -1;
    }
    // Symbols and the engine's own keys are not written.
    if (runtime.heap.isString(name) && (flags & FLAG_HIDDEN) == 0 && (runtime.heap.attrOf(handle, slot) & PROP_ENUMERABLE) != 0) {
      state.names[write] = name;
      state.slots[write] = slot;
      write = write + 1;
    }
    read = read + 1;
  }
  popKeys(inout state, write);
  return i64(start);
}

function popKeys(inout state: Stringifier, mark: usize): void {
  while (state.names.length > mark) {
    const name = state.names.pop();
    const slot = state.slots.pop();
  }
}

// Whether `handle`'s chain is the one recorded as having no toJSON.
function knownWithoutToJSON(in runtime: Runtime, in state: Stringifier, handle: u32): boolean {
  if (!state.plainKnown || !runtime.heap.isObject(handle)) return false;
  if (runtime.heap.objectClass(handle) != state.plainClass) return false;
  const proto = runtime.heap.objectProto(handle);
  if (proto != state.plainProto) return false;
  if (proto == 0) return true;
  if (runtime.heap.objectClass(proto) != state.plainProtoClass) return false;
  const proto2 = runtime.heap.objectProto(proto);
  if (proto2 != state.plainProto2) return false;
  if (proto2 == 0) return true;
  return runtime.heap.objectClass(proto2) == state.plainProto2Class && runtime.heap.objectProto(proto2) == 0;
}

// After a lookup of toJSON found nothing: record the chain when every
// object on it is ordinary, in class mode, and truly without the
// property (not an accessor that gave undefined).
function noteWithoutToJSON(in runtime: Runtime, inout state: Stringifier, handle: u32): void {
  const atom = asCell(state.toJSONKey);
  let chain: u32[3] = [0, 0, 0];
  let count: usize = 0;
  let current = handle;
  while (current != 0) {
    if (count == 3) return;
    if (!runtime.heap.isObject(current) || runtime.heap.isDictionary(current)) return;
    if (runtime.heap.objectFindSlot(current, atom) >= 0) return;
    chain[count] = current;
    count = count + 1;
    current = runtime.heap.objectProto(current);
  }
  state.plainClass = runtime.heap.objectClass(chain[0]);
  state.plainProto = chain[1];
  state.plainProtoClass = chain[1] == 0 ? 0 : runtime.heap.objectClass(chain[1]);
  state.plainProto2 = chain[2];
  state.plainProto2Class = chain[2] == 0 ? 0 : runtime.heap.objectClass(chain[2]);
  state.plainKnown = true;
}

// SerializeJSONProperty with the property's value already read.
function serializeValue(inout runtime: Runtime, inout state: Stringifier, holder: Value, key: Value, given: Value, inout text: TextBuilder): boolean {
  let value = given;
  if (runtime.isObjectLike(value) && !knownWithoutToJSON(in runtime, in state, asCell(value))) {
    const toJSONKey = state.toJSONKey;
    const toJSON = runtime.getProperty(value, toJSONKey);
    if (!runtime.pendingThrow && isUndefined(toJSON)) noteWithoutToJSON(in runtime, inout state, asCell(value));
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
    if (isTrue(value)) {
      putByte(inout text, 116);
      putByte(inout text, 114);
      putByte(inout text, 117);
      putByte(inout text, 101);
    } else {
      putByte(inout text, 102);
      putByte(inout text, 97);
      putByte(inout text, 108);
      putByte(inout text, 115);
      putByte(inout text, 101);
    }
    return true;
  }
  if (runtime.isStringValue(value)) {
    quoteString(in runtime, inout text, asCell(value));
    return true;
  }
  if (isInt32(value)) {
    pushInt32(inout text, asInt32(value));
    return true;
  }
  if (isNumber(value)) {
    const number = toNumber(value);
    if (number != number || number == 1.0 / 0.0 || number == -1.0 / 0.0) {
      pushNull(inout text);
      return true;
    }
    const rendered = runtime.toStringValue(value);
    putString(in runtime, inout text, asCell(rendered));
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
  // Indentation changes only when there is a gap.
  const pretty = state.gap.length > 0;
  let outerIndent = Array<u16>();
  if (pretty) {
    outerIndent = copyBytes(in state.indent);
    const gap = copyBytes(in state.gap);
    appendAll(inout state.indent, in gap);
  }
  const isArray = runtime.heap.isArray(handle);
  let plainStart: i64 = -1;
  if (!isArray && !state.useAllowed && runtime.heap.isObject(handle) && handle != runtime.globalObject) {
    plainStart = pushPlainKeys(inout runtime, inout state, handle);
  }
  const open: u8 = isArray ? 91 : 123;
  putByte(inout text, open);
  let wroteAny = false;
  if (isArray) {
    const length = runtime.heap.arrayLength(handle);
    let index: u32 = 0;
    while (index < length) {
      if (index > 0) putByte(inout text, 44);
      if (state.gap.length > 0) {
        putByte(inout text, 10);
        putUnits(inout text, in state.indent);
      }
      // A present data element is read in place; a hole or an accessor
      // goes through Get.
      let element = runtime.heap.dataElement(handle, index);
      if (isDeleted(element)) {
        element = runtime.getProperty(value, int32Value(i32(index)));
        if (runtime.pendingThrow) return false;
      }
      const wrote = serializeValue(inout runtime, inout state, value, int32Value(i32(index)), element, inout text);
      if (runtime.pendingThrow) return false;
      if (!wrote) pushNull(inout text);
      wroteAny = true;
      index = index + 1;
    }
  } else if (plainStart >= 0) {
    // A plain object: its keys from its shape, each value read from its
    // slot while the object keeps the shape its keys were read from (a
    // getter or toJSON may change it), else by Get.
    const first = usize(plainStart);
    const end = state.names.length;
    const shape = runtime.heap.objectClass(handle);
    let k = first;
    while (k < end) {
      const name = state.names[k];
      const slot = state.slots[k];
      const mark = textLength(in text);
      if (wroteAny) putByte(inout text, 44);
      if (pretty) {
        putByte(inout text, 10);
        putUnits(inout text, in state.indent);
      }
      quoteString(in runtime, inout text, name);
      putByte(inout text, 58);
      if (pretty) putByte(inout text, 32);
      let propertyValue = runtime.heap.slot(handle, slot);
      if (runtime.heap.objectClass(handle) != shape || isDeleted(propertyValue) || (runtime.heap.attrOf(handle, slot) & PROP_ACCESSOR) != 0) {
        propertyValue = runtime.getProperty(value, cellValue(name));
        if (runtime.pendingThrow) return false;
      }
      const wrote = serializeValue(inout runtime, inout state, value, cellValue(name), propertyValue, inout text);
      if (runtime.pendingThrow) return false;
      if (wrote) {
        wroteAny = true;
      } else {
        truncateTo(inout text, mark);
      }
      k = k + 1;
    }
    popKeys(inout state, first);
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
      // The key goes out first; a value with no JSON form takes it back.
      const mark = textLength(in text);
      if (wroteAny) putByte(inout text, 44);
      if (pretty) {
        putByte(inout text, 10);
        putUnits(inout text, in state.indent);
      }
      quoteString(in runtime, inout text, asCell(propertyKey));
      putByte(inout text, 58);
      if (pretty) putByte(inout text, 32);
      const wrote = serialize(inout runtime, inout state, value, propertyKey, inout text);
      if (runtime.pendingThrow) return false;
      if (wrote) {
        wroteAny = true;
      } else {
        truncateTo(inout text, mark);
      }
      index = index + 1;
    }
  }
  if (wroteAny && state.gap.length > 0) {
    putByte(inout text, 10);
    putUnits(inout text, in outerIndent);
  }
  const close: u8 = isArray ? 93 : 125;
  putByte(inout text, close);
  if (pretty) state.indent = move outerIndent;
  state.stackCount = state.stackCount - 1;
  return true;
}

function jsonStringify(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const value = runtime.argument(argsBase, argc, 0);
  const replacer = runtime.argument(argsBase, argc, 1);
  const toJSONText: String = "toJSON";
  let state = Stringifier({
    indent: Array<u16>(), gap: Array<u16>(), replacer: undefinedValue(),
    allowed: Array<u32>(), useAllowed: false, stack: Array<u32>(), stackCount: 0,
    toJSONKey: runtime.internText(in toJSONText),
    names: Array<u32>(), slots: Array<u32>(),
    plainClass: 0, plainProto: 0, plainProtoClass: 0, plainProto2: 0, plainProto2Class: 0, plainKnown: false,
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
  let hint = runtime.jsonTextHint + 16;
  if (hint > 1048576) hint = 1048576;
  let text = textBuilder(hint);
  const wrote = serialize(inout runtime, inout state, cellValue(holder), emptyKey, inout text);
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  if (!wrote) return undefinedValue();
  runtime.jsonTextHint = textLength(in text);
  return finishText(inout runtime, inout text);
}

export function installJson(inout runtime: Runtime): void {
  if ((runtime.features & FEATURE_JSON) != 0) return;
  runtime.features = runtime.features | FEATURE_JSON;
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
