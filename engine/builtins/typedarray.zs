// ArrayBuffer, DataView, and the typed arrays (ECMA-262 25.1, 25.3, and
// 23.2), installed by installTypedArrays: zjs_new_context installs them, a
// core context when zjs_install_typed_arrays asks.
//
// An ArrayBuffer, a typed array, and a DataView are ordinary objects with
// FLAG_BINARY,
// made with a class whose leading slots hold their internal data
// (runtime.zs, Binary data); a typed array's elements are reached through
// the runtime's property operations, which ask the runtime for the
// element when the key is a canonical numeric string. The bytes live in a
// TAG_BYTES cell the buffer holds; detaching drops the cell.
//
// Not here yet: resizable buffers, Float16Array, and the BigInt element
// kinds.
import { thread } from "std/thread";
import { Value, undefinedValue, nullValue, booleanValue, int32Value, cellValue, asCell, isCell, isUndefined, isNull, isDeleted, isNumber, asInt32 } from "../value.zs";
import { Runtime, HostFunction, toNumber, truncateDouble, isIntegralDouble, binaryNumber, elementSize, FEATURE_TYPED_ARRAYS, BINARY_BUFFER, BINARY_TYPED, BINARY_VIEW, ELEMENT_INT8, ELEMENT_UINT8, ELEMENT_UINT8_CLAMPED, ELEMENT_INT16, ELEMENT_UINT16, ELEMENT_INT32, ELEMENT_UINT32, ELEMENT_FLOAT32, ELEMENT_FLOAT64 } from "../runtime.zs";
import { PROP_METHOD, PROP_NONE, PROP_CONFIGURABLE, PROP_ACCESSOR, FLAG_BINARY } from "../heap.zs";
import { defineSpecies } from "./collections.zs";
import { textBuilder, putByte, putString, finishText } from "./builder.zs";

// The most bytes an ArrayBuffer holds. A larger one is a RangeError, as
// CreateByteDataBlock allows, rather than an allocation the process cannot
// survive (the engine has no fallible allocation).
const MAX_BYTE_LENGTH: f64 = 2147483647.0;
const ELEMENT_KINDS: i32 = 9;
// 2^53 - 1, the largest index ToIndex accepts.
const MAX_INDEX: f64 = 9007199254740991.0;

// The kind's name in DataView's methods: getInt8 ... getFloat64.
function viewKindName(kind: i32): String {
  if (kind == ELEMENT_INT8) return "Int8";
  if (kind == ELEMENT_UINT8) return "Uint8";
  if (kind == ELEMENT_INT16) return "Int16";
  if (kind == ELEMENT_UINT16) return "Uint16";
  if (kind == ELEMENT_INT32) return "Int32";
  if (kind == ELEMENT_UINT32) return "Uint32";
  if (kind == ELEMENT_FLOAT32) return "Float32";
  return "Float64";
}

function elementName(kind: i32): String {
  if (kind == ELEMENT_INT8) return "Int8Array";
  if (kind == ELEMENT_UINT8) return "Uint8Array";
  if (kind == ELEMENT_UINT8_CLAMPED) return "Uint8ClampedArray";
  if (kind == ELEMENT_INT16) return "Int16Array";
  if (kind == ELEMENT_UINT16) return "Uint16Array";
  if (kind == ELEMENT_INT32) return "Int32Array";
  if (kind == ELEMENT_UINT32) return "Uint32Array";
  if (kind == ELEMENT_FLOAT32) return "Float32Array";
  return "Float64Array";
}

function raiseType(inout runtime: Runtime, in message: String): Value {
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return undefinedValue();
}

function raiseRange(inout runtime: Runtime, in message: String): Value {
  const error = runtime.rangeError(in message);
  runtime.raise(error);
  return undefinedValue();
}

// ToIntegerOrInfinity.
function toIntegerOrInfinity(inout runtime: Runtime, value: Value): f64 {
  const number = runtime.toNumberValue(value);
  if (runtime.pendingThrow || number != number) return 0.0;
  const integer = truncateDouble(number);
  return integer == 0.0 ? 0.0 : integer;
}

// ToIndex: a RangeError past 0 .. 2^53 - 1.
function toIndex(inout runtime: Runtime, value: Value): f64 {
  if (isUndefined(value)) return 0.0;
  const integer = toIntegerOrInfinity(inout runtime, value);
  if (runtime.pendingThrow) return 0.0;
  if (integer < 0.0 || integer > MAX_INDEX) {
    const message: String = "Invalid index";
    raiseRange(inout runtime, in message);
    return 0.0;
  }
  return integer;
}

// GetPrototypeFromConstructor: new.target's `prototype` when it is an
// object, the intrinsic otherwise.
function protoFrom(inout runtime: Runtime, newTarget: Value, fallback: u32): u32 {
  const atomPrototype = runtime.atomPrototype;
  const held = runtime.getProperty(newTarget, cellValue(atomPrototype));
  if (runtime.pendingThrow) return 0;
  if (runtime.isObjectLike(held)) return asCell(held);
  return fallback;
}

// AllocateArrayBuffer: `byteLength` zero bytes.
function allocateBuffer(inout runtime: Runtime, proto: u32, byteLength: f64): Value {
  if (byteLength > MAX_BYTE_LENGTH) {
    const message: String = "Array buffer allocation failed";
    return raiseRange(inout runtime, in message);
  }
  const bufferClass = runtime.bufferClass;
  const object = runtime.heap.allocateObjectOfClass(proto, bufferClass);
  runtime.heap.setFlags(object, runtime.heap.flagsOf(object) | FLAG_BINARY);
  runtime.heap.setSlot(object, 0, int32Value(BINARY_BUFFER));
  const bytes = runtime.heap.allocateBytes(usize(byteLength));
  runtime.heap.setSlot(object, 1, cellValue(bytes));
  runtime.heap.setSlot(object, 2, binaryNumber(byteLength));
  return cellValue(object);
}

function bufferByteLength(in runtime: Runtime, buffer: u32): f64 {
  if (runtime.bufferBytes(buffer) == 0) return 0.0;
  return toNumber(runtime.binaryField(buffer, 2));
}

// `count` bytes from one buffer's bytes to another's.
function copyBytes(inout runtime: Runtime, source: u32, sourceAt: usize, target: u32, targetAt: usize, count: usize): void {
  let k: usize = 0;
  while (k < count) {
    const byte = runtime.heap.byteAt(source, sourceAt + k);
    runtime.heap.setByteAt(target, targetAt + k, byte);
    k = k + 1;
  }
}

// --- ArrayBuffer ---

function constructArrayBuffer(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const newTarget = runtime.takeHostNewTarget();
  if (isUndefined(newTarget)) {
    const message: String = "Constructor ArrayBuffer requires 'new'";
    return raiseType(inout runtime, in message);
  }
  const byteLength = toIndex(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const proto = protoFrom(inout runtime, newTarget, runtime.arrayBufferProto);
  if (runtime.pendingThrow) return undefinedValue();
  return allocateBuffer(inout runtime, proto, byteLength);
}

// `this` as an ArrayBuffer, or 0 and a TypeError.
function thisBuffer(inout runtime: Runtime, thisValue: Value, in method: String): u32 {
  if (runtime.isArrayBuffer(thisValue)) return asCell(thisValue);
  const message: String = `${method} called on an object that is not an ArrayBuffer`;
  raiseType(inout runtime, in message);
  return 0;
}

function bufferByteLengthGetter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "get ArrayBuffer.prototype.byteLength";
  const buffer = thisBuffer(inout runtime, thisValue, in method);
  if (buffer == 0) return undefinedValue();
  return binaryNumber(bufferByteLength(in runtime, buffer));
}

// A fixed-length buffer's most is its length.
function bufferMaxByteLength(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "get ArrayBuffer.prototype.maxByteLength";
  const buffer = thisBuffer(inout runtime, thisValue, in method);
  if (buffer == 0) return undefinedValue();
  return binaryNumber(bufferByteLength(in runtime, buffer));
}

function bufferResizable(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "get ArrayBuffer.prototype.resizable";
  const buffer = thisBuffer(inout runtime, thisValue, in method);
  if (buffer == 0) return undefinedValue();
  return booleanValue(false);
}

function bufferDetached(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "get ArrayBuffer.prototype.detached";
  const buffer = thisBuffer(inout runtime, thisValue, in method);
  if (buffer == 0) return undefinedValue();
  return booleanValue(runtime.bufferBytes(buffer) == 0);
}

// The relative index of slice: from the end when negative, clamped.
function relativeIndex(inout runtime: Runtime, value: Value, length: f64, fallback: f64): f64 {
  if (isUndefined(value)) return fallback;
  const relative = toIntegerOrInfinity(inout runtime, value);
  if (relative < 0.0) return relative + length < 0.0 ? 0.0 : relative + length;
  return relative < length ? relative : length;
}

