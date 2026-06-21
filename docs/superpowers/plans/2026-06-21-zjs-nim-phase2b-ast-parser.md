# ZJS-Nim Phase 2b (AST + Parser skeleton) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure-Nim AST model + recursive-descent parser skeleton that parses a meaningful expression/declaration subset into the same tree as the Zen-c parser — validated **byte-for-byte against `zjs parse`** (the parse-tree differential oracle).

**Architecture:** Oracle-first, exactly as Phase 2a. Build the AST dumper (`nim-parse`) + differential harness BEFORE growing the parser, so every increment is checked against the running Zen-c engine. The parser consumes the Phase-2a lexer's `Token` stream. This increment covers the AST node model, the parser skeleton, primary + operator expressions, and variable declarations / expression statements — enough to make `zjs parse 'let x = 1 + 2;'` match. Later increments (2c full expressions: calls/members/objects/arrays/arrows; 2d statements: if/for/while/function/class) flesh it out; Phase 2 merges to `nim` only when the whole phase (lexer + parser + AST) is done.

**Tech Stack:** Nim 2.2.10, the existing `zjs parse` CLI (Zen-c reference), the Phase-2a `nim/src/zjs/{token,lexer}.nim`, `std/unittest`, a shell diff harness.

**Branch:** `nim-phase2` (continues from the completed lexer).

**Reference:** Design `docs/superpowers/specs/2026-06-20-zjs-nim-migration-design.md`. Zen-c sources: `src/ast.zc` (the `NodeKind` enum — 74 variants — + the `AstNode` struct), `src/parser.zc` (4779 LOC of recursive-descent rules — THE behavioral spec). The lexer plan `2026-06-20-zjs-nim-phase2a-lexer.md` is the template for the oracle-driven method.

---

## AST representation decision (FINALIZED — Step-0 design step done 2026-06-21)

**Decided + designed (owner-approved, 2026-06-21): object variants with semantic
fields.** Per design doc §3.2 (port to do BEST, not fast) and §3.4 (the AST
standing decision). The Step-0 controller+owner design step (reading `src/ast.zc`
+ `src/parser.zc` + `dump_ast`) is **complete**; the finalized type is in Task 1
Step 3. The AST is a Nim **`ref object` variant**, NOT a flat fat node:
- Discriminant = the full `NodeKind` (mirrors `src/ast.zc`, same names). The
  enum keeps the real names for the compiler; the **dumper** labels via
  `nkLabel` (see oracle section), NOT `$kind`. Nim-managed (`ref` + `seq`, arc;
  no manual memory — AST is host-side data per the two-heap rule).
- `of`-branches **group kinds by shared shape** (Nim allows multiple enum values
  per branch) → ~10 branches, not 74.
- Fields are **semantic** (`lhs`/`rhs`/`unOp`/`operand`/`init`/`declarators`/
  `stmts`/`inner`), NOT generic `left`/`right`/`third`.
- **Nim requires globally-unique field names** across the whole variant (verified
  — even same-type reuse errors). Hence `binOp`/`unOp`/`assignOp`/`declKind`, not
  a shared `op`. Bare role names are unique within 2b (`init` is fine); a future
  increment's design step qualifies any new collision then (design doc §3.4).
- Branches grow incrementally with an `else: discard` catch-all; the `zjs parse`
  differential oracle gates every step.

**Verified during Step 0** (these shaped the finalized type — see corrections
baked into Tasks 1–3):
- **Parens are NOT transparent** — `parse_primary` builds a real `Paren` node
  (`left = inner`), so `(42)` dumps as `Paren` → `NumberExpr 42`. `Paren` is an
  in-scope kind with an `inner` field.
- **`nk_label` is incomplete** (stops at `ForOfStmt`): `BigIntExpr`/`RegexExpr`
  render as `?`, and dump **label-only** (NOT quoted slices — they are not in the
  `IdentExpr`/`StringExpr` branch of `dump_ast`).
- **Expression statements have NO wrapper node** — there is no `ExpressionStmt`
  kind; the bare expression node is placed directly in `Program.stmts`.
