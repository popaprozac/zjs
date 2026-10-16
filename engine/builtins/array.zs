// Array: the constructor, isArray, and Array.prototype.
//
// Every prototype method is generic, as the specification has it: the
// receiver goes through ToObject, its length through ToLength, and the
// elements through the property protocol, so an array-like works the
// same as an array. A real array's elements still read straight fromIndex
// the heap inside the property protocol. Values held in Z locals across
// a call into JavaScript are rooted, since a collection may run there.
import { Value, undefinedValue, nullValue, deletedValue, booleanValue, int32Value, doubleValue, cellValue, asCell, isCell, isUndefined, isNull, isDeleted, asInt32, isInt32, isNumber, isBoolean } from "../value.zs";
import { thread } from "std/thread";
import { PROP_METHOD, PROP_NONE, PROP_CONFIGURABLE, PROP_DEFAULT, PROP_ACCESSOR, bytesOf } from "../heap.zs";
import { Runtime, HostFunction, ERROR_KIND_RANGE, DescriptorInput, emptyDescriptorInput, toNumber, isIntegralDouble, truncateDouble, int32DigitsInto } from "../runtime.zs";
import { textBuilder, putByte, putString, finishText } from "./builder.zs";

const MAX_SAFE_LENGTH: f64 = 9007199254740991.0;
const MAX_ARRAY_LENGTH: f64 = 4294967295.0;

// --- Array-like access ---

// The receiver as an object; undefined with a TypeError pending otherwise.
function receiverObject(inout runtime: Runtime, thisValue: Value): Value {
  return runtime.toObjectValue(thisValue);
}

// LengthOfArrayLike, as a double up to 2^53 - 1; -1 with a throw pending.
function lengthOf(inout runtime: Runtime, object: Value): f64 {
  if (isCell(object) && runtime.heap.isArray(asCell(object))) return f64(runtime.heap.arrayLength(asCell(object)));
  const atomLength = runtime.atomLength;
  const raw = runtime.getProperty(object, cellValue(atomLength));
  if (runtime.pendingThrow) return -1.0;
  const number = runtime.toNumberValue(raw);
  if (runtime.pendingThrow) return -1.0;
  if (number != number || number <= 0.0) return 0.0;
  if (number >= MAX_SAFE_LENGTH) return MAX_SAFE_LENGTH;
  return truncateDouble(number);
}

// ToIntegerOrInfinity.
function toInteger(inout runtime: Runtime, value: Value): f64 {
  const number = runtime.toNumberValue(value);
  if (runtime.pendingThrow) return 0.0;
  if (number != number) return 0.0;
  return truncateDouble(number);
}

function indexKey(index: f64): Value {
  if (index < 2147483648.0) return int32Value(i32(index));
  return doubleValue(index);
}

// An integral result as a number value: an int32 when it fits (so -0
// from an index computation reads as +0), a double otherwise.
function integerValue(number: f64): Value {
  if (number >= -2147483648.0 && number <= 2147483647.0) return int32Value(i32(number));
  return doubleValue(number);
}

function getIndex(inout runtime: Runtime, object: Value, index: f64): Value {
  return runtime.getProperty(object, indexKey(index));
}

function hasIndex(inout runtime: Runtime, object: Value, index: f64): boolean {
  return runtime.hasProperty(object, indexKey(index));
}

// An array's own data element at `index`, read in place: what HasProperty
// then Get would find there, with nothing observable in between. Deleted
// for a hole, an accessor, or anything but an array, which take the
// general path.
function ownElement(in runtime: Runtime, object: Value, index: f64): Value {
  if (!isArrayValue(in runtime, object) || index >= 4294967295.0) return deletedValue();
  return runtime.heap.dataElement(asCell(object), u32(index));
}

// Set(O, P, V, true).
function setKey(inout runtime: Runtime, object: Value, key: Value, value: Value): boolean {
  const done = runtime.setProperty(object, key, value);
  if (runtime.pendingThrow) return false;
  if (!done) {
    const message: String = "Cannot assign to read only property";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return false;
  }
  return true;
}

function setIndex(inout runtime: Runtime, object: Value, index: f64, value: Value): boolean {
  return setKey(inout runtime, object, indexKey(index), value);
}

function setLength(inout runtime: Runtime, object: Value, length: f64): boolean {
  const atomLength = runtime.atomLength;
  return setKey(inout runtime, object, cellValue(atomLength), doubleValue(length));
}

// DeletePropertyOrThrow.
function deleteIndex(inout runtime: Runtime, object: Value, index: f64): boolean {
  const done = runtime.deleteProperty(object, indexKey(index));
  if (runtime.pendingThrow) return false;
  if (!done) {
    const message: String = "Cannot delete property";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return false;
  }
  return true;
}

// CreateDataPropertyOrThrow.
function createIndex(inout runtime: Runtime, object: Value, index: f64, value: Value): boolean {
  if (isCell(object) && runtime.heap.isArray(asCell(object)) && index < MAX_ARRAY_LENGTH && runtime.heap.flagsOf(asCell(object)) == 0) {
    runtime.heap.arraySet(asCell(object), u32(index), value);
    return true;
  }
  let desc = emptyDescriptorInput();
  desc.hasValue = true;
  desc.value = value;
  desc.hasWritable = true;
  desc.writable = true;
  desc.hasEnumerable = true;
  desc.enumerable = true;
  desc.hasConfigurable = true;
  desc.configurable = true;
  const done = runtime.defineOwnProperty(object, indexKey(index), desc);
  if (runtime.pendingThrow) return false;
  if (!done) {
    const message: String = "Cannot define property";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return false;
  }
  return true;
}

// A relative index argument resolved against `length`: negative counts
// fromIndex the end, the result clamped into [0, length].
function relativeIndex(inout runtime: Runtime, given: Value, length: f64, fallback: f64): f64 {
  if (isUndefined(given)) return fallback;
  const relative = toInteger(inout runtime, given);
  if (runtime.pendingThrow) return 0.0;
  if (relative < 0.0) {
    const fromEnd = length + relative;
    return fromEnd < 0.0 ? 0.0 : fromEnd;
  }
  return relative > length ? length : relative;
}

function isArrayValue(in runtime: Runtime, value: Value): boolean {
  return isCell(value) && asCell(value) != 0 && runtime.heap.isArray(asCell(value));
}

