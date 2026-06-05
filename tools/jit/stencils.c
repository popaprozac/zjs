// tools/jit/stencils.c — zjs JIT copy-and-patch STENCIL templates.
//
// One function per (opcode, operand shape). Each is compiled (NOT linked) to a
// relocatable .o; tools/jit/extract_stencils.py reads each function's machine
// code + relocation records (the "holes") and emits build/jit_stencils_<arch>.h.
// At runtime the JIT memcpy's a stencil per bytecode instruction and patches
// the holes (operands, the next-stencil branch). See docs/jit-design-study.md
// and docs/jit-spike-phase1.md.
//
// Built only when ZJS_JIT is set; never for iOS. Compiled with
//   -O3 -fno-asynchronous-unwind-tables -fomit-frame-pointer -fno-stack-protector -fno-pic
//
// HOLE CONVENTION (CPython Tools/jit model): a hole is an `extern` placeholder
// symbol. clang can't fold an unknown address, so it emits a relocation wherever
// the hole is materialized; the stitcher overwrites that site with the real
// value. `_JIT_CONTINUE` is the fall-through to the next stencil, emitted as a
// tail call so stencils chain with no prologue/epilogue.
//
// On Apple arm64 these materialize via the GOT (adrp@GOTPAGE / ldr@GOTPAGEOFF)
// rather than inline movz/movk; the extractor + stitcher handle the GOT-indirect
// form (per the J1 toolchain finding — see jit-impl-notes.md).
//
// ABI (J4): every stencil is `void f(ZjsValue *regs, int *deopt)`.
//   x0 = regs  — the frame's register file (NaN-boxed cells, interpreter layout)
//   x1 = deopt — a one-int bail flag. A value op that meets an operand outside
//                its fast domain (a non-number for arithmetic, a non-primitive
//                truthiness for a branch) writes *deopt=1 and returns; the bridge
//                discards the run and falls back to the interpreter. This keeps
//                the JIT faithful: it only ever produces a value the interpreter
//                would, or bails. Both x0/x1 thread through every continuation
//                unchanged, so a musttail is a bare branch.

#include <stdint.h>

// Mirror of the engine's NaN-boxed value cell (src/value.zc). The JIT keeps
// values in the interpreter's frame layout (design study §4) so deopt + GC stay
// free. These constants MUST match value.zc:
//   int32 v   :  bits = NUMBER_TAG | (uint32_t)i
//   double v  :  bits = double_to_bits(d) + DOUBLE_ENCODE_OFFSET
//   is_int32  : (bits & NUMBER_TAG) == NUMBER_TAG
//   is_number : (bits & NUMBER_TAG) != 0
//   false/true/null/undefined : 6 / 7 / 2 / 10
typedef struct { uint64_t bits; } ZjsValue;

#define JIT_NUMBER_TAG  0xfffe000000000000ULL
#define JIT_DBL_OFFSET  0x0002000000000000ULL   /* 1 << 49 */
#define JIT_VAL_NULL    2ULL
#define JIT_VAL_UNDEF   10ULL
#define JIT_VAL_FALSE   6ULL
#define JIT_VAL_TRUE    7ULL
#define JIT_VAL_DELETED 0x10002ULL              /* TDZ hole sentinel (value.zc) */

typedef void (*JitCont)(ZjsValue *regs, int *deopt);

// ---- Holes (patched per instruction at stitch time) ------------------------
extern uint8_t  _JIT_RA;        // operand register index a (usually dest)
extern uint8_t  _JIT_RB;        // operand register index b
extern uint8_t  _JIT_RC;        // operand register index c
extern uint64_t _JIT_IMM64;     // a 64-bit immediate (boxed constant, or raw int)
extern void     _JIT_CONTINUE(ZjsValue *regs, int *deopt);  // fall-through
extern void     _JIT_TARGET(ZjsValue *regs, int *deopt);    // branch destination

