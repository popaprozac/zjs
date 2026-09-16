// The Error family and Object: the first builtins, and the ones the
// runtime's own errors depend on.
//
// Each constructor is a host function whose slot 0 holds its error kind,
// so one Z function serves the whole family. Error.prototype carries
// `name`, `message`, and `toString`; the subclasses' prototypes inherit
// from it with their own `name`.
import { Value, undefinedValue, booleanValue, cellValue, asCell, isCell, isUndefined, isInt32, asInt32, int32Value, isNumber } from "../value.zs";
import { thread } from "std/thread";
import { Runtime, ERROR_KIND_ERROR, ERROR_KIND_AGGREGATE, ERROR_KIND_COUNT, errorKindName } from "../runtime.zs";
import { bytesOf, PROP_METHOD, PROP_NONE, PROP_DEFAULT, PROP_WRITABLE, PROP_CONFIGURABLE, PROP_ACCESSOR } from "../heap.zs";
import { unitsOf, appendText } from "../text.zs";

// new Error(message) / Error(message): the object under construction
// arrives as `this`; a plain call makes its own.
// Error(message, options) and the native errors; AggregateError(errors,
// message, options) takes its iterable first and keeps it as `errors`.
// An `options` object with a `cause` gives the error a `cause`.
function constructError(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const kind = u32(asInt32(runtime.heap.slot(callee, 0)));
  let object: u32 = 0;
  if (isCell(thisValue) && asCell(thisValue) != 0 && runtime.heap.isObject(asCell(thisValue))) {
    object = asCell(thisValue);
  } else {
    object = runtime.heap.allocateObject(runtime.errorPrototype(kind));
  }
  runtime.pushTempRoot(cellValue(object));
  runtime.markErrorData(object);
  const aggregate = kind == ERROR_KIND_AGGREGATE;
  const messageIndex: u32 = aggregate ? 1 : 0;
  const first = runtime.argument(argsBase, argc, messageIndex);
  if (!isUndefined(first)) {
    const message = runtime.toStringValue(first);
    if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
    const atomMessage = runtime.atomMessage;
    runtime.heap.objectDefine(object, atomMessage, message, PROP_METHOD);
  }
  const options = runtime.argument(argsBase, argc, messageIndex + 1);
  if (runtime.isObjectLike(options)) {
    const causeText: String = "cause";
    const causeKey = runtime.internText(in causeText);
    const hasCause = runtime.hasProperty(options, causeKey);
    if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
    if (hasCause) {
      const cause = runtime.getProperty(options, causeKey);
      if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
      const causeAtom = runtime.atomOf(in causeText);
      runtime.heap.objectDefine(object, causeAtom, cause, PROP_METHOD);
    }
  }
  if (aggregate) {
    const errors = runtime.iterateToArray(runtime.argument(argsBase, argc, 0));
    if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
    const errorsText: String = "errors";
    const errorsAtom = runtime.atomOf(in errorsText);
    runtime.heap.objectDefine(object, errorsAtom, errors, PROP_METHOD);
  }
  runtime.popTempRoot();
  return cellValue(object);
}

