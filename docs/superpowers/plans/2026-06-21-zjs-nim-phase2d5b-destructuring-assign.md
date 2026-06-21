# ZJS-Nim Phase 2d-5b (destructuring assignment) Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Destructuring ASSIGNMENT — `[a, b] = c`, `({x, y} = o)`, `[a, ...r] = x`, `({a = 1, b: c} = o)` — byte-for-byte vs `build/zjs parse`. Uses the cover-grammar `reinterpret_as_pattern` (the LHS is first parsed as an Array/Object literal, then reinterpreted when `=` follows). BINDING patterns (`let [a]=x`, pattern params, catch) → 2d-5c.

**Branch:** `nim-phase2`. **Reference:** `src/parser.zc` `reinterpret_as_pattern` (~2976), `reinterpret_assign_target`, and the assignment cover-grammar in `parse_assignment` (~3243).

## Design (Step-0, verified)
New variant branches (`nim/src/zjs/ast.nim`) — ArrayPattern/ObjectPattern/PatternEntry all dump `?`:
```nim
of ArrayPattern, ObjectPattern:
  patEntries*: seq[AstNode]            # PatternEntry children (Zen-c children)
of PatternEntry:
  patKeyStart*, patKeyLen*: uint32     # object source key (not dumped); 0/0 for array elem
  patTarget*: AstNode                  # Zen-c left  (binding target / nested pattern; nil for elision)
  patDefault*: AstNode                 # Zen-c right (default; nil if none)
  patComputedKey*: AstNode             # Zen-c third (computed key; nil)
  patIsRest*: bool                     # `...rest` (not dumped)
```
Constructors: `newPattern(kind, s, e, entries)` (kind ∈ {ArrayPattern, ObjectPattern}, `{.cast(uncheckedAssign).}`), `newPatternEntry(s, e, keyStart, keyLen, target, default, computedKey, isRest)`.

Dumper — child order target → default → computed (Zen-c left/right/third, skip nil):
```nim
of ArrayPattern, ObjectPattern:
  stdout.write(&"{ind}{label}\n")
  for en in n.patEntries: dumpAst(en, src, depth+1)
of PatternEntry:
  stdout.write(&"{ind}{label}\n")
  if n.patTarget != nil: dumpAst(n.patTarget, src, depth+1)
  if n.patDefault != nil: dumpAst(n.patDefault, src, depth+1)
  if n.patComputedKey != nil: dumpAst(n.patComputedKey, src, depth+1)
```

## Parser — reinterpret + wire into assignment
**`reinterpretAssignTarget(p, node): AstNode`**: if `node.kind in {Array, Object}` → `reinterpretAsPattern(p, node)`; if `node.kind == Paren` → `reinterpretAssignTarget(p, node.inner)`; if `node.kind in {IdentExpr, Member, OptionalMember, Computed, OptionalComputed}` → `node` (leaf target); else `node` (be permissive — no error-tracking; the oracle gates shape).

**`reinterpretAsPattern(p, node): AstNode`**:
- `Array` → `ArrayPattern` (span = node's), entries from `node.elems`, each:
  - `HoleExpr` (or nil) → `newPatternEntry(.., 0,0, nil, nil, nil, false)` (elision).
  - `Spread` → `newPatternEntry(.., 0,0, reinterpretAssignTarget(spreadArg), nil, nil, true)`.
  - `Assignment` with `assignOp == Eq` → `newPatternEntry(.., 0,0, reinterpretAssignTarget(target), value (default), nil, false)`.
  - else → `newPatternEntry(.., 0,0, reinterpretAssignTarget(elem), nil, nil, false)`.
- `Object` → `ObjectPattern`, entries from `node.props`, each:
  - `Spread` → `newPatternEntry(.., 0,0, reinterpretAssignTarget(spreadArg), nil, nil, true)`.
  - `ObjectProp` → key = prop.keyStart/keyLength, computed = prop.computedKey; then if `prop.propVal` is `Assignment(Eq)` → target=reinterpret(propVal.target), default=propVal.value; else target=reinterpret(propVal). `newPatternEntry(.., keyStart, keyLen, target, default, computedKey, false)`.
- `Paren` → `reinterpretAsPattern(p, node.inner)`.

**Wire** — in `parseAssignmentExpr`, where the assignment-op is handled: when `op.kind == Eq` AND `left.kind in {Array, Object}` → `let target = reinterpretAsPattern(p, left)` (else `target = left`); then `newAssignment(.., target, right)`. (Compound ops like `+=` do NOT destructure.)

## Verified trees
`[a, b] = c`→Assignment/{ArrayPattern{PatternEntry{a}, PatternEntry{b}}, c}; `({x, y} = o)`→Paren/Assignment/{ObjectPattern{PatternEntry{x}, PatternEntry{y}}, o}; `[a, ...r] = x`→Assignment/{ArrayPattern{PatternEntry{a}, PatternEntry{r}}, x}; `({a = 1, b: c} = o)`→Assignment/{ObjectPattern{PatternEntry{IdentExpr a, NumberExpr 1}, PatternEntry{IdentExpr c}}, o}; `[a, [b, c]] = x`→nested ArrayPattern; `[a.b, c[d]] = x`→PatternEntry targets are Member/Computed.

## Task 1: AST branches + dumper
- [ ] tests + impl (ArrayPattern/ObjectPattern/PatternEntry branches + ctors + dumper). `make nim-parse` builds. commit `nim: AST + dumper — destructuring pattern nodes (phase 2d-5b)`.

## Task 2: reinterpret + wire
- [ ] tests (suite "parser destructuring") + impl reinterpretAsPattern/reinterpretAssignTarget + wire into parseAssignmentExpr.
- [ ] CLEAN rebuild then differential battery (verified trees + `[,a] = x`, `[...a] = b`, `({...r} = o)`, `[a = 1, b = 2] = c`, `({a: [b, c]} = o)`, `({[k]: v} = o)`). All OK.
- [ ] no-regression: array/object LITERALS not as assignment targets must stay Array/Object (`[1,2,3]`, `({a:1})`, `f([a],{b})`); compound `+=` doesn't destructure.
- [ ] commit `nim: parser — destructuring assignment (phase 2d-5b)`.

## Done criteria
Battery byte-clean; literals-not-targets unaffected; 0 regressions. Next: 2d-5c (binding patterns: let/params/catch via parse_binding_target + Declarator.declPattern), then classes, then modules.
