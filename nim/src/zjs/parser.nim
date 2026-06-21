## Recursive-descent parser — idiomatic Nim port of src/parser.zc.
## Consumes the Phase-2a lexer's Token stream; produces a ref AstNode tree.
import std/strutils
import token, lexer, ast

type
  Parser* = object
    source*: string
    toks*: seq[Token]
    pos*: int
    hadError*: bool        ## set by expect() on mismatch; signals parse failure
    noIn*: bool            ## when true, KwIn is NOT treated as a relational operator (for-init)
    inGenerator*: bool     ## true when parsing inside a generator body
    inAsync*: bool         ## true when parsing inside an async function body

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
# Cover-grammar reinterpretation — Array/Object literal → Pattern
# ------------------------------------------------------------------

proc reinterpretAsPattern(node: AstNode): AstNode

proc reinterpretAssignTarget(node: AstNode): AstNode =
  if node == nil: return nil
  case node.kind
  of Array, Object: reinterpretAsPattern(node)
  of Paren: reinterpretAssignTarget(node.inner)
  else: node            # IdentExpr / Member / Computed / etc — leaf target

proc reinterpretAsPattern(node: AstNode): AstNode =
  if node == nil: return nil
  case node.kind
  of Array:
    var entries: seq[AstNode]
    for el in node.elems:
      if el == nil or el.kind == HoleExpr:
        entries.add(newPatternEntry(0'u32, 0'u32, 0'u32, 0'u32, nil, nil, nil, false))
      elif el.kind == Spread:
        entries.add(newPatternEntry(el.start, el.`end`, 0'u32, 0'u32, reinterpretAssignTarget(el.spreadArg), nil, nil, true))
      elif el.kind == Assignment and el.assignOp == Eq:
        entries.add(newPatternEntry(el.start, el.`end`, 0'u32, 0'u32, reinterpretAssignTarget(el.target), el.value, nil, false))
      else:
        entries.add(newPatternEntry(el.start, el.`end`, 0'u32, 0'u32, reinterpretAssignTarget(el), nil, nil, false))
    return newPattern(ArrayPattern, node.start, node.`end`, entries)
  of Object:
    var entries: seq[AstNode]
    for pr in node.props:
      if pr.kind == Spread:
        entries.add(newPatternEntry(pr.start, pr.`end`, 0'u32, 0'u32, reinterpretAssignTarget(pr.spreadArg), nil, nil, true))
      elif pr.kind == ObjectProp:
        var tgt: AstNode
        var dflt: AstNode = nil
        if pr.propVal != nil and pr.propVal.kind == Assignment and pr.propVal.assignOp == Eq:
          tgt = reinterpretAssignTarget(pr.propVal.target); dflt = pr.propVal.value
        else:
          tgt = reinterpretAssignTarget(pr.propVal)
        entries.add(newPatternEntry(pr.start, pr.`end`, pr.keyStart, pr.keyLength, tgt, dflt, pr.computedKey, false))
    return newPattern(ObjectPattern, node.start, node.`end`, entries)
  of Paren:
    return reinterpretAsPattern(node.inner)
  else:
    return node

# ------------------------------------------------------------------
# Binding pattern forward declarations
# ------------------------------------------------------------------

proc parseBindingTarget(p: var Parser): AstNode
proc parseObjectPattern(p: var Parser): AstNode
proc parseArrayPattern(p: var Parser): AstNode

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
proc parseTemplateLit(p: var Parser): AstNode
proc parseFunctionDecl(p: var Parser, isAsync = false): AstNode
proc parseFunctionExpr(p: var Parser, isAsync = false): AstNode
proc parseParamList(p: var Parser): seq[AstNode]
proc parseBlock(p: var Parser): AstNode
proc lookaheadArrowParen(p: Parser): bool
proc parseArrowBody(p: var Parser, isAsync: bool): AstNode
proc parseArrowSingle(p: var Parser, isAsync: bool): AstNode
proc parseArrowParen(p: var Parser, isAsync: bool): AstNode
# Class forward declarations (Phase 2e-1)
proc parseClassDecl(p: var Parser): AstNode
proc parseClassExpr(p: var Parser): AstNode
proc parseClassBody(p: var Parser, isDerived: bool): seq[AstNode]
proc parseMethodBodyPair(p: var Parser): AstNode

# ------------------------------------------------------------------
# Arrow function helpers
# ------------------------------------------------------------------

proc lookaheadArrowParen(p: Parser): bool =
  ## Scan from current pos (at '(') to find matching ')'; check if followed by '=>'.
  var depth = 0
  var i = p.pos
  while i < p.toks.len:
    let k = p.toks[i].kind
    if k == LParen: inc depth
    elif k == RParen:
      dec depth
      if depth == 0:
        return i + 1 < p.toks.len and p.toks[i+1].kind == Arrow
    elif k == Eof: return false
    inc i
  false

# ------------------------------------------------------------------
# isKeywordName — returns true for Kw* token kinds that may appear
# as object property names (e.g. {if: 1, return: 2}).
# Also needed for binding-pattern keys (moved here from parseObject section).
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
# Binding pattern procs — parse `{...}` / `[...]` directly as patterns.
# These are used for binding contexts (var-decl, param-list, catch)
# as opposed to reinterpretAsPattern which handles assignment targets.
# ------------------------------------------------------------------

