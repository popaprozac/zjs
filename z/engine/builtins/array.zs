// Array: the constructor, isArray, and the prototype's core methods.
//
// Methods that take a callback root their working cells while the
// callback runs, since a collection may happen inside it.
import { Value, undefinedValue, booleanValue, int32Value, doubleValue, cellValue, asCell, isCell, isUndefined, isNull, isDeleted, asInt32, isInt32, isNumber } from "../value.zs";
import { thread } from "std/thread";
import { Runtime, ERROR_KIND_RANGE, toNumber, isIntegralDouble, truncateDouble } from "../runtime.zs";

function thisArray(inout runtime: Runtime, thisValue: Value, in method: String): u32 {
  if (isCell(thisValue) && asCell(thisValue) != 0 && runtime.heap.isArray(asCell(thisValue))) return asCell(thisValue);
  const message: String = `Array.prototype.${method} called on a non-array`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return 0;
}

// new Array(n) / Array(a, b, c)
function constructArray(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (argc == 1) {
    // One number is a length; it must be a non-negative integer.
    const first = runtime.argument(argsBase, argc, 0);
    if (isNumber(first)) {
      const number = toNumber(first);
      if (!isIntegralDouble(number) || number < 0.0 || number > 4294967295.0) {
        const message: String = "Invalid array length";
        const error = runtime.makeError(ERROR_KIND_RANGE, bytesOfText(in message));
        runtime.raise(error);
        return undefinedValue();
      }
      return cellValue(runtime.heap.allocateArray(u32(number)));
    }
  }
  const array = runtime.heap.allocateArray(argc);
  let index: u32 = 0;
  while (index < argc) {
    const element = runtime.argument(argsBase, argc, index);
    runtime.heap.setSlot(array, index, element);
    index = index + 1;
  }
  return cellValue(array);
}

function bytesOfText(in text: String): Array<u8> {
  const copy = text.copyBytes(0, text.byteLength);
  let bytes = Array<u8>();
  let index: usize = 0;
  while (index < copy.byteLength) {
    bytes.push(copy.byteAt(index));
    index = index + 1;
  }
  return bytes;
}

function arrayIsArray(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const first = runtime.argument(argsBase, argc, 0);
  return booleanValue(isCell(first) && asCell(first) != 0 && runtime.heap.isArray(asCell(first)));
}

function arrayPush(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const pushText: String = "push";
  const array = thisArray(inout runtime, thisValue, in pushText);
  if (array == 0) return undefinedValue();
  let index: u32 = 0;
  while (index < argc) {
    const element = runtime.argument(argsBase, argc, index);
    const length = runtime.heap.arrayLength(array);
    runtime.heap.arraySet(array, length, element);
    index = index + 1;
  }
  return int32Value(i32(runtime.heap.arrayLength(array)));
}

function arrayPop(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const popText: String = "pop";
  const array = thisArray(inout runtime, thisValue, in popText);
  if (array == 0) return undefinedValue();
  const length = runtime.heap.arrayLength(array);
  if (length == 0) return undefinedValue();
  const last = runtime.heap.arrayGet(array, length - 1);
  runtime.heap.setArrayLength(array, length - 1);
  return last;
}

// join(separator): elements through ToString, holes and nullish empty.
function arrayJoin(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const joinText: String = "join";
  const array = thisArray(inout runtime, thisValue, in joinText);
  if (array == 0) return undefinedValue();
  let separator = Array<u8>();
  const given = runtime.argument(argsBase, argc, 0);
  if (isUndefined(given)) {
    separator.push(44);
  } else {
    const text = runtime.toStringValue(given);
    if (runtime.pendingThrow) return undefinedValue();
    separator = runtime.heap.stringBytes(asCell(text));
  }
  let joined = Array<u8>();
  const length = runtime.heap.arrayLength(array);
  let index: u32 = 0;
  while (index < length) {
    if (index > 0) {
      let s: usize = 0;
      while (s < separator.length) {
        joined.push(separator[s]);
        s = s + 1;
      }
    }
    const element = runtime.heap.arrayGet(array, index);
    if (!isUndefined(element) && !isNull(element)) {
      const text = runtime.toStringValue(element);
      if (runtime.pendingThrow) return undefinedValue();
      const handle = asCell(text);
      const count = runtime.heap.stringLength(handle);
      let i: usize = 0;
      while (i < count) {
        joined.push(runtime.heap.stringByte(handle, i));
        i = i + 1;
      }
    }
    index = index + 1;
  }
  return runtime.newString(move joined);
}

