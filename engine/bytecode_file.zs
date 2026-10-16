// Bytecode files: a compiled program written out as bytes, and loaded
// into a runtime that then runs it as if it had compiled the source
// itself. What the file holds and why is docs/bytecode-files.md.
import { Value, undefinedValue, deletedValue, int32Value, doubleValue, cellValue, asCell, isCell, isInt32, asInt32, isDouble, asDouble, isDeleted, isUndefined } from "./value.zs";
import { Op, Inst, FunctionCode, EvalSite, EvalLevel, EvalBinding, createFunctionCode, opCode, opsByCode, bcU16, INSTRUCTION_SET_VERSION } from "./bytecode.zs";
import { Runtime, GLOBAL_SLOT_LIMIT } from "./runtime.zs";

export const BYTECODE_FORMAT_VERSION: u32 = 1;

// Why a file was refused (loadProgram's result below zero).
export const LOAD_NOT_BYTECODE: i64 = -1;
export const LOAD_OTHER_VERSION: i64 = -2;
export const LOAD_DAMAGED: i64 = -3;
// The runtime has no global slots left for the file's names.
export const LOAD_TOO_MANY_GLOBALS: i64 = -4;

const HEADER_BYTES: usize = 20;
const NONE: u32 = 0xFFFF_FFFF;

const FLAG_ARROW: u16 = 1;
const FLAG_ASYNC: u16 = 2;
const FLAG_GENERATOR: u16 = 4;
const FLAG_STRICT: u16 = 8;
const FLAG_CLASS_CONSTRUCTOR: u16 = 16;
const FLAG_DERIVED: u16 = 32;
const FLAG_METHOD: u16 = 64;
const FLAGS_KNOWN: u16 = 127;

const CONSTANT_INT32: u8 = 0;
const CONSTANT_DOUBLE: u8 = 1;
const CONSTANT_STRING: u8 = 2;
const CONSTANT_FUNCTION: u8 = 3;
const CONSTANT_TEMPLATE: u8 = 4;
const CONSTANT_HOLE: u8 = 5;

// Whether an instruction's 16-bit operand is a global slot, which the
// file names by its index in the file's table of global names.
function isGlobalOp(op: Op): boolean {
  return match (op) {
    loadGlobal => true;
    loadGlobalOrUndefined => true;
    storeGlobal => true;
    storeGlobalStrict => true;
    defineGlobal => true;
    _ => false;
  };
}

function withU16(inst: Inst, value: u16): Inst {
  return Inst({ op: inst.op, a: inst.a, b: u8(value & 0xFF), c: u8((value >> 8) & 0xFF), d: inst.d });
}

function checksum(bytes: Slice<u8>, start: usize): u32 {
  let hash: u32 = 2166136261;
  let index = start;
  while (index < bytes.length) {
    hash = (hash ^ u32(bytes[index])).wrappingMultiply(16777619);
    index = index + 1;
  }
  return hash;
}

// --- Writing ---

function putU8(inout buffer: Array<u8>, value: u8): void {
  buffer.push(value);
}

function putU16(inout buffer: Array<u8>, value: u16): void {
  buffer.push(u8(value & 0xFF));
  buffer.push(u8(value >> 8));
}

function putU32(inout buffer: Array<u8>, value: u32): void {
  buffer.push(u8(value & 0xFF));
  buffer.push(u8((value >> 8) & 0xFF));
  buffer.push(u8((value >> 16) & 0xFF));
  buffer.push(u8(value >> 24));
}

function putU64(inout buffer: Array<u8>, value: u64): void {
  putU32(inout buffer, u32(value & 0xFFFF_FFFF));
  putU32(inout buffer, u32(value >> 32));
}

// Positions handed out in order of first sight, for keys that are never
// 0: an open-addressed table from key to position, and the keys in
// position order.
struct IndexTable {
  keys: Array<u32>;
  positions: Array<u32>;
  order: Array<u32>;
}

