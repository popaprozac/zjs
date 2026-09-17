// RegExp: the constructor and prototype over the runtime's RegExp
// objects, the @@match / @@matchAll / @@replace / @@search / @@split
// protocol the string methods dispatch through, and the string
// iterator matchAll returns. Matching itself is the runtime's
// regexpExecRaw over the backend; this file is the specification's
// algorithms around it, over byte offsets.
import { Value, undefinedValue, nullValue, booleanValue, int32Value, doubleValue, cellValue, asCell, isCell, isUndefined, isNull, isNumber, asInt32, isInt32 } from "../value.zs";
import { bytesOf, PROP_METHOD, PROP_NONE, PROP_CONFIGURABLE, PROP_ACCESSOR, PROP_DEFAULT } from "../heap.zs";
import { unitsOf, sliceUnits, copyUnits, appendUnits, isHighSurrogate, isLowSurrogate } from "../text.zs";
import { Runtime, HostFunction, toNumber, truncateDouble, appendBytes } from "../runtime.zs";
import { REGEX_GLOBAL, REGEX_IGNORE_CASE, REGEX_MULTILINE, REGEX_DOT_ALL, REGEX_UNICODE, REGEX_STICKY, REGEX_HAS_INDICES, REGEX_UNICODE_SETS, REGEX_MATCH } from "../regex.zs";
import { thread } from "std/thread";

// --- Helpers ---

function raiseType(inout runtime: Runtime, in message: String): Value {
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return undefinedValue();
}

function thisObject(inout runtime: Runtime, thisValue: Value, in what: String): boolean {
  if (runtime.isObjectLike(thisValue)) return true;
  let message = bytesOf(in what);
  const tail: String = " called on a non-object";
  appendBytes(inout message, bytesOf(in tail));
  const error = runtime.makeError(2, move message);
  runtime.raise(error);
  return false;
}

function thisRegExp(inout runtime: Runtime, thisValue: Value, in what: String): u32 {
  if (runtime.isRegExpObject(thisValue)) return asCell(thisValue);
  let message = bytesOf(in what);
  const tail: String = " called on an object that is not a RegExp";
  appendBytes(inout message, bytesOf(in tail));
  const error = runtime.makeError(2, move message);
  runtime.raise(error);
  return 0;
}

function textKey(inout runtime: Runtime, in text: String): Value {
  return runtime.internText(in text);
}

// A string's units.
function stringBytesOf(inout runtime: Runtime, value: Value): Array<u16> {
  return runtime.heap.stringUnits(asCell(value));
}

function substring(inout runtime: Runtime, in bytes: Array<u16>, start: usize, end: usize): Value {
  let begin = start;
  let finish = end;
  if (finish > bytes.length) finish = bytes.length;
  if (begin > finish) begin = finish;
  return runtime.newStringUnits(sliceUnits(in bytes, begin, finish));
}

// units[start..], the end bound taken before the borrow.
function sliceFrom(in bytes: Array<u16>, start: usize): Array<u16> {
  const end = bytes.length;
  return sliceUnits(in bytes, start, end);
}

function hasFlag(in flags: Array<u16>, letter: u16): boolean {
  let i: usize = 0;
  while (i < flags.length) {
    if (flags[i] == letter) return true;
    i = i + 1;
  }
  return false;
}

// ToLength on a value, saturating at the runtime's index width.
function lengthOf(inout runtime: Runtime, value: Value): usize {
  return usize(runtime.toLength(value));
}

// AdvanceStringIndex: one unit, or a whole surrogate pair when matching
// by code point.
function advanceIndex(in bytes: Array<u16>, index: usize, unicode: boolean): usize {
  if (!unicode || index + 1 >= bytes.length) return index + 1;
  if (isHighSurrogate(bytes[index]) && isLowSurrogate(bytes[index + 1])) return index + 2;
  return index + 1;
}

// Get(rx, "lastIndex") as a length.
function getLastIndex(inout runtime: Runtime, rx: Value): usize {
  const atomLastIndex = runtime.atomLastIndex;
  const held = runtime.getProperty(rx, cellValue(atomLastIndex));
  if (runtime.pendingThrow) return 0;
  return lengthOf(inout runtime, held);
}

// Set(rx, "lastIndex", value, true).
function setLastIndex(inout runtime: Runtime, rx: Value, value: usize): boolean {
  const atomLastIndex = runtime.atomLastIndex;
  const stored = runtime.setProperty(rx, cellValue(atomLastIndex), doubleValue(f64(value)));
  if (runtime.pendingThrow) return false;
  if (!stored) {
    const message: String = "Cannot assign to read only property 'lastIndex'";
    raiseType(inout runtime, in message);
    return false;
  }
  return true;
}

function flagsStringOf(inout runtime: Runtime, rx: Value): Array<u16> {
  const atomFlags = runtime.atomFlags;
  const held = runtime.getProperty(rx, cellValue(atomFlags));
  if (runtime.pendingThrow) return Array<u16>();
  const text = runtime.toStringValue(held);
  if (runtime.pendingThrow) return Array<u16>();
  return stringBytesOf(inout runtime, text);
}

// SpeciesConstructor(object, default).
function speciesConstructorOf(inout runtime: Runtime, object: Value, defaultCtor: Value): Value {
  const atomConstructor = runtime.atomConstructor;
  const ctor = runtime.getProperty(object, cellValue(atomConstructor));
  if (runtime.pendingThrow) return undefinedValue();
  if (isUndefined(ctor)) return defaultCtor;
  if (!runtime.isObjectLike(ctor)) {
    const message: String = "object.constructor is not an object";
    return raiseType(inout runtime, in message);
  }
  const symbolSpecies = runtime.symbolSpecies;
  const species = runtime.getProperty(ctor, symbolSpecies);
  if (runtime.pendingThrow) return undefinedValue();
  if (isUndefined(species) || isNull(species)) return defaultCtor;
  if (runtime.isConstructorValue(species)) return species;
  const message: String = "object.constructor[Symbol.species] is not a constructor";
  return raiseType(inout runtime, in message);
}

