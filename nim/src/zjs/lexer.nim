## The lexer — a single forward pass producing flat Token slices.
## Idiomatic Nim port of src/lexer.zc. Tokens slice into `source`.
##
## Task 3: trivia skipping, identifiers, keywords, numbers, punctuators.
## Strings (" '), templates (`), and regex (/) are OUT OF SCOPE for now —
## lead bytes for those advance one char and emit Invalid (Task 4-5 gap).
import token

# =====================================================================
# Character classification (mirrors src/lexer.zc, ASCII fast paths)
# =====================================================================

func isDigit(c: char): bool {.inline.} = c >= '0' and c <= '9'

func isHexDigit(c: char): bool {.inline.} =
  (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')

func isAlpha(c: char): bool {.inline.} =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')

func isIdStart(c: char): bool {.inline.} =
  ## ASCII letters, _, $, or any non-ASCII byte (pragmatic v1).
  isAlpha(c) or c == '_' or c == '$' or c.uint8 >= 0x80'u8

func isIdPart(c: char): bool {.inline.} =
  ## IdentifierPart: id_start or digit.
  isIdStart(c) or isDigit(c)

# =====================================================================
# Keyword lookup (mirrors src/lexer.zc lookup_keyword)
# NOTE: get/set are NOT in this table — they lex as Identifier,
# matching the Zen-c reference exactly.
# =====================================================================

func openArrayEq(a: openArray[char]; b: string): bool =
  ## True iff `a` has the same length and same bytes as `b`.
  if a.len != b.len: return false
  for i in 0 ..< b.len:
    if a[i] != b[i]: return false
  true

func lookupKeyword(text: openArray[char]): TokenKind =
  template eq(s: string): bool = openArrayEq(text, s)
  if eq("var"):        return KwVar
  if eq("let"):        return KwLet
  if eq("const"):      return KwConst
  if eq("function"):   return KwFunction
  if eq("return"):     return KwReturn
  if eq("if"):         return KwIf
  if eq("else"):       return KwElse
  if eq("for"):        return KwFor
  if eq("while"):      return KwWhile
  if eq("do"):         return KwDo
  if eq("break"):      return KwBreak
  if eq("continue"):   return KwContinue
  if eq("class"):      return KwClass
  if eq("extends"):    return KwExtends
  if eq("super"):      return KwSuper
  if eq("new"):        return KwNew
  if eq("this"):       return KwThis
  if eq("true"):       return KwTrue
  if eq("false"):      return KwFalse
  if eq("null"):       return KwNull
  if eq("undefined"):  return KwUndefined
  if eq("typeof"):     return KwTypeof
  if eq("delete"):     return KwDelete
  if eq("void"):       return KwVoid
  if eq("in"):         return KwIn
  if eq("of"):         return KwOf
  if eq("instanceof"): return KwInstanceof
  if eq("throw"):      return KwThrow
  if eq("try"):        return KwTry
  if eq("catch"):      return KwCatch
  if eq("finally"):    return KwFinally
  if eq("switch"):     return KwSwitch
  if eq("case"):       return KwCase
  if eq("default"):    return KwDefault
  if eq("with"):       return KwWith
  if eq("async"):      return KwAsync
  if eq("await"):      return KwAwait
  if eq("yield"):      return KwYield
  if eq("import"):     return KwImport
  if eq("export"):     return KwExport
  if eq("from"):       return KwFrom
  if eq("as"):         return KwAs
  return Identifier

# =====================================================================
# Lexer type
# =====================================================================

type
  Lexer* = object
    source*: string
    pos*: int
    expectRegex: bool   ## true => next `/` starts a regex literal
    prevKind: TokenKind
    crossedNewline: bool

proc initLexer*(source: string): Lexer =
  Lexer(source: source, pos: 0, expectRegex: true,
        prevKind: Eof, crossedNewline: false)

# =====================================================================
# Cursor primitives
# =====================================================================

func atEnd(lx: Lexer): bool {.inline.} = lx.pos >= lx.source.len

func peek(lx: Lexer): char {.inline.} =
  if lx.pos >= lx.source.len: '\0' else: lx.source[lx.pos]

func peekAt(lx: Lexer; offset: int): char {.inline.} =
  let p = lx.pos + offset
  if p >= lx.source.len: '\0' else: lx.source[p]

proc advance(lx: var Lexer): char {.inline, discardable.} =
  result = lx.peek()
  inc lx.pos

proc matchChar(lx: var Lexer; expected: char): bool {.inline.} =
  if lx.peek() != expected: return false
  lx.advance()
  return true

# =====================================================================
# Token constructors
# =====================================================================

func tok1(kind: TokenKind; start: uint32): Token {.inline.} =
  Token(kind: kind, start: start, length: 1'u32)

func tokN(kind: TokenKind; start: uint32; pos: int): Token {.inline.} =
  Token(kind: kind, start: start, length: uint32(pos) - start)

# =====================================================================
# Trivia skipping (whitespace + comments)
# =====================================================================

proc skipTrivia(lx: var Lexer) =
  lx.crossedNewline = false
  while not lx.atEnd():
    let c = lx.peek()
    case c
    of ' ', '\t', '\r', '\n', '\x0B', '\x0C':
      # CR and LF are LineTerminators per §12.3.
      if c == '\n' or c == '\r': lx.crossedNewline = true
      lx.advance()
    else:
      let b = c.uint8
      if b == 0xC2'u8 and lx.peekAt(1).uint8 == 0xA0'u8:
        # U+00A0 NO-BREAK SPACE (UTF-8: C2 A0)
        lx.advance(); lx.advance()
      elif b == 0xEF'u8 and lx.peekAt(1).uint8 == 0xBB'u8 and lx.peekAt(2).uint8 == 0xBF'u8:
        # U+FEFF BOM (UTF-8: EF BB BF)
        lx.advance(); lx.advance(); lx.advance()
      elif b == 0xE2'u8 and lx.peekAt(1).uint8 == 0x80'u8 and
           (lx.peekAt(2).uint8 == 0xA8'u8 or lx.peekAt(2).uint8 == 0xA9'u8):
        # U+2028 LINE SEPARATOR / U+2029 PARAGRAPH SEPARATOR
        lx.crossedNewline = true
        lx.advance(); lx.advance(); lx.advance()
      elif c == '/' and lx.peekAt(1) == '/':
        # Line comment: consume until newline (don't eat the newline itself)
        lx.advance(); lx.advance()
        while not lx.atEnd() and lx.peek() != '\n' and lx.peek() != '\r':
          lx.advance()
      elif c == '/' and lx.peekAt(1) == '*':
        # Block comment: consume until "*/"
        lx.advance(); lx.advance()
        while not lx.atEnd():
          if lx.peek() == '*' and lx.peekAt(1) == '/':
            lx.advance(); lx.advance()
            break
          lx.advance()
      else:
        break

# =====================================================================
# expectRegexAfter — mirrors src/lexer.zc expect_regex_after
# =====================================================================

func expectRegexAfter(kind: TokenKind): bool =
  case kind
  of Identifier, NumberLit, BigIntLit, StringLit, RegexLit,
     RParen, RBracket, RBrace,
     PlusPlus, MinusMinus,
     KwTrue, KwFalse, KwNull, KwUndefined, KwThis, KwSuper,
     KwOf, KwAs, KwFrom, KwGet, KwSet, KwAsync, KwAwait, KwYield:
    false
  else:
    true

# =====================================================================
# Unicode escape consumer (for \uXXXX / \u{...} in identifiers)
# =====================================================================

proc consumeUnicodeEscape(lx: var Lexer): bool =
  ## Assumes `\u` has not yet been consumed.
  if lx.peek() != '\\' or lx.peekAt(1) != 'u': return false
  lx.advance(); lx.advance()  # consume \u
  var cp: uint32 = 0
  if lx.peek() == '{':
    lx.advance()
    var n: int = 0
    while not lx.atEnd() and lx.peek() != '}':
      let d = lx.peek()
      let dv: int =
        if d >= '0' and d <= '9': int(d) - int('0')
        elif d >= 'a' and d <= 'f': int(d) - int('a') + 10
        elif d >= 'A' and d <= 'F': int(d) - int('A') + 10
        else: -1
      if dv < 0: return false
      cp = (cp shl 4) or uint32(dv)
      inc n
      if n > 6 or cp > 0x10FFFF'u32: return false
      lx.advance()
    if lx.peek() != '}': return false
    lx.advance()
  else:
    for _ in 0 ..< 4:
      let d = lx.peek()
      let dv: int =
        if d >= '0' and d <= '9': int(d) - int('0')
        elif d >= 'a' and d <= 'f': int(d) - int('a') + 10
        elif d >= 'A' and d <= 'F': int(d) - int('A') + 10
        else: -1
      if dv < 0: return false
      cp = (cp shl 4) or uint32(dv)
      lx.advance()
  # Accept ASCII id_part; accept non-ASCII without consulting tables.
  if cp <= 0x7F'u32:
    if not isIdPart(char(cp)): return false
  return true

# =====================================================================
# lookupKeywordAfterEscape — decode \u escapes then classify
# =====================================================================

proc lookupKeywordAfterEscape(lx: Lexer; start: uint32; length: uint32): TokenKind =
  ## Decode the raw source slice [start, start+length) into a plain-char
  ## buffer and keyword-test it.  Non-ASCII code points → Identifier.
  var buf: array[16, char]
  var outp: int = 0
  var j: uint32 = 0
  while j < length:
    if outp >= 16: return Identifier
    let c = lx.source[int(start + j)]
    if c == '\\' and j + 1 < length and lx.source[int(start + j + 1)] == 'u':
      j += 2
      var cp: uint32 = 0
      if j < length and lx.source[int(start + j)] == '{':
        j += 1
        while j < length and lx.source[int(start + j)] != '}':
          let d = lx.source[int(start + j)]
          let dv: int =
            if d >= '0' and d <= '9': int(d) - int('0')
            elif d >= 'a' and d <= 'f': int(d) - int('a') + 10
            elif d >= 'A' and d <= 'F': int(d) - int('A') + 10
            else: -1
          if dv < 0: return Identifier
          cp = (cp shl 4) or uint32(dv)
          j += 1
        if j < length: j += 1  # consume '}'
      else:
        var n: uint32 = 0
        while n < 4 and j < length:
          let d = lx.source[int(start + j)]
          let dv: int =
            if d >= '0' and d <= '9': int(d) - int('0')
            elif d >= 'a' and d <= 'f': int(d) - int('a') + 10
            elif d >= 'A' and d <= 'F': int(d) - int('A') + 10
            else: -1
          if dv < 0: return Identifier
          cp = (cp shl 4) or uint32(dv)
          j += 1
          n += 1
      if cp > 0x7F'u32: return Identifier
      buf[outp] = char(cp)
      outp += 1
    else:
      buf[outp] = c
      outp += 1
      j += 1
  return lookupKeyword(buf.toOpenArray(0, outp - 1))

# =====================================================================
# Identifier / keyword scanner
# =====================================================================

proc scanIdentifierOrKeyword(lx: var Lexer; start: uint32): Token =
  var hasEscape = false
  if lx.peek() == '\\':
    if not lx.consumeUnicodeEscape():
      return Token(kind: Invalid, start: start, length: 1)
    hasEscape = true
  else:
    lx.advance()
  while not lx.atEnd():
    let c = lx.peek()
    if isIdPart(c):
      lx.advance()
    elif c == '\\' and lx.peekAt(1) == 'u':
      if not lx.consumeUnicodeEscape():
        return Token(kind: Invalid, start: start, length: 1)
      hasEscape = true
    else:
      break
  let length = uint32(lx.pos) - start
  let kind =
    if hasEscape:
      lx.lookupKeywordAfterEscape(start, length)
    else:
      lookupKeyword(lx.source.toOpenArray(int(start), int(start + length) - 1))
  Token(kind: kind, start: start, length: length)

# =====================================================================
# Number scanner
# =====================================================================

proc scanNumber(lx: var Lexer; start: uint32): Token =
  let c0 = lx.peek()
  let c1 = lx.peekAt(1)

  # Hex: 0x / 0X
  if c0 == '0' and (c1 == 'x' or c1 == 'X'):
    lx.advance(); lx.advance()
    while not lx.atEnd() and (isHexDigit(lx.peek()) or lx.peek() == '_'):
      lx.advance()
    if lx.peek() == 'n':
      lx.advance()
      return tokN(BigIntLit, start, lx.pos)
    return tokN(NumberLit, start, lx.pos)

  # Binary: 0b / 0B
  if c0 == '0' and (c1 == 'b' or c1 == 'B'):
    lx.advance(); lx.advance()
    while not lx.atEnd() and (lx.peek() == '0' or lx.peek() == '1' or lx.peek() == '_'):
      lx.advance()
    if lx.peek() == 'n':
      lx.advance()
      return tokN(BigIntLit, start, lx.pos)
    return tokN(NumberLit, start, lx.pos)

  # Octal: 0o / 0O
  if c0 == '0' and (c1 == 'o' or c1 == 'O'):
    lx.advance(); lx.advance()
    while not lx.atEnd() and ((lx.peek() >= '0' and lx.peek() <= '7') or lx.peek() == '_'):
      lx.advance()
    if lx.peek() == 'n':
      lx.advance()
      return tokN(BigIntLit, start, lx.pos)
    return tokN(NumberLit, start, lx.pos)

  # Decimal integer part (may be empty if we started on '.')
  let sawIntDigit = isDigit(c0)
  while not lx.atEnd() and (isDigit(lx.peek()) or lx.peek() == '_'):
    lx.advance()

  # BigInt suffix on plain decimal integer: 123n
  if sawIntDigit and lx.peek() == 'n':
    lx.advance()
    return tokN(BigIntLit, start, lx.pos)

  # Optional fractional part
  if lx.peek() == '.':
    lx.advance()
    while not lx.atEnd() and (isDigit(lx.peek()) or lx.peek() == '_'):
      lx.advance()

  # Optional exponent
  if lx.peek() == 'e' or lx.peek() == 'E':
    lx.advance()
    if lx.peek() == '+' or lx.peek() == '-': lx.advance()
    while not lx.atEnd() and (isDigit(lx.peek()) or lx.peek() == '_'):
      lx.advance()

  # n on a non-integer literal (1.5n, 1e3n) → Invalid (SyntaxError)
  if lx.peek() == 'n':
    lx.advance()
    return tokN(Invalid, start, lx.pos)

  tokN(NumberLit, start, lx.pos)

# =====================================================================
# String scanner — single/double-quoted string literals
# =====================================================================
# Port of src/lexer.zc scan_string.
# The token spans the WHOLE literal including both quotes.
# Escapes are passed through as raw source bytes (the compiler decodes).
# A raw newline (not preceded by \) terminates the string with Invalid.

proc scanString(lx: var Lexer; start: uint32; quote: char): Token =
  lx.advance()  # consume opening quote
  while not lx.atEnd():
    let c = lx.peek()
    if c == quote:
      lx.advance()
      return tokN(StringLit, start, lx.pos)
    if c == '\n' or c == '\r':
      # unterminated string at end of line
      return tokN(Invalid, start, lx.pos)
    if c == '\\':
      lx.advance()
      if not lx.atEnd():
        # LineContinuation: \<CR><LF> is one terminator sequence.
        if lx.peek() == '\r':
          lx.advance()
          if not lx.atEnd() and lx.peek() == '\n': lx.advance()
        else:
          lx.advance()
    else:
      lx.advance()
  # ran off the end without a closing quote
  return tokN(Invalid, start, lx.pos)

# =====================================================================
# Template literal scanner
# =====================================================================
# Port of src/lexer.zc scan_template + scan_template_substitution.
# Emits a single TemplateLit token covering the entire backtick-delimited
# literal including all ${...} interpolations. The parser walks the slice
# to extract cooked string segments. Regex (/) is out of scope for Task 4;
# the substitution helper tracks it best-effort.

proc scanTemplateSubstitution(lx: var Lexer): bool

proc scanTemplate(lx: var Lexer; start: uint32): Token =
  lx.advance()  # consume opening backtick
  while not lx.atEnd():
    let c = lx.peek()
    if c == '`':
      lx.advance()
      return tokN(TemplateLit, start, lx.pos)
    if c == '\\':
      lx.advance()
      if not lx.atEnd(): lx.advance()
      continue
    if c == '$' and lx.peekAt(1) == '{':
      lx.advance(); lx.advance()  # past ${
      if not lx.scanTemplateSubstitution():
        return tokN(Invalid, start, lx.pos)
      continue
    lx.advance()
  return tokN(Invalid, start, lx.pos)

proc scanTemplateSubstitution(lx: var Lexer): bool =
  ## Skip past a `${ ... }` substitution. Tracks balanced braces, nested
  ## templates / strings / comments / regexes. Returns false on unterminated input.
  ## Port of src/lexer.zc scan_template_substitution.
  var depth: int = 1
  # prev_sig tracks the last significant (non-whitespace) char consumed.
  # Decides whether a `/` starts a regex (expression position: after an
  # operator/opener/comma) or is division (value position: after
  # ident/)/]/quote). Initialized to '{' (expression position).
  var prevSig: char = '{'
  while depth > 0 and not lx.atEnd():
    let c = lx.peek()
    if c == '{':
      lx.advance(); inc depth; prevSig = c; continue
    if c == '}':
      lx.advance(); dec depth; prevSig = c; continue
    if c == '\\':
      lx.advance()
      if not lx.atEnd(): lx.advance()
      prevSig = '\\'
      continue
    if c == '/':
      let nx = lx.peekAt(1)
      if nx == '/':
        # Line comment — skip to end of line.
        while not lx.atEnd() and lx.peek() != '\n':
          lx.advance()
        continue
      if nx == '*':
        # Block comment — skip past the closing */.
        lx.advance(); lx.advance()
        while not lx.atEnd():
          if lx.peek() == '*' and lx.peekAt(1) == '/':
            lx.advance(); lx.advance()
            break
          lx.advance()
        continue
      # Is this a regex literal or division?
      let isValueEnd: bool =
        (prevSig >= 'a' and prevSig <= 'z') or
        (prevSig >= 'A' and prevSig <= 'Z') or
        (prevSig >= '0' and prevSig <= '9') or
        prevSig == '_' or prevSig == '$' or
        prevSig == ')' or prevSig == ']' or
        prevSig == '\'' or prevSig == '"' or
        prevSig == '`' or prevSig == '}' or
        prevSig == '.'
      if not isValueEnd:
        # Regex literal: body (a `/` inside a [...] char class is literal),
        # then flag letters.
        lx.advance()  # opening /
        var inClass: bool = false
        while not lx.atEnd():
          let rc = lx.peek()
          if rc == '\\':
            lx.advance()
            if not lx.atEnd(): lx.advance()
            continue
          if rc == '\n': return false
          if rc == '[': inClass = true; lx.advance(); continue
          if rc == ']': inClass = false; lx.advance(); continue
          if rc == '/' and not inClass:
            lx.advance()  # closing /
            break
          lx.advance()
        # Flags: greedy run of letter chars (g/i/m/s/u/y/d)
        while not lx.atEnd():
          let fc = lx.peek()
          if not ((fc >= 'a' and fc <= 'z') or (fc >= 'A' and fc <= 'Z')):
            break
          lx.advance()
        prevSig = ')'  # a regex is a value
        continue
      # Division operator
      lx.advance()
      prevSig = c
      continue
    if c == '`':
      # Nested template — consume it whole inline (mirrors the Zen-c approach).
      lx.advance()  # opening backtick
      while not lx.atEnd() and lx.peek() != '`':
        let ic = lx.peek()
        if ic == '\\':
          lx.advance()
          if not lx.atEnd(): lx.advance()
          continue
        if ic == '$' and lx.peekAt(1) == '{':
          lx.advance(); lx.advance()
          if not lx.scanTemplateSubstitution(): return false
          continue
        lx.advance()
      if not lx.atEnd(): lx.advance()  # closing `
      prevSig = '`'
      continue
    if c == '"' or c == '\'':
      let quote = c
      lx.advance()
      while not lx.atEnd() and lx.peek() != quote:
        if lx.peek() == '\\':
          lx.advance()
          if not lx.atEnd(): lx.advance()
        elif lx.peek() == '\n':
          return false
        else:
          lx.advance()
      if not lx.atEnd(): lx.advance()  # closing quote
      prevSig = quote
      continue
    # Update prevSig for significant (non-whitespace) chars
    if c != ' ' and c != '\t' and c != '\n' and c != '\r':
      prevSig = c
    lx.advance()
  return depth == 0

# =====================================================================
# Regex literal scanner
# =====================================================================
# Port of src/lexer.zc scan_regex_body.
# Called after the opening `/` has been consumed (by scanPunctuator's
# advance() at the top of that proc). Consumes pattern + closing `/`
# + flag letters. Returns RegexLit spanning from `start` (the `/`)
# through the end of the flags, or Invalid on unterminated input.

proc scanRegexBody(lx: var Lexer; start: uint32): Token =
  var inClass = false
  while not lx.atEnd():
    let c = lx.peek()
    if c == '\n' or c == '\r':
      return Token(kind: Invalid, start: start, length: uint32(lx.pos) - start)
    if c == '\\':
      lx.advance()
      if not lx.atEnd():
        let nc = lx.peek()
        if nc == '\n' or nc == '\r':
          return Token(kind: Invalid, start: start, length: uint32(lx.pos) - start)
        lx.advance()
      continue
    if c == '[':
      inClass = true
      lx.advance()
      continue
    if c == ']':
      inClass = false
      lx.advance()
      continue
    if c == '/' and not inClass:
      lx.advance()  # closing slash
      # Flags: greedy run of identifier-part chars (g/i/m/s/u/y/d)
      while not lx.atEnd() and isIdPart(lx.peek()):
        lx.advance()
      return tokN(RegexLit, start, lx.pos)
    lx.advance()
  # Ran off the end without finding a closing `/`
  return Token(kind: Invalid, start: start, length: uint32(lx.pos) - start)

# =====================================================================
# Punctuator scanner (longest-match)
# =====================================================================

proc scanPunctuator(lx: var Lexer; start: uint32): Token =
  let c = lx.advance()
  case c
  of '(': return tok1(LParen,    start)
  of ')': return tok1(RParen,    start)
  of '[': return tok1(LBracket,  start)
  of ']': return tok1(RBracket,  start)
  of '{': return tok1(LBrace,    start)
  of '}': return tok1(RBrace,    start)
  of ',': return tok1(Comma,     start)
  of ';': return tok1(Semicolon, start)
  of ':': return tok1(Colon,     start)
  of '~': return tok1(Tilde,     start)

  of '?':
    if lx.matchChar('?'):
      if lx.matchChar('='): return tokN(QuestionQuestionEq, start, lx.pos)
      return tokN(QuestionQuestion, start, lx.pos)
    if lx.matchChar('.'): return tokN(QuestionDot, start, lx.pos)
    return tok1(Question, start)

  of '!':
    if lx.matchChar('='):
      if lx.matchChar('='): return tokN(BangEqEq, start, lx.pos)
      return tokN(BangEq, start, lx.pos)
    return tok1(Bang, start)

  of '=':
    if lx.matchChar('='):
      if lx.matchChar('='): return tokN(EqEqEq, start, lx.pos)
      return tokN(EqEq, start, lx.pos)
    if lx.matchChar('>'): return tokN(Arrow, start, lx.pos)
    return tok1(Eq, start)

  of '<':
    if lx.matchChar('='): return tokN(LtEq, start, lx.pos)
    if lx.matchChar('<'):
      if lx.matchChar('='): return tokN(LtLtEq, start, lx.pos)
      return tokN(LtLt, start, lx.pos)
    return tok1(Lt, start)

  of '>':
    if lx.matchChar('='):   return tokN(GtEq, start, lx.pos)
    if lx.matchChar('>'):
      if lx.matchChar('>'):
        if lx.matchChar('='): return tokN(GtGtGtEq, start, lx.pos)
        return tokN(GtGtGt, start, lx.pos)
      if lx.matchChar('='): return tokN(GtGtEq, start, lx.pos)
      return tokN(GtGt, start, lx.pos)
    return tok1(Gt, start)

  of '+':
    if lx.matchChar('+'): return tokN(PlusPlus, start, lx.pos)
    if lx.matchChar('='): return tokN(PlusEq, start, lx.pos)
    return tok1(Plus, start)

  of '-':
    if lx.matchChar('-'): return tokN(MinusMinus, start, lx.pos)
    if lx.matchChar('='): return tokN(MinusEq, start, lx.pos)
    return tok1(Minus, start)

  of '*':
    if lx.matchChar('*'):
      if lx.matchChar('='): return tokN(StarStarEq, start, lx.pos)
      return tokN(StarStar, start, lx.pos)
    if lx.matchChar('='): return tokN(StarEq, start, lx.pos)
    return tok1(Star, start)

  of '/':
    # ECMA-262 §12.2.1: contextual regex vs division.
    # `expectRegex` is set by expectRegexAfter after each token.
    # Special case: `}` followed by a newline-then-`/` is treated as
    # end-of-block (ASI) → the `/` starts a regex. Without the newline,
    # `}/` is more likely object-literal / division.
    let forceRegex =
      lx.expectRegex or
      (lx.prevKind == RBrace and lx.crossedNewline)
    if forceRegex:
      return lx.scanRegexBody(start)
    if lx.matchChar('='): return tokN(SlashEq, start, lx.pos)
    return tok1(Slash, start)

  of '%':
    if lx.matchChar('='): return tokN(PercentEq, start, lx.pos)
    return tok1(Percent, start)

  of '&':
    if lx.matchChar('&'):
      if lx.matchChar('='): return tokN(AmpAmpEq, start, lx.pos)
      return tokN(AmpAmp, start, lx.pos)
    if lx.matchChar('='): return tokN(AmpEq, start, lx.pos)
    return tok1(Amp, start)

  of '|':
    if lx.matchChar('|'):
      if lx.matchChar('='): return tokN(PipePipeEq, start, lx.pos)
      return tokN(PipePipe, start, lx.pos)
    if lx.matchChar('='): return tokN(PipeEq, start, lx.pos)
    return tok1(Pipe, start)

  of '^':
    if lx.matchChar('='): return tokN(CaretEq, start, lx.pos)
    return tok1(Caret, start)

  of '#':
    # PrivateName: `#identifier`. `#` already consumed by advance() above.
    if lx.atEnd():
      return Token(kind: Invalid, start: start, length: 1)
    if lx.peek() == '\\' and lx.peekAt(1) == 'u':
      if not lx.consumeUnicodeEscape():
        return Token(kind: Invalid, start: start, length: 1)
    elif isIdStart(lx.peek()):
      lx.advance()
    else:
      return Token(kind: Invalid, start: start, length: 1)
    while not lx.atEnd():
      let ch = lx.peek()
      if isIdPart(ch):
        lx.advance()
      elif ch == '\\' and lx.peekAt(1) == 'u':
        if not lx.consumeUnicodeEscape():
          return Token(kind: Invalid, start: start, length: 1)
      else:
        break
    return tokN(PrivateName, start, lx.pos)

  else:
    return Token(kind: Invalid, start: start, length: 1)

# =====================================================================
# Top-level token dispatch
# =====================================================================

proc nextTokenInner(lx: var Lexer): Token =
  lx.skipTrivia()
  if lx.atEnd():
    return tokenEof(uint32(lx.pos))

  let start = uint32(lx.pos)
  let c = lx.peek()

  if isIdStart(c):
    return lx.scanIdentifierOrKeyword(start)
  # \uXXXX / \u{...} is a valid IdentifierStart
  if c == '\\' and lx.peekAt(1) == 'u':
    return lx.scanIdentifierOrKeyword(start)
  if isDigit(c):
    return lx.scanNumber(start)
  if c == '"' or c == '\'':
    return lx.scanString(start, c)
  if c == '`':
    return lx.scanTemplate(start)
  # '.' may start a number (.5), Ellipsis (...), or plain Dot
  if c == '.':
    if isDigit(lx.peekAt(1)):
      return lx.scanNumber(start)
    if lx.peekAt(1) == '.' and lx.peekAt(2) == '.':
      lx.advance(); lx.advance(); lx.advance()
      return Token(kind: Ellipsis, start: start, length: 3)
    lx.advance()
    return Token(kind: Dot, start: start, length: 1)

  return lx.scanPunctuator(start)

proc nextToken*(lx: var Lexer): Token =
  let t = lx.nextTokenInner()
  lx.expectRegex = expectRegexAfter(t.kind)
  lx.prevKind = t.kind
  t

iterator tokens*(lx: var Lexer): Token =
  ## Yields every token through and including the final Eof.
  while true:
    let t = lx.nextToken()
    yield t
    if t.kind == Eof: break
