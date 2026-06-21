# ZJS-Nim Phase 2b (AST + Parser skeleton) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure-Nim AST model + recursive-descent parser skeleton that parses a meaningful expression/declaration subset into the same tree as the Zen-c parser — validated **byte-for-byte against `zjs parse`** (the parse-tree differential oracle).

**Architecture:** Oracle-first, exactly as Phase 2a. Build the AST dumper (`nim-parse`) + differential harness BEFORE growing the parser, so every increment is checked against the running Zen-c engine. The parser consumes the Phase-2a lexer's `Token` stream. This increment covers the AST node model, the parser skeleton, primary + operator expressions, and variable declarations / expression statements — enough to make `zjs parse 'let x = 1 + 2;'` match. Later increments (2c full expressions: calls/members/objects/arrays/arrows; 2d statements: if/for/while/function/class) flesh it out; Phase 2 merges to `nim` only when the whole phase (lexer + parser + AST) is done.

**Tech Stack:** Nim 2.2.10, the existing `zjs parse` CLI (Zen-c reference), the Phase-2a `nim/src/zjs/{token,lexer}.nim`, `std/unittest`, a shell diff harness.

**Branch:** `nim-phase2` (continues from the completed lexer).

**Reference:** Design `docs/superpowers/specs/2026-06-20-zjs-nim-migration-design.md`. Zen-c sources: `src/ast.zc` (the `NodeKind` enum — 95 variants — + the `AstNode` struct), `src/parser.zc` (4779 LOC of recursive-descent rules — THE behavioral spec). The lexer plan `2026-06-20-zjs-nim-phase2a-lexer.md` is the template for the oracle-driven method.

---

## AST representation decision (deliberate, flag for review)

**Decided (owner, 2026-06-21): object variants with semantic fields.** Per design
doc §3.2 (this is a port to do BEST, not fast) and §3.4 (the AST standing
decision), the AST is a Nim **`ref object` variant**, NOT a flat fat node:
- Discriminant = the full `NodeKind` (mirrors `src/ast.zc`, same names → `$kind`
  matches `zjs parse`'s `nk_label`). Nim-managed (`ref` + `seq`, arc; no manual
  memory — AST is host-side data per the two-heap rule).
- `of`-branches **group kinds by shared shape** (Nim allows multiple enum values
  per branch) → ~8–12 branches, not 95.
- Fields are **semantic** (`lhs`/`rhs`/`unOp`/`operand`/`init`/`declarators`/
  `stmts`), NOT generic `left`/`right`/`third`. Deriving these requires reading
  the Zen-c parser to learn each kind's field meaning — the effort we choose to
  spend.
- Branches grow incrementally with an `else: discard` catch-all; the `zjs parse`
  differential oracle gates every step.

**Because the AST shape is foundational (parser AND the Phase-3 compiler consume
it), the exact variant-branch design for the Phase-2b kinds is a deliberate
controller+owner design step done at the START of execution (with the Zen-c
parser open) — see Task 1. It is NOT improvised by an implementer subagent.**

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
Per-node format (from `dump_ast` in `tools/zjs.zc`):
- default: `<NodeKindLabel>` (then newline)
- `NumberExpr`: `<label> %g` (the number via printf `%g`)
- `BoolExpr`: `<label> true|false`
- `IdentExpr` / `StringExpr`: `<label> "<source-slice>"`
- `Binary`/`Logical`/`Unary`/`Postfix`/`Assignment`/`VarDecl`: `<label> op=<TokenKindLabel>`
- `Member`/`OptionalMember`/`ObjectProp`/`Declarator`: `<label> name="<slice>"`
- `FunctionDecl`/`FunctionExpr`: `<label> name="<slice>"` or `<label> (anonymous)`

The node-kind label is `nk_label(kind)` and the op label is the TokenKind label — both in `tools/zjs.zc`. **Acceptance:** `nim-parse '<src>'` output == `build/zjs parse '<src>'`, byte-for-byte, over a corpus.

---

## File Structure

| File | Responsibility |
|---|---|
| `nim/src/zjs/ast.nim` | `NodeKind` enum (mirrors `src/ast.zc`) + `AstNode` ref type + node constructors. Pure data, idiomatic register. |
| `nim/src/zjs/parser.nim` | The recursive-descent parser: `Parser` object over the token stream, `parseProgram`, expression + statement parsers. Idiomatic Nim port of `src/parser.zc`. |
| `nim/tools/nim_parse.nim` | CLI: parse argv source, dump the AST in `zjs parse` format. The parse-tree differential dumper. |
| `nim/tests/tparser.nim` | `std/unittest` parser tests. |
| `nim/tests/diff_parse.sh` | Differential harness: run a JS corpus through `zjs parse` and `nim-parse`, diff. |
| `Makefile` | Targets `nim-parse`, `nim-diffparse`. |

