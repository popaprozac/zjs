## Recursive-descent parser — idiomatic Nim port of src/parser.zc.
## Consumes the Phase-2a lexer's Token stream; produces a ref AstNode tree.
import std/strutils
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

# ------------------------------------------------------------------
# Cursor helpers
# ------------------------------------------------------------------

proc peek(p: Parser): Token {.inline.} =
  ## The current token; always safe because the last is always Eof.
  p.toks[p.pos]

proc advance(p: var Parser): Token {.inline.} =
  ## Return current token and move forward.
  result = p.toks[p.pos]
  if p.pos < p.toks.len - 1:
    inc p.pos

proc check(p: Parser, k: TokenKind): bool {.inline.} =
  p.toks[p.pos].kind == k

proc expect(p: var Parser, k: TokenKind): bool {.inline.} =
  ## Advance if the current token matches k; return true. Otherwise leave
  ## pos unchanged and return false. For this task all inputs are valid,
  ## so a false result is only a guard (caller can ignore in the battery).
  if p.toks[p.pos].kind == k:
    discard p.advance()
    true
  else:
    false

# ------------------------------------------------------------------
# Numeric literal decoding — port of parse_number_literal / parse_int_prefix
# ------------------------------------------------------------------

proc parseIntPrefix(digits: string, base: int): float64 =
  ## Accumulate a base-N integer from a digit string (hex/bin/oct).
  var acc = 0.0
  for c in digits:
    var d: int
    if c >= '0' and c <= '9': d = ord(c) - ord('0')
    elif c >= 'a' and c <= 'f': d = ord(c) - ord('a') + 10
    elif c >= 'A' and c <= 'F': d = ord(c) - ord('A') + 10
    else: return acc
    acc = acc * float64(base) + float64(d)
  acc

proc parseNumberLiteral(src: string, start, length: uint32): float64 =
  ## Port of fn parse_number_literal in src/parser.zc.
  ## Strip numeric separators `_`, then dispatch on prefix.
  var buf = newStringOfCap(int(length))
  var i = 0'u32
  while i < length:
    let c = src[int(start + i)]
    if c != '_': buf.add(c)
    inc i

  # Hex / binary / octal
  if buf.len >= 2 and buf[0] == '0':
    let c1 = buf[1]
    if c1 == 'x' or c1 == 'X': return parseIntPrefix(buf[2..^1], 16)
    if c1 == 'b' or c1 == 'B': return parseIntPrefix(buf[2..^1], 2)
    if c1 == 'o' or c1 == 'O': return parseIntPrefix(buf[2..^1], 8)

  # Decimal / scientific via parseFloat (matches C strtod for this domain)
  parseFloat(buf)

# ------------------------------------------------------------------
# Forward declaration
# ------------------------------------------------------------------

proc parseExpression(p: var Parser): AstNode

# ------------------------------------------------------------------
# parsePrimary — mirrors fn parse_primary in src/parser.zc
# ------------------------------------------------------------------

proc parsePrimary(p: var Parser): AstNode =
  let t = p.peek()
  case t.kind
  of NumberLit:
    discard p.advance()
    let v = parseNumberLiteral(p.source, t.start, t.length)
    return newNumber(t.start, t.start + t.length, v)

  of BigIntLit:
    discard p.advance()
    return newLeaf(BigIntExpr, t.start, t.start + t.length)

  of StringLit:
    discard p.advance()
    return newLeaf(StringExpr, t.start, t.start + t.length)

  of RegexLit:
    discard p.advance()
    return newLeaf(RegexExpr, t.start, t.start + t.length)

  of KwTrue:
    discard p.advance()
    return newBool(t.start, t.start + t.length, true)

  of KwFalse:
    discard p.advance()
    return newBool(t.start, t.start + t.length, false)

  of KwNull:
    discard p.advance()
    return newLeaf(NullExpr, t.start, t.start + t.length)

  of KwUndefined:
    discard p.advance()
    return newLeaf(UndefinedExpr, t.start, t.start + t.length)

  of KwThis:
    discard p.advance()
    return newLeaf(ThisExpr, t.start, t.start + t.length)

  of Identifier:
    discard p.advance()
    return newLeaf(IdentExpr, t.start, t.start + t.length)

  of LParen:
    let lp = p.advance()    # consume '('
    let inner = p.parseExpression()
    let close = p.peek()    # should be RParen
    discard p.expect(RParen)
    return newParen(lp.start, close.start + close.length, inner)

  else:
    # Unknown / unimplemented primary — skip and return nil.
    # (Later tasks will fill in array, object, template, etc.)
    discard p.advance()
    return nil

# ------------------------------------------------------------------
# parseExpression — for this task, just primaries. Later tasks extend this.
# ------------------------------------------------------------------

proc parseExpression(p: var Parser): AstNode =
  parsePrimary(p)

# ------------------------------------------------------------------
# parseStatement — bare expression (no ExpressionStmt wrapper per spec).
# Consumes an optional trailing semicolon.
# ------------------------------------------------------------------

proc parseStatement(p: var Parser): AstNode =
  result = p.parseExpression()
  # Optional trailing semicolon (harmless; keeps later tasks compatible)
  if p.check(Semicolon):
    discard p.advance()

# ------------------------------------------------------------------
# parseProgram — entry point
# ------------------------------------------------------------------

proc parseProgram*(p: var Parser): AstNode =
  var stmts: seq[AstNode]
  while p.peek().kind != Eof:
    let before = p.pos
    let s = p.parseStatement()
    if s != nil:
      stmts.add(s)
    # Guard against infinite loop if pos didn't advance
    if p.pos == before:
      break
  newProgram(0'u32, p.source.len.uint32, stmts)