function bufferSlice(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "ArrayBuffer.prototype.slice";
  const buffer = thisBuffer(inout runtime, thisValue, in method);
  if (buffer == 0) return undefinedValue();
  if (runtime.bufferBytes(buffer) == 0) {
    const message: String = "ArrayBuffer.prototype.slice called on a detached ArrayBuffer";
    return raiseType(inout runtime, in message);
  }
  const length = bufferByteLength(in runtime, buffer);
  const first = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 0), length, 0.0);
  if (runtime.pendingThrow) return undefinedValue();
  const last = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 1), length, length);
  if (runtime.pendingThrow) return undefinedValue();
  const newLength = last > first ? last - first : 0.0;
  const defaultCtor = cellValue(runtime.arrayBufferCtor);
  const ctor = runtime.speciesConstructor(thisValue, defaultCtor);
  if (runtime.pendingThrow) return undefinedValue();
  let args = Array<Value>();
  args.push(binaryNumber(newLength));
  const made = runtime.constructValue(ctor, move args, ctor);
  if (runtime.pendingThrow) return undefinedValue();
  if (!runtime.isArrayBuffer(made)) {
    const message: String = "ArrayBuffer subclass returned this from species constructor";
    return raiseType(inout runtime, in message);
  }
  const target = asCell(made);
  if (runtime.bufferBytes(target) == 0) {
    const message: String = "The species constructor made a detached ArrayBuffer";
    return raiseType(inout runtime, in message);
  }
  if (target == buffer) {
    const message: String = "The species constructor returned the same ArrayBuffer";
    return raiseType(inout runtime, in message);
  }
  if (bufferByteLength(in runtime, target) < newLength) {
    const message: String = "The species constructor made an ArrayBuffer too small";
    return raiseType(inout runtime, in message);
  }
  if (runtime.bufferBytes(buffer) == 0) {
    const message: String = "ArrayBuffer.prototype.slice: the ArrayBuffer was detached";
    return raiseType(inout runtime, in message);
  }
  const fromBytes = runtime.bufferBytes(buffer);
  const toBytes = runtime.bufferBytes(target);
  copyBytes(inout runtime, fromBytes, usize(first), toBytes, 0, usize(newLength));
  return made;
}

// ArrayBufferCopyAndDetach for a fixed-length buffer: the bytes go to a
// new buffer of the length asked (the same cell when it is the same
// length), and this one is detached.
function copyAndDetach(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, in method: String): Value {
  const buffer = thisBuffer(inout runtime, thisValue, in method);
  if (buffer == 0) return undefinedValue();
  const asked = runtime.argument(argsBase, argc, 0);
  let newLength = bufferByteLength(in runtime, buffer);
  if (!isUndefined(asked)) newLength = toIndex(inout runtime, asked);
  if (runtime.pendingThrow) return undefinedValue();
  const bytes = runtime.bufferBytes(buffer);
  if (bytes == 0) {
    const message: String = `${method} called on a detached ArrayBuffer`;
    return raiseType(inout runtime, in message);
  }
  const oldLength = bufferByteLength(in runtime, buffer);
  const arrayBufferProto = runtime.arrayBufferProto;
  let made = undefinedValue();
  if (newLength == oldLength) {
    const bufferClass = runtime.bufferClass;
    const object = runtime.heap.allocateObjectOfClass(arrayBufferProto, bufferClass);
    runtime.heap.setFlags(object, runtime.heap.flagsOf(object) | FLAG_BINARY);
    runtime.heap.setSlot(object, 0, int32Value(BINARY_BUFFER));
    runtime.heap.setSlot(object, 1, cellValue(bytes));
    runtime.heap.setSlot(object, 2, binaryNumber(oldLength));
    made = cellValue(object);
  } else {
    made = allocateBuffer(inout runtime, arrayBufferProto, newLength);
    if (runtime.pendingThrow) return undefinedValue();
    const kept = newLength < oldLength ? newLength : oldLength;
    const toBytes = runtime.bufferBytes(asCell(made));
    copyBytes(inout runtime, bytes, 0, toBytes, 0, usize(kept));
  }
  runtime.setBinaryField(buffer, 1, nullValue());
  runtime.setBinaryField(buffer, 2, int32Value(0));
  return made;
}

function bufferTransfer(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "ArrayBuffer.prototype.transfer";
  return copyAndDetach(inout runtime, thisValue, argsBase, argc, in method);
}

function bufferTransferToFixedLength(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "ArrayBuffer.prototype.transferToFixedLength";
  return copyAndDetach(inout runtime, thisValue, argsBase, argc, in method);
}

// A typed array or a DataView.
function bufferIsView(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const given = runtime.argument(argsBase, argc, 0);
  if (!isCell(given) || asCell(given) == 0) return booleanValue(false);
  const kind = runtime.binaryKind(asCell(given));
  return booleanValue(kind == BINARY_TYPED || kind == BINARY_VIEW);
}

// --- %TypedArray% ---

function constructTypedArrayAbstract(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const newTarget = runtime.takeHostNewTarget();
  const message: String = "Abstract class TypedArray not directly constructable";
  return raiseType(inout runtime, in message);
}

// A typed array of kind `kind` with no buffer yet: what AllocateTypedArray
// makes before it is given one.
function typedObject(inout runtime: Runtime, kind: i32, proto: u32): u32 {
  const typedClass = runtime.typedClass;
  const object = runtime.heap.allocateObjectOfClass(proto, typedClass);
  runtime.heap.setFlags(object, runtime.heap.flagsOf(object) | FLAG_BINARY);
  runtime.typedArraysMade = true;
  runtime.heap.setSlot(object, 0, int32Value(BINARY_TYPED));
  runtime.heap.setSlot(object, 1, nullValue());
  runtime.heap.setSlot(object, 2, int32Value(0));
  runtime.heap.setSlot(object, 3, int32Value(0));
  runtime.heap.setSlot(object, 4, int32Value(kind));
  return object;
}

// AllocateTypedArrayBuffer: a new buffer of `length` elements for it.
function giveBuffer(inout runtime: Runtime, object: u32, length: f64): boolean {
  const kind = runtime.typedElement(object);
  const byteLength = length * f64(elementSize(kind));
  const arrayBufferProto = runtime.arrayBufferProto;
  const buffer = allocateBuffer(inout runtime, arrayBufferProto, byteLength);
  if (runtime.pendingThrow) return false;
  runtime.setBinaryField(object, 1, buffer);
  runtime.setBinaryField(object, 2, int32Value(0));
  runtime.setBinaryField(object, 3, binaryNumber(length));
  return true;
}

// InitializeTypedArrayFromTypedArray.
function fromTypedArray(inout runtime: Runtime, object: u32, source: u32): boolean {
  if (runtime.bufferBytes(runtime.typedBuffer(source)) == 0) {
    const message: String = "Cannot construct from a typed array whose buffer is detached";
    raiseType(inout runtime, in message);
    return false;
  }
  const length = runtime.typedLength(source);
  if (!giveBuffer(inout runtime, object, length)) return false;
  const kind = runtime.typedElement(object);
  if (kind == runtime.typedElement(source)) {
    const size = usize(elementSize(kind));
    const fromBytes = runtime.bufferBytes(runtime.typedBuffer(source));
    const fromAt = usize(runtime.typedByteOffset(source));
    const toBytes = runtime.bufferBytes(runtime.typedBuffer(object));
    copyBytes(inout runtime, fromBytes, fromAt, toBytes, 0, usize(length) * size);
    return true;
  }
  let index: f64 = 0.0;
  while (index < length) {
    const value = runtime.typedRead(source, index);
    runtime.typedWrite(object, index, toNumber(value));
    index = index + 1.0;
  }
  return true;
}

// InitializeTypedArrayFromArrayBuffer.
function fromArrayBuffer(inout runtime: Runtime, object: u32, buffer: u32, byteOffset: Value, length: Value): boolean {
  const kind = runtime.typedElement(object);
  const size = f64(elementSize(kind));
  const name = elementName(kind);
  const offset = toIndex(inout runtime, byteOffset);
  if (runtime.pendingThrow) return false;
  if (offset - size * truncateDouble(offset / size) != 0.0) {
    const message: String = `Start offset of ${name} should be a multiple of its element size`;
    raiseRange(inout runtime, in message);
    return false;
  }
  let newLength: f64 = 0.0;
  if (!isUndefined(length)) newLength = toIndex(inout runtime, length);
  if (runtime.pendingThrow) return false;
  if (runtime.bufferBytes(buffer) == 0) {
    const message: String = `Cannot construct ${name} on a detached ArrayBuffer`;
    raiseType(inout runtime, in message);
    return false;
  }
  const available = bufferByteLength(in runtime, buffer);
  let byteLength: f64 = 0.0;
  if (isUndefined(length)) {
    if (available - size * truncateDouble(available / size) != 0.0) {
      const message: String = `Byte length of ${name} should be a multiple of its element size`;
      raiseRange(inout runtime, in message);
      return false;
    }
    byteLength = available - offset;
    if (byteLength < 0.0) {
      const message: String = "Start offset is outside the bounds of the buffer";
      raiseRange(inout runtime, in message);
      return false;
    }
  } else {
    byteLength = newLength * size;
    if (offset + byteLength > available) {
      const message: String = "Invalid typed array length";
      raiseRange(inout runtime, in message);
      return false;
    }
  }
  runtime.setBinaryField(object, 1, cellValue(buffer));
  runtime.setBinaryField(object, 2, binaryNumber(offset));
  runtime.setBinaryField(object, 3, binaryNumber(byteLength / size));
  return true;
}

// IteratorToList: what the iterator `method` makes of `source` gives, kept
// in a heap array, which roots it until the builtin returns. 0 with a
// throw pending.
function iterableToList(inout runtime: Runtime, source: Value, method: Value): u32 {
  const iteration = runtime.getIteratorFromMethod(source, method);
  if (runtime.pendingThrow) return 0;
  runtime.pushTempRoot(iteration);
  const list = runtime.heap.allocateArray(0);
  runtime.pushTempRoot(cellValue(list));
  let count: u32 = 0;
  while (true) {
    const next = runtime.iteratorStep(iteration);
    if (runtime.pendingThrow) return 0;
    if (isDeleted(next)) break;
    runtime.heap.arraySet(list, count, next);
    count = count + 1;
  }
  return list;
}

// InitializeTypedArrayFromList, from what an iterator gave.
function fromIterable(inout runtime: Runtime, object: u32, source: Value, method: Value): boolean {
  const list = iterableToList(inout runtime, source, method);
  if (list == 0) return false;
  const count = runtime.heap.arrayLength(list);
  if (!giveBuffer(inout runtime, object, f64(count))) return false;
  let index: u32 = 0;
  while (index < count) {
    const value = runtime.heap.arrayGet(list, index);
    runtime.typedSetElement(object, f64(index), value);
    if (runtime.pendingThrow) return false;
    index = index + 1;
  }
  return true;
}

