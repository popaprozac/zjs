# Jitless speed

The Z engine against the jit-less engines an embedder would otherwise
choose, on ten small kernels. The engine's goal is to be the fastest
engine that runs without a JIT, which is what every iOS app gets; these
kernels are how that is tracked.

| | |
|---|---|
| `kernels/` | One program per kind of work. Each ends by assigning `result`; the runner prints it, and an engine whose checksum differs from the Z engine's gets no time. |
| `run.py` | Runs every engine present, median of `RUNS` (default 5) interleaved runs less that engine's startup, and prints a table; with a path, also writes JSON. |
| `results/` | Recorded runs, with the date, the load average, and each engine's startup. |

Engines, each measured only when present:

| Name | Command | What it is |
|---|---|---|
| `zjsz` | `z/build/zjsz run` | the Z engine (`ZJSZ=` points at another build) |
| `zjs-ref` | `z/build/zjs-ref run` | the Zen-c reference engine |
| `jsc-nojit` | `jsc --useJIT=false` | JavaScriptCore's interpreter, what iOS runs when JIT is unavailable |
| `v8-jitless` | `node --jitless` | V8's Ignition interpreter |
| `quickjs` | `qjs` | QuickJS, when a `qjs` is on PATH |
| `hermes` | `hermes -Xes6-class` | Hermes run from source, when `hermes` is on PATH |
| `hermes-hbc` | `hvm -Xes6-class` | Hermes on bytecode `hermesc -O` made before timing, the way a React Native app ships it |

The kernels are written for this suite, each with its work inside a
function, as most code runs (`results/2026-09-25.json` was recorded with an
earlier version that ran at the top level, where every variable is a
global; `results/2026-09-26.json` is the first with QuickJS beside the
others, and `results/2026-09-26-hermes.json` adds Hermes). They are small
on purpose: each
isolates one cost (calls, property access, closures, arrays, strings,
allocation, JSON, regular expressions, Map and Set), so a regression or a
win points at a subsystem. They are not a substitute for real programs.

The `vs zjsz` row is the geometric mean over the kernels of each engine's
time divided by the Z engine's: below 1 means that engine is faster.
Timing wants a quiet machine; the load average is recorded with every run,
and figures taken above a load of a few are for ratios, not absolutes.

```
./z/build.sh
./z/bench/speed/run.py z/bench/speed/results/<date>.json
```