proc parseObjectPattern(p: var Parser): AstNode =
  let lb = p.advance()                       # '{'
  var entries: seq[AstNode]
  while p.peek().kind notin {RBrace, Eof}:
    let entryStart = p.peek().start
    if p.peek().kind == Ellipsis:            # ...rest (identifier only)
      discard p.advance()
      let id = p.advance()
      let ident = newLeaf(IdentExpr, id.start, id.start + id.length)
      entries.add(newPatternEntry(entryStart, id.start + id.length, 0'u32, 0'u32, ident, nil, nil, true))
      break                                  # rest must be last
    var computedKey: AstNode = nil
    var keyStart = 0'u32
    var keyLen = 0'u32
    if p.peek().kind == LBracket:            # [expr]: target
      discard p.advance()
      computedKey = parseAssignmentExpr(p)
      discard p.expect(RBracket)
    else:
      let keyTok = p.peek()
      if keyTok.kind notin {Identifier, StringLit, NumberLit} and not isKeywordName(keyTok.kind): break
      discard p.advance()
      keyStart = keyTok.start; keyLen = keyTok.length
    var target: AstNode
    if p.peek().kind == Colon:               # rename / nested
      discard p.advance()
      target = parseBindingTarget(p)
    elif computedKey != nil:
      break                                  # computed needs a target
    else:                                    # shorthand
      target = newLeaf(IdentExpr, keyStart, keyStart + keyLen)
    var dflt: AstNode = nil
    if p.peek().kind == Eq:
      discard p.advance()
      dflt = parseAssignmentExpr(p)
    let entryEnd = (if dflt != nil: dflt.`end` elif target != nil: target.`end` else: entryStart)
    entries.add(newPatternEntry(entryStart, entryEnd, keyStart, keyLen, target, dflt, computedKey, false))
    if p.peek().kind != Comma: break
    discard p.advance()
  let close = p.peek()
  discard p.expect(RBrace)
  newPattern(ObjectPattern, lb.start, close.start + close.length, entries)

proc parseArrayPattern(p: var Parser): AstNode =
  let lb = p.advance()                       # '['
  var entries: seq[AstNode]
  while p.peek().kind notin {RBracket, Eof}:
    let entryStart = p.peek().start
    if p.peek().kind == Comma:               # elision
      entries.add(newPatternEntry(entryStart, entryStart, 0'u32, 0'u32, nil, nil, nil, false))
      discard p.advance()                    # consume the comma
      continue
    elif p.peek().kind == Ellipsis:          # ...rest
      discard p.advance()
      let target = parseBindingTarget(p)
      entries.add(newPatternEntry(entryStart, (if target != nil: target.`end` else: entryStart), 0'u32, 0'u32, target, nil, nil, true))
      if p.peek().kind == Comma: discard p.advance()
      break                                  # rest must be last
    else:
      let target = parseBindingTarget(p)
      var dflt: AstNode = nil
      if p.peek().kind == Eq:
        discard p.advance()
        dflt = parseAssignmentExpr(p)
      let entryEnd = (if dflt != nil: dflt.`end` elif target != nil: target.`end` else: entryStart)
      entries.add(newPatternEntry(entryStart, entryEnd, 0'u32, 0'u32, target, dflt, nil, false))
    if p.peek().kind != Comma: break
    discard p.advance()
  let close = p.peek()
  discard p.expect(RBracket)
  newPattern(ArrayPattern, lb.start, close.start + close.length, entries)

proc parseBindingTarget(p: var Parser): AstNode =
  case p.peek().kind
  of LBrace:   parseObjectPattern(p)
  of LBracket: parseArrayPattern(p)
  else:
    let t = p.advance()
    newLeaf(IdentExpr, t.start, t.start + t.length)

proc parseArrowBody(p: var Parser, isAsync: bool): AstNode =
  let savedA = p.inAsync
  if isAsync: p.inAsync = true
  result = (if p.peek().kind == LBrace: parseBlock(p) else: parseAssignmentExpr(p))
  p.inAsync = savedA

proc parseArrowSingle(p: var Parser, isAsync: bool): AstNode =
  let nameTok = p.advance()             # identifier
  discard p.advance()                   # '=>'
  let param = newLeaf(IdentExpr, nameTok.start, nameTok.start + nameTok.length)
  let body = parseArrowBody(p, isAsync)
  newArrow(nameTok.start, (if body != nil: body.`end` else: nameTok.start), body, @[param], isAsync)

proc parseArrowParen(p: var Parser, isAsync: bool): AstNode =
  let lp = p.advance()                  # '('
  let params = parseParamList(p)
  discard p.expect(RParen)
  discard p.expect(Arrow)
  let body = parseArrowBody(p, isAsync)
  newArrow(lp.start, (if body != nil: body.`end` else: lp.start), body, params, isAsync)

# ------------------------------------------------------------------
# parseTemplateExprSlice — re-lex a substitution slice with absolute
# offsets, parse as an assignment expression.
# ------------------------------------------------------------------

proc parseTemplateExprSlice(p: var Parser, exprStart, exprEnd: uint32): AstNode =
  if exprStart >= exprEnd: return nil
  let sub = p.source[exprStart.int ..< exprEnd.int]
  var lx = initLexer(sub)
  var toks: seq[Token]
  for t in lx.tokens():
    var tt = t
    tt.start += exprStart        # shift to absolute
    toks.add(tt)
  var subP = Parser(source: p.source, toks: toks, pos: 0)
  parseAssignmentExpr(subP)

# ------------------------------------------------------------------
# parseTemplateLit — port of fn parse_template_lit in src/parser.zc.
# Splits the TemplateLit token body on ${ } substitutions, emitting
# alternating TemplatePartExpr / expression children.
# ------------------------------------------------------------------