// ArrayCreate.
function arrayCreate(inout runtime: Runtime, length: f64): Value {
  if (length > MAX_ARRAY_LENGTH) {
    const message: String = "Invalid array length";
    const error = runtime.rangeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  return cellValue(runtime.heap.allocateArrayOfLength(u32(length)));
}

// ArraySpeciesCreate.
function arraySpeciesCreate(inout runtime: Runtime, original: Value, length: f64): Value {
  if (!isArrayValue(in runtime, original)) return arrayCreate(inout runtime, length);
  const atomConstructor = runtime.atomConstructor;
  let ctor = runtime.getProperty(original, cellValue(atomConstructor));
  if (runtime.pendingThrow) return undefinedValue();
  if (runtime.isObjectLike(ctor)) {
    const symbolSpecies = runtime.symbolSpecies;
    ctor = runtime.getProperty(ctor, symbolSpecies);
    if (runtime.pendingThrow) return undefinedValue();
    if (isNull(ctor)) ctor = undefinedValue();
  }
  if (isUndefined(ctor)) return arrayCreate(inout runtime, length);
  if (!runtime.isConstructorValue(ctor)) {
    const message: String = "species is not a constructor";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  let args = Array<Value>();
  args.push(doubleValue(length));
  return runtime.constructValue(ctor, move args, ctor);
}

function requireCallback(inout runtime: Runtime, callback: Value): boolean {
  if (runtime.isCallable(callback)) return true;
  const message: String = "callback is not a function";
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return false;
}

function callWith3(inout runtime: Runtime, callback: Value, receiver: Value, a: Value, b: Value, c: Value): Value {
  return runtime.callValue3(callback, receiver, a, b, c);
}

// --- The constructor and statics ---

// new Array(n) / Array(a, b, c)
function constructArray(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (argc == 1) {
    // One number is a length; it must be a non-negative integer.
    const first = runtime.argument(argsBase, argc, 0);
    if (isNumber(first)) {
      const number = toNumber(first);
      if (!isIntegralDouble(number) || number < 0.0 || number > MAX_ARRAY_LENGTH) {
        const message: String = "Invalid array length";
        const error = runtime.rangeError(in message);
        runtime.raise(error);
        return undefinedValue();
      }
      return cellValue(runtime.heap.allocateArrayOfLength(u32(number)));
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

function arrayIsArray(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const first = runtime.argument(argsBase, argc, 0);
  return booleanValue(isArrayValue(in runtime, first));
}

// --- Mutators ---

function arrayPush(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  // The direct path is for an ordinary array whose new elements no
  // prototype could intercept: push assigns, so an inherited element
  // setter would run (the general path, through Set, does that).
  if (isArrayValue(in runtime, thisValue) && runtime.heap.flagsOf(asCell(thisValue)) == 0 && !runtime.heap.indexKeysDefined && runtime.heap.linkOf(asCell(thisValue)) == 0) {
    const array = asCell(thisValue);
    let index: u32 = 0;
    while (index < argc) {
      const element = runtime.argument(argsBase, argc, index);
      const length = runtime.heap.arrayLength(array);
      runtime.heap.arraySet(array, length, element);
      index = index + 1;
    }
    return integerValue(f64(runtime.heap.arrayLength(array)));
  }
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  if (length + f64(argc) > MAX_SAFE_LENGTH) {
    runtime.popTempRoot();
    const message: String = "Pushing beyond the maximum length";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  let index: u32 = 0;
  while (index < argc) {
    const element = runtime.argument(argsBase, argc, index);
    if (!setIndex(inout runtime, object, length + f64(index), element)) { runtime.popTempRoot(); return undefinedValue(); }
    index = index + 1;
  }
  const total = length + f64(argc);
  const ok = setLength(inout runtime, object, total);
  runtime.popTempRoot();
  if (!ok) return undefinedValue();
  return integerValue(total);
}

function arrayPop(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (isArrayValue(in runtime, thisValue) && runtime.heap.flagsOf(asCell(thisValue)) == 0) {
    const array = asCell(thisValue);
    const count = runtime.heap.arrayLength(array);
    if (count == 0) return undefinedValue();
    const last = getIndex(inout runtime, thisValue, f64(count - 1));
    if (runtime.pendingThrow) return undefinedValue();
    runtime.heap.setArrayLength(array, count - 1);
    return last;
  }
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  if (length == 0.0) {
    const ok = setLength(inout runtime, object, 0.0);
    runtime.popTempRoot();
    return undefinedValue();
  }
  const last = getIndex(inout runtime, object, length - 1.0);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  runtime.pushTempRoot(last);
  let ok = deleteIndex(inout runtime, object, length - 1.0);
  if (ok) ok = setLength(inout runtime, object, length - 1.0);
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (!ok) return undefinedValue();
  return last;
}

function arrayShift(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  if (length == 0.0) {
    const ok = setLength(inout runtime, object, 0.0);
    runtime.popTempRoot();
    return undefinedValue();
  }
  const first = getIndex(inout runtime, object, 0.0);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  runtime.pushTempRoot(first);
  let ok = true;
  let k = 1.0;
  while (ok && k < length) {
    const present = hasIndex(inout runtime, object, k);
    if (runtime.pendingThrow) { ok = false; break; }
    if (present) {
      const value = getIndex(inout runtime, object, k);
      if (runtime.pendingThrow) { ok = false; break; }
      ok = setIndex(inout runtime, object, k - 1.0, value);
    } else {
      ok = deleteIndex(inout runtime, object, k - 1.0);
    }
    k = k + 1.0;
  }
  if (ok) ok = deleteIndex(inout runtime, object, length - 1.0);
  if (ok) ok = setLength(inout runtime, object, length - 1.0);
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (!ok) return undefinedValue();
  return first;
}

function arrayUnshift(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  const count = f64(argc);
  let ok = true;
  if (argc > 0) {
    if (length + count > MAX_SAFE_LENGTH) {
      runtime.popTempRoot();
      const message: String = "Unshifting beyond the maximum length";
      const error = runtime.typeError(in message);
      runtime.raise(error);
      return undefinedValue();
    }
    let k = length;
    while (ok && k > 0.0) {
      const fromIndex = k - 1.0;
      const present = hasIndex(inout runtime, object, fromIndex);
      if (runtime.pendingThrow) { ok = false; break; }
      if (present) {
        const value = getIndex(inout runtime, object, fromIndex);
        if (runtime.pendingThrow) { ok = false; break; }
        ok = setIndex(inout runtime, object, fromIndex + count, value);
      } else {
        ok = deleteIndex(inout runtime, object, fromIndex + count);
      }
      k = k - 1.0;
    }
    let j: u32 = 0;
    while (ok && j < argc) {
      const element = runtime.argument(argsBase, argc, j);
      ok = setIndex(inout runtime, object, f64(j), element);
      j = j + 1;
    }
  }
  if (ok) ok = setLength(inout runtime, object, length + count);
  runtime.popTempRoot();
  if (!ok) return undefinedValue();
  return integerValue(length + count);
}

function arrayReverse(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  const middle = truncateDouble(length / 2.0);
  let lower = 0.0;
  let ok = true;
  while (ok && lower != middle) {
    const upper = length - lower - 1.0;
    const lowerExists = hasIndex(inout runtime, object, lower);
    if (runtime.pendingThrow) { ok = false; break; }
    let lowerValue = undefinedValue();
    if (lowerExists) {
      lowerValue = getIndex(inout runtime, object, lower);
      if (runtime.pendingThrow) { ok = false; break; }
    }
    runtime.pushTempRoot(lowerValue);
    const upperExists = hasIndex(inout runtime, object, upper);
    if (runtime.pendingThrow) { runtime.popTempRoot(); ok = false; break; }
    let upperValue = undefinedValue();
    if (upperExists) {
      upperValue = getIndex(inout runtime, object, upper);
      if (runtime.pendingThrow) { runtime.popTempRoot(); ok = false; break; }
    }
    if (lowerExists && upperExists) {
      ok = setIndex(inout runtime, object, lower, upperValue);
      if (ok) ok = setIndex(inout runtime, object, upper, lowerValue);
    } else if (upperExists) {
      ok = setIndex(inout runtime, object, lower, upperValue);
      if (ok) ok = deleteIndex(inout runtime, object, upper);
    } else if (lowerExists) {
      ok = deleteIndex(inout runtime, object, lower);
      if (ok) ok = setIndex(inout runtime, object, upper, lowerValue);
    }
    runtime.popTempRoot();
    lower = lower + 1.0;
  }
  runtime.popTempRoot();
  if (!ok) return undefinedValue();
  return object;
}

function arrayFill(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  const value = runtime.argument(argsBase, argc, 0);
  let k = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 1), length, 0.0);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  const end = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 2), length, length);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  let ok = true;
  while (ok && k < end) {
    ok = setIndex(inout runtime, object, k, value);
    k = k + 1.0;
  }
  runtime.popTempRoot();
  if (!ok) return undefinedValue();
  return object;
}

function arrayCopyWithin(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  let to = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 0), length, 0.0);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  let fromIndex = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 1), length, 0.0);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  const end = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 2), length, length);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  let count = end - fromIndex;
  if (length - to < count) count = length - to;
  let direction = 1.0;
  if (fromIndex < to && to < fromIndex + count) {
    direction = -1.0;
    fromIndex = fromIndex + count - 1.0;
    to = to + count - 1.0;
  }
  let ok = true;
  while (ok && count > 0.0) {
    const present = hasIndex(inout runtime, object, fromIndex);
    if (runtime.pendingThrow) { ok = false; break; }
    if (present) {
      const value = getIndex(inout runtime, object, fromIndex);
      if (runtime.pendingThrow) { ok = false; break; }
      ok = setIndex(inout runtime, object, to, value);
    } else {
      ok = deleteIndex(inout runtime, object, to);
    }
    fromIndex = fromIndex + direction;
    to = to + direction;
    count = count - 1.0;
  }
  runtime.popTempRoot();
  if (!ok) return undefinedValue();
  return object;
}