- **`&"{x:g}"` (Nim strformat) == C `%g`** byte-for-byte (verified across
  `1`/`1.5`/`1e+21`/`1e+20`/`1.23457e+08`/`1e-06`) — use it for `numVal`.

---

## The differential oracle (verified)

`build/zjs parse '<source>'` prints an indented AST (2 spaces per depth):
```
Program
  VarDecl op=KwLet
    Declarator name="x"
      Binary op=Plus
        NumberExpr 1
        NumberExpr 2
```
Per-node format (from `dump_ast` in `tools/zjs.zc` — the kind→branch mapping is
EXACT, replicate it; anything not listed falls to the default label-only line):
- default / label-only: `<label>` (then newline) — incl. `NullExpr`,
  `UndefinedExpr`, `ThisExpr`, `Paren`, **and `BigIntExpr`/`RegexExpr`** (these
  two are NOT quoted — they hit the default branch)
- `NumberExpr`: `<label> %g` (the number via printf `%g`)
- `BoolExpr`: `<label> true|false`
- `IdentExpr` / `StringExpr` ONLY: `<label> "<source-slice>"`
- `Binary`/`Logical`/`Unary`/`Postfix`/`Assignment`/`VarDecl`: `<label> op=<TokenKindLabel>`
- `Member`/`OptionalMember`/`ObjectProp`/`Declarator`: `<label> name="<slice>"`
- `FunctionDecl`/`FunctionExpr`: `<label> name="<slice>"` or `<label> (anonymous)`

**Label mirroring (critical — design doc §3.4):** `<label>` = `nk_label(kind)` and
`<TokenKindLabel>` = `tk_label(op)`, both lookup tables in `tools/zjs.zc` that are
**incomplete** — `nk_label` stops at `ForOfStmt`, so `BigIntExpr`/`RegexExpr` (and
many later kinds) render as `?`. The Nim dumper must reproduce this verbatim via
`nkLabel`/`tkLabel` procs (shared `nim/tools/labels.nim`), **NOT** Nim's `$kind`
(which prints the real enum name and would diff). **Child walk:** `dump_ast`
recurses **uniformly** `left → right → third → children[]` for every kind; the
variant dumper reproduces that order per-kind (e.g. Binary = lhs then rhs,
Declarator = init only, Paren = inner). **Acceptance:** `nim-parse '<src>'`
output == `build/zjs parse '<src>'`, byte-for-byte, over a corpus.

---

## File Structure

| File | Responsibility |
|---|---|
| `nim/src/zjs/ast.nim` | `NodeKind` enum (mirrors `src/ast.zc`) + `AstNode` ref type + node constructors. Pure data, idiomatic register. |
| `nim/src/zjs/parser.nim` | The recursive-descent parser: `Parser` object over the token stream, `parseProgram`, expression + statement parsers. Idiomatic Nim port of `src/parser.zc`. |
| `nim/tools/labels.nim` | **New (DRY).** `tkLabel` (moved from `nim_lex.nim`) + `nkLabel` — both mirror the Zen-c `tools/zjs.zc` dump tables verbatim (incl. `?` fallback). Imported by both `nim_lex.nim` and `nim_parse.nim`. Tool-only; the engine enum keeps real names. |
| `nim/tools/nim_lex.nim` | **Modified:** drop its local `tkLabel`, import it from `labels.nim` (re-verified by `make nim-difflex`). |
| `nim/tools/nim_parse.nim` | CLI: parse argv source, dump the AST in `zjs parse` format. The parse-tree differential dumper. |
| `nim/tests/tparser.nim` | `std/unittest` parser tests. |
| `nim/tests/diff_parse.sh` | Differential harness: run a JS corpus through `zjs parse` and `nim-parse`, diff. |
| `Makefile` | Targets `nim-parse`, `nim-diffparse`. |

---

## Task 1: AST node model (object variant — design step + build)

**Files:** Create `nim/src/zjs/ast.nim`, Create `nim/tests/tparser.nim`.

