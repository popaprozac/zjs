// Runtime -- the per-context engine state the interpreter runs against:
// the heap, compiled functions, globals, the register stack, and call
// frames. One Runtime per context; it lives inside the context registry.
//
// The interpreter is a method on Runtime so every piece of mutable state is
// reached through `this`. Z rejects `inout` through indexed storage, but a
// method call on the projection is accepted, and the registry calls
// `slots[i].runtime.eval(...)`.

import { expect } from "std/test";
import { Value, int32Value, asInt32, doubleValue, asDouble, isInt32, isDouble, isNumber, isBoolean, isTrue, isNull, isUndefined, isCell, asCell, cellValue, undefinedValue, nullValue, booleanValue, deletedValue, isDeleted } from "./value.zs";
import { Heap, createHeap, bytesOf, TAG_OBJECT, TAG_ARRAY, TAG_FUNCTION, TAG_HOST_FUNCTION, TAG_CLOSURE, TAG_ENV } from "./heap.zs";
import { Op, Inst, FunctionCode, createFunctionCode, bcU16, bcI16 } from "./bytecode.zs";
import stdlib from "stdlib.h";
import stdio from "stdio.h";
import string from "string.h";

struct Global {
  name: String;
  value: Value;
  defined: boolean;
}

struct Frame {
  functionIndex: u32;
  ip: usize;
  regsBase: u32;
  regCount: u32;
  returnDst: u8;
  // The caller's `this`, restored on return.
  savedThis: Value;
  // Handlers pushed inside this frame are dropped when it pops.
  tryDepthAtEntry: u32;
  // For a constructor call, the object under construction: it is the
  // result unless the body returns an object of its own.
  constructThis: Value;
  // The environment the frame's captured bindings resolve against: the
  // closure's at entry, then a fresh one chained to it if the function
  // has captured bindings of its own. 0 for none.
  env: u32;
  // The function or closure value the frame was called through.
  callee: Value;
}

// A live try handler: the frame it belongs to, where its catch block
// starts, and the register that receives the thrown value.
struct TryFrame {
  frameIndex: u32;
  catchIp: usize;
  catchReg: u8;
}

// Builtins implemented in Z. A host function cell carries one of these
// ids; `callHost` dispatches on it.
const BUILTIN_ERROR: u32 = 0;
const BUILTIN_TYPE_ERROR: u32 = 1;
const BUILTIN_REFERENCE_ERROR: u32 = 2;
const BUILTIN_RANGE_ERROR: u32 = 3;
const BUILTIN_SYNTAX_ERROR: u32 = 4;
const BUILTIN_COUNT: u32 = 5;

function builtinName(id: u32): String {
  if (id == BUILTIN_ERROR) return "Error";
  if (id == BUILTIN_TYPE_ERROR) return "TypeError";
  if (id == BUILTIN_REFERENCE_ERROR) return "ReferenceError";
  if (id == BUILTIN_RANGE_ERROR) return "RangeError";
  return "SyntaxError";
}

export struct RunResult {
  isThrow: boolean;
  value: Value;
}

export struct Runtime {
  heap: Heap;
  functions: Array<FunctionCode>;
  globals: Array<Global>;
  // Interned strings: open-addressed table of string cell handles, keyed by
  // the bytes' hash. 0 marks an empty bucket (handle 0 is never a cell).
  atoms: Array<u32>;
  atomCount: u32;
  // The register stack and frame stack grow monotonically and are reused;
  // `regTop` / `frameCount` mark the live extent. This is the reference's
  // model, and it sidesteps Z's Array having no pop.
  regStack: Array<Value>;
  regTop: u32;
  frames: Array<Frame>;
  frameCount: u32;
  hadError: boolean;
  lastError: Value;
  // The `this` of the running function.
  hostThis: Value;
  // Try handlers, live to `tryDepth`.
  tryStack: Array<TryFrame>;
  tryDepth: u32;
  // A throw raised by a helper (property access, a builtin) for the
  // dispatch loop to pick up after the call returns.
  pendingThrow: boolean;
  pendingValue: Value;
  // Realm: the intrinsic prototypes, as cell handles.
  objectProto: u32;
  functionProto: u32;
  arrayProto: u32;
  stringProto: u32;
  // Atoms the runtime consults by identity.
  atomLength: u32;
  atomPrototype: u32;
  atomConstructor: u32;
  atomName: u32;
  atomMessage: u32;

  function addFunction(inout this, code: FunctionCode): u32 {
    this.functions.push(move code);
    return u32(this.functions.length - 1);
  }

  // Reserve a function index before its body is compiled, so a named
  // function expression can refer to itself; fill it in afterwards.
  function reserveFunction(inout this): u32 {
    this.functions.push(createFunctionCode());
    return u32(this.functions.length - 1);
  }

  function setFunction(inout this, index: u32, code: FunctionCode): void {
    this.functions[usize(index)] = move code;
  }

  function functionValue(inout this, index: u32): Value {
    return cellValue(this.heap.allocateFunction(index));
  }

  function isFunctionValue(value: Value): boolean {
    return isCell(value) && asCell(value) != 0 && this.heap.isFunction(asCell(value));
  }

  // A global that a hoisted declaration defines before any statement runs.
  function defineGlobalSlot(inout this, name: String): u16 {
    const slot = this.globalSlot(move name);
    this.globals[usize(slot)].defined = true;
    return slot;
  }

  // Global slot for a name, allocating one on first sight. Linear for now.
  function globalSlot(inout this, name: String): u16 {
    let index: usize = 0;
    while (index < this.globals.length) {
      if (this.globals[index].name == name) return u16(index);
      index = index + 1;
    }
    this.globals.push(Global({ name: move name, value: undefinedValue(), defined: false }));
    return u16(this.globals.length - 1);
  }

  // --- Strings ---

  function isStringValue(value: Value): boolean {
    return isCell(value) && asCell(value) != 0 && this.heap.isString(asCell(value));
  }

  function hashBytes(in bytes: Array<u8>): u32 {
    let hash: u32 = 2166136261;
    let index: usize = 0;
    const length = bytes.length;
    while (index < length) {
      hash = (hash ^ u32(bytes[index])).wrappingMultiply(16777619);
      index = index + 1;
    }
    return hash;
  }

  function atomMatches(handle: u32, in bytes: Array<u8>): boolean {
    const length = bytes.length;
    if (this.heap.stringLength(handle) != length) return false;
    let index: usize = 0;
    while (index < length) {
      if (this.heap.stringByte(handle, index) != bytes[index]) return false;
      index = index + 1;
    }
    return true;
  }

  function growAtoms(inout this): void {
    const oldSize = this.atoms.length;
    const initial: usize = 64;
    const newSize = oldSize == 0 ? initial : oldSize * 2;
    let rebuilt = Array<u32>();
    let fill: usize = 0;
    while (fill < newSize) {
      rebuilt.push(0);
      fill = fill + 1;
    }
    let index: usize = 0;
    while (index < oldSize) {
      const handle = this.atoms[index];
      if (handle != 0) {
        const bytes = this.heap.stringBytes(handle);
        let slot = usize(this.hashBytes(in bytes)) & (newSize - 1);
        while (rebuilt[slot] != 0) { slot = (slot + 1) & (newSize - 1); }
        rebuilt[slot] = handle;
      }
      index = index + 1;
    }
    this.atoms = move rebuilt;
  }

  // The unique string cell for these bytes.
  function internBytes(inout this, bytes: Array<u8>): u32 {
    if ((usize(this.atomCount) + 1) * 2 > this.atoms.length) this.growAtoms();
    const mask = this.atoms.length - 1;
    let slot = usize(this.hashBytes(in bytes)) & mask;
    while (true) {
      const existing = this.atoms[slot];
      if (existing == 0) break;
      if (this.atomMatches(existing, in bytes)) return existing;
      slot = (slot + 1) & mask;
    }
    const handle = this.heap.allocateString(move bytes);
    this.atoms[slot] = handle;
    this.atomCount = this.atomCount + 1;
    return handle;
  }

  function internValue(inout this, bytes: Array<u8>): Value {
    return cellValue(this.internBytes(move bytes));
  }

