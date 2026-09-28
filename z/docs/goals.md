# The engine against its goals

What the rewrite is for, in order, and where it stands. Size measured
2026-09-26 at engine commit `798b7eb` (the engine's own code has since
grown from 610 to about 625 KB, `325838b`); speed 2026-09-28 at
`4143c54`, memory at `325838b`; z-lang `bdc237d2`, macOS arm64.

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

`z/bench/speed` (`results/2026-09-28.json`, engine `4143c54`),
milliseconds per kernel with each engine's startup subtracted, median of
five interleaved runs, load average 3.8. Hermes is 0.13.0, run from
source and on bytecode `hermesc -O` made beforehand:

| Kernel | zjsz | Zen-c reference | QuickJS | Hermes | Hermes, precompiled | JSC, no JIT | V8, jitless |
|---|---|---|---|---|---|---|---|
| allocation | 21 | 48 | 45 | 37 | 37 | 23 | 24 |
| arrays | 106 | 161 | 151 | 314 | 312 | 176 | 83 |
| calls | 11 | 15 | 11 | 9 | 8 | 9 | 10 |
| closures | 22 | 49 | 33 | 13 | 13 | 22 | 18 |
| json | 19 | 34 | 43 | 33 | 33 | 8 | 13 |
| maps | 42 | 7,918 | 55 | 54 | 52 | 58 | 53 |
| polymorphic | 17 | 29 | 18 | 22 | 22 | 22 | 18 |
| properties | 36 | 64 | 41 | 33 | 33 | 25 | 32 |
| regexp | 23 | 44 | 21 | 33 | 32 | 18 | 21 |
| strings | 16 | 44 | 19 | 18 | 17 | 11 | 13 |
| startup | 2.4 | 4.2 | 2.9 | 4.3 | 3.6 | 5.2 | 27.1 |
| geometric mean, engine / zjsz | 1.00 | 2.98 | 1.33 | 1.27 | 1.24 | 0.92 | 0.91 |

Over these kernels the engine is 1.33 times faster than QuickJS and 1.27
times faster than Hermes (1.24 precompiled); JavaScriptCore's
interpreter is 1.09 times faster and V8's 1.10. On 2026-09-27
(`results/2026-09-27.json`, engine `325838b`) the engine was 1.06 times
faster than QuickJS and level with Hermes, and JavaScriptCore was 1.37
times faster, V8 1.49; on 2026-09-26 (`results/2026-09-26-hermes.json`)
QuickJS was 1.19 times faster, Hermes 1.25 (1.28 precompiled),
JavaScriptCore 1.7, V8 1.9. The engine is the fastest of these on
allocation, polymorphic access, and Map and Set, ahead of Hermes on all
but calls, closures, and properties, and starts fastest. The Hermes VM
alone is 2.75 MB of code and 3.34 MB with its compiler (arm64), against
the engine's minimal embedder of about 0.70 MB. The largest gaps left:
JSON (2.4x JavaScriptCore), closures (1.6x Hermes), strings and
properties (1.5x JavaScriptCore), calls (1.4x Hermes precompiled),
arrays and regular expressions (1.3x V8 and JavaScriptCore). The plan
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