function indexTable(): IndexTable {
  let keys = Array<u32>.withCapacity(64);
  keys.appendRepeated(0, 64);
  let positions = Array<u32>.withCapacity(64);
  positions.appendRepeated(0, 64);
  return IndexTable({ keys: move keys, positions: move positions, order: Array<u32>() });
}

function placeKey(inout keys: Array<u32>, inout positions: Array<u32>, key: u32, position: u32): void {
  const mask = keys.length - 1;
  let slot = usize(key.wrappingMultiply(2654435761)) & mask;
  while (keys[slot] != 0) { slot = (slot + 1) & mask; }
  keys[slot] = key;
  positions[slot] = position;
}

function positionOf(inout table: IndexTable, key: u32): u32 {
  if ((table.order.length + 1) * 2 > table.keys.length) {
    const size = table.keys.length * 2;
    let keys = Array<u32>.withCapacity(size);
    keys.appendRepeated(0, size);
    let positions = Array<u32>.withCapacity(size);
    positions.appendRepeated(0, size);
    let index: usize = 0;
    while (index < table.order.length) {
      placeKey(inout keys, inout positions, table.order[index], u32(index));
      index = index + 1;
    }
    table.keys = move keys;
    table.positions = move positions;
  }
  const mask = table.keys.length - 1;
  let slot = usize(key.wrappingMultiply(2654435761)) & mask;
  while (true) {
    const held = table.keys[slot];
    if (held == key) return table.positions[slot];
    if (held == 0) {
      const position = u32(table.order.length);
      table.keys[slot] = key;
      table.positions[slot] = position;
      table.order.push(key);
      return position;
    }
    slot = (slot + 1) & mask;
  }
  return 0;
}

// What a program's writing carries from function to function.
struct Writer {
  strings: IndexTable;
  // Runtime global slots, each one more than the slot, since a key is
  // never 0.
  globals: IndexTable;
  first: u32;
  script: u32;
  failed: boolean;
}

// An atom's position in the file's strings. An atom kept hidden from
// programs is the runtime's own and has no text a file could carry.
function stringOf(in runtime: Runtime, inout writer: Writer, atom: u32): u32 {
  if (runtime.isHiddenAtom(atom)) {
    writer.failed = true;
    return 0;
  }
  return positionOf(inout writer.strings, atom);
}

function putString(in runtime: Runtime, inout buffer: Array<u8>, atom: u32): void {
  if (runtime.heap.isWideString(atom)) {
    const units = runtime.heap.stringUnits(atom);
    putU8(inout buffer, 1);
    putU32(inout buffer, u32(units.length));
    let index: usize = 0;
    while (index < units.length) {
      putU16(inout buffer, units[index]);
      index = index + 1;
    }
    return;
  }
  const bytes = runtime.heap.stringStorageBytes(atom);
  putU8(inout buffer, 0);
  putU32(inout buffer, u32(bytes.length));
  buffer.append(bytes);
}

