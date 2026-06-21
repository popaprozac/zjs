import std/unittest
import ../src/zjs/token
import ../src/zjs/lexer

suite "token model":
  test "TokenKind variant names stringify to match Zen-c dump names":
    check $TokenKind.KwLet == "KwLet"
    check $TokenKind.Eq == "Eq"
    check $TokenKind.NumberLit == "NumberLit"
    check $TokenKind.Eof == "Eof"
    check $TokenKind.QuestionQuestionEq == "QuestionQuestionEq"

  test "Token is a flat slice (kind, start, length)":
    let t = Token(kind: TokenKind.Identifier, start: 4'u32, length: 1'u32)
    check t.kind == TokenKind.Identifier
    check t.start == 4'u32
    check t.length == 1'u32

# Helper: collect all tokens (including Eof) from a source string.
proc lex(src: string): seq[Token] =
  var lx = initLexer(src)
  for t in lx.tokens():
    result.add(t)

suite "lexer core":
  test "let x = 1 produces KwLet Identifier Eq NumberLit Eof":
    # Reference: build/zjs lex 'let x = 1'
    # KwLet         start=0  length=3
    # Identifier    start=4  length=1
    # Eq            start=6  length=1
    # NumberLit     start=8  length=1
    # Eof           start=9  length=0
    let toks = lex("let x = 1")
    check toks.len == 5
    check toks[0] == Token(kind: KwLet,       start: 0, length: 3)
    check toks[1] == Token(kind: Identifier,  start: 4, length: 1)
    check toks[2] == Token(kind: Eq,          start: 6, length: 1)
    check toks[3] == Token(kind: NumberLit,   start: 8, length: 1)
    check toks[4] == Token(kind: Eof,         start: 9, length: 0)

  test "keyword vs identifier: let vs lets":
    # 'let' => KwLet; 'lets' => Identifier
    let t1 = lex("let")
    check t1[0].kind == KwLet
    check t1[0].start == 0
    check t1[0].length == 3

    let t2 = lex("lets")
    check t2[0].kind == Identifier
    check t2[0].start == 0
    check t2[0].length == 4

  test "keyword vs identifier: for vs forx":
    # 'for' => KwFor; 'forx' => Identifier
    let t1 = lex("for")
    check t1[0].kind == KwFor
    check t1[0].length == 3

    let t2 = lex("forx")
    check t2[0].kind == Identifier
    check t2[0].length == 4

  test "punctuator longest-match: >>>= is one token GtGtGtEq":
    # Reference: GtGtGtEq start=0 length=4
    let toks = lex(">>>=")
    check toks[0] == Token(kind: GtGtGtEq, start: 0, length: 4)
    check toks[1].kind == Eof

  test "punctuator ??=":
    # Reference: QuestionQuestionEq start=0 length=3
    let toks = lex("??=")
    check toks[0] == Token(kind: QuestionQuestionEq, start: 0, length: 3)
    check toks[1].kind == Eof

  test "punctuator ===":
    let toks = lex("===")
    check toks[0] == Token(kind: EqEqEq, start: 0, length: 3)
    check toks[1].kind == Eof

  test "punctuator ...":
    let toks = lex("...")
    check toks[0] == Token(kind: Ellipsis, start: 0, length: 3)
    check toks[1].kind == Eof

  test "punctuator ?.":
    let toks = lex("?.")
    check toks[0] == Token(kind: QuestionDot, start: 0, length: 2)
    check toks[1].kind == Eof

  test "punctuator =>":
    let toks = lex("=>")
    check toks[0] == Token(kind: Arrow, start: 0, length: 2)
    check toks[1].kind == Eof

  test "punctuator a>>b: Identifier GtGt Identifier":
    # Reference: a=Identifier(0,1), GtGt(1,2), b=Identifier(3,1)
    let toks = lex("a>>b")
    check toks[0] == Token(kind: Identifier, start: 0, length: 1)
    check toks[1] == Token(kind: GtGt,       start: 1, length: 2)
    check toks[2] == Token(kind: Identifier, start: 3, length: 1)
    check toks[3].kind == Eof

  test "number: 0":
    let toks = lex("0")
    check toks[0] == Token(kind: NumberLit, start: 0, length: 1)

  test "number: 123":
    let toks = lex("123")
    check toks[0] == Token(kind: NumberLit, start: 0, length: 3)

  test "number: 1.5":
    let toks = lex("1.5")
    check toks[0] == Token(kind: NumberLit, start: 0, length: 3)

  test "number: 0xFF":
    let toks = lex("0xFF")
    check toks[0] == Token(kind: NumberLit, start: 0, length: 4)

  test "number: 0o17":
    let toks = lex("0o17")
    check toks[0] == Token(kind: NumberLit, start: 0, length: 4)

  test "number: 0b101":
    let toks = lex("0b101")
    check toks[0] == Token(kind: NumberLit, start: 0, length: 5)

  test "number: 1e10":
    let toks = lex("1e10")
    check toks[0] == Token(kind: NumberLit, start: 0, length: 4)

  test "number: 1.5e10":
    # Reference: NumberLit start=0 length=6
    let toks = lex("1.5e10")
    check toks[0] == Token(kind: NumberLit, start: 0, length: 6)

  test "number: 0b1010":
    # Reference: NumberLit start=0 length=6
    let toks = lex("0b1010")
    check toks[0] == Token(kind: NumberLit, start: 0, length: 6)

  test "BigInt: 42n":
    # Reference: ? (BigIntLit) start=0 length=3
    let toks = lex("42n")
    check toks[0] == Token(kind: BigIntLit, start: 0, length: 3)

  test "BigInt: 0xFFn":
    # Reference: ? (BigIntLit) start=0 length=5
    let toks = lex("0xFFn")
    check toks[0] == Token(kind: BigIntLit, start: 0, length: 5)

  test "PrivateName: #priv":
    # Reference: ? (PrivateName) start=0 length=5
    let toks = lex("#priv")
    check toks[0] == Token(kind: PrivateName, start: 0, length: 5)

  test "line comment: a // c\\nb":
    # Reference: Identifier(0,1), Identifier(7,1), Eof(8,0)
    let src = "a // c\nb"
    let toks = lex(src)
    check toks[0] == Token(kind: Identifier, start: 0, length: 1)
    check toks[1] == Token(kind: Identifier, start: 7, length: 1)
    check toks[2] == Token(kind: Eof,        start: 8, length: 0)

  test "block comment: a /* c */ b":
    # Reference: Identifier(0,1), Identifier(10,1), Eof(11,0)
    let src = "a /* c */ b"
    let toks = lex(src)
    check toks[0] == Token(kind: Identifier, start: 0,  length: 1)
    check toks[1] == Token(kind: Identifier, start: 10, length: 1)
    check toks[2] == Token(kind: Eof,        start: 11, length: 0)

  test "for(;;) keyword and punctuators":
    # Reference: KwFor(0,3), LParen(3,1), Semicolon(4,1), Semicolon(5,1), RParen(6,1), Eof(7,0)
    let toks = lex("for(;;)")
    check toks[0] == Token(kind: KwFor,      start: 0, length: 3)
    check toks[1] == Token(kind: LParen,     start: 3, length: 1)
    check toks[2] == Token(kind: Semicolon,  start: 4, length: 1)
    check toks[3] == Token(kind: Semicolon,  start: 5, length: 1)
    check toks[4] == Token(kind: RParen,     start: 6, length: 1)
    check toks[5].kind == Eof

  test "a >>> b: Identifier GtGtGt Identifier":
    # Reference: Identifier(0,1), GtGtGt(2,3), Identifier(6,1)
    let toks = lex("a >>> b")
    check toks[0] == Token(kind: Identifier, start: 0, length: 1)
    check toks[1] == Token(kind: GtGtGt,     start: 2, length: 3)
    check toks[2] == Token(kind: Identifier, start: 6, length: 1)

  test "dot: .5 is a number":
    # '.5' starts with '.' but peek_at(1) is a digit, so it becomes a number
    let toks = lex(".5")
    check toks[0].kind == NumberLit
    check toks[0].start == 0
    check toks[0].length == 2

  test "empty source gives only Eof":
    let toks = lex("")
    check toks.len == 1
    check toks[0].kind == Eof
    check toks[0].start == 0

