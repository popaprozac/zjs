// Variant: if-chain dispatch, opcode bodies inline, malloc heap via usize.
import console from "std/console";
import stdlib from "stdlib.h";
import timeh from "time.h";
import {
  Value, fromInt32, toInt32, fromBoolean, isTruthy, fromCell, toCell,
} from "./value.zs";
import {
  OP_HALT, OP_LOADK, OP_ADD, OP_LT, OP_JMPF, OP_JMP,
  OP_GETF, OP_SETF, OP_NEWOBJ, OP_RET,
  buildProgram, buildConstants, workloadSize,
} from "./isa.zs";

// std/time exposes only sleep/delay -- there is no monotonic
// clock read, so any benchmark harness in Z needs its own raw c timer.
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

// The spike uses wrapping int32 add so every variant has one uniform hot
// path and a deterministic checksum. A real engine promotes overflow to
// double; that cold path is out of scope for a dispatch measurement.
function addValues(left: Value, right: Value): Value {
  return fromInt32(toInt32(left).wrappingAdd(toInt32(right)));
}

function run(in code: Array<u8>, in consts: Array<Value>): Value {
  let regs = Array<Value>();
  let index: usize = 0;
  while (index < 8) {
    regs.push(fromInt32(0));
    index = index + 1;
  }

  let pc: usize = 0;
  while (true) {
    const base = pc * 4;
    const op = code[base];
    const a = usize(code[base + 1]);
    const b = usize(code[base + 2]);
    const c = usize(code[base + 3]);
    pc = pc + 1;

    if (op == OP_LOADK) {
      regs[a] = consts[b];
    } else if (op == OP_ADD) {
      regs[a] = addValues(regs[b], regs[c]);
    } else if (op == OP_LT) {
      regs[a] = fromBoolean(toInt32(regs[b]) < toInt32(regs[c]));
    } else if (op == OP_JMPF) {
      if (!isTruthy(regs[a])) pc = b;
    } else if (op == OP_JMP) {
      pc = a;
    } else if (op == OP_GETF) {
      regs[a] = Value({ bits: cellGet(toCell(regs[b]), c) });
    } else if (op == OP_SETF) {
      cellSet(toCell(regs[a]), b, regs[c].bits);
    } else if (op == OP_NEWOBJ) {
      regs[a] = fromCell(cellAlloc(b));
    } else if (op == OP_RET) {
      return regs[a];
    } else if (op == OP_HALT) {
      return fromInt32(0);
    }
  }
  // `while (true)` whose only exits are `return` is not
  // recognized as diverging, so an unreachable trailing return is required.
  return fromInt32(0);
}

function main(): i32 {
  const limit = workloadSize();
  let code = Array<u8>();
  let consts = Array<Value>();
  buildProgram(inout code);
  buildConstants(inout consts, limit);

  const started = monotonicNanoseconds();
  const result = run(in code, in consts);
  const elapsed = monotonicNanoseconds() - started;

  console.log(`variant=inline-ptr n=${limit} result=${toInt32(result)} ns=${elapsed}`);
  return 0;
}
