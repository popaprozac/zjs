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

## J4 — faithful NaN-box arithmetic (DONE)

The value-infaithful stencils (raw int64) are replaced with **conformance-
faithful** ones that match `value.zc`'s encoding and `zjs_arith_*` semantics
exactly. Key decisions:

- **2-arg ABI.** Every stencil is now `void f(ZjsValue *regs, int *deopt)`
  (x0/x1). A value op that meets an operand outside its fast domain (a non-
  number for arithmetic, a non-primitive for a branch test, a TDZ hole) writes
  `*deopt = 1` and `return`s; the bridge discards the partial run and falls back
  to the interpreter. Both regs/deopt thread through every continuation
  unchanged, so a `musttail` is still a bare `b` — the stitcher is untouched.
- **Faithful number ops** (`Add`/`Sub`/`AddImm`/`SubImm`/`CmpLt`): int32 fast
  path with overflow→double, then the both-number (double) path, mirroring
  `zjs_arith_add`/`_sub`. `JmpIfFalse` does real ToBoolean (bool/null/undefined/
  numeric-zero inline; strings/objects deopt). `ThrowIfHole` deopts on the hole.
- **No new relocations.** The 64-bit NaN-box constants (`NUMBER_TAG`,
  `1<<49`) materialize inline via movz/movk and the bit-casts use unions — so
  the only holes remain GOT (kind 5/6) + BRANCH26 (kind 2). Copy-and-patch is
  unchanged; faithfulness was free at the toolchain level.

**Validated.** `jit-selftest` now runs the register loop with *boxed* values:
sum(0..1e6−1) overflows int32 partway, so it exercises the int32 path → the
int32→double promotion → the double-add path → the boolean condition → the
back-edge, and checks the boxed-double result. `jit-check` PASSes real compiled
JS: `1+2`, `1+2+3`, `10-3`, `100+200+300`, and **`2147483647+1`** (the overflow
boundary, on real bytecode). Default build unchanged (test262 diff empty).

## J4b — real JS loops JIT + first measurement (DONE)

A real register-based loop now JITs end to end and matches the interpreter.

- **Inner-function extraction.** Top-level `let` compiles to *globals*
  (`DefineGlobal`/`LoadGlobal`), so a script-level loop is all global-table
  access — not register-based. Register locals only exist inside a function
  body, which the compiler stores as a function value in the enclosing
  constant pool. `jit-check`/`jit-bench` dig out the first 0-arg inner function
  (`jit_find_inner_function`) and JIT *that*, which is also the eventual
  hot-loop target.
- **Fused 2-slot jumps.** `JmpIfNotLt` (reg form) and `JmpIfNotLtImm` carry
  their i16 offset in the *following* instruction slot. The dispatch loop has a
  universal bottom `ip += 1`, so: `Jmp` target = `i + off + 1`; fused-jump
  exit = `i + off + 2`, continue = `i + 2` (skips the carrier). The bridge maps
  the carrier slot to a new `Nop` stencil (never executed — preserves the 1:1
  index↔slot mapping branch targets need) and points the jump's `_JIT_TARGET`
  at the exit index.
- **Authoritative op identity.** The interpreter's op-name *table* drifts from
  the `Op` enum past `Mov`; `jit_op_name` (symbolic `Op::` comparisons) is the
  reliable disassembler (`JITDUMP=1`).

**Measured** (`jit-bench`, K=5, jit==interp gated first; Apple Silicon):
| loop (1e7 iters) | interp | jit | speedup |
|---|---|---|---|
| `s += i` (overflows int32 → double) | 140.8 ms | 67.5 ms | **2.08×** |
| `a = i` (stays int32) | 101.8 ms | 65.2 ms | **1.56×** |

Honest read: real but below the spike's 4–6× — the bench *includes* per-call
compile/alloc, and the copy-and-patch baseline still pays per-op tail-call
overhead (no fusion/IC yet). The number is the floor, not the ceiling.

## J5 — the JIT fires under `run` (DONE)

The JIT now dispatches from inside the interpreter: a hot function is compiled
once, cached on the `Function*`, and run from the live frame — so it pays off
under plain `zjs run`, not just `jit-check`/`jit-bench`.