// --- Searches ---

function arrayIndexOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length <= 0.0) { runtime.popTempRoot(); return length < 0.0 ? undefinedValue() : int32Value(-1); }
  let n = 0.0;
  if (argc > 1) {
    n = toInteger(inout runtime, runtime.argument(argsBase, argc, 1));
    if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  }
  if (n >= length) { runtime.popTempRoot(); return int32Value(-1); }
  let k = n;
  if (n < 0.0) {
    k = length + n;
    if (k < 0.0) k = 0.0;
  }
  const target = runtime.argument(argsBase, argc, 0);
  let found = -1.0;
  while (found < 0.0 && k < length) {
    const present = hasIndex(inout runtime, object, k);
    if (runtime.pendingThrow) break;
    if (present) {
      const element = getIndex(inout runtime, object, k);
      if (runtime.pendingThrow) break;
      if (runtime.strictEquals(element, target)) found = k;
    }
    k = k + 1.0;
  }
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  return integerValue(found);
}

function arrayLastIndexOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length <= 0.0) { runtime.popTempRoot(); return length < 0.0 ? undefinedValue() : int32Value(-1); }
  let n = length - 1.0;
  if (argc > 1) {
    n = toInteger(inout runtime, runtime.argument(argsBase, argc, 1));
    if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  }
  let k = 0.0;
  if (n >= 0.0) {
    k = n < length - 1.0 ? n : length - 1.0;
  } else {
    k = length + n;
  }
  const target = runtime.argument(argsBase, argc, 0);
  let found = -1.0;
  while (found < 0.0 && k >= 0.0) {
    const present = hasIndex(inout runtime, object, k);
    if (runtime.pendingThrow) break;
    if (present) {
      const element = getIndex(inout runtime, object, k);
      if (runtime.pendingThrow) break;
      if (runtime.strictEquals(element, target)) found = k;
    }
    k = k - 1.0;
  }
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  return integerValue(found);
}

function arrayIncludes(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length <= 0.0) { runtime.popTempRoot(); return length < 0.0 ? undefinedValue() : booleanValue(false); }
  let n = 0.0;
  if (argc > 1) {
    n = toInteger(inout runtime, runtime.argument(argsBase, argc, 1));
    if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  }
  let k = n;
  if (n < 0.0) {
    k = length + n;
    if (k < 0.0) k = 0.0;
  }
  const target = runtime.argument(argsBase, argc, 0);
  let found = false;
  while (!found && k < length) {
    const element = getIndex(inout runtime, object, k);
    if (runtime.pendingThrow) break;
    if (runtime.sameValueZero(element, target)) found = true;
    k = k + 1.0;
  }
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  return booleanValue(found);
}

