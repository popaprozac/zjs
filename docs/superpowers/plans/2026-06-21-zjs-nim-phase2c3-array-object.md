# ZJS-Nim Phase 2c-3 (array + object data literals) Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Array literals (elements, holes, spread) + object **data** literals (shorthand, `key: value`, computed `[k]: v`, string/number keys, spread), byte-for-byte vs `build/zjs parse`. Object **methods/getters/setters/async-gen** are DEFERRED (they need `FunctionExpr` from 2d).

**Branch:** `nim-phase2`. **Reference:** `src/parser.zc` `fn parse_array` (~4314), `fn parse_object` (~4375). Owner-approved design below.

## Design (Step-0, 2026-06-21)
New variant branches (`nim/src/zjs/ast.nim`):
```nim
of Array:  elems*: seq[AstNode]
of Object: props*: seq[AstNode]
of ObjectProp:
  keyStart*, keyLength*: uint32   # raw key slice (incl. quotes for strings); 0/0 = computed
  propVal*: AstNode               # Zen-c left (the value; for shorthand = IdentExpr of the key)
  computedKey*: AstNode           # Zen-c third (the `[expr]` key; nil unless computed)
```
`Spread` already exists (2c-1). `HoleExpr` needs NO branch — construct via `newLeaf(HoleExpr, s, s)` (nullary) and it dumps as `?` via the existing `else` branch.

Constructors: `newArray(s, e, elems)`, `newObject(s, e, props)`, `newObjectProp(s, e, keyStart, keyLength, propVal, computedKey)`.

Dumper (`nim/tools/nim_parse.nim`) — Array/Object/ObjectProp are in `nk_label` (real labels). VERIFIED child order: ObjectProp walks **propVal then computedKey** (Zen-c left then third):
```nim
of Array:
  stdout.write(&"{ind}{label}\n")
  for el in n.elems: dumpAst(el, src, depth+1)
of Object:
  stdout.write(&"{ind}{label}\n")
  for pr in n.props: dumpAst(pr, src, depth+1)
of ObjectProp:
  stdout.write(&"{ind}{label} name=\"{slice(src, n.keyStart, n.keyStart + n.keyLength)}\"\n")
  dumpAst(n.propVal, src, depth+1)
  if n.computedKey != nil: dumpAst(n.computedKey, src, depth+1)
```

## Parser (`nim/src/zjs/parser.nim`)
Wire into `parsePrimary`: `LBracket` → `parseArray(p)`, `LBrace` → `parseObject(p)`.
- `parseArray`: consume `[`; loop until `]`/`Eof`: if `peek==Comma` → `newLeaf(HoleExpr, peek.start, peek.start)`; elif `peek==Ellipsis` → consume, `newSpread(dots.start, inner.`end`, parseAssignmentExpr())`; else `parseAssignmentExpr()`. Append; if `peek==Comma` consume + continue, else break. Consume `]`; `newArray([.start, ].end, elems)`. Elements are no-comma (`parseAssignmentExpr`).
- `parseObject`: consume `{`; loop until `}`/`Eof`:
  - `Ellipsis` → `newSpread(...)`, append, comma-or-break.
  - `LBracket` (computed) → consume, `key = parseAssignmentExpr()`, expect `]`; expect `:`; `val = parseAssignmentExpr()`; `newObjectProp(.., 0, 0, val, key)`. (If after `]` the next is `(` it's a computed METHOD → out of scope; break.)
  - else key_tok = peek (Identifier / keyword used as name / StringLit / NumberLit):
    - next after key is `Colon` → `key:value`: consume key + `:`, `val = parseAssignmentExpr()`, `newObjectProp(.., key.start, key.length, val, nil)`.
    - next after key is `Comma`/`RBrace` → **shorthand**: consume key; `val = newLeaf(IdentExpr, key.start, key.start+key.length)`; `newObjectProp(.., key.start, key.length, val, nil)`.
    - next after key is `LParen`/`get`/`set`/`*`/async → METHOD/ACCESSOR → out of scope (needs functions); break.
  - append; if `peek==Comma` consume + continue, else break.
  - Consume `}`; `newObject({.start, }.end, props)`.

## Verified expected trees
`[1,2,3]`→Array{1,2,3}; `[1,,3]`→Array{1,?,3}; `[...a,b]`→Array{?{a},b}; `[]`→Array(empty); `({a:1,b:2})`→Paren/Object/{ObjectProp name="a"/{1}, ...}; `({a})`→ObjectProp name="a"/{IdentExpr a}; `({[k]:v})`→ObjectProp name=""/{IdentExpr v, IdentExpr k}; `({...x,y:1})`→Object/{?{x}, ObjectProp name="y"/{1}}; `({"s":1,5:2})`→ObjectProp name=""s""/{1}, name="5"/{2}.

## Task 1: AST branches + dumper
- [ ] tests (suite "ast 2c-3"): construct Array/Object/ObjectProp, check fields. FAIL→impl→PASS.
- [ ] `ast.nim` 3 branches + 3 constructors; `nim_parse.nim` 3 dumper branches. `make nim-parse` builds.
- [ ] commit `nim: AST + dumper — array/object/objectprop nodes (phase 2c-3)`.

## Task 2: parseArray + parseObject + wire parsePrimary
- [ ] tests (suite "parser array/object") for the verified trees. FAIL→impl.
- [ ] implement parseArray/parseObject; add LBracket/LBrace to parsePrimary.
- [ ] verify differential battery (above + `[a,[b,c]]`, `[,]`, `({})`, `({a, b, c})`, `[1, ...x, 2]`, `({a: [1,2], b: {c: 3}})`) all OK; no-regression sweep; nim-diffparse counts.
- [ ] commit `nim: parser — array + object data literals (phase 2c-3)`.

## Done criteria
Differential battery byte-clean; 0 regressions; nested literals work. Methods/accessors deferred to post-2d.

Next: 2c-4 (assignment + arrows + destructuring).
