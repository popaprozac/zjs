// Bytecode -- emitted by the compiler, consumed by the interpreter.
//
// Uniform 4-byte instructions { op, a, b, c }; operands reinterpreted per
// opcode, with `bc` forming a u16 / i16 where an opcode needs one. Opcode
// ORDER mirrors src/bytecode.zc and `opCode` reproduces its numbering so
// disassemblies from both engines can be compared where the compilers
// agree. Generated from src/bytecode.zc; do not reorder by hand.
//
// A compiled function is a FunctionCode: its instructions, constant pool,
// and register layout. Function *values* are heap cells that refer to a
// FunctionCode by index, so the code lives in one Z-owned Array and no
// pointer crosses into the object graph.

import { expect } from "std/test";
import { Value } from "./value.zs";

export enum Op {
  halt,
  loadConst,
  loadInt,
  loadUndefined,
  loadHole,
  throwIfHole,
  loadNull,
  loadTrue,
  loadFalse,
  mov,
  defineGlobal,
  loadGlobal,
  storeGlobal,
  loadGlobalOrUndefined,
  withEnter,
  withLeave,
  withLookup,
  add,
  sub,
  mul,
  div,
  mod,
  pow,
  addImm,
  subImm,
  cmpLtImm,
  cmpLeImm,
  cmpGtImm,
  cmpGeImm,
  bitAnd,
  bitOr,
  bitXor,
  shl,
  shr,
  uShr,
  cmpEq,
  cmpNe,
  cmpStrictEq,
  cmpStrictNe,
  cmpLt,
  cmpLe,
  cmpGt,
  cmpGe,
  neg,
  bitNot,
  logicalNot,
  jmp,
  jmpIfTrue,
  jmpIfFalse,
  jmpIfNotNullish,
  jmpIfNullish,
  jmpIfNotLt,
  jmpIfNotLe,
  jmpIfNotGt,
  jmpIfNotGe,
  jmpIfNotLtImm,
  jmpIfNotLeImm,
  jmpIfNotGtImm,
  jmpIfNotGeImm,
  jmpIfNotEq,
  jmpIfNotNe,
  jmpIfNotStrictEq,
  jmpIfNotStrictNe,
  returnOp,
  invoke,
  tailInvoke,
  loadProp,
  storeProp,
  mathSqrt,
  mathAbs,
  mathFloor,
  mathCeil,
  iterPrepare,
  arrayLength,
  deleteElem,
  buildArguments,
  buildRestArgs,
  importBind,
  exportBind,
  dynamicImport,
  importMeta,
  awaitOp,
  yieldOp,
  generatorStart,
  templateObject,
  arrayPush,
  arraySpread,
  objectSpread,
  arrayRestFrom,
  assertCoercible,
  iterGet,
  iterGetAsync,
  iterStep,
  iterRestCollect,
  iterClose,
  iterNextRaw,
  spreadInvoke,
  spreadMethodInvoke,
  spreadNewInvoke,
  methodInvoke,
  tailMethodInvoke,
  defineGetter,
  defineSetter,
  defineMethodGetter,
  defineMethodSetter,
  makeClosure,
  loadEnv,
  loadCallee,
  newRegex,
  newRegexR,
  newObject,
  newArray,
  loadElem,
  storeElem,
  throwOp,
  enterTry,
  leaveTry,
  inOp,
  instanceofOp,
  loadThis,
  loadNewTarget,
  newInvoke,
  typeofOp,
  setProto,
  superCall,
  defineMethod,
  defineMethodComputed,
  setParentCtor,
  setFunctionName,
  initObjData,
  spreadSuperCall,
  jmpIfLt,
  jmpIfLe,
  jmpIfGt,
  jmpIfGe,
  jmpIfLtImm,
  jmpIfLeImm,
  jmpIfGtImm,
  jmpIfGeImm,
  invokeGlobal,
  privateCheck,
  throwTypeError,
  storeGlobalStrict,
  iterCloseQuiet,
  jmpIfNotGenReturn,
  // Beyond the reference's table. Captured bindings live in environment
  // cells addressed by slot, where the reference stores them in property
  // bags by name.
  newEnv,          // bc = slot count: the frame's environment becomes a new one chained to the old.
  loadEnvSlot,     // a = dst, b = hops outward, c = slot.
  storeEnvSlot,    // a = src, b = hops outward, c = slot.
  objectRest,      // a = dst, b = source, c = array of keys to leave out.
}

