# The engine against its goals

What the rewrite is for, in order, and where it stands. Measured
2026-09-25 at engine commit `34a0dc6` plus the optimized-library and
regexp-subject changes, z-lang `bdc237d2`, macOS arm64.

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
| The engine (one translation unit from Z) | 584 KB | 14 KB |
| Regular-expression backend (`libregexp`, `libunicode`, adapter) | 82 KB | under 1 KB |
| ABI shim | under 1 KB | under 1 KB |
| **A minimal embedder, linked and dead-stripped (macOS)** | **655 KB** | **16 KB** |
| The same, iOS device (arm64) | 672 KB | 16 KB |

Where the engine's code goes (share of 569 KB of functions):

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
single optional piece is `libunicode` (57 KB), which only Unicode-aware
regular expressions and case mapping need.

Not yet in the core, and each will add to it: Proxy, typed arrays and
ArrayBuffer, BigInt, WeakRef, ES modules. Nothing is opt-in yet: the
frozen ABI has the installers (`zjs_new_minimal_context`,
`zjs_install_web_*`), but the Z engine implements only the core, so today
the minimal context and the default one are the same engine.

## 2. Speed

`z/bench/speed` (`results/2026-09-25.json`), milliseconds per kernel with
each engine's startup subtracted, median of five interleaved runs, load
average 12:

| Kernel | zjsz | Zen-c reference | JSC, no JIT | V8, jitless |
|---|---|---|---|---|
| allocation | 54 | 54 | 35 | 22 |
| arrays | 371 | 182 | 217 | 83 |
| calls | 29 | 15 | 9 | 9 |
| closures | 44 | 50 | 27 | 18 |
| json | 84 | 35 | 8 | 12 |
| maps | 465 | 7,981 | 66 | 50 |
| polymorphic | 74 | 40 | 43 | 19 |
| properties | 114 | 80 | 66 | 33 |
| regexp | 56 | 42 | 17 | 19 |
| strings | 178 | 42 | 12 | 10 |
| startup | 2.6 | 5.1 | 5.9 | 29.1 |
| geometric mean, relative to zjsz | 1.00 | 0.82 | 0.30 | 0.22 |

The engine starts fastest and is slowest at running: JavaScriptCore's
interpreter is 3.3 times faster over these kernels and V8's 4.5 times.
The largest gaps: string building (15x JSC), JSON (10x), Map and Set with
string keys (7x), calls (3x), regular expressions (3x).

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