function putConstant(inout runtime: Runtime, inout buffer: Array<u8>, inout writer: Writer, value: Value): void {
  if (isInt32(value)) {
    putU8(inout buffer, CONSTANT_INT32);
    putU32(inout buffer, asInt32(value).toBits());
    return;
  }
  if (isDouble(value)) {
    putU8(inout buffer, CONSTANT_DOUBLE);
    putU64(inout buffer, asDouble(value).toBits());
    return;
  }
  if (isDeleted(value)) {
    putU8(inout buffer, CONSTANT_HOLE);
    return;
  }
  if (!isCell(value)) {
    writer.failed = true;
    return;
  }
  const handle = asCell(value);
  if (runtime.heap.isFunction(handle)) {
    const index = runtime.heap.functionIndex(handle);
    if (index < writer.first || index > writer.script) {
      writer.failed = true;
      return;
    }
    putU8(inout buffer, CONSTANT_FUNCTION);
    putU32(inout buffer, index - writer.first);
    return;
  }
  if (runtime.isStringValue(value)) {
    putU8(inout buffer, CONSTANT_STRING);
    putU32(inout buffer, stringOf(in runtime, inout writer, handle));
    return;
  }
  if (runtime.heap.isArray(handle)) {
    // A tagged template's object: its cooked strings, and the raw ones
    // on its `raw` property.
    const rawText: String = "raw";
    const rawAtom = runtime.atomOf(in rawText);
    const bag = runtime.heap.linkOf(handle);
    const rawSlot = bag == 0 ? -1 : runtime.heap.objectFindSlot(bag, rawAtom);
    if (rawSlot < 0) {
      writer.failed = true;
      return;
    }
    const rawValue = runtime.heap.slot(bag, u32(rawSlot));
    const count = runtime.heap.arrayLength(handle);
    if (!isCell(rawValue) || !runtime.heap.isArray(asCell(rawValue)) || runtime.heap.arrayLength(asCell(rawValue)) != count) {
      writer.failed = true;
      return;
    }
    putU8(inout buffer, CONSTANT_TEMPLATE);
    putU32(inout buffer, count);
    let index: u32 = 0;
    while (index < count) {
      const cooked = runtime.heap.slot(handle, index);
      if (isUndefined(cooked)) {
        putU32(inout buffer, NONE);
      } else if (runtime.isStringValue(cooked)) {
        putU32(inout buffer, stringOf(in runtime, inout writer, asCell(cooked)));
      } else {
        writer.failed = true;
      }
      index = index + 1;
    }
    index = 0;
    while (index < count) {
      const raw = runtime.heap.slot(asCell(rawValue), index);
      if (runtime.isStringValue(raw)) {
        putU32(inout buffer, stringOf(in runtime, inout writer, asCell(raw)));
      } else {
        writer.failed = true;
      }
      index = index + 1;
    }
    return;
  }
  writer.failed = true;
}

function putEvalSite(sites: Slice<EvalSite>, site: usize, inout buffer: Array<u8>): void {
  putU32(inout buffer, u32(sites[site].names.length));
  buffer.append(sites[site].names);
  const levels = sites[site].levels.length;
  putU32(inout buffer, u32(levels));
  let level: usize = 0;
  while (level < levels) {
    const bindings = sites[site].levels[level].bindings.length;
    putU32(inout buffer, u32(bindings));
    let index: usize = 0;
    while (index < bindings) {
      const binding = sites[site].levels[level].bindings[index];
      putU32(inout buffer, binding.nameStart);
      putU32(inout buffer, binding.nameLength);
      putU32(inout buffer, binding.slot);
      putU32(inout buffer, binding.depth);
      let flags: u8 = 0;
      if (binding.isConst) flags = flags | 1;
      if (binding.conflicts) flags = flags | 2;
      if (binding.checked) flags = flags | 4;
      putU8(inout buffer, flags);
      index = index + 1;
    }
    putU8(inout buffer, sites[site].levels[level].hasEnv ? 1 : 0);
    putU32(inout buffer, sites[site].levels[level].openEnvs);
    putU8(inout buffer, sites[site].levels[level].isArrow ? 1 : 0);
    putU32(inout buffer, sites[site].levels[level].thisSlot.toBits());
    putU32(inout buffer, sites[site].levels[level].varSlot.toBits());
    level = level + 1;
  }
  putU8(inout buffer, sites[site].strict ? 1 : 0);
  putU8(inout buffer, sites[site].inParameters ? 1 : 0);
}

