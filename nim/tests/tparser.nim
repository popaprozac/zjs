import std/unittest
import ../src/zjs/ast
import ../src/zjs/token
import ../src/zjs/parser

suite "ast model":
  test "NodeKind variant names match Zen-c dump labels":
    check $NodeKind.Program == "Program"
    check $NodeKind.NumberExpr == "NumberExpr"
    check $NodeKind.Binary == "Binary"
    check $NodeKind.VarDecl == "VarDecl"
    check $NodeKind.Declarator == "Declarator"

  test "variant nodes expose semantic fields":
    let lhs = newNumber(0'u32, 1'u32, 1.0)
    let rhs = newNumber(4'u32, 5'u32, 2.0)
    let b = newBinary(NodeKind.Binary, 0'u32, 5'u32, TokenKind.Plus, lhs, rhs)
    check b.kind == NodeKind.Binary
    check b.binOp == TokenKind.Plus
    check b.lhs.numVal == 1.0
    check b.rhs.numVal == 2.0

  test "paren wraps inner; declarator carries optional init":
    let inner = newNumber(1'u32, 3'u32, 42.0)
    let p = newParen(0'u32, 4'u32, inner)
    check p.kind == NodeKind.Paren
    check p.inner.numVal == 42.0
    let d = newDeclarator(0'u32, 1'u32, 0'u32, 1'u32, nil)
    check d.kind == NodeKind.Declarator
    check d.init == nil

suite "parser primaries":
  test "number literal integer":
    var p = initParser("1")
    let prog = p.parseProgram()
    check prog.kind == NodeKind.Program
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.NumberExpr
    check prog.stmts[0].numVal == 1.0

  test "number literal float":
    var p = initParser("1.5")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.NumberExpr
    check prog.stmts[0].numVal == 1.5

  test "number literal 42":
    var p = initParser("42")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.NumberExpr
    check prog.stmts[0].numVal == 42.0

  test "string literal":
    var p = initParser("\"s\"")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.StringExpr

  test "boolean true":
    var p = initParser("true")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.BoolExpr
    check prog.stmts[0].boolVal == true

  test "boolean false":
    var p = initParser("false")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.BoolExpr
    check prog.stmts[0].boolVal == false

  test "null":
    var p = initParser("null")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.NullExpr

  test "undefined":
    var p = initParser("undefined")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.UndefinedExpr

  test "identifier":
    var p = initParser("x")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.IdentExpr

  test "identifier foo":
    var p = initParser("foo")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.IdentExpr

  test "this":
    var p = initParser("this")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.ThisExpr

  test "parenthesized is not transparent":
    var p = initParser("(42)")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.Paren
    check prog.stmts[0].inner.kind == NodeKind.NumberExpr
    check prog.stmts[0].inner.numVal == 42.0

  test "parenthesized spans from lparen to rparen inclusive":
    var p = initParser("(42)")
    let prog = p.parseProgram()
    let paren = prog.stmts[0]
    # "(42)" — start=0, end=4
    check paren.start == 0'u32
    check paren.`end` == 4'u32

  test "number literal start/end spans":
    var p = initParser("1")
    let prog = p.parseProgram()
    let n = prog.stmts[0]
    check n.start == 0'u32
    check n.`end` == 1'u32