export struct Inst {
  op: Op;
  a: u8;
  b: u8;
  c: u8;
}

export function instA(op: Op, a: u8): Inst {
  return Inst({ op: op, a: a, b: 0, c: 0 });
}

export function instAB(op: Op, a: u8, b: u8): Inst {
  return Inst({ op: op, a: a, b: b, c: 0 });
}

export function instABC(op: Op, a: u8, b: u8, c: u8): Inst {
  return Inst({ op: op, a: a, b: b, c: c });
}

export function instAU16(op: Op, a: u8, value: u16): Inst {
  return Inst({ op: op, a: a, b: u8(value & 0xFF), c: u8((value >> 8) & 0xFF) });
}

// A signed 16-bit operand is stored as its two's-complement bit pattern.
export function instAI16(op: Op, a: u8, value: i32): Inst {
  const bits: u32 = u32(i64(value) & 0xFFFF);
  return Inst({ op: op, a: a, b: u8(bits & 0xFF), c: u8((bits >> 8) & 0xFF) });
}

export function instU16(op: Op, value: u16): Inst {
  return instAU16(op, 0, value);
}

export function instI16(op: Op, value: i32): Inst {
  return instAI16(op, 0, value);
}

export function bcU16(inst: Inst): u16 {
  return u16(inst.b) | (u16(inst.c) << 8);
}

export function bcI16(inst: Inst): i32 {
  const bits: u32 = u32(inst.b) | (u32(inst.c) << 8);
  if ((bits & 0x8000) != 0) return i32(i64(bits) - 0x1_0000);
  return i32(bits);
}

// Reference numbering (C enum order in src/bytecode.zc).
export function opCode(op: Op): i32 {
  return match (op) {
    halt => 0;
    loadConst => 1;
    loadInt => 2;
    loadUndefined => 3;
    loadHole => 4;
    throwIfHole => 5;
    loadNull => 6;
    loadTrue => 7;
    loadFalse => 8;
    mov => 9;
    defineGlobal => 10;
    loadGlobal => 11;
    storeGlobal => 12;
    loadGlobalOrUndefined => 13;
    withEnter => 14;
    withLeave => 15;
    withLookup => 16;
    add => 17;
    sub => 18;
    mul => 19;
    div => 20;
    mod => 21;
    pow => 22;
    addImm => 23;
    subImm => 24;
    cmpLtImm => 25;
    cmpLeImm => 26;
    cmpGtImm => 27;
    cmpGeImm => 28;
    bitAnd => 29;
    bitOr => 30;
    bitXor => 31;
    shl => 32;
    shr => 33;
    uShr => 34;
    cmpEq => 35;
    cmpNe => 36;
    cmpStrictEq => 37;
    cmpStrictNe => 38;
    cmpLt => 39;
    cmpLe => 40;
    cmpGt => 41;
    cmpGe => 42;
    neg => 43;
    bitNot => 44;
    logicalNot => 45;
    jmp => 46;
    jmpIfTrue => 47;
    jmpIfFalse => 48;
    jmpIfNotNullish => 49;
    jmpIfNullish => 50;
    jmpIfNotLt => 51;
    jmpIfNotLe => 52;
    jmpIfNotGt => 53;
    jmpIfNotGe => 54;
    jmpIfNotLtImm => 55;
    jmpIfNotLeImm => 56;
    jmpIfNotGtImm => 57;
    jmpIfNotGeImm => 58;
    jmpIfNotEq => 59;
    jmpIfNotNe => 60;
    jmpIfNotStrictEq => 61;
    jmpIfNotStrictNe => 62;
    returnOp => 63;
    invoke => 64;
    tailInvoke => 65;
    loadProp => 66;
    storeProp => 67;
    mathSqrt => 68;
    mathAbs => 69;
    mathFloor => 70;
    mathCeil => 71;
    iterPrepare => 72;
    arrayLength => 73;
    deleteElem => 74;
    buildArguments => 75;
    buildRestArgs => 76;
    importBind => 77;
    exportBind => 78;
    dynamicImport => 79;
    importMeta => 80;
    awaitOp => 81;
    yieldOp => 82;
    generatorStart => 83;
    templateObject => 84;
    arrayPush => 85;
    arraySpread => 86;
    objectSpread => 87;
    arrayRestFrom => 88;
    assertCoercible => 89;
    iterGet => 90;
    iterGetAsync => 91;
    iterStep => 92;
    iterRestCollect => 93;
    iterClose => 94;
    iterNextRaw => 95;
    spreadInvoke => 96;
    spreadMethodInvoke => 97;
    spreadNewInvoke => 98;
    methodInvoke => 99;
    tailMethodInvoke => 100;
    defineGetter => 101;
    defineSetter => 102;
    defineMethodGetter => 103;
    defineMethodSetter => 104;
    makeClosure => 105;
    loadEnv => 106;
    loadCallee => 107;
    newRegex => 108;
    newRegexR => 109;
    newObject => 110;
    newArray => 111;
    loadElem => 112;
    storeElem => 113;
    throwOp => 114;
    enterTry => 115;
    leaveTry => 116;
    inOp => 117;
    instanceofOp => 118;
    loadThis => 119;
    loadNewTarget => 120;
    newInvoke => 121;
    typeofOp => 122;
    setProto => 123;
    superCall => 124;
    defineMethod => 125;
    defineMethodComputed => 126;
    setParentCtor => 127;
    setFunctionName => 128;
    initObjData => 129;
    spreadSuperCall => 130;
    jmpIfLt => 131;
    jmpIfLe => 132;
    jmpIfGt => 133;
    jmpIfGe => 134;
    jmpIfLtImm => 135;
    jmpIfLeImm => 136;
    jmpIfGtImm => 137;
    jmpIfGeImm => 138;
    invokeGlobal => 139;
    privateCheck => 140;
    throwTypeError => 141;
    storeGlobalStrict => 142;
    iterCloseQuiet => 143;
    jmpIfNotGenReturn => 144;
    newEnv => 145;
    loadEnvSlot => 146;
    storeEnvSlot => 147;
    objectRest => 148;
  };
}