- [x] **Step 0 (CONTROLLER+OWNER DESIGN STEP — DONE 2026-06-21, owner-approved).**
  The variant was designed by reading `src/ast.zc` (per-kind field semantics are
  documented inline there), `tools/zjs.zc` `dump_ast`/`nk_label`/`tk_label` (the
  output contract), and `src/parser.zc` (actual node construction). In-scope
  kinds (18): Program, NumberExpr, BigIntExpr, StringExpr, RegexExpr, BoolExpr,
  NullExpr, UndefinedExpr, ThisExpr, IdentExpr, Binary, Logical, Unary, Postfix,
  Assignment, **Paren**, VarDecl, Declarator. The finalized type + constructors
  are in Step 3 below (no longer "illustrative" — build exactly this). Field
  semantics derived: Binary/Logical = `binOp`+`lhs`+`rhs` (op,left,right);
  Unary/Postfix = `unOp`+`operand` (op,left); Assignment = `assignOp`+`target`+
  `value` (op,left,right); Paren = `inner` (left); VarDecl = `declKind`+
  `declarators` (op=keyword, children); Declarator = `nameStart`/`nameLength`+
  `init` (name_*, left=init or nil). Number/String/Ident/Regex/BigInt = value is
  the `start..end` slice (Number additionally carries `numVal` from
  `parse_number_literal`); Bool = `boolVal`; Null/Undefined/This = nullary.

- [ ] **Step 1: Write the failing test** — `nim/tests/tparser.nim` (adjust field/
  constructor names to match the Step-0 finalized design):
```nim
import std/unittest
import ../src/zjs/ast
import ../src/zjs/token

suite "ast model":
  test "NodeKind variant names match Zen-c dump labels":
    check $NodeKind.Program == "Program"
    check $NodeKind.NumberExpr == "NumberExpr"
    check $NodeKind.Binary == "Binary"
    check $NodeKind.VarDecl == "VarDecl"
    check $NodeKind.Declarator == "Declarator"

  test "variant nodes expose semantic fields":
    let lhs = newNumber(0'u32, 1'u32, 1.0)
    let rhs = newNumber(4'u32, 5'u32, 2.0)
    let b = newBinary(NodeKind.Binary, 0'u32, 5'u32, TokenKind.Plus, lhs, rhs)
    check b.kind == NodeKind.Binary
    check b.binOp == TokenKind.Plus
    check b.lhs.numVal == 1.0
    check b.rhs.numVal == 2.0
```

- [ ] **Step 2: Run, verify it fails** — `nim c -r --mm:arc --hints:off nim/tests/tparser.nim`.

- [ ] **Step 3: Write `nim/src/zjs/ast.nim`.** Mirror the `NodeKind` enum from
  `src/ast.zc` (read it — **all 74 variants, in order, same names**; the enum
  keeps the real names for the Phase-3 compiler — same discipline as the lexer's
  TokenKind mirror. NOTE: the dumper does NOT use `$kind`; it uses `nkLabel`
  which mirrors `nk_label`'s `?`-gap. The enum still mirrors all 95 so the
  compiler and `else: discard` growth work cleanly). Then the **finalized
  object-variant** node — build exactly this (Step-0 design, owner-approved):
