# ZJS-Nim Phase 2d-1 (core control-flow statements) Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Block, if/else, while, do-while, C-style for, return, throw, break, continue, empty, labeled statements — byte-for-byte vs `build/zjs parse`. (for-in/of, switch, try, with → 2d-2; functions → 2d-3.)

**Branch:** `nim-phase2`. **Reference:** `src/parser.zc` `fn parse_statement` (~459, the dispatch), `parse_block` (~541), `parse_if` (~1200), `parse_return` (~1226), `parse_while` (~1253), `parse_do_while` (~1288), `parse_for` (~1306, C-style path only), `parse_break` (~1480), `parse_continue` (~1505), `parse_throw` (~1527).

## Design (Step-0, verified against oracle)
New variant branches (`nim/src/zjs/ast.nim`) — qualified field names (Nim global-unique rule):
```nim
of BlockStmt:    stmtList*: seq[AstNode]
of IfStmt:       ifCond*, thenStmt*, elseStmt*: AstNode   # elseStmt nil if no else
of WhileStmt:    whileCond*, whileBody*: AstNode
of DoWhileStmt:  doBody*, doCond*: AstNode                # Zen-c left=body, right=cond
of ForStmt:      forInit*, forTest*, forUpdate*, forBody*: AstNode  # init/test/update may be nil
of ReturnStmt:   retArg*: AstNode                         # nil for bare return
of ThrowStmt:    throwArg*: AstNode
of LabeledStmt:  labelStart*, labelLen*: uint32; labeled*: AstNode
```
`BreakStmt`/`ContinueStmt`/`EmptyStmt` need NO branch — nullary via `newLeaf(kind, s, e)`. Constructors: `newBlock`, `newIf`, `newWhile`, `newDoWhile`, `newFor`, `newReturn`, `newThrow`, `newLabeled`.

Labels: `BlockStmt/IfStmt/WhileStmt/DoWhileStmt/ForStmt/ReturnStmt/BreakStmt/ContinueStmt/EmptyStmt` are in `nk_label` → real labels. `ThrowStmt/LabeledStmt` are NOT → dump `?` (nkLabel already returns "?" for them — no nkLabel change).

Dumper (`nim/tools/nim_parse.nim`) — child walk reproduces Zen-c left→right→third→children, SKIPPING nil slots:
```nim
of BlockStmt:
  stdout.write(&"{ind}{label}\n");  for s in n.stmtList: dumpAst(s, src, depth+1)
of IfStmt:
  stdout.write(&"{ind}{label}\n")
  dumpAst(n.ifCond, src, depth+1); dumpAst(n.thenStmt, src, depth+1)
  if n.elseStmt != nil: dumpAst(n.elseStmt, src, depth+1)
of WhileStmt:
  stdout.write(&"{ind}{label}\n"); dumpAst(n.whileCond, src, depth+1); dumpAst(n.whileBody, src, depth+1)
of DoWhileStmt:
  stdout.write(&"{ind}{label}\n"); dumpAst(n.doBody, src, depth+1); dumpAst(n.doCond, src, depth+1)
of ForStmt:
  stdout.write(&"{ind}{label}\n")
  if n.forInit != nil: dumpAst(n.forInit, src, depth+1)
  if n.forTest != nil: dumpAst(n.forTest, src, depth+1)
  if n.forUpdate != nil: dumpAst(n.forUpdate, src, depth+1)
  dumpAst(n.forBody, src, depth+1)
of ReturnStmt:
  stdout.write(&"{ind}{label}\n");  if n.retArg != nil: dumpAst(n.retArg, src, depth+1)
of ThrowStmt:
  stdout.write(&"{ind}{label}\n"); dumpAst(n.throwArg, src, depth+1)
of LabeledStmt:
  stdout.write(&"{ind}{label}\n"); dumpAst(n.labeled, src, depth+1)
```

