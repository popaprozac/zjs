# ZJS engine migration: Zen-c → Nim — status matrix

**Goal:** full committed cutover of the zjs engine from Zen-c to pure Nim (not a trial).
Main consumer = Zapp (itself being rewritten in Nim). Performance parity is mandatory;
idiomatic-Nim wins (binary size, engine shape) are in scope.

**Method:** differential oracle — `build/zjs <cmd>` (Zen-c reference) vs the Nim port must
match byte-for-byte. `make nim-difflex` / `make nim-diffparse`; error-parity via
`nim/tests/measure_errparity.sh`.

**Branch discipline:** ALL migration work lives on `nim-phase2` → long-lived `nim` branch.
Nothing touches `main` until the whole port is complete + validated — `main` stays the
working Zen-c engine Zapp pulls today. (Verified: nim-phase2 changes only `nim/`, `docs/`,
additive `nim-*` Makefile targets — zero `src/` or `tools/` edits.)

_Last updated: 2026-07-06. Zen-c sizes are LOC (rough effort proxy); the "best-not-fast"
Nim parser is proportionally larger than its source, so LOC understates frontend progress._

## Matrix

| Stage | Component | Zen-c LOC | Status | Notes |
|---|---|---:|---|---|
| **Frontend** | Tokens | 102 | ✅ Done | `token.nim` |
| | Lexer | 1,018 | ✅ Done | byte-identical over 5,113 test262 files |
| | AST types | 310 | ✅ Done | object variants; `childNodes` iterator |
| | Parser (grammar) | 4,779 | ✅ Done | all ES grammar; byte-identical AST dumps |
| | Parser (early errors) | *(in parser.zc)* | 🟡 ~99% | broad 98.9% clean, **0 false-rejects**; scattered singleton tail (escaped-reserved-keyword, hashbang, decorators-proposal, obj-shorthand) |
| **Middle** | Bytecode format/ops | 894 | ✅ Done | `bytecode.nim` — 145-op enum, Inst, Function |
| | Compiler (AST→bytecode) | 9,049 | 🟢 ~95% | Phase 3 — byte-identical `disasm` across the language; hard-edge tail bails cleanly (see below) |
| | AOT (bytecode serialize) | 840 | ⬜ Not started | |
| **Backend** | Interpreter / VM | 9,170 | 🟡 ~35% | Phase 4 — `vm.nim` executes arithmetic/control-flow/functions/recursion/strings/coercion byte-exact vs `zjs eval`; object model (slice 4) = the heap/GC fork, CHECKPOINTED pending design |
| | Eval entry points | 214 | ⬜ Not started | |
| **Runtime core** | Value type + ops | 3,806 | 🟡 ~2% | `value.nim` = NaN-boxed immediates only (Phase 0-1) |
| | Object model, hidden classes, **GC**, Realm, **all built-ins** | **34,528** | ⬜ Not started | `context.zc` — 52% of the engine; see breakdown |
| | Misc lib glue | 300 | ⬜ Not started | |
| **Tooling** | CLI | 1,479 | 🟡 dumpers only | `nim_lex`/`nim_parse` diff harnesses; no `run`/`eval` |
| **Optional** | Copy-and-patch JIT | `jit/` | ⬜ Out of scope | opt-in, non-iOS; last, if ever |

Legend: ✅ done (byte-parity where applicable) · 🟡 partial/in-progress · ⬜ not started.

## `context.zc` breakdown (the 34.5k-line bulk of what's left)
- **Object & property model** — get/set, hidden classes (`cls`/`class_find_slot`), prototypes
- **GC** — non-moving chunked nursery + generational mark-sweep + write barriers. The
  `Rooted[T]` root-set design lands here — see `project_nim_gc_rootset` (memory). Port the
  proven collector (non-moving, per-ctx/thread-local allocator, ARC-host + manual-arena-heap);
  NOT copying/incremental/global-alloc/danger-flags.
- **Realm / Runtime** — Runtime/Realm split, intrinsics-as-singletons, microtask queue
- **Built-in intrinsics** — Array, Object, String, Number, Boolean, Symbol, Math, JSON,
  RegExp, Date, Function, Error types, Map/Set/WeakMap/WeakSet, Proxy/Reflect, Promise,
  TypedArrays/ArrayBuffer, BigInt, Temporal
- **Stdlib / runtime layer** — fetch / timers / codecs (WinterTC rings), batteries-included

## Progress
- **Frontend (lex + parse): essentially complete** — only the error-reporting tail remains;
  byte-identical on every *accepted* input across the whole test262 language corpus.
- **Everything else (compile → VM → runtime → GC → built-ins): not started** (Phases 3–6).
- Raw LOC migrated ≈ 6,200 / ~66,500 ≈ **9%** — undercounts, since the frontend is the
  hardest to get byte-exact (done) and much of `context.zc` is repetitive built-in surface
  that ports faster once the object model + GC + VM exist.

## Order for the rest
1. **Finish parser error-reporting tail** → merge Phase 2 → `nim`.
2. **Bytecode + Compiler (Phase 3)** — differential on `build/zjs compile` bytecode dumps.
3. **VM / interpreter (Phase 4)** — run bytecode; differential on execution results.
4. **Runtime core (Phase 5)** — value ops, object model, hidden classes, **GC + `Rooted[T]`**.
5. **Built-in intrinsics + stdlib (Phase 6)** — long parallelizable tail; test262 execution = oracle.
