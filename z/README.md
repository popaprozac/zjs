# ZJS in Z

The Z rewrite of the ZJS engine. Design:
[`docs/superpowers/specs/2026-09-14-zjs-z-rewrite-design.md`](../docs/superpowers/specs/2026-09-14-zjs-z-rewrite-design.md).

`src/` (Zen-c) remains the shipping engine and the behavioral oracle. This tree
is built beside it, never on top of it.

## Status — Phases 4–5 in progress: the engine evaluates JavaScript

The loop works end to end: the **unmodified** `tests/test262_runner.c` links
against a Z-implemented `libzjs.a` and runs. It reports 0 passed, because no
JavaScript is evaluated yet. Every phase after this is about making that
number climb.

Phase 2 added the foundation the interpreter will sit on — NaN-boxed values
and a handle-based cell heap, with each context owning its own heap. 12 unit
tests via `z test`.

Phase 3: the lexer produces **byte-identical token streams** to the Zen-c
reference over the whole local corpus (24 files, 33,168 tokens,
`./z/oracle-tokens.sh`), and the parser produces **byte-identical ASTs** for
all 24 real files plus an 11-file synthetic corpus covering every construct
(`./z/oracle-ast.sh`). Both reference dumps link `build/libzjs.a` directly, so
the oracles need no Zen-c toolchain. The parser is ordinary Z throughout; its
one native call is `strtod` for decimal literals.

Phases 4–5, grown as vertical slices against a **behavioral oracle**
(`./z/oracle-eval.sh`: both engines evaluate a file and print a canonical
rendering of the completion value or uncaught throw): numbers with the
reference's int32 fast paths, strings as byte arrays with interning,
concatenation, number/string coercions and formatting, equality and ordering,
logical operators, `var`/`let`/`const`, assignment in all forms, `++`/`--`,
`if`/`while`/`do`/`for`/`break`/`continue`; functions, calls, recursion,
defaults, hoisting, the conditional operator; objects on hidden classes with
prototype chains, arrays with holes, property access in every form, method
calls with `this`, `new` with `prototype`/`constructor`, `typeof`; the Error
family as Z builtins, `throw`, `try`/`catch`/`finally` with unwinding across
frames; closures -- captured bindings live in environment cells addressed by
slot, resolved at compile time through the scope chain, with arrows keeping
the `this` of their creation; template literals, `switch`, labeled
`break`/`continue`, `for`-`in` (keys in insertion order across the prototype
chain) and `for`-`of` over arrays, `in`/`instanceof`/`delete`, `++`/`--` and
logical assignment on properties, and `Object`. **34 of 34** corpus files
identical.

Phase 7, builtins, in progress. Builtins are Z modules under
`engine/builtins/`, each registering its functions in the runtime's
host-function table (Z function values with an any-thread contract) and
attaching them to the intrinsic prototypes -- the runtime module knows
nothing of them, so they call back into it, and through `callValue` into
JavaScript, with no import cycle. Landed: the Error family, `Object` and
its prototype's `toString` / `valueOf` / `hasOwnProperty` / `isPrototypeOf`,
`Function.prototype.call` / `apply`, `Array` with `isArray` and the core
prototype methods, `eval` (global scope), `parseInt` / `parseFloat` /
`isNaN` / `isFinite`, and `globalThis` as a real object whose properties
fall through to the globals table. ToPrimitive runs `valueOf` / `toString`,
so `"" + obj` and `obj + 1` follow user code. Top-level and sloppy-call
`this` are the global object. Then `Boolean`, `Number` (with `toString`
in any radix, `toFixed`, the `is*` predicates and constants), `String`
(the byte-string prototype: `charAt` through `split`, `replace` with a
string pattern), wrapper objects keyed by an unforgeable hidden atom, and
`Math` in full over the C library with a xorshift `random`.

