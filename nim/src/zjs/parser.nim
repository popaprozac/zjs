## Recursive-descent parser — idiomatic Nim port of src/parser.zc.
## Consumes the Phase-2a lexer's Token stream; produces a ref AstNode tree.
import std/strutils
import token, lexer, ast

type
  Parser* = object
    source*: string
    toks*: seq[Token]
    pos*: int
    hadError*: bool   ## set by expect() on mismatch; signals parse failure

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
  ## Advance if the current token matches k; return true. Otherwise set
  ## hadError, leave pos unchanged, and return false.
  if p.toks[p.pos].kind == k:
    discard p.advance()
    true
  else:
    p.hadError = true
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
proc parseConditional(p: var Parser): AstNode
proc parseSequence(p: var Parser): AstNode
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
proc parseCallMember(p: var Parser): AstNode
proc parseArguments(p: var Parser): (seq[AstNode], uint32)
proc parseAssignmentExpr(p: var Parser): AstNode
proc parseArray(p: var Parser): AstNode
proc parseObject(p: var Parser): AstNode

# ------------------------------------------------------------------
# isKeywordName — returns true for Kw* token kinds that may appear
# as object property names (e.g. {if: 1, return: 2}).
# ------------------------------------------------------------------

proc isKeywordName(k: TokenKind): bool {.inline.} =
  k in {KwVar, KwLet, KwConst,
        KwFunction, KwReturn,
        KwIf, KwElse,
        KwFor, KwWhile, KwDo,
        KwBreak, KwContinue,
        KwClass, KwExtends, KwSuper, KwNew, KwThis,
        KwTrue, KwFalse, KwNull, KwUndefined,
        KwTypeof, KwDelete, KwVoid, KwIn, KwOf, KwInstanceof,
        KwThrow, KwTry, KwCatch, KwFinally,
        KwSwitch, KwCase, KwDefault,
        KwWith,
        KwAsync, KwAwait, KwYield,
        KwImport, KwExport, KwFrom, KwAs,
        KwGet, KwSet}

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

  of LBracket:
    return parseArray(p)

  of LBrace:
    return parseObject(p)

  else:
    # Unknown / unimplemented primary — skip and return nil.
    # (Later tasks will fill in template, etc.)
    discard p.advance()
    return nil

# ------------------------------------------------------------------
# parseArray — port of fn parse_array in src/parser.zc (~4314).
# ------------------------------------------------------------------

proc parseArray(p: var Parser): AstNode =
  let lb = p.advance()                       # consume '['
  var elems: seq[AstNode]
  while p.peek().kind notin {RBracket, Eof}:
    var elem: AstNode
    if p.peek().kind == Comma:
      # Elision: comma in element position → HoleExpr (zero-width at comma start)
      let h = p.peek()
      elem = newLeaf(HoleExpr, h.start, h.start)
    elif p.peek().kind == Ellipsis:
      let dots = p.advance()
      let inner = parseAssignmentExpr(p)
      if inner == nil: break
      elem = newSpread(dots.start, inner.`end`, inner)
    else:
      elem = parseAssignmentExpr(p)
      if elem == nil: break
    elems.add(elem)
    if p.peek().kind != Comma: break
    discard p.advance()                      # consume ','
  let close = p.peek()
  discard p.expect(RBracket)
  newArray(lb.start, close.start + close.length, elems)

# ------------------------------------------------------------------
# parseObject — port of fn parse_object in src/parser.zc (~4375).
# ------------------------------------------------------------------

proc parseObject(p: var Parser): AstNode =
  let lb = p.advance()                       # consume '{'
  var props: seq[AstNode]
  while p.peek().kind notin {RBrace, Eof}:
    if p.peek().kind == Ellipsis:
      let dots = p.advance()
      let inner = parseAssignmentExpr(p)
      if inner == nil: break
      props.add(newSpread(dots.start, inner.`end`, inner))
    elif p.peek().kind == LBracket:
      # Computed key: [expr]: val
      discard p.advance()                    # consume '['
      let key = parseAssignmentExpr(p)
      if key == nil: break
      if not p.expect(RBracket): break
      if p.peek().kind != Colon: break       # computed method — out of scope
      discard p.advance()                    # consume ':'
      let val = parseAssignmentExpr(p)
      if val == nil: break
      # keyStart/keyLength = 0/0 for computed; computedKey = key
      props.add(newObjectProp(key.start, val.`end`, 0'u32, 0'u32, val, key))
    else:
      # Named key: Identifier, keyword-as-name, StringLit, NumberLit
      let keyTok = p.peek()
      if keyTok.kind notin {Identifier, StringLit, NumberLit} and not isKeywordName(keyTok.kind):
        break
      discard p.advance()                    # consume the key token
      let nxt = p.peek().kind
      if nxt == Colon:
        discard p.advance()                  # consume ':'
        let val = parseAssignmentExpr(p)
        if val == nil: break
        props.add(newObjectProp(keyTok.start, val.`end`,
                                keyTok.start, keyTok.length, val, nil))
      elif nxt == Comma or nxt == RBrace:
        # Shorthand {a} — value = IdentExpr spanning the key token
        let v = newLeaf(IdentExpr, keyTok.start, keyTok.start + keyTok.length)
        props.add(newObjectProp(keyTok.start, keyTok.start + keyTok.length,
                                keyTok.start, keyTok.length, v, nil))
      else:
        # '(' = method, 'get'/'set' prefix, '*' = generator — out of scope
        break
    if p.peek().kind != Comma: break
    discard p.advance()                      # consume ','
  let close = p.peek()
  discard p.expect(RBrace)
  newObject(lb.start, close.start + close.length, props)