function putFunction(inout runtime: Runtime, inout buffer: Array<u8>, inout writer: Writer, fi: u32): void {
  const index = usize(fi);
  const nameAtom = runtime.functions[index].nameAtom;
  putU32(inout buffer, nameAtom == 0 ? NONE : stringOf(in runtime, inout writer, nameAtom));
  putU32(inout buffer, runtime.functions[index].registerCount);
  putU32(inout buffer, runtime.functions[index].fixedRegs);
  putU32(inout buffer, runtime.functions[index].paramCount);
  putU32(inout buffer, runtime.functions[index].thisReg.toBits());
  putU32(inout buffer, runtime.functions[index].expectedArgCount);
  let flags: u16 = 0;
  if (runtime.functions[index].isArrow) flags = flags | FLAG_ARROW;
  if (runtime.functions[index].isAsync) flags = flags | FLAG_ASYNC;
  if (runtime.functions[index].isGenerator) flags = flags | FLAG_GENERATOR;
  if (runtime.functions[index].strict) flags = flags | FLAG_STRICT;
  if (runtime.functions[index].isClassConstructor) flags = flags | FLAG_CLASS_CONSTRUCTOR;
  if (runtime.functions[index].isDerived) flags = flags | FLAG_DERIVED;
  if (runtime.functions[index].isMethod) flags = flags | FLAG_METHOD;
  putU16(inout buffer, flags);

  const start = usize(runtime.functions[index].codeStart);
  const length = usize(runtime.functions[index].codeLength);
  putU32(inout buffer, u32(length));
  let at: usize = 0;
  while (at < length) {
    let inst = runtime.codeSegment[start + at];
    if (isGlobalOp(inst.op)) inst = withU16(inst, u16(positionOf(inout writer.globals, u32(bcU16(inst)) + 1)));
    putU8(inout buffer, u8(opCode(inst.op)));
    putU8(inout buffer, inst.a);
    putU8(inout buffer, inst.b);
    putU8(inout buffer, inst.c);
    putU8(inout buffer, inst.d);
    at = at + 1;
  }

  const constants = runtime.functions[index].constants.length;
  putU32(inout buffer, u32(constants));
  let k: usize = 0;
  while (k < constants) {
    const value = runtime.functions[index].constants[k];
    putConstant(inout runtime, inout buffer, inout writer, value);
    k = k + 1;
  }

  const names = runtime.functions[index].propertyNames.length;
  putU32(inout buffer, u32(names));
  let n: usize = 0;
  while (n < names) {
    const atom = runtime.functions[index].propertyNames[n];
    putU32(inout buffer, stringOf(in runtime, inout writer, atom));
    n = n + 1;
  }

  const declared = runtime.functions[index].declaredGlobals.length;
  putU32(inout buffer, u32(declared));
  let d: usize = 0;
  while (d < declared) {
    const slot = runtime.functions[index].declaredGlobals[d];
    putU32(inout buffer, positionOf(inout writer.globals, slot + 1));
    d = d + 1;
  }

  const sites = runtime.functions[index].evalSites.length;
  putU32(inout buffer, u32(sites));
  let s: usize = 0;
  while (s < sites) {
    putEvalSite(runtime.functions[index].evalSites, s, inout buffer);
    s = s + 1;
  }
}