// InitializeTypedArrayFromArrayLike.
function fromArrayLike(inout runtime: Runtime, object: u32, source: Value): boolean {
  const lengthKey = cellValue(runtime.atomLength);
  const lengthValue = runtime.getProperty(source, lengthKey);
  if (runtime.pendingThrow) return false;
  const length = runtime.toLength(lengthValue);
  if (runtime.pendingThrow) return false;
  if (!giveBuffer(inout runtime, object, f64(length))) return false;
  let index: u32 = 0;
  while (index < length) {
    const value = runtime.getProperty(source, int32Value(i32(index)));
    if (runtime.pendingThrow) return false;
    runtime.typedSetElement(object, f64(index), value);
    if (runtime.pendingThrow) return false;
    index = index + 1;
  }
  return true;
}

// The constructors of the nine kinds: a length, a typed array, an
// ArrayBuffer (with an offset and a length), an iterable, or an
// array-like.
function constructTyped(inout runtime: Runtime, argsBase: u32, argc: u32, kind: i32): Value {
  const newTarget = runtime.takeHostNewTarget();
  const name = elementName(kind);
  if (isUndefined(newTarget)) {
    const message: String = `Constructor ${name} requires 'new'`;
    return raiseType(inout runtime, in message);
  }
  const fallback = runtime.typedArrayProtos[usize(kind)];
  const first = runtime.argument(argsBase, argc, 0);
  if (!runtime.isObjectLike(first)) {
    const length = toIndex(inout runtime, first);
    if (runtime.pendingThrow) return undefinedValue();
    const proto = protoFrom(inout runtime, newTarget, fallback);
    if (runtime.pendingThrow) return undefinedValue();
    const object = typedObject(inout runtime, kind, proto);
    runtime.pushTempRoot(cellValue(object));
    if (!giveBuffer(inout runtime, object, length)) return undefinedValue();
    return cellValue(object);
  }
  const proto = protoFrom(inout runtime, newTarget, fallback);
  if (runtime.pendingThrow) return undefinedValue();
  const object = typedObject(inout runtime, kind, proto);
  runtime.pushTempRoot(cellValue(object));
  let made = false;
  if (runtime.isTypedArray(first)) {
    made = fromTypedArray(inout runtime, object, asCell(first));
  } else if (runtime.isArrayBuffer(first)) {
    made = fromArrayBuffer(inout runtime, object, asCell(first), runtime.argument(argsBase, argc, 1), runtime.argument(argsBase, argc, 2));
  } else {
    const symbolIterator = runtime.symbolIterator;
    const method = runtime.getProperty(first, symbolIterator);
    if (runtime.pendingThrow) return undefinedValue();
    if (!isUndefined(method) && !isNull(method)) {
      if (!runtime.isCallable(method)) {
        const message: String = `${name}: Symbol.iterator is not a function`;
        return raiseType(inout runtime, in message);
      }
      made = fromIterable(inout runtime, object, first, method);
    } else {
      made = fromArrayLike(inout runtime, object, first);
    }
  }
  if (!made) return undefinedValue();
  return cellValue(object);
}

function constructInt8(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return constructTyped(inout runtime, argsBase, argc, ELEMENT_INT8);
}
function constructUint8(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return constructTyped(inout runtime, argsBase, argc, ELEMENT_UINT8);
}
function constructUint8Clamped(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return constructTyped(inout runtime, argsBase, argc, ELEMENT_UINT8_CLAMPED);
}
function constructInt16(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return constructTyped(inout runtime, argsBase, argc, ELEMENT_INT16);
}
function constructUint16(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return constructTyped(inout runtime, argsBase, argc, ELEMENT_UINT16);
}
function constructInt32(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return constructTyped(inout runtime, argsBase, argc, ELEMENT_INT32);
}
function constructUint32(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return constructTyped(inout runtime, argsBase, argc, ELEMENT_UINT32);
}
function constructFloat32(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return constructTyped(inout runtime, argsBase, argc, ELEMENT_FLOAT32);
}
function constructFloat64(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return constructTyped(inout runtime, argsBase, argc, ELEMENT_FLOAT64);
}

// --- %TypedArray%.prototype ---

// `this` as a typed array, or 0 and a TypeError.
function thisTyped(inout runtime: Runtime, thisValue: Value, in method: String): u32 {
  if (runtime.isTypedArray(thisValue)) return asCell(thisValue);
  const message: String = `${method} called on an object that is not a typed array`;
  raiseType(inout runtime, in message);
  return 0;
}

function typedBufferGetter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "get TypedArray.prototype.buffer";
  const handle = thisTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  return runtime.binaryField(handle, 1);
}

function typedByteLengthGetter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "get TypedArray.prototype.byteLength";
  const handle = thisTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  return binaryNumber(runtime.typedLength(handle) * f64(elementSize(runtime.typedElement(handle))));
}

function typedByteOffsetGetter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "get TypedArray.prototype.byteOffset";
  const handle = thisTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  if (runtime.bufferBytes(runtime.typedBuffer(handle)) == 0) return int32Value(0);
  return binaryNumber(runtime.typedByteOffset(handle));
}

function typedLengthGetter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "get TypedArray.prototype.length";
  const handle = thisTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  return binaryNumber(runtime.typedLength(handle));
}

// Its kind's name, undefined for anything that is not a typed array.
function typedTagGetter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (!runtime.isTypedArray(thisValue)) return undefinedValue();
  const name = elementName(runtime.typedElement(asCell(thisValue)));
  return runtime.internText(in name);
}

// ValidateTypedArray: `value` as a typed array whose buffer is attached,
// or 0 and a TypeError.
function validTyped(inout runtime: Runtime, value: Value, in method: String): u32 {
  const handle = thisTyped(inout runtime, value, in method);
  if (handle == 0) return 0;
  if (isDetached(in runtime, handle)) {
    const message: String = `${method} called on a typed array whose buffer is detached`;
    raiseType(inout runtime, in message);
    return 0;
  }
  return handle;
}

function isDetached(in runtime: Runtime, handle: u32): boolean {
  return runtime.bufferBytes(runtime.typedBuffer(handle)) == 0;
}

// ValidateTypedArray, then an array iterator over it.
function typedIterator(inout runtime: Runtime, thisValue: Value, in method: String, kind: u32): Value {
  const handle = validTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  return runtime.createArrayIterator(thisValue, kind);
}

function typedValues(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.values";
  return typedIterator(inout runtime, thisValue, in method, 0);
}

function typedKeys(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.keys";
  return typedIterator(inout runtime, thisValue, in method, 1);
}

function typedEntries(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.entries";
  return typedIterator(inout runtime, thisValue, in method, 2);
}

// --- %TypedArray%.prototype's methods ---
//
// Each validates its receiver first (ValidateTypedArray) and reads the
// length the typed array holds, never a `length` property. A callback or
// a conversion may detach the buffer: after that an element reads as
// undefined and a write does nothing, as Get and Set on a typed array do.
// Elements are numbers, so a Z list of them needs no roots.

// TypedArrayCreateFromConstructor: what `ctor` makes from `args`, which
// must be a typed array with its buffer attached and, when a length was
// asked for, at least that long. Rooted until the builtin returns; 0 with
// a throw pending.
function createFromConstructor(inout runtime: Runtime, ctor: Value, args: Array<Value>, in method: String): u32 {
  let asked: f64 = -1.0;
  if (args.length == 1 && isNumber(args[0])) asked = toNumber(args[0]);
  const made = runtime.constructValue(ctor, move args, ctor);
  if (runtime.pendingThrow) return 0;
  runtime.pushTempRoot(made);
  const handle = validTyped(inout runtime, made, in method);
  if (handle == 0) return 0;
  if (runtime.typedLength(handle) < asked) {
    const message: String = `${method}: the constructor made a typed array shorter than asked`;
    raiseType(inout runtime, in message);
    return 0;
  }
  return handle;
}

// TypedArraySpeciesCreate. Every kind here holds numbers, so the content
// types match (the BigInt kinds are not here yet).
function speciesCreate(inout runtime: Runtime, exemplar: u32, args: Array<Value>, in method: String): u32 {
  const kind = runtime.typedElement(exemplar);
  const defaultCtor = cellValue(runtime.typedArrayCtors[usize(kind)]);
  const ctor = runtime.speciesConstructor(cellValue(exemplar), defaultCtor);
  if (runtime.pendingThrow) return 0;
  return createFromConstructor(inout runtime, ctor, move args, in method);
}

function speciesCreateOfLength(inout runtime: Runtime, exemplar: u32, length: f64, in method: String): u32 {
  let args = Array<Value>();
  args.push(binaryNumber(length));
  return speciesCreate(inout runtime, exemplar, move args, in method);
}

// TypedArrayCreateSameType, made here as the intrinsic constructor would
// make it (its `prototype` cannot change). Rooted; 0 with a throw pending.
function createSameType(inout runtime: Runtime, exemplar: u32, length: f64): u32 {
  const kind = runtime.typedElement(exemplar);
  const proto = runtime.typedArrayProtos[usize(kind)];
  const object = typedObject(inout runtime, kind, proto);
  runtime.pushTempRoot(cellValue(object));
  if (!giveBuffer(inout runtime, object, length)) return 0;
  return object;
}

function requireCallable(inout runtime: Runtime, callback: Value, in method: String): boolean {
  if (runtime.isCallable(callback)) return true;
  const message: String = `${method}: the callback is not a function`;
  raiseType(inout runtime, in message);
  return false;
}

