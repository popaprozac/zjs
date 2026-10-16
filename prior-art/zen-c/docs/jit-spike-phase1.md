# zjs JIT — Phase 1 Substrate Spike (GO/NO-GO research deliverable)

> Companion to [`jit-design-study.md`](./jit-design-study.md). This is the
> Phase-1 *substrate spike* the design study's Implementation-order §1 calls
> for: prove the copy-and-patch mechanism on this platform, bound the
> dispatch-elimination win on a hot loop, and return a GO/NO-GO.
>
> **This is a research spike, not a JIT.** No engine source was modified. Two
> standalone C artifacts were built and measured: `tools/jit/jit_poc.c` (the
> W^X copy-and-patch mechanism) and `tools/jit/native_ref.c` + `tools/jit/jit_model.c`
> (the perf ceiling bounds). Numbers measured 2026-06-04 on the host below.

## TL;DR verdict

**GO — but conditional and scoped, with one re-scoping recommendation.**

- The **copy-and-patch W^X mechanism works on Apple Silicon** (PASS, see §B). No
  blocker there — `MAP_JIT` + `pthread_jit_write_protect_np` + i-cache flush is
  straightforward and the conformance-by-construction story (same clang -O3 on
  the same op-bodies) holds.
- The **dispatch-elimination headroom is large, not marginal**: the interpreter
  spends ~90% of hot-loop time on dispatch/decode/guard-ladder/control overhead
  (profiled, §C), not arithmetic. A baseline JIT that only removes that has a
  **realistic ~4–6x** ceiling on integer-hot loops (honest center), with an
  optimistic edge to ~13x. This is well above the design study's worried
  "1.5–2x → not worth it" bar. The brief's hypothesis that the already-jump-
  tabled dispatch leaves little room is **refuted for hot arithmetic loops**.
- **BUT** the strategic justification needs a correction. zjs already **beats
  our jitless peer qjs** on these loops (2.1x faster on int_loop, faster on
  double_loop; 1.2x slower only on fib's call overhead). The JIT's job is
  therefore *not* "catch qjs" — it's "close the gap to V8/JSC (currently
  14–40x)". A no-regalloc baseline copy-and-patch JIT closes maybe 4–6x of that
  and **leaves a large residual gap** to the optimizing tiers. So: GO on the
  substrate, but right-size expectations — this is a 4–6x desktop win, not a
  "JSC-class throughput" win, and it must stay the second-class, opt-in,
  zapp-desktop-only tier the design study already scopes.

See §D for the full reasoning and the next 3–5 steps.

### Host / toolchain
```
Darwin 25.5.0  arm64 (Apple M-series, Mac Studio T6041)
Apple clang version 21.0.0
zc v0.4.4-217-g10cf66d
build/zjs built via `make cli` (clean, 0 errors)
```

---

## (A) Feasibility of copy-and-patch for zjs specifically

### A.1 How stencils get generated given the zc→clang toolchain