// ---- NaN-box helpers (all inline, no external symbols / no libcalls) --------
static inline int jv_is_int32(uint64_t b)  { return (b & JIT_NUMBER_TAG) == JIT_NUMBER_TAG; }
static inline int jv_is_number(uint64_t b) { return (b & JIT_NUMBER_TAG) != 0; }
static inline double jv_bits_to_double(uint64_t u) {
    union { uint64_t u; double d; } x; x.u = u; return x.d;
}
static inline uint64_t jv_double_to_bits(double d) {
    union { double d; uint64_t u; } x; x.d = d; return x.u;
}
static inline double jv_to_double(uint64_t b) {
    if (jv_is_int32(b)) return (double)(int32_t)(uint32_t)b;
    return jv_bits_to_double(b - JIT_DBL_OFFSET);          // assumes is_number
}
static inline uint64_t jv_box_int32(int32_t i) { return JIT_NUMBER_TAG | (uint32_t)i; }
static inline uint64_t jv_box_double(double d) { return jv_double_to_bits(d) + JIT_DBL_OFFSET; }

// Mirror of zjs_arith_add's number cases (value.zc): int32 fast path with
// overflow→double, then the both-number path; non-number → caller deopts.
static inline uint64_t jv_num_add(uint64_t a, uint64_t b, int *ok) {
    if (jv_is_int32(a) && jv_is_int32(b)) {
        int64_t s = (int64_t)(int32_t)(uint32_t)a + (int64_t)(int32_t)(uint32_t)b;
        *ok = 1;
        if (s >= -2147483647LL - 1 && s <= 2147483647LL) return jv_box_int32((int32_t)s);
        return jv_box_double((double)s);
    }
    if (jv_is_number(a) && jv_is_number(b)) {
        *ok = 1;
        return jv_box_double(jv_to_double(a) + jv_to_double(b));
    }
    *ok = 0;
    return 0;
}

// Mirror of zjs_arith_sub's number cases.
static inline uint64_t jv_num_sub(uint64_t a, uint64_t b, int *ok) {
    if (jv_is_int32(a) && jv_is_int32(b)) {
        int64_t s = (int64_t)(int32_t)(uint32_t)a - (int64_t)(int32_t)(uint32_t)b;
        *ok = 1;
        if (s >= -2147483647LL - 1 && s <= 2147483647LL) return jv_box_int32((int32_t)s);
        return jv_box_double((double)s);
    }
    if (jv_is_number(a) && jv_is_number(b)) {
        *ok = 1;
        return jv_box_double(jv_to_double(a) - jv_to_double(b));
    }
    *ok = 0;
    return 0;
}

// ---- Stencils ---------------------------------------------------------------

