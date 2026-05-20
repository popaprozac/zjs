# zjs Phase 4.5 — Async iteration (partial)

> Adds the `for await (x of expr)` statement and a stale-skip-list
> cleanup. Full async iterator protocol (`Symbol.asyncIterator`
> dispatch + async generators) is deferred — the larger arc.

## What landed

### `for await (let x of expr)` on sync iterables

Parser detects `await` between `for` and `(`, threads a flag through
`finish_for_in_or_of_ex`, marks the resulting ForOfStmt with
`bool_value=true`. Compiler emits `Op::Await` after each
`Op::IterStep` so:

- Sync iterable yielding non-Promise values: `Op::Await` is a
  pass-through (per ECMA-262 §7.5 Await on a non-Promise wraps in
  resolved Promise then unwraps, net identity).
- Sync iterable yielding Promises (the common test262 pattern):
  `Op::Await` unwraps each Promise before binding.

```js
async function run() {
  let total = 0;
  for await (let v of [Promise.resolve(1), Promise.resolve(2)]) {
    total += v;
  }
  return total;  // 3
}
```

`for await` outside an async function is a SyntaxError. `for await
(... in ...)` is also a SyntaxError (await is for-of only).

### Brand-check syntax `#x in obj`

Per ECMA-262, PrivateIdentifier is allowed as the LHS of `in` (and
only there). Parser detects the PrivateName + KwIn lookahead at the
head of `parse_relational`; emits a synthetic Member node with
left=NULL carrying the `#x` slice. Compiler detects this shape
inside the Binary KwIn handler and routes to `Op::In` with the
mangled key (`__zjs_priv_<class_id>_x`) as the lookup.

```js
class E { #x = 1; static has(o) { return #x in o; } }
E.has(new E());  // true
E.has({});       // false
```

### Stale skip-list cleanup

Removed skip_features entries for shipped features that were
never flipped: TypedArray, ArrayBuffer, DataView, Generator,
destructuring-assignment, optional-chaining, nullish-coalescing,
logical-assignment-operators, Array.prototype.flat / flatMap /
values, object-rest, object-spread, string-trimming, globalThis,
well-formed-json-stringify.

## What's NOT in this phase

- **`Symbol.asyncIterator` dispatch**: `for await` currently always
  uses `Op::IterGet` (which calls `@@iterator`). A real async
  iterable returns an iterator whose `.next()` returns Promises.
  Needs a separate `Op::IterGetAsync` that checks `@@asyncIterator`
  first.

- **Async generators (`async function*`)**: The parser parses them
  (marked num=5.0) but the compiler treats async-and-generator as
  async-only. Full impl needs the generator runtime + async wrapping
  combined. ~312 of the remaining class-private failures cluster on
  `async-private-gen-meth` — the largest single follow-up cluster.

## Results

| | Tests | |
|---|---|---|
| Baseline (post Phase 4.6) | 8,122 / 10,130 = 80.2% | — |
| for-await-of + unmask async-iteration | 8,416 / 11,771 = 71.5% | +294 (denom +1,641) |
| Stale-skip cleanup | 8,461 / 11,895 = 71.1% | +45 (denom +124) |
| `#x in obj` brand check | 8,465 / 11,895 = 71.2% | +4 |

**Cumulative +343 tests** vs. the start of this phase.

## Status

Partial. The structural surface (`for await` statement +
brand-check) is in place. Async generators + `@@asyncIterator`
dispatch are queued follow-ups.