zjs has a property most engines don't: **the op-bodies are already pure C-level
functions** after the `zc` transpile, compiled by the *same* clang -O3 that
builds the interpreter. That makes the CPython 3.13 `Tools/jit/` model a near-
direct fit. The pipeline (mirroring CPython's `_stencils.py` / `jit.py`):

1. **Author a stencil TU** — one function per (opcode, operand-width), in `zc`,
   with the op-body logic factored out of `interpret_inner_full`'s giant
   if/else chain. The "holes" (immediates, branch targets, runtime-helper
   addresses) are expressed as `extern` placeholder symbols, e.g.
   `extern void zjs_HOLE_next_stencil(void);` and `extern uint64_t zjs_HOLE_imm;`.
   Because the body is the *same source semantics* as the interpreter handler,
   a JIT'd `Add` is guaranteed to match the interpreted `Add` — the design
   study's "conformance superpower."

2. **Transpile + compile, don't link**: `zc stencils.zc → stencils.c`, then
   `clang -O3 -c -fno-asynchronous-unwind-tables -fomit-frame-pointer
   stencils.c → stencils-<arch>.o`. One object per target arch (arm64,
   x86-64). The `-fno-pic`/`large`-code-model knobs CPython uses to keep
   relocations simple apply here too.

3. **Extract** (a new build step, `tools/jit/extract_stencils.py`): read each
   `.o` via Mach-O/ELF, pull each function's `__text` bytes (the stencil body)
   and its **relocation records** (the holes — offset + kind + target symbol).
   Emit a generated header:
   ```c
   static const uint8_t STENCIL_Add[]       = { 0x.. };
   static const Hole    STENCIL_Add_holes[] = {{off, R_ARM64_MOVW_*, "zjs_HOLE_imm"}, ...};
   ```

4. **Runtime stitch** (the JIT proper): `mmap(MAP_JIT)` → for each bytecode
   instruction `memcpy(STENCIL_<op>)` → apply each hole (splice immediate / fix
   the branch to the next stencil's offset / store the helper address) →
   `pthread_jit_write_protect_np` toggle → `sys_icache_invalidate` → execute.
   This is exactly what `jit_poc.c` does by hand in §B; the only difference is
   the stencil bytes come from step 3 instead of hand-encoding.

**Where the new step slots into the build.** It is a post-compile, pre-link
codegen step gated on `ZJS_JIT`: `Makefile` adds a `stencils-$(ARCH).o` target,
runs `extract_stencils.py` to produce `build/jit_stencils_$(ARCH).h`, and the
JIT TU `#include`s it. Off by default; never built for iOS. The zc wrinkle is
benign: `zc` already emits C, so the stencil TU rides the existing
`zc → clang -O3` path with no new toolchain dependency (no LLVM, no Cranelift,
no assembler) — which is the whole point of choosing copy-and-patch.

### A.2 Easy first-target opcodes (high payoff, no GC/throw/call hazards)

These are straight-line, allocation-free, and dominate the hot arithmetic/loop
profile. They should be the spike-2 stencil set:

| Op | Why easy |
|---|---|
| `LoadInt`, `LoadConst`, `Mov`, `LoadUndefined`/`Null`/`True`/`False` | pure frame-slot writes; immediate is the only hole |
| `Add`, `Sub`, `Mul` | int32 fast path + inline guard; cold path can `call` the existing handler |
| `AddImm`, `SubImm` | immediate hole already i8 — trivial |
| `CmpLt`/`Le`/`Gt`/`Ge` and the `*Imm` forms | bool result to a frame slot |
| `Jmp`, `JmpIfFalse`/`True`, and the fused `JmpIfNot*` | branch-target hole = offset to another stencil; the loop back-edge keeps a GC-poll call |
| `LoadProp`/`StoreProp` (with IC) | reuse the existing shape-keyed IC side-table; emit the shape guard inline, `call` the IC-miss helper on miss — design study §5 |

The first six rows alone cover essentially all of `int_loop`, `double_loop`,
and the inner arithmetic of `nbody`/`mandelbrot`.

### A.3 The hard parts (defer / wrap as `call` to existing helpers)

- **Calls (`Invoke`/`MethodInvoke`/`TailInvoke`)** — frame push/pop, arg copy,
  re-entry. v1 should emit a `call` into the existing C call-frame machinery
  rather than inlining; the win on `fib` will be smaller as a result (call
  overhead dominates there, see §C). Tail-call's in-place frame replacement
  (commit 7d1b844 caveats) must be preserved.
- **Allocation safepoints** — `NewObject`/`NewArray`/`NewClosure` must hit the
  same write-barrier + `ctx_maybe_gc` hooks. Keep them as `call` stencils with
  the safepoint metadata, not inlined.
- **Exception unwind** — every op that can throw (`Add` on a Symbol, property
  access, TDZ `ThrowIfHole`) must bail to the interpreter at the bytecode
  index. The design study's free-deopt model (shared frame layout) makes this a
  `jit_pc → bytecode_index` table lookup + interpreter re-entry; the stencil's
  throw path is a `call` that returns a "deopt to N" signal.
- **GC frame scan** — works *for free* only because the JIT keeps values in the
  interpreter frame layout (no regalloc). This is load-bearing: any later
  regalloc tier needs precise stack maps (explicitly v2).

**Conclusion (A):** Feasible and a clean fit. zc's "compiles to C" nature makes
the CPython stencil-extraction model directly reusable, with **no new runtime
dependency**. The hard parts all have a safe fallback: emit a `call` to the
existing interpreter helper and keep the shared frame.

---

## (B) Copy-and-patch W^X proof-of-concept — `tools/jit/jit_poc.c`

A standalone C file (not wired into the engine) that stitches two micro-stencils
— a constant-load with a **patchable immediate hole** and an integer-sum loop
with a **back-edge branch** — into one function `uint64_t f(void)` computing
`sum(0..N-1)`, entirely under W^X.

**What it exercises (the full mechanism):**
1. `mmap(PROT_READ|WRITE|EXEC, MAP_PRIVATE|ANON|MAP_JIT)` — `MAP_JIT` is
   **required** on Apple Silicon; a plain `PROT_EXEC` anon map is denied.
2. `pthread_jit_write_protect_np(0)` → **copy** stencil words → **patch** the
   `MOVZ/MOVK` immediate hole with the real N (verifying the sentinel was
   present first, proving it's a real relocation not a baked constant) →
   `pthread_jit_write_protect_np(1)`.
3. `sys_icache_invalidate` (mandatory on arm64 after writing code).
4. Call the buffer and compare against the closed-form `N*(N-1)/2`.

**Commands and output (verbatim):**
```
$ clang -O2 -o /tmp/jit_poc tools/jit_poc.c
$ /tmp/jit_poc
[poc] mmap MAP_JIT ok: 0x1047bc000 (16384 bytes, page=16384)
[poc] hole sentinel present before patch: yes
[poc] patched N=1000000 (lo=0x4240 hi=0x000f)
[poc] jit sum(0..1000000-1) = 499999500000
[poc] expected           = 499999500000
[poc] PASS
$ echo $?
0
```

**Result: the W^X copy-and-patch mechanism works on this platform.** The page is
never RWX simultaneously (write-protect is toggled per-thread), the immediate
hole is patched at runtime, the back-edge branch is stitched, and the executed
code returns the correct sum. The only deployment caveat is the platform gate
the design study already names: a CLI binary from Terminal may JIT freely; an
app under the hardened runtime needs `com.apple.security.cs.allow-jit`.

---

## (C) Measured dispatch-elimination upside (the core GO/NO-GO datum)

**Method.** All loop bodies timed *loop-only* (in-JS `Date.now()` on the engine
side, `CLOCK_MONOTONIC` on native), best-of-N, excluding process startup, so we
compare the actual hot loop and not parse/boot. Native references defeat clang's
closed-form folding with an opaque per-iteration barrier so the loop genuinely
runs N times (else `-O3` collapses `sum(0..n-1)` to a multiply — see the
`folded` vs `real` columns in `tools/jit/native_ref.c`).

### C.1 Where the interpreter's hot-loop time goes (profiled)

`sample` on a 2×10^8-iteration `sum=sum+i` loop:

```
interpret_inner_full ........ ~250 samples   (dispatch + a/b/c decode +
                                               Op::Add guard ladder + loop ctrl)
zjs_arith_add ...............  ~22 samples   (the actual int32 add)
```

**~90% of hot-loop time is interpreter overhead a JIT can attack; ~10% is
irreducible arithmetic.** This is the quantitative basis for the win band below.

### C.2 The ceilings (int_loop, n=10^7, loop-only)

| Variant | ms | speedup vs zjs interp | what it models |
|---|---|---|---|
| zjs interpreter (`let`) | **85** | 1.0x | baseline |
| `jit_model` (NaN-box memory frame, **no dispatch/decode**, conservative — reloads frame each op) | **19.4** | **4.4x** | realistic no-regalloc baseline JIT, low end |
| `jit_model_opt` (same, frame slots kept in regs within the body) | **6.2** | **13.7x** | realistic baseline JIT, optimistic edge |
| `native_ref` real (full regalloc, native i64, no NaN-box) | **2.2** | **38.6x** | theoretical ceiling — **unreachable** by a no-regalloc baseline |

The honest baseline-JIT estimate is the **4–6x** region: a copy-and-patch JIT
keeps NaN-boxed values in the shared frame (design study §4) and stitches
separate stencils, so consecutive ops genuinely reload operands from frame slots
— closer to the conservative `jit_model` than to full regalloc. The 38x native
number is *not* a baseline-JIT target; it's the cost of the NaN-box + memory-
frame discipline the design deliberately accepts to make deopt/GC free.

### C.3 Cross-engine context (loop-only, best-of-8)

| bench | zjs | qjs (jitless peer) | node (V8) | bun (JSC) | native | realistic JIT est. |
|---|---|---|---|---|---|---|
| int_loop (1e7, `let`) | 85 | 178 | 6 | 5 | 2.2 | ~14–20 (≈4–6x) |
| double_loop (5e5) | 4 | 6 | 0.4 | 0.4 | 0.28 | ~1 |
| fib(32) | 126 | 103 | 10 | 7 | 3.2 | ~40–60 (call-bound; smaller win) |

**Two findings that reshape the justification:**

1. **zjs already beats qjs** on the arithmetic loops (2.1x faster on int_loop,
   1.5x on double_loop), and trails only on `fib` (1.2x slower — pure call
   overhead). The jitless interpreter is *already* at/ahead of our peer. So the
   JIT's mission is not "reach qjs"; it's "claw toward V8/JSC."
2. The gap to the **JIT engines is 14–40x**. A baseline copy-and-patch JIT
   closes ~4–6x of that on arithmetic loops — **meaningful but partial**. The
   residual (still ~3–7x slower than V8/JSC) is the regalloc + type-
   specialization + inlining that only an optimizing tier buys, which the design
   study explicitly defers to v2.

### C.4 The `let` vs `var` aside (incidental, possibly more valuable than the JIT short-term)

While measuring I found zjs's `var` int-loop (177ms) is **2.1x slower than its
`let` int-loop (85ms)** — the `for (var i …)` path is markedly slower than
`for (let i …)`. This is a pure-interpreter optimization opportunity with **zero
W^X/binary-size/iOS cost**, and it's a 2x win on a common loop shape. Worth a
look *before* the JIT (consistent with the perf-speculation / jitless-first
discipline).

---

## (D) GO / NO-GO recommendation + next steps

### Verdict: **GO on the substrate spike's premise — conditional, scoped, and re-justified.**

**Why GO (the mechanism + the win both clear the bar):**
- The W^X copy-and-patch mechanism is **proven on the target platform** (§B PASS)
  with no new runtime dependency and the conformance-by-construction property
  intact.
- The dispatch-elimination headroom is **real and large** — ~90% of hot-loop
  time is attackable overhead (§C.1), giving a realistic **4–6x** on arithmetic
  loops. That decisively clears the design study's "1.5–2x ⇒ not worth it"
  threshold. The brief's worry that the jump-tabled dispatch leaves no room is
  refuted for the hot-loop case.

**Why conditional / re-scoped (intellectual honesty):**
- The JIT must stay exactly what the design study says: **second-class, opt-in
  (`ZJS_JIT` off by default), zapp-desktop-only, iOS stays pure interpreter.**
  Nothing here changes that — the W^X surface and binary growth are only justified
  for the desktop consumer.
- **Right-size the expectation to ~4–6x desktop arithmetic throughput, not
  "JSC-class."** A no-regalloc baseline leaves a 3–7x residual gap to V8/JSC.
  Selling it internally as "catch up to Bun" would over-promise; selling it as
  "a 4–6x opt-in desktop accelerator that keeps deopt+GC free" is honest.
- **The threshold gate from the design study still governs *implementation*.**
  This spike clears the *substrate* question; it does not clear the conformance
  leg (86.6% vs ~90% target) or re-validate jitless-perf-vs-current-qjs for the
  full suite. Implementation should still wait on that gate.
- **Cheaper wins exist first.** The `var`-loop 2x regression (§C.4) and `fib`
  call-overhead (zjs slower than qjs) are pure-interpreter improvements with no
  JIT cost. Per jitless-first discipline, harvest those before paying the JIT's
  complexity/W^X/binary tax.

### Concrete next steps (if/when the gate opens — in order)

1. **Interpreter wins first (no JIT cost):** fix the `for (var i …)` slow path
   (§C.4, ~2x on a common loop) and profile `fib`'s call-frame setup (zjs is
   1.2x slower than qjs on calls). These may move the jitless-perf gate leg on
   their own and are prerequisites for the JIT's call story anyway.
2. **Spike-2 — real stencil extraction:** build `tools/jit/extract_stencils.py`
   (CPython model) for the §A.2 easy opcode set (`LoadInt`/`Mov`/`Add`/`Sub`/
   `Mul`/`CmpLt*`/`Jmp`/`JmpIfFalse`), one arm64 `.o`. Validate that an extracted
   `Add` stencil stitched by the §B harness reproduces the interpreter result on
   a real bytecode fragment.
3. **End-to-end one loop:** JIT exactly `int_loop`'s body from real zjs bytecode
   (frame-shared, NaN-boxed) and **measure against the §C numbers** to confirm
   the 4–6x lands in practice (not just in the C model). This is the true
   GO/NO-GO for *implementation*.
4. **IC inlining + deopt:** wire `LoadProp`/`StoreProp` to emit the existing
   shape-keyed IC guard inline with a `call` to the IC-miss helper; add the
   `jit_pc → bytecode_index` deopt table and the guard-fail→interpreter bail.
5. **Platform gate + W^X productionization:** `ZJS_JIT` Makefile plumbing (off
   by default, never on iOS), the `allow-jit` entitlement path for hardened-
   runtime apps, and the JIT platform-support matrix in
   `platform-port-status.md` per the platform-port discipline.

### Artifacts produced by this spike
- `tools/jit/jit_poc.c` — W^X copy-and-patch mechanism PoC (PASS).
- `tools/jit/native_ref.c` — native -O3 loop ceilings (folded vs real).
- `tools/jit/jit_model.c` (+ `/tmp/jit_model_opt.c` variant) — realistic no-regalloc
  baseline-JIT cost model.
- This document. No engine source modified; `make cli` remains clean.
