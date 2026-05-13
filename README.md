# zjs

An embeddable JavaScript engine. Hobby project; long-running and exploratory — same design space as Meta's Hermes (jitless-first, iOS-friendly, spec-bound).

## Goals

- Embeddable engine with a clean C ABI
- **Jitless-first interpreter perf** — explore how far we can push without runtime codegen; JIT is additive, only on supported platforms
- iOS as a first-class target (proven path through Zen-c's `xcrun`-driven cross-compile)
- ECMA-262 spec compliant; friendly to recent TC39 proposals
- Eventual batteries-included runtime layer (`fetch`, `WebSocket`, Timers) above the engine core — modeled on [txiki.js](https://github.com/saghul/txiki.js)

## Implementation language

Written in [Zen-c](https://github.com/zenc-lang/zenc). Zen-c transpiles to GNU C11, so the engine compiles via standard C toolchains and exposes a plain C ABI by default — any host that can call C can embed zjs.

Pinned compiler version: `zc v0.4.4-217-g10cf66d` (or compatible).

## Status

| Phase | What |
|---|---|
| 0     | Scaffolding — build, embed ABI, smoke test |
| 1     | Jitless-first design study (`docs/jitless-design-study.md`) |
| 2.1   | NaN-boxed values (JSC layout) |
| 2.2   | Lexer (full ECMA-262 §12.7) |
| 2.3   | Parser — expressions |
| 2.4   | Parser — statements |
| 2.5   | Parser — functions, arrow functions, for-in/of |
| **3.0a** | **Bytecode compiler + register-machine interpreter — arithmetic, variables, control flow** |
| **3.0b** | **Functions, calls, recursion, locals** |
| **3.0c** | **test262 conformance scaffolding** |

530 in-tree test assertions pass (lexer + parser + interpreter + embed smoke). Per-phase plans are in `docs/phases/`.

**Programs run end-to-end:**

```bash
$ ./build/zjs eval "function fib(n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); } fib(10)"
55

$ ./build/zjs eval "function sum(n) { let s = 0; for (let i = 1; i <= n; i = i + 1) s = s + i; return s; } sum(100)"
5050

$ ./build/zjs eval "let inc = x => x + 1; inc(41)"
42
```

## Build

```bash
make            # builds the library, CLI, and all in-tree tests
make test       # runs every test target
make clean      # removes build/
```

After `make`:

- `build/zjs` — CLI binary with `eval`, `lex`, `parse`, `--version` subcommands
- `build/libzjs.dylib` (macOS) / `build/libzjs.so` (Linux) — shared library exposing the public C ABI
- `build/smoke` — pure-C consumer of the library; validates the embed surface
- `build/lexer_test`, `build/parser_test`, `build/interp_test` — Zen-c test runners

Try it:

```bash
./build/zjs --version
./build/zjs eval  "1 + 2 * 3"
./build/zjs lex   "let x = 1 + 2;"
./build/zjs parse "function add(a, b) { return a + b; }"
```

## test262 conformance

The TC39 test262 suite isn't bundled (large repo). Clone it to `vendor/` and run:

```bash
mkdir -p vendor
git clone --depth 1 https://github.com/tc39/test262 vendor/test262
make test262
```

Caveat for Phase 3.0c: the pass rate is a **biased "didn't crash" measure** until Phase 3.1 lands strings, throw, and object property access — at which point test262's `assert.*` machinery starts producing real signal. See `docs/phases/phase-3-0c-test262.md`.

## Embed surface

See `include/zjs.h`. QuickJS-style: opaque `ZjsContext*` handle, opaque NaN-boxed `ZjsValue`, no global state, all functions `extern "C"`-callable.

```c
#include "zjs.h"

ZjsContext* ctx = zjs_new_context();
ZjsValue    v   = zjs_eval(ctx, "let x = 10; let y = 20; x + y");
int         n   = zjs_is_int32(v) ? zjs_as_int32(v) : 0;   // 30
zjs_free_context(ctx);
```

## Project layout

```
zjs/
├── include/zjs.h           # Public C ABI — the contract for embedders
├── src/
│   ├── lib.zc              # Library entry; re-exports public API
│   ├── value.zc            # NaN-boxed ZjsValue + arithmetic helpers
│   ├── context.zc          # Globals table, function ownership
│   ├── token.zc / lexer.zc # Lexer
│   ├── ast.zc / parser.zc  # Parser
│   ├── bytecode.zc         # Opcode enum + Inst + Function
│   ├── compiler.zc         # AST → bytecode
│   ├── interpreter.zc      # Bytecode → ZjsValue
│   └── eval.zc             # Lex → parse → compile → interpret pipeline
├── tools/zjs.zc            # CLI
├── tests/
│   ├── embed_smoke.c       # Pure-C consumer test (NaN-box + eval)
│   ├── lexer_test.zc       # Lexer test runner
│   ├── parser_test.zc      # Parser test runner
│   ├── interpreter_test.zc # End-to-end eval tests
│   └── test262_runner.c    # test262 conformance harness
├── docs/
│   ├── jitless-design-study.md         # Phase 1 — Hermes/QuickJS/LLInt synthesis
│   └── phases/phase-2-*.md, phase-3-*.md
└── Makefile
```

## License

TBD.
