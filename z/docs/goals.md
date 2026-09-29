# The engine against its goals

What the rewrite is for, in order, and where it stands. Size measured
2026-09-26 at engine commit `798b7eb` (the engine's own code has since
grown from 610 to about 625 KB, `325838b`); speed 2026-09-28 at
`322e164`, memory at `325838b`; z-lang `bdc237d2`, macOS arm64.

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
| The engine (one translation unit from Z) | 683 KB | 14 KB |
| Regular-expression backend (QuickJS 2026-06-04's `libregexp`, `libunicode`, and `cutils`; the adapter) | 97 KB (74 KB once dead-stripped) | under 1 KB |
| ABI shim | under 1 KB | under 1 KB |
| **A minimal embedder, linked and dead-stripped (macOS)** | **770 KB** | **16 KB** |
| The same, iOS device (arm64), 2026-09-26 (688 KB on macOS then) | 705 KB | 16 KB |

KB is 1000 bytes. Measured 2026-09-29 at `525afba`; on 2026-09-26
(`d259ae4`) the minimal embedder was 688 KB, its code 640 KB where it is
712 KB now. The 72 KB went to the dispatch loop's split into hot and
cold handlers and the frameless runner for leaf callbacks (12 KB), direct
eval seeing and writing a function's locals (8 KB), the compiler's
inlining, string joins, and fused instructions (6 KB), the young
generation's collector (3 KB), and JSON's single-buffer rewrite (2 KB);
the rest is spread thin. Two ways down, both measured: an embedder that
leaves out RegExp, Date, Map and Set, Promise, JSON, Reflect, and
generators links 623 KB (-147 KB, -19%) with nothing else changed, since
dead-stripping drops what is never installed -- what it needs is
installers an embedder calls, which the frozen ABI does not have for
these; and optimizing for size the large functions no profile of the
speed kernels or of compiling a large script touches gives 705 KB (-66
KB) at no measured cost, which needs a mark Z does not have
(docs/z-findings.md).

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

`z/bench/speed` (`results/2026-09-29-arrays.json`, engine `b6cbba7`),
milliseconds per kernel with each engine's startup subtracted, median of
five interleaved runs, load average 4.0. Hermes is 0.13.0, run from
source and on bytecode `hermesc -O` made beforehand:

| Kernel | zjsz | Zen-c reference | QuickJS | Hermes | Hermes, precompiled | JSC, no JIT | V8, jitless |
|---|---|---|---|---|---|---|---|
| allocation | 20 | 46 | 43 | 34 | 35 | 22 | 19 |
| arrays | 93 | 159 | 146 | 310 | 307 | 173 | 82 |
| calls | 11 | 14 | 10 | 8 | 7 | 9 | 7 |
| closures | 19 | 47 | 33 | 13 | 13 | 20 | 16 |
| helpers | 23 | 85 | 52 | 23 | 23 | 56 | 50 |
| json | 18 | 33 | 42 | 32 | 32 | 7 | 11 |
| maps | 41 | 7,448 | 53 | 53 | 53 | 58 | 47 |
| polymorphic | 16 | 27 | 17 | 21 | 21 | 21 | 15 |
| properties | 36 | 62 | 41 | 32 | 32 | 24 | 31 |
| regexp | 21 | 39 | 19 | 29 | 28 | 15 | 15 |
| strings | 10 | 39 | 17 | 14 | 15 | 9 | 7 |
| startup | 2.7 | 4.6 | 3.1 | 4.6 | 4.0 | 5.3 | 28.2 |
| geometric mean, engine / zjsz | 1.00 | 3.18 | 1.47 | 1.29 | 1.27 | 1.03 | 0.88 |

Over these eleven kernels the engine is 1.47 times faster than QuickJS
and 1.29 times faster than Hermes (1.27 precompiled), 1.03 times faster
than JavaScriptCore's interpreter, and V8's is 1.13 times faster, its
figures moving more than the others' from run to run. On 2026-09-28
(`results/2026-09-28-captured.json`, engine `322e164`): 1.39 QuickJS,
1.22 Hermes (1.21 precompiled), JavaScriptCore level, V8 1.14 faster. Over the ten before
`helpers` (`results/2026-09-28.json`, engine `4143c54`): 1.33 QuickJS,
1.27 Hermes, JavaScriptCore 1.09 faster, V8 1.10. On 2026-09-27
(`results/2026-09-27.json`, engine `325838b`) the engine was 1.06 times
faster than QuickJS and level with Hermes, and JavaScriptCore was 1.37
times faster, V8 1.49; on 2026-09-26 (`results/2026-09-26-hermes.json`)
QuickJS was 1.19 times faster, Hermes 1.25 (1.28 precompiled),
JavaScriptCore 1.7, V8 1.9. The engine is the fastest of these on Map
and Set and on helpers, within about a millisecond of V8 on allocation and
polymorphic access, and starts fastest. The Hermes VM alone is 2.75 MB of code and
3.34 MB with its compiler (arm64), against the engine's minimal
embedder of about 0.70 MB. The largest gaps left: JSON (2.6x
JavaScriptCore), calls (1.7x V8, whose figure moves most), closures
(1.5x Hermes), properties (1.5x JavaScriptCore), regular expressions
(1.4x V8), strings (1.4x V8), arrays (1.1x V8). The plan
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