suite "parser operators":
  test "1 + 2 is Binary Plus":
    var p = initParser("1 + 2")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0]
    check node.kind == NodeKind.Binary
    check node.binOp == TokenKind.Plus
    check node.lhs.kind == NodeKind.NumberExpr
    check node.rhs.kind == NodeKind.NumberExpr

  test "1 + 2 * 3 — precedence: Plus over {1, Star{2,3}}":
    var p = initParser("1 + 2 * 3")
    let prog = p.parseProgram()
    let node = prog.stmts[0]
    check node.kind == NodeKind.Binary
    check node.binOp == TokenKind.Plus
    check node.lhs.kind == NodeKind.NumberExpr
    check node.lhs.numVal == 1.0
    check node.rhs.kind == NodeKind.Binary
    check node.rhs.binOp == TokenKind.Star
    check node.rhs.lhs.numVal == 2.0
    check node.rhs.rhs.numVal == 3.0

  test "-x is Unary Minus":
    var p = initParser("-x")
    let prog = p.parseProgram()
    let node = prog.stmts[0]
    check node.kind == NodeKind.Unary
    check node.unOp == TokenKind.Minus
    check node.operand.kind == NodeKind.IdentExpr

  test "!a is Unary Bang":
    var p = initParser("!a")
    let prog = p.parseProgram()
    let node = prog.stmts[0]
    check node.kind == NodeKind.Unary
    check node.unOp == TokenKind.Bang
    check node.operand.kind == NodeKind.IdentExpr

  test "a && b is Logical AmpAmp":
    var p = initParser("a && b")
    let prog = p.parseProgram()
    let node = prog.stmts[0]
    check node.kind == NodeKind.Logical
    check node.binOp == TokenKind.AmpAmp
    check node.lhs.kind == NodeKind.IdentExpr
    check node.rhs.kind == NodeKind.IdentExpr

  test "2 ** 3 ** 2 is right-associative":
    # outer StarStar, rhs is also StarStar
    var p = initParser("2 ** 3 ** 2")
    let prog = p.parseProgram()
    let node = prog.stmts[0]
    check node.kind == NodeKind.Binary
    check node.binOp == TokenKind.StarStar
    check node.lhs.kind == NodeKind.NumberExpr
    check node.lhs.numVal == 2.0
    check node.rhs.kind == NodeKind.Binary
    check node.rhs.binOp == TokenKind.StarStar
    check node.rhs.lhs.numVal == 3.0
    check node.rhs.rhs.numVal == 2.0

  test "a + b - c is left-associative — outer Minus, lhs is Plus":
    var p = initParser("a + b - c")
    let prog = p.parseProgram()
    let node = prog.stmts[0]
    check node.kind == NodeKind.Binary
    check node.binOp == TokenKind.Minus
    check node.lhs.kind == NodeKind.Binary
    check node.lhs.binOp == TokenKind.Plus
    check node.rhs.kind == NodeKind.IdentExpr

  test "a++ is Postfix PlusPlus":
    var p = initParser("a++")
    let prog = p.parseProgram()
    let node = prog.stmts[0]
    check node.kind == NodeKind.Postfix
    check node.unOp == TokenKind.PlusPlus
    check node.operand.kind == NodeKind.IdentExpr

suite "parser declarations":
  test "let x = 1; — VarDecl KwLet with one Declarator init NumberExpr":
    var p = initParser("let x = 1;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let decl = prog.stmts[0]
    check decl.kind == NodeKind.VarDecl
    check decl.declKind == TokenKind.KwLet
    check decl.declarators.len == 1
    let d = decl.declarators[0]
    check d.kind == NodeKind.Declarator
    check p.source[d.nameStart.int ..< (d.nameStart + d.nameLength).int] == "x"
    check d.init != nil
    check d.init.kind == NodeKind.NumberExpr
    check d.init.numVal == 1.0

  test "const a = 1 + 2; — VarDecl KwConst init Binary":
    var p = initParser("const a = 1 + 2;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let decl = prog.stmts[0]
    check decl.kind == NodeKind.VarDecl
    check decl.declKind == TokenKind.KwConst
    check decl.declarators.len == 1
    let d = decl.declarators[0]
    check p.source[d.nameStart.int ..< (d.nameStart + d.nameLength).int] == "a"
    check d.init != nil
    check d.init.kind == NodeKind.Binary
    check d.init.binOp == TokenKind.Plus

  test "var y; — VarDecl KwVar one Declarator with nil init":
    var p = initParser("var y;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let decl = prog.stmts[0]
    check decl.kind == NodeKind.VarDecl
    check decl.declKind == TokenKind.KwVar
    check decl.declarators.len == 1
    let d = decl.declarators[0]
    check p.source[d.nameStart.int ..< (d.nameStart + d.nameLength).int] == "y"
    check d.init == nil

  test "let a = 1, b = 2; — two declarators":
    var p = initParser("let a = 1, b = 2;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let decl = prog.stmts[0]
    check decl.kind == NodeKind.VarDecl
    check decl.declKind == TokenKind.KwLet
    check decl.declarators.len == 2
    let da = decl.declarators[0]
    check p.source[da.nameStart.int ..< (da.nameStart + da.nameLength).int] == "a"
    check da.init != nil
    check da.init.numVal == 1.0
    let db = decl.declarators[1]
    check p.source[db.nameStart.int ..< (db.nameStart + db.nameLength).int] == "b"
    check db.init != nil
    check db.init.numVal == 2.0

  test "bare expression statement still works after dispatch extension":
    var p = initParser("x + 1;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0]
    check node.kind == NodeKind.Binary
    check node.binOp == TokenKind.Plus
    check node.lhs.kind == NodeKind.IdentExpr
    check node.rhs.kind == NodeKind.NumberExpr