function arrayToString(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return arrayJoin(inout runtime, thisValue, argsBase, 0, callee);
}

function arrayIndexOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const indexOfText: String = "indexOf";
  const array = thisArray(inout runtime, thisValue, in indexOfText);
  if (array == 0) return undefinedValue();
  const target = runtime.argument(argsBase, argc, 0);
  const length = runtime.heap.arrayLength(array);
  let index: u32 = 0;
  while (index < length) {
    if (runtime.heap.arrayHasIndex(array, index)) {
      const element = runtime.heap.arrayGet(array, index);
      if (runtime.strictEquals(element, target)) return int32Value(i32(index));
    }
    index = index + 1;
  }
  return int32Value(-1);
}

function arraySlice(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const sliceText: String = "slice";
  const array = thisArray(inout runtime, thisValue, in sliceText);
  if (array == 0) return undefinedValue();
  const length = i32(runtime.heap.arrayLength(array));
  let start = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 0), length, 0);
  if (runtime.pendingThrow) return undefinedValue();
  const endGiven = runtime.argument(argsBase, argc, 1);
  let end = isUndefined(endGiven) ? length : relativeIndex(inout runtime, endGiven, length, length);
  if (runtime.pendingThrow) return undefinedValue();
  const result = runtime.heap.allocateArray(0);
  while (start < end) {
    if (runtime.heap.arrayHasIndex(array, u32(start))) {
      const element = runtime.heap.arrayGet(array, u32(start));
      const count = runtime.heap.arrayLength(result);
      runtime.heap.arraySet(result, count, element);
    } else {
      const count = runtime.heap.arrayLength(result);
      runtime.heap.setArrayLength(result, count + 1);
    }
    start = start + 1;
  }
  return cellValue(result);
}

// A relative index argument clamped into [0, length]; undefined is the default.
function relativeIndex(inout runtime: Runtime, given: Value, length: i32, fallback: i32): i32 {
  if (isUndefined(given)) return fallback;
  const number = runtime.toNumberValue(given);
  if (runtime.pendingThrow) return 0;
  if (number != number) return 0;
  let index: i32 = 0;
  if (number < -2147483648.0) {
    index = -2147483648;
  } else if (number > 2147483647.0) {
    index = 2147483647;
  } else {
    index = i32(truncateDouble(number));
  }
  if (index < 0) {
    const fromEnd = length + index;
    return fromEnd < 0 ? 0 : fromEnd;
  }
  return index > length ? length : index;
}

// forEach / map / filter / some / every share one walk; `mode` picks
// what happens with each callback result.
const WALK_FOR_EACH: u32 = 0;
const WALK_MAP: u32 = 1;
const WALK_FILTER: u32 = 2;
const WALK_SOME: u32 = 3;
const WALK_EVERY: u32 = 4;