  function internText(inout this, in text: String): Value {
    return cellValue(this.internBytes(bytesOf(in text)));
  }

  // A fresh (non-interned) string cell.
  function newString(inout this, bytes: Array<u8>): Value {
    return cellValue(this.heap.allocateString(move bytes));
  }

  // --- Objects and properties ---

  function isObjectLike(value: Value): boolean {
    if (!isCell(value) || asCell(value) == 0) return false;
    const tag = this.heap.tagOf(asCell(value));
    return tag == TAG_OBJECT || tag == TAG_ARRAY || tag == TAG_FUNCTION || tag == TAG_HOST_FUNCTION || tag == TAG_CLOSURE;
  }

  function isHostFunctionValue(value: Value): boolean {
    return isCell(value) && asCell(value) != 0 && this.heap.isHostFunction(asCell(value));
  }

  function isClosureValue(value: Value): boolean {
    return isCell(value) && asCell(value) != 0 && this.heap.isClosure(asCell(value));
  }

  // A value with compiled code behind it: a plain function or a closure.
  function isCompiledCallable(value: Value): boolean {
    return this.isFunctionValue(value) || this.isClosureValue(value);
  }

  function isCallable(value: Value): boolean {
    return this.isCompiledCallable(value) || this.isHostFunctionValue(value);
  }

  function atomOf(inout this, in text: String): u32 {
    return this.internBytes(bytesOf(in text));
  }

  // Raise from a helper; the dispatch loop consumes it after the call.
  function raise(inout this, value: Value): void {
    this.pendingThrow = true;
    this.pendingValue = value;
  }

  function takePending(inout this): Value {
    const value = this.pendingValue;
    this.pendingThrow = false;
    this.pendingValue = undefinedValue();
    return value;
  }

  // The prototype of the named error constructor, or 0 before builtins.
  function errorPrototype(inout this, kind: u32): u32 {
    const slot = this.globalSlot(builtinName(kind));
    const ctor = this.globals[usize(slot)].value;
    if (!this.isHostFunctionValue(ctor)) return 0;
    return this.heap.linkOf(asCell(ctor));
  }

  // An error object the engine throws itself: `name` and `message` as own
  // properties, prototype from the matching constructor.
  function makeError(inout this, kind: u32, message: Array<u8>): Value {
    const proto = this.errorPrototype(kind);
    const object = this.heap.allocateObject(proto);
    const kindName = builtinName(kind);
    const nameValue = this.internText(in kindName);
    const atomName = this.atomName;
    this.heap.objectSet(object, atomName, nameValue);
    const messageValue = this.newString(move message);
    const atomMessage = this.atomMessage;
    this.heap.objectSet(object, atomMessage, messageValue);
    return cellValue(object);
  }

  function typeError(inout this, in message: String): Value {
    return this.makeError(BUILTIN_TYPE_ERROR, bytesOf(in message));
  }

  // A property key as an atom handle: strings intern their bytes; anything
  // else goes through ToString first.
  function propertyKey(inout this, key: Value): u32 {
    if (this.isStringValue(key)) return this.internBytes(this.heap.stringBytes(asCell(key)));
    const text = this.toStringValue(key);
    const textBytes = this.heap.stringBytes(asCell(text));
    return this.internBytes(textBytes);
  }

  // A key that names an array element: a non-negative int32, an integral
  // double, or the canonical decimal spelling of one. Otherwise -1.
  function arrayIndexOf(key: Value): i32 {
    if (isInt32(key)) return asInt32(key) >= 0 ? asInt32(key) : -1;
    if (isDouble(key)) {
      const d = asDouble(key);
      if (d >= 0.0 && d < 2147483648.0 && f64(i32(d)) == d) return i32(d);
      return -1;
    }
    if (!this.isStringValue(key)) return -1;
    const handle = asCell(key);
    const length = this.heap.stringLength(handle);
    if (length == 0 || length > 10) return -1;
    if (length > 1 && this.heap.stringByte(handle, 0) == 48) return -1;
    let value: i64 = 0;
    let index: usize = 0;
    while (index < length) {
      const byte = this.heap.stringByte(handle, index);
      if (byte < 48 || byte > 57) return -1;
      value = value * 10 + i64(byte - 48);
      index = index + 1;
    }
    if (value > 2147483647) return -1;
    return i32(value);
  }

  // Own-or-inherited data property of an object cell.
  function objectGet(handle: u32, atom: u32): Value {
    let current = handle;
    while (current != 0) {
      const slot = this.heap.objectFindSlot(current, atom);
      if (slot >= 0) {
        const value = this.heap.slot(current, u32(slot));
        if (!isDeleted(value)) return value;
      }
      current = this.heap.objectProto(current);
    }
    return undefinedValue();
  }

  // A function's `prototype` object, created on first use with a
  // `constructor` back-reference.
  function prototypeOf(inout this, fn: u32): u32 {
    const closure = this.heap.isClosure(fn);
    if (closure) {
      const held = this.heap.slot(fn, 1);
      if (isCell(held) && asCell(held) != 0) return asCell(held);
    } else {
      const existing = this.heap.linkOf(fn);
      if (existing != 0) return existing;
    }
    const objectProto = this.objectProto;
    const created = this.heap.allocateObject(objectProto);
    const atomConstructor = this.atomConstructor;
    this.heap.objectSet(created, atomConstructor, cellValue(fn));
    if (closure) {
      this.heap.setSlot(fn, 1, cellValue(created));
    } else {
      this.heap.setLink(fn, created);
    }
    return created;
  }

  // The bag of named properties on an array, created on first use.
  function arrayBag(inout this, array: u32): u32 {
    const existing = this.heap.linkOf(array);
    if (existing != 0) return existing;
    const created = this.heap.allocateObject(0);
    this.heap.setLink(array, created);
    return created;
  }