proc parseTemplateLit(p: var Parser): AstNode =
  let t = p.advance()                          # the TemplateLit token
  let bodyStart = t.start + 1
  let bodyEnd = (if t.length >= 2: t.start + t.length - 1 else: t.start + 1)
  var children: seq[AstNode]
  var cur = bodyStart
  var segStart = cur
  while cur < bodyEnd:
    let c = p.source[cur.int]
    if c == '\\':
      cur += 1
      if cur < bodyEnd: cur += 1
      continue
    if c == '$' and cur + 1 < bodyEnd and p.source[(cur+1).int] == '{':
      children.add(newLeaf(TemplatePartExpr, segStart, cur))   # literal part [segStart, cur)
      cur += 2                                  # past `${`
      let exprStart = cur
      var depth = 1'u32
      while cur < bodyEnd:
        let ec = p.source[cur.int]
        if ec == '\\':
          cur += 1
          if cur < bodyEnd: cur += 1
          continue
        if ec == '{':
          depth += 1; cur += 1; continue
        if ec == '}':
          depth -= 1
          if depth == 0: break
          cur += 1; continue
        if ec == '"' or ec == '\'':
          let q = ec
          cur += 1
          while cur < bodyEnd and p.source[cur.int] != q:
            if p.source[cur.int] == '\\':
              cur += 1
              if cur < bodyEnd: cur += 1
            else: cur += 1
          if cur < bodyEnd: cur += 1
          continue
        if ec == '`':                           # nested template — skip as a unit
          cur += 1
          while cur < bodyEnd and p.source[cur.int] != '`':
            let tc = p.source[cur.int]
            if tc == '\\':
              cur += 1
              if cur < bodyEnd: cur += 1
              continue
            if tc == '$' and cur + 1 < bodyEnd and p.source[(cur+1).int] == '{':
              cur += 2
              var nd = 1'u32
              while cur < bodyEnd and nd > 0'u32:
                let nc = p.source[cur.int]
                if nc == '\\':
                  cur += 1
                  if cur < bodyEnd: cur += 1
                  continue
                if nc == '{': nd += 1
                if nc == '}':
                  nd -= 1
                  if nd == 0'u32:
                    cur += 1
                    break
                cur += 1
              continue
            cur += 1
          if cur < bodyEnd: cur += 1
          continue
        cur += 1
      let exprEnd = cur
      if cur < bodyEnd: cur += 1                # past `}`
      let e = parseTemplateExprSlice(p, exprStart, exprEnd)
      if e != nil: children.add(e)
      segStart = cur
      continue
    cur += 1
  children.add(newLeaf(TemplatePartExpr, segStart, bodyEnd))   # trailing part
  newTemplateExpr(t.start, t.start + t.length, children)

# ------------------------------------------------------------------
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

  of KwSuper:
    discard p.advance()
    return newLeaf(SuperExpr, t.start, t.start + t.length)

  of KwClass:
    return parseClassExpr(p)

  of Identifier:
    discard p.advance()
    return newLeaf(IdentExpr, t.start, t.start + t.length)

  of LParen:
    let lp = p.advance()    # consume '('
    let savedNoIn = p.noIn; p.noIn = false
    let inner = p.parseExpression()
    p.noIn = savedNoIn
    let close = p.peek()    # should be RParen
    discard p.expect(RParen)
    return newParen(lp.start, close.start + close.length, inner)

  of LBracket:
    let savedNoIn = p.noIn; p.noIn = false
    let arrNode = parseArray(p)
    p.noIn = savedNoIn
    return arrNode

  of LBrace:
    let savedNoIn = p.noIn; p.noIn = false
    let objNode = parseObject(p)
    p.noIn = savedNoIn
    return objNode

  of TemplateLit:
    return parseTemplateLit(p)

  of KwFunction:
    return parseFunctionExpr(p)

  of KwAsync:
    # async function expr: `async function ...`
    if p.toks[p.pos + 1].kind == KwFunction:
      discard p.advance()   # consume 'async'
      return parseFunctionExpr(p, isAsync = true)
    # Otherwise fall through: treat 'async' as an identifier
    discard p.advance()
    return newLeaf(IdentExpr, t.start, t.start + t.length)

  of KwYield:
    # Outside a generator, 'yield' is an identifier
    if not p.inGenerator:
      discard p.advance()
      return newLeaf(IdentExpr, t.start, t.start + t.length)
    # Inside a generator, handled in parseAssignmentExpr before we get here
    discard p.advance()
    return newLeaf(IdentExpr, t.start, t.start + t.length)

  of KwAwait:
    # Outside async, 'await' is an identifier
    if not p.inAsync:
      discard p.advance()
      return newLeaf(IdentExpr, t.start, t.start + t.length)
    # Inside async, handled in parseUnary before we get here
    discard p.advance()
    return newLeaf(IdentExpr, t.start, t.start + t.length)

  else:
    # Unknown / unimplemented primary — skip and return nil.
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

proc isPropertyNameStart(k: TokenKind): bool {.inline.} =
  ## Returns true for token kinds that can begin a property name (key).
  k in {Identifier, StringLit, NumberLit, LBracket, Star} or isKeywordName(k)

