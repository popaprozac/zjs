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
  // a and b (or a and a 24-bit literal, its low 16 bits in b and c and
  // its top 8 in the next word's a) compared, the offset in the next
  // word's bc: jumps when the comparison is false, or with d = 1 when it
  // is true (a loop's test at its bottom).
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
  // a and b compared with ===, the offset in the next word's bc: jumps
  // when they differ, or with d = 1 when they are the same (`!==` in a
  // condition, and `===` at a loop's bottom).
  jmpIfNotStrictEq,
  jmpIfNotStrictNe,
  returnOp,
  // a = result, b = callee, c = first argument, d = argument count: the
  // callee and the arguments each where they already are when they can.
  // methodInvoke: b = callee, c = receiver, arguments from b + 2;
  // newInvoke as invoke.
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
  makeClosure,  // a = dst, bc = the function's constant: a closure over the current environment.
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
  throwTypeError,  // bc = message constant: throws a TypeError with that message (an async delegation's missing throw method).
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
  // Classes.
  newPrivateName,  // a = dst, bc = constant index of the description: a fresh private key.
  defineField,     // a = object, b = key, c = value: CreateDataPropertyOrThrow.
  loadSuper,       // a = dst, b = key: `super[key]` with the frame's `this` as receiver.
  storeSuper,      // a = key, b = value: `super[key] = value`.
  initClass,       // a = constructor, b = prototype, c = parent: wire a class with a heritage.
  initClassBase,   // a = constructor, b = prototype: wire a class without one.
  yieldRaw,        // a = dst, b = value: an async generator yields a delegate's value without awaiting it.
  envToReg,        // a = dst: the frame's current environment, as a cell index.
  renewEnv,        // a = env register, bc = slot count: a fresh environment with the same parent and copied slots replaces it (per-iteration bindings).
  exitEnv,         // a = env register: the frame's environment becomes that environment's parent.
  throwConstAssign, // throws a TypeError: assignment to a constant binding.
  checkThis,       // a = register: throws a ReferenceError when it holds an uninitialized `this` (a derived constructor before super() returns).
  yieldDelegate,   // a = dst, b = result object: a generator yields a delegate's iterator result as it is; a receives what the resumption sends.
  resumeMode,      // a = dst: how the generator was last resumed (0 next, 1 throw, 2 return), as an int32.
  iterNextWith,    // a = result, b = iterator, c = value: iterator.next(value), checked to be an object.
  iterThrowWith,   // a = result, b = iterator, c = value: iterator.throw(value); without one, closes the iterator and throws a TypeError.
  iterReturnWith,  // a = result, b = iterator, c = value: iterator.return(value); without one, a done result holding the value.
  jmpIfNotReturn,  // bc = offset: jumps unless the generator's last resumption was a return (after a plain yield: fall through into the return).
  iterCallNext,    // a = result, b = iterator, c = value: iterator.next(value) as returned, unchecked (an async delegation awaits it first).
  iterCallThrow,   // a = result, b = iterator, c = value: iterator.throw(value) as returned, or the deleted marker when there is no such method.
  iterCallReturn,  // a = result, b = iterator, c = value: iterator.return(value) as returned, or the deleted marker when there is no such method.
  isAbsent,        // a = dst, b = src: whether src holds the deleted marker.
  requireIterResult, // a = value: throws a TypeError unless it is an object.
  inc, // a = dst, b = src: ToNumeric(src) + 1, an int32 kept an int32 while it fits.
  dec, // a = dst, b = src: ToNumeric(src) - 1.
  toNumeric, // a = dst, b = src: ToNumeric(src), a postfix update's value.
  // a = dst, b = left, c and d = the right operand as a signed 16-bit
  // integer, c its low byte: the bitwise and shift operators against a
  // small integer literal (a shift reads c alone, all its count needs).
  bitOrImm,
  bitAndImm,
  bitXorImm,
  shlImm,
  shrImm,
  uShrImm,
  // a = object, b = name slot, c = value: an object literal's property
  // with a name known at compile time, through the site's cache.
  defineNamed,
  // a = dst, b = left, c and d = the right operand as a signed 16-bit
  // integer: `*` and `%` against a small integer literal.
  mulImm,
  modImm,
  // a against a 24-bit literal, as jmpIfNotLtImm, compared with ===; d
  // as in jmpIfNotStrictEq.
  jmpIfNotStrictEqImm,
  // a = dst, b = right operand, c = hops, d = slot: `x += b` on a binding
  // in an environment, the sum stored there and left in a.
  envAdd,
  // A call spelled `eval(...)`: as invoke, and when the callee is the
  // intrinsic eval, the code sees the caller's bindings. The next word:
  // a = the register holding `this`, bc = the call's EvalSite.
  directEval,
  // The bindings a sloppy direct eval adds to a function live in an
  // object in b hops, slot c, of the environment chain; the name is the
  // constant in the next word's bc. loadEvalVar: a = the binding's
  // value, or the deleted marker when there is none. storeEvalVar: a =
  // whether there is one, assigned the next word's register a when so.
  // declareEvalVar: the object made if need be, the binding added as
  // undefined unless it exists.
  loadEvalVar,
  storeEvalVar,
  declareEvalVar,
  // a = ToString(b): a template substitution's conversion (the string
  // hint, unlike `+`).
  toStringOp,
  // a = the c registers from b joined as `+` joins them, in one string:
  // each piece after the first converted in order (as `+` would), then
  // all appended at once. A first piece that is not a string: d = 0, the
  // additions left to right; d = 1 (`x += "a" + y`), the rest joined
  // first, then added to it.
  concatN,
  // A counted loop's step and its test at the bottom in one: a = the
  // counter, stepped as `++` steps it, then compared with the bound, a
  // 24-bit literal as in jmpIfNotLtImm (incJmpIfLtImm) or register b
  // (incJmpIfLt), or the `length` of the value in register b
  // (incJmpIfLtLength); jumps back by the next word's offset while the
  // counter is less.
  incJmpIfLtImm,
  incJmpIfLt,
  incJmpIfLtLength,
  // a = (b + c) | 0: an addition truncated to a 32-bit integer, as `+`
  // then `| 0`.
  addToInt32,
  // a = b[c].name, d the name slot: loadElem then loadProp, the element
  // not kept.
  loadElemProp,
  // a = b[k], k a non-negative integer literal in c (low byte) and d.
  loadElemImm,
  // The globals a script or eval code declares (its function's
  // declaredGlobals) become defined: the start of the code, where
  // GlobalDeclarationInstantiation makes them, not its compile.
  declareGlobals,
}