  // [[Get]] for every value the engine has. Absent properties are
  // undefined; primitives read from their intrinsic prototype.
  function getProperty(inout this, object: Value, key: Value): Value {
    if (!isCell(object) || asCell(object) == 0) return undefinedValue();
    const handle = asCell(object);
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_OBJECT) {
      const atom = this.propertyKey(key);
      return this.objectGet(handle, atom);
    }
    if (tag == TAG_ARRAY) {
      const index = this.arrayIndexOf(key);
      if (index >= 0) {
        if (this.heap.arrayHasIndex(handle, u32(index))) return this.heap.arrayGet(handle, u32(index));
        const arrayProto = this.arrayProto;
        const atom = this.propertyKey(key);
        return this.objectGet(arrayProto, atom);
      }
      const atom = this.propertyKey(key);
      if (atom == this.atomLength) return int32Value(i32(this.heap.arrayLength(handle)));
      const bag = this.heap.linkOf(handle);
      if (bag != 0) {
        const slot = this.heap.objectFindSlot(bag, atom);
        if (slot >= 0) return this.heap.slot(bag, u32(slot));
      }
      const arrayProto = this.arrayProto;
      return this.objectGet(arrayProto, atom);
    }
    if (this.heap.isString(handle)) {
      const index = this.arrayIndexOf(key);
      if (index >= 0) {
        if (usize(index) >= this.heap.stringLength(handle)) return undefinedValue();
        let one = Array<u8>();
        one.push(this.heap.stringByte(handle, usize(index)));
        return this.internValue(move one);
      }
      const atom = this.propertyKey(key);
      if (atom == this.atomLength) return int32Value(i32(this.heap.stringLength(handle)));
      const stringProto = this.stringProto;
      return this.objectGet(stringProto, atom);
    }
    if (tag == TAG_FUNCTION || tag == TAG_HOST_FUNCTION || tag == TAG_CLOSURE) {
      const atom = this.propertyKey(key);
      if (atom == this.atomPrototype) return cellValue(this.prototypeOf(handle));
      const functionProto = this.functionProto;
      return this.objectGet(functionProto, atom);
    }
    return undefinedValue();
  }

  // [[Set]]. Writes to primitives are silently dropped, as in sloppy
  // mode; attribute and setter checks arrive with property descriptors.
  function setProperty(inout this, object: Value, key: Value, value: Value): void {
    if (!isCell(object) || asCell(object) == 0) return;
    const handle = asCell(object);
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_OBJECT) {
      const atom = this.propertyKey(key);
      this.heap.objectSet(handle, atom, value);
      return;
    }
    if (tag == TAG_ARRAY) {
      const index = this.arrayIndexOf(key);
      if (index >= 0) {
        this.heap.arraySet(handle, u32(index), value);
        return;
      }
      const atom = this.propertyKey(key);
      if (atom == this.atomLength) {
        this.heap.setArrayLength(handle, toUint32(value));
        return;
      }
      const bag = this.arrayBag(handle);
      this.heap.objectSet(bag, atom, value);
      return;
    }
    if (tag == TAG_FUNCTION || tag == TAG_HOST_FUNCTION) {
      const atom = this.propertyKey(key);
      if (atom == this.atomPrototype && this.isObjectLike(value)) this.heap.setLink(handle, asCell(value));
      return;
    }
    if (tag == TAG_CLOSURE) {
      const atom = this.propertyKey(key);
      if (atom == this.atomPrototype && this.isObjectLike(value)) this.heap.setSlot(handle, 1, value);
      return;
    }
  }

  function typeofValue(inout this, value: Value): Value {
    let label: String = "object";
    if (isUndefined(value)) {
      label = "undefined";
    } else if (isNull(value)) {
      label = "object";
    } else if (isBoolean(value)) {
      label = "boolean";
    } else if (isNumber(value)) {
      label = "number";
    } else if (this.isStringValue(value)) {
      label = "string";
    } else if (this.isCallable(value)) {
      label = "function";
    }
    return this.internText(in label);
  }

  // --- Builtins ---

  function hostFunctionValue(inout this, id: u32): Value {
    return cellValue(this.heap.allocateHostFunction(id));
  }

  // Call a builtin with its arguments in the register stack.
  function callHost(inout this, id: u32, thisValue: Value, argsBase: u32, argc: u32): Value {
    if (id < BUILTIN_COUNT) return this.constructError(id, thisValue, argsBase, argc);
    return undefinedValue();
  }

  // The Error constructors, called or constructed. An object under
  // construction arrives as `this`; a plain call makes its own.
  function constructError(inout this, kind: u32, thisValue: Value, argsBase: u32, argc: u32): Value {
    let object: u32 = 0;
    if (isCell(thisValue) && asCell(thisValue) != 0 && this.heap.isObject(asCell(thisValue))) {
      object = asCell(thisValue);
    } else {
      const proto = this.errorPrototype(kind);
      object = this.heap.allocateObject(proto);
    }
    if (argc > 0) {
      const first = this.regStack[usize(argsBase)];
      if (!isUndefined(first)) {
        const message = this.toStringValue(first);
        const atomMessage = this.atomMessage;
        this.heap.objectSet(object, atomMessage, message);
      }
    }
    const kindName = builtinName(kind);
    const nameValue = this.internText(in kindName);
    const atomName = this.atomName;
    this.heap.objectSet(object, atomName, nameValue);
    return cellValue(object);
  }

  function setGlobal(inout this, name: String, value: Value): void {
    const slot = this.defineGlobalSlot(move name);
    this.globals[usize(slot)].value = value;
  }

  // The intrinsics every context starts with.
  function installBuiltins(inout this): void {
    const lengthText: String = "length";
    const prototypeText: String = "prototype";
    const constructorText: String = "constructor";
    const nameText: String = "name";
    const messageText: String = "message";
    this.atomLength = this.atomOf(in lengthText);
    this.atomPrototype = this.atomOf(in prototypeText);
    this.atomConstructor = this.atomOf(in constructorText);
    this.atomName = this.atomOf(in nameText);
    this.atomMessage = this.atomOf(in messageText);
    this.objectProto = this.heap.allocateObject(0);
    const objectProto = this.objectProto;
    this.functionProto = this.heap.allocateObject(objectProto);
    this.arrayProto = this.heap.allocateObject(objectProto);
    this.stringProto = this.heap.allocateObject(objectProto);
    // Error, then the subclasses whose prototypes inherit from its.
    let errorProto: u32 = 0;
    let kind: u32 = 0;
    while (kind < BUILTIN_COUNT) {
      const ctor = this.heap.allocateHostFunction(kind);
      const parentProto = kind == BUILTIN_ERROR ? this.objectProto : errorProto;
      const proto = this.heap.allocateObject(parentProto);
      if (kind == BUILTIN_ERROR) errorProto = proto;
      const kindName = builtinName(kind);
      const nameValue = this.internText(in kindName);
      const atomName = this.atomName;
      this.heap.objectSet(proto, atomName, nameValue);
      const emptyMessage = this.internValue(Array<u8>());
      const atomMessage = this.atomMessage;
      this.heap.objectSet(proto, atomMessage, emptyMessage);
      const atomConstructor = this.atomConstructor;
      this.heap.objectSet(proto, atomConstructor, cellValue(ctor));
      this.heap.setLink(ctor, proto);
      this.setGlobal(builtinName(kind), cellValue(ctor));
      kind = kind + 1;
    }
  }

  // --- Coercions that need the heap ---

  // An arithmetic operand: numbers pass through; anything else goes
  // through ToNumber, which for strings and arrays needs the heap.
  function numericOperand(inout this, value: Value): Value {
    if (isNumber(value)) return value;
    return doubleValue(this.toNumberValue(value));
  }

  function toNumberValue(inout this, value: Value): f64 {
    if (this.isStringValue(value)) {
      const bytes = this.heap.stringBytes(asCell(value));
      return stringToNumber(in bytes);
    }
    if (isCell(value) && asCell(value) != 0 && this.heap.isArray(asCell(value))) {
      const text = this.toStringValue(value);
      const bytes = this.heap.stringBytes(asCell(text));
      return stringToNumber(in bytes);
    }
    return toNumber(value);
  }

  function toBooleanValue(value: Value): boolean {
    if (this.isStringValue(value)) return this.heap.stringLength(asCell(value)) > 0;
    if (isCell(value) && asCell(value) != 0) return true;
    return toBoolean(value);
  }

  // ToString. Objects have no user-visible toString yet, so they render
  // the way the reference renders an object without one.
  function toStringValue(inout this, value: Value): Value {
    if (this.isStringValue(value)) return value;
    if (isCell(value) && asCell(value) != 0) {
      const handle = asCell(value);
      if (this.heap.isArray(handle)) return this.joinArray(handle);
      if (this.isCallable(value)) {
        const functionText: String = "function";
        return this.internText(in functionText);
      }
      const objectText: String = "[object Object]";
      return this.internText(in objectText);
    }
    if (isInt32(value)) {
      const text = int32ToString(asInt32(value));
      return this.internText(in text);
    }
    if (isDouble(value)) {
      const text = doubleToString(asDouble(value));
      return this.internText(in text);
    }
    if (isBoolean(value)) {
      const text: String = isTrue(value) ? "true" : "false";
      return this.internText(in text);
    }
    if (isNull(value)) {
      const nullText: String = "null";
      return this.internText(in nullText);
    }
    const undefinedText: String = "undefined";
    return this.internText(in undefinedText);
  }

  // Array.prototype.join with the default separator: holes, null, and
  // undefined are empty.
  function joinArray(inout this, array: u32): Value {
    let joined = Array<u8>();
    const length = this.heap.arrayLength(array);
    let index: u32 = 0;
    while (index < length) {
      if (index > 0) joined.push(44);
      const element = this.heap.arrayGet(array, index);
      if (!isUndefined(element) && !isNull(element)) {
        const text = this.toStringValue(element);
        const handle = asCell(text);
        const count = this.heap.stringLength(handle);
        let i: usize = 0;
        while (i < count) {
          joined.push(this.heap.stringByte(handle, i));
          i = i + 1;
        }
      }
      index = index + 1;
    }
    return this.newString(move joined);
  }

  function concatStrings(inout this, a: Value, b: Value): Value {
    const left = this.toStringValue(a);
    const right = this.toStringValue(b);
    const leftHandle = asCell(left);
    const rightHandle = asCell(right);
    if (this.heap.stringLength(leftHandle) == 0) return right;
    if (this.heap.stringLength(rightHandle) == 0) return left;
    let joined = this.heap.stringBytes(leftHandle);
    const rightLength = this.heap.stringLength(rightHandle);
    let index: usize = 0;
    while (index < rightLength) {
      joined.push(this.heap.stringByte(rightHandle, index));
      index = index + 1;
    }
    return this.newString(move joined);
  }

  // --- Equality and ordering ---

  function strictEquals(a: Value, b: Value): boolean {
    if (isInt32(a) && isInt32(b)) return asInt32(a) == asInt32(b);
    if (isNumber(a) && isNumber(b)) return toNumber(a) == toNumber(b);
    if (this.isStringValue(a) && this.isStringValue(b)) return this.heap.stringsEqual(asCell(a), asCell(b));
    return a.bits == b.bits;
  }

  function looseEquals(inout this, a: Value, b: Value): boolean {
    if (isInt32(a) && isInt32(b)) return asInt32(a) == asInt32(b);
    if (isNumber(a) && isNumber(b)) return toNumber(a) == toNumber(b);
    const aString = this.isStringValue(a);
    const bString = this.isStringValue(b);
    if (aString && bString) return this.heap.stringsEqual(asCell(a), asCell(b));
    if (isBoolean(a) && isBoolean(b)) return a.bits == b.bits;
    const aNullish = isNull(a) || isUndefined(a);
    const bNullish = isNull(b) || isUndefined(b);
    if (aNullish && bNullish) return true;
    if (isNumber(a) && bString) return toNumber(a) == this.toNumberValue(b);
    if (aString && isNumber(b)) return this.toNumberValue(a) == toNumber(b);
    if (isBoolean(a)) return this.looseEquals(int32Value(isTrue(a) ? 1 : 0), b);
    if (isBoolean(b)) return this.looseEquals(a, int32Value(isTrue(b) ? 1 : 0));
    return false;
  }

  // Relational comparison. `orEqual` selects <= over <; swap operands for
  // > and >=.
  function lessThan(inout this, a: Value, b: Value, orEqual: boolean): boolean {
    if (this.isStringValue(a) && this.isStringValue(b)) {
      const order = this.heap.compareStrings(asCell(a), asCell(b));
      return orEqual ? order <= 0 : order < 0;
    }
    const af = this.toNumberValue(a);
    const bf = this.toNumberValue(b);
    if (af != af || bf != bf) return false;
    return orEqual ? af <= bf : af < bf;
  }

  // --- Frames ---

  function pushFrame(inout this, functionIndex: u32, returnDst: u8): void {
    let regCount = this.functions[usize(functionIndex)].registerCount;
    const paramCount = this.functions[usize(functionIndex)].paramCount;
    if (regCount < paramCount) regCount = paramCount;
    const base = this.regTop;
    const needed = usize(base + regCount);
    while (this.regStack.length < needed) { this.regStack.push(undefinedValue()); }
    let i: u32 = 0;
    while (i < regCount) {
      this.regStack[usize(base + i)] = undefinedValue();
      i = i + 1;
    }
    this.regTop = base + regCount;
    const frame = Frame({
      functionIndex: functionIndex, ip: 0, regsBase: base, regCount: regCount, returnDst: returnDst,
      savedThis: this.hostThis, tryDepthAtEntry: this.tryDepth, constructThis: undefinedValue(),
      env: 0, callee: undefinedValue(),
    });
    if (usize(this.frameCount) < this.frames.length) {
      this.frames[usize(this.frameCount)] = frame;
    } else {
      this.frames.push(frame);
    }
    this.frameCount = this.frameCount + 1;
  }

  function popFrame(inout this): Frame {
    this.frameCount = this.frameCount - 1;
    const frame = this.frames[usize(this.frameCount)];
    this.regTop = frame.regsBase;
    this.hostThis = frame.savedThis;
    if (this.tryDepth > frame.tryDepthAtEntry) this.tryDepth = frame.tryDepthAtEntry;
    return frame;
  }

  // Push a call through a function or closure value: arguments from the
  // caller's registers, `this` bound (an arrow's is the one it captured),
  // the closure's environment installed, the constructed object (if any)
  // recorded.
  function enterCallable(inout this, callee: Value, returnDst: u8, thisValue: Value, argsBase: u32, argc: u32, constructThis: Value): void {
    const handle = asCell(callee);
    const target = this.heap.functionIndex(handle);
    let env: u32 = 0;
    let boundThis = thisValue;
    if (this.heap.isClosure(handle)) {
      env = this.heap.linkOf(handle);
      if (this.functions[usize(target)].isArrow) boundThis = this.heap.slot(handle, 0);
    }
    this.enterFunction(target, returnDst, boundThis, argsBase, argc, constructThis);
    const top = usize(this.frameCount - 1);
    this.frames[top].env = env;
    this.frames[top].callee = callee;
  }

  // Push a call to a compiled function: arguments from the caller's
  // registers, `this` bound, the constructed object (if any) recorded.
  function enterFunction(inout this, target: u32, returnDst: u8, thisValue: Value, argsBase: u32, argc: u32, constructThis: Value): void {
    this.pushFrame(target, returnDst);
    const top = usize(this.frameCount - 1);
    const calleeBase = this.frames[top].regsBase;
    const paramCount = this.functions[usize(target)].paramCount;
    const copied = argc < paramCount ? argc : paramCount;
    let arg: u32 = 0;
    while (arg < copied) {
      const passed = this.regStack[usize(argsBase + arg)];
      this.regStack[usize(calleeBase + arg)] = passed;
      arg = arg + 1;
    }
    this.hostThis = thisValue;
    this.frames[top].constructThis = constructThis;
    const thisReg = this.functions[usize(target)].thisReg;
    if (thisReg >= 0) this.setReg(calleeBase, u8(thisReg), thisValue);
  }

  function pushTry(inout this, catchIp: usize, catchReg: u8): void {
    const frame = TryFrame({ frameIndex: this.frameCount - 1, catchIp: catchIp, catchReg: catchReg });
    if (usize(this.tryDepth) < this.tryStack.length) {
      this.tryStack[usize(this.tryDepth)] = frame;
    } else {
      this.tryStack.push(frame);
    }
    this.tryDepth = this.tryDepth + 1;
  }

  function reg(base: u32, index: u8): Value {
    return this.regStack[usize(base + u32(index))];
  }

  function setReg(inout this, base: u32, index: u8, value: Value): void {
    this.regStack[usize(base + u32(index))] = value;
  }

  // --- Interpreter ---

  // Every operand is bound before a `setReg` call: Z rejects a value use
  // of `this` inside a call that borrows `this` mutably.
  function run(inout this, functionIndex: u32): RunResult {
    const entryDepth = this.frameCount;
    this.pushFrame(functionIndex, 0);
    let result = undefinedValue();
    while (this.frameCount > entryDepth) {
      const frameIndex = usize(this.frameCount - 1);
      const fi = this.frames[frameIndex].functionIndex;
      const base = this.frames[frameIndex].regsBase;
      let ip = this.frames[frameIndex].ip;
      const codeLength = this.functions[usize(fi)].code.length;
      let returned = false;
      let throwing = false;
      let thrown = undefinedValue();
      while (ip < codeLength && !returned && !throwing) {
        const inst = this.functions[usize(fi)].code[ip];
        ip = ip + 1;
        const op = inst.op;

        if (op == Op.loadInt) {
          this.setReg(base, inst.a, int32Value(bcI16(inst)));
        } else if (op == Op.loadConst) {
          const operand1 = this.functions[usize(fi)].constants[usize(bcU16(inst))];
          this.setReg(base, inst.a, operand1);
        } else if (op == Op.loadUndefined) {
          this.setReg(base, inst.a, undefinedValue());
        } else if (op == Op.loadNull) {
          this.setReg(base, inst.a, nullValue());
        } else if (op == Op.loadTrue) {
          this.setReg(base, inst.a, booleanValue(true));
        } else if (op == Op.loadFalse) {
          this.setReg(base, inst.a, booleanValue(false));
        } else if (op == Op.mov) {
          const operand2 = this.reg(base, inst.b);
          this.setReg(base, inst.a, operand2);
        } else if (op == Op.defineGlobal) {
          const slot = usize(bcU16(inst));
          this.globals[slot].value = this.reg(base, inst.a);
          this.globals[slot].defined = true;
        } else if (op == Op.storeGlobal) {
          const slot = usize(bcU16(inst));
          this.globals[slot].value = this.reg(base, inst.a);
          this.globals[slot].defined = true;
        } else if (op == Op.loadGlobal) {
          const slot = usize(bcU16(inst));
          if (!this.globals[slot].defined) {
            const nameLength = this.globals[slot].name.byteLength;
            const name = this.globals[slot].name.copyBytes(0, nameLength);
            const text: String = `${name} is not defined`;
            thrown = this.makeError(BUILTIN_REFERENCE_ERROR, bytesOf(in text));
            throwing = true;
          } else {
            const operand3 = this.globals[slot].value;
            this.setReg(base, inst.a, operand3);
          }
        } else if (op == Op.loadGlobalOrUndefined) {
          const slot = usize(bcU16(inst));
          const operand4 = this.globals[slot].defined ? this.globals[slot].value : undefinedValue();
          this.setReg(base, inst.a, operand4);
        } else if (op == Op.add) {
          const left = this.reg(base, inst.b);
          const right = this.reg(base, inst.c);
          if (this.isStringValue(left) || this.isStringValue(right)) {
            const joined = this.concatStrings(left, right);
            this.setReg(base, inst.a, joined);
          } else {
            const sum = numericAdd(left, right);
            this.setReg(base, inst.a, sum);
          }
        } else if (op == Op.cmpEq || op == Op.cmpNe) {
          const operandB = this.reg(base, inst.b);
          const operandC = this.reg(base, inst.c);
          const equal = this.looseEquals(operandB, operandC);
          this.setReg(base, inst.a, booleanValue(op == Op.cmpEq ? equal : !equal));
        } else if (op == Op.cmpStrictEq || op == Op.cmpStrictNe) {
          const operandB = this.reg(base, inst.b);
          const operandC = this.reg(base, inst.c);
          const equal = this.strictEquals(operandB, operandC);
          this.setReg(base, inst.a, booleanValue(op == Op.cmpStrictEq ? equal : !equal));
        } else if (op == Op.cmpLt) {
          const operandB = this.reg(base, inst.b);
          const operandC = this.reg(base, inst.c);
          const outcome = this.lessThan(operandB, operandC, false);
          this.setReg(base, inst.a, booleanValue(outcome));
        } else if (op == Op.cmpLe) {
          const operandB = this.reg(base, inst.b);
          const operandC = this.reg(base, inst.c);
          const outcome = this.lessThan(operandB, operandC, true);
          this.setReg(base, inst.a, booleanValue(outcome));
        } else if (op == Op.cmpGt) {
          const operandC = this.reg(base, inst.c);
          const operandB = this.reg(base, inst.b);
          const outcome = this.lessThan(operandC, operandB, false);
          this.setReg(base, inst.a, booleanValue(outcome));
        } else if (op == Op.cmpGe) {
          const operandC = this.reg(base, inst.c);
          const operandB = this.reg(base, inst.b);
          const outcome = this.lessThan(operandC, operandB, true);
          this.setReg(base, inst.a, booleanValue(outcome));
        } else if (op == Op.jmp) {
          ip = usize(i64(ip) + i64(bcI16(inst)));
        } else if (op == Op.jmpIfTrue) {
          const operandA = this.reg(base, inst.a);
          if (this.toBooleanValue(operandA)) ip = usize(i64(ip) + i64(bcI16(inst)));
        } else if (op == Op.jmpIfFalse) {
          const operandA = this.reg(base, inst.a);
          if (!this.toBooleanValue(operandA)) ip = usize(i64(ip) + i64(bcI16(inst)));
        } else if (op == Op.jmpIfNotNullish) {
          const tested = this.reg(base, inst.a);
          if (!(isNull(tested) || isUndefined(tested))) ip = usize(i64(ip) + i64(bcI16(inst)));
        } else if (op == Op.jmpIfNullish) {
          const tested = this.reg(base, inst.a);
          if (isNull(tested) || isUndefined(tested)) ip = usize(i64(ip) + i64(bcI16(inst)));
        } else if (op == Op.sub) {
          const rawB = this.reg(base, inst.b);
          const numberB = this.numericOperand(rawB);
          const rawC = this.reg(base, inst.c);
          const numberC = this.numericOperand(rawC);
          const operand5 = numericSub(numberB, numberC);
          this.setReg(base, inst.a, operand5);
        } else if (op == Op.mul) {
          const rawB = this.reg(base, inst.b);
          const numberB = this.numericOperand(rawB);
          const rawC = this.reg(base, inst.c);
          const numberC = this.numericOperand(rawC);
          const operand6 = numericMul(numberB, numberC);
          this.setReg(base, inst.a, operand6);
        } else if (op == Op.div) {
          const rawB = this.reg(base, inst.b);
          const numberB = this.numericOperand(rawB);
          const rawC = this.reg(base, inst.c);
          const numberC = this.numericOperand(rawC);
          const operand7 = numericDiv(numberB, numberC);
          this.setReg(base, inst.a, operand7);
        } else if (op == Op.mod) {
          const rawB = this.reg(base, inst.b);
          const numberB = this.numericOperand(rawB);
          const rawC = this.reg(base, inst.c);
          const numberC = this.numericOperand(rawC);
          const operand8 = numericMod(numberB, numberC);
          this.setReg(base, inst.a, operand8);
        } else if (op == Op.pow) {
          const operand9 = doubleValue(nativePow(toNumber(this.reg(base, inst.b)), toNumber(this.reg(base, inst.c))));
          this.setReg(base, inst.a, operand9);
        } else if (op == Op.neg) {
          const rawB = this.reg(base, inst.b);
          const numberB = this.numericOperand(rawB);
          const operand10 = numericNeg(numberB);
          this.setReg(base, inst.a, operand10);
        } else if (op == Op.logicalNot) {
          const operandB = this.reg(base, inst.b);
          const negated = booleanValue(!this.toBooleanValue(operandB));
          this.setReg(base, inst.a, negated);
        } else if (op == Op.bitNot) {
          const rawB = this.reg(base, inst.b);
          const numberB = this.numericOperand(rawB);
          const operand12 = int32Value(~toInt32(numberB));
          this.setReg(base, inst.a, operand12);
        } else if (op == Op.bitAnd) {
          const rawB = this.reg(base, inst.b);
          const numberB = this.numericOperand(rawB);
          const rawC = this.reg(base, inst.c);
          const numberC = this.numericOperand(rawC);
          const operand13 = int32Value(toInt32(numberB) & toInt32(numberC));
          this.setReg(base, inst.a, operand13);
        } else if (op == Op.bitOr) {
          const rawB = this.reg(base, inst.b);
          const numberB = this.numericOperand(rawB);
          const rawC = this.reg(base, inst.c);
          const numberC = this.numericOperand(rawC);
          const operand14 = int32Value(toInt32(numberB) | toInt32(numberC));
          this.setReg(base, inst.a, operand14);
        } else if (op == Op.bitXor) {
          const rawB = this.reg(base, inst.b);
          const numberB = this.numericOperand(rawB);
          const rawC = this.reg(base, inst.c);
          const numberC = this.numericOperand(rawC);
          const operand15 = int32Value(toInt32(numberB) ^ toInt32(numberC));
          this.setReg(base, inst.a, operand15);
        } else if (op == Op.shl) {
          const rawC = this.reg(base, inst.c);
          const numberC = this.numericOperand(rawC);
          const shift = u32(toUint32(numberC) & 31);
          const rawB = this.reg(base, inst.b);
          const numberB = this.numericOperand(rawB);
          const operand16 = int32Value(i32.fromBits(toInt32(numberB).toBits() << shift));
          this.setReg(base, inst.a, operand16);
        } else if (op == Op.shr) {
          const rawC = this.reg(base, inst.c);
          const numberC = this.numericOperand(rawC);
          const shift = u32(toUint32(numberC) & 31);
          const rawB = this.reg(base, inst.b);
          const numberB = this.numericOperand(rawB);
          const operand17 = int32Value(toInt32(numberB) >> i32(shift));
          this.setReg(base, inst.a, operand17);
        } else if (op == Op.uShr) {
          const rawC = this.reg(base, inst.c);
          const numberC = this.numericOperand(rawC);
          const shift = u32(toUint32(numberC) & 31);
          const rawB = this.reg(base, inst.b);
          const numberB = this.numericOperand(rawB);
          const shifted = toUint32(numberB) >> shift;
          this.setReg(base, inst.a, uint32ToValue(shifted));
        } else if (op == Op.invoke) {
          // Callee at b, arguments above it, result into a. A compiled
          // callee gets a frame and the outer loop resumes on it; a
          // builtin runs to completion here. A plain call binds `this`
          // to undefined: there is no global object yet.
          const callee = this.reg(base, inst.b);
          const argc = u32(inst.c);
          const argsBase = base + u32(inst.b) + 1;
          if (this.isCompiledCallable(callee)) {
            this.frames[frameIndex].ip = ip;
            this.enterCallable(callee, inst.a, undefinedValue(), argsBase, argc, undefinedValue());
            returned = true;
          } else if (this.isHostFunctionValue(callee)) {
            const builtin = this.heap.hostFunctionId(asCell(callee));
            const outcome = this.callHost(builtin, undefinedValue(), argsBase, argc);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else {
              this.setReg(base, inst.a, outcome);
            }
          } else {
            const message: String = "value is not a function";
            thrown = this.typeError(in message);
            throwing = true;
          }
        } else if (op == Op.methodInvoke) {
          // Callee at b, receiver at b + 1, arguments above.
          const callee = this.reg(base, inst.b);
          const receiver = this.reg(base, inst.b + 1);
          const argc = u32(inst.c);
          const argsBase = base + u32(inst.b) + 2;
          if (this.isCompiledCallable(callee)) {
            this.frames[frameIndex].ip = ip;
            this.enterCallable(callee, inst.a, receiver, argsBase, argc, undefinedValue());
            returned = true;
          } else if (this.isHostFunctionValue(callee)) {
            const builtin = this.heap.hostFunctionId(asCell(callee));
            const outcome = this.callHost(builtin, receiver, argsBase, argc);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else {
              this.setReg(base, inst.a, outcome);
            }
          } else {
            const message: String = "property is not a function";
            thrown = this.typeError(in message);
            throwing = true;
          }
        } else if (op == Op.newInvoke) {
          // Construct: a fresh object whose prototype is the callee's
          // `prototype` becomes `this`; the body's return value replaces
          // it only when that value is an object.
          const callee = this.reg(base, inst.b);
          const argc = u32(inst.c);
          const argsBase = base + u32(inst.b) + 1;
          if (this.isCompiledCallable(callee)) {
            const proto = this.prototypeOf(asCell(callee));
            const created = cellValue(this.heap.allocateObject(proto));
            this.frames[frameIndex].ip = ip;
            this.enterCallable(callee, inst.a, created, argsBase, argc, created);
            returned = true;
          } else if (this.isHostFunctionValue(callee)) {
            const proto = this.prototypeOf(asCell(callee));
            const created = cellValue(this.heap.allocateObject(proto));
            const builtin = this.heap.hostFunctionId(asCell(callee));
            const outcome = this.callHost(builtin, created, argsBase, argc);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else {
              const produced = this.isObjectLike(outcome) ? outcome : created;
              this.setReg(base, inst.a, produced);
            }
          } else {
            const message: String = "value is not a constructor";
            thrown = this.typeError(in message);
            throwing = true;
          }
        } else if (op == Op.returnOp) {
          let value = this.reg(base, inst.a);
          const frame = this.popFrame();
          if (this.isObjectLike(frame.constructThis) && !this.isObjectLike(value)) value = frame.constructThis;
          if (this.frameCount <= entryDepth) {
            result = value;
          } else {
            const callerBase = this.frames[usize(this.frameCount - 1)].regsBase;
            this.setReg(callerBase, frame.returnDst, value);
          }
          returned = true;
        } else if (op == Op.newObject) {
          const objectProto = this.objectProto;
          const created = cellValue(this.heap.allocateObject(objectProto));
          this.setReg(base, inst.a, created);
        } else if (op == Op.newArray) {
          // Elements contiguous from b, c of them.
          const count = u32(inst.c);
          const array = this.heap.allocateArray(count);
          let index: u32 = 0;
          while (index < count) {
            const element = this.regStack[usize(base + u32(inst.b) + index)];
            this.heap.setSlot(array, index, element);
            index = index + 1;
          }
          this.setReg(base, inst.a, cellValue(array));
        } else if (op == Op.arrayPush) {
          const array = this.reg(base, inst.a);
          const element = this.reg(base, inst.b);
          if (isCell(array) && this.heap.isArray(asCell(array))) {
            const length = this.heap.arrayLength(asCell(array));
            this.heap.arraySet(asCell(array), length, element);
          }
        } else if (op == Op.loadProp) {
          const object = this.reg(base, inst.b);
          const atom = this.functions[usize(fi)].propertyNames[usize(inst.c)];
          if (isUndefined(object) || isNull(object)) {
            thrown = this.propertyOfNullish(object, atom, true);
            throwing = true;
          } else {
            const found = this.getProperty(object, cellValue(atom));
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else {
              this.setReg(base, inst.a, found);
            }
          }
        } else if (op == Op.storeProp) {
          const object = this.reg(base, inst.a);
          const atom = this.functions[usize(fi)].propertyNames[usize(inst.b)];
          const value = this.reg(base, inst.c);
          if (isUndefined(object) || isNull(object)) {
            thrown = this.propertyOfNullish(object, atom, false);
            throwing = true;
          } else {
            this.setProperty(object, cellValue(atom), value);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            }
          }
        } else if (op == Op.loadElem) {
          const object = this.reg(base, inst.b);
          const key = this.reg(base, inst.c);
          if (isUndefined(object) || isNull(object)) {
            const atom = this.propertyKey(key);
            thrown = this.propertyOfNullish(object, atom, true);
            throwing = true;
          } else {
            const found = this.getProperty(object, key);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else {
              this.setReg(base, inst.a, found);
            }
          }
        } else if (op == Op.storeElem) {
          const object = this.reg(base, inst.a);
          const key = this.reg(base, inst.b);
          const value = this.reg(base, inst.c);
          if (isUndefined(object) || isNull(object)) {
            const atom = this.propertyKey(key);
            thrown = this.propertyOfNullish(object, atom, false);
            throwing = true;
          } else {
            this.setProperty(object, key, value);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            }
          }
        } else if (op == Op.initObjData) {
          // Object literal property: define on the literal's own class.
          const object = this.reg(base, inst.a);
          const key = this.reg(base, inst.b);
          const value = this.reg(base, inst.c);
          const atom = this.propertyKey(key);
          this.heap.objectSet(asCell(object), atom, value);
        } else if (op == Op.loadThis) {
          const current = this.hostThis;
          this.setReg(base, inst.a, current);
        } else if (op == Op.typeofOp) {
          const operand = this.reg(base, inst.b);
          const label = this.typeofValue(operand);
          this.setReg(base, inst.a, label);
        } else if (op == Op.throwOp) {
          thrown = this.reg(base, inst.a);
          throwing = true;
        } else if (op == Op.enterTry) {
          // The catch block starts at the jump target; the thrown value
          // lands in register a.
          const target = usize(i32(ip) + i32(bcI16(inst)));
          this.pushTry(target, inst.a);
        } else if (op == Op.leaveTry) {
          this.tryDepth = this.tryDepth - 1;
        } else if (op == Op.newEnv) {
          const parent = this.frames[frameIndex].env;
          const created = this.heap.allocateEnv(parent, u32(bcU16(inst)));
          this.frames[frameIndex].env = created;
        } else if (op == Op.loadEnvSlot) {
          let env = this.frames[frameIndex].env;
          let hops = u32(inst.b);
          while (hops > 0) {
            env = this.heap.linkOf(env);
            hops = hops - 1;
          }
          const value = this.heap.slot(env, u32(inst.c));
          this.setReg(base, inst.a, value);
        } else if (op == Op.storeEnvSlot) {
          let env = this.frames[frameIndex].env;
          let hops = u32(inst.b);
          while (hops > 0) {
            env = this.heap.linkOf(env);
            hops = hops - 1;
          }
          const value = this.reg(base, inst.a);
          this.heap.setSlot(env, u32(inst.c), value);
        } else if (op == Op.makeClosure) {
          // The function in b becomes a closure over the frame's current
          // environment; an arrow also keeps the frame's `this`.
          const fn = this.reg(base, inst.b);
          const env = this.frames[frameIndex].env;
          const capturedThis = this.hostThis;
          const wrapped = this.heap.functionIndex(asCell(fn));
          const closure = this.heap.allocateClosure(wrapped, env, capturedThis);
          this.setReg(base, inst.a, cellValue(closure));
        } else if (op == Op.loadCallee) {
          const callee = this.frames[frameIndex].callee;
          this.setReg(base, inst.a, callee);
        } else {
          // Not yet implemented: an internal error, surfaced as a throw.
          const message: String = "unsupported operation";
          thrown = this.typeError(in message);
          throwing = true;
        }
      }
      if (throwing) {
        // Unwind to the nearest handler, popping frames as needed. The
        // handler's frame resumes at its catch block with the value in
        // the catch register; with no handler left, the throw escapes.
        let caught = false;
        while (!caught && this.frameCount > entryDepth) {
          const top = this.frameCount - 1;
          if (this.tryDepth > 0 && this.tryStack[usize(this.tryDepth - 1)].frameIndex == top) {
            const handler = this.tryStack[usize(this.tryDepth - 1)];
            this.frames[usize(top)].ip = handler.catchIp;
            const handlerBase = this.frames[usize(top)].regsBase;
            this.setReg(handlerBase, handler.catchReg, thrown);
            this.tryDepth = this.tryDepth - 1;
            caught = true;
          } else {
            this.popFrame();
          }
        }
        if (!caught) return RunResult({ isThrow: true, value: thrown });
      } else if (!returned) {
        // Fell off the end without Return: pop and yield undefined.
        this.popFrame();
      }
    }
    return RunResult({ isThrow: false, value: result });
  }

  // The TypeError for reading or writing a property of null or undefined.
  function propertyOfNullish(inout this, object: Value, atom: u32, reading: boolean): Value {
    const head: String = reading ? "Cannot read properties of " : "Cannot set properties of ";
    const which: String = isNull(object) ? "null" : "undefined";
    const action: String = reading ? " (reading '" : " (setting '";
    const tail: String = "')";
    let message = bytesOf(in head);
    appendBytes(inout message, bytesOf(in which));
    appendBytes(inout message, bytesOf(in action));
    appendBytes(inout message, this.heap.stringBytes(atom));
    appendBytes(inout message, bytesOf(in tail));
    return this.makeError(BUILTIN_TYPE_ERROR, move message);
  }
}

