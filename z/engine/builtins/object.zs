// Object's static methods and the rest of its prototype: descriptors,
// keys, prototypes, extensibility.
import { thread } from "std/thread";
import { Value, undefinedValue, nullValue, booleanValue, int32Value, cellValue, asCell, isCell, isUndefined, isNull, isDeleted, isTrue } from "../value.zs";
import { Runtime, PropertyDescriptor, DescriptorInput, emptyDescriptorInput, absentProperty } from "../runtime.zs";
import { PROP_WRITABLE, PROP_ENUMERABLE, PROP_CONFIGURABLE, PROP_ACCESSOR, PROP_METHOD, PROP_DEFAULT } from "../heap.zs";

function requireObject(inout runtime: Runtime, value: Value, in method: String): boolean {
  if (runtime.isObjectLike(value)) return true;
  const message: String = `Object.${method} called on non-object`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return false;
}

// ToPropertyDescriptor: a descriptor object's fields, each optional.
function toDescriptorInput(inout runtime: Runtime, object: Value): DescriptorInput {
  let desc = emptyDescriptorInput();
  if (!runtime.isObjectLike(object)) {
    const message: String = "Property description must be an object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return desc;
  }
  const enumerableText: String = "enumerable";
  if (hasField(inout runtime, object, in enumerableText)) {
    desc.hasEnumerable = true;
    desc.enumerable = runtime.toBooleanValue(readField(inout runtime, object, in enumerableText));
  }
  if (runtime.pendingThrow) return desc;
  const configurableText: String = "configurable";
  if (hasField(inout runtime, object, in configurableText)) {
    desc.hasConfigurable = true;
    desc.configurable = runtime.toBooleanValue(readField(inout runtime, object, in configurableText));
  }
  if (runtime.pendingThrow) return desc;
  const valueText: String = "value";
  if (hasField(inout runtime, object, in valueText)) {
    desc.hasValue = true;
    desc.value = readField(inout runtime, object, in valueText);
  }
  if (runtime.pendingThrow) return desc;
  const writableText: String = "writable";
  if (hasField(inout runtime, object, in writableText)) {
    desc.hasWritable = true;
    desc.writable = runtime.toBooleanValue(readField(inout runtime, object, in writableText));
  }
  if (runtime.pendingThrow) return desc;
  const getText: String = "get";
  if (hasField(inout runtime, object, in getText)) {
    desc.hasGetter = true;
    desc.getter = readField(inout runtime, object, in getText);
    if (!isUndefined(desc.getter) && !runtime.isCallable(desc.getter)) {
      const message: String = "Getter must be a function";
      const error = runtime.typeError(in message);
      runtime.raise(error);
      return desc;
    }
  }
  if (runtime.pendingThrow) return desc;
  const setText: String = "set";
  if (hasField(inout runtime, object, in setText)) {
    desc.hasSetter = true;
    desc.setter = readField(inout runtime, object, in setText);
    if (!isUndefined(desc.setter) && !runtime.isCallable(desc.setter)) {
      const message: String = "Setter must be a function";
      const error = runtime.typeError(in message);
      runtime.raise(error);
      return desc;
    }
  }
  if (runtime.pendingThrow) return desc;
  if ((desc.hasGetter || desc.hasSetter) && (desc.hasValue || desc.hasWritable)) {
    const message: String = "Invalid property descriptor. Cannot both specify accessors and a value or writable attribute";
    const error = runtime.typeError(in message);
    runtime.raise(error);
  }
  return desc;
}

function hasField(inout runtime: Runtime, object: Value, in name: String): boolean {
  const key = runtime.internText(in name);
  return runtime.hasProperty(object, key);
}

function readField(inout runtime: Runtime, object: Value, in name: String): Value {
  const key = runtime.internText(in name);
  return runtime.getProperty(object, key);
}

