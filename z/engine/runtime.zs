// Runtime -- the per-context engine state the interpreter runs against:
// the heap, compiled functions, globals, the register stack, and call
// frames. One Runtime per context; it lives inside the context registry.
//
// The interpreter is a method on Runtime so every piece of mutable state is
// reached through `this`. Z rejects `inout` through indexed storage, but a
// method call on the projection is accepted, and the registry calls
// `slots[i].runtime.eval(...)`.

import { expect } from "std/test";
import { Value, int32Value, doubleValue, undefinedValue, nullValue, booleanValue, isInt32, asInt32, isDouble, asDouble, isNumber, isUndefined, isNull, isBoolean, isTrue, isCell, cellValue, asCell, NUMBER_TAG } from "./value.zs";
import { Heap, createHeap, bytesOf, TAG_STRING } from "./heap.zs";
import { Op, Inst, FunctionCode, bcU16, bcI16 } from "./bytecode.zs";
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

  function addFunction(inout this, code: FunctionCode): u32 {
    this.functions.push(move code);
    return u32(this.functions.length - 1);
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

  // --- Coercions that need the heap ---

  function toNumberValue(value: Value): f64 {
    if (this.isStringValue(value)) {
      const bytes = this.heap.stringBytes(asCell(value));
      return stringToNumber(in bytes);
    }
    return toNumber(value);
  }

  function toBooleanValue(value: Value): boolean {
    if (this.isStringValue(value)) return this.heap.stringLength(asCell(value)) > 0;
    if (isCell(value) && asCell(value) != 0) return true;
    return toBoolean(value);
  }

  // ToString for the primitives the engine has.
  function toStringValue(inout this, value: Value): Value {
    if (this.isStringValue(value)) return value;
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

  function looseEquals(a: Value, b: Value): boolean {
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
  function lessThan(a: Value, b: Value, orEqual: boolean): boolean {
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
    const regCount = this.functions[usize(functionIndex)].registerCount;
    const base = this.regTop;
    const needed = usize(base + regCount);
    while (this.regStack.length < needed) { this.regStack.push(undefinedValue()); }
    let i: u32 = 0;
    while (i < regCount) {
      this.regStack[usize(base + i)] = undefinedValue();
      i = i + 1;
    }
    this.regTop = base + regCount;
    const frame = Frame({ functionIndex: functionIndex, ip: 0, regsBase: base, regCount: regCount, returnDst: returnDst });
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
    return frame;
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
      while (ip < codeLength && !returned) {
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
            // ReferenceError; Error objects do not exist yet, so the
            // thrown value is undefined for now.
            this.frames[frameIndex].ip = ip;
            this.popFrame();
            return RunResult({ isThrow: true, value: undefinedValue() });
          }
          const operand3 = this.globals[slot].value;
          this.setReg(base, inst.a, operand3);
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
          const equal = this.looseEquals(this.reg(base, inst.b), this.reg(base, inst.c));
          this.setReg(base, inst.a, booleanValue(op == Op.cmpEq ? equal : !equal));
        } else if (op == Op.cmpStrictEq || op == Op.cmpStrictNe) {
          const equal = this.strictEquals(this.reg(base, inst.b), this.reg(base, inst.c));
          this.setReg(base, inst.a, booleanValue(op == Op.cmpStrictEq ? equal : !equal));
        } else if (op == Op.cmpLt) {
          const outcome = this.lessThan(this.reg(base, inst.b), this.reg(base, inst.c), false);
          this.setReg(base, inst.a, booleanValue(outcome));
        } else if (op == Op.cmpLe) {
          const outcome = this.lessThan(this.reg(base, inst.b), this.reg(base, inst.c), true);
          this.setReg(base, inst.a, booleanValue(outcome));
        } else if (op == Op.cmpGt) {
          const outcome = this.lessThan(this.reg(base, inst.c), this.reg(base, inst.b), false);
          this.setReg(base, inst.a, booleanValue(outcome));
        } else if (op == Op.cmpGe) {
          const outcome = this.lessThan(this.reg(base, inst.c), this.reg(base, inst.b), true);
          this.setReg(base, inst.a, booleanValue(outcome));
        } else if (op == Op.jmp) {
          ip = usize(i64(ip) + i64(bcI16(inst)));
        } else if (op == Op.jmpIfTrue) {
          if (this.toBooleanValue(this.reg(base, inst.a))) ip = usize(i64(ip) + i64(bcI16(inst)));
        } else if (op == Op.jmpIfFalse) {
          if (!this.toBooleanValue(this.reg(base, inst.a))) ip = usize(i64(ip) + i64(bcI16(inst)));
        } else if (op == Op.jmpIfNotNullish) {
          const tested = this.reg(base, inst.a);
          if (!(isNull(tested) || isUndefined(tested))) ip = usize(i64(ip) + i64(bcI16(inst)));
        } else if (op == Op.jmpIfNullish) {
          const tested = this.reg(base, inst.a);
          if (isNull(tested) || isUndefined(tested)) ip = usize(i64(ip) + i64(bcI16(inst)));
        } else if (op == Op.sub) {
          const operand5 = numericSub(this.reg(base, inst.b), this.reg(base, inst.c));
          this.setReg(base, inst.a, operand5);
        } else if (op == Op.mul) {
          const operand6 = numericMul(this.reg(base, inst.b), this.reg(base, inst.c));
          this.setReg(base, inst.a, operand6);
        } else if (op == Op.div) {
          const operand7 = numericDiv(this.reg(base, inst.b), this.reg(base, inst.c));
          this.setReg(base, inst.a, operand7);
        } else if (op == Op.mod) {
          const operand8 = numericMod(this.reg(base, inst.b), this.reg(base, inst.c));
          this.setReg(base, inst.a, operand8);
        } else if (op == Op.pow) {
          const operand9 = doubleValue(nativePow(toNumber(this.reg(base, inst.b)), toNumber(this.reg(base, inst.c))));
          this.setReg(base, inst.a, operand9);
        } else if (op == Op.neg) {
          const operand10 = numericNeg(this.reg(base, inst.b));
          this.setReg(base, inst.a, operand10);
        } else if (op == Op.logicalNot) {
          const negated = booleanValue(!this.toBooleanValue(this.reg(base, inst.b)));
          this.setReg(base, inst.a, negated);
        } else if (op == Op.bitNot) {
          const operand12 = int32Value(~toInt32(this.reg(base, inst.b)));
          this.setReg(base, inst.a, operand12);
        } else if (op == Op.bitAnd) {
          const operand13 = int32Value(toInt32(this.reg(base, inst.b)) & toInt32(this.reg(base, inst.c)));
          this.setReg(base, inst.a, operand13);
        } else if (op == Op.bitOr) {
          const operand14 = int32Value(toInt32(this.reg(base, inst.b)) | toInt32(this.reg(base, inst.c)));
          this.setReg(base, inst.a, operand14);
        } else if (op == Op.bitXor) {
          const operand15 = int32Value(toInt32(this.reg(base, inst.b)) ^ toInt32(this.reg(base, inst.c)));
          this.setReg(base, inst.a, operand15);
        } else if (op == Op.shl) {
          const shift = u32(toUint32(this.reg(base, inst.c)) & 31);
          const operand16 = int32Value(i32.fromBits(toInt32(this.reg(base, inst.b)).toBits() << shift));
          this.setReg(base, inst.a, operand16);
        } else if (op == Op.shr) {
          const shift = u32(toUint32(this.reg(base, inst.c)) & 31);
          const operand17 = int32Value(toInt32(this.reg(base, inst.b)) >> i32(shift));
          this.setReg(base, inst.a, operand17);
        } else if (op == Op.uShr) {
          const shift = u32(toUint32(this.reg(base, inst.c)) & 31);
          const shifted = toUint32(this.reg(base, inst.b)) >> shift;
          this.setReg(base, inst.a, uint32ToValue(shifted));
        } else if (op == Op.returnOp) {
          const value = this.reg(base, inst.a);
          const frame = this.popFrame();
          if (this.frameCount <= entryDepth) {
            result = value;
          } else {
            const callerBase = this.frames[usize(this.frameCount - 1)].regsBase;
            this.setReg(callerBase, frame.returnDst, value);
          }
          returned = true;
        } else {
          // Not yet implemented: treat as an internal error.
          this.frames[frameIndex].ip = ip;
          this.popFrame();
          return RunResult({ isThrow: true, value: undefinedValue() });
        }
      }
      if (!returned) {
        // Fell off the end without Return: pop and yield undefined.
        this.popFrame();
      }
    }
    return RunResult({ isThrow: false, value: result });
  }
}

export function createRuntime(): Runtime {
  let globals = Array<Global>();
  // Value properties of the global object the engine has so far.
  globals.push(Global({ name: "NaN", value: doubleValue(nativeNan()), defined: true }));
  globals.push(Global({ name: "Infinity", value: doubleValue(1.0 / 0.0), defined: true }));
  globals.push(Global({ name: "undefined", value: undefinedValue(), defined: true }));
  return Runtime({
    heap: createHeap(), functions: Array<FunctionCode>(), globals: move globals,
    atoms: Array<u32>(), atomCount: 0,
    regStack: Array<Value>(), regTop: 0, frames: Array<Frame>(), frameCount: 0,
    hadError: false, lastError: undefinedValue(),
  });
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