```nim
## AST — object variant (design doc §3.4). Discriminant = full NodeKind
## (names mirror src/ast.zc). of-branches grouped by shape; SEMANTIC field
## names; globally-unique (Nim requires it); Nim-managed (ref + seq + arc).
import token

type
  NodeKind* = enum
    Program,
    NumberExpr, BigIntExpr, StringExpr, TemplateExpr, TemplatePartExpr,
    TaggedTemplate, BoolExpr, NullExpr, UndefinedExpr, HoleExpr, ThisExpr,
    IdentExpr, RegexExpr,
    ## ... (continue: mirror EVERY variant from src/ast.zc, in order, through
    ## ImportMetaExpr — the full 74. Most stay in the `else: discard` branch
    ## until 2c/2d/3.x implement them.) ...

  AstNode* = ref object
    start*, `end`*: uint32              # `end` is a Nim keyword — backtick-escape
    case kind*: NodeKind
    of NumberExpr: numVal*: float64
    of BoolExpr: boolVal*: bool
    of StringExpr, IdentExpr, RegexExpr, BigIntExpr,
       NullExpr, UndefinedExpr, ThisExpr: discard   # value = start..end slice, or nullary
    of Binary, Logical:
      binOp*: TokenKind
      lhs*, rhs*: AstNode
    of Unary, Postfix:
      unOp*: TokenKind
      operand*: AstNode
    of Assignment:
      assignOp*: TokenKind
      target*, value*: AstNode
    of Paren:
      inner*: AstNode
    of VarDecl:
      declKind*: TokenKind              # KwLet / KwConst / KwVar
      declarators*: seq[AstNode]
    of Declarator:
      nameStart*, nameLength*: uint32
      init*: AstNode                    # initializer, or nil
    of Program:
      stmts*: seq[AstNode]
    else: discard                       # kinds implemented in later increments

# Shape constructors (one per branch family) — semantic + total:
proc newProgram*(s, e: uint32, stmts: seq[AstNode] = @[]): AstNode =
  AstNode(kind: Program, start: s, `end`: e, stmts: stmts)
proc newNumber*(s, e: uint32, v: float64): AstNode =
  AstNode(kind: NumberExpr, start: s, `end`: e, numVal: v)
proc newBool*(s, e: uint32, v: bool): AstNode =
  AstNode(kind: BoolExpr, start: s, `end`: e, boolVal: v)
proc newLeaf*(kind: NodeKind, s, e: uint32): AstNode =
  ## String/Ident/Regex/BigInt (value = slice) + Null/Undefined/This (nullary)
  AstNode(kind: kind, start: s, `end`: e)
proc newBinary*(kind: NodeKind, s, e: uint32, op: TokenKind, lhs, rhs: AstNode): AstNode =
  AstNode(kind: kind, start: s, `end`: e, binOp: op, lhs: lhs, rhs: rhs)  # Binary | Logical
proc newUnary*(kind: NodeKind, s, e: uint32, op: TokenKind, operand: AstNode): AstNode =
  AstNode(kind: kind, start: s, `end`: e, unOp: op, operand: operand)     # Unary | Postfix
proc newAssignment*(s, e: uint32, op: TokenKind, target, value: AstNode): AstNode =
  AstNode(kind: Assignment, start: s, `end`: e, assignOp: op, target: target, value: value)
proc newParen*(s, e: uint32, inner: AstNode): AstNode =
  AstNode(kind: Paren, start: s, `end`: e, inner: inner)
proc newVarDecl*(s, e: uint32, declKind: TokenKind, declarators: seq[AstNode]): AstNode =
  AstNode(kind: VarDecl, start: s, `end`: e, declKind: declKind, declarators: declarators)
proc newDeclarator*(s, e, nameStart, nameLength: uint32, init: AstNode): AstNode =
  AstNode(kind: Declarator, start: s, `end`: e,
          nameStart: nameStart, nameLength: nameLength, init: init)
```
KEY Nim rules: each field name must be UNIQUE across the whole variant (hence
`binOp`/`unOp`/`assignOp`/`declKind`, not one shared `op`); common fields
(`start`/`end`) go OUTSIDE the `case`; you cannot mutate `kind` after
construction, so construct each node with its kind + fields in one shot via the
shape constructors. The dumper (Task 2) reads the right semantic field per
kind-group (`binOp` for Binary/Logical, `unOp` for Unary/Postfix, etc.).

- [ ] **Step 4: Run, verify it passes** — `nim c -r --mm:arc --hints:off nim/tests/tparser.nim` → PASS.

- [ ] **Step 5: Commit** — `git add nim/src/zjs/ast.nim nim/tests/tparser.nim && git commit -m "nim: AST object-variant node model — semantic fields (phase 2b)"`

---

## Task 2: AST dumper + differential harness (oracle before the parser)

Build the dumper + harness against a stub parser (returns a bare `Program`), so the oracle is live for Tasks 3-5.

**Files:** Create `nim/tools/labels.nim`, Modify `nim/tools/nim_lex.nim`, Create `nim/src/zjs/parser.nim` (stub), Create `nim/tools/nim_parse.nim`, Create `nim/tests/diff_parse.sh`, Modify `Makefile`.

- [ ] **Step 0: Shared label module (DRY refactor).** Create `nim/tools/labels.nim`
  exporting two procs that mirror the Zen-c `tools/zjs.zc` dump tables **verbatim,
  including the `?` fallback** — these are tool-only and must reproduce the Zen-c
  tables' incompleteness for byte-identical parity:
