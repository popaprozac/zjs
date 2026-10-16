// Shared ISA + program encoding for the dispatch/heap spike.
//
// Fixed 4-byte instructions: [op, a, b, c].

import { Value, fromInt32 } from "./value.zs";

export const OP_HALT: u8 = 0;
export const OP_LOADK: u8 = 1;
export const OP_ADD: u8 = 2;
export const OP_LT: u8 = 3;
export const OP_JMPF: u8 = 4;
export const OP_JMP: u8 = 5;
export const OP_GETF: u8 = 6;
export const OP_SETF: u8 = 7;
export const OP_NEWOBJ: u8 = 8;
export const OP_RET: u8 = 9;

export function emit(inout code: Array<u8>, op: u8, a: u8, b: u8, c: u8): void {
  code.push(op);
  code.push(a);
  code.push(b);
  code.push(c);
}

// r0=obj r1=i r2=tmp r3=limit r4=acc
// k0=0 k1=limit k2=1
export function buildProgram(inout code: Array<u8>): void {
  emit(inout code, OP_NEWOBJ, 0, 4, 0);   //  0
  emit(inout code, OP_LOADK, 4, 0, 0);    //  1  acc = 0
  emit(inout code, OP_SETF, 0, 0, 4);     //  2  obj.0 = acc
  emit(inout code, OP_LOADK, 1, 0, 0);    //  3  i = 0
  emit(inout code, OP_LOADK, 3, 1, 0);    //  4  limit = N
  emit(inout code, OP_LT, 2, 1, 3);       //  5  tmp = i < limit
  emit(inout code, OP_JMPF, 2, 13, 0);    //  6  if !tmp goto 13
  emit(inout code, OP_GETF, 4, 0, 0);     //  7  acc = obj.0
  emit(inout code, OP_ADD, 4, 4, 1);      //  8  acc = acc + i
  emit(inout code, OP_SETF, 0, 0, 4);     //  9  obj.0 = acc
  emit(inout code, OP_LOADK, 2, 2, 0);    // 10  tmp = 1
  emit(inout code, OP_ADD, 1, 1, 2);      // 11  i = i + 1
  emit(inout code, OP_JMP, 5, 0, 0);      // 12  goto 5
  emit(inout code, OP_GETF, 4, 0, 0);     // 13  acc = obj.0
  emit(inout code, OP_RET, 4, 0, 0);      // 14
}

export function buildConstants(inout consts: Array<Value>, limit: i32): void {
  consts.push(fromInt32(0));
  consts.push(fromInt32(limit));
  consts.push(fromInt32(1));
}

// Workload size arrives at runtime so the optimizer cannot precompute.
export function workloadSize(): i32 = raw c {
  const char *text = getenv("SPIKE_N");
  return text ? atoi(text) : 1000000;
}