// Error.prototype.toString: "<name>: <message>", either side optional.
function errorToString(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (!runtime.isObjectLike(thisValue)) {
    const message: String = "Error.prototype.toString called on a non-object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const nameKey = cellValue(runtime.atomName);
  let name = runtime.getProperty(thisValue, nameKey);
  if (runtime.pendingThrow) return undefinedValue();
  const messageKey = cellValue(runtime.atomMessage);
  let message = runtime.getProperty(thisValue, messageKey);
  if (runtime.pendingThrow) return undefinedValue();
  let nameBytes = Array<u16>();
  if (isUndefined(name)) {
    const fallback: String = "Error";
    nameBytes = unitsOf(in fallback);
  } else {
    const text = runtime.toStringValue(name);
    if (runtime.pendingThrow) return undefinedValue();
    nameBytes = runtime.heap.stringUnits(asCell(text));
  }
  let messageBytes = Array<u16>();
  if (!isUndefined(message)) {
    const text = runtime.toStringValue(message);
    if (runtime.pendingThrow) return undefinedValue();
    messageBytes = runtime.heap.stringUnits(asCell(text));
  }
  if (nameBytes.length == 0) return runtime.newStringUnits(move messageBytes);
  if (messageBytes.length == 0) return runtime.newStringUnits(move nameBytes);
  let joined = move nameBytes;
  joined.push(58);
  joined.push(32);
  let index: usize = 0;
  while (index < messageBytes.length) {
    joined.push(messageBytes[index]);
    index = index + 1;
  }
  return runtime.newStringUnits(move joined);
}

// Object(value): the value itself when it is already an object, a
// wrapper for a primitive, else a fresh empty object.
function constructObject(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const first = runtime.argument(argsBase, argc, 0);
  if (runtime.isObjectLike(first)) return first;
  const proto = runtime.primitiveProto(first);
  if (proto != 0) return runtime.wrapPrimitive(first, proto);
  if (runtime.isObjectLike(thisValue)) return thisValue;
  const objectProto = runtime.objectProto;
  return cellValue(runtime.heap.allocateObject(objectProto));
}

// Object.prototype.toString: "[object <Tag>]" from the value's kind.
function objectToString(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  let tag: String = "Object";
  if (isUndefined(thisValue)) {
    tag = "Undefined";
  } else if (thisValue.bits == 2) {
    tag = "Null";
  } else if (runtime.isCallable(thisValue)) {
    tag = "Function";
  } else if (isCell(thisValue) && asCell(thisValue) != 0 && runtime.heap.isArray(asCell(thisValue))) {
    tag = runtime.isArgumentsObject(asCell(thisValue)) ? "Arguments" : "Array";
  } else if (runtime.isStringValue(thisValue)) {
    tag = "String";
  } else if (isNumber(thisValue)) {
    tag = "Number";
  } else if (thisValue.bits == 6 || thisValue.bits == 7) {
    tag = "Boolean";
  } else if (runtime.isDateObject(thisValue)) {
    tag = "Date";
  } else if (runtime.isRegExpObject(thisValue)) {
    tag = "RegExp";
  } else if (runtime.isObjectLike(thisValue)) {
    // A wrapper announces its primitive; an error object its inherited
    // brand.
    let wrapped = undefinedValue();
    if (runtime.heap.isObject(asCell(thisValue))) wrapped = runtime.wrappedPrimitive(asCell(thisValue));
    if (isNumber(wrapped)) {
      tag = "Number";
    } else if (runtime.isStringValue(wrapped)) {
      tag = "String";
    } else if (wrapped.bits == 6 || wrapped.bits == 7) {
      tag = "Boolean";
    } else {
      const errorProto = runtime.errorPrototype(ERROR_KIND_ERROR);
      let current = runtime.heap.objectProto(asCell(thisValue));
      while (current != 0) {
        if (current == errorProto) tag = "Error";
        current = runtime.heap.objectProto(current);
      }
    }
  }
  // An own or inherited @@toStringTag string overrides the builtin tag.
  let tagBytes = unitsOf(in tag);
  if (runtime.isObjectLike(thisValue) || runtime.isSymbolValue(thisValue) || isNumber(thisValue) || runtime.isStringValue(thisValue) || thisValue.bits == 6 || thisValue.bits == 7) {
    const tagKey = runtime.symbolToStringTag;
    const custom = runtime.getProperty(thisValue, tagKey);
    if (runtime.pendingThrow) return undefinedValue();
    if (runtime.isStringValue(custom)) tagBytes = runtime.heap.stringUnits(asCell(custom));
  }
  const head: String = "[object ";
  let text = unitsOf(in head);
  let index: usize = 0;
  while (index < tagBytes.length) {
    text.push(tagBytes[index]);
    index = index + 1;
  }
  text.push(93);
  return runtime.newStringUnits(move text);
}

function objectValueOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return thisValue;
}

