# zjs Phase 3.0c — test262 Conformance Scaffolding

> Wires the TC39 test262 conformance suite into the build. The
> dashboard starts at near-zero meaningful conformance and grows
> automatically as Phase 3.1+ features (strings, throw, objects) land.

## Scope

In scope:
- A C harness (`tests/test262_runner.c`) that walks a test262 subtree, runs every `.js` file through `zjs_eval`, and tallies results
- A `make test262` target that builds the harness and runs it against `vendor/test262/test/language/expressions`
- Feature-blocklist scan: tests using unsupported constructs (`class`, `import`, template literals, `throw`, BigInt, regex) are skipped rather than counted as failures
- README instructions for cloning the test262 repo

Out of scope (Phase 3.1+):
- Loading test262's standard harness (`harness/assert.js`, `harness/sta.js`) — needs strings + throw + objects
- YAML frontmatter parsing for `negative:` (expected-throw) tests
- Per-test timeout / sandbox
- Async tests (`flags: async`)
- Parallel execution
- A real pass/fail dashboard tied to spec sections

## Why the initial pass rate is biased

The bulk of test262 tests look like:

```js
/*--- description: ... ---*/
assert.sameValue(1 + 1, 2);
```

Where `assert.sameValue` is defined in test262's `harness/assert.js`, which throws on mismatch. We have no throw mechanism yet, and `assert` doesn't exist as a global, so `assert.sameValue(1 + 1, 2)` evaluates as:

1. `LoadGlobal "assert"` → `undefined` (no such global)
2. `Member ".sameValue"` → not yet implemented; produces `undefined`
3. `Call (undefined, 2, 2)` → not a function; produces `undefined`
4. Program ends with `undefined` as the final value
5. Harness reports "pass" (no crash)

So our "pass count" is closer to "tests that didn't trigger a parser error or segfault." That's still a useful baseline — it goes up as we support more syntax and goes down only when we regress.

Real conformance signal arrives in Phase 3.1 once we have strings, throw, and object property access — at which point `assert.sameValue` either does its job or throws, and the harness gets a meaningful pass/fail.

## Architecture

```
vendor/test262/                  (gitignored; cloned separately)
  test/language/expressions/
    addition/
      *.js
    ...

tests/test262_runner.c           — C harness, walks dirs, runs tests in-process
Makefile :: test262              — builds + invokes the runner
```

In-process (not a per-test subprocess) for speed. Each test gets a fresh `ZjsContext` so global pollution doesn't bleed.

## Files

- `docs/phases/phase-3-0c-test262.md` — this doc
- `tests/test262_runner.c` — C harness
- `Makefile` — `test262` + `test262-runner` targets
- `.gitignore` — `vendor/`
- `README.md` — clone + run instructions

## Running

```bash
# One-time setup
mkdir -p vendor
git clone --depth 1 https://github.com/tc39/test262 vendor/test262

# Run against the default subset (expressions)
make test262

# Or target a specific subdir
./build/test262_runner vendor/test262/test/language/expressions/addition
```

## What's next

Phase 3.1 adds the features needed for real conformance signal:
- **Strings** — heap-allocated, refcounted (or via GC); enables `assert` message generation
- **Objects + property access** — enables `assert.sameValue(...)` to actually look up methods
- **Throw / try / catch** — enables assertion-based pass/fail
- **Arrays** — common in tests for iteration

Once those land, the test262 pass rate becomes a meaningful spec-conformance number, and the harness can be extended with frontmatter parsing and `negative:` test handling.