// The program whose functions are `first` to `script`, the script last,
// as a bytecode file; empty if any part has no form in one.
export function writeProgram(inout runtime: Runtime, first: u32, script: u32): Array<u8> {
  let writer = Writer({ strings: indexTable(), globals: indexTable(), first: first, script: script, failed: false });
  let functions = Array<u8>();
  putU32(inout functions, script - first + 1);
  let fi = first;
  while (fi <= script) {
    putFunction(inout runtime, inout functions, inout writer, fi);
    fi = fi + 1;
  }
  let globalNames = Array<u32>();
  let g: usize = 0;
  while (g < writer.globals.order.length) {
    const slot = usize(writer.globals.order[g] - 1);
    const atom = runtime.globals[slot].atom;
    globalNames.push(stringOf(in runtime, inout writer, atom));
    g = g + 1;
  }
  if (writer.failed) return Array<u8>();

  let payload = Array<u8>();
  putU32(inout payload, u32(writer.strings.order.length));
  let s: usize = 0;
  while (s < writer.strings.order.length) {
    putString(in runtime, inout payload, writer.strings.order[s]);
    s = s + 1;
  }
  putU32(inout payload, u32(globalNames.length));
  g = 0;
  while (g < globalNames.length) {
    putU32(inout payload, globalNames[g]);
    g = g + 1;
  }
  payload.append(functions);

  let file = Array<u8>.withCapacity(HEADER_BYTES + payload.length);
  file.push(90);
  file.push(74);
  file.push(83);
  file.push(98);
  putU32(inout file, BYTECODE_FORMAT_VERSION);
  putU32(inout file, INSTRUCTION_SET_VERSION);
  putU32(inout file, u32(payload.length));
  putU32(inout file, checksum(payload, 0));
  file.append(payload);
  return file;
}

// --- Loading ---

struct Reader {
  at: usize;
  failed: boolean;
}

function getU8(bytes: Slice<u8>, inout reader: Reader): u8 {
  if (reader.failed || reader.at >= bytes.length) {
    reader.failed = true;
    return 0;
  }
  const value = bytes[reader.at];
  reader.at = reader.at + 1;
  return value;
}

function getU16(bytes: Slice<u8>, inout reader: Reader): u16 {
  const low = getU8(bytes, inout reader);
  const high = getU8(bytes, inout reader);
  return u16(low) | (u16(high) << 8);
}

function getU32(bytes: Slice<u8>, inout reader: Reader): u32 {
  const b0 = getU8(bytes, inout reader);
  const b1 = getU8(bytes, inout reader);
  const b2 = getU8(bytes, inout reader);
  const b3 = getU8(bytes, inout reader);
  return u32(b0) | (u32(b1) << 8) | (u32(b2) << 16) | (u32(b3) << 24);
}

function getU64(bytes: Slice<u8>, inout reader: Reader): u64 {
  const low = getU32(bytes, inout reader);
  const high = getU32(bytes, inout reader);
  return u64(low) | (u64(high) << 32);
}

// A count of records at least `size` bytes each, refused when the file
// cannot hold that many, before anything is made for them.
function getCount(bytes: Slice<u8>, inout reader: Reader, size: usize): u32 {
  const count = getU32(bytes, inout reader);
  if (reader.failed || usize(count) * size > bytes.length - reader.at) {
    reader.failed = true;
    return 0;
  }
  return count;
}

// An index below `limit`, or NONE where `none` allows it.
function getIndex(bytes: Slice<u8>, inout reader: Reader, limit: u32, none: boolean): u32 {
  const index = getU32(bytes, inout reader);
  if (index == NONE && none) return index;
  if (index >= limit) reader.failed = true;
  return index;
}

// What reading a program knows: the file's counts, and once installing,
// what the file's strings, globals, and functions became here.
struct Program {
  stringCount: u32;
  globalCount: u32;
  functionCount: u32;
  install: boolean;
  atoms: Array<u32>;
  slots: Array<u16>;
  base: u32;
  ops: Array<Op>;
  // Function constants, made once every function is installed:
  // (function, constant, target) in threes.
  patches: Array<u32>;
}

