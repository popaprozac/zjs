import std/unittest
import ../src/zjs/token

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