## Parser (`nim/src/zjs/parser.nim`) — extend `parseStatement` dispatch
On leading token: `LBrace`→parseBlock; `KwIf`→parseIf; `KwWhile`→parseWhile; `KwDo`→parseDoWhile; `KwFor`→parseFor; `KwReturn`→parseReturn; `KwBreak`→parseBreak; `KwContinue`→parseContinue; `KwThrow`→parseThrow; `Semicolon`→EmptyStmt (newLeaf, consume `;`); `Identifier`+next `Colon`→labeled; else existing var-decl / expression-statement path.
- `parseBlock`: consume `{`; loop `parseStatement` until `}`/Eof; consume `}`; `newBlock([.start, }.end, stmts)`.
- `parseIf`: `if`, `(`, cond=parseExpression, `)`, then=parseStatement; if `else` then else=parseStatement (dangling-else binds nearest); `newIf`.
- `parseWhile`: `while`, `(`, cond, `)`, body=parseStatement; `newWhile`.
- `parseDoWhile`: `do`, body=parseStatement, `while`, `(`, cond, `)`, opt `;`; `newDoWhile(body, cond)`.
- `parseFor` (C-STYLE ONLY): `for`, `(`; init = (if `;`→nil; elif KwVar/Let/Const→parseVarDecl WITHOUT consuming `;`; else parseExpression); expect `;`; test = (if `;`→nil else parseExpression); expect `;`; update = (if `)`→nil else parseExpression); expect `)`; body=parseStatement; `newFor`. (If after init the next token is `KwIn`/`KwOf`, that's for-in/of → 2d-2, NOT in this battery — fine to leave unhandled.)
- `parseReturn`: `return`; arg = (if next is `Semicolon`/`RBrace`/`Eof`→nil else parseExpression); opt `;`; `newReturn`. (NOTE: Zen-c errors on top-level return [function_depth==0]; we don't track that yet, so top-level return builds a node — a known error-reporting-gap divergence, tested properly in 2d-3.)
- `parseThrow`: `throw`, arg=parseExpression, opt `;`; `newThrow`.
- `parseBreak`/`parseContinue`: consume `break`/`continue`; if next is `Identifier` (same line — skip ASI nuance for now) consume it (label target, discarded — dump doesn't show it); opt `;`; `newLeaf(BreakStmt/ContinueStmt, ...)`.
- labeled: `id`, `:`, body=parseStatement; `newLabeled(id.start, body.end, id.start, id.length, body)`.
- Need a `parseVarDecl` variant that does NOT consume the trailing `;` for the for-init — the existing `parseVarDecl` consumes an optional `;`; add a `consumeSemi: bool` param (default true) and pass false from `parseFor`.

## Verified trees
`{let x=1;}`→BlockStmt/VarDecl; `if(a)b;else c;`→IfStmt/{a,b,c}; `if(a)if(b)c;else d;`→dangling-else inner; `while(a)b;`→WhileStmt/{a,b}; `do x;while(a);`→DoWhileStmt/{x,a}; `for(let i=0;i<n;i++)x;`→ForStmt/{VarDecl,Binary,Postfix,x}; `for(;;)x;`→ForStmt/{x}; `for(x;;z++)y;`→ForStmt/{x,z++,y}; `throw e;`→`?`/{e}; `break;`/`break foo;`→BreakStmt; `;`→EmptyStmt; `foo:bar;`→`?`/{bar}.

## Task 1: AST branches + dumper
- [ ] tests (suite "ast 2d-1"): construct each + check fields. FAIL→impl→PASS. `make nim-parse` builds.
- [ ] commit `nim: AST + dumper — core control-flow statement nodes (phase 2d-1)`.

## Task 2: statement parsers + dispatch
- [ ] tests (suite "parser control-flow") + differential battery (the verified trees + `{ { } }`, `if(a){b}else{c}`, `for(i=0;i<3;i=i+1){}`, `while(true){break;}`, `do{x}while(y)`, `outer: while(a) break outer;`). FAIL→impl.
- [ ] verify all OK; no-regression sweep over 2b/2c batteries; `make nim-diffparse` counts.
- [ ] commit `nim: parser — core control-flow statements (phase 2d-1)`.

## Done criteria
Battery byte-clean; 0 regressions. (return tested fully in 2d-3 with functions.) Next: 2d-2 (for-in/of, switch, try, with).
