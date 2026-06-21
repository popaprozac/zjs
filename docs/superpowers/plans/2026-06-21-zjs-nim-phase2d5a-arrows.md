# ZJS-Nim Phase 2d-5a (arrow functions, identifier params) Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Arrow functions `x => e`, `(a, b) => e`, `() => {}`, `async x => e`, curried `a => b => c` — byte-for-byte vs `build/zjs parse`. IDENTIFIER/default/rest params only; PATTERN params (`({a}) =>`) → 2d-5c (destructuring).

**Branch:** `nim-phase2`. **Reference:** `src/parser.zc` `parse_arrow_single` (~2851), `parse_arrow_paren` (~2882), `lookahead_arrow_paren` (~2909), arrow detection in `parse_assignment` (~3199), `parse_arrow_body`.

## Design
New variant branch (`nim/src/zjs/ast.nim`):
```nim
of ArrowFunc:
  arrowBody*: AstNode          # Zen-c left (BlockStmt or expression)
  arrowParams*: seq[AstNode]   # Zen-c children
  arrowIsAsync*: bool          # not dumped
```
Constructor `newArrow(s, e, body, params, isAsync)`. `ArrowFunc` is in `nk_label` → real label. Dumper (body FIRST, then params — like FunctionDecl):
```nim
of ArrowFunc:
  stdout.write(&"{ind}{label}\n")
  dumpAst(n.arrowBody, src, depth+1)
  for prm in n.arrowParams: dumpAst(prm, src, depth+1)
```

## Parser
**`lookaheadArrowParen(p): bool`** — port: from `p.pos`, track paren depth; at the `)` that returns depth to 0, return `p.toks[i+1].kind == Arrow`; false on Eof.

**Arrow detection** — at the TOP of `parseAssignmentExpr` (BEFORE the yield check and `parseConditional`):
```nim
# single-ident arrow:  x => ...
if p.peek().kind == Identifier and p.toks[p.pos+1].kind == Arrow:
  return parseArrowSingle(p, false)
# paren arrow:  (a, b) => ...
if p.peek().kind == LParen and lookaheadArrowParen(p):
  return parseArrowParen(p, false)
# async arrows
if p.peek().kind == KwAsync:
  if p.toks[p.pos+1].kind == Identifier and p.toks[p.pos+2].kind == Arrow:
    discard p.advance()                 # 'async'
    return parseArrowSingle(p, true)
  if p.toks[p.pos+1].kind == LParen:
    let saved = p.pos
    discard p.advance()                 # tentatively consume 'async'
    if lookaheadArrowParen(p): return parseArrowParen(p, true)
    p.pos = saved                       # not an arrow — rewind ('async' was an identifier/call)
```

**`parseArrowSingle(p, isAsync)`**: `nameTok = advance` (the ident); `advance` (`=>`); `param = newLeaf(IdentExpr, nameTok.start, nameTok.start+nameTok.length)`; `body = parseArrowBody(p, isAsync)`; `newArrow(nameTok.start, body.`end`, body, @[param], isAsync)`.

**`parseArrowParen(p, isAsync)`**: `lp = advance` (`(`); `params = parseParamList(p)`; `expect(RParen)`; `expect(Arrow)`; `body = parseArrowBody(p, isAsync)`; `newArrow(lp.start, body.`end`, body, params, isAsync)`.

**`parseArrowBody(p, isAsync): AstNode`**: if `isAsync` save+set `p.inAsync = true` around the parse, restore after (so `async x => await x` works; leave inGenerator unchanged). Body: if `peek == LBrace` → `parseBlock(p)`; else `parseAssignmentExpr(p)` (expression body).

(`parseParamList` already handles ident/default/rest; a pattern param `{`/`[` makes it break — those tests are NOT in this battery.)

## Verified trees
`x => x + 1`→ArrowFunc/{Binary, IdentExpr x}; `(a, b) => a`→ArrowFunc/{IdentExpr a, IdentExpr a, IdentExpr b}; `() => {}`→ArrowFunc/{BlockStmt}; `(a) => { return a; }`→ArrowFunc/{BlockStmt{ReturnStmt}, IdentExpr a}; `async x => x`→ArrowFunc/{x, x}; `a => b => c`→ArrowFunc/{ArrowFunc/{c, b}, a}.

## Task 1 (single task)
**Files:** `ast.nim`, `nim_parse.nim`, `parser.nim`, `tparser.nim`.
- [ ] tests (suite "parser arrows") + impl (ArrowFunc branch + ctor + dumper; lookaheadArrowParen; detection in parseAssignmentExpr; parseArrowSingle/Paren/Body).
- [ ] CLEAN rebuild (`rm -f build/nim/nim-parse && make nim-parse`) then differential battery (verified trees + `(a = 1) => a`, `(...r) => r`, `x => ({a: 1})` (paren-wrapped object body), `f(x => x)`, `[a => a, b => b]`, `async () => await x`, `(a, b, c) => a + b + c`). All OK.
- [ ] CRITICAL no-regression — `(a, b)` WITHOUT `=>` must stay a Paren/Sequence; `(a)` stays Paren; `async` alone stays IdentExpr; `async(x)` stays a Call. Sweep: `(a, b)`, `(a)`, `(1 + 2) * 3`, `async`, `async(x)`, `f(a, b)`, `a ? b : c`.
- [ ] commit `nim: parser — arrow functions, identifier params (phase 2d-5a)`.

## Done criteria
Battery byte-clean; non-arrow parens/sequence/async-call not regressed; 0 regressions. Next: 2d-5b (destructuring assignment + bindings), 2d-5c (pattern params).