function arrayAt(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  const relative = toInteger(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  const k = relative >= 0.0 ? relative : length + relative;
  if (k < 0.0 || k >= length) { runtime.popTempRoot(); return undefinedValue(); }
  const element = getIndex(inout runtime, object, k);
  runtime.popTempRoot();
  return element;
}

// find / findIndex / findLast / findLastIndex: every index is visited,
// holes as undefined.
const FIND_VALUE: u32 = 0;
const FIND_INDEX: u32 = 1;

function findWalk(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, want: u32, fromEnd: boolean): Value {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  const callback = runtime.argument(argsBase, argc, 0);
  if (!requireCallback(inout runtime, callback)) { runtime.popTempRoot(); return undefinedValue(); }
  const receiver = runtime.argument(argsBase, argc, 1);
  const leaf = runtime.leafCodeOf(callback);
  let k = fromEnd ? length - 1.0 : 0.0;
  let outcome = want == FIND_INDEX ? int32Value(-1) : undefinedValue();
  let done = false;
  while (!done && (fromEnd ? k >= 0.0 : k < length)) {
    let element = ownElement(in runtime, object, k);
    if (isDeleted(element)) {
      element = getIndex(inout runtime, object, k);
      if (runtime.pendingThrow) break;
    }
    runtime.pushTempRoot(element);
    let verdict = deletedValue();
    if (leaf >= 0) verdict = runtime.callLeaf(usize(leaf), 3, element, integerValue(k), object, undefinedValue());
    if (isDeleted(verdict)) verdict = callWith3(inout runtime, callback, receiver, element, integerValue(k), object);
    runtime.popTempRoot();
    if (runtime.pendingThrow) break;
    if (runtime.toBooleanValue(verdict)) {
      outcome = want == FIND_INDEX ? integerValue(k) : element;
      done = true;
    }
    k = fromEnd ? k - 1.0 : k + 1.0;
  }
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  return outcome;
}

function arrayFind(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return findWalk(inout runtime, thisValue, argsBase, argc, FIND_VALUE, false);
}
function arrayFindIndex(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return findWalk(inout runtime, thisValue, argsBase, argc, FIND_INDEX, false);
}
function arrayFindLast(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return findWalk(inout runtime, thisValue, argsBase, argc, FIND_VALUE, true);
}
function arrayFindLastIndex(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return findWalk(inout runtime, thisValue, argsBase, argc, FIND_INDEX, true);
}

// --- Callback walks over present elements ---

const WALK_FOR_EACH: u32 = 0;
const WALK_MAP: u32 = 1;
const WALK_FILTER: u32 = 2;
const WALK_SOME: u32 = 3;
const WALK_EVERY: u32 = 4;

function walkArray(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, mode: u32): Value {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  const callback = runtime.argument(argsBase, argc, 0);
  if (!requireCallback(inout runtime, callback)) { runtime.popTempRoot(); return undefinedValue(); }
  const receiver = runtime.argument(argsBase, argc, 1);
  const leaf = runtime.leafCodeOf(callback);
  let result = undefinedValue();
  if (mode == WALK_MAP) {
    result = arraySpeciesCreate(inout runtime, object, length);
  } else if (mode == WALK_FILTER) {
    result = arraySpeciesCreate(inout runtime, object, 0.0);
  }
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  runtime.pushTempRoot(result);
  let outcome = undefinedValue();
  if (mode == WALK_SOME) outcome = booleanValue(false);
  if (mode == WALK_EVERY) outcome = booleanValue(true);
  let to = 0.0;
  let k = 0.0;
  let stop = false;
  // An array's elements are read in place (a hole or an accessor takes
  // the general path); whether it is one cannot change during the walk.
  const array: u32 = isArrayValue(in runtime, object) && length <= 4294967295.0 ? asCell(object) : u32(0);
  while (!stop && k < length) {
    let element = array != 0 ? runtime.heap.dataElement(array, u32(k)) : deletedValue();
    let present = !isDeleted(element);
    const inPlace = present;
    if (!present) {
      present = hasIndex(inout runtime, object, k);
      if (runtime.pendingThrow) break;
      if (present) {
        element = getIndex(inout runtime, object, k);
        if (runtime.pendingThrow) break;
      }
    }
    if (present) {
      let produced = deletedValue();
      if (leaf >= 0) produced = runtime.callLeaf(usize(leaf), 3, element, integerValue(k), object, undefinedValue());
      // An element read in place stays reachable through the rooted
      // array, and a leaf allocates nothing: only a full call, or an
      // element a getter made, needs a root of its own.
      const rooted = isDeleted(produced) || !inPlace;
      if (rooted) runtime.pushTempRoot(element);
      if (isDeleted(produced)) produced = callWith3(inout runtime, callback, receiver, element, integerValue(k), object);
      if (runtime.pendingThrow) {
        if (rooted) runtime.popTempRoot();
        break;
      }
      if (mode == WALK_MAP) {
        if (!createIndex(inout runtime, result, k, produced)) stop = true;
      } else if (mode == WALK_FILTER) {
        if (runtime.toBooleanValue(produced)) {
          if (!createIndex(inout runtime, result, to, element)) stop = true;
          to = to + 1.0;
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
      if (rooted) runtime.popTempRoot();
    }
    k = k + 1.0;
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  if (mode == WALK_MAP || mode == WALK_FILTER) return result;
  return outcome;
}

function arrayForEach(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return walkArray(inout runtime, thisValue, argsBase, argc, WALK_FOR_EACH);
}
function arrayMap(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return walkArray(inout runtime, thisValue, argsBase, argc, WALK_MAP);
}
function arrayFilter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return walkArray(inout runtime, thisValue, argsBase, argc, WALK_FILTER);
}
function arraySome(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return walkArray(inout runtime, thisValue, argsBase, argc, WALK_SOME);
}
function arrayEvery(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return walkArray(inout runtime, thisValue, argsBase, argc, WALK_EVERY);
}

function reduceWalk(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, fromEnd: boolean): Value {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  const callback = runtime.argument(argsBase, argc, 0);
  if (!requireCallback(inout runtime, callback)) { runtime.popTempRoot(); return undefinedValue(); }
  const leaf = runtime.leafCodeOf(callback);
  let k = fromEnd ? length - 1.0 : 0.0;
  let accumulator = undefinedValue();
  let started = false;
  if (argc > 1) {
    accumulator = runtime.argument(argsBase, argc, 1);
    started = true;
  } else {
    while (!started && (fromEnd ? k >= 0.0 : k < length)) {
      const present = hasIndex(inout runtime, object, k);
      if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
      if (present) {
        accumulator = getIndex(inout runtime, object, k);
        if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
        started = true;
      }
      k = fromEnd ? k - 1.0 : k + 1.0;
    }
    if (!started) {
      runtime.popTempRoot();
      const message: String = "Reduce of empty array with no initial value";
      const error = runtime.typeError(in message);
      runtime.raise(error);
      return undefinedValue();
    }
  }
  runtime.pushTempRoot(accumulator);
  while (fromEnd ? k >= 0.0 : k < length) {
    let element = ownElement(in runtime, object, k);
    let present = !isDeleted(element);
    if (!present) {
      present = hasIndex(inout runtime, object, k);
      if (runtime.pendingThrow) break;
      if (present) {
        element = getIndex(inout runtime, object, k);
        if (runtime.pendingThrow) break;
      }
    }
    if (present) {
      let next = deletedValue();
      if (leaf >= 0) next = runtime.callLeaf(usize(leaf), 4, accumulator, element, integerValue(k), object);
      if (isDeleted(next)) next = runtime.callValue4(callback, undefinedValue(), accumulator, element, integerValue(k), object);
      accumulator = next;
      if (runtime.pendingThrow) break;
      runtime.popTempRoot();
      runtime.pushTempRoot(accumulator);
    }
    k = fromEnd ? k - 1.0 : k + 1.0;
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  return accumulator;
}

function arrayReduce(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return reduceWalk(inout runtime, thisValue, argsBase, argc, false);
}
function arrayReduceRight(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return reduceWalk(inout runtime, thisValue, argsBase, argc, true);
}

// --- Slicing and joining ---

function arraySlice(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  let k = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 0), length, 0.0);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  const end = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 1), length, length);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  const count = end > k ? end - k : 0.0;
  const result = arraySpeciesCreate(inout runtime, object, count);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  runtime.pushTempRoot(result);
  let n = 0.0;
  let ok = true;
  while (ok && k < end) {
    const present = hasIndex(inout runtime, object, k);
    if (runtime.pendingThrow) { ok = false; break; }
    if (present) {
      const element = getIndex(inout runtime, object, k);
      if (runtime.pendingThrow) { ok = false; break; }
      ok = createIndex(inout runtime, result, n, element);
    }
    k = k + 1.0;
    n = n + 1.0;
  }
  if (ok) ok = setLength(inout runtime, result, n);
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (!ok) return undefinedValue();
  return result;
}

