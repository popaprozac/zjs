# The engine against its goals

What the rewrite is for, in order, and where it stands. Size measured
2026-09-26 at engine commit `798b7eb` (the engine's own code has since
grown from 610 to about 625 KB, `325838b`); speed 2026-09-28 at
`f4dcab3`, memory at `325838b`; z-lang `bdc237d2`, macOS arm64.

1. **Small, with features opt-in.** The core is ECMAScript and nothing
   else; web APIs, WinterTC, and the like are modules an embedder links
   only when wanted. The Zen-c prior art showed under 1.5 MB is possible.
2. **The fastest engine without a JIT**, for every device, iOS included.
3. **Embeddable and portable** the way QuickJS is.
4. **A JIT, opt-in**, last.

## 1. Size

Code and data an embedder links, from the optimized build (the figures are
segment sizes; nothing is stripped):

| | `__TEXT` | `__DATA` |
|---|---|---|
| The engine (one translation unit from Z) | 610 KB | 14 KB |
| Regular-expression backend (QuickJS 2026-06-04's `libregexp`, `libunicode`, and `cutils`; the adapter) | 96 KB (73 KB once dead-stripped) | under 1 KB |
| ABI shim | under 1 KB | under 1 KB |
| **A minimal embedder, linked and dead-stripped (macOS)** | **688 KB** | **16 KB** |
| The same, iOS device (arm64) | 705 KB | 16 KB |

Where the engine's code goes (share of 569 KB of functions, measured
2026-09-25 at 584 KB of `__TEXT`):

| Subsystem | Share |
|---|---|
| Interpreter and object model (`runtime.zs`) | 20% |
| Bytecode compiler (`compiler.zs`) | 16% |
| Parser (`parser.zs`) | 11% |
| String, Number, Boolean builtins | 8% |
| Array builtins | 6% |
| Builtin installation | 6% |
| RegExp builtins | 5% |
| Map, Set, WeakMap, WeakSet | 4% |
| Date | 4% |
| Heap and collector | 3% |
| everything else (JSON, lexer, Promise, Object, Function, Reflect, Math, errors, URI, iteration, text, Z runtime) | 17% |

The front end (lexer, parser, compiler) is 29% of the engine. The largest
single optional piece is `libunicode` (60 KB, 38 KB once dead-stripped),
which only Unicode-aware regular expressions and case mapping need.

Not yet in the core, and each will add to it: Proxy, typed arrays and
ArrayBuffer, BigInt, WeakRef, ES modules. Nothing is opt-in yet: the
frozen ABI has the installers (`zjs_new_minimal_context`,
`zjs_install_web_*`), but the Z engine implements only the core, so today
the minimal context and the default one are the same engine.

## 2. Speed

`z/bench/speed` (`results/2026-09-28-inline.json`, engine `f4dcab3`),
milliseconds per kernel with each engine's startup subtracted, median of
five interleaved runs, load average 3.3. Hermes is 0.13.0, run from
source and on bytecode `hermesc -O` made beforehand. `helpers`, calls to
small functions from a loop, joined the suite that day:

| Kernel | zjsz | Zen-c reference | QuickJS | Hermes | Hermes, precompiled | JSC, no JIT | V8, jitless |
|---|---|---|---|---|---|---|---|
| allocation | 20 | 47 | 44 | 35 | 35 | 22 | 22 |
| arrays | 108 | 162 | 149 | 312 | 310 | 175 | 82 |
| calls | 12 | 15 | 10 | 9 | 8 | 10 | 9 |
| closures | 22 | 49 | 34 | 13 | 13 | 21 | 18 |
| helpers | 24 | 88 | 53 | 24 | 24 | 58 | 54 |
| json | 19 | 34 | 43 | 33 | 33 | 8 | 14 |
| maps | 41 | 7,460 | 54 | 53 | 52 | 56 | 48 |
| polymorphic | 16 | 28 | 18 | 22 | 21 | 21 | 18 |
| properties | 38 | 65 | 42 | 33 | 33 | 26 | 34 |
| regexp | 22 | 41 | 20 | 30 | 30 | 16 | 18 |
| strings | 16 | 42 | 18 | 15 | 15 | 10 | 11 |
| startup | 2.3 | 4.2 | 2.8 | 4.3 | 3.8 | 5.1 | 26.6 |
| geometric mean, engine / zjsz | 1.00 | 2.98 | 1.37 | 1.20 | 1.19 | 0.98 | 0.94 |

