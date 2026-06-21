## The lexer — a single forward pass producing flat Token slices.
## Idiomatic Nim port of src/lexer.zc. Tokens slice into `source`.
import token

type
  Lexer* = object
    source*: string
    pos*: int

proc initLexer*(source: string): Lexer = Lexer(source: source, pos: 0)

proc nextToken*(lx: var Lexer): Token =
  ## STUB (Task 2): emit Eof immediately. Real tokenization in Task 3+.
  tokenEof(lx.source.len.uint32)

iterator tokens*(lx: var Lexer): Token =
  ## Yields every token through and including the final Eof.
  while true:
    let t = lx.nextToken()
    yield t
    if t.kind == Eof: break
