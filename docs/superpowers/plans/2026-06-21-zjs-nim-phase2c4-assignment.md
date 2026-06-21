# ZJS-Nim Phase 2c-4 (plain assignment) Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Assignment expressions with simple targets (`a = b`, `a.b = c`, `a[i] = b`) and all 16 compound operators, right-associative, byte-for-byte vs `build/zjs parse`. The `Assignment` AST node + dumper already exist (built in 2b) — this is a PURE parser change.

**SEQUENCING NOTE (autonomous adjustment 2026-06-21):** The owner's original 2c-4 was "assignment + arrows + destructuring." Reading `parse_assignment` showed **arrows depend on block-body/statement parsing (2d)** and **destructuring depends on `reinterpret_as_pattern` + ArrayPattern/ObjectPattern/PatternEntry**. So this slice is scoped to **plain assignment only**; arrows + destructuring are deferred to a post-2d slice (they reuse 2d's param/block/pattern infrastructure). `yield` (needs generator context) also deferred.

**Branch:** `nim-phase2`. **Reference:** `src/parser.zc` `fn parse_assignment` (~3153) + `fn is_assignment_op` (~3259).

## Design
No AST/dumper changes (Assignment exists; dumper prints `op=tkLabel(assignOp)` + target + value). Parser only:
- Add `isAssignmentOp(k): bool` — true for: Eq, PlusEq, MinusEq, StarEq, StarStarEq, SlashEq, PercentEq, LtLtEq, GtGtEq, GtGtGtEq, AmpEq, PipeEq, CaretEq, AmpAmpEq, PipePipeEq, QuestionQuestionEq (16).
- Change `parseAssignmentExpr` from `= parseConditional(p)` to:
```nim
proc parseAssignmentExpr(p: var Parser): AstNode =
  let left = parseConditional(p)
  if left == nil: return nil
  if isAssignmentOp(p.peek().kind):
    let op = p.advance()
    let right = parseAssignmentExpr(p)   # right-assoc
    if right == nil: return nil
    return newAssignment(left.start, right.`end`, op.kind, left, right)
  return left
```
(`newAssignment(s, e, op, target, value)` already exists.) For plain targets (Ident/Member/Computed) `target = left` directly — Zen-c's `reinterpret_as_pattern` only triggers for Array/Object LHS, which is the deferred destructuring case.

## Verified expected trees
`a = b`→Assignment Eq{a,b}; `a.b = c`→Assignment{Member,c}; `a[i] = b`→Assignment{Computed,b}; `a += b`→PlusEq; `x **= 2`→StarStarEq; `a = b = c`→right-assoc nested; `a ||= b`→PipePipeEq; `a ??= c`→QuestionQuestionEq; `a &&= b ||= c`→right-assoc. (`[a,b]=c` → ArrayPattern = DEFERRED, excluded from battery.)

## Task 1 (single task)
**Files:** Modify `parser.nim`, `tparser.nim`.
- [ ] tests (suite "parser assignment"): `a = b`, `a.b = c`, `a = b = c` right-assoc, `a += b`. FAIL→impl.
- [ ] implement `isAssignmentOp` + the `parseAssignmentExpr` change.
- [ ] differential battery: `'a = b' 'a.b = c' 'a[i] = b' 'a += b' 'x **= 2' 'a = b = c' 'a ||= b' 'a ??= c' 'obj.x = y' 'a &&= b ||= c' 'a = b ? c : d' 'x = y = z = 0' 'a.b.c = d' 'f().x = 1' 'arr[i][j] = v'` all OK; no-regression sweep; nim-diffparse counts.
- [ ] commit `nim: parser — plain assignment expressions (phase 2c-4)`.

## Done criteria
Battery byte-clean; 0 regressions; the long-standing "out-of-scope assignment" DIFFs from 2c-1..2c-3 now resolve. Destructuring-assignment + arrows deferred to post-2d.

Next: 2c-5 (templates).
