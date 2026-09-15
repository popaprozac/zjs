// The Error family and Object: the first builtins, and the ones the
// runtime's own errors depend on.
//
// Each constructor is a host function whose slot 0 holds its error kind,
// so one Z function serves the whole family. Error.prototype carries
// `name`, `message`, and `toString`; the subclasses' prototypes inherit
// from it with their own `name`.
import { Value, undefinedValue, booleanValue, cellValue, asCell, isCell, isUndefined, isInt32, asInt32, int32Value, isNumber } from "../value.zs";
import { thread } from "std/thread";
import { Runtime, ERROR_KIND_ERROR, ERROR_KIND_COUNT, errorKindName } from "../runtime.zs";
import { bytesOf, PROP_METHOD, PROP_NONE } from "../heap.zs";

// new Error(message) / Error(message): the object under construction
// arrives as `this`; a plain call makes its own.
function constructError(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const kind = u32(asInt32(runtime.heap.slot(callee, 0)));
  let object: u32 = 0;
  if (isCell(thisValue) && asCell(thisValue) != 0 && runtime.heap.isObject(asCell(thisValue))) {
    object = asCell(thisValue);
  } else {
    object = runtime.heap.allocateObject(runtime.errorPrototype(kind));
  }
  const first = runtime.argument(argsBase, argc, 0);
  if (!isUndefined(first)) {
    const message = runtime.toStringValue(first);
    if (runtime.pendingThrow) return undefinedValue();
    const atomMessage = runtime.atomMessage;
    runtime.heap.objectSet(object, atomMessage, message);
  }
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
  let nameBytes = Array<u8>();
  if (isUndefined(name)) {
    const fallback: String = "Error";
    nameBytes = bytesOf(in fallback);
  } else {
    const text = runtime.toStringValue(name);
    if (runtime.pendingThrow) return undefinedValue();
    nameBytes = runtime.heap.stringBytes(asCell(text));
  }
  let messageBytes = Array<u8>();
  if (!isUndefined(message)) {
    const text = runtime.toStringValue(message);
    if (runtime.pendingThrow) return undefinedValue();
    messageBytes = runtime.heap.stringBytes(asCell(text));
  }
  if (nameBytes.length == 0) return runtime.newString(move messageBytes);
  if (messageBytes.length == 0) return runtime.newString(move nameBytes);
  let joined = move nameBytes;
  joined.push(58);
  joined.push(32);
  let index: usize = 0;
  while (index < messageBytes.length) {
    joined.push(messageBytes[index]);
    index = index + 1;
  }
  return runtime.newString(move joined);
}

// Object(value): the value itself when it is already an object, else a
// fresh empty object (primitives are not wrapped yet).
function constructObject(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const first = runtime.argument(argsBase, argc, 0);
  if (runtime.isObjectLike(first)) return first;
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
    tag = "Array";
  } else if (runtime.isStringValue(thisValue)) {
    tag = "String";
  } else if (isNumber(thisValue)) {
    tag = "Number";
  } else if (thisValue.bits == 6 || thisValue.bits == 7) {
    tag = "Boolean";
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
  const head: String = "[object ";
  let text = bytesOf(in head);
  const tagBytes = bytesOf(in tag);
  let index: usize = 0;
  while (index < tagBytes.length) {
    text.push(tagBytes[index]);
    index = index + 1;
  }
  text.push(93);
  return runtime.newString(move text);
}

function objectValueOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return thisValue;
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
  const hasOwnText: String = "hasOwnProperty";
  runtime.defineMethod(objectProto, in hasOwnText, objectHasOwnProperty, 1);
  const isProtoText: String = "isPrototypeOf";
  runtime.defineMethod(objectProto, in isProtoText, objectIsPrototypeOf, 1);

  // Error, then the subclasses whose prototypes inherit from its.
  let errorProto: u32 = 0;
  let kind: u32 = 0;
  while (kind < ERROR_KIND_COUNT) {
    const kindName = errorKindName(kind);
    const ctor = runtime.defineConstructor(constructError, int32Value(i32(kind)), 1, in kindName);
    const parent: u32 = kind == ERROR_KIND_ERROR ? objectProto : errorProto;
    const proto = runtime.heap.allocateObject(parent);
    if (kind == ERROR_KIND_ERROR) errorProto = proto;
    const nameValue = runtime.internText(in kindName);
    const atomName = runtime.atomName;
    runtime.defineOwnAttr(proto, atomName, nameValue, PROP_METHOD);
    const emptyMessage = runtime.internValue(Array<u8>());
    const atomMessage = runtime.atomMessage;
    runtime.defineOwnAttr(proto, atomMessage, emptyMessage, PROP_METHOD);
    runtime.defineOwnAttr(proto, atomConstructor, cellValue(ctor), PROP_METHOD);
    if (kind == ERROR_KIND_ERROR) runtime.defineMethod(proto, in toStringText, errorToString, 0);
    runtime.heap.setLink(ctor, proto);
    runtime.setGlobal(errorKindName(kind), cellValue(ctor));
    kind = kind + 1;
  }
}