```nim
## Mirrors tools/zjs.zc's tk_label + nk_label EXACTLY (incl. the `?` fallback
## for kinds/tokens the Zen-c tables omit). Tool-only; NOT $kind/$tok.
import ../src/zjs/[token, ast]

proc tkLabel*(k: TokenKind): string =
  case k
  of Eof: "Eof"
  # ... (move the EXACT body of the existing tkLabel from nim_lex.nim here) ...
  else: "?"

proc nkLabel*(k: NodeKind): string =
  ## Mirror nk_label in tools/zjs.zc — it stops at ForOfStmt, so kinds after
  ## it (BigIntExpr, RegexExpr, …) MUST fall through to "?".
  case k
  of Program: "Program"
  of NumberExpr: "NumberExpr"
  of StringExpr: "StringExpr"
  of BoolExpr: "BoolExpr"
  of NullExpr: "NullExpr"
  of UndefinedExpr: "UndefinedExpr"
  of ThisExpr: "ThisExpr"
  of IdentExpr: "IdentExpr"
  of Binary: "Binary"
  of Logical: "Logical"
  of Unary: "Unary"
  of Postfix: "Postfix"
  of Conditional: "Conditional"
  of Assignment: "Assignment"
  of Call: "Call"
  of OptionalCall: "OptionalCall"
  of New: "New"
  of Member: "Member"
  of OptionalMember: "OptionalMember"
  of Computed: "Computed"
  of OptionalComputed: "OptionalComputed"
  of Sequence: "Sequence"
  of Array: "Array"
  of Object: "Object"
  of ObjectProp: "ObjectProp"
  of Paren: "Paren"
  of BlockStmt: "BlockStmt"
  of VarDecl: "VarDecl"
  of Declarator: "Declarator"
  of IfStmt: "IfStmt"
  of ReturnStmt: "ReturnStmt"
  of WhileStmt: "WhileStmt"
  of DoWhileStmt: "DoWhileStmt"
  of ForStmt: "ForStmt"
  of BreakStmt: "BreakStmt"
  of ContinueStmt: "ContinueStmt"
  of EmptyStmt: "EmptyStmt"
  of FunctionDecl: "FunctionDecl"
  of FunctionExpr: "FunctionExpr"
  of ArrowFunc: "ArrowFunc"
  of ForInStmt: "ForInStmt"
  of ForOfStmt: "ForOfStmt"
  else: "?"     # BigIntExpr, RegexExpr, TemplateExpr, … all render as "?"
```
  Then **modify `nim/tools/nim_lex.nim`**: delete its local `tkLabel`, add
  `import labels` (or `from labels import tkLabel`). Rebuild + `make nim-difflex`
  → must STILL be byte-clean (proves the move is behavior-preserving). Commit
  this refactor on its own: `git add nim/tools/labels.nim nim/tools/nim_lex.nim &&
  git commit -m "nim: extract shared dump-label tables to tools/labels.nim"`.
  (The `nkLabel` arm list above is the EXACT current `nk_label` table — verify
  against `tools/zjs.zc` at build time in case it grew.)

- [ ] **Step 1: Stub parser** — `nim/src/zjs/parser.nim`:
```nim
## Recursive-descent parser — idiomatic Nim port of src/parser.zc.
## Consumes the Phase-2a lexer's Token stream; produces a ref AstNode tree.
import token, lexer, ast

type
  Parser* = object
    source*: string
    toks*: seq[Token]
    pos*: int

proc initParser*(source: string): Parser =
  var lx = initLexer(source)
  var ts: seq[Token]
  for t in lx.tokens(): ts.add(t)
  Parser(source: source, toks: ts, pos: 0)

proc parseProgram*(p: var Parser): AstNode =
  ## STUB (Task 2): empty Program. Real parsing in Task 3+.
  newProgram(0'u32, p.source.len.uint32)   # variant constructor; stmts defaults to @[]
```

