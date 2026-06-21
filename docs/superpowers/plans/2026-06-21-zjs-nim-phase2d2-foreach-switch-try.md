# ZJS-Nim Phase 2d-2 (for-in/of, switch, try, with) Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** for-in / for-of (simple bindings), switch, try/catch/finally, with — byte-for-byte vs `build/zjs parse`. Pattern bindings in for-in/of heads and destructuring catch params are DEFERRED (need destructuring, post-2d).

**Branch:** `nim-phase2`. **Reference:** `src/parser.zc` `finish_for_in_or_of_ex` (~1402), `parse_switch` (~1541), `parse_try` (~1614), `parse_with` (~1270).

## Design (Step-0, verified)
New variant branches (`nim/src/zjs/ast.nim`):
```nim
of ForInStmt, ForOfStmt:
  forBinding*, forIterable*, forInOfBody*: AstNode    # Zen-c left=binding, right=iterable, children[0]=body
of SwitchStmt:
  switchDisc*: AstNode
  cases*: seq[AstNode]
of SwitchCase:
  caseTest*: AstNode                                  # nil for `default:`
  caseBody*: seq[AstNode]
of TryStmt:
  tryBlock*, catchBlock*, finallyBlock*: AstNode      # catch/finally nil if absent
  catchParamStart*, catchParamLen*: uint32            # identifier catch param (0/0 = none); not dumped
of WithStmt:
  withObj*, withBody*: AstNode
```
Constructors: `newForInOf(kind, s, e, binding, iterable, body)` (kind ∈ {ForInStmt, ForOfStmt}, uses `{.cast(uncheckedAssign).}`), `newSwitch(s, e, disc, cases)`, `newSwitchCase(s, e, test, body)`, `newTry(s, e, tryBlock, catchBlock, finallyBlock, catchParamStart, catchParamLen)`, `newWith(s, e, obj, body)`.

Labels: `ForInStmt`/`ForOfStmt` are in `nk_label` → real labels. `SwitchStmt`/`SwitchCase`/`TryStmt`/`WithStmt` → `?` (nkLabel already returns "?").

Dumper:
```nim
of ForInStmt, ForOfStmt:
  stdout.write(&"{ind}{label}\n")
  dumpAst(n.forBinding, src, depth+1); dumpAst(n.forIterable, src, depth+1); dumpAst(n.forInOfBody, src, depth+1)
of SwitchStmt:
  stdout.write(&"{ind}{label}\n")
  dumpAst(n.switchDisc, src, depth+1)
  for c in n.cases: dumpAst(c, src, depth+1)
of SwitchCase:
  stdout.write(&"{ind}{label}\n")
  if n.caseTest != nil: dumpAst(n.caseTest, src, depth+1)
  for st in n.caseBody: dumpAst(st, src, depth+1)
of TryStmt:
  stdout.write(&"{ind}{label}\n")
  dumpAst(n.tryBlock, src, depth+1)
  if n.catchBlock != nil: dumpAst(n.catchBlock, src, depth+1)
  if n.finallyBlock != nil: dumpAst(n.finallyBlock, src, depth+1)
of WithStmt:
  stdout.write(&"{ind}{label}\n")
  dumpAst(n.withObj, src, depth+1); dumpAst(n.withBody, src, depth+1)
```

## Parser — incl. the `noIn` flag (REQUIRED for for-in)
Add `noIn*: bool` to the `Parser` object (default false). Gate the relational `in`: in `parseRelational`, treat `KwIn` as an operator ONLY when `not p.noIn` (i.e. `if k == KwIn and p.noIn: break`). Reset `noIn = false` inside grouping in `parsePrimary`: when parsing `( … )`, `[ … ]`, `{ … }` save/restore `noIn` around the inner parse and set it false (so `for ((a in b);;)` / `for ([a in b];;)` work). 

`parseFor` (extend the existing C-style parser): set `noIn = true` (save/restore) while parsing the INIT only. After the init, branch:
- if `peek().kind in {KwIn, KwOf}`: finish-for-in/of — consume the `in`/`of`; iterable = (`KwOf` → `parseAssignmentExpr`; `KwIn` → `parseExpression`); expect `)`; body = `parseStatement`; `newForInOf(if KwOf: ForOfStmt else ForInStmt, kw.start, body.`end`, binding, iterable, body)`. (Binding = the init: an IdentExpr/Member for `for(x in o)`, or a VarDecl-no-semi for `for(let k of a)`. Pattern bindings `[a,b]` → DEFERRED.)
- else: existing C-style (`;` test `;` update `)` body).

`parseSwitch`: `switch (` disc `)` `{`; loop until `}`: `KwDefault` → test=nil; `KwCase` → test=`parseExpression`; expect `:`; body = loop `parseStatement` until next `KwCase`/`KwDefault`/`RBrace`/`Eof`; `newSwitchCase`. After cases, `}`; `newSwitch(disc, cases)`.

`parseTry`: `try`, `tryBlock = parseBlock`; if `KwCatch`: optional `( ident )` (for 2d-2: bare identifier or none — store its start/length; pattern catch param → DEFERRED), `catchBlock = parseBlock`; if `KwFinally`: `finallyBlock = parseBlock`; `newTry`. (At least one of catch/finally — but no error-tracking yet, so just build with whatever is present.)

`parseWith`: `with (` obj `)` body=`parseStatement`; `newWith`. (Zen-c errors in strict/module; we don't track strict, so just parse.)

Dispatch in `parseStatement`: `KwSwitch`→parseSwitch, `KwTry`→parseTry, `KwWith`→parseWith. (KwFor already dispatches to parseFor.)

## Verified trees
`for(x in obj)y;`→ForInStmt/{x,obj,y}; `for(let k of arr)z;`→ForOfStmt/{VarDecl,arr,z}; `switch(x){case 1:a;break;default:b;}`→`?`/{x, `?`/{1,a,BreakStmt}, `?`/{b}}; `try{a}catch(e){b}finally{c}`→`?`/{BlockStmt a, BlockStmt b, BlockStmt c}; `try{a}catch{b}`→`?`/{a,b}; `try{a}finally{c}`→`?`/{a,c}; `with(o)x;`→`?`/{o,x}.

## Task 1: AST branches + dumper
- [ ] tests (suite "ast 2d-2") + impl + `make nim-parse` builds. commit `nim: AST + dumper — for-in/of, switch, try, with nodes (phase 2d-2)`.

## Task 2: parsers + noIn flag
- [ ] tests + differential battery (verified trees + `for(k in o){x}`, `for(let v of [1,2,3]){f(v)}`, `switch(x){case 1:case 2:a;break;default:}`, `try{a}catch(e){throw e}`, nested try, `for((a in b);;)x`). FAIL→impl→verify all OK; no-regression sweep (esp. `a in b` still parses as Binary outside for-init!); nim-diffparse.
- [ ] commit `nim: parser — for-in/of, switch, try, with (phase 2d-2)`.

## Done criteria
Battery byte-clean; `a in b` (bare) still a Binary; 0 regressions. Pattern bindings / destructuring catch deferred. Next: 2d-3 (functions).