proc parseObject(p: var Parser): AstNode =
  let lb = p.advance()                       # consume '{'
  var props: seq[AstNode]
  while p.peek().kind notin {RBrace, Eof}:
    # --- spread ---
    if p.peek().kind == Ellipsis:
      let dots = p.advance()
      let inner = parseAssignmentExpr(p)
      if inner == nil: break
      props.add(newSpread(dots.start, inner.`end`, inner))
      if p.peek().kind != Comma: break
      discard p.advance()
      continue

    # Per-iteration flags
    var omAsync = false
    var omGen = false

    # Step 1: detect async prefix
    if p.peek().kind == KwAsync and p.toks[p.pos + 1].kind.isPropertyNameStart():
      omAsync = true
      discard p.advance()                    # consume 'async'

    # Step 2: detect generator prefix
    if p.peek().kind == Star:
      omGen = true
      discard p.advance()                    # consume '*'

    # Step 3: computed key [ expr ]
    if p.peek().kind == LBracket:
      discard p.advance()                    # consume '['
      let key = parseAssignmentExpr(p)
      if key == nil: break
      if not p.expect(RBracket): break
      if p.peek().kind == LParen:
        # Computed method: [k]() {}
        discard p.expect(LParen)
        let params = parseParamList(p)
        discard p.expect(RParen)
        let sg = p.inGenerator; let sa = p.inAsync
        p.inGenerator = omGen; p.inAsync = omAsync
        let body = parseBlock(p)
        p.inGenerator = sg; p.inAsync = sa
        let fn = newFunctionExpr(key.start, body.`end`, 0'u32, 0'u32, body, params, omAsync, omGen)
        props.add(newObjectProp(key.start, body.`end`, 0'u32, 0'u32, fn, key))
      elif p.peek().kind == Colon:
        # Computed data prop: [k]: val
        discard p.advance()                  # consume ':'
        let val = parseAssignmentExpr(p)
        if val == nil: break
        props.add(newObjectProp(key.start, val.`end`, 0'u32, 0'u32, val, key))
      else:
        break
      if p.peek().kind != Comma: break
      discard p.advance()
      continue

    # Step 4: named key
    let keyTok = p.peek()
    if keyTok.kind notin {Identifier, StringLit, NumberLit} and not isKeywordName(keyTok.kind):
      break

    # Accessor check: get/set followed by a property-name-start
    if keyTok.kind == Identifier and keyTok.length == 3'u32:
      let ktext = p.source[keyTok.start.int ..< (keyTok.start + keyTok.length).int]
      let isAccessor = (ktext == "get" or ktext == "set")
      let nextKind = p.toks[p.pos + 1].kind
      if isAccessor and nextKind.isPropertyNameStart() and nextKind != LParen:
        # It's an accessor: consume 'get'/'set', read real name
        discard p.advance()                  # consume 'get' or 'set'
        var realNameStart = 0'u32
        var realNameLen = 0'u32
        var computedAccKey: AstNode = nil
        if p.peek().kind == LBracket:
          # computed accessor: get [expr]() {}
          discard p.advance()                # consume '['
          computedAccKey = parseAssignmentExpr(p)
          if computedAccKey == nil: break
          if not p.expect(RBracket): break
        else:
          let realTok = p.advance()          # the property name token
          realNameStart = realTok.start
          realNameLen = realTok.length
        discard p.expect(LParen)
        let params = parseParamList(p)
        discard p.expect(RParen)
        let sg = p.inGenerator; let sa = p.inAsync
        p.inGenerator = false; p.inAsync = false
        let body = parseBlock(p)
        p.inGenerator = sg; p.inAsync = sa
        let fnStart = if computedAccKey != nil: computedAccKey.start else: realNameStart
        let fn = newFunctionExpr(fnStart, body.`end`, realNameStart, realNameLen, body, params)
        props.add(newObjectProp(keyTok.start, body.`end`, realNameStart, realNameLen, fn, computedAccKey))
        if p.peek().kind != Comma: break
        discard p.advance()
        continue

    # Plain named key: consume it, then dispatch on what follows
    discard p.advance()                      # consume the key token

    if p.peek().kind == LParen:
      # Named method: key() {}
      discard p.expect(LParen)
      let params = parseParamList(p)
      discard p.expect(RParen)
      let sg = p.inGenerator; let sa = p.inAsync
      p.inGenerator = omGen; p.inAsync = omAsync
      let body = parseBlock(p)
      p.inGenerator = sg; p.inAsync = sa
      let fn = newFunctionExpr(keyTok.start, body.`end`, 0'u32, 0'u32, body, params, omAsync, omGen)
      props.add(newObjectProp(keyTok.start, body.`end`, keyTok.start, keyTok.length, fn, nil))
    elif p.peek().kind == Colon:
      discard p.advance()                    # consume ':'
      let val = parseAssignmentExpr(p)
      if val == nil: break
      props.add(newObjectProp(keyTok.start, val.`end`,
                              keyTok.start, keyTok.length, val, nil))
    elif p.peek().kind == Eq:
      # Shorthand with default: { a = expr }
      discard p.advance()                  # consume '='
      let defaultExpr = parseAssignmentExpr(p)
      if defaultExpr == nil: break
      let ident = newLeaf(IdentExpr, keyTok.start, keyTok.start + keyTok.length)
      let assign = newAssignment(ident.start, defaultExpr.`end`, Eq, ident, defaultExpr)
      props.add(newObjectProp(keyTok.start, defaultExpr.`end`,
                              keyTok.start, keyTok.length, assign, nil))
    elif p.peek().kind in {Comma, RBrace}:
      # Shorthand {a}
      let v = newLeaf(IdentExpr, keyTok.start, keyTok.start + keyTok.length)
      props.add(newObjectProp(keyTok.start, keyTok.start + keyTok.length,
                              keyTok.start, keyTok.length, v, nil))
    else:
      break

    if p.peek().kind != Comma: break
    discard p.advance()                      # consume ','

  let close = p.peek()
  discard p.expect(RBrace)
  newObject(lb.start, close.start + close.length, props)

# ------------------------------------------------------------------
# parseAssignmentExpr — no-comma entry; handles plain and compound
# assignment (right-associative). Port of fn parse_assignment / is_assignment_op
# in src/parser.zc (~3153, ~3259).
# ------------------------------------------------------------------