- [ ] **Step 2: The dumper** — `nim/tools/nim_parse.nim` — must match `zjs parse` format (indent 2/depth + per-node attrs from the oracle section). Label via `nkLabel(n.kind)` and op via `tkLabel(...)` (from `labels.nim`) — **NOT** `$kind`/`$binOp` (those print the real enum name; `nkLabel`/`tkLabel` reproduce the Zen-c `?`-gap). Number via `&"{n.numVal:g}"` (verified == C `%g`). With the **object variant**, the header line AND the child walk are both driven by a single `case n.kind` — each branch reads its own semantic fields and recurses into its own semantic children in source order. This is the variant payoff: no generic `left/right/third/children` walk that could visit the wrong slot. Implement `dumpAst(node, source, depth)`:
```nim
import std/[os, strformat, strutils]
import ../src/zjs/[ast, token, parser]
import labels   # nkLabel, tkLabel — shared with nim_lex

proc slice(src: string, s, e: uint32): string = src[s.int ..< e.int]

proc dumpAst(n: AstNode, src: string, depth: int) =
  if n == nil:
    stdout.write(repeat("  ", depth) & "(null)\n"); return
  let ind = repeat("  ", depth)
  let label = nkLabel(n.kind)        # mirrors nk_label, incl. "?" gap — NOT $kind
  case n.kind
  of NumberExpr:
    stdout.write(&"{ind}{label} {n.numVal:g}\n")        # :g == C %g (verified)
  of BoolExpr:
    stdout.write(&"{ind}{label} {(if n.boolVal: \"true\" else: \"false\")}\n")
  of IdentExpr, StringExpr:                              # ONLY these two are quoted
    stdout.write(&"{ind}{label} \"{slice(src, n.start, n.`end`)}\"\n")
  of Binary, Logical:
    stdout.write(&"{ind}{label} op={tkLabel(n.binOp)}\n")
    dumpAst(n.lhs, src, depth+1)
    dumpAst(n.rhs, src, depth+1)
  of Unary, Postfix:
    stdout.write(&"{ind}{label} op={tkLabel(n.unOp)}\n")
    dumpAst(n.operand, src, depth+1)
  of Assignment:
    stdout.write(&"{ind}{label} op={tkLabel(n.assignOp)}\n")
    dumpAst(n.target, src, depth+1)
    dumpAst(n.value, src, depth+1)
  of VarDecl:
    stdout.write(&"{ind}{label} op={tkLabel(n.declKind)}\n")
    for d in n.declarators: dumpAst(d, src, depth+1)
  of Declarator:
    stdout.write(&"{ind}{label} name=\"{slice(src, n.nameStart, n.nameStart + n.nameLength)}\"\n")
    if n.init != nil: dumpAst(n.init, src, depth+1)
  of Paren:
    stdout.write(&"{ind}{label}\n")                      # label-only ("Paren")
    dumpAst(n.inner, src, depth+1)
  of Program:
    stdout.write(&"{ind}{label}\n")
    for s in n.stmts: dumpAst(s, src, depth+1)
  else:  # NullExpr/UndefinedExpr/ThisExpr + BigIntExpr/RegexExpr (label-only "?")
    stdout.write(&"{ind}{label}\n")

proc main() =
  let src = if paramCount() >= 1: paramStr(1) else: ""
  var p = initParser(src)
  let root = p.parseProgram()
  dumpAst(root, src, 0)

main()
```
CRITICAL (Step 4): the **per-kind child-walk order** must match Zen-c's `dump_ast` (which walks uniformly `left → right → third → children[]`) — the per-branch walks above reproduce that order (Binary = lhs→rhs, Assignment = target→value, Declarator = init only, Paren = inner, Program/VarDecl = their seq). Number formatting is `:g` (already verified byte-equal to C `%g`). `BigIntExpr`/`RegexExpr` are deliberately in the `else` (label-only `?`) branch — they are NOT quoted. Use a `Program` with one child to lock indentation, then diff a real dump clean.

- [ ] **Step 3: Differential harness** — `nim/tests/diff_parse.sh` (copy the structure of `nim/tests/diff_lex.sh`, swapping `lex`→`parse` and `nim-lex`→`nim-parse`; same built-in snippets + `<dir>` mode + `diff` + count).

