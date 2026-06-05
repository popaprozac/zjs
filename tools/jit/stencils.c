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
extern uint8_t  _JIT_RA;        // operand register index a (dest)
extern uint8_t  _JIT_RB;        // operand register index b (src)
extern uint64_t _JIT_IMM64;     // a 64-bit immediate (e.g. a NaN-boxed constant)
extern void     _JIT_CONTINUE(ZjsValue *regs);   // fall-through to next stencil

// LoadConst-shaped: regs[RA] = IMM64.  (constant materialized as a 64-bit hole)
void zjs_stencil_LoadConst(ZjsValue *regs) {
    regs[(uintptr_t)&_JIT_RA].bits = (uint64_t)(uintptr_t)&_JIT_IMM64;
    __attribute__((musttail)) return _JIT_CONTINUE(regs);
}

// Mov: regs[RA] = regs[RB].  (two register-index holes, no value hole)
void zjs_stencil_Mov(ZjsValue *regs) {
    regs[(uintptr_t)&_JIT_RA] = regs[(uintptr_t)&_JIT_RB];
    __attribute__((musttail)) return _JIT_CONTINUE(regs);
}
