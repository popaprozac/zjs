// Reflect: the object internal methods as functions.
import { thread } from "std/thread";
import { Value, undefinedValue, nullValue, booleanValue, int32Value, cellValue, asCell, isCell, isUndefined, isNull } from "../value.zs";
import { Runtime, emptyDescriptorInput } from "../runtime.zs";
import { PROP_METHOD, PROP_ENUMERABLE, PROP_WRITABLE, PROP_CONFIGURABLE, PROP_ACCESSOR } from "../heap.zs";

function requireTarget(inout runtime: Runtime, value: Value, in method: String): boolean {
  if (runtime.isObjectLike(value)) return true;
  const message: String = `Reflect.${method} called on non-object`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return false;
}

// CreateListFromArrayLike
function argumentList(inout runtime: Runtime, list: Value): Array<Value> {
  let args = Array<Value>();
  if (!runtime.isObjectLike(list)) {
    const message: String = "CreateListFromArrayLike called on non-object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return args;
  }
  const lengthKey = cellValue(runtime.atomLength);
  const lengthValue = runtime.getProperty(list, lengthKey);
  if (runtime.pendingThrow) return args;
  const length = runtime.toLength(lengthValue);
  if (runtime.pendingThrow) return args;
  let index: u32 = 0;
  while (index < length) {
    const element = runtime.getProperty(list, int32Value(i32(index)));
    if (runtime.pendingThrow) return args;
    args.push(element);
    index = index + 1;
  }
  return args;
}

function reflectApply(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  if (!runtime.isCallable(target)) {
    const message: String = "Reflect.apply target is not a function";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const receiver = runtime.argument(argsBase, argc, 1);
  const args = argumentList(inout runtime, runtime.argument(argsBase, argc, 2));
  if (runtime.pendingThrow) return undefinedValue();
  return runtime.callValue(target, receiver, move args);
}

function reflectConstruct(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  if (!runtime.isConstructorValue(target)) {
    const message: String = "Reflect.construct target is not a constructor";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  let newTarget = target;
  if (argc > 2) newTarget = runtime.argument(argsBase, argc, 2);
  if (!runtime.isConstructorValue(newTarget)) {
    const message: String = "Reflect.construct newTarget is not a constructor";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const args = argumentList(inout runtime, runtime.argument(argsBase, argc, 1));
  if (runtime.pendingThrow) return undefinedValue();
  return runtime.constructValue(target, move args, newTarget);
}

function reflectOwnKeys(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  const method: String = "ownKeys";
  if (!requireTarget(inout runtime, target, in method)) return undefinedValue();
  const keys = runtime.ownKeys(target);
  const result = runtime.heap.allocateArray(u32(keys.length));
  let index: usize = 0;
  while (index < keys.length) {
    const key = keys[index];
    runtime.heap.setSlot(result, u32(index), key);
    index = index + 1;
  }
  return cellValue(result);
}

function reflectGetPrototypeOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  const method: String = "getPrototypeOf";
  if (!requireTarget(inout runtime, target, in method)) return undefinedValue();
  const proto = runtime.protoOfValue(target);
  if (proto == 0) return nullValue();
  return cellValue(proto);
}

function reflectHas(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  const method: String = "has";
  if (!requireTarget(inout runtime, target, in method)) return undefinedValue();
  return booleanValue(runtime.hasProperty(target, runtime.argument(argsBase, argc, 1)));
}

function reflectGet(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  const method: String = "get";
  if (!requireTarget(inout runtime, target, in method)) return undefinedValue();
  return runtime.getProperty(target, runtime.argument(argsBase, argc, 1));
}

function reflectSet(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  const method: String = "set";
  if (!requireTarget(inout runtime, target, in method)) return undefinedValue();
  const accepted = runtime.setProperty(target, runtime.argument(argsBase, argc, 1), runtime.argument(argsBase, argc, 2));
  if (runtime.pendingThrow) return undefinedValue();
  return booleanValue(accepted);
}

function reflectDeleteProperty(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  const method: String = "deleteProperty";
  if (!requireTarget(inout runtime, target, in method)) return undefinedValue();
  return booleanValue(runtime.deleteProperty(target, runtime.argument(argsBase, argc, 1)));
}

function reflectIsExtensible(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  const method: String = "isExtensible";
  if (!requireTarget(inout runtime, target, in method)) return undefinedValue();
  return booleanValue(runtime.isExtensible(target));
}

function reflectPreventExtensions(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  const method: String = "preventExtensions";
  if (!requireTarget(inout runtime, target, in method)) return undefinedValue();
  runtime.preventExtensions(target);
  return booleanValue(true);
}

export function installReflect(inout runtime: Runtime): void {
  const objectProto = runtime.objectProto;
  const reflect = runtime.heap.allocateObject(objectProto);
  runtime.setGlobal("Reflect", cellValue(reflect));
  const applyText: String = "apply"; runtime.defineMethod(reflect, in applyText, reflectApply, 3);
  const constructText: String = "construct"; runtime.defineMethod(reflect, in constructText, reflectConstruct, 2);
  const ownKeysText: String = "ownKeys"; runtime.defineMethod(reflect, in ownKeysText, reflectOwnKeys, 1);
  const getPrototypeOfText: String = "getPrototypeOf"; runtime.defineMethod(reflect, in getPrototypeOfText, reflectGetPrototypeOf, 1);
  const hasText: String = "has"; runtime.defineMethod(reflect, in hasText, reflectHas, 2);
  const getText: String = "get"; runtime.defineMethod(reflect, in getText, reflectGet, 2);
  const setText: String = "set"; runtime.defineMethod(reflect, in setText, reflectSet, 3);
  const deletePropertyText: String = "deleteProperty"; runtime.defineMethod(reflect, in deletePropertyText, reflectDeleteProperty, 2);
  const isExtensibleText: String = "isExtensible"; runtime.defineMethod(reflect, in isExtensibleText, reflectIsExtensible, 1);
  const preventExtensionsText: String = "preventExtensions"; runtime.defineMethod(reflect, in preventExtensionsText, reflectPreventExtensions, 1);
}
