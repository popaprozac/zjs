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
`Math` in full over the C library with a xorshift `random`. Then property
attributes: one attribute byte beside every slot, accessor cells for
getters and setters (object literals included), `[[DefineOwnProperty]]`
with its validation, own keys in specification order, extensibility flags,
strict-mode rejection of read-only writes; `Object`'s statics and `Reflect`;
`Function` compiled from source, `bind`, and host functions that are not
constructors. The `arguments` object (an array tagged for
`Object.prototype.toString`, shared with arrows through the environment)
and rest parameters read the frame's actual arguments. `Symbol`: a symbol
is a cell whose property key is a hidden atom (0xFF, a counter) linked
back to it, so the property machinery is unchanged and the key is
unforgeable; the registry, the well-known symbols, `@@toPrimitive` with
the default hint for `+` and `==`, `@@toStringTag`, `@@hasInstance`, and
symbol keys last in `Reflect.ownKeys`. `JSON.parse` (a byte-level
recursive-descent parser with the reviver walk) and `JSON.stringify`
(`toJSON`, replacer function and allow-list, indentation, wrappers, cycle
detection). The iteration protocol: `for`-`of` drives GetIterator /
IteratorStep and closes the iterator on `break`, `continue` past it, and
`return`; spread in array literals, calls, and `new`; array iterators
(values / keys / entries, with an allocation-free step while `next` is
pristine), `String.prototype[@@iterator]`, `Array.from` / `of`.
Destructuring in every position -- declarations, parameters (with
defaults), catch parameters, loop heads, and assignment -- with nested
patterns, defaults, holes, rest elements, object rest, and computed keys,
through the iterator protocol for arrays. Control flow that leaves a
region undoes it on the way out: a `break`, `continue`, or `return`
pops the try handlers it crosses, runs the `finally` blocks it crosses
inline, and closes the `for`-`of` iterators it leaves; a throw inside a
`for`-`of` body closes the iterator too. Anonymous functions take the name
of the binding, property, or parameter they initialize (accessors with a
`get ` / `set ` prefix); only a function expression written with a name
binds it inside itself. Generators: a generator object is an ordinary
object holding a record under a hidden key; a call runs the parameter
prologue and suspends at GeneratorStart, `yield` copies the frame's
register window and open try handlers out, and `next` / `throw` / `return`
push a fresh frame and copy them back. `yield*` delegates values (what
`next` sends is not yet forwarded, nor is the delegate's final value).
Keyed collections: `Map`, `Set`, `WeakMap`, `WeakSet` as ordinary objects
holding a record under a hidden key -- keys and values in insertion order
with a deleted marker, an open-addressed index hashed consistently with
SameValueZero, and the live count -- so iteration walks by position and
sees additions and deletions during the walk; `forEach`, the three
iterators (`Map Iterator` / `Set Iterator` prototypes), `Map.groupBy` /
`Object.groupBy`, `getOrInsert` / `getOrInsertComputed`, the Set methods
(`union` through `isDisjointFrom` over any set-like), and
`get [Symbol.species]` on `Map`, `Set`, and `Array`. The weak
collections keep their keys alive; the collector does not yet treat them
weakly. Deleting a global through the global object undefines the
binding.

`./z/test262.py` runs the reference's own test262 runner logic
(`scripts/test262/run.py`: harness assembly, strict/sloppy modes, curated
subset, classification) against both engines through matching command
lines, `z/build/zjs-ref` (public ABI) and `z/build/zjsz` (Z), and reports
the gap with the tests the reference passes and Z does not. Needs
`vendor/test262`. Measurements so far: `language/statements/if` 117 of the
reference's 121; `built-ins/Math` 614 of 618; `built-ins/Object` 5714 of
6244; `built-ins/Number` 578 of 582; `built-ins/Symbol` 130 against the
reference's 90; `built-ins/JSON` 220 of 224 -- with Z passing 18, 230,
64, 50, and 14 tests respectively that the reference fails. `built-ins/Map`
395 against the reference's 367, `WeakMap` 273 against 244, `WeakSet` 166
against 154, and `Set` 628 of 725, where the gap is the class syntax the
set-method tests are written with and `Array.prototype.shift`. The largest
remaining gaps are the missing `Date` and `RegExp`, classes, and the rest
of `Array.prototype` / `String.prototype`.

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
holding a string yields its numeric value (the reference concatenates);
`Map()` without `new` throws a TypeError (the reference returns
undefined); `Map.prototype[@@iterator]` is `entries` and
`Set.prototype.keys` / `[@@iterator]` are `values` (the reference makes
distinct functions); `Object.prototype.toString` on a collection iterator
reads its `@@toStringTag` (the reference says `[object Object]`); a
closure created inside `catch` sees the catch parameter (the reference
throws a ReferenceError).

Strings are byte strings, as in the reference: `length`, indexing, and
the String methods count bytes. Whether the rewrite keeps that or moves to
UTF-16 code units is an open design question; the oracle needs parity with
the reference for now.

Not yet: per-iteration `let` bindings in loops (a closure made in a loop
sees one binding), classes, `Date` / `RegExp`, direct `eval` seeing the
caller's locals, weak semantics for `WeakMap` / `WeakSet`, and the
remaining builtins. The collector is stop-the-world and
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