- [ ] **Step 4: Makefile targets + format-lock.** Add `nim-parse`/`nim-diffparse` targets (mirror the `nim-lex`/`nim-difflex` targets). Build, then lock the format: `build/zjs parse 'x'` vs `build/nim/nim-parse 'x'` — with the stub, both emit just `Program` (the stub) vs Zen-c's real parse of `x` (which is `Program` + `IdentExpr "x"`). They WON'T fully match yet (stub), but confirm the `Program` line's bytes match (indentation/label). Lock the format on that line.

- [ ] **Step 5: Commit** — `git add nim/src/zjs/parser.nim nim/tools/nim_parse.nim nim/tests/diff_parse.sh Makefile && git commit -m "nim: parser stub + AST differential dump harness vs zjs parse (phase 2b)"`

---

## Task 3: Primary expressions

**Files:** Modify `nim/src/zjs/parser.nim`, Modify `nim/tests/tparser.nim`.

- [ ] **Step 1: Unit tests** for parsing single primary expressions wrapped in a Program (an expression statement): `1` → Program/NumberExpr; `"s"` → Program/StringExpr; `true`/`false` → BoolExpr; `null` → NullExpr; `x` → IdentExpr; `this` → ThisExpr; `(42)` → Program/**Paren**/NumberExpr (parens are NOT transparent — Zen-c builds a real `Paren` node with `inner` = the expression; verify against `zjs parse '(42)'`). Derive expected trees from `build/zjs parse '<input>'`. Assert by comparing your dumped tree (call a small test helper that renders the AST like the dumper, or assert node kinds/fields directly).

- [ ] **Step 2: Run, verify they fail** (stub returns empty Program).

