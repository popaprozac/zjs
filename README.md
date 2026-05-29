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
| 2.3-2.5 | Parser — expressions, statements, functions, arrow funcs, for-in/of |
| 3.0a-c | Bytecode compiler + register-machine interpreter, test262 scaffolding |
| 3.1a-f | Heap, strings, objects, arrays, throw/try/catch, host fns, GC, atoms |
| 3.2a-b | Hidden classes + inline caches (LoadProp/StoreProp `{cls, slot}`) |
| 3.3    | Closures + env chain |
| 3.4    | for-in / for-of, iteration protocol |
| 3.5    | Built-ins — Array / String / JSON / Math / Object / Number / Date |
| 3.6    | Prototype chain (`new`, `.prototype`, instanceof) |
| 3.7    | Classes (extends, super, static, methods, accessors, fields) |
| 3.8    | Strictness sweep, conformance coverage push |
| 3.9    | Performance pass — async/await, generators, modules, IC poly, instruction fusion, proto-chain IC, register-borrow / preferred-dst threading |
| 3.9h   | Non-recursive interpreter — single outer loop with explicit CallFrame stack |
| 4.0    | AOT bytecode — `zjs compile in.js -o out.zbc` + `zjs run out.zbc`; CLI auto-sniffs the `ZJSb` magic; embed ABI via `zjs_compile_to_bytecode` / `zjs_eval_bytecode`; wire format in `docs/aot-bytecode-format.md` |
| 4.1    | Iterator-protocol cleanup — Promise.{all,race,any,allSettled} drive `GetIterator`/`IteratorStep`; spec-correct non-Object rejects; `Map.groupBy` + `Object.groupBy`; ES2025 Set composition (`difference`/`intersection`/`union`/`symmetricDifference`/`isSubsetOf`/`isSupersetOf`/`isDisjointFrom`); object-shorthand-default cover grammar (`({x = 1} = src)`) |
| 4.2 | Perf pass against Hermes — string ropes (O(n²)→O(n) concat, 3.8x speedup); super-instructions (`JmpIfNot{Eq,Ne,StrictEq,StrictNe}`, `JmpIfNullish` + nullish-literal peephole, `f.this_reg` metadata hoist replacing per-call `LoadThis`, `borrow_local_ok` at `ReturnStmt`); `libzjs.a` static archive for iOS embedding; WebSocket keep-alive ping/pong; `hermes`/`shermes` added to bench-compare |
| 4.3 | Symbol semantics cleanup — `@@*` shim keys filtered from `Object.keys` / `getOwnPropertyNames` / `for-in` / `JSON.stringify`; `Object.getOwnPropertySymbols` implemented (walks both young + old cell pools for live Symbols); `Symbol.toPrimitive` dispatch in `zjs_to_primitive` (§7.1.1 step 4); JSON.stringify skips Symbol-valued properties |
| 4.4 | Private class fields + methods (`#name`) — lexer `PrivateName` token, compile-time mangling to `__zjs_priv_<class_id>_<name>` already-filtered keys (each class gets a fresh id from `ctx.class_id_counter`). Fields, methods, static fields, static methods all supported. ~+1,500 test262 unlocks |
| 4.5    | Async iteration — `for-await-of` (sync + async iterables), `Symbol.asyncIterator`, async generator method parsing |
| 4.6    | Proxy + Reflect — `TAG_PROXY` cell, `property_get` / `property_set` detour to `handler.get`/`handler.set` traps, revoked-proxy TypeError, `Reflect.{get,set,has}`. Infrastructure in place for the remaining traps |
| 4.7    | Subclassing parity — `class Sub extends Promise/Array/Map/Set/Date/RegExp {}` carries a per-instance `[[Prototype]]`; `super()` propagates outer `new.target`; `NewPromiseCapability` protocol lifted out of Promise.all/race/any/allSettled |
| 4.8    | Conformance polish — Symbol.toPrimitive, IteratorClose on abrupt completion, captured-FunctionDecl exports, captured rest parameter, contextual keywords (`from`/`as`), named function expression self-binding, per-iteration env for `for (let\|const x of/in iter)` |
| **5.0** | **Standard library (task #190, `docs/stdlib-design.md`) — node-flavored modules under `node:` prefix + WinterTC web globals. See "Standard library" below.** |
| **5.1** | **WinterTC MCA conformance push — own probe suite at `tests/wintercg/` + runner; closed `getRandomValues` / URL setters / `Headers.append` / `Request` / `Response` / AES-GCM / async-generator-await / `String.prototype.replace` `$N` / Date copy ctor / arrow lexical `this` / method-shorthand self-bind. WinterTC suite at 100% (103/103).** |
| **5.2** | **Stdlib DX — pure-JS bootstraps extracted to real `.js` files (`tools/embed_js.py` embeds at build time); `// @ts-check` + `tsc -p tsconfig.stdlib.json` validation. `zjs-types` package at `types/` ships TypeScript declarations for embedders.** |

**Conformance (three framings, intentionally):**

- **test262 curated subset — 87.2%** (12,097 of 13,878). The Phase 4.3 → 4.8 arc unmasked private class fields, Proxy/Reflect, async iteration, subclass-built-ins (Promise/Array/Map/Set/Date/RegExp), plus stale-skipped features that were actually shipping. This number answers **"of the parts we claim to support, how spec-correct are we?"**.
- **test262 full suite — 54.1%** (25,084 of 46,364) against `test/language/` + `test/built-ins/` with no feature-skip list, matching the methodology of dashboards like [test262.fyi](https://test262.fyi). Missing-feature failures count as real failures here. Run via `make test262-full`. This number answers **"across the entire spec surface, how complete is the engine?"** — the ~30pt gap to QuickJS NG (~82%) is mostly BigInt, WeakRef, and Temporal.
- **WinterTC Minimum Common API — 100%** (103/103, `make wintercg`). zjs-owned probe suite at `tests/wintercg/` since there's no upstream WinterTC test repo. Covers encoding (TextEncoder/Decoder + streams), URL, EventTarget, AbortController, crypto + crypto.subtle (digest / importKey / generateKey / exportKey / sign / verify / encrypt / decrypt), Blob/File/FormData, streams (default + BYOB + tee), timers + queueMicrotask, performance User Timing, structuredClone, fetch + Headers/Request/Response.

Live dashboards: `docs/conformance/index.html` (test262 macOS), `docs/conformance/index-{windows,linux}.html`, `docs/wintercg/index.html`.

**Perf:** vs qjs (our closest peer — both jitless interpreters), zjs ahead on 14 / behind on 7 of 21 microbenches in the current snapshot (`make bench-compare`). vs hermes (Meta's jitless engine, the design-space ceiling), zjs ahead on a couple / behind on most — richards within ~1.6×, splay ~1.9×; widest gaps on numeric / alloc-heavy benches (mandelbrot, nbody) where Hermes's generational GC and specialized arithmetic opcodes are the structural lead. Live charts at `docs/perf/index.html` (macOS) — Windows / Linux / cross-engine siblings as above.

**Perf pass (2026-05-29):** investigated the apparent ~10% regression vs the 2026-05-27 history baseline. Rebuilding `3567bc7` on the same machine showed most of it was measurement-environment delta (the prior baseline ran on a quieter system) — HEAD is actually faster than the historical baseline on several benches. Two real regressions remained. `hash_count` (+20%) closed via a ToInt32/ToUint32 fast path for finite doubles in int64 range (commit e0daa87) — the spec walk was hitting `fmod` per `seed & MASK`; also recovered 2–5% on `int_loop` / `richards` / `fib_recursive`. `regex_match` (+115%) is intrinsic to the TRE → libregexp swap (672e28c — DFA → backtracking NFA, paid for lookahead / non-greedy / named captures); hoisting the regex literal out of the loop didn't help, so it's matching time, not compile. Closing or improving that would mean vendoring a third engine or shipping a DFA fast-path for simple patterns — left as future work.

## Standard library

Node-flavored modules under the `node:` prefix + WinterTC-aligned web
globals. Design notes in `docs/stdlib-design.md`.

**Node-flavored (`import x from 'node:foo'`):**

| Module | Surface |
|---|---|
| `node:path` | `join`, `resolve`, `normalize`, `dirname`, `basename`, `extname`, `parse`, `format`, `isAbsolute`, `relative`, `sep`, `delimiter` (POSIX) |
| `node:fs` | `readFileSync`, `writeFileSync`, `readdirSync`, `statSync`, `lstatSync`, `mkdirSync({recursive})`, `unlinkSync`, `rmSync({recursive,force})`, `copyFileSync`, `renameSync`, `accessSync`, `existsSync` + `F_OK/R_OK/W_OK/X_OK` + `promises` namespace |
| `node:fs/promises` | promise-returning equivalents (`readFile`, `writeFile`, `readdir`, `stat`, `lstat`, `mkdir`, `unlink`, `rm`, `copyFile`, `rename`, `access`). Errors carry `.code` / `.errno` / `.syscall` / `.path` so `err.code === 'ENOENT'` checks work. |
| `node:process` | `argv`, `env`, `platform`, `arch`, `pid`, `versions`, `cwd()`, `chdir()`, `exit(code)`, `hrtime([prev])`, `nextTick(cb)` — also exposed as `globalThis.process` (Node convention) |
| `node:os` | `tmpdir`, `homedir`, `platform`, `arch`, `type`, `release`, `hostname`, `cpus`, `totalmem`, `freemem`, `userInfo`, `EOL` |
| `node:events` | `EventEmitter` — `on`/`off`/`once`/`prependListener`/`removeListener`/`removeAllListeners`/`listeners`/`listenerCount`/`eventNames`/`emit`; `'error'` without listener throws (Node convention) |
| `node:util` | `promisify` (+ `.custom` symbol), `callbackify`, `types.is{Promise,Date,RegExp,Map,Set,Uint8Array,ArrayBuffer,TypedArray}`, `inspect` (cycle-safe), `format` (printf-style `%s %d %i %f %j %o %O %%`) |
| `node:assert` | `ok`/`equal`/`notEqual`/`strictEqual`/`notStrictEqual`/`deepStrictEqual` (alias `deepEqual`)/`throws`/`doesNotThrow`/`fail` + `AssertionError`; `assert.strict === assert` |

**WinterTC web globals** ([Minimum Common API](https://min-common-api.proposal.wintertc.org/)):

`fetch` / `Request` / `Response` / `Headers` · `URL` / `URLSearchParams` (full setter set: `pathname` / `search` / `hash` / `hostname` / `port` / `protocol`) · `TextEncoder` / `TextDecoder` / `TextEncoderStream` / `TextDecoderStream` · `WebSocket` · `setTimeout` / `setInterval` / `clearTimeout` / `clearInterval` · `queueMicrotask` · `console` · `globalThis` · `performance.now` / `performance.timeOrigin` / `performance.mark` / `performance.measure` / `performance.clearMarks` / `performance.clearMeasures` / `performance.getEntries{,ByName,ByType}` · `crypto.getRandomValues` / `crypto.randomUUID` / `crypto.subtle.digest` / `crypto.subtle.importKey` / `crypto.subtle.generateKey` / `crypto.subtle.exportKey` / `crypto.subtle.sign` / `crypto.subtle.verify` / `crypto.subtle.encrypt` / `crypto.subtle.decrypt` (SHA-1/256/384/512, HMAC, AES-GCM 128/192/256) · `btoa` / `atob` · `reportError` · `Event` / `CustomEvent` / `EventTarget` · `AbortController` / `AbortSignal` (+ `.timeout`, `.any`, `.abort`, `.throwIfAborted`) · `DOMException` · `structuredClone` · `Blob` / `File` / `FormData` · `ReadableStream` (+ `.tee()` + BYOB reader for `type: 'bytes'` streams) / `WritableStream` / `TransformStream` / `CountQueuingStrategy` / `ByteLengthQueuingStrategy`

```js
import path from 'node:path';
import * as fs from 'node:fs/promises';

const dir = path.dirname(process.argv[1]);
const text = await fs.readFile(path.join(dir, 'config.json'), 'utf8');
console.log(JSON.parse(text));

// AbortSignal-aware fetch
const ctrl = new AbortController();
setTimeout(() => ctrl.abort(), 5_000);
const res = await fetch('https://api.example.com', { signal: ctrl.signal });
```

**Bundle control** is at the C-ABI layer: `zjs_new_context()` registers
everything by default. Embedders wanting a smaller surface skip the
registration calls. Build-time flags (`-DZJS_NO_NETWORK`,
`-DZJS_NO_CHILD_PROCESS`, `-DZJS_NO_FS`) drop the genuinely fat
dependency chains.

Not yet shipped: `node:net` / `node:http` (server side — `fetch`
covers client), `node:child_process`. Tracked in
`docs/stdlib-design.md`.

```js
// Async iteration over a stream
import { ReadableStream } from 'node:stream/web';  // also globals
const rs = new ReadableStream({ start(c) { c.enqueue('a'); c.enqueue('b'); c.close(); } });
for await (const chunk of rs) console.log(chunk);  // a, b

// HMAC signing
const key = await crypto.subtle.importKey('raw', new TextEncoder().encode('secret'),
  { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode('payload'));

// Node-style EventEmitter
import EventEmitter from 'node:events';
const ee = new EventEmitter();
ee.on('data', d => console.log(d));
ee.emit('data', 42);
```

Per-phase plans live in `docs/phases/`.

**Programs run end-to-end:**

```bash
$ ./build/zjs eval "function fib(n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); } fib(10)"
55

$ ./build/zjs eval "let inc = x => x + 1; inc(41)"
42

# Classes — extends, super, fields, accessors
$ ./build/zjs eval "class Animal { speak() { return 'silence'; } } class Dog extends Animal { speak() { return super.speak() + ' broken by a bark'; } } new Dog().speak()"
silence broken by a bark

# Template literals + tagged templates (String.raw is built-in)
$ ./build/zjs eval "let name = 'world'; \`hello \${name}\`"
hello world
$ ./build/zjs eval "String.raw\`first \\\\n second \${1+2}\`"
first \n second 3

# async / await
$ ./build/zjs eval "async function f() { return 42; } f().then(v => console.log(v))"
42

# Destructuring (binding + assignment forms)
$ ./build/zjs eval "let [a, ...rest] = [1, 2, 3, 4]; rest.join(',')"
2,3,4
$ ./build/zjs eval "let x; ({a: x = 99} = {}); x"
99

# Map.groupBy + Set composition (ES2024 / 2025)
$ ./build/zjs eval "JSON.stringify(Object.groupBy([1,2,3,4], x => x % 2 ? 'odd' : 'even'))"
{"odd":[1,3],"even":[2,4]}
$ ./build/zjs eval "[...new Set([1,2,3]).difference(new Set([2]))]"
[1,3]

# Promise combinators accept any iterable (not just arrays)
$ ./build/zjs eval "function* g(){yield 1;yield 2;yield 3} Promise.all(g()).then(v => console.log(JSON.stringify(v)))"
[1,2,3]

# AOT bytecode — parse + compile once, run from the .zbc later
$ ./build/zjs compile script.js -o script.zbc && ./build/zjs run script.zbc
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
- `build/libzjs.a` — static archive of the same; required for iOS App Store embedding (no `dlopen`), useful elsewhere as the small-binary path
- `build/smoke` / `build/smoke_static` — pure-C consumers of the library (dylib and `.a`); validate the embed surface from both link modes
- `build/lexer_test`, `build/parser_test`, `build/interp_test` — Zen-c test runners

Try it:

```bash
./build/zjs --version
./build/zjs eval  "1 + 2 * 3"
./build/zjs lex   "let x = 1 + 2;"
./build/zjs parse "function add(a, b) { return a + b; }"
```

## test262 conformance

The TC39 test262 suite isn't bundled (large repo). Clone it once into `vendor/`:

```bash
git clone --depth=1 https://github.com/tc39/test262 vendor/test262
```

Then run the canonical conformance subset:

```bash
make test262
```

`make test262` runs the Python harness in `scripts/test262/` — it
parses each test's YAML frontmatter, skips tests that need features
or harness helpers we haven't built yet, classifies negative tests by
expected throw type, and writes:

- `docs/conformance/last.json` — per-test results for this run
- `docs/conformance/history.jsonl` — append-only summary
- `docs/conformance/index.html` — self-contained report with a pass-rate sparkline + first failures (open in any browser)

When the runner detects Windows (`sys.platform == 'win32'`) it writes
to `last-windows.json` / `history-windows.jsonl` / `index-windows.html`
instead, so the macOS history isn't polluted by a different host
configuration.

The included subset (see `scripts/test262/config.json`) covers
language expressions / statements / iteration plus built-ins we
support (Object / Array / String / JSON / Math). Expand the
`include` list as the engine grows.

For a fast harness-light sanity pass against a single subdir, the
older C-based runner is still available as `make test262-quick`.

## WinterTC MCA conformance

```bash
make wintercg
```

Runs the zjs-owned WinterTC Minimum Common API probe suite at
`tests/wintercg/` — eleven WPT-shaped `.js` files (one per API area)
through the harness at `scripts/wintercg/zjs_harness.js`. Each probe
calls `test()` / `promise_test()` / `assert_equals` / etc.; the
runner aggregates per-area pass/fail and writes
`docs/wintercg/{last.json, history.jsonl, index.html}`.

There's no upstream `wintercg/api-test` repo (verified against all
18 repos in the WinterTC55 GitHub org), so the probes ship with zjs
and ratchet over time. Suite is at **100%** as of the current commit.

The TypeScript declarations consumers can use to type-check their
own code against zjs's surface live in `types/` (also published as
the `zjs-types` package — see `types/README.md`). Type-check the
stdlib internals with `make stdlib-check`.

## Benchmarks

```bash
make bench
```

Runs the scripts in `scripts/bench/*.js` (tight integer / double
loops, monomorphic and polymorphic property access, closure invoke,
method dispatch on a class prototype, array build + for-of, object
literal allocation, string concat, try/catch overhead) and writes:

- `docs/perf/last.json` — per-bench median / min / max
- `docs/perf/history.jsonl` — append-only summary, one row per run
- `docs/perf/index.html` — table of latest medians plus per-bench
  line charts of median ms over time (open in any browser)

Windows runs land in the `-windows`-suffixed siblings of those files,
same convention as the conformance dashboard above.

Each benchmark is timed end-to-end around `zjs run <file>` (parse +
compile + interpret). Numbers are tracked across commits in
`docs/perf/index.html`.

```bash
make bench-compare
```

Also runs each script under `qjs`, `boa`, `hermes -O` (Meta's jitless
interpreter — our direct design-space peer), `shermes -O -exec`
(Static Hermes, JS → C → native — AOT-to-native ceiling reference),
`node`, `bun`, and `deno`, and writes `docs/perf/compare.html`.
qjs and hermes are the meaningful peers (both jitless); node / bun /
deno include JIT but their numbers are largely process-startup on
our short scripts.

Builds default to `--release` (`-O3`-ish) via `zc`. For debug
builds: `make ZC_FLAGS='-w -O0 -g'`.

## Embed surface

See `include/zjs.h`. QuickJS-style: opaque `ZjsContext*` handle, opaque NaN-boxed `ZjsValue`, no global state, all functions `extern "C"`-callable. The header is the complete contract — what's in there works for embedders, nothing more.

```c
#include "zjs.h"

ZjsContext* ctx = zjs_new_context();

/* Evaluate source */
ZjsValue v = zjs_eval(ctx, "let x = 10; let y = 20; x + y");
int      n = zjs_is_int32(v) ? zjs_as_int32(v) : 0;        // 30

/* Detect uncaught throws */
zjs_eval(ctx, "throw 'boom'");
if (zjs_had_error(ctx)) {
    ZjsValue err = zjs_get_error(ctx);     // the thrown value
}

/* Build JS values from C, set globals, call JS from C */
ZjsValue obj = zjs_new_object(ctx);
zjs_set_property(ctx, obj, "answer", zjs_int32(42));
zjs_set_global(ctx, "from_host", obj);

/* Host function callable from JS */
ZjsValue my_log(ZjsContext* c, ZjsValue* argv, uint32_t argc) { /* ... */ return zjs_undefined(); }
zjs_register_host_function(ctx, "hostLog", my_log);

/* AOT bytecode — parse + compile once, replay later */
size_t n_bytes = 0;
unsigned char* bc = zjs_compile_to_bytecode(ctx, source, &n_bytes);
ZjsValue result = zjs_eval_bytecode(ctx, bc, n_bytes);
free(bc);

zjs_free_context(ctx);
```

## Project layout

```
zjs/
├── include/zjs.h           # Public C ABI — the contract for embedders
├── src/
│   ├── lib.zc              # Library entry; re-exports public API
│   ├── value.zc            # NaN-boxed ZjsValue + arithmetic helpers
│   ├── context.zc          # Globals table, function ownership, host fns
│   ├── token.zc / lexer.zc # Lexer
│   ├── ast.zc / parser.zc  # Parser
│   ├── bytecode.zc         # Opcode enum + Inst + Function
│   ├── compiler.zc         # AST → bytecode
│   ├── interpreter.zc      # Bytecode → ZjsValue
│   ├── eval.zc             # Lex → parse → compile → interpret pipeline
│   ├── aot.zc              # AOT bytecode serializer / deserializer
│   ├── platform/           # Per-OS native shims (http, ws, portability)
│   └── stdlib/             # node:* modules + WinterTC web globals
│       ├── node_path.zc, node_fs.zc, node_process.zc, node_os.zc
│       ├── web_events.zc, web_abort.zc, web_clone.zc, web_blob.zc,
│       │   web_streams.zc
│       └── *.js             # pure-JS source for stdlib bootstraps —
│                            # embedded as C strings via tools/embed_js.py
│                            # at build time (writes *.gen.h alongside)
├── types/                  # zjs-types — TypeScript declarations
│   ├── index.d.ts          #   barrel reference file
│   ├── globals.d.ts        #   ambient globals (process, performance, …)
│   └── node-*.d.ts         #   one per `node:` module
├── tools/zjs.zc            # CLI
├── tests/
│   ├── embed_smoke.c       # Pure-C consumer test (NaN-box + eval)
│   ├── lexer_test.zc       # Lexer test runner
│   ├── parser_test.zc      # Parser test runner
│   ├── interpreter_test.zc # End-to-end eval tests
│   └── test262_runner.c    # test262 conformance harness
├── docs/
│   ├── jitless-design-study.md   # Phase 1 — Hermes/QuickJS/LLInt synthesis
│   ├── stdlib-design.md          # Standard library design + roadmap
│   ├── platform-port-status.md   # Per-OS porting ledger
│   ├── aot-bytecode-format.md, cross-compile.md, gc-experiment.md, …
│   └── phases/phase-2-*.md, phase-3-*.md
└── Makefile
```

## License

TBD.
