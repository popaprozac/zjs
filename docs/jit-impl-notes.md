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

## J3b-1 — engine build integration (done)

The JIT is now compiled INTO the engine behind `ZJS_JIT`, and the engine binary
runs the copy-and-patch stitcher end to end.

- **Gating mechanism (settled).** `zc build` forwards command-line `-D`/`-I` to
  its clang backend AND compiles+links extra `.c` sources passed positionally
  (verified: `zc build jt.zc jp.c -DZJS_JIT` defines the macro for raw{} blocks
  and resolves the extern). So the gate is just conditional command-line args —
  no `ZC_FLAGS` surgery, no touching the separate stdlib clang step. Makefile:
  when `ZJS_JIT` is set, `JIT_BUILD_ARGS := -DZJS_JIT -Ibuild src/jit/jit_stitch.c`
  and `JIT_BUILD_DEPS := <generated header>`, appended to the `cli` rule; both
  EMPTY by default so the default/iOS build is byte-identical (recipe unchanged).
  The vars are defined before the `cli` rule (prereqs expand at parse time).
- `src/jit/jit_stitch.c`: the engine-side stitcher (the two-pass loop stitcher
  generalized + `jit_selftest_loop()`), includes the generated header. Pure C,
  no zc-type coupling yet.
- `tools/zjs.zc`: a `jit-selftest` subcommand inside a `raw { #ifdef ZJS_JIT
  extern int jit_selftest_loop(void); ... #endif }` block. Absent (prints "no
  JIT") in the default build; PASS in the `ZJS_JIT=1` build.
- Verified: `make ZJS_JIT=1 cli` → `./build/zjs jit-selftest` = PASS, normal JS
  still runs; default `make cli` → "no JIT" and test262 unchanged (87.2%,
  23338, 0 delta).

NOTE on comptime: Zen-c `comptime { yield(...) }` can't read external `-D`
defines, so raw{} `#ifdef` is the right gate. comptime IS the future lever for
CODEGEN — generate the `Op`→stencil dispatch table (and maybe stencil bodies)
from one comptime list instead of hand-maintaining them.

## J3b-2a — JIT real compiled bytecode (value-faithful subset, done)

The engine now JITs REAL compiled JS bytecode (not hand-written self-test
descriptors) and matches the interpreter.

- `src/jit/jit_stitch.c`: `jit_compile(prog, n)` extern — the zc side hands it a
  layout-matched `JitInsn[]` and runs the returned pointer.
- `tools/zjs.zc`: `JitDesc`/`JitResult` zc structs (mirror the C `JitInsn`) + a
  `jit_try_run(ctx, f)` that walks `f.code[]`, maps each `Op` to a stencil +
  operands, and **bails** (`ok=0`) on any op outside the value-faithful subset —
  so the interpreter result always stands. Subset: `LoadInt`/`LoadConst`/
  `LoadUndefined`/`LoadNull`/`LoadTrue`/`LoadFalse` (→ the `LoadConst` stencil
  with the right boxed bits), `Mov`, `Return`. These reproduce the interpreter
  EXACTLY (load/copy boxed values), so JIT == interpret by construction. The
  `jit_compile` call lives in a `raw{} #ifdef ZJS_JIT` block, so the function is
  a harmless always-bail no-op in the default build.
- `jit-check "<expr>"` CLI: compile → run via interpreter AND via the JIT →
  compare bits. Verified: `42`, `1000000`, `undefined`/`null`/`true`/`false`
  → `PASS (jit == interp)`; `1+2`, `-7` → clean `BAIL` (Add/Neg not yet
  faithful). Default build: `jit-check` reports no-JIT; test262 unchanged.

This proves the whole real-bytecode path: `Op`→stencil, operands from `Inst`
(+ constants pool), a frame-allocated run, return-value read, and the bail
safety net. The frame here is a fresh `alloc_n<ZjsValue>` (true `reg_stack`
sharing comes with nested calls); good enough for a top-level program.

## Next — faithful arithmetic + loops + measurement (J4)

1. **Build gating** — DONE.
2. **Real bytecode consume + bail** — DONE (value-faithful subset).
3. **Faithful arithmetic/compare/branch stencils.** Make `Add`/`AddImm`/`CmpLt`/
   `JmpIfFalse`/`JmpIfNotLt` (the fused loop op) NaN-box-correct: inline the
   int32 fast path (unbox via tag check, add with overflow → rebox) and `call`
   the existing interpreter helper on the slow path. Then a real JS loop JITs.
4. **Branch target mapping.** `Jmp`/`JmpIfFalse` carry a signed instruction
   offset (`inst_bc_i16`); convert to a target instruction index for the
   stitcher's `_JIT_TARGET` hole (the loop_test already proved back-edges).
5. **Hot-loop detection + dispatch hook**, then **measure a real JS loop vs the
   spike's 4–6× model** — the implementation GO/NO-GO.
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