function appendBytes(inout target: Array<u8>, source: Array<u8>): void {
  let index: usize = 0;
  while (index < source.length) {
    target.push(source[index]);
    index = index + 1;
  }
}

export function createRuntime(): Runtime {
  let globals = Array<Global>();
  // Value properties of the global object the engine has so far.
  globals.push(Global({ name: "NaN", value: doubleValue(nativeNan()), defined: true }));
  globals.push(Global({ name: "Infinity", value: doubleValue(1.0 / 0.0), defined: true }));
  globals.push(Global({ name: "undefined", value: undefinedValue(), defined: true }));
  let runtime = Runtime({
    heap: createHeap(), functions: Array<FunctionCode>(), globals: move globals,
    atoms: Array<u32>(), atomCount: 0,
    regStack: Array<Value>(), regTop: 0, frames: Array<Frame>(), frameCount: 0,
    hadError: false, lastError: undefinedValue(),
    hostThis: undefinedValue(), tryStack: Array<TryFrame>(), tryDepth: 0,
    pendingThrow: false, pendingValue: undefinedValue(),
    objectProto: 0, functionProto: 0, arrayProto: 0, stringProto: 0,
    atomLength: 0, atomPrototype: 0, atomConstructor: 0, atomName: 0, atomMessage: 0,
  });
  runtime.installBuiltins();
  return runtime;
}