function arraySplice(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  const start = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 0), length, 0.0);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  let insertCount = 0.0;
  let deleteCount = 0.0;
  if (argc == 1) {
    deleteCount = length - start;
  } else if (argc > 1) {
    insertCount = f64(argc - 2);
    const requested = toInteger(inout runtime, runtime.argument(argsBase, argc, 1));
    if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
    deleteCount = requested < 0.0 ? 0.0 : requested;
    if (deleteCount > length - start) deleteCount = length - start;
  }
  if (length + insertCount - deleteCount > MAX_SAFE_LENGTH) {
    runtime.popTempRoot();
    const message: String = "Splicing beyond the maximum length";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const removed = arraySpeciesCreate(inout runtime, object, deleteCount);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  runtime.pushTempRoot(removed);
  let ok = true;
  let k = 0.0;
  while (ok && k < deleteCount) {
    const fromIndex = start + k;
    const present = hasIndex(inout runtime, object, fromIndex);
    if (runtime.pendingThrow) { ok = false; break; }
    if (present) {
      const element = getIndex(inout runtime, object, fromIndex);
      if (runtime.pendingThrow) { ok = false; break; }
      ok = createIndex(inout runtime, removed, k, element);
    }
    k = k + 1.0;
  }
  if (ok) ok = setLength(inout runtime, removed, deleteCount);
  if (ok && insertCount < deleteCount) {
    k = start;
    while (ok && k < length - deleteCount) {
      const fromIndex = k + deleteCount;
      const to = k + insertCount;
      const present = hasIndex(inout runtime, object, fromIndex);
      if (runtime.pendingThrow) { ok = false; break; }
      if (present) {
        const element = getIndex(inout runtime, object, fromIndex);
        if (runtime.pendingThrow) { ok = false; break; }
        ok = setIndex(inout runtime, object, to, element);
      } else {
        ok = deleteIndex(inout runtime, object, to);
      }
      k = k + 1.0;
    }
    k = length;
    while (ok && k > length - deleteCount + insertCount) {
      ok = deleteIndex(inout runtime, object, k - 1.0);
      k = k - 1.0;
    }
  } else if (ok && insertCount > deleteCount) {
    k = length - deleteCount;
    while (ok && k > start) {
      const fromIndex = k + deleteCount - 1.0;
      const to = k + insertCount - 1.0;
      const present = hasIndex(inout runtime, object, fromIndex);
      if (runtime.pendingThrow) { ok = false; break; }
      if (present) {
        const element = getIndex(inout runtime, object, fromIndex);
        if (runtime.pendingThrow) { ok = false; break; }
        ok = setIndex(inout runtime, object, to, element);
      } else {
        ok = deleteIndex(inout runtime, object, to);
      }
      k = k - 1.0;
    }
  }
  let i: u32 = 2;
  while (ok && i < argc) {
    const element = runtime.argument(argsBase, argc, i);
    ok = setIndex(inout runtime, object, start + f64(i - 2), element);
    i = i + 1;
  }
  if (ok) ok = setLength(inout runtime, object, length - deleteCount + insertCount);
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (!ok) return undefinedValue();
  return removed;
}

// IsConcatSpreadable.
function isConcatSpreadable(inout runtime: Runtime, value: Value): boolean {
  if (!runtime.isObjectLike(value)) return false;
  const symbolIsConcatSpreadable = runtime.symbolIsConcatSpreadable;
  const spreadable = runtime.getProperty(value, symbolIsConcatSpreadable);
  if (runtime.pendingThrow) return false;
  if (!isUndefined(spreadable)) return runtime.toBooleanValue(spreadable);
  return isArrayValue(in runtime, value);
}

function arrayConcat(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const result = arraySpeciesCreate(inout runtime, object, 0.0);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  runtime.pushTempRoot(result);
  let n = 0.0;
  let ok = true;
  let i: i32 = -1;
  while (ok && i < i32(argc)) {
    const item: Value = i < 0 ? object : runtime.argument(argsBase, argc, u32(i));
    const spread = isConcatSpreadable(inout runtime, item);
    if (runtime.pendingThrow) { ok = false; break; }
    if (spread) {
      const length = lengthOf(inout runtime, item);
      if (length < 0.0) { ok = false; break; }
      if (n + length > MAX_SAFE_LENGTH) {
        const message: String = "Concatenation beyond the maximum length";
        const error = runtime.typeError(in message);
        runtime.raise(error);
        ok = false;
        break;
      }
      let k = 0.0;
      while (ok && k < length) {
        const present = hasIndex(inout runtime, item, k);
        if (runtime.pendingThrow) { ok = false; break; }
        if (present) {
          const element = getIndex(inout runtime, item, k);
          if (runtime.pendingThrow) { ok = false; break; }
          ok = createIndex(inout runtime, result, n, element);
        }
        n = n + 1.0;
        k = k + 1.0;
      }
    } else {
      if (n >= MAX_SAFE_LENGTH) {
        const message: String = "Concatenation beyond the maximum length";
        const error = runtime.typeError(in message);
        runtime.raise(error);
        ok = false;
        break;
      }
      ok = createIndex(inout runtime, result, n, item);
      n = n + 1.0;
    }
    i = i + 1;
  }
  if (ok) ok = setLength(inout runtime, result, n);
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (!ok) return undefinedValue();
  return result;
}

// FlattenIntoArray; the count of elements written, or -1 on a throw.
function flattenInto(inout runtime: Runtime, target: Value, source: Value, sourceLength: f64, start: f64, depth: f64, mapper: Value, receiver: Value): f64 {
  let targetIndex = start;
  let sourceIndex = 0.0;
  while (sourceIndex < sourceLength) {
    const present = hasIndex(inout runtime, source, sourceIndex);
    if (runtime.pendingThrow) return -1.0;
    if (present) {
      let element = getIndex(inout runtime, source, sourceIndex);
      if (runtime.pendingThrow) return -1.0;
      if (!isUndefined(mapper)) {
        runtime.pushTempRoot(element);
        element = callWith3(inout runtime, mapper, receiver, element, doubleValue(sourceIndex), source);
        runtime.popTempRoot();
        if (runtime.pendingThrow) return -1.0;
      }
      runtime.pushTempRoot(element);
      let flattenable = false;
      if (depth > 0.0) {
        flattenable = isArrayValue(in runtime, element);
      }
      if (flattenable) {
        const elementLength = lengthOf(inout runtime, element);
        if (elementLength < 0.0) { runtime.popTempRoot(); return -1.0; }
        targetIndex = flattenInto(inout runtime, target, element, elementLength, targetIndex, depth - 1.0, undefinedValue(), undefinedValue());
        if (targetIndex < 0.0) { runtime.popTempRoot(); return -1.0; }
      } else {
        if (targetIndex >= MAX_SAFE_LENGTH) {
          runtime.popTempRoot();
          const message: String = "Flattening beyond the maximum length";
          const error = runtime.typeError(in message);
          runtime.raise(error);
          return -1.0;
        }
        if (!createIndex(inout runtime, target, targetIndex, element)) { runtime.popTempRoot(); return -1.0; }
        targetIndex = targetIndex + 1.0;
      }
      runtime.popTempRoot();
    }
    sourceIndex = sourceIndex + 1.0;
  }
  return targetIndex;
}

function arrayFlat(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  let depth = 1.0;
  const given = runtime.argument(argsBase, argc, 0);
  if (!isUndefined(given)) {
    depth = toInteger(inout runtime, given);
    if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
    if (depth < 0.0) depth = 0.0;
  }
  const result = arraySpeciesCreate(inout runtime, object, 0.0);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  runtime.pushTempRoot(result);
  const written = flattenInto(inout runtime, result, object, length, 0.0, depth, undefinedValue(), undefinedValue());
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (written < 0.0) return undefinedValue();
  return result;
}

function arrayFlatMap(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  const mapper = runtime.argument(argsBase, argc, 0);
  if (!requireCallback(inout runtime, mapper)) { runtime.popTempRoot(); return undefinedValue(); }
  const receiver = runtime.argument(argsBase, argc, 1);
  const result = arraySpeciesCreate(inout runtime, object, 0.0);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  runtime.pushTempRoot(result);
  const written = flattenInto(inout runtime, result, object, length, 0.0, 1.0, mapper, receiver);
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (written < 0.0) return undefinedValue();
  return result;
}

