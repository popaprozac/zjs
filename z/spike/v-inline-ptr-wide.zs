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

    if (op == 200) {
      regs[a] = fromInt32(0);
    } else if (op == 100) {
      regs[a] = fromInt32(0);
    } else if (op == 101) {
      regs[a] = fromInt32(1);
    } else if (op == 102) {
      regs[a] = fromInt32(2);
    } else if (op == 103) {
      regs[a] = fromInt32(3);
    } else if (op == 104) {
      regs[a] = fromInt32(4);
    } else if (op == 105) {
      regs[a] = fromInt32(5);
    } else if (op == 106) {
      regs[a] = fromInt32(6);
    } else if (op == 107) {
      regs[a] = fromInt32(7);
    } else if (op == 108) {
      regs[a] = fromInt32(8);
    } else if (op == 109) {
      regs[a] = fromInt32(9);
    } else if (op == 110) {
      regs[a] = fromInt32(10);
    } else if (op == 111) {
      regs[a] = fromInt32(11);
    } else if (op == 112) {
      regs[a] = fromInt32(12);
    } else if (op == 113) {
      regs[a] = fromInt32(13);
    } else if (op == 114) {
      regs[a] = fromInt32(14);
    } else if (op == 115) {
      regs[a] = fromInt32(15);
    } else if (op == 116) {
      regs[a] = fromInt32(16);
    } else if (op == 117) {
      regs[a] = fromInt32(17);
    } else if (op == 118) {
      regs[a] = fromInt32(18);
    } else if (op == 119) {
      regs[a] = fromInt32(19);
    } else if (op == 120) {
      regs[a] = fromInt32(20);
    } else if (op == 121) {
      regs[a] = fromInt32(21);
    } else if (op == 122) {
      regs[a] = fromInt32(22);
    } else if (op == 123) {
      regs[a] = fromInt32(23);
    } else if (op == 124) {
      regs[a] = fromInt32(24);
    } else if (op == 125) {
      regs[a] = fromInt32(25);
    } else if (op == 126) {
      regs[a] = fromInt32(26);
    } else if (op == 127) {
      regs[a] = fromInt32(27);
    } else if (op == 128) {
      regs[a] = fromInt32(28);
    } else if (op == 129) {
      regs[a] = fromInt32(29);
    } else if (op == 130) {
      regs[a] = fromInt32(30);
    } else if (op == 131) {
      regs[a] = fromInt32(31);
    } else if (op == 132) {
      regs[a] = fromInt32(32);
    } else if (op == 133) {
      regs[a] = fromInt32(33);
    } else if (op == 134) {
      regs[a] = fromInt32(34);
    } else if (op == 135) {
      regs[a] = fromInt32(35);
    } else if (op == 136) {
      regs[a] = fromInt32(36);
    } else if (op == 137) {
      regs[a] = fromInt32(37);
    } else if (op == 138) {
      regs[a] = fromInt32(38);
    } else if (op == 139) {
      regs[a] = fromInt32(39);
    } else if (op == 140) {
      regs[a] = fromInt32(40);
    } else if (op == 141) {
      regs[a] = fromInt32(41);
    } else if (op == 142) {
      regs[a] = fromInt32(42);
    } else if (op == 143) {
      regs[a] = fromInt32(43);
    } else if (op == 144) {
      regs[a] = fromInt32(44);
    } else if (op == 145) {
      regs[a] = fromInt32(45);
    } else if (op == 146) {
      regs[a] = fromInt32(46);
    } else if (op == 147) {
      regs[a] = fromInt32(47);
    } else if (op == 148) {
      regs[a] = fromInt32(48);
    } else if (op == 149) {
      regs[a] = fromInt32(49);
    } else if (op == 150) {
      regs[a] = fromInt32(50);
    } else if (op == 151) {
      regs[a] = fromInt32(51);
    } else if (op == 152) {
      regs[a] = fromInt32(52);
    } else if (op == 153) {
      regs[a] = fromInt32(53);
    } else if (op == 154) {
      regs[a] = fromInt32(54);
    } else if (op == 155) {
      regs[a] = fromInt32(55);
    } else if (op == 156) {
      regs[a] = fromInt32(56);
    } else if (op == 157) {
      regs[a] = fromInt32(57);
    } else if (op == 158) {
      regs[a] = fromInt32(58);
    } else if (op == 159) {
      regs[a] = fromInt32(59);
    } else if (op == OP_LOADK) {
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

  console.log(`variant=inline-ptr-wide n=${limit} result=${toInt32(result)} ns=${elapsed}`);
  return 0;
}