function walkArray(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, mode: u32, in method: String): Value {
  const array = thisArray(inout runtime, thisValue, in method);
  if (array == 0) return undefinedValue();
  const callback = runtime.argument(argsBase, argc, 0);
  if (!runtime.isCallable(callback)) {
    const message: String = "callback is not a function";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const receiver = runtime.argument(argsBase, argc, 1);
  let result: u32 = 0;
  if (mode == WALK_MAP || mode == WALK_FILTER) {
    result = runtime.heap.allocateArray(0);
    runtime.pushTempRoot(cellValue(result));
  }
  runtime.pushTempRoot(thisValue);
  let outcome = undefinedValue();
  if (mode == WALK_SOME) outcome = booleanValue(false);
  if (mode == WALK_EVERY) outcome = booleanValue(true);
  let index: u32 = 0;
  let stop = false;
  while (!stop && index < runtime.heap.arrayLength(array)) {
    if (runtime.heap.arrayHasIndex(array, index)) {
      const element = runtime.heap.arrayGet(array, index);
      let args = Array<Value>();
      args.push(element);
      args.push(int32Value(i32(index)));
      args.push(thisValue);
      const produced = runtime.callValue(callback, receiver, move args);
      if (runtime.pendingThrow) {
        stop = true;
      } else if (mode == WALK_MAP) {
        runtime.heap.arraySet(result, index, produced);
      } else if (mode == WALK_FILTER) {
        if (runtime.toBooleanValue(produced)) {
          const count = runtime.heap.arrayLength(result);
          runtime.heap.arraySet(result, count, element);
        }
      } else if (mode == WALK_SOME) {
        if (runtime.toBooleanValue(produced)) {
          outcome = booleanValue(true);
          stop = true;
        }
      } else if (mode == WALK_EVERY) {
        if (!runtime.toBooleanValue(produced)) {
          outcome = booleanValue(false);
          stop = true;
        }
      }
    } else if (mode == WALK_MAP) {
      const count = runtime.heap.arrayLength(result);
      if (count <= index) runtime.heap.setArrayLength(result, index + 1);
    }
    index = index + 1;
  }
  runtime.popTempRoot();
  if (mode == WALK_MAP || mode == WALK_FILTER) {
    runtime.popTempRoot();
    if (runtime.pendingThrow) return undefinedValue();
    if (mode == WALK_MAP && runtime.heap.arrayLength(result) < runtime.heap.arrayLength(array)) {
      const total = runtime.heap.arrayLength(array);
      runtime.heap.setArrayLength(result, total);
    }
    return cellValue(result);
  }
  if (runtime.pendingThrow) return undefinedValue();
  return outcome;
}

function arrayForEach(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "forEach";
  return walkArray(inout runtime, thisValue, argsBase, argc, WALK_FOR_EACH, in text);
}
function arrayMap(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "map";
  return walkArray(inout runtime, thisValue, argsBase, argc, WALK_MAP, in text);
}
function arrayFilter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "filter";
  return walkArray(inout runtime, thisValue, argsBase, argc, WALK_FILTER, in text);
}
function arraySome(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "some";
  return walkArray(inout runtime, thisValue, argsBase, argc, WALK_SOME, in text);
}
function arrayEvery(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "every";
  return walkArray(inout runtime, thisValue, argsBase, argc, WALK_EVERY, in text);
}

export function installArray(inout runtime: Runtime): void {
  const arrayProto = runtime.arrayProto;
  const arrayText: String = "Array";
  const ctor = runtime.defineHostFunction(constructArray, undefinedValue(), 1, in arrayText);
  runtime.heap.setLink(ctor, arrayProto);
  const atomConstructor = runtime.atomConstructor;
  runtime.heap.objectSet(arrayProto, atomConstructor, cellValue(ctor));
  runtime.setGlobal("Array", cellValue(ctor));
  const isArrayText: String = "isArray";
  runtime.defineMethod(ctor, in isArrayText, arrayIsArray, 1);
  const pushText: String = "push";
  runtime.defineMethod(arrayProto, in pushText, arrayPush, 1);
  const popText: String = "pop";
  runtime.defineMethod(arrayProto, in popText, arrayPop, 0);
  const joinText: String = "join";
  runtime.defineMethod(arrayProto, in joinText, arrayJoin, 1);
  const toStringText: String = "toString";
  runtime.defineMethod(arrayProto, in toStringText, arrayToString, 0);
  const indexOfText: String = "indexOf";
  runtime.defineMethod(arrayProto, in indexOfText, arrayIndexOf, 1);
  const sliceText: String = "slice";
  runtime.defineMethod(arrayProto, in sliceText, arraySlice, 2);
  const forEachText: String = "forEach";
  runtime.defineMethod(arrayProto, in forEachText, arrayForEach, 1);
  const mapText: String = "map";
  runtime.defineMethod(arrayProto, in mapText, arrayMap, 1);
  const filterText: String = "filter";
  runtime.defineMethod(arrayProto, in filterText, arrayFilter, 1);
  const someText: String = "some";
  runtime.defineMethod(arrayProto, in someText, arraySome, 1);
  const everyText: String = "every";
  runtime.defineMethod(arrayProto, in everyText, arrayEvery, 1);
}
