// %IteratorPrototype%, %ArrayIteratorPrototype%, and the iterators of
// Array, String, and arguments.
import { thread } from "std/thread";
import { Value, undefinedValue, booleanValue, int32Value, cellValue, asCell, isCell, isUndefined, isNull, isDeleted } from "../value.zs";
import { Runtime, ITERATOR_OF_STRING } from "../runtime.zs";
import { PROP_METHOD, PROP_CONFIGURABLE } from "../heap.zs";
import { constructReceiver, fillReceiver } from "./array.zs";

// %IteratorPrototype%[Symbol.iterator]: itself.
function iteratorSelf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return thisValue;
}

// %ArrayIteratorPrototype%.next and %StringIteratorPrototype%.next: each
// steps only an iterator of its own kind.
function iteratorNext(inout runtime: Runtime, thisValue: Value, ofString: boolean): Value {
  const kind = runtime.iteratorKind(thisValue);
  if (kind < 0 || (kind == i32(ITERATOR_OF_STRING)) != ofString) {
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

function arrayIteratorNext(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return iteratorNext(inout runtime, thisValue, false);
}

function stringIteratorNext(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return iteratorNext(inout runtime, thisValue, true);
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

// String.prototype[Symbol.iterator]: the string's own iterator, by code
// point.
function stringIterator(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "String.prototype[Symbol.iterator]";
  if (!requireCoercible(inout runtime, thisValue, in method)) return undefinedValue();
  const text = runtime.toStringValue(thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  return runtime.createArrayIterator(text, ITERATOR_OF_STRING);
}

// Close the array iterator a loop over `items` stood in for, after a
// throw: the iterator as it would be with `yielded` elements read, so
// that a `return` a program has given array iterators is found and run
// as it would have been. The throw stands.
function closeStandIn(inout runtime: Runtime, items: Value, yielded: u32): void {
  const iterator = runtime.createArrayIterator(items, 0);
  runtime.pushTempRoot(iterator);
  const made = asCell(iterator);
  const indexSlot = runtime.heap.objectFindSlot(made, runtime.atomIterIndex);
  runtime.heap.setSlot(made, u32(indexSlot), int32Value(i32(yielded)));
  runtime.closeAfterThrow(iterator);
}

// Array.from(items, mapFn): an iterable, or an array-like by length.
// Each value is mapped as it is produced, so a mapFn that changes the
// source sees its change in the values after.
function arrayFrom(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const items = runtime.argument(argsBase, argc, 0);
  const mapFn = runtime.argument(argsBase, argc, 1);
  const mapping = !isUndefined(mapFn);
  if (mapping && !runtime.isCallable(mapFn)) {
    const message: String = "Array.from: mapFn is not callable";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const thisArg = runtime.argument(argsBase, argc, 2);
  // Symbol.iterator is read once: the iterator is made from what this
  // read found.
  const symbolIterator = runtime.symbolIterator;
  let usingIterator = undefinedValue();
  if (!isUndefined(items) && !isNull(items)) usingIterator = runtime.getProperty(items, symbolIterator);
  if (runtime.pendingThrow) return undefinedValue();
  // The values gather in a plain array. The receiver's own object, when
  // it is a constructor other than Array, is made before the items are
  // read and filled once they are gathered. Both, and the iteration, are
  // rooted until the builtin returns (callHost pops them).
  const array = runtime.heap.allocateArray(0);
  runtime.pushTempRoot(cellValue(array));
  if (runtime.isCallable(usingIterator)) {
    const target = constructReceiver(inout runtime, thisValue, -1.0);
    if (runtime.pendingThrow) return undefinedValue();
    runtime.pushTempRoot(target);
    if (isCell(usingIterator) && asCell(usingIterator) == runtime.arrayValuesFn && runtime.arrayIterationPristine(items)) {
      // An ordinary array, and the method read is the one that iterates
      // it: its elements as that iterator would read them, each when
      // reached, without making the iterator. Asked only here, since
      // making the receiver's object may have changed the iterator's
      // `next`.
      const source = asCell(items);
      let at: u32 = 0;
      while (at < runtime.heap.arrayLength(source)) {
        let element = runtime.heap.dataElement(source, at);
        if (isDeleted(element)) {
          element = runtime.getProperty(items, int32Value(i32(at)));
          if (runtime.pendingThrow) return undefinedValue();
        }
        if (mapping) {
          element = runtime.callValue2(mapFn, thisArg, element, int32Value(i32(at)));
          if (runtime.pendingThrow) {
            closeStandIn(inout runtime, items, at + 1);
            return undefinedValue();
          }
        }
        runtime.heap.arraySet(array, at, element);
        at = at + 1;
      }
      return fillReceiver(inout runtime, target, array);
    }
    const iteration = runtime.getIteratorFromMethod(items, usingIterator);
    if (runtime.pendingThrow) return undefinedValue();
    runtime.pushTempRoot(iteration);
    let index: u32 = 0;
    while (true) {
      let next = runtime.iteratorStep(iteration);
      if (runtime.pendingThrow) return undefinedValue();
      if (isDeleted(next)) return fillReceiver(inout runtime, target, array);
      if (mapping) {
        next = runtime.callValue2(mapFn, thisArg, next, int32Value(i32(index)));
        if (runtime.pendingThrow) {
          runtime.closeAfterThrow(iteration);
          return undefinedValue();
        }
      }
      runtime.heap.arraySet(array, index, next);
      index = index + 1;
    }
  }
  if (isUndefined(items) || isNull(items)) {
    const message: String = "Array.from requires an array-like or iterable";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const lengthKey = cellValue(runtime.atomLength);
  const lengthValue = runtime.getProperty(items, lengthKey);
  if (runtime.pendingThrow) return undefinedValue();
  const length = runtime.toLength(lengthValue);
  if (runtime.pendingThrow) return undefinedValue();
  const target = constructReceiver(inout runtime, thisValue, f64(length));
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(target);
  let index: u32 = 0;
  while (index < length) {
    let element = runtime.getProperty(items, int32Value(i32(index)));
    if (runtime.pendingThrow) return undefinedValue();
    if (mapping) {
      element = runtime.callValue2(mapFn, thisArg, element, int32Value(i32(index)));
      if (runtime.pendingThrow) return undefinedValue();
    }
    runtime.heap.arraySet(array, index, element);
    index = index + 1;
  }
  return fillReceiver(inout runtime, target, array);
}

function arrayOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = constructReceiver(inout runtime, thisValue, f64(argc));
  if (runtime.pendingThrow) return undefinedValue();
  const array = runtime.heap.allocateArray(argc);
  let index: u32 = 0;
  while (index < argc) {
    const element = runtime.argument(argsBase, argc, index);
    runtime.heap.setSlot(array, index, element);
    index = index + 1;
  }
  return fillReceiver(inout runtime, target, array);
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

  const stringIteratorProto = runtime.heap.allocateObject(iteratorProto);
  runtime.stringIteratorProto = stringIteratorProto;
  const stringNextFn = runtime.defineMethod(stringIteratorProto, in nextText, stringIteratorNext, 0);
  runtime.stringIteratorNext = stringNextFn;
  const stringTagText: String = "String Iterator";
  const stringTagValue = runtime.internText(in stringTagText);
  runtime.heap.objectDefine(stringIteratorProto, tagKey, stringTagValue, PROP_CONFIGURABLE);

  const arrayProto = runtime.arrayProto;
  const valuesText: String = "values";
  const valuesFn = runtime.defineMethod(arrayProto, in valuesText, arrayValues, 0);
  runtime.heap.objectDefine(arrayProto, iteratorKey, cellValue(valuesFn), PROP_METHOD);
  runtime.arrayValuesFn = valuesFn;
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
