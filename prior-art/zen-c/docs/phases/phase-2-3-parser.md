# zjs Phase 2.3 — Parser (Expressions)

> Third slice of Phase 2. Turns the lexer's token stream into an AST.

## Scope

In scope:
- Full ECMA-262 §13 expression grammar — precedence + associativity correct
- All binary operators: `**`, `* / %`, `+ -`, `<< >> >>>`, `< > <= >= in instanceof`, `== != === !==`, `&`, `^`, `|`, `&&`, `||`, `??`
- Unary prefix: `! ~ + - typeof void delete ++ --`
- Postfix: `++ --`
- Conditional (ternary): `cond ? a : b`
- Assignment (right-assoc): `= += -= *= /= %= **= <<= >>= >>>= &= |= ^= &&= ||= ??=`
- Comma (sequence): `a, b, c`
- Call: `f(a, b)`
- Member access: `a.b`, `a[b]`
- Optional chaining: `a?.b`, `a?.()`, `a?.[b]`
- `new` (with and without args)
- Parenthesized expressions
- Array literals `[a, b, c]` (with empty slots via comma)
- Object literals `{a: 1, b: 2}` — identifier keys, string keys, identifier-shorthand
- Top-level program = `(expression ";")* EOF` — `parse_program` returns a `Program` node with `children[]`
- AST dump CLI subcommand: `zjs parse <source>`

Out of scope (later sub-phases):
- Statements: `var/let/const`, `if/else`, `return`, blocks, `for`, `while`, `do`, `break`, `continue`, `switch`, `throw`, `try`, `with` — Phase 2.4
- Functions: `function` declarations + expressions, arrow functions — Phase 2.4 / 2.5
- Classes — Phase 2.5
- Template literals — separate; needs lexer cooperation
- Regex literals — needs context-sensitive lex
- Spread/rest in call/array/object — defer (tokens already recognized as `Ellipsis`)
- ASI (Automatic Semicolon Insertion) — require explicit `;` for now
- Module syntax (`import`/`export`) — much later

## AST representation

Flat tagged struct, ~80 bytes per node. All possible fields present; only the relevant ones are used per kind. Trades memory for simplicity — appropriate for a hobby-project AST, especially since the AST is transient (lives only during compilation to bytecode).

```zc
struct AstNode {
    kind:           NodeKind,
    start:          u32,        // source span (inclusive)
    end:            u32,        // source span (exclusive)
    op:             TokenKind,  // Binary / Logical / Unary / Postfix / Assignment / Computed
    num:            f64,        // NumberLit
    bool_value:     bool,       // BoolLit
    left:           AstNode*,   // first child
    right:          AstNode*,   // second child
    third:          AstNode*,   // third child (Conditional alt)
    children:       AstNode**,  // variadic children — Call args / Array / Object / Program / Sequence
    children_count: u32,
    name_start:     u32,        // Member name / ObjectProp key
    name_length:    u32,
}
```

`NodeKind` enum: Program, NumberLit, StringLit, BoolLit, NullLit, UndefinedLit, ThisExpr, Identifier, Binary, Logical, Unary, Postfix, Conditional, Assignment, Call, OptionalCall, New, Member, OptionalMember, Computed, Sequence, Array, Object, ObjectProp, Paren.

## Memory ownership

Parser owns all allocations via a tracked allocation list. Caller calls `parser_free_result` to release everything in one shot. Trees can't outlive their parser — fine for our usage (parse → compile-to-bytecode → discard).

When the GC lands (Phase 5), the AST will still be heap-allocated outside the GC — it's never visible to JS, so no need to integrate.

## Number decoding

Numeric literals are decoded at parse time and stored as `f64` on the `NumberLit` node. `strtod` for decimal/scientific; hand-rolled converters for hex (`0x`), binary (`0b`), octal (`0o`).

String contents are NOT decoded — `StringLit` carries only the source slice. Escape resolution happens at bytecode-emission time (Phase 3).

## Precedence table (highest first → lowest at root)

| Level | Productions | Assoc |
|---|---|---|
| 0 | Primary: literals, ident, `this`, `(expr)`, `[…]`, `{…}` | — |
| 1 | Member: `.`, `[]`, `?.`, Call: `()`, `?.()`, `new` | left |
| 2 | Postfix: `x++`, `x--` | left |
| 3 | Unary prefix: `! ~ + - typeof void delete ++ --` | right |
| 4 | Exponentiation: `**` | right |
| 5 | Multiplicative: `* / %` | left |
| 6 | Additive: `+ -` | left |
| 7 | Shift: `<< >> >>>` | left |
| 8 | Relational: `< > <= >= in instanceof` | left |
| 9 | Equality: `== != === !==` | left |
| 10 | Bitwise AND: `&` | left |
| 11 | Bitwise XOR: `^` | left |
| 12 | Bitwise OR: \| | left |
| 13 | Logical AND: `&&` | left |
| 14 | Logical OR: \|\| | left |
| 15 | Nullish: `??` | left |
| 16 | Ternary: `?:` | right |
| 17 | Assignment | right |
| 18 | Comma (sequence) | left |

## Verification

- `make test-parse` builds `build/parser_test` from `tests/parser_test.zc` and runs it.
- New CLI subcommand `./build/zjs parse <source>` dumps the AST as an indented tree.
- Test cases cover: every primary form, every operator's precedence + associativity, mixed expressions, member chains, call chains, arrays, objects, ternary, assignment, parenthesized expressions, syntax-error recovery (or at least non-crash on malformed input).

## Files

- `src/ast.zc` — `NodeKind`, `AstNode`, allocator, recursive freer
- `src/parser.zc` — `Parser` + recursive-descent functions
- `src/lib.zc` — add imports
- `tools/zjs.zc` — `parse` subcommand + AST tree printer
- `tests/parser_test.zc` — test runner with shape assertions
- `Makefile` — `test-parse` target wired into `make test`

## What's next (Phase 2.4)

Statements. Parse `var/let/const x = expr;`, `if (cond) stmt else stmt`, `return expr;`, block statements `{ ... }`. With statements in hand, Phase 3 (bytecode compiler) can start emitting executable programs.
