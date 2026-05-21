# zjs Phase 4.7 — Conformance push

> A multi-fix push following the Phase 4.4 / 4.5 / 4.6 feature arcs.
> Goal: chase the test262 cluster of failures that the feature work
> exposed but didn't address, plus unmask stale-skip features and
> harness includes. Net **+1,866 passing tests** in this phase alone.

## Wins, in order

### 1. TypedArray iteration via for-of (+16)

`iter_get` recognized arrays + strings + custom @@iterator objects
but not TypedArrays. Added a TAG_UINT8_ARRAY / TAG_TYPED_ARRAY
fast path that builds a TAG_ARRAY_ITER directly. `iter_step` gains
a matching branch that loads via `ta_load(ta, idx)`.

```js
for (let v of new Int32Array([1, 2, 3])) { ... }  // works
```

### 2. Static-method install on closure-wrapped ctor (+15)

When a class body captures outer scope (any inner method
references a name declared outside the class), the ctor is wrapped
in `MakeClosure`. `Op::DefineMethod` then stores static methods on
the closure's underlying `Function.props`. But `property_get` for
TAG_CLOSURE never looked at `cl.function.props` — it walked
Function.prototype directly. So `C.staticMethod` returned undefined
whenever the class body captured.

Added a `f.props` lookup at the head of the closure path. Silent
loss of static methods on capturing classes — fixed.

### 3. Async-generator method form `async *m()` (+1,137)

`parse_method_body_pair`'s async-prefix lookahead accepted
property-name-start tokens, LBracket, and PrivateName but not the
`*` of `async *method()`. So `async` was treated as the method
name and the generator-method install path silently dropped.

Single-token fix to add `Star` to the lookahead. The largest
single-commit unlock of the session — the structural pieces
(async-gen runtime, static-method closure install, generator
runtime) were all in place; the parser was just blocking entry.

### 4. `delete obj.#x` early SyntaxError (+32, +64 covered)

Per ECMA-262, private class members can't be deleted. Parser
rejects `delete <Member-with-private-name>` and the covered-
parenthesized form `delete (this.#x)` (walks through Paren wrappers
before the check).

### 5. Duplicate private-name detection (+28)

Spec early-error: ClassBody PrivateBoundNames must not contain
duplicates, EXCEPT a name used exactly once for a getter AND once
for a setter. Walk children, intern each private name's mangled
key, track attr bitmask (plain / get / set). Reject anything that
isn't exactly the get+set combo.

### 6. Inner compile-error propagation (+81)

`compile_class_value` called `compile_function` for each method
body. On failure (e.g. one of the new early-error checks fires
inside the method), it got NULL back and just skipped the install,
letting the outer program run as if nothing was wrong. Set
`c.had_error = true` and bail on NULL (mirrors what
`compile_function_value` already did for plain FunctionExpr).

### 7. `propertyHelper.js` unmask (+495)

The 1,983-test cluster gated on the propertyHelper include — used
to verify property descriptor attributes — was conservatively
skipped. The include parses + runs cleanly under zjs; we just had
it in `skip_includes` forever. Unmasking exposed many descriptor
edge cases we don't enforce (queued follow-ups), but +495 tests
that just needed the include to load now pass.

### 8. Class method `Function.name` (+14)

Per ECMA-262 §15.4.4, every MethodDefinition's function value has
`.name = PropName`. We were leaving it undefined. `compile_class_value`
now sets `mfn.props.name` after each method compile. Accessors get
`"get foo"` / `"set foo"` prefix per spec.

## Results

Conformance trajectory (passed / non-skipped):

| | Tests |
|---|---|
| Start of arc (Phase 4.6) | 8,122 / 10,130 = 80.2% |
| + TypedArray for-of | 8,481 / 11,895 |
| + static-closure | 8,496 / 11,895 |
| + async-gen-method form | 9,633 / 11,895 |
| + delete-#x | 9,665 / 11,895 |
| + covered-delete | 9,729 / 11,895 |
| + dup-private-name | 9,757 / 11,895 |
| + error-propagation | 9,838 / 11,895 |
| + propertyHelper unmask | 10,333 / 13,878 |
| + method.name | 10,347 / 13,878 = 74.6% |

**Total: +2,225 tests passing.** Cumulative session (Phase 4.3
start to here): **+3,636** (6,711 → 10,347).

## What's still on the floor

- **`for await (let x of asyncIter())` hangs** — `Op::IterStep`
  expects a sync iter-result; for an async generator's `.next()`
  it gets a Promise instead. Needs `Op::IterStepAsync` that awaits
  before extracting `value`/`done`. ~220 "async test never signaled
  completion" failures gate on this.

- **IteratorClose on abrupt completion** — when for-of throws /
  breaks / returns from the body, spec requires calling
  `iter.return()`. We don't. ~50-60 dstr + iter-close failures.

- **Property descriptor enforcement** — `Object.freeze` is a no-op
  for attr tracking, `[[Writable]] / [[Configurable]] / [[Enumerable]]`
  are partial. Many propertyHelper-driven failures cluster here.

- **Unicode-identifier escapes** (`\u{6F}`, `‍` ZWJ in
  identifiers, etc.) — ~30 parse-error failures.

- **`await` / `yield` as binding identifier in restricted contexts**
  — parser needs stricter rejection in async-gen-private-method
  bodies. ~80 expected-SyntaxError failures.

- **Async generators** — minimal runtime in place (`.next()` wraps
  iter-result in Promise) but spec semantics around `return` /
  `throw` calling and queueing aren't right. Cluster of edge cases.

## Status

Done; the structural pieces for the next push (real async
iteration, IteratorClose, property descriptors) are the queued
follow-up arcs.
