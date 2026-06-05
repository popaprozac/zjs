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
// ABI (J4/J6): every stencil is `void f(ZjsValue *regs, int *deopt)`.
//   x0 = regs  — the frame's register file (NaN-boxed cells, interpreter layout)
//   x1 = deopt — the deopt channel (init -1 = "ran to a Return"). A value op
//                that meets an operand outside its fast domain (a non-number for
//                arithmetic, a non-primitive truthiness, a TDZ hole) writes its
//                OWN bytecode instruction index (the _JIT_BCIDX hole) and
//                returns. The engine resumes the interpreter at that index with
//                the live registers (J6 OSR) — so a partial run is continued,
//                not re-run, and faithfulness still means "produces what the
//                interpreter would, or hands control back at the exact op."
//                Both x0/x1 thread through every continuation unchanged, so a
//                musttail is a bare branch.

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
extern int      _JIT_BCIDX;     // this instruction's bytecode index (for OSR deopt)
extern uint64_t _JIT_HELP_arrget;  // GOT slot holds &jit_array_get_fast (J8a)
extern uint64_t _JIT_HELP_arrset;  // GOT slot holds &jit_array_set_fast (J8b)
extern void     _JIT_CONTINUE(ZjsValue *regs, int *deopt);  // fall-through
extern void     _JIT_TARGET(ZjsValue *regs, int *deopt);    // branch destination

// Report a deopt at this stencil's bytecode index; the engine resumes the
// interpreter there with the live registers.
#define JIT_DEOPT(d) do { *(d) = (int)(intptr_t)&_JIT_BCIDX; return; } while (0)

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

