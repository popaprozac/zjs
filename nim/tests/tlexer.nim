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

suite "lexer regex":
  # --- Division (NOT regex) after value-producing tokens ---------------

  test "a / b => Identifier Slash Identifier (division after identifier)":
    # Reference: build/zjs lex 'a / b'
    # Identifier(0,1) Slash(2,1) Identifier(4,1) Eof(5,0)
    let toks = lex("a / b")
    check toks.len == 4
    check toks[0] == Token(kind: Identifier, start: 0, length: 1)
    check toks[1] == Token(kind: Slash,      start: 2, length: 1)
    check toks[2] == Token(kind: Identifier, start: 4, length: 1)
    check toks[3].kind == Eof

  test "a /= b => Identifier SlashEq Identifier":
    # Reference: build/zjs lex 'a /= b'
    # Identifier(0,1) SlashEq(2,2) Identifier(5,1) Eof(6,0)
    let toks = lex("a /= b")
    check toks.len == 4
    check toks[0] == Token(kind: Identifier, start: 0, length: 1)
    check toks[1] == Token(kind: SlashEq,    start: 2, length: 2)
    check toks[2] == Token(kind: Identifier, start: 5, length: 1)
    check toks[3].kind == Eof

  test "4 / 2 => NumberLit Slash NumberLit (division after number)":
    # Reference: build/zjs lex '4 / 2'
    # NumberLit(0,1) Slash(2,1) NumberLit(4,1) Eof(5,0)
    let toks = lex("4 / 2")
    check toks.len == 4
    check toks[0] == Token(kind: NumberLit, start: 0, length: 1)
    check toks[1] == Token(kind: Slash,     start: 2, length: 1)
    check toks[2] == Token(kind: NumberLit, start: 4, length: 1)
    check toks[3].kind == Eof

  test "a[0] / b => ... Slash ... (division after RBracket)":
    # Reference: build/zjs lex 'a[0] / b'
    # Identifier(0,1) LBracket(1,1) NumberLit(2,1) RBracket(3,1) Slash(5,1) Identifier(7,1) Eof(8,0)
    let toks = lex("a[0] / b")
    check toks.len == 7
    check toks[0] == Token(kind: Identifier, start: 0, length: 1)
    check toks[1] == Token(kind: LBracket,   start: 1, length: 1)
    check toks[2] == Token(kind: NumberLit,  start: 2, length: 1)
    check toks[3] == Token(kind: RBracket,   start: 3, length: 1)
    check toks[4] == Token(kind: Slash,      start: 5, length: 1)
    check toks[5] == Token(kind: Identifier, start: 7, length: 1)
    check toks[6].kind == Eof

  # --- Regex at expression-start positions ----------------------------

  test "/re/gi at start => RegexLit(0,6) Eof(6,0)":
    # Reference: build/zjs lex '/re/gi'
    # ?(=RegexLit)(0,6) Eof(6,0)
    let toks = lex("/re/gi")
    check toks.len == 2
    check toks[0] == Token(kind: RegexLit, start: 0, length: 6)
    check toks[1].kind == Eof

  test "return /x/ => KwReturn RegexLit(7,3)":
    # Reference: build/zjs lex 'return /x/'
    # KwReturn(0,6) ?(7,3) Eof(10,0)
    let toks = lex("return /x/")
    check toks.len == 3
    check toks[0] == Token(kind: KwReturn,  start: 0, length: 6)
    check toks[1] == Token(kind: RegexLit,  start: 7, length: 3)
    check toks[2].kind == Eof

  test "x = /y/ => Identifier Eq RegexLit(4,3)":
    # Reference: build/zjs lex 'x = /y/'
    # Identifier(0,1) Eq(2,1) ?(4,3) Eof(7,0)
    let toks = lex("x = /y/")
    check toks.len == 4
    check toks[0] == Token(kind: Identifier, start: 0, length: 1)
    check toks[1] == Token(kind: Eq,         start: 2, length: 1)
    check toks[2] == Token(kind: RegexLit,   start: 4, length: 3)
    check toks[3].kind == Eof

  test "typeof /z/ => KwTypeof RegexLit(7,3)":
    # Reference: build/zjs lex 'typeof /z/'
    # KwTypeof(0,6) ?(7,3) Eof(10,0)
    let toks = lex("typeof /z/")
    check toks.len == 3
    check toks[0] == Token(kind: KwTypeof, start: 0, length: 6)
    check toks[1] == Token(kind: RegexLit, start: 7, length: 3)
    check toks[2].kind == Eof

  test "(/a/) => LParen RegexLit(1,3) RParen":
    # Reference: build/zjs lex '(/a/)'
    # LParen(0,1) ?(1,3) RParen(4,1) Eof(5,0)
    let toks = lex("(/a/)")
    check toks.len == 4
    check toks[0] == Token(kind: LParen,   start: 0, length: 1)
    check toks[1] == Token(kind: RegexLit, start: 1, length: 3)
    check toks[2] == Token(kind: RParen,   start: 4, length: 1)
    check toks[3].kind == Eof

  # --- Regex internals ------------------------------------------------

  test "/[/]/ => RegexLit(0,5): slash inside char class is literal":
    # Reference: build/zjs lex '/[/]/'
    # ?(0,5) Eof(5,0)
    let toks = lex("/[/]/")
    check toks.len == 2
    check toks[0] == Token(kind: RegexLit, start: 0, length: 5)
    check toks[1].kind == Eof

  test "/a\\/b/ => RegexLit(0,6): escaped slash inside regex":
    # Reference: build/zjs lex '/a\/b/'
    # ?(0,6) Eof(6,0)
    let toks = lex("/a\\/b/")
    check toks.len == 2
    check toks[0] == Token(kind: RegexLit, start: 0, length: 6)
    check toks[1].kind == Eof

  test "/x/gimuy => RegexLit(0,8): multi-char flags":
    # Reference: build/zjs lex '/x/gimuy'
    # ?(0,8) Eof(8,0)
    let toks = lex("/x/gimuy")
    check toks.len == 2
    check toks[0] == Token(kind: RegexLit, start: 0, length: 8)
    check toks[1].kind == Eof

  # --- The } ambiguity ------------------------------------------------

  test "x={} / 2 => ... Slash (division: } without preceding newline)":
    # Reference: build/zjs lex 'x={} / 2'
    # Identifier(0,1) Eq(1,1) LBrace(2,1) RBrace(3,1) Slash(5,1) NumberLit(7,1) Eof(8,0)
    let toks = lex("x={} / 2")
    check toks.len == 7
    check toks[0] == Token(kind: Identifier, start: 0, length: 1)
    check toks[1] == Token(kind: Eq,         start: 1, length: 1)
    check toks[2] == Token(kind: LBrace,     start: 2, length: 1)
    check toks[3] == Token(kind: RBrace,     start: 3, length: 1)
    check toks[4] == Token(kind: Slash,      start: 5, length: 1)
    check toks[5] == Token(kind: NumberLit,  start: 7, length: 1)
    check toks[6].kind == Eof

  test "function f(){}\\n/re/ => RegexLit after block (} + newline)":
    # Reference: build/zjs lex "function f(){}\n/re/"
    # KwFunction(0,8) Identifier(9,1) LParen(10,1) RParen(11,1)
    # LBrace(12,1) RBrace(13,1) ?(15,4) Eof(19,0)
    let src = "function f(){}\n/re/"
    let toks = lex(src)
    check toks.len == 8
    check toks[0] == Token(kind: KwFunction, start: 0,  length: 8)
    check toks[1] == Token(kind: Identifier, start: 9,  length: 1)
    check toks[2] == Token(kind: LParen,     start: 10, length: 1)
    check toks[3] == Token(kind: RParen,     start: 11, length: 1)
    check toks[4] == Token(kind: LBrace,     start: 12, length: 1)
    check toks[5] == Token(kind: RBrace,     start: 13, length: 1)
    check toks[6] == Token(kind: RegexLit,   start: 15, length: 4)
    check toks[7].kind == Eof