// FromPropertyDescriptor: a fresh object describing the property.
function fromDescriptor(inout runtime: Runtime, desc: PropertyDescriptor): Value {
  if (!desc.present) return undefinedValue();
  const objectProto = runtime.objectProto;
  const result = runtime.heap.allocateObject(objectProto);
  if ((desc.attr & PROP_ACCESSOR) != 0) {
    const getText: String = "get";
    defineField(inout runtime, result, in getText, desc.getter);
    const setText: String = "set";
    defineField(inout runtime, result, in setText, desc.setter);
  } else {
    const valueText: String = "value";
    defineField(inout runtime, result, in valueText, desc.value);
    const writableText: String = "writable";
    defineField(inout runtime, result, in writableText, booleanValue((desc.attr & PROP_WRITABLE) != 0));
  }
  const enumerableText: String = "enumerable";
  defineField(inout runtime, result, in enumerableText, booleanValue((desc.attr & PROP_ENUMERABLE) != 0));
  const configurableText: String = "configurable";
  defineField(inout runtime, result, in configurableText, booleanValue((desc.attr & PROP_CONFIGURABLE) != 0));
  return cellValue(result);
}

function defineField(inout runtime: Runtime, object: u32, in name: String, value: Value): void {
  const atom = runtime.atomOf(in name);
  runtime.heap.objectSet(object, atom, value);
}

