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
| **The same on a core context (`zjs_new_core_context`), no installers** | **557 KB** | **16 KB** |
| **A core context running bytecode only (`zjs_eval_bytecode`), no front end, 2026-10-16** | **393 KB** | **16 KB** |
| The core with JSON and Map / Set installed | 606 KB | 16 KB |
| The same, iOS device (arm64), 2026-09-26 (688 KB on macOS then) | 705 KB | 16 KB |

KB is 1000 bytes. Measured 2026-09-29 at `525afba`; on 2026-09-26
(`d259ae4`) the minimal embedder was 688 KB, its code 640 KB where it is
712 KB now. The 72 KB went to the dispatch loop's split into hot and
cold handlers and the frameless runner for leaf callbacks (12 KB), direct
eval seeing and writing a function's locals (8 KB), the compiler's
inlining, string joins, and fused instructions (6 KB), the young
generation's collector (3 KB), and JSON's single-buffer rewrite (2 KB);
the rest is spread thin. The optional builtins are opt-in: a core
context (`zjs_new_core_context`) has the language and the builtins it
cannot do without, and `zjs_install_json`, `_regexp`, `_date`,
`_collections`, `_promise`, and `_reflect` add the rest; an embedder
links only the installers it calls, and without RegExp none of the
regular-expression matcher (a literal then throws a TypeError).
`zjs_new_context` is the core with every installer run. Not yet: size
optimization of the large functions no profile touches, 705 KB (-66 KB)
at no measured cost, which needs a mark Z does not have
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

Not yet in the engine, and each will add to it: Proxy, typed arrays and
ArrayBuffer, BigInt, WeakRef, ES modules. Opt-in: JSON, RegExp, Date,
Map / Set / WeakMap / WeakSet, Promise, and Reflect, each with its own
installer on a core context; the frozen ABI's other installers
(`zjs_new_minimal_context`, `zjs_install_web_*`) are not implemented by
the Z engine yet.

## 2. Speed

`bench/speed` (`results/2026-09-29-core.json`, engine `2c21974`),
milliseconds per kernel with each engine's startup subtracted, median of
five interleaved runs, load average 3.8. Hermes is 0.13.0, run from
source and on bytecode `hermesc -O` made beforehand:

| Kernel | zjsz | Zen-c reference | QuickJS | Hermes | Hermes, precompiled | JSC, no JIT | V8, jitless |
|---|---|---|---|---|---|---|---|
| allocation | 18 | 45 | 43 | 35 | 34 | 23 | 21 |
| arrays | 83 | 153 | 142 | 300 | 301 | 169 | 78 |
| calls | 11 | 13 | 10 | 8 | 8 | 8 | 7 |
| closures | 18 | 47 | 32 | 12 | 12 | 21 | 17 |
| helpers | 20 | 82 | 50 | 22 | 22 | 53 | 50 |
| json | 18 | 31 | 41 | 31 | 32 | 6 | 9 |
| maps | 37 | 7,017 | 51 | 52 | 51 | 54 | 43 |
| polymorphic | 9 | 27 | 17 | 20 | 20 | 20 | 13 |
| properties | 29 | 60 | 40 | 31 | 30 | 23 | 28 |
| regexp | 20 | 37 | 18 | 27 | 27 | 14 | 12 |
| strings | 8 | 37 | 16 | 14 | 14 | 7 | 5 |
| startup | 3.0 | 5.3 | 3.3 | 5.3 | 4.8 | 6.8 | 30.5 |
| geometric mean, engine / zjsz | 1.00 | 3.54 | 1.65 | 1.45 | 1.42 | 1.13 | 0.94 |

Over these eleven kernels the engine is 1.65 times faster than QuickJS
and 1.45 times faster than Hermes (1.42 precompiled), 1.13 times faster
than JavaScriptCore's interpreter, and V8's is 1.06 times faster, its
figures moving more than the others' from run to run. Earlier the same
day (`results/2026-09-29-arrays.json`, engine `b6cbba7`, before the fused
instructions): 1.47 QuickJS, 1.29 Hermes (1.27 precompiled),
JavaScriptCore 1.03, V8 1.14 faster; on 2026-09-28
(`results/2026-09-28-captured.json`, engine `322e164`): 1.39 QuickJS,
1.22 Hermes (1.21 precompiled), JavaScriptCore level, V8 1.14 faster. Over the ten before
`helpers` (`results/2026-09-28.json`, engine `4143c54`): 1.33 QuickJS,
1.27 Hermes, JavaScriptCore 1.09 faster, V8 1.10. On 2026-09-27
(`results/2026-09-27.json`, engine `325838b`) the engine was 1.06 times
faster than QuickJS and level with Hermes, and JavaScriptCore was 1.37
times faster, V8 1.49; on 2026-09-26 (`results/2026-09-26-hermes.json`)
QuickJS was 1.19 times faster, Hermes 1.25 (1.28 precompiled),
JavaScriptCore 1.7, V8 1.9. The engine is the fastest of these on
allocation, helpers, Map and Set, and polymorphic access, and starts
fastest. The Hermes VM alone is 2.75 MB of code and 3.34 MB with its
compiler (arm64), against the engine's minimal embedder of 0.77 MB
(0.56 MB on a core context). The largest gaps left: JSON (2.8x
JavaScriptCore), strings (1.8x V8), regular expressions (1.6x V8), calls
(1.5x V8), closures (1.5x Hermes precompiled), properties (1.2x
JavaScriptCore), arrays (1.1x V8). The plan to close them is
[levers.md](levers.md).

Memory, on a large live heap (`bench/memory`): about 100 MB at peak,
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
./build.sh                                    # optimized engine, every gate
./bench/speed/run.py                          # the speed table
size -m engine/.z-cache/build/zjsz.o          # the engine's sections
```
