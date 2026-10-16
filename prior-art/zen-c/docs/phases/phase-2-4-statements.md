# zjs Phase 2.4 — Statements

> Fourth slice of Phase 2. Extends the parser from expressions-only to
> a full statement grammar. Closes out Phase 2 of the overall plan
> (lexer + parser + AST) modulo functions/classes, which slip into
> Phase 2.5.

## Scope

In scope:
- `BlockStmt` — `{ stmt* }`
- `VarDecl` — `(var|let|const) declarator (',' declarator)* ;`
  - `Declarator` — `identifier ('=' AssignmentExpression)?`
  - Records `var`/`let`/`const` via the `op` field on `VarDecl`
- `IfStmt` — `if '(' expr ')' stmt ('else' stmt)?`
- `ReturnStmt` — `return expression? ;`
- `WhileStmt` — `while '(' expr ')' stmt`
- `DoWhileStmt` — `do stmt while '(' expr ')' ;`
- `ForStmt` — `for '(' init? ; cond? ; update? ')' stmt`
  - `init` may be a `VarDecl` (no trailing `;`) or an Expression
- `BreakStmt`, `ContinueStmt` — labelless (no labels yet)
- `EmptyStmt` — `;`
- Expression statement — any Expression followed by an optional terminator

Out of scope (later sub-phases):
- Functions: declarations + expressions + arrow — Phase 2.5
- Classes — Phase 2.5
- `for-in` / `for-of` — Phase 2.5 (need an iterator-protocol concept)
- `throw` / `try` / `catch` / `finally` — needs exception machinery in Phase 3+
- `switch` — defer
- Labeled statements + labeled `break`/`continue` — defer
- Destructuring patterns in `Declarator` — defer
- Real Automatic Semicolon Insertion — see "Terminators" below

## Terminators

ECMA-262 ASI is a parser-level rule that depends on newlines, but our
lexer doesn't emit newline tokens. For Phase 2.4 we adopt a lenient
"optional terminator" policy:

```
match_terminator(p):
    if peek == ;       advance
    elif peek == }     ok (no consume)
    elif peek == EOF   ok (no consume)
    else               ok, but real engines would warn here
```

This makes both `let x = 1;` and `let x = 1\n` work; it forgives missing
`;` in places real engines would also forgive via ASI. Real ASI lands
when we have newline-position info in tokens.

## New AST node kinds

```
BlockStmt        children = stmts
VarDecl          op = KwVar | KwLet | KwConst
                 children = Declarator nodes
Declarator       name_start/name_length = identifier
                 left = initializer expression (NULL if absent)
IfStmt           left = test, right = then, third = else (NULL if absent)
ReturnStmt       left = argument (NULL for bare `return;`)
WhileStmt        left = test, right = body
DoWhileStmt      left = body, right = test
ForStmt          left = init (VarDecl/Expr/NULL),
                 right = test (NULL ok),
                 third = update (NULL ok),
                 children[0] = body
BreakStmt        no fields
ContinueStmt     no fields
EmptyStmt        no fields
```

Expression statements are *not* wrapped — an expression at the top level
of `Program.children[]` IS the statement. The bytecode compiler will
dispatch on `kind` to decide whether to discard the result or use it.

## Disambiguation at statement-start

`{` at statement-start is always a `BlockStmt` (per ECMA-262 §13.2). An
object literal at the start of a statement would require parens, e.g.,
`({a: 1});`. The parser is naturally correct here because
`parse_statement` dispatches `LBrace → parse_block` before falling through
to expression parsing.

## Files

- `src/ast.zc` — extend `NodeKind`
- `src/parser.zc` — add `parse_statement` + per-statement helpers; modify `parse_program`
- `tools/zjs.zc` — extend `nk_label`, AST dumper handles new kinds
- `tests/parser_test.zc` — add ~15 statement test cases
- `docs/phases/phase-2-4-statements.md` — this doc

## Verification

`make test` continues to pass all 378 prior assertions, plus the new
statement assertions. CLI demo:

```
$ zjs parse "let x = 1 + 2; if (x) return x;"
Program
  VarDecl op=KwLet
    Declarator name="x"
      Binary op=Plus
        NumberExpr 1
        NumberExpr 2
  IfStmt
    IdentExpr "x"
    ReturnStmt
      IdentExpr "x"
```

## What's next (Phase 2.5 / Phase 3)

Phase 2.5: functions + classes + arrow functions + `for-in`/`for-of`.
After 2.5, the AST is sufficient to start Phase 3: bytecode compiler +
interpreter. The MVP runnable program will go through every layer
we've built so far.