// LoadConst: regs[RA] = IMM64 (the boxed constant value).
void zjs_stencil_LoadConst(ZjsValue *regs, int *deopt) {
    regs[(uintptr_t)&_JIT_RA].bits = (uint64_t)(uintptr_t)&_JIT_IMM64;
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// Mov: regs[RA] = regs[RB].
void zjs_stencil_Mov(ZjsValue *regs, int *deopt) {
    regs[(uintptr_t)&_JIT_RA] = regs[(uintptr_t)&_JIT_RB];
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// ThrowIfHole: TDZ check — if regs[RA] is the hole sentinel, bail to the
// interpreter (which raises the ReferenceError); otherwise pass through.
void zjs_stencil_ThrowIfHole(ZjsValue *regs, int *deopt) {
    if (regs[(uintptr_t)&_JIT_RA].bits == JIT_VAL_DELETED) { *deopt = 1; return; }
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// Add: regs[RA] = regs[RB] + regs[RC], spec number semantics (else deopt).
void zjs_stencil_Add(ZjsValue *regs, int *deopt) {
    int ok;
    uint64_t r = jv_num_add(regs[(uintptr_t)&_JIT_RB].bits,
                            regs[(uintptr_t)&_JIT_RC].bits, &ok);
    if (!ok) { *deopt = 1; return; }
    regs[(uintptr_t)&_JIT_RA].bits = r;
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// AddImm: regs[RA] = regs[RB] + IMM64, where IMM64 is a boxed int32 constant.
void zjs_stencil_AddImm(ZjsValue *regs, int *deopt) {
    int ok;
    uint64_t r = jv_num_add(regs[(uintptr_t)&_JIT_RB].bits,
                            (uint64_t)(uintptr_t)&_JIT_IMM64, &ok);
    if (!ok) { *deopt = 1; return; }
    regs[(uintptr_t)&_JIT_RA].bits = r;
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// Sub: regs[RA] = regs[RB] - regs[RC], spec number semantics (else deopt).
void zjs_stencil_Sub(ZjsValue *regs, int *deopt) {
    int ok;
    uint64_t r = jv_num_sub(regs[(uintptr_t)&_JIT_RB].bits,
                            regs[(uintptr_t)&_JIT_RC].bits, &ok);
    if (!ok) { *deopt = 1; return; }
    regs[(uintptr_t)&_JIT_RA].bits = r;
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// SubImm: regs[RA] = regs[RB] - IMM64, where IMM64 is a boxed int32 constant.
void zjs_stencil_SubImm(ZjsValue *regs, int *deopt) {
    int ok;
    uint64_t r = jv_num_sub(regs[(uintptr_t)&_JIT_RB].bits,
                            (uint64_t)(uintptr_t)&_JIT_IMM64, &ok);
    if (!ok) { *deopt = 1; return; }
    regs[(uintptr_t)&_JIT_RA].bits = r;
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// CmpLt: regs[RA] = (regs[RB] < regs[RC]) as a JS boolean (number compare; else deopt).
void zjs_stencil_CmpLt(ZjsValue *regs, int *deopt) {
    uint64_t a = regs[(uintptr_t)&_JIT_RB].bits;
    uint64_t b = regs[(uintptr_t)&_JIT_RC].bits;
    int lt;
    if (jv_is_int32(a) && jv_is_int32(b)) {
        lt = (int32_t)(uint32_t)a < (int32_t)(uint32_t)b;
    } else if (jv_is_number(a) && jv_is_number(b)) {
        lt = jv_to_double(a) < jv_to_double(b);   // NaN → false, matching JS <
    } else {
        *deopt = 1; return;
    }
    regs[(uintptr_t)&_JIT_RA].bits = lt ? JIT_VAL_TRUE : JIT_VAL_FALSE;
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// Jmp: unconditional branch to TARGET.
void zjs_stencil_Jmp(ZjsValue *regs, int *deopt) {
    __attribute__((musttail)) return _JIT_TARGET(regs, deopt);
}

// JmpIfFalse: branch to TARGET when ToBoolean(regs[RA]) is false. Handles the
// boolean / null / undefined / numeric-zero cases inline (a CmpLt result is a
// boolean, so the hot loop-condition path is exact); strings/objects deopt.
void zjs_stencil_JmpIfFalse(ZjsValue *regs, int *deopt) {
    uint64_t v = regs[(uintptr_t)&_JIT_RA].bits;
    int falsy;
    if (v == JIT_VAL_FALSE || v == JIT_VAL_NULL || v == JIT_VAL_UNDEF) {
        falsy = 1;
    } else if (v == JIT_VAL_TRUE) {
        falsy = 0;
    } else if (jv_is_int32(v)) {
        falsy = ((int32_t)(uint32_t)v == 0);
    } else if (jv_is_number(v)) {
        double d = jv_to_double(v);
        falsy = (d == 0.0) || (d != d);           // +0/-0/NaN are falsy
    } else {
        *deopt = 1; return;
    }
    if (falsy) __attribute__((musttail)) return _JIT_TARGET(regs, deopt);
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// Return: leave the JIT'd region (back to the bridge / interpreter).
void zjs_stencil_Return(ZjsValue *regs, int *deopt) {
    (void)regs; (void)deopt;
}