function getEvalSite(bytes: Slice<u8>, inout reader: Reader): EvalSite {
  const nameBytes = getCount(bytes, inout reader, 1);
  let names = Array<u8>.withCapacity(usize(nameBytes));
  let b: u32 = 0;
  while (b < nameBytes) {
    names.push(getU8(bytes, inout reader));
    b = b + 1;
  }
  const levelCount = getCount(bytes, inout reader, 18);
  let levels = Array<EvalLevel>();
  let level: u32 = 0;
  while (level < levelCount && !reader.failed) {
    const bindingCount = getCount(bytes, inout reader, 17);
    let bindings = Array<EvalBinding>();
    let index: u32 = 0;
    while (index < bindingCount && !reader.failed) {
      const nameStart = getU32(bytes, inout reader);
      const nameLength = getU32(bytes, inout reader);
      const slot = getU32(bytes, inout reader);
      const depth = getU32(bytes, inout reader);
      const flags = getU8(bytes, inout reader);
      if ((flags & ~u8(7)) != 0 || usize(nameStart) + usize(nameLength) > usize(nameBytes)) reader.failed = true;
      bindings.push(EvalBinding({ nameStart: nameStart, nameLength: nameLength, slot: slot, depth: depth, isConst: (flags & 1) != 0, conflicts: (flags & 2) != 0, checked: (flags & 4) != 0 }));
      index = index + 1;
    }
    const hasEnv = getU8(bytes, inout reader);
    const openEnvs = getU32(bytes, inout reader);
    const isArrow = getU8(bytes, inout reader);
    const thisSlot = i32.fromBits(getU32(bytes, inout reader));
    const varSlot = i32.fromBits(getU32(bytes, inout reader));
    if (hasEnv > 1 || isArrow > 1) reader.failed = true;
    levels.push(EvalLevel({ bindings: move bindings, hasEnv: hasEnv == 1, openEnvs: openEnvs, isArrow: isArrow == 1, thisSlot: thisSlot, varSlot: varSlot }));
    level = level + 1;
  }
  const strict = getU8(bytes, inout reader);
  const inParameters = getU8(bytes, inout reader);
  if (strict > 1 || inParameters > 1) reader.failed = true;
  return EvalSite({ names: move names, levels: move levels, strict: strict == 1, inParameters: inParameters == 1 });
}