const WALK_FOR_EACH: u32 = 0;
const WALK_EVERY: u32 = 1;
const WALK_SOME: u32 = 2;
const WALK_FIND: u32 = 3;
const WALK_FIND_INDEX: u32 = 4;
const WALK_FIND_LAST: u32 = 5;
const WALK_FIND_LAST_INDEX: u32 = 6;
const WALK_MAP: u32 = 7;
const WALK_FILTER: u32 = 8;

// forEach, every, some, the four finds, map, and filter: the callback
// called with each element, its index, and the typed array.
function typedWalk(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, in method: String, mode: u32): Value {
  const handle = validTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  const length = runtime.typedLength(handle);
  const callback = runtime.argument(argsBase, argc, 0);
  if (!requireCallable(inout runtime, callback, in method)) return undefinedValue();
  const receiver = runtime.argument(argsBase, argc, 1);
  let mapped: u32 = 0;
  if (mode == WALK_MAP) {
    mapped = speciesCreateOfLength(inout runtime, handle, length, in method);
    if (mapped == 0) return undefinedValue();
  }
  const fromEnd = mode == WALK_FIND_LAST || mode == WALK_FIND_LAST_INDEX;
  let kept = Array<Value>();
  let step: f64 = 0.0;
  while (step < length) {
    const index = fromEnd ? length - 1.0 - step : step;
    const element = runtime.typedGetElement(handle, index);
    const result = runtime.callValue3(callback, receiver, element, binaryNumber(index), thisValue);
    if (runtime.pendingThrow) return undefinedValue();
    if (mode == WALK_MAP) {
      runtime.typedSetElement(mapped, index, result);
      if (runtime.pendingThrow) return undefinedValue();
    } else if (mode != WALK_FOR_EACH) {
      const chosen = runtime.toBooleanValue(result);
      if (mode == WALK_EVERY && !chosen) return booleanValue(false);
      if (chosen) {
        if (mode == WALK_SOME) return booleanValue(true);
        if (mode == WALK_FIND || mode == WALK_FIND_LAST) return element;
        if (mode == WALK_FIND_INDEX || mode == WALK_FIND_LAST_INDEX) return binaryNumber(index);
        if (mode == WALK_FILTER) kept.push(element);
      }
    }
    step = step + 1.0;
  }
  if (mode == WALK_EVERY) return booleanValue(true);
  if (mode == WALK_SOME) return booleanValue(false);
  if (mode == WALK_FIND_INDEX || mode == WALK_FIND_LAST_INDEX) return int32Value(-1);
  if (mode == WALK_MAP) return cellValue(mapped);
  if (mode != WALK_FILTER) return undefinedValue();
  const filtered = speciesCreateOfLength(inout runtime, handle, f64(kept.length), in method);
  if (filtered == 0) return undefinedValue();
  let n: usize = 0;
  while (n < kept.length) {
    runtime.typedSetElement(filtered, f64(n), kept[n]);
    if (runtime.pendingThrow) return undefinedValue();
    n = n + 1;
  }
  return cellValue(filtered);
}

function typedForEach(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.forEach";
  return typedWalk(inout runtime, thisValue, argsBase, argc, in method, WALK_FOR_EACH);
}
function typedEvery(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.every";
  return typedWalk(inout runtime, thisValue, argsBase, argc, in method, WALK_EVERY);
}
function typedSome(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.some";
  return typedWalk(inout runtime, thisValue, argsBase, argc, in method, WALK_SOME);
}
function typedFind(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.find";
  return typedWalk(inout runtime, thisValue, argsBase, argc, in method, WALK_FIND);
}
function typedFindIndex(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.findIndex";
  return typedWalk(inout runtime, thisValue, argsBase, argc, in method, WALK_FIND_INDEX);
}
function typedFindLast(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.findLast";
  return typedWalk(inout runtime, thisValue, argsBase, argc, in method, WALK_FIND_LAST);
}
function typedFindLastIndex(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.findLastIndex";
  return typedWalk(inout runtime, thisValue, argsBase, argc, in method, WALK_FIND_LAST_INDEX);
}
function typedMap(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.map";
  return typedWalk(inout runtime, thisValue, argsBase, argc, in method, WALK_MAP);
}
function typedFilter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.filter";
  return typedWalk(inout runtime, thisValue, argsBase, argc, in method, WALK_FILTER);
}

// reduce and reduceRight; the accumulator, which may be any value, is
// rooted while the next element is read.
function typedReduce(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, in method: String, fromEnd: boolean): Value {
  const handle = validTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  const length = runtime.typedLength(handle);
  const callback = runtime.argument(argsBase, argc, 0);
  if (!requireCallable(inout runtime, callback, in method)) return undefinedValue();
  let step: f64 = 0.0;
  let accumulator = runtime.argument(argsBase, argc, 1);
  if (argc < 2) {
    if (length == 0.0) {
      const message: String = "Reduce of empty array with no initial value";
      return raiseType(inout runtime, in message);
    }
    accumulator = runtime.typedRead(handle, fromEnd ? length - 1.0 : 0.0);
    step = 1.0;
  }
  runtime.pushTempRoot(accumulator);
  while (step < length) {
    const index = fromEnd ? length - 1.0 - step : step;
    const element = runtime.typedGetElement(handle, index);
    accumulator = runtime.callValue4(callback, undefinedValue(), accumulator, element, binaryNumber(index), thisValue);
    if (runtime.pendingThrow) return undefinedValue();
    runtime.popTempRoot();
    runtime.pushTempRoot(accumulator);
    step = step + 1.0;
  }
  return accumulator;
}

function typedReduceLeft(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.reduce";
  return typedReduce(inout runtime, thisValue, argsBase, argc, in method, false);
}
function typedReduceRight(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.reduceRight";
  return typedReduce(inout runtime, thisValue, argsBase, argc, in method, true);
}

const SEARCH_INDEX_OF: u32 = 0;
const SEARCH_LAST_INDEX_OF: u32 = 1;
const SEARCH_INCLUDES: u32 = 2;

// indexOf and lastIndexOf (strict equality, only where an element is) and
// includes (SameValueZero, a detached element reading as undefined).
function typedSearch(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, in method: String, mode: u32): Value {
  const handle = validTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  const length = runtime.typedLength(handle);
  const missing = mode == SEARCH_INCLUDES ? booleanValue(false) : int32Value(-1);
  if (length == 0.0) return missing;
  const wanted = runtime.argument(argsBase, argc, 0);
  if (mode == SEARCH_LAST_INDEX_OF) {
    let origin = length - 1.0;
    if (argc > 1) origin = toIntegerOrInfinity(inout runtime, runtime.argument(argsBase, argc, 1));
    if (runtime.pendingThrow) return undefinedValue();
    let k = origin >= 0.0 ? (origin < length - 1.0 ? origin : length - 1.0) : length + origin;
    while (k >= 0.0) {
      if (runtime.typedValidIndex(handle, k) && runtime.strictEquals(runtime.typedRead(handle, k), wanted)) return binaryNumber(k);
      k = k - 1.0;
    }
    return missing;
  }
  const origin = toIntegerOrInfinity(inout runtime, runtime.argument(argsBase, argc, 1));
  if (runtime.pendingThrow) return undefinedValue();
  let k = origin >= 0.0 ? origin : (length + origin > 0.0 ? length + origin : 0.0);
  while (k < length) {
    if (mode == SEARCH_INCLUDES) {
      if (runtime.sameValueZero(runtime.typedGetElement(handle, k), wanted)) return booleanValue(true);
    } else if (runtime.typedValidIndex(handle, k) && runtime.strictEquals(runtime.typedRead(handle, k), wanted)) {
      return binaryNumber(k);
    }
    k = k + 1.0;
  }
  return missing;
}

function typedIndexOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.indexOf";
  return typedSearch(inout runtime, thisValue, argsBase, argc, in method, SEARCH_INDEX_OF);
}
function typedLastIndexOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.lastIndexOf";
  return typedSearch(inout runtime, thisValue, argsBase, argc, in method, SEARCH_LAST_INDEX_OF);
}
function typedIncludes(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.includes";
  return typedSearch(inout runtime, thisValue, argsBase, argc, in method, SEARCH_INCLUDES);
}

// join and toLocaleString: each element's string, a detached element's
// empty, between separators.
function typedJoin(inout runtime: Runtime, thisValue: Value, separatorGiven: Value, locale: boolean, in method: String): Value {
  const handle = validTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  const length = runtime.typedLength(handle);
  let separator: u32 = 0;
  if (!isUndefined(separatorGiven)) {
    const text = runtime.toStringValue(separatorGiven);
    if (runtime.pendingThrow) return undefinedValue();
    separator = asCell(text);
    runtime.pushTempRoot(text);
  }
  let joined = textBuilder(64);
  let k: f64 = 0.0;
  while (k < length) {
    if (k > 0.0) {
      if (separator == 0) {
        putByte(inout joined, 44);
      } else {
        putString(in runtime, inout joined, separator);
      }
    }
    const element = runtime.typedGetElement(handle, k);
    if (!isUndefined(element)) {
      let text = undefinedValue();
      if (locale) {
        const toLocaleText: String = "toLocaleString";
        const key = runtime.internText(in toLocaleText);
        const local = runtime.getProperty(element, key);
        if (runtime.pendingThrow) return undefinedValue();
        if (!runtime.isCallable(local)) {
          const message: String = "toLocaleString is not a function";
          return raiseType(inout runtime, in message);
        }
        const produced = runtime.callValue0(local, element);
        if (runtime.pendingThrow) return undefinedValue();
        text = runtime.toStringValue(produced);
      } else {
        text = runtime.toStringValue(element);
      }
      if (runtime.pendingThrow) return undefinedValue();
      putString(in runtime, inout joined, asCell(text));
    }
    k = k + 1.0;
  }
  return finishText(inout runtime, inout joined);
}

