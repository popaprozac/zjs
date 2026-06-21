## Token model — mirrors src/token.zc. A Token is a flat slice into the
## source (kind + start + length); no decoded value. Variant names MUST
## match src/token.zc exactly so `$kind` reproduces the `zjs lex` dump.

type
  TokenKind* = enum
    Eof, Invalid,
    Identifier, NumberLit, BigIntLit, StringLit, RegexLit, TemplateLit,
    KwVar, KwLet, KwConst,
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
    KwGet, KwSet,
    LParen, RParen, LBracket, RBracket, LBrace, RBrace,
    Comma, Semicolon, Colon, Dot, Ellipsis, Arrow, Tilde,
    Question, QuestionDot, QuestionQuestion, QuestionQuestionEq,
    Bang, BangEq, BangEqEq, Eq, EqEq, EqEqEq,
    Lt, LtEq, LtLt, LtLtEq, Gt, GtEq, GtGt, GtGtEq, GtGtGt, GtGtGtEq,
    Plus, PlusEq, PlusPlus, Minus, MinusEq, MinusMinus,
    Star, StarEq, StarStar, StarStarEq, Slash, SlashEq, Percent, PercentEq,
    Amp, AmpAmp, AmpEq, AmpAmpEq, Pipe, PipePipe, PipeEq, PipePipeEq,
    Caret, CaretEq,
    PrivateName

  Token* = object
    kind*: TokenKind
    start*: uint32
    length*: uint32

proc tokenEof*(at: uint32): Token {.inline.} =
  Token(kind: Eof, start: at, length: 0'u32)
proc tokenInvalid*(at: uint32): Token {.inline.} =
  Token(kind: Invalid, start: at, length: 1'u32)
