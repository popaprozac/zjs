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
import math from "std/math";
import native from "./builtins/clock.h";
import { Value, int32Value, asInt32, doubleValue, asDouble, isInt32, isDouble, isNumber, isBoolean, isTrue, isNull, isUndefined, isCell, asCell, cellValue, undefinedValue, nullValue, booleanValue, deletedValue, isDeleted, holeValue, isHole } from "./value.zs";
import { RegexBackend, createRegexBackend, REGEX_GLOBAL, REGEX_IGNORE_CASE, REGEX_MULTILINE, REGEX_DOT_ALL, REGEX_UNICODE, REGEX_STICKY, REGEX_HAS_INDICES, REGEX_UNICODE_SETS, REGEX_MATCH, REGEX_NO_MATCH, REGEX_OUT_OF_MEMORY, REGEX_STEP_LIMIT, REGEX_BAD_BYTECODE, REGEX_STACK_LIMIT, REGEX_SYNTAX, REGEX_SIZE_LIMIT } from "./regex.zs";
import { Heap, createHeap, bytesOf, TAG_OBJECT, TAG_ARRAY, TAG_FUNCTION, TAG_HOST_FUNCTION, TAG_CLOSURE, TAG_ENV, TAG_SYMBOL, PROP_WRITABLE, PROP_ENUMERABLE, PROP_CONFIGURABLE, PROP_ACCESSOR, PROP_DEFAULT, PROP_METHOD, PROP_NONE, FLAG_NON_EXTENSIBLE, FLAG_LENGTH_READONLY, FLAG_PRIVATE_NAME, FLAG_INTERNED, FLAG_WIDE, FLAG_HIDDEN, FLAG_REGISTERED_SYMBOL } from "./heap.zs";
import { utf8ToUnits, unitsToUtf8, unitsToWtf8, unitsOf, latin1Units, unitsToLatin1, isNarrowUnits, isAsciiBytes, sliceUnits, appendUnits, sameUnits, isJsSpace, pushCodePoint, codePointAt } from "./text.zs";
import { Op, Inst, FunctionCode, createFunctionCode, bcU16, bcI16, PropertyCache, emptyCache, CACHE_EMPTY, CACHE_OWN, CACHE_PROTO, CACHE_TRANSITION } from "./bytecode.zs";
import stdlib from "stdlib.h";
import stdio from "stdio.h";
import string from "string.h";

struct Global {
  value: Value;
  defined: boolean;
  // The name interned, for lookups through the global object.
  atom: u32;
  // PROP_* bits as seen through the global object: script bindings are
  // writable and enumerable, builtins writable and configurable, the
  // value constants none.
  attr: u8;
}

struct Frame {
  // The `new.target` of a construct call; undefined for a plain call.
  newTarget: Value;
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
  // Where the call's actual arguments sit in the register stack, and how
  // many there are: the `arguments` object and rest parameters read them.
  argsBase: u32;
  argc: u32;
  // The generator object this frame runs for, 0 for none.
  generator: u32;
}

// A live try handler: the frame it belongs to, where its catch block
// starts, and the register that receives the thrown value.
struct TryFrame {
  frameIndex: u32;
  catchIp: usize;
  catchReg: u8;
  // The frame's environment when the try was entered; a throw from a
  // deeper per-iteration environment lands the handler back in it.
  env: u32;
}

// The errors the engine itself throws, by the name of their constructor.
// The builtins module installs the constructors; the runtime finds a
// prototype through the global of that name.
export const ERROR_KIND_ERROR: u32 = 0;
export const ERROR_KIND_TYPE: u32 = 1;
export const ERROR_KIND_REFERENCE: u32 = 2;
export const ERROR_KIND_RANGE: u32 = 3;
export const ERROR_KIND_SYNTAX: u32 = 4;
export const ERROR_KIND_EVAL: u32 = 5;
export const ERROR_KIND_URI: u32 = 6;
export const ERROR_KIND_AGGREGATE: u32 = 7;
export const ERROR_KIND_COUNT: u32 = 8;

export const PROMISE_PENDING: i32 = 0;
export const PROMISE_FULFILLED: i32 = 1;
export const PROMISE_REJECTED: i32 = 2;
// Builtins whose instances are made while the program runs: resolving
// functions, element functions, bound functions. Each is registered in
// the host table once, and an instance is a cell sharing that entry, so
// making one grows nothing but the heap the collector manages.
export const HOST_PROMISE_RESOLVE: usize = 0;
export const HOST_PROMISE_REJECT: usize = 1;
export const HOST_ASYNC_FROM_SYNC_UNWRAP: usize = 2;
export const HOST_CAPABILITY_EXECUTOR: usize = 3;
export const HOST_RETURN_BOUND: usize = 4;
export const HOST_THROW_BOUND: usize = 5;
export const HOST_FINALLY_FULFILLED: usize = 6;
export const HOST_FINALLY_REJECTED: usize = 7;
export const HOST_ELEMENT_FULFILLED: usize = 8;
export const HOST_ELEMENT_REJECTED: usize = 9;
export const HOST_BOUND_TRAMPOLINE: usize = 10;

// What a function's [[Prototype]] chain answered to a [[Set]].
const SET_NOT_INHERITED: i32 = 0;
const SET_DONE: i32 = 1;
const SET_REFUSED: i32 = 2;

const JOB_REACTION: i32 = 0;
const JOB_THENABLE: i32 = 1;
// The drained front of the job queue is dropped once it is this long
// (in values, four to a job) and at least half the queue.
const JOB_COMPACT_AT: usize = 4096;
export const REACTION_HANDLER: i32 = 0;
export const REACTION_ASYNC: i32 = 1;
export const REACTION_ASYNC_GEN_AWAIT: i32 = 2;
export const REACTION_ASYNC_GEN_YIELD: i32 = 3;
// The awaited value of a return request on a generator that is not
// running (unstarted or completed): settles the request.
export const REACTION_ASYNC_GEN_RETURN_DONE: i32 = 4;
// The awaited value of a return request into a suspended body: resumes
// it in return mode, or in throw mode when the await rejected.
export const REACTION_ASYNC_GEN_RESUME_RETURN: i32 = 5;

// ToPrimitive hints.
export const HINT_DEFAULT: u32 = 0;
export const HINT_NUMBER: u32 = 1;
export const HINT_STRING: u32 = 2;

// Generator states.
const GEN_START: i32 = 0;
const GEN_YIELDED: i32 = 1;
const GEN_RUNNING: i32 = 2;
const GEN_COMPLETED: i32 = 3;
// An async body parked on an await (or an async generator on the await
// of its yielded value): only the driver resumes it.
const GEN_AWAITING: i32 = 4;
// An async generator awaiting a return request's value while not
// running; requests queue behind it.
const GEN_AWAITING_RETURN: i32 = 5;

export function errorKindName(kind: u32): String {
  if (kind == ERROR_KIND_ERROR) return "Error";
  if (kind == ERROR_KIND_TYPE) return "TypeError";
  if (kind == ERROR_KIND_REFERENCE) return "ReferenceError";
  if (kind == ERROR_KIND_RANGE) return "RangeError";
  if (kind == ERROR_KIND_SYNTAX) return "SyntaxError";
  if (kind == ERROR_KIND_EVAL) return "EvalError";
  if (kind == ERROR_KIND_URI) return "URIError";
  return "AggregateError";
}

// An own property as seen by [[GetOwnProperty]]: a data property holds
// `value`, an accessor holds `getter` / `setter`; `attr` carries the
// PROP_* bits. `present` is false for no such property.
export struct PropertyDescriptor {
  present: boolean;
  value: Value;
  getter: Value;
  setter: Value;
  attr: u8;
}

export function absentProperty(): PropertyDescriptor {
  return PropertyDescriptor({ present: false, value: undefinedValue(), getter: undefinedValue(), setter: undefinedValue(), attr: 0 });
}

export function dataProperty(value: Value, attr: u8): PropertyDescriptor {
  return PropertyDescriptor({ present: true, value: value, getter: undefinedValue(), setter: undefinedValue(), attr: attr });
}

// A descriptor as [[DefineOwnProperty]] receives it: every field optional.
export struct DescriptorInput {
  hasValue: boolean;
  value: Value;
  hasGetter: boolean;
  getter: Value;
  hasSetter: boolean;
  setter: Value;
  hasWritable: boolean;
  writable: boolean;
  hasEnumerable: boolean;
  enumerable: boolean;
  hasConfigurable: boolean;
  configurable: boolean;
}