proc isAssignmentOp(k: TokenKind): bool {.inline.} =
  k in {Eq, PlusEq, MinusEq, StarEq, StarStarEq, SlashEq, PercentEq,
        LtLtEq, GtGtEq, GtGtGtEq, AmpEq, PipeEq, CaretEq,
        AmpAmpEq, PipePipeEq, QuestionQuestionEq}

proc parseAssignmentExpr(p: var Parser): AstNode =
  # Arrow function detection — must come before yield/conditional
  if p.peek().kind == Identifier and p.toks[p.pos+1].kind == Arrow:
    return parseArrowSingle(p, false)
  if p.peek().kind == LParen and lookaheadArrowParen(p):
    return parseArrowParen(p, false)
  if p.peek().kind == KwAsync:
    if p.toks[p.pos+1].kind == Identifier and p.toks[p.pos+2].kind == Arrow:
      discard p.advance()               # 'async'
      return parseArrowSingle(p, true)
    if p.toks[p.pos+1].kind == LParen:
      let saved = p.pos
      discard p.advance()               # tentatively consume 'async'
      if lookaheadArrowParen(p):
        return parseArrowParen(p, true)
      p.pos = saved                     # not an arrow — rewind
  # yield expression — only inside a generator body
  if p.peek().kind == KwYield and p.inGenerator:
    let kw = p.advance()
    var delegate = false
    if p.peek().kind == Star: discard p.advance(); delegate = true
    var arg: AstNode = nil
    var endPos = kw.start + kw.length
    if delegate or p.peek().kind notin {Semicolon, RParen, RBracket, RBrace, Comma, Colon, Eof}:
      arg = parseAssignmentExpr(p)
      if arg != nil: endPos = arg.`end`
    return newYield(kw.start, endPos, arg, delegate)
  let left = parseConditional(p)
  if left == nil: return nil
  if isAssignmentOp(p.peek().kind):
    let op = p.advance()
    let right = parseAssignmentExpr(p)   # right-associative (recurse self)
    if right == nil: return nil
    let tgt =
      if op.kind == Eq and left.kind in {Array, Object}:
        reinterpretAsPattern(left)
      else:
        left
    return newAssignment(left.start, right.`end`, op.kind, tgt, right)
  return left

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
    elif k == TemplateLit:
      let tmpl = parseTemplateLit(p)
      expr = newTaggedTemplate(expr.start, tmpl.`end`, expr, tmpl)
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
  # await expression — only inside an async function body
  if p.peek().kind == KwAwait and p.inAsync:
    let kw = p.advance()
    let operand = parseUnary(p)
    return newAwait(kw.start, (if operand != nil: operand.`end` else: kw.start + kw.length), operand)
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
# When p.noIn is true, KwIn is NOT treated as an operator (for-init context).
proc parseRelational(p: var Parser): AstNode =
  result = parseShift(p)
  if result == nil: return nil
  while true:
    let k = p.peek().kind
    if k notin {Lt, Gt, LtEq, GtEq, KwIn, KwInstanceof}: break
    if k == KwIn and p.noIn: break      # noIn gate: stop before 'in'
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

# isBindingIdent — returns true for token kinds that may serve as a binding
# identifier (plain Identifier or contextual keywords that JS allows as names).
proc isBindingIdent(k: TokenKind): bool {.inline.} =
  k in {Identifier, KwYield, KwAwait, KwAsync,
        KwOf, KwFrom, KwAs, KwGet, KwSet}

proc parseVarDecl(p: var Parser, consumeSemi = true): AstNode =
  let kw = p.advance()          # consume var / let / const
  var declarators: seq[AstNode]
  var lastEnd = kw.start + kw.length

  while true:
    let declStart = p.peek().start
    # Pattern declarator: { or [
    if p.peek().kind in {LBrace, LBracket}:
      let pat = parseBindingTarget(p)
      var d = newDeclarator(pat.start, pat.`end`, 0'u32, 0'u32, nil)
      d.declPattern = pat
      if p.peek().kind == Eq:
        discard p.advance()     # consume '='
        let ini = p.parseAssignmentExpr()
        if ini != nil:
          d.init = ini
          d.`end` = ini.`end`
      declarators.add(d)
      lastEnd = d.`end`
      if p.peek().kind != Comma: break
      discard p.advance()       # consume ','
      continue

    let nameTok = p.peek()
    if not isBindingIdent(nameTok.kind):
      break                     # guard: non-identifier = stop
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

  # Consume optional trailing semicolon only when requested
  if consumeSemi and p.peek().kind == Semicolon:
    discard p.advance()

  newVarDecl(kw.start, lastEnd, kw.kind, declarators)

# ------------------------------------------------------------------
# Statement parsers — forward declarations
# ------------------------------------------------------------------

proc parseStatement(p: var Parser): AstNode
proc parseSwitch(p: var Parser): AstNode
proc parseTry(p: var Parser): AstNode
proc parseWith(p: var Parser): AstNode

proc parseBlock(p: var Parser): AstNode =
  let lb = p.advance()                       # '{'
  var stmts: seq[AstNode]
  while p.peek().kind notin {RBrace, Eof}:
    let s = parseStatement(p)
    if s == nil: break
    stmts.add(s)
  let close = p.peek()
  discard p.expect(RBrace)
  newBlock(lb.start, close.start + close.length, stmts)

proc parseIf(p: var Parser): AstNode =
  let kw = p.advance()                       # 'if'
  discard p.expect(LParen)
  let cond = parseExpression(p)
  discard p.expect(RParen)
  let then = parseStatement(p)
  var els: AstNode = nil
  var endPos = (if then != nil: then.`end` else: kw.start)
  if p.peek().kind == KwElse:
    discard p.advance()
    els = parseStatement(p)
    if els != nil: endPos = els.`end`
  newIf(kw.start, endPos, cond, then, els)

