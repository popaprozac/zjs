# TDZ implementation plan (#330)

zjs currently implements **no** Temporal Dead Zone: `let`/`const`/default
params are hoisted-and-initialized-to-`undefined` like `var`. Reads before
initialization should throw `ReferenceError`. ~52 test262 failures are
"expected a ReferenceError, none thrown" (class 30, for-of 17, for-in 5),
plus the async default-param set surfaced by #329.

## Mechanism

Bindings subject to TDZ start as a **hole** (`zjs_deleted` sentinel,
already used for array elision + `this`-before-super). A read of a hole
throws `ReferenceError`. The init step overwrites the hole with the real
value (or `undefined` for `let x;`).

Perf (jitless mandate): emit the runtime check ONLY where a read can
precede init. Reads the compiler proves are post-init in straight-line
order use plain loads — so the dominant `let x = ...; use x` pattern pays
nothing.

## Stages (each builds + test262 no-regression + commit)

1. **Interpreter primitive + non-captured register lexicals.**
   - `Op::ThrowIfHole` (a=reg): if `regs[a]` is the hole, throw
     ReferenceError "Cannot access lexical binding before initialization".
   - Mark `let`/`const` locals `is_tdz`; add per-local `initialized` flag
     in the compiler.
   - At the binding's lexical-scope entry, `LoadHole` into its register.
   - IdentExpr read of an `is_tdz` local that isn't proven `initialized`
     → emit `ThrowIfHole` before the borrow/Mov. Declaration init sets
     `initialized = true` (straight-line; reset conservatively at the
     scope level).
   - Target: `let`/`const` read-before-decl, `const c = c`.

2. **Default-parameter TDZ** (the originally-requested #330 slice).
   - Params with defaults hole-init in the default-eval prologue; a
     default initializer referencing a not-yet-initialized param (self or
     later) hits `ThrowIfHole`. `(a, b=a)` ref-earlier stays valid.

3. **Captured (env-slot) lexicals.**
   - Captured `let`/`const` live as env props; today a missing prop reads
     `undefined` (deliberately, see compiler.zc VarDecl comment). Needs
     env slots seeded with the hole + checked env reads. Bigger blast
     radius — do last, behind its own validation.

4. **Sweep + perf gate.**
   - Full test262; confirm the ~52 cluster drops. Run `try_overhead` /
     `closure_call` / `property_mono` benches to confirm the hot path is
     unaffected (checks only on unproven reads).

## Notes
- test262 only checks the error TYPE (ReferenceError), not the message —
  a generic message is fine.
- `typeof x` where x is in TDZ must STILL throw (not return "undefined")
  — unlike `typeof undeclaredGlobal`. Verify the typeof path.
- Keep `var` and function-scope hoisting unchanged.
