# zjs Phase 4.3 — Symbol property semantics

> Symbol primitives shipped earlier (TAG_SYMBOL, well-known symbols,
> Symbol.for / keyFor); this phase cleans up the semantics around
> Symbol-keyed property access, Symbol-aware coercion, and the
> reflection surface (`Object.getOwnPropertySymbols`).

## What changed

### Filter `@@`-prefixed shim keys from enumeration

zjs stores Symbol-keyed properties under a canonical string key —
`@@sym:N` for user-created Symbols, `@@iterator` etc. for
well-known. Before this phase those keys leaked through every
enumeration path:

```js
let obj = { a: 1 };
obj[Symbol('s')] = 2;
Object.keys(obj);                 // ["a", "@@sym:1"]  ← spec violation
Object.getOwnPropertyNames(obj);  // ["a", "@@sym:1"]
JSON.stringify(obj);              // '{"a":1,"@@sym:1":2}'
for (let k in obj) ...            // emits "@@sym:1"
```

Added `string_is_hidden_key` covering both the `@@` shim prefix and
the existing `__zjs_*` engine-internal prefix, plumbed through five
filter sites (`host_object_keys` array + object paths,
`host_object_get_own_property_names` for functions, the
`iter_prepare` for-in walker, and `json_stringify_value`'s object
emit). JSON.stringify had no hidden-key filter at all previously
— `__zjs_*` keys would also have leaked if they'd ended up on a
user object.

### `Object.getOwnPropertySymbols`

Returns the Symbol-valued own keys of an object. Implementation
walks both cell pools (young + old — generational scaffolding
splits storage, naive walk of just `ctx.cells` missed all live
nursery Symbols, hence the dedicated `lookup_symbol_by_key`
helper) and matches against each `@@`-prefixed key on the object's
hidden-class chain.

Known limitation, documented inline: a Symbol referenced only via
a property key (the user dropped their local binding to it) can
be GC'd before this function is called — the canonical key string
on the host object doesn't pin the Symbol cell. Fixing this
requires a Symbol-keyed property bucket separate from the
string-keyed slots — a larger refactor not scoped here.

### `Symbol.toPrimitive` dispatch in `zjs_to_primitive`

Before falling through to the valueOf / toString dance (ECMA-262
§7.1.1 step 4), look up the well-known `@@toPrimitive` key. If
callable, invoke with the hint string (`"string"` for
prefer_string, `"default"` otherwise). Symbol-returning-object
throws TypeError per spec.

Unlocks the addition + equals coercion-by-toprim test cluster.

### JSON.stringify treats Symbol values like undefined

Per ECMA-262 §25.5.2.2: skipped at object-property emit, returned-
as-undefined at top level. Previously emitted `"null"` for
Symbol-valued properties / top-level Symbol.

## Results

| Step | Tests | Δ |
|---|---|---|
| Baseline | 6,711 / 7,997 = 83.9% | — |
| `@@` enumeration filter | 6,741 / 7,997 = 84.3% | +30 |
| `Object.getOwnPropertySymbols` | 6,741 / 7,997 = 84.3% | 0 (unblocks future) |
| `Symbol.toPrimitive` dispatch | 6,750 / 7,997 = 84.4% | +9 |
| `JSON.stringify` Symbol skip | 6,751 / 7,997 = 84.4% | +1 |

Cumulative +40 tests on the curated subset.

## Status

Done; merged.