function typedJoinMethod(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.join";
  return typedJoin(inout runtime, thisValue, runtime.argument(argsBase, argc, 0), false, in method);
}
function typedToLocaleString(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.toLocaleString";
  return typedJoin(inout runtime, thisValue, undefinedValue(), true, in method);
}

// SortCompare without a comparator: numeric order, -0 before +0, NaN last.
function compareNumbers(x: f64, y: f64): f64 {
  if (x != x) return y != y ? 0.0 : 1.0;
  if (y != y) return -1.0;
  if (x < y) return -1.0;
  if (x > y) return 1.0;
  if (x == 0.0 && y == 0.0) {
    const xNegative = 1.0 / x < 0.0;
    const yNegative = 1.0 / y < 0.0;
    if (xNegative && !yNegative) return -1.0;
    if (yNegative && !xNegative) return 1.0;
  }
  return 0.0;
}

// SortCompare: the comparator's answer through ToNumber, NaN as 0.
function sortOrder(inout runtime: Runtime, comparator: Value, x: f64, y: f64): f64 {
  if (isUndefined(comparator)) return compareNumbers(x, y);
  const verdict = runtime.callValue2(comparator, undefinedValue(), binaryNumber(x), binaryNumber(y));
  if (runtime.pendingThrow) return 0.0;
  const number = runtime.toNumberValue(verdict);
  if (runtime.pendingThrow || number != number) return 0.0;
  return number;
}

// A stable bottom-up merge sort: each pass merges runs of `width` into
// `merged` and copies them back. Stops on a throw.
function sortNumbers(inout runtime: Runtime, inout values: Array<f64>, comparator: Value): void {
  const count = values.length;
  let merged = Array<f64>.withCapacity(count);
  merged.appendRepeated(0.0, count);
  let width: usize = 1;
  while (width < count) {
    let low: usize = 0;
    while (low < count) {
      const middle = low + width < count ? low + width : count;
      const high = middle + width < count ? middle + width : count;
      let left = low;
      let right = middle;
      let write = low;
      while (left < middle && right < high) {
        const order = sortOrder(inout runtime, comparator, values[right], values[left]);
        if (runtime.pendingThrow) return;
        if (order < 0.0) {
          merged[write] = values[right];
          right = right + 1;
        } else {
          merged[write] = values[left];
          left = left + 1;
        }
        write = write + 1;
      }
      while (left < middle) {
        merged[write] = values[left];
        left = left + 1;
        write = write + 1;
      }
      while (right < high) {
        merged[write] = values[right];
        right = right + 1;
        write = write + 1;
      }
      low = high;
    }
    let k: usize = 0;
    while (k < count) {
      values[k] = merged[k];
      k = k + 1;
    }
    width = width * 2;
  }
}

// sort, in place, and toSorted, into a new typed array of the same kind.
function typedSortInto(inout runtime: Runtime, thisValue: Value, comparator: Value, copy: boolean, in method: String): Value {
  if (!isUndefined(comparator) && !runtime.isCallable(comparator)) {
    const message: String = "The comparison function must be either a function or undefined";
    return raiseType(inout runtime, in message);
  }
  const handle = validTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  const length = runtime.typedLength(handle);
  let target = handle;
  if (copy) {
    target = createSameType(inout runtime, handle, length);
    if (target == 0) return undefinedValue();
  }
  let values = Array<f64>.withCapacity(usize(length));
  let k: f64 = 0.0;
  while (k < length) {
    values.push(toNumber(runtime.typedRead(handle, k)));
    k = k + 1.0;
  }
  sortNumbers(inout runtime, inout values, comparator);
  if (runtime.pendingThrow) return undefinedValue();
  let j: usize = 0;
  while (j < values.length) {
    if (runtime.typedValidIndex(target, f64(j))) runtime.typedWrite(target, f64(j), values[j]);
    j = j + 1;
  }
  return cellValue(target);
}

function typedSort(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.sort";
  return typedSortInto(inout runtime, thisValue, runtime.argument(argsBase, argc, 0), false, in method);
}
function typedToSorted(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.toSorted";
  return typedSortInto(inout runtime, thisValue, runtime.argument(argsBase, argc, 0), true, in method);
}

function typedAt(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.at";
  const handle = validTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  const length = runtime.typedLength(handle);
  const relative = toIntegerOrInfinity(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const k = relative >= 0.0 ? relative : length + relative;
  if (k < 0.0 || k >= length) return undefinedValue();
  return runtime.typedGetElement(handle, k);
}

// The bytes from `fromAt` to `toAt` in one buffer's bytes, `count` of
// them, forward or (when the target overlaps the source's tail) backward,
// none at or past `limit`.
function moveBytes(inout runtime: Runtime, bytes: u32, fromAt: f64, toAt: f64, count: f64, limit: f64): void {
  let origin = fromAt;
  let to = toAt;
  let direction: f64 = 1.0;
  if (fromAt < toAt && toAt < fromAt + count) {
    direction = -1.0;
    origin = fromAt + count - 1.0;
    to = toAt + count - 1.0;
  }
  let left = count;
  while (left > 0.0 && origin < limit && to < limit) {
    const byte = runtime.heap.byteAt(bytes, usize(origin));
    runtime.heap.setByteAt(bytes, usize(to), byte);
    origin = origin + direction;
    to = to + direction;
    left = left - 1.0;
  }
}

function typedCopyWithin(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.copyWithin";
  const handle = validTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  const length = runtime.typedLength(handle);
  const to = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 0), length, 0.0);
  if (runtime.pendingThrow) return undefinedValue();
  const origin = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 1), length, 0.0);
  if (runtime.pendingThrow) return undefinedValue();
  const last = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 2), length, length);
  if (runtime.pendingThrow) return undefinedValue();
  const count = last - origin < length - to ? last - origin : length - to;
  if (count > 0.0) {
    if (isDetached(in runtime, handle)) {
      const message: String = `${method}: the typed array's buffer was detached`;
      return raiseType(inout runtime, in message);
    }
    const size = f64(elementSize(runtime.typedElement(handle)));
    const offset = runtime.typedByteOffset(handle);
    const limit = runtime.typedLength(handle) * size + offset;
    const bytes = runtime.bufferBytes(runtime.typedBuffer(handle));
    moveBytes(inout runtime, bytes, origin * size + offset, to * size + offset, count * size, limit);
  }
  return thisValue;
}

function typedFill(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.fill";
  const handle = validTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  const length = runtime.typedLength(handle);
  const number = runtime.toNumberValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const first = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 1), length, 0.0);
  if (runtime.pendingThrow) return undefinedValue();
  const last = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 2), length, length);
  if (runtime.pendingThrow) return undefinedValue();
  if (isDetached(in runtime, handle)) {
    const message: String = `${method}: the typed array's buffer was detached`;
    return raiseType(inout runtime, in message);
  }
  let k = first;
  while (k < last) {
    runtime.typedWrite(handle, k, number);
    k = k + 1.0;
  }
  return thisValue;
}

function typedReverse(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.reverse";
  const handle = validTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  let lower: f64 = 0.0;
  let upper = runtime.typedLength(handle) - 1.0;
  while (lower < upper) {
    const low = toNumber(runtime.typedRead(handle, lower));
    const high = toNumber(runtime.typedRead(handle, upper));
    runtime.typedWrite(handle, lower, high);
    runtime.typedWrite(handle, upper, low);
    lower = lower + 1.0;
    upper = upper - 1.0;
  }
  return thisValue;
}

function typedToReversed(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.toReversed";
  const handle = validTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  const length = runtime.typedLength(handle);
  const made = createSameType(inout runtime, handle, length);
  if (made == 0) return undefinedValue();
  let k: f64 = 0.0;
  while (k < length) {
    runtime.typedWrite(made, k, toNumber(runtime.typedRead(handle, length - 1.0 - k)));
    k = k + 1.0;
  }
  return cellValue(made);
}

function typedWith(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.with";
  const handle = validTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  const length = runtime.typedLength(handle);
  const relative = toIntegerOrInfinity(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const actual = relative >= 0.0 ? relative : length + relative;
  const number = runtime.toNumberValue(runtime.argument(argsBase, argc, 1));
  if (runtime.pendingThrow) return undefinedValue();
  if (!runtime.typedValidIndex(handle, actual)) {
    const message: String = "Invalid typed array index";
    return raiseRange(inout runtime, in message);
  }
  const made = createSameType(inout runtime, handle, length);
  if (made == 0) return undefinedValue();
  let k: f64 = 0.0;
  while (k < length) {
    const value = k == actual ? number : toNumber(runtime.typedGetElement(handle, k));
    runtime.typedWrite(made, k, value);
    k = k + 1.0;
  }
  return cellValue(made);
}

function typedSlice(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.slice";
  const handle = validTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  const length = runtime.typedLength(handle);
  const first = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 0), length, 0.0);
  if (runtime.pendingThrow) return undefinedValue();
  let last = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 1), length, length);
  if (runtime.pendingThrow) return undefinedValue();
  const count = last > first ? last - first : 0.0;
  const made = speciesCreateOfLength(inout runtime, handle, count, in method);
  if (made == 0) return undefinedValue();
  if (count > 0.0) {
    if (isDetached(in runtime, handle)) {
      const message: String = `${method}: the typed array's buffer was detached`;
      return raiseType(inout runtime, in message);
    }
    const now = runtime.typedLength(handle);
    if (last > now) last = now;
    const kind = runtime.typedElement(handle);
    if (kind == runtime.typedElement(made)) {
      // The same kind: the bytes, forward, as the specification copies them.
      const size = f64(elementSize(kind));
      const fromBytes = runtime.bufferBytes(runtime.typedBuffer(handle));
      const toBytes = runtime.bufferBytes(runtime.typedBuffer(made));
      let origin = runtime.typedByteOffset(handle) + first * size;
      let to = runtime.typedByteOffset(made);
      const end = runtime.typedByteOffset(handle) + last * size;
      while (origin < end) {
        const byte = runtime.heap.byteAt(fromBytes, usize(origin));
        runtime.heap.setByteAt(toBytes, usize(to), byte);
        origin = origin + 1.0;
        to = to + 1.0;
      }
    } else {
      let k = first;
      let n: f64 = 0.0;
      while (k < last) {
        runtime.typedSetElement(made, n, runtime.typedGetElement(handle, k));
        k = k + 1.0;
        n = n + 1.0;
      }
    }
  }
  return cellValue(made);
}