// --- Numeric semantics -----------------------------------------------------
//
// Mirrors the reference's int32 fast paths: an int32 result is produced
// only when it is exactly representable, otherwise the operation is
// performed in doubles.

function nativePow(base: f64, exponent: f64): f64 = raw c {
  return __builtin_pow(base, exponent);
}

function nativeFmod(a: f64, b: f64): f64 = raw c {
  return __builtin_fmod(a, b);
}

function nativeNan(): f64 = raw c {
  return __builtin_nan("");
}

export function toNumber(value: Value): f64 {
  if (isInt32(value)) return f64(asInt32(value));
  if (isDouble(value)) return asDouble(value);
  if (isBoolean(value)) return isTrue(value) ? 1.0 : 0.0;
  if (isNull(value)) return 0.0;
  return nativeNan();
}

export function toBoolean(value: Value): boolean {
  if (isBoolean(value)) return isTrue(value);
  if (isInt32(value)) return asInt32(value) != 0;
  if (isDouble(value)) {
    const d = asDouble(value);
    return d != 0.0 && d == d;
  }
  return false;
}

// ECMA-262 ToInt32: modulo 2^32, then reinterpret.
export function toInt32(value: Value): i32 {
  if (isInt32(value)) return asInt32(value);
  return i32.fromBits(toUint32(value));
}

