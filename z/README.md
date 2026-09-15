# ZJS in Z

The Z rewrite of the ZJS engine. Design:
[`docs/superpowers/specs/2026-09-14-zjs-z-rewrite-design.md`](../docs/superpowers/specs/2026-09-14-zjs-z-rewrite-design.md).

`src/` (Zen-c) remains the shipping engine and the behavioral oracle. This tree
is built beside it, never on top of it.

## Status — Phase 1 complete

The loop works end to end. The **unmodified** `tests/test262_runner.c` links
against a Z-implemented `libzjs.a` and runs. It reports 0 passed, which is the
Phase 1 goal: no JavaScript is evaluated yet. Every phase after this one is
about making that number climb.

```
$ ./z/oracle.sh
reference passed: 5   z passed: 0   gap: 5
```

## Layout

| Path | What |
|---|---|
| `engine/` | the Z engine — `z.json` builds `libzjsz.a` plus a generated header |
| `shim/zjs_shim.c` | frozen-ABI shim: exact `zjs.h` signatures over the Z exports |
| `spike/` | Phase 0 measurements — see [`spike/RESULTS.md`](spike/RESULTS.md) |
| `tests/` | `loop_smoke.c` and a synthetic corpus for the oracle |
| `build.sh` | build the engine, shim, `libzjs.a`, and the runner |
| `oracle.sh` | run a corpus through both engines and diff |

## Commands

```sh
./z/build.sh                      # engine + shim + libzjs.a + runner
./z/build/loop_smoke              # ABI round-trip assertions
./z/oracle.sh                     # differential oracle, synthetic corpus
./z/oracle.sh vendor/test262/test/language/expressions   # real corpus
./z/spike/run.sh                  # Phase 0 measurements
```

The real corpus is not vendored:
`git clone --depth 1 https://github.com/tc39/test262 vendor/test262`.

## Two decisions already made, and why

**Contexts cross the ABI as handles, not pointers.** Contexts live in a
Z-owned `Array` behind a `Mutex`, published once through the manifest runtime
root. What the host receives is an index, cast into the opaque `ZjsContext*`
the frozen header promises. No raw pointer touches Z state. This is the same
choice the spike settled for heap cells, applied one level up.

**The interpreter will be written in ordinary Z, not `raw c`.** The spike
measured an `if`-chain interpreter in plain Z at **0.84× the C computed-goto
baseline** — faster than C, and faster than the same loop written as
whole-function `raw c` (0.99×). Dropping to C for the hot loop is the worst
trade available.

## Known Phase 1 compromises

Both are recorded in [`docs/z-findings.md`](../docs/z-findings.md) and neither
may survive into the worker model.

- **`Engine` carries a vestigial `publicationEpoch` field** it never reads,
  because `Once<T>` requires a main-bound class — and marking the whole class
  `on thread.main` makes every field main-affine, which `export c function`
  then rejects. A main-bound *field* threads the needle.
- **The shim reports every thread as main and releases inline.** Correct for a
  single-threaded harness, wrong for Zapp's workers.