- [ ] **Step 3: Implement** in `nim/src/zjs/parser.nim`: cursor helpers (`peek`/`advance`/`expect`), `parseProgram` (loop parsing statements into a local `stmts: seq[AstNode]`, then `newProgram(0, len, stmts)` — recall a variant's `kind` and case fields are fixed at construction, so accumulate children first and build the node once), a minimal `parseStatement` that for now handles only expression statements (an expression statement is the **bare expression node** placed directly in `Program.stmts` — there is no ExpressionStmt wrapper), and `parsePrimary` (number/string/bool/null/undefined/ident/this/regex/parenthesized). Build each node via its shape constructor: `newNumber` (set `numVal` from a port of `parse_number_literal`), `newBool`, `newLeaf(StringExpr|IdentExpr|RegexExpr|NullExpr|UndefinedExpr|ThisExpr, …)`, and **`newParen(start, end, inner)`** for `( expr )` — Zen-c consumes `(`, parses the inner expression, consumes `)`, and wraps it in a `Paren` whose span runs from `(` to `)`. Set `start`/`end` to match the Zen-c spans (the dump reveals these). For value-from-slice kinds (Ident/String/Regex/BigInt) the value is the `start..end` source slice — set the span, no separate field.

- [ ] **Step 4: Run unit tests → PASS. Differential checks:**
```bash
make nim-parse >/dev/null
for s in '1' '"s"' 'true' 'null' 'x' 'this' '(42)' '1.5' 'foo'; do
  diff <(build/zjs parse "$s") <(build/nim/nim-parse "$s") >/dev/null && echo "OK: $s" || { echo "DIFF: $s"; diff <(build/zjs parse "$s") <(build/nim/nim-parse "$s"); }
done
```
All must diff clean.

- [ ] **Step 5: Commit** — `git add -u && git commit -m "nim: parser — primary expressions (phase 2b)"`

---

## Task 4: Operator expressions (unary, binary, precedence)

**Files:** Modify `nim/src/zjs/parser.nim`, Modify `nim/tests/tparser.nim`.

- [ ] **Step 1: Unit tests** for: `1 + 2` → Binary(Plus); `1 + 2 * 3` → Binary(Plus){NumberExpr, Binary(Star)} (precedence); `-x` → Unary(Minus); `!a` → Unary(Bang); `a && b` → Logical(AmpAmp); `a < b` → Binary(Lt); `2 ** 3 ** 2` → right-assoc; `a, b` if Zen-c models sequence — check `zjs parse`. Derive ALL expected trees from `build/zjs parse`.

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** binary/unary expression parsing with correct precedence + associativity, porting `src/parser.zc`'s expression parser (it likely uses precedence climbing or a Pratt-style ladder — mirror its precedence table and associativity exactly; the differential oracle will catch any precedence error). Produce nodes via the shape constructors: `newBinary(Binary|Logical, …, op, lhs, rhs)` (`binOp` field), `newUnary(Unary|Postfix, …, op, operand)` (`unOp` field). Note Binary and Logical share the `binOp`/`lhs`/`rhs` shape (one constructor, kind selects which) — Zen-c routes logical operators (`&&`/`||`/`??`) to the `Logical` kind; check `zjs parse 'a && b'` to confirm which operators map to `Logical` vs `Binary` and dispatch the kind accordingly.

- [ ] **Step 4: Run unit tests → PASS. Differential checks:**
```bash
for s in '1 + 2' '1 + 2 * 3' '(1 + 2) * 3' '-x' '!a' 'a && b || c' 'a < b == c' '2 ** 3 ** 2' 'a + b - c'; do
  diff <(build/zjs parse "$s") <(build/nim/nim-parse "$s") >/dev/null && echo "OK: $s" || { echo "DIFF: $s"; diff <(build/zjs parse "$s") <(build/nim/nim-parse "$s"); }
done
```
All clean (precedence + associativity must match Zen-c).

- [ ] **Step 5: Commit** — `git add -u && git commit -m "nim: parser — operator expressions with precedence (phase 2b)"`

---

## Task 5: Variable declarations + expression statements + corpus check

**Files:** Modify `nim/src/zjs/parser.nim`, Modify `nim/tests/tparser.nim`.

- [ ] **Step 1: Unit tests** for: `let x = 1;` → Program/VarDecl(op=KwLet)/Declarator(name="x")/NumberExpr; `const a = 1 + 2;`; `var y;` (no initializer); `let a = 1, b = 2;` (multiple declarators); a bare expression statement `x + 1;`. Derive expected trees from `build/zjs parse`. (Match how Zen-c structures VarDecl → Declarator(name) → initializer-expr.)

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** `let`/`const`/`var` declaration parsing (port `src/parser.zc`'s var-decl path): `newVarDecl(…, declKind, declarators)` where `declKind` = the keyword token (`KwLet`/`KwConst`/`KwVar`) and `declarators` is a `seq[AstNode]` of `newDeclarator(…, nameStart, nameLength, init)` nodes (each with the identifier span + an optional initializer child, `init = nil` when absent). Accumulate the declarator seq first, then build the `VarDecl` once (variant fields are construction-time). Wire it into `parseStatement` (dispatch on `KwLet`/`KwConst`/`KwVar`). Keep expression statements working. Handle the trailing `;` (ASI not required for this increment — just consume an optional semicolon, matching `zjs parse 'let x = 1'` with and without `;`).

- [ ] **Step 4: Run unit tests → PASS. Differential checks + a small corpus:**
```bash
for s in 'let x = 1;' 'const a = 1 + 2;' 'var y;' 'let a = 1, b = 2;' 'x + 1;' 'let x = 1 + 2;'; do
  diff <(build/zjs parse "$s") <(build/nim/nim-parse "$s") >/dev/null && echo "OK: $s" || { echo "DIFF: $s"; diff <(build/zjs parse "$s") <(build/nim/nim-parse "$s"); }
done
```
All clean. (A full test262 corpus diff comes in later increments once statements/expressions are complete — this increment only needs the declaration/expression subset clean.)

- [ ] **Step 5: Commit** — `git add -u && git commit -m "nim: parser — variable declarations + expression statements (phase 2b)"`

---

## Done criteria

- `nim c -r nim/tests/tparser.nim` passes.
- The Task 3-5 differential snippet batteries all diff clean against `zjs parse`.
- `build/zjs parse 'let x = 1 + 2;'` and `build/nim/nim-parse 'let x = 1 + 2;'` are byte-identical.

This establishes the AST + parser skeleton + the expression/declaration core. Next increments: **2c** (calls, member access, objects, arrays, arrow functions, templates) and **2d** (if/for/while/switch/try/function/class statements), each oracle-driven, building to a full `zjs parse` corpus diff. When the whole parser is green over a test262 corpus, Phase 2 (lexer + parser + AST) merges to `nim`.
