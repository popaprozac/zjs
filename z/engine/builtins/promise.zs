// Promise: the constructor, the prototype's then / catch / finally, and
// the statics. The promise machinery itself (records, reactions, the
// job queue, resolution) lives in the runtime, shared with async
// functions; this module is the JavaScript-facing surface over it.
import { thread } from "std/thread";
import { Value, undefinedValue, nullValue, booleanValue, int32Value, cellValue, asCell, isCell, isUndefined, isNull, isDeleted, asInt32, isTrue } from "../value.zs";
import { Runtime, ERROR_KIND_AGGREGATE, HOST_CAPABILITY_EXECUTOR, HOST_RETURN_BOUND, HOST_THROW_BOUND, HOST_FINALLY_FULFILLED, HOST_FINALLY_REJECTED, HOST_ELEMENT_FULFILLED, HOST_ELEMENT_REJECTED } from "../runtime.zs";
import { PROP_METHOD, PROP_NONE, PROP_CONFIGURABLE, PROP_DEFAULT, bytesOf } from "../heap.zs";
import { defineSpecies } from "./collections.zs";

function raiseType(inout runtime: Runtime, in message: String): Value {
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return undefinedValue();
}

function requirePromise(inout runtime: Runtime, value: Value, in what: String): u32 {
  if (runtime.isPromise(value)) return asCell(value);
  const message: String = `${what} called on an incompatible receiver`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return 0;
}

function isIntrinsicConstructor(inout runtime: Runtime, ctor: Value): boolean {
  return isCell(ctor) && asCell(ctor) == runtime.promiseCtor;
}

// --- Capabilities ---
//
// A capability is the heap array [promise, resolve, reject] that
// NewPromiseCapability builds by constructing `ctor` with an executor
// of the engine's own. The constructor is the program's: what it returns
// need not be a promise the engine made, and the two functions are
// whatever it chose to pass, so nothing here looks inside the promise.
// The intrinsic constructor is the one exception: constructing it has
// no step the program can see, so its capability is built directly.

// The executor a constructor receives: it records the resolve / reject
// pair, once. `callee`'s bound data is the capability.
function capabilityExecutor(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const capability = asCell(runtime.heap.slot(callee, 0));
  if (!isUndefined(runtime.heap.slot(capability, 1)) || !isUndefined(runtime.heap.slot(capability, 2))) {
    const message: String = "Promise executor has already been given its functions";
    return raiseType(inout runtime, in message);
  }
  runtime.heap.setSlot(capability, 1, runtime.argument(argsBase, argc, 0));
  runtime.heap.setSlot(capability, 2, runtime.argument(argsBase, argc, 1));
  return undefinedValue();
}

// NewPromiseCapability(ctor): the capability, or 0 with a throw pending.
function newPromiseCapability(inout runtime: Runtime, ctor: Value): u32 {
  if (!runtime.isConstructorValue(ctor)) {
    const message: String = "Promise capability requires a constructor";
    const ignored = raiseType(inout runtime, in message);
    return 0;
  }
  const capability = runtime.heap.allocateArray(3);
  runtime.heap.setSlot(capability, 0, undefinedValue());
  runtime.heap.setSlot(capability, 1, undefinedValue());
  runtime.heap.setSlot(capability, 2, undefinedValue());
  runtime.pushTempRoot(cellValue(capability));
  if (isIntrinsicConstructor(inout runtime, ctor)) {
    const promise = runtime.newPromise();
    runtime.heap.setSlot(capability, 0, promise);
    const shared = runtime.newResolvingShared(promise);
    runtime.pushTempRoot(shared);
    const resolve = runtime.resolvingFunction(promise, shared, false);
    runtime.heap.setSlot(capability, 1, resolve);
    const reject = runtime.resolvingFunction(promise, shared, true);
    runtime.heap.setSlot(capability, 2, reject);
    runtime.popTempRoot();
    runtime.popTempRoot();
    return capability;
  }
  const executor = runtime.newSharedHost(HOST_CAPABILITY_EXECUTOR, cellValue(capability), 2);
  let args = Array<Value>();
  args.push(cellValue(executor));
  runtime.pushTempRoot(ctor);
  const promise = runtime.constructValue(ctor, move args, ctor);
  runtime.popTempRoot();
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return 0;
  }
  if (!runtime.isCallable(runtime.heap.slot(capability, 1)) || !runtime.isCallable(runtime.heap.slot(capability, 2))) {
    runtime.popTempRoot();
    const message: String = "Promise constructor did not supply resolve and reject functions";
    const ignored = raiseType(inout runtime, in message);
    return 0;
  }
  runtime.heap.setSlot(capability, 0, promise);
  runtime.popTempRoot();
  return capability;
}

