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

## J3a — easy-op stencil set + two-pass LOOP stitcher (done)

- `tools/jit/stencils.c` grown to 8 ops: `LoadConst`, `Mov`, `Add`, `AddImm`,
  `CmpLt`, `Jmp`, `JmpIfFalse`, `Return`. New holes: `_JIT_RC` (3rd operand),
  `_JIT_TARGET` (explicit branch destination, a 2nd `BRANCH26`). The extractor
  picks all of them up unchanged (8 stencils, holes verified).
- `tools/jit/loop_test.c` (Makefile: `jit-loop-test`): a **two-pass stitcher**
  for a real loop. Pass 1 lays out a stencil per bytecode instruction and
  records each instruction's code offset (the pc-map). Pass 2 patches each
  instruction's operand holes (per-instruction GOT slots from `ra/rb/rc/imm`),
  its `_JIT_CONTINUE` (BRANCH26 → next instruction), and its `_JIT_TARGET`
  (BRANCH26 → the jump-destination instruction — forward branch AND back-edge).
  Assembles the `int_loop` body (acc+=i; i++; if i<N goto loop) and runs it:
  `sum(0..1000000-1) = 499999500000` → **PASS**. This is the J4 mechanism
  proven; values are raw int64 in `.bits` (validates STITCHING — conformance-
  faithful NaN-box stencils are the engine step).
- `make jit-test` runs the whole self-test chain (stitch + loop).

The toolchain is complete and proven: compile → extract → two-pass stitch of a
real loop with operands, continuations, a conditional branch, and a back-edge.

## Next — engine integration (J3b/J4)

The remaining work is wiring this into the engine behind `ZJS_JIT`:
1. **Build gating.** Add `src/jit/jit.zc` to the engine build only when
   `ZJS_JIT` is set, with `-DZJS_JIT` reaching the clang that compiles the
   raw{} blocks + the generated header `#include`. (Investigate the existing
   `ZJS_NO_*` define plumbing — it currently rides a separate clang step at
   Makefile:250, NOT the main `zc build`; the JIT needs the define on the
   main engine build. Likely append to `ZC_FLAGS` for a JIT build and confirm
   `zc` forwards `-D`/`-I` like it does `-Isrc`.)
2. **Consume real bytecode.** Map zjs `Op` → stencil, extract operands from
   the real `Inst` (`inst.a`/`inst.b`/`inst.c` + `inst_bc_*` immediates),
   build the pc-map over the function's `code[]`, bail (don't JIT) on any op
   outside the easy set so correctness is never at risk.
3. **Frame sharing.** Run the JIT'd code on the interpreter's live `reg_stack`
   frame (design study §4) so deopt + GC stay free; the entry passes
   `&reg_stack[regs_base]`.
4. **Hot-loop detection + dispatch hook + measure.** Count back-edges per
   Function*; once hot, JIT the body and run vs the interpreter; **measure
   int_loop against the spike's 4–6× model** — the implementation GO/NO-GO.
5. Conformance-faithful stencils (share the interpreter op-bodies / NaN-box),
   then IC inlining + deopt + the platform gate (J5/J6).