function typedSubarray(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.subarray";
  const handle = thisTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  const length = runtime.typedLength(handle);
  const first = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 0), length, 0.0);
  if (runtime.pendingThrow) return undefinedValue();
  const last = relativeIndex(inout runtime, runtime.argument(argsBase, argc, 1), length, length);
  if (runtime.pendingThrow) return undefinedValue();
  const size = f64(elementSize(runtime.typedElement(handle)));
  let args = Array<Value>();
  args.push(cellValue(runtime.typedBuffer(handle)));
  args.push(binaryNumber(runtime.typedByteOffset(handle) + first * size));
  args.push(binaryNumber(last > first ? last - first : 0.0));
  const made = speciesCreate(inout runtime, handle, move args, in method);
  if (made == 0) return undefinedValue();
  return cellValue(made);
}

// set(source, offset): a typed array's elements (its bytes, for the same
// kind) or an array-like's, from `offset` on. The whole source is read
// before anything is written, so one sharing the target's buffer is read
// as it was.
function typedSet(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.prototype.set";
  const target = thisTyped(inout runtime, thisValue, in method);
  if (target == 0) return undefinedValue();
  const source = runtime.argument(argsBase, argc, 0);
  const offset = toIntegerOrInfinity(inout runtime, runtime.argument(argsBase, argc, 1));
  if (runtime.pendingThrow) return undefinedValue();
  if (offset < 0.0) {
    const message: String = "offset is out of bounds";
    return raiseRange(inout runtime, in message);
  }
  if (runtime.isTypedArray(source)) {
    const origin = asCell(source);
    if (isDetached(in runtime, target) || isDetached(in runtime, origin)) {
      const message: String = `${method}: a typed array's buffer is detached`;
      return raiseType(inout runtime, in message);
    }
    const count = runtime.typedLength(origin);
    if (count + offset > runtime.typedLength(target)) {
      const message: String = "offset is out of bounds";
      return raiseRange(inout runtime, in message);
    }
    const kind = runtime.typedElement(target);
    if (kind == runtime.typedElement(origin)) {
      const size = f64(elementSize(kind));
      const fromBytes = runtime.bufferBytes(runtime.typedBuffer(origin));
      const fromAt = runtime.typedByteOffset(origin);
      let held = Array<u8>.withCapacity(usize(count * size));
      let k: f64 = 0.0;
      while (k < count * size) {
        held.push(runtime.heap.byteAt(fromBytes, usize(fromAt + k)));
        k = k + 1.0;
      }
      const toBytes = runtime.bufferBytes(runtime.typedBuffer(target));
      const toAt = runtime.typedByteOffset(target) + offset * size;
      let j: usize = 0;
      while (j < held.length) {
        runtime.heap.setByteAt(toBytes, usize(toAt) + j, held[j]);
        j = j + 1;
      }
      return undefinedValue();
    }
    let values = Array<f64>.withCapacity(usize(count));
    let k: f64 = 0.0;
    while (k < count) {
      values.push(toNumber(runtime.typedRead(origin, k)));
      k = k + 1.0;
    }
    let j: usize = 0;
    while (j < values.length) {
      runtime.typedWrite(target, offset + f64(j), values[j]);
      j = j + 1;
    }
    return undefinedValue();
  }
  if (isDetached(in runtime, target)) {
    const message: String = `${method}: the typed array's buffer is detached`;
    return raiseType(inout runtime, in message);
  }
  const targetLength = runtime.typedLength(target);
  const object = runtime.toObjectValue(source);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(object);
  const lengthKey = cellValue(runtime.atomLength);
  const lengthValue = runtime.getProperty(object, lengthKey);
  if (runtime.pendingThrow) return undefinedValue();
  const count = f64(runtime.toLength(lengthValue));
  if (runtime.pendingThrow) return undefinedValue();
  if (count + offset > targetLength) {
    const message: String = "offset is out of bounds";
    return raiseRange(inout runtime, in message);
  }
  let k: f64 = 0.0;
  while (k < count) {
    const value = runtime.getProperty(object, binaryNumber(k));
    if (runtime.pendingThrow) return undefinedValue();
    runtime.typedSetElement(target, offset + k, value);
    if (runtime.pendingThrow) return undefinedValue();
    k = k + 1.0;
  }
  return undefinedValue();
}

// --- %TypedArray%.from and .of ---

function constructorThis(inout runtime: Runtime, thisValue: Value, in method: String): boolean {
  if (runtime.isConstructorValue(thisValue)) return true;
  const message: String = `${method}: this is not a constructor`;
  raiseType(inout runtime, in message);
  return false;
}

function typedFrom(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.from";
  if (!constructorThis(inout runtime, thisValue, in method)) return undefinedValue();
  const source = runtime.argument(argsBase, argc, 0);
  const mapper = runtime.argument(argsBase, argc, 1);
  const mapping = !isUndefined(mapper);
  if (mapping && !requireCallable(inout runtime, mapper, in method)) return undefinedValue();
  const receiver = runtime.argument(argsBase, argc, 2);
  const symbolIterator = runtime.symbolIterator;
  const iterate = runtime.getProperty(source, symbolIterator);
  if (runtime.pendingThrow) return undefinedValue();
  // From an iterable, its values listed first; from an array-like, read
  // by index as they are written.
  let list: u32 = 0;
  let object = source;
  let length: f64 = 0.0;
  if (!isUndefined(iterate) && !isNull(iterate)) {
    if (!runtime.isCallable(iterate)) {
      const message: String = `${method}: Symbol.iterator is not a function`;
      return raiseType(inout runtime, in message);
    }
    list = iterableToList(inout runtime, source, iterate);
    if (list == 0) return undefinedValue();
    length = f64(runtime.heap.arrayLength(list));
  } else {
    object = runtime.toObjectValue(source);
    if (runtime.pendingThrow) return undefinedValue();
    runtime.pushTempRoot(object);
    const lengthKey = cellValue(runtime.atomLength);
    const lengthValue = runtime.getProperty(object, lengthKey);
    if (runtime.pendingThrow) return undefinedValue();
    length = f64(runtime.toLength(lengthValue));
    if (runtime.pendingThrow) return undefinedValue();
  }
  let args = Array<Value>();
  args.push(binaryNumber(length));
  const target = createFromConstructor(inout runtime, thisValue, move args, in method);
  if (target == 0) return undefinedValue();
  let k: f64 = 0.0;
  while (k < length) {
    let value = undefinedValue();
    if (list != 0) {
      value = runtime.heap.arrayGet(list, u32(k));
    } else {
      value = runtime.getProperty(object, binaryNumber(k));
      if (runtime.pendingThrow) return undefinedValue();
    }
    if (mapping) {
      value = runtime.callValue2(mapper, receiver, value, binaryNumber(k));
      if (runtime.pendingThrow) return undefinedValue();
    }
    runtime.typedSetElement(target, k, value);
    if (runtime.pendingThrow) return undefinedValue();
    k = k + 1.0;
  }
  return cellValue(target);
}

function typedOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "TypedArray.of";
  if (!constructorThis(inout runtime, thisValue, in method)) return undefinedValue();
  let args = Array<Value>();
  args.push(int32Value(i32(argc)));
  const target = createFromConstructor(inout runtime, thisValue, move args, in method);
  if (target == 0) return undefinedValue();
  let k: u32 = 0;
  while (k < argc) {
    runtime.typedSetElement(target, f64(k), runtime.argument(argsBase, argc, k));
    if (runtime.pendingThrow) return undefinedValue();
    k = k + 1;
  }
  return cellValue(target);
}

// --- DataView ---
//
// A view of an ArrayBuffer's bytes read and written as any element kind,
// in either byte order. It keeps a typed array's leading slots without the
// element kind (runtime.zs, Binary data); a fixed-length buffer changes
// length only by being detached, which the view then sees as zero.

function constructDataView(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const newTarget = runtime.takeHostNewTarget();
  if (isUndefined(newTarget)) {
    const message: String = "Constructor DataView requires 'new'";
    return raiseType(inout runtime, in message);
  }
  const given = runtime.argument(argsBase, argc, 0);
  if (!runtime.isArrayBuffer(given)) {
    const message: String = "First argument to DataView constructor must be an ArrayBuffer";
    return raiseType(inout runtime, in message);
  }
  const buffer = asCell(given);
  const offset = toIndex(inout runtime, runtime.argument(argsBase, argc, 1));
  if (runtime.pendingThrow) return undefinedValue();
  if (runtime.bufferBytes(buffer) == 0) {
    const message: String = "Cannot construct a DataView on a detached ArrayBuffer";
    return raiseType(inout runtime, in message);
  }
  const available = bufferByteLength(in runtime, buffer);
  if (offset > available) {
    const message: String = "Start offset is outside the bounds of the buffer";
    return raiseRange(inout runtime, in message);
  }
  let viewLength = available - offset;
  const lengthGiven = runtime.argument(argsBase, argc, 2);
  if (!isUndefined(lengthGiven)) {
    viewLength = toIndex(inout runtime, lengthGiven);
    if (runtime.pendingThrow) return undefinedValue();
    if (offset + viewLength > available) {
      const message: String = "Invalid DataView length";
      return raiseRange(inout runtime, in message);
    }
  }
  // Reading new.target's `prototype` can run a getter that detaches the
  // buffer.
  const proto = protoFrom(inout runtime, newTarget, runtime.dataViewProto);
  if (runtime.pendingThrow) return undefinedValue();
  if (runtime.bufferBytes(buffer) == 0) {
    const message: String = "Cannot construct a DataView on a detached ArrayBuffer";
    return raiseType(inout runtime, in message);
  }
  const viewClass = runtime.viewClass;
  const object = runtime.heap.allocateObjectOfClass(proto, viewClass);
  runtime.heap.setFlags(object, runtime.heap.flagsOf(object) | FLAG_BINARY);
  runtime.heap.setSlot(object, 0, int32Value(BINARY_VIEW));
  runtime.heap.setSlot(object, 1, cellValue(buffer));
  runtime.heap.setSlot(object, 2, binaryNumber(offset));
  runtime.heap.setSlot(object, 3, binaryNumber(viewLength));
  return cellValue(object);
}

