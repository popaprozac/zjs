# ZJS-Nim Phase 2d-4 (object methods + accessors) Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Object-literal methods `{ m() {} }`, getters/setters `{ get x(){} }`, generator/async methods `{ *g(){} }` / `{ async a(){} }`, and computed-key methods `{ [k]() {} }` — byte-for-byte vs `build/zjs parse`. Deferred from 2c-3 (needed FunctionExpr, now available).

**Branch:** `nim-phase2`. **Reference:** `src/parser.zc` `parse_object` accessor/method block (~4409–4720).

## Design — PURE parser change (no AST/dumper changes)
Each method is an `ObjectProp` whose `propVal` is a `FunctionExpr`. The existing `ObjectProp` dumper (walks `propVal` then `computedKey`) and `FunctionExpr` dumper already render this. VERIFIED:
- `{ m() {} }` → ObjectProp name="m" / FunctionExpr (anonymous) / BlockStmt
- `{ get x(){} }` → ObjectProp name="x" / FunctionExpr **name="x"** / BlockStmt   (accessor names its FunctionExpr with the prop)
- `{ set x(v){} }` → ObjectProp name="x" / FunctionExpr name="x" / BlockStmt, IdentExpr v
- `{ *gen(){} }` → ObjectProp name="gen" / FunctionExpr (anonymous, generator) / BlockStmt{...}
- `{ async af(){} }` → ObjectProp name="af" / FunctionExpr (anonymous, async)
- `{ [k]() {} }` → ObjectProp name="" / FunctionExpr (anonymous) / BlockStmt, then computedKey IdentExpr k

So: regular/gen/async method → FunctionExpr ANONYMOUS (name 0/0); get/set accessor → FunctionExpr NAMED with the property name. (The get/set accessor-kind itself is not dumped — skip storing it.)

## Parser — extend `parseObject` (`nim/src/zjs/parser.nim`)
Inside the property loop, BEFORE the existing computed/key/shorthand handling, add method detection. Port `parse_object`'s logic:
1. **async prefix**: if `peek().kind == KwAsync` AND the token after is a property-name-start (`Identifier`/keyword/`StringLit`/`NumberLit`/`LBracket`/`Star`) → `omAsync = true`, consume `async`.
2. **generator `*`**: if `peek().kind == Star` → `omGen = true`, consume.
3. **computed key** `[expr]`: (existing) — but after `]`, if next is `(` it's a computed METHOD: params + body → anonymous FunctionExpr; ObjectProp(name 0/0, propVal=fn, computedKey=key). If next is `:` it's a computed data prop (existing).
4. Otherwise read the key token (Identifier/keyword-name/StringLit/NumberLit).
   - **accessor**: if the key is the identifier `get` or `set` (length 3) AND the NEXT token is a property-name (Identifier/keyword/StringLit/NumberLit/`[`) → it's an accessor. Consume `get`/`set`; the real name = next token (or `[computed]`); `expect(LParen)`; params; `expect(RParen)`; body=parseBlock (scope gen/async = false); build `FunctionExpr(name = realName (or 0/0 if computed), params, body)`; `ObjectProp(key = realName or computed, propVal = fn, computedKey = (the [..] key or nil))`.
   - else consume the key; then:
     - if next is `(` → **method**: `expect(LParen)`... actually consume `(` via params flow; params=parseParamList; `expect(RParen)`; body=parseBlock (scope inGenerator=omGen, inAsync=omAsync around the body); `FunctionExpr(ANONYMOUS 0/0, params, body, isAsync=omAsync, isGenerator=omGen)`; `ObjectProp(key, propVal=fn, computedKey=nil)`.
     - if next is `:` → data property (existing).
     - if next is `Comma`/`RBrace` → shorthand (existing).
5. Append; comma-or-break (existing).

Method/accessor body context: save/set/restore `inGenerator`/`inAsync` around `parseBlock` (methods get fresh context; accessors are never gen/async so false/false).

NOTE: reuse `parseParamList`, `parseBlock`, `newFunctionExpr`, `newObjectProp`, `isKeywordName`. Build the FunctionExpr span = realName/keyStart .. body.`end` (match Zen-c; the dump doesn't show spans here so approximate is fine, but use the method-name start).

## Verified battery
`({m(){}})`, `({m(a,b){return a;}})`, `({get x(){return 1;}})`, `({set x(v){}})`, `({*gen(){yield 1;}})`, `({async af(){await x;}})`, `({[k](){}})`, `({"str"(){}, 5(){}})`, `({a, m(){}, b: 2})`, `({get [k](){}})`, `({ m() {}, get x() {}, set x(v) {} })`.

## Task 1 (single task)
**Files:** `parser.nim`, `tparser.nim`.
- [ ] tests (suite "parser obj methods") + extend parseObject. FAIL→impl.
- [ ] differential battery (above) all OK; no-regression sweep (data-object literals `({a:1})`, `({a})`, `({[k]:v})`, `({...x})` must still work!); nim-diffparse.
- [ ] commit `nim: parser — object methods + accessors (phase 2d-4)`.

## Done criteria
Battery byte-clean; data-object literals not regressed; 0 regressions. Next: arrows + destructuring, then classes, then modules.