---

## Task 1: AST node model (object variant — design step + build)

**Files:** Create `nim/src/zjs/ast.nim`, Create `nim/tests/tparser.nim`.

- [ ] **Step 0 (CONTROLLER+OWNER DESIGN STEP — do this first, at execution start, with the Zen-c parser open; NOT delegated to an implementer subagent).**
  Per design doc §3.4, design the object-variant `AstNode` for the Phase-2b
  kinds. For each kind in scope (Program, NumberExpr, BigIntExpr, StringExpr,
  RegexExpr, BoolExpr, NullExpr, UndefinedExpr, ThisExpr, IdentExpr, Binary,
  Logical, Unary, Postfix, Assignment, VarDecl, Declarator), read `src/parser.zc`
  + `src/ast.zc` to learn what its generic `left`/`right`/`third`/`children`/
  `name_*` fields actually MEAN, and define **semantic** variant fields. Group
  kinds sharing a shape into one `of` branch. Finalize the type below against
  the reference, then proceed to the TDD steps. The illustrative sketch in Step 3
  is a STARTING POINT to refine, not the final word.

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
  `src/ast.zc` (read it — 95 variants, in order, same names so `$kind` matches
  `nk_label`; same discipline as the lexer's TokenKind mirror — a mismatch
  silently breaks the dump). Then the **object-variant** node. ILLUSTRATIVE
  sketch (finalize against the Step-0 design):
```nim
## AST — object variant (design doc §3.4). Discriminant = full NodeKind
## (names mirror src/ast.zc so `$kind` == `zjs parse`'s nk_label). of-branches
## grouped by shape; SEMANTIC field names; Nim-managed (ref + seq + arc).
import token

type
  NodeKind* = enum
    Program,
    NumberExpr, BigIntExpr, StringExpr, TemplateExpr, TemplatePartExpr,
    TaggedTemplate, BoolExpr, NullExpr, UndefinedExpr, HoleExpr, ThisExpr,
    IdentExpr, RegexExpr,
    ## ... (continue: mirror EVERY variant from src/ast.zc, in order) ...

  AstNode* = ref object
    start*, `end`*: uint32              # `end` is a Nim keyword — backtick-escape
    case kind*: NodeKind
    of NumberExpr: numVal*: float64
    of BoolExpr: boolVal*: bool
    of StringExpr, IdentExpr, RegexExpr, BigIntExpr: discard  # value = source slice
    of NullExpr, UndefinedExpr, ThisExpr: discard             # nullary
    of Binary, Logical:
      binOp*: TokenKind
      lhs*, rhs*: AstNode
    of Unary, Postfix:
      unOp*: TokenKind
      operand*: AstNode
    of Assignment:
      assignOp*: TokenKind
      target*, value*: AstNode
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
proc newNumber*(s, e: uint32, v: float64): AstNode =
  AstNode(kind: NumberExpr, start: s, `end`: e, numVal: v)
proc newBinary*(k: NodeKind, s, e: uint32, op: TokenKind, lhs, rhs: AstNode): AstNode =
  AstNode(kind: k, start: s, `end`: e, binOp: op, lhs: lhs, rhs: rhs)
# ... (newUnary, newAssignment, newVarDecl, newDeclarator, newProgram,
#      newIdent/newString/newBool/newNull/..., per the Step-0 design) ...
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

**Files:** Create `nim/src/zjs/parser.nim` (stub), Create `nim/tools/nim_parse.nim`, Create `nim/tests/diff_parse.sh`, Modify `Makefile`.

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

- [ ] **Step 2: The dumper** — `nim/tools/nim_parse.nim` — must match `zjs parse` format (indent 2/depth + per-node attrs from the oracle section). Use `$kind` for the node label and `$binOp`/`$unOp`/… for the op labels (both mirror the Zen-c labels because the enums mirror Zen-c). With the **object variant**, the header line AND the child walk are both driven by a single `case n.kind` — each branch reads its own semantic fields and recurses into its own semantic children in source order. This is the variant payoff: no generic `left/right/third/children` walk that could visit the wrong slot. Implement `dumpAst(node, source, depth)`:
```nim
import std/[os, strformat, strutils]
import ../src/zjs/[ast, token, parser]

proc slice(src: string, s, e: uint32): string = src[s.int ..< e.int]

