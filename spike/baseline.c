/* Pure C reference: computed-goto dispatch, malloc heap, same ISA and
 * program as the Z variants. This is the ceiling the Z variants are
 * measured against. Built with the same -O2 the Z --release path uses. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define NUMBER_TAG (((uint64_t)0xfffe) << 48)

typedef struct { uint64_t bits; } Value;

static inline Value from_int32(int32_t v) {
  Value r; r.bits = NUMBER_TAG | (uint64_t)(uint32_t)v; return r;
}
static inline int32_t to_int32(Value v) { return (int32_t)(uint32_t)(v.bits & 0xffffffffu); }
static inline Value from_bool(int b) { Value r; r.bits = b ? 7 : 6; return r; }
static inline int is_truthy(Value v) { return v.bits == 7; }
static inline Value from_cell(uint64_t p) { Value r; r.bits = p; return r; }

enum { OP_HALT, OP_LOADK, OP_ADD, OP_LT, OP_JMPF, OP_JMP,
       OP_GETF, OP_SETF, OP_NEWOBJ, OP_RET };

static uint64_t monotonic_ns(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}

static Value run(const uint8_t *code, const Value *consts) {
  static void *table[] = {
    &&op_halt, &&op_loadk, &&op_add, &&op_lt, &&op_jmpf,
    &&op_jmp, &&op_getf, &&op_setf, &&op_newobj, &&op_ret,
  };
  Value regs[8];
  for (int i = 0; i < 8; i++) regs[i] = from_int32(0);
  size_t pc = 0;
  uint8_t op, a, b, c;

#define DISPATCH()                                                            \
  do {                                                                        \
    const uint8_t *ins = code + pc * 4;                                       \
    op = ins[0]; a = ins[1]; b = ins[2]; c = ins[3];                           \
    pc++;                                                                      \
    goto *table[op];                                                           \
  } while (0)

  DISPATCH();
op_halt:   return from_int32(0);
op_loadk:  regs[a] = consts[b]; DISPATCH();
op_add:    regs[a] = from_int32((int32_t)((uint32_t)to_int32(regs[b]) +
                                          (uint32_t)to_int32(regs[c]))); DISPATCH();
op_lt:     regs[a] = from_bool(to_int32(regs[b]) < to_int32(regs[c])); DISPATCH();
op_jmpf:   if (!is_truthy(regs[a])) pc = b; DISPATCH();
op_jmp:    pc = a; DISPATCH();
op_getf:   regs[a].bits = ((uint64_t *)(uintptr_t)regs[b].bits)[c]; DISPATCH();
op_setf:   ((uint64_t *)(uintptr_t)regs[a].bits)[b] = regs[c].bits; DISPATCH();
op_newobj: regs[a] = from_cell((uint64_t)(uintptr_t)calloc(b, sizeof(uint64_t))); DISPATCH();
op_ret:    return regs[a];
}

int main(void) {
  const char *text = getenv("SPIKE_N");
  int32_t limit = text ? atoi(text) : 1000000;

  uint8_t code[15 * 4];
  int n = 0;
#define EMIT(o, x, y, z) do { code[n*4]=(o); code[n*4+1]=(x); code[n*4+2]=(y); code[n*4+3]=(z); n++; } while (0)
  EMIT(OP_NEWOBJ, 0, 4, 0);
  EMIT(OP_LOADK, 4, 0, 0);
  EMIT(OP_SETF, 0, 0, 4);
  EMIT(OP_LOADK, 1, 0, 0);
  EMIT(OP_LOADK, 3, 1, 0);
  EMIT(OP_LT, 2, 1, 3);
  EMIT(OP_JMPF, 2, 13, 0);
  EMIT(OP_GETF, 4, 0, 0);
  EMIT(OP_ADD, 4, 4, 1);
  EMIT(OP_SETF, 0, 0, 4);
  EMIT(OP_LOADK, 2, 2, 0);
  EMIT(OP_ADD, 1, 1, 2);
  EMIT(OP_JMP, 5, 0, 0);
  EMIT(OP_GETF, 4, 0, 0);
  EMIT(OP_RET, 4, 0, 0);

  Value consts[3] = { from_int32(0), from_int32(limit), from_int32(1) };

  uint64_t started = monotonic_ns();
  Value result = run(code, consts);
  uint64_t elapsed = monotonic_ns() - started;

  printf("variant=c-computed-goto n=%d result=%d ns=%llu\n",
         limit, to_int32(result), (unsigned long long)elapsed);
  return 0;
}