# ------------------------------------------------------------------
# parseAssignmentExpr — no-comma entry; routes through conditional.
# ------------------------------------------------------------------

proc parseAssignmentExpr(p: var Parser): AstNode =
  parseConditional(p)

# ------------------------------------------------------------------
# parseArguments — port of fn parse_arguments in src/parser.zc.
# Consumes '(' arglist ')'. Returns (args, endOffset).
# ------------------------------------------------------------------

proc parseArguments(p: var Parser): (seq[AstNode], uint32) =
  discard p.advance()   # consume '('
  var args: seq[AstNode] = @[]

  if p.peek().kind != RParen:
    while true:
      var arg: AstNode
      if p.peek().kind == Ellipsis:
        let dots = p.advance()          # consume '...'
        let inner = p.parseAssignmentExpr()
        if inner == nil: break
        arg = newSpread(dots.start, inner.`end`, inner)
      else:
        arg = p.parseAssignmentExpr()
        if arg == nil: break
      args.add(arg)
      if p.peek().kind == Comma:
        discard p.advance()              # consume ','
        # Trailing comma: ')' right after the comma ends the list
        if p.peek().kind == RParen: break
      else:
        break

  let close = p.peek()
  discard p.expect(RParen)
  result = (args, close.start + close.length)

# ------------------------------------------------------------------
# parseCallMember — Level 1 (new, call, member, optional chain).
# Port of fn parse_call_member in src/parser.zc.
# ------------------------------------------------------------------

proc parseCallMember(p: var Parser): AstNode =
  var expr: AstNode

  if p.peek().kind == KwNew:
    let newTok = p.advance()   # consume 'new'

    # new.target — deferred; skip to regular `new Callee(args?)`.
    # (We do NOT check for new.target here — no battery cases need it.)

    # Build the callee via primary + member-only loop (no calls).
    var callee = p.parsePrimary()
    if callee == nil: return nil

    while true:
      let kk = p.peek().kind
      if kk == Dot:
        discard p.advance()
        let idTok = p.advance()
        callee = newMember(NodeKind.Member, callee.start,
                           idTok.start + idTok.length,
                           idTok.start, idTok.length, callee)
      elif kk == LBracket:
        discard p.advance()
        let idx = p.parseExpression()
        if idx == nil: return nil
        let close = p.peek()
        discard p.expect(RBracket)
        callee = newComputed(NodeKind.Computed, callee.start,
                             close.start + close.length, callee, idx)
      else:
        break

    # Optional argument list.
    if p.peek().kind == LParen:
      let (args, argsEnd) = p.parseArguments()
      expr = newCall(NodeKind.New, newTok.start, argsEnd, callee, args)
    else:
      expr = newCall(NodeKind.New, newTok.start, callee.`end`, callee, @[])

  else:
    expr = p.parsePrimary()
    if expr == nil: return nil

  # Suffix loop — call / member / computed / optional chain.
  while true:
    let k = p.peek().kind
    if k == Dot:
      discard p.advance()
      let idTok = p.advance()
      expr = newMember(NodeKind.Member, expr.start,
                       idTok.start + idTok.length,
                       idTok.start, idTok.length, expr)
    elif k == LBracket:
      discard p.advance()
      let idx = p.parseExpression()
      if idx == nil: return nil
      let close = p.peek()
      discard p.expect(RBracket)
      expr = newComputed(NodeKind.Computed, expr.start,
                         close.start + close.length, expr, idx)
    elif k == LParen:
      let (args, argsEnd) = p.parseArguments()
      expr = newCall(NodeKind.Call, expr.start, argsEnd, expr, args)
    elif k == QuestionDot:
      discard p.advance()
      let after = p.peek().kind
      if after == LParen:
        let (args, argsEnd) = p.parseArguments()
        expr = newCall(NodeKind.OptionalCall, expr.start, argsEnd, expr, args)
      elif after == LBracket:
        discard p.advance()
        let idx = p.parseExpression()
        if idx == nil: return nil
        let close = p.peek()
        discard p.expect(RBracket)
        expr = newComputed(NodeKind.OptionalComputed, expr.start,
                           close.start + close.length, expr, idx)
      else:
        let idTok = p.advance()
        expr = newMember(NodeKind.OptionalMember, expr.start,
                         idTok.start + idTok.length,
                         idTok.start, idTok.length, expr)
    else:
      return expr

