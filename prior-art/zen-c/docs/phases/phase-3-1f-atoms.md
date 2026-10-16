# zjs Phase 3.1f — Atom Interning

> Foundation for hidden classes + inline caches (Phase 3.2). Dedupes
> property name strings on the context: any two identical-content
> atoms are the same `ZjsString*`. Pointer-compare replaces
> byte-compare on the property-lookup hot path.

## Scope

In scope:
- Atom table on `ZjsContext`: open-addressed hash table mapping bytes → `ZjsString*`
- FNV-1a string hash (32-bit) for the table
- Two intern helpers:
  - `ctx_intern_atom(ctx, data, len) -> ZjsString*` — copies the bytes
  - `ctx_intern_atom_take(ctx, data, len) -> ZjsString*` — adopts an already-malloc'd buffer, freeing it on dedup hit
- Atoms are GC roots. Once interned, an atom lives for the context's lifetime. (For property names and string literals this is the right shape; truly transient strings — ToString results, concat outputs — stay non-atom and remain GC-able.)
- Compiler routes through atoms for:
  - **Property names in `Member`/`Computed`** (`obj.foo` interns "foo")
  - **Object-literal keys** (`{foo: 1}` interns "foo")
  - **String literals in source** (`"hello"` interns "hello")
- Built-in setup (`Error`, `Math.*`) uses `ctx_intern_atom` for every property name string

What stays non-atom (and therefore stays GC-able):
- `zjs_to_string` results — numeric → string conversions are unique-ish, often transient
- `zjs_string_concat` results — could be anything, usually one-shot
- Anything the host runtime might generate dynamically later

Out of scope:
- **Hidden classes** — that's Phase 3.2a, which builds on this
- **Inline caches** — Phase 3.2b
- **Symbol interning / GlobalSymbolRegistry** — different problem
- **Removing dead atoms** — atoms are permanent for now. If a context accumulates many dynamically-generated atom strings this could leak; not a concern for our current allocation patterns.

## Why this comes before hidden classes

The hot path for property access today is:

```
LoadElem dst, obj, key_reg
  → lookup name string vs obj's prop list (byte-compare each)
```

With atoms, the same access becomes:

```
LoadElem dst, obj, key_reg
  → pointer-compare each prop name against the key string (early-exit)
  → byte-compare only if pointers differ (won't happen for atom-vs-atom)
```

Hidden classes layer on top of this — each transition is keyed on `(SymbolID, ...)`. SymbolID is "the atom that names this property." Without atoms, you can't have stable per-name identity, and hidden classes degenerate into per-byte-string comparisons.

## Hash table

Open-addressed (linear probing), power-of-2 sizes, growth at 70% load factor. Initial cap 16. FNV-1a 32-bit hash:

```
hash = 2166136261
for each byte:
    hash = hash XOR byte
    hash = hash * 16777619
```

Probing on collision: `i = (i + 1) & mask`. Tombstones are unnecessary because we never delete atoms.

## GC interaction

`gc_mark_roots` walks `ctx.atoms[]` and marks every entry's `ZjsString*`. That keeps interned strings alive across collections. The cells list still holds the same atom pointers; sweep skips them because they're marked.

## Verification

Both observable through `zjs_eval`:

```bash
# Without interning each "x" was a separate cell. With interning,
# both literals refer to the same ZjsString*, but the user can't
# directly observe that — they can observe === between strings,
# which already worked via byte-compare. Cell count is the
# observable difference.
```

A direct test: allocate two object literals using the same property name, count cells before and after. With interning the count grows by one fewer string per name.

```c
ZjsContext* ctx = zjs_new_context();
unsigned a = zjs_cell_count(ctx);
zjs_eval(ctx, "let o1 = {foo: 1, bar: 2}");
unsigned b = zjs_cell_count(ctx);
zjs_eval(ctx, "let o2 = {foo: 3, bar: 4}");
unsigned c = zjs_cell_count(ctx);
/* (c - b) == 1 (the o2 object) — name strings already interned */
```

Plus the full existing test suite continues to pass — atom interning is purely additive.

## What's next

Phase 3.2a — hidden classes. Each object carries a `HiddenClass*`. Properties transition by `(atom, flags)`. The first big perf payoff from the jitless-first design study.