export function emptyDescriptorInput(): DescriptorInput {
  return DescriptorInput({
    hasValue: false, value: undefinedValue(), hasGetter: false, getter: undefinedValue(),
    hasSetter: false, setter: undefinedValue(), hasWritable: false, writable: false,
    hasEnumerable: false, enumerable: false, hasConfigurable: false, configurable: false,
  });
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
  // Every installed function's instructions, end to end; a function
  // locates its own by codeStart and codeLength.
  codeSegment: Array<Inst>;
  globals: Array<Global>;
  // Interned strings: open-addressed table of string cell handles, keyed by
  // the bytes' hash. 0 marks an empty bucket (handle 0 is never a cell).
  atoms: Array<u32>;
  atomCount: u32;
  // The register stack and frame stack grow monotonically and are reused;
  // `regTop` / `frameCount` mark the live extent, as in the reference. A
  // frame is a window over the register stack, so both move together.
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
  symbolProto: u32;
  // Math.random's state.
  randomState: u64;
  // The completion value of the last run, kept alive for the embedder.
  lastResult: Value;
  // Builtins, indexed by a host function cell's payload.
  hostTable: Array<HostFunction>;
  // Host table entries of the builtins instantiated at run time, by the
  // HOST_ constants.
  sharedHosts: Array<u32>;
  // The global object: `this` at the top level and in sloppy calls; its
  // properties fall through to the globals table.
  globalObject: u32;
  // Cells a builtin holds in Z locals across a call back into JavaScript,
  // so a collection there cannot free them.
  tempRoots: Array<Value>;
  // Atoms the runtime consults by identity.
  atomLength: u32;
  atomPrototype: u32;
  atomConstructor: u32;
  atomName: u32;
  atomMessage: u32;
  // Names the engine itself looks up constantly: iterator results,
  // thenables, iterator methods. Held as atoms so a lookup builds nothing.
  atomDone: u32;
  atomValue: u32;
  atomThen: u32;
  atomNext: u32;
  atomReturn: u32;
  atomThrow: u32;
  atomResolve: u32;
  // The hidden key under which a wrapper object keeps its primitive. Its
  // bytes begin with 0xFF, which no JavaScript string can contain, so
  // user code can neither read nor forge it.
  atomPrimitive: u32;
  // The hidden key marking an arguments object's bag.
  atomArgumentsMarker: u32;
  // Iteration: %IteratorPrototype%, %ArrayIteratorPrototype%, the hidden
  // keys an array iterator keeps its state under, and the builtin `next`
  // whose presence allows the allocation-free fast path.
  iteratorProto: u32;
  arrayIteratorProto: u32;
  // %GeneratorPrototype%, and the hidden key under which a generator
  // object keeps its record.
  generatorProto: u32;
  atomGenRecord: u32;
  // Keyed collections: the prototypes the collections module installs,
  // and the hidden keys a collection and its iterator keep their records
  // under.
  mapProto: u32;
  setProto: u32;
  weakMapProto: u32;
  weakSetProto: u32;
  mapIteratorProto: u32;
  setIteratorProto: u32;
  atomMapRecord: u32;
  atomMapIter: u32;
  // Class bookkeeping on function cells, under hidden keys: the parent
  // constructor, the home object of a method (for `super`), an arrow's
  // captured `new.target`, and a constructor's own [[Prototype]] when it
  // is not Function.prototype.
  atomHome: u32;
  atomNewTarget: u32;
  atomFunctionProto: u32;
  // Promises: %Promise.prototype%, the hidden key of a promise's record,
  // and the job queue (each job a heap array) with its read cursor.
  promiseProto: u32;
  // The intrinsic Promise constructor: the one constructor whose
  // capabilities the engine may make without observable steps.
  promiseCtor: u32;
  // Function.prototype[@@hasInstance], which is neither writable nor
  // configurable. When an instanceof finds it as the handler, the call
  // is skipped for what it does, OrdinaryHasInstance.
  hasInstanceBuiltin: u32;
  // The getter installed as Promise[Symbol.species]. While it is still
  // in place its call can be skipped: it returns its receiver and does
  // nothing else, so nothing can tell.
  promiseSpeciesGetter: u32;
  // The new target of a builtin construct call whose constructor makes
  // its own object; that constructor takes it on entry, so a plain call
  // finds undefined here.
  hostNewTarget: Value;
  atomPromiseRecord: u32;
  atomErrorData: u32;
  atomDateValue: u32;
  atomRegexSource: u32;
  atomRegexFlags: u32;
  atomRegexCompiled: u32;
  atomRegexIter: u32;
  atomRegexTicket: u32;
  atomLastIndex: u32;
  atomIndex: u32;
  atomInput: u32;
  atomGroups: u32;
  atomExec: u32;
  atomFlags: u32;
  regexProto: u32;
  regexIteratorProto: u32;
  regexExecFn: u32;
  regexCtor: u32;
  regexBackend: RegexBackend;
  symbolMatch: Value;
  symbolMatchAll: Value;
  symbolReplace: Value;
  symbolSearch: Value;
  symbolSplit: Value;
  // %AsyncIteratorPrototype% and %AsyncGeneratorPrototype%.
  asyncIteratorProto: u32;
  asyncGeneratorProto: u32;
  symbolAsyncIterator: Value;
  // %AsyncFromSyncIteratorPrototype%, and the hidden key under which such
  // a wrapper keeps its sync iterator.
  asyncFromSyncProto: u32;
  atomSyncIterator: u32;
  jobs: Array<Value>;
  jobCursor: usize;
  // Collection timing, off unless the host turns it on: each pause in
  // nanoseconds, in order. Nothing is read from the clock otherwise.
  gcTiming: boolean;
  gcPauses: Array<f64>;
  // Whether the async body last resumed finished, beside the value it
  // handed back (see resumeResult).
  resumeDone: boolean;
  atomIterSource: u32;
  atomIterIndex: u32;
  atomIterKind: u32;
  arrayIteratorNext: u32;
  // Symbols: each takes a fresh number for its key atom; the registry
  // backs Symbol.for; the well-known ones the runtime consults.
  symbolCounter: u32;
  symbolRegistry: Array<Value>;
  symbolIterator: Value;
  symbolToPrimitive: Value;
  symbolToStringTag: Value;
  symbolHasInstance: Value;
  symbolSpecies: Value;
  symbolIsConcatSpreadable: Value;
  symbolUnscopables: Value;

  function addFunction(inout this, code: FunctionCode): u32 {
    const index = this.reserveFunction();
    this.setFunction(index, move code);
    return index;
  }

  // Reserve a function index before its body is compiled, so a named
  // function expression can refer to itself; fill it in afterwards.
  function reserveFunction(inout this): u32 {
    this.functions.push(createFunctionCode());
    return u32(this.functions.length - 1);
  }

  function setFunction(inout this, index: u32, code: FunctionCode): void {
    let installed = move code;
    installed.codeStart = u32(this.codeSegment.length);
    installed.codeLength = u32(installed.code.length);
    let at: usize = 0;
    const count = installed.code.length;
    while (at < count) {
      const inst = installed.code[at];
      this.codeSegment.push(inst);
      at = at + 1;
    }
    installed.code = Array<Inst>();
    installed.caches = Array<PropertyCache>();
    let nameSlot: usize = 0;
    const names = installed.propertyNames.length;
    while (nameSlot < names) {
      installed.caches.push(emptyCache());
      nameSlot = nameSlot + 1;
    }
    this.functions[usize(index)] = move installed;
  }

  // --- Inline caches ---
  //
  // A property access site remembers the receiver's hidden class and
  // where the property was found. Validation is by class: a class fixes
  // the slot layout, adding or removing a property changes the class, and
  // a redefined slot is caught by the attribute checks. A cached
  // prototype is compared by handle against the receiver's actual
  // prototype, so a reused handle cannot alias. A dictionary-mode object
  // is never recorded, and its payload equals no class, so a site that
  // cached the object before it changed representation misses.

  // A cached load, or the deleted marker for a miss.
  function loadCached(fi: u32, nameSlot: usize, handle: u32): Value {
    const cache = this.functions[usize(fi)].caches[nameSlot];
    if (cache.kind == CACHE_OWN) {
      if (this.heap.objectClass(handle) != cache.receiverClass) return deletedValue();
      if ((this.heap.attrOf(handle, cache.slot) & PROP_ACCESSOR) != 0) return deletedValue();
      return this.heap.slot(handle, cache.slot);
    }
    if (cache.kind == CACHE_PROTO) {
      if (this.heap.objectClass(handle) != cache.receiverClass) return deletedValue();
      const proto = this.heap.objectProto(handle);
      if (proto != cache.proto1 || this.heap.objectClass(proto) != cache.proto1Class) return deletedValue();
      if ((this.heap.attrOf(proto, cache.slot) & PROP_ACCESSOR) != 0) return deletedValue();
      return this.heap.slot(proto, cache.slot);
    }
    return deletedValue();
  }

  function populateLoadCache(inout this, fi: u32, nameSlot: usize, handle: u32, atom: u32): void {
    if (this.heap.isDictionary(handle)) return;
    const receiverClass = this.heap.objectClass(handle);
    const own = this.heap.objectFindSlot(handle, atom);
    if (own >= 0) {
      if (isDeleted(this.heap.slot(handle, u32(own)))) return;
      this.functions[usize(fi)].caches[nameSlot] = PropertyCache({ kind: CACHE_OWN, depth: 0, receiverClass: receiverClass, slot: u32(own), targetClass: 0, proto1: 0, proto1Class: 0, proto2: 0, proto2Class: 0 });
      return;
    }
    const proto = this.heap.objectProto(handle);
    if (proto == 0 || !this.heap.isObject(proto) || this.heap.isDictionary(proto)) return;
    const inherited = this.heap.objectFindSlot(proto, atom);
    if (inherited < 0 || isDeleted(this.heap.slot(proto, u32(inherited)))) return;
    const protoClass = this.heap.objectClass(proto);
    this.functions[usize(fi)].caches[nameSlot] = PropertyCache({ kind: CACHE_PROTO, depth: 1, receiverClass: receiverClass, slot: u32(inherited), targetClass: 0, proto1: proto, proto1Class: protoClass, proto2: 0, proto2Class: 0 });
  }

  // A cached store; false for a miss.
  function storeCached(inout this, fi: u32, nameSlot: usize, handle: u32, value: Value): boolean {
    const cache = this.functions[usize(fi)].caches[nameSlot];
    if (cache.kind == CACHE_OWN) {
      if (this.heap.objectClass(handle) != cache.receiverClass) return false;
      const attr = this.heap.attrOf(handle, cache.slot);
      if ((attr & PROP_ACCESSOR) != 0 || (attr & PROP_WRITABLE) == 0) return false;
      if (isDeleted(this.heap.slot(handle, cache.slot))) return false;
      this.heap.setSlot(handle, cache.slot, value);
      return true;
    }
    if (cache.kind == CACHE_TRANSITION) {
      if (this.heap.objectClass(handle) != cache.receiverClass) return false;
      if ((this.heap.flagsOf(handle) & FLAG_NON_EXTENSIBLE) != 0) return false;
      let proto = this.heap.objectProto(handle);
      if (cache.depth >= 1) {
        if (proto != cache.proto1 || this.heap.objectClass(proto) != cache.proto1Class) return false;
        proto = this.heap.objectProto(proto);
      }
      if (cache.depth >= 2) {
        if (proto != cache.proto2 || this.heap.objectClass(proto) != cache.proto2Class) return false;
        proto = this.heap.objectProto(proto);
      }
      if (proto != 0) return false;
      this.heap.transitionTo(handle, cache.targetClass, cache.slot, value);
      return true;
    }
    return false;
  }

  // After a slow-path store on an object: remember an own writable data
  // property, or the transition that added one when the prototype chain
  // (at most two objects, ending in null) holds no such property.
  function populateStoreCache(inout this, fi: u32, nameSlot: usize, handle: u32, atom: u32, classBefore: u32): void {
    if (handle == this.globalObject || this.heap.isDictionary(handle)) return;
    const own = this.heap.objectFindSlot(handle, atom);
    if (own < 0) return;
    const attr = this.heap.attrOf(handle, u32(own));
    if ((attr & PROP_ACCESSOR) != 0 || (attr & PROP_WRITABLE) == 0) return;
    if (isDeleted(this.heap.slot(handle, u32(own)))) return;
    const classAfter = this.heap.objectClass(handle);
    if (classAfter == classBefore) {
      this.functions[usize(fi)].caches[nameSlot] = PropertyCache({ kind: CACHE_OWN, depth: 0, receiverClass: classAfter, slot: u32(own), targetClass: 0, proto1: 0, proto1Class: 0, proto2: 0, proto2Class: 0 });
      return;
    }
    if (!this.heap.isTransitionOf(classAfter, classBefore, atom)) return;
    let depth: u8 = 0;
    let proto1: u32 = 0;
    let proto1Class: u32 = 0;
    let proto2: u32 = 0;
    let proto2Class: u32 = 0;
    let proto = this.heap.objectProto(handle);
    if (proto != 0) {
      if (!this.heap.isObject(proto) || this.heap.isDictionary(proto) || this.heap.objectFindSlot(proto, atom) >= 0) return;
      depth = 1;
      proto1 = proto;
      proto1Class = this.heap.objectClass(proto);
      proto = this.heap.objectProto(proto);
    }
    if (proto != 0) {
      if (!this.heap.isObject(proto) || this.heap.isDictionary(proto) || this.heap.objectFindSlot(proto, atom) >= 0) return;
      depth = 2;
      proto2 = proto;
      proto2Class = this.heap.objectClass(proto);
      proto = this.heap.objectProto(proto);
    }
    if (proto != 0) return;
    this.functions[usize(fi)].caches[nameSlot] = PropertyCache({ kind: CACHE_TRANSITION, depth: depth, receiverClass: classBefore, slot: u32(own), targetClass: classAfter, proto1: proto1, proto1Class: proto1Class, proto2: proto2, proto2Class: proto2Class });
  }

  function functionValue(inout this, index: u32): Value {
    return cellValue(this.heap.allocateFunction(index));
  }

  function isFunctionValue(value: Value): boolean {
    return isCell(value) && asCell(value) != 0 && this.heap.isFunction(asCell(value));
  }

  // A global that a hoisted declaration defines before any statement runs.
  function defineGlobalSlot(inout this, name: String): u16 {
    return this.defineGlobalSlotBytes(bytesOf(in name));
  }

  function defineGlobalSlotBytes(inout this, bytes: Array<u8>): u16 {
    const slot = this.globalSlotBytes(move bytes);
    this.globals[usize(slot)].defined = true;
    return slot;
  }

  function globalSlot(inout this, name: String): u16 {
    return this.globalSlotBytes(bytesOf(in name));
  }

  // Global slot for a name, allocating one on first sight. Names are
  // interned; the slot is found by atom. Linear for now.
  function globalSlotBytes(inout this, bytes: Array<u8>): u16 {
    const atom = this.internUtf8(move bytes);
    const found = this.findGlobalByAtom(atom);
    if (found >= 0) return u16(found);
    this.globals.push(Global({ value: undefinedValue(), defined: false, atom: atom, attr: PROP_WRITABLE | PROP_ENUMERABLE }));
    return u16(this.globals.length - 1);
  }

  // A hidden two-letter key: 0xFF then the letters, unforgeable from
  // JavaScript.
  function hiddenAtom(inout this, first: u8, second: u8): u32 {
    let bytes = Array<u8>();
    bytes.push(255);
    bytes.push(first);
    bytes.push(second);
    return this.hiddenAtomBytes(move bytes);
  }

  // A hidden value kept on a function-like cell's bag; undefined if none.
  function functionHidden(handle: u32, atom: u32): Value {
    const bag = this.functionBag(handle);
    if (bag == 0) return undefinedValue();
    const slot = this.heap.objectFindSlot(bag, atom);
    if (slot < 0) return undefinedValue();
    const held = this.heap.slot(bag, u32(slot));
    if (isDeleted(held)) return undefinedValue();
    return held;
  }

  function setFunctionHidden(inout this, handle: u32, atom: u32, value: Value): void {
    const bag = this.ensureFunctionBag(handle);
    this.heap.objectDefine(bag, atom, value, PROP_NONE);
  }

  // A function's [[Prototype]] -- the object it inherits from, which is
  // not its `prototype` property. Function.prototype unless it was given
  // another: a class's parent constructor, a bound function's target's
  // own, or whatever setPrototypeOf installed, null (0) included.
  function functionProtoOf(handle: u32): u32 {
    const atomFunctionProto = this.atomFunctionProto;
    const override = this.functionHidden(handle, atomFunctionProto);
    if (isNull(override)) return 0;
    if (isCell(override) && asCell(override) != 0) return asCell(override);
    return this.functionProto;
  }

  // A bound function is an instance of the one bound trampoline; its
  // bound data is [target, boundThis, arguments...].
  function isBoundFunction(value: Value): boolean {
    if (!this.isHostFunctionValue(value)) return false;
    if (this.sharedHosts.length <= HOST_BOUND_TRAMPOLINE) return false;
    return this.heap.hostFunctionId(asCell(value)) == this.sharedHosts[HOST_BOUND_TRAMPOLINE];
  }

  function boundTargetOf(value: Value): Value {
    const record = asCell(this.heap.slot(asCell(value), 0));
    return this.heap.slot(record, 0);
  }

  // A private name read or written on a value that does not hold it: a
  // primitive, or an object the class did not initialize.
  function privateNameMissing(inout this, value: Value, key: Value): boolean {
    if (!this.isSymbolValue(key)) return false;
    if ((this.heap.flagsOf(asCell(key)) & FLAG_PRIVATE_NAME) == 0) return false;
    if (!this.isObjectLike(value)) return true;
    return !this.hasProperty(value, key);
  }

  // Whether a symbol key atom names a class private name.
  function isPrivateKeyAtom(atom: u32): boolean {
    if (!this.isSymbolKeyAtom(atom)) return false;
    const symbol = this.heap.linkOf(atom);
    return symbol != 0 && (this.heap.flagsOf(symbol) & FLAG_PRIVATE_NAME) != 0;
  }

  // --- Strings ---

  function isStringValue(value: Value): boolean {
    return isCell(value) && asCell(value) != 0 && this.heap.isString(asCell(value));
  }

  // Atoms hash by unit value, so Latin-1 bytes and the units they stand
  // for hash alike.
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

  function hashUnits(in units: Array<u16>): u32 {
    let hash: u32 = 2166136261;
    let index: usize = 0;
    const length = units.length;
    while (index < length) {
      hash = (hash ^ u32(units[index])).wrappingMultiply(16777619);
      index = index + 1;
    }
    return hash;
  }

  function hashStorage(handle: u32): u32 {
    let hash: u32 = 2166136261;
    let index: usize = 0;
    if (!this.heap.isWideString(handle)) {
      const length = this.heap.stringStorageLength(handle);
      while (index < length) {
        hash = (hash ^ u32(this.heap.stringStorageByte(handle, index))).wrappingMultiply(16777619);
        index = index + 1;
      }
      return hash;
    }
    const units = this.heap.stringLength(handle);
    while (index < units) {
      hash = (hash ^ u32(this.heap.stringUnit(handle, index))).wrappingMultiply(16777619);
      index = index + 1;
    }
    return hash;
  }

  // A fresh string holding units[start, end) of another.
  function substringValue(inout this, handle: u32, start: usize, end: usize): Value {
    return cellValue(this.heap.allocateSubstring(handle, start, end));
  }

  function atomMatches(handle: u32, in bytes: Array<u8>): boolean {
    if (this.heap.isWideString(handle)) return false;
    const length = bytes.length;
    if (this.heap.stringStorageLength(handle) != length) return false;
    let index: usize = 0;
    while (index < length) {
      if (this.heap.stringStorageByte(handle, index) != bytes[index]) return false;
      index = index + 1;
    }
    return true;
  }

  function atomMatchesUnits(handle: u32, in units: Array<u16>): boolean {
    const length = units.length;
    if (this.heap.stringLength(handle) != length) return false;
    let index: usize = 0;
    while (index < length) {
      if (this.heap.stringUnit(handle, index) != units[index]) return false;
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
        let slot = usize(this.hashStorage(handle)) & (newSize - 1);
        while (rebuilt[slot] != 0) { slot = (slot + 1) & (newSize - 1); }
        rebuilt[slot] = handle;
      }
      index = index + 1;
    }
    this.atoms = move rebuilt;
  }

  function markInterned(inout this, handle: u32): void {
    const flags = this.heap.flagsOf(handle);
    this.heap.setFlags(handle, flags | FLAG_INTERNED);
  }

  // The unique string cell whose units are these Latin-1 bytes.
  function internLatin1(inout this, bytes: Array<u8>): u32 {
    if ((usize(this.atomCount) + 1) * 2 > this.atoms.length) this.growAtoms();
    const mask = this.atoms.length - 1;
    let slot = usize(this.hashBytes(in bytes)) & mask;
    while (true) {
      const existing = this.atoms[slot];
      if (existing == 0) break;
      if (this.atomMatches(existing, in bytes)) return existing;
      slot = (slot + 1) & mask;
    }
    const handle = this.heap.allocateLatin1(move bytes);
    this.markInterned(handle);
    this.atoms[slot] = handle;
    this.atomCount = this.atomCount + 1;
    return handle;
  }

  // The unique string cell with these units.
  function internUnits(inout this, units: Array<u16>): u32 {
    if (isNarrowUnits(in units)) return this.internLatin1(unitsToLatin1(in units));
    if ((usize(this.atomCount) + 1) * 2 > this.atoms.length) this.growAtoms();
    const mask = this.atoms.length - 1;
    let slot = usize(this.hashUnits(in units)) & mask;
    while (true) {
      const existing = this.atoms[slot];
      if (existing == 0) break;
      if (this.atomMatchesUnits(existing, in units)) return existing;
      slot = (slot + 1) & mask;
    }
    const handle = this.heap.allocateUnits(move units);
    this.markInterned(handle);
    this.atoms[slot] = handle;
    this.atomCount = this.atomCount + 1;
    return handle;
  }

  // The unique string cell for UTF-8 text (source names, host text).
  function internUtf8(inout this, bytes: Array<u8>): u32 {
    if (isAsciiBytes(in bytes)) return this.internLatin1(move bytes);
    return this.internUnits(utf8ToUnits(in bytes));
  }

  // The atom with an existing string cell's content: the cell itself
  // once registered, so a computed key costs no copy.
  function internExisting(inout this, handle: u32): u32 {
    if ((this.heap.flagsOf(handle) & FLAG_INTERNED) != 0) return handle;
    if ((usize(this.atomCount) + 1) * 2 > this.atoms.length) this.growAtoms();
    const mask = this.atoms.length - 1;
    let slot = usize(this.hashStorage(handle)) & mask;
    while (true) {
      const existing = this.atoms[slot];
      if (existing == 0) break;
      if (this.heap.stringsEqual(existing, handle)) return existing;
      slot = (slot + 1) & mask;
    }
    this.markInterned(handle);
    this.atoms[slot] = handle;
    this.atomCount = this.atomCount + 1;
    return handle;
  }

  function internLatin1Value(inout this, bytes: Array<u8>): Value {
    return cellValue(this.internLatin1(move bytes));
  }

  function internUnitsValue(inout this, units: Array<u16>): Value {
    return cellValue(this.internUnits(move units));
  }

  function internUtf8Value(inout this, bytes: Array<u8>): Value {
    return cellValue(this.internUtf8(move bytes));
  }

  function internText(inout this, in text: String): Value {
    return cellValue(this.internUtf8(bytesOf(in text)));
  }

  // Fresh (non-interned) string cells: from Latin-1 bytes (ASCII output
  // such as numbers), from units, from UTF-8 text.
  function newStringLatin1(inout this, bytes: Array<u8>): Value {
    return cellValue(this.heap.allocateLatin1(move bytes));
  }

  function newStringUnits(inout this, units: Array<u16>): Value {
    return cellValue(this.heap.allocateUnits(move units));
  }

  function newStringUtf8(inout this, bytes: Array<u8>): Value {
    return cellValue(this.heap.allocateUtf8(move bytes));
  }

  // An engine-internal key: a string cell no program can reach by
  // content, since it is never in the atom table.
  function hiddenAtomBytes(inout this, bytes: Array<u8>): u32 {
    const handle = this.heap.allocateLatin1(move bytes);
    this.heap.setFlags(handle, FLAG_HIDDEN);
    return handle;
  }

  // ToNumber of a string: the specification's whitespace beyond ASCII
  // trims like a space; any other unit above ASCII makes it NaN.
  function stringValueToNumber(handle: u32): f64 {
    const length = this.heap.stringLength(handle);
    let bytes = Array<u8>.withCapacity(length);
    let index: usize = 0;
    while (index < length) {
      const unit = this.heap.stringUnit(handle, index);
      if (unit < 0x80) {
        bytes.push(u8(unit));
      } else if (isJsSpace(unit)) {
        bytes.push(32);
      } else {
        return nativeNan();
      }
      index = index + 1;
    }
    return stringToNumber(in bytes);
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
    return this.internUtf8(bytesOf(in text));
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
    this.markErrorData(object);
    const kindName = errorKindName(kind);
    const nameValue = this.internText(in kindName);
    const atomName = this.atomName;
    this.heap.objectSet(object, atomName, nameValue);
    const messageValue = this.newStringUtf8(move message);
    const atomMessage = this.atomMessage;
    this.heap.objectSet(object, atomMessage, messageValue);
    return cellValue(object);
  }

  // The error data slot: what makes an object an error instance to the
  // `stack` accessor, whichever prototype it was given.
  function markErrorData(inout this, object: u32): void {
    const atomErrorData = this.atomErrorData;
    if (this.heap.objectFindSlot(object, atomErrorData) >= 0) return;
    this.heap.objectDefine(object, atomErrorData, booleanValue(true), PROP_NONE);
  }

  // --- Date objects ---
  //
  // A Date is an object with a hidden time-value slot; the prototype has
  // none, so it is not a Date itself.
  function isDateObject(value: Value): boolean {
    if (!this.isObjectLike(value)) return false;
    return this.heap.objectFindSlot(asCell(value), this.atomDateValue) >= 0;
  }

  function dateTimeValue(handle: u32): f64 {
    const slot = this.heap.objectFindSlot(handle, this.atomDateValue);
    if (slot < 0) return nanValue();
    return toNumber(this.heap.slot(handle, u32(slot)));
  }

  function setDateTimeValue(inout this, handle: u32, time: f64): void {
    const atomDateValue = this.atomDateValue;
    this.heap.objectDefine(handle, atomDateValue, doubleValue(time), PROP_NONE);
  }

  // --- RegExp objects ---
  //
  // A RegExp keeps its source, flag bits, and the backend cache slot of
  // its compiled form in hidden slots; `lastIndex` is an ordinary own
  // property. The prototype has no slots, so it is not a RegExp itself.
  function isRegExpObject(value: Value): boolean {
    if (!this.isObjectLike(value)) return false;
    return this.heap.objectFindSlot(asCell(value), this.atomRegexSource) >= 0;
  }

  function regexpSourceValue(handle: u32): Value {
    const slot = this.heap.objectFindSlot(handle, this.atomRegexSource);
    return this.heap.slot(handle, u32(slot));
  }

  // The pattern for the backend: UTF-8 with lone surrogates kept.
  function regexpSource(handle: u32): Array<u8> {
    const units = this.heap.stringUnits(asCell(this.regexpSourceValue(handle)));
    return unitsToWtf8(in units);
  }

  function regexpFlagBits(handle: u32): i32 {
    const slot = this.heap.objectFindSlot(handle, this.atomRegexFlags);
    return asInt32(this.heap.slot(handle, u32(slot)));
  }

  // IsRegExp: an object's @@match decides when present; else the slot.
  function isRegExp(inout this, value: Value): boolean {
    if (!this.isObjectLike(value)) return false;
    const symbolMatch = this.symbolMatch;
    const matcher = this.getProperty(value, symbolMatch);
    if (this.pendingThrow) return false;
    if (!isUndefined(matcher)) return this.toBooleanValue(matcher);
    return this.isRegExpObject(value);
  }

  // A flags string to bits; -1 for an unknown or repeated flag.
  function regexpFlagBitsOf(in flags: Array<u16>): i32 {
    let bits: i32 = 0;
    let i: usize = 0;
    while (i < flags.length) {
      const flag = flags[i];
      let bit: i32 = 0;
      if (flag == 100) bit = REGEX_HAS_INDICES;
      if (flag == 103) bit = REGEX_GLOBAL;
      if (flag == 105) bit = REGEX_IGNORE_CASE;
      if (flag == 109) bit = REGEX_MULTILINE;
      if (flag == 115) bit = REGEX_DOT_ALL;
      if (flag == 117) bit = REGEX_UNICODE;
      if (flag == 118) bit = REGEX_UNICODE_SETS;
      if (flag == 121) bit = REGEX_STICKY;
      if (bit == 0 || (bits & bit) != 0) return -1;
      bits = bits | bit;
      i = i + 1;
    }
    if ((bits & REGEX_UNICODE) != 0 && (bits & REGEX_UNICODE_SETS) != 0) return -1;
    return bits;
  }

  // RegExpAlloc: an object with a writable, non-enumerable,
  // non-configurable `lastIndex`, not yet a RegExp.
  function regexpAlloc(inout this, proto: u32): u32 {
    const object = this.heap.allocateObject(proto);
    const atomLastIndex = this.atomLastIndex;
    this.heap.objectDefine(object, atomLastIndex, int32Value(0), PROP_WRITABLE);
    return object;
  }

  // RegExpInitialize with the pattern and flags already strings: the
  // flags parse, the pattern compiles (a SyntaxError names the backend's
  // complaint), the slots fill, and lastIndex is set to 0 through Set.
  function regexpInitialize(inout this, object: u32, pattern: Value, flags: Value): boolean {
    const flagUnits = this.heap.stringUnits(asCell(flags));
    const bits = this.regexpFlagBitsOf(in flagUnits);
    if (bits < 0) {
      const head: String = "Invalid flags supplied to RegExp constructor '";
      let message = bytesOf(in head);
      appendBytes(inout message, this.heap.stringUtf8(asCell(flags)));
      message.push(39);
      const error = this.makeError(ERROR_KIND_SYNTAX, move message);
      this.raise(error);
      return false;
    }
    const sourceUnits = this.heap.stringUnits(asCell(pattern));
    const sourceBytes = unitsToWtf8(in sourceUnits);
    const entry = this.regexBackend.compile(in sourceBytes, bits);
    if (entry < 0) {
      // A resource failure is not a syntax error.
      const failure = this.regexBackend.lastFailure;
      if (failure == REGEX_OUT_OF_MEMORY) {
        const message: String = "Regular expression: out of memory";
        const error = this.rangeError(in message);
        this.raise(error);
        return false;
      }
      if (failure == REGEX_STACK_LIMIT) {
        const message: String = "Regular expression too complex";
        const error = this.rangeError(in message);
        this.raise(error);
        return false;
      }
      if (failure == REGEX_SIZE_LIMIT) {
        const message: String = "Regular expression too large";
        const error = this.rangeError(in message);
        this.raise(error);
        return false;
      }
      const head: String = "Invalid regular expression: /";
      let message = bytesOf(in head);
      appendBytes(inout message, this.heap.stringUtf8(asCell(pattern)));
      message.push(47);
      appendBytes(inout message, this.heap.stringUtf8(asCell(flags)));
      const separator: String = ": ";
      appendBytes(inout message, bytesOf(in separator));
      const detail = this.regexBackend.errorMessage();
      let k: usize = 0;
      while (k < detail.length) {
        message.push(detail[k]);
        k = k + 1;
      }
      const error = this.makeError(ERROR_KIND_SYNTAX, move message);
      this.raise(error);
      return false;
    }
    const atomRegexSource = this.atomRegexSource;
    this.heap.objectDefine(object, atomRegexSource, pattern, PROP_NONE);
    const atomRegexFlags = this.atomRegexFlags;
    this.heap.objectDefine(object, atomRegexFlags, int32Value(bits), PROP_NONE);
    const atomRegexCompiled = this.atomRegexCompiled;
    this.heap.objectDefine(object, atomRegexCompiled, int32Value(entry), PROP_NONE);
    const ticket = this.regexBackend.ticket(entry);
    const atomRegexTicket = this.atomRegexTicket;
    this.heap.objectDefine(object, atomRegexTicket, doubleValue(ticket), PROP_NONE);
    const atomLastIndex = this.atomLastIndex;
    const stored = this.setProperty(cellValue(object), cellValue(atomLastIndex), int32Value(0));
    if (this.pendingThrow) return false;
    if (!stored) {
      const message: String = "Cannot assign to read only property 'lastIndex'";
      const error = this.typeError(in message);
      this.raise(error);
      return false;
    }
    return true;
  }

  // RegExpCreate from strings (undefined for either means empty).
  function regexpCreate(inout this, pattern: Value, flags: Value, proto: u32): Value {
    let patternText = pattern;
    if (isUndefined(pattern)) patternText = this.internLatin1Value(Array<u8>());
    let flagsText = flags;
    if (isUndefined(flags)) flagsText = this.internLatin1Value(Array<u8>());
    const patternString = this.toStringValue(patternText);
    if (this.pendingThrow) return undefinedValue();
    this.pushTempRoot(patternString);
    const flagsString = this.toStringValue(flagsText);
    if (this.pendingThrow) {
      this.popTempRoot();
      return undefinedValue();
    }
    this.pushTempRoot(flagsString);
    const object = this.regexpAlloc(proto);
    this.pushTempRoot(cellValue(object));
    const ok = this.regexpInitialize(object, patternString, flagsString);
    this.popTempRoot();
    this.popTempRoot();
    this.popTempRoot();
    if (!ok) return undefinedValue();
    return cellValue(object);
  }

  // The backend cache slot for a RegExp, recompiling if it was evicted:
  // the slot's ticket changes when the slot is reused.
  function regexpEntry(inout this, handle: u32): i32 {
    const slot = this.heap.objectFindSlot(handle, this.atomRegexCompiled);
    const cached = asInt32(this.heap.slot(handle, u32(slot)));
    const ticketSlot = this.heap.objectFindSlot(handle, this.atomRegexTicket);
    const ticket = toNumber(this.heap.slot(handle, u32(ticketSlot)));
    if (this.regexBackend.ticket(cached) == ticket) return cached;
    const source = this.regexpSource(handle);
    const bits = this.regexpFlagBits(handle);
    const entry = this.regexBackend.compile(in source, bits);
    if (entry < 0) {
      const message: String = "Regular expression: recompilation failed";
      const error = this.rangeError(in message);
      this.raise(error);
      return -1;
    }
    const atomRegexCompiled = this.atomRegexCompiled;
    this.heap.objectDefine(handle, atomRegexCompiled, int32Value(entry), PROP_NONE);
    const freshTicket = this.regexBackend.ticket(entry);
    const atomRegexTicket = this.atomRegexTicket;
    this.heap.objectDefine(handle, atomRegexTicket, doubleValue(freshTicket), PROP_NONE);
    return entry;
  }

  // Run a RegExp against a string from a unit offset: REGEX_MATCH or
  // REGEX_NO_MATCH, or a raised error for the backend's failures. The
  // string's storage goes straight from the heap into the backend's
  // buffer: Latin-1 bytes are its 8-bit units, wide storage its 16-bit
  // units, so nothing is transcoded.
  function regexpExecRaw(inout this, handle: u32, input: u32, start: usize): i32 {
    const entry = this.regexpEntry(handle);
    if (this.pendingThrow) return REGEX_NO_MATCH;
    const length = this.heap.stringLength(input);
    const storageLength = this.heap.stringStorageLength(input);
    const wide = this.heap.isWideString(input);
    const buffer = this.regexBackend.reserve(storageLength);
    let result = REGEX_OUT_OF_MEMORY;
    if (buffer != 0) {
      let i: usize = 0;
      while (i < storageLength) {
        const byte = this.heap.stringStorageByte(input, i);
        this.regexBackend.store(buffer, i, byte);
        i = i + 1;
      }
      result = this.regexBackend.execLoaded(entry, buffer, length, start, wide);
    }
    if (result >= 0) return result;
    if (result == REGEX_OUT_OF_MEMORY) {
      const message: String = "Regular expression: out of memory";
      const error = this.rangeError(in message);
      this.raise(error);
    } else if (result == REGEX_STEP_LIMIT) {
      const message: String = "Regular expression: step limit exceeded";
      const error = this.rangeError(in message);
      this.raise(error);
    } else if (result == REGEX_STACK_LIMIT) {
      const message: String = "Maximum call stack size exceeded";
      const error = this.rangeError(in message);
      this.raise(error);
    } else {
      const message: String = "Regular expression: invalid bytecode";
      const error = this.typeError(in message);
      this.raise(error);
    }
    return REGEX_NO_MATCH;
  }

  // Native resources held by this runtime go back when it is destroyed,
  // on whatever thread drops the last reference to its context.
  deinit on thread.any {
    this.regexBackend.release();
  }

  function hasErrorData(value: Value): boolean {
    if (!this.isObjectLike(value)) return false;
    return this.heap.objectFindSlot(asCell(value), this.atomErrorData) >= 0;
  }

  function typeError(inout this, in message: String): Value {
    return this.makeError(ERROR_KIND_TYPE, bytesOf(in message));
  }

  function rangeError(inout this, in message: String): Value {
    return this.makeError(ERROR_KIND_RANGE, bytesOf(in message));
  }

  function uriError(inout this, in message: String): Value {
    return this.makeError(ERROR_KIND_URI, bytesOf(in message));
  }

  function syntaxError(inout this, in message: String): Value {
    return this.makeError(ERROR_KIND_SYNTAX, bytesOf(in message));
  }

  // A property key as an atom handle: strings intern their bytes; anything
  // else goes through ToString first.
  function propertyKey(inout this, key: Value): u32 {
    // An atom names itself; any other string registers as one.
    if (this.isStringValue(key)) return this.internExisting(asCell(key));
    if (this.isSymbolValue(key)) return this.heap.symbolKeyAtom(asCell(key));
    const text = this.toStringValue(key);
    return this.internExisting(asCell(text));
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
    if (length > 1 && this.heap.stringUnit(handle, 0) == 48) return -1;
    let value: i64 = 0;
    let index: usize = 0;
    while (index < length) {
      const byte = this.heap.stringUnit(handle, index);
      if (byte < 48 || byte > 57) return -1;
      value = value * 10 + i64(byte - 48);
      index = index + 1;
    }
    if (value > 2147483647) return -1;
    return i32(value);
  }

  // Own-or-inherited property of an object cell, an accessor's getter
  // called with `receiver` as this.
  function lookupProperty(inout this, handle: u32, atom: u32, receiver: Value): Value {
    let current = handle;
    while (current != 0) {
      const slot = this.heap.objectFindSlot(current, atom);
      if (slot >= 0) {
        const value = this.heap.slot(current, u32(slot));
        if (!isDeleted(value)) {
          if ((this.heap.attrOf(current, u32(slot)) & PROP_ACCESSOR) != 0) {
            const getter = this.heap.slot(asCell(value), 0);
            if (!this.isCallable(getter)) return undefinedValue();
            return this.callValue0(getter, receiver);
          }
          return value;
        }
      }
      current = this.heap.objectProto(current);
    }
    return undefinedValue();
  }

  function objectGet(inout this, handle: u32, atom: u32): Value {
    return this.lookupProperty(handle, atom, cellValue(handle));
  }

  // The own property `atom` of an object cell, as a descriptor.
  function ownSlotDescriptor(handle: u32, atom: u32): PropertyDescriptor {
    const slot = this.heap.objectFindSlot(handle, atom);
    if (slot < 0) return absentProperty();
    const value = this.heap.slot(handle, u32(slot));
    if (isDeleted(value)) return absentProperty();
    const attr = this.heap.attrOf(handle, u32(slot));
    if ((attr & PROP_ACCESSOR) != 0) {
      const getter = this.heap.slot(asCell(value), 0);
      const setter = this.heap.slot(asCell(value), 1);
      return PropertyDescriptor({ present: true, value: undefinedValue(), getter: getter, setter: setter, attr: attr });
    }
    return dataProperty(value, attr);
  }

  // A function's `prototype` object, created on first use with a
  // `constructor` back-reference.
  function prototypeOf(inout this, fn: u32): u32 {
    // A `prototype` the program defined (a class, or an assignment)
    // lives in the bag and wins over the lazily created one.
    const atomPrototype = this.atomPrototype;
    const defined = this.functionHidden(fn, atomPrototype);
    if (this.isObjectLike(defined)) return asCell(defined);
    if (this.functionBagHas(fn, atomPrototype)) return this.objectProto;
    const closure = this.heap.isClosure(fn);
    if (closure) {
      const held = this.heap.slot(fn, 1);
      if (isCell(held) && asCell(held) != 0) return asCell(held);
    } else {
      const existing = this.heap.linkOf(fn);
      if (existing != 0) return existing;
    }
    // A generator function's prototype inherits %GeneratorPrototype% and
    // has no constructor.
    let isGeneratorFunction = false;
    if (this.heap.tagOf(fn) == TAG_FUNCTION || closure) {
      const code = this.heap.functionIndex(fn);
      isGeneratorFunction = this.functions[usize(code)].isGenerator;
    }
    let isAsyncGeneratorFunction = false;
    if (isGeneratorFunction) {
      const code = this.heap.functionIndex(fn);
      isAsyncGeneratorFunction = this.functions[usize(code)].isAsync;
    }
    const objectProto = this.objectProto;
    const generatorProto = isAsyncGeneratorFunction ? this.asyncGeneratorProto : this.generatorProto;
    const created = this.heap.allocateObject(isGeneratorFunction ? generatorProto : objectProto);
    const atomConstructor = this.atomConstructor;
    if (!isGeneratorFunction) this.heap.objectDefine(created, atomConstructor, cellValue(fn), PROP_METHOD);
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

  // ToObject: an object as-is, a primitive in its wrapper, null and
  // undefined a TypeError (left pending; the result is then undefined).
  function toObjectValue(inout this, value: Value): Value {
    if (this.isObjectLike(value)) return value;
    if (isUndefined(value) || isNull(value)) {
      const message: String = "Cannot convert undefined or null to object";
      const error = this.typeError(in message);
      this.raise(error);
      return undefinedValue();
    }
    const proto = this.primitiveProto(value);
    return this.wrapPrimitive(value, proto);
  }

  // The intrinsic prototype a primitive reads through, 0 for none.
  function primitiveProto(value: Value): u32 {
    if (isNumber(value)) return this.numberProto;
    if (isBoolean(value)) return this.booleanProto;
    if (this.isStringValue(value)) return this.stringProto;
    if (this.isSymbolValue(value)) return this.symbolProto;
    return 0;
  }

  // [[Get]] for every value the engine has. Absent properties are
  // undefined; primitives read from their intrinsic prototype.
  function getProperty(inout this, object: Value, key: Value): Value {
    if (!isCell(object) || asCell(object) == 0) {
      const proto = this.primitiveProto(object);
      if (proto == 0) return undefinedValue();
      const atom = this.propertyKey(key);
      return this.lookupProperty(proto, atom, object);
    }
    const handle = asCell(object);
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_SYMBOL) {
      const symbolProto = this.symbolProto;
      const atom = this.propertyKey(key);
      return this.lookupProperty(symbolProto, atom, object);
    }
    if (tag == TAG_OBJECT) {
      const atom = this.propertyKey(key);
      const found = this.lookupProperty(handle, atom, object);
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
        if (this.heap.arrayHasIndex(handle, u32(index))) return this.elementValue(handle, u32(index), object);
        const arrayProto = this.arrayProto;
        const atom = this.propertyKey(key);
        return this.lookupProperty(arrayProto, atom, object);
      }
      const atom = this.propertyKey(key);
      if (atom == this.atomLength) return int32Value(i32(this.heap.arrayLength(handle)));
      const bag = this.heap.linkOf(handle);
      if (bag != 0) {
        const own = this.lookupProperty(bag, atom, object);
        if (!isUndefined(own)) return own;
      }
      const arrayProto = this.arrayProto;
      return this.lookupProperty(arrayProto, atom, object);
    }
    if (this.heap.isString(handle)) {
      const index = this.arrayIndexOf(key);
      if (index >= 0) {
        if (usize(index) >= this.heap.stringLength(handle)) return undefinedValue();
        let one = Array<u16>();
        one.push(this.heap.stringUnit(handle, usize(index)));
        return this.internUnitsValue(move one);
      }
      const atom = this.propertyKey(key);
      if (atom == this.atomLength) return int32Value(i32(this.heap.stringLength(handle)));
      const stringProto = this.stringProto;
      return this.lookupProperty(stringProto, atom, object);
    }
    if (tag == TAG_FUNCTION || tag == TAG_HOST_FUNCTION || tag == TAG_CLOSURE) return this.functionGet(handle, key, object);
    return undefinedValue();
  }

  // [[Get]] on a function cell. A class constructor's [[Prototype]] is
  // its parent constructor, itself a function cell with virtual
  // properties, so the walk continues there with the receiver unchanged:
  // an inherited accessor runs against the function the read began on.
  function functionGet(inout this, start: u32, key: Value, receiver: Value): Value {
    const atom = this.propertyKey(key);
    let handle = start;
    while (true) {
      const tag = this.heap.tagOf(handle);
      // An own property wins whatever it holds: one whose value is
      // undefined still hides the virtual property and the parent's.
      const bag = this.functionBag(handle);
      if (bag != 0) {
        const slot = this.heap.objectFindSlot(bag, atom);
        if (slot >= 0) {
          const held = this.heap.slot(bag, u32(slot));
          if (!isDeleted(held)) {
            if ((this.heap.attrOf(bag, u32(slot)) & PROP_ACCESSOR) == 0) return held;
            const getter = this.heap.slot(asCell(held), 0);
            if (!this.isCallable(getter)) return undefinedValue();
            return this.callValue0(getter, receiver);
          }
        }
      }
      if (atom == this.atomPrototype && this.functionHasPrototype(cellValue(handle))) return cellValue(this.prototypeOf(handle));
      if (!this.functionVirtualDeleted(handle, atom)) {
        if (tag == TAG_HOST_FUNCTION) {
          if (atom == this.atomLength) return this.heap.slot(handle, 1);
          if (atom == this.atomName) return this.heap.slot(handle, 2);
        } else {
          const code = this.heap.functionIndex(handle);
          if (atom == this.atomLength) return int32Value(i32(this.functions[usize(code)].expectedArgCount));
          if (atom == this.atomName) return this.functionName(code);
        }
      }
      const functionProto = this.functionProtoOf(handle);
      if (functionProto == 0) return undefinedValue();
      if (this.heap.isObject(functionProto)) return this.lookupProperty(functionProto, atom, receiver);
      const protoTag = this.heap.tagOf(functionProto);
      if (protoTag != TAG_FUNCTION && protoTag != TAG_HOST_FUNCTION && protoTag != TAG_CLOSURE) return this.getProperty(cellValue(functionProto), key);
      handle = functionProto;
    }
    return undefinedValue();
  }

  // [[Set]]. Writes to primitives are silently dropped, as in sloppy
  // mode; attribute and setter checks arrive with property descriptors.
  // [[Set]] on a function that does not own `atom`: the first holder
  // along its [[Prototype]] chain, function cells and then objects. A
  // setter there is called with the receiver (SET_DONE); a setterless
  // accessor or a read-only property refuses (SET_REFUSED); anything
  // else, or nothing, leaves the caller to create an own property.
  function setThroughFunctionChain(inout this, start: u32, atom: u32, value: Value, receiver: Value): i32 {
    let current = this.functionProtoOf(start);
    while (current != 0) {
      const tag = this.heap.tagOf(current);
      const isFunction = tag == TAG_FUNCTION || tag == TAG_HOST_FUNCTION || tag == TAG_CLOSURE;
      if (!isFunction && tag != TAG_OBJECT) return SET_NOT_INHERITED;
      const holder: u32 = isFunction ? this.functionBag(current) : current;
      if (holder != 0) {
        const slot = this.heap.objectFindSlot(holder, atom);
        if (slot >= 0 && !isDeleted(this.heap.slot(holder, u32(slot)))) {
          const attr = this.heap.attrOf(holder, u32(slot));
          if ((attr & PROP_ACCESSOR) != 0) {
            const setter = this.heap.slot(asCell(this.heap.slot(holder, u32(slot))), 1);
            if (!this.isCallable(setter)) return SET_REFUSED;
            const ignored = this.callValue1(setter, receiver, value);
            return SET_DONE;
          }
          return (attr & PROP_WRITABLE) == 0 ? SET_REFUSED : SET_NOT_INHERITED;
        }
      }
      // A function cell's virtual `length` and `name` are read-only.
      if (isFunction && (atom == this.atomLength || atom == this.atomName) && !this.functionVirtualDeleted(current, atom)) return SET_REFUSED;
      current = isFunction ? this.functionProtoOf(current) : this.heap.objectProto(current);
    }
    return SET_NOT_INHERITED;
  }

  // An array element, through its getter when the slot is an accessor.
  function elementValue(inout this, array: u32, index: u32, receiver: Value): Value {
    const held = this.heap.arrayGet(array, index);
    if ((this.heap.attrOf(array, index) & PROP_ACCESSOR) == 0) return held;
    const getter = this.heap.slot(asCell(held), 0);
    if (!this.isCallable(getter)) return undefinedValue();
    return this.callValue0(getter, receiver);
  }

  // The length an array may take from a value: its ToNumber must be an
  // exact uint32, else a RangeError is raised.
  function arrayLengthFrom(inout this, value: Value): u32 {
    const number = this.toNumberValue(value);
    if (this.pendingThrow) return 0;
    if (number != number || number < 0.0 || number > 4294967295.0 || !isIntegralDouble(number)) {
      const message: String = "Invalid array length";
      const error = this.makeError(ERROR_KIND_RANGE, bytesOf(in message));
      this.raise(error);
      return 0;
    }
    return u32(number);
  }

  // [[Set]]: an own or inherited setter runs; a non-writable property or
  // an unextensible target rejects the write, and the caller decides
  // whether that is a TypeError (strict code) or silence. Writes to
  // primitives are dropped.
  function setProperty(inout this, object: Value, key: Value, value: Value): boolean {
    if (!isCell(object) || asCell(object) == 0) return true;
    const handle = asCell(object);
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_OBJECT) {
      const atom = this.propertyKey(key);
      if (handle == this.globalObject && this.heap.objectFindSlot(handle, atom) < 0) {
        const slot = this.findGlobalByAtom(atom);
        if (slot >= 0) {
          if ((this.globals[usize(slot)].attr & PROP_WRITABLE) == 0 && this.globals[usize(slot)].defined) return false;
          this.globals[usize(slot)].value = value;
          this.globals[usize(slot)].defined = true;
          return true;
        }
      }
      return this.setOnObject(handle, atom, value, object);
    }
    if (tag == TAG_ARRAY) {
      const index = this.arrayIndexOf(key);
      if (index >= 0) {
        const present = this.heap.arrayHasIndex(handle, u32(index));
        if (present) {
          const attr = this.heap.attrOf(handle, u32(index));
          if ((attr & PROP_ACCESSOR) != 0) {
            const setter = this.heap.slot(asCell(this.heap.arrayGet(handle, u32(index))), 1);
            if (!this.isCallable(setter)) return false;
            this.callValue1(setter, object, value);
            return true;
          }
          if ((attr & PROP_WRITABLE) == 0) return false;
        }
        if (!present && (this.heap.flagsOf(handle) & FLAG_NON_EXTENSIBLE) != 0) return false;
        if (!present && u32(index) >= this.heap.arrayLength(handle) && (this.heap.flagsOf(handle) & FLAG_LENGTH_READONLY) != 0) return false;
        this.heap.arraySet(handle, u32(index), value);
        return true;
      }
      const atom = this.propertyKey(key);
      if (atom == this.atomLength) {
        if ((this.heap.flagsOf(handle) & FLAG_LENGTH_READONLY) != 0) return false;
        const length = this.arrayLengthFrom(value);
        if (this.pendingThrow) return false;
        this.heap.setArrayLength(handle, length);
        return true;
      }
      const bag = this.arrayBag(handle);
      if ((this.heap.flagsOf(handle) & FLAG_NON_EXTENSIBLE) != 0 && this.heap.objectFindSlot(bag, atom) < 0) return false;
      return this.setOnObject(bag, atom, value, object);
    }
    if (tag == TAG_FUNCTION || tag == TAG_HOST_FUNCTION || tag == TAG_CLOSURE) {
      const atom = this.propertyKey(key);
      const owns = this.functionBagHas(handle, atom);
      // A function with no `prototype` of its own (a bound function, an
      // arrow, a method, most builtins) takes the assignment as an
      // ordinary property; a builtin constructor's is not writable.
      if (atom == this.atomPrototype && !owns && this.functionHasPrototype(object)) {
        if (tag == TAG_HOST_FUNCTION) return false;
        if (!this.isObjectLike(value)) {
          // Any value may be assigned; a non-object one lives in the
          // bag and leaves construction to Object.prototype.
          this.defineOwnAttr(handle, atom, value, PROP_WRITABLE);
          return true;
        }
        if (tag == TAG_CLOSURE) {
          this.heap.setSlot(handle, 1, value);
        } else {
          this.heap.setLink(handle, asCell(value));
        }
        return true;
      }
      if (atom == this.atomLength || atom == this.atomName) {
        if (!owns) return false;
      }
      // Not an own property: what the [[Prototype]] chain holds decides.
      // An inherited setter runs against this function, an inherited
      // read-only property refuses the write.
      if (!owns) {
        const inherited = this.setThroughFunctionChain(handle, atom, value, object);
        if (inherited != SET_NOT_INHERITED) return inherited == SET_DONE;
      }
      const bag = this.ensureFunctionBag(handle);
      if ((this.heap.flagsOf(handle) & FLAG_NON_EXTENSIBLE) != 0 && this.heap.objectFindSlot(bag, atom) < 0) return false;
      return this.setOnObject(bag, atom, value, object);
    }
    return true;
  }

  // Whether a virtual property of a function (`length`, `name`,
  // `prototype`) was deleted: its bag then holds a deleted marker.
  function functionVirtualDeleted(handle: u32, atom: u32): boolean {
    const bag = this.functionBag(handle);
    if (bag == 0) return false;
    const slot = this.heap.objectFindSlot(bag, atom);
    return slot >= 0 && isDeleted(this.heap.slot(bag, u32(slot)));
  }

  // Whether a function-like cell's bag holds `atom` as a live property.
  function functionBagHas(handle: u32, atom: u32): boolean {
    const bag = this.functionBag(handle);
    if (bag == 0) return false;
    const slot = this.heap.objectFindSlot(bag, atom);
    return slot >= 0 && !isDeleted(this.heap.slot(bag, u32(slot)));
  }

  // [[Set]] on an object cell: the chain decides -- a setter runs with
  // `receiver`, a read-only data property rejects, and otherwise the
  // property is created or updated on the object itself.
  function setOnObject(inout this, handle: u32, atom: u32, value: Value, receiver: Value): boolean {
    let current = handle;
    while (current != 0) {
      const slot = this.heap.objectFindSlot(current, atom);
      if (slot >= 0) {
        const held = this.heap.slot(current, u32(slot));
        if (!isDeleted(held)) {
          const attr = this.heap.attrOf(current, u32(slot));
          if ((attr & PROP_ACCESSOR) != 0) {
            const setter = this.heap.slot(asCell(held), 1);
            if (!this.isCallable(setter)) return false;
            this.callValue1(setter, receiver, value);
            return true;
          }
          if ((attr & PROP_WRITABLE) == 0) return false;
          if (current == handle) {
            this.heap.setSlot(handle, u32(slot), value);
            return true;
          }
          break;
        }
      }
      current = this.heap.objectProto(current);
    }
    // Not own: create it, if the object allows new properties.
    const ownSlot = this.heap.objectFindSlot(handle, atom);
    if (ownSlot < 0 || isDeleted(this.heap.slot(handle, u32(ownSlot)))) {
      if ((this.heap.flagsOf(handle) & FLAG_NON_EXTENSIBLE) != 0) return false;
    }
    this.heap.objectDefine(handle, atom, value, PROP_DEFAULT);
    return true;
  }

  // --- Descriptors ---

  function emptyInput(): DescriptorInput {
    return emptyDescriptorInput();
  }

  // [[GetOwnProperty]] for every value: objects (with the global object's
  // bindings and a String wrapper's characters), arrays, strings, and
  // the virtual properties of functions.
  function getOwnDescriptor(inout this, object: Value, key: Value): PropertyDescriptor {
    if (!isCell(object) || asCell(object) == 0) {
      if (this.isStringValue(object)) return this.stringOwnDescriptor(asCell(object), key);
      return absentProperty();
    }
    const handle = asCell(object);
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_OBJECT) {
      const atom = this.propertyKey(key);
      const own = this.ownSlotDescriptor(handle, atom);
      if (own.present) return own;
      if (handle == this.globalObject) {
        const slot = this.findGlobalByAtom(atom);
        if (slot >= 0 && this.globals[usize(slot)].defined) return dataProperty(this.globals[usize(slot)].value, this.globals[usize(slot)].attr);
      }
      const primitive = this.wrappedPrimitive(handle);
      if (!isDeleted(primitive) && this.isStringValue(primitive)) return this.stringOwnDescriptor(asCell(primitive), key);
      return absentProperty();
    }
    if (tag == TAG_ARRAY) {
      const index = this.arrayIndexOf(key);
      if (index >= 0) {
        if (!this.heap.arrayHasIndex(handle, u32(index))) return absentProperty();
        const attr = this.heap.attrOf(handle, u32(index));
        const held = this.heap.arrayGet(handle, u32(index));
        if ((attr & PROP_ACCESSOR) != 0) {
          return PropertyDescriptor({ present: true, value: undefinedValue(), getter: this.heap.slot(asCell(held), 0), setter: this.heap.slot(asCell(held), 1), attr: attr });
        }
        return dataProperty(held, attr);
      }
      const atom = this.propertyKey(key);
      if (atom == this.atomLength) {
        const attr: u8 = (this.heap.flagsOf(handle) & FLAG_LENGTH_READONLY) != 0 ? PROP_NONE : PROP_WRITABLE;
        return dataProperty(int32Value(i32(this.heap.arrayLength(handle))), attr);
      }
      const bag = this.heap.linkOf(handle);
      if (bag == 0) return absentProperty();
      return this.ownSlotDescriptor(bag, atom);
    }
    if (this.heap.isString(handle)) return this.stringOwnDescriptor(handle, key);
    if (tag == TAG_FUNCTION || tag == TAG_HOST_FUNCTION || tag == TAG_CLOSURE) {
      const atom = this.propertyKey(key);
      const bag = this.functionBag(handle);
      if (bag != 0) {
        const own = this.ownSlotDescriptor(bag, atom);
        if (own.present) return own;
      }
      if (this.functionVirtualDeleted(handle, atom)) return absentProperty();
      if (atom == this.atomPrototype) {
        if (!this.functionHasPrototype(object)) return absentProperty();
        const attr: u8 = tag == TAG_HOST_FUNCTION ? PROP_NONE : PROP_WRITABLE;
        return dataProperty(cellValue(this.prototypeOf(handle)), attr);
      }
      if (atom == this.atomLength) {
        if (tag == TAG_HOST_FUNCTION) return dataProperty(this.heap.slot(handle, 1), PROP_CONFIGURABLE);
        const code = this.heap.functionIndex(handle);
        return dataProperty(int32Value(i32(this.functions[usize(code)].expectedArgCount)), PROP_CONFIGURABLE);
      }
      if (atom == this.atomName) {
        if (tag == TAG_HOST_FUNCTION) return dataProperty(this.heap.slot(handle, 2), PROP_CONFIGURABLE);
        return dataProperty(this.functionName(this.heap.functionIndex(handle)), PROP_CONFIGURABLE);
      }
      return absentProperty();
    }
    return absentProperty();
  }

  // A compiled function's name: the declared one, or the empty string.
  function functionName(inout this, code: u32): Value {
    const atom = this.functions[usize(code)].nameAtom;
    if (atom == 0) return this.internLatin1Value(Array<u8>());
    return cellValue(atom);
  }

  function stringOwnDescriptor(inout this, handle: u32, key: Value): PropertyDescriptor {
    const index = this.arrayIndexOf(key);
    if (index >= 0) {
      if (usize(index) >= this.heap.stringLength(handle)) return absentProperty();
      let one = Array<u16>();
      one.push(this.heap.stringUnit(handle, usize(index)));
      return dataProperty(this.internUnitsValue(move one), PROP_ENUMERABLE);
    }
    const atom = this.propertyKey(key);
    if (atom == this.atomLength) return dataProperty(int32Value(i32(this.heap.stringLength(handle))), PROP_NONE);
    return absentProperty();
  }

  // The object cell that holds a value's named properties for definition:
  // the object itself, an array's or function's bag. 0 for none.
  function definitionTarget(inout this, handle: u32, atom: u32): u32 {
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_OBJECT) return handle;
    if (tag == TAG_ARRAY) return this.arrayBag(handle);
    if (tag == TAG_FUNCTION || tag == TAG_HOST_FUNCTION || tag == TAG_CLOSURE) return this.ensureFunctionBag(handle);
    return 0;
  }

  function isExtensible(value: Value): boolean {
    if (!this.isObjectLike(value)) return false;
    return (this.heap.flagsOf(asCell(value)) & FLAG_NON_EXTENSIBLE) == 0;
  }

  function preventExtensions(inout this, value: Value): void {
    if (!this.isObjectLike(value)) return;
    const handle = asCell(value);
    const flags = this.heap.flagsOf(handle);
    this.heap.setFlags(handle, flags | FLAG_NON_EXTENSIBLE);
  }

  // [[DefineOwnProperty]] with the validation of a non-configurable
  // current property. Returns false where the spec rejects.
  function defineOwnProperty(inout this, object: Value, key: Value, desc: DescriptorInput): boolean {
    if (!this.isObjectLike(object)) return false;
    const handle = asCell(object);
    const tag = this.heap.tagOf(handle);
    const atom = this.propertyKey(key);
    const isAccessorInput = desc.hasGetter || desc.hasSetter;
    const current = this.getOwnDescriptor(object, key);
    // An array's length: value and writability only, with RangeError for
    // a value that is not a valid length.
    if (tag == TAG_ARRAY && atom == this.atomLength) {
      if (isAccessorInput) return false;
      let newLength: u32 = 0;
      if (desc.hasValue) {
        newLength = this.arrayLengthFrom(desc.value);
        if (this.pendingThrow) return false;
      }
      const lengthLocked = (this.heap.flagsOf(handle) & FLAG_LENGTH_READONLY) != 0;
      if (desc.hasConfigurable && desc.configurable) return false;
      if (desc.hasEnumerable && desc.enumerable) return false;
      if (lengthLocked && desc.hasWritable && desc.writable) return false;
      if (desc.hasValue) {
        if (lengthLocked && newLength != this.heap.arrayLength(handle)) return false;
        this.heap.setArrayLength(handle, newLength);
      }
      if (desc.hasWritable && !desc.writable) {
        const flags = this.heap.flagsOf(handle);
        this.heap.setFlags(handle, flags | FLAG_LENGTH_READONLY);
      }
      return true;
    }
    if (!this.descriptorCompatible(object, current, desc)) return false;
    const attr = this.mergedAttr(current, desc);
    const currentIsAccessor = current.present && (current.attr & PROP_ACCESSOR) != 0;
    const becomesAccessor = isAccessorInput || (currentIsAccessor && !desc.hasValue && !desc.hasWritable);
    let stored = undefinedValue();
    let storedAttr = attr & (PROP_WRITABLE | PROP_ENUMERABLE | PROP_CONFIGURABLE);
    if (becomesAccessor) {
      let getter = currentIsAccessor ? current.getter : undefinedValue();
      let setter = currentIsAccessor ? current.setter : undefinedValue();
      if (desc.hasGetter) getter = desc.getter;
      if (desc.hasSetter) setter = desc.setter;
      stored = cellValue(this.heap.allocateAccessor(getter, setter));
      storedAttr = (attr & (PROP_ENUMERABLE | PROP_CONFIGURABLE)) | PROP_ACCESSOR;
    } else {
      stored = current.present && !currentIsAccessor ? current.value : undefinedValue();
      if (desc.hasValue) stored = desc.value;
    }
    // Array elements live in the array's slots.
    if (tag == TAG_ARRAY) {
      const index = this.arrayIndexOf(key);
      if (index >= 0) {
        if (!current.present && u32(index) >= this.heap.arrayLength(handle) && (this.heap.flagsOf(handle) & FLAG_LENGTH_READONLY) != 0) return false;
        this.heap.arraySet(handle, u32(index), stored);
        this.heap.setAttr(handle, u32(index), storedAttr);
        return true;
      }
    }
    // A global binding seen through the global object stays a binding.
    if (handle == this.globalObject && this.heap.objectFindSlot(handle, atom) < 0) {
      const slot = this.findGlobalByAtom(atom);
      if (slot >= 0 && this.globals[usize(slot)].defined) {
        if (becomesAccessor) return false;
        this.globals[usize(slot)].value = stored;
        this.globals[usize(slot)].attr = storedAttr;
        return true;
      }
    }
    // A function's prototype / length / name move into its bag once
    // redefined; the bag is consulted first from then on.
    const target = this.definitionTarget(handle, atom);
    if (target == 0) return false;
    this.heap.objectDefine(target, atom, stored, storedAttr);
    return true;
  }

  // ValidateAndApplyPropertyDescriptor's rejections: a non-configurable
  // property cannot become configurable, change enumerability, change
  // kind, or (when read-only) change value or accessors; a missing
  // property needs an extensible object.
  function descriptorCompatible(inout this, object: Value, current: PropertyDescriptor, desc: DescriptorInput): boolean {
    if (!current.present) return this.isExtensible(object);
    if ((current.attr & PROP_CONFIGURABLE) != 0) return true;
    const isAccessorInput = desc.hasGetter || desc.hasSetter;
    if (desc.hasConfigurable && desc.configurable) return false;
    if (desc.hasEnumerable && desc.enumerable != ((current.attr & PROP_ENUMERABLE) != 0)) return false;
    const currentIsAccessor = (current.attr & PROP_ACCESSOR) != 0;
    if (isAccessorInput && !currentIsAccessor) return false;
    if ((desc.hasValue || desc.hasWritable) && currentIsAccessor) return false;
    if (currentIsAccessor) {
      if (desc.hasGetter && !this.sameValue(desc.getter, current.getter)) return false;
      if (desc.hasSetter && !this.sameValue(desc.setter, current.setter)) return false;
      return true;
    }
    if ((current.attr & PROP_WRITABLE) == 0) {
      if (desc.hasWritable && desc.writable) return false;
      if (desc.hasValue && !this.sameValue(desc.value, current.value)) return false;
    }
    return true;
  }

  // The attribute bits after applying `desc` over `current`; absent
  // fields keep the current value, or default to false for a new property.
  function mergedAttr(current: PropertyDescriptor, desc: DescriptorInput): u8 {
    let attr: u8 = current.present ? current.attr & (PROP_WRITABLE | PROP_ENUMERABLE | PROP_CONFIGURABLE) : PROP_NONE;
    if (desc.hasWritable) attr = desc.writable ? attr | PROP_WRITABLE : attr & (PROP_ENUMERABLE | PROP_CONFIGURABLE);
    if (desc.hasEnumerable) attr = desc.enumerable ? attr | PROP_ENUMERABLE : attr & (PROP_WRITABLE | PROP_CONFIGURABLE);
    if (desc.hasConfigurable) attr = desc.configurable ? attr | PROP_CONFIGURABLE : attr & (PROP_WRITABLE | PROP_ENUMERABLE);
    return attr;
  }

  // SameValueZero: strict equality, except NaN equals NaN.
  function sameValueZero(a: Value, b: Value): boolean {
    if (isNumber(a) && isNumber(b)) {
      const x = toNumber(a);
      const y = toNumber(b);
      if (x != x && y != y) return true;
      return x == y;
    }
    return this.strictEquals(a, b);
  }

  // A hash consistent with SameValueZero: numbers by value (both zeros
  // and every NaN alike), strings by content, everything else by bits.
  function hashValue(value: Value): u32 {
    if (isNumber(value)) {
      let number = toNumber(value);
      if (number != number) return 0x7FF80000;
      if (number == 0.0) number = 0.0;
      const bits = number.toBits();
      const mixed = (bits ^ (bits >> 32)).wrappingMultiply(0x9E3779B1);
      return u32(mixed & 0xFFFFFFFF);
    }
    if (this.isStringValue(value)) {
      return this.hashStorage(asCell(value));
    }
    const mixed = (value.bits ^ (value.bits >> 29)).wrappingMultiply(0x9E3779B1);
    return u32(mixed & 0xFFFFFFFF);
  }

  // SameValue: strict equality, except NaN equals NaN and +0 differs from -0.
  function sameValue(a: Value, b: Value): boolean {
    if (isNumber(a) && isNumber(b)) {
      const x = toNumber(a);
      const y = toNumber(b);
      if (x != x && y != y) return true;
      if (x == 0.0 && y == 0.0) return (1.0 / x < 0.0) == (1.0 / y < 0.0);
      return x == y;
    }
    return this.strictEquals(a, b);
  }

  // Define an accessor from an object literal: `get x() {}` / `set x(v) {}`,
  // merging with an accessor already there.
  function defineAccessor(inout this, object: Value, key: Value, getter: Value, setter: Value, isGetter: boolean): void {
    this.defineAccessorAttr(object, key, getter, setter, isGetter, PROP_ENUMERABLE | PROP_CONFIGURABLE | PROP_ACCESSOR);
  }

  function defineAccessorAttr(inout this, object: Value, key: Value, getter: Value, setter: Value, isGetter: boolean, attr: u8): void {
    if (!this.isObjectLike(object)) return;
    const handle = asCell(object);
    const atom = this.propertyKey(key);
    const target = this.definitionTarget(handle, atom);
    if (target == 0) return;
    const current = this.ownSlotDescriptor(target, atom);
    let currentGetter = undefinedValue();
    let currentSetter = undefinedValue();
    if (current.present && (current.attr & PROP_ACCESSOR) != 0) {
      currentGetter = current.getter;
      currentSetter = current.setter;
    }
    const accessor = this.heap.allocateAccessor(isGetter ? getter : currentGetter, isGetter ? currentSetter : setter);
    this.heap.objectDefine(target, atom, cellValue(accessor), attr);
  }

  // Own property keys in the specification's order: array indices
  // ascending, then strings in insertion order; every own key, enumerable
  // or not. Hidden keys never appear.
  function ownKeys(inout this, object: Value): Array<Value> {
    let keys = Array<Value>();
    if (!isCell(object) || asCell(object) == 0) {
      if (this.isStringValue(object)) this.pushStringKeys(inout keys, asCell(object));
      return keys;
    }
    const handle = asCell(object);
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_ARRAY) {
      const length = this.heap.arrayLength(handle);
      let index: u32 = 0;
      while (index < length) {
        if (this.heap.arrayHasIndex(handle, index)) keys.push(this.toStringValue(int32Value(i32(index))));
        index = index + 1;
      }
      keys.push(cellValue(this.atomLength));
      const bag = this.heap.linkOf(handle);
      if (bag != 0) this.pushObjectKeys(inout keys, bag, true);
      return keys;
    }
    if (tag == TAG_OBJECT) {
      const primitive = this.wrappedPrimitive(handle);
      if (!isDeleted(primitive) && this.isStringValue(primitive)) this.pushStringKeys(inout keys, asCell(primitive));
      this.pushObjectKeys(inout keys, handle, false);
      if (handle == this.globalObject) {
        let g: usize = 0;
        while (g < this.globals.length) {
          if (this.globals[g].defined && this.heap.objectFindSlot(handle, this.globals[g].atom) < 0) keys.push(cellValue(this.globals[g].atom));
          g = g + 1;
        }
      }
      return keys;
    }
    if (this.heap.isString(handle)) {
      this.pushStringKeys(inout keys, handle);
      return keys;
    }
    if (tag == TAG_FUNCTION || tag == TAG_HOST_FUNCTION || tag == TAG_CLOSURE) {
      const bag = this.functionBag(handle);
      if (!this.functionBagHas(handle, this.atomLength) && !this.functionVirtualDeleted(handle, this.atomLength)) keys.push(cellValue(this.atomLength));
      if (!this.functionBagHas(handle, this.atomName) && !this.functionVirtualDeleted(handle, this.atomName)) keys.push(cellValue(this.atomName));
      if (this.functionHasPrototype(object) && !this.functionBagHas(handle, this.atomPrototype)) keys.push(cellValue(this.atomPrototype));
      if (bag != 0) this.pushObjectKeys(inout keys, bag, false);
      return keys;
    }
    return keys;
  }

  function pushStringKeys(inout this, inout keys: Array<Value>, handle: u32): void {
    const length = this.heap.stringLength(handle);
    let index: u32 = 0;
    while (usize(index) < length) {
      keys.push(this.toStringValue(int32Value(i32(index))));
      index = index + 1;
    }
    keys.push(cellValue(this.atomLength));
  }

  // An object cell's own live keys: index-like names ascending first,
  // then the rest in insertion order.
  function pushObjectKeys(inout this, inout keys: Array<Value>, object: u32, skipIndices: boolean): void {
    const names = this.ownNames(object);
    let indices = Array<u32>();
    let i: usize = 0;
    while (i < names.length) {
      const name = names[i];
      if (name != 0) {
        const slot = this.heap.objectFindSlot(object, name);
        if (slot >= 0 && !isDeleted(this.heap.slot(object, u32(slot)))) {
          const index = this.arrayIndexOf(cellValue(name));
          if (index >= 0) {
            if (!skipIndices) indices.push(u32(index));
          }
        }
      }
      i = i + 1;
    }
    // Insertion sort: index keys are few.
    let sorted: usize = 1;
    while (sorted < indices.length) {
      let position = sorted;
      while (position > 0 && indices[position - 1] > indices[position]) {
        const swapped = indices[position - 1];
        indices[position - 1] = indices[position];
        indices[position] = swapped;
        position = position - 1;
      }
      sorted = sorted + 1;
    }
    i = 0;
    while (i < indices.length) {
      keys.push(this.toStringValue(int32Value(i32(indices[i]))));
      i = i + 1;
    }
    i = 0;
    while (i < names.length) {
      const name = names[i];
      if (name != 0) {
        const slot = this.heap.objectFindSlot(object, name);
        if (slot >= 0 && !isDeleted(this.heap.slot(object, u32(slot))) && this.arrayIndexOf(cellValue(name)) < 0) keys.push(cellValue(name));
      }
      i = i + 1;
    }
    // Symbol keys last, in insertion order.
    const allNames = this.heap.objectNames(object);
    i = 0;
    while (i < allNames.length) {
      const name = allNames[i];
      if (name != 0 && this.isSymbolKeyAtom(name) && !this.isPrivateKeyAtom(name)) {
        const slot = this.heap.objectFindSlot(object, name);
        if (slot >= 0 && !isDeleted(this.heap.slot(object, u32(slot)))) keys.push(this.symbolOfKeyAtom(name));
      }
      i = i + 1;
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
        // A hole reads through the prototype chain, where an element may
        // be an accessor without a getter: presence, not value.
        const arrayProto = this.arrayProto;
        return this.hasProperty(cellValue(arrayProto), key);
      }
      const atom = this.propertyKey(key);
      if (atom == this.atomLength) return true;
      const bag = this.heap.linkOf(handle);
      if (bag != 0 && this.heap.objectFindSlot(bag, atom) >= 0 && !isDeleted(this.heap.slot(bag, u32(this.heap.objectFindSlot(bag, atom))))) return true;
      const arrayProto = this.arrayProto;
      return this.hasProperty(cellValue(arrayProto), key);
    }
    if (tag == TAG_OBJECT) {
      // A String wrapper has its characters and length.
      const primitive = this.wrappedPrimitive(handle);
      if (!isDeleted(primitive) && this.isStringValue(primitive)) {
        const own = this.stringOwnDescriptor(asCell(primitive), key);
        if (own.present) return true;
      }
      const atom = this.propertyKey(key);
      let current = handle;
      while (current != 0) {
        const slot = this.heap.objectFindSlot(current, atom);
        if (slot >= 0 && !isDeleted(this.heap.slot(current, u32(slot)))) return true;
        current = this.heap.objectProto(current);
      }
      return false;
    }
    // Functions: `prototype` (constructors only), `length`, `name`, own
    // named properties, then Function.prototype.
    const atom = this.propertyKey(key);
    if (this.functionBagHas(handle, atom)) return true;
    if (atom == this.atomPrototype && !this.functionVirtualDeleted(handle, atom)) return this.functionHasPrototype(object);
    if ((atom == this.atomLength || atom == this.atomName) && !this.functionVirtualDeleted(handle, atom)) return true;
    const bag = this.functionBag(handle);
    if (bag != 0 && this.heap.objectFindSlot(bag, atom) >= 0) return true;
    const functionProto = this.functionProtoOf(handle);
    if (functionProto == 0) return false;
    return this.hasProperty(cellValue(functionProto), key);
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
      if (this.functionBagHas(handle, atom)) return true;
      if (this.functionVirtualDeleted(handle, atom)) return false;
      if (atom == this.atomPrototype) return this.functionHasPrototype(object);
      return atom == this.atomLength || atom == this.atomName;
    }
    return false;
  }

  // OrdinaryHasInstance. A bound function answers with its target's
  // whole instanceof behaviour, a custom @@hasInstance included; any
  // other callable reads its `prototype` (the program's to observe),
  // which must be an object, and looks for it on the value's chain. A
  // throw is left pending.
  function ordinaryHasInstance(inout this, ctor: Value, value: Value): boolean {
    if (!this.isCallable(ctor)) return false;
    if (this.isBoundFunction(ctor)) return this.instanceofValue(value, this.boundTargetOf(ctor));
    if (!this.isObjectLike(value)) return false;
    const atomPrototype = this.atomPrototype;
    const held = this.getProperty(ctor, cellValue(atomPrototype));
    if (this.pendingThrow) return false;
    if (!this.isObjectLike(held)) {
      const message: String = "Function has non-object prototype in instanceof check";
      const error = this.typeError(in message);
      this.raise(error);
      return false;
    }
    const target = asCell(held);
    let current = this.protoOfValue(value);
    while (current != 0) {
      if (current == target) return true;
      current = this.protoOfValue(cellValue(current));
    }
    return false;
  }

  // InstanceofOperator(value, target): the target's @@hasInstance method
  // decides when there is one, else OrdinaryHasInstance. A throw is left
  // pending.
  function instanceofValue(inout this, value: Value, target: Value): boolean {
    const hasInstanceKey = this.symbolHasInstance;
    const handler = this.isObjectLike(target) ? this.getProperty(target, hasInstanceKey) : undefinedValue();
    if (this.pendingThrow) return false;
    // The lookup above is the program's to observe; calling the builtin
    // it usually finds is not, so its work is done here directly.
    if (isCell(handler) && asCell(handler) == this.hasInstanceBuiltin && this.hasInstanceBuiltin != 0) return this.ordinaryHasInstance(target, value);
    if (!isUndefined(handler) && !isNull(handler)) {
      const verdict = this.callValue1(handler, target, value);
      if (this.pendingThrow) return false;
      return this.toBooleanValue(verdict);
    }
    if (!this.isCallable(target)) {
      const message: String = "Right-hand side of 'instanceof' is not callable";
      const error = this.typeError(in message);
      this.raise(error);
      return false;
    }
    return this.ordinaryHasInstance(target, value);
  }

  // OrdinarySetPrototypeOf for the values whose [[Prototype]] the engine
  // can change: plain objects and function objects. `proto` is an object
  // or null. False when the target is not extensible or the change would
  // close a cycle. Other exotic values keep the prototype they have and
  // report success, as before.
  function setPrototypeOfValue(inout this, target: Value, proto: Value): boolean {
    const handle = asCell(target);
    const wanted: u32 = isNull(proto) ? 0 : asCell(proto);
    if (this.protoOfValue(target) == wanted) return true;
    const tag = this.heap.tagOf(handle);
    const isFunction = tag == TAG_FUNCTION || tag == TAG_HOST_FUNCTION || tag == TAG_CLOSURE;
    if (tag != TAG_OBJECT && !isFunction) return true;
    if (!this.isExtensible(target)) return false;
    let current = wanted;
    while (current != 0) {
      if (current == handle) return false;
      current = this.protoOfValue(cellValue(current));
    }
    if (tag == TAG_OBJECT) {
      this.heap.setObjectProto(handle, wanted);
    } else {
      const atomFunctionProto = this.atomFunctionProto;
      this.setFunctionHidden(handle, atomFunctionProto, proto);
    }
    return true;
  }

  // The prototype a value inherits from, for instanceof: 0 for none.
  function protoOfValue(value: Value): u32 {
    if (!isCell(value) || asCell(value) == 0) return 0;
    const handle = asCell(value);
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_OBJECT) return this.heap.objectProto(handle);
    if (tag == TAG_ARRAY) return this.arrayProto;
    if (tag == TAG_FUNCTION || tag == TAG_HOST_FUNCTION || tag == TAG_CLOSURE) return this.functionProtoOf(handle);
    if (this.heap.isString(handle)) return this.stringProto;
    return 0;
  }

  // Remove an own property: the heap drops it from the object's class
  // or dictionary (a virtual property of a function leaves a tombstone
  // in its bag instead); arrays leave a hole.
  function deleteProperty(inout this, object: Value, key: Value): boolean {
    if (!isCell(object) || asCell(object) == 0) return true;
    const handle = asCell(object);
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_OBJECT) {
      const atom = this.propertyKey(key);
      // A global binding seen through the global object: deleting it
      // undefines the binding.
      if (handle == this.globalObject && this.heap.objectFindSlot(handle, atom) < 0) {
        const slot = this.findGlobalByAtom(atom);
        if (slot >= 0 && this.globals[usize(slot)].defined) {
          if ((this.globals[usize(slot)].attr & PROP_CONFIGURABLE) == 0) return false;
          this.globals[usize(slot)].defined = false;
          this.globals[usize(slot)].value = undefinedValue();
          return true;
        }
      }
      return this.deleteFromObject(handle, atom);
    }
    if (tag == TAG_ARRAY) {
      const index = this.arrayIndexOf(key);
      if (index >= 0) {
        if (this.heap.arrayHasIndex(handle, u32(index))) {
          if ((this.heap.attrOf(handle, u32(index)) & PROP_CONFIGURABLE) == 0) return false;
          this.heap.setSlot(handle, u32(index), deletedValue());
        }
        return true;
      }
      const atom = this.propertyKey(key);
      if (atom == this.atomLength) return false;
      const bag = this.heap.linkOf(handle);
      if (bag != 0) return this.deleteFromObject(bag, atom);
      return true;
    }
    if (tag == TAG_FUNCTION || tag == TAG_HOST_FUNCTION || tag == TAG_CLOSURE) {
      const atom = this.propertyKey(key);
      if (this.functionBagHas(handle, atom)) {
        const bag = this.functionBag(handle);
        const removed = this.deleteFromObject(bag, atom);
        // A redefined `length` or `name`, once gone, must not uncover the
        // virtual one: the tombstone records the deletion.
        if (removed && (atom == this.atomLength || atom == this.atomName)) this.heap.objectDefine(bag, atom, deletedValue(), PROP_CONFIGURABLE);
        return removed;
      }
      if (atom == this.atomPrototype) return !this.isConstructorValue(object);
      if (atom == this.atomLength || atom == this.atomName) {
        // Configurable: deleting leaves a tombstone in the bag.
        const bag = this.ensureFunctionBag(handle);
        this.heap.objectDefine(bag, atom, deletedValue(), PROP_CONFIGURABLE);
        return true;
      }
      return true;
    }
    return true;
  }

  function deleteFromObject(inout this, handle: u32, atom: u32): boolean {
    const slot = this.heap.objectFindSlot(handle, atom);
    if (slot < 0) return true;
    if ((this.heap.attrOf(handle, u32(slot)) & PROP_CONFIGURABLE) == 0) return false;
    this.heap.objectDelete(handle, atom, u32(slot));
    return true;
  }

  // Whether an array cell was built as a function's arguments object.
  function isArgumentsObject(handle: u32): boolean {
    if (!this.heap.isArray(handle)) return false;
    const bag = this.heap.linkOf(handle);
    if (bag == 0) return false;
    return this.heap.objectFindSlot(bag, this.atomArgumentsMarker) >= 0;
  }

  // Whether an atom is one of the engine's hidden keys.
  function isHiddenAtom(atom: u32): boolean {
    return (this.heap.flagsOf(atom) & FLAG_HIDDEN) != 0;
  }

  function isSymbolValue(value: Value): boolean {
    return isCell(value) && asCell(value) != 0 && this.heap.isSymbol(asCell(value));
  }

  // A new symbol with a fresh key atom, 0xFF 's' and a counter, the atom
  // linked back to the symbol.
  function newSymbol(inout this, description: Value): Value {
    const symbol = this.heap.allocateSymbol(description);
    this.symbolCounter = this.symbolCounter + 1;
    const number = this.symbolCounter;
    let bytes = Array<u8>();
    bytes.push(255);
    bytes.push(115);
    bytes.push(u8((number >> 24) & 255));
    bytes.push(u8((number >> 16) & 255));
    bytes.push(u8((number >> 8) & 255));
    bytes.push(u8(number & 255));
    const atom = this.hiddenAtomBytes(move bytes);
    this.heap.setSlot(symbol, 1, cellValue(atom));
    this.heap.setLink(atom, symbol);
    return cellValue(symbol);
  }

  // Whether a hidden atom stands for a symbol, and which.
  function isSymbolKeyAtom(atom: u32): boolean {
    return this.heap.stringLength(atom) == 6 && this.heap.stringUnit(atom, 0) == 255 && this.heap.stringUnit(atom, 1) == 115;
  }

  function symbolOfKeyAtom(atom: u32): Value {
    return cellValue(this.heap.linkOf(atom));
  }

  // "Symbol(description)"
  function symbolDescriptiveString(inout this, symbol: u32): Value {
    const head: String = "Symbol(";
    let text = bytesOf(in head);
    const description = this.heap.symbolDescription(symbol);
    if (this.isStringValue(description)) appendBytes(inout text, this.heap.stringUtf8(asCell(description)));
    text.push(41);
    return this.newStringUtf8(move text);
  }

  function symbolTypeError(inout this, in what: String): Value {
    const head: String = "Cannot convert a Symbol value to a ";
    let message = bytesOf(in head);
    appendBytes(inout message, bytesOf(in what));
    return this.makeError(ERROR_KIND_TYPE, move message);
  }

  // The names an object holds, in insertion order, hidden keys left out
  // (as 0).
  function ownNames(handle: u32): Array<u32> {
    let names = this.heap.objectNames(handle);
    let i: usize = 0;
    while (i < names.length) {
      if (names[i] != 0 && this.isHiddenAtom(names[i])) names[i] = 0;
      i = i + 1;
    }
    return names;
  }

  // The keys for-in visits, as an array of strings: array indices then
  // named properties; an object's own names in insertion order, then its
  // prototypes' (stopping short of Object.prototype), each name once.
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
    if (tag == TAG_FUNCTION || tag == TAG_HOST_FUNCTION || tag == TAG_CLOSURE) {
      // A function's own enumerable properties live in its bag; its
      // builtin ones and Function.prototype's are all non-enumerable.
      const bag = this.functionBag(handle);
      if (bag != 0) this.appendObjectKeys(keys, bag, false);
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
            const live = slot >= 0 && !isDeleted(this.heap.slot(current, u32(slot)));
            if (live && (this.heap.attrOf(current, u32(slot)) & PROP_ENUMERABLE) != 0) {
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
      const live = slot >= 0 && !isDeleted(this.heap.slot(object, u32(slot))) && (this.heap.attrOf(object, u32(slot)) & PROP_ENUMERABLE) != 0;
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
    } else if (this.isSymbolValue(value)) {
      label = "symbol";
    } else if (this.isCallable(value)) {
      label = "function";
    }
    return this.internText(in label);
  }

  // --- Iteration ---

  // { value, done }
  // What a suspended or finished body hands whoever resumed it. A
  // generator's resumer is the program, which gets an iterator result.
  // An async body's is always the engine's own driver, so it takes the
  // value as it is, with `resumeDone` beside it: no object is made only
  // to be taken apart again.
  function resumeResult(inout this, isAsync: boolean, value: Value, done: boolean): Value {
    if (isAsync) {
      this.resumeDone = done;
      return value;
    }
    return this.createIterResult(value, done);
  }

  function createIterResult(inout this, value: Value, done: boolean): Value {
    const objectProto = this.objectProto;
    const result = this.heap.allocateObject(objectProto);
    const valueAtom = this.atomValue;
    this.heap.objectSet(result, valueAtom, value);
    const doneAtom = this.atomDone;
    this.heap.objectSet(result, doneAtom, booleanValue(done));
    return cellValue(result);
  }

  // An array iterator over `source` (an array, a string, or any
  // array-like), yielding values (0), keys (1), or entries (2).
  function createArrayIterator(inout this, source: Value, kind: u32): Value {
    const arrayIteratorProto = this.arrayIteratorProto;
    const iterator = this.heap.allocateObject(arrayIteratorProto);
    const atomIterSource = this.atomIterSource;
    this.heap.objectDefine(iterator, atomIterSource, source, PROP_WRITABLE);
    const atomIterIndex = this.atomIterIndex;
    this.heap.objectDefine(iterator, atomIterIndex, int32Value(0), PROP_WRITABLE);
    const atomIterKind = this.atomIterKind;
    this.heap.objectDefine(iterator, atomIterKind, int32Value(i32(kind)), PROP_WRITABLE);
    return cellValue(iterator);
  }

  // One step of an array iterator: the next value, or the deleted
  // marker once the source is exhausted (which also drops the source).
  function arrayIteratorStep(inout this, iterator: u32): Value {
    const sourceSlot = this.heap.objectFindSlot(iterator, this.atomIterSource);
    const source = this.heap.slot(iterator, u32(sourceSlot));
    if (isUndefined(source)) return deletedValue();
    const indexSlot = this.heap.objectFindSlot(iterator, this.atomIterIndex);
    const index = u32(asInt32(this.heap.slot(iterator, u32(indexSlot))));
    const kindSlot = this.heap.objectFindSlot(iterator, this.atomIterKind);
    const kind = u32(asInt32(this.heap.slot(iterator, u32(kindSlot))));
    let length: u32 = 0;
    if (isCell(source) && asCell(source) != 0 && this.heap.isArray(asCell(source))) {
      length = this.heap.arrayLength(asCell(source));
    } else if (this.isStringValue(source)) {
      length = u32(this.heap.stringLength(asCell(source)));
    } else {
      const lengthKey = cellValue(this.atomLength);
      const lengthValue = this.getProperty(source, lengthKey);
      if (this.pendingThrow) return deletedValue();
      length = this.toLength(lengthValue);
      if (this.pendingThrow) return deletedValue();
    }
    if (index >= length) {
      this.heap.setSlot(iterator, u32(sourceSlot), undefinedValue());
      return deletedValue();
    }
    // A string iterates by code point: a surrogate pair is one element.
    if (kind == 0 && this.isStringValue(source)) {
      const handle = asCell(source);
      const unit = this.heap.stringUnit(handle, usize(index));
      let step: u32 = 1;
      if (unit >= 0xD800 && unit <= 0xDBFF && index + 1 < length) {
        const next = this.heap.stringUnit(handle, usize(index + 1));
        if (next >= 0xDC00 && next <= 0xDFFF) step = 2;
      }
      this.heap.setSlot(iterator, u32(indexSlot), int32Value(i32(index + step)));
      return this.newStringUnits(this.heap.stringUnitsSlice(handle, usize(index), usize(index + step)));
    }
    this.heap.setSlot(iterator, u32(indexSlot), int32Value(i32(index + 1)));
    if (kind == 1) return int32Value(i32(index));
    const element = this.getProperty(source, int32Value(i32(index)));
    if (this.pendingThrow) return deletedValue();
    if (kind == 0) return element;
    const pair = this.heap.allocateArray(2);
    this.heap.setSlot(pair, 0, int32Value(i32(index)));
    this.heap.setSlot(pair, 1, element);
    return cellValue(pair);
  }

  // Whether an iterator is a pristine array iterator: its own state, and
  // `next` still the builtin, found through its prototype.
  function isPristineArrayIterator(inout this, iterator: Value): boolean {
    if (!isCell(iterator) || asCell(iterator) == 0 || !this.heap.isObject(asCell(iterator))) return false;
    const handle = asCell(iterator);
    if (this.heap.objectFindSlot(handle, this.atomIterSource) < 0) return false;
    const nextAtom = this.atomNext;
    if (this.heap.objectFindSlot(handle, nextAtom) >= 0) return false;
    const arrayIteratorProto = this.arrayIteratorProto;
    if (this.heap.objectProto(handle) != arrayIteratorProto) return false;
    const slot = this.heap.objectFindSlot(arrayIteratorProto, nextAtom);
    if (slot < 0) return false;
    const held = this.heap.slot(arrayIteratorProto, u32(slot));
    return isCell(held) && asCell(held) == this.arrayIteratorNext;
  }

  // GetIterator: the value's @@iterator method, called; its result must
  // be an object. A throw is left pending.
  function getIterator(inout this, value: Value): Value {
    const symbolIterator = this.symbolIterator;
    let method = undefinedValue();
    if (!isUndefined(value) && !isNull(value)) method = this.getProperty(value, symbolIterator);
    if (this.pendingThrow) return undefinedValue();
    if (!this.isCallable(method)) {
      const message: String = "value is not iterable";
      const error = this.typeError(in message);
      this.raise(error);
      return undefinedValue();
    }
    const iterator = this.callValue0(method, value);
    if (this.pendingThrow) return undefinedValue();
    if (!this.isObjectLike(iterator)) {
      const message: String = "Result of the Symbol.iterator method is not an object";
      const error = this.typeError(in message);
      this.raise(error);
      return undefinedValue();
    }
    return iterator;
  }

  // GetIterator(value, async): the @@asyncIterator method, else the sync
  // iterator wrapped so its results arrive through promises.
  function getAsyncIterator(inout this, value: Value): Value {
    const symbolAsyncIterator = this.symbolAsyncIterator;
    let method = undefinedValue();
    if (!isUndefined(value) && !isNull(value)) method = this.getProperty(value, symbolAsyncIterator);
    if (this.pendingThrow) return undefinedValue();
    if (isUndefined(method) || isNull(method)) {
      const sync = this.getIterator(value);
      if (this.pendingThrow) return undefinedValue();
      this.pushTempRoot(sync);
      const asyncFromSyncProto = this.asyncFromSyncProto;
      const wrapper = this.heap.allocateObject(asyncFromSyncProto);
      const atomSyncIterator = this.atomSyncIterator;
      this.heap.objectDefine(wrapper, atomSyncIterator, sync, PROP_NONE);
      this.popTempRoot();
      return cellValue(wrapper);
    }
    if (!this.isCallable(method)) {
      const message: String = "value is not async iterable";
      const error = this.typeError(in message);
      this.raise(error);
      return undefinedValue();
    }
    const iterator = this.callValue0(method, value);
    if (this.pendingThrow) return undefinedValue();
    if (!this.isObjectLike(iterator)) {
      const message: String = "Result of the Symbol.asyncIterator method is not an object";
      const error = this.typeError(in message);
      this.raise(error);
      return undefinedValue();
    }
    return iterator;
  }

  // The sync iterator inside an async-from-sync wrapper, or undefined.
  function wrappedSyncIterator(value: Value): Value {
    if (!isCell(value) || asCell(value) == 0 || !this.heap.isObject(asCell(value))) return undefinedValue();
    const slot = this.heap.objectFindSlot(asCell(value), this.atomSyncIterator);
    if (slot < 0) return undefinedValue();
    return this.heap.slot(asCell(value), u32(slot));
  }

  // IteratorStep: the next value, or the deleted marker when done. A
  // throw is left pending (and reads as done).
  function iteratorStep(inout this, iterator: Value): Value {
    if (this.isPristineArrayIterator(iterator)) return this.arrayIteratorStep(asCell(iterator));
    const nextKey = cellValue(this.atomNext);
    const next = this.getProperty(iterator, nextKey);
    if (this.pendingThrow) return deletedValue();
    if (!this.isCallable(next)) {
      const message: String = "iterator.next is not a function";
      const error = this.typeError(in message);
      this.raise(error);
      return deletedValue();
    }
    const result = this.callValue0(next, iterator);
    if (this.pendingThrow) return deletedValue();
    if (!this.isObjectLike(result)) {
      const message: String = "Iterator result is not an object";
      const error = this.typeError(in message);
      this.raise(error);
      return deletedValue();
    }
    const doneKey = cellValue(this.atomDone);
    const done = this.getProperty(result, doneKey);
    if (this.pendingThrow) return deletedValue();
    if (this.toBooleanValue(done)) return deletedValue();
    const valueKey = cellValue(this.atomValue);
    const value = this.getProperty(result, valueKey);
    if (this.pendingThrow) return deletedValue();
    return value;
  }

  // IteratorClose: the iterator's `return`, if any; its result must be an
  // object.
  // iterator.<method>(value) for a delegating yield*: the result object,
  // or the deleted marker when the method is absent (`absent` set) or
  // the call threw (pending).
  // The key of an iterator method by its name: the three the engine
  // calls are atoms already.
  function iteratorMethodKey(inout this, in name: String): Value {
    if (name.byteLength == 4 && name.byteAt(0) == 110) return cellValue(this.atomNext);
    if (name.byteLength == 5 && name.byteAt(0) == 116) return cellValue(this.atomThrow);
    if (name.byteLength == 6 && name.byteAt(0) == 114) return cellValue(this.atomReturn);
    return this.internText(in name);
  }

  function iteratorCallWith(inout this, iterator: Value, in name: String, value: Value, inout absent: boolean): Value {
    absent = false;
    const key = this.iteratorMethodKey(in name);
    const method = this.getProperty(iterator, key);
    if (this.pendingThrow) return deletedValue();
    if (isUndefined(method) || isNull(method)) {
      absent = true;
      return deletedValue();
    }
    if (!this.isCallable(method)) {
      const message: String = `iterator.${name} is not a function`;
      const error = this.typeError(in message);
      this.raise(error);
      return deletedValue();
    }
    const result = this.callValue1(method, iterator, value);
    if (this.pendingThrow) return deletedValue();
    if (!this.isObjectLike(result)) {
      const message: String = "Iterator result is not an object";
      const error = this.typeError(in message);
      this.raise(error);
      return deletedValue();
    }
    return result;
  }

  // iterator.<method>(value) as returned, for an async delegation that
  // awaits and checks the result itself: `absent` when there is no such
  // method (next must exist), the deleted marker on a throw (pending).
  function iteratorCallRaw(inout this, iterator: Value, in name: String, value: Value, mustExist: boolean, inout absent: boolean): Value {
    absent = false;
    const key = this.iteratorMethodKey(in name);
    const method = this.getProperty(iterator, key);
    if (this.pendingThrow) return deletedValue();
    if (isUndefined(method) || isNull(method)) {
      if (!mustExist) {
        absent = true;
        return deletedValue();
      }
      const missing: String = `iterator.${name} is not a function`;
      const error = this.typeError(in missing);
      this.raise(error);
      return deletedValue();
    }
    if (!this.isCallable(method)) {
      const message: String = `iterator.${name} is not a function`;
      const error = this.typeError(in message);
      this.raise(error);
      return deletedValue();
    }
    const result = this.callValue1(method, iterator, value);
    if (this.pendingThrow) return deletedValue();
    return result;
  }

  function iteratorClose(inout this, iterator: Value): void {
    if (!this.isObjectLike(iterator)) return;
    if (this.isPristineArrayIterator(iterator)) return;
    const returnKey = cellValue(this.atomReturn);
    const method = this.getProperty(iterator, returnKey);
    if (this.pendingThrow) return;
    if (isUndefined(method) || isNull(method)) return;
    if (!this.isCallable(method)) {
      const message: String = "iterator.return is not a function";
      const error = this.typeError(in message);
      this.raise(error);
      return;
    }
    const result = this.callValue0(method, iterator);
    if (this.pendingThrow) return;
    if (!this.isObjectLike(result)) {
      const message: String = "iterator.return result is not an object";
      const error = this.typeError(in message);
      this.raise(error);
    }
  }

  // CopyDataProperties: every own enumerable property of `source`,
  // string or symbol keyed, onto `target`, except the keys in `excluded`
  // (an array of key values, or 0). Null and undefined sources copy nothing.
  function copyDataProperties(inout this, target: u32, source: Value, excluded: u32): void {
    if (isUndefined(source) || isNull(source)) return;
    const keys = this.ownKeys(source);
    let index: usize = 0;
    while (index < keys.length) {
      const key = keys[index];
      let skip = false;
      if (excluded != 0) {
        const count = this.heap.arrayLength(excluded);
        let e: u32 = 0;
        while (e < count) {
          const candidate = this.heap.arrayGet(excluded, e);
          if (this.propertyKey(candidate) == this.propertyKey(key)) skip = true;
          e = e + 1;
        }
      }
      if (!skip) {
        const desc = this.getOwnDescriptor(source, key);
        if (desc.present && (desc.attr & PROP_ENUMERABLE) != 0) {
          const value = this.getProperty(source, key);
          if (this.pendingThrow) return;
          const atom = this.propertyKey(key);
          this.heap.objectDefine(target, atom, value, PROP_DEFAULT);
        }
      }
      index = index + 1;
    }
  }

  // Every value an iterable yields, as an array. A throw is left pending.
  function iterateToArray(inout this, iterable: Value): Value {
    const array = this.heap.allocateArray(0);
    this.pushTempRoot(cellValue(array));
    const iterator = this.getIterator(iterable);
    if (this.pendingThrow) {
      this.popTempRoot();
      return undefinedValue();
    }
    this.pushTempRoot(iterator);
    while (true) {
      const next = this.iteratorStep(iterator);
      if (this.pendingThrow || isDeleted(next)) break;
      const count = this.heap.arrayLength(array);
      this.heap.arraySet(array, count, next);
    }
    this.popTempRoot();
    this.popTempRoot();
    if (this.pendingThrow) return undefinedValue();
    return cellValue(array);
  }

  // Place an array's elements on the register stack for a spread call and
  // return where they start; the caller restores regTop afterwards.
  function spreadArguments(inout this, array: u32): u32 {
    const argsBase = this.regTop;
    const argc = this.heap.arrayLength(array);
    const needed = usize(argsBase + argc);
    while (this.regStack.length < needed) { this.regStack.push(undefinedValue()); }
    let index: u32 = 0;
    while (index < argc) {
      const element = this.heap.arrayGet(array, index);
      this.regStack[usize(argsBase + index)] = element;
      index = index + 1;
    }
    this.regTop = argsBase + argc;
    return argsBase;
  }

  // --- Generators ---
  //
  // A generator object is an ordinary object holding a record under a
  // hidden key: state, the function value, this, the original arguments,
  // the saved registers, the resume point, the register that receives
  // what next() sends, the saved try handlers, and the environment.
  // Suspending copies the frame's register window out; resuming pushes a
  // fresh frame and copies it back.

  function isGeneratorObject(value: Value): boolean {
    if (!isCell(value) || asCell(value) == 0 || !this.heap.isObject(asCell(value))) return false;
    return this.heap.objectFindSlot(asCell(value), this.atomGenRecord) >= 0;
  }

  function generatorRecord(gen: u32): u32 {
    const slot = this.heap.objectFindSlot(gen, this.atomGenRecord);
    return asCell(this.heap.slot(gen, u32(slot)));
  }

  // A generator object for a call of a generator function. The call runs
  // the parameter prologue at once; GeneratorStart suspends the frame and
  // returns this object, and the first next() resumes after it.
  function createGenerator(inout this, callee: Value, thisValue: Value): Value {
    const proto = this.prototypeOf(asCell(callee));
    const gen = this.heap.allocateObject(proto);
    // [state, callee, this, promise, saved regs, ip, resume dst, saved
    // tries, env, suspension kind, request queue, queue cursor, resume
    // mode]; the queue exists for async generators only. Suspension kind
    // 3 is a delegating yield (yield*), which every resumption -- next,
    // throw, return -- re-enters with its mode for the delegation loop.
    const record = this.heap.allocateArray(13);
    this.heap.setSlot(record, 0, int32Value(GEN_START));
    this.heap.setSlot(record, 1, callee);
    this.heap.setSlot(record, 2, thisValue);
    this.heap.setSlot(record, 3, undefinedValue());
    this.heap.setSlot(record, 5, int32Value(0));
    this.heap.setSlot(record, 6, int32Value(0));
    this.heap.setSlot(record, 8, int32Value(0));
    this.heap.setSlot(record, 9, int32Value(0));
    this.heap.setSlot(record, 10, undefinedValue());
    this.heap.setSlot(record, 11, int32Value(0));
    this.heap.setSlot(record, 12, int32Value(0));
    const code = this.heap.functionIndex(asCell(callee));
    if (this.functions[usize(code)].isAsync && this.functions[usize(code)].isGenerator) {
      this.heap.setSlot(record, 10, cellValue(this.heap.allocateArray(0)));
    }
    const atomGenRecord = this.atomGenRecord;
    this.heap.objectDefine(gen, atomGenRecord, cellValue(record), PROP_NONE);
    return cellValue(gen);
  }

  // Resume with next (mode 0), throw (1), or return (2). The result is
  // the iterator result the body produced; a throw is left pending.
  function generatorIsAsync(record: u32): boolean {
    const callee = this.heap.slot(record, 1);
    return this.functions[usize(this.heap.functionIndex(asCell(callee)))].isAsync;
  }

  function generatorResume(inout this, gen: u32, sent: Value, mode: u32): Value {
    const record = this.generatorRecord(gen);
    const state = asInt32(this.heap.slot(record, 0));
    if (state == GEN_COMPLETED) {
      if (mode == 1) {
        this.raise(sent);
        return undefinedValue();
      }
      const finishedAsync = this.generatorIsAsync(record);
      return this.resumeResult(finishedAsync, mode == 2 ? sent : undefinedValue(), true);
    }
    if (state == GEN_RUNNING) {
      const message: String = "Generator is already running";
      const error = this.typeError(in message);
      this.raise(error);
      return undefinedValue();
    }
    const kind = asInt32(this.heap.slot(record, 9));
    const delegating = kind == 3 || kind == 5;
    const callee = this.heap.slot(record, 1);
    if (mode == 2 && kind == 4) {
      // A return before the body ever ran completes the generator (an
      // async generator's driver settles such a request itself, after
      // awaiting the value, and never resumes here).
      this.heap.setSlot(record, 0, int32Value(GEN_COMPLETED));
      const unstartedAsync = this.generatorIsAsync(record);
      return this.resumeResult(unstartedAsync, sent, true);
    }
    // A return at a yield re-enters the body, which returns the value
    // through its finally blocks (the compiler checks the mode after
    // every yield); a delegating yield forwards it.
    this.heap.setSlot(record, 12, int32Value(i32(mode)));
    this.heap.setSlot(record, 0, int32Value(GEN_RUNNING));
    const thisValue = this.heap.slot(record, 2);
    const entryDepth = this.frameCount;
    const savedTop = this.regTop;
    {
      const target = this.heap.functionIndex(asCell(callee));
      this.pushFrame(target, 0);
      const top = usize(this.frameCount - 1);
      const base = this.frames[top].regsBase;
      const saved = asCell(this.heap.slot(record, 4));
      const count = this.heap.arrayLength(saved);
      let index: u32 = 0;
      while (index < count) {
        const held = this.heap.slot(saved, index);
        this.regStack[usize(base + index)] = held;
        index = index + 1;
      }
      this.frames[top].ip = usize(asInt32(this.heap.slot(record, 5)));
      this.frames[top].env = u32(asInt32(this.heap.slot(record, 8)));
      this.frames[top].callee = callee;
      this.hostThis = thisValue;
      const heldTries = this.heap.slot(record, 7);
      const tries: u32 = isCell(heldTries) ? asCell(heldTries) : 0;
      const pairs: u32 = tries == 0 ? 0 : this.heap.arrayLength(tries);
      let t: u32 = 0;
      while (t + 2 < pairs) {
        const catchIp = usize(asInt32(this.heap.slot(tries, t)));
        const catchReg = u8(asInt32(this.heap.slot(tries, t + 1)));
        const tryEnv = u32(asInt32(this.heap.slot(tries, t + 2)));
        this.pushTryEnv(catchIp, catchReg, tryEnv);
        t = t + 3;
      }
      const resumeDst = u8(asInt32(this.heap.slot(record, 6)));
      if (mode == 1 && !delegating) {
        this.raise(sent);
      } else {
        // next and return deliver the value; a delegating yield takes a
        // throw as a value too and forwards it.
        this.setReg(base, resumeDst, sent);
      }
    }
    const top = usize(this.frameCount - 1);
    this.frames[top].generator = gen;
    const result = this.runFrames(entryDepth);
    this.regTop = savedTop;
    if (result.isThrow) {
      this.completeGenerator(gen);
      this.raise(result.value);
      return undefinedValue();
    }
    return result.value;
  }

  // Suspend the running generator frame at a yield: registers, resume
  // point, environment, and the frame's try handlers go into the record.
  function suspendGenerator(inout this, frameIndex: usize, ip: usize, resumeDst: u8): void {
    const gen = this.frames[frameIndex].generator;
    const record = this.generatorRecord(gen);
    const base = this.frames[frameIndex].regsBase;
    const count = this.frames[frameIndex].regCount;
    // The registers go back into the array the last suspension filled,
    // which has been idle since they were restored from it.
    const previous = this.heap.slot(record, 4);
    let saved: u32 = 0;
    if (isCell(previous) && asCell(previous) != 0 && this.heap.arrayLength(asCell(previous)) == count) {
      saved = asCell(previous);
    } else {
      saved = this.heap.allocateArray(count);
    }
    let index: u32 = 0;
    while (index < count) {
      const held = this.regStack[usize(base + index)];
      this.heap.setSlot(saved, index, held);
      index = index + 1;
    }
    this.heap.setSlot(record, 4, cellValue(saved));
    this.heap.setSlot(record, 5, int32Value(i32(ip)));
    this.heap.setSlot(record, 6, int32Value(i32(resumeDst)));
    const env = this.frames[frameIndex].env;
    this.heap.setSlot(record, 8, int32Value(i32(env)));
    // The frame's handlers, bottom-up, then popped; most suspensions
    // have none, and then nothing is made to hold them.
    let first = this.tryDepth;
    while (first > 0 && this.tryStack[usize(first - 1)].frameIndex == u32(frameIndex)) { first = first - 1; }
    if (first == this.tryDepth) {
      this.heap.setSlot(record, 7, undefinedValue());
    } else {
      const tries = this.heap.allocateArray(0);
      let t = first;
      while (t < this.tryDepth) {
        const length = this.heap.arrayLength(tries);
        this.heap.arraySet(tries, length, int32Value(i32(this.tryStack[usize(t)].catchIp)));
        this.heap.arraySet(tries, length + 1, int32Value(i32(this.tryStack[usize(t)].catchReg)));
        this.heap.arraySet(tries, length + 2, int32Value(i32(this.tryStack[usize(t)].env)));
        t = t + 1;
      }
      this.tryDepth = first;
      this.heap.setSlot(record, 7, cellValue(tries));
    }
    this.heap.setSlot(record, 0, int32Value(GEN_YIELDED));
  }

  // A finished body lets go of the registers and handlers it had saved.
  function completeGenerator(inout this, gen: u32): void {
    const record = this.generatorRecord(gen);
    this.heap.setSlot(record, 0, int32Value(GEN_COMPLETED));
    this.heap.setSlot(record, 4, undefinedValue());
    this.heap.setSlot(record, 7, undefinedValue());
  }

  // --- Builtins ---

  // Register a builtin that is not a constructor: a host function cell
  // whose payload indexes the table. Slot 0 is per-instance data, slot 1
  // `length`, slot 2 `name`, slot 3 the property bag, slot 4 whether `new`
  // may be applied.
  function defineHostFunction(inout this, fn: HostFunction, bound: Value, length: u32, in name: String): u32 {
    return this.defineHostFunctionBytes(fn, bound, length, bytesOf(in name));
  }

  // The name as engine bytes, for names assembled from JavaScript strings.
  function defineHostFunctionBytes(inout this, fn: HostFunction, bound: Value, length: u32, nameBytes: Array<u8>): u32 {
    this.hostTable.push(fn);
    const id = u32(this.hostTable.length - 1);
    const handle = this.heap.allocateHostFunction(id);
    this.heap.setSlot(handle, 0, bound);
    this.heap.setSlot(handle, 1, int32Value(i32(length)));
    const nameValue = this.internUtf8Value(move nameBytes);
    this.heap.setSlot(handle, 2, nameValue);
    this.heap.setSlot(handle, 4, booleanValue(false));
    return handle;
  }

  // A host function named from units assembled at run time.
  function defineHostFunctionUnits(inout this, fn: HostFunction, bound: Value, length: u32, nameUnits: Array<u16>): u32 {
    this.hostTable.push(fn);
    const id = u32(this.hostTable.length - 1);
    const handle = this.heap.allocateHostFunction(id);
    this.heap.setSlot(handle, 0, bound);
    this.heap.setSlot(handle, 1, int32Value(i32(length)));
    const nameValue = this.internUnitsValue(move nameUnits);
    this.heap.setSlot(handle, 2, nameValue);
    this.heap.setSlot(handle, 4, booleanValue(false));
    return handle;
  }

  // Register a builtin that will be instantiated at run time.
  function registerSharedHost(inout this, which: usize, fn: HostFunction): void {
    while (this.sharedHosts.length <= which) { this.sharedHosts.push(0); }
    this.hostTable.push(fn);
    this.sharedHosts[which] = u32(this.hostTable.length - 1);
  }

  // An instance of a registered builtin, anonymous unless named.
  function newSharedHost(inout this, which: usize, bound: Value, length: u32): u32 {
    return this.newSharedHostNamed(which, bound, length, Array<u16>());
  }

  function newSharedHostNamed(inout this, which: usize, bound: Value, length: u32, nameUnits: Array<u16>): u32 {
    const id = this.sharedHosts[which];
    const handle = this.heap.allocateHostFunction(id);
    this.heap.setSlot(handle, 0, bound);
    this.heap.setSlot(handle, 1, int32Value(i32(length)));
    const nameValue = this.internUnitsValue(move nameUnits);
    this.heap.setSlot(handle, 2, nameValue);
    this.heap.setSlot(handle, 4, booleanValue(false));
    return handle;
  }

  // Register a builtin constructor.
  function defineConstructor(inout this, fn: HostFunction, bound: Value, length: u32, in name: String): u32 {
    const handle = this.defineHostFunction(fn, bound, length, in name);
    this.heap.setSlot(handle, 4, booleanValue(true));
    return handle;
  }

  // Register a builtin constructor that makes its own object: it is
  // called with no `this`, and takes the new target from the runtime, so
  // it can tell a construct from a call and order the `prototype` read
  // among its own checks. Slot 4 holds an integer for these.
  function defineAllocatingConstructor(inout this, fn: HostFunction, bound: Value, length: u32, in name: String): u32 {
    const handle = this.defineHostFunction(fn, bound, length, in name);
    this.heap.setSlot(handle, 4, int32Value(1));
    return handle;
  }

  // Mark an existing host function as such a constructor.
  function markAllocatingConstructor(inout this, handle: u32): void {
    this.heap.setSlot(handle, 4, int32Value(1));
  }

  function hostMakesOwnObject(handle: u32): boolean {
    return isInt32(this.heap.slot(handle, 4));
  }

  // The new target of the construct call being entered, or undefined
  // for a plain call; reading it clears it.
  function takeHostNewTarget(inout this): Value {
    const target = this.hostNewTarget;
    if (!isUndefined(target)) this.hostNewTarget = undefinedValue();
    return target;
  }

  // `new` applied directly to a builtin constructor, which is then its
  // own new target. A throw is left pending.
  function constructHostDirect(inout this, callee: u32, argsBase: u32, argc: u32): Value {
    const builtin = this.heap.hostFunctionId(callee);
    if (this.hostMakesOwnObject(callee)) {
      this.hostNewTarget = cellValue(callee);
      return this.callHost(builtin, undefinedValue(), argsBase, argc, callee);
    }
    const proto = this.prototypeOf(callee);
    const created = cellValue(this.heap.allocateObject(proto));
    const outcome = this.callHost(builtin, created, argsBase, argc, callee);
    if (this.pendingThrow) return undefinedValue();
    return this.isObjectLike(outcome) ? outcome : created;
  }

  function isConstructorValue(value: Value): boolean {
    if (!isCell(value) || asCell(value) == 0) return false;
    const handle = asCell(value);
    const tag = this.heap.tagOf(handle);
    if (tag == TAG_HOST_FUNCTION) {
      const mark = this.heap.slot(handle, 4);
      return isTrue(mark) || isInt32(mark);
    }
    if (tag == TAG_FUNCTION || tag == TAG_CLOSURE) {
      const code = this.heap.functionIndex(handle);
      return !this.functions[usize(code)].isArrow && !this.functions[usize(code)].isGenerator && !this.functions[usize(code)].isAsync && !this.functions[usize(code)].isMethod;
    }
    return false;
  }

  // Whether a function value exposes `prototype`: constructors, generator
  // functions, and host functions given one explicitly (Symbol).
  function functionHasPrototype(value: Value): boolean {
    if (this.isBoundFunction(value)) return false;
    if (this.isConstructorValue(value)) return true;
    if (this.isCompiledCallable(value)) {
      const code = this.heap.functionIndex(asCell(value));
      return this.functions[usize(code)].isGenerator;
    }
    return this.isHostFunctionValue(value) && this.heap.linkOf(asCell(value)) != 0;
  }

  // A builtin as a non-enumerable property of `target`.
  function defineMethod(inout this, target: u32, in name: String, fn: HostFunction, length: u32): u32 {
    const handle = this.defineHostFunction(fn, undefinedValue(), length, in name);
    const atom = this.atomOf(in name);
    this.defineOwnAttr(target, atom, cellValue(handle), PROP_METHOD);
    return handle;
  }

  // Define an own data property with attributes on an object or a
  // function-like cell.
  function defineOwnAttr(inout this, target: u32, atom: u32, value: Value, attr: u8): void {
    if (this.heap.isObject(target)) {
      this.heap.objectDefine(target, atom, value, attr);
      return;
    }
    const bag = this.ensureFunctionBag(target);
    this.heap.objectDefine(bag, atom, value, attr);
  }

  function callHost(inout this, id: u32, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value {
    const fn = this.hostTable[usize(id)];
    return fn(inout this, thisValue, argsBase, argc, callee);
  }

  // CanBeHeldWeakly: an object, or a symbol that is not in the global
  // registry (well-known symbols qualify).
  function canBeHeldWeakly(value: Value): boolean {
    if (this.isObjectLike(value)) return true;
    if (!this.isSymbolValue(value)) return false;
    return (this.heap.flagsOf(asCell(value)) & FLAG_REGISTERED_SYMBOL) == 0;
  }

  // A builtin global: writable and configurable, not enumerable.
  function setGlobal(inout this, name: String, value: Value): void {
    this.setGlobalAttr(move name, value, PROP_METHOD);
  }

  function setGlobalAttr(inout this, name: String, value: Value, attr: u8): void {
    const slot = this.defineGlobalSlot(move name);
    this.globals[usize(slot)].value = value;
    this.globals[usize(slot)].attr = attr;
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
    this.tempRoots.push(value);
  }

  function popTempRoot(inout this): void {
    const dropped = this.tempRoots.pop();
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
    return this.callPlaced(callee, thisValue, argsBase, argc);
  }

  // The same with a known few arguments, placed straight into the
  // registers a call reads them from: no vector is built to carry them.
  function callValue0(inout this, callee: Value, thisValue: Value): Value {
    const argsBase = this.regTop;
    return this.callPlaced(callee, thisValue, argsBase, 0);
  }

  function callValue1(inout this, callee: Value, thisValue: Value, first: Value): Value {
    const argsBase = this.regTop;
    while (this.regStack.length < usize(argsBase + 1)) { this.regStack.push(undefinedValue()); }
    this.regStack[usize(argsBase)] = first;
    this.regTop = argsBase + 1;
    return this.callPlaced(callee, thisValue, argsBase, 1);
  }

  function callValue2(inout this, callee: Value, thisValue: Value, first: Value, second: Value): Value {
    const argsBase = this.regTop;
    while (this.regStack.length < usize(argsBase + 2)) { this.regStack.push(undefinedValue()); }
    this.regStack[usize(argsBase)] = first;
    this.regStack[usize(argsBase + 1)] = second;
    this.regTop = argsBase + 2;
    return this.callPlaced(callee, thisValue, argsBase, 2);
  }

  // The call itself, its arguments already in registers from argsBase.
  function callPlaced(inout this, callee: Value, thisValue: Value, argsBase: u32, argc: u32): Value {
    let outcome = undefinedValue();
    if (this.isHostFunctionValue(callee)) {
      const handle = asCell(callee);
      const builtin = this.heap.hostFunctionId(handle);
      outcome = this.callHost(builtin, thisValue, argsBase, argc, handle);
    } else if (this.isCompiledCallable(callee)) {
      const entryDepth = this.frameCount;
      if (this.enterCallable(callee, 0, thisValue, argsBase, argc, undefinedValue())) {
        const result = this.runFrames(entryDepth);
        if (result.isThrow) {
          this.raise(result.value);
        } else {
          outcome = result.value;
        }
      }
    } else {
      const message: String = "value is not a function";
      const error = this.typeError(in message);
      this.raise(error);
    }
    this.regTop = argsBase;
    return outcome;
  }

  // Construct from Z: a fresh object inheriting from newTarget's prototype
  // becomes this; the constructor's own object result wins. A throw is
  // left pending; the result is then undefined.
  function constructValue(inout this, callee: Value, args: Array<Value>, newTarget: Value): Value {
    if (!this.isConstructorValue(callee) || !this.isConstructorValue(newTarget)) {
      const error = this.notConstructorError(callee);
      this.raise(error);
      return undefinedValue();
    }
    let outcome = undefinedValue();
    if (this.isHostFunctionValue(callee)) {
      if (this.hostMakesOwnObject(asCell(callee))) {
        this.hostNewTarget = newTarget;
        outcome = this.callValue(callee, undefinedValue(), move args);
        if (this.pendingThrow) return undefinedValue();
        return outcome;
      }
      // The new target's `prototype` if it is an object, else the
      // builtin's own.
      const atomPrototype = this.atomPrototype;
      const held = this.getProperty(newTarget, cellValue(atomPrototype));
      if (this.pendingThrow) return undefinedValue();
      let proto = this.prototypeOf(asCell(callee));
      if (this.isObjectLike(held)) proto = asCell(held);
      const created = cellValue(this.heap.allocateObject(proto));
      this.pushTempRoot(created);
      outcome = this.callValue(callee, created, move args);
      this.popTempRoot();
      if (this.pendingThrow) return undefinedValue();
      return this.isObjectLike(outcome) ? outcome : created;
    }
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
    const entryDepth = this.frameCount;
    // The return handler substitutes the constructed object for a
    // non-object return value, and checks a derived constructor did
    // call super(), so the result is the object or a throw.
    if (this.enterConstruct(callee, 0, argsBase, argc, newTarget)) {
      const result = this.runFrames(entryDepth);
      if (result.isThrow) {
        this.raise(result.value);
      } else {
        outcome = result.value;
      }
    }
    this.regTop = argsBase;
    if (this.pendingThrow) return undefinedValue();
    return outcome;
  }

  // ToPrimitive with the string or number hint.
  function toPrimitive(inout this, value: Value, preferString: boolean): Value {
    return this.toPrimitiveWithHint(value, preferString ? HINT_STRING : HINT_NUMBER);
  }

  // ToPrimitive: an @@toPrimitive method decides first, else valueOf and
  // toString in the order the hint asks for (default counts as number);
  // the first that yields a primitive wins.
  function toPrimitiveWithHint(inout this, value: Value, hint: u32): Value {
    if (!this.isObjectLike(value)) return value;
    const preferString = hint == HINT_STRING;
    // An object's own @@toPrimitive decides first.
    const toPrimitiveKey = this.symbolToPrimitive;
    const exotic = this.getProperty(value, toPrimitiveKey);
    if (this.pendingThrow) return undefinedValue();
    if (!isUndefined(exotic) && !isNull(exotic)) {
      if (!this.isCallable(exotic)) {
        const message: String = "Symbol.toPrimitive is not a function";
        const error = this.typeError(in message);
        this.raise(error);
        return undefinedValue();
      }
      let hintText: String = "default";
      if (hint == HINT_STRING) hintText = "string";
      if (hint == HINT_NUMBER) hintText = "number";
      const produced = this.callValue1(exotic, value, this.internText(in hintText));
      if (this.pendingThrow) return undefinedValue();
      if (this.isObjectLike(produced)) {
        const message: String = "Cannot convert object to primitive value";
        const error = this.typeError(in message);
        this.raise(error);
        return undefinedValue();
      }
      return produced;
    }
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
    const result = this.callValue0(method, object);
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
    const doneText: String = "done";
    this.atomDone = this.atomOf(in doneText);
    const valueText: String = "value";
    this.atomValue = this.atomOf(in valueText);
    const thenText: String = "then";
    this.atomThen = this.atomOf(in thenText);
    const nextText: String = "next";
    this.atomNext = this.atomOf(in nextText);
    const returnText: String = "return";
    this.atomReturn = this.atomOf(in returnText);
    const throwText: String = "throw";
    this.atomThrow = this.atomOf(in throwText);
    const resolveText: String = "resolve";
    this.atomResolve = this.atomOf(in resolveText);
    let hidden = Array<u8>();
    hidden.push(255);
    hidden.push(112);
    hidden.push(114);
    hidden.push(105);
    hidden.push(109);
    this.atomPrimitive = this.hiddenAtomBytes(move hidden);
    let marker = Array<u8>();
    marker.push(255);
    marker.push(97);
    marker.push(114);
    marker.push(103);
    this.atomArgumentsMarker = this.hiddenAtomBytes(move marker);
    let iterSource = Array<u8>();
    iterSource.push(255);
    iterSource.push(105);
    iterSource.push(115);
    this.atomIterSource = this.hiddenAtomBytes(move iterSource);
    let iterIndex = Array<u8>();
    iterIndex.push(255);
    iterIndex.push(105);
    iterIndex.push(120);
    this.atomIterIndex = this.hiddenAtomBytes(move iterIndex);
    let iterKind = Array<u8>();
    iterKind.push(255);
    iterKind.push(105);
    iterKind.push(107);
    this.atomIterKind = this.hiddenAtomBytes(move iterKind);
    let genRecord = Array<u8>();
    genRecord.push(255);
    genRecord.push(103);
    genRecord.push(114);
    this.atomGenRecord = this.hiddenAtomBytes(move genRecord);
    let mapRecord = Array<u8>();
    mapRecord.push(255);
    mapRecord.push(109);
    mapRecord.push(114);
    this.atomMapRecord = this.hiddenAtomBytes(move mapRecord);
    let mapIter = Array<u8>();
    mapIter.push(255);
    mapIter.push(109);
    mapIter.push(105);
    this.atomMapIter = this.hiddenAtomBytes(move mapIter);
    this.atomHome = this.hiddenAtom(104, 111);
    this.atomNewTarget = this.hiddenAtom(110, 116);
    this.atomFunctionProto = this.hiddenAtom(102, 112);
    this.atomPromiseRecord = this.hiddenAtom(112, 114);
    this.atomErrorData = this.hiddenAtom(101, 100);
    this.atomDateValue = this.hiddenAtom(100, 116);
    this.atomRegexSource = this.hiddenAtom(114, 115);
    this.atomRegexFlags = this.hiddenAtom(114, 102);
    this.atomRegexCompiled = this.hiddenAtom(114, 99);
    this.atomRegexIter = this.hiddenAtom(114, 105);
    this.atomRegexTicket = this.hiddenAtom(114, 116);
    const lastIndexText: String = "lastIndex";
    this.atomLastIndex = this.atomOf(in lastIndexText);
    const indexText: String = "index";
    this.atomIndex = this.atomOf(in indexText);
    const inputText: String = "input";
    this.atomInput = this.atomOf(in inputText);
    const groupsText: String = "groups";
    this.atomGroups = this.atomOf(in groupsText);
    const execText: String = "exec";
    this.atomExec = this.atomOf(in execText);
    const flagsText: String = "flags";
    this.atomFlags = this.atomOf(in flagsText);
    this.atomSyncIterator = this.hiddenAtom(115, 105);
    this.objectProto = this.heap.allocateObject(0);
    const objectProto = this.objectProto;
    this.functionProto = this.heap.allocateObject(objectProto);
    this.arrayProto = this.heap.allocateObject(objectProto);
    this.stringProto = this.heap.allocateObject(objectProto);
    this.numberProto = this.heap.allocateObject(objectProto);
    this.booleanProto = this.heap.allocateObject(objectProto);
    this.symbolProto = this.heap.allocateObject(objectProto);
    this.iteratorProto = this.heap.allocateObject(objectProto);
    const iteratorProto = this.iteratorProto;
    this.arrayIteratorProto = this.heap.allocateObject(iteratorProto);
    this.generatorProto = this.heap.allocateObject(iteratorProto);
    this.asyncIteratorProto = this.heap.allocateObject(objectProto);
    const asyncIteratorProto = this.asyncIteratorProto;
    this.asyncGeneratorProto = this.heap.allocateObject(asyncIteratorProto);
    this.asyncFromSyncProto = this.heap.allocateObject(asyncIteratorProto);
    this.globalObject = this.heap.allocateObject(objectProto);
    const iteratorText: String = "Symbol.iterator";
    this.symbolIterator = this.newSymbol(this.internText(in iteratorText));
    const toPrimitiveText: String = "Symbol.toPrimitive";
    this.symbolToPrimitive = this.newSymbol(this.internText(in toPrimitiveText));
    const toStringTagText: String = "Symbol.toStringTag";
    this.symbolToStringTag = this.newSymbol(this.internText(in toStringTagText));
    const hasInstanceText: String = "Symbol.hasInstance";
    this.symbolHasInstance = this.newSymbol(this.internText(in hasInstanceText));
    const speciesText: String = "Symbol.species";
    this.symbolSpecies = this.newSymbol(this.internText(in speciesText));
    const spreadableText: String = "Symbol.isConcatSpreadable";
    this.symbolIsConcatSpreadable = this.newSymbol(this.internText(in spreadableText));
    const unscopablesText: String = "Symbol.unscopables";
    this.symbolUnscopables = this.newSymbol(this.internText(in unscopablesText));
    const asyncIteratorText: String = "Symbol.asyncIterator";
    this.symbolAsyncIterator = this.newSymbol(this.internText(in asyncIteratorText));
    const matchText: String = "Symbol.match";
    this.symbolMatch = this.newSymbol(this.internText(in matchText));
    const matchAllText: String = "Symbol.matchAll";
    this.symbolMatchAll = this.newSymbol(this.internText(in matchAllText));
    const replaceText: String = "Symbol.replace";
    this.symbolReplace = this.newSymbol(this.internText(in replaceText));
    const searchText: String = "Symbol.search";
    this.symbolSearch = this.newSymbol(this.internText(in searchText));
    const splitText: String = "Symbol.split";
    this.symbolSplit = this.newSymbol(this.internText(in splitText));
    // Value properties of the global object.
    this.setGlobalAttr("NaN", doubleValue(nativeNan()), PROP_NONE);
    this.setGlobalAttr("Infinity", doubleValue(1.0 / 0.0), PROP_NONE);
    this.setGlobalAttr("undefined", undefinedValue(), PROP_NONE);
    this.setGlobal("globalThis", cellValue(this.globalObject));
  }

  // --- Collection ---

  // Mark everything reachable from the runtime's roots, then sweep. Runs
  // only at instruction boundaries, where every live value sits in a
  // register, a frame, a global, or a table -- never in a Z local.
  function collectGarbage(inout this): void {
    let started: f64 = 0.0;
    if (this.gcTiming) started = native.zjs_clock_mono_ns();
    this.collectNow();
    if (this.gcTiming) this.gcPauses.push(native.zjs_clock_mono_ns() - started);
  }

  function collectNow(inout this): void {
    this.heap.markedCells = 0;
    this.heap.markedSlots = 0;
    this.heap.weakVisits = 0;
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
      const newTarget = this.frames[index].newTarget;
      const generator = this.frames[index].generator;
      this.heap.markValue(savedThis);
      this.heap.markValue(constructThis);
      this.heap.markValue(callee);
      this.heap.markHandle(env);
      this.heap.markValue(newTarget);
      // A running generator or async body: its object (and record) may
      // be referenced by nothing else during its first run.
      this.heap.markHandle(generator);
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
    const symbolProto = this.symbolProto;
    this.heap.markHandle(symbolProto);
    const atomPrimitive = this.atomPrimitive;
    this.heap.markHandle(atomPrimitive);
    const atomArgumentsMarker = this.atomArgumentsMarker;
    this.heap.markHandle(atomArgumentsMarker);
    const iteratorProto = this.iteratorProto;
    this.heap.markHandle(iteratorProto);
    const arrayIteratorProto = this.arrayIteratorProto;
    this.heap.markHandle(arrayIteratorProto);
    const atomIterSource = this.atomIterSource;
    this.heap.markHandle(atomIterSource);
    const atomIterIndex = this.atomIterIndex;
    this.heap.markHandle(atomIterIndex);
    const atomIterKind = this.atomIterKind;
    this.heap.markHandle(atomIterKind);
    const arrayIteratorNext = this.arrayIteratorNext;
    this.heap.markHandle(arrayIteratorNext);
    const generatorProto = this.generatorProto;
    this.heap.markHandle(generatorProto);
    const atomGenRecord = this.atomGenRecord;
    this.heap.markHandle(atomGenRecord);
    const mapProto = this.mapProto;
    this.heap.markHandle(mapProto);
    const setProto = this.setProto;
    this.heap.markHandle(setProto);
    const weakMapProto = this.weakMapProto;
    this.heap.markHandle(weakMapProto);
    const weakSetProto = this.weakSetProto;
    this.heap.markHandle(weakSetProto);
    const mapIteratorProto = this.mapIteratorProto;
    this.heap.markHandle(mapIteratorProto);
    const setIteratorProto = this.setIteratorProto;
    this.heap.markHandle(setIteratorProto);
    const atomMapRecord = this.atomMapRecord;
    this.heap.markHandle(atomMapRecord);
    const atomMapIter = this.atomMapIter;
    this.heap.markHandle(atomMapIter);
    const atomHome = this.atomHome;
    this.heap.markHandle(atomHome);
    const atomNewTarget = this.atomNewTarget;
    this.heap.markHandle(atomNewTarget);
    const atomFunctionProto = this.atomFunctionProto;
    this.heap.markHandle(atomFunctionProto);
    const atomPromiseRecord = this.atomPromiseRecord;
    this.heap.markHandle(atomPromiseRecord);
    const atomErrorData = this.atomErrorData;
    this.heap.markHandle(atomErrorData);
    const atomDateValue = this.atomDateValue;
    this.heap.markHandle(atomDateValue);
    const atomRegexSource = this.atomRegexSource;
    this.heap.markHandle(atomRegexSource);
    const atomRegexFlags = this.atomRegexFlags;
    this.heap.markHandle(atomRegexFlags);
    const atomRegexCompiled = this.atomRegexCompiled;
    this.heap.markHandle(atomRegexCompiled);
    const atomRegexIter = this.atomRegexIter;
    this.heap.markHandle(atomRegexIter);
    const atomRegexTicket = this.atomRegexTicket;
    this.heap.markHandle(atomRegexTicket);
    const atomLastIndex = this.atomLastIndex;
    this.heap.markHandle(atomLastIndex);
    const atomIndex = this.atomIndex;
    this.heap.markHandle(atomIndex);
    const atomInput = this.atomInput;
    this.heap.markHandle(atomInput);
    const atomGroups = this.atomGroups;
    this.heap.markHandle(atomGroups);
    const atomExec = this.atomExec;
    this.heap.markHandle(atomExec);
    const atomFlags = this.atomFlags;
    this.heap.markHandle(atomFlags);
    const regexProto = this.regexProto;
    if (regexProto != 0) this.heap.markHandle(regexProto);
    const regexIteratorProto = this.regexIteratorProto;
    if (regexIteratorProto != 0) this.heap.markHandle(regexIteratorProto);
    const regexExecFn = this.regexExecFn;
    if (regexExecFn != 0) this.heap.markHandle(regexExecFn);
    const regexCtor = this.regexCtor;
    if (regexCtor != 0) this.heap.markHandle(regexCtor);
    const symbolMatch = this.symbolMatch;
    this.heap.markValue(symbolMatch);
    const symbolMatchAll = this.symbolMatchAll;
    this.heap.markValue(symbolMatchAll);
    const symbolReplace = this.symbolReplace;
    this.heap.markValue(symbolReplace);
    const symbolSearch = this.symbolSearch;
    this.heap.markValue(symbolSearch);
    const symbolSplit = this.symbolSplit;
    this.heap.markValue(symbolSplit);
    const promiseProto = this.promiseProto;
    this.heap.markHandle(promiseProto);
    const promiseCtor = this.promiseCtor;
    this.heap.markHandle(promiseCtor);
    const promiseSpeciesGetter = this.promiseSpeciesGetter;
    this.heap.markHandle(promiseSpeciesGetter);
    let job: usize = 0;
    while (job < this.jobs.length) {
      const queued = this.jobs[job];
      this.heap.markValue(queued);
      job = job + 1;
    }
    const symbolIterator = this.symbolIterator;
    this.heap.markValue(symbolIterator);
    const symbolToPrimitive = this.symbolToPrimitive;
    this.heap.markValue(symbolToPrimitive);
    const symbolToStringTag = this.symbolToStringTag;
    this.heap.markValue(symbolToStringTag);
    const symbolHasInstance = this.symbolHasInstance;
    this.heap.markValue(symbolHasInstance);
    const symbolSpecies = this.symbolSpecies;
    this.heap.markValue(symbolSpecies);
    const symbolIsConcatSpreadable = this.symbolIsConcatSpreadable;
    this.heap.markValue(symbolIsConcatSpreadable);
    const symbolUnscopables = this.symbolUnscopables;
    this.heap.markValue(symbolUnscopables);
    const symbolAsyncIterator = this.symbolAsyncIterator;
    this.heap.markValue(symbolAsyncIterator);
    const asyncIteratorProto = this.asyncIteratorProto;
    this.heap.markHandle(asyncIteratorProto);
    const asyncGeneratorProto = this.asyncGeneratorProto;
    this.heap.markHandle(asyncGeneratorProto);
    const asyncFromSyncProto = this.asyncFromSyncProto;
    this.heap.markHandle(asyncFromSyncProto);
    const atomSyncIterator = this.atomSyncIterator;
    this.heap.markHandle(atomSyncIterator);
    index = 0;
    while (index < this.symbolRegistry.length) {
      const registered = this.symbolRegistry[index];
      this.heap.markValue(registered);
      index = index + 1;
    }
    index = 0;
    while (index < this.tempRoots.length) {
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
    const atomDone = this.atomDone;
    this.heap.markHandle(atomDone);
    const atomValue = this.atomValue;
    this.heap.markHandle(atomValue);
    const atomThen = this.atomThen;
    this.heap.markHandle(atomThen);
    const atomNext = this.atomNext;
    this.heap.markHandle(atomNext);
    const atomReturn = this.atomReturn;
    this.heap.markHandle(atomReturn);
    const atomThrow = this.atomThrow;
    this.heap.markHandle(atomThrow);
    const atomResolve = this.atomResolve;
    this.heap.markHandle(atomResolve);
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
      const nameAtom = this.functions[index].nameAtom;
      this.heap.markHandle(nameAtom);
      index = index + 1;
    }
    // Weak collections: values reached through marked keys, to a
    // fixpoint, then the entries of dead keys dropped -- before the
    // atom rebuild, since such values can hold interned strings.
    this.heap.markEphemerons();
    this.heap.clearDeadWeakEntries();
    // The atom table is weak: an interned string nothing else reaches is
    // dropped, and the table is rebuilt from the survivors.
    this.rebuildAtoms();
    this.heap.sweep();
  }

  function rebuildAtoms(inout this): void {
    let survivors = Array<u32>.withCapacity(usize(this.atomCount));
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
    const mask = this.atoms.length - 1;
    let slot = usize(this.hashStorage(handle)) & mask;
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
      return this.stringValueToNumber(asCell(value));
    }
    if (this.isSymbolValue(value)) {
      const what: String = "number";
      const error = this.symbolTypeError(in what);
      this.raise(error);
      return nativeNan();
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
    if (this.isSymbolValue(value)) {
      const what: String = "string";
      const error = this.symbolTypeError(in what);
      this.raise(error);
      return this.internLatin1Value(Array<u8>());
    }
    if (this.isObjectLike(value)) {
      const primitive = this.toPrimitive(value, true);
      if (this.pendingThrow) return this.internLatin1Value(Array<u8>());
      return this.toStringValue(primitive);
    }
    if (isInt32(value)) {
      const text = int32ToString(asInt32(value));
      return this.newStringLatin1(bytesOf(in text));
    }
    if (isDouble(value)) {
      const text = doubleToString(asDouble(value));
      return this.newStringLatin1(bytesOf(in text));
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
    let joined = Array<u16>();
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
          joined.push(this.heap.stringUnit(handle, i));
          i = i + 1;
        }
      }
      index = index + 1;
    }
    return this.newStringUnits(move joined);
  }

  function concatStrings(inout this, a: Value, b: Value): Value {
    const left = this.toStringValue(a);
    const right = this.toStringValue(b);
    const leftHandle = asCell(left);
    const rightHandle = asCell(right);
    if (this.heap.stringLength(leftHandle) == 0) return right;
    if (this.heap.stringLength(rightHandle) == 0) return left;
    // Two narrow strings stay narrow by joining storage; anything else
    // goes through units.
    if (!this.heap.isWideString(leftHandle) && !this.heap.isWideString(rightHandle)) {
      const leftLength = this.heap.stringStorageLength(leftHandle);
      const rightLength = this.heap.stringStorageLength(rightHandle);
      let joined = Array<u8>.withCapacity(leftLength + rightLength);
      let i: usize = 0;
      while (i < leftLength) {
        joined.push(this.heap.stringStorageByte(leftHandle, i));
        i = i + 1;
      }
      i = 0;
      while (i < rightLength) {
        joined.push(this.heap.stringStorageByte(rightHandle, i));
        i = i + 1;
      }
      return this.newStringLatin1(move joined);
    }
    let units = this.heap.stringUnits(leftHandle);
    appendUnits(inout units, this.heap.stringUnits(rightHandle));
    return this.newStringUnits(move units);
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
      const primitive = this.toPrimitiveWithHint(a, HINT_DEFAULT);
      if (this.pendingThrow) return false;
      return this.looseEquals(primitive, b);
    }
    if (bObject) {
      const primitive = this.toPrimitiveWithHint(b, HINT_DEFAULT);
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
      env: 0, callee: undefinedValue(), argsBase: 0, argc: 0, generator: 0, newTarget: undefinedValue(),
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
  function enterCallable(inout this, callee: Value, returnDst: u8, thisValue: Value, argsBase: u32, argc: u32, constructThis: Value): boolean {
    const handle = asCell(callee);
    const target = this.heap.functionIndex(handle);
    if (this.functions[usize(target)].isClassConstructor && isUndefined(constructThis)) {
      const message: String = "Class constructor cannot be invoked without 'new'";
      const error = this.typeError(in message);
      this.raise(error);
      return false;
    }
    let env: u32 = 0;
    let boundThis = thisValue;
    if (this.heap.isClosure(handle)) {
      env = this.heap.linkOf(handle);
      if (this.functions[usize(target)].isArrow) boundThis = this.heap.slot(handle, 0);
    }
    // A sloppy function called with no receiver sees the global object.
    if (!this.functions[usize(target)].strict && (isUndefined(boundThis) || isNull(boundThis))) boundThis = cellValue(this.globalObject);
    // A generator's parameters initialize now; GeneratorStart then
    // suspends and hands the caller the generator object.
    let generator: u32 = 0;
    if (this.functions[usize(target)].isGenerator || this.functions[usize(target)].isAsync) generator = asCell(this.createGenerator(callee, thisValue));
    this.enterFunction(target, returnDst, boundThis, argsBase, argc, constructThis);
    const top = usize(this.frameCount - 1);
    this.frames[top].env = env;
    this.frames[top].callee = callee;
    this.frames[top].generator = generator;
    return true;
  }

  // Push a construct call to a compiled function: an ordinary or base
  // class constructor gets a fresh object whose prototype comes from
  // `newTarget`; a derived constructor starts with `this` uninitialized
  // and receives its object from super().
  function enterConstruct(inout this, callee: Value, returnDst: u8, argsBase: u32, argc: u32, newTarget: Value): boolean {
    const code = this.heap.functionIndex(asCell(callee));
    let created = deletedValue();
    if (!this.functions[usize(code)].isDerived) {
      const proto = this.prototypeOf(asCell(newTarget));
      created = cellValue(this.heap.allocateObject(proto));
    }
    if (!this.enterCallable(callee, returnDst, created, argsBase, argc, created)) return false;
    this.frames[usize(this.frameCount - 1)].newTarget = newTarget;
    return true;
  }

  // super(...args) from a derived constructor's frame: construct the
  // parent with the frame's new.target and bind the result as `this`;
  // the compiler places the instance field initializers after the call.
  function superConstruct(inout this, frameIndex: usize, args: Array<Value>): Value {
    const callee = this.frames[frameIndex].callee;
    if (!isCell(callee) || asCell(callee) == 0) {
      const message: String = "'super' keyword unexpected here";
      const error = this.makeError(ERROR_KIND_SYNTAX, bytesOf(in message));
      this.raise(error);
      return undefinedValue();
    }
    const code = this.heap.functionIndex(asCell(callee));
    if (!this.functions[usize(code)].isDerived) {
      const message: String = "'super' keyword unexpected here";
      const error = this.makeError(ERROR_KIND_SYNTAX, bytesOf(in message));
      this.raise(error);
      return undefinedValue();
    }
    // GetSuperConstructor: the active function's [[Prototype]] now, so a
    // class re-parented with setPrototypeOf constructs its new parent.
    const parentHandle = this.functionProtoOf(asCell(callee));
    const parent = parentHandle == 0 ? nullValue() : cellValue(parentHandle);
    if (!this.isConstructorValue(parent)) {
      const message: String = "Super constructor is not a constructor";
      const error = this.typeError(in message);
      this.raise(error);
      return undefinedValue();
    }
    const newTarget = this.frames[frameIndex].newTarget;
    const result = this.constructValue(parent, move args, newTarget);
    if (this.pendingThrow) return undefinedValue();
    // The parent runs first; binding `this` a second time is the error.
    if (!isDeleted(this.frames[frameIndex].constructThis)) {
      const message: String = "Super constructor may only be called once";
      const error = this.makeError(ERROR_KIND_REFERENCE, bytesOf(in message));
      this.raise(error);
      return undefinedValue();
    }
    this.frames[frameIndex].constructThis = result;
    this.hostThis = result;
    const thisReg = this.functions[usize(code)].thisReg;
    const regsBase = this.frames[frameIndex].regsBase;
    if (thisReg >= 0) this.setReg(regsBase, u8(thisReg), result);
    return result;
  }

  // The name a method gets from its property key: a symbol's description
  // in brackets, otherwise the key's string form; accessors prefixed.
  function setFunctionNameFromKey(inout this, fn: Value, key: Value, prefix: u32): void {
    if (!isCell(fn) || asCell(fn) == 0) return;
    let name = Array<u8>();
    if (prefix == 1) {
      const getPrefix: String = "get ";
      name = bytesOf(in getPrefix);
    } else if (prefix == 2) {
      const setPrefix: String = "set ";
      name = bytesOf(in setPrefix);
    }
    if (this.isSymbolValue(key)) {
      const description = this.heap.slot(asCell(key), 0);
      const isPrivate = (this.heap.flagsOf(asCell(key)) & FLAG_PRIVATE_NAME) != 0;
      if (this.isStringValue(description)) {
        if (!isPrivate) name.push(91);
        appendBytes(inout name, this.heap.stringUtf8(asCell(description)));
        if (!isPrivate) name.push(93);
      }
    } else {
      const text = this.toStringValue(key);
      if (this.pendingThrow) return;
      appendBytes(inout name, this.heap.stringUtf8(asCell(text)));
    }
    const atomName = this.atomName;
    this.defineOwnAttr(asCell(fn), atomName, this.newStringUtf8(move name), PROP_CONFIGURABLE);
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
    this.frames[top].argsBase = argsBase;
    this.frames[top].argc = argc;
    const thisReg = this.functions[usize(target)].thisReg;
    if (thisReg >= 0) this.setReg(calleeBase, u8(thisReg), thisValue);
  }

  function pushTry(inout this, catchIp: usize, catchReg: u8): void {
    const env = this.frames[usize(this.frameCount - 1)].env;
    this.pushTryEnv(catchIp, catchReg, env);
  }

  function pushTryEnv(inout this, catchIp: usize, catchReg: u8, env: u32): void {
    const frame = TryFrame({ frameIndex: this.frameCount - 1, catchIp: catchIp, catchReg: catchReg, env: env });
    if (usize(this.tryDepth) < this.tryStack.length) {
      this.tryStack[usize(this.tryDepth)] = frame;
    } else {
      this.tryStack.push(frame);
    }
    this.tryDepth = this.tryDepth + 1;
  }

  // Register access: a window lies within the stack and is at most 256
  // wide, so the sum cannot overflow and wraps rather than checks.
  function reg(base: u32, index: u8): Value {
    return this.regStack[usize(base.wrappingAdd(u32(index)))];
  }

  function setReg(inout this, base: u32, index: u8, value: Value): void {
    this.regStack[usize(base.wrappingAdd(u32(index)))] = value;
  }

  // --- Template objects ---

  // The template object of a tagged template site: the cooked strings
  // as a frozen array with a frozen `raw` array of the raw strings.
  // Built once at compile time, so every evaluation of the site gets
  // the same object.
  function newTemplateObject(inout this, cooked: Array<Value>, raw: Array<Value>): Value {
    const count = u32(cooked.length);
    const rawArray = this.heap.allocateArray(count);
    this.pushTempRoot(cellValue(rawArray));
    const cookedArray = this.heap.allocateArray(count);
    this.pushTempRoot(cellValue(cookedArray));
    let index: u32 = 0;
    while (index < count) {
      const rawValue = raw[usize(index)];
      this.heap.setSlot(rawArray, index, rawValue);
      this.heap.setAttr(rawArray, index, PROP_ENUMERABLE);
      const cookedValue = cooked[usize(index)];
      this.heap.setSlot(cookedArray, index, cookedValue);
      this.heap.setAttr(cookedArray, index, PROP_ENUMERABLE);
      index = index + 1;
    }
    this.heap.setFlags(rawArray, FLAG_NON_EXTENSIBLE | FLAG_LENGTH_READONLY);
    const rawText: String = "raw";
    const rawAtom = this.atomOf(in rawText);
    const bag = this.arrayBag(cookedArray);
    this.heap.objectDefine(bag, rawAtom, cellValue(rawArray), PROP_NONE);
    this.heap.setFlags(cookedArray, FLAG_NON_EXTENSIBLE | FLAG_LENGTH_READONLY);
    this.popTempRoot();
    this.popTempRoot();
    return cellValue(cookedArray);
  }

  // --- Promises and jobs ---
  //
  // A promise is an ordinary object holding a record under a hidden key:
  // [state, result, reactions, handled]. `reactions` is undefined while
  // nothing waits, the one reaction while one does, and an array of them
  // from the second on; settling empties it. A reaction is [kind,
  // onFulfilled, onRejected, destination, generator]: kind 0 runs the
  // handler for the outcome and settles the destination with its result;
  // the other kinds resume an async body. A job is four values in the
  // queue the host drains after each script -- kind, a, b, c -- and not
  // a cell: a job that has run leaves nothing behind.
  //
  // A destination is one of three things. A promise the engine made for
  // itself (await, async bodies, a `then` whose species is the intrinsic
  // constructor) is settled directly: nothing the program can see stands
  // between the reaction and that record. A capability made through a
  // constructor the program chose is the array [promise, resolve,
  // reject], and only its two functions are ever called; its promise may
  // be any object at all. Undefined means nobody is waiting.

  function isPromise(value: Value): boolean {
    if (!isCell(value) || asCell(value) == 0 || !this.heap.isObject(asCell(value))) return false;
    return this.heap.objectFindSlot(asCell(value), this.atomPromiseRecord) >= 0;
  }

  function promiseRecord(handle: u32): u32 {
    const slot = this.heap.objectFindSlot(handle, this.atomPromiseRecord);
    return asCell(this.heap.slot(handle, u32(slot)));
  }

  function newPromise(inout this): Value {
    const promiseProto = this.promiseProto;
    return this.newPromiseWithProto(promiseProto);
  }

  function newPromiseWithProto(inout this, proto: u32): Value {
    const object = this.heap.allocateObject(proto);
    this.pushTempRoot(cellValue(object));
    const record = this.heap.allocateArray(4);
    this.heap.setSlot(record, 0, int32Value(PROMISE_PENDING));
    this.heap.setSlot(record, 1, undefinedValue());
    this.heap.setSlot(record, 2, undefinedValue());
    this.heap.setSlot(record, 3, booleanValue(false));
    const atomPromiseRecord = this.atomPromiseRecord;
    this.heap.objectDefine(object, atomPromiseRecord, cellValue(record), PROP_NONE);
    this.popTempRoot();
    return cellValue(object);
  }

  function promiseState(handle: u32): i32 {
    return asInt32(this.heap.slot(this.promiseRecord(handle), 0));
  }

  function promiseResult(handle: u32): Value {
    return this.heap.slot(this.promiseRecord(handle), 1);
  }

  function enqueueJob(inout this, kind: i32, a: Value, b: Value, c: Value): void {
    this.jobs.push(int32Value(kind));
    this.jobs.push(a);
    this.jobs.push(b);
    this.jobs.push(c);
  }

  function settlePromise(inout this, handle: u32, state: i32, value: Value): void {
    const record = this.promiseRecord(handle);
    if (asInt32(this.heap.slot(record, 0)) != PROMISE_PENDING) return;
    this.heap.setSlot(record, 0, int32Value(state));
    this.heap.setSlot(record, 1, value);
    const waiting = this.heap.slot(record, 2);
    this.heap.setSlot(record, 2, undefinedValue());
    if (isUndefined(waiting)) return;
    const rejected = booleanValue(state == PROMISE_REJECTED);
    if (this.isReactionCell(asCell(waiting))) {
      this.enqueueJob(JOB_REACTION, waiting, value, rejected);
      return;
    }
    const count = this.heap.arrayLength(asCell(waiting));
    let index: u32 = 0;
    while (index < count) {
      const reaction = this.heap.arrayGet(asCell(waiting), index);
      this.enqueueJob(JOB_REACTION, reaction, value, rejected);
      index = index + 1;
    }
  }

  // A reaction's first slot is its kind, a number; a list of reactions
  // holds cells only.
  function isReactionCell(handle: u32): boolean {
    return isInt32(this.heap.slot(handle, 0));
  }

  function fulfillPromise(inout this, handle: u32, value: Value): void {
    this.settlePromise(handle, PROMISE_FULFILLED, value);
  }

  function rejectPromise(inout this, handle: u32, reason: Value): void {
    this.settlePromise(handle, PROMISE_REJECTED, reason);
  }

  // The promise resolve function's work: a thenable is followed through
  // a job, anything else fulfills.
  function resolvePromise(inout this, handle: u32, resolution: Value): void {
    if (isCell(resolution) && asCell(resolution) == handle) {
      const message: String = "Chaining cycle detected for promise";
      const error = this.typeError(in message);
      this.rejectPromise(handle, error);
      return;
    }
    if (!this.isObjectLike(resolution)) {
      this.fulfillPromise(handle, resolution);
      return;
    }
    const thenKey = cellValue(this.atomThen);
    const then = this.getProperty(resolution, thenKey);
    if (this.pendingThrow) {
      const thrown = this.takePending();
      this.rejectPromise(handle, thrown);
      return;
    }
    if (!this.isCallable(then)) {
      this.fulfillPromise(handle, resolution);
      return;
    }
    this.enqueueJob(JOB_THENABLE, resolution, then, cellValue(handle));
  }

  function newReaction(inout this, kind: i32, onFulfilled: Value, onRejected: Value, destination: Value, gen: u32): Value {
    const reaction = this.heap.allocateArray(5);
    this.heap.setSlot(reaction, 0, int32Value(kind));
    this.heap.setSlot(reaction, 1, onFulfilled);
    this.heap.setSlot(reaction, 2, onRejected);
    this.heap.setSlot(reaction, 3, destination);
    // The generator a driver reaction resumes, as a cell so the
    // collector keeps a suspended body alive through its pending promise.
    if (gen == 0) {
      this.heap.setSlot(reaction, 4, int32Value(0));
    } else {
      this.heap.setSlot(reaction, 4, cellValue(gen));
    }
    return cellValue(reaction);
  }

  // PerformPromiseThen: one reaction carrying the handler for each
  // outcome.
  function performThen(inout this, handle: u32, onFulfilled: Value, onRejected: Value, derived: Value): void {
    const reaction = this.newReaction(REACTION_HANDLER, onFulfilled, onRejected, derived, 0);
    this.attachReaction(handle, reaction);
  }

  // A pending promise keeps the reaction -- alone, or in a list from the
  // second on; a settled one queues its job at once.
  function attachReaction(inout this, handle: u32, reaction: Value): void {
    const record = this.promiseRecord(handle);
    const state = asInt32(this.heap.slot(record, 0));
    if (state == PROMISE_PENDING) {
      const waiting = this.heap.slot(record, 2);
      if (isUndefined(waiting)) {
        this.heap.setSlot(record, 2, reaction);
      } else if (this.isReactionCell(asCell(waiting))) {
        const list = this.heap.allocateArray(0);
        this.heap.arraySet(list, 0, waiting);
        this.heap.arraySet(list, 1, reaction);
        this.heap.setSlot(record, 2, cellValue(list));
      } else {
        const list = asCell(waiting);
        this.heap.arraySet(list, this.heap.arrayLength(list), reaction);
      }
    } else {
      const result = this.heap.slot(record, 1);
      this.enqueueJob(JOB_REACTION, reaction, result, booleanValue(state == PROMISE_REJECTED));
    }
    this.heap.setSlot(record, 3, booleanValue(true));
  }

  // PromiseResolve(%Promise%, value): a promise whose `constructor` is
  // the intrinsic one as-is, anything else wrapped in a new promise. The
  // `constructor` read is the program's to observe, and its throw is
  // left pending.
  function promiseResolveValue(inout this, value: Value): Value {
    if (this.isPromise(value)) {
      const atomConstructor = this.atomConstructor;
      this.pushTempRoot(value);
      const held = this.getProperty(value, cellValue(atomConstructor));
      this.popTempRoot();
      if (this.pendingThrow) return undefinedValue();
      if (isCell(held) && asCell(held) == this.promiseCtor) return value;
    }
    const promise = this.newPromise();
    this.pushTempRoot(promise);
    this.resolvePromise(asCell(promise), value);
    this.popTempRoot();
    return promise;
  }

  // Whether Promise[Symbol.species] is still the accessor the engine
  // installed, with its getter.
  function promiseSpeciesPristine(inout this): boolean {
    const bag = this.functionBag(this.promiseCtor);
    if (bag == 0) return false;
    const symbolSpecies = this.symbolSpecies;
    const key = this.propertyKey(symbolSpecies);
    const slot = this.heap.objectFindSlot(bag, key);
    if (slot < 0) return false;
    if ((this.heap.attrOf(bag, u32(slot)) & PROP_ACCESSOR) == 0) return false;
    const accessor = this.heap.slot(bag, u32(slot));
    if (!isCell(accessor) || asCell(accessor) == 0) return false;
    const getter = this.heap.slot(asCell(accessor), 0);
    return isCell(getter) && asCell(getter) == this.promiseSpeciesGetter;
  }

  // SpeciesConstructor(promise, %Promise%). The `constructor` read is
  // always made. When it yields the intrinsic constructor and that
  // constructor's species accessor is untouched, the answer is the
  // intrinsic constructor and the getter call is skipped: the builtin
  // getter only returns its receiver, so the call is not observable.
  function promiseSpeciesConstructor(inout this, promise: Value): Value {
    const atomConstructor = this.atomConstructor;
    const ctor = this.getProperty(promise, cellValue(atomConstructor));
    if (this.pendingThrow) return undefinedValue();
    if (isCell(ctor) && asCell(ctor) == this.promiseCtor && this.promiseSpeciesPristine()) return ctor;
    const intrinsic = cellValue(this.promiseCtor);
    return this.speciesFromConstructor(ctor, intrinsic);
  }

  // SpeciesConstructor(object, default): every read is observable, and
  // a throw is left pending.
  function speciesConstructor(inout this, object: Value, defaultCtor: Value): Value {
    const atomConstructor = this.atomConstructor;
    const ctor = this.getProperty(object, cellValue(atomConstructor));
    if (this.pendingThrow) return undefinedValue();
    return this.speciesFromConstructor(ctor, defaultCtor);
  }

  // The rest of SpeciesConstructor, from the `constructor` value read.
  function speciesFromConstructor(inout this, ctor: Value, defaultCtor: Value): Value {
    if (isUndefined(ctor)) return defaultCtor;
    if (!this.isObjectLike(ctor)) {
      const message: String = "object.constructor is not an object";
      const error = this.typeError(in message);
      this.raise(error);
      return undefinedValue();
    }
    const symbolSpecies = this.symbolSpecies;
    const species = this.getProperty(ctor, symbolSpecies);
    if (this.pendingThrow) return undefinedValue();
    if (isUndefined(species) || isNull(species)) return defaultCtor;
    if (this.isConstructorValue(species)) return species;
    const message: String = "object.constructor[Symbol.species] is not a constructor";
    const error = this.typeError(in message);
    this.raise(error);
    return undefinedValue();
  }

  // Settle a reaction's destination (see the note above): directly for
  // an engine promise, through the capability's own function otherwise.
  // A throw from that function is left pending for the job to drop.
  function settleDestination(inout this, destination: Value, value: Value, isReject: boolean): void {
    if (!isCell(destination) || asCell(destination) == 0) return;
    const handle = asCell(destination);
    if (this.heap.isObject(handle)) {
      if (isReject) {
        this.rejectPromise(handle, value);
      } else {
        this.resolvePromise(handle, value);
      }
      return;
    }
    const settle = this.heap.slot(handle, isReject ? 2 : 1);
    const ignored = this.callValue1(settle, undefinedValue(), value);
  }

  // The resolve / reject function pair for a promise, sharing an
  // "already resolved" record: [promise, resolved].
  function resolvingFunction(inout this, promise: Value, shared: Value, isReject: boolean): Value {
    const fn = this.newSharedHost(isReject ? HOST_PROMISE_REJECT : HOST_PROMISE_RESOLVE, shared, 1);
    return cellValue(fn);
  }

  function newResolvingShared(inout this, promise: Value): Value {
    const shared = this.heap.allocateArray(2);
    this.heap.setSlot(shared, 0, promise);
    this.heap.setSlot(shared, 1, booleanValue(false));
    return cellValue(shared);
  }

  // Run every queued job, including those queued while running. A job
  // that has run keeps nothing alive: its queue slot is cleared as it is
  // taken, the job is held for its own run only, and the drained front
  // of a long queue is dropped, so a program that settles promises
  // forever runs in bounded memory.
  function runJobs(inout this): void {
    while (this.jobCursor < this.jobs.length) {
      const at = this.jobCursor;
      const kind = asInt32(this.jobs[at]);
      const first = this.jobs[at + 1];
      const second = this.jobs[at + 2];
      const third = this.jobs[at + 3];
      this.jobs[at + 1] = undefinedValue();
      this.jobs[at + 2] = undefinedValue();
      this.jobs[at + 3] = undefinedValue();
      this.jobCursor = at + 4;
      if (this.jobCursor >= JOB_COMPACT_AT && this.jobCursor * 2 >= this.jobs.length) this.compactJobs();
      // The job's values are held for its own run only.
      this.pushTempRoot(first);
      this.pushTempRoot(second);
      this.pushTempRoot(third);
      if (kind == JOB_REACTION) {
        this.runReaction(asCell(first), second, isTrue(third));
      } else {
        const thenable = first;
        const then = second;
        const promise = third;
        const shared = this.newResolvingShared(promise);
        this.pushTempRoot(shared);
        const resolve = this.resolvingFunction(promise, shared, false);
        this.pushTempRoot(resolve);
        const reject = this.resolvingFunction(promise, shared, true);
        this.pushTempRoot(reject);
        this.callValue2(then, thenable, resolve, reject);
        if (this.pendingThrow) {
          const thrown = this.takePending();
          if (!isTrue(this.heap.slot(asCell(shared), 1))) {
            this.heap.setSlot(asCell(shared), 1, booleanValue(true));
            this.rejectPromise(asCell(promise), thrown);
          }
        }
        this.popTempRoot();
        this.popTempRoot();
        this.popTempRoot();
      }
      if (this.pendingThrow) { const dropped = this.takePending(); }
      this.popTempRoot();
      this.popTempRoot();
      this.popTempRoot();
    }
    this.jobs = Array<Value>();
    this.jobCursor = 0;
  }

  function compactJobs(inout this): void {
    // Room to refill to the next compaction without growing again.
    let rest = Array<Value>.withCapacity(this.jobs.length - this.jobCursor + JOB_COMPACT_AT * 2);
    let index = this.jobCursor;
    while (index < this.jobs.length) {
      rest.push(this.jobs[index]);
      index = index + 1;
    }
    this.jobs = move rest;
    this.jobCursor = 0;
  }

  function runReaction(inout this, reaction: u32, argument: Value, isReject: boolean): void {
    const kind = asInt32(this.heap.slot(reaction, 0));
    if (kind == REACTION_ASYNC) {
      const gen = asCell(this.heap.slot(reaction, 4));
      this.asyncStep(gen, argument, isReject ? 1 : 0);
      return;
    }
    if (kind == REACTION_ASYNC_GEN_AWAIT) {
      const gen = asCell(this.heap.slot(reaction, 4));
      this.asyncGeneratorStep(gen, argument, isReject ? 1 : 0);
      return;
    }
    if (kind == REACTION_ASYNC_GEN_RETURN_DONE) {
      // AsyncGeneratorAwaitReturn settled: the front request gets the
      // awaited value as its done result, or the rejection.
      const gen = asCell(this.heap.slot(reaction, 4));
      const record = this.generatorRecord(gen);
      this.heap.setSlot(record, 0, int32Value(GEN_COMPLETED));
      const request = this.asyncGeneratorFront(record);
      if (request != 0) {
        const promise = this.heap.slot(request, 2);
        if (isReject) {
          this.rejectPromise(asCell(promise), argument);
        } else {
          this.pushTempRoot(argument);
          const produced = this.createIterResult(argument, true);
          this.popTempRoot();
          this.resolvePromise(asCell(promise), produced);
        }
        this.asyncGeneratorPop(record);
      }
      this.asyncGeneratorResumeNext(gen);
      return;
    }
    if (kind == REACTION_ASYNC_GEN_RESUME_RETURN) {
      // The value of a return request into a suspended body settled:
      // the body resumes in return mode with it, or in throw mode with
      // the rejection.
      const gen = asCell(this.heap.slot(reaction, 4));
      this.asyncGeneratorStep(gen, argument, isReject ? 1 : 2);
      return;
    }
    if (kind == REACTION_ASYNC_GEN_YIELD) {
      // The yielded value settled: a fulfillment answers the request, a
      // rejection is thrown into the body at the yield.
      const gen = asCell(this.heap.slot(reaction, 4));
      if (isReject) {
        this.asyncGeneratorStep(gen, argument, 1);
        return;
      }
      const record = this.generatorRecord(gen);
      this.heap.setSlot(record, 0, int32Value(GEN_YIELDED));
      const request = this.asyncGeneratorFront(record);
      if (request != 0) {
        const promise = this.heap.slot(request, 2);
        this.pushTempRoot(argument);
        const produced = this.createIterResult(argument, false);
        this.popTempRoot();
        this.resolvePromise(asCell(promise), produced);
        this.asyncGeneratorPop(record);
      }
      this.asyncGeneratorResumeNext(gen);
      return;
    }
    const handler = this.heap.slot(reaction, isReject ? 2 : 1);
    const destination = this.heap.slot(reaction, 3);
    if (!this.isCallable(handler)) {
      // No handler: the outcome passes through to the destination.
      this.settleDestination(destination, argument, isReject);
      return;
    }
    const produced = this.callValue1(handler, undefinedValue(), argument);
    if (this.pendingThrow) {
      const thrown = this.takePending();
      this.settleDestination(destination, thrown, true);
      return;
    }
    this.settleDestination(destination, produced, false);
  }

  // Drive an async function: resume its body; a completed body settles
  // the promise, an await parks the continuation on the awaited value.
  function asyncStep(inout this, gen: u32, sent: Value, mode: u32): void {
    const record = this.generatorRecord(gen);
    const promise = this.heap.slot(record, 3);
    const outcome = this.generatorResume(gen, sent, mode);
    if (this.pendingThrow) {
      const thrown = this.takePending();
      this.rejectPromise(asCell(promise), thrown);
      return;
    }
    const value = outcome;
    if (this.resumeDone) {
      this.resolvePromise(asCell(promise), value);
      return;
    }
    // The `constructor` read may run the program: the body is between
    // its frame and its reaction here, so it is held explicitly.
    this.pushTempRoot(cellValue(gen));
    this.pushTempRoot(value);
    const awaited = this.promiseResolveValue(value);
    this.popTempRoot();
    this.popTempRoot();
    if (this.pendingThrow) {
      // The awaited promise's `constructor` read threw: the await throws.
      const thrown = this.takePending();
      this.asyncStep(gen, thrown, 1);
      return;
    }
    this.pushTempRoot(awaited);
    const reaction = this.newReaction(REACTION_ASYNC, undefinedValue(), undefinedValue(), undefinedValue(), gen);
    this.attachReaction(asCell(awaited), reaction);
    this.popTempRoot();
  }

  // --- Async generators ---
  //
  // Requests (next / return / throw, each with its promise) queue on
  // the generator record; the front one drives the body. A yield awaits
  // its value and then answers the front request; an await parks the
  // body; completion or a throw answers the front request and settles
  // the rest as done.

  function isAsyncGeneratorObject(value: Value): boolean {
    if (!this.isGeneratorObject(value)) return false;
    const record = this.generatorRecord(asCell(value));
    return !isUndefined(this.heap.slot(record, 10));
  }

  function asyncGeneratorFront(record: u32): u32 {
    const queue = asCell(this.heap.slot(record, 10));
    const cursor = u32(asInt32(this.heap.slot(record, 11)));
    if (cursor >= this.heap.arrayLength(queue)) return 0;
    return asCell(this.heap.slot(queue, cursor));
  }

  function asyncGeneratorPop(inout this, record: u32): void {
    const queue = asCell(this.heap.slot(record, 10));
    const cursor = u32(asInt32(this.heap.slot(record, 11))) + 1;
    if (cursor >= this.heap.arrayLength(queue)) {
      this.heap.setSlot(record, 10, cellValue(this.heap.allocateArray(0)));
      this.heap.setSlot(record, 11, int32Value(0));
    } else {
      this.heap.setSlot(record, 11, int32Value(i32(cursor)));
    }
  }

  // AsyncGeneratorEnqueue: the promise for one next / return / throw.
  function asyncGeneratorEnqueue(inout this, gen: u32, mode: u32, value: Value): Value {
    const promise = this.newPromise();
    this.pushTempRoot(promise);
    const record = this.generatorRecord(gen);
    const request = this.heap.allocateArray(3);
    this.heap.setSlot(request, 0, int32Value(i32(mode)));
    this.heap.setSlot(request, 1, value);
    this.heap.setSlot(request, 2, promise);
    const queue = asCell(this.heap.slot(record, 10));
    this.heap.arraySet(queue, this.heap.arrayLength(queue), cellValue(request));
    const state = asInt32(this.heap.slot(record, 0));
    if (state != GEN_RUNNING && state != GEN_AWAITING && state != GEN_AWAITING_RETURN) this.asyncGeneratorResumeNext(gen);
    this.popTempRoot();
    return promise;
  }

  // AsyncGeneratorAwaitReturn: a return request on a generator that is
  // not running awaits its value, then settles the request with it.
  function asyncGeneratorAwaitReturn(inout this, gen: u32, record: u32, value: Value): void {
    this.heap.setSlot(record, 0, int32Value(GEN_AWAITING_RETURN));
    // The `constructor` read may run the program: the body is between
    // its frame and its reaction here, so it is held explicitly.
    this.pushTempRoot(cellValue(gen));
    this.pushTempRoot(value);
    const awaited = this.promiseResolveValue(value);
    this.popTempRoot();
    this.popTempRoot();
    if (this.pendingThrow) {
      // The value's `constructor` read threw: the request is rejected.
      const thrown = this.takePending();
      this.heap.setSlot(record, 0, int32Value(GEN_COMPLETED));
      const request = this.asyncGeneratorFront(record);
      if (request != 0) {
        const promise = this.heap.slot(request, 2);
        this.rejectPromise(asCell(promise), thrown);
        this.asyncGeneratorPop(record);
      }
      this.asyncGeneratorResumeNext(gen);
      return;
    }
    this.pushTempRoot(awaited);
    const reaction = this.newReaction(REACTION_ASYNC_GEN_RETURN_DONE, undefinedValue(), undefinedValue(), undefinedValue(), gen);
    this.attachReaction(asCell(awaited), reaction);
    this.popTempRoot();
  }

  // AsyncGeneratorUnwrapYieldResumption: a return request into a body
  // suspended at a yield awaits its value first; the body then resumes
  // in return mode with it (or in throw mode with the rejection).
  function asyncGeneratorAwaitResumeReturn(inout this, gen: u32, record: u32, value: Value): void {
    this.heap.setSlot(record, 0, int32Value(GEN_AWAITING));
    // The `constructor` read may run the program: the body is between
    // its frame and its reaction here, so it is held explicitly.
    this.pushTempRoot(cellValue(gen));
    this.pushTempRoot(value);
    const awaited = this.promiseResolveValue(value);
    this.popTempRoot();
    this.popTempRoot();
    if (this.pendingThrow) {
      const thrown = this.takePending();
      this.asyncGeneratorStep(gen, thrown, 1);
      return;
    }
    this.pushTempRoot(awaited);
    const reaction = this.newReaction(REACTION_ASYNC_GEN_RESUME_RETURN, undefinedValue(), undefinedValue(), undefinedValue(), gen);
    this.attachReaction(asCell(awaited), reaction);
    this.popTempRoot();
  }

  // Answer requests that need no body run; start the body for one that does.
  function asyncGeneratorResumeNext(inout this, gen: u32): void {
    while (true) {
      const record = this.generatorRecord(gen);
      const request = this.asyncGeneratorFront(record);
      if (request == 0) return;
      const state = asInt32(this.heap.slot(record, 0));
      const unstarted = asInt32(this.heap.slot(record, 9)) == 4;
      const mode = u32(asInt32(this.heap.slot(request, 0)));
      const value = this.heap.slot(request, 1);
      const promise = this.heap.slot(request, 2);
      if (state == GEN_COMPLETED || (unstarted && mode != 0)) {
        this.heap.setSlot(record, 0, int32Value(GEN_COMPLETED));
        if (mode == 2) {
          // The value is awaited before the request settles.
          this.asyncGeneratorAwaitReturn(gen, record, value);
          return;
        }
        if (mode == 1) {
          this.rejectPromise(asCell(promise), value);
        } else {
          const produced = this.createIterResult(undefinedValue(), true);
          this.resolvePromise(asCell(promise), produced);
        }
        this.asyncGeneratorPop(record);
        continue;
      }
      if (mode == 2) {
        // Into a suspended body: the value is awaited, then the body
        // returns it through its finally blocks.
        this.asyncGeneratorAwaitResumeReturn(gen, record, value);
        return;
      }
      this.asyncGeneratorStep(gen, value, mode);
      return;
    }
  }

  // Run the body from where it stopped and act on how it stops.
  function asyncGeneratorStep(inout this, gen: u32, sent: Value, mode: u32): void {
    const outcome = this.generatorResume(gen, sent, mode);
    const record = this.generatorRecord(gen);
    if (this.pendingThrow) {
      const thrown = this.takePending();
      this.heap.setSlot(record, 0, int32Value(GEN_COMPLETED));
      const request = this.asyncGeneratorFront(record);
      if (request != 0) {
        const promise = this.heap.slot(request, 2);
        this.rejectPromise(asCell(promise), thrown);
        this.asyncGeneratorPop(record);
      }
      this.asyncGeneratorResumeNext(gen);
      return;
    }
    const value = outcome;
    if (this.resumeDone) {
      this.heap.setSlot(record, 0, int32Value(GEN_COMPLETED));
      const request = this.asyncGeneratorFront(record);
      if (request != 0) {
        const promise = this.heap.slot(request, 2);
        this.pushTempRoot(value);
        const produced = this.createIterResult(value, true);
        this.popTempRoot();
        this.resolvePromise(asCell(promise), produced);
        this.asyncGeneratorPop(record);
      }
      this.asyncGeneratorResumeNext(gen);
      return;
    }
    const kind = asInt32(this.heap.slot(record, 9));
    if (kind == 2 || kind == 5) {
      // A delegated value answers the request as it is.
      const request = this.asyncGeneratorFront(record);
      if (request != 0) {
        const promise = this.heap.slot(request, 2);
        this.pushTempRoot(value);
        const produced = this.createIterResult(value, false);
        this.popTempRoot();
        this.resolvePromise(asCell(promise), produced);
        this.asyncGeneratorPop(record);
      }
      this.asyncGeneratorResumeNext(gen);
      return;
    }
    // A yield awaits its value before answering; nothing else resumes
    // the body meanwhile.
    if (kind == 0) this.heap.setSlot(record, 0, int32Value(GEN_AWAITING));
    // The `constructor` read may run the program: the body is between
    // its frame and its reaction here, so it is held explicitly.
    this.pushTempRoot(cellValue(gen));
    this.pushTempRoot(value);
    const awaited = this.promiseResolveValue(value);
    this.popTempRoot();
    this.popTempRoot();
    if (this.pendingThrow) {
      // The `constructor` read threw: the await or yield throws.
      const thrown = this.takePending();
      this.asyncGeneratorStep(gen, thrown, 1);
      return;
    }
    this.pushTempRoot(awaited);
    const reaction = this.newReaction(kind == 1 ? REACTION_ASYNC_GEN_AWAIT : REACTION_ASYNC_GEN_YIELD, undefinedValue(), undefinedValue(), undefinedValue(), gen);
    this.attachReaction(asCell(awaited), reaction);
    this.popTempRoot();
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
      const codeLength = usize(this.functions[usize(fi)].codeLength);
      const codeStart = usize(this.functions[usize(fi)].codeStart);
      let returned = false;
      let throwing = false;
      let thrown = undefinedValue();
      if (this.pendingThrow) {
        thrown = this.takePending();
        throwing = true;
      }
      while (ip < codeLength && !returned && !throwing) {
        const inst = this.codeSegment[codeStart.wrappingAdd(ip)];
        ip = ip.wrappingAdd(1);
        const op = inst.op;

        match (op) {
          loadInt => {
            this.setReg(base, inst.a, int32Value(bcI16(inst)));
          }
          loadConst => {
            const operand1 = this.functions[usize(fi)].constants[usize(bcU16(inst))];
            this.setReg(base, inst.a, operand1);
          }
          loadUndefined => {
            this.setReg(base, inst.a, undefinedValue());
          }
          loadNull => {
            this.setReg(base, inst.a, nullValue());
          }
          loadTrue => {
            this.setReg(base, inst.a, booleanValue(true));
          }
          loadFalse => {
            this.setReg(base, inst.a, booleanValue(false));
          }
          mov => {
            const operand2 = this.reg(base, inst.b);
            this.setReg(base, inst.a, operand2);
          }
          defineGlobal => {
            const slot = usize(bcU16(inst));
            this.globals[slot].value = this.reg(base, inst.a);
            this.globals[slot].defined = true;
          }
          storeGlobal => {
            const slot = usize(bcU16(inst));
            this.globals[slot].value = this.reg(base, inst.a);
            this.globals[slot].defined = true;
          }
          loadGlobal => {
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
                let message = this.heap.stringUtf8(atom);
                const notDefined: String = " is not defined";
                appendBytes(inout message, bytesOf(in notDefined));
                thrown = this.makeError(ERROR_KIND_REFERENCE, move message);
                throwing = true;
              }
            } else {
              const operand3 = this.globals[slot].value;
              this.setReg(base, inst.a, operand3);
            }
          }
          loadGlobalOrUndefined => {
            const slot = usize(bcU16(inst));
            const operand4 = this.globals[slot].defined ? this.globals[slot].value : undefinedValue();
            this.setReg(base, inst.a, operand4);
          }
          add => {
            const rawLeft = this.reg(base, inst.b);
            const rawRight = this.reg(base, inst.c);
            if (isNumber(rawLeft) && isNumber(rawRight)) {
              const sum = numericAdd(rawLeft, rawRight);
              this.setReg(base, inst.a, sum);
            } else {
              const left = this.toPrimitiveWithHint(rawLeft, HINT_DEFAULT);
              const right = this.toPrimitiveWithHint(rawRight, HINT_DEFAULT);
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
                if (this.pendingThrow) {
                  thrown = this.takePending();
                  throwing = true;
                } else {
                  const sum = numericAdd(leftNumber, rightNumber);
                  this.setReg(base, inst.a, sum);
                }
              }
            }
          }
          cmpLt => {
            const operandB = this.reg(base, inst.b);
            const operandC = this.reg(base, inst.c);
            const outcome = this.lessThan(operandB, operandC, false);
            this.setReg(base, inst.a, booleanValue(outcome));
          }
          cmpLe => {
            const operandB = this.reg(base, inst.b);
            const operandC = this.reg(base, inst.c);
            const outcome = this.lessThan(operandB, operandC, true);
            this.setReg(base, inst.a, booleanValue(outcome));
          }
          cmpGt => {
            const operandC = this.reg(base, inst.c);
            const operandB = this.reg(base, inst.b);
            const outcome = this.lessThan(operandC, operandB, false);
            this.setReg(base, inst.a, booleanValue(outcome));
          }
          cmpGe => {
            const operandC = this.reg(base, inst.c);
            const operandB = this.reg(base, inst.b);
            const outcome = this.lessThan(operandC, operandB, true);
            this.setReg(base, inst.a, booleanValue(outcome));
          }
          jmp => {
            const offset = bcI16(inst);
            ip = usize(i64(ip) + i64(offset));
            // A loop's back edge is a safe point too, so a program that
            // allocates without calling collects all the same.
            if (offset < 0 && this.heap.shouldCollect()) {
              this.frames[frameIndex].ip = ip;
              this.collectGarbage();
            }
          }
          jmpIfTrue => {
            const operandA = this.reg(base, inst.a);
            if (this.toBooleanValue(operandA)) ip = usize(i64(ip) + i64(bcI16(inst)));
          }
          jmpIfFalse => {
            const operandA = this.reg(base, inst.a);
            if (!this.toBooleanValue(operandA)) ip = usize(i64(ip) + i64(bcI16(inst)));
          }
          jmpIfNotNullish => {
            const tested = this.reg(base, inst.a);
            if (!(isNull(tested) || isUndefined(tested))) ip = usize(i64(ip) + i64(bcI16(inst)));
          }
          jmpIfNullish => {
            const tested = this.reg(base, inst.a);
            if (isNull(tested) || isUndefined(tested)) ip = usize(i64(ip) + i64(bcI16(inst)));
          }
          sub => {
            const rawB = this.reg(base, inst.b);
            const numberB = this.numericOperand(rawB);
            const rawC = this.reg(base, inst.c);
            const numberC = this.numericOperand(rawC);
            const operand5 = numericSub(numberB, numberC);
            this.setReg(base, inst.a, operand5);
          }
          mul => {
            const rawB = this.reg(base, inst.b);
            const numberB = this.numericOperand(rawB);
            const rawC = this.reg(base, inst.c);
            const numberC = this.numericOperand(rawC);
            const operand6 = numericMul(numberB, numberC);
            this.setReg(base, inst.a, operand6);
          }
          div => {
            const rawB = this.reg(base, inst.b);
            const numberB = this.numericOperand(rawB);
            const rawC = this.reg(base, inst.c);
            const numberC = this.numericOperand(rawC);
            const operand7 = numericDiv(numberB, numberC);
            this.setReg(base, inst.a, operand7);
          }
          mod => {
            const rawB = this.reg(base, inst.b);
            const numberB = this.numericOperand(rawB);
            const rawC = this.reg(base, inst.c);
            const numberC = this.numericOperand(rawC);
            const operand8 = numericMod(numberB, numberC);
            this.setReg(base, inst.a, operand8);
          }
          pow => {
            const operand9 = doubleValue(nativePow(toNumber(this.reg(base, inst.b)), toNumber(this.reg(base, inst.c))));
            this.setReg(base, inst.a, operand9);
          }
          neg => {
            const rawB = this.reg(base, inst.b);
            const numberB = this.numericOperand(rawB);
            const operand10 = numericNeg(numberB);
            this.setReg(base, inst.a, operand10);
          }
          logicalNot => {
            const operandB = this.reg(base, inst.b);
            const negated = booleanValue(!this.toBooleanValue(operandB));
            this.setReg(base, inst.a, negated);
          }
          bitNot => {
            const rawB = this.reg(base, inst.b);
            const numberB = this.numericOperand(rawB);
            const operand12 = int32Value(~toInt32(numberB));
            this.setReg(base, inst.a, operand12);
          }
          bitAnd => {
            const rawB = this.reg(base, inst.b);
            const numberB = this.numericOperand(rawB);
            const rawC = this.reg(base, inst.c);
            const numberC = this.numericOperand(rawC);
            const operand13 = int32Value(toInt32(numberB) & toInt32(numberC));
            this.setReg(base, inst.a, operand13);
          }
          bitOr => {
            const rawB = this.reg(base, inst.b);
            const numberB = this.numericOperand(rawB);
            const rawC = this.reg(base, inst.c);
            const numberC = this.numericOperand(rawC);
            const operand14 = int32Value(toInt32(numberB) | toInt32(numberC));
            this.setReg(base, inst.a, operand14);
          }
          bitXor => {
            const rawB = this.reg(base, inst.b);
            const numberB = this.numericOperand(rawB);
            const rawC = this.reg(base, inst.c);
            const numberC = this.numericOperand(rawC);
            const operand15 = int32Value(toInt32(numberB) ^ toInt32(numberC));
            this.setReg(base, inst.a, operand15);
          }
          shl => {
            const rawC = this.reg(base, inst.c);
            const numberC = this.numericOperand(rawC);
            const shift = u32(toUint32(numberC) & 31);
            const rawB = this.reg(base, inst.b);
            const numberB = this.numericOperand(rawB);
            const operand16 = int32Value(i32.fromBits(shiftLeft32(toInt32(numberB).toBits(), shift)));
            this.setReg(base, inst.a, operand16);
          }
          shr => {
            const rawC = this.reg(base, inst.c);
            const numberC = this.numericOperand(rawC);
            const shift = u32(toUint32(numberC) & 31);
            const rawB = this.reg(base, inst.b);
            const numberB = this.numericOperand(rawB);
            const operand17 = int32Value(toInt32(numberB) >> i32(shift));
            this.setReg(base, inst.a, operand17);
          }
          uShr => {
            const rawC = this.reg(base, inst.c);
            const numberC = this.numericOperand(rawC);
            const shift = u32(toUint32(numberC) & 31);
            const rawB = this.reg(base, inst.b);
            const numberB = this.numericOperand(rawB);
            const shifted = toUint32(numberB) >> shift;
            this.setReg(base, inst.a, uint32ToValue(shifted));
          }
          invoke => {
            // Callee at b, arguments above it, result into a. A compiled
            // callee gets a frame and the outer loop resumes on it; a
            // builtin runs to completion here. A plain call binds `this`
            // to undefined: there is no global object yet.
            const callee = this.reg(base, inst.b);
            const argc = u32(inst.c);
            const argsBase = base + u32(inst.b) + 1;
            if (this.isCompiledCallable(callee)) {
              this.frames[frameIndex].ip = ip;
              if (this.enterCallable(callee, inst.a, undefinedValue(), argsBase, argc, undefinedValue())) {
                returned = true;
              } else {
                thrown = this.takePending();
                throwing = true;
              }
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
          }
          methodInvoke => {
            // Callee at b, receiver at b + 1, arguments above.
            const callee = this.reg(base, inst.b);
            const receiver = this.reg(base, inst.b + 1);
            const argc = u32(inst.c);
            const argsBase = base + u32(inst.b) + 2;
            if (this.isCompiledCallable(callee)) {
              this.frames[frameIndex].ip = ip;
              if (this.enterCallable(callee, inst.a, receiver, argsBase, argc, undefinedValue())) {
                returned = true;
              } else {
                thrown = this.takePending();
                throwing = true;
              }
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
          }
          newInvoke => {
            // Construct: a fresh object whose prototype is the callee's
            // `prototype` becomes `this`; the body's return value replaces
            // it only when that value is an object.
            const callee = this.reg(base, inst.b);
            const argc = u32(inst.c);
            const argsBase = base + u32(inst.b) + 1;
            if (!this.isConstructorValue(callee)) {
              thrown = this.notConstructorError(callee);
              throwing = true;
            } else if (this.isCompiledCallable(callee)) {
              this.frames[frameIndex].ip = ip;
              if (this.enterConstruct(callee, inst.a, argsBase, argc, callee)) {
                returned = true;
              } else {
                thrown = this.takePending();
                throwing = true;
              }
            } else if (this.isHostFunctionValue(callee)) {
              const produced = this.constructHostDirect(asCell(callee), argsBase, argc);
              if (this.pendingThrow) {
                thrown = this.takePending();
                throwing = true;
              } else {
                this.setReg(base, inst.a, produced);
              }
            } else {
              const message: String = "value is not a constructor";
              thrown = this.typeError(in message);
              throwing = true;
            }
          }
          generatorStart => {
            // The prologue is done: suspend, and the call's result is the
            // generator object -- or, for an async function, its promise,
            // after the body has run to its first await.
            const gen = this.frames[frameIndex].generator;
            this.suspendGenerator(frameIndex, ip, inst.a);
            // A generator records that its body has not run (kind 4): a
            // return or throw before the first next() completes it as
            // it is, without running the body.
            if (this.functions[usize(fi)].isGenerator) {
              const startRecord = this.generatorRecord(gen);
              this.heap.setSlot(startRecord, 9, int32Value(4));
            }
            const frame = this.popFrame();
            let produced = cellValue(gen);
            if (this.functions[usize(fi)].isAsync && !this.functions[usize(fi)].isGenerator) {
              const promise = this.newPromise();
              const record = this.generatorRecord(gen);
              this.heap.setSlot(record, 3, promise);
              this.asyncStep(gen, undefinedValue(), 0);
              produced = promise;
            }
            if (this.frameCount <= entryDepth) {
              result = produced;
            } else {
              const callerBase = this.frames[usize(this.frameCount - 1)].regsBase;
              this.setReg(callerBase, frame.returnDst, produced);
            }
            returned = true;
          }
          yieldOp => {
            // a receives what next() sends on resume; b is the value yielded.
            if (this.frames[frameIndex].generator == 0) {
              const message: String = "yield outside a generator";
              thrown = this.typeError(in message);
              throwing = true;
            } else {
              const yielded = this.reg(base, inst.b);
              this.suspendGenerator(frameIndex, ip, inst.a);
              const gen = this.frames[frameIndex].generator;
              const record = this.generatorRecord(gen);
              this.heap.setSlot(record, 9, int32Value(0));
              const yieldingAsync = this.functions[usize(fi)].isAsync;
              const produced = this.resumeResult(yieldingAsync, yielded, false);
              const frame = this.popFrame();
              if (this.frameCount <= entryDepth) {
                result = produced;
              } else {
                const callerBase = this.frames[usize(this.frameCount - 1)].regsBase;
                this.setReg(callerBase, frame.returnDst, produced);
              }
              returned = true;
            }
          }
          iterGetAsync => {
            const iterable = this.reg(base, inst.b);
            const iterator = this.getAsyncIterator(iterable);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else {
              this.setReg(base, inst.a, iterator);
            }
          }
          yieldDelegate => {
            // yield*: the delegate's result object goes to the caller as
            // it is; a receives what the next resumption sends, and the
            // record notes a delegating suspension so every resumption
            // re-enters the loop with its mode.
            if (this.frames[frameIndex].generator == 0) {
              const message: String = "yield outside a generator";
              thrown = this.typeError(in message);
              throwing = true;
            } else {
              let produced = this.reg(base, inst.b);
              this.suspendGenerator(frameIndex, ip, inst.a);
              const gen = this.frames[frameIndex].generator;
              const record = this.generatorRecord(gen);
              if (this.functions[usize(fi)].isAsync) {
                // An async delegation yields the delegate's value; the
                // driver answers the request with it as it is.
                this.heap.setSlot(record, 9, int32Value(5));
                this.resumeDone = false;
              } else {
                this.heap.setSlot(record, 9, int32Value(3));
              }
              const frame = this.popFrame();
              if (this.frameCount <= entryDepth) {
                result = produced;
              } else {
                const callerBase = this.frames[usize(this.frameCount - 1)].regsBase;
                this.setReg(callerBase, frame.returnDst, produced);
              }
              returned = true;
            }
          }
          jmpIfNotReturn => {
            const gen = this.frames[frameIndex].generator;
            let returning = false;
            if (gen != 0) {
              const record = this.generatorRecord(gen);
              returning = asInt32(this.heap.slot(record, 12)) == 2;
            }
            if (!returning) ip = usize(i64(ip) + i64(bcI16(inst)));
          }
          resumeMode => {
            const gen = this.frames[frameIndex].generator;
            if (gen == 0) {
              this.setReg(base, inst.a, int32Value(0));
            } else {
              const record = this.generatorRecord(gen);
              const mode = this.heap.slot(record, 12);
              this.setReg(base, inst.a, mode);
            }
          }
          iterCallNext => {
            const iterator = this.reg(base, inst.b);
            const value = this.reg(base, inst.c);
            const nextText: String = "next";
            let absent = false;
            const produced = this.iteratorCallRaw(iterator, in nextText, value, true, inout absent);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else {
              this.setReg(base, inst.a, produced);
            }
          }
          iterCallThrow => {
            const iterator = this.reg(base, inst.b);
            const value = this.reg(base, inst.c);
            const throwText: String = "throw";
            let absent = false;
            const produced = this.iteratorCallRaw(iterator, in throwText, value, false, inout absent);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else {
              this.setReg(base, inst.a, produced);
            }
          }
          iterCallReturn => {
            const iterator = this.reg(base, inst.b);
            const value = this.reg(base, inst.c);
            const returnText: String = "return";
            let absent = false;
            const produced = this.iteratorCallRaw(iterator, in returnText, value, false, inout absent);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else {
              this.setReg(base, inst.a, produced);
            }
          }
          isAbsent => {
            const held = this.reg(base, inst.b);
            this.setReg(base, inst.a, booleanValue(isDeleted(held)));
          }
          requireIterResult => {
            const held = this.reg(base, inst.a);
            if (!this.isObjectLike(held)) {
              const message: String = "Iterator result is not an object";
              thrown = this.typeError(in message);
              throwing = true;
            }
          }
          throwTypeError => {
            const named = this.functions[usize(fi)].constants[usize(bcU16(inst))];
            thrown = this.makeError(ERROR_KIND_TYPE, this.heap.stringUtf8(asCell(named)));
            throwing = true;
          }
          iterNextWith => {
            const iterator = this.reg(base, inst.b);
            const value = this.reg(base, inst.c);
            const nextText: String = "next";
            let absent = false;
            const produced = this.iteratorCallWith(iterator, in nextText, value, inout absent);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else if (absent) {
              const message: String = "iterator.next is not a function";
              thrown = this.typeError(in message);
              throwing = true;
            } else {
              this.setReg(base, inst.a, produced);
            }
          }
          iterThrowWith => {
            const iterator = this.reg(base, inst.b);
            const value = this.reg(base, inst.c);
            const throwText: String = "throw";
            let absent = false;
            const produced = this.iteratorCallWith(iterator, in throwText, value, inout absent);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else if (absent) {
              // No throw method: close the delegate (its own throw wins),
              // then the protocol violation is a TypeError.
              this.iteratorClose(iterator);
              if (this.pendingThrow) {
                thrown = this.takePending();
              } else {
                const message: String = "The iterator does not provide a 'throw' method";
                thrown = this.typeError(in message);
              }
              throwing = true;
            } else {
              this.setReg(base, inst.a, produced);
            }
          }
          iterReturnWith => {
            const iterator = this.reg(base, inst.b);
            const value = this.reg(base, inst.c);
            const returnText: String = "return";
            let absent = false;
            const produced = this.iteratorCallWith(iterator, in returnText, value, inout absent);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else if (absent) {
              // No return method: the outer generator returns the value.
              const finished = this.createIterResult(value, true);
              this.setReg(base, inst.a, finished);
            } else {
              this.setReg(base, inst.a, produced);
            }
          }
          yieldRaw => {
            // An async generator hands a delegate's value straight to its
            // request, without awaiting it.
            if (this.frames[frameIndex].generator == 0) {
              const message: String = "yield outside a generator";
              thrown = this.typeError(in message);
              throwing = true;
            } else {
              const yielded = this.reg(base, inst.b);
              this.suspendGenerator(frameIndex, ip, inst.a);
              const gen = this.frames[frameIndex].generator;
              const record = this.generatorRecord(gen);
              this.heap.setSlot(record, 9, int32Value(2));
              // Only an async generator delegates this way: its driver takes the value.
              this.resumeDone = false;
              const produced = yielded;
              const frame = this.popFrame();
              if (this.frameCount <= entryDepth) {
                result = produced;
              } else {
                const callerBase = this.frames[usize(this.frameCount - 1)].regsBase;
                this.setReg(callerBase, frame.returnDst, produced);
              }
              returned = true;
            }
          }
          awaitOp => {
            // Like yield, but the body is parked until the value settles:
            // the driver alone resumes it.
            if (this.frames[frameIndex].generator == 0) {
              const message: String = "await outside an async function";
              thrown = this.typeError(in message);
              throwing = true;
            } else {
              const awaited = this.reg(base, inst.b);
              this.suspendGenerator(frameIndex, ip, inst.a);
              const gen = this.frames[frameIndex].generator;
              const record = this.generatorRecord(gen);
              this.heap.setSlot(record, 9, int32Value(1));
              this.heap.setSlot(record, 0, int32Value(GEN_AWAITING));
              this.resumeDone = false;
              const produced = awaited;
              const frame = this.popFrame();
              if (this.frameCount <= entryDepth) {
                result = produced;
              } else {
                const callerBase = this.frames[usize(this.frameCount - 1)].regsBase;
                this.setReg(callerBase, frame.returnDst, produced);
              }
              returned = true;
            }
          }
          returnOp => {
            let value = this.reg(base, inst.a);
            const frame = this.popFrame();
            if (frame.generator != 0) {
              this.completeGenerator(frame.generator);
              const finishedAsync = this.functions[usize(frame.functionIndex)].isAsync;
              value = this.resumeResult(finishedAsync, value, true);
            }
            // A constructor call yields its object unless it returned one; a
            // derived constructor must have called super() by now, and may
            // return only an object or undefined.
            if (isDeleted(frame.constructThis) && !this.isObjectLike(value)) {
              if (isUndefined(value)) {
                const message: String = "Must call super constructor in derived class before accessing 'this' or returning from derived constructor";
                thrown = this.makeError(ERROR_KIND_REFERENCE, bytesOf(in message));
              } else {
                const message: String = "Derived constructors may only return object or undefined";
                thrown = this.typeError(in message);
              }
              throwing = true;
            } else if (this.isObjectLike(frame.constructThis) && !this.isObjectLike(value)) {
              if (!isUndefined(value) && this.functions[usize(frame.functionIndex)].isDerived) {
                const message: String = "Derived constructors may only return object or undefined";
                thrown = this.typeError(in message);
                throwing = true;
              }
              value = frame.constructThis;
            }
            // A safe point: the frame is gone, so the value it hands back is
            // parked in the caller's next register through the collection.
            if (this.heap.shouldCollect()) {
              this.setReg(frame.regsBase, 0, value);
              this.regTop = frame.regsBase + 1;
              this.collectGarbage();
              this.regTop = frame.regsBase;
            }
            if (this.frameCount <= entryDepth) {
              result = value;
            } else {
              const callerBase = this.frames[usize(this.frameCount - 1)].regsBase;
              this.setReg(callerBase, frame.returnDst, value);
            }
            returned = true;
          }
          newObject => {
            const objectProto = this.objectProto;
            const created = cellValue(this.heap.allocateObject(objectProto));
            this.setReg(base, inst.a, created);
          }
          newArray => {
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
          }
          arrayPush => {
            const array = this.reg(base, inst.a);
            const element = this.reg(base, inst.b);
            if (isCell(array) && this.heap.isArray(asCell(array))) {
              const length = this.heap.arrayLength(asCell(array));
              this.heap.arraySet(asCell(array), length, element);
            }
          }
          loadProp => {
            const object = this.reg(base, inst.b);
            const nameSlot = usize(inst.c);
            const isPlainObject = isCell(object) && asCell(object) != 0 && this.heap.isObject(asCell(object));
            let cached = deletedValue();
            if (isPlainObject) cached = this.loadCached(fi, nameSlot, asCell(object));
            if (!isDeleted(cached)) {
              this.setReg(base, inst.a, cached);
            } else {
              const atom = this.functions[usize(fi)].propertyNames[nameSlot];
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
                  if (isPlainObject) this.populateLoadCache(fi, nameSlot, asCell(object), atom);
                }
              }
            }
          }
          storeProp => {
            const object = this.reg(base, inst.a);
            const nameSlot = usize(inst.b);
            const value = this.reg(base, inst.c);
            const isPlainObject = isCell(object) && asCell(object) != 0 && this.heap.isObject(asCell(object));
            let stored = false;
            if (isPlainObject) stored = this.storeCached(fi, nameSlot, asCell(object), value);
            if (!stored) {
              const atom = this.functions[usize(fi)].propertyNames[nameSlot];
              if (isUndefined(object) || isNull(object)) {
                thrown = this.propertyOfNullish(object, atom, false);
                throwing = true;
              } else {
                const classBefore: u32 = isPlainObject ? this.heap.objectClass(asCell(object)) : 0;
                const accepted = this.setProperty(object, cellValue(atom), value);
                if (this.pendingThrow) {
                  thrown = this.takePending();
                  throwing = true;
                } else if (!accepted && this.functions[usize(fi)].strict) {
                  thrown = this.readOnlyError(atom);
                  throwing = true;
                } else if (accepted && isPlainObject) {
                  this.populateStoreCache(fi, nameSlot, asCell(object), atom, classBefore);
                }
              }
            }
          }
          loadElem => {
            const object = this.reg(base, inst.b);
            const key = this.reg(base, inst.c);
            if (isUndefined(object) || isNull(object)) {
              const atom = this.propertyKey(key);
              thrown = this.propertyOfNullish(object, atom, true);
              throwing = true;
            } else if (this.privateNameMissing(object, key)) {
              const message: String = "Cannot read private member from an object whose class did not declare it";
              thrown = this.typeError(in message);
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
          }
          storeElem => {
            const object = this.reg(base, inst.a);
            const key = this.reg(base, inst.b);
            const value = this.reg(base, inst.c);
            if (isUndefined(object) || isNull(object)) {
              const atom = this.propertyKey(key);
              thrown = this.propertyOfNullish(object, atom, false);
              throwing = true;
            } else if (this.privateNameMissing(object, key)) {
              const message: String = "Cannot write private member to an object whose class did not declare it";
              thrown = this.typeError(in message);
              throwing = true;
            } else {
              const accepted = this.setProperty(object, key, value);
              if (this.pendingThrow) {
                thrown = this.takePending();
                throwing = true;
              } else if (!accepted && this.functions[usize(fi)].strict) {
                thrown = this.readOnlyError(this.propertyKey(key));
                throwing = true;
              }
            }
          }
          initObjData => {
            // Object literal property: define on the literal's own class. A
            // function value remembers the literal as its home, for `super`.
            const object = this.reg(base, inst.a);
            const key = this.reg(base, inst.b);
            const value = this.reg(base, inst.c);
            const atom = this.propertyKey(key);
            this.heap.objectSet(asCell(object), atom, value);
            if (this.isCompiledCallable(value)) {
              const atomHome = this.atomHome;
              this.setFunctionHidden(asCell(value), atomHome, object);
            }
          }
          loadThis => {
            const current = this.hostThis;
            if (isDeleted(current)) {
              const message: String = "Must call super constructor before accessing 'this'";
              thrown = this.makeError(ERROR_KIND_REFERENCE, bytesOf(in message));
              throwing = true;
            } else {
              this.setReg(base, inst.a, current);
            }
          }
          typeofOp => {
            const operand = this.reg(base, inst.b);
            const label = this.typeofValue(operand);
            this.setReg(base, inst.a, label);
          }
          throwOp => {
            thrown = this.reg(base, inst.a);
            throwing = true;
          }
          enterTry => {
            // The catch block starts at the jump target; the thrown value
            // lands in register a.
            const target = usize(i32(ip) + i32(bcI16(inst)));
            this.pushTry(target, inst.a);
          }
          leaveTry => {
            this.tryDepth = this.tryDepth - 1;
          }
          inOp => {
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
          }
          instanceofOp => {
            const value = this.reg(base, inst.b);
            const ctor = this.reg(base, inst.c);
            const found = this.instanceofValue(value, ctor);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else {
              this.setReg(base, inst.a, booleanValue(found));
            }
          }
          deleteElem => {
            const object = this.reg(base, inst.b);
            const key = this.reg(base, inst.c);
            const removed = this.deleteProperty(object, key);
            if (!removed && this.functions[usize(fi)].strict) {
              const message: String = "Cannot delete property";
              thrown = this.typeError(in message);
              throwing = true;
            } else {
              this.setReg(base, inst.a, booleanValue(removed));
            }
          }
          iterPrepare => {
            const source = this.reg(base, inst.b);
            const keys = this.enumerateKeys(source);
            this.setReg(base, inst.a, keys);
          }
          arrayLength => {
            const source = this.reg(base, inst.b);
            let length: i32 = 0;
            if (isCell(source) && asCell(source) != 0 && this.heap.isArray(asCell(source))) length = i32(this.heap.arrayLength(asCell(source)));
            this.setReg(base, inst.a, int32Value(length));
          }
          newEnv => {
            const parent = this.frames[frameIndex].env;
            const created = this.heap.allocateEnv(parent, u32(bcU16(inst)));
            this.frames[frameIndex].env = created;
          }
          loadEnvSlot => {
            let env = this.frames[frameIndex].env;
            let hops = u32(inst.b);
            while (hops > 0) {
              env = this.heap.linkOf(env);
              hops = hops - 1;
            }
            const value = this.heap.slot(env, u32(inst.c));
            this.setReg(base, inst.a, value);
          }
          storeEnvSlot => {
            let env = this.frames[frameIndex].env;
            let hops = u32(inst.b);
            while (hops > 0) {
              env = this.heap.linkOf(env);
              hops = hops - 1;
            }
            const value = this.reg(base, inst.a);
            this.heap.setSlot(env, u32(inst.c), value);
          }
          makeClosure => {
            // The function in b becomes a closure over the frame's current
            // environment; an arrow also keeps the frame's `this`.
            const fn = this.reg(base, inst.b);
            const env = this.frames[frameIndex].env;
            const capturedThis = this.hostThis;
            const wrapped = this.heap.functionIndex(asCell(fn));
            const closure = this.heap.allocateClosure(wrapped, env, capturedThis);
            if (this.functions[usize(wrapped)].isArrow) {
              const creator = this.frames[frameIndex].callee;
              if (isCell(creator) && asCell(creator) != 0) {
                const atomHome = this.atomHome;
                const atomNewTarget = this.atomNewTarget;
                const home = this.functionHidden(asCell(creator), atomHome);
                if (!isUndefined(home)) this.setFunctionHidden(closure, atomHome, home);
                let newTarget = this.frames[frameIndex].newTarget;
                const creatorIndex = this.frames[frameIndex].functionIndex;
                if (this.functions[usize(creatorIndex)].isArrow) newTarget = this.functionHidden(asCell(creator), atomNewTarget);
                if (!isUndefined(newTarget)) this.setFunctionHidden(closure, atomNewTarget, newTarget);
              }
            }
            this.setReg(base, inst.a, cellValue(closure));
          }
          iterGet => {
            const iterable = this.reg(base, inst.b);
            const iterator = this.getIterator(iterable);
            if (!this.pendingThrow) this.setReg(base, inst.a, iterator);
          }
          iterStep => {
            // a = the value, c = done; a throw reads as done.
            const iterator = this.reg(base, inst.b);
            const next = this.iteratorStep(iterator);
            if (this.pendingThrow || isDeleted(next)) {
              this.setReg(base, inst.c, booleanValue(true));
            } else {
              this.setReg(base, inst.a, next);
              this.setReg(base, inst.c, booleanValue(false));
            }
          }
          iterClose => {
            const done = this.reg(base, inst.b);
            if (!(isBoolean(done) && isTrue(done))) {
              const iterator = this.reg(base, inst.a);
              this.iteratorClose(iterator);
            }
          }
          iterCloseQuiet => {
            // Closing on the way out of a throw: the original throw wins
            // over anything `return` raises.
            const done = this.reg(base, inst.b);
            if (!(isBoolean(done) && isTrue(done))) {
              const iterator = this.reg(base, inst.a);
              this.iteratorClose(iterator);
              if (this.pendingThrow) this.takePending();
            }
          }
          arraySpread => {
            // Append everything the iterable in b yields to the array in a.
            const array = this.reg(base, inst.a);
            const iterable = this.reg(base, inst.b);
            const items = this.iterateToArray(iterable);
            if (!this.pendingThrow) {
              const target = asCell(array);
              const source = asCell(items);
              const count = this.heap.arrayLength(source);
              let index: u32 = 0;
              while (index < count) {
                const element = this.heap.arrayGet(source, index);
                const length = this.heap.arrayLength(target);
                this.heap.arraySet(target, length, element);
                index = index + 1;
              }
            }
          }
          objectSpread => {
            // { ...source } into the object in a.
            const target = this.reg(base, inst.a);
            const source = this.reg(base, inst.b);
            this.copyDataProperties(asCell(target), source, 0);
          }
          objectRest => {
            // { ...rest } of a pattern: a fresh object with what the other
            // entries did not take.
            const source = this.reg(base, inst.b);
            const excluded = this.reg(base, inst.c);
            const objectProto = this.objectProto;
            const created = this.heap.allocateObject(objectProto);
            this.setReg(base, inst.a, cellValue(created));
            this.copyDataProperties(created, source, asCell(excluded));
          }
          assertCoercible => {
            const value = this.reg(base, inst.a);
            if (isUndefined(value) || isNull(value)) {
              const message: String = "Cannot destructure null or undefined";
              thrown = this.typeError(in message);
              throwing = true;
            }
          }
          iterRestCollect => {
            // The iterator's remaining values as an array; the iterator is
            // then done.
            const iterator = this.reg(base, inst.b);
            const array = this.heap.allocateArray(0);
            this.setReg(base, inst.a, cellValue(array));
            while (!this.pendingThrow) {
              const next = this.iteratorStep(iterator);
              if (this.pendingThrow || isDeleted(next)) break;
              const count = this.heap.arrayLength(array);
              this.heap.arraySet(array, count, next);
            }
            this.setReg(base, inst.c, booleanValue(true));
          }
          buildArguments => {
            // The frame's actual arguments as an array, marked so that
            // Object.prototype.toString reports Arguments.
            const argsBase = this.frames[frameIndex].argsBase;
            const argc = this.frames[frameIndex].argc;
            const array = this.heap.allocateArray(argc);
            let index: u32 = 0;
            while (index < argc) {
              const passed = this.regStack[usize(argsBase + index)];
              this.heap.setSlot(array, index, passed);
              index = index + 1;
            }
            const bag = this.arrayBag(array);
            const marker = this.atomArgumentsMarker;
            this.heap.objectDefine(bag, marker, booleanValue(true), PROP_NONE);
            this.setReg(base, inst.a, cellValue(array));
          }
          buildRestArgs => {
            // The actual arguments past the first b, as an array.
            const argsBase = this.frames[frameIndex].argsBase;
            const argc = this.frames[frameIndex].argc;
            const skip = u32(inst.b);
            const count: u32 = argc > skip ? argc - skip : 0;
            const array = this.heap.allocateArray(count);
            let index: u32 = 0;
            while (index < count) {
              const passed = this.regStack[usize(argsBase + skip + index)];
              this.heap.setSlot(array, index, passed);
              index = index + 1;
            }
            this.setReg(base, inst.a, cellValue(array));
          }
          loadCallee => {
            const callee = this.frames[frameIndex].callee;
            this.setReg(base, inst.a, callee);
          }
          loadNewTarget => {
            let target = this.frames[frameIndex].newTarget;
            if (this.functions[usize(this.frames[frameIndex].functionIndex)].isArrow) {
              const callee = this.frames[frameIndex].callee;
              const atomNewTarget = this.atomNewTarget;
              target = isCell(callee) && asCell(callee) != 0 ? this.functionHidden(asCell(callee), atomNewTarget) : undefinedValue();
            }
            this.setReg(base, inst.a, target);
          }
          newPrivateName => {
            const functionIndex = this.frames[frameIndex].functionIndex;
            const description = this.functions[usize(functionIndex)].constants[usize(bcU16(inst))];
            const symbol = this.newSymbol(description);
            this.heap.setFlags(asCell(symbol), FLAG_PRIVATE_NAME);
            this.setReg(base, inst.a, symbol);
          }
          defineField => {
            const object = this.reg(base, inst.a);
            const key = this.reg(base, inst.b);
            const value = this.reg(base, inst.c);
            let desc = emptyDescriptorInput();
            desc.hasValue = true;
            desc.value = value;
            desc.hasWritable = true;
            desc.writable = true;
            desc.hasEnumerable = true;
            desc.enumerable = true;
            desc.hasConfigurable = true;
            desc.configurable = true;
            const defined = this.defineOwnProperty(object, key, desc);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else if (!defined) {
              const message: String = "Cannot define class field";
              thrown = this.typeError(in message);
              throwing = true;
            }
          }
          loadSuper => {
            const callee = this.frames[frameIndex].callee;
            const atomHome = this.atomHome;
            const home = isCell(callee) && asCell(callee) != 0 ? this.functionHidden(asCell(callee), atomHome) : undefinedValue();
            if (!this.isObjectLike(home)) {
              const message: String = "'super' keyword unexpected here";
              thrown = this.makeError(ERROR_KIND_SYNTAX, bytesOf(in message));
              throwing = true;
            } else {
              const key = this.reg(base, inst.b);
              const proto = this.protoOfValue(home);
              let found = undefinedValue();
              if (proto != 0) {
                if (this.heap.isObject(proto)) {
                  const atom = this.propertyKey(key);
                  const receiver = this.hostThis;
                  found = this.lookupProperty(proto, atom, receiver);
                } else {
                  found = this.getProperty(cellValue(proto), key);
                }
              }
              if (this.pendingThrow) {
                thrown = this.takePending();
                throwing = true;
              } else {
                this.setReg(base, inst.a, found);
              }
            }
          }
          storeSuper => {
            const key = this.reg(base, inst.a);
            const value = this.reg(base, inst.b);
            const receiver = this.hostThis;
            const stored = this.setProperty(receiver, key, value);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else if (!stored) {
              const message: String = "Cannot assign to read only property";
              thrown = this.typeError(in message);
              throwing = true;
            }
          }
          loadHole => {
            this.setReg(base, inst.a, holeValue());
          }
          throwIfHole => {
            // A lexical binding read before its declaration ran.
            if (isHole(this.reg(base, inst.a))) {
              const named = this.functions[usize(fi)].constants[usize(bcU16(inst))];
              const before: String = "Cannot access '";
              let message = bytesOf(in before);
              appendBytes(inout message, this.heap.stringUtf8(asCell(named)));
              const after: String = "' before initialization";
              appendBytes(inout message, bytesOf(in after));
              thrown = this.makeError(ERROR_KIND_REFERENCE, move message);
              throwing = true;
            }
          }
          checkThis => {
            const held = this.reg(base, inst.a);
            if (isDeleted(held) || isHole(held)) {
              const text: String = "Must call super constructor in derived class before accessing 'this' or returning from derived constructor";
              thrown = this.makeError(ERROR_KIND_REFERENCE, bytesOf(in text));
              throwing = true;
            }
          }
          throwConstAssign => {
            const text: String = "Assignment to constant variable.";
            thrown = this.makeError(ERROR_KIND_TYPE, bytesOf(in text));
            throwing = true;
          }
          envToReg => {
            const env = this.frames[frameIndex].env;
            this.setReg(base, inst.a, int32Value(i32(env)));
          }
          renewEnv => {
            // A fresh environment for the next iteration: the same parent
            // as the loop's current one, its slots copied.
            const current = u32(asInt32(this.reg(base, inst.a)));
            const count = u32(bcU16(inst));
            const parent = this.heap.linkOf(current);
            const created = this.heap.allocateEnv(parent, count);
            let slot: u32 = 0;
            while (slot < count) {
              const held = this.heap.slot(current, slot);
              this.heap.setSlot(created, slot, held);
              slot = slot + 1;
            }
            this.frames[frameIndex].env = created;
            this.setReg(base, inst.a, int32Value(i32(created)));
          }
          exitEnv => {
            const current = u32(asInt32(this.reg(base, inst.a)));
            this.frames[frameIndex].env = this.heap.linkOf(current);
          }
          newRegex => {
            const pattern = this.functions[usize(fi)].constants[usize(inst.b)];
            const flags = this.functions[usize(fi)].constants[usize(inst.c)];
            const regexProto = this.regexProto;
            const created = this.regexpCreate(pattern, flags, regexProto);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else {
              this.setReg(base, inst.a, created);
            }
          }
          newRegexR => {
            const pattern = this.reg(base, inst.b);
            const flags = this.reg(base, inst.c);
            const regexProto = this.regexProto;
            const created = this.regexpCreate(pattern, flags, regexProto);
            if (this.pendingThrow) {
              thrown = this.takePending();
              throwing = true;
            } else {
              this.setReg(base, inst.a, created);
            }
          }
          _ => {
            // Opcode pairs that share a handler, and the unimplemented rest.
            if (op == Op.cmpEq || op == Op.cmpNe) {
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
            } else if (op == Op.defineGetter || op == Op.defineSetter) {
              const object = this.reg(base, inst.a);
              const key = this.reg(base, inst.b);
              const fn = this.reg(base, inst.c);
              this.defineAccessor(object, key, fn, fn, op == Op.defineGetter);
              if (this.isCompiledCallable(fn)) {
                const atomHome = this.atomHome;
                this.setFunctionHidden(asCell(fn), atomHome, object);
              }
            } else if (op == Op.spreadInvoke || op == Op.spreadMethodInvoke || op == Op.spreadNewInvoke) {
              // Callee at b; for a method call the receiver at b + 1; the
              // arguments array in the next register. The elements are placed
              // on the register stack and the ordinary call paths take over.
              const callee = this.reg(base, inst.b);
              const isMethod = op == Op.spreadMethodInvoke;
              const receiver = isMethod ? this.reg(base, inst.b + 1) : undefinedValue();
              const arrayReg: u8 = isMethod ? inst.b + 2 : inst.b + 1;
              const argsArray = this.reg(base, arrayReg);
              const argsBase = this.spreadArguments(asCell(argsArray));
              const argc = this.regTop - argsBase;
              if (op == Op.spreadNewInvoke) {
                if (!this.isConstructorValue(callee)) {
                  thrown = this.notConstructorError(callee);
                  throwing = true;
                } else if (this.isCompiledCallable(callee)) {
                  this.frames[frameIndex].ip = ip;
                  if (this.enterConstruct(callee, inst.a, argsBase, argc, callee)) {
                    returned = true;
                  } else {
                    thrown = this.takePending();
                    throwing = true;
                  }
                } else {
                  const produced = this.constructHostDirect(asCell(callee), argsBase, argc);
                  this.regTop = argsBase;
                  if (!this.pendingThrow) this.setReg(base, inst.a, produced);
                }
              } else if (this.isCompiledCallable(callee)) {
                this.frames[frameIndex].ip = ip;
                if (this.enterCallable(callee, inst.a, receiver, argsBase, argc, undefinedValue())) {
                  returned = true;
                } else {
                  thrown = this.takePending();
                  throwing = true;
                }
              } else if (this.isHostFunctionValue(callee)) {
                const builtin = this.heap.hostFunctionId(asCell(callee));
                const outcome = this.callHost(builtin, receiver, argsBase, argc, asCell(callee));
                this.regTop = argsBase;
                if (!this.pendingThrow) this.setReg(base, inst.a, outcome);
              } else {
                this.regTop = argsBase;
                const message: String = isMethod ? "property is not a function" : "value is not a function";
                thrown = this.typeError(in message);
                throwing = true;
              }
            } else if (op == Op.initClass || op == Op.initClassBase) {
              const ctor = this.reg(base, inst.a);
              const proto = this.reg(base, inst.b);
              const ctorHandle = asCell(ctor);
              const protoHandle = asCell(proto);
              let failed = false;
              if (op == Op.initClass) {
                const parent = this.reg(base, inst.c);
                if (isNull(parent)) {
                  this.heap.setObjectProto(protoHandle, 0);
                } else if (!this.isConstructorValue(parent)) {
                  const message: String = "Class extends value is not a constructor or null";
                  thrown = this.typeError(in message);
                  throwing = true;
                  failed = true;
                } else {
                  const atomPrototype = this.atomPrototype;
                  const parentProto = this.getProperty(parent, cellValue(atomPrototype));
                  if (this.pendingThrow) {
                    thrown = this.takePending();
                    throwing = true;
                    failed = true;
                  } else if (!this.isObjectLike(parentProto) && !isNull(parentProto)) {
                    const message: String = "Class extends value does not have valid prototype property";
                    thrown = this.typeError(in message);
                    throwing = true;
                    failed = true;
                  } else {
                    this.heap.setObjectProto(protoHandle, isNull(parentProto) ? 0 : asCell(parentProto));
                    const atomFunctionProto = this.atomFunctionProto;
                    this.setFunctionHidden(ctorHandle, atomFunctionProto, parent);
                  }
                }
              }
              if (!failed) {
                const atomPrototype = this.atomPrototype;
                this.defineOwnAttr(ctorHandle, atomPrototype, proto, PROP_NONE);
                const atomConstructor = this.atomConstructor;
                this.heap.objectDefine(protoHandle, atomConstructor, ctor, PROP_METHOD);
              }
            } else if (op == Op.defineMethod || op == Op.defineMethodComputed) {
              // Methods are writable and configurable but not enumerable, and
              // remember the object they were defined on for `super`.
              const target = this.reg(base, inst.a);
              const fn = this.reg(base, inst.c);
              let atom: u32 = 0;
              if (op == Op.defineMethod) {
                const functionIndex = this.frames[frameIndex].functionIndex;
                atom = this.functions[usize(functionIndex)].propertyNames[usize(inst.b)];
              } else {
                const key = this.reg(base, inst.b);
                atom = this.propertyKey(key);
                this.setFunctionNameFromKey(fn, key, 0);
              }
              if (this.pendingThrow) {
                thrown = this.takePending();
                throwing = true;
              } else {
                this.defineOwnAttr(asCell(target), atom, fn, PROP_METHOD);
                const atomHome = this.atomHome;
                this.setFunctionHidden(asCell(fn), atomHome, target);
              }
            } else if (op == Op.defineMethodGetter || op == Op.defineMethodSetter) {
              const target = this.reg(base, inst.a);
              const key = this.reg(base, inst.b);
              const fn = this.reg(base, inst.c);
              const isGetter = op == Op.defineMethodGetter;
              this.setFunctionNameFromKey(fn, key, isGetter ? 1 : 2);
              if (this.pendingThrow) {
                thrown = this.takePending();
                throwing = true;
              } else {
                this.defineAccessorAttr(target, key, fn, fn, isGetter, PROP_CONFIGURABLE | PROP_ACCESSOR);
                const atomHome = this.atomHome;
                this.setFunctionHidden(asCell(fn), atomHome, target);
              }
            } else if (op == Op.superCall || op == Op.spreadSuperCall) {
              let args = Array<Value>();
              if (op == Op.superCall) {
                let index: u32 = 0;
                while (index < u32(inst.c)) {
                  const passed = this.reg(base, inst.b + u8(index));
                  args.push(passed);
                  index = index + 1;
                }
              } else {
                const spread = this.reg(base, inst.b);
                const count = this.heap.arrayLength(asCell(spread));
                let index: u32 = 0;
                while (index < count) {
                  const passed = this.heap.arrayGet(asCell(spread), index);
                  args.push(passed);
                  index = index + 1;
                }
              }
              this.frames[frameIndex].ip = ip;
              const constructed = this.superConstruct(frameIndex, move args);
              if (this.pendingThrow) {
                thrown = this.takePending();
                throwing = true;
              } else {
                this.setReg(base, inst.a, constructed);
              }
            } else {
              // Not yet implemented: an internal error, surfaced as a throw.
              const message: String = "unsupported operation";
              thrown = this.typeError(in message);
              throwing = true;
            }
          }
        }
        // A coercion inside any handler may have raised (a Symbol in
        // arithmetic, a throwing valueOf); it surfaces here.
        if (this.pendingThrow && !throwing) {
          thrown = this.takePending();
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
            this.frames[usize(top)].env = handler.env;
            const handlerBase = this.frames[usize(top)].regsBase;
            this.setReg(handlerBase, handler.catchReg, thrown);
            this.tryDepth = this.tryDepth - 1;
            caught = true;
          } else {
            const generator = this.frames[usize(top)].generator;
            if (generator != 0) this.completeGenerator(generator);
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

  // The TypeError for a rejected write in strict code.
  function readOnlyError(inout this, atom: u32): Value {
    const head: String = "Cannot assign to read only property '";
    const tail: String = "'";
    let message = bytesOf(in head);
    appendBytes(inout message, this.heap.stringUtf8(atom));
    appendBytes(inout message, bytesOf(in tail));
    return this.makeError(ERROR_KIND_TYPE, move message);
  }

  // The TypeError for `new` on something that is not a constructor.
  function notConstructorError(inout this, callee: Value): Value {
    let message = Array<u8>();
    if (this.isHostFunctionValue(callee)) {
      const name = this.heap.slot(asCell(callee), 2);
      if (this.isStringValue(name)) message = this.heap.stringUtf8(asCell(name));
    }
    if (message.length == 0) {
      const generic: String = "value";
      message = bytesOf(in generic);
    }
    const tail: String = " is not a constructor";
    appendBytes(inout message, bytesOf(in tail));
    return this.makeError(ERROR_KIND_TYPE, move message);
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
    appendBytes(inout message, this.heap.stringUtf8(atom));
    appendBytes(inout message, bytesOf(in tail));
    return this.makeError(ERROR_KIND_TYPE, move message);
  }
}

export function appendBytes(inout target: Array<u8>, source: Array<u8>): void {
  let index: usize = 0;
  while (index < source.length) {
    target.push(source[index]);
    index = index + 1;
  }
}

export function createRuntime(): Runtime {
  let runtime = Runtime({
    heap: createHeap(), functions: Array<FunctionCode>(), codeSegment: Array<Inst>(), globals: Array<Global>(),
    atoms: Array<u32>(), atomCount: 0,
    regStack: Array<Value>(), regTop: 0, frames: Array<Frame>(), frameCount: 0,
    hadError: false, lastError: undefinedValue(),
    hostThis: undefinedValue(), tryStack: Array<TryFrame>(), tryDepth: 0,
    pendingThrow: false, pendingValue: undefinedValue(),
    objectProto: 0, functionProto: 0, arrayProto: 0, stringProto: 0, numberProto: 0, booleanProto: 0, symbolProto: 0,
    randomState: 0x9E3779B97F4A7C15, lastResult: undefinedValue(),
    hostTable: Array<HostFunction>(), sharedHosts: Array<u32>(), globalObject: 0, tempRoots: Array<Value>(),
    atomLength: 0, atomPrototype: 0, atomConstructor: 0, atomName: 0, atomMessage: 0, atomDone: 0, atomValue: 0, atomThen: 0, atomNext: 0, atomReturn: 0, atomThrow: 0, atomResolve: 0, atomPrimitive: 0,
    atomArgumentsMarker: 0, iteratorProto: 0, arrayIteratorProto: 0, atomIterSource: 0, atomIterIndex: 0, atomIterKind: 0, arrayIteratorNext: 0,
    generatorProto: 0, atomGenRecord: 0,
    mapProto: 0, setProto: 0, weakMapProto: 0, weakSetProto: 0, mapIteratorProto: 0, setIteratorProto: 0, atomMapRecord: 0, atomMapIter: 0, atomHome: 0, atomNewTarget: 0, atomFunctionProto: 0, promiseProto: 0, promiseCtor: 0, hasInstanceBuiltin: 0, promiseSpeciesGetter: 0, hostNewTarget: undefinedValue(), atomPromiseRecord: 0, atomErrorData: 0, atomDateValue: 0, atomRegexSource: 0, atomRegexFlags: 0, atomRegexCompiled: 0, atomRegexIter: 0, atomRegexTicket: 0, atomLastIndex: 0, atomIndex: 0, atomInput: 0, atomGroups: 0, atomExec: 0, atomFlags: 0, regexProto: 0, regexIteratorProto: 0, regexExecFn: 0, regexCtor: 0, regexBackend: createRegexBackend(), symbolMatch: undefinedValue(), symbolMatchAll: undefinedValue(), symbolReplace: undefinedValue(), symbolSearch: undefinedValue(), symbolSplit: undefinedValue(), asyncIteratorProto: 0, asyncGeneratorProto: 0, symbolAsyncIterator: undefinedValue(), asyncFromSyncProto: 0, atomSyncIterator: 0, jobs: Array<Value>(), jobCursor: 0, gcTiming: false, gcPauses: Array<f64>(), resumeDone: false,
    symbolCounter: 0, symbolRegistry: Array<Value>(),
    symbolIterator: undefinedValue(), symbolToPrimitive: undefinedValue(), symbolToStringTag: undefinedValue(), symbolHasInstance: undefinedValue(), symbolSpecies: undefinedValue(), symbolIsConcatSpreadable: undefinedValue(), symbolUnscopables: undefinedValue(),
  });
  runtime.installIntrinsics();
  runtime.registerSharedHost(HOST_PROMISE_RESOLVE, promiseResolveFunction);
  runtime.registerSharedHost(HOST_PROMISE_REJECT, promiseRejectFunction);
  runtime.registerSharedHost(HOST_ASYNC_FROM_SYNC_UNWRAP, asyncFromSyncUnwrap);
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

// JavaScript's shift discards the bits that leave the word; the count
// is already masked to the word by the caller.
export function shiftLeft32(bits: u32, count: u32): u32 {
  return bits.wrappingShiftLeft(usize(count));
}

// Z's checked conversion from f64 traps on a fractional value, so every
// place that narrows a double to an integer truncates first and compares.
export function truncateDouble(value: f64): f64 {
  return math.trunc(value);
}

export function isIntegralDouble(value: f64): boolean {
  return value == value && truncateDouble(value) == value;
}

function nativeNan(): f64 = raw c {
  return __builtin_nan("");
}

export function nanValue(): f64 {
  return nativeNan();
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
// --- Text for diagnostics ---
//
// Engine strings are bytes, and not necessarily UTF-8: JavaScript source
// and string values may hold any byte sequence. They never become Z
// Strings on the way into the engine (source is parsed as bytes) or
// inside it (values are byte arrays). The one direction that needs a Z
// String is display -- a message for the host, a log line -- and that
// decoding replaces each maximal invalid subpart with U+FFFD, as the
// WHATWG decoder does, so the result always satisfies String's
// valid-UTF-8 invariant and never stands in for the original bytes.

const REPLACEMENT_LEAD: u8 = 0xEF;
const REPLACEMENT_MID: u8 = 0xBF;
const REPLACEMENT_TAIL: u8 = 0xBD;

// The length of the well-formed UTF-8 sequence starting at `index`, or
// the length of the maximal invalid subpart there, negated (-1 to -3).
export function utf8SequenceLength(in bytes: Array<u8>, index: usize): i32 {
  const count = bytes.length;
  const lead = bytes[index];
  if (lead < 0x80) return 1;
  let needed: usize = 0;
  let low: u8 = 0x80;
  let high: u8 = 0xBF;
  if (lead >= 0xC2 && lead <= 0xDF) {
    needed = 1;
  } else if (lead >= 0xE0 && lead <= 0xEF) {
    needed = 2;
    if (lead == 0xE0) low = 0xA0;
    if (lead == 0xED) high = 0x9F;
  } else if (lead >= 0xF0 && lead <= 0xF4) {
    needed = 3;
    if (lead == 0xF0) low = 0x90;
    if (lead == 0xF4) high = 0x8F;
  } else {
    return -1;
  }
  let seen: usize = 0;
  while (seen < needed) {
    const at = index + 1 + seen;
    if (at >= count) return -i32(seen + 1);
    const byte = bytes[at];
    if (byte < low || byte > high) return -i32(seen + 1);
    low = 0x80;
    high = 0xBF;
    seen = seen + 1;
  }
  return i32(needed + 1);
}

// The bytes as text for display: well-formed sequences copied, each
// maximal invalid subpart replaced with U+FFFD. Embedded NULs and
// characters outside the BMP pass through; a lone surrogate encoded as
// bytes is invalid and replaced.
export function bytesToDisplayString(in bytes: Array<u8>): String {
  let cleaned = Array<u8>();
  const count = bytes.length;
  let index: usize = 0;
  while (index < count) {
    const length = utf8SequenceLength(in bytes, index);
    if (length > 0) {
      let copied: usize = 0;
      while (copied < usize(length)) {
        cleaned.push(bytes[index + copied]);
        copied = copied + 1;
      }
      index = index + usize(length);
    } else {
      cleaned.push(REPLACEMENT_LEAD);
      cleaned.push(REPLACEMENT_MID);
      cleaned.push(REPLACEMENT_TAIL);
      index = index + usize(0 - length);
    }
  }
  const decoded = attempt String.fromBytes(cleaned);
  const marker: String = "�";
  return match (decoded) {
    success(text) => text;
    // Unreachable once the validator above agrees with the library's;
    // kept so a disagreement shows up as marked text, never as an abort.
    failure(error) => marker;
  };
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

function displayOf(bytes: Array<u8>): String {
  return bytesToDisplayString(in bytes);
}

test "display decoding keeps well-formed text, NULs, and non-BMP characters" {
  let plain = Array<u8>();
  plain.push(0x61);
  plain.push(0);
  plain.push(0x62);
  const withNul = displayOf(move plain);
  expect(withNul.byteLength).toEqual(3);
  expect(withNul.byteAt(1)).toEqual(0);
  let emoji = Array<u8>();
  emoji.push(0xF0);
  emoji.push(0x9F);
  emoji.push(0x98);
  emoji.push(0x80);
  const grin = displayOf(move emoji);
  expect(grin.byteLength).toEqual(4);
  expect(grin.byteAt(0)).toEqual(0xF0);
  let accented = Array<u8>();
  accented.push(0xC3);
  accented.push(0xA9);
  const acute = displayOf(move accented);
  expect(acute.byteLength).toEqual(2);
}

test "display decoding replaces each maximal invalid subpart with U+FFFD" {
  let stray = Array<u8>();
  stray.push(0x61);
  stray.push(0xFF);
  stray.push(0x62);
  const replaced = displayOf(move stray);
  expect(replaced.byteLength).toEqual(5);
  expect(replaced.byteAt(1)).toEqual(0xEF);
  expect(replaced.byteAt(4)).toEqual(0x62);
  let truncated = Array<u8>();
  truncated.push(0xE2);
  truncated.push(0x82);
  truncated.push(0x41);
  const cut = displayOf(move truncated);
  expect(cut.byteLength).toEqual(4);
  expect(cut.byteAt(3)).toEqual(0x41);
  let surrogate = Array<u8>();
  surrogate.push(0xED);
  surrogate.push(0xA0);
  surrogate.push(0x80);
  const lone = displayOf(move surrogate);
  expect(lone.byteLength).toEqual(9);
  let overlong = Array<u8>();
  overlong.push(0xC0);
  overlong.push(0x80);
  const doubled = displayOf(move overlong);
  expect(doubled.byteLength).toEqual(6);
  let unfinished = Array<u8>();
  unfinished.push(0xF0);
  unfinished.push(0x9F);
  const short = displayOf(move unfinished);
  expect(short.byteLength).toEqual(3);
}

// The resolve function of a promise: the first call wins, later ones
// are ignored. `callee`'s bound data is the shared [promise, resolved].
function promiseResolveFunction(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const shared = asCell(runtime.heap.slot(callee, 0));
  if (isTrue(runtime.heap.slot(shared, 1))) return undefinedValue();
  runtime.heap.setSlot(shared, 1, booleanValue(true));
  const promise = runtime.heap.slot(shared, 0);
  runtime.resolvePromise(asCell(promise), runtime.argument(argsBase, argc, 0));
  return undefinedValue();
}

function promiseRejectFunction(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const shared = asCell(runtime.heap.slot(callee, 0));
  if (isTrue(runtime.heap.slot(shared, 1))) return undefinedValue();
  runtime.heap.setSlot(shared, 1, booleanValue(true));
  const promise = runtime.heap.slot(shared, 0);
  runtime.rejectPromise(asCell(promise), runtime.argument(argsBase, argc, 0));
  return undefinedValue();
}

// %AsyncFromSyncIteratorPrototype%.next / return / throw: the sync
// iterator's method runs at once and its result's value is awaited into
// a promise for {value, done}. `callee`'s bound data is the mode.
function asyncFromSyncRequest(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, mode: i32): Value {
  const promise = runtime.newPromise();
  runtime.pushTempRoot(promise);
  const sync = runtime.wrappedSyncIterator(thisValue);
  if (isUndefined(sync)) {
    const message: String = "not an async-from-sync iterator";
    const error = runtime.typeError(in message);
    runtime.rejectPromise(asCell(promise), error);
    runtime.popTempRoot();
    return promise;
  }
  let method = undefinedValue();
  if (mode == 0) {
    method = runtime.getProperty(sync, cellValue(runtime.atomNext));
  } else if (mode == 2) {
    method = runtime.getProperty(sync, cellValue(runtime.atomReturn));
  } else {
    method = runtime.getProperty(sync, cellValue(runtime.atomThrow));
  }
  let result = undefinedValue();
  if (!runtime.pendingThrow) {
    if (isUndefined(method) || isNull(method)) {
      // No such method on the sync iterator: return finishes, throw
      // rejects with the argument.
      if (mode == 2) {
        result = runtime.createIterResult(runtime.argument(argsBase, argc, 0), true);
      } else {
        runtime.raise(runtime.argument(argsBase, argc, 0));
      }
    } else {
      let args = Array<Value>();
      if (argc > 0) args.push(runtime.argument(argsBase, argc, 0));
      result = runtime.callValue(method, sync, move args);
    }
  }
  if (!runtime.pendingThrow && !runtime.isObjectLike(result)) {
    const message: String = "Iterator result is not an object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
  }
  if (runtime.pendingThrow) {
    const thrown = runtime.takePending();
    runtime.rejectPromise(asCell(promise), thrown);
    runtime.popTempRoot();
    return promise;
  }
  runtime.pushTempRoot(result);
  const doneKey = cellValue(runtime.atomDone);
  const done = runtime.getProperty(result, doneKey);
  const valueKey = cellValue(runtime.atomValue);
  const value = runtime.getProperty(result, valueKey);
  runtime.popTempRoot();
  if (runtime.pendingThrow) {
    const thrown = runtime.takePending();
    runtime.rejectPromise(asCell(promise), thrown);
    runtime.popTempRoot();
    return promise;
  }
  const isDone = runtime.toBooleanValue(done);
  runtime.pushTempRoot(value);
  const settled = runtime.promiseResolveValue(value);
  runtime.popTempRoot();
  if (runtime.pendingThrow) {
    const thrown = runtime.takePending();
    runtime.rejectPromise(asCell(promise), thrown);
    runtime.popTempRoot();
    return promise;
  }
  runtime.pushTempRoot(settled);
  const unwrap = runtime.newSharedHost(HOST_ASYNC_FROM_SYNC_UNWRAP, booleanValue(isDone), 1);
  runtime.performThen(asCell(settled), cellValue(unwrap), undefinedValue(), promise);
  runtime.popTempRoot();
  runtime.popTempRoot();
  return promise;
}

// The awaited value back into an iterator result; `callee` binds done.
function asyncFromSyncUnwrap(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const done = isTrue(runtime.heap.slot(callee, 0));
  return runtime.createIterResult(runtime.argument(argsBase, argc, 0), done);
}

export function asyncFromSyncNext(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return asyncFromSyncRequest(inout runtime, thisValue, argsBase, argc, 0);
}

export function asyncFromSyncReturn(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return asyncFromSyncRequest(inout runtime, thisValue, argsBase, argc, 2);
}

export function asyncFromSyncThrow(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return asyncFromSyncRequest(inout runtime, thisValue, argsBase, argc, 1);
}
