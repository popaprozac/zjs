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

suite "parser conditional/sequence":
  test "ternary a?b:c produces Conditional with three children":
    var p = initParser("a ? b : c")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let cond = prog.stmts[0]
    check cond.kind == NodeKind.Conditional
    check cond.cond.kind == NodeKind.IdentExpr
    check cond.conseq.kind == NodeKind.IdentExpr
    check cond.alt.kind == NodeKind.IdentExpr

  test "ternary is right-associative: a?b:c?d:e":
    var p = initParser("a ? b : c ? d : e")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let outer = prog.stmts[0]
    check outer.kind == NodeKind.Conditional
    # cond = a, conseq = b, alt = Conditional{c,d,e}
    check outer.cond.kind == NodeKind.IdentExpr
    check outer.conseq.kind == NodeKind.IdentExpr
    check outer.alt.kind == NodeKind.Conditional
    check outer.alt.cond.kind == NodeKind.IdentExpr
    check outer.alt.conseq.kind == NodeKind.IdentExpr
    check outer.alt.alt.kind == NodeKind.IdentExpr

  test "comma sequence a,b,c produces Sequence with 3 items":
    var p = initParser("a, b, c")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let seq0 = prog.stmts[0]
    check seq0.kind == NodeKind.Sequence
    check seq0.items.len == 3
    check seq0.items[0].kind == NodeKind.IdentExpr
    check seq0.items[1].kind == NodeKind.IdentExpr
    check seq0.items[2].kind == NodeKind.IdentExpr

  test "?: binds tighter than comma: a?b:c,d -> Sequence{Conditional,d}":
    var p = initParser("a ? b : c, d")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let seq0 = prog.stmts[0]
    check seq0.kind == NodeKind.Sequence
    check seq0.items.len == 2
    check seq0.items[0].kind == NodeKind.Conditional
    check seq0.items[1].kind == NodeKind.IdentExpr

  test "newConditional and newSequence constructors":
    let a = newLeaf(IdentExpr, 0'u32, 1'u32)
    let b = newLeaf(IdentExpr, 4'u32, 5'u32)
    let c = newLeaf(IdentExpr, 8'u32, 9'u32)
    let cnode = newConditional(0'u32, 9'u32, a, b, c)
    check cnode.kind == NodeKind.Conditional
    check cnode.cond.kind == NodeKind.IdentExpr
    check cnode.conseq.kind == NodeKind.IdentExpr
    check cnode.alt.kind == NodeKind.IdentExpr
    let snode = newSequence(0'u32, 9'u32, @[a, b, c])
    check snode.kind == NodeKind.Sequence
    check snode.items.len == 3

suite "ast 2c-3 nodes":
  test "array":
    let a = newArray(0'u32, 5'u32, @[newNumber(1'u32,2'u32,1.0)])
    check a.kind == NodeKind.Array
    check a.elems.len == 1
  test "object + prop":
    let v = newNumber(4'u32,5'u32,1.0)
    let prop = newObjectProp(1'u32,5'u32, 1'u32,1'u32, v, nil)
    check prop.kind == NodeKind.ObjectProp
    check prop.keyStart == 1'u32 and prop.keyLength == 1'u32
    check prop.propVal.kind == NodeKind.NumberExpr
    check prop.computedKey == nil
    let o = newObject(0'u32,6'u32, @[prop])
    check o.kind == NodeKind.Object
    check o.props.len == 1
  test "hole via newLeaf":
    let h = newLeaf(HoleExpr, 2'u32, 2'u32)
    check h.kind == NodeKind.HoleExpr