// Call a capability's resolve or reject function; a throw is left pending.
function capabilitySettle(inout runtime: Runtime, capability: u32, value: Value, isReject: boolean): Value {
  const settle = runtime.heap.slot(capability, isReject ? 2 : 1);
  let args = Array<Value>();
  args.push(value);
  return runtime.callValue(settle, undefinedValue(), move args);
}

// PromiseResolve(ctor, value): a promise whose `constructor` is `ctor`
// as-is, anything else resolved into a new capability of `ctor`.
function promiseResolveWith(inout runtime: Runtime, ctor: Value, value: Value): Value {
  if (isIntrinsicConstructor(inout runtime, ctor)) return runtime.promiseResolveValue(value);
  runtime.pushTempRoot(value);
  if (runtime.isPromise(value)) {
    const atomConstructor = runtime.atomConstructor;
    const held = runtime.getProperty(value, cellValue(atomConstructor));
    if (runtime.pendingThrow || runtime.sameValue(held, ctor)) {
      runtime.popTempRoot();
      return runtime.pendingThrow ? undefinedValue() : value;
    }
  }
  const capability = newPromiseCapability(inout runtime, ctor);
  if (capability == 0) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  runtime.pushTempRoot(cellValue(capability));
  const ignored = capabilitySettle(inout runtime, capability, value, false);
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  return runtime.heap.slot(capability, 0);
}

// Invoke(target, "then", args): the lookup and the call are both the
// program's to observe.
function invokeThen(inout runtime: Runtime, target: Value, args: Array<Value>): Value {
  // A `then` getter may collect: the arguments are not in registers yet.
  let index: usize = 0;
  while (index < args.length) {
    runtime.pushTempRoot(args[index]);
    index = index + 1;
  }
  const thenText: String = "then";
  const thenKey = runtime.internText(in thenText);
  const then = runtime.getProperty(target, thenKey);
  while (index > 0) {
    runtime.popTempRoot();
    index = index - 1;
  }
  if (runtime.pendingThrow) return undefinedValue();
  return runtime.callValue(then, target, move args);
}