export struct Inst {
  op: Op;
  a: u8;
  b: u8;
  c: u8;
  // A fourth operand, where the op's tag leaves a byte: invoke's
  // argument count.
  d: u8;
}

export function instA(op: Op, a: u8): Inst {
  return Inst({ op: op, a: a, b: 0, c: 0, d: 0 });
}

export function instAB(op: Op, a: u8, b: u8): Inst {
  return Inst({ op: op, a: a, b: b, c: 0, d: 0 });
}

export function instABC(op: Op, a: u8, b: u8, c: u8): Inst {
  return Inst({ op: op, a: a, b: b, c: c, d: 0 });
}

export function instABCD(op: Op, a: u8, b: u8, c: u8, d: u8): Inst {
  return Inst({ op: op, a: a, b: b, c: c, d: d });
}

export function instAU16(op: Op, a: u8, value: u16): Inst {
  return Inst({ op: op, a: a, b: u8(value & 0xFF), c: u8((value >> 8) & 0xFF), d: 0 });
}

// A signed 16-bit operand is stored as its two's-complement bit pattern.
export function instAI16(op: Op, a: u8, value: i32): Inst {
  const bits: u32 = u32(i64(value) & 0xFFFF);
  return Inst({ op: op, a: a, b: u8(bits & 0xFF), c: u8((bits >> 8) & 0xFF), d: 0 });
}

export function instU16(op: Op, value: u16): Inst {
  return instAU16(op, 0, value);
}

export function instI16(op: Op, value: i32): Inst {
  return instAI16(op, 0, value);
}

// A jump's offset, in instructions from the one after it: 24 bits signed,
// in b, c, and d, so a function may run to millions of instructions. A
// jump never needs d for anything else.
export const JUMP_OFFSET_LIMIT: i32 = 0x7F_FFFF;

export function instAJump(op: Op, a: u8, offset: i32): Inst {
  const bits: u32 = u32(i64(offset) & 0xFF_FFFF);
  return Inst({ op: op, a: a, b: u8(bits & 0xFF), c: u8((bits >> 8) & 0xFF), d: u8(bits >> 16) });
}