// `this` as a DataView, or 0 and a TypeError.
function thisView(inout runtime: Runtime, thisValue: Value, in method: String): u32 {
  if (isCell(thisValue) && asCell(thisValue) != 0 && runtime.binaryKind(asCell(thisValue)) == BINARY_VIEW) return asCell(thisValue);
  const message: String = `${method} called on an object that is not a DataView`;
  raiseType(inout runtime, in message);
  return 0;
}

// `this` as a DataView whose buffer is attached, or 0 and a TypeError.
function attachedView(inout runtime: Runtime, thisValue: Value, in method: String): u32 {
  const view = thisView(inout runtime, thisValue, in method);
  if (view == 0) return 0;
  if (isDetached(in runtime, view)) {
    const message: String = `${method} called on a DataView whose buffer is detached`;
    raiseType(inout runtime, in message);
    return 0;
  }
  return view;
}

function viewBufferGetter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "get DataView.prototype.buffer";
  const view = thisView(inout runtime, thisValue, in method);
  if (view == 0) return undefinedValue();
  return runtime.binaryField(view, 1);
}

function viewByteLengthGetter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "get DataView.prototype.byteLength";
  const view = attachedView(inout runtime, thisValue, in method);
  if (view == 0) return undefinedValue();
  return runtime.binaryField(view, 3);
}

function viewByteOffsetGetter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "get DataView.prototype.byteOffset";
  const view = attachedView(inout runtime, thisValue, in method);
  if (view == 0) return undefinedValue();
  return runtime.binaryField(view, 2);
}

// The byte in the buffer where an element of kind `kind` at `index` in the
// view starts, checked against the view's length; -1 with a RangeError.
function viewPlace(inout runtime: Runtime, view: u32, index: f64, kind: i32): f64 {
  const viewLength = toNumber(runtime.binaryField(view, 3));
  if (index + f64(elementSize(kind)) > viewLength) {
    const message: String = "Offset is outside the bounds of the DataView";
    raiseRange(inout runtime, in message);
    return -1.0;
  }
  return toNumber(runtime.binaryField(view, 2)) + index;
}