export function toUint32(value: Value): u32 {
  if (isInt32(value)) return asInt32(value).toBits();
  const d = toNumber(value);
  if (d != d) return 0;
  return nativeToUint32(d);
}

function nativeToUint32(d: f64): u32 = raw c {
  if (!__builtin_isfinite(d)) return 0;
  double t = __builtin_trunc(d);
  double m = __builtin_fmod(t, 4294967296.0);
  if (m < 0) m += 4294967296.0;
  return (uint32_t)m;
}

// A uint32 result becomes int32 when it fits, otherwise a double.
function uint32ToValue(value: u32): Value {
  if (value <= 0x7FFF_FFFF) return int32Value(i32(value));
  return doubleValue(f64(value));
}

function int32OrDouble(wide: i64): Value {
  const lowest: i64 = -2147483648;
  const highest: i64 = 2147483647;
  if (wide >= lowest && wide <= highest) return int32Value(i32(wide));
  return doubleValue(f64(wide));
}

export function numericAdd(a: Value, b: Value): Value {
  if (isInt32(a) && isInt32(b)) return int32OrDouble(i64(asInt32(a)) + i64(asInt32(b)));
  return doubleValue(toNumber(a) + toNumber(b));
}

export function numericSub(a: Value, b: Value): Value {
  if (isInt32(a) && isInt32(b)) return int32OrDouble(i64(asInt32(a)) - i64(asInt32(b)));
  return doubleValue(toNumber(a) - toNumber(b));
}