// join(separator): elements through ToString, holes and nullish empty.
function joinWith(inout runtime: Runtime, thisValue: Value, separatorGiven: Value, locale: boolean): Value {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  // The separator: a comma, or its string, rooted while elements convert.
  let separator: u32 = 0;
  if (!isUndefined(separatorGiven)) {
    const text = runtime.toStringValue(separatorGiven);
    if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
    separator = asCell(text);
    runtime.pushTempRoot(text);
  }
  if (!locale && isArrayValue(in runtime, object) && (separator == 0 || !runtime.heap.isWideString(separator))) {
    const plain = joinPlain(inout runtime, asCell(object), length, separator);
    if (!isDeleted(plain)) {
      if (separator != 0) runtime.popTempRoot();
      runtime.popTempRoot();
      return plain;
    }
  }
  let joined = textBuilder(64);
  let k = 0.0;
  while (k < length) {
    if (k > 0.0) {
      if (separator == 0) {
        putByte(inout joined, 44);
      } else {
        putString(in runtime, inout joined, separator);
      }
    }
    // An array's element read in place; a hole, an accessor, or an
    // array-like goes through Get.
    let element = ownElement(in runtime, object, k);
    if (isDeleted(element)) {
      element = getIndex(inout runtime, object, k);
      if (runtime.pendingThrow) break;
    }
    if (!isUndefined(element) && !isNull(element)) {
      let text = undefinedValue();
      if (locale) {
        runtime.pushTempRoot(element);
        const toLocaleText: String = "toLocaleString";
        const key = runtime.internText(in toLocaleText);
        const method = runtime.getProperty(element, key);
        if (runtime.pendingThrow) { runtime.popTempRoot(); break; }
        if (!runtime.isCallable(method)) {
          runtime.popTempRoot();
          const message: String = "toLocaleString is not a function";
          const error = runtime.typeError(in message);
          runtime.raise(error);
          break;
        }
        const produced = runtime.callValue0(method, element);
        runtime.popTempRoot();
        if (runtime.pendingThrow) break;
        text = runtime.toStringValue(produced);
      } else {
        text = runtime.toStringValue(element);
      }
      if (runtime.pendingThrow) break;
      putString(in runtime, inout joined, asCell(text));
    }
    k = k + 1.0;
  }
  if (separator != 0) runtime.popTempRoot();
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  return finishText(inout runtime, inout joined);
}

// An array's join when every element is a narrow string, a number, a
// boolean, undefined, or null (none of which runs anything to become a
// string) and the separator is narrow: the bytes gathered in a local
// array, one string made from them. The deleted marker, with nothing
// having run, when an element is anything else (then the general path).
function joinPlain(inout runtime: Runtime, array: u32, length: f64, separator: u32): Value {
  let bytes = Array<u8>.withCapacity(64);
  let k: u32 = 0;
  const count = u32(length);
  while (k < count) {
    if (k > 0) {
      if (separator == 0) {
        bytes.push(44);
      } else {
        bytes = runtime.heap.appendNarrowTo(separator, move bytes);
      }
    }
    const element = runtime.heap.dataElement(array, k);
    if (isDeleted(element)) return deletedValue();
    if (isInt32(element)) {
      let digits: u8[11] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
      const n = int32DigitsInto(inout digits, asInt32(element));
      let d: usize = 0;
      while (d < n) {
        bytes.push(digits[d]);
        d = d + 1;
      }
    } else if (runtime.isStringValue(element)) {
      if (runtime.heap.isWideString(asCell(element))) return deletedValue();
      bytes = runtime.heap.appendNarrowTo(asCell(element), move bytes);
    } else if (isNumber(element) || isBoolean(element)) {
      const text = runtime.toStringValue(element);
      bytes = runtime.heap.appendNarrowTo(asCell(text), move bytes);
    } else if (!isUndefined(element) && !isNull(element)) {
      return deletedValue();
    }
    k = k + 1;
  }
  return runtime.newStringLatin1(move bytes);
}

function arrayJoin(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return joinWith(inout runtime, thisValue, runtime.argument(argsBase, argc, 0), false);
}

function arrayToLocaleString(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return joinWith(inout runtime, thisValue, undefinedValue(), true);
}

// toString: the receiver's join if callable, else Object.prototype.toString.
function arrayToString(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const joinText: String = "join";
  const joinKey = runtime.internText(in joinText);
  const method = runtime.getProperty(object, joinKey);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  let result = undefinedValue();
  if (runtime.isCallable(method)) {
    result = runtime.callValue0(method, object);
  } else {
    const objectProto = runtime.objectProto;
    const toStringText: String = "toString";
    const toStringKey = runtime.internText(in toStringText);
    const fallback = runtime.getProperty(cellValue(objectProto), toStringKey);
    if (!runtime.pendingThrow) result = runtime.callValue0(fallback, object);
  }
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  return result;
}

// --- Sorting ---

// SortCompare: undefined last, then the comparator, then byte order of
// the string forms. NaN fromIndex a comparator counts as 0.
function sortCompare(inout runtime: Runtime, comparator: Value, leaf: i64, x: Value, y: Value): f64 {
  if (isUndefined(x) && isUndefined(y)) return 0.0;
  if (isUndefined(x)) return 1.0;
  if (isUndefined(y)) return -1.0;
  if (!isUndefined(comparator)) {
    let verdict = deletedValue();
    if (leaf >= 0) verdict = runtime.callLeaf(usize(leaf), 2, x, y, undefinedValue(), undefinedValue());
    if (isDeleted(verdict)) verdict = runtime.callValue2(comparator, undefinedValue(), x, y);
    if (runtime.pendingThrow) return 0.0;
    let number = 0.0;
    if (isNumber(verdict)) {
      number = toNumber(verdict);
    } else {
      number = runtime.toNumberValue(verdict);
      if (runtime.pendingThrow) return 0.0;
    }
    if (number != number) return 0.0;
    return number;
  }
  const xs = runtime.toStringValue(x);
  if (runtime.pendingThrow) return 0.0;
  runtime.pushTempRoot(xs);
  const ys = runtime.toStringValue(y);
  runtime.popTempRoot();
  if (runtime.pendingThrow) return 0.0;
  const xb = runtime.heap.stringUnits(asCell(xs));
  const yb = runtime.heap.stringUnits(asCell(ys));
  let i: usize = 0;
  while (i < xb.length && i < yb.length) {
    if (xb[i] != yb[i]) return xb[i] < yb[i] ? -1.0 : 1.0;
    i = i + 1;
  }
  if (xb.length == yb.length) return 0.0;
  return xb.length < yb.length ? -1.0 : 1.0;
}

// A stable merge sort of target[low, high) in place, `source` holding the
// same elements in the same order on entry: each half is sorted into
// `source` (with `target` as its scratch) and the halves are merged back
// into `target`, so no level copies back. Halves of four or more that are
// already in order are joined after one comparison, so sorted runs cost
// little. Stops early on a throw.
function sortInto(inout runtime: Runtime, target: u32, source: u32, low: u32, high: u32, comparator: Value, leaf: i64): void {
  if (high - low < 2) return;
  const middle = low + (high - low) / 2;
  sortInto(inout runtime, source, target, low, middle, comparator, leaf);
  if (runtime.pendingThrow) return;
  sortInto(inout runtime, source, target, middle, high, comparator, leaf);
  if (runtime.pendingThrow) return;
  if (high - low >= 8) {
    const lastLeft = runtime.heap.slot(source, middle - 1);
    const firstRight = runtime.heap.slot(source, middle);
    const order = sortCompare(inout runtime, comparator, leaf, firstRight, lastLeft);
    if (runtime.pendingThrow) return;
    if (order >= 0.0) {
      // Right's first is not less than left's last: left then right.
      copySlots(inout runtime, source, target, low, high);
      return;
    }
  }
  let left = low;
  let right = middle;
  let write = low;
  while (left < middle && right < high) {
    const a = runtime.heap.slot(source, left);
    const b = runtime.heap.slot(source, right);
    const order = sortCompare(inout runtime, comparator, leaf, b, a);
    if (runtime.pendingThrow) return;
    if (order < 0.0) {
      runtime.heap.setSlot(target, write, b);
      right = right + 1;
    } else {
      runtime.heap.setSlot(target, write, a);
      left = left + 1;
    }
    write = write + 1;
  }
  while (left < middle) {
    const a = runtime.heap.slot(source, left);
    runtime.heap.setSlot(target, write, a);
    left = left + 1;
    write = write + 1;
  }
  while (right < high) {
    const b = runtime.heap.slot(source, right);
    runtime.heap.setSlot(target, write, b);
    right = right + 1;
    write = write + 1;
  }
}