// Object.prototype.toLocaleString: this.toString()
function objectToLocaleString(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (isUndefined(thisValue) || thisValue.bits == 2) {
    const message: String = "Object.prototype.toLocaleString called on null or undefined";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const toStringText: String = "toString";
  const key = runtime.internText(in toStringText);
  const method = runtime.getProperty(thisValue, key);
  if (runtime.pendingThrow) return undefinedValue();
  return runtime.callValue(method, thisValue, Array<Value>());
}

// Object.prototype.hasOwnProperty
function objectHasOwnProperty(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const key = runtime.argument(argsBase, argc, 0);
  return booleanValue(runtime.hasOwnProperty(thisValue, key));
}

// Object.prototype.isPrototypeOf
function objectIsPrototypeOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const candidate = runtime.argument(argsBase, argc, 0);
  if (!runtime.isObjectLike(thisValue) || !runtime.isObjectLike(candidate)) return booleanValue(false);
  let current = runtime.protoOfValue(candidate);
  while (current != 0) {
    if (current == asCell(thisValue)) return booleanValue(true);
    current = runtime.heap.objectProto(current);
  }
  return booleanValue(false);
}

// --- Error.prototype.stack ---
//
// An accessor on Error.prototype. The getter renders an error instance
// (any object carrying error data, whatever its prototype) and yields
// undefined for other objects; the setter stores a plain own `stack` on
// the receiver, or updates a writable one it already has.
function errorStackGet(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (!runtime.isObjectLike(thisValue)) {
    const message: String = "Error.prototype.stack getter called on a non-object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  if (!runtime.hasErrorData(thisValue)) return undefinedValue();
  const head = errorToString(inout runtime, thisValue, argsBase, argc, callee);
  if (runtime.pendingThrow) return undefinedValue();
  let text = runtime.heap.stringUnits(asCell(head));
  const frame: String = "\n    at <anonymous>";
  appendText(inout text, in frame);
  return runtime.newStringUnits(move text);
}

function errorStackSet(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (!runtime.isObjectLike(thisValue)) {
    const message: String = "Error.prototype.stack setter called on a non-object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  if (argc == 0) {
    const message: String = "Error.prototype.stack setter requires a value";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const value = runtime.argument(argsBase, argc, 0);
  if (!runtime.isStringValue(value)) {
    const message: String = "Error.prototype.stack setter requires a string";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const stackText: String = "stack";
  const atomStack = runtime.atomOf(in stackText);
  const handle = asCell(thisValue);
  const target = runtime.definitionTarget(handle, atomStack);
  if (target == 0) {
    const message: String = "Cannot set property stack";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const current = runtime.ownSlotDescriptor(target, atomStack);
  if (!current.present) {
    if (!runtime.isExtensible(thisValue)) {
      const message: String = "Cannot define property stack, object is not extensible";
      const error = runtime.typeError(in message);
      runtime.raise(error);
      return undefinedValue();
    }
    runtime.defineOwnAttr(target, atomStack, value, PROP_DEFAULT);
    return undefinedValue();
  }
  if ((current.attr & PROP_ACCESSOR) != 0) {
    // An own accessor takes the value through its own setter; the
    // receiver holding this very accessor (Error.prototype) rejects.
    const ownSetter = current.setter;
    if (!runtime.isCallable(ownSetter) || asCell(ownSetter) == callee) {
      const message: String = "Cannot set property stack, which has only a getter";
      const error = runtime.typeError(in message);
      runtime.raise(error);
      return undefinedValue();
    }
    let args = Array<Value>();
    args.push(value);
    const ignored = runtime.callValue(ownSetter, thisValue, move args);
    return undefinedValue();
  }
  if ((current.attr & PROP_WRITABLE) == 0) {
    const message: String = "Cannot assign to read only property 'stack'";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  runtime.defineOwnAttr(target, atomStack, value, current.attr);
  return undefinedValue();
}

export function installErrors(inout runtime: Runtime): void {
  // Object first: its prototype is the root every object inherits.
  const objectProto = runtime.objectProto;
  const objectText: String = "Object";
  const objectCtor = runtime.defineConstructor(constructObject, undefinedValue(), 1, in objectText);
  runtime.heap.setLink(objectCtor, objectProto);
  const atomConstructor = runtime.atomConstructor;
  runtime.defineOwnAttr(objectProto, atomConstructor, cellValue(objectCtor), PROP_METHOD);
  runtime.setGlobal("Object", cellValue(objectCtor));
  const toStringText: String = "toString";
  runtime.defineMethod(objectProto, in toStringText, objectToString, 0);
  const valueOfText: String = "valueOf";
  runtime.defineMethod(objectProto, in valueOfText, objectValueOf, 0);
  const toLocaleStringText: String = "toLocaleString";
  runtime.defineMethod(objectProto, in toLocaleStringText, objectToLocaleString, 0);
  const hasOwnText: String = "hasOwnProperty";
  runtime.defineMethod(objectProto, in hasOwnText, objectHasOwnProperty, 1);
  const isProtoText: String = "isPrototypeOf";
  runtime.defineMethod(objectProto, in isProtoText, objectIsPrototypeOf, 1);

  // Error, then the subclasses whose prototypes inherit from its.
  let errorProto: u32 = 0;
  let errorCtor: u32 = 0;
  let kind: u32 = 0;
  while (kind < ERROR_KIND_COUNT) {
    const kindName = errorKindName(kind);
    const ctor = runtime.defineConstructor(constructError, int32Value(i32(kind)), kind == ERROR_KIND_AGGREGATE ? 2 : 1, in kindName);
    const parent: u32 = kind == ERROR_KIND_ERROR ? objectProto : errorProto;
    if (kind == ERROR_KIND_ERROR) {
      errorCtor = ctor;
    } else {
      // A native error constructor inherits from Error itself.
      const atomFunctionProto = runtime.atomFunctionProto;
      runtime.setFunctionHidden(ctor, atomFunctionProto, cellValue(errorCtor));
    }
    const proto = runtime.heap.allocateObject(parent);
    if (kind == ERROR_KIND_ERROR) errorProto = proto;
    const nameValue = runtime.internText(in kindName);
    const atomName = runtime.atomName;
    runtime.defineOwnAttr(proto, atomName, nameValue, PROP_METHOD);
    const emptyMessage = runtime.internLatin1Value(Array<u8>());
    const atomMessage = runtime.atomMessage;
    runtime.defineOwnAttr(proto, atomMessage, emptyMessage, PROP_METHOD);
    runtime.defineOwnAttr(proto, atomConstructor, cellValue(ctor), PROP_METHOD);
    if (kind == ERROR_KIND_ERROR) runtime.defineMethod(proto, in toStringText, errorToString, 0);
    runtime.heap.setLink(ctor, proto);
    runtime.setGlobal(errorKindName(kind), cellValue(ctor));
    kind = kind + 1;
  }

  const getText: String = "get stack";
  const stackGetter = runtime.defineHostFunction(errorStackGet, undefinedValue(), 0, in getText);
  const setText: String = "set stack";
  const stackSetter = runtime.defineHostFunction(errorStackSet, undefinedValue(), 1, in setText);
  const stackAccessor = runtime.heap.allocateAccessor(cellValue(stackGetter), cellValue(stackSetter));
  const stackText: String = "stack";
  const atomStack = runtime.atomOf(in stackText);
  runtime.heap.objectDefine(errorProto, atomStack, cellValue(stackAccessor), PROP_CONFIGURABLE | PROP_ACCESSOR);
}