// The reference keeps an int32 product whenever it fits, including a
// zero product with a negative operand (spec says -0); parity wins.
export function numericMul(a: Value, b: Value): Value {
  if (isInt32(a) && isInt32(b)) return int32OrDouble(i64(asInt32(a)) * i64(asInt32(b)));
  return doubleValue(toNumber(a) * toNumber(b));
}

// The reference has no int32 path for division: the result is always a
// double, even for 6 / 3.
export function numericDiv(a: Value, b: Value): Value {
  return doubleValue(toNumber(a) / toNumber(b));
}

export function numericMod(a: Value, b: Value): Value {
  if (isInt32(a) && isInt32(b)) {
    const ai = asInt32(a);
    const bi = asInt32(b);
    const minimum: i32 = -2147483648;
    if (bi != 0 && !(ai == minimum && bi == -1)) {
      const remainder = ai % bi;
      if (!(remainder == 0 && ai < 0)) return int32Value(remainder);
    }
  }
  return doubleValue(nativeFmod(toNumber(a), toNumber(b)));
}

export function numericNeg(a: Value): Value {
  if (isInt32(a)) {
    const ai = asInt32(a);
    const minimum: i32 = -2147483648;
    if (ai != 0 && ai != minimum) return int32Value(0 - ai);
  }
  return doubleValue(0.0 - toNumber(a));
}

