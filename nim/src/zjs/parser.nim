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
  ## STUB (this task): empty Program. Real parsing in the next task.
  newProgram(0'u32, p.source.len.uint32)
