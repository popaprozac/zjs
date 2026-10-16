# zjs Phase 3.4 — for-in / for-of

> The parser already produces `ForInStmt` and `ForOfStmt` nodes. This
> phase lowers them to bytecode by desugaring to a standard
> index-walked loop over a prepared iterable array.

## Scope

- New opcodes:
  - **`IterPrepare a=dst, b=src, c=kind`** — normalizes the iterable
    into an array of items the compiler can walk with `LoadElem`.
    `kind = 0` (for-in) collects own enumerable string keys; `kind = 1`
    (for-of) collects element values. Snapshots the source so mid-loop
    mutation doesn't affect iteration.
  - **`ArrayLength a=dst, b=src`** — fast direct read of `arr.length`,
    bypassing the `property_get` "length"-string memcmp.

- Compile path for `ForInStmt` / `ForOfStmt`:
  ```
  iter = IterPrepare(src, kind)
  len  = ArrayLength(iter)
  one  = 1
  i    = 0
  loop_top:
    if !(i < len) goto loop_end
    elem = iter[i]
    <binding> = elem        // VarDecl declarator OR bare ident
    <body>
    i = i + one
    goto loop_top
  loop_end:
  ```
  `c.fixed_regs` is bumped to cover the loop-state slots so
  `reset_temps` between body statements doesn't clobber them.

- Bindings supported:
  - `for (let v of …)` — VarDecl with one declarator (the typical case)
  - `for (v of …)` — bare `IdentExpr` referring to an existing local,
    captured outer local, or global. Mirrors the Assignment resolution
    chain.

## Iteration semantics

- **for-of on Array** — yields `arr[0]`, `arr[1]`, ... over a snapshot
  taken at loop start. Adding to the source array during iteration
  does not extend the loop (matches ECMA-262 ArrayIterator semantics
  for most practical purposes; we just snapshot up front instead of
  re-reading length each step).
- **for-of on String** — yields each char as a 1-character string. No
  surrogate-pair handling yet.
- **for-of on anything else** — zero iterations (real JS would throw
  `TypeError`; MVP is permissive).
- **for-in on Object** — yields own property names in insertion order
  (walks the hidden-class chain bottom-up, same logic as `Object.keys`).
- **for-in on anything else** — zero iterations.

## Out of scope

- `break` / `continue` — neither for-in/of nor the existing `ForStmt`
  supports them yet (`compile_stmt` errors on `BreakStmt` /
  `ContinueStmt`). A follow-up phase will add jump labels + a
  loop-context stack.
- Real ECMA-262 iterator protocol (`Symbol.iterator`, `.next()`,
  `.return()`). When generators / iterables become user-defined
  we'll need this; for now Array / String are the only useful for-of
  shapes anyway.
- for-in over arrays — real JS exposes numeric-string indices
  ("0", "1", …) plus any inherited enumerable property names. We
  return zero iterations; deviation, but tracking it would require
  the prototype chain (Phase 3.6).
- Destructuring patterns as bindings (`for (let [a, b] of …)`).
- Multi-declarator bindings (`for (let a = 1, b of …)` — illegal anyway).

## Verification

```bash
zjs eval "let s=0; for (let v of [1,2,3,4]) { s = s + v }; s"              # 10
zjs eval "let n=0; for (let k in {a:1,b:2,c:3}) { n = n + 1 }; n"          # 3
zjs eval "let keys=''; for (let k in {a:1,b:2,c:3}) { keys = keys + k }; keys"  # "abc"
zjs eval "let r=''; for (let c of 'hi') { r = r + c }; r"                  # "hi"
zjs eval "function f(xs){ let s=0; for (let x of xs) s = s + x; return s } f([10,20,30])"  # 60
```

12 new tests cover for-of on arrays/strings, for-in on objects, bare
ident bindings, nested loops, snapshot-on-start semantics, empty
iteration, and for-in's zero-result behavior on non-objects.

## What's next

- **3.6 — prototype chain + `instanceof`.** Replaces the array/string
  prototype intercept with general `cls.proto` walking. Also makes
  for-in on arrays inherit numeric indices "for free" — though that
  path is still a deviation worth thinking through.
- **3.7 — class syntax.**
- **break / continue** in loops (rolling up the existing `ForStmt`
  too).
