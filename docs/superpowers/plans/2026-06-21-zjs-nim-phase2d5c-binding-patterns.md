# ZJS-Nim Phase 2d-5c (binding patterns: var-decl / params / catch) Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Destructuring BINDINGS — `let [a, b] = x`, `let {a: x, b = 2} = o`, `function f([a], {b})`, `({a}) => a`, `catch ([e])` — byte-for-byte vs `build/zjs parse`. Uses `parse_binding_target` (parses `{..}`/`[..]` DIRECTLY into ObjectPattern/ArrayPattern in binding context — the pattern nodes from 2d-5b are reused).

**Branch:** `nim-phase2`. **Reference:** `src/parser.zc` `parse_binding_target` (~909), `parse_object_pattern` (~926), `parse_array_pattern` (~1030); the pattern paths in `parse_var_decl` (~1101), `parse_param_list` (~1716), `parse_try` catch (~1627).

## Design (Step-0, verified) — add fields to 3 EXISTING branches
The pattern nodes (ArrayPattern/ObjectPattern/PatternEntry) exist (2d-5b). Add nilable fields to existing branches:
- **Declarator** branch: add `declPattern*: AstNode` (Zen-c third; the binding pattern; name="" / nameLength=0 when present).
- **IdentExpr** branch: add `identPattern*: AstNode` (Zen-c third; the pattern for a pattern-param — the IdentExpr's slice IS the pattern source, e.g. `"[a, b]"`).
- **TryStmt** branch: add `catchPattern*: AstNode` (Zen-c children[0]; pattern catch param).

Dumper updates:
- `Declarator`: after the `name="..."` line + `if init != nil` walk, ADD `if n.declPattern != nil: dumpAst(n.declPattern, ...)`. (Pattern declarators have empty name, so `name=""`.)
- `IdentExpr`: after the `"slice"` + `if identDefault != nil` walk, ADD `if n.identPattern != nil: dumpAst(n.identPattern, ...)`. (Order: identDefault then identPattern.)
- `TryStmt`: after the tryBlock/catchBlock/finallyBlock walk, ADD `if n.catchPattern != nil: dumpAst(n.catchPattern, ...)` LAST (Zen-c walks children[0] after left/right/third).

## Parser — `parseBindingTarget` + wire
**`parseBindingTarget(p): AstNode`** — `{` → `parseObjectPattern`; `[` → `parseArrayPattern`; else identifier → `newLeaf(IdentExpr, tok.start, tok.start+tok.length)` (consume).

**`parseObjectPattern(p)`** (port `parse_object_pattern`): `{`; loop until `}`: `...name` → rest PatternEntry (`patIsRest=true`, target=IdentExpr); `[expr]:` computed key; else key (property-name); optional `: target` (`target = parseBindingTarget`) else shorthand (target = IdentExpr of key); optional `= default`. Build `newPatternEntry(.., keyStart, keyLen, target, default, computedKey, false)`. `newPattern(ObjectPattern, ..., entries)`.

**`parseArrayPattern(p)`** (port `parse_array_pattern`): `[`; loop until `]`: `,` in element position → elision PatternEntry (target nil); `...` → rest PatternEntry (target=parseBindingTarget); else `target = parseBindingTarget`, optional `= default` → PatternEntry. `newPattern(ArrayPattern, ..., entries)`.

**Wire:**
- `parseVarDecl`: when the declarator binding starts with `[`/`{` → `pat = parseBindingTarget(p)`; build a `Declarator` with name="" (nameStart=0, nameLength=0), `declPattern = pat`; then optional `= init` sets `init`. (Declarator span = pat span, or init.end if init.) Build via `newDeclarator` then set `.declPattern = pat` (mutate the field), since `newDeclarator` doesn't take it.
- `parseParamList`: when a param starts with `[`/`{` → `pat = parseBindingTarget(p)`; `param = newLeaf(IdentExpr, pat.start, pat.`end`)`; `param.identPattern = pat`; optional `= default` → `param.identDefault = ...`. (The IdentExpr slice = pattern source.)
- `parseTry`: in the catch clause, when the `(` is followed by `[`/`{` → `catchPat = parseBindingTarget(p)`, store via `newTry(..)` then set `.catchPattern = catchPat` (or thread it in). Identifier catch param stays as before (catchParamStart/Len).

## Verified trees
`let [a, b] = x;`→Declarator name=""/{IdentExpr x, ArrayPattern{PatternEntry{a}, PatternEntry{b}}}; `let {a: x, b = 2} = o;`→ObjectPattern{PatternEntry{IdentExpr x}, PatternEntry{IdentExpr b, NumberExpr 2}}; `const [a, ...r] = x;`→ArrayPattern{PatternEntry{a}, PatternEntry{r}}; `function f([a, b]) {}`→FunctionDecl/{BlockStmt, IdentExpr "[a, b]"{ArrayPattern}}; `({a}) => a`→ArrowFunc/{IdentExpr a, IdentExpr "{a}"{ObjectPattern}}; `try{x}catch([e]){y}`→TryStmt/{BlockStmt x, BlockStmt y, ArrayPattern{PatternEntry{e}}}; `let [a, [b, c]] = x;`→nested ArrayPattern.

## Task 1: add fields + dumper
- [ ] tests + add `declPattern`/`identPattern`/`catchPattern` to the 3 branches + dumper updates. Verify existing Declarator/IdentExpr/TryStmt tests + full differential still pass. `make nim-parse` builds. commit `nim: AST + dumper — binding-pattern fields on Declarator/IdentExpr/TryStmt (phase 2d-5c)`.

## Task 2: parseBindingTarget + wire
- [ ] tests (suite "parser binding patterns") + impl parseBindingTarget/parseObjectPattern/parseArrayPattern + wire var-decl/params/catch.
- [ ] CLEAN rebuild then differential battery (verified trees + `let {a, b, c} = o;`, `function f({x: {y}}) {}`, `([a, b]) => a`, `let [, , c] = x;`, `({a: A, b: B} = ...)` is ASSIGNMENT not binding — keep 2d-5b path, `catch ({message}) {}`, `function f(a, [b], {c}) {}`). All OK.
- [ ] no-regression: identifier var-decls / params / catch unaffected; object/array LITERALS unaffected; 2d-5b destructuring-ASSIGNMENT unaffected.
- [ ] commit `nim: parser — binding patterns (var-decl/params/catch) (phase 2d-5c)`.

## Done criteria
Battery byte-clean; identifier bindings + literals + assignment-destructuring all unaffected; 0 regressions. This completes destructuring. Next: classes, then modules.