// Mirror of zjs_arith_mul's number cases.
static inline uint64_t jv_num_mul(uint64_t a, uint64_t b, int *ok) {
    if (jv_is_int32(a) && jv_is_int32(b)) {
        int64_t p = (int64_t)(int32_t)(uint32_t)a * (int64_t)(int32_t)(uint32_t)b;
        *ok = 1;
        if (p >= -2147483647LL - 1 && p <= 2147483647LL) return jv_box_int32((int32_t)p);
        return jv_box_double((double)p);
    }
    if (jv_is_number(a) && jv_is_number(b)) {
        *ok = 1;
        return jv_box_double(jv_to_double(a) * jv_to_double(b));
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
    if (regs[(uintptr_t)&_JIT_RA].bits == JIT_VAL_DELETED) { JIT_DEOPT(deopt); }
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// Add: regs[RA] = regs[RB] + regs[RC], spec number semantics (else deopt).
void zjs_stencil_Add(ZjsValue *regs, int *deopt) {
    int ok;
    uint64_t r = jv_num_add(regs[(uintptr_t)&_JIT_RB].bits,
                            regs[(uintptr_t)&_JIT_RC].bits, &ok);
    if (!ok) { JIT_DEOPT(deopt); }
    regs[(uintptr_t)&_JIT_RA].bits = r;
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// AddImm: regs[RA] = regs[RB] + IMM64, where IMM64 is a boxed int32 constant.
void zjs_stencil_AddImm(ZjsValue *regs, int *deopt) {
    int ok;
    uint64_t r = jv_num_add(regs[(uintptr_t)&_JIT_RB].bits,
                            (uint64_t)(uintptr_t)&_JIT_IMM64, &ok);
    if (!ok) { JIT_DEOPT(deopt); }
    regs[(uintptr_t)&_JIT_RA].bits = r;
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// Sub: regs[RA] = regs[RB] - regs[RC], spec number semantics (else deopt).
void zjs_stencil_Sub(ZjsValue *regs, int *deopt) {
    int ok;
    uint64_t r = jv_num_sub(regs[(uintptr_t)&_JIT_RB].bits,
                            regs[(uintptr_t)&_JIT_RC].bits, &ok);
    if (!ok) { JIT_DEOPT(deopt); }
    regs[(uintptr_t)&_JIT_RA].bits = r;
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// SubImm: regs[RA] = regs[RB] - IMM64, where IMM64 is a boxed int32 constant.
void zjs_stencil_SubImm(ZjsValue *regs, int *deopt) {
    int ok;
    uint64_t r = jv_num_sub(regs[(uintptr_t)&_JIT_RB].bits,
                            (uint64_t)(uintptr_t)&_JIT_IMM64, &ok);
    if (!ok) { JIT_DEOPT(deopt); }
    regs[(uintptr_t)&_JIT_RA].bits = r;
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// Mul: regs[RA] = regs[RB] * regs[RC], spec number semantics (else deopt).
void zjs_stencil_Mul(ZjsValue *regs, int *deopt) {
    int ok;
    uint64_t r = jv_num_mul(regs[(uintptr_t)&_JIT_RB].bits,
                            regs[(uintptr_t)&_JIT_RC].bits, &ok);
    if (!ok) { JIT_DEOPT(deopt); }
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
        JIT_DEOPT(deopt);
    }
    regs[(uintptr_t)&_JIT_RA].bits = lt ? JIT_VAL_TRUE : JIT_VAL_FALSE;
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// LoadElem: regs[RA] = regs[RB][regs[RC]] for the array fast path (J8). Calls
// the ctx-free engine helper jit_array_get_fast through the GOT-held address
// (asm-laundered so clang emits an indirect blr — no branch-range limit). The
// helper is read-only / allocation-free, so a miss is a clean deopt and a hit
// needs no write barrier (the result lands in a GC-rooted register).
void zjs_stencil_LoadElem(ZjsValue *regs, int *deopt) {
    typedef uint64_t (*arrget_fn)(uint64_t arr, int32_t idx, int *ok);
    uintptr_t haddr = (uintptr_t)&_JIT_HELP_arrget;
    arrget_fn helper;
    __asm__("" : "=r"(helper) : "0"(haddr));   // opaque → indirect call
    int ok = 0;
    uint64_t r = helper(regs[(uintptr_t)&_JIT_RB].bits,
                        (int32_t)(uint32_t)regs[(uintptr_t)&_JIT_RC].bits, &ok);
    if (!ok) { JIT_DEOPT(deopt); }
    regs[(uintptr_t)&_JIT_RA].bits = r;
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// StoreElem: regs[RA][regs[RB]] = regs[RC] for the array fast path (J8b).
// a=obj, b=key, c=val. Calls jit_array_set_fast through its GOT-held address.
// The helper writes only in-bounds dense slots with non-cell values (no write
// barrier, no allocation); anything else is a clean OSR deopt. No dst register.
void zjs_stencil_StoreElem(ZjsValue *regs, int *deopt) {
    typedef void (*arrset_fn)(uint64_t arr, int32_t idx, uint64_t val, int *ok);
    uintptr_t haddr = (uintptr_t)&_JIT_HELP_arrset;
    arrset_fn helper;
    __asm__("" : "=r"(helper) : "0"(haddr));   // opaque → indirect call
    int ok = 0;
    helper(regs[(uintptr_t)&_JIT_RA].bits,
           (int32_t)(uint32_t)regs[(uintptr_t)&_JIT_RB].bits,
           regs[(uintptr_t)&_JIT_RC].bits, &ok);
    if (!ok) { JIT_DEOPT(deopt); }
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// Jmp: unconditional branch to TARGET.
void zjs_stencil_Jmp(ZjsValue *regs, int *deopt) {
    __attribute__((musttail)) return _JIT_TARGET(regs, deopt);
}

// Nop: pass through. Used for the offset-carrier slot of a fused 2-slot jump
// (JmpIfNotLtImm et al.), which the interpreter never executes — keeping it in
// the layout preserves the 1:1 instruction-index ↔ stencil-slot mapping that
// branch targets depend on.
void zjs_stencil_Nop(ZjsValue *regs, int *deopt) {
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// JmpIfNotLt: fused compare-and-branch, register form. regs[RA] < regs[RB] ?
// fall through (CONTINUE) : branch to TARGET. Number compare; non-number
// deopts. Same 2-slot layout as the Imm form (offset carrier → Nop).
void zjs_stencil_JmpIfNotLt(ZjsValue *regs, int *deopt) {
    uint64_t a = regs[(uintptr_t)&_JIT_RA].bits;
    uint64_t b = regs[(uintptr_t)&_JIT_RB].bits;
    int lt;
    if (jv_is_int32(a) && jv_is_int32(b)) {
        lt = ((int32_t)(uint32_t)a) < ((int32_t)(uint32_t)b);
    } else if (jv_is_number(a) && jv_is_number(b)) {
        lt = jv_to_double(a) < jv_to_double(b);
    } else {
        JIT_DEOPT(deopt);
    }
    if (lt) __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
    __attribute__((musttail)) return _JIT_TARGET(regs, deopt);
}

// JmpIfNotLtImm: fused compare-and-branch. regs[RA] < IMM (a raw int, the i8
// immediate) ? fall through (CONTINUE) : branch to TARGET. Number compare;
// non-number deopts. The bridge sets CONTINUE to skip the offset-carrier slot
// (Nop) and TARGET to the loop-exit index.
void zjs_stencil_JmpIfNotLtImm(ZjsValue *regs, int *deopt) {
    uint64_t a = regs[(uintptr_t)&_JIT_RA].bits;
    int32_t imm = (int32_t)(int64_t)(uintptr_t)&_JIT_IMM64;
    int lt;
    if (jv_is_int32(a))       lt = ((int32_t)(uint32_t)a) < imm;
    else if (jv_is_number(a)) lt = jv_to_double(a) < (double)imm;
    else { JIT_DEOPT(deopt); }
    if (lt) __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
    __attribute__((musttail)) return _JIT_TARGET(regs, deopt);
}

// The ≤ / > / ≥ fused jumps are identical to JmpIfNotLt(Imm) but for the
// comparison operator (NaN → all false, matching JS, since C double compares
// are false on NaN). Generated to keep them byte-for-byte consistent.
#define JIT_FUSED_JMP_REG(NAME, OP)                                            \
void zjs_stencil_##NAME(ZjsValue *regs, int *deopt) {                          \
    uint64_t a = regs[(uintptr_t)&_JIT_RA].bits;                              \
    uint64_t b = regs[(uintptr_t)&_JIT_RB].bits;                              \
    int cond;                                                                 \
    if (jv_is_int32(a) && jv_is_int32(b))                                     \
        cond = ((int32_t)(uint32_t)a) OP ((int32_t)(uint32_t)b);             \
    else if (jv_is_number(a) && jv_is_number(b))                              \
        cond = jv_to_double(a) OP jv_to_double(b);                            \
    else { JIT_DEOPT(deopt); }                                                \
    if (cond) __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);    \
    __attribute__((musttail)) return _JIT_TARGET(regs, deopt);                \
}
#define JIT_FUSED_JMP_IMM(NAME, OP)                                           \
void zjs_stencil_##NAME(ZjsValue *regs, int *deopt) {                          \
    uint64_t a = regs[(uintptr_t)&_JIT_RA].bits;                             \
    int32_t imm = (int32_t)(int64_t)(uintptr_t)&_JIT_IMM64;                  \
    int cond;                                                                 \
    if (jv_is_int32(a))       cond = ((int32_t)(uint32_t)a) OP imm;          \
    else if (jv_is_number(a)) cond = jv_to_double(a) OP (double)imm;         \
    else { JIT_DEOPT(deopt); }                                                \
    if (cond) __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);    \
    __attribute__((musttail)) return _JIT_TARGET(regs, deopt);                \
}
JIT_FUSED_JMP_REG(JmpIfNotLe, <=)
JIT_FUSED_JMP_REG(JmpIfNotGt, >)
JIT_FUSED_JMP_REG(JmpIfNotGe, >=)
JIT_FUSED_JMP_IMM(JmpIfNotLeImm, <=)
JIT_FUSED_JMP_IMM(JmpIfNotGtImm, >)
JIT_FUSED_JMP_IMM(JmpIfNotGeImm, >=)

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
        JIT_DEOPT(deopt);
    }
    if (falsy) __attribute__((musttail)) return _JIT_TARGET(regs, deopt);
    __attribute__((musttail)) return _JIT_CONTINUE(regs, deopt);
}

// Return: leave the JIT'd region (back to the bridge / interpreter).
void zjs_stencil_Return(ZjsValue *regs, int *deopt) {
    (void)regs; (void)deopt;
}