// --- The builtin exec ---

// RegExpBuiltinExec: the match array (index, input, groups, indices
// with the d flag), or null.
function builtinExec(inout runtime: Runtime, rx: u32, input: Value): Value {
  const rxValue = cellValue(rx);
  const inputHandle = asCell(input);
  const length = runtime.heap.stringLength(inputHandle);
  let lastIndex = getLastIndex(inout runtime, rxValue);
  if (runtime.pendingThrow) return undefinedValue();
  const bits = runtime.regexpFlagBits(rx);
  const global = (bits & REGEX_GLOBAL) != 0;
  const sticky = (bits & REGEX_STICKY) != 0;
  const hasIndices = (bits & REGEX_HAS_INDICES) != 0;
  if (!global && !sticky) lastIndex = 0;
  if (lastIndex > length) {
    if (global || sticky) {
      if (!setLastIndex(inout runtime, rxValue, 0)) return undefinedValue();
    }
    return nullValue();
  }
  const outcome = runtime.regexpExecRaw(rx, inputHandle, lastIndex);
  if (runtime.pendingThrow) return undefinedValue();
  if (outcome != REGEX_MATCH) {
    if (global || sticky) {
      if (!setLastIndex(inout runtime, rxValue, 0)) return undefinedValue();
    }
    return nullValue();
  }
  const entry = runtime.regexpEntry(rx);
  if (runtime.pendingThrow) return undefinedValue();
  const count = runtime.regexBackend.captures(entry);
  // The offsets are read result first: any allocation below may run the
  // collector, and any getter may run another exec.
  let starts = Array<i32>();
  let ends = Array<i32>();
  let g: i32 = 0;
  while (g < count) {
    starts.push(runtime.regexBackend.captureStart(g));
    ends.push(runtime.regexBackend.captureEnd(g));
    g = g + 1;
  }
  const matchEnd = usize(ends[0]);
  if (global || sticky) {
    if (!setLastIndex(inout runtime, rxValue, matchEnd)) return undefinedValue();
  }
  const array = runtime.heap.allocateArray(u32(count));
  const arrayValue = cellValue(array);
  runtime.pushTempRoot(arrayValue);
  const bag = runtime.arrayBag(array);
  const atomIndex = runtime.atomIndex;
  runtime.heap.objectDefine(bag, atomIndex, int32Value(starts[0]), PROP_DEFAULT);
  const atomInput = runtime.atomInput;
  runtime.heap.objectDefine(bag, atomInput, input, PROP_DEFAULT);
  g = 0;
  while (g < count) {
    let captured = undefinedValue();
    if (starts[usize(g)] >= 0) captured = runtime.substringValue(inputHandle, usize(starts[usize(g)]), usize(ends[usize(g)]));
    runtime.heap.arraySet(array, u32(g), captured);
    g = g + 1;
  }
  // groups: an object without a prototype when the pattern names any.
  let groups = undefinedValue();
  const hasNames = runtime.regexBackend.hasNames(entry);
  if (hasNames) {
    const groupsObject = runtime.heap.allocateObject(0);
    groups = cellValue(groupsObject);
    runtime.pushTempRoot(groups);
    const names = runtime.regexBackend.names(entry);
    let at: usize = 0;
    let group: i32 = 1;
    while (group < count && at <= names.length) {
      let name = Array<u8>();
      while (at < names.length && names[at] != 0) {
        name.push(names[at]);
        at = at + 1;
      }
      at = at + 1;
      if (name.length > 0) {
        const nameAtom = runtime.internUtf8Value(move name);
        const existing = runtime.heap.objectFindSlot(groupsObject, asCell(nameAtom));
        let captured = undefinedValue();
        if (starts[usize(group)] >= 0) captured = runtime.substringValue(inputHandle, usize(starts[usize(group)]), usize(ends[usize(group)]));
        // A duplicated name keeps the group that took part.
        if (existing < 0 || starts[usize(group)] >= 0) runtime.heap.objectDefine(groupsObject, asCell(nameAtom), captured, PROP_DEFAULT);
      }
      group = group + 1;
    }
    runtime.popTempRoot();
  }
  const atomGroups = runtime.atomGroups;
  runtime.heap.objectDefine(bag, atomGroups, groups, PROP_DEFAULT);
  if (hasIndices) {
    const indices = runtime.heap.allocateArray(u32(count));
    const indicesValue = cellValue(indices);
    runtime.pushTempRoot(indicesValue);
    g = 0;
    while (g < count) {
      let pair = undefinedValue();
      if (starts[usize(g)] >= 0) {
        const pairArray = runtime.heap.allocateArray(2);
        runtime.heap.arraySet(pairArray, 0, int32Value(starts[usize(g)]));
        runtime.heap.arraySet(pairArray, 1, int32Value(ends[usize(g)]));
        pair = cellValue(pairArray);
      }
      runtime.heap.arraySet(indices, u32(g), pair);
      g = g + 1;
    }
    let indexGroups = undefinedValue();
    if (hasNames) {
      const indexGroupsObject = runtime.heap.allocateObject(0);
      indexGroups = cellValue(indexGroupsObject);
      runtime.pushTempRoot(indexGroups);
      const names = runtime.regexBackend.names(entry);
      let at: usize = 0;
      let group: i32 = 1;
      while (group < count && at <= names.length) {
        let name = Array<u8>();
        while (at < names.length && names[at] != 0) {
          name.push(names[at]);
          at = at + 1;
        }
        at = at + 1;
        if (name.length > 0) {
          const nameAtom = runtime.internUtf8Value(move name);
          const existing = runtime.heap.objectFindSlot(indexGroupsObject, asCell(nameAtom));
          const pair = runtime.heap.arrayHasIndex(indices, u32(group)) ? runtime.heap.arrayGet(indices, u32(group)) : undefinedValue();
          if (existing < 0 || starts[usize(group)] >= 0) runtime.heap.objectDefine(indexGroupsObject, asCell(nameAtom), pair, PROP_DEFAULT);
        }
        group = group + 1;
      }
      runtime.popTempRoot();
    }
    const indicesBag = runtime.arrayBag(indices);
    runtime.heap.objectDefine(indicesBag, atomGroups, indexGroups, PROP_DEFAULT);
    const indicesText: String = "indices";
    const indicesAtom = runtime.atomOf(in indicesText);
    runtime.heap.objectDefine(bag, indicesAtom, indicesValue, PROP_DEFAULT);
    runtime.popTempRoot();
  }
  runtime.popTempRoot();
  return arrayValue;
}