// new Promise(executor). The constructor makes its own object, so the
// executor is checked before the new target's `prototype` is read.
function constructPromise(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const newTarget = runtime.takeHostNewTarget();
  if (isUndefined(newTarget)) {
    const message: String = "Promise constructor cannot be invoked without 'new'";
    return raiseType(inout runtime, in message);
  }
  const executor = runtime.argument(argsBase, argc, 0);
  if (!runtime.isCallable(executor)) {
    const message: String = "Promise resolver is not a function";
    return raiseType(inout runtime, in message);
  }
  let proto = runtime.promiseProto;
  if (!isIntrinsicConstructor(inout runtime, newTarget)) {
    const atomPrototype = runtime.atomPrototype;
    const held = runtime.getProperty(newTarget, cellValue(atomPrototype));
    if (runtime.pendingThrow) return undefinedValue();
    if (runtime.isObjectLike(held)) proto = asCell(held);
  }
  const promise = runtime.newPromiseWithProto(proto);
  runtime.pushTempRoot(promise);
  const shared = runtime.newResolvingShared(promise);
  runtime.pushTempRoot(shared);
  const resolve = runtime.resolvingFunction(promise, shared, false);
  runtime.pushTempRoot(resolve);
  const reject = runtime.resolvingFunction(promise, shared, true);
  runtime.pushTempRoot(reject);
  let args = Array<Value>();
  args.push(resolve);
  args.push(reject);
  const ignored = runtime.callValue(executor, undefinedValue(), move args);
  if (runtime.pendingThrow) {
    const thrown = runtime.takePending();
    let rejectArgs = Array<Value>();
    rejectArgs.push(thrown);
    const dropped = runtime.callValue(reject, undefinedValue(), move rejectArgs);
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  runtime.popTempRoot();
  runtime.popTempRoot();
  return promise;
}

// then(onFulfilled, onRejected): the derived promise comes from the
// receiver's species. The intrinsic constructor's is settled directly;
// any other's is reached only through its capability.
function promiseThen(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Promise.prototype.then";
  const promise = requirePromise(inout runtime, thisValue, in what);
  if (promise == 0) return undefinedValue();
  const intrinsic = cellValue(runtime.promiseCtor);
  const ctor = runtime.speciesConstructor(thisValue, intrinsic);
  if (runtime.pendingThrow) return undefinedValue();
  const onFulfilled = runtime.argument(argsBase, argc, 0);
  const onRejected = runtime.argument(argsBase, argc, 1);
  if (isIntrinsicConstructor(inout runtime, ctor)) {
    const derived = runtime.newPromise();
    runtime.performThen(promise, onFulfilled, onRejected, derived);
    return derived;
  }
  const capability = newPromiseCapability(inout runtime, ctor);
  if (capability == 0) return undefinedValue();
  runtime.performThen(promise, onFulfilled, onRejected, cellValue(capability));
  return runtime.heap.slot(capability, 0);
}

// catch(onRejected) is this.then(undefined, onRejected).
function promiseCatch(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  let args = Array<Value>();
  args.push(undefinedValue());
  args.push(runtime.argument(argsBase, argc, 0));
  return invokeThen(inout runtime, thisValue, move args);
}

// finally(onFinally): then with handlers that run onFinally, resolve its
// result through the receiver's species constructor, and pass the
// original outcome on. Their bound data is [onFinally, constructor].
function finallySettled(inout runtime: Runtime, argsBase: u32, argc: u32, callee: u32, isReject: boolean): Value {
  const bound = asCell(runtime.heap.slot(callee, 0));
  const onFinally = runtime.heap.slot(bound, 0);
  const ctor = runtime.heap.slot(bound, 1);
  const outcome = runtime.argument(argsBase, argc, 0);
  runtime.pushTempRoot(outcome);
  const produced = runtime.callValue(onFinally, undefinedValue(), Array<Value>());
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  const settled = promiseResolveWith(inout runtime, ctor, produced);
  if (runtime.pendingThrow) {
    runtime.popTempRoot();
    return undefinedValue();
  }
  runtime.pushTempRoot(settled);
  const pass = runtime.newSharedHost(isReject ? HOST_THROW_BOUND : HOST_RETURN_BOUND, outcome, 0);
  let args = Array<Value>();
  args.push(cellValue(pass));
  const result = invokeThen(inout runtime, settled, move args);
  runtime.popTempRoot();
  runtime.popTempRoot();
  return result;
}

function finallyFulfilled(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return finallySettled(inout runtime, argsBase, argc, callee, false);
}

function finallyRejected(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return finallySettled(inout runtime, argsBase, argc, callee, true);
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
    return raiseType(inout runtime, in message);
  }
  const intrinsic = cellValue(runtime.promiseCtor);
  const ctor = runtime.speciesConstructor(thisValue, intrinsic);
  if (runtime.pendingThrow) return undefinedValue();
  const onFinally = runtime.argument(argsBase, argc, 0);
  let onFulfilled = onFinally;
  let onRejected = onFinally;
  if (runtime.isCallable(onFinally)) {
    const bound = runtime.heap.allocateArray(2);
    runtime.heap.setSlot(bound, 0, onFinally);
    runtime.heap.setSlot(bound, 1, ctor);
    onFulfilled = cellValue(runtime.newSharedHost(HOST_FINALLY_FULFILLED, cellValue(bound), 1));
    onRejected = cellValue(runtime.newSharedHost(HOST_FINALLY_REJECTED, cellValue(bound), 1));
  }
  let args = Array<Value>();
  args.push(onFulfilled);
  args.push(onRejected);
  return invokeThen(inout runtime, thisValue, move args);
}

// --- statics ---
//
// Each static builds its result from its receiver, not from
// Symbol.species: `Promise.all.call(C, ...)` constructs C.

function promiseResolveStatic(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (!runtime.isObjectLike(thisValue)) {
    const message: String = "Promise.resolve called on a non-object";
    return raiseType(inout runtime, in message);
  }
  return promiseResolveWith(inout runtime, thisValue, runtime.argument(argsBase, argc, 0));
}

function promiseRejectStatic(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const reason = runtime.argument(argsBase, argc, 0);
  if (isIntrinsicConstructor(inout runtime, thisValue)) {
    const promise = runtime.newPromise();
    runtime.rejectPromise(asCell(promise), reason);
    return promise;
  }
  const capability = newPromiseCapability(inout runtime, thisValue);
  if (capability == 0) return undefinedValue();
  runtime.pushTempRoot(cellValue(capability));
  const ignored = capabilitySettle(inout runtime, capability, reason, true);
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  return runtime.heap.slot(capability, 0);
}