// One function: checked, and installed at `base + position` when the
// program is installing.
function getFunction(inout runtime: Runtime, bytes: Slice<u8>, inout reader: Reader, inout program: Program, position: u32): void {
  let code = createFunctionCode();
  const name = getIndex(bytes, inout reader, program.stringCount, true);
  code.registerCount = getU32(bytes, inout reader);
  code.fixedRegs = getU32(bytes, inout reader);
  code.paramCount = getU32(bytes, inout reader);
  code.thisReg = i32.fromBits(getU32(bytes, inout reader));
  code.expectedArgCount = getU32(bytes, inout reader);
  const flags = getU16(bytes, inout reader);
  // Registers are named by one byte.
  if (code.registerCount > 256 || code.fixedRegs > code.registerCount || code.thisReg < -1 || code.thisReg >= i32(code.registerCount) || (flags & ~FLAGS_KNOWN) != 0) reader.failed = true;
  code.isArrow = (flags & FLAG_ARROW) != 0;
  code.isAsync = (flags & FLAG_ASYNC) != 0;
  code.isGenerator = (flags & FLAG_GENERATOR) != 0;
  code.strict = (flags & FLAG_STRICT) != 0;
  code.isClassConstructor = (flags & FLAG_CLASS_CONSTRUCTOR) != 0;
  code.isDerived = (flags & FLAG_DERIVED) != 0;
  code.isMethod = (flags & FLAG_METHOD) != 0;
  if (program.install && name != NONE) code.nameAtom = program.atoms[usize(name)];

  const length = getCount(bytes, inout reader, 5);
  if (length == 0) reader.failed = true;
  let at: u32 = 0;
  while (at < length && !reader.failed) {
    const number = getU8(bytes, inout reader);
    const a = getU8(bytes, inout reader);
    const b = getU8(bytes, inout reader);
    const c = getU8(bytes, inout reader);
    const d = getU8(bytes, inout reader);
    if (usize(number) >= program.ops.length) {
      reader.failed = true;
    } else {
      let inst = Inst({ op: program.ops[usize(number)], a: a, b: b, c: c, d: d });
      if (isGlobalOp(inst.op)) {
        const global = u32(bcU16(inst));
        if (global >= program.globalCount) {
          reader.failed = true;
        } else if (program.install) {
          inst = withU16(inst, program.slots[usize(global)]);
        }
      }
      if (program.install) code.code.push(inst);
    }
    at = at + 1;
  }

  const constants = getCount(bytes, inout reader, 1);
  let k: u32 = 0;
  while (k < constants && !reader.failed) {
    const tag = getU8(bytes, inout reader);
    let value = undefinedValue();
    if (tag == CONSTANT_INT32) {
      value = int32Value(i32.fromBits(getU32(bytes, inout reader)));
    } else if (tag == CONSTANT_DOUBLE) {
      value = doubleValue(f64.fromBits(getU64(bytes, inout reader)));
    } else if (tag == CONSTANT_STRING) {
      const index = getIndex(bytes, inout reader, program.stringCount, false);
      if (program.install) value = cellValue(program.atoms[usize(index)]);
    } else if (tag == CONSTANT_FUNCTION) {
      const target = getIndex(bytes, inout reader, program.functionCount, false);
      if (program.install) {
        program.patches.push(program.base + position);
        program.patches.push(k);
        program.patches.push(program.base + target);
      }
    } else if (tag == CONSTANT_TEMPLATE) {
      const count = getCount(bytes, inout reader, 8);
      let cooked = Array<Value>();
      let raw = Array<Value>();
      let index: u32 = 0;
      while (index < count) {
        const string = getIndex(bytes, inout reader, program.stringCount, true);
        if (program.install) cooked.push(string == NONE ? undefinedValue() : cellValue(program.atoms[usize(string)]));
        index = index + 1;
      }
      index = 0;
      while (index < count) {
        const string = getIndex(bytes, inout reader, program.stringCount, false);
        if (program.install) raw.push(cellValue(program.atoms[usize(string)]));
        index = index + 1;
      }
      if (program.install) value = runtime.newTemplateObject(move cooked, move raw);
    } else if (tag == CONSTANT_HOLE) {
      value = deletedValue();
    } else {
      reader.failed = true;
    }
    if (program.install) code.constants.push(value);
    k = k + 1;
  }

  const names = getCount(bytes, inout reader, 4);
  let n: u32 = 0;
  while (n < names) {
    const index = getIndex(bytes, inout reader, program.stringCount, false);
    if (program.install) code.propertyNames.push(program.atoms[usize(index)]);
    n = n + 1;
  }

  const declared = getCount(bytes, inout reader, 4);
  let g: u32 = 0;
  while (g < declared) {
    const index = getIndex(bytes, inout reader, program.globalCount, false);
    if (program.install) code.declaredGlobals.push(u32(program.slots[usize(index)]));
    g = g + 1;
  }

  const sites = getCount(bytes, inout reader, 10);
  let s: u32 = 0;
  while (s < sites && !reader.failed) {
    const site = getEvalSite(bytes, inout reader);
    if (program.install) code.evalSites.push(move site);
    s = s + 1;
  }
  if (program.install) runtime.setFunction(program.base + position, move code);
}