proc dumpAst(n: AstNode, src: string, depth: int) =
  if n == nil:
    stdout.write(repeat("  ", depth) & "(null)\n"); return
  let ind = repeat("  ", depth)
  let label = $n.kind
  case n.kind
  of NumberExpr:
    stdout.write(&"{ind}{label} {formatFloat(n.numVal, ffDefault, 0)}\n")  # match printf %g — verify in Step 4
  of BoolExpr:
    stdout.write(&"{ind}{label} {(if n.boolVal: \"true\" else: \"false\")}\n")
  of IdentExpr, StringExpr, RegexExpr, BigIntExpr:
    stdout.write(&"{ind}{label} \"{slice(src, n.start, n.`end`)}\"\n")
  of Binary, Logical:
    stdout.write(&"{ind}{label} op={$n.binOp}\n")
    dumpAst(n.lhs, src, depth+1)
    dumpAst(n.rhs, src, depth+1)
  of Unary, Postfix:
    stdout.write(&"{ind}{label} op={$n.unOp}\n")
    dumpAst(n.operand, src, depth+1)
  of Assignment:
    stdout.write(&"{ind}{label} op={$n.assignOp}\n")
    dumpAst(n.target, src, depth+1)
    dumpAst(n.value, src, depth+1)
  of VarDecl:
    stdout.write(&"{ind}{label} op={$n.declKind}\n")
    for d in n.declarators: dumpAst(d, src, depth+1)
  of Declarator:
    stdout.write(&"{ind}{label} name=\"{slice(src, n.nameStart, n.nameStart + n.nameLength)}\"\n")
    if n.init != nil: dumpAst(n.init, src, depth+1)
  of Program:
    stdout.write(&"{ind}{label}\n")
    for s in n.stmts: dumpAst(s, src, depth+1)
  else:  # NullExpr, UndefinedExpr, ThisExpr, + later-increment kinds (nullary for now)
    stdout.write(&"{ind}{label}\n")

proc main() =
  let src = if paramCount() >= 1: paramStr(1) else: ""
  var p = initParser(src)
  let root = p.parseProgram()
  dumpAst(root, src, 0)

main()
```
CRITICAL (Step 4): the **per-kind child-walk order** and the **`%g` number formatting** must match Zen-c's `dump_ast` exactly. Read `dump_ast` in `tools/zjs.zc` to confirm, for each kind, the order it recurses its children (e.g. Binary = left-then-right, Declarator = name-then-init) and replicate that order inside the matching `of` branch. Use a `Program` with one child to lock indentation, and adjust `formatFloat`/the per-branch walk until a real dump diffs clean.

- [ ] **Step 3: Differential harness** — `nim/tests/diff_parse.sh` (copy the structure of `nim/tests/diff_lex.sh`, swapping `lex`→`parse` and `nim-lex`→`nim-parse`; same built-in snippets + `<dir>` mode + `diff` + count).

- [ ] **Step 4: Makefile targets + format-lock.** Add `nim-parse`/`nim-diffparse` targets (mirror the `nim-lex`/`nim-difflex` targets). Build, then lock the format: `build/zjs parse 'x'` vs `build/nim/nim-parse 'x'` — with the stub, both emit just `Program` (the stub) vs Zen-c's real parse of `x` (which is `Program` + `IdentExpr "x"`). They WON'T fully match yet (stub), but confirm the `Program` line's bytes match (indentation/label). Lock the format on that line.

- [ ] **Step 5: Commit** — `git add nim/src/zjs/parser.nim nim/tools/nim_parse.nim nim/tests/diff_parse.sh Makefile && git commit -m "nim: parser stub + AST differential dump harness vs zjs parse (phase 2b)"`

---

## Task 3: Primary expressions

**Files:** Modify `nim/src/zjs/parser.nim`, Modify `nim/tests/tparser.nim`.

- [ ] **Step 1: Unit tests** for parsing single primary expressions wrapped in a Program (an expression statement): `1` → Program/NumberExpr; `"s"` → Program/StringExpr; `true`/`false` → BoolExpr; `null` → NullExpr; `x` → IdentExpr; `this` → ThisExpr; `(1)` → the inner NumberExpr (parens are transparent — verify against `zjs parse '(1)'`). Derive expected trees from `build/zjs parse '<input>'`. Assert by comparing your dumped tree (call a small test helper that renders the AST like the dumper, or assert node kinds/fields directly).

- [ ] **Step 2: Run, verify they fail** (stub returns empty Program).

- [ ] **Step 3: Implement** in `nim/src/zjs/parser.nim`: cursor helpers (`peek`/`advance`/`expect`), `parseProgram` (loop parsing statements into a local `stmts: seq[AstNode]`, then `newProgram(0, len, stmts)` — recall a variant's `kind` and case fields are fixed at construction, so accumulate children first and build the node once), a minimal `parseStatement` that for now handles only expression statements, and `parsePrimary` (number/string/bool/null/undefined/ident/this/regex/parenthesized). Build each node via its shape constructor (`newNumber`/`newString`/`newBool`/`newNull`/`newIdent`/`newThis`/…), setting `start`/`end`/`numVal`/`boolVal` to match what the Zen-c parser records (the dump reveals these). For value-from-slice kinds (Ident/String/Regex/BigInt) the value is the `start..end` source slice — set the span, no separate field.

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
