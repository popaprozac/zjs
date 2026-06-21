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

suite "parser call/member":
  test "a.b — Member node with propName 'b' and IdentExpr recv":
    var p = initParser("a.b")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let m = prog.stmts[0]
    check m.kind == NodeKind.Member
    check m.recv.kind == NodeKind.IdentExpr
    # propStart=2, propLength=1 → "b"
    check p.source[m.propStart.int ..< (m.propStart + m.propLength).int] == "b"

  test "a[b] — Computed node with IdentExpr index":
    var p = initParser("a[b]")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let c = prog.stmts[0]
    check c.kind == NodeKind.Computed
    check c.recv.kind == NodeKind.IdentExpr
    check c.index.kind == NodeKind.IdentExpr

  test "f(x) — Call with one IdentExpr arg":
    var p = initParser("f(x)")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let call = prog.stmts[0]
    check call.kind == NodeKind.Call
    check call.callee.kind == NodeKind.IdentExpr
    check call.args.len == 1
    check call.args[0].kind == NodeKind.IdentExpr

  test "f() — Call with zero args":
    var p = initParser("f()")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let call = prog.stmts[0]
    check call.kind == NodeKind.Call
    check call.callee.kind == NodeKind.IdentExpr
    check call.args.len == 0

  test "new F(1) — New with NumberExpr arg":
    var p = initParser("new F(1)")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let n = prog.stmts[0]
    check n.kind == NodeKind.New
    check n.callee.kind == NodeKind.IdentExpr
    check n.args.len == 1
    check n.args[0].kind == NodeKind.NumberExpr
    check n.args[0].numVal == 1.0

  test "new X — New with no args":
    var p = initParser("new X")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let n = prog.stmts[0]
    check n.kind == NodeKind.New
    check n.callee.kind == NodeKind.IdentExpr
    check n.args.len == 0

  test "a?.b — OptionalMember node":
    var p = initParser("a?.b")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let m = prog.stmts[0]
    check m.kind == NodeKind.OptionalMember
    check m.recv.kind == NodeKind.IdentExpr
    check p.source[m.propStart.int ..< (m.propStart + m.propLength).int] == "b"

  test "f(...x) — Call with Spread arg":
    var p = initParser("f(...x)")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let call = prog.stmts[0]
    check call.kind == NodeKind.Call
    check call.args.len == 1
    check call.args[0].kind == NodeKind.Spread
    check call.args[0].spreadArg.kind == NodeKind.IdentExpr

  test "a.b.c(d)[e] — chained member/call/computed":
    var p = initParser("a.b.c(d)[e]")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let comp = prog.stmts[0]
    check comp.kind == NodeKind.Computed
    check comp.recv.kind == NodeKind.Call
    let call = comp.recv
    check call.callee.kind == NodeKind.Member  # "c"
    check call.callee.recv.kind == NodeKind.Member  # "b"
    check call.callee.recv.recv.kind == NodeKind.IdentExpr  # "a"

  test "new a.b() — New with Member callee":
    var p = initParser("new a.b()")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let n = prog.stmts[0]
    check n.kind == NodeKind.New
    check n.callee.kind == NodeKind.Member
    check n.callee.recv.kind == NodeKind.IdentExpr

suite "ast 2c-1 nodes":
  test "member + computed":
    let recv = newLeaf(IdentExpr, 0'u32, 1'u32)
    let m = newMember(NodeKind.Member, 0'u32, 3'u32, 2'u32, 1'u32, recv)
    check m.kind == NodeKind.Member
    check m.recv.kind == NodeKind.IdentExpr
    check m.propStart == 2'u32 and m.propLength == 1'u32
    let idx = newLeaf(IdentExpr, 2'u32, 3'u32)
    let c = newComputed(NodeKind.Computed, 0'u32, 4'u32, recv, idx)
    check c.kind == NodeKind.Computed
    check c.index.kind == NodeKind.IdentExpr

  test "call + new + spread":
    let callee = newLeaf(IdentExpr, 0'u32, 1'u32)
    let arg = newNumber(2'u32, 3'u32, 1.0)
    let call = newCall(NodeKind.Call, 0'u32, 4'u32, callee, @[arg])
    check call.kind == NodeKind.Call
    check call.callee.kind == NodeKind.IdentExpr
    check call.args.len == 1
    let sp = newSpread(0'u32, 4'u32, callee)
    check sp.kind == NodeKind.Spread
    check sp.spreadArg.kind == NodeKind.IdentExpr

  test "optional variants carry correct kind":
    let recv = newLeaf(IdentExpr, 0'u32, 1'u32)
    let idx = newLeaf(IdentExpr, 4'u32, 5'u32)
    let om = newMember(NodeKind.OptionalMember, 0'u32, 4'u32, 3'u32, 1'u32, recv)
    check om.kind == NodeKind.OptionalMember
    check om.recv.kind == NodeKind.IdentExpr
    let oc = newComputed(NodeKind.OptionalComputed, 0'u32, 6'u32, recv, idx)
    check oc.kind == NodeKind.OptionalComputed
    check oc.index.kind == NodeKind.IdentExpr
    let callee = newLeaf(IdentExpr, 0'u32, 1'u32)
    let ocall = newCall(NodeKind.OptionalCall, 0'u32, 5'u32, callee, @[])
    check ocall.kind == NodeKind.OptionalCall
    check ocall.callee.kind == NodeKind.IdentExpr
    let newNode = newCall(NodeKind.New, 0'u32, 6'u32, callee, @[newNumber(4'u32, 5'u32, 1.0)])
    check newNode.kind == NodeKind.New
    check newNode.args.len == 1
