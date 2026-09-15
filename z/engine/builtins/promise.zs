// Promise: the constructor, the prototype's then / catch / finally, and
// the statics. The promise machinery itself (records, reactions, the
// job queue, resolution) lives in the runtime, shared with async
// functions; this module is the JavaScript-facing surface over it.
import { thread } from "std/thread";
import { Value, undefinedValue, nullValue, booleanValue, int32Value, cellValue, asCell, isCell, isUndefined, isNull, isDeleted, asInt32, isTrue } from "../value.zs";
import { Runtime, ERROR_KIND_AGGREGATE } from "../runtime.zs";
import { PROP_METHOD, PROP_NONE, PROP_CONFIGURABLE, PROP_DEFAULT, bytesOf } from "../heap.zs";
import { defineSpecies } from "./collections.zs";

function requirePromise(inout runtime: Runtime, value: Value, in what: String): u32 {
  if (runtime.isPromise(value)) return asCell(value);
  const message: String = `${what} called on an incompatible receiver`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return 0;
}

// new Promise(executor)
function constructPromise(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (!runtime.isObjectLike(thisValue)) {
    const message: String = "Promise constructor cannot be invoked without 'new'";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const executor = runtime.argument(argsBase, argc, 0);
  if (!runtime.isCallable(executor)) {
    const message: String = "Promise resolver is not a function";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  // The object new made, with a fresh record attached.
  const object = asCell(thisValue);
  const proto = runtime.heap.objectProto(object);
  const fresh = runtime.newPromiseWithProto(proto);
  const atomPromiseRecord = runtime.atomPromiseRecord;
  const recordSlot = runtime.heap.objectFindSlot(asCell(fresh), atomPromiseRecord);
  const record = runtime.heap.slot(asCell(fresh), u32(recordSlot));
  runtime.heap.objectDefine(object, atomPromiseRecord, record, PROP_NONE);
  const shared = runtime.newResolvingShared(thisValue);
  runtime.pushTempRoot(shared);
  const resolve = runtime.resolvingFunction(thisValue, shared, false);
  runtime.pushTempRoot(resolve);
  const reject = runtime.resolvingFunction(thisValue, shared, true);
  runtime.pushTempRoot(reject);
  let args = Array<Value>();
  args.push(resolve);
  args.push(reject);
  runtime.callValue(executor, undefinedValue(), move args);
  if (runtime.pendingThrow) {
    const thrown = runtime.takePending();
    let rejectArgs = Array<Value>();
    rejectArgs.push(thrown);
    runtime.callValue(reject, undefinedValue(), move rejectArgs);
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  runtime.popTempRoot();
  return thisValue;
}

function promiseThen(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Promise.prototype.then";
  const promise = requirePromise(inout runtime, thisValue, in what);
  if (promise == 0) return undefinedValue();
  const derived = runtime.newPromise();
  runtime.performThen(promise, runtime.argument(argsBase, argc, 0), runtime.argument(argsBase, argc, 1), derived);
  return derived;
}

// catch(onRejected) is this.then(undefined, onRejected).
function promiseCatch(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const thenText: String = "then";
  const thenKey = runtime.internText(in thenText);
  const then = runtime.getProperty(thisValue, thenKey);
  if (runtime.pendingThrow) return undefinedValue();
  let args = Array<Value>();
  args.push(undefinedValue());
  args.push(runtime.argument(argsBase, argc, 0));
  return runtime.callValue(then, thisValue, move args);
}

// finally(onFinally): then with handlers that run onFinally and pass the
// original outcome through; the callee's bound data is onFinally.
function finallyFulfilled(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const onFinally = runtime.heap.slot(callee, 0);
  const value = runtime.argument(argsBase, argc, 0);
  runtime.pushTempRoot(value);
  const produced = runtime.callValue(onFinally, undefinedValue(), Array<Value>());
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  // The result waits for onFinally's promise, then yields the value.
  const settled = runtime.promiseResolveValue(produced);
  runtime.pushTempRoot(settled);
  const derived = runtime.newPromise();
  runtime.pushTempRoot(derived);
  const name: String = "";
  const valueThunk = runtime.defineHostFunction(returnBound, value, 0, in name);
  runtime.performThen(asCell(settled), cellValue(valueThunk), undefinedValue(), derived);
  runtime.popTempRoot();
  runtime.popTempRoot();
  return derived;
}

function finallyRejected(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const onFinally = runtime.heap.slot(callee, 0);
  const reason = runtime.argument(argsBase, argc, 0);
  runtime.pushTempRoot(reason);
  const produced = runtime.callValue(onFinally, undefinedValue(), Array<Value>());
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  const settled = runtime.promiseResolveValue(produced);
  runtime.pushTempRoot(settled);
  const derived = runtime.newPromise();
  runtime.pushTempRoot(derived);
  const name: String = "";
  const thrower = runtime.defineHostFunction(throwBound, reason, 0, in name);
  runtime.performThen(asCell(settled), cellValue(thrower), undefinedValue(), derived);
  runtime.popTempRoot();
  runtime.popTempRoot();
  return derived;
}

function returnBound(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return runtime.heap.slot(callee, 0);
}

function throwBound(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const reason = runtime.heap.slot(callee, 0);
  runtime.raise(reason);
  return undefinedValue();
}

function promiseFinally(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (!runtime.isObjectLike(thisValue)) {
    const message: String = "Promise.prototype.finally called on a non-object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const onFinally = runtime.argument(argsBase, argc, 0);
  let onFulfilled = onFinally;
  let onRejected = onFinally;
  if (runtime.isCallable(onFinally)) {
    const name: String = "";
    onFulfilled = cellValue(runtime.defineHostFunction(finallyFulfilled, onFinally, 1, in name));
    runtime.pushTempRoot(onFulfilled);
    onRejected = cellValue(runtime.defineHostFunction(finallyRejected, onFinally, 1, in name));
    runtime.popTempRoot();
  }
  runtime.pushTempRoot(onFulfilled);
  runtime.pushTempRoot(onRejected);
  const thenText: String = "then";
  const thenKey = runtime.internText(in thenText);
  const then = runtime.getProperty(thisValue, thenKey);
  let result = undefinedValue();
  if (!runtime.pendingThrow) {
    let args = Array<Value>();
    args.push(onFulfilled);
    args.push(onRejected);
    result = runtime.callValue(then, thisValue, move args);
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  return result;
}

// --- statics ---

function promiseResolveStatic(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (!runtime.isObjectLike(thisValue)) {
    const message: String = "Promise.resolve called on a non-object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  return runtime.promiseResolveValue(runtime.argument(argsBase, argc, 0));
}

function promiseRejectStatic(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (!runtime.isObjectLike(thisValue)) {
    const message: String = "Promise.reject called on a non-object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const promise = runtime.newPromise();
  runtime.rejectPromise(asCell(promise), runtime.argument(argsBase, argc, 0));
  return promise;
}

function promiseWithResolvers(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const promise = runtime.newPromise();
  runtime.pushTempRoot(promise);
  const shared = runtime.newResolvingShared(promise);
  runtime.pushTempRoot(shared);
  const resolve = runtime.resolvingFunction(promise, shared, false);
  runtime.pushTempRoot(resolve);
  const reject = runtime.resolvingFunction(promise, shared, true);
  runtime.pushTempRoot(reject);
  const objectProto = runtime.objectProto;
  const result = runtime.heap.allocateObject(objectProto);
  const promiseText: String = "promise";
  const promiseAtom = runtime.atomOf(in promiseText);
  runtime.heap.objectDefine(result, promiseAtom, promise, PROP_DEFAULT);
  const resolveText: String = "resolve";
  const resolveAtom = runtime.atomOf(in resolveText);
  runtime.heap.objectDefine(result, resolveAtom, resolve, PROP_DEFAULT);
  const rejectText: String = "reject";
  const rejectAtom = runtime.atomOf(in rejectText);
  runtime.heap.objectDefine(result, rejectAtom, reject, PROP_DEFAULT);
  runtime.popTempRoot();
  runtime.popTempRoot();
  runtime.popTempRoot();
  runtime.popTempRoot();
  return cellValue(result);
}

// Promise.all / allSettled / any / race share one iteration: each
// element is resolved to a promise whose settlement runs an element
// handler bound to [aggregate, index]. The aggregate is a heap array:
// [values, remaining, result promise, mode, errors].
const AGG_ALL: i32 = 0;
const AGG_ALL_SETTLED: i32 = 1;
const AGG_ANY: i32 = 2;
const AGG_RACE: i32 = 3;

function aggregateSettle(inout runtime: Runtime, aggregate: u32, index: u32, value: Value, rejected: boolean): void {
  const mode = asInt32(runtime.heap.slot(aggregate, 3));
  const result = runtime.heap.slot(aggregate, 2);
  const values = asCell(runtime.heap.slot(aggregate, 0));
  if (mode == AGG_RACE) {
    if (rejected) { runtime.rejectPromise(asCell(result), value); } else { runtime.resolvePromise(asCell(result), value); }
    return;
  }
  if (mode == AGG_ALL) {
    if (rejected) {
      runtime.rejectPromise(asCell(result), value);
      return;
    }
    runtime.heap.setSlot(values, index, value);
  } else if (mode == AGG_ALL_SETTLED) {
    const objectProto = runtime.objectProto;
    const entry = runtime.heap.allocateObject(objectProto);
    runtime.pushTempRoot(cellValue(entry));
    const statusText: String = "status";
    const statusAtom = runtime.atomOf(in statusText);
    let label = undefinedValue();
    let keyAtom: u32 = 0;
    if (rejected) {
      const rejectedText: String = "rejected";
      label = runtime.internText(in rejectedText);
      const reasonText: String = "reason";
      keyAtom = runtime.atomOf(in reasonText);
    } else {
      const fulfilledText: String = "fulfilled";
      label = runtime.internText(in fulfilledText);
      const valueText: String = "value";
      keyAtom = runtime.atomOf(in valueText);
    }
    runtime.heap.objectDefine(entry, statusAtom, label, PROP_DEFAULT);
    runtime.heap.objectDefine(entry, keyAtom, value, PROP_DEFAULT);
    runtime.popTempRoot();
    runtime.heap.setSlot(values, index, cellValue(entry));
  } else {
    // any: a fulfillment wins; rejections collect.
    if (!rejected) {
      runtime.resolvePromise(asCell(result), value);
      return;
    }
    runtime.heap.setSlot(values, index, value);
  }
  const remaining = asInt32(runtime.heap.slot(aggregate, 1)) - 1;
  runtime.heap.setSlot(aggregate, 1, int32Value(remaining));
  if (remaining == 0) aggregateFinish(inout runtime, aggregate);
}

function aggregateFinish(inout runtime: Runtime, aggregate: u32): void {
  const mode = asInt32(runtime.heap.slot(aggregate, 3));
  const result = runtime.heap.slot(aggregate, 2);
  const values = runtime.heap.slot(aggregate, 0);
  if (mode == AGG_ANY) {
    const message: String = "All promises were rejected";
    const error = runtime.makeError(ERROR_KIND_AGGREGATE, bytesOf(in message));
    runtime.pushTempRoot(error);
    const errorsText: String = "errors";
    const errorsAtom = runtime.atomOf(in errorsText);
    runtime.heap.objectDefine(asCell(error), errorsAtom, values, PROP_METHOD);
    runtime.popTempRoot();
    runtime.rejectPromise(asCell(result), error);
    return;
  }
  runtime.resolvePromise(asCell(result), values);
}

// Element handlers: the callee's bound data is [aggregate, index, done].
function elementFulfilled(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const bound = asCell(runtime.heap.slot(callee, 0));
  if (isTrue(runtime.heap.slot(bound, 2))) return undefinedValue();
  runtime.heap.setSlot(bound, 2, booleanValue(true));
  const aggregate = asCell(runtime.heap.slot(bound, 0));
  const index = u32(asInt32(runtime.heap.slot(bound, 1)));
  aggregateSettle(inout runtime, aggregate, index, runtime.argument(argsBase, argc, 0), false);
  return undefinedValue();
}

function elementRejected(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const bound = asCell(runtime.heap.slot(callee, 0));
  if (isTrue(runtime.heap.slot(bound, 2))) return undefinedValue();
  runtime.heap.setSlot(bound, 2, booleanValue(true));
  const aggregate = asCell(runtime.heap.slot(bound, 0));
  const index = u32(asInt32(runtime.heap.slot(bound, 1)));
  aggregateSettle(inout runtime, aggregate, index, runtime.argument(argsBase, argc, 0), true);
  return undefinedValue();
}

function aggregate(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, mode: i32): Value {
  if (!runtime.isObjectLike(thisValue)) {
    const message: String = "Promise combinator called on a non-object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const result = runtime.newPromise();
  runtime.pushTempRoot(result);
  const record = runtime.heap.allocateArray(5);
  runtime.heap.setSlot(record, 0, cellValue(runtime.heap.allocateArray(0)));
  runtime.heap.setSlot(record, 1, int32Value(1));
  runtime.heap.setSlot(record, 2, result);
  runtime.heap.setSlot(record, 3, int32Value(mode));
  runtime.heap.setSlot(record, 4, undefinedValue());
  runtime.pushTempRoot(cellValue(record));
  const resolveText: String = "resolve";
  const resolveKey = runtime.internText(in resolveText);
  const promiseResolve = runtime.getProperty(thisValue, resolveKey);
  let failed = runtime.pendingThrow;
  if (!failed && !runtime.isCallable(promiseResolve)) {
    const message: String = "Promise resolve is not a function";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    failed = true;
  }
  let iterator = undefinedValue();
  if (!failed) {
    iterator = runtime.getIterator(runtime.argument(argsBase, argc, 0));
    failed = runtime.pendingThrow;
  }
  let index: u32 = 0;
  if (!failed) {
    runtime.pushTempRoot(iterator);
    while (true) {
      const item = runtime.iteratorStep(iterator);
      if (runtime.pendingThrow || isDeleted(item)) break;
      let resolveArgs = Array<Value>();
      resolveArgs.push(item);
      const element = runtime.callValue(promiseResolve, thisValue, move resolveArgs);
      if (runtime.pendingThrow) break;
      runtime.pushTempRoot(element);
      const values = asCell(runtime.heap.slot(record, 0));
      runtime.heap.arraySet(values, index, undefinedValue());
      runtime.heap.setSlot(record, 1, int32Value(asInt32(runtime.heap.slot(record, 1)) + 1));
      const bound = runtime.heap.allocateArray(3);
      runtime.heap.setSlot(bound, 0, cellValue(record));
      runtime.heap.setSlot(bound, 1, int32Value(i32(index)));
      runtime.heap.setSlot(bound, 2, booleanValue(false));
      runtime.pushTempRoot(cellValue(bound));
      const name: String = "";
      const onFulfilled = cellValue(runtime.defineHostFunction(elementFulfilled, cellValue(bound), 1, in name));
      runtime.pushTempRoot(onFulfilled);
      const onRejected = cellValue(runtime.defineHostFunction(elementRejected, cellValue(bound), 1, in name));
      runtime.pushTempRoot(onRejected);
      const thenText: String = "then";
      const thenKey = runtime.internText(in thenText);
      const then = runtime.getProperty(element, thenKey);
      if (!runtime.pendingThrow) {
        let thenArgs = Array<Value>();
        thenArgs.push(onFulfilled);
        thenArgs.push(onRejected);
        runtime.callValue(then, element, move thenArgs);
      }
      runtime.popTempRoot();
      runtime.popTempRoot();
      runtime.popTempRoot();
      runtime.popTempRoot();
      if (runtime.pendingThrow) break;
      index = index + 1;
    }
    runtime.popTempRoot();
    failed = runtime.pendingThrow;
  }
  if (failed) {
    const thrown = runtime.takePending();
    runtime.rejectPromise(asCell(result), thrown);
  } else {
    // The extra count taken before the loop: finish if nothing is pending.
    const remaining = asInt32(runtime.heap.slot(record, 1)) - 1;
    runtime.heap.setSlot(record, 1, int32Value(remaining));
    if (remaining == 0 && mode != AGG_RACE) aggregateFinish(inout runtime, record);
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  return result;
}

function promiseAll(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return aggregate(inout runtime, thisValue, argsBase, argc, AGG_ALL);
}
function promiseAllSettled(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return aggregate(inout runtime, thisValue, argsBase, argc, AGG_ALL_SETTLED);
}
function promiseAny(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return aggregate(inout runtime, thisValue, argsBase, argc, AGG_ANY);
}
function promiseRace(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return aggregate(inout runtime, thisValue, argsBase, argc, AGG_RACE);
}

export function installPromise(inout runtime: Runtime): void {
  const objectProto = runtime.objectProto;
  runtime.promiseProto = runtime.heap.allocateObject(objectProto);
  const promiseProto = runtime.promiseProto;
  const promiseText: String = "Promise";
  const ctor = runtime.defineConstructor(constructPromise, undefinedValue(), 1, in promiseText);
  runtime.heap.setLink(ctor, promiseProto);
  const atomConstructor = runtime.atomConstructor;
  runtime.defineOwnAttr(promiseProto, atomConstructor, cellValue(ctor), PROP_METHOD);
  runtime.setGlobal("Promise", cellValue(ctor));
  const thenText: String = "then"; runtime.defineMethod(promiseProto, in thenText, promiseThen, 2);
  const catchText: String = "catch"; runtime.defineMethod(promiseProto, in catchText, promiseCatch, 1);
  const finallyText: String = "finally"; runtime.defineMethod(promiseProto, in finallyText, promiseFinally, 1);
  const resolveText: String = "resolve"; runtime.defineMethod(ctor, in resolveText, promiseResolveStatic, 1);
  const rejectText: String = "reject"; runtime.defineMethod(ctor, in rejectText, promiseRejectStatic, 1);
  const allText: String = "all"; runtime.defineMethod(ctor, in allText, promiseAll, 1);
  const allSettledText: String = "allSettled"; runtime.defineMethod(ctor, in allSettledText, promiseAllSettled, 1);
  const anyText: String = "any"; runtime.defineMethod(ctor, in anyText, promiseAny, 1);
  const raceText: String = "race"; runtime.defineMethod(ctor, in raceText, promiseRace, 1);
  const withResolversText: String = "withResolvers"; runtime.defineMethod(ctor, in withResolversText, promiseWithResolvers, 0);
  defineSpecies(inout runtime, ctor);
  const symbolToStringTag = runtime.symbolToStringTag;
  const tagKey = runtime.propertyKey(symbolToStringTag);
  const tagValue = runtime.internText(in promiseText);
  runtime.heap.objectDefine(promiseProto, tagKey, tagValue, PROP_CONFIGURABLE);
}
