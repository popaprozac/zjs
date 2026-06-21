# ZJS-Nim Phase 2c-5 (template literals + tagged templates) Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Template literals `` `a${x}b` `` and tagged templates `` tag`...` ``, byte-for-byte vs `build/zjs parse`. The lexer emits ONE `TemplateLit` token for the whole `` `...` ``; the parser re-scans the slice into alternating `TemplatePartExpr` (literal) + embedded-expression children. All three kinds (TemplateExpr/TemplatePartExpr/TaggedTemplate) dump as `?`.

**Branch:** `nim-phase2`. **Reference:** `src/parser.zc` `fn parse_template_lit` (~3843) + `fn parse_template_expr_slice` (~3982) + the `TemplateLit` suffix case in `fn parse_call_member` (~3720).

## Design (Step-0)
New variant branches (`nim/src/zjs/ast.nim`):
```nim
of TemplateExpr:   tparts*: seq[AstNode]    # alternating TemplatePartExpr / expr (N+1 parts, N exprs)
of TaggedTemplate: tag*: AstNode; tmpl*: AstNode   # Zen-c left=tag, right=TemplateExpr
```
`TemplatePartExpr` needs NO branch — slice-valued nullary, built via `newLeaf(TemplatePartExpr, s, e)`, dumps `?` via the existing `else`. Constructors: `newTemplateExpr(s, e, tparts)`, `newTaggedTemplate(s, e, tag, tmpl)`.

Dumper (all three are `?` — not in nk_label):
```nim
of TemplateExpr:
  stdout.write(&"{ind}{label}\n")
  for c in n.tparts: dumpAst(c, src, depth+1)
of TaggedTemplate:
  stdout.write(&"{ind}{label}\n")
  dumpAst(n.tag, src, depth+1)
  dumpAst(n.tmpl, src, depth+1)
```

## Parser
- `parseTemplateLit(p)` — port `parse_template_lit`'s char-scan (full algorithm in Task 2). bodyStart = tok.start+1, bodyEnd = tok.start+len-1 (strip backticks). Scan: skip `\x`; on `${` emit `TemplatePartExpr[segStart,cur)`, brace-balance to matching `}` (skipping strings + nested templates), parse the substitution via `parseTemplateExprSlice`, append; trailing `TemplatePartExpr[segStart,bodyEnd)`. Build `TemplateExpr(tok.start, tok.start+len, children)`.
- `parseTemplateExprSlice(p, exprStart, exprEnd)` — re-lex `source[exprStart..<exprEnd]`, shift token starts by `+exprStart` (absolute), parse as an **assignment expression** (`parseAssignmentExpr`) on a sub-Parser whose `source` = the full source:
```nim
proc parseTemplateExprSlice(p: var Parser, exprStart, exprEnd: uint32): AstNode =
  let sub = p.source[exprStart.int ..< exprEnd.int]
  var lx = initLexer(sub)
  var toks: seq[Token]
  for t in lx.tokens():
    var tt = t
    tt.start += exprStart       # shift to absolute
    toks.add(tt)
  var subP = Parser(source: p.source, toks: toks, pos: 0)
  parseAssignmentExpr(subP)
```
- Wire: `parsePrimary` `of TemplateLit: return parseTemplateLit(p)`. And in `parseCallMember`'s suffix loop add `TemplateLit` → `newTaggedTemplate(expr.start, tmpl.`end`, expr, parseTemplateLit(p))` (this was deferred in 2c-1).

## Verified expected dumps
`` `abc` ``→`?`/{`?`}; `` `a${x}b` ``→`?`/{`?`,IdentExpr x,`?`}; `` `${x}` ``→`?`/{`?`,x,`?`}; `` tag`hi ${a} there` ``→`?`/{IdentExpr tag, `?`/{`?`,a,`?`}}; `` `${a}${b}` ``→`?`/{`?`,a,`?`,b,`?`}.

## Task 1: AST branches + dumper
- [ ] tests (suite "ast 2c-5"): newTemplateExpr/newTaggedTemplate + newLeaf(TemplatePartExpr). FAIL→impl→PASS. `make nim-parse` builds.
- [ ] commit `nim: AST + dumper — template/tagged-template nodes (phase 2c-5)`.

## Task 2: parseTemplateLit + parseTemplateExprSlice + wire
- [ ] tests + differential battery (the verified dumps + `` `a${x + 1}b` ``, `` `${f(a)}` ``, `` `outer ${`inner ${x}`}` `` (nested), `` `a${ {x:1} }b` `` (object in subst), `` obj.m`x${y}` ``). FAIL→impl.
- [ ] verify all OK; no-regression sweep; `make nim-diffparse` (should reach 7-8/8).
- [ ] commit `nim: parser — template literals + tagged templates (phase 2c-5)`.

## Done criteria
Differential battery byte-clean incl. nested templates + object-in-substitution; 0 regressions. This completes 2c EXCEPT the deferred arrows + destructuring (post-2d).

Next: 2d (statements + functions).