// source[low, high) into target[low, high).
function copySlots(inout runtime: Runtime, source: u32, target: u32, low: u32, high: u32): void {
  let index = low;
  while (index < high) {
    const element = runtime.heap.slot(source, index);
    runtime.heap.setSlot(target, index, element);
    index = index + 1;
  }
}

// SortIndexedProperties: the present elements below `length`, sorted;
// 0 with a throw pending. Holes are skipped when `skipHoles`, else read
// as undefined.
function sortedElements(inout runtime: Runtime, object: Value, length: f64, comparator: Value, skipHoles: boolean): u32 {
  if (length > MAX_ARRAY_LENGTH) {
    const message: String = "Invalid array length";
    const error = runtime.rangeError(in message);
    runtime.raise(error);
    return 0;
  }
  const items = runtime.heap.allocateArray(0);
  runtime.pushTempRoot(cellValue(items));
  let k = 0.0;
  while (k < length) {
    let present = true;
    if (skipHoles) {
      present = hasIndex(inout runtime, object, k);
      if (runtime.pendingThrow) { runtime.popTempRoot(); return 0; }
    }
    if (present) {
      const element = getIndex(inout runtime, object, k);
      if (runtime.pendingThrow) { runtime.popTempRoot(); return 0; }
      const count = runtime.heap.arrayLength(items);
      runtime.heap.arraySet(items, count, element);
    }
    k = k + 1.0;
  }
  const count = runtime.heap.arrayLength(items);
  const scratch = runtime.heap.allocateArray(count);
  runtime.pushTempRoot(cellValue(scratch));
  copySlots(inout runtime, items, scratch, 0, count);
  sortInto(inout runtime, items, scratch, 0, count, comparator, runtime.leafCodeOf(comparator));
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (runtime.pendingThrow) return 0;
  return items;
}

function requireComparator(inout runtime: Runtime, comparator: Value): boolean {
  if (isUndefined(comparator) || runtime.isCallable(comparator)) return true;
  const message: String = "The comparison function must be either a function or undefined";
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return false;
}

