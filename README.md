# zjs

An embeddable JavaScript engine. Hobby project; long-running and exploratory.

## Goals

- Generic, embeddable engine with a clean C ABI
- Two execution modes: JIT (where the platform permits) and interpreter-only (for iOS / sandboxed environments)
- iOS first-class
- ECMA-262 spec compliant; friendly to recent TC39 proposals
- Max performance and efficiency as a long-term north star

## Implementation language

Written in [Zen-c](https://github.com/zenc-lang/zenc). Zen-c transpiles to GNU C11, so the engine compiles via standard C toolchains and exposes a plain C ABI by default — any host that can call C can embed zjs.

Pinned compiler version: `zc v0.4.4-217-g10cf66d` (or compatible).

## Status

Phase 0: scaffolding. `zjs_eval` is a stub that ignores its input and returns `42`. The point of Phase 0 is to lock down the embed API surface, the build, and the C ABI smoke test before any real engine work begins.

## Build

```bash
make            # builds CLI, shared library, and C smoke test
make test       # builds everything and runs the smoke checks
make clean      # removes build/
```

After `make`:

- `build/zjs` — CLI binary
- `build/libzjs.dylib` (macOS) / `build/libzjs.so` (Linux) — shared library exposing the public ABI
- `build/smoke` — pure-C consumer of the library; validates the C ABI

Run the CLI:

```bash
./build/zjs --version
./build/zjs eval "1+1"   # prints 42 (Phase 0 stub)
```

## Embed surface

See `include/zjs.h`. QuickJS-style: opaque `ZjsContext*` handle, opaque `ZjsValue` payload, no global state, all functions `extern "C"`-callable.

## Project layout

```
zjs/
├── include/zjs.h        # Public C ABI — the contract for embedders
├── src/                 # Engine implementation in Zen-c
│   ├── lib.zc           # Library entry point
│   ├── context.zc       # ZjsContext (Phase 0 stub)
│   ├── value.zc         # ZjsValue (Phase 0 stub)
│   └── eval.zc          # zjs_eval (Phase 0 stub)
├── tools/zjs.zc         # CLI binary — thin embedder
├── tests/embed_smoke.c  # Pure-C smoke test for the embed ABI
└── Makefile             # Build orchestration
```
