# zjs Phase 3.1c — Throw / Try / Catch + Real test262 Signal

> Adds JavaScript's exception machinery and uses it to turn the
> test262 harness from a "didn't crash" check into a real spec-
> conformance dashboard. Assertions can now actually fail.

## Scope

In scope:
- AST: `ThrowStmt`, `TryStmt`
- Parser: `throw <expr>;` and `try { ... } catch (id) { ... }` (no `finally` for MVP)
- Bytecode opcodes:
  - `Throw src` — raise `regs[src]` as an exception
  - `EnterTry catch_reg, offset` — push a try frame; on throw, jump to `ip + offset` and place the thrown value in `regs[catch_reg]`
  - `LeaveTry` — pop the innermost try frame (normal exit from a try block)
- Interpreter:
  - Per-function try-frame stack (32-deep, plenty for any reasonable nesting)
  - `is_throw` propagation up the call chain via `InterpretResult { is_throw, value }`
  - `Invoke` propagates throws from nested calls
- Context:
  - `last_error: ZjsValue` and `had_error: bool` set by `zjs_eval` on uncaught throw
  - Public C ABI: `zjs_had_error(ctx)` + `zjs_get_error(ctx)`
- test262 runner:
  - Prepends a tiny assert harness to each test (`assert.sameValue`, `assert.notSameValue`, `assert.throws`, `$ERROR`)
  - Distinguishes "test passed" (no uncaught throw) from "test failed" (uncaught throw)
  - Reports real pass/fail counts

Out of scope (Phase 3.1d / 3.1e):
- **`finally`** — adds a second target per try frame; deferred
- **Error / TypeError / SyntaxError objects** — `throw "string"` works; `throw new Error("msg")` requires the `Error` constructor + prototype chain
- **`error.message` / `error.stack`** — needs proper Error objects
- **Atom interning of property names** — Phase 3.1d (helps the hidden-class path)
- **Real mark-sweep GC** — Phase 3.1d
- **`for-in` / `for-of` execution** — separate concern; deferred

## Throw propagation model

The interpreter switches from returning `ZjsValue` to returning
`InterpretResult { is_throw: bool, value: ZjsValue }`:

- `Throw` sets a function-local `throwing` flag with the thrown value
- The dispatch loop checks `throwing` at the top of each iteration
- If `throwing` and the try-frame stack is non-empty: pop the innermost
  frame, jump to its catch handler, place the value in the catch register, clear `throwing`
- If `throwing` and the try-frame stack is empty: return `{is_throw: true, value}` to the caller
- The `Invoke` op handler checks the nested call's result; if it threw, set the current function's `throwing` state

This is the simplest correct unwinding model — no `longjmp`, no
exceptional control flow at the C level, just a status-return chain.

## Public C ABI changes

```c
// New: check whether the last zjs_eval call ended with an uncaught throw.
int      zjs_had_error(ZjsContext* ctx);

// New: read the value that was thrown (only meaningful when had_error is 1).
ZjsValue zjs_get_error(ZjsContext* ctx);
```

`zjs_eval` itself still returns `ZjsValue` — on uncaught throw, it
returns the thrown value (the caller disambiguates via `zjs_had_error`).

## test262 harness

A minimal harness is prepended to every test before evaluation:

```js
var assert = {};
assert.sameValue    = function (a, b) { if (a !== b) throw 'fail'; };
assert.notSameValue = function (a, b) { if (a === b) throw 'fail'; };
assert.throws       = function (_e, fn) { try { fn(); throw 'no-throw'; } catch (e) { } };
function $ERROR(m) { throw m; }
```

If a test produces no uncaught throw, it passes. If it does, it fails.
That's the real test262 signal — albeit on a thinner harness than
test262's `harness/assert.js`. We'll grow the harness as we add more
language features (NaN handling, deep equality, error type checking).

## Verification

```bash
zjs eval "try { throw 'oops' } catch (e) { e }"                => oops
zjs eval "try { let x = 1/0; x } catch (e) { 'caught: ' + e }" => Infinity   (Infinity isn't thrown)
zjs eval "function bad() { throw 42 } try { bad() } catch (e) { e + 1 }"  => 43
zjs eval "try { try { throw 1 } catch (e) { throw e + 10 } } catch (e) { e }" => 11
```

Plus a fresh test262 runner output that shows actual pass/fail per
spec subdirectory (replacing the "didn't crash" measure from Phase 3.0c).

## Files

- `src/ast.zc` — `ThrowStmt`, `TryStmt` variants
- `src/parser.zc` — `parse_throw`, `parse_try`; dispatch
- `src/bytecode.zc` — new opcodes
- `src/compiler.zc` — `ThrowStmt`/`TryStmt` codegen; catch param as local
- `src/interpreter.zc` — `InterpretResult`, try stack, unwinding, new handlers; `Invoke` propagates throws
- `src/context.zc` — `last_error` + `had_error` fields
- `src/eval.zc` — translates `InterpretResult` to the public surface
- `include/zjs.h` — `zjs_had_error`, `zjs_get_error`
- `tools/zjs.zc` — print uncaught-error message
- `tests/test262_runner.c` — preamble + real pass/fail counting
- `tests/interpreter_test.zc` — try/catch test cases
- `tests/embed_smoke.c` — exercise the new error-detection ABI

## What's next

- **3.1d** — Mark-sweep GC (replaces per-context allocation list); atom interning of property names
- **3.1e** — Built-in `Error` constructor and minimal prototype chain; broader test262 harness; pass-rate growth as language features land
