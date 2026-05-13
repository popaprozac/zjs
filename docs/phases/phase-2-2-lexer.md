# zjs Phase 2.2 — Lexer

> Second slice of Phase 2. Converts source text into a token stream.

## Scope

In scope:
- ASCII source, UTF-8 byte-transparent (Unicode IdentifierStart deferred)
- Whitespace + line comments (`//`) + block comments (`/* */`) — skipped
- Identifiers + keyword recognition
- Numeric literals: decimal int, decimal float, scientific, hex (`0x`), binary (`0b`), octal (`0o`)
- String literals: single + double quoted, with escape sequences validated (not yet decoded)
- Full ECMA-262 §12.7 punctuator set
- Lazy API (`next_token`) plus an eager helper for testing/CLI

Out of scope:
- Template literals `` `...${expr}...` `` — needs parser cooperation for substitution mode
- Regex literals — slash-vs-divide is context-sensitive; needs parser-driven re-lex
- BigInt suffix `123n`
- Numeric separators `1_000_000`
- Legacy octal literals (`017`)
- Unicode IdentifierStart/IdentifierPart beyond ASCII (`$`, `_`, `[A-Za-z0-9]` only)
- Source-position decoding to `(line, column)` — we track line only for now

## Token model

```zc
struct Token {
    kind:   TokenKind,   // enum, ~80 variants
    start:  u32,         // byte offset into source
    length: u32,         // byte length of the slice
}
```

Tokens are 12-byte slices into the source. No allocation, no decoded
values. The parser/compiler will decode numeric values and string
contents on demand.

## Lexer API

```zc
struct Lexer { source: char*, pos: usize, len: usize, line: u32 }

impl Lexer {
    fn new(source: char*, len: usize) -> Self;
    fn next_token(self) -> Token;     // returns Token{kind: Eof, ...} when exhausted
}
```

For tests and the CLI dumper, an eager helper tokenizes a whole source
into a fixed buffer:

```zc
fn tokenize_into(source: char*, len: usize, out: Token*, cap: usize) -> usize;
```

## Keyword recognition

Lexer-level (not parser-level), matching JSC/V8/Hermes. After scanning
an identifier we do a linear `streq_n` walk of the keyword table. ~40
keywords; not yet a perfect hash. **TODO:** length-bucketed lookup or
gperf-style perfect hash if profiling shows it matters.

Keywords landed in this phase (full ES2023 set so we don't churn the
enum later):

```
var let const  function return  if else  for while do  break continue
class extends super new this  true false null undefined
typeof delete void in of instanceof  throw try catch finally
switch case default  async await yield  import export from as
```

## Verification

- New test target `make test-lex` builds `build/lexer_test` from `tests/lexer_test.zc` and runs it.
- New CLI subcommand `./build/zjs lex <source>` dumps the token stream — useful for debugging.
- Test cases cover: empty input, whitespace-only, comments, every keyword, identifiers (basic + with `$`/`_`/digits), numbers (decimal/hex/binary/octal/scientific/float), strings (both quotes, basic escapes), every punctuator, a few small expressions end-to-end.

## Files

- `src/token.zc` — `TokenKind` enum + `Token` struct
- `src/lexer.zc` — `Lexer` + scanning routines + char classifiers + keyword table
- `src/lib.zc` — import token + lexer
- `tools/zjs.zc` — `lex` subcommand
- `tests/lexer_test.zc` — Zen-c test runner with assertion helpers
- `Makefile` — new `test-lex` target wired into `make test`

## What's next (Phase 2.3)

Parser. Recursive descent over an ECMA-262 expression-subset grammar
to start (literals, identifiers, unary/binary/assignment, function
calls, member access). AST node types as tagged structs. Output: an
AST that the bytecode compiler will consume in Phase 3.
