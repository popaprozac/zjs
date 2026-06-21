# ZJS-Nim Phase 2c-2 (conditional `?:` + sequence `,`) Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Add the ternary conditional (`a ? b : c`) and the comma/sequence operator (`a, b, c`) to the Nim parser, byte-for-byte against `build/zjs parse`. These slot in at the TOP of the operator ladder (above nullish).

**Branch:** `nim-phase2`. **Reference:** `src/parser.zc` `fn parse_conditional` (~3280), `fn parse_expression` sequence path (~2935). Owner-approved Step-0 design below.

## Design (owner-approved 2026-06-21)
New variant branches in `nim/src/zjs/ast.nim`:
```nim
of Conditional:
  cond*, conseq*, alt*: AstNode   # Zen-c left=test, right=consequent, third=alternate
of Sequence:
  items*: seq[AstNode]            # Zen-c children
```
Constructors: `newConditional(s, e, cond, conseq, alt)`, `newSequence(s, e, items)`.

Dumper (`nim/tools/nim_parse.nim`) — both are label-only + child walk (both are in `nk_label` → real labels "Conditional"/"Sequence"):
```nim
of Conditional:
  stdout.write(&"{ind}{label}\n")
  dumpAst(n.cond, src, depth+1); dumpAst(n.conseq, src, depth+1); dumpAst(n.alt, src, depth+1)
of Sequence:
  stdout.write(&"{ind}{label}\n")
  for it in n.items: dumpAst(it, src, depth+1)
```

Parser wiring (`nim/src/zjs/parser.nim`) — insert two levels, re-point two entries:
- `parseConditional(p)`: `cond = parseNullish(p)`; if `peek().kind != Question` return cond; advance `?`; `conseq = parseAssignmentExpr(p)`; expect `:`; `alt = parseAssignmentExpr(p)`; `newConditional(cond.start, alt.`end`, cond, conseq, alt)`. (Right-assoc falls out: alt → parseAssignmentExpr → parseConditional.)
- `parseSequence(p)`: `first = parseAssignmentExpr(p)`; if `peek().kind != Comma` return first; `items = @[first]`; while `peek().kind == Comma`: advance, `items.add(parseAssignmentExpr(p))`; `newSequence(first.start, items[^1].`end`, items)`.
- Change `parseAssignmentExpr` from `= parseNullish(p)` to `= parseConditional(p)`.
- Change `parseExpression` from `= parseNullish(p)` to `= parseSequence(p)`.

This keeps args (parseAssignmentExpr → conditional, no comma) and computed-index (parseExpression → sequence) correct: `a[b, c]` becomes `Computed` with a `Sequence` index.

## Verified expected trees
`a ? b : c` → Conditional{a,b,c}; `a ? b : c ? d : e` → right-assoc (alt is nested Conditional); `a, b, c` → Sequence{a,b,c}; `a ? b : c, d` → Sequence{Conditional, d}; `a[b, c]` → Computed{a, Sequence{b,c}}; `f(a, b ? c : d)` → Call with a Conditional arg.

## Task 1 (single combined task)
**Files:** Modify `ast.nim`, `nim_parse.nim`, `parser.nim`, `tparser.nim`.
- [ ] Failing tests (suite "parser conditional/sequence"): assert shapes for `a?b:c`, nested right-assoc, `a,b,c`. Run → FAIL.
- [ ] Implement the 2 branches + 2 constructors + 2 dumper branches + the 4 parser changes.
- [ ] Verify: unit tests pass; differential battery `'a ? b : c' 'a ? b : c ? d : e' 'a, b, c' 'a ? b : c, d' 'f(a, b ? c : d)' 'a[b, c]' 'a, b ? c : d, e'` all OK; no-regression sweep over 2b+2c-1 batteries; `make nim-diffparse` counts.
- [ ] Commit: `nim: parser — conditional + sequence (phase 2c-2)`.

## Done criteria
- Differential battery byte-clean; 0 regressions; `a[b,c]` now yields a Sequence index.

Next: 2c-3 (array + object literals).
