// stencil_probe.c — de-risking experiment for the zjs JIT stencil pipeline.
// Proves the CPython Tools/jit "hole = extern symbol → relocation" technique
// works on this clang/arm64 toolchain: each HOLE must show up as a relocation
// record in the compiled .o so extract_stencils.py can find + patch it.
//
//   clang -O3 -c -fno-asynchronous-unwind-tables -fomit-frame-pointer \
//       tools/jit/stencil_probe.c -o /tmp/stencil_probe.o
//   otool -rv /tmp/stencil_probe.o      # relocations (the holes)
//   otool -tv /tmp/stencil_probe.o      # disassembly (the stencil body)
//
// NOT wired into the engine.
#include <stdint.h>

typedef struct { uint64_t bits; } ZjsValue;

// --- Holes: extern placeholders. The compiler can't fold an unknown address,
// so it emits a RELOCATION wherever the hole is materialized. At stitch time
// the JIT overwrites that site with the real value (operand / branch target).
extern uint8_t  _JIT_DST;                  // dest frame-slot index
extern uint64_t _JIT_IMM;                  // value to store (NaN-boxed int)
extern void     _JIT_CONTINUE(ZjsValue *); // next stencil (branch hole)

// Stencil for a LoadInt-shaped op: regs[DST] = IMM ; then fall through to the
// next stencil via a musttail call (the CPython continuation-as-tailcall trick,
// so stencils stitch with no prologue/epilogue and the branch is one reloc).
void zjs_stencil_LoadConst(ZjsValue *regs) {
    regs[(uintptr_t)&_JIT_DST].bits = (uint64_t)(uintptr_t)&_JIT_IMM;
    __attribute__((musttail)) return _JIT_CONTINUE(regs);
}