// RegExpExec: a user `exec` when the object has one, else the builtin.
function regexpExec(inout runtime: Runtime, rx: Value, input: Value): Value {
  const atomExec = runtime.atomExec;
  const exec = runtime.getProperty(rx, cellValue(atomExec));
  if (runtime.pendingThrow) return undefinedValue();
  const builtin = runtime.regexExecFn;
  if (runtime.isCallable(exec) && !(isCell(exec) && asCell(exec) == builtin)) {
    const result = runtime.callValue1(exec, rx, input);
    if (runtime.pendingThrow) return undefinedValue();
    if (!runtime.isObjectLike(result) && !isNull(result)) {
      const message: String = "RegExp exec method returned something other than an Object or null";
      return raiseType(inout runtime, in message);
    }
    return result;
  }
  if (!runtime.isRegExpObject(rx)) {
    const message: String = "RegExp.prototype.exec called on an object that is not a RegExp";
    return raiseType(inout runtime, in message);
  }
  return builtinExec(inout runtime, asCell(rx), input);
}

// --- Constructor ---

function constructRegExp(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const pattern = runtime.argument(argsBase, argc, 0);
  const flags = runtime.argument(argsBase, argc, 1);
  const patternIsRegExp = runtime.isRegExp(pattern);
  if (runtime.pendingThrow) return undefinedValue();
  const constructing = runtime.isObjectLike(thisValue);
  if (!constructing && patternIsRegExp && isUndefined(flags)) {
    // RegExp(re) hands back a RegExp whose constructor is RegExp itself.
    const atomConstructor = runtime.atomConstructor;
    const patternCtor = runtime.getProperty(pattern, cellValue(atomConstructor));
    if (runtime.pendingThrow) return undefinedValue();
    if (isCell(patternCtor) && asCell(patternCtor) == callee) return pattern;
  }
  let p = pattern;
  let f = flags;
  if (runtime.isRegExpObject(pattern)) {
    p = runtime.regexpSourceValue(asCell(pattern));
    if (isUndefined(flags)) {
      const flagsText: String = "flags";
      const flagsKey = textKey(inout runtime, in flagsText);
      f = runtime.getProperty(pattern, flagsKey);
      if (runtime.pendingThrow) return undefinedValue();
    }
  } else if (patternIsRegExp) {
    const sourceText: String = "source";
    const sourceKey = textKey(inout runtime, in sourceText);
    p = runtime.getProperty(pattern, sourceKey);
    if (runtime.pendingThrow) return undefinedValue();
    if (isUndefined(flags)) {
      const flagsText: String = "flags";
      const flagsKey = textKey(inout runtime, in flagsText);
      f = runtime.getProperty(pattern, flagsKey);
      if (runtime.pendingThrow) return undefinedValue();
    }
  }
  // The object: the one construction made (its prototype from the new
  // target), or a fresh one for a plain call.
  let object: u32 = 0;
  if (constructing) {
    object = asCell(thisValue);
    const atomLastIndex = runtime.atomLastIndex;
    if (runtime.heap.objectFindSlot(object, atomLastIndex) < 0) runtime.heap.objectDefine(object, atomLastIndex, int32Value(0), 1);
  } else {
    const regexProto = runtime.regexProto;
    object = runtime.regexpAlloc(regexProto);
  }
  runtime.pushTempRoot(cellValue(object));
  let patternText = p;
  if (isUndefined(p)) patternText = runtime.internLatin1Value(Array<u8>());
  let flagsText2 = f;
  if (isUndefined(f)) flagsText2 = runtime.internLatin1Value(Array<u8>());
  const patternString = runtime.toStringValue(patternText);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  runtime.pushTempRoot(patternString);
  const flagsString = runtime.toStringValue(flagsText2);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    runtime.popTempRoot();
    return undefinedValue();
  }
  const ok = runtime.regexpInitialize(object, patternString, flagsString);
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (!ok) return undefinedValue();
  return cellValue(object);
}

// --- Prototype methods ---

function regexpExecMethod(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "RegExp.prototype.exec";
  const rx = thisRegExp(inout runtime, thisValue, in what);
  if (rx == 0) return undefinedValue();
  const input = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(input);
  const result = builtinExec(inout runtime, rx, input);
  runtime.popTempRoot();
  return result;
}

function regexpTest(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "RegExp.prototype.test";
  if (!thisObject(inout runtime, thisValue, in what)) return undefinedValue();
  const input = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(input);
  const result = regexpExec(inout runtime, thisValue, input);
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  return booleanValue(!isNull(result));
}

function regexpToString(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "RegExp.prototype.toString";
  if (!thisObject(inout runtime, thisValue, in what)) return undefinedValue();
  const sourceText: String = "source";
  const sourceKey = textKey(inout runtime, in sourceText);
  const source = runtime.getProperty(thisValue, sourceKey);
  if (runtime.pendingThrow) return undefinedValue();
  const sourceString = runtime.toStringValue(source);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(sourceString);
  const flagsText: String = "flags";
  const flagsKey = textKey(inout runtime, in flagsText);
  const flags = runtime.getProperty(thisValue, flagsKey);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  const flagsString = runtime.toStringValue(flags);
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  let text = Array<u16>();
  text.push(47);
  appendUnits(inout text, stringBytesOf(inout runtime, sourceString));
  text.push(47);
  appendUnits(inout text, stringBytesOf(inout runtime, flagsString));
  return runtime.newStringUnits(move text);
}

