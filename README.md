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
| **4.2** | **Perf pass against Hermes — string ropes (O(n²)→O(n) concat, 3.8x speedup); super-instructions (`JmpIfNot{Eq,Ne,StrictEq,StrictNe}`, `JmpIfNullish` + nullish-literal peephole, `f.this_reg` metadata hoist replacing per-call `LoadThis`, `borrow_local_ok` at `ReturnStmt`); `libzjs.a` static archive for iOS embedding; WebSocket keep-alive ping/pong; `hermes`/`shermes` added to bench-compare** |

**Tests:** 941 in-tree assertions pass (378 smoke + 48 lexer + 84 parser + 431 interpreter).

**Conformance:** 83.9% of the test262 included subset (6,711 of 7,997 non-skipped). Live dashboard at `docs/conformance/index.html` (macOS) — Windows results at `docs/conformance/index-windows.html`.

**Perf:** vs qjs (our closest peer — both jitless interpreters), zjs ahead on 17 / tied on 1 / behind on 3 of 21 microbenches. vs hermes (Meta's jitless engine, the design-space ceiling), zjs ahead on 5 / behind on 14 of 19 measurable — richards within 1.40×, splay 1.65×, with widest gaps on numeric / alloc-heavy benches (mandelbrot, nbody, object_alloc) where Hermes's generational GC and specialized arithmetic opcodes are the structural lead. Live charts at `docs/perf/index.html` (macOS) — Windows results at `docs/perf/index-windows.html`, cross-engine at `docs/perf/compare.html`.

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
│   ├── context.zc          # Globals table, function ownership
│   ├── token.zc / lexer.zc # Lexer
│   ├── ast.zc / parser.zc  # Parser
│   ├── bytecode.zc         # Opcode enum + Inst + Function
│   ├── compiler.zc         # AST → bytecode
│   ├── interpreter.zc      # Bytecode → ZjsValue
│   └── eval.zc             # Lex → parse → compile → interpret pipeline
├── tools/zjs.zc            # CLI
├── tests/
│   ├── embed_smoke.c       # Pure-C consumer test (NaN-box + eval)
│   ├── lexer_test.zc       # Lexer test runner
│   ├── parser_test.zc      # Parser test runner
│   ├── interpreter_test.zc # End-to-end eval tests
│   └── test262_runner.c    # test262 conformance harness
├── docs/
│   ├── jitless-design-study.md         # Phase 1 — Hermes/QuickJS/LLInt synthesis
│   └── phases/phase-2-*.md, phase-3-*.md
└── Makefile
```

## License

TBD.