// GetViewValue: getInt8 ... getFloat64, the element kind bound in the
// function; big-endian unless the second argument is true.
function viewGet(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const kind = asInt32(runtime.heap.slot(callee, 0));
  const method: String = "DataView.prototype.get";
  const view = thisView(inout runtime, thisValue, in method);
  if (view == 0) return undefinedValue();
  const index = toIndex(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const little = runtime.toBooleanValue(runtime.argument(argsBase, argc, 1));
  if (attachedView(inout runtime, thisValue, in method) == 0) return undefinedValue();
  const at = viewPlace(inout runtime, view, index, kind);
  if (at < 0.0) return undefinedValue();
  const bytes = runtime.bufferBytes(runtime.typedBuffer(view));
  return runtime.readElement(bytes, usize(at), kind, !little);
}

// SetViewValue: setInt8 ... setFloat64, the value made a number before the
// buffer is checked.
function viewSet(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const kind = asInt32(runtime.heap.slot(callee, 0));
  const method: String = "DataView.prototype.set";
  const view = thisView(inout runtime, thisValue, in method);
  if (view == 0) return undefinedValue();
  const index = toIndex(inout runtime, runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const number = runtime.toNumberValue(runtime.argument(argsBase, argc, 1));
  if (runtime.pendingThrow) return undefinedValue();
  const little = runtime.toBooleanValue(runtime.argument(argsBase, argc, 2));
  if (attachedView(inout runtime, thisValue, in method) == 0) return undefinedValue();
  const at = viewPlace(inout runtime, view, index, kind);
  if (at < 0.0) return undefinedValue();
  const bytes = runtime.bufferBytes(runtime.typedBuffer(view));
  runtime.writeElement(bytes, usize(at), kind, number, !little);
  return undefinedValue();
}

// --- installation ---

function defineGetter(inout runtime: Runtime, target: u32, in name: String, fn: HostFunction): void {
  const getterName: String = `get ${name}`;
  const getter = runtime.defineHostFunction(fn, undefinedValue(), 0, in getterName);
  const accessor = runtime.heap.allocateAccessor(cellValue(getter), undefinedValue());
  const atom = runtime.atomOf(in name);
  runtime.heap.objectDefine(target, atom, cellValue(accessor), PROP_CONFIGURABLE | PROP_ACCESSOR);
}

function defineConstant(inout runtime: Runtime, target: u32, in name: String, value: Value): void {
  const atom = runtime.atomOf(in name);
  runtime.defineOwnAttr(target, atom, value, PROP_NONE);
}

// A hidden name for an internal slot: never a key a program can write.
function slotAtom(inout runtime: Runtime, which: u8): u32 {
  let bytes = Array<u8>();
  bytes.push(255);
  bytes.push(98);
  bytes.push(105);
  bytes.push(110);
  bytes.push(which);
  return runtime.hiddenAtomBytes(move bytes);
}

export function installTypedArrays(inout runtime: Runtime): void {
  if ((runtime.features & FEATURE_TYPED_ARRAYS) != 0) return;
  runtime.features = runtime.features | FEATURE_TYPED_ARRAYS;
  const objectProto = runtime.objectProto;
  const atomConstructor = runtime.atomConstructor;

  // The classes: the binary kind first, then each kind's own slots.
  const kindAtom = slotAtom(inout runtime, 48);
  const bytesAtom = slotAtom(inout runtime, 49);
  const byteLengthAtom = slotAtom(inout runtime, 50);
  const bufferAtom = slotAtom(inout runtime, 51);
  const offsetAtom = slotAtom(inout runtime, 52);
  const lengthAtom = slotAtom(inout runtime, 53);
  const elementAtom = slotAtom(inout runtime, 54);
  const kindClass = runtime.heap.classTransitionWith(0, kindAtom, PROP_NONE);
  const bytesClass = runtime.heap.classTransitionWith(kindClass, bytesAtom, PROP_NONE);
  runtime.bufferClass = runtime.heap.classTransitionWith(bytesClass, byteLengthAtom, PROP_NONE);
  const bufferAtClass = runtime.heap.classTransitionWith(kindClass, bufferAtom, PROP_NONE);
  const offsetClass = runtime.heap.classTransitionWith(bufferAtClass, offsetAtom, PROP_NONE);
  const lengthClass = runtime.heap.classTransitionWith(offsetClass, lengthAtom, PROP_NONE);
  runtime.typedClass = runtime.heap.classTransitionWith(lengthClass, elementAtom, PROP_NONE);
  runtime.viewClass = lengthClass;

  // ArrayBuffer
  runtime.arrayBufferProto = runtime.heap.allocateObject(objectProto);
  const bufferProto = runtime.arrayBufferProto;
  const bufferText: String = "ArrayBuffer";
  const bufferCtor = runtime.defineAllocatingConstructor(constructArrayBuffer, undefinedValue(), 1, in bufferText);
  runtime.arrayBufferCtor = bufferCtor;
  runtime.heap.setLink(bufferCtor, bufferProto);
  runtime.defineOwnAttr(bufferProto, atomConstructor, cellValue(bufferCtor), PROP_METHOD);
  runtime.setGlobal("ArrayBuffer", cellValue(bufferCtor));
  const isViewText: String = "isView"; runtime.defineMethod(bufferCtor, in isViewText, bufferIsView, 1);
  defineSpecies(inout runtime, bufferCtor);
  const byteLengthText: String = "byteLength"; defineGetter(inout runtime, bufferProto, in byteLengthText, bufferByteLengthGetter);
  const maxByteLengthText: String = "maxByteLength"; defineGetter(inout runtime, bufferProto, in maxByteLengthText, bufferMaxByteLength);
  const resizableText: String = "resizable"; defineGetter(inout runtime, bufferProto, in resizableText, bufferResizable);
  const detachedText: String = "detached"; defineGetter(inout runtime, bufferProto, in detachedText, bufferDetached);
  const sliceText: String = "slice"; runtime.defineMethod(bufferProto, in sliceText, bufferSlice, 2);
  const transferText: String = "transfer"; runtime.defineMethod(bufferProto, in transferText, bufferTransfer, 0);
  const transferFixedText: String = "transferToFixedLength"; runtime.defineMethod(bufferProto, in transferFixedText, bufferTransferToFixedLength, 0);
  const symbolToStringTag = runtime.symbolToStringTag;
  const tagKey = runtime.propertyKey(symbolToStringTag);
  const bufferTag = runtime.internText(in bufferText);
  runtime.heap.objectDefine(bufferProto, tagKey, bufferTag, PROP_CONFIGURABLE);

  // %TypedArray%
  runtime.typedArrayProto = runtime.heap.allocateObject(objectProto);
  const typedProto = runtime.typedArrayProto;
  const typedText: String = "TypedArray";
  const typedCtor = runtime.defineAllocatingConstructor(constructTypedArrayAbstract, undefinedValue(), 0, in typedText);
  runtime.heap.setLink(typedCtor, typedProto);
  runtime.defineOwnAttr(typedProto, atomConstructor, cellValue(typedCtor), PROP_METHOD);
  defineSpecies(inout runtime, typedCtor);
  const bufferPropText: String = "buffer"; defineGetter(inout runtime, typedProto, in bufferPropText, typedBufferGetter);
  defineGetter(inout runtime, typedProto, in byteLengthText, typedByteLengthGetter);
  const byteOffsetText: String = "byteOffset"; defineGetter(inout runtime, typedProto, in byteOffsetText, typedByteOffsetGetter);
  const lengthText: String = "length"; defineGetter(inout runtime, typedProto, in lengthText, typedLengthGetter);
  const tagName: String = "get [Symbol.toStringTag]";
  const tagGetter = runtime.defineHostFunction(typedTagGetter, undefinedValue(), 0, in tagName);
  const tagAccessor = runtime.heap.allocateAccessor(cellValue(tagGetter), undefinedValue());
  runtime.heap.objectDefine(typedProto, tagKey, cellValue(tagAccessor), PROP_CONFIGURABLE | PROP_ACCESSOR);
  const keysText: String = "keys"; runtime.defineMethod(typedProto, in keysText, typedKeys, 0);
  const entriesText: String = "entries"; runtime.defineMethod(typedProto, in entriesText, typedEntries, 0);
  const valuesText: String = "values";
  const valuesFn = runtime.defineMethod(typedProto, in valuesText, typedValues, 0);
  const symbolIterator = runtime.symbolIterator;
  const iteratorKey = runtime.propertyKey(symbolIterator);
  runtime.heap.objectDefine(typedProto, iteratorKey, cellValue(valuesFn), PROP_METHOD);
  const atText: String = "at"; runtime.defineMethod(typedProto, in atText, typedAt, 1);
  const copyWithinText: String = "copyWithin"; runtime.defineMethod(typedProto, in copyWithinText, typedCopyWithin, 2);
  const everyText: String = "every"; runtime.defineMethod(typedProto, in everyText, typedEvery, 1);
  const fillText: String = "fill"; runtime.defineMethod(typedProto, in fillText, typedFill, 1);
  const filterText: String = "filter"; runtime.defineMethod(typedProto, in filterText, typedFilter, 1);
  const findText: String = "find"; runtime.defineMethod(typedProto, in findText, typedFind, 1);
  const findIndexText: String = "findIndex"; runtime.defineMethod(typedProto, in findIndexText, typedFindIndex, 1);
  const findLastText: String = "findLast"; runtime.defineMethod(typedProto, in findLastText, typedFindLast, 1);
  const findLastIndexText: String = "findLastIndex"; runtime.defineMethod(typedProto, in findLastIndexText, typedFindLastIndex, 1);
  const forEachText: String = "forEach"; runtime.defineMethod(typedProto, in forEachText, typedForEach, 1);
  const includesText: String = "includes"; runtime.defineMethod(typedProto, in includesText, typedIncludes, 1);
  const indexOfText: String = "indexOf"; runtime.defineMethod(typedProto, in indexOfText, typedIndexOf, 1);
  const joinText: String = "join"; runtime.defineMethod(typedProto, in joinText, typedJoinMethod, 1);
  const lastIndexOfText: String = "lastIndexOf"; runtime.defineMethod(typedProto, in lastIndexOfText, typedLastIndexOf, 1);
  const mapText: String = "map"; runtime.defineMethod(typedProto, in mapText, typedMap, 1);
  const reduceText: String = "reduce"; runtime.defineMethod(typedProto, in reduceText, typedReduceLeft, 1);
  const reduceRightText: String = "reduceRight"; runtime.defineMethod(typedProto, in reduceRightText, typedReduceRight, 1);
  const reverseText: String = "reverse"; runtime.defineMethod(typedProto, in reverseText, typedReverse, 0);
  const setText: String = "set"; runtime.defineMethod(typedProto, in setText, typedSet, 1);
  runtime.defineMethod(typedProto, in sliceText, typedSlice, 2);
  const someText: String = "some"; runtime.defineMethod(typedProto, in someText, typedSome, 1);
  const sortText: String = "sort"; runtime.defineMethod(typedProto, in sortText, typedSort, 1);
  const subarrayText: String = "subarray"; runtime.defineMethod(typedProto, in subarrayText, typedSubarray, 2);
  const toLocaleText: String = "toLocaleString"; runtime.defineMethod(typedProto, in toLocaleText, typedToLocaleString, 0);
  const toReversedText: String = "toReversed"; runtime.defineMethod(typedProto, in toReversedText, typedToReversed, 0);
  const toSortedText: String = "toSorted"; runtime.defineMethod(typedProto, in toSortedText, typedToSorted, 1);
  const withText: String = "with"; runtime.defineMethod(typedProto, in withText, typedWith, 2);
  // toString is Array.prototype.toString's own function object.
  const toStringText: String = "toString";
  const toStringKey = runtime.atomOf(in toStringText);
  const arrayProto = runtime.arrayProto;
  const arrayToString = runtime.getProperty(cellValue(arrayProto), cellValue(toStringKey));
  runtime.defineOwnAttr(typedProto, toStringKey, arrayToString, PROP_METHOD);
  const fromText: String = "from"; runtime.defineMethod(typedCtor, in fromText, typedFrom, 1);
  const ofText: String = "of"; runtime.defineMethod(typedCtor, in ofText, typedOf, 0);

  // DataView: getX and setX for each kind, the kind bound in the function.
  runtime.dataViewProto = runtime.heap.allocateObject(objectProto);
  const viewProto = runtime.dataViewProto;
  const viewText: String = "DataView";
  const viewCtor = runtime.defineAllocatingConstructor(constructDataView, undefinedValue(), 1, in viewText);
  runtime.heap.setLink(viewCtor, viewProto);
  runtime.defineOwnAttr(viewProto, atomConstructor, cellValue(viewCtor), PROP_METHOD);
  runtime.setGlobal("DataView", cellValue(viewCtor));
  defineGetter(inout runtime, viewProto, in bufferPropText, viewBufferGetter);
  defineGetter(inout runtime, viewProto, in byteLengthText, viewByteLengthGetter);
  defineGetter(inout runtime, viewProto, in byteOffsetText, viewByteOffsetGetter);
  const viewTag = runtime.internText(in viewText);
  runtime.heap.objectDefine(viewProto, tagKey, viewTag, PROP_CONFIGURABLE);
  let viewKind: i32 = 0;
  while (viewKind < ELEMENT_KINDS) {
    if (viewKind != ELEMENT_UINT8_CLAMPED) {
      const getName: String = `get${viewKindName(viewKind)}`;
      const getter = runtime.defineHostFunction(viewGet, int32Value(viewKind), 1, in getName);
      const getAtom = runtime.atomOf(in getName);
      runtime.defineOwnAttr(viewProto, getAtom, cellValue(getter), PROP_METHOD);
      const setName: String = `set${viewKindName(viewKind)}`;
      const setter = runtime.defineHostFunction(viewSet, int32Value(viewKind), 2, in setName);
      const setAtom = runtime.atomOf(in setName);
      runtime.defineOwnAttr(viewProto, setAtom, cellValue(setter), PROP_METHOD);
    }
    viewKind = viewKind + 1;
  }

  // The nine kinds: each constructor inherits from %TypedArray%, each
  // prototype from %TypedArray%.prototype.
  const bytesText: String = "BYTES_PER_ELEMENT";
  let kind: i32 = 0;
  while (kind < ELEMENT_KINDS) {
    const proto = runtime.heap.allocateObject(typedProto);
    runtime.typedArrayProtos.push(proto);
    const name = elementName(kind);
    let ctor: u32 = 0;
    if (kind == ELEMENT_INT8) {
      ctor = runtime.defineAllocatingConstructor(constructInt8, undefinedValue(), 3, in name);
    } else if (kind == ELEMENT_UINT8) {
      ctor = runtime.defineAllocatingConstructor(constructUint8, undefinedValue(), 3, in name);
    } else if (kind == ELEMENT_UINT8_CLAMPED) {
      ctor = runtime.defineAllocatingConstructor(constructUint8Clamped, undefinedValue(), 3, in name);
    } else if (kind == ELEMENT_INT16) {
      ctor = runtime.defineAllocatingConstructor(constructInt16, undefinedValue(), 3, in name);
    } else if (kind == ELEMENT_UINT16) {
      ctor = runtime.defineAllocatingConstructor(constructUint16, undefinedValue(), 3, in name);
    } else if (kind == ELEMENT_INT32) {
      ctor = runtime.defineAllocatingConstructor(constructInt32, undefinedValue(), 3, in name);
    } else if (kind == ELEMENT_UINT32) {
      ctor = runtime.defineAllocatingConstructor(constructUint32, undefinedValue(), 3, in name);
    } else if (kind == ELEMENT_FLOAT32) {
      ctor = runtime.defineAllocatingConstructor(constructFloat32, undefinedValue(), 3, in name);
    } else {
      ctor = runtime.defineAllocatingConstructor(constructFloat64, undefinedValue(), 3, in name);
    }
    runtime.typedArrayCtors.push(ctor);
    runtime.heap.setLink(ctor, proto);
    const kept = runtime.setPrototypeOfValue(cellValue(ctor), cellValue(typedCtor));
    runtime.defineOwnAttr(proto, atomConstructor, cellValue(ctor), PROP_METHOD);
    const size = int32Value(i32(elementSize(kind)));
    defineConstant(inout runtime, ctor, in bytesText, size);
    defineConstant(inout runtime, proto, in bytesText, size);
    runtime.setGlobal(move name, cellValue(ctor));
    kind = kind + 1;
  }
}
