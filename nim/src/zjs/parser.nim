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
# Forward declarations
# ------------------------------------------------------------------

proc parseExpression(p: var Parser): AstNode
proc parseNullish(p: var Parser): AstNode
proc parseLogicalOr(p: var Parser): AstNode
proc parseLogicalAnd(p: var Parser): AstNode
proc parseBitOr(p: var Parser): AstNode
proc parseBitXor(p: var Parser): AstNode
proc parseBitAnd(p: var Parser): AstNode
proc parseEquality(p: var Parser): AstNode
proc parseRelational(p: var Parser): AstNode
proc parseShift(p: var Parser): AstNode
proc parseAdditive(p: var Parser): AstNode
proc parseMultiplicative(p: var Parser): AstNode
proc parseExponent(p: var Parser): AstNode
proc parseUnary(p: var Parser): AstNode
proc parsePostfix(p: var Parser): AstNode

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
# Operator precedence ladder — mirrors parse_postfix..parse_nullish in
# src/parser.zc. Level names and associativity follow Zen-c exactly.
# ------------------------------------------------------------------

# Level 2 — postfix ++ / --.
# Operand is parsePrimary here (call/member is a later increment).
proc parsePostfix(p: var Parser): AstNode =
  result = parsePrimary(p)
  if result == nil: return nil
  let k = p.peek().kind
  if k == PlusPlus or k == MinusMinus:
    let opTok = p.advance()
    result = newUnary(NodeKind.Postfix,
                      result.start,
                      opTok.start + opTok.length,
                      opTok.kind,
                      result)

# Level 3 — unary prefix (right-associative; recurses itself).
proc parseUnary(p: var Parser): AstNode =
  let k = p.peek().kind
  if k == Bang or k == Tilde or
     k == Plus or k == Minus or
     k == PlusPlus or k == MinusMinus or
     k == KwTypeof or k == KwVoid or k == KwDelete:
    let opTok = p.advance()
    let operand = parseUnary(p)
    if operand == nil: return nil
    return newUnary(NodeKind.Unary, opTok.start, operand.`end`, opTok.kind, operand)
  return parsePostfix(p)

# Level 4 — exponentiation (right-associative).
proc parseExponent(p: var Parser): AstNode =
  result = parseUnary(p)
  if result == nil: return nil
  if p.peek().kind != StarStar: return result
  let opTok = p.advance()
  let rhs = parseExponent(p)   # right-recursive
  if rhs == nil: return nil
  result = newBinary(NodeKind.Binary, result.start, rhs.`end`, opTok.kind, result, rhs)

# Level 5 — multiplicative.
proc parseMultiplicative(p: var Parser): AstNode =
  result = parseExponent(p)
  if result == nil: return nil
  while p.peek().kind in {Star, Slash, Percent}:
    let opTok = p.advance()
    let rhs = parseExponent(p)
    if rhs == nil: return nil
    result = newBinary(NodeKind.Binary, result.start, rhs.`end`, opTok.kind, result, rhs)

# Level 6 — additive.
proc parseAdditive(p: var Parser): AstNode =
  result = parseMultiplicative(p)
  if result == nil: return nil
  while p.peek().kind in {Plus, Minus}:
    let opTok = p.advance()
    let rhs = parseMultiplicative(p)
    if rhs == nil: return nil
    result = newBinary(NodeKind.Binary, result.start, rhs.`end`, opTok.kind, result, rhs)

# Level 7 — shift.
proc parseShift(p: var Parser): AstNode =
  result = parseAdditive(p)
  if result == nil: return nil
  while p.peek().kind in {LtLt, GtGt, GtGtGt}:
    let opTok = p.advance()
    let rhs = parseAdditive(p)
    if rhs == nil: return nil
    result = newBinary(NodeKind.Binary, result.start, rhs.`end`, opTok.kind, result, rhs)

# Level 8 — relational.
# no_in flag omitted (no for-loops yet); `in` always allowed.
proc parseRelational(p: var Parser): AstNode =
  result = parseShift(p)
  if result == nil: return nil
  while true:
    let k = p.peek().kind
    if k notin {Lt, Gt, LtEq, GtEq, KwIn, KwInstanceof}: break
    let opTok = p.advance()
    let rhs = parseShift(p)
    if rhs == nil: return nil
    result = newBinary(NodeKind.Binary, result.start, rhs.`end`, opTok.kind, result, rhs)

# Level 9 — equality.
proc parseEquality(p: var Parser): AstNode =
  result = parseRelational(p)
  if result == nil: return nil
  while p.peek().kind in {EqEq, BangEq, EqEqEq, BangEqEq}:
    let opTok = p.advance()
    let rhs = parseRelational(p)
    if rhs == nil: return nil
    result = newBinary(NodeKind.Binary, result.start, rhs.`end`, opTok.kind, result, rhs)

# Level 10 — bitwise AND.
proc parseBitAnd(p: var Parser): AstNode =
  result = parseEquality(p)
  if result == nil: return nil
  while p.peek().kind == Amp:
    let opTok = p.advance()
    let rhs = parseEquality(p)
    if rhs == nil: return nil
    result = newBinary(NodeKind.Binary, result.start, rhs.`end`, opTok.kind, result, rhs)

# Level 11 — bitwise XOR.
proc parseBitXor(p: var Parser): AstNode =
  result = parseBitAnd(p)
  if result == nil: return nil
  while p.peek().kind == Caret:
    let opTok = p.advance()
    let rhs = parseBitAnd(p)
    if rhs == nil: return nil
    result = newBinary(NodeKind.Binary, result.start, rhs.`end`, opTok.kind, result, rhs)

# Level 12 — bitwise OR.
proc parseBitOr(p: var Parser): AstNode =
  result = parseBitXor(p)
  if result == nil: return nil
  while p.peek().kind == Pipe:
    let opTok = p.advance()
    let rhs = parseBitXor(p)
    if rhs == nil: return nil
    result = newBinary(NodeKind.Binary, result.start, rhs.`end`, opTok.kind, result, rhs)

# Level 13 — logical AND.
proc parseLogicalAnd(p: var Parser): AstNode =
  result = parseBitOr(p)
  if result == nil: return nil
  while p.peek().kind == AmpAmp:
    let opTok = p.advance()
    let rhs = parseBitOr(p)
    if rhs == nil: return nil
    result = newBinary(NodeKind.Logical, result.start, rhs.`end`, opTok.kind, result, rhs)

# Level 14 — logical OR.
proc parseLogicalOr(p: var Parser): AstNode =
  result = parseLogicalAnd(p)
  if result == nil: return nil
  while p.peek().kind == PipePipe:
    let opTok = p.advance()
    let rhs = parseLogicalAnd(p)
    if rhs == nil: return nil
    result = newBinary(NodeKind.Logical, result.start, rhs.`end`, opTok.kind, result, rhs)

# Level 15 — nullish coalescing.
proc parseNullish(p: var Parser): AstNode =
  result = parseLogicalOr(p)
  if result == nil: return nil
  while p.peek().kind == QuestionQuestion:
    let opTok = p.advance()
    let rhs = parseLogicalOr(p)
    if rhs == nil: return nil
    result = newBinary(NodeKind.Logical, result.start, rhs.`end`, opTok.kind, result, rhs)

# ------------------------------------------------------------------
# parseExpression — entry point for expressions; nullish is top of
# this increment's ladder. Comma/assignment/conditional come later.
# ------------------------------------------------------------------

proc parseExpression(p: var Parser): AstNode =
  parseNullish(p)

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