proc parseWhile(p: var Parser): AstNode =
  let kw = p.advance()
  discard p.expect(LParen)
  let cond = parseExpression(p)
  discard p.expect(RParen)
  let body = parseStatement(p)
  newWhile(kw.start, (if body != nil: body.`end` else: kw.start), cond, body)

proc parseDoWhile(p: var Parser): AstNode =
  let kw = p.advance()
  let body = parseStatement(p)
  discard p.expect(KwWhile)
  discard p.expect(LParen)
  let cond = parseExpression(p)
  let close = p.peek()
  discard p.expect(RParen)
  if p.peek().kind == Semicolon: discard p.advance()
  newDoWhile(kw.start, close.start + close.length, body, cond)

proc parseFor(p: var Parser): AstNode =
  let kw = p.advance()                       # 'for'
  # for-await: consume 'await' if present inside an async function
  if p.peek().kind == KwAwait and p.inAsync: discard p.advance()
  discard p.expect(LParen)

  # Parse the init clause with noIn=true so "x in obj" stops at 'in'.
  let savedNoIn = p.noIn
  p.noIn = true
  var init: AstNode = nil
  if p.peek().kind notin {Semicolon, KwIn, KwOf}:
    if p.peek().kind in {KwVar, KwLet, KwConst}:
      init = parseVarDecl(p, consumeSemi = false)
    else:
      init = parseExpression(p)
  p.noIn = savedNoIn

  # Check if the next token is 'in' or 'of' → for-in / for-of.
  let afterInit = p.peek().kind
  if afterInit == KwIn or afterInit == KwOf:
    let wasOf = (afterInit == KwOf)
    discard p.advance()            # consume 'in' or 'of'
    let iterable = if wasOf: parseAssignmentExpr(p) else: parseExpression(p)
    discard p.expect(RParen)
    let body = parseStatement(p)
    let endPos = if body != nil: body.`end` else: kw.start
    let stmtKind = if wasOf: ForOfStmt else: ForInStmt
    return newForInOf(stmtKind, kw.start, endPos, init, iterable, body)

  # C-style for loop.
  discard p.expect(Semicolon)
  var test: AstNode = nil
  if p.peek().kind != Semicolon: test = parseExpression(p)
  discard p.expect(Semicolon)
  var update: AstNode = nil
  if p.peek().kind != RParen: update = parseExpression(p)
  discard p.expect(RParen)
  let body = parseStatement(p)
  newFor(kw.start, (if body != nil: body.`end` else: kw.start), init, test, update, body)

proc parseReturn(p: var Parser): AstNode =
  let kw = p.advance()
  var arg: AstNode = nil
  var endPos = kw.start + kw.length
  if p.peek().kind notin {Semicolon, RBrace, Eof}:
    arg = parseExpression(p)
    if arg != nil: endPos = arg.`end`
  if p.peek().kind == Semicolon: discard p.advance()
  newReturn(kw.start, endPos, arg)

proc parseThrow(p: var Parser): AstNode =
  let kw = p.advance()
  let arg = parseExpression(p)
  if p.peek().kind == Semicolon: discard p.advance()
  newThrow(kw.start, (if arg != nil: arg.`end` else: kw.start), arg)

proc parseBreakContinue(p: var Parser, kind: NodeKind): AstNode =
  let kw = p.advance()
  var endPos = kw.start + kw.length
  if p.peek().kind == Identifier:            # optional label target (discarded — dump omits it)
    let lbl = p.advance(); endPos = lbl.start + lbl.length
  if p.peek().kind == Semicolon: discard p.advance()
  newLeaf(kind, kw.start, endPos)

proc parseSwitch(p: var Parser): AstNode =
  let kw = p.advance()                 # 'switch'
  discard p.expect(LParen)
  let disc = parseExpression(p)
  discard p.expect(RParen)
  discard p.expect(LBrace)
  var cases: seq[AstNode]
  while p.peek().kind notin {RBrace, Eof}:
    let head = p.peek()
    var test: AstNode = nil
    if head.kind == KwDefault: discard p.advance()
    elif head.kind == KwCase:
      discard p.advance(); test = parseExpression(p)
    else: break
    discard p.expect(Colon)
    var body: seq[AstNode]
    while p.peek().kind notin {KwCase, KwDefault, RBrace, Eof}:
      let s = parseStatement(p)
      if s == nil: break
      body.add(s)
    let caseEnd = (if body.len > 0: body[^1].`end` else: head.start + head.length)
    cases.add(newSwitchCase(head.start, caseEnd, test, body))
  let close = p.peek()
  discard p.expect(RBrace)
  newSwitch(kw.start, close.start + close.length, disc, cases)

proc parseTry(p: var Parser): AstNode =
  let kw = p.advance()                 # 'try'
  let tryBlk = parseBlock(p)
  var catchBlk: AstNode = nil
  var cpStart = 0'u32
  var cpLen = 0'u32
  var catchPat: AstNode = nil
  if p.peek().kind == KwCatch:
    discard p.advance()
    if p.peek().kind == LParen:
      discard p.advance()
      if p.peek().kind in {LBrace, LBracket}:  # pattern catch param
        catchPat = parseBindingTarget(p)
      elif p.peek().kind == Identifier:         # bare identifier catch param
        let id = p.advance(); cpStart = id.start; cpLen = id.length
      discard p.expect(RParen)
    catchBlk = parseBlock(p)
  var finallyBlk: AstNode = nil
  if p.peek().kind == KwFinally:
    discard p.advance()
    finallyBlk = parseBlock(p)
  let endPos = (if finallyBlk != nil: finallyBlk.`end`
                elif catchBlk != nil: catchBlk.`end`
                else: tryBlk.`end`)
  let tryNode = newTry(kw.start, endPos, tryBlk, catchBlk, finallyBlk, cpStart, cpLen)
  if catchPat != nil:
    tryNode.catchPattern = catchPat
  tryNode