// EscapeRegExpPattern: "/" and line terminators escaped, "(?:)" when
// empty, so the result reads back as the same pattern.
function escapedSource(in source: Array<u16>): Array<u16> {
  let result = Array<u16>();
  if (source.length == 0) {
    const empty: String = "(?:)";
    return unitsOf(in empty);
  }
  let inClass = false;
  let i: usize = 0;
  while (i < source.length) {
    const byte = source[i];
    if (byte == 92 && i + 1 < source.length) {
      result.push(byte);
      result.push(source[i + 1]);
      i = i + 2;
      continue;
    }
    if (byte == 91) inClass = true;
    if (byte == 93) inClass = false;
    if (byte == 47 && !inClass) {
      result.push(92);
      result.push(47);
    } else if (byte == 10) {
      result.push(92);
      result.push(110);
    } else if (byte == 13) {
      result.push(92);
      result.push(114);
    } else {
      result.push(byte);
    }
    i = i + 1;
  }
  return result;
}

function regexpSourceGetter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (runtime.isRegExpObject(thisValue)) {
    const source = runtime.heap.stringUnits(asCell(runtime.regexpSourceValue(asCell(thisValue))));
    return runtime.newStringUnits(escapedSource(in source));
  }
  const regexProto = runtime.regexProto;
  if (isCell(thisValue) && asCell(thisValue) == regexProto) {
    const empty: String = "(?:)";
    return runtime.internText(in empty);
  }
  const message: String = "RegExp.prototype.source getter called on an object that is not a RegExp";
  return raiseType(inout runtime, in message);
}

// One boolean flag getter; the callee's slot 0 is the bit.
function regexpFlagGetter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const bit = asInt32(runtime.heap.slot(callee, 0));
  if (runtime.isRegExpObject(thisValue)) return booleanValue((runtime.regexpFlagBits(asCell(thisValue)) & bit) != 0);
  const regexProto = runtime.regexProto;
  if (isCell(thisValue) && asCell(thisValue) == regexProto) return undefinedValue();
  const message: String = "RegExp flag getter called on an object that is not a RegExp";
  return raiseType(inout runtime, in message);
}

// flags: the letters in specification order, each read as a property.
function regexpFlagsGetter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "RegExp.prototype.flags";
  if (!thisObject(inout runtime, thisValue, in what)) return undefinedValue();
  const names: String = "hasIndices,global,ignoreCase,multiline,dotAll,unicode,unicodeSets,sticky";
  const letters: String = "dgimsuvy";
  const nameBytes = unitsOf(in names);
  const letterBytes = unitsOf(in letters);
  let result = Array<u16>();
  let at: usize = 0;
  let which: usize = 0;
  while (at <= nameBytes.length) {
    let name = Array<u16>();
    while (at < nameBytes.length && nameBytes[at] != 44) {
      name.push(nameBytes[at]);
      at = at + 1;
    }
    at = at + 1;
    const key = runtime.internUnitsValue(move name);
    const held = runtime.getProperty(thisValue, key);
    if (runtime.pendingThrow) return undefinedValue();
    if (runtime.toBooleanValue(held)) result.push(letterBytes[which]);
    which = which + 1;
  }
  return runtime.newStringUnits(move result);
}

// --- @@match ---