Over these eleven kernels the engine is 1.37 times faster than QuickJS
and 1.20 times faster than Hermes (1.19 precompiled); JavaScriptCore's
interpreter is 1.02 times faster and V8's 1.06. Over the ten before
`helpers` (`results/2026-09-28.json`, engine `4143c54`): 1.33 QuickJS,
1.27 Hermes, JavaScriptCore 1.09 faster, V8 1.10. On 2026-09-27
(`results/2026-09-27.json`, engine `325838b`) the engine was 1.06 times
faster than QuickJS and level with Hermes, and JavaScriptCore was 1.37
times faster, V8 1.49; on 2026-09-26 (`results/2026-09-26-hermes.json`)
QuickJS was 1.19 times faster, Hermes 1.25 (1.28 precompiled),
JavaScriptCore 1.7, V8 1.9. The engine is the fastest of these on
allocation, polymorphic access, and Map and Set, level with Hermes on
helpers, and starts fastest. The Hermes VM alone is 2.75 MB of code and
3.34 MB with its compiler (arm64), against the engine's minimal
embedder of about 0.70 MB. The largest gaps left: JSON (2.4x
JavaScriptCore), closures (1.7x Hermes), strings (1.6x JavaScriptCore),
calls (1.5x Hermes precompiled), properties (1.5x JavaScriptCore),
regular expressions (1.4x JavaScriptCore), arrays (1.3x V8). The plan
to close them is [levers.md](levers.md).

Memory, on a large live heap (`z/bench/memory`): about 100 MB at peak,
against QuickJS 131, JavaScriptCore 188, V8 240, and Hermes 67.

Tried and not kept: direct-threaded dispatch (computed goto), measured by
rewriting the generated C by hand, was slower on Apple silicon
(polymorphic +39%, properties +24%, calls +6%), so dispatch stays the
`match` the compiler lowers to a `switch`.

## 3. Embeddability and portability

- **iOS.** The engine's C, the regex backend, and the shim compile
  unchanged for iOS devices and the simulator; a minimal embedder runs in
  an iOS 26.1 simulator (`zjs embedded: ok`). No JIT, no writable
  executable memory, no main-thread requirement.
- **Linux.** Compiles for x86_64 (musl) and aarch64 (glibc) with zig's
  bundled toolchains, given GNU C11 (`-std=gnu11`) or
  `-D_POSIX_C_SOURCE=200809L` so the POSIX clock is declared.
- **Windows.** One gap: `builtins/clock.h` uses POSIX local time
  (`localtime_r`, `tm_gmtoff`, `tm_zone`).
- **wasm32.** The engine compiles; the shim assumes 64-bit pointers, since
  a context handle packs a slot and a generation into 64 bits.
- The emitted C needs only the C standard library and pthread mutexes.
  The Z compiler itself runs only on macOS.
- **Locale.** Number text goes through the C library's `snprintf` and
  `strtod`, which follow the host's `LC_NUMERIC`: an embedder that sets a
  comma-decimal locale gets wrong numeric literals, `String(0.1)`,
  `JSON.parse`, and `parseFloat`. The fix waits on locale-independent
  conversion in Z's standard library (docs/z-findings.md).
- **Embedding.** The frozen `zjs.h` ABI; handle-based contexts, created,
  used, and freed from any host thread, independent contexts concurrent;
  a lifecycle test (1,000 create/free cycles with no growth, free after
  admission, shutdown on a worker). ES modules are not supported yet.

## 4. JIT

None, by design, until the first three are met.

## Reproducing

```
./z/build.sh                                    # optimized engine, every gate
./z/bench/speed/run.py                          # the speed table
size -m z/engine/.z-cache/build/zjsz.o          # the engine's sections
```