suite "parser array/object":
  test "empty array [] — Array with zero elems":
    var p = initParser("[]")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.Array
    check arr.elems.len == 0

  test "[1, 2, 3] — Array with three NumberExpr elems":
    var p = initParser("[1, 2, 3]")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.Array
    check arr.elems.len == 3
    check arr.elems[0].kind == NodeKind.NumberExpr
    check arr.elems[0].numVal == 1.0
    check arr.elems[1].numVal == 2.0
    check arr.elems[2].numVal == 3.0

  test "[1, , 3] — elision produces HoleExpr":
    var p = initParser("[1, , 3]")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.Array
    check arr.elems.len == 3
    check arr.elems[0].kind == NodeKind.NumberExpr
    check arr.elems[1].kind == NodeKind.HoleExpr
    check arr.elems[2].kind == NodeKind.NumberExpr

  test "[,] — single hole":
    var p = initParser("[,]")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.Array
    check arr.elems.len == 1
    check arr.elems[0].kind == NodeKind.HoleExpr

  test "[...a, b] — spread followed by ident":
    var p = initParser("[...a, b]")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.Array
    check arr.elems.len == 2
    check arr.elems[0].kind == NodeKind.Spread
    check arr.elems[0].spreadArg.kind == NodeKind.IdentExpr
    check arr.elems[1].kind == NodeKind.IdentExpr

  test "[1, ...x, 2] — spread in middle":
    var p = initParser("[1, ...x, 2]")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.Array
    check arr.elems.len == 3
    check arr.elems[0].kind == NodeKind.NumberExpr
    check arr.elems[1].kind == NodeKind.Spread
    check arr.elems[2].kind == NodeKind.NumberExpr

  test "[a, [b, c]] — nested array":
    var p = initParser("[a, [b, c]]")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.Array
    check arr.elems.len == 2
    check arr.elems[0].kind == NodeKind.IdentExpr
    check arr.elems[1].kind == NodeKind.Array
    check arr.elems[1].elems.len == 2

  test "({}) — empty object":
    var p = initParser("({})")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let paren = prog.stmts[0]
    check paren.kind == NodeKind.Paren
    let obj = paren.inner
    check obj.kind == NodeKind.Object
    check obj.props.len == 0

  test "({a: 1, b: 2}) — two named props":
    var p = initParser("({a: 1, b: 2})")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let obj = prog.stmts[0].inner
    check obj.kind == NodeKind.Object
    check obj.props.len == 2
    let pa = obj.props[0]
    check pa.kind == NodeKind.ObjectProp
    check p.source[pa.keyStart.int ..< (pa.keyStart + pa.keyLength).int] == "a"
    check pa.propVal.kind == NodeKind.NumberExpr
    check pa.propVal.numVal == 1.0
    check pa.computedKey == nil
    let pb = obj.props[1]
    check p.source[pb.keyStart.int ..< (pb.keyStart + pb.keyLength).int] == "b"
    check pb.propVal.numVal == 2.0

  test "({a}) — shorthand prop value is IdentExpr":
    var p = initParser("({a})")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let obj = prog.stmts[0].inner
    check obj.kind == NodeKind.Object
    check obj.props.len == 1
    let prop = obj.props[0]
    check prop.kind == NodeKind.ObjectProp
    check p.source[prop.keyStart.int ..< (prop.keyStart + prop.keyLength).int] == "a"
    check prop.propVal.kind == NodeKind.IdentExpr
    check prop.computedKey == nil

  test "({a, b, c}) — multiple shorthand props":
    var p = initParser("({a, b, c})")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let obj = prog.stmts[0].inner
    check obj.kind == NodeKind.Object
    check obj.props.len == 3
    for prop in obj.props:
      check prop.kind == NodeKind.ObjectProp
      check prop.propVal.kind == NodeKind.IdentExpr

  test "({[k]: v}) — computed key: keyStart/Length=0, computedKey=IdentExpr":
    var p = initParser("({[k]: v})")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let obj = prog.stmts[0].inner
    check obj.kind == NodeKind.Object
    check obj.props.len == 1
    let prop = obj.props[0]
    check prop.kind == NodeKind.ObjectProp
    check prop.keyStart == 0'u32
    check prop.keyLength == 0'u32
    check prop.propVal.kind == NodeKind.IdentExpr   # "v"
    check prop.computedKey != nil
    check prop.computedKey.kind == NodeKind.IdentExpr  # "k"

  test "({...x, y: 1}) — spread then named prop":
    var p = initParser("({...x, y: 1})")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let obj = prog.stmts[0].inner
    check obj.kind == NodeKind.Object
    check obj.props.len == 2
    check obj.props[0].kind == NodeKind.Spread
    check obj.props[0].spreadArg.kind == NodeKind.IdentExpr
    check obj.props[1].kind == NodeKind.ObjectProp
    check obj.props[1].propVal.kind == NodeKind.NumberExpr

  test "({\"s\": 1, 5: 2}) — string and number keys":
    var p = initParser("({\"s\": 1, 5: 2})")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let obj = prog.stmts[0].inner
    check obj.kind == NodeKind.Object
    check obj.props.len == 2
    # string key keeps quotes in the source slice
    let ps = obj.props[0]
    check ps.kind == NodeKind.ObjectProp
    check p.source[ps.keyStart.int ..< (ps.keyStart + ps.keyLength).int] == "\"s\""
    check ps.propVal.numVal == 1.0
    # number key
    let pn = obj.props[1]
    check p.source[pn.keyStart.int ..< (pn.keyStart + pn.keyLength).int] == "5"
    check pn.propVal.numVal == 2.0

  test "({a: [1,2], b: {c: 3}}) — nested object/array values":
    var p = initParser("({a: [1,2], b: {c: 3}})")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let obj = prog.stmts[0].inner
    check obj.kind == NodeKind.Object
    check obj.props.len == 2
    check obj.props[0].propVal.kind == NodeKind.Array
    check obj.props[0].propVal.elems.len == 2
    check obj.props[1].propVal.kind == NodeKind.Object
    check obj.props[1].propVal.props.len == 1

  test "({k: a, ...rest}) — prop then spread":
    var p = initParser("({k: a, ...rest})")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let obj = prog.stmts[0].inner
    check obj.kind == NodeKind.Object
    check obj.props.len == 2
    check obj.props[0].kind == NodeKind.ObjectProp
    check obj.props[1].kind == NodeKind.Spread

  test "[a ? b : c] — conditional inside array":
    var p = initParser("[a ? b : c]")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.Array
    check arr.elems.len == 1
    check arr.elems[0].kind == NodeKind.Conditional

