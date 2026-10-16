// Variant: table dispatch through an Array of Z function values, malloc heap.
//
// This is the finding that matters: Z can express a dispatch *table* today,
// with no language change -- `Array<(inout Frame, usize, usize, usize) => void>`
// indexed by opcode. The cost this variant pays versus the if-chain is the
// halt check after every handler call, because Z has no tail call to let a
// handler jump straight to the next one.
import console from "std/console";
import stdlib from "stdlib.h";
import timeh from "time.h";
import { Value, fromInt32, toInt32, fromBoolean, isTruthy, fromCell, toCell } from "./value.zs";
import { buildProgram, buildConstants, workloadSize } from "./isa.zs";

struct Frame {
  regs: Array<Value>;
  consts: Array<Value>;
  pc: usize;
  halted: boolean;
  result: Value;
}

function monotonicNanoseconds(): u64 = raw c {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}

function cellAlloc(fieldCount: usize): u64 = raw c {
  return (uint64_t)(uintptr_t)calloc(fieldCount, sizeof(uint64_t));
}

function cellGet(cell: u64, field: usize): u64 = raw c {
  return ((uint64_t *)(uintptr_t)cell)[field];
}

function cellSet(cell: u64, field: usize, bits: u64): void = raw c {
  ((uint64_t *)(uintptr_t)cell)[field] = bits;
}

function opHalt(inout frame: Frame, a: usize, b: usize, c: usize): void {
  frame.halted = true;
  frame.result = fromInt32(0);
}

function opLoadk(inout frame: Frame, a: usize, b: usize, c: usize): void {
  frame.regs[a] = frame.consts[b];
}

function opAdd(inout frame: Frame, a: usize, b: usize, c: usize): void {
  frame.regs[a] = fromInt32(toInt32(frame.regs[b]).wrappingAdd(toInt32(frame.regs[c])));
}

function opLt(inout frame: Frame, a: usize, b: usize, c: usize): void {
  frame.regs[a] = fromBoolean(toInt32(frame.regs[b]) < toInt32(frame.regs[c]));
}

function opJmpf(inout frame: Frame, a: usize, b: usize, c: usize): void {
  if (!isTruthy(frame.regs[a])) frame.pc = b;
}

function opJmp(inout frame: Frame, a: usize, b: usize, c: usize): void {
  frame.pc = a;
}

function opGetf(inout frame: Frame, a: usize, b: usize, c: usize): void {
  frame.regs[a] = Value({ bits: cellGet(toCell(frame.regs[b]), c) });
}

function opSetf(inout frame: Frame, a: usize, b: usize, c: usize): void {
  cellSet(toCell(frame.regs[a]), b, frame.regs[c].bits);
}

function opNewobj(inout frame: Frame, a: usize, b: usize, c: usize): void {
  frame.regs[a] = fromCell(cellAlloc(b));
}

function opRet(inout frame: Frame, a: usize, b: usize, c: usize): void {
  frame.halted = true;
  frame.result = frame.regs[a];
}

function run(in code: Array<u8>, consts: Array<Value>): Value {
  const table = Array<(inout frame: Frame, a: usize, b: usize, c: usize) => void>(
    opHalt, opLoadk, opAdd, opLt, opJmpf, opJmp, opGetf, opSetf, opNewobj, opRet
  );

  let regs = Array<Value>();
  let index: usize = 0;
  while (index < 8) {
    regs.push(fromInt32(0));
    index = index + 1;
  }

  let frame = Frame({
    regs: move regs,
    consts: move consts,
    pc: 0,
    halted: false,
    result: fromInt32(0),
  });

  while (!frame.halted) {
    const base = frame.pc * 4;
    const op = usize(code[base]);
    const a = usize(code[base + 1]);
    const b = usize(code[base + 2]);
    const c = usize(code[base + 3]);
    frame.pc = frame.pc + 1;
    const handler = table[op];
    handler(inout frame, a, b, c);
  }
  return frame.result;
}

function main(): i32 {
  const limit = workloadSize();
  let code = Array<u8>();
  let consts = Array<Value>();
  buildProgram(inout code);
  buildConstants(inout consts, limit);

  const started = monotonicNanoseconds();
  const result = run(in code, move consts);
  const elapsed = monotonicNanoseconds() - started;

  console.log(`variant=table-ptr n=${limit} result=${toInt32(result)} ns=${elapsed}`);
  return 0;
}