function promiseWithResolvers(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const capability = newPromiseCapability(inout runtime, thisValue);
  if (capability == 0) return undefinedValue();
  const objectProto = runtime.objectProto;
  const result = runtime.heap.allocateObject(objectProto);
  const promiseText: String = "promise";
  const promiseAtom = runtime.atomOf(in promiseText);
  runtime.heap.objectDefine(result, promiseAtom, runtime.heap.slot(capability, 0), PROP_DEFAULT);
  const resolveText: String = "resolve";
  const resolveAtom = runtime.atomOf(in resolveText);
  runtime.heap.objectDefine(result, resolveAtom, runtime.heap.slot(capability, 1), PROP_DEFAULT);
  const rejectText: String = "reject";
  const rejectAtom = runtime.atomOf(in rejectText);
  runtime.heap.objectDefine(result, rejectAtom, runtime.heap.slot(capability, 2), PROP_DEFAULT);
  return cellValue(result);
}

// Promise.all / allSettled / any / race share one iteration. Each
// element is resolved through the receiver's own `resolve`, and its
// `then` is invoked with the functions the mode calls for: element
// functions the engine makes, or the capability's own resolve / reject.
// The aggregate is a heap array [values, remaining, capability, mode];
// an element function's bound data is [aggregate, index, called].
const AGG_ALL: i32 = 0;
const AGG_ALL_SETTLED: i32 = 1;
const AGG_ANY: i32 = 2;
const AGG_RACE: i32 = 3;

// Every element has reported. `all` and `allSettled` resolve with the
// values; `any` rejects with an AggregateError, which the loop raises
// (its caller rejects with whatever is pending) and an element function
// hands to reject itself.
function aggregateFinish(inout runtime: Runtime, aggregate: u32, fromLoop: boolean): Value {
  const mode = asInt32(runtime.heap.slot(aggregate, 3));
  const capability = asCell(runtime.heap.slot(aggregate, 2));
  const values = runtime.heap.slot(aggregate, 0);
  if (mode != AGG_ANY) return capabilitySettle(inout runtime, capability, values, false);
  const message: String = "All promises were rejected";
  const error = runtime.makeError(ERROR_KIND_AGGREGATE, bytesOf(in message));
  const errorsText: String = "errors";
  const errorsAtom = runtime.atomOf(in errorsText);
  runtime.heap.objectDefine(asCell(error), errorsAtom, values, PROP_METHOD);
  if (fromLoop) {
    runtime.raise(error);
    return undefinedValue();
  }
  return capabilitySettle(inout runtime, capability, error, true);
}

function elementSettled(inout runtime: Runtime, argsBase: u32, argc: u32, callee: u32, rejected: boolean): Value {
  const bound = asCell(runtime.heap.slot(callee, 0));
  if (isTrue(runtime.heap.slot(bound, 2))) return undefinedValue();
  runtime.heap.setSlot(bound, 2, booleanValue(true));
  const aggregate = asCell(runtime.heap.slot(bound, 0));
  const index = u32(asInt32(runtime.heap.slot(bound, 1)));
  const mode = asInt32(runtime.heap.slot(aggregate, 3));
  const values = asCell(runtime.heap.slot(aggregate, 0));
  const value = runtime.argument(argsBase, argc, 0);
  if (mode == AGG_ALL_SETTLED) {
    const objectProto = runtime.objectProto;
    const entry = runtime.heap.allocateObject(objectProto);
    const statusText: String = "status";
    const statusAtom = runtime.atomOf(in statusText);
    const labelText: String = rejected ? "rejected" : "fulfilled";
    const label = runtime.internText(in labelText);
    const keyText: String = rejected ? "reason" : "value";
    const keyAtom = runtime.atomOf(in keyText);
    runtime.heap.objectDefine(entry, statusAtom, label, PROP_DEFAULT);
    runtime.heap.objectDefine(entry, keyAtom, value, PROP_DEFAULT);
    runtime.heap.setSlot(values, index, cellValue(entry));
  } else {
    runtime.heap.setSlot(values, index, value);
  }
  const remaining = asInt32(runtime.heap.slot(aggregate, 1)) - 1;
  runtime.heap.setSlot(aggregate, 1, int32Value(remaining));
  if (remaining == 0) return aggregateFinish(inout runtime, aggregate, false);
  return undefinedValue();
}

function elementFulfilled(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return elementSettled(inout runtime, argsBase, argc, callee, false);
}

function elementRejected(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return elementSettled(inout runtime, argsBase, argc, callee, true);
}