`./z/test262.py` runs the reference's own test262 runner logic
(`scripts/test262/run.py`: harness assembly, strict/sloppy modes, curated
subset, classification) against both engines through matching command
lines, `z/build/zjs-ref` (public ABI) and `z/build/zjsz` (Z), and reports
the gap with the tests the reference passes and Z does not. Needs
`vendor/test262`. Measurements so far: `language/statements/if` 117 of the
reference's 121; `built-ins/Math` 292 of 618 -- the gap there is property
attributes (`verifyProperty`), `Function.prototype.bind`, and host
functions that must not be constructors, which the next slice brings.

Phase 6, the collector: mark-sweep over the handle heap with stable handles.
Marking walks from the runtime's roots (registers, globals, frames, the
realm, compiled code's constants and property names); sweeping frees dead
headers onto a free list for reuse and compacts every live cell's slots into
a fresh arena, so an object that outgrew its range leaves no permanent hole
and nothing outside the heap needs updating. The atom table is weak. It runs
at instruction boundaries only -- returns and loop back edges -- so no value
is ever held only in a Z local across a collection. The ABI smoke test runs a
200,000-iteration allocating loop and checks the heap stays bounded.

Places the corpus deliberately steps around, where the reference is wrong and
the Z engine follows the specification: a property write to `undefined`
throws a TypeError (the reference drops it); `Error.prototype.message` is
`""` (the reference has no such property); `for`-`in` over a string visits
its indices (the reference visits nothing); a postfix `++` on a property
holding a string yields its numeric value (the reference concatenates).

Strings are byte strings, as in the reference: `length`, indexing, and
the String methods count bytes. Whether the rewrite keeps that or moves to
UTF-16 code units is an open design question; the oracle needs parity with
the reference for now.

Not yet: per-iteration `let` bindings in loops (a closure made in a loop
sees one binding), `Function` / `bind` / `JSON` / `Date` / `RegExp`,
direct `eval` seeing the caller's locals, property attributes (everything
is writable and enumerable, except that an inherited `constructor` is
skipped by `for`-`in`), accessors,
`for`-`of` over anything but an array, `return` and `break` through a
`finally`, and the remaining builtins. The collector is stop-the-world and
non-generational; the reference's nursery is a later refinement.

```
$ ./z/oracle.sh
reference passed: 5   z passed: 0   gap: 5
```

## Layout

| Path | What |
|---|---|
| `engine/value.zs` | NaN-boxed value, JSC layout, handle-carrying cells |
| `engine/heap.zs` | handle-based cell heap: headers, slots, mark bits |
| `engine/lib.zs` | context registry and the C ABI exports |
| `engine/token.zs` | token kinds (order mirrors `src/token.zc`; numbering generated) |
| `engine/lexer.zs` | the lexer, idiomatic register, no `raw c` |
| `engine/ast.zs` | AST: one flat node shape, index-linked, order mirrors `src/ast.zc` |
| `engine/parser.zs` | recursive-descent parser, index-linked nodes, no raw pointers |
| `engine/bytecode.zs` | opcodes (order mirrors `src/bytecode.zc`), instructions, compiled functions |
| `engine/compiler.zs` | AST to bytecode; high-water register allocation |
| `engine/runtime.zs` | per-context state and the interpreter loop; coercions and comparisons |
| `tools/evaldump-ref.c`, `tools/evaldump-z/` | eval-result dumps from each engine |
| `tests/eval-corpus/` | behavioral corpus for the eval oracle |
| `tools/astdump-ref.c`, `tools/astdump-z/` | AST dumps from each engine |
| `tests/parse-corpus/` | synthetic corpus, one file per construct family |
| `tools/tokdump-ref.c`, `tools/tokdump-z/` | token dumps from each engine |
| `probes/` | executable acceptance cases for `docs/z-findings.md` |
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
./z/oracle-tokens.sh              # lexer oracle: diff token dumps, both engines
./z/oracle-ast.sh                 # parser oracle: diff AST dumps, both engines
./z/oracle-eval.sh                # behavioral oracle: diff eval results, both engines
./z/probes/run.sh                 # z-lang acceptance probes (see probes/README.md)
./z/spike/run.sh                  # Phase 0 measurements

cd ~/code/z-lang && bun run z test ~/code/zjs/z/engine/heap.zs   # unit tests
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