export function jumpOffset(inst: Inst): i32 {
  const bits: u32 = u32(inst.b) | (u32(inst.c) << 8) | (u32(inst.d) << 16);
  if ((bits & 0x80_0000) != 0) return i32(i64(bits) - 0x100_0000);
  return i32(bits);
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
    newPrivateName => 149;
    defineField => 150;
    loadSuper => 151;
    storeSuper => 152;
    initClass => 153;
    initClassBase => 154;
    yieldRaw => 155;
    envToReg => 156;
    renewEnv => 157;
    exitEnv => 158;
    throwConstAssign => 159;
    checkThis => 160;
    yieldDelegate => 161;
    resumeMode => 162;
    iterNextWith => 163;
    iterThrowWith => 164;
    iterReturnWith => 165;
    jmpIfNotReturn => 166;
    iterCallNext => 167;
    iterCallThrow => 168;
    iterCallReturn => 169;
    isAbsent => 170;
    requireIterResult => 171;
    inc => 172;
    dec => 173;
    toNumeric => 174;
    bitOrImm => 175;
    bitAndImm => 176;
    bitXorImm => 177;
    shlImm => 178;
    shrImm => 179;
    uShrImm => 180;
    defineNamed => 181;
    mulImm => 182;
    modImm => 183;
    jmpIfNotStrictEqImm => 184;
    envAdd => 185;
    directEval => 186;
    loadEvalVar => 187;
    storeEvalVar => 188;
    declareEvalVar => 189;
    toStringOp => 190;
    concatN => 191;
    incJmpIfLtImm => 192;
    incJmpIfLt => 193;
    incJmpIfLtLength => 194;
    addToInt32 => 195;
    loadElemProp => 196;
    loadElemImm => 197;
    declareGlobals => 198;
  };
}