# ------------------------------------------------------------------
# Operator precedence ladder — mirrors parse_postfix..parse_nullish in
# src/parser.zc. Level names and associativity follow Zen-c exactly.
# ------------------------------------------------------------------

# Level 2 — postfix ++ / --.
# Operand is parseCallMember (rewired from parsePrimary).
proc parsePostfix(p: var Parser): AstNode =
  result = parseCallMember(p)
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
# parseConditional — Level 16 — ternary ?:  (right-associative).
# Port of fn parse_conditional in src/parser.zc (~3280).
# Branches: parse_nullish; if no '?' return; else parse two
# parse_assignment arms. Right-assoc because alt = parseAssignmentExpr.
# ------------------------------------------------------------------

proc parseConditional(p: var Parser): AstNode =
  let cond = parseNullish(p)
  if cond == nil: return nil
  if p.peek().kind != Question: return cond
  discard p.advance()                   # consume '?'
  let conseq = parseAssignmentExpr(p)
  if conseq == nil: return nil
  if not p.expect(Colon): return nil
  let alt = parseAssignmentExpr(p)
  if alt == nil: return nil
  newConditional(cond.start, alt.`end`, cond, conseq, alt)

# ------------------------------------------------------------------
# parseSequence — Level 17 — comma / sequence operator.
# Port of fn parse_expression in src/parser.zc (~2935).
# The Zen-c function is named parse_expression but produces Sequence.
# ------------------------------------------------------------------

proc parseSequence(p: var Parser): AstNode =
  let first = parseAssignmentExpr(p)
  if first == nil: return nil
  if p.peek().kind != Comma: return first
  var items = @[first]
  while p.peek().kind == Comma:
    discard p.advance()                 # consume ','
    let nxt = parseAssignmentExpr(p)
    if nxt == nil: break
    items.add(nxt)
  newSequence(first.start, items[^1].`end`, items)

# ------------------------------------------------------------------
# parseExpression — entry point for expressions; routes through
# the sequence level (Level 17, the top of the expression ladder).
# ------------------------------------------------------------------

proc parseExpression(p: var Parser): AstNode =
  parseSequence(p)

# ------------------------------------------------------------------
# parseVarDecl — port of fn parse_var_decl in src/parser.zc.
# Identifier-binding only (destructuring is out of scope this increment).
# ------------------------------------------------------------------

proc parseVarDecl(p: var Parser): AstNode =
  let kw = p.advance()          # consume var / let / const
  var declarators: seq[AstNode]
  var lastEnd = kw.start + kw.length

  while true:
    let declStart = p.peek().start
    let nameTok = p.peek()
    if nameTok.kind != Identifier:
      break                     # guard: non-identifier = stop (pattern etc.)
    discard p.advance()         # consume the identifier

    var declEnd = nameTok.start + nameTok.length
    var init: AstNode = nil

    if p.peek().kind == Eq:
      discard p.advance()       # consume '='
      init = p.parseAssignmentExpr()
      if init != nil:
        declEnd = init.`end`

    let d = newDeclarator(declStart, declEnd,
                          nameTok.start, nameTok.length, init)
    declarators.add(d)
    lastEnd = declEnd

    if p.peek().kind != Comma:
      break
    discard p.advance()         # consume ','

  # Consume optional trailing semicolon (ASI not required this increment)
  if p.peek().kind == Semicolon:
    discard p.advance()

  newVarDecl(kw.start, lastEnd, kw.kind, declarators)

# ------------------------------------------------------------------
# parseStatement — bare expression (no ExpressionStmt wrapper per spec).
# Consumes an optional trailing semicolon.
# ------------------------------------------------------------------

proc parseStatement(p: var Parser): AstNode =
  # Dispatch variable declarations
  if p.peek().kind in {KwVar, KwLet, KwConst}:
    return p.parseVarDecl()
  # Expression statement path
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
