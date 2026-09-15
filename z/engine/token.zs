// Token kinds and the flat token record.
//
// Variant ORDER mirrors src/token.zc exactly, and `kindCode` reproduces the
// reference engine's integer numbering, so token dumps from both engines can
// be diffed line-for-line. Do not reorder without regenerating kindCode.
//
// Finding G17: Z enums (plain or `c enum`) have no outward integer
// conversion -- `u8(kind)` is rejected -- so the numbering has to be an
// exhaustive match instead of a cast. Generated from src/token.zc.
//
// A Token is a slice into the source plus a kind. No decoded value lives
// here; numbers and strings are decoded when the compiler materializes
// constants. Cleanup-free, so it copies freely.

export enum TokenKind {
  eof,
  invalid,
  identifier,
  numberLit,
  bigIntLit,
  stringLit,
  regexLit,
  templateLit,
  kwVar,
  kwLet,
  kwConst,
  kwFunction,
  kwReturn,
  kwIf,
  kwElse,
  kwFor,
  kwWhile,
  kwDo,
  kwBreak,
  kwContinue,
  kwClass,
  kwExtends,
  kwSuper,
  kwNew,
  kwThis,
  kwTrue,
  kwFalse,
  kwNull,
  kwUndefined,
  kwTypeof,
  kwDelete,
  kwVoid,
  kwIn,
  kwOf,
  kwInstanceof,
  kwThrow,
  kwTry,
  kwCatch,
  kwFinally,
  kwSwitch,
  kwCase,
  kwDefault,
  kwWith,
  kwAsync,
  kwAwait,
  kwYield,
  kwImport,
  kwExport,
  kwFrom,
  kwAs,
  kwGet,
  kwSet,
  lParen,
  rParen,
  lBracket,
  rBracket,
  lBrace,
  rBrace,
  comma,
  semicolon,
  colon,
  dot,
  ellipsis,
  arrow,
  tilde,
  question,
  questionDot,
  questionQuestion,
  questionQuestionEq,
  bang,
  bangEq,
  bangEqEq,
  eq,
  eqEq,
  eqEqEq,
  lt,
  ltEq,
  ltLt,
  ltLtEq,
  gt,
  gtEq,
  gtGt,
  gtGtEq,
  gtGtGt,
  gtGtGtEq,
  plus,
  plusEq,
  plusPlus,
  minus,
  minusEq,
  minusMinus,
  star,
  starEq,
  starStar,
  starStarEq,
  slash,
  slashEq,
  percent,
  percentEq,
  amp,
  ampAmp,
  ampEq,
  ampAmpEq,
  pipe,
  pipePipe,
  pipeEq,
  pipePipeEq,
  caret,
  caretEq,
  privateName,
}

export struct Token {
  kind: TokenKind;
  start: u32;
  length: u32;
}

export function tokenEof(at: u32): Token {
  return Token({ kind: TokenKind.eof, start: at, length: 0 });
}

export function tokenInvalid(at: u32): Token {
  return Token({ kind: TokenKind.invalid, start: at, length: 1 });
}

// Reference numbering (C enum order in src/token.zc).
export function kindCode(kind: TokenKind): i32 {
  return match (kind) {
    eof => 0;
    invalid => 1;
    identifier => 2;
    numberLit => 3;
    bigIntLit => 4;
    stringLit => 5;
    regexLit => 6;
    templateLit => 7;
    kwVar => 8;
    kwLet => 9;
    kwConst => 10;
    kwFunction => 11;
    kwReturn => 12;
    kwIf => 13;
    kwElse => 14;
    kwFor => 15;
    kwWhile => 16;
    kwDo => 17;
    kwBreak => 18;
    kwContinue => 19;
    kwClass => 20;
    kwExtends => 21;
    kwSuper => 22;
    kwNew => 23;
    kwThis => 24;
    kwTrue => 25;
    kwFalse => 26;
    kwNull => 27;
    kwUndefined => 28;
    kwTypeof => 29;
    kwDelete => 30;
    kwVoid => 31;
    kwIn => 32;
    kwOf => 33;
    kwInstanceof => 34;
    kwThrow => 35;
    kwTry => 36;
    kwCatch => 37;
    kwFinally => 38;
    kwSwitch => 39;
    kwCase => 40;
    kwDefault => 41;
    kwWith => 42;
    kwAsync => 43;
    kwAwait => 44;
    kwYield => 45;
    kwImport => 46;
    kwExport => 47;
    kwFrom => 48;
    kwAs => 49;
    kwGet => 50;
    kwSet => 51;
    lParen => 52;
    rParen => 53;
    lBracket => 54;
    rBracket => 55;
    lBrace => 56;
    rBrace => 57;
    comma => 58;
    semicolon => 59;
    colon => 60;
    dot => 61;
    ellipsis => 62;
    arrow => 63;
    tilde => 64;
    question => 65;
    questionDot => 66;
    questionQuestion => 67;
    questionQuestionEq => 68;
    bang => 69;
    bangEq => 70;
    bangEqEq => 71;
    eq => 72;
    eqEq => 73;
    eqEqEq => 74;
    lt => 75;
    ltEq => 76;
    ltLt => 77;
    ltLtEq => 78;
    gt => 79;
    gtEq => 80;
    gtGt => 81;
    gtGtEq => 82;
    gtGtGt => 83;
    gtGtGtEq => 84;
    plus => 85;
    plusEq => 86;
    plusPlus => 87;
    minus => 88;
    minusEq => 89;
    minusMinus => 90;
    star => 91;
    starEq => 92;
    starStar => 93;
    starStarEq => 94;
    slash => 95;
    slashEq => 96;
    percent => 97;
    percentEq => 98;
    amp => 99;
    ampAmp => 100;
    ampEq => 101;
    ampAmpEq => 102;
    pipe => 103;
    pipePipe => 104;
    pipeEq => 105;
    pipePipeEq => 106;
    caret => 107;
    caretEq => 108;
    privateName => 109;
  };
}

// Whether the *next* `/` should lex as a regex literal, given the kind of
// token just emitted. Value-producing tokens block regex mode; everything
// else leaves it on. Mirrors expect_regex_after in src/lexer.zc, including
// the contextual keywords that can stand in as identifiers.
export function expectRegexAfter(kind: TokenKind): boolean {
  return match (kind) {
    identifier => false;
    numberLit => false;
    bigIntLit => false;
    stringLit => false;
    regexLit => false;
    rParen => false;
    rBracket => false;
    rBrace => false;
    plusPlus => false;
    minusMinus => false;
    kwTrue => false;
    kwFalse => false;
    kwNull => false;
    kwUndefined => false;
    kwThis => false;
    kwSuper => false;
    kwOf => false;
    kwAs => false;
    kwFrom => false;
    kwGet => false;
    kwSet => false;
    kwAsync => false;
    kwAwait => false;
    kwYield => false;
    _ => true;
  };
}