// Every opcode by its number, opCode's inverse: what a bytecode file
// names by number is read back through it.
export function opsByCode(): Array<Op> {
  let ops = Array<Op>.withCapacity(199);
  ops.push(Op.halt);
  ops.push(Op.loadConst);
  ops.push(Op.loadInt);
  ops.push(Op.loadUndefined);
  ops.push(Op.loadHole);
  ops.push(Op.throwIfHole);
  ops.push(Op.loadNull);
  ops.push(Op.loadTrue);
  ops.push(Op.loadFalse);
  ops.push(Op.mov);
  ops.push(Op.defineGlobal);
  ops.push(Op.loadGlobal);
  ops.push(Op.storeGlobal);
  ops.push(Op.loadGlobalOrUndefined);
  ops.push(Op.withEnter);
  ops.push(Op.withLeave);
  ops.push(Op.withLookup);
  ops.push(Op.add);
  ops.push(Op.sub);
  ops.push(Op.mul);
  ops.push(Op.div);
  ops.push(Op.mod);
  ops.push(Op.pow);
  ops.push(Op.addImm);
  ops.push(Op.subImm);
  ops.push(Op.cmpLtImm);
  ops.push(Op.cmpLeImm);
  ops.push(Op.cmpGtImm);
  ops.push(Op.cmpGeImm);
  ops.push(Op.bitAnd);
  ops.push(Op.bitOr);
  ops.push(Op.bitXor);
  ops.push(Op.shl);
  ops.push(Op.shr);
  ops.push(Op.uShr);
  ops.push(Op.cmpEq);
  ops.push(Op.cmpNe);
  ops.push(Op.cmpStrictEq);
  ops.push(Op.cmpStrictNe);
  ops.push(Op.cmpLt);
  ops.push(Op.cmpLe);
  ops.push(Op.cmpGt);
  ops.push(Op.cmpGe);
  ops.push(Op.neg);
  ops.push(Op.bitNot);
  ops.push(Op.logicalNot);
  ops.push(Op.jmp);
  ops.push(Op.jmpIfTrue);
  ops.push(Op.jmpIfFalse);
  ops.push(Op.jmpIfNotNullish);
  ops.push(Op.jmpIfNullish);
  ops.push(Op.jmpIfNotLt);
  ops.push(Op.jmpIfNotLe);
  ops.push(Op.jmpIfNotGt);
  ops.push(Op.jmpIfNotGe);
  ops.push(Op.jmpIfNotLtImm);
  ops.push(Op.jmpIfNotLeImm);
  ops.push(Op.jmpIfNotGtImm);
  ops.push(Op.jmpIfNotGeImm);
  ops.push(Op.jmpIfNotEq);
  ops.push(Op.jmpIfNotNe);
  ops.push(Op.jmpIfNotStrictEq);
  ops.push(Op.jmpIfNotStrictNe);
  ops.push(Op.returnOp);
  ops.push(Op.invoke);
  ops.push(Op.tailInvoke);
  ops.push(Op.loadProp);
  ops.push(Op.storeProp);
  ops.push(Op.mathSqrt);
  ops.push(Op.mathAbs);
  ops.push(Op.mathFloor);
  ops.push(Op.mathCeil);
  ops.push(Op.iterPrepare);
  ops.push(Op.arrayLength);
  ops.push(Op.deleteElem);
  ops.push(Op.buildArguments);
  ops.push(Op.buildRestArgs);
  ops.push(Op.importBind);
  ops.push(Op.exportBind);
  ops.push(Op.dynamicImport);
  ops.push(Op.importMeta);
  ops.push(Op.awaitOp);
  ops.push(Op.yieldOp);
  ops.push(Op.generatorStart);
  ops.push(Op.templateObject);
  ops.push(Op.arrayPush);
  ops.push(Op.arraySpread);
  ops.push(Op.objectSpread);
  ops.push(Op.arrayRestFrom);
  ops.push(Op.assertCoercible);
  ops.push(Op.iterGet);
  ops.push(Op.iterGetAsync);
  ops.push(Op.iterStep);
  ops.push(Op.iterRestCollect);
  ops.push(Op.iterClose);
  ops.push(Op.iterNextRaw);
  ops.push(Op.spreadInvoke);
  ops.push(Op.spreadMethodInvoke);
  ops.push(Op.spreadNewInvoke);
  ops.push(Op.methodInvoke);
  ops.push(Op.tailMethodInvoke);
  ops.push(Op.defineGetter);
  ops.push(Op.defineSetter);
  ops.push(Op.defineMethodGetter);
  ops.push(Op.defineMethodSetter);
  ops.push(Op.makeClosure);
  ops.push(Op.loadEnv);
  ops.push(Op.loadCallee);
  ops.push(Op.newRegex);
  ops.push(Op.newRegexR);
  ops.push(Op.newObject);
  ops.push(Op.newArray);
  ops.push(Op.loadElem);
  ops.push(Op.storeElem);
  ops.push(Op.throwOp);
  ops.push(Op.enterTry);
  ops.push(Op.leaveTry);
  ops.push(Op.inOp);
  ops.push(Op.instanceofOp);
  ops.push(Op.loadThis);
  ops.push(Op.loadNewTarget);
  ops.push(Op.newInvoke);
  ops.push(Op.typeofOp);
  ops.push(Op.setProto);
  ops.push(Op.superCall);
  ops.push(Op.defineMethod);
  ops.push(Op.defineMethodComputed);
  ops.push(Op.setParentCtor);
  ops.push(Op.setFunctionName);
  ops.push(Op.initObjData);
  ops.push(Op.spreadSuperCall);
  ops.push(Op.jmpIfLt);
  ops.push(Op.jmpIfLe);
  ops.push(Op.jmpIfGt);
  ops.push(Op.jmpIfGe);
  ops.push(Op.jmpIfLtImm);
  ops.push(Op.jmpIfLeImm);
  ops.push(Op.jmpIfGtImm);
  ops.push(Op.jmpIfGeImm);
  ops.push(Op.invokeGlobal);
  ops.push(Op.privateCheck);
  ops.push(Op.throwTypeError);
  ops.push(Op.storeGlobalStrict);
  ops.push(Op.iterCloseQuiet);
  ops.push(Op.jmpIfNotGenReturn);
  ops.push(Op.newEnv);
  ops.push(Op.loadEnvSlot);
  ops.push(Op.storeEnvSlot);
  ops.push(Op.objectRest);
  ops.push(Op.newPrivateName);
  ops.push(Op.defineField);
  ops.push(Op.loadSuper);
  ops.push(Op.storeSuper);
  ops.push(Op.initClass);
  ops.push(Op.initClassBase);
  ops.push(Op.yieldRaw);
  ops.push(Op.envToReg);
  ops.push(Op.renewEnv);
  ops.push(Op.exitEnv);
  ops.push(Op.throwConstAssign);
  ops.push(Op.checkThis);
  ops.push(Op.yieldDelegate);
  ops.push(Op.resumeMode);
  ops.push(Op.iterNextWith);
  ops.push(Op.iterThrowWith);
  ops.push(Op.iterReturnWith);
  ops.push(Op.jmpIfNotReturn);
  ops.push(Op.iterCallNext);
  ops.push(Op.iterCallThrow);
  ops.push(Op.iterCallReturn);
  ops.push(Op.isAbsent);
  ops.push(Op.requireIterResult);
  ops.push(Op.inc);
  ops.push(Op.dec);
  ops.push(Op.toNumeric);
  ops.push(Op.bitOrImm);
  ops.push(Op.bitAndImm);
  ops.push(Op.bitXorImm);
  ops.push(Op.shlImm);
  ops.push(Op.shrImm);
  ops.push(Op.uShrImm);
  ops.push(Op.defineNamed);
  ops.push(Op.mulImm);
  ops.push(Op.modImm);
  ops.push(Op.jmpIfNotStrictEqImm);
  ops.push(Op.envAdd);
  ops.push(Op.directEval);
  ops.push(Op.loadEvalVar);
  ops.push(Op.storeEvalVar);
  ops.push(Op.declareEvalVar);
  ops.push(Op.toStringOp);
  ops.push(Op.concatN);
  ops.push(Op.incJmpIfLtImm);
  ops.push(Op.incJmpIfLt);
  ops.push(Op.incJmpIfLtLength);
  ops.push(Op.addToInt32);
  ops.push(Op.loadElemProp);
  ops.push(Op.loadElemImm);
  ops.push(Op.declareGlobals);
  return ops;
}

