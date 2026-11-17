// ArrayBuffer and the typed arrays (ECMA-262 25.1 and 23.2), installed by
// installTypedArrays: zjs_new_context installs them, a core context when
// zjs_install_typed_arrays asks.
//
// An ArrayBuffer and a typed array are ordinary objects with FLAG_BINARY,
// made with a class whose leading slots hold their internal data
// (runtime.zs, Binary data); a typed array's elements are reached through
// the runtime's property operations, which ask the runtime for the
// element when the key is a canonical numeric string. The bytes live in a
// TAG_BYTES cell the buffer holds; detaching drops the cell.
//
// Not here yet: resizable buffers, DataView, the prototype methods beyond
// the getters and iterators, from and of, Float16Array, and the BigInt
// element kinds.
import { thread } from "std/thread";
import { Value, undefinedValue, nullValue, booleanValue, int32Value, cellValue, asCell, isCell, isUndefined, isNull, isDeleted, asInt32 } from "../value.zs";
import { Runtime, HostFunction, toNumber, truncateDouble, isIntegralDouble, binaryNumber, elementSize, FEATURE_TYPED_ARRAYS, BINARY_BUFFER, BINARY_TYPED, ELEMENT_INT8, ELEMENT_UINT8, ELEMENT_UINT8_CLAMPED, ELEMENT_INT16, ELEMENT_UINT16, ELEMENT_INT32, ELEMENT_UINT32, ELEMENT_FLOAT32, ELEMENT_FLOAT64 } from "../runtime.zs";
import { PROP_METHOD, PROP_NONE, PROP_CONFIGURABLE, PROP_ACCESSOR, FLAG_BINARY } from "../heap.zs";
import { defineSpecies } from "./collections.zs";

// The most bytes an ArrayBuffer holds. A larger one is a RangeError, as
// CreateByteDataBlock allows, rather than an allocation the process cannot
// survive (the engine has no fallible allocation).
const MAX_BYTE_LENGTH: f64 = 2147483647.0;
const ELEMENT_KINDS: i32 = 9;
// 2^53 - 1, the largest index ToIndex accepts.
const MAX_INDEX: f64 = 9007199254740991.0;

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

function bufferIsView(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return booleanValue(runtime.isTypedArray(runtime.argument(argsBase, argc, 0)));
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

// InitializeTypedArrayFromList, from what an iterator gave: kept in a heap
// array, which roots it.
function fromIterable(inout runtime: Runtime, object: u32, source: Value, method: Value): boolean {
  const iteration = runtime.getIteratorFromMethod(source, method);
  if (runtime.pendingThrow) return false;
  runtime.pushTempRoot(iteration);
  const list = runtime.heap.allocateArray(0);
  runtime.pushTempRoot(cellValue(list));
  let count: u32 = 0;
  while (true) {
    const next = runtime.iteratorStep(iteration);
    if (runtime.pendingThrow) return false;
    if (isDeleted(next)) break;
    runtime.heap.arraySet(list, count, next);
    count = count + 1;
  }
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

// ValidateTypedArray, then an array iterator over it.
function typedIterator(inout runtime: Runtime, thisValue: Value, in method: String, kind: u32): Value {
  const handle = thisTyped(inout runtime, thisValue, in method);
  if (handle == 0) return undefinedValue();
  if (runtime.bufferBytes(runtime.typedBuffer(handle)) == 0) {
    const message: String = `${method} called on a typed array whose buffer is detached`;
    return raiseType(inout runtime, in message);
  }
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