// The payload, read through once to check it (`install` false) and once
// more to install it: a file is refused with nothing added, and the
// install, which reads what the check accepted, cannot fail part way.
function getProgram(inout runtime: Runtime, bytes: Slice<u8>, install: boolean): i64 {
  let reader = Reader({ at: HEADER_BYTES, failed: false });
  let program = Program({ stringCount: 0, globalCount: 0, functionCount: 0, install: install, atoms: Array<u32>(), slots: Array<u16>(), base: 0, ops: opsByCode(), patches: Array<u32>() });

  program.stringCount = getCount(bytes, inout reader, 5);
  let s: u32 = 0;
  while (s < program.stringCount && !reader.failed) {
    const kind = getU8(bytes, inout reader);
    const length = getU32(bytes, inout reader);
    const size = kind == 1 ? usize(length) * 2 : usize(length);
    if (kind > 1 || size > bytes.length - reader.at) {
      reader.failed = true;
    } else if (install) {
      if (kind == 0) {
        let latin1 = Array<u8>.withCapacity(usize(length));
        latin1.append(bytes.slice(reader.at, reader.at + size));
        program.atoms.push(runtime.internLatin1(move latin1));
      } else {
        let units = Array<u16>.withCapacity(usize(length));
        let index: usize = 0;
        while (index < size) {
          units.push(u16(bytes[reader.at + index]) | (u16(bytes[reader.at + index + 1]) << 8));
          index = index + 2;
        }
        program.atoms.push(runtime.internUnits(move units));
      }
    }
    reader.at = reader.at + size;
    s = s + 1;
  }

  program.globalCount = getCount(bytes, inout reader, 4);
  let g: u32 = 0;
  while (g < program.globalCount && !reader.failed) {
    const name = getIndex(bytes, inout reader, program.stringCount, false);
    if (install && !reader.failed) program.slots.push(runtime.globalSlotAtom(program.atoms[usize(name)]));
    g = g + 1;
  }

  // Checked before anything is installed: names the runtime already has
  // take no slot, but counting them all is the bound the check can make.
  if (!install && runtime.globals.length + usize(program.globalCount) > GLOBAL_SLOT_LIMIT) return LOAD_TOO_MANY_GLOBALS;
  program.functionCount = getCount(bytes, inout reader, 40);
  if (program.functionCount == 0) reader.failed = true;
  if (install) {
    program.base = u32(runtime.functions.length);
    let r: u32 = 0;
    while (r < program.functionCount) {
      const reserved = runtime.reserveFunction();
      r = r + 1;
    }
  }
  let f: u32 = 0;
  while (f < program.functionCount && !reader.failed) {
    getFunction(inout runtime, bytes, inout reader, inout program, f);
    f = f + 1;
  }
  if (reader.failed || reader.at != bytes.length) return LOAD_DAMAGED;
  if (install) {
    // Every function is installed, so each cell takes its function's
    // leaf flag.
    let p: usize = 0;
    while (p < program.patches.length) {
      const owner = usize(program.patches[p]);
      const constant = usize(program.patches[p + 1]);
      const target = program.patches[p + 2];
      runtime.functions[owner].constants[constant] = runtime.functionValue(target);
      p = p + 3;
    }
  }
  return i64(program.base + program.functionCount - 1);
}

// Whether the bytes start as a bytecode file does.
export function isBytecodeFile(bytes: Slice<u8>): boolean {
  return bytes.length >= 4 && bytes[0] == 90 && bytes[1] == 74 && bytes[2] == 83 && bytes[3] == 98;
}

// Load a bytecode file into the runtime: the script's function index,
// to run as `run` runs one compiled from source, or a LOAD_ reason the
// file was refused, with nothing added.
export function loadProgram(inout runtime: Runtime, bytes: Slice<u8>): i64 {
  if (!isBytecodeFile(bytes)) return LOAD_NOT_BYTECODE;
  if (bytes.length < HEADER_BYTES) return LOAD_DAMAGED;
  let reader = Reader({ at: 4, failed: false });
  const format = getU32(bytes, inout reader);
  const instructionSet = getU32(bytes, inout reader);
  const payload = getU32(bytes, inout reader);
  const sum = getU32(bytes, inout reader);
  if (format != BYTECODE_FORMAT_VERSION || instructionSet != INSTRUCTION_SET_VERSION) return LOAD_OTHER_VERSION;
  if (usize(payload) != bytes.length - HEADER_BYTES || checksum(bytes, HEADER_BYTES) != sum) return LOAD_DAMAGED;
  const checked = getProgram(inout runtime, bytes, false);
  if (checked < 0) return checked;
  return getProgram(inout runtime, bytes, true);
}
