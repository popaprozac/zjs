// Runtime -- the per-context engine state the interpreter runs against:
// the heap, compiled functions, globals, the register stack, and call
// frames. One Runtime per context; it lives inside the context registry.
//
// The interpreter is a method on Runtime so every piece of mutable state is
// reached through `this`. Z rejects `inout` through indexed storage, but a
// method call on the projection is accepted, and the registry calls
// `slots[i].runtime.eval(...)`.

import { expect } from "std/test";
import { thread } from "std/thread";
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
  // The name interned, for lookups through the global object.
  atom: u32;
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

// The errors the engine itself throws, by the name of their constructor.
// The builtins module installs the constructors; the runtime finds a
// prototype through the global of that name.
export const ERROR_KIND_ERROR: u32 = 0;
export const ERROR_KIND_TYPE: u32 = 1;
export const ERROR_KIND_REFERENCE: u32 = 2;
export const ERROR_KIND_RANGE: u32 = 3;
export const ERROR_KIND_SYNTAX: u32 = 4;
export const ERROR_KIND_COUNT: u32 = 5;

export function errorKindName(kind: u32): String {
  if (kind == ERROR_KIND_ERROR) return "Error";
  if (kind == ERROR_KIND_TYPE) return "TypeError";
  if (kind == ERROR_KIND_REFERENCE) return "ReferenceError";
  if (kind == ERROR_KIND_RANGE) return "RangeError";
  return "SyntaxError";
}

