// Runtime -- the per-context engine state the interpreter runs against:
// the heap, compiled functions, globals, the register stack, and call
// frames. One Runtime per context; it lives inside the context registry.
//
// The interpreter is a method on Runtime so every piece of mutable state is
// reached through `this`. Z rejects `inout` through indexed storage, but a
// method call on the projection is accepted, and the registry calls
// `slots[i].runtime.eval(...)`.

import { expect } from "std/test";
import { Value, int32Value, doubleValue, undefinedValue, nullValue, booleanValue, isInt32, asInt32, isDouble, asDouble, isNumber, isUndefined, isNull, isBoolean, isTrue, NUMBER_TAG } from "./value.zs";
import { Heap, createHeap } from "./heap.zs";
import { Op, Inst, FunctionCode, bcU16, bcI16 } from "./bytecode.zs";

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
          const operand4 = numericAdd(this.reg(base, inst.b), this.reg(base, inst.c));
          this.setReg(base, inst.a, operand4);
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
          const operand11 = booleanValue(!toBoolean(this.reg(base, inst.b)));
          this.setReg(base, inst.a, operand11);
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
  return Runtime({
    heap: createHeap(), functions: Array<FunctionCode>(), globals: Array<Global>(),
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