proc parseWith(p: var Parser): AstNode =
  let kw = p.advance()                 # 'with'
  discard p.expect(LParen)
  let obj = parseExpression(p)
  discard p.expect(RParen)
  let body = parseStatement(p)
  newWith(kw.start, (if body != nil: body.`end` else: kw.start), obj, body)

# ------------------------------------------------------------------
# parseParamList — consumes plain/default/rest params up to (not
# including) the closing ')'. Port of fn parse_param_list in
# src/parser.zc (~1694).
# ------------------------------------------------------------------

proc parseParamList(p: var Parser): seq[AstNode] =
  while p.peek().kind notin {RParen, Eof}:
    if p.peek().kind == Ellipsis:
      let dots = p.advance()
      let nameTok = p.advance()                 # identifier
      let ident = newLeaf(IdentExpr, nameTok.start, nameTok.start + nameTok.length)
      result.add(newRestParam(dots.start, nameTok.start + nameTok.length, ident))
      break                                     # rest must be last
    elif p.peek().kind in {LBrace, LBracket}:
      let pat = parseBindingTarget(p)
      let param = newLeaf(IdentExpr, pat.start, pat.`end`)
      param.identPattern = pat
      if p.peek().kind == Eq:
        discard p.advance()
        param.identDefault = parseAssignmentExpr(p)
      result.add(param)
    else:
      let nameTok = p.advance()                 # identifier
      let ident = newLeaf(IdentExpr, nameTok.start, nameTok.start + nameTok.length)
      if p.peek().kind == Eq:
        discard p.advance()
        ident.identDefault = parseAssignmentExpr(p)
      result.add(ident)
    if p.peek().kind != Comma: break
    discard p.advance()                         # consume ','  (trailing comma: loop re-checks RParen)

# ------------------------------------------------------------------
# parseFunctionDecl — port of fn parse_function_decl in src/parser.zc (~1823).
# ------------------------------------------------------------------

proc parseFunctionDecl(p: var Parser, isAsync = false): AstNode =
  let kw = p.advance()                          # 'function'
  var isGen = false
  if p.peek().kind == Star: discard p.advance(); isGen = true
  let nameTok = p.advance()                     # name (Identifier) — required for a declaration
  discard p.expect(LParen)
  let params = parseParamList(p)
  discard p.expect(RParen)
  let savedG = p.inGenerator; let savedA = p.inAsync
  p.inGenerator = isGen; p.inAsync = isAsync
  let body = parseBlock(p)
  p.inGenerator = savedG; p.inAsync = savedA
  newFunctionDecl(kw.start, body.`end`, nameTok.start, nameTok.length, body, params, isAsync, isGen)

# ------------------------------------------------------------------
# parseFunctionExpr — port of fn parse_function_expr in src/parser.zc (~2772).
# ------------------------------------------------------------------

proc parseFunctionExpr(p: var Parser, isAsync = false): AstNode =
  let kw = p.advance()                          # 'function'
  var isGen = false
  if p.peek().kind == Star: discard p.advance(); isGen = true
  var nameStart = 0'u32
  var nameLen = 0'u32
  if p.peek().kind == Identifier:               # optional name
    let nameTok = p.advance()
    nameStart = nameTok.start; nameLen = nameTok.length
  discard p.expect(LParen)
  let params = parseParamList(p)
  discard p.expect(RParen)
  let savedG = p.inGenerator; let savedA = p.inAsync
  p.inGenerator = isGen; p.inAsync = isAsync
  let body = parseBlock(p)
  p.inGenerator = savedG; p.inAsync = savedA
  newFunctionExpr(kw.start, body.`end`, nameStart, nameLen, body, params, isAsync, isGen)

# ------------------------------------------------------------------
# Class parsing (Phase 2e-1) — ports of parse_class_decl/parse_class_expr/
# parse_class_body (no synthesis in 2e-1) / parse_method_body_pair
# (method + static-block paths). Instance fields = 2e-2.
# ------------------------------------------------------------------