suite "lexer strings/templates":
  # --- Single-quoted string -------------------------------------------

  test "'single' => StringLit(0,8) Eof(8,0)":
    # Reference: build/zjs lex "'single'"
    # StringLit  start=0  length=8
    # Eof        start=8  length=0
    let toks = lex("'single'")
    check toks.len == 2
    check toks[0] == Token(kind: StringLit, start: 0, length: 8)
    check toks[1] == Token(kind: Eof,       start: 8, length: 0)

  # --- Double-quoted string -------------------------------------------

  test "\"double\" => StringLit(0,8) Eof(8,0)":
    # Reference: build/zjs lex '"double"'
    # StringLit  start=0  length=8
    # Eof        start=8  length=0
    let toks = lex("\"double\"")
    check toks.len == 2
    check toks[0] == Token(kind: StringLit, start: 0, length: 8)
    check toks[1] == Token(kind: Eof,       start: 8, length: 0)

  # --- Escape sequences -----------------------------------------------

  test "'a\\\\nb' => StringLit(0,6) Eof(6,0)   (backslash-n escape)":
    # Reference: build/zjs lex "'a\nb'"
    # StringLit  start=0  length=6   ('a\nb' = 6 chars including quotes)
    # Eof        start=6  length=0
    let toks = lex("'a\\nb'")
    check toks.len == 2
    check toks[0] == Token(kind: StringLit, start: 0, length: 6)
    check toks[1] == Token(kind: Eof,       start: 6, length: 0)

  test "'\\x41' => StringLit(0,6) Eof(6,0)   (hex escape)":
    # Reference: build/zjs lex "'\x41'"
    # StringLit  start=0  length=6
    # Eof        start=6  length=0
    let toks = lex("'\\x41'")
    check toks.len == 2
    check toks[0] == Token(kind: StringLit, start: 0, length: 6)
    check toks[1] == Token(kind: Eof,       start: 6, length: 0)

  test "'it\\'s' => StringLit(0,7) Eof(7,0)   (escaped quote)":
    # Reference: build/zjs lex "'it\'s'"
    # StringLit  start=0  length=7   ('it\'s' = 7 chars including quotes)
    # Eof        start=7  length=0
    let toks = lex("'it\\'s'")
    check toks.len == 2
    check toks[0] == Token(kind: StringLit, start: 0, length: 7)
    check toks[1] == Token(kind: Eof,       start: 7, length: 0)

  # --- Unterminated string --------------------------------------------

  test "'abc (unterminated) => Invalid(0,4) Eof(4,0)":
    # Reference: build/zjs lex "'abc"
    # Invalid  start=0  length=4
    # Eof      start=4  length=0
    let toks = lex("'abc")
    check toks.len == 2
    check toks[0] == Token(kind: Invalid, start: 0, length: 4)
    check toks[1] == Token(kind: Eof,     start: 4, length: 0)

  # --- Template literals ----------------------------------------------

  test "`plain` => TemplateLit(0,7) Eof(7,0)":
    # Reference: build/zjs lex '`plain`'
    # ?  start=0  length=7
    # Eof start=7 length=0
    let toks = lex("`plain`")
    check toks.len == 2
    check toks[0] == Token(kind: TemplateLit, start: 0, length: 7)
    check toks[1] == Token(kind: Eof,         start: 7, length: 0)

  test "`a${b}c` => TemplateLit(0,8) Eof(8,0)   (one token spans whole literal)":
    # Reference: build/zjs lex '`a${b}c`'
    # ?  start=0  length=8
    # Eof start=8 length=0
    let toks = lex("`a${b}c`")
    check toks.len == 2
    check toks[0] == Token(kind: TemplateLit, start: 0, length: 8)
    check toks[1] == Token(kind: Eof,         start: 8, length: 0)

  test "`${`x`}` => TemplateLit(0,8) Eof(8,0)   (nested template)":
    # Reference: build/zjs lex '`${`x`}`'
    # ?  start=0  length=8
    # Eof start=8 length=0
    let toks = lex("`${`x`}`")
    check toks.len == 2
    check toks[0] == Token(kind: TemplateLit, start: 0, length: 8)
    check toks[1] == Token(kind: Eof,         start: 8, length: 0)

  test "`${1+2}` => TemplateLit(0,8) Eof(8,0)":
    # Reference: build/zjs lex '`${1+2}`'
    # ?  start=0  length=8
    # Eof start=8 length=0
    let toks = lex("`${1+2}`")
    check toks.len == 2
    check toks[0] == Token(kind: TemplateLit, start: 0, length: 8)
    check toks[1] == Token(kind: Eof,         start: 8, length: 0)

  test "regex-in-substitution: `${s.replace(/q/g,\"x\")}` => TemplateLit(0,24)":
    # Reference: SRC='`${s.replace(/q/g,"x")}`'
    # build/zjs lex "$SRC"
    # ?  start=0  length=24
    # Eof start=24 length=0
    # The ' inside the regex must NOT open a string.
    let src = "`${s.replace(/q/g,\"x\")}`"
    let toks = lex(src)
    check toks.len == 2
    check toks[0] == Token(kind: TemplateLit, start: 0,  length: 24)
    check toks[1] == Token(kind: Eof,         start: 24, length: 0)