// The instruction set a bytecode file was written for: its opcodes, their
// operands, and what each does. Moves whenever any of them changes, so a
// file from another engine is refused rather than misread; the test
// below pins it beside the opcode count, which a new opcode changes.
export const INSTRUCTION_SET_VERSION: u32 = 2;

// One property access site's inline cache, kept per property name of a
// function: the receiver's hidden class and where the property was
// last found, so the next access with the same shape skips the lookup.
// A transition entry records the class an added property moves the
// receiver to, and the prototype chain (at most two objects, then
// null) that was checked to hold no such property.
export const CACHE_EMPTY: u8 = 0;
export const CACHE_OWN: u8 = 1;
export const CACHE_PROTO: u8 = 2;
export const CACHE_TRANSITION: u8 = 3;
// A read on an array with no named properties of its own, or on a
// string, of a name its prototype holds: the prototype and its class,
// and the slot there.
export const CACHE_INHERITED: u8 = 4;
// An object literal's property defined by a transition: the literal's
// class before and after, and the slot.
export const CACHE_DEFINE: u8 = 5;

export struct PropertyCache {
  kind: u8;
  depth: u8;
  // The attributes of the property the first entry found, fixed by its
  // class: a hit needs no attribute check.
  attr: u8;
  receiverClass: u32;
  slot: u32;
  targetClass: u32;
  proto1: u32;
  proto1Class: u32;
  proto2: u32;
  proto2Class: u32;
  // A read site that sees own properties on several shapes keeps up to
  // three more (class, slot) pairs beside the first, replaced in turn
  // once full: a polymorphic site stops missing.
  extraCount: u8;
  extraNext: u8;
  extraClass0: u32;
  extraSlot0: u32;
  extraClass1: u32;
  extraSlot1: u32;
  extraClass2: u32;
  extraSlot2: u32;
}

export function emptyCache(): PropertyCache {
  return PropertyCache({ kind: CACHE_EMPTY, attr: 0, depth: 0, receiverClass: 0, slot: 0, targetClass: 0, proto1: 0, proto1Class: 0, proto2: 0, proto2Class: 0, extraCount: 0, extraNext: 0, extraClass0: 0, extraSlot0: 0, extraClass1: 0, extraSlot1: 0, extraClass2: 0, extraSlot2: 0 });
}

// What a direct eval call sees: the scopes around it as the compiler saw
// them at the call, outermost first, each binding spelled in `names` and
// held in an environment slot. The eval code compiles against them as a
// function nested at the call would.
export struct EvalBinding {
  nameStart: u32;
  nameLength: u32;
  slot: u32;
  // Nested environments between the scope's function environment and
  // the one holding the binding.
  depth: u32;
  isConst: boolean;
  // A var of this name from sloppy eval code is a SyntaxError: the
  // binding is lexical (let, const, class, a block's function), or a
  // parameter and the call is in the parameter list.
  conflicts: boolean;
  // May still hold the hole: reads check.
  checked: boolean;
}

export struct EvalLevel {
  bindings: Array<EvalBinding>;
  hasEnv: boolean;
  openEnvs: u32;
  isArrow: boolean;
  thisSlot: i32;
  // The slot of the object holding the bindings a sloppy direct eval
  // adds to the function, -1 for none.
  varSlot: i32;
}

