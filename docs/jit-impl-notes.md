# zjs JIT — implementation notes (living)

Running notes for the JIT *implementation* arc (after the Phase-1 substrate
spike's GO verdict — see [`jit-spike-phase1.md`](./jit-spike-phase1.md) and
[`jit-design-study.md`](./jit-design-study.md)). Tasks #362–#364.

The JIT is **opt-in (`ZJS_JIT`, off by default), second-class, zapp-desktop
only; iOS / sandboxed builds stay pure interpreter.**

## J1 — gate + stencil TU (done)

- `Makefile`: `ZJS_JIT` gate + `make jit-stencils` target. Compiles
  `tools/jit/stencils.c` → `build/jit_stencils-<arch>.o` with
  `-O3 -c -fno-asynchronous-unwind-tables -fomit-frame-pointer
  -fno-stack-protector -fno-pic` (relocation-clean: the only relocations left
  are the real holes). `JIT_ARCH` from `uname -m`. Inert in the default build.
- `tools/jit/stencils.c`: first stencils (`LoadConst`, `Mov`), CPython
  Tools/jit hole model — each hole is an `extern` placeholder, the next-stencil
  fall-through is a `musttail` call to `_JIT_CONTINUE`.

## Key toolchain finding: holes go through the GOT on Apple arm64

The spike's `jit_poc.c` hand-encoded `movz/movk` immediates. Real clang output
for an `extern` hole on **arm64-apple-darwin** does NOT use inline immediates —
it materializes the address via the **GOT**:

```
adrp x8, _JIT_RA@GOTPAGE      ; reloc: ARM64_RELOC_GOT_LOAD_PAGE21   (otool: GOTLDP)
ldr  x8, [x8, _JIT_RA@GOTPAGEOFF] ; reloc: ARM64_RELOC_GOT_LOAD_PAGEOFF12 (GOTLDPOF)
...
b    _JIT_CONTINUE            ; reloc: ARM64_RELOC_BRANCH26          (otool: BR26)
```

Tried `-fno-pic`, `-mcmodel=large`, `-mcmodel=small` — all still emit GOT
loads for external symbols on Darwin (large even routes the branch through the
GOT, which is worse). This matches what CPython 3.13 hits for
`aarch64-apple-darwin`; the fix is NOT to fight the GOT but to handle it:

**Implication for J2 (extractor) + J3 (stitcher):**
- The extractor must recognize three reloc kinds per stencil:
  `GOT_LOAD_PAGE21` + `GOT_LOAD_PAGEOFF12` (a GOT-loaded operand, as an
  adrp/ldr **pair** keyed by the same symbol) and `BRANCH26` (the
  continuation / intra-stencil branch).
- The stitcher builds a small **per-function data region** (a synthetic GOT)
  holding each instance's hole values, and rewrites the `adrp@GOTPAGE` +
  `ldr@GOTPAGEOFF` pair to address that region (page+offset of the value slot,
  relative to the stitched code). `BRANCH26` is patched to the
  next-stencil offset (the `jit_poc` back-edge mechanism).
- Operands that are small integers (register indices) still arrive as a
  GOT-loaded 64-bit value; we just store the small int into the data slot.
  (A later optimization can peephole adrp/ldr→movz for known-small holes, but
  correctness first.)

Relocation kinds observed (otool `-rv` shorthand → Mach-O):
`GOTLDP` = `ARM64_RELOC_GOT_LOAD_PAGE21`,
`GOTLDPOF` = `ARM64_RELOC_GOT_LOAD_PAGEOFF12`,
`BR26` = `ARM64_RELOC_BRANCH26`,
`UNSIGND` = `ARM64_RELOC_UNSIGNED` (in `__compact_unwind`, ignorable once
`-fno-asynchronous-unwind-tables` strips the rest).

## J2 — extractor + GOT-aware stitch validation (done)

- `tools/jit/extract_stencils.py`: hand-rolled Mach-O parser (no deps). Reads
  `__text` bytes per `_zjs_stencil_*` symbol (sizes derived from sorted symbol
  offsets), parses the `relocation_info` table, and emits
  `build/jit_stencils_<arch>.h` — `STENCIL_<op>_code[]` + `STENCIL_<op>_holes[]`
  ({offset, kind, sym}) + a `JIT_STENCILS[]` table. Cross-checks against
  `otool -rv` (10 holes = 5 LoadConst + 5 Mov). Makefile: `jit-stencils-header`.
- `tools/jit/stitch_test.c` (Makefile: `jit-stitch-test`): the pipeline
  GO/NO-GO. Stitches the EXTRACTED `LoadConst` under W^X with a **synthetic
  GOT** — lays out `[code][RET]…[GOT slots]`, writes the hole values into the
  slots (`__JIT_RA`→2, `__JIT_IMM64`→sentinel), patches each `adrp@GOTPAGE`
  (immlo/immhi = page delta) + `ldr@GOTPAGEOFF` (imm12 = slot&0xFFF>>3) pair to
  address its slot, patches `BRANCH26` to the RET, runs on a real frame.
  Result: `regs[2].bits == 0x123456789abcdef0` → **PASS**. The whole
  compile→extract→stitch→execute path is proven on real extracted stencils.

GOT patch encodings (arm64), for reference:
- `ADRP Xd, page`: imm21 = (page(slot) − page(pc)) >> 12; immlo = imm21 & 3
  (bits 30:29), immhi = (imm21 >> 2) & 0x7FFFF (bits 23:5).
- `LDR Xt, [Xn, #imm12]`: imm12 = (slot & 0xFFF) >> 3 (bits 21:10; /8 for x-reg).
- `B`: imm26 = (target − pc) >> 2 (bits 25:0); opcode 0x14000000.

## Next (J3)

Move the stitcher into the engine behind `ZJS_JIT`: an `src/jit/*.zc` runtime
that, given a hot `Function*`'s bytecode, allocates a MAP_JIT region, copies the
right stencil per instruction, builds the per-function GOT, patches operand
holes from the real `Inst` operands (`inst.a`/`inst.b`/immediates → GOT slots)
and chains the `BRANCH26` continuations, then runs it sharing the interpreter's
`reg_stack` frame (design study §4 — free deopt/GC). Grow the stencil set to the
§A.2 easy ops (Add/Sub/Mul/CmpLt*/Jmp/JmpIfFalse) and stand up one real loop
(J4) measured vs the spike's 4–6× model. Add a `Return`/epilogue stencil so the
last op returns to the interpreter instead of a hand-appended RET.