- **One seam, every call path.** The hook sits at the top of the dispatch loop
  at `ip == 0` (after the `this`-seed, before the inner loop). Every call —
  the entry frame AND trampoline `Op::Invoke` pushes — funnels through here, so
  no call-machinery surgery was needed. It reuses the existing frame setup
  (params/`this`/env already bound) and, on a successful run, finishes exactly
  as `Op::Return` would (`pop_call_frame` + write the result to the caller /
  `final_result`, then `continue` — verified equivalent to `exit_reason==1`).
- **Compile once, cache.** `Function` gains `jit_code`/`jit_ret_reg`/
  `jit_calls`/`jit_state` (all zero-init). State machine: 0 unknown → count to
  `ZJS_JIT_THRESHOLD` (default 8) → `jit_compile_fn` → 1 compiled or 2 disabled.
- **Eligibility (kept tight for safety):** plain sync functions (not
  generator/async/ctor), body fully in the op subset, **exactly one `Return`**
  (unambiguous return reg), and **no in-place write to a param register**.
  That last rule is the deopt-safety invariant: a deopt re-interprets from
  `ip==0`, which re-inits locals but not params, so a partial JIT run that
  mutated a param would corrupt the re-run's inputs. Read-only params (e.g.
  `sumTo(n)`) still qualify; the subset is otherwise side-effect-free, so a
  deopt is a safe no-op rollback.
- **Gating.** Folded out entirely in the default/iOS build via
  `jit_build_enabled()` (clang constant-folds → zero cost). Runtime knobs:
  `ZJS_JIT_OFF=1` disables, `ZJS_JIT_THRESHOLD=N` tunes hotness.

**Validated.** test262 on the **ZJS_JIT build with `ZJS_JIT_THRESHOLD=1`**
(every eligible function JIT'd) = **byte-identical** failure set to the
interpreter baseline (0 new / 0 fixed across 27k tests). Real `run` (1e8 iters
across 100 hot `sumTo(1e6)` calls): interp **1.60 s** → JIT **0.82 s** =
**1.95×** — clean ~2× now that compile is cached (no per-call recompile).

## J6 — deopt-resume / OSR (DONE)

A deopt no longer re-runs from the top — the interpreter **resumes at the exact
deopt instruction** with the live registers.

- **The deopt channel carries an index, not a flag.** Each deopt-capable
  stencil reports its OWN bytecode index via a new `_JIT_BCIDX` hole
  (`*deopt = (int)&_JIT_BCIDX`, the same GOT-slot-holds-the-value trick as the
  reg holes; the stitcher patches it to the instruction index `i`). `-1` =
  "ran to the Return". The engine hook: `jdeopt < 0` → finish as `Op::Return`;
  `jdeopt >= 0` → `ip = jdeopt` and fall through to the interpreter.
- **Why it's correct.** The JIT executed `0..jdeopt-1` faithfully in place
  (every stencil mirrors its interpreter op), so the live frame at `jdeopt` is
  bit-identical to what the interpreter would have — *including any params it
  mutated*. Resuming at `jdeopt` continues rather than replays, so the
  **param-write guard is gone**: `g(x){ x = x-1; return x + null; }` now JITs,
  deopts at `x + null`, and resumes with `x = 4` → correct `4`. A deopting
  function is then disabled (`jit_state = 2`) — usually polymorphic, not worth
  re-JITting.
- The pure-numeric monomorphic path (the actual hot case) never deopts and is
  unaffected.

**Validated.** test262 on the ZJS_JIT build with `ZJS_JIT_THRESHOLD=1` (every
eligible fn JIT'd, now including param-mutating bodies) = byte-identical
failure set to the interpreter baseline. Default build unchanged.

## Next — J6+/J7

1. **More ops + wider loop shapes:** `Mul`/`Div`/`Mod`, the rest of the compare
   + fused-jump family (`CmpLtImm`/`≤,>,≥` and `JmpIfNotLe/Gt/Ge(Imm)`), so
   `for(i=n;i>0;i--)` / `i<=n` / multiply-heavy bodies JIT.
2. **IC inlining + property/global access** (`LoadGlobal`/`LoadProp` with `ctx`
   threaded into the ABI), then **fusion** to close toward the spike's 4–6×.
3. **Multi-`Return`** via the unified exit channel (Return reports its index
   too → drop the single-Return restriction).
4. **Platform-gate finalize + lifetime:** the `ZJS_JIT` Makefile gate already
   excludes iOS — lock it in + document, and free cached regions on
   `Function`/GC teardown (today they leak for the process lifetime).