function objectDefineProperty(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  const method: String = "defineProperty";
  if (!requireObject(inout runtime, target, in method)) return undefinedValue();
  const key = runtime.argument(argsBase, argc, 1);
  const desc = toDescriptorInput(inout runtime, runtime.argument(argsBase, argc, 2));
  if (runtime.pendingThrow) return undefinedValue();
  if (!runtime.defineOwnProperty(target, key, desc)) {
    const message: String = "Cannot redefine property";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  return target;
}

function objectDefineProperties(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  const method: String = "defineProperties";
  if (!requireObject(inout runtime, target, in method)) return undefinedValue();
  const properties = runtime.argument(argsBase, argc, 1);
  if (!runtime.isObjectLike(properties)) {
    const message: String = "Property description must be an object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const keys = runtime.ownKeys(properties);
  let index: usize = 0;
  while (index < keys.length) {
    const key = keys[index];
    const own = runtime.getOwnDescriptor(properties, key);
    if (own.present && (own.attr & PROP_ENUMERABLE) != 0) {
      const descObject = runtime.getProperty(properties, key);
      if (runtime.pendingThrow) return undefinedValue();
      const desc = toDescriptorInput(inout runtime, descObject);
      if (runtime.pendingThrow) return undefinedValue();
      if (!runtime.defineOwnProperty(target, key, desc)) {
        const message: String = "Cannot redefine property";
        const error = runtime.typeError(in message);
        runtime.raise(error);
        return undefinedValue();
      }
    }
    index = index + 1;
  }
  return target;
}

function objectGetOwnPropertyDescriptor(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  if (isUndefined(target) || isNull(target)) {
    const message: String = "Cannot convert undefined or null to object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const key = runtime.argument(argsBase, argc, 1);
  const desc = runtime.getOwnDescriptor(target, key);
  if (runtime.pendingThrow) return undefinedValue();
  return fromDescriptor(inout runtime, desc);
}

function objectGetOwnPropertyDescriptors(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  const objectProto = runtime.objectProto;
  const result = runtime.heap.allocateObject(objectProto);
  const keys = runtime.ownKeys(target);
  let index: usize = 0;
  while (index < keys.length) {
    const key = keys[index];
    const desc = runtime.getOwnDescriptor(target, key);
    if (desc.present) {
      const atom = runtime.propertyKey(key);
      runtime.heap.objectSet(result, atom, fromDescriptor(inout runtime, desc));
    }
    index = index + 1;
  }
  return cellValue(result);
}

// keys / values / entries / getOwnPropertyNames share one walk.
const KEYS_NAMES: u32 = 0;
const KEYS_ENUMERABLE: u32 = 1;
const KEYS_VALUES: u32 = 2;
const KEYS_ENTRIES: u32 = 3;

function collectKeys(inout runtime: Runtime, argsBase: u32, argc: u32, mode: u32): Value {
  const target = runtime.argument(argsBase, argc, 0);
  if (isUndefined(target) || isNull(target)) {
    const message: String = "Cannot convert undefined or null to object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const result = runtime.heap.allocateArray(0);
  runtime.pushTempRoot(cellValue(result));
  const keys = runtime.ownKeys(target);
  let index: usize = 0;
  while (index < keys.length) {
    const key = keys[index];
    let take = mode == KEYS_NAMES;
    if (!take) {
      const desc = runtime.getOwnDescriptor(target, key);
      take = desc.present && (desc.attr & PROP_ENUMERABLE) != 0;
    }
    if (take) {
      let element = key;
      if (mode == KEYS_VALUES || mode == KEYS_ENTRIES) {
        const value = runtime.getProperty(target, key);
        if (runtime.pendingThrow) {
          runtime.popTempRoot();
          return undefinedValue();
        }
        if (mode == KEYS_VALUES) {
          element = value;
        } else {
          const pair = runtime.heap.allocateArray(2);
          runtime.heap.setSlot(pair, 0, key);
          runtime.heap.setSlot(pair, 1, value);
          element = cellValue(pair);
        }
      }
      const count = runtime.heap.arrayLength(result);
      runtime.heap.arraySet(result, count, element);
    }
    index = index + 1;
  }
  runtime.popTempRoot();
  return cellValue(result);
}

function objectKeys(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return collectKeys(inout runtime, argsBase, argc, KEYS_ENUMERABLE);
}
function objectValues(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return collectKeys(inout runtime, argsBase, argc, KEYS_VALUES);
}
function objectEntries(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return collectKeys(inout runtime, argsBase, argc, KEYS_ENTRIES);
}
function objectGetOwnPropertyNames(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return collectKeys(inout runtime, argsBase, argc, KEYS_NAMES);
}

function objectGetPrototypeOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  if (isUndefined(target) || isNull(target)) {
    const message: String = "Cannot convert undefined or null to object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const proto = runtime.protoOfValue(target);
  if (proto == 0) return nullValue();
  return cellValue(proto);
}

function objectSetPrototypeOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  const proto = runtime.argument(argsBase, argc, 1);
  if (!runtime.isObjectLike(proto) && !isNull(proto)) {
    const message: String = "Object prototype may only be an Object or null";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  if (!runtime.isObjectLike(target)) return target;
  const handle = asCell(target);
  if (!runtime.heap.isObject(handle)) return target;
  const wanted: u32 = isNull(proto) ? 0 : asCell(proto);
  if (runtime.heap.objectProto(handle) == wanted) return target;
  if (!runtime.isExtensible(target)) {
    const message: String = "Object is not extensible";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  // No cycles.
  let current = wanted;
  while (current != 0) {
    if (current == handle) {
      const message: String = "Cyclic __proto__ value";
      const error = runtime.typeError(in message);
      runtime.raise(error);
      return undefinedValue();
    }
    current = runtime.heap.objectProto(current);
  }
  runtime.heap.setObjectProto(handle, wanted);
  return target;
}

function objectCreate(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const proto = runtime.argument(argsBase, argc, 0);
  if (!runtime.isObjectLike(proto) && !isNull(proto)) {
    const message: String = "Object prototype may only be an Object or null";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const parent: u32 = isNull(proto) ? 0 : asCell(proto);
  const created = cellValue(runtime.heap.allocateObject(parent));
  const properties = runtime.argument(argsBase, argc, 1);
  if (isUndefined(properties)) return created;
  // Object.defineProperties(created, properties)
  runtime.pushTempRoot(created);
  const keys = runtime.ownKeys(properties);
  let index: usize = 0;
  while (index < keys.length) {
    const key = keys[index];
    const own = runtime.getOwnDescriptor(properties, key);
    if (own.present && (own.attr & PROP_ENUMERABLE) != 0) {
      const descObject = runtime.getProperty(properties, key);
      if (runtime.pendingThrow) {
        runtime.popTempRoot();
        return undefinedValue();
      }
      const desc = toDescriptorInput(inout runtime, descObject);
      if (runtime.pendingThrow) {
        runtime.popTempRoot();
        return undefinedValue();
      }
      runtime.defineOwnProperty(created, key, desc);
    }
    index = index + 1;
  }
  runtime.popTempRoot();
  return created;
}

function objectAssign(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  if (isUndefined(target) || isNull(target)) {
    const message: String = "Cannot convert undefined or null to object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  let sourceIndex: u32 = 1;
  while (sourceIndex < argc) {
    const source = runtime.argument(argsBase, argc, sourceIndex);
    if (!isUndefined(source) && !isNull(source)) {
      const keys = runtime.ownKeys(source);
      let index: usize = 0;
      while (index < keys.length) {
        const key = keys[index];
        const desc = runtime.getOwnDescriptor(source, key);
        if (desc.present && (desc.attr & PROP_ENUMERABLE) != 0) {
          const value = runtime.getProperty(source, key);
          if (runtime.pendingThrow) return undefinedValue();
          const accepted = runtime.setProperty(target, key, value);
          if (runtime.pendingThrow) return undefinedValue();
          if (!accepted) {
            const message: String = "Cannot assign to read only property";
            const error = runtime.typeError(in message);
            runtime.raise(error);
            return undefinedValue();
          }
        }
        index = index + 1;
      }
    }
    sourceIndex = sourceIndex + 1;
  }
  return target;
}

// freeze / seal / preventExtensions lock every own property to a degree.
function lockProperties(inout runtime: Runtime, target: Value, freeze: boolean): void {
  runtime.preventExtensions(target);
  const keys = runtime.ownKeys(target);
  let index: usize = 0;
  while (index < keys.length) {
    const key = keys[index];
    const desc = runtime.getOwnDescriptor(target, key);
    if (desc.present) {
      let change = emptyDescriptorInput();
      change.hasConfigurable = true;
      change.configurable = false;
      if (freeze && (desc.attr & PROP_ACCESSOR) == 0) {
        change.hasWritable = true;
        change.writable = false;
      }
      runtime.defineOwnProperty(target, key, change);
    }
    index = index + 1;
  }
}

function objectFreeze(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  if (runtime.isObjectLike(target)) lockProperties(inout runtime, target, true);
  return target;
}

function objectSeal(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  if (runtime.isObjectLike(target)) lockProperties(inout runtime, target, false);
  return target;
}

function objectPreventExtensions(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  runtime.preventExtensions(target);
  return target;
}

function objectIsExtensible(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return booleanValue(runtime.isExtensible(runtime.argument(argsBase, argc, 0)));
}

// isFrozen / isSealed: unextensible, and every own property locked.
function checkLocked(inout runtime: Runtime, target: Value, frozen: boolean): boolean {
  if (!runtime.isObjectLike(target)) return true;
  if (runtime.isExtensible(target)) return false;
  const keys = runtime.ownKeys(target);
  let index: usize = 0;
  while (index < keys.length) {
    const desc = runtime.getOwnDescriptor(target, keys[index]);
    if (desc.present) {
      if ((desc.attr & PROP_CONFIGURABLE) != 0) return false;
      if (frozen && (desc.attr & PROP_ACCESSOR) == 0 && (desc.attr & PROP_WRITABLE) != 0) return false;
    }
    index = index + 1;
  }
  return true;
}

function objectIsFrozen(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return booleanValue(checkLocked(inout runtime, runtime.argument(argsBase, argc, 0), true));
}

function objectIsSealed(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return booleanValue(checkLocked(inout runtime, runtime.argument(argsBase, argc, 0), false));
}

function objectIs(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return booleanValue(runtime.sameValue(runtime.argument(argsBase, argc, 0), runtime.argument(argsBase, argc, 1)));
}

function objectHasOwn(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const target = runtime.argument(argsBase, argc, 0);
  if (isUndefined(target) || isNull(target)) {
    const message: String = "Cannot convert undefined or null to object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  return booleanValue(runtime.hasOwnProperty(target, runtime.argument(argsBase, argc, 1)));
}

function objectFromEntries(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const entries = runtime.argument(argsBase, argc, 0);
  const objectProto = runtime.objectProto;
  const result = runtime.heap.allocateObject(objectProto);
  if (!isCell(entries) || asCell(entries) == 0 || !runtime.heap.isArray(asCell(entries))) {
    const message: String = "Object.fromEntries requires an array of entries";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const array = asCell(entries);
  const length = runtime.heap.arrayLength(array);
  let index: u32 = 0;
  while (index < length) {
    const pair = runtime.heap.arrayGet(array, index);
    const key = runtime.getProperty(pair, int32Value(0));
    if (runtime.pendingThrow) return undefinedValue();
    const value = runtime.getProperty(pair, int32Value(1));
    if (runtime.pendingThrow) return undefinedValue();
    const atom = runtime.propertyKey(key);
    runtime.heap.objectSet(result, atom, value);
    index = index + 1;
  }
  return cellValue(result);
}

function objectPropertyIsEnumerable(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const desc = runtime.getOwnDescriptor(thisValue, runtime.argument(argsBase, argc, 0));
  return booleanValue(desc.present && (desc.attr & PROP_ENUMERABLE) != 0);
}

export function installObject(inout runtime: Runtime): void {
  const objectSlot = runtime.globalSlot("Object");
  const ctorValue = runtime.globals[usize(objectSlot)].value;
  const ctor = asCell(ctorValue);
  const objectProto = runtime.objectProto;
  const definePropertyText: String = "defineProperty";
  runtime.defineMethod(ctor, in definePropertyText, objectDefineProperty, 3);
  const definePropertiesText: String = "defineProperties";
  runtime.defineMethod(ctor, in definePropertiesText, objectDefineProperties, 2);
  const getOwnPropertyDescriptorText: String = "getOwnPropertyDescriptor";
  runtime.defineMethod(ctor, in getOwnPropertyDescriptorText, objectGetOwnPropertyDescriptor, 2);
  const getOwnPropertyDescriptorsText: String = "getOwnPropertyDescriptors";
  runtime.defineMethod(ctor, in getOwnPropertyDescriptorsText, objectGetOwnPropertyDescriptors, 1);
  const getOwnPropertyNamesText: String = "getOwnPropertyNames";
  runtime.defineMethod(ctor, in getOwnPropertyNamesText, objectGetOwnPropertyNames, 1);
  const keysText: String = "keys";
  runtime.defineMethod(ctor, in keysText, objectKeys, 1);
  const valuesText: String = "values";
  runtime.defineMethod(ctor, in valuesText, objectValues, 1);
  const entriesText: String = "entries";
  runtime.defineMethod(ctor, in entriesText, objectEntries, 1);
  const getPrototypeOfText: String = "getPrototypeOf";
  runtime.defineMethod(ctor, in getPrototypeOfText, objectGetPrototypeOf, 1);
  const setPrototypeOfText: String = "setPrototypeOf";
  runtime.defineMethod(ctor, in setPrototypeOfText, objectSetPrototypeOf, 2);
  const createText: String = "create";
  runtime.defineMethod(ctor, in createText, objectCreate, 2);
  const assignText: String = "assign";
  runtime.defineMethod(ctor, in assignText, objectAssign, 2);
  const freezeText: String = "freeze";
  runtime.defineMethod(ctor, in freezeText, objectFreeze, 1);
  const sealText: String = "seal";
  runtime.defineMethod(ctor, in sealText, objectSeal, 1);
  const preventExtensionsText: String = "preventExtensions";
  runtime.defineMethod(ctor, in preventExtensionsText, objectPreventExtensions, 1);
  const isExtensibleText: String = "isExtensible";
  runtime.defineMethod(ctor, in isExtensibleText, objectIsExtensible, 1);
  const isFrozenText: String = "isFrozen";
  runtime.defineMethod(ctor, in isFrozenText, objectIsFrozen, 1);
  const isSealedText: String = "isSealed";
  runtime.defineMethod(ctor, in isSealedText, objectIsSealed, 1);
  const isText: String = "is";
  runtime.defineMethod(ctor, in isText, objectIs, 2);
  const hasOwnText: String = "hasOwn";
  runtime.defineMethod(ctor, in hasOwnText, objectHasOwn, 2);
  const fromEntriesText: String = "fromEntries";
  runtime.defineMethod(ctor, in fromEntriesText, objectFromEntries, 1);
  const propertyIsEnumerableText: String = "propertyIsEnumerable";
  runtime.defineMethod(objectProto, in propertyIsEnumerableText, objectPropertyIsEnumerable, 1);
}