test "int32 arithmetic promotes to double only when it must" {
  expect(isInt32(numericAdd(int32Value(1), int32Value(2)))).toEqual(true);
  expect(asInt32(numericAdd(int32Value(1), int32Value(2)))).toEqual(3);
  expect(isDouble(numericAdd(int32Value(2147483647), int32Value(1)))).toEqual(true);
  expect(isDouble(numericDiv(int32Value(6), int32Value(3)))).toEqual(true);
  expect(isInt32(numericMul(int32Value(0), int32Value(-1)))).toEqual(true);
  expect(isDouble(numericNeg(int32Value(0)))).toEqual(true);
  expect(asInt32(numericMod(int32Value(7), int32Value(3)))).toEqual(1);
}

// --- Number and string conversions -----------------------------------------
//
// Formatting and parsing go through C, as the reference does. Bytes move
// between Z and C through a native buffer addressed as usize, because a
// String cannot cross a raw boundary; the result comes back as a cstring
// view that String.from copies.

function nativeAlloc(count: usize): usize = raw c {
  return (uintptr_t)calloc(count, 1);
}

function nativeStoreByte(buffer: usize, index: usize, value: u8): void = raw c {
  ((uint8_t *)buffer)[index] = value;
}

function nativeView(buffer: usize): cstring = raw c {
  return (const char *)buffer;
}

function nativeFree(buffer: usize): void = raw c {
  free((void *)buffer);
}

function nativeFormatInt32(buffer: usize, value: i32): void = raw c {
  snprintf((char *)buffer, 32, "%d", (int)value);
}

// The reference's ToString(Number): integral values within 1e15 print as
// integers, integral values below 1e21 through %.0f, and everything else
// through the shortest digit string that round-trips.
function nativeFormatDouble(buffer: usize, value: f64): void = raw c {
  char *out = (char *)buffer;
  if (value != value) { snprintf(out, 64, "NaN"); return; }
  if (__builtin_isinf(value)) { snprintf(out, 64, value > 0 ? "Infinity" : "-Infinity"); return; }
  if (value == (double)(long long)value && value >= -1e15 && value <= 1e15) {
    snprintf(out, 64, "%lld", (long long)value); return;
  }
  if (value == __builtin_floor(value) && __builtin_fabs(value) < 1e21) {
    snprintf(out, 64, "%.0f", value); return;
  }
  /* Shortest round-trip digits, then ECMA-262 Number::toString layout. */
  char digits[40];
  int precision = 1;
  for (; precision <= 17; precision++) {
    snprintf(digits, sizeof digits, "%.*e", precision - 1, value);
    if (strtod(digits, NULL) == value) break;
  }
  const char *p = digits;
  int negative = 0;
  if (*p == '-') { negative = 1; p++; }
  char mant[32]; int n = 0;
  while (*p && *p != 'e') { if (*p != '.') mant[n++] = *p; p++; }
  mant[n] = 0;
  int exponent = atoi(p + 1);
  int k = n;
  int e = exponent + 1;
  char *w = out;
  if (negative) *w++ = '-';
  if (k <= e && e <= 21) {
    memcpy(w, mant, k); w += k;
    for (int i = 0; i < e - k; i++) *w++ = '0';
  } else if (0 < e && e <= 21) {
    memcpy(w, mant, e); w += e; *w++ = '.';
    memcpy(w, mant + e, k - e); w += k - e;
  } else if (-6 < e && e <= 0) {
    *w++ = '0'; *w++ = '.';
    for (int i = 0; i < -e; i++) *w++ = '0';
    memcpy(w, mant, k); w += k;
  } else {
    *w++ = mant[0];
    if (k > 1) { *w++ = '.'; memcpy(w, mant + 1, k - 1); w += k - 1; }
    *w++ = 'e';
    int ex = e - 1;
    *w++ = ex < 0 ? '-' : '+';
    if (ex < 0) ex = -ex;
    w += snprintf(w, 8, "%d", ex);
  }
  *w = 0;
}

// StringToNumber: JS whitespace trimmed, empty is 0, strtod must consume
// everything, and only the exact spelling "Infinity" may be infinite.
function nativeParseNumber(buffer: usize, length: usize, outOk: usize): f64 = raw c {
  const char *p = (const char *)buffer;
  const char *end = p + length;
  int *ok = (int *)outOk;
  while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == '\v' || *p == '\f')) p++;
  if (p == end) { *ok = 1; return 0.0; }
  char *ep = NULL;
  double parsed = strtod(p, &ep);
  while (ep < end && (*ep == ' ' || *ep == '\t' || *ep == '\n' || *ep == '\r' || *ep == '\v' || *ep == '\f')) ep++;
  *ok = (ep == end && ep != p) ? 1 : 0;
  if (*ok && __builtin_isinf(parsed)) {
    const char *q = p;
    if (q < end && (*q == '+' || *q == '-')) q++;
    if (!(end - q >= 8 && memcmp(q, "Infinity", 8) == 0
          && (q + 8 == end || q[8] == ' ' || q[8] == '\t' || q[8] == '\n' || q[8] == '\r' || q[8] == '\v' || q[8] == '\f'))) {
      *ok = 0;
    }
  }
  return parsed;
}

function nativeReadInt(buffer: usize): i32 = raw c {
  return *(int *)buffer;
}

function bufferToString(buffer: usize): String {
  const view: cstring = nativeView(buffer);
  return String.from(view);
}

export function int32ToString(value: i32): String {
  const buffer = nativeAlloc(32);
  nativeFormatInt32(buffer, value);
  const text = bufferToString(buffer);
  nativeFree(buffer);
  return text;
}

export function doubleToString(value: f64): String {
  const buffer = nativeAlloc(64);
  nativeFormatDouble(buffer, value);
  const text = bufferToString(buffer);
  nativeFree(buffer);
  return text;
}

export function stringToNumber(in bytes: Array<u8>): f64 {
  const length = bytes.length;
  const buffer = nativeAlloc(length + 1);
  let index: usize = 0;
  while (index < length) {
    nativeStoreByte(buffer, index, bytes[index]);
    index = index + 1;
  }
  const okCell = nativeAlloc(4);
  const parsed = nativeParseNumber(buffer, length, okCell);
  const ok = nativeReadInt(okCell);
  nativeFree(okCell);
  nativeFree(buffer);
  if (ok != 0) return parsed;
  return nativeNan();
}

test "number formatting follows the reference" {
  const formatted1 = int32ToString(-42);
  expect(formatted1).toEqual("-42");
  const formatted2 = doubleToString(2.5);
  expect(formatted2).toEqual("2.5");
  const formatted3 = doubleToString(0.1);
  expect(formatted3).toEqual("0.1");
  const formatted4 = doubleToString(1e21);
  expect(formatted4).toEqual("1e+21");
  const formatted5 = doubleToString(1.5e-7);
  expect(formatted5).toEqual("1.5e-7");
  const formatted6 = doubleToString(0.000001);
  expect(formatted6).toEqual("0.000001");
  const formatted7 = doubleToString(-0.0);
  expect(formatted7).toEqual("0");
  const formatted8 = doubleToString(1.0 / 0.0);
  expect(formatted8).toEqual("Infinity");
}

function numberOf(text: String): f64 {
  const bytes = bytesOf(in text);
  return stringToNumber(in bytes);
}

test "string to number follows the reference" {
  expect(numberOf("  42  ")).toEqual(42.0);
  expect(numberOf("")).toEqual(0.0);
  expect(numberOf("0x10")).toEqual(16.0);
  expect(numberOf("1e3")).toEqual(1000.0);
  const notANumber = numberOf("abc");
  expect(notANumber != notANumber).toEqual(true);
  const infinite = numberOf("Infinity");
  expect(infinite > 1e308).toEqual(true);
  const lowercase = numberOf("inf");
  expect(lowercase != lowercase).toEqual(true);
}
