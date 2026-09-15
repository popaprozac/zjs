// Variant: the dispatch loop is one whole-function `raw c` with computed
// goto -- design option (a) from the rewrite design §6.1. Z builds the
// program; the hottest component of the engine is C.
//
// This variant exists to price option (a) honestly. The cost it makes
// visible is not runtime, it is that `run` is no longer Z at all: no
// ownership, no type checking, no Z tooling over the interpreter.
import console from "std/console";
import stdlib from "stdlib.h";
import timeh from "time.h";
import { Value, fromInt32, toInt32 } from "./value.zs";
import { buildProgram, buildConstants, workloadSize } from "./isa.zs";

function monotonicNanoseconds(): u64 = raw c {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}

function allocBytes(count: usize): u64 = raw c {
  return (uint64_t)(uintptr_t)calloc(count, 1);
}

function storeByte(buffer: u64, index: usize, value: u8): void = raw c {
  ((uint8_t *)(uintptr_t)buffer)[index] = value;
}

function storeValue(buffer: u64, index: usize, bits: u64): void = raw c {
  ((uint64_t *)(uintptr_t)buffer)[index] = bits;
}

function interpret(code: u64, consts: u64): u64 = raw c {
  static void *table[] = {
    &&op_halt, &&op_loadk, &&op_add, &&op_lt, &&op_jmpf,
    &&op_jmp, &&op_getf, &&op_setf, &&op_newobj, &&op_ret,
  };
  const uint64_t NUMBER_TAG = ((uint64_t)0xfffe) << 48;
  const uint8_t *program = (const uint8_t *)(uintptr_t)code;
  const uint64_t *pool = (const uint64_t *)(uintptr_t)consts;
  uint64_t regs[8];
  for (int i = 0; i < 8; i++) regs[i] = NUMBER_TAG;
  size_t pc = 0;
  uint8_t op, a, b, c;

#define SPIKE_DISPATCH()                                                      \
  do {                                                                        \
    const uint8_t *ins = program + pc * 4;                                    \
    op = ins[0]; a = ins[1]; b = ins[2]; c = ins[3];                          \
    pc++;                                                                     \
    goto *table[op];                                                          \
  } while (0)

  SPIKE_DISPATCH();
op_halt:   return NUMBER_TAG;
op_loadk:  regs[a] = pool[b]; SPIKE_DISPATCH();
op_add:    regs[a] = NUMBER_TAG | (uint64_t)(uint32_t)
             ((uint32_t)regs[b] + (uint32_t)regs[c]); SPIKE_DISPATCH();
op_lt:     regs[a] = ((int32_t)(uint32_t)regs[b] < (int32_t)(uint32_t)regs[c])
             ? 7 : 6; SPIKE_DISPATCH();
op_jmpf:   if (regs[a] != 7) pc = b; SPIKE_DISPATCH();
op_jmp:    pc = a; SPIKE_DISPATCH();
op_getf:   regs[a] = ((uint64_t *)(uintptr_t)regs[b])[c]; SPIKE_DISPATCH();
op_setf:   ((uint64_t *)(uintptr_t)regs[a])[b] = regs[c]; SPIKE_DISPATCH();
op_newobj: regs[a] = (uint64_t)(uintptr_t)calloc(b, sizeof(uint64_t));
             SPIKE_DISPATCH();
op_ret:    return regs[a];
}

function main(): i32 {
  const limit = workloadSize();
  let code = Array<u8>();
  let consts = Array<Value>();
  buildProgram(inout code);
  buildConstants(inout consts, limit);

  const codeBuffer = allocBytes(code.length);
  let index: usize = 0;
  while (index < code.length) {
    storeByte(codeBuffer, index, code[index]);
    index = index + 1;
  }

  const constBuffer = allocBytes(consts.length * 8);
  index = 0;
  while (index < consts.length) {
    storeValue(constBuffer, index, consts[index].bits);
    index = index + 1;
  }

  const started = monotonicNanoseconds();
  const raw = interpret(codeBuffer, constBuffer);
  const elapsed = monotonicNanoseconds() - started;

  console.log(`variant=rawc-ptr n=${limit} result=${toInt32(Value({ bits: raw }))} ns=${elapsed}`);
  return 0;
}
