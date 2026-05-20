# zjs Phase 4.4 — Private class fields + methods (`#name`)

> Adds ECMA-262 private class members — fields, methods, static
> fields, static methods — under the `#name` syntax. Previously the
> entire feature family was in `skip_features` (~3,600 tests skipped
> behind `class-fields-private` + `class-methods-private` +
> `class-static-fields-private` + `class-static-methods-private`).

## Approach

Compile-time mangling. Each class declaration is assigned a fresh
id from `ctx.class_id_counter`; `#x` inside that class compiles to
the hidden key `__zjs_priv_<id>_x`. The `__zjs_` prefix is already
filtered out of `Object.keys` / `getOwnPropertyNames` / `for-in` /
`JSON.stringify` via `string_is_hidden_key`, so private members
stay invisible to reflection.

Different classes get different ids — `#x` in `A` and `#x` in `B`
never collide; a subclass can't see its superclass's mangled name
(lookup uses the lexical id, not the receiver's class).

## What it required

- **Lexer**: new `TokenKind::PrivateName` covering `#identifier` as
  a single token (no whitespace between `#` and the name body).
- **Parser**: `parse_method_body_pair` accepts PrivateName at the
  class-member name position. `static`, `async`, and `get`/`set`
  lookaheads also accept PrivateName as the following token. The
  name slice preserves the leading `#` so the compiler can sniff
  it. Member access (`this.#x`, `obj.#x`) already takes the next
  token after `.` as the name; PrivateName slots in transparently.
- **Compiler**: `Compiler.enclosing_class_id` propagated to child
  compilers (methods inherit their enclosing class's id).
  `mangle_private_name` returns NULL and sets `had_error` if
  `enclosing_class_id < 0` — matches the spec's SyntaxError for
  `#x` outside a class body.
- Five mangle sites: `intern_method_name_atom`, `compile_member`,
  `compile_property_target`, `compile_assignment_to_property`,
  `compile_call_inner`'s MethodInvoke path, and the static-field
  install loop.

## Results

| | Tests | |
|---|---|---|
| Baseline (post Phase 4.3) | 6,751 / 7,997 = 84.4% | — |
| After unmask + impl | 7,922 / 10,085 = 78.6% | +1,171 |
| After method-call + parser fixes | 8,218 / 10,085 = 81.5% | +296 more |

**Cumulative +1,467 tests passing.** The rate dropped because the
denominator grew by 2,088 (the previously-skipped
private-features tests now run).

Perf flat: richards 122.96 ms (was 123.92), splay 154.53 ms, fib
121.36 ms — all within noise.

## Known follow-ups (not in this phase)

Remaining class failures cluster in `statements/class` (486) +
`expressions/class` (300) — spec edge cases around:

- **`#x in obj` brand check** — currently a parse error. Spec
  allows `#x` as the LHS of `in` for instance-of-class checks.
- **TypeError on missing private slot** — `obj.#x` where obj lacks
  `#x` should throw, not return undefined.
- **Private methods stored per-instance, not prototype** — our
  mangle puts them on prototype, which works for same-class access
  but doesn't enforce spec brand semantics.

Tractable follow-ups but not in this commit; the storage approach
above accepts the trade-off.

## Status

Done; merged. The 4 `class-*-private` features removed from
`scripts/test262/config.json`'s skip_features.
