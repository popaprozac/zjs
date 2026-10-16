# zjs Phase 3.8 — Strictness + Coverage

> Three sub-phases focused on making the engine honest about what it
> can and can't do. test262 conformance went from a misleading 92.6%
> (where many failed compiles were silently counted as passes) to a
> honest 59.5% baseline that tracks the actual feature gap.

## 3.8a — break / continue + console.log

Loop control flow + a minimal console.

- `break` / `continue` work in `while`, `do-while`, `for`,
  `for-in`, `for-of`. Compile-time loop-context stack tracks the
  current loop's continue target and break-patch list.
- `ContinueStmt` emits a placeholder when the target isn't known yet
  (for-style loops where `continue` jumps past the body to the
  update step) and patches once `loop_set_continue` is called.
- `console.log` / `info` write to stdout (space-separated args,
  newline), `console.warn` / `error` to stderr. Arrays/objects use
  the JSON walker; functions print as `[function]`.

## 3.8b — Parser strictness + previously-silent compile gaps

Two intertwined fixes that drove the conformance baseline correction:

1. **Surface parse/compile failures as JS-visible throws.**
   `zjs_eval` used to return undefined silently when the parser or
   compiler errored. That inflated test262 pass rates — any test
   whose source we couldn't compile got marked "ran, didn't throw"
   = pass. Now we build a `{ name: "SyntaxError", message }` object
   and set `ctx.had_error` so the public ABI sees it.

2. **Actual strictness:**
   - declarations (`let`, `const`, `function`, `class`) are rejected
     as the non-block body of `if`/`while`/`do-while`/`for`/`for-in`/
     `for-of`. `var` is still permitted (legacy form).
   - `return` outside any function body is rejected. Parser tracks
     `function_depth`, bumped around function/arrow/method bodies.
   - `this` on the LHS of assignment was already rejected by the
     compiler; now correctly surfaces.

Several compile gaps had to be filled to keep the positive-test side
up:

- **Conditional expressions** (`c ? a : b`) — never had a compile
  path; was silently a `had_error` before. Now jumps + Mov pattern.
- **`void`** operator.
- **Postfix and prefix `++` / `--`** on identifier targets. Helper
  `compile_inc_dec` handles local / captured-local / outer-captured /
  global storage uniformly.
- **Number-coercion globals**: `isNaN`, `isFinite`, `parseInt`
  (handles `0x` prefix when no radix, leading whitespace),
  `parseFloat`. Fall back to NaN on no parse.
- **Numeric constants**: `NaN`, `Infinity`, `undefined`.

## 3.8c — Array constructor, Object.prototype, ReferenceError, error subtypes

The big batch.

### Built-in surface
- `Array()` / `new Array()` / `Array(N)` / `Array(a,b,c)`.
- `Array.isArray(x)`.
- `Boolean(x)` / `Number(x)` / `String(x)` coercion ctors. `Number`
  drives a real ToNumber including string parsing (whitespace trim
  + strtod; empty/all-whitespace → 0).
- `ReferenceError` / `TypeError` / `RangeError` / `SyntaxError` /
  `URIError` / `EvalError` constructors. `make_named_error`
  decorates `ctx.host_this` when invoked via `new`, so the new
  object's proto stays = `Ctor.prototype` and `e instanceof TypeError`
  works.
- `Object.prototype` is now a real object on `ctx.object_proto`,
  populated with `hasOwnProperty` and `toString`. Every `{}` from
  `ctx_new_object` inherits from it. `array_proto` / `string_proto`
  also chain to `object_proto`, so `arr.hasOwnProperty(0)` walks
  correctly.
- `HostFunction.props: ZjsObject*` (lazy) — lets us attach
  `Array.isArray` directly on the `Array` host function via the
  normal property machinery.

### Reference semantics
- `GlobalEntry.defined: bool` — `false` until a write (DefineGlobal /
  StoreGlobal / pre-init) populates the slot.
- `Op::LoadGlobal` throws `ReferenceError` if `!defined`.
- `Op::LoadGlobalOrUndefined` — `typeof`'s no-throw variant. The
  compiler routes `typeof IdentExpr` through this opcode when the
  operand resolves to a global.
- Top-level VarDecl / FunctionDecl / ClassDecl names are
  pre-declared at compile time (set `defined = true` on their
  global slots) so var-hoisting works for the common cases.

### Stubs
- `Function`, `Date`, `RegExp`, `Symbol`, `Map`, `Set`, `WeakMap`,
  `WeakSet`, `Promise`, `Proxy`, typed-array constructors,
  `BigInt`, `eval`, `$262` — all registered as no-op host functions
  (or empty objects) so tests that touch the names without
  depending on the feature don't blow up with `ReferenceError`.

### Build helpers
- `build_typed_error` / `build_syntax_error` / `build_reference_error`
  / `build_type_error` moved from `eval.zc` into `context.zc` so
  the interpreter (which throws ReferenceError mid-execution) can
  use them too.

## Conformance trajectory

(Curated test262 subset, ~4144 tests; "skipped" = feature filter.)

| Phase | Passed | Failed | Skipped | Rate |
|---|---:|---:|---:|---:|
| Pre-3.8b baseline             | 2420 | 193  | 1531 | 92.6% (misleading) |
| After 3.8b (parse SyntaxError)|  193 | 2420 | 1531 |  7.4% (harness break) |
| Local minimal harness         | 1370 | 1243 | 1531 | 52.4% |
| + Conditional + void + ++/-- + globals | 1566 | 1047 | 1531 | 59.9% |
| + ReferenceError (no hoist)   | 1015 | 1598 | 1531 | 38.8% |
| + hoist top-level decls       | 1031 | 1582 | 1531 | 39.5% |
| + stub globals (Date/Regexp/Symbol/...) | 1513 | 1100 | 1531 | 57.9% |
| **3.8c final**                | **1555** | **1058** | **1531** | **59.5%** |

The drop from 92.6% to 59.5% is honest: the old number counted many
silently-failed compiles as passes. The 59.5% reflects what the
engine genuinely handles end-to-end against test262's positive tests
+ our minimal harness. Trajectory from here is upward through real
feature work.

## What's next (the actual gap)

- **`Function.prototype.call` / `bind`** — biggest unlock. Used
  pervasively by test262's built-in-method tests, and would let us
  switch back to the real test262 harness (which depends on `.call`).
- **`arguments` object** inside functions — ~36 tests.
- **Property descriptors** (`Object.defineProperty`, `Object.create`'s
  second arg) — ~50 tests in `Object/create`, `Object/keys`.
- **Wrapper objects**: `new Number(x)`, `new Boolean(x)`,
  `new String(x)`. Today we return primitives.
- **Switch statement** — unlocks the real test262 harness.
- **Destructuring + rest/spread** — modern JS patterns.
- **Labeled statements** (`label: while(...) { break label; }`) —
  ~30 tests.
- **`delete` operator** — used in a few try-block tests.
- **Real `eval`** — long way off; deliberately stubbed.

The HTML report at `docs/conformance/index.html` shows the running
history and lists the first 200 failures with reason. That's the
queue for the next round of work.
