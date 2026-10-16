# zjs Phase 4.2 — Perf pass against Hermes

> After Phase 4.1's iterator-protocol + Set composition cleanup, perf
> against qjs (our jitless peer) was solid but the gap to Hermes
> (Meta's jitless engine, the design-space ceiling) was still wide on
> richards / splay / fib_recursive. This phase profiled, fused, and
> hoisted to close that gap.

## Why

Bench measurement at the start of the phase (vs Hermes -O on the
same hardware, 2026-05-19):

| bench | zjs | hermes | ratio |
|---|---|---|---|
| richards      | 146.22 ms | 87.00 ms | 1.68× |
| splay         | 151.92 ms | 83.00 ms | 1.83× |
| fib_recursive | 111.81 ms | 57.00 ms | 1.96× |
| nbody         |  80.82 ms | 27.00 ms | 3.00× |
| mandelbrot    |  49.99 ms | 15.00 ms | 3.33× |

richards / splay / fib are OO + dispatch-bound — same machinery we
already invest in (polymorphic ICs, hidden classes). nbody /
mandelbrot are numeric, gated by specialized arithmetic + GC. The
attainable wins for *this* phase were on the OO benches; numeric +
GC is a separate, larger structural project.

## What landed

Profile-driven, in order:

### 1. String ropes / cords (`c1e8317`)

`String.prototype.concat` and the `+` operator were O(n²) for chained
concatenation. Switched to a lazy rope (`TAG_STRING_ROPE`) with
flattening on read.

- `string_concat`: **3.8× faster**; now beats qjs.
- `length` / `slice` extended to accept ropes via `property_get`.
- GC mark walks left / right / flat for ropes.

### 2. Super-instruction fusion pass (`a51fe0d`)

Profile pass on richards / splay using a new pair-counter
(`ZJS_PROFILE_OPS=1` now dumps a 256×256 pair table in addition to
the per-op count). Top opcode pairs picked off in order of dispatch
share:

1. **`borrow_local_ok` at `ReturnStmt`.** `return localVar` was
   emitting a defensive `Mov tmp, local` before `Return tmp`. With
   the borrow flag set at the ReturnStmt site, `Return` takes the
   local's reg directly. `Mov → Return` was 2.1% of richards
   dispatches; down 35% afterwards.

2. **`JmpIfNot{Eq, Ne, StrictEq, StrictNe}` super-instructions.**
   Mirrors the existing `JmpIfNot{Lt, Le, Gt, Ge}` family — fuses
   `Cmp + JmpIfFalse` for equality into a single two-inst dispatch
   (operands at `inst[J]`, i16 offset at `inst[J+1]`). `CmpEq →
   JmpIfFalse` alone was 3.4% of richards dispatches.

3. **`JmpIfNullish` + nullish-literal peephole.**
   `if (x == null) {}` and `if (x != null) {}` (loose equality)
   check exactly for nullishness per §7.2.13. The compiler peephole
   detects `Binary(CmpEq | CmpNe, x, NullExpr | UndefinedExpr)` and
   emits `JmpIfNotNullish` (existing) or new `JmpIfNullish` directly
   on the non-literal operand, eliminating the `LoadNull` /
   `LoadUndefined` setup dispatch. Combined `LoadNull → JmpIfNotEq/Ne`
   pairs were 4.9% of richards dispatches.

4. **`Function.this_reg` metadata hoist.**
   Compiler used to emit `Op::LoadThis r` at the top of every method
   body that referenced `this` — re-running once per call. Added a
   `this_reg: i32` field on `Function` (–1 when the body doesn't read
   `this`). The interpreter seeds `regs[f.this_reg] = ctx.host_this`
   on first frame entry (`ip == 0`) instead. `Op::LoadThis` removed
   from the prologue. Was 3.9% of richards dispatches.

Cumulative on richards: 146.22 ms → **124.57 ms (−14.8%)**.
Hermes ratio: 1.68× → **1.40×**. Total dispatches on richards:
59.2M → **48.3M (−18%)**.

### 3. Static-lib build target (`7b50308`)

`build/libzjs.a` for iOS App Store embedding (no `dlopen` allowed)
and as the small-binary path for other embedders. zc's `--release
-c` rejects some patterns the shared build accepts, so the Makefile
runs `zc transpile` to get the C, compiles + ar's directly.
`smoke_static` validates the archive end-to-end.

### 4. Bench-compare against Hermes (`a5b0f5a`)

Added `hermes -O` and `shermes -O -exec` columns to
`docs/perf/compare.html`. Hermes is the design-space peer we now
target. shermes (Static Hermes, JS → C → native) is an AOT-to-
native ceiling reference.

### 5. WebSocket keep-alive ping/pong (`573f788`)

Client-side `dispatch_source` ping every 25s on Apple (`ws_apple.m`).
Pong-error → CLOSE 1006. Not perf — included in the phase because
it landed in the same arc and reshaped the WS lifecycle on Apple.

## What we tried and reverted

**Borrow-mode call ABI** (squashed via `git reset`).
Attempted to alias the callee's `regs[0..argc)` onto the caller's
reg slice in `push_call_frame_inplace` to skip the arg memcpy. The
infrastructure was correct (and exposed a latent `tail_call_frame`
bug along the way — fixed and re-folded) but the empirical win on
call-heavy benches was inside ±1% of the baseline. The arg-copy
itself is sub-nanosecond; CPU pipelining absorbs it. Reverted
because complexity-without-measurable-gain isn't worth keeping.

Honest takeaway: the bulk of per-call cost lives in frame field
writes + `host_this` save/restore + `reg_stack` growth check + GC
poll at call boundaries — **not** in the arg copy. Future call-ABI
work should target one of those.

## What's still on the floor

Closest remaining single-pair fusions on richards (post-Phase 4.2):

| pair | dispatches | share |
|---|---|---|
| `LoadProp → LoadProp` | 5.04M | 10.4% |
| `LoadProp → LoadGlobal` | 2.84M | 5.9% |
| `Mov → LoadProp` | 2.60M | 5.4% |
| `LoadProp → MethodInvoke` | 2.00M | 4.1% |

`LoadProp → LoadProp` (chained `a.b.c`) is the largest single pair
left. Un-fusable in the current 4-byte uniform Inst encoding — would
need a wider/variable-width ISA, which is a separate structural
project not scoped here.

## Results

`docs/perf/compare.json` at HEAD (`a51fe0d`, 2026-05-20):

- vs qjs: ahead on 17 / tied on 1 / behind on 3 of 21 microbenches.
- vs hermes: ahead on 5 / behind on 14 of 19 measurable.
- Conformance held at 83.9% (6,711 / 7,997 non-skipped) — no
  spec regressions from the fusion work.

## Files touched

- `src/bytecode.zc` — new opcodes `JmpIfNot{Eq, Ne, StrictEq,
  StrictNe}`, `JmpIfNullish`; `Function.this_reg` field;
  `TAG_STRING_ROPE` cell tag.
- `src/value.zc` — `ZjsStringRope` struct + flatten path.
- `src/context.zc` — rope-aware `zjs_string_concat`, GC mark for
  ropes.
- `src/compiler.zc` — `borrow_local_ok` at `ReturnStmt`; nullish +
  Eq/Ne extensions in `try_emit_cmp_branch_if_false`; skip
  prologue `Op::LoadThis` emission; `f.this_reg` writeback.
- `src/interpreter.zc` — new opcode handlers; `f.this_reg` seed at
  frame entry; pair-counter (`zjs_pair_counts[256*256]`).
- `src/platform/ws_apple.m` — `dispatch_source` ping timer.
- `Makefile` — `lib-static` / `smoke-static` targets, platform-
  object compile rules.
- `scripts/bench/run.py` — `hermes` / `shermes` in
  `DEFAULT_OTHER_ENGINES`; palette + chart entries; corrected
  prelude comment about `performance.now()` availability.

## Status

Done; merged.