function arraySort(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const comparator = runtime.argument(argsBase, argc, 0);
  if (!requireComparator(inout runtime, comparator)) return undefinedValue();
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  const items = sortedElements(inout runtime, object, length, comparator, true);
  if (items == 0) { runtime.popTempRoot(); return undefinedValue(); }
  runtime.pushTempRoot(cellValue(items));
  const count = runtime.heap.arrayLength(items);
  let ok = true;
  let j: u32 = 0;
  while (ok && j < count) {
    const element = runtime.heap.slot(items, j);
    ok = setIndex(inout runtime, object, f64(j), element);
    j = j + 1;
  }
  let k = f64(count);
  while (ok && k < length) {
    ok = deleteIndex(inout runtime, object, k);
    k = k + 1.0;
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (!ok) return undefinedValue();
  return object;
}

// --- Copying methods (ES2023) ---

function arrayToReversed(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  const result = arrayCreate(inout runtime, length);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  runtime.pushTempRoot(result);
  let k = 0.0;
  let ok = true;
  while (ok && k < length) {
    const element = getIndex(inout runtime, object, length - k - 1.0);
    if (runtime.pendingThrow) { ok = false; break; }
    ok = createIndex(inout runtime, result, k, element);
    k = k + 1.0;
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (!ok) return undefinedValue();
  return result;
}

function arrayToSorted(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const comparator = runtime.argument(argsBase, argc, 0);
  if (!requireComparator(inout runtime, comparator)) return undefinedValue();
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  const result = arrayCreate(inout runtime, length);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  runtime.pushTempRoot(result);
  const items = sortedElements(inout runtime, object, length, comparator, false);
  let ok = items != 0;
  if (ok) {
    const count = runtime.heap.arrayLength(items);
    let j: u32 = 0;
    while (j < count) {
      const element = runtime.heap.slot(items, j);
      runtime.heap.arraySet(asCell(result), j, element);
      j = j + 1;
    }
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (!ok) return undefinedValue();
  return result;
}

function arrayToSpliced(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  const start = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 0), length, 0.0);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  let insertCount = 0.0;
  let skipCount = 0.0;
  if (argc == 1) {
    skipCount = length - start;
  } else if (argc > 1) {
    insertCount = f64(argc - 2);
    const requested = toInteger(inout runtime, runtime.argument(argsBase, argc, 1));
    if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
    skipCount = requested < 0.0 ? 0.0 : requested;
    if (skipCount > length - start) skipCount = length - start;
  }
  const newLength = length + insertCount - skipCount;
  if (newLength > MAX_SAFE_LENGTH) {
    runtime.popTempRoot();
    const message: String = "Splicing beyond the maximum length";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const result = arrayCreate(inout runtime, newLength);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  runtime.pushTempRoot(result);
  let ok = true;
  let i = 0.0;
  while (ok && i < start) {
    const element = getIndex(inout runtime, object, i);
    if (runtime.pendingThrow) { ok = false; break; }
    ok = createIndex(inout runtime, result, i, element);
    i = i + 1.0;
  }
  let a: u32 = 2;
  while (ok && a < argc) {
    const element = runtime.argument(argsBase, argc, a);
    ok = createIndex(inout runtime, result, i, element);
    i = i + 1.0;
    a = a + 1;
  }
  let r = start + skipCount;
  while (ok && i < newLength) {
    const element = getIndex(inout runtime, object, r);
    if (runtime.pendingThrow) { ok = false; break; }
    ok = createIndex(inout runtime, result, i, element);
    i = i + 1.0;
    r = r + 1.0;
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (!ok) return undefinedValue();
  return result;
}

function arrayWith(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const object = receiverObject(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const length = lengthOf(inout runtime, object);
  if (length < 0.0) { runtime.popTempRoot(); return undefinedValue(); }
  const relative = toInteger(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  const actual = relative >= 0.0 ? relative : length + relative;
  if (actual < 0.0 || actual >= length) {
    runtime.popTempRoot();
    const message: String = "Invalid index";
    const error = runtime.rangeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const result = arrayCreate(inout runtime, length);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
  runtime.pushTempRoot(result);
  const replacement = runtime.argument(argsBase, argc, 1);
  let k = 0.0;
  let ok = true;
  while (ok && k < length) {
    let element = replacement;
    if (k != actual) {
      element = getIndex(inout runtime, object, k);
      if (runtime.pendingThrow) { ok = false; break; }
    }
    ok = createIndex(inout runtime, result, k, element);
    k = k + 1.0;
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (!ok) return undefinedValue();
  return result;
}

// --- Installation ---

function method(inout runtime: Runtime, target: u32, in name: String, fn: HostFunction, length: u32): void {
  runtime.defineMethod(target, in name, fn, length);
}

function unscopable(inout runtime: Runtime, target: u32, in name: String): void {
  const atom = runtime.atomOf(in name);
  runtime.heap.objectDefine(target, atom, booleanValue(true), PROP_DEFAULT);
}

export function installArray(inout runtime: Runtime): void {
  const arrayProto = runtime.arrayProto;
  const arrayText: String = "Array";
  const ctor = runtime.defineConstructor(constructArray, undefinedValue(), 1, in arrayText);
  runtime.heap.setLink(ctor, arrayProto);
  const atomConstructor = runtime.atomConstructor;
  runtime.defineOwnAttr(arrayProto, atomConstructor, cellValue(ctor), PROP_METHOD);
  runtime.setGlobal("Array", cellValue(ctor));
  const isArrayText: String = "isArray"; method(inout runtime, ctor, in isArrayText, arrayIsArray, 1);
  const atText: String = "at"; method(inout runtime, arrayProto, in atText, arrayAt, 1);
  const concatText: String = "concat"; method(inout runtime, arrayProto, in concatText, arrayConcat, 1);
  const copyWithinText: String = "copyWithin"; method(inout runtime, arrayProto, in copyWithinText, arrayCopyWithin, 2);
  const everyText: String = "every"; method(inout runtime, arrayProto, in everyText, arrayEvery, 1);
  const fillText: String = "fill"; method(inout runtime, arrayProto, in fillText, arrayFill, 1);
  const filterText: String = "filter"; method(inout runtime, arrayProto, in filterText, arrayFilter, 1);
  const findText: String = "find"; method(inout runtime, arrayProto, in findText, arrayFind, 1);
  const findIndexText: String = "findIndex"; method(inout runtime, arrayProto, in findIndexText, arrayFindIndex, 1);
  const findLastText: String = "findLast"; method(inout runtime, arrayProto, in findLastText, arrayFindLast, 1);
  const findLastIndexText: String = "findLastIndex"; method(inout runtime, arrayProto, in findLastIndexText, arrayFindLastIndex, 1);
  const flatText: String = "flat"; method(inout runtime, arrayProto, in flatText, arrayFlat, 0);
  const flatMapText: String = "flatMap"; method(inout runtime, arrayProto, in flatMapText, arrayFlatMap, 1);
  const forEachText: String = "forEach"; method(inout runtime, arrayProto, in forEachText, arrayForEach, 1);
  const includesText: String = "includes"; method(inout runtime, arrayProto, in includesText, arrayIncludes, 1);
  const indexOfText: String = "indexOf"; method(inout runtime, arrayProto, in indexOfText, arrayIndexOf, 1);
  const joinText: String = "join"; method(inout runtime, arrayProto, in joinText, arrayJoin, 1);
  const lastIndexOfText: String = "lastIndexOf"; method(inout runtime, arrayProto, in lastIndexOfText, arrayLastIndexOf, 1);
  const mapText: String = "map"; method(inout runtime, arrayProto, in mapText, arrayMap, 1);
  const popText: String = "pop"; method(inout runtime, arrayProto, in popText, arrayPop, 0);
  const pushText: String = "push"; method(inout runtime, arrayProto, in pushText, arrayPush, 1);
  const reduceText: String = "reduce"; method(inout runtime, arrayProto, in reduceText, arrayReduce, 1);
  const reduceRightText: String = "reduceRight"; method(inout runtime, arrayProto, in reduceRightText, arrayReduceRight, 1);
  const reverseText: String = "reverse"; method(inout runtime, arrayProto, in reverseText, arrayReverse, 0);
  const shiftText: String = "shift"; method(inout runtime, arrayProto, in shiftText, arrayShift, 0);
  const sliceText: String = "slice"; method(inout runtime, arrayProto, in sliceText, arraySlice, 2);
  const someText: String = "some"; method(inout runtime, arrayProto, in someText, arraySome, 1);
  const sortText: String = "sort"; method(inout runtime, arrayProto, in sortText, arraySort, 1);
  const spliceText: String = "splice"; method(inout runtime, arrayProto, in spliceText, arraySplice, 2);
  const toLocaleStringText: String = "toLocaleString"; method(inout runtime, arrayProto, in toLocaleStringText, arrayToLocaleString, 0);
  const toReversedText: String = "toReversed"; method(inout runtime, arrayProto, in toReversedText, arrayToReversed, 0);
  const toSortedText: String = "toSorted"; method(inout runtime, arrayProto, in toSortedText, arrayToSorted, 1);
  const toSplicedText: String = "toSpliced"; method(inout runtime, arrayProto, in toSplicedText, arrayToSpliced, 2);
  const toStringText: String = "toString"; method(inout runtime, arrayProto, in toStringText, arrayToString, 0);
  const unshiftText: String = "unshift"; method(inout runtime, arrayProto, in unshiftText, arrayUnshift, 1);
  const withText: String = "with"; method(inout runtime, arrayProto, in withText, arrayWith, 2);

  // Array.prototype[@@unscopables]: a null-prototype object naming the
  // methods `with` statements skip.
  const unscopables = runtime.heap.allocateObject(0);
  const unscopable0: String = "at"; unscopable(inout runtime, unscopables, in unscopable0);
  const unscopable1: String = "copyWithin"; unscopable(inout runtime, unscopables, in unscopable1);
  const unscopable2: String = "entries"; unscopable(inout runtime, unscopables, in unscopable2);
  const unscopable3: String = "fill"; unscopable(inout runtime, unscopables, in unscopable3);
  const unscopable4: String = "find"; unscopable(inout runtime, unscopables, in unscopable4);
  const unscopable5: String = "findIndex"; unscopable(inout runtime, unscopables, in unscopable5);
  const unscopable6: String = "findLast"; unscopable(inout runtime, unscopables, in unscopable6);
  const unscopable7: String = "findLastIndex"; unscopable(inout runtime, unscopables, in unscopable7);
  const unscopable8: String = "flat"; unscopable(inout runtime, unscopables, in unscopable8);
  const unscopable9: String = "flatMap"; unscopable(inout runtime, unscopables, in unscopable9);
  const unscopable10: String = "includes"; unscopable(inout runtime, unscopables, in unscopable10);
  const unscopable11: String = "keys"; unscopable(inout runtime, unscopables, in unscopable11);
  const unscopable12: String = "toReversed"; unscopable(inout runtime, unscopables, in unscopable12);
  const unscopable13: String = "toSorted"; unscopable(inout runtime, unscopables, in unscopable13);
  const unscopable14: String = "toSpliced"; unscopable(inout runtime, unscopables, in unscopable14);
  const unscopable15: String = "values"; unscopable(inout runtime, unscopables, in unscopable15);
  const symbolUnscopables = runtime.symbolUnscopables;
  const unscopablesKey = runtime.propertyKey(symbolUnscopables);
  runtime.heap.objectDefine(arrayProto, unscopablesKey, cellValue(unscopables), PROP_CONFIGURABLE);
}