proc parseMethodBodyPair(p: var Parser): AstNode =
  let mutStart = p.peek().start
  # --- optional `static` ---
  var isStatic = false
  block:
    let first = p.peek()
    if first.kind == Identifier and first.length == 6'u32 and
       p.source[first.start.int ..< (first.start + first.length).int] == "static":
      # static { ... } block
      if p.toks[p.pos + 1].kind == LBrace:
        discard p.advance()                 # consume 'static'
        let sg = p.inGenerator; let sa = p.inAsync
        p.inGenerator = false; p.inAsync = false
        let body = parseBlock(p)
        p.inGenerator = sg; p.inAsync = sa
        if body == nil: return nil
        return newStaticBlock(mutStart, body.`end`, body)
      # `static <name>` / `static [` / `static *` / `static #x`
      let k2 = p.toks[p.pos + 1].kind
      if isPropertyNameStart(k2) or k2 == LBracket or k2 == Star or k2 == PrivateName:
        discard p.advance(); isStatic = true
  # --- optional `async` (async method) ---
  var isAsync = false
  if p.peek().kind == KwAsync:
    let k2 = p.toks[p.pos + 1].kind
    if isPropertyNameStart(k2) or k2 == LBracket or k2 == PrivateName or k2 == Star:
      discard p.advance(); isAsync = true
  # --- optional `*` (generator method) ---
  var isGen = false
  if p.peek().kind == Star:
    discard p.advance(); isGen = true
  # --- optional `get`/`set` accessor (not after async) ---
  var accessor = Eq                         # Eq sentinel = plain method
  if not isAsync:
    let id2 = p.peek()
    if id2.kind == Identifier and id2.length == 3'u32:
      let txt = p.source[id2.start.int ..< (id2.start + id2.length).int]
      if (txt == "get" or txt == "set"):
        let k2 = p.toks[p.pos + 1].kind
        if isPropertyNameStart(k2) or k2 == LBracket or k2 == PrivateName:
          discard p.advance()
          accessor = (if txt == "get": KwGet else: KwSet)
  # --- method name OR computed key ---
  var computedKey: AstNode = nil
  let nameTok = p.peek()
  if nameTok.kind == LBracket:
    discard p.advance()
    computedKey = parseAssignmentExpr(p)
    if computedKey == nil: return nil
    if not p.expect(RBracket): return nil
  else:
    # accept any property-name token or PrivateName (permissive; #constructor
    # early-error deferred to the error-reporting increment)
    if not isPropertyNameStart(nameTok.kind) and nameTok.kind != PrivateName:
      p.hadError = true; return nil
    discard p.advance()
  # === 2e-2 INSERTION POINT: field branch goes here (see slice 2e-2) ===
  # --- method: params + body ---
  let sg = p.inGenerator; let sa = p.inAsync
  p.inAsync = isAsync; p.inGenerator = isGen
  if not p.expect(LParen):
    p.inGenerator = sg; p.inAsync = sa; return nil
  let params = parseParamList(p)
  if not p.expect(RParen):
    p.inGenerator = sg; p.inAsync = sa; return nil
  let body = parseBlock(p)
  p.inGenerator = sg; p.inAsync = sa
  if body == nil: return nil
  return newMethodDef(mutStart, body.`end`,
                      (if computedKey != nil: 0'u32 else: nameTok.start),
                      (if computedKey != nil: 0'u32 else: nameTok.length),
                      body, computedKey, params, isStatic, accessor, isAsync, isGen)

proc parseClassBody(p: var Parser, isDerived: bool): seq[AstNode] =
  if not p.expect(LBrace): return @[]
  var members: seq[AstNode]
  while p.peek().kind notin {RBrace, Eof}:
    if p.peek().kind == Semicolon:          # skip empty `;` separators
      discard p.advance(); continue
    let m = parseMethodBodyPair(p)
    if m == nil: p.hadError = true; break
    members.add(m)
  discard p.expect(RBrace)
  return members

proc parseClassDecl(p: var Parser): AstNode =
  let kw = p.advance()                      # 'class'
  let nameTok = p.advance()                 # class name (binding ident)
  var parent: AstNode = nil
  if p.peek().kind == KwExtends:
    discard p.advance()
    parent = parseCallMember(p)             # LeftHandSideExpression
    if parent == nil: return nil
  let members = parseClassBody(p, parent != nil)
  let endPos = if members.len > 0: members[^1].`end` else: p.peek().start
  return newClass(ClassDecl, kw.start, endPos, nameTok.start, nameTok.length, parent, members)

proc parseClassExpr(p: var Parser): AstNode =
  let kw = p.advance()                      # 'class'
  var nameStart = 0'u32
  var nameLen = 0'u32
  if p.peek().kind == Identifier:
    let nt = p.advance()
    nameStart = nt.start; nameLen = nt.length
  var parent: AstNode = nil
  if p.peek().kind == KwExtends:
    discard p.advance()
    parent = parseCallMember(p)
    if parent == nil: return nil
  let members = parseClassBody(p, parent != nil)
  let endPos = if members.len > 0: members[^1].`end` else: p.peek().start
  return newClass(ClassExpr, kw.start, endPos, nameStart, nameLen, parent, members)

# ------------------------------------------------------------------
# parseStatement — core dispatch. Expression statement consumes an
# optional trailing semicolon.
# ------------------------------------------------------------------

proc parseStatement(p: var Parser): AstNode =
  # Control-flow dispatch
  case p.peek().kind
  of LBrace: return parseBlock(p)
  of KwFunction: return parseFunctionDecl(p)
  of KwClass: return parseClassDecl(p)
  of KwIf: return parseIf(p)
  of KwWhile: return parseWhile(p)
  of KwDo: return parseDoWhile(p)
  of KwFor: return parseFor(p)
  of KwReturn: return parseReturn(p)
  of KwThrow: return parseThrow(p)
  of KwBreak: return parseBreakContinue(p, BreakStmt)
  of KwContinue: return parseBreakContinue(p, ContinueStmt)
  of KwSwitch: return parseSwitch(p)
  of KwTry: return parseTry(p)
  of KwWith: return parseWith(p)
  of Semicolon:
    let semi = p.advance()
    return newLeaf(EmptyStmt, semi.start, semi.start + semi.length)
  else: discard
  # async function declaration: `async function ...`
  if p.peek().kind == KwAsync and p.toks[p.pos + 1].kind == KwFunction:
    discard p.advance()   # consume 'async'
    return parseFunctionDecl(p, isAsync = true)
  # Labeled statement: Identifier ':' (2-token lookahead)
  if p.peek().kind == Identifier and p.toks[p.pos + 1].kind == Colon:
    let id = p.advance()
    discard p.advance()                      # ':'
    let body = parseStatement(p)
    return newLabeled(id.start, (if body != nil: body.`end` else: id.start), id.start, id.length, body)
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