function aggregate(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, mode: i32): Value {
  const capability = newPromiseCapability(inout runtime, thisValue);
  if (capability == 0) return undefinedValue();
  runtime.pushTempRoot(cellValue(capability));
  const record = runtime.heap.allocateArray(4);
  runtime.heap.setSlot(record, 0, cellValue(runtime.heap.allocateArray(0)));
  runtime.heap.setSlot(record, 1, int32Value(1));
  runtime.heap.setSlot(record, 2, cellValue(capability));
  runtime.heap.setSlot(record, 3, int32Value(mode));
  runtime.pushTempRoot(cellValue(record));
  const resolveText: String = "resolve";
  const resolveKey = runtime.internText(in resolveText);
  const promiseResolve = runtime.getProperty(thisValue, resolveKey);
  if (!runtime.pendingThrow && !runtime.isCallable(promiseResolve)) {
    const message: String = "Promise resolve is not a function";
    const ignored = raiseType(inout runtime, in message);
  }
  runtime.pushTempRoot(promiseResolve);
  let iterator = undefinedValue();
  if (!runtime.pendingThrow) iterator = runtime.getIterator(runtime.argument(argsBase, argc, 0));
  runtime.pushTempRoot(iterator);
  // Whether the iterator is finished with: it is closed on a throw only
  // while it is still mid-iteration.
  let exhausted = true;
  if (!runtime.pendingThrow) {
    exhausted = false;
    let index: u32 = 0;
    while (true) {
      const item = runtime.iteratorStep(iterator);
      if (runtime.pendingThrow || isDeleted(item)) {
        exhausted = true;
        break;
      }
      let resolveArgs = Array<Value>();
      resolveArgs.push(item);
      const element = runtime.callValue(promiseResolve, thisValue, move resolveArgs);
      if (runtime.pendingThrow) break;
      runtime.pushTempRoot(element);
      let onFulfilled = runtime.heap.slot(capability, 1);
      let onRejected = runtime.heap.slot(capability, 2);
      if (mode != AGG_RACE) {
        const values = asCell(runtime.heap.slot(record, 0));
        runtime.heap.arraySet(values, index, undefinedValue());
        runtime.heap.setSlot(record, 1, int32Value(asInt32(runtime.heap.slot(record, 1)) + 1));
        const bound = runtime.heap.allocateArray(3);
        runtime.heap.setSlot(bound, 0, cellValue(record));
        runtime.heap.setSlot(bound, 1, int32Value(i32(index)));
        runtime.heap.setSlot(bound, 2, booleanValue(false));
        if (mode != AGG_ANY) onFulfilled = cellValue(runtime.newSharedHost(HOST_ELEMENT_FULFILLED, cellValue(bound), 1));
        if (mode != AGG_ALL) onRejected = cellValue(runtime.newSharedHost(HOST_ELEMENT_REJECTED, cellValue(bound), 1));
      }
      let thenArgs = Array<Value>();
      thenArgs.push(onFulfilled);
      thenArgs.push(onRejected);
      const ignored = invokeThen(inout runtime, element, move thenArgs);
      runtime.popTempRoot();
      if (runtime.pendingThrow) break;
      index = index + 1;
    }
  }
  if (!runtime.pendingThrow && mode != AGG_RACE) {
    // The count taken before the loop is released: with nothing
    // outstanding, the result settles now.
    const remaining = asInt32(runtime.heap.slot(record, 1)) - 1;
    runtime.heap.setSlot(record, 1, int32Value(remaining));
    if (remaining == 0) {
      const ignored = aggregateFinish(inout runtime, record, true);
    }
  }
  if (runtime.pendingThrow) {
    // The throw rejects the result; an iterator still mid-iteration is
    // closed first, and the original throw stands whatever closing does.
    const thrown = runtime.takePending();
    runtime.pushTempRoot(thrown);
    if (!exhausted) {
      runtime.iteratorClose(iterator);
      if (runtime.pendingThrow) { const dropped = runtime.takePending(); }
    }
    const ignored = capabilitySettle(inout runtime, capability, thrown, true);
    runtime.popTempRoot();
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  return runtime.heap.slot(capability, 0);
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
  runtime.registerSharedHost(HOST_CAPABILITY_EXECUTOR, capabilityExecutor);
  runtime.registerSharedHost(HOST_RETURN_BOUND, returnBound);
  runtime.registerSharedHost(HOST_THROW_BOUND, throwBound);
  runtime.registerSharedHost(HOST_FINALLY_FULFILLED, finallyFulfilled);
  runtime.registerSharedHost(HOST_FINALLY_REJECTED, finallyRejected);
  runtime.registerSharedHost(HOST_ELEMENT_FULFILLED, elementFulfilled);
  runtime.registerSharedHost(HOST_ELEMENT_REJECTED, elementRejected);
  const objectProto = runtime.objectProto;
  runtime.promiseProto = runtime.heap.allocateObject(objectProto);
  const promiseProto = runtime.promiseProto;
  const promiseText: String = "Promise";
  const ctor = runtime.defineAllocatingConstructor(constructPromise, undefinedValue(), 1, in promiseText);
  runtime.promiseCtor = ctor;
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