// A builtin implemented in Z. The runtime keeps these in a table; a host
// function cell carries its index. `callee` is the cell being called, whose
// slots hold per-instance data (an Error constructor's kind, a bound
// function's target) and its `length` and `name`.
export type HostFunction = (inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32) => Value on thread.any;

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
  numberProto: u32;
  booleanProto: u32;
  // Math.random's state.
  randomState: u64;
  // The completion value of the last run, kept alive for the embedder.
  lastResult: Value;
  // Builtins, indexed by a host function cell's payload.
  hostTable: Array<HostFunction>;
  // The global object: `this` at the top level and in sloppy calls; its
  // properties fall through to the globals table.
  globalObject: u32;
  // Cells a builtin holds in Z locals across a call back into JavaScript,
  // so a collection there cannot free them. Live to `tempRootCount`.
  tempRoots: Array<Value>;
  tempRootCount: usize;
  // Atoms the runtime consults by identity.
  atomLength: u32;
  atomPrototype: u32;
  atomConstructor: u32;
  atomName: u32;
  atomMessage: u32;
  // The hidden key under which a wrapper object keeps its primitive. Its
  // bytes begin with 0xFF, which no JavaScript string can contain, so
  // user code can neither read nor forge it.
  atomPrimitive: u32;

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
    const atom = this.internBytes(bytesOf(in name));
    this.globals.push(Global({ name: move name, value: undefinedValue(), defined: false, atom: atom }));
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
    const slot = this.globalSlot(errorKindName(kind));
    const ctor = this.globals[usize(slot)].value;
    if (!this.isHostFunctionValue(ctor)) return 0;
    return this.heap.linkOf(asCell(ctor));
  }

  // An error object the engine throws itself: `name` and `message` as own
  // properties, prototype from the matching constructor.
  function makeError(inout this, kind: u32, message: Array<u8>): Value {
    const proto = this.errorPrototype(kind);
    const object = this.heap.allocateObject(proto);
    const kindName = errorKindName(kind);
    const nameValue = this.internText(in kindName);
    const atomName = this.atomName;
    this.heap.objectSet(object, atomName, nameValue);
    const messageValue = this.newString(move message);
    const atomMessage = this.atomMessage;
    this.heap.objectSet(object, atomMessage, messageValue);
    return cellValue(object);
  }

  function typeError(inout this, in message: String): Value {
    return this.makeError(ERROR_KIND_TYPE, bytesOf(in message));
  }

  function syntaxError(inout this, in message: String): Value {
    return this.makeError(ERROR_KIND_SYNTAX, bytesOf(in message));
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
      if (d >= 0.0 && d < 2147483648.0 && isIntegralDouble(d)) return i32(d);
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

  // The slot that holds a function-like cell's bag of named properties.
  function functionBagSlot(handle: u32): u32 {
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_HOST_FUNCTION) return 3;
    if (tag == TAG_CLOSURE) return 2;
    return 0;
  }

  // A function-like cell's bag, 0 if none exists yet.
  function functionBag(handle: u32): u32 {
    const held = this.heap.slot(handle, this.functionBagSlot(handle));
    if (isCell(held) && asCell(held) != 0) return asCell(held);
    return 0;
  }

  // A function-like cell's bag, created on first use.
  function ensureFunctionBag(inout this, handle: u32): u32 {
    const existing = this.functionBag(handle);
    if (existing != 0) return existing;
    const created = this.heap.allocateObject(0);
    const slot = this.functionBagSlot(handle);
    this.heap.setSlot(handle, slot, cellValue(created));
    return created;
  }

  // Define an own data property on an object or a function-like cell.
  function defineOwn(inout this, target: u32, atom: u32, value: Value): void {
    if (this.heap.isObject(target)) {
      this.heap.objectSet(target, atom, value);
      return;
    }
    const bag = this.ensureFunctionBag(target);
    this.heap.objectSet(bag, atom, value);
  }

  // The primitive a wrapper object holds, or the deleted marker for an
  // ordinary object.
  function wrappedPrimitive(handle: u32): Value {
    const slot = this.heap.objectFindSlot(handle, this.atomPrimitive);
    if (slot < 0) return deletedValue();
    return this.heap.slot(handle, u32(slot));
  }

  // A wrapper object around `primitive`, inheriting from `proto`.
  function wrapPrimitive(inout this, primitive: Value, proto: u32): Value {
    const object = this.heap.allocateObject(proto);
    const atomPrimitive = this.atomPrimitive;
    this.heap.objectSet(object, atomPrimitive, primitive);
    return cellValue(object);
  }

  // The intrinsic prototype a primitive reads through, 0 for none.
  function primitiveProto(value: Value): u32 {
    if (isNumber(value)) return this.numberProto;
    if (isBoolean(value)) return this.booleanProto;
    if (this.isStringValue(value)) return this.stringProto;
    return 0;
  }

  // [[Get]] for every value the engine has. Absent properties are
  // undefined; primitives read from their intrinsic prototype.
  function getProperty(inout this, object: Value, key: Value): Value {
    if (!isCell(object) || asCell(object) == 0) {
      const proto = this.primitiveProto(object);
      if (proto == 0) return undefinedValue();
      const atom = this.propertyKey(key);
      return this.objectGet(proto, atom);
    }
    const handle = asCell(object);
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_OBJECT) {
      const atom = this.propertyKey(key);
      const found = this.objectGet(handle, atom);
      if (!isUndefined(found)) return found;
      if (handle == this.globalObject) {
        const slot = this.findGlobalByAtom(atom);
        if (slot >= 0 && this.globals[usize(slot)].defined) return this.globals[usize(slot)].value;
        return found;
      }
      // A String wrapper exposes its characters and length.
      const primitive = this.wrappedPrimitive(handle);
      if (!isDeleted(primitive) && this.isStringValue(primitive)) {
        if (atom == this.atomLength || this.arrayIndexOf(key) >= 0) return this.getProperty(primitive, key);
      }
      return found;
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
      if (tag == TAG_HOST_FUNCTION) {
        if (atom == this.atomLength) return this.heap.slot(handle, 1);
        if (atom == this.atomName) return this.heap.slot(handle, 2);
      } else {
        const code = this.heap.functionIndex(handle);
        if (atom == this.atomLength) return int32Value(i32(this.functions[usize(code)].expectedArgCount));
      }
      const bag = this.functionBag(handle);
      if (bag != 0) {
        const slot = this.heap.objectFindSlot(bag, atom);
        if (slot >= 0 && !isDeleted(this.heap.slot(bag, u32(slot)))) return this.heap.slot(bag, u32(slot));
      }
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
      if (handle == this.globalObject && this.heap.objectFindSlot(handle, atom) < 0) {
        const slot = this.findGlobalByAtom(atom);
        if (slot >= 0) {
          this.globals[usize(slot)].value = value;
          this.globals[usize(slot)].defined = true;
          return;
        }
      }
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
    if (tag == TAG_FUNCTION || tag == TAG_HOST_FUNCTION || tag == TAG_CLOSURE) {
      const atom = this.propertyKey(key);
      if (atom == this.atomPrototype) {
        if (!this.isObjectLike(value)) return;
        if (tag == TAG_CLOSURE) {
          this.heap.setSlot(handle, 1, value);
        } else {
          this.heap.setLink(handle, asCell(value));
        }
        return;
      }
      const bag = this.ensureFunctionBag(handle);
      this.heap.objectSet(bag, atom, value);
      return;
    }
  }

  // The `in` operator's lookup: whether `object` or its prototype chain
  // has `key`. The caller has checked that `object` is object-like.
  function hasProperty(inout this, object: Value, key: Value): boolean {
    const handle = asCell(object);
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_ARRAY) {
      const index = this.arrayIndexOf(key);
      if (index >= 0) {
        if (this.heap.arrayHasIndex(handle, u32(index))) return true;
        const arrayProto = this.arrayProto;
        return !isUndefined(this.getProperty(cellValue(arrayProto), key));
      }
      const atom = this.propertyKey(key);
      if (atom == this.atomLength) return true;
      const bag = this.heap.linkOf(handle);
      if (bag != 0 && this.heap.objectFindSlot(bag, atom) >= 0) return true;
      const arrayProto = this.arrayProto;
      return !isUndefined(this.objectGet(arrayProto, atom));
    }
    if (tag == TAG_OBJECT) {
      const atom = this.propertyKey(key);
      let current = handle;
      while (current != 0) {
        const slot = this.heap.objectFindSlot(current, atom);
        if (slot >= 0 && !isDeleted(this.heap.slot(current, u32(slot)))) return true;
        current = this.heap.objectProto(current);
      }
      return false;
    }
    // Functions: `prototype`, own named properties, then Function.prototype.
    const atom = this.propertyKey(key);
    if (atom == this.atomPrototype) return true;
    const bag = this.functionBag(handle);
    if (bag != 0 && this.heap.objectFindSlot(bag, atom) >= 0) return true;
    const functionProto = this.functionProto;
    return !isUndefined(this.objectGet(functionProto, atom));
  }

  // Whether a value has `key` as an own property: an object's live slot,
  // an array's present element or bag entry, a string's index or length,
  // a function's `prototype` / `length` / `name`.
  function hasOwnProperty(inout this, object: Value, key: Value): boolean {
    if (!isCell(object) || asCell(object) == 0) return false;
    const handle = asCell(object);
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_OBJECT) {
      const atom = this.propertyKey(key);
      const slot = this.heap.objectFindSlot(handle, atom);
      if (slot >= 0 && !isDeleted(this.heap.slot(handle, u32(slot)))) return true;
      if (handle == this.globalObject) {
        const global = this.findGlobalByAtom(atom);
        return global >= 0 && this.globals[usize(global)].defined;
      }
      return false;
    }
    if (tag == TAG_ARRAY) {
      const index = this.arrayIndexOf(key);
      if (index >= 0) return this.heap.arrayHasIndex(handle, u32(index));
      const atom = this.propertyKey(key);
      if (atom == this.atomLength) return true;
      const bag = this.heap.linkOf(handle);
      if (bag == 0) return false;
      const slot = this.heap.objectFindSlot(bag, atom);
      return slot >= 0 && !isDeleted(this.heap.slot(bag, u32(slot)));
    }
    if (this.heap.isString(handle)) {
      const index = this.arrayIndexOf(key);
      if (index >= 0) return usize(index) < this.heap.stringLength(handle);
      const atom = this.propertyKey(key);
      return atom == this.atomLength;
    }
    if (tag == TAG_FUNCTION || tag == TAG_HOST_FUNCTION || tag == TAG_CLOSURE) {
      const atom = this.propertyKey(key);
      if (atom == this.atomPrototype || atom == this.atomLength || (tag == TAG_HOST_FUNCTION && atom == this.atomName)) return true;
      const bag = this.functionBag(handle);
      if (bag == 0) return false;
      const slot = this.heap.objectFindSlot(bag, atom);
      return slot >= 0 && !isDeleted(this.heap.slot(bag, u32(slot)));
    }
    return false;
  }

  // The prototype a value inherits from, for instanceof: 0 for none.
  function protoOfValue(value: Value): u32 {
    if (!isCell(value) || asCell(value) == 0) return 0;
    const handle = asCell(value);
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_OBJECT) return this.heap.objectProto(handle);
    if (tag == TAG_ARRAY) return this.arrayProto;
    if (tag == TAG_FUNCTION || tag == TAG_HOST_FUNCTION || tag == TAG_CLOSURE) return this.functionProto;
    if (this.heap.isString(handle)) return this.stringProto;
    return 0;
  }

  // Remove an own property. Objects keep their class and mark the slot
  // deleted, as the reference does; arrays leave a hole.
  function deleteProperty(inout this, object: Value, key: Value): boolean {
    if (!isCell(object) || asCell(object) == 0) return true;
    const handle = asCell(object);
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_OBJECT) {
      const atom = this.propertyKey(key);
      const slot = this.heap.objectFindSlot(handle, atom);
      if (slot >= 0) this.heap.setSlot(handle, u32(slot), deletedValue());
      return true;
    }
    if (tag == TAG_ARRAY) {
      const index = this.arrayIndexOf(key);
      if (index >= 0) {
        if (this.heap.arrayHasIndex(handle, u32(index))) this.heap.setSlot(handle, u32(index), deletedValue());
        return true;
      }
      const atom = this.propertyKey(key);
      if (atom == this.atomLength) return false;
      const bag = this.heap.linkOf(handle);
      if (bag != 0) {
        const slot = this.heap.objectFindSlot(bag, atom);
        if (slot >= 0) this.heap.setSlot(bag, u32(slot), deletedValue());
      }
      return true;
    }
    return true;
  }

  // Whether an atom is one of the engine's hidden keys.
  function isHiddenAtom(atom: u32): boolean {
    return this.heap.stringLength(atom) > 0 && this.heap.stringByte(atom, 0) == 255;
  }

  // The names an object's own class holds, in slot order, hidden keys
  // left out.
  function ownNames(handle: u32): Array<u32> {
    const propCount = this.heap.classPropCount(this.heap.objectClass(handle));
    let names = Array<u32>();
    let fill: u32 = 0;
    while (fill < propCount) {
      names.push(0);
      fill = fill + 1;
    }
    let classId = this.heap.objectClass(handle);
    while (classId != 0) {
      const slot = this.heap.classes[usize(classId)].transitionSlot;
      const name = this.heap.classes[usize(classId)].transitionName;
      if (!this.isHiddenAtom(name)) names[usize(slot)] = name;
      classId = this.heap.classes[usize(classId)].parent;
    }
    return names;
  }

  // The keys for-in visits, as an array of strings: array indices then
  // named properties; an object's own names in insertion order, then its
  // prototypes' (stopping short of Object.prototype), each name once.
  // Property attributes do not exist yet, so every property counts as
  // enumerable except an inherited `constructor`.
  function enumerateKeys(inout this, value: Value): Value {
    const keys = this.heap.allocateArray(0);
    if (!isCell(value) || asCell(value) == 0) return cellValue(keys);
    const handle = asCell(value);
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_ARRAY) {
      const length = this.heap.arrayLength(handle);
      let index: u32 = 0;
      while (index < length) {
        if (this.heap.arrayHasIndex(handle, index)) {
          const key = this.toStringValue(int32Value(i32(index)));
          const count = this.heap.arrayLength(keys);
          this.heap.arraySet(keys, count, key);
        }
        index = index + 1;
      }
      const bag = this.heap.linkOf(handle);
      if (bag != 0) this.appendObjectKeys(keys, bag, true);
      return cellValue(keys);
    }
    if (this.heap.isString(handle)) {
      const length = this.heap.stringLength(handle);
      let index: u32 = 0;
      while (usize(index) < length) {
        const key = this.toStringValue(int32Value(i32(index)));
        const count = this.heap.arrayLength(keys);
        this.heap.arraySet(keys, count, key);
        index = index + 1;
      }
      return cellValue(keys);
    }
    if (tag == TAG_OBJECT) {
      let current = handle;
      let seen = Array<u32>();
      while (current != 0 && current != this.objectProto) {
        const names = this.ownNames(current);
        let i: usize = 0;
        while (i < names.length) {
          const name = names[i];
          if (name == 0) {
            i = i + 1;
            continue;
          }
          let already = false;
          let j: usize = 0;
          while (j < seen.length) {
            if (seen[j] == name) already = true;
            j = j + 1;
          }
          if (!already) {
            seen.push(name);
            const slot = this.heap.objectFindSlot(current, name);
            const inheritedConstructor = current != handle && name == this.atomConstructor;
            if (slot >= 0 && !isDeleted(this.heap.slot(current, u32(slot))) && !inheritedConstructor) {
              const count = this.heap.arrayLength(keys);
              this.heap.arraySet(keys, count, cellValue(name));
            }
          }
          i = i + 1;
        }
        current = this.heap.objectProto(current);
      }
      return cellValue(keys);
    }
    return cellValue(keys);
  }

  // Append an object's own live names to `keys`, skipping array indices
  // when the object is an array's bag.
  function appendObjectKeys(inout this, keys: u32, object: u32, skipIndices: boolean): void {
    const names = this.ownNames(object);
    let i: usize = 0;
    while (i < names.length) {
      const name = names[i];
      if (name == 0) {
        i = i + 1;
        continue;
      }
      const slot = this.heap.objectFindSlot(object, name);
      const live = slot >= 0 && !isDeleted(this.heap.slot(object, u32(slot)));
      if (live && !(skipIndices && this.arrayIndexOf(cellValue(name)) >= 0)) {
        const count = this.heap.arrayLength(keys);
        this.heap.arraySet(keys, count, cellValue(name));
      }
      i = i + 1;
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

  // Register a builtin: a host function cell whose payload indexes the
  // table. Slot 0 is per-instance data, slot 1 `length`, slot 2 `name`.
  function defineHostFunction(inout this, fn: HostFunction, bound: Value, length: u32, in name: String): u32 {
    this.hostTable.push(fn);
    const id = u32(this.hostTable.length - 1);
    const handle = this.heap.allocateHostFunction(id);
    this.heap.setSlot(handle, 0, bound);
    this.heap.setSlot(handle, 1, int32Value(i32(length)));
    const nameValue = this.internText(in name);
    this.heap.setSlot(handle, 2, nameValue);
    return handle;
  }

  // A builtin as a property of `target`.
  function defineMethod(inout this, target: u32, in name: String, fn: HostFunction, length: u32): u32 {
    const handle = this.defineHostFunction(fn, undefinedValue(), length, in name);
    const atom = this.atomOf(in name);
    this.defineOwn(target, atom, cellValue(handle));
    return handle;
  }

  function callHost(inout this, id: u32, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value {
    const fn = this.hostTable[usize(id)];
    return fn(inout this, thisValue, argsBase, argc, callee);
  }

  function setGlobal(inout this, name: String, value: Value): void {
    const slot = this.defineGlobalSlot(move name);
    this.globals[usize(slot)].value = value;
  }

  // The global with this interned name, or -1.
  function findGlobalByAtom(atom: u32): i32 {
    let index: usize = 0;
    while (index < this.globals.length) {
      if (this.globals[index].atom == atom) return i32(index);
      index = index + 1;
    }
    return -1;
  }

  // ToLength: an integer clamped to [0, 2^32 - 1] as a u32; NaN is 0.
  // Every conversion to an unsigned index goes through here, since Z's
  // checked numeric conversion traps on anything out of range.
  function toLength(inout this, value: Value): u32 {
    const number = this.toNumberValue(value);
    if (number != number || number <= 0.0) return 0;
    if (number >= 4294967295.0) return 4294967295;
    return u32(truncateDouble(number));
  }

  // An argument by position, undefined past the end.
  function argument(argsBase: u32, argc: u32, index: u32): Value {
    if (index >= argc) return undefinedValue();
    return this.regStack[usize(argsBase + index)];
  }

  function pushTempRoot(inout this, value: Value): void {
    if (this.tempRootCount < this.tempRoots.length) {
      this.tempRoots[this.tempRootCount] = value;
    } else {
      this.tempRoots.push(value);
    }
    this.tempRootCount = this.tempRootCount + 1;
  }

  function popTempRoot(inout this): void {
    this.tempRootCount = this.tempRootCount - 1;
  }

  // Call a function value from Z with the arguments given, running the
  // interpreter re-entrantly for compiled code. A throw is left pending
  // for the caller to check; the result is then undefined.
  function callValue(inout this, callee: Value, thisValue: Value, args: Array<Value>): Value {
    const argsBase = this.regTop;
    const argc = u32(args.length);
    const needed = usize(argsBase + argc);
    while (this.regStack.length < needed) { this.regStack.push(undefinedValue()); }
    let index: u32 = 0;
    while (index < argc) {
      const passed = args[usize(index)];
      this.regStack[usize(argsBase + index)] = passed;
      index = index + 1;
    }
    this.regTop = argsBase + argc;
    let outcome = undefinedValue();
    if (this.isHostFunctionValue(callee)) {
      const handle = asCell(callee);
      const builtin = this.heap.hostFunctionId(handle);
      outcome = this.callHost(builtin, thisValue, argsBase, argc, handle);
    } else if (this.isCompiledCallable(callee)) {
      const entryDepth = this.frameCount;
      this.enterCallable(callee, 0, thisValue, argsBase, argc, undefinedValue());
      const result = this.runFrames(entryDepth);
      if (result.isThrow) {
        this.raise(result.value);
      } else {
        outcome = result.value;
      }
    } else {
      const message: String = "value is not a function";
      const error = this.typeError(in message);
      this.raise(error);
    }
    this.regTop = argsBase;
    return outcome;
  }

  // ToPrimitive: an object's valueOf / toString, in the order the hint
  // asks for; the first that yields a primitive wins.
  function toPrimitive(inout this, value: Value, preferString: boolean): Value {
    if (!this.isObjectLike(value)) return value;
    const valueOfText: String = "valueOf";
    const toStringText: String = "toString";
    let first = undefinedValue();
    if (preferString) {
      first = this.tryPrimitiveMethod(value, in toStringText);
    } else {
      first = this.tryPrimitiveMethod(value, in valueOfText);
    }
    if (this.pendingThrow) return undefinedValue();
    if (!isDeleted(first)) return first;
    let second = undefinedValue();
    if (preferString) {
      second = this.tryPrimitiveMethod(value, in valueOfText);
    } else {
      second = this.tryPrimitiveMethod(value, in toStringText);
    }
    if (this.pendingThrow) return undefinedValue();
    if (!isDeleted(second)) return second;
    const message: String = "Cannot convert object to primitive value";
    const error = this.typeError(in message);
    this.raise(error);
    return undefinedValue();
  }

  // The deleted marker means "no primitive from this method".
  function tryPrimitiveMethod(inout this, object: Value, in name: String): Value {
    const key = this.internText(in name);
    const method = this.getProperty(object, key);
    if (this.pendingThrow) return undefinedValue();
    if (!this.isCallable(method)) return deletedValue();
    const result = this.callValue(method, object, Array<Value>());
    if (this.pendingThrow) return undefinedValue();
    if (this.isObjectLike(result)) return deletedValue();
    return result;
  }

  // The atoms and prototype objects everything else hangs off. The
  // builtins module attaches constructors and methods to them.
  function installIntrinsics(inout this): void {
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
    let hidden = Array<u8>();
    hidden.push(255);
    hidden.push(112);
    hidden.push(114);
    hidden.push(105);
    hidden.push(109);
    this.atomPrimitive = this.internBytes(move hidden);
    this.objectProto = this.heap.allocateObject(0);
    const objectProto = this.objectProto;
    this.functionProto = this.heap.allocateObject(objectProto);
    this.arrayProto = this.heap.allocateObject(objectProto);
    this.stringProto = this.heap.allocateObject(objectProto);
    this.numberProto = this.heap.allocateObject(objectProto);
    this.booleanProto = this.heap.allocateObject(objectProto);
    this.globalObject = this.heap.allocateObject(objectProto);
    // Value properties of the global object.
    this.setGlobal("NaN", doubleValue(nativeNan()));
    this.setGlobal("Infinity", doubleValue(1.0 / 0.0));
    this.setGlobal("undefined", undefinedValue());
    this.setGlobal("globalThis", cellValue(this.globalObject));
  }

  // --- Collection ---

  // Mark everything reachable from the runtime's roots, then sweep. Runs
  // only at instruction boundaries, where every live value sits in a
  // register, a frame, a global, or a table -- never in a Z local.
  function collectGarbage(inout this): void {
    let index: usize = 0;
    while (index < usize(this.regTop)) {
      const value = this.regStack[index];
      this.heap.markValue(value);
      index = index + 1;
    }
    index = 0;
    while (index < this.globals.length) {
      const value = this.globals[index].value;
      this.heap.markValue(value);
      index = index + 1;
    }
    index = 0;
    while (index < usize(this.frameCount)) {
      const savedThis = this.frames[index].savedThis;
      const constructThis = this.frames[index].constructThis;
      const callee = this.frames[index].callee;
      const env = this.frames[index].env;
      this.heap.markValue(savedThis);
      this.heap.markValue(constructThis);
      this.heap.markValue(callee);
      this.heap.markHandle(env);
      index = index + 1;
    }
    const hostThis = this.hostThis;
    this.heap.markValue(hostThis);
    const pendingValue = this.pendingValue;
    this.heap.markValue(pendingValue);
    const lastError = this.lastError;
    this.heap.markValue(lastError);
    const lastResult = this.lastResult;
    this.heap.markValue(lastResult);
    const objectProto = this.objectProto;
    this.heap.markHandle(objectProto);
    const functionProto = this.functionProto;
    this.heap.markHandle(functionProto);
    const arrayProto = this.arrayProto;
    this.heap.markHandle(arrayProto);
    const stringProto = this.stringProto;
    this.heap.markHandle(stringProto);
    const globalObject = this.globalObject;
    this.heap.markHandle(globalObject);
    const numberProto = this.numberProto;
    this.heap.markHandle(numberProto);
    const booleanProto = this.booleanProto;
    this.heap.markHandle(booleanProto);
    const atomPrimitive = this.atomPrimitive;
    this.heap.markHandle(atomPrimitive);
    index = 0;
    while (index < this.tempRootCount) {
      const rooted = this.tempRoots[index];
      this.heap.markValue(rooted);
      index = index + 1;
    }
    const atomLength = this.atomLength;
    this.heap.markHandle(atomLength);
    const atomPrototype = this.atomPrototype;
    this.heap.markHandle(atomPrototype);
    const atomConstructor = this.atomConstructor;
    this.heap.markHandle(atomConstructor);
    const atomName = this.atomName;
    this.heap.markHandle(atomName);
    const atomMessage = this.atomMessage;
    this.heap.markHandle(atomMessage);
    // Names that hidden classes carry: a class is never freed, so the
    // atoms it names live as long as the runtime.
    index = 1;
    while (index < this.heap.classes.length) {
      const name = this.heap.classes[index].transitionName;
      this.heap.markHandle(name);
      index = index + 1;
    }
    // Function values, strings, and property names held by compiled code.
    index = 0;
    while (index < this.functions.length) {
      let c: usize = 0;
      while (c < this.functions[index].constants.length) {
        const constant = this.functions[index].constants[c];
        this.heap.markValue(constant);
        c = c + 1;
      }
      c = 0;
      while (c < this.functions[index].propertyNames.length) {
        const name = this.functions[index].propertyNames[c];
        this.heap.markHandle(name);
        c = c + 1;
      }
      index = index + 1;
    }
    // The atom table is weak: an interned string nothing else reaches is
    // dropped, and the table is rebuilt from the survivors.
    this.rebuildAtoms();
    this.heap.sweep();
  }

  function rebuildAtoms(inout this): void {
    let survivors = Array<u32>();
    let index: usize = 0;
    while (index < this.atoms.length) {
      const atom = this.atoms[index];
      if (atom != 0 && this.heap.marked(atom)) survivors.push(atom);
      this.atoms[index] = 0;
      index = index + 1;
    }
    this.atomCount = 0;
    index = 0;
    while (index < survivors.length) {
      const atom = survivors[index];
      this.insertAtom(atom);
      index = index + 1;
    }
  }

  // Place an existing string cell in the atom table by its bytes' hash.
  function insertAtom(inout this, handle: u32): void {
    const bytes = this.heap.stringBytes(handle);
    const mask = this.atoms.length - 1;
    let slot = usize(this.hashBytes(in bytes)) & mask;
    while (this.atoms[slot] != 0) { slot = (slot + 1) & mask; }
    this.atoms[slot] = handle;
    this.atomCount = this.atomCount + 1;
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
    if (this.isObjectLike(value)) {
      const primitive = this.toPrimitive(value, false);
      if (this.pendingThrow) return nativeNan();
      return this.toNumberValue(primitive);
    }
    return toNumber(value);
  }

  function toBooleanValue(value: Value): boolean {
    if (this.isStringValue(value)) return this.heap.stringLength(asCell(value)) > 0;
    if (isCell(value) && asCell(value) != 0) return true;
    return toBoolean(value);
  }

  // ToString. An object goes through ToPrimitive with the string hint;
  // a throw there is left pending and the result is the empty string.
  function toStringValue(inout this, value: Value): Value {
    if (this.isStringValue(value)) return value;
    if (this.isObjectLike(value)) {
      const primitive = this.toPrimitive(value, true);
      if (this.pendingThrow) return this.internValue(Array<u8>());
      return this.toStringValue(primitive);
    }
    if (isInt32(value)) {
      const text = int32ToString(asInt32(value));
      return this.newString(bytesOf(in text));
    }
    if (isDouble(value)) {
      const text = doubleToString(asDouble(value));
      return this.newString(bytesOf(in text));
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
    if (aNullish || bNullish) return false;
    // An object against a primitive compares through ToPrimitive; two
    // objects compare by identity.
    const aObject = this.isObjectLike(a);
    const bObject = this.isObjectLike(b);
    if (aObject && bObject) return a.bits == b.bits;
    if (aObject) {
      const primitive = this.toPrimitive(a, false);
      if (this.pendingThrow) return false;
      return this.looseEquals(primitive, b);
    }
    if (bObject) {
      const primitive = this.toPrimitive(b, false);
      if (this.pendingThrow) return false;
      return this.looseEquals(a, primitive);
    }
    if (isNumber(a) && bString) return toNumber(a) == this.toNumberValue(b);
    if (aString && isNumber(b)) return this.toNumberValue(a) == toNumber(b);
    if (isBoolean(a)) return this.looseEquals(int32Value(isTrue(a) ? 1 : 0), b);
    if (isBoolean(b)) return this.looseEquals(a, int32Value(isTrue(b) ? 1 : 0));
    return false;
  }

  // Relational comparison. `orEqual` selects <= over <; swap operands for
  // > and >=.
  function lessThan(inout this, a: Value, b: Value, orEqual: boolean): boolean {
    if (this.isObjectLike(a) || this.isObjectLike(b)) {
      const left = this.toPrimitive(a, false);
      if (this.pendingThrow) return false;
      const right = this.toPrimitive(b, false);
      if (this.pendingThrow) return false;
      return this.lessThan(left, right, orEqual);
    }
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
    // A sloppy function called with no receiver sees the global object.
    if (!this.functions[usize(target)].strict && (isUndefined(boundThis) || isNull(boundThis))) boundThis = cellValue(this.globalObject);
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
  // Run a program: its frame on the stack, `this` the global object.
  function run(inout this, functionIndex: u32): RunResult {
    const entryDepth = this.frameCount;
    this.pushFrame(functionIndex, 0);
    this.hostThis = cellValue(this.globalObject);
    return this.runFrames(entryDepth);
  }

  // The dispatch loop, until the frame stack is back to `entryDepth`.
  function runFrames(inout this, entryDepth: u32): RunResult {
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
            // A property set on the global object counts as a global.
            const atom = this.globals[slot].atom;
            const globalObject = this.globalObject;
            const own = this.heap.objectFindSlot(globalObject, atom);
            if (own >= 0 && !isDeleted(this.heap.slot(globalObject, u32(own)))) {
              const operand3 = this.heap.slot(globalObject, u32(own));
              this.setReg(base, inst.a, operand3);
            } else {
              const nameLength = this.globals[slot].name.byteLength;
              const name = this.globals[slot].name.copyBytes(0, nameLength);
              const text: String = `${name} is not defined`;
              thrown = this.makeError(ERROR_KIND_REFERENCE, bytesOf(in text));
              throwing = true;
            }
          } else {
            const operand3 = this.globals[slot].value;
            this.setReg(base, inst.a, operand3);
          }
        } else if (op == Op.loadGlobalOrUndefined) {
          const slot = usize(bcU16(inst));
          const operand4 = this.globals[slot].defined ? this.globals[slot].value : undefinedValue();
          this.setReg(base, inst.a, operand4);
        } else if (op == Op.add) {
          const rawLeft = this.reg(base, inst.b);
          const rawRight = this.reg(base, inst.c);
          if (isNumber(rawLeft) && isNumber(rawRight)) {
            const sum = numericAdd(rawLeft, rawRight);
            this.setReg(base, inst.a, sum);
          } else {
            const left = this.toPrimitive(rawLeft, false);
            const right = this.toPrimitive(rawRight, false);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else if (this.isStringValue(left) || this.isStringValue(right)) {
              const joined = this.concatStrings(left, right);
              if (this.pendingThrow) {
                thrown = this.takePending();
                throwing = true;
              } else {
                this.setReg(base, inst.a, joined);
              }
            } else {
              const leftNumber = this.numericOperand(left);
              const rightNumber = this.numericOperand(right);
              const sum = numericAdd(leftNumber, rightNumber);
              this.setReg(base, inst.a, sum);
            }
          }
        } else if (op == Op.cmpEq || op == Op.cmpNe) {
          const operandB = this.reg(base, inst.b);
          const operandC = this.reg(base, inst.c);
          const equal = this.looseEquals(operandB, operandC);
          this.setReg(base, inst.a, booleanValue(op == Op.cmpEq ? equal : !equal));
          if (this.pendingThrow) {
            thrown = this.takePending();
            throwing = true;
          }
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
          const offset = bcI16(inst);
          ip = usize(i64(ip) + i64(offset));
          // A loop's back edge is a safe point too, so a program that
          // allocates without calling collects all the same.
          if (offset < 0 && this.heap.shouldCollect()) {
            this.frames[frameIndex].ip = ip;
            this.collectGarbage();
          }
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
          const operand16 = int32Value(i32.fromBits(shiftLeft32(toInt32(numberB).toBits(), shift)));
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
            const outcome = this.callHost(builtin, undefinedValue(), argsBase, argc, asCell(callee));
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
            const outcome = this.callHost(builtin, receiver, argsBase, argc, asCell(callee));
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
            const outcome = this.callHost(builtin, created, argsBase, argc, asCell(callee));
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
          // A safe point: the return value is in the caller's register
          // once written below; keep it rooted through the collection.
          if (this.heap.shouldCollect()) {
            this.setReg(frame.regsBase, 0, value);
            this.regTop = frame.regsBase + 1;
            this.collectGarbage();
            this.regTop = frame.regsBase;
          }
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
        } else if (op == Op.inOp) {
          const key = this.reg(base, inst.b);
          const object = this.reg(base, inst.c);
          if (!this.isObjectLike(object)) {
            const message: String = "Cannot use 'in' on a non-object";
            thrown = this.typeError(in message);
            throwing = true;
          } else {
            const present = this.hasProperty(object, key);
            this.setReg(base, inst.a, booleanValue(present));
          }
        } else if (op == Op.instanceofOp) {
          const value = this.reg(base, inst.b);
          const ctor = this.reg(base, inst.c);
          if (!this.isCallable(ctor)) {
            const message: String = "Right-hand side of 'instanceof' is not callable";
            thrown = this.typeError(in message);
            throwing = true;
          } else {
            const target = this.prototypeOf(asCell(ctor));
            let current = this.protoOfValue(value);
            let found = false;
            while (current != 0 && !found) {
              if (current == target) found = true;
              current = this.heap.objectProto(current);
            }
            this.setReg(base, inst.a, booleanValue(found));
          }
        } else if (op == Op.deleteElem) {
          const object = this.reg(base, inst.b);
          const key = this.reg(base, inst.c);
          const removed = this.deleteProperty(object, key);
          this.setReg(base, inst.a, booleanValue(removed));
        } else if (op == Op.iterPrepare) {
          const source = this.reg(base, inst.b);
          const keys = this.enumerateKeys(source);
          this.setReg(base, inst.a, keys);
        } else if (op == Op.arrayLength) {
          const source = this.reg(base, inst.b);
          let length: i32 = 0;
          if (isCell(source) && asCell(source) != 0 && this.heap.isArray(asCell(source))) length = i32(this.heap.arrayLength(asCell(source)));
          this.setReg(base, inst.a, int32Value(length));
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
        if (!caught) {
          this.lastResult = thrown;
          return RunResult({ isThrow: true, value: thrown });
        }
      } else if (!returned) {
        // Fell off the end without Return: pop and yield undefined.
        this.popFrame();
      }
    }
    this.lastResult = result;
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
    return this.makeError(ERROR_KIND_TYPE, move message);
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
  let runtime = Runtime({
    heap: createHeap(), functions: Array<FunctionCode>(), globals: Array<Global>(),
    atoms: Array<u32>(), atomCount: 0,
    regStack: Array<Value>(), regTop: 0, frames: Array<Frame>(), frameCount: 0,
    hadError: false, lastError: undefinedValue(),
    hostThis: undefinedValue(), tryStack: Array<TryFrame>(), tryDepth: 0,
    pendingThrow: false, pendingValue: undefinedValue(),
    objectProto: 0, functionProto: 0, arrayProto: 0, stringProto: 0, numberProto: 0, booleanProto: 0,
    randomState: 0x9E3779B97F4A7C15, lastResult: undefinedValue(),
    hostTable: Array<HostFunction>(), globalObject: 0, tempRoots: Array<Value>(), tempRootCount: 0,
    atomLength: 0, atomPrototype: 0, atomConstructor: 0, atomName: 0, atomMessage: 0, atomPrimitive: 0,
  });
  runtime.installIntrinsics();
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

// Z's shift traps when bits leave the word; JavaScript's discards them.
export function shiftLeft32(bits: u32, count: u32): u32 = raw c {
  return bits << count;
}

// Z's checked conversion from f64 traps on a fractional value, so every
// place that narrows a double to an integer truncates first and compares.
export function truncateDouble(value: f64): f64 = raw c {
  return __builtin_trunc(value);
}

export function isIntegralDouble(value: f64): boolean {
  return value == value && truncateDouble(value) == value;
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
  // Negation, not subtraction from zero: -(+0) is -0.
  return doubleValue(-1.0 * toNumber(a));
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

// A Z String from a JavaScript string's bytes, by way of a NUL-terminated
// native buffer: Z has no direct construction from bytes, and the copy
// stops at an embedded NUL.
export function bytesToString(in bytes: Array<u8>): String {
  const buffer = nativeAlloc(bytes.length + 1);
  let index: usize = 0;
  while (index < bytes.length) {
    nativeStoreByte(buffer, index, bytes[index]);
    index = index + 1;
  }
  const text = bufferToString(buffer);
  nativeFree(buffer);
  return text;
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