// One compiled function. Fields beyond the code and constants are added
// as the interpreter grows to need them (inline caches, template sites,
// closure environment, class flags).
export struct FunctionCode {
  code: Array<Inst>;
  constants: Array<Value>;
  // Interned names for LoadProp / StoreProp, indexed by the instruction's
  // name operand. This is the reference's inline-cache slot table; the
  // cache itself is a performance-phase addition.
  propertyNames: Array<u32>;
  // The declared name as an atom, 0 for none.
  nameAtom: u32;
  registerCount: u32;
  fixedRegs: u32;
  paramCount: u32;
  thisReg: i32;
  expectedArgCount: u32;
  isArrow: boolean;
  isAsync: boolean;
  isGenerator: boolean;
  strict: boolean;
}

export function createFunctionCode(): FunctionCode {
  return FunctionCode({
    code: Array<Inst>(), constants: Array<Value>(), propertyNames: Array<u32>(), nameAtom: 0, registerCount: 0, fixedRegs: 0,
    paramCount: 0, thisReg: -1, expectedArgCount: 0,
    isArrow: false, isAsync: false, isGenerator: false, strict: false,
  });
}

test "u16 and i16 operands round-trip through b and c" {
  const wide: u16 = 0xBEEF;
  expect(bcU16(instAU16(Op.loadConst, 1, wide))).toEqual(wide);
  expect(bcI16(instAI16(Op.jmp, 0, -2))).toEqual(-2);
  expect(bcI16(instAI16(Op.jmp, 0, 32767))).toEqual(32767);
  expect(bcI16(instAI16(Op.jmp, 0, -32768))).toEqual(-32768);
}

test "opcode numbering mirrors the reference" {
  expect(opCode(Op.halt)).toEqual(0);
  expect(opCode(Op.loadConst)).toEqual(1);
  expect(opCode(Op.jmpIfNotGenReturn)).toEqual(144);
}
