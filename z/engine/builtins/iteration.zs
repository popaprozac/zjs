// %IteratorPrototype%, %ArrayIteratorPrototype%, and the iterators of
// Array, String, and arguments.
import { thread } from "std/thread";
import { Value, undefinedValue, booleanValue, int32Value, cellValue, asCell, isCell, isUndefined, isNull, isDeleted } from "../value.zs";
import { Runtime } from "../runtime.zs";
import { PROP_METHOD, PROP_CONFIGURABLE } from "../heap.zs";

// %IteratorPrototype%[Symbol.iterator]: itself.
function iteratorSelf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return thisValue;
}

// %ArrayIteratorPrototype%.next
function arrayIteratorNext(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (!isCell(thisValue) || asCell(thisValue) == 0 || !runtime.heap.isObject(asCell(thisValue)) || runtime.heap.objectFindSlot(asCell(thisValue), runtime.atomIterSource) < 0) {
    const message: String = "next called on an incompatible receiver";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const next = runtime.arrayIteratorStep(asCell(thisValue));
  if (runtime.pendingThrow) return undefinedValue();
  if (isDeleted(next)) return runtime.createIterResult(undefinedValue(), true);
  return runtime.createIterResult(next, false);
}

function requireCoercible(inout runtime: Runtime, thisValue: Value, in method: String): boolean {
  if (!isUndefined(thisValue) && !isNull(thisValue)) return true;
  const message: String = `${method} called on null or undefined`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return false;
}

function arrayValues(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "Array.prototype.values";
  if (!requireCoercible(inout runtime, thisValue, in method)) return undefinedValue();
  return runtime.createArrayIterator(thisValue, 0);
}

function arrayKeys(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "Array.prototype.keys";
  if (!requireCoercible(inout runtime, thisValue, in method)) return undefinedValue();
  return runtime.createArrayIterator(thisValue, 1);
}

function arrayEntries(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "Array.prototype.entries";
  if (!requireCoercible(inout runtime, thisValue, in method)) return undefinedValue();
  return runtime.createArrayIterator(thisValue, 2);
}

// String.prototype[Symbol.iterator]: over the bytes, as the engine's
// strings are byte strings.
function stringIterator(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "String.prototype[Symbol.iterator]";
  if (!requireCoercible(inout runtime, thisValue, in method)) return undefinedValue();
  const text = runtime.toStringValue(thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  return runtime.createArrayIterator(text, 0);
}

// Array.from(items, mapFn): an iterable, or an array-like by length.
function arrayFrom(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const items = runtime.argument(argsBase, argc, 0);
  const mapFn = runtime.argument(argsBase, argc, 1);
  if (!isUndefined(mapFn) && !runtime.isCallable(mapFn)) {
    const message: String = "Array.from: mapFn is not callable";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const symbolIterator = runtime.symbolIterator;
  let usingIterator = undefinedValue();
  if (!isUndefined(items) && !isNull(items)) usingIterator = runtime.getProperty(items, symbolIterator);
  if (runtime.pendingThrow) return undefinedValue();
  let source = undefinedValue();
  if (runtime.isCallable(usingIterator)) {
    source = runtime.iterateToArray(items);
    if (runtime.pendingThrow) return undefinedValue();
  } else {
    if (isUndefined(items) || isNull(items)) {
      const message: String = "Array.from requires an array-like or iterable";
      const error = runtime.typeError(in message);
      runtime.raise(error);
      return undefinedValue();
    }
    const gathered = runtime.heap.allocateArray(0);
    runtime.pushTempRoot(cellValue(gathered));
    const lengthKey = cellValue(runtime.atomLength);
    const lengthValue = runtime.getProperty(items, lengthKey);
    if (runtime.pendingThrow) {
      runtime.popTempRoot();
      return undefinedValue();
    }
    const length = runtime.toLength(lengthValue);
    let index: u32 = 0;
    while (index < length) {
      const element = runtime.getProperty(items, int32Value(i32(index)));
      if (runtime.pendingThrow) {
        runtime.popTempRoot();
        return undefinedValue();
      }
      runtime.heap.arraySet(gathered, index, element);
      index = index + 1;
    }
    runtime.popTempRoot();
    source = cellValue(gathered);
  }
  if (isUndefined(mapFn)) return source;
  const array = asCell(source);
  runtime.pushTempRoot(source);
  const count = runtime.heap.arrayLength(array);
  let index: u32 = 0;
  while (index < count) {
    let args = Array<Value>();
    args.push(runtime.heap.arrayGet(array, index));
    args.push(int32Value(i32(index)));
    const mapped = runtime.callValue(mapFn, runtime.argument(argsBase, argc, 2), move args);
    if (runtime.pendingThrow) {
      runtime.popTempRoot();
      return undefinedValue();
    }
    runtime.heap.arraySet(array, index, mapped);
    index = index + 1;
  }
  runtime.popTempRoot();
  return source;
}

function arrayOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const array = runtime.heap.allocateArray(argc);
  let index: u32 = 0;
  while (index < argc) {
    const element = runtime.argument(argsBase, argc, index);
    runtime.heap.setSlot(array, index, element);
    index = index + 1;
  }
  return cellValue(array);
}

export function installIteration(inout runtime: Runtime): void {
  const iteratorProto = runtime.iteratorProto;
  const symbolIterator = runtime.symbolIterator;
  const iteratorKey = runtime.propertyKey(symbolIterator);
  const selfName: String = "[Symbol.iterator]";
  const selfFn = runtime.defineHostFunction(iteratorSelf, undefinedValue(), 0, in selfName);
  runtime.heap.objectDefine(iteratorProto, iteratorKey, cellValue(selfFn), PROP_METHOD);

  const arrayIteratorProto = runtime.arrayIteratorProto;
  const nextText: String = "next";
  const nextFn = runtime.defineMethod(arrayIteratorProto, in nextText, arrayIteratorNext, 0);
  runtime.arrayIteratorNext = nextFn;
  const symbolToStringTag = runtime.symbolToStringTag;
  const tagKey = runtime.propertyKey(symbolToStringTag);
  const tagText: String = "Array Iterator";
  const tagValue = runtime.internText(in tagText);
  runtime.heap.objectDefine(arrayIteratorProto, tagKey, tagValue, PROP_CONFIGURABLE);

  const arrayProto = runtime.arrayProto;
  const valuesText: String = "values";
  const valuesFn = runtime.defineMethod(arrayProto, in valuesText, arrayValues, 0);
  runtime.heap.objectDefine(arrayProto, iteratorKey, cellValue(valuesFn), PROP_METHOD);
  const keysText: String = "keys";
  runtime.defineMethod(arrayProto, in keysText, arrayKeys, 0);
  const entriesText: String = "entries";
  runtime.defineMethod(arrayProto, in entriesText, arrayEntries, 0);

  const stringProto = runtime.stringProto;
  const stringIteratorName: String = "[Symbol.iterator]";
  const stringFn = runtime.defineHostFunction(stringIterator, undefinedValue(), 0, in stringIteratorName);
  runtime.heap.objectDefine(stringProto, iteratorKey, cellValue(stringFn), PROP_METHOD);

  const arraySlot = runtime.globalSlot("Array");
  const arrayCtor = asCell(runtime.globals[usize(arraySlot)].value);
  const fromText: String = "from";
  runtime.defineMethod(arrayCtor, in fromText, arrayFrom, 1);
  const ofText: String = "of";
  runtime.defineMethod(arrayCtor, in ofText, arrayOf, 0);
}