function regexpMatch(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "RegExp.prototype[Symbol.match]";
  if (!thisObject(inout runtime, thisValue, in what)) return undefinedValue();
  const input = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(input);
  const flags = flagsStringOf(inout runtime, thisValue);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  if (!hasFlag(in flags, 103)) {
    const result = regexpExec(inout runtime, thisValue, input);
    runtime.popTempRoot();
    return result;
  }
  const unicode = hasFlag(in flags, 117) || hasFlag(in flags, 118);
  if (!setLastIndex(inout runtime, thisValue, 0)) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  const bytes = stringBytesOf(inout runtime, input);
  const array = runtime.heap.allocateArray(0);
  const arrayValue = cellValue(array);
  runtime.pushTempRoot(arrayValue);
  let n: u32 = 0;
  while (true) {
    const result = regexpExec(inout runtime, thisValue, input);
    if (runtime.pendingThrow) break;
    if (isNull(result)) break;
    const matched = runtime.getProperty(result, int32Value(0));
    if (runtime.pendingThrow) break;
    const matchString = runtime.toStringValue(matched);
    if (runtime.pendingThrow) break;
    runtime.heap.arraySet(array, n, matchString);
    n = n + 1;
    if (runtime.heap.stringLength(asCell(matchString)) == 0) {
      const thisIndex = getLastIndex(inout runtime, thisValue);
      if (runtime.pendingThrow) break;
      if (!setLastIndex(inout runtime, thisValue, advanceIndex(in bytes, thisIndex, unicode))) break;
    }
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  if (n == 0) return nullValue();
  return arrayValue;
}

// --- @@search ---

function regexpSearch(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "RegExp.prototype[Symbol.search]";
  if (!thisObject(inout runtime, thisValue, in what)) return undefinedValue();
  const input = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(input);
  const atomLastIndex = runtime.atomLastIndex;
  const previous = runtime.getProperty(thisValue, cellValue(atomLastIndex));
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  runtime.pushTempRoot(previous);
  if (!runtime.sameValue(previous, int32Value(0))) {
    if (!setLastIndex(inout runtime, thisValue, 0)) {
      runtime.popTempRoot();
      runtime.popTempRoot();
      return undefinedValue();
    }
  }
  const result = regexpExec(inout runtime, thisValue, input);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    runtime.popTempRoot();
    return undefinedValue();
  }
  runtime.pushTempRoot(result);
  const current = runtime.getProperty(thisValue, cellValue(atomLastIndex));
  if (!runtime.pendingThrow && !runtime.sameValue(current, previous)) {
    const restored = runtime.setProperty(thisValue, cellValue(atomLastIndex), previous);
    if (!runtime.pendingThrow && !restored) {
      const message: String = "Cannot assign to read only property 'lastIndex'";
      raiseType(inout runtime, in message);
    }
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  if (isNull(result)) return int32Value(-1);
  const atomIndex = runtime.atomIndex;
  return runtime.getProperty(result, cellValue(atomIndex));
}

// --- @@replace ---

// GetSubstitution over bytes: $$ $& $` $' $n $nn $<name>.
function substitution(inout runtime: Runtime, in matched: Array<u16>, in text: Array<u16>, position: usize, in captures: Array<Value>, namedCaptures: Value, in template: Array<u16>): Array<u16> {
  let result = Array<u16>();
  const m = captures.length;
  let i: usize = 0;
  while (i < template.length) {
    const byte = template[i];
    if (byte != 36 || i + 1 >= template.length) {
      result.push(byte);
      i = i + 1;
      continue;
    }
    const next = template[i + 1];
    if (next == 36) {
      result.push(36);
      i = i + 2;
    } else if (next == 38) {
      appendUnits(inout result, sliceFrom(in matched, 0));
      i = i + 2;
    } else if (next == 96) {
      appendUnits(inout result, sliceUnits(in text, 0, position));
      i = i + 2;
    } else if (next == 39) {
      const tailStart = position + matched.length;
      if (tailStart < text.length) appendUnits(inout result, sliceFrom(in text, tailStart));
      i = i + 2;
    } else if (next >= 48 && next <= 57) {
      let digits: usize = 1;
      let index = usize(next - 48);
      if (i + 2 < template.length && template[i + 2] >= 48 && template[i + 2] <= 57) {
        const two = index * 10 + usize(template[i + 2] - 48);
        if (two >= 1 && two <= m) {
          index = two;
          digits = 2;
        }
      }
      if (index >= 1 && index <= m) {
        const capture = captures[index - 1];
        if (!isUndefined(capture)) {
          const captureText = runtime.toStringValue(capture);
          if (runtime.pendingThrow) return Array<u16>();
          appendUnits(inout result, stringBytesOf(inout runtime, captureText));
        }
        i = i + 1 + digits;
      } else {
        result.push(36);
        i = i + 1;
      }
    } else if (next == 60) {
      if (isUndefined(namedCaptures)) {
        result.push(36);
        result.push(60);
        i = i + 2;
        continue;
      }
      let close = i + 2;
      while (close < template.length && template[close] != 62) { close = close + 1; }
      if (close >= template.length) {
        result.push(36);
        result.push(60);
        i = i + 2;
        continue;
      }
      const groupName = runtime.newStringUnits(sliceUnits(in template, i + 2, close));
      const capture = runtime.getProperty(namedCaptures, groupName);
      if (runtime.pendingThrow) return Array<u16>();
      if (!isUndefined(capture)) {
        const captureText = runtime.toStringValue(capture);
        if (runtime.pendingThrow) return Array<u16>();
        appendUnits(inout result, stringBytesOf(inout runtime, captureText));
      }
      i = close + 1;
    } else {
      result.push(36);
      i = i + 1;
    }
  }
  return result;
}

function regexpReplace(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "RegExp.prototype[Symbol.replace]";
  if (!thisObject(inout runtime, thisValue, in what)) return undefinedValue();
  const input = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(input);
  const bytes = stringBytesOf(inout runtime, input);
  let replaceValue = runtime.argument(argsBase, argc, 1);
  const functional = runtime.isCallable(replaceValue);
  let template = Array<u16>();
  if (!functional) {
    const replaceText = runtime.toStringValue(replaceValue);
    if (runtime.pendingThrow) {
      runtime.popTempRoot();
      return undefinedValue();
    }
    replaceValue = replaceText;
    template = stringBytesOf(inout runtime, replaceText);
  }
  runtime.pushTempRoot(replaceValue);
  const flags = flagsStringOf(inout runtime, thisValue);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    runtime.popTempRoot();
    return undefinedValue();
  }
  const global = hasFlag(in flags, 103);
  const unicode = hasFlag(in flags, 117) || hasFlag(in flags, 118);
  if (global) {
    if (!setLastIndex(inout runtime, thisValue, 0)) {
      runtime.popTempRoot();
      runtime.popTempRoot();
      return undefinedValue();
    }
  }
  // Every match first, rooted in an array; then the replacements.
  const results = runtime.heap.allocateArray(0);
  const resultsValue = cellValue(results);
  runtime.pushTempRoot(resultsValue);
  let resultCount: u32 = 0;
  while (true) {
    const result = regexpExec(inout runtime, thisValue, input);
    if (runtime.pendingThrow) break;
    if (isNull(result)) break;
    runtime.heap.arraySet(results, resultCount, result);
    resultCount = resultCount + 1;
    if (!global) break;
    const matched = runtime.getProperty(result, int32Value(0));
    if (runtime.pendingThrow) break;
    const matchString = runtime.toStringValue(matched);
    if (runtime.pendingThrow) break;
    if (runtime.heap.stringLength(asCell(matchString)) == 0) {
      const thisIndex = getLastIndex(inout runtime, thisValue);
      if (runtime.pendingThrow) break;
      if (!setLastIndex(inout runtime, thisValue, advanceIndex(in bytes, thisIndex, unicode))) break;
    }
  }
  let accumulated = Array<u16>();
  let nextSourcePosition: usize = 0;
  let r: u32 = 0;
  while (!runtime.pendingThrow && r < resultCount) {
    const result = runtime.heap.arrayGet(results, r);
    r = r + 1;
    const atomLength = runtime.atomLength;
    const lengthValue = runtime.getProperty(result, cellValue(atomLength));
    if (runtime.pendingThrow) break;
    const resultLength = lengthOf(inout runtime, lengthValue);
    if (runtime.pendingThrow) break;
    const nCaptures: usize = resultLength > 0 ? resultLength - 1 : 0;
    const matchedValue = runtime.getProperty(result, int32Value(0));
    if (runtime.pendingThrow) break;
    const matchedString = runtime.toStringValue(matchedValue);
    if (runtime.pendingThrow) break;
    runtime.pushTempRoot(matchedString);
    const matched = stringBytesOf(inout runtime, matchedString);
    const atomIndex = runtime.atomIndex;
    const indexValue = runtime.getProperty(result, cellValue(atomIndex));
    if (runtime.pendingThrow) {
      runtime.popTempRoot();
      break;
    }
    const indexNumber = runtime.toNumberValue(indexValue);
    if (runtime.pendingThrow) {
      runtime.popTempRoot();
      break;
    }
    let position: usize = 0;
    if (indexNumber == indexNumber && indexNumber > 0.0) {
      const clipped = truncateDouble(indexNumber);
      position = clipped >= f64(bytes.length) ? bytes.length : usize(clipped);
    }
    let captures = Array<Value>();
    const capturesArray = runtime.heap.allocateArray(0);
    runtime.pushTempRoot(cellValue(capturesArray));
    let n: usize = 1;
    while (n <= nCaptures) {
      let capture = runtime.getProperty(result, int32Value(i32(n)));
      if (runtime.pendingThrow) break;
      if (!isUndefined(capture)) {
        capture = runtime.toStringValue(capture);
        if (runtime.pendingThrow) break;
      }
      runtime.heap.arraySet(capturesArray, u32(n - 1), capture);
      captures.push(capture);
      n = n + 1;
    }
    if (runtime.pendingThrow) {
      runtime.popTempRoot();
      runtime.popTempRoot();
      break;
    }
    const atomGroups = runtime.atomGroups;
    let namedCaptures = runtime.getProperty(result, cellValue(atomGroups));
    if (runtime.pendingThrow) {
      runtime.popTempRoot();
      runtime.popTempRoot();
      break;
    }
    let replacement = Array<u16>();
    if (functional) {
      let args = Array<Value>();
      args.push(matchedString);
      let c: usize = 0;
      while (c < captures.length) {
        args.push(captures[c]);
        c = c + 1;
      }
      args.push(doubleValue(f64(position)));
      args.push(input);
      if (!isUndefined(namedCaptures)) args.push(namedCaptures);
      const produced = runtime.callValue(replaceValue, undefinedValue(), move args);
      if (runtime.pendingThrow) {
        runtime.popTempRoot();
        runtime.popTempRoot();
        break;
      }
      const producedString = runtime.toStringValue(produced);
      if (runtime.pendingThrow) {
        runtime.popTempRoot();
        runtime.popTempRoot();
        break;
      }
      replacement = stringBytesOf(inout runtime, producedString);
    } else {
      if (!isUndefined(namedCaptures)) {
        namedCaptures = runtime.toObjectValue(namedCaptures);
        if (runtime.pendingThrow) {
          runtime.popTempRoot();
          runtime.popTempRoot();
          break;
        }
      }
      replacement = substitution(inout runtime, in matched, in bytes, position, in captures, namedCaptures, in template);
      if (runtime.pendingThrow) {
        runtime.popTempRoot();
        runtime.popTempRoot();
        break;
      }
    }
    runtime.popTempRoot();
    runtime.popTempRoot();
    if (position >= nextSourcePosition) {
      appendUnits(inout accumulated, sliceUnits(in bytes, nextSourcePosition, position));
      appendUnits(inout accumulated, move replacement);
      nextSourcePosition = position + matched.length;
    }
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  if (nextSourcePosition < bytes.length) appendUnits(inout accumulated, sliceFrom(in bytes, nextSourcePosition));
  return runtime.newStringUnits(move accumulated);
}

// --- @@split ---

function regexpSplit(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "RegExp.prototype[Symbol.split]";
  if (!thisObject(inout runtime, thisValue, in what)) return undefinedValue();
  const input = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(input);
  const bytes = stringBytesOf(inout runtime, input);
  const size = bytes.length;
  const defaultCtor = cellValue(runtime.regexCtor);
  const ctor = speciesConstructorOf(inout runtime, thisValue, defaultCtor);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  let flags = flagsStringOf(inout runtime, thisValue);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  const unicode = hasFlag(in flags, 117) || hasFlag(in flags, 118);
  if (!hasFlag(in flags, 121)) flags.push(121);
  let ctorArgs = Array<Value>();
  ctorArgs.push(thisValue);
  ctorArgs.push(runtime.newStringUnits(move flags));
  const splitter = runtime.constructValue(ctor, move ctorArgs, ctor);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  runtime.pushTempRoot(splitter);
  const array = runtime.heap.allocateArray(0);
  const arrayValue = cellValue(array);
  runtime.pushTempRoot(arrayValue);
  const limitValue = runtime.argument(argsBase, argc, 1);
  let limit: u32 = 4294967295;
  if (!isUndefined(limitValue)) {
    const limitNumber = runtime.toNumberValue(limitValue);
    if (runtime.pendingThrow) {
      runtime.popTempRoot();
      runtime.popTempRoot();
      runtime.popTempRoot();
      return undefinedValue();
    }
    limit = toUint32Of(limitNumber);
  }
  let count: u32 = 0;
  let failed = false;
  if (limit == 0) {
    // nothing
  } else if (size == 0) {
    const z = regexpExec(inout runtime, splitter, input);
    if (runtime.pendingThrow) {
      failed = true;
    } else if (isNull(z)) {
      runtime.heap.arraySet(array, 0, input);
      count = 1;
    }
  } else {
    let p: usize = 0;
    let q: usize = 0;
    while (q < size) {
      if (!setLastIndex(inout runtime, splitter, q)) { failed = true; break; }
      const z = regexpExec(inout runtime, splitter, input);
      if (runtime.pendingThrow) { failed = true; break; }
      if (isNull(z)) {
        q = advanceIndex(in bytes, q, unicode);
        continue;
      }
      let e = getLastIndex(inout runtime, splitter);
      if (runtime.pendingThrow) { failed = true; break; }
      if (e > size) e = size;
      if (e == p) {
        q = advanceIndex(in bytes, q, unicode);
        continue;
      }
      runtime.heap.arraySet(array, count, substring(inout runtime, in bytes, p, q));
      count = count + 1;
      if (count == limit) break;
      p = e;
      const atomLength = runtime.atomLength;
      const lengthValue = runtime.getProperty(z, cellValue(atomLength));
      if (runtime.pendingThrow) { failed = true; break; }
      const zLength = lengthOf(inout runtime, lengthValue);
      if (runtime.pendingThrow) { failed = true; break; }
      const captures: usize = zLength > 0 ? zLength - 1 : 0;
      let i: usize = 1;
      let reachedLimit = false;
      while (i <= captures) {
        const capture = runtime.getProperty(z, int32Value(i32(i)));
        if (runtime.pendingThrow) { failed = true; break; }
        runtime.heap.arraySet(array, count, capture);
        count = count + 1;
        if (count == limit) { reachedLimit = true; break; }
        i = i + 1;
      }
      if (failed || reachedLimit) break;
      q = p;
    }
    if (!failed && count != limit) {
      runtime.heap.arraySet(array, count, substring(inout runtime, in bytes, p, size));
      count = count + 1;
    }
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (failed || runtime.pendingThrow) return undefinedValue();
  return arrayValue;
}

function toUint32Of(number: f64): u32 {
  if (number != number) return 0;
  const truncated = truncateDouble(number);
  const modulus = 4294967296.0;
  let wrapped = truncated - truncateDouble(truncated / modulus) * modulus;
  if (wrapped < 0.0) wrapped = wrapped + modulus;
  return u32(wrapped);
}

// --- @@matchAll and the string iterator ---

// The iterator's state: [matcher, string, global, unicode, done].
function regexpMatchAll(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "RegExp.prototype[Symbol.matchAll]";
  if (!thisObject(inout runtime, thisValue, in what)) return undefinedValue();
  const input = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(input);
  const defaultCtor = cellValue(runtime.regexCtor);
  const ctor = speciesConstructorOf(inout runtime, thisValue, defaultCtor);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  const flags = flagsStringOf(inout runtime, thisValue);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  const global = hasFlag(in flags, 103);
  const unicode = hasFlag(in flags, 117) || hasFlag(in flags, 118);
  let ctorArgs = Array<Value>();
  ctorArgs.push(thisValue);
  ctorArgs.push(runtime.newStringUnits(copyUnits(in flags)));
  const matcher = runtime.constructValue(ctor, move ctorArgs, ctor);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  runtime.pushTempRoot(matcher);
  const lastIndex = getLastIndex(inout runtime, thisValue);
  if (runtime.pendingThrow || !setLastIndex(inout runtime, matcher, lastIndex)) {
    runtime.popTempRoot();
    runtime.popTempRoot();
    return undefinedValue();
  }
  const state = runtime.heap.allocateArray(5);
  runtime.pushTempRoot(cellValue(state));
  runtime.heap.arraySet(state, 0, matcher);
  runtime.heap.arraySet(state, 1, input);
  runtime.heap.arraySet(state, 2, booleanValue(global));
  runtime.heap.arraySet(state, 3, booleanValue(unicode));
  runtime.heap.arraySet(state, 4, booleanValue(false));
  const regexIteratorProto = runtime.regexIteratorProto;
  const iterator = runtime.heap.allocateObject(regexIteratorProto);
  const atomRegexIter = runtime.atomRegexIter;
  runtime.heap.objectDefine(iterator, atomRegexIter, cellValue(state), PROP_NONE);
  runtime.popTempRoot();
  runtime.popTempRoot();
  runtime.popTempRoot();
  return cellValue(iterator);
}

function iterationResult(inout runtime: Runtime, value: Value, done: boolean): Value {
  const objectProto = runtime.objectProto;
  const result = runtime.heap.allocateObject(objectProto);
  const valueText: String = "value";
  const valueAtom = runtime.atomOf(in valueText);
  runtime.heap.objectDefine(result, valueAtom, value, PROP_DEFAULT);
  const doneText: String = "done";
  const doneAtom = runtime.atomOf(in doneText);
  runtime.heap.objectDefine(result, doneAtom, booleanValue(done), PROP_DEFAULT);
  return cellValue(result);
}

function regexpStringIteratorNext(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const atomRegexIter = runtime.atomRegexIter;
  if (!runtime.isObjectLike(thisValue) || runtime.heap.objectFindSlot(asCell(thisValue), atomRegexIter) < 0) {
    const message: String = "%RegExpStringIterator%.next called on an incompatible receiver";
    return raiseType(inout runtime, in message);
  }
  const slot = runtime.heap.objectFindSlot(asCell(thisValue), atomRegexIter);
  const state = asCell(runtime.heap.slot(asCell(thisValue), u32(slot)));
  if (runtime.toBooleanValue(runtime.heap.arrayGet(state, 4))) return iterationResult(inout runtime, undefinedValue(), true);
  const matcher = runtime.heap.arrayGet(state, 0);
  const input = runtime.heap.arrayGet(state, 1);
  const global = runtime.toBooleanValue(runtime.heap.arrayGet(state, 2));
  const unicode = runtime.toBooleanValue(runtime.heap.arrayGet(state, 3));
  const found = regexpExec(inout runtime, matcher, input);
  if (runtime.pendingThrow) return undefinedValue();
  if (isNull(found)) {
    runtime.heap.arraySet(state, 4, booleanValue(true));
    return iterationResult(inout runtime, undefinedValue(), true);
  }
  if (!global) {
    runtime.heap.arraySet(state, 4, booleanValue(true));
    return iterationResult(inout runtime, found, false);
  }
  runtime.pushTempRoot(found);
  const matched = runtime.getProperty(found, int32Value(0));
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  const matchString = runtime.toStringValue(matched);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  if (runtime.heap.stringLength(asCell(matchString)) == 0) {
    const bytes = stringBytesOf(inout runtime, input);
    const thisIndex = getLastIndex(inout runtime, matcher);
    if (runtime.pendingThrow || !setLastIndex(inout runtime, matcher, advanceIndex(in bytes, thisIndex, unicode))) {
      runtime.popTempRoot();
      return undefinedValue();
    }
  }
  runtime.popTempRoot();
  return iterationResult(inout runtime, found, false);
}

function speciesGetter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return thisValue;
}

// --- Install ---

function defineGetter(inout runtime: Runtime, target: u32, in name: String, fn: HostFunction, bound: Value): void {
  const getPrefix: String = "get ";
  let getterName = bytesOf(in getPrefix);
  appendBytes(inout getterName, bytesOf(in name));
  const getter = runtime.defineHostFunctionBytes(fn, bound, 0, move getterName);
  const accessor = runtime.heap.allocateAccessor(cellValue(getter), undefinedValue());
  const atom = runtime.atomOf(in name);
  runtime.heap.objectDefine(target, atom, cellValue(accessor), PROP_CONFIGURABLE | PROP_ACCESSOR);
}

function defineSymbolMethod(inout runtime: Runtime, target: u32, symbol: Value, in name: String, fn: HostFunction, length: u32): void {
  const handle = runtime.defineHostFunction(fn, undefinedValue(), length, in name);
  const key = runtime.propertyKey(symbol);
  runtime.heap.objectDefine(target, key, cellValue(handle), PROP_METHOD);
}

export function installRegExp(inout runtime: Runtime): void {
  const objectProto = runtime.objectProto;
  const proto = runtime.heap.allocateObject(objectProto);
  runtime.regexProto = proto;
  const regexText: String = "RegExp";
  const ctor = runtime.defineConstructor(constructRegExp, undefinedValue(), 2, in regexText);
  runtime.heap.setLink(ctor, proto);
  const atomConstructor = runtime.atomConstructor;
  runtime.defineOwnAttr(proto, atomConstructor, cellValue(ctor), PROP_METHOD);
  runtime.setGlobal("RegExp", cellValue(ctor));
  runtime.regexCtor = ctor;
  const speciesName: String = "get [Symbol.species]";
  const speciesFn = runtime.defineHostFunction(speciesGetter, undefinedValue(), 0, in speciesName);
  const speciesAccessor = runtime.heap.allocateAccessor(cellValue(speciesFn), undefinedValue());
  const symbolSpecies = runtime.symbolSpecies;
  const speciesKey = runtime.propertyKey(symbolSpecies);
  runtime.defineOwnAttr(ctor, speciesKey, cellValue(speciesAccessor), PROP_CONFIGURABLE | PROP_ACCESSOR);

  const execText: String = "exec";
  runtime.regexExecFn = runtime.defineMethod(proto, in execText, regexpExecMethod, 1);
  const testText: String = "test";
  runtime.defineMethod(proto, in testText, regexpTest, 1);
  const toStringText: String = "toString";
  runtime.defineMethod(proto, in toStringText, regexpToString, 0);

  const sourceText: String = "source";
  defineGetter(inout runtime, proto, in sourceText, regexpSourceGetter, undefinedValue());
  const flagsText: String = "flags";
  defineGetter(inout runtime, proto, in flagsText, regexpFlagsGetter, undefinedValue());
  const globalText: String = "global";
  defineGetter(inout runtime, proto, in globalText, regexpFlagGetter, int32Value(REGEX_GLOBAL));
  const ignoreCaseText: String = "ignoreCase";
  defineGetter(inout runtime, proto, in ignoreCaseText, regexpFlagGetter, int32Value(REGEX_IGNORE_CASE));
  const multilineText: String = "multiline";
  defineGetter(inout runtime, proto, in multilineText, regexpFlagGetter, int32Value(REGEX_MULTILINE));
  const dotAllText: String = "dotAll";
  defineGetter(inout runtime, proto, in dotAllText, regexpFlagGetter, int32Value(REGEX_DOT_ALL));
  const unicodeText: String = "unicode";
  defineGetter(inout runtime, proto, in unicodeText, regexpFlagGetter, int32Value(REGEX_UNICODE));
  const unicodeSetsText: String = "unicodeSets";
  defineGetter(inout runtime, proto, in unicodeSetsText, regexpFlagGetter, int32Value(REGEX_UNICODE_SETS));
  const stickyText: String = "sticky";
  defineGetter(inout runtime, proto, in stickyText, regexpFlagGetter, int32Value(REGEX_STICKY));
  const hasIndicesText: String = "hasIndices";
  defineGetter(inout runtime, proto, in hasIndicesText, regexpFlagGetter, int32Value(REGEX_HAS_INDICES));

  const symbolMatch = runtime.symbolMatch;
  const matchName: String = "[Symbol.match]";
  defineSymbolMethod(inout runtime, proto, symbolMatch, in matchName, regexpMatch, 1);
  const symbolMatchAll = runtime.symbolMatchAll;
  const matchAllName: String = "[Symbol.matchAll]";
  defineSymbolMethod(inout runtime, proto, symbolMatchAll, in matchAllName, regexpMatchAll, 1);
  const symbolReplace = runtime.symbolReplace;
  const replaceName: String = "[Symbol.replace]";
  defineSymbolMethod(inout runtime, proto, symbolReplace, in replaceName, regexpReplace, 2);
  const symbolSearch = runtime.symbolSearch;
  const searchName: String = "[Symbol.search]";
  defineSymbolMethod(inout runtime, proto, symbolSearch, in searchName, regexpSearch, 1);
  const symbolSplit = runtime.symbolSplit;
  const splitName: String = "[Symbol.split]";
  defineSymbolMethod(inout runtime, proto, symbolSplit, in splitName, regexpSplit, 2);

  // %RegExpStringIteratorPrototype%
  const iteratorProto = runtime.iteratorProto;
  const stringIteratorProto = runtime.heap.allocateObject(iteratorProto);
  runtime.regexIteratorProto = stringIteratorProto;
  const nextText: String = "next";
  runtime.defineMethod(stringIteratorProto, in nextText, regexpStringIteratorNext, 0);
  const symbolToStringTag = runtime.symbolToStringTag;
  const tagKey = runtime.propertyKey(symbolToStringTag);
  const tagText: String = "RegExp String Iterator";
  runtime.heap.objectDefine(stringIteratorProto, tagKey, runtime.internText(in tagText), PROP_CONFIGURABLE);
}