export struct EvalSite {
  names: Array<u8>;
  levels: Array<EvalLevel>;
  strict: boolean;
  // The call is in a function's parameter list (not an arrow's), where
  // the code may not declare `arguments` either.
  inParameters: boolean;
}

// One compiled function. Fields beyond the code and constants are added
// as the interpreter grows to need them (inline caches, template sites,
// closure environment, class flags).
export struct FunctionCode {
  // The instructions, as compiled. Once the function is installed in a
  // runtime they move into its code segment and `codeStart` /
  // `codeLength` locate them there, so the interpreter fetches from one
  // array rather than through the function table.
  code: Array<Inst>;
  codeStart: u32;
  codeLength: u32;
  constants: Array<Value>;
  // Interned names for LoadProp / StoreProp, indexed by the instruction's
  // name operand. This is the reference's inline-cache slot table; the
  // cache itself is a performance-phase addition.
  propertyNames: Array<u32>;
  // One inline cache per property name, filled in as the code runs.
  caches: Array<PropertyCache>;
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
  // Class code: a constructor (derived when it has a heritage, so `this`
  // waits for super()), or a method, which is not a constructor.
  isClassConstructor: boolean;
  isDerived: boolean;
  isMethod: boolean;
  // Straight-line arithmetic, comparisons, forward branches, and cached
  // reads, with no call, store, loop, or `this`: a builtin calling it
  // back may run it without a frame (the runtime's runLeaf). Set when the
  // function is installed.
  leaf: boolean;
  // Its direct eval calls, by the directEval instruction's index.
  evalSites: Array<EvalSite>;
  // Script or eval code's hoisted var, function, and class names: the
  // global slots its declareGlobals instruction defines.
  declaredGlobals: Array<u32>;
}

export function createFunctionCode(): FunctionCode {
  return FunctionCode({
    code: Array<Inst>(), codeStart: 0, codeLength: 0, constants: Array<Value>(), propertyNames: Array<u32>(), caches: Array<PropertyCache>(), nameAtom: 0, registerCount: 0, fixedRegs: 0,
    paramCount: 0, thisReg: -1, expectedArgCount: 0,
    isArrow: false, isAsync: false, isGenerator: false, strict: false,
    isClassConstructor: false, isDerived: false, isMethod: false, leaf: false, evalSites: Array<EvalSite>(), declaredGlobals: Array<u32>(),
  });
}

test "jump offsets take 24 bits" {
  expect(jumpOffset(instAJump(Op.jmp, 0, -1))).toEqual(-1);
  expect(jumpOffset(instAJump(Op.jmpIfFalse, 7, 40000))).toEqual(40000);
  expect(jumpOffset(instAJump(Op.jmp, 0, -40000))).toEqual(-40000);
  expect(jumpOffset(instAJump(Op.jmp, 0, JUMP_OFFSET_LIMIT))).toEqual(JUMP_OFFSET_LIMIT);
  expect(jumpOffset(instAJump(Op.jmp, 0, -JUMP_OFFSET_LIMIT - 1))).toEqual(-JUMP_OFFSET_LIMIT - 1);
  expect(instAJump(Op.jmpIfFalse, 7, 40000).a).toEqual(7);
}

test "u16 and i16 operands round-trip through b and c" {
  const wide: u16 = 0xBEEF;
  expect(bcU16(instAU16(Op.loadConst, 1, wide))).toEqual(wide);
  expect(bcI16(instAI16(Op.jmp, 0, -2))).toEqual(-2);
  expect(bcI16(instAI16(Op.jmp, 0, 32767))).toEqual(32767);
  expect(bcI16(instAI16(Op.jmp, 0, -32768))).toEqual(-32768);
}

test "the instruction set version moves with the opcodes" {
  // A new opcode lands here first: move INSTRUCTION_SET_VERSION with it.
  const ops = opsByCode();
  expect(ops.length).toEqual(199);
  expect(INSTRUCTION_SET_VERSION).toEqual(2);
  let code: usize = 0;
  while (code < ops.length) {
    expect(opCode(ops[code])).toEqual(i32(code));
    code = code + 1;
  }
}

test "opcode numbering mirrors the reference" {
  expect(opCode(Op.halt)).toEqual(0);
  expect(opCode(Op.loadConst)).toEqual(1);
  expect(opCode(Op.jmpIfNotGenReturn)).toEqual(144);
}
