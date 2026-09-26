# The engine against its goals

What the rewrite is for, in order, and where it stands. Measured
2026-09-26 at engine commit `798b7eb`, z-lang `bdc237d2`, macOS arm64.

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

`z/bench/speed` (`results/2026-09-26.json`), milliseconds per kernel with
each engine's startup subtracted, median of five interleaved runs, load
average 4.7:

| Kernel | zjsz | Zen-c reference | QuickJS | JSC, no JIT | V8, jitless |
|---|---|---|---|---|---|
| allocation | 40 | 47 | 44 | 22 | 22 |
| arrays | 173 | 163 | 151 | 177 | 83 |
| calls | 17 | 16 | 11 | 10 | 11 |
| closures | 35 | 49 | 33 | 22 | 19 |
| json | 50 | 34 | 43 | 8 | 12 |
| maps | 52 | 7,698 | 54 | 56 | 48 |
| polymorphic | 20 | 28 | 17 | 21 | 17 |
| properties | 46 | 63 | 41 | 24 | 33 |
| regexp | 27 | 40 | 19 | 16 | 17 |
| strings | 23 | 40 | 18 | 9 | 8 |
| startup | 2.5 | 4.5 | 2.8 | 5.1 | 27.2 |
| geometric mean, relative to zjsz | 1.00 | 1.92 | 0.86 | 0.58 | 0.55 |

Over these kernels QuickJS is 1.16 times faster than the engine,
JavaScriptCore's interpreter 1.7 times, and V8's 1.8 times; on
2026-09-25 (`results/2026-09-25.json`, when the kernels still ran at the
top level) they were 2.2, 3.3, and 4.5 times. The engine is ahead of
QuickJS on allocation and Map and Set, level on closures, and starts
fastest. The largest gaps left: JSON (6x JavaScriptCore), strings (2.6x),
calls (1.7x), and regular expressions (1.6x).

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
