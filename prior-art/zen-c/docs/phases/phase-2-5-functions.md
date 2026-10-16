# zjs Phase 2.5 — Functions, Arrow Functions, for-in / for-of

> Final substantive slice of Phase 2. After this, the AST is rich enough
> for Phase 3 (bytecode compiler + interpreter) to start emitting real
> programs.

## Scope

In scope:
- `FunctionDecl` — `function name(params) { body }`
- `FunctionExpr` — `function (params) { body }` and `function name(params) { body }` (in expression context)
- `ArrowFunc` — `(params) => body` / `(params) => { stmts }` / `param => body` / `() => body`
- Parameter lists: bare identifiers only (no defaults, rest, destructuring)
- `for-in`: `for (binding in expr) body`
- `for-of`: `for (binding of expr) body`
- Bindings in for-in/for-of: `var/let/const x` OR a single lvalue expression

Out of scope (Phase 2.6 / later):
- **Classes** — declarations, expressions, methods, static, getters/setters, fields, private fields, extends/super. Sugar over functions + prototype assignment; can be desugared in the parser or bytecode compiler later.
- **Default parameters** (`function f(x = 1) {}`)
- **Rest parameters** (`function f(...args) {}`)
- **Destructuring parameters** (`function f({a, b}) {}`)
- **Generator functions** (`function*`)
- **Async / await** keywords beyond lexer recognition
- **`super` / `new.target`** — pending classes
- **Function name inference** for arrow assignments

## New AST kinds

```
FunctionDecl     name_start/length, children=params, left=body (BlockStmt)
FunctionExpr     name_start/length (0 if anonymous), children=params, left=body
ArrowFunc        no name, children=params, left=body (BlockStmt OR expression)
ForInStmt        left=binding (VarDecl or lvalue Expr), right=iterable, children[0]=body
ForOfStmt        same shape as ForInStmt
```

Parameters are stored as plain `IdentExpr` nodes — no `Param` wrapper, since for this phase a parameter is just a name. When destructuring lands later, we can introduce a richer `Param` node.

## Arrow disambiguation

The parser uses a bounded lookahead to disambiguate arrow function
parameter lists from parenthesized expressions:

- `Identifier '=>' ...` → single-param arrow (cheap two-token check)
- `'(' ... ')' '=>' ...` → paren-list arrow (scan for the matching `)` and peek the token after)
- Otherwise the `(` opens a parenthesized expression as usual

The lookahead is O(tokens-in-parens) but bounded by the source, and only
runs when `parse_assignment` is entered at a fresh expression boundary.
Negligible parser-perf impact; saves us from a cover-grammar or
tentative-parsing implementation.

## for-init disambiguation

`parse_for` parses the init slot, then peeks for `in` / `of` / `;` to
decide whether this is a C-style for, a for-in, or a for-of. The init
slot can be:

- empty (`for (;;)`)
- a `var`/`let`/`const` declaration (no trailing `;` consumed)
- an expression

When the next token after the init is `in` or `of`, we dispatch to
for-in / for-of; otherwise we continue with the C-style three-slot form.

## Files

- `src/ast.zc` — extend `NodeKind`
- `src/parser.zc` — new parse functions + arrow lookahead + for-init dispatch
- `tools/zjs.zc` — extend `nk_label` for the new kinds
- `tests/parser_test.zc` — function, arrow, for-in, for-of cases
- `docs/phases/phase-2-5-functions.md` — this doc

## Verification

CLI demo after this slice:

```
$ zjs parse "function add(a, b) { return a + b; }"
Program
  FunctionDecl name="add"
    IdentExpr "a"
    IdentExpr "b"
    BlockStmt
      ReturnStmt
        Binary op=Plus
          IdentExpr "a"
          IdentExpr "b"

$ zjs parse "let inc = x => x + 1;"
Program
  VarDecl op=KwLet
    Declarator name="inc"
      ArrowFunc
        IdentExpr "x"
        Binary op=Plus
          IdentExpr "x"
          NumberExpr 1
```

## What's next (Phase 3)

Bytecode compiler + interpreter. AST → flat bytecode → run.
**test262 wired up at the same time** — even at 0-1% pass rate, it
becomes the objective dashboard for spec progress. Hermes-style
packed-struct-per-opcode bytecode (per the design study), computed-goto
interpreter dispatch, refcount + cycle collector GC at first.
