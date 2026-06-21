# ZJS-Nim Phase 2c-1 (member / call / new + optional chaining) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` checkboxes.

**Goal:** Extend the Nim parser with the **call/member postfix chain** — member access (`a.b`), computed (`a[b]`), calls (`f(x)`), `new`, and the optional-chain variants (`?.`, `?.()`, `?.[]`) — plus argument spread (`f(...x)`), validated **byte-for-byte** against `build/zjs parse`.

**Architecture:** This is increment 2c-1 of the Zen-c→Nim migration (see design doc `docs/superpowers/specs/2026-06-20-zjs-nim-migration-design.md`). It ports `fn parse_call_member` + `fn parse_arguments` from `src/parser.zc`. The chain slots in at the BOTTOM of the existing operator ladder: `parsePostfix`'s operand changes from `parsePrimary` to a new `parseCallMember`. Everything above (the operator ladder, var decls) already works and keeps working. The differential oracle gates every step.

**Tech Stack:** Nim 2.2.10, `build/zjs parse` (Zen-c reference), existing `nim/src/zjs/{token,lexer,ast,parser}.nim` + `nim/tools/nim_parse.nim`, `std/unittest`.

**Branch:** `nim-phase2` (continues from completed 2b).

**Reference:** `src/parser.zc` `fn parse_call_member` (~line 3601) + `fn parse_arguments` (~3780); `src/ast.zc` kind docs (Call/Member/Computed/New/Spread/etc.). Owner-approved Step-0 design recorded below.

---

## In-scope kinds + variant design (owner-approved 2026-06-21)

Three new `of` branches in `nim/src/zjs/ast.nim`. Field names are forced apart by Nim's **global-unique-field rule** (Member cannot reuse Declarator's `nameStart`):

```nim
of Member, OptionalMember, Computed, OptionalComputed:
  recv*: AstNode                  # receiver/object (Zen-c `left`)
  propStart*, propLength*: uint32 # Member/OptionalMember: property name slice
  index*: AstNode                 # Computed/OptionalComputed: `[expr]` index (nil for Member)
of Call, OptionalCall, New:
  callee*: AstNode                # Zen-c `left`
  args*: seq[AstNode]             # Zen-c `children`
of Spread:
  spreadArg*: AstNode             # `...expr` inner (Zen-c `left`)
```

Constructors:
- `newMember(kind, s, e, recv, propStart, propLength)` — kind ∈ {Member, OptionalMember}; `index` = nil.
- `newComputed(kind, s, e, recv, index)` — kind ∈ {Computed, OptionalComputed}; `propLength` = 0.
- `newCall(kind, s, e, callee, args)` — kind ∈ {Call, OptionalCall, New}.
- `newSpread(s, e, spreadArg)`.

(Runtime-discriminant constructors that span a multi-kind branch need `{.cast(uncheckedAssign).}`, same as `newBinary`/`newUnary`.)

## Dumper additions (`nim/tools/nim_parse.nim`)

Per the verified oracle (Member/OptionalMember use `name=`; the rest are label-only + child walk; Spread label is `?`):
```nim
of Member, OptionalMember:
  stdout.write(&"{ind}{label} name=\"{slice(src, n.propStart, n.propStart + n.propLength)}\"\n")
  dumpAst(n.recv, src, depth+1)
of Computed, OptionalComputed:
  stdout.write(&"{ind}{label}\n")
  dumpAst(n.recv, src, depth+1)
  dumpAst(n.index, src, depth+1)
of Call, OptionalCall, New:
  stdout.write(&"{ind}{label}\n")
  dumpAst(n.callee, src, depth+1)
  for a in n.args: dumpAst(a, src, depth+1)
of Spread:
  stdout.write(&"{ind}{label}\n")     # label = nkLabel(Spread) = "?"
  dumpAst(n.spreadArg, src, depth+1)
```
`Member/OptionalMember/Computed/OptionalComputed/Call/OptionalCall/New` are all in `nk_label` (real labels); `Spread` → `?`. Child-walk order reproduces Zen-c's uniform `left → right → third → children[]` (verified: Call = callee then args; Computed = recv then index).

## Structural addition — the no-comma expression entry

Introduce `parseAssignmentExpr(p): AstNode = parseNullish(p)` (placeholder; 2c-4 fills in real assignment, 2c-2 inserts conditional). Route **call/new arguments** through `parseAssignmentExpr` (no-comma). **Computed-index `[…]`** uses full `parseExpression` (matches Zen-c `parse_expression_in` — `a[b, c]` → Computed with a Sequence index once 2c-2 lands). This split prevents a footgun when `parseExpression` becomes comma-level in 2c-2.

## Deferred (guarded/skipped — NOT in this increment's battery)
- Tagged-template suffix (TemplateLit after an expr) → 2c-5.
- `super` member/call (needs class context) → 2d.
- `new.target` meta-property (small edge case) → later.
- `a.#priv` private-name members → 2d.
These don't appear in the 2c-1 battery, so the chain simply won't implement those suffix cases yet (a `TemplateLit`/`PrivateName` token terminates the suffix loop).

