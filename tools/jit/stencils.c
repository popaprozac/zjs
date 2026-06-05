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

#include <stdint.h>

// Mirror of the engine's NaN-boxed value cell. The JIT keeps values in the
// interpreter's frame layout (design study §4) so deopt + GC stay free.
typedef struct { uint64_t bits; } ZjsValue;

// The stencil ABI: x0 = regs (the current frame's register file). Every stencil
// receives it and tail-calls the next with it unchanged.
typedef void (*JitCont)(ZjsValue *regs);

// ---- Holes (patched per instruction at stitch time) ------------------------
extern uint8_t  _JIT_RA;        // operand register index a (usually dest)
extern uint8_t  _JIT_RB;        // operand register index b
extern uint8_t  _JIT_RC;        // operand register index c
extern uint64_t _JIT_IMM64;     // a 64-bit immediate (constant / int operand)
extern void     _JIT_CONTINUE(ZjsValue *regs);   // fall-through to next stencil
extern void     _JIT_TARGET(ZjsValue *regs);     // explicit branch destination

// NOTE on value model: these first ops operate on regs[].bits as a raw int64 to
// validate the STITCHING machinery (operands, branches, back-edges) on the real
// int_loop shape. The conformance-faithful stencils share the interpreter's
// actual op-bodies (NaN-box unbox/rebox + guards) — that's the engine-integration
// step. The extractor/stitcher are identical either way.

// LoadConst: regs[RA] = IMM64.
void zjs_stencil_LoadConst(ZjsValue *regs) {
    regs[(uintptr_t)&_JIT_RA].bits = (uint64_t)(uintptr_t)&_JIT_IMM64;
    __attribute__((musttail)) return _JIT_CONTINUE(regs);
}

// Mov: regs[RA] = regs[RB].
void zjs_stencil_Mov(ZjsValue *regs) {
    regs[(uintptr_t)&_JIT_RA] = regs[(uintptr_t)&_JIT_RB];
    __attribute__((musttail)) return _JIT_CONTINUE(regs);
}

// Add: regs[RA] = regs[RB] + regs[RC].
void zjs_stencil_Add(ZjsValue *regs) {
    regs[(uintptr_t)&_JIT_RA].bits =
        regs[(uintptr_t)&_JIT_RB].bits + regs[(uintptr_t)&_JIT_RC].bits;
    __attribute__((musttail)) return _JIT_CONTINUE(regs);
}

// AddImm: regs[RA] = regs[RB] + IMM64.
void zjs_stencil_AddImm(ZjsValue *regs) {
    regs[(uintptr_t)&_JIT_RA].bits =
        regs[(uintptr_t)&_JIT_RB].bits + (uint64_t)(uintptr_t)&_JIT_IMM64;
    __attribute__((musttail)) return _JIT_CONTINUE(regs);
}

// CmpLt: regs[RA] = (regs[RB] < regs[RC]) ? 1 : 0  (signed).
void zjs_stencil_CmpLt(ZjsValue *regs) {
    regs[(uintptr_t)&_JIT_RA].bits =
        ((int64_t)regs[(uintptr_t)&_JIT_RB].bits <
         (int64_t)regs[(uintptr_t)&_JIT_RC].bits) ? 1 : 0;
    __attribute__((musttail)) return _JIT_CONTINUE(regs);
}

// Jmp: unconditional branch to TARGET.
void zjs_stencil_Jmp(ZjsValue *regs) {
    __attribute__((musttail)) return _JIT_TARGET(regs);
}

// JmpIfFalse: if regs[RA] == 0 branch to TARGET, else fall through.
void zjs_stencil_JmpIfFalse(ZjsValue *regs) {
    if (regs[(uintptr_t)&_JIT_RA].bits == 0)
        __attribute__((musttail)) return _JIT_TARGET(regs);
    __attribute__((musttail)) return _JIT_CONTINUE(regs);
}

// Return: leave the JIT'd region (back to the caller / interpreter).
void zjs_stencil_Return(ZjsValue *regs) {
    (void)regs;
}