suite "parser assignment":
  test "a = b — Assignment Eq with IdentExpr target and value":
    var p = initParser("a = b")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0]
    check node.kind == NodeKind.Assignment
    check node.assignOp == TokenKind.Eq
    check node.target.kind == NodeKind.IdentExpr
    check node.value.kind == NodeKind.IdentExpr

  test "a = b = c — right-associative nested Assignment":
    var p = initParser("a = b = c")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let outer = prog.stmts[0]
    check outer.kind == NodeKind.Assignment
    check outer.assignOp == TokenKind.Eq
    check outer.target.kind == NodeKind.IdentExpr
    let inner = outer.value
    check inner.kind == NodeKind.Assignment
    check inner.assignOp == TokenKind.Eq
    check inner.target.kind == NodeKind.IdentExpr
    check inner.value.kind == NodeKind.IdentExpr

  test "a += b — Assignment PlusEq":
    var p = initParser("a += b")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0]
    check node.kind == NodeKind.Assignment
    check node.assignOp == TokenKind.PlusEq
    check node.target.kind == NodeKind.IdentExpr
    check node.value.kind == NodeKind.IdentExpr

  test "a **= 2 — Assignment StarStarEq with NumberExpr rhs":
    var p = initParser("a **= 2")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0]
    check node.kind == NodeKind.Assignment
    check node.assignOp == TokenKind.StarStarEq
    check node.target.kind == NodeKind.IdentExpr
    check node.value.kind == NodeKind.NumberExpr
    check node.value.numVal == 2.0

  test "a ||= b — Assignment PipePipeEq":
    var p = initParser("a ||= b")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0]
    check node.kind == NodeKind.Assignment
    check node.assignOp == TokenKind.PipePipeEq
    check node.target.kind == NodeKind.IdentExpr
    check node.value.kind == NodeKind.IdentExpr

  test "a ??= b — Assignment QuestionQuestionEq":
    var p = initParser("a ??= b")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0]
    check node.kind == NodeKind.Assignment
    check node.assignOp == TokenKind.QuestionQuestionEq
    check node.target.kind == NodeKind.IdentExpr
    check node.value.kind == NodeKind.IdentExpr

  test "a.b = c — Assignment Eq with Member target":
    var p = initParser("a.b = c")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0]
    check node.kind == NodeKind.Assignment
    check node.assignOp == TokenKind.Eq
    check node.target.kind == NodeKind.Member
    check node.target.recv.kind == NodeKind.IdentExpr
    check node.value.kind == NodeKind.IdentExpr

  test "a[i] = b — Assignment Eq with Computed target":
    var p = initParser("a[i] = b")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0]
    check node.kind == NodeKind.Assignment
    check node.assignOp == TokenKind.Eq
    check node.target.kind == NodeKind.Computed
    check node.target.recv.kind == NodeKind.IdentExpr
    check node.value.kind == NodeKind.IdentExpr

  test "a = b ? c : d — rhs is Conditional":
    var p = initParser("a = b ? c : d")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0]
    check node.kind == NodeKind.Assignment
    check node.assignOp == TokenKind.Eq
    check node.target.kind == NodeKind.IdentExpr
    check node.value.kind == NodeKind.Conditional

  test "a &&= b ||= c — right-assoc: AmpAmpEq outer, PipePipeEq inner":
    var p = initParser("a &&= b ||= c")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let outer = prog.stmts[0]
    check outer.kind == NodeKind.Assignment
    check outer.assignOp == TokenKind.AmpAmpEq
    check outer.target.kind == NodeKind.IdentExpr
    let inner = outer.value
    check inner.kind == NodeKind.Assignment
    check inner.assignOp == TokenKind.PipePipeEq
    check inner.target.kind == NodeKind.IdentExpr
    check inner.value.kind == NodeKind.IdentExpr

suite "ast 2c-5 nodes":
  test "template expr":
    let p0 = newLeaf(TemplatePartExpr, 1'u32, 2'u32)
    let x = newLeaf(IdentExpr, 4'u32, 5'u32)
    let p1 = newLeaf(TemplatePartExpr, 6'u32, 6'u32)
    let t = newTemplateExpr(0'u32, 7'u32, @[p0, x, p1])
    check t.kind == NodeKind.TemplateExpr
    check t.tparts.len == 3
    check t.tparts[0].kind == NodeKind.TemplatePartExpr
  test "tagged template":
    let tag = newLeaf(IdentExpr, 0'u32, 3'u32)
    let tmpl = newTemplateExpr(3'u32, 8'u32, @[newLeaf(TemplatePartExpr, 4'u32, 7'u32)])
    let tt = newTaggedTemplate(0'u32, 8'u32, tag, tmpl)
    check tt.kind == NodeKind.TaggedTemplate
    check tt.tag.kind == NodeKind.IdentExpr
    check tt.tmpl.kind == NodeKind.TemplateExpr