---

## Task 1: AST branches + constructors + dumper

**Files:** Modify `nim/src/zjs/ast.nim`, Modify `nim/tools/nim_parse.nim`, Modify `nim/tests/tparser.nim`.

- [ ] **Step 1: failing tests** — add a `suite "ast 2c-1 nodes"` constructing each new node via its constructor and checking `kind` + semantic fields (`recv`, `propStart`/`propLength`, `index`, `callee`, `args`, `spreadArg`).
- [ ] **Step 2: run, verify FAIL.**
- [ ] **Step 3: implement** the 3 `of` branches (above) in `ast.nim` + the 4 constructors. Move the new kinds OUT of the `else: discard` catch-all (they're already in the `NodeKind` enum). Then add the 4 dumper branches (above) to `nim_parse.nim`.
- [ ] **Step 4: run** `nim c -r --mm:arc --hints:off nim/tests/tparser.nim` (all suites PASS) and `make nim-parse` (builds clean).
- [ ] **Step 5: commit** — `nim: AST + dumper — call/member/spread nodes (phase 2c-1)`.

## Task 2: parse_call_member chain + arguments + rewire

**Files:** Modify `nim/src/zjs/parser.nim`, Modify `nim/tests/tparser.nim`.

- [ ] **Step 1: failing unit + differential tests** for: `a.b`, `a[b]`, `f(x, y)`, `new F(1)`, `a?.b`, `a?.[b]`, `a?.(x)`, `f(...x)`, `a.b.c(d)[e]`, `new a.b()`. Derive expected trees from `build/zjs parse`.
- [ ] **Step 2: run, verify FAIL.**
- [ ] **Step 3: implement** in `parser.nim`:
  - `parseAssignmentExpr(p): AstNode = parseNullish(p)` (forward-declared; the no-comma entry).
  - `parseArguments(p): seq[AstNode]` — port `parse_arguments`: consume `(`, loop args separated by `,` until `)`; each arg is `...`-spread (`newSpread(parseAssignmentExpr())`) or `parseAssignmentExpr()`. (Carry/return the end offset too, for the node span.)
  - `parseCallMember(p): AstNode` — port `parse_call_member`: handle leading `new` (member-only callee loop, then optional args → `New`); else operand = `parsePrimary`. Then the suffix loop: `.` → Member, `[` → Computed (index via `parseExpression`), `(` → Call, `?.` → OptionalMember / OptionalComputed / OptionalCall by lookahead. Build left-associatively, spans per Zen-c. Stop the loop on any other token (incl. `TemplateLit`/`PrivateName` — deferred).
  - Rewire `parsePostfix`'s operand from `parsePrimary(p)` to `parseCallMember(p)`.
- [ ] **Step 4: verify** — all unit tests pass; the differential battery above all `OK`; run a no-regression sweep over the 2b batteries (primaries/operators/decls); run `make nim-diffparse` and report the new pass/diff counts.
- [ ] **Step 5: commit** — `nim: parser — call/member chain + optional chaining (phase 2c-1)`.

---

## Done criteria
- `nim c -r nim/tests/tparser.nim` passes (all suites).
- The Task-2 differential battery is byte-clean against `build/zjs parse`.
- No regression on the 2b batteries.
- `delete a.b` now matches (member access unblocks it).

## STATUS: DONE (2026-06-21, commits 5118484 + e98a176)
- 43 unit tests pass; 29/29 VALID member/call/new/optional-chain inputs byte-clean
  (battery + adversarial: `a?.b?.c?.d`, `new a.b.c(d)`, `f(g(),h(...x),...y)`,
  `f(a,)`, `a?.[b][c]`, `a.b.c.d.e.f`, etc.). 0 regressions. nim-diffparse 5/8
  (the 3 diffs are out-of-scope: compound-assign, tagged template, private names).

## KNOWN DIVERGENCE — parser error reporting (NOT a 2c-1 bug; pre-existing since 2b)
`new new A()()` was the one adversarial DIFF: **Zen-c emits `zjs: parse error`**
(its `new`-callee uses `parse_primary`, which can't recurse into a nested `new`),
while our parser is permissive and emits a tree. Probing confirmed this is a
**systemic gap**: the Nim parser does NOT replicate Zen-c's parse-error behavior
at all — on malformed input (`a +`, `(`, `f(`, `)`, `let`, `@`) Zen-c prints
`zjs: parse error` while the Nim parser silently prints `Program`. (Note Zen-c's
error set is SPECIFIC — `1 2` and `a.` do NOT error there — so matching means
faithfully porting `p.had_error` at every parse site + the CLI's error path.)

This is a distinct, cross-cutting future increment (**"parser error reporting"**)
— it affects no valid program's parse tree, but it IS a prerequisite for the
eventual test262 **corpus** diff (negative tests) that gates the Phase-2→`nim`
merge. Scheduled after the remaining positive-input slices (2c-2…2c-5) OR before
the corpus gate, owner's call.

Next: 2c-2 (conditional `?:` + sequence `,`).
