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

suite "parser templates":
  test "`abc` — TemplateExpr with one TemplatePartExpr child":
    var p = initParser("`abc`")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let tmpl = prog.stmts[0]
    check tmpl.kind == NodeKind.TemplateExpr
    check tmpl.tparts.len == 1
    check tmpl.tparts[0].kind == NodeKind.TemplatePartExpr

  test "`a${x}b` — TemplateExpr with 3 children: Part, IdentExpr, Part":
    var p = initParser("`a${x}b`")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let tmpl = prog.stmts[0]
    check tmpl.kind == NodeKind.TemplateExpr
    check tmpl.tparts.len == 3
    check tmpl.tparts[0].kind == NodeKind.TemplatePartExpr
    check tmpl.tparts[1].kind == NodeKind.IdentExpr
    check tmpl.tparts[2].kind == NodeKind.TemplatePartExpr

  test "tag`${a}` — TaggedTemplate with IdentExpr tag and TemplateExpr":
    var p = initParser("tag`${a}`")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let tt = prog.stmts[0]
    check tt.kind == NodeKind.TaggedTemplate
    check tt.tag.kind == NodeKind.IdentExpr
    check tt.tmpl.kind == NodeKind.TemplateExpr
    check tt.tmpl.tparts.len == 3   # empty part, IdentExpr a, empty part

suite "ast 2d-1 nodes":
  test "BlockStmt — stmtList field":
    let s1 = newLeaf(IdentExpr, 2'u32, 3'u32)
    let s2 = newLeaf(IdentExpr, 5'u32, 6'u32)
    let b = newBlock(0'u32, 8'u32, @[s1, s2])
    check b.kind == NodeKind.BlockStmt
    check b.stmtList.len == 2
    check b.stmtList[0].kind == NodeKind.IdentExpr
    check b.stmtList[1].kind == NodeKind.IdentExpr

  test "IfStmt — with else":
    let cond = newLeaf(IdentExpr, 4'u32, 5'u32)
    let then = newLeaf(IdentExpr, 7'u32, 8'u32)
    let els  = newLeaf(IdentExpr, 15'u32, 16'u32)
    let n = newIf(0'u32, 16'u32, cond, then, els)
    check n.kind == NodeKind.IfStmt
    check n.ifCond.kind == NodeKind.IdentExpr
    check n.thenStmt.kind == NodeKind.IdentExpr
    check n.elseStmt != nil
    check n.elseStmt.kind == NodeKind.IdentExpr

  test "IfStmt — no else (elseStmt is nil)":
    let cond = newLeaf(IdentExpr, 4'u32, 5'u32)
    let then = newLeaf(IdentExpr, 7'u32, 8'u32)
    let n = newIf(0'u32, 9'u32, cond, then, nil)
    check n.kind == NodeKind.IfStmt
    check n.elseStmt == nil

  test "WhileStmt — cond + body":
    let cond = newLeaf(IdentExpr, 7'u32, 8'u32)
    let body = newLeaf(IdentExpr, 10'u32, 11'u32)
    let w = newWhile(0'u32, 12'u32, cond, body)
    check w.kind == NodeKind.WhileStmt
    check w.whileCond.kind == NodeKind.IdentExpr
    check w.whileBody.kind == NodeKind.IdentExpr

  test "DoWhileStmt — body first then cond":
    let body = newLeaf(IdentExpr, 3'u32, 4'u32)
    let cond = newLeaf(IdentExpr, 13'u32, 14'u32)
    let d = newDoWhile(0'u32, 16'u32, body, cond)
    check d.kind == NodeKind.DoWhileStmt
    check d.doBody.kind == NodeKind.IdentExpr
    check d.doCond.kind == NodeKind.IdentExpr

  test "ForStmt — all slots present":
    let init   = newLeaf(IdentExpr, 5'u32, 6'u32)
    let test0  = newLeaf(IdentExpr, 8'u32, 9'u32)
    let update = newLeaf(IdentExpr, 11'u32, 12'u32)
    let body   = newLeaf(IdentExpr, 14'u32, 15'u32)
    let f = newFor(0'u32, 16'u32, init, test0, update, body)
    check f.kind == NodeKind.ForStmt
    check f.forInit   != nil
    check f.forTest   != nil
    check f.forUpdate != nil
    check f.forBody.kind == NodeKind.IdentExpr

  test "ForStmt — nil init/test/update":
    let body = newLeaf(IdentExpr, 6'u32, 7'u32)
    let f = newFor(0'u32, 8'u32, nil, nil, nil, body)
    check f.kind == NodeKind.ForStmt
    check f.forInit   == nil
    check f.forTest   == nil
    check f.forUpdate == nil
    check f.forBody.kind == NodeKind.IdentExpr

  test "ReturnStmt — with arg":
    let arg = newLeaf(IdentExpr, 7'u32, 8'u32)
    let r = newReturn(0'u32, 9'u32, arg)
    check r.kind == NodeKind.ReturnStmt
    check r.retArg != nil
    check r.retArg.kind == NodeKind.IdentExpr

  test "ReturnStmt — bare return (nil arg)":
    let r = newReturn(0'u32, 7'u32, nil)
    check r.kind == NodeKind.ReturnStmt
    check r.retArg == nil

  test "ThrowStmt — throwArg":
    let arg = newLeaf(IdentExpr, 6'u32, 7'u32)
    let t = newThrow(0'u32, 8'u32, arg)
    check t.kind == NodeKind.ThrowStmt
    check t.throwArg.kind == NodeKind.IdentExpr

  test "LabeledStmt — label slice + body":
    let body = newLeaf(IdentExpr, 5'u32, 8'u32)
    let l = newLabeled(0'u32, 9'u32, 0'u32, 3'u32, body)
    check l.kind == NodeKind.LabeledStmt
    check l.labelStart  == 0'u32
    check l.labelLen    == 3'u32
    check l.labeled.kind == NodeKind.IdentExpr

  test "BreakStmt + ContinueStmt + EmptyStmt — via newLeaf":
    let br = newLeaf(BreakStmt,    0'u32, 5'u32)
    let co = newLeaf(ContinueStmt, 0'u32, 8'u32)
    let em = newLeaf(EmptyStmt,    0'u32, 1'u32)
    check br.kind == NodeKind.BreakStmt
    check co.kind == NodeKind.ContinueStmt
    check em.kind == NodeKind.EmptyStmt

suite "parser control-flow":
  test "block { let x = 1; } — BlockStmt with VarDecl":
    var p = initParser("{ let x = 1; }")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let blk = prog.stmts[0]
    check blk.kind == NodeKind.BlockStmt
    check blk.stmtList.len == 1
    check blk.stmtList[0].kind == NodeKind.VarDecl

  test "nested blocks {{ }} — BlockStmt containing BlockStmt":
    var p = initParser("{ { } }")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let outer = prog.stmts[0]
    check outer.kind == NodeKind.BlockStmt
    check outer.stmtList.len == 1
    check outer.stmtList[0].kind == NodeKind.BlockStmt

  test "if (a) b; — IfStmt no else":
    var p = initParser("if (a) b;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let n = prog.stmts[0]
    check n.kind == NodeKind.IfStmt
    check n.ifCond.kind == NodeKind.IdentExpr
    check n.thenStmt.kind == NodeKind.IdentExpr
    check n.elseStmt == nil

  test "if (a) b; else c; — IfStmt with else":
    var p = initParser("if (a) b; else c;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let n = prog.stmts[0]
    check n.kind == NodeKind.IfStmt
    check n.ifCond.kind == NodeKind.IdentExpr
    check n.thenStmt.kind == NodeKind.IdentExpr
    check n.elseStmt != nil
    check n.elseStmt.kind == NodeKind.IdentExpr

  test "dangling else binds inner if: if(a)if(b)c;else d;":
    var p = initParser("if(a)if(b)c;else d;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let outer = prog.stmts[0]
    check outer.kind == NodeKind.IfStmt
    check outer.elseStmt == nil
    let inner = outer.thenStmt
    check inner.kind == NodeKind.IfStmt
    check inner.elseStmt != nil
    check inner.elseStmt.kind == NodeKind.IdentExpr

  test "while (a) b; — WhileStmt":
    var p = initParser("while (a) b;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let w = prog.stmts[0]
    check w.kind == NodeKind.WhileStmt
    check w.whileCond.kind == NodeKind.IdentExpr
    check w.whileBody.kind == NodeKind.IdentExpr

  test "do x; while (a); — DoWhileStmt":
    var p = initParser("do x; while (a);")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let d = prog.stmts[0]
    check d.kind == NodeKind.DoWhileStmt
    check d.doBody.kind == NodeKind.IdentExpr
    check d.doCond.kind == NodeKind.IdentExpr

  test "for (let i = 0; i < n; i++) x; — ForStmt with VarDecl init":
    var p = initParser("for (let i = 0; i < n; i++) x;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let f = prog.stmts[0]
    check f.kind == NodeKind.ForStmt
    check f.forInit != nil
    check f.forInit.kind == NodeKind.VarDecl
    check f.forTest != nil
    check f.forTest.kind == NodeKind.Binary
    check f.forUpdate != nil
    check f.forUpdate.kind == NodeKind.Postfix
    check f.forBody.kind == NodeKind.IdentExpr

  test "for (;;) x; — ForStmt with all nil slots":
    var p = initParser("for (;;) x;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let f = prog.stmts[0]
    check f.kind == NodeKind.ForStmt
    check f.forInit == nil
    check f.forTest == nil
    check f.forUpdate == nil
    check f.forBody.kind == NodeKind.IdentExpr

  test "throw e; — ThrowStmt with IdentExpr arg":
    var p = initParser("throw e;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let t = prog.stmts[0]
    check t.kind == NodeKind.ThrowStmt
    check t.throwArg.kind == NodeKind.IdentExpr

  test "break; — BreakStmt":
    var p = initParser("break;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.BreakStmt

  test "break foo; — BreakStmt with label (label discarded in AST)":
    var p = initParser("break foo;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.BreakStmt

  test "continue; — ContinueStmt":
    var p = initParser("continue;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.ContinueStmt

  test "; — EmptyStmt":
    var p = initParser(";")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.EmptyStmt

  test "foo: bar; — LabeledStmt with IdentExpr body":
    var p = initParser("foo: bar;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let l = prog.stmts[0]
    check l.kind == NodeKind.LabeledStmt
    check l.labeled.kind == NodeKind.IdentExpr

  test "outer: while (a) break outer; — labeled while":
    var p = initParser("outer: while (a) break outer;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let l = prog.stmts[0]
    check l.kind == NodeKind.LabeledStmt
    check l.labeled.kind == NodeKind.WhileStmt

suite "ast 2d-2 nodes":
  test "ForInStmt — binding/iterable/body fields":
    let binding  = newLeaf(IdentExpr, 5'u32, 6'u32)
    let iterable = newLeaf(IdentExpr, 10'u32, 13'u32)
    let body     = newLeaf(IdentExpr, 15'u32, 16'u32)
    let n = newForInOf(NodeKind.ForInStmt, 0'u32, 17'u32, binding, iterable, body)
    check n.kind == NodeKind.ForInStmt
    check n.forBinding.kind  == NodeKind.IdentExpr
    check n.forIterable.kind == NodeKind.IdentExpr
    check n.forInOfBody.kind == NodeKind.IdentExpr

  test "ForOfStmt — correct kind via newForInOf":
    let binding  = newLeaf(VarDecl, 5'u32, 10'u32)
    let iterable = newLeaf(IdentExpr, 14'u32, 17'u32)
    let body     = newLeaf(IdentExpr, 19'u32, 20'u32)
    let n = newForInOf(NodeKind.ForOfStmt, 0'u32, 21'u32, binding, iterable, body)
    check n.kind == NodeKind.ForOfStmt
    check n.forBinding.kind  == NodeKind.VarDecl
    check n.forIterable.kind == NodeKind.IdentExpr
    check n.forInOfBody.kind == NodeKind.IdentExpr

  test "SwitchStmt — discriminant and cases":
    let disc = newLeaf(IdentExpr, 7'u32, 8'u32)
    let test1 = newNumber(14'u32, 15'u32, 1.0)
    let body1 = @[newLeaf(IdentExpr, 16'u32, 17'u32), newLeaf(BreakStmt, 18'u32, 24'u32)]
    let case1 = newSwitchCase(9'u32, 25'u32, test1, body1)
    let body2 = @[newLeaf(IdentExpr, 34'u32, 35'u32)]
    let case2 = newSwitchCase(26'u32, 36'u32, nil, body2)   # default:
    let sw = newSwitch(0'u32, 37'u32, disc, @[case1, case2])
    check sw.kind == NodeKind.SwitchStmt
    check sw.switchDisc.kind == NodeKind.IdentExpr
    check sw.cases.len == 2
    check sw.cases[0].kind == NodeKind.SwitchCase
    check sw.cases[0].caseTest != nil
    check sw.cases[0].caseTest.kind == NodeKind.NumberExpr
    check sw.cases[0].caseBody.len == 2
    check sw.cases[1].kind == NodeKind.SwitchCase
    check sw.cases[1].caseTest == nil    # default: has nil caseTest
    check sw.cases[1].caseBody.len == 1

  test "TryStmt — try+catch+finally":
    let tryB     = newBlock(0'u32, 3'u32, @[newLeaf(IdentExpr, 1'u32, 2'u32)])
    let catchB   = newBlock(12'u32, 15'u32, @[newLeaf(IdentExpr, 13'u32, 14'u32)])
    let finallyB = newBlock(24'u32, 27'u32, @[newLeaf(IdentExpr, 25'u32, 26'u32)])
    let t = newTry(0'u32, 27'u32, tryB, catchB, finallyB, 8'u32, 1'u32)
    check t.kind == NodeKind.TryStmt
    check t.tryBlock.kind     == NodeKind.BlockStmt
    check t.catchBlock != nil
    check t.catchBlock.kind   == NodeKind.BlockStmt
    check t.finallyBlock != nil
    check t.finallyBlock.kind == NodeKind.BlockStmt
    check t.catchParamStart   == 8'u32
    check t.catchParamLen     == 1'u32

  test "TryStmt — try+finally only (nil catchBlock)":
    let tryB     = newBlock(0'u32, 3'u32, @[newLeaf(IdentExpr, 1'u32, 2'u32)])
    let finallyB = newBlock(12'u32, 15'u32, @[newLeaf(IdentExpr, 13'u32, 14'u32)])
    let t = newTry(0'u32, 15'u32, tryB, nil, finallyB, 0'u32, 0'u32)
    check t.kind == NodeKind.TryStmt
    check t.tryBlock.kind     == NodeKind.BlockStmt
    check t.catchBlock        == nil
    check t.finallyBlock != nil
    check t.finallyBlock.kind == NodeKind.BlockStmt
    check t.catchParamStart   == 0'u32
    check t.catchParamLen     == 0'u32

  test "WithStmt — obj and body":
    let obj  = newLeaf(IdentExpr, 5'u32, 6'u32)
    let body = newLeaf(IdentExpr, 7'u32, 8'u32)
    let w = newWith(0'u32, 9'u32, obj, body)
    check w.kind == NodeKind.WithStmt
    check w.withObj.kind  == NodeKind.IdentExpr
    check w.withBody.kind == NodeKind.IdentExpr

suite "parser 2d-2":
  test "for (x in obj) y; — ForInStmt with IdentExpr binding":
    var p = initParser("for (x in obj) y;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let f = prog.stmts[0]
    check f.kind == NodeKind.ForInStmt
    check f.forBinding.kind == NodeKind.IdentExpr
    check f.forIterable.kind == NodeKind.IdentExpr
    check f.forInOfBody.kind == NodeKind.IdentExpr

  test "for (let k of arr) z; — ForOfStmt with VarDecl binding":
    var p = initParser("for (let k of arr) z;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let f = prog.stmts[0]
    check f.kind == NodeKind.ForOfStmt
    check f.forBinding.kind == NodeKind.VarDecl
    check f.forBinding.declarators.len == 1
    check f.forIterable.kind == NodeKind.IdentExpr
    check f.forInOfBody.kind == NodeKind.IdentExpr

  test "for (k in o) { x; } — ForInStmt with BlockStmt body":
    var p = initParser("for (k in o) { x; }")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let f = prog.stmts[0]
    check f.kind == NodeKind.ForInStmt
    check f.forInOfBody.kind == NodeKind.BlockStmt

  test "a in b — Binary KwIn (noIn NOT set outside for-init)":
    var p = initParser("a in b")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let n = prog.stmts[0]
    check n.kind == NodeKind.Binary
    check n.binOp == TokenKind.KwIn
    check n.lhs.kind == NodeKind.IdentExpr
    check n.rhs.kind == NodeKind.IdentExpr

  test "[a in b] — in is binary inside array literal":
    var p = initParser("[a in b]")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.Array
    check arr.elems.len == 1
    check arr.elems[0].kind == NodeKind.Binary
    check arr.elems[0].binOp == TokenKind.KwIn

  test "switch (x) { case 1: a; break; default: b; } — SwitchStmt":
    var p = initParser("switch (x) { case 1: a; break; default: b; }")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let sw = prog.stmts[0]
    check sw.kind == NodeKind.SwitchStmt
    check sw.switchDisc.kind == NodeKind.IdentExpr
    check sw.cases.len == 2
    check sw.cases[0].kind == NodeKind.SwitchCase
    check sw.cases[0].caseTest != nil
    check sw.cases[0].caseTest.kind == NodeKind.NumberExpr
    check sw.cases[0].caseBody.len == 2   # a; break;
    check sw.cases[1].caseTest == nil     # default:
    check sw.cases[1].caseBody.len == 1   # b;

  test "switch (x) { case 1: case 2: a; break; default: } — fall-through cases":
    var p = initParser("switch (x) { case 1: case 2: a; break; default: }")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let sw = prog.stmts[0]
    check sw.kind == NodeKind.SwitchStmt
    check sw.cases.len == 3
    check sw.cases[0].caseBody.len == 0   # fall-through: case 1 has no body
    check sw.cases[1].caseTest != nil
    check sw.cases[1].caseBody.len == 2   # a; break;
    check sw.cases[2].caseTest == nil     # default: with no body

  test "try { a; } catch (e) { b; } finally { c; } — TryStmt all three":
    var p = initParser("try { a; } catch (e) { b; } finally { c; }")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let t = prog.stmts[0]
    check t.kind == NodeKind.TryStmt
    check t.tryBlock.kind == NodeKind.BlockStmt
    check t.catchBlock != nil
    check t.catchBlock.kind == NodeKind.BlockStmt
    check t.finallyBlock != nil
    check t.finallyBlock.kind == NodeKind.BlockStmt
    check t.catchParamLen == 1'u32   # "e"

  test "try { a; } catch { b; } — optional catch param (no binding)":
    var p = initParser("try { a; } catch { b; }")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let t = prog.stmts[0]
    check t.kind == NodeKind.TryStmt
    check t.catchBlock != nil
    check t.finallyBlock == nil
    check t.catchParamLen == 0'u32   # no catch param

  test "try { a; } finally { c; } — no catch block":
    var p = initParser("try { a; } finally { c; }")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let t = prog.stmts[0]
    check t.kind == NodeKind.TryStmt
    check t.catchBlock == nil
    check t.finallyBlock != nil
    check t.finallyBlock.kind == NodeKind.BlockStmt

  test "with (o) x; — WithStmt":
    var p = initParser("with (o) x;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let w = prog.stmts[0]
    check w.kind == NodeKind.WithStmt
    check w.withObj.kind == NodeKind.IdentExpr
    check w.withBody.kind == NodeKind.IdentExpr

  test "for ((a in b); ;) x; — paren'd in-expr is not for-in":
    var p = initParser("for ((a in b); ;) x;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let f = prog.stmts[0]
    check f.kind == NodeKind.ForStmt   # C-style, not ForInStmt
    check f.forInit != nil
    check f.forInit.kind == NodeKind.Paren
    check f.forInit.inner.kind == NodeKind.Binary
    check f.forInit.inner.binOp == TokenKind.KwIn

  test "for (var i = 0; i < 3; i++) for (j in o) x; — nested for-in inside for":
    var p = initParser("for (var i = 0; i < 3; i++) for (j in o) x;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let outer = prog.stmts[0]
    check outer.kind == NodeKind.ForStmt
    check outer.forBody.kind == NodeKind.ForInStmt
    check outer.forBody.forBinding.kind == NodeKind.IdentExpr

suite "ast 2d-3a nodes":
  test "IdentExpr via newLeaf — identDefault is nil":
    let id = newLeaf(IdentExpr, 0'u32, 3'u32)
    check id.kind == NodeKind.IdentExpr
    check id.identDefault == nil

  test "IdentExpr with default — identDefault is non-nil":
    let defVal = newNumber(5'u32, 6'u32, 5.0)
    let id = AstNode(kind: IdentExpr, start: 3'u32, `end`: 4'u32, identDefault: defVal)
    check id.kind == NodeKind.IdentExpr
    check id.identDefault != nil
    check id.identDefault.kind == NodeKind.NumberExpr
    check id.identDefault.numVal == 5.0

  test "RestParam — restArg field":
    let arg = newLeaf(IdentExpr, 3'u32, 7'u32)
    let rp = newRestParam(0'u32, 7'u32, arg)
    check rp.kind == NodeKind.RestParam
    check rp.restArg != nil
    check rp.restArg.kind == NodeKind.IdentExpr

  test "FunctionDecl — named, params, body":
    let body = newBlock(10'u32, 12'u32, @[])
    let paramA = newLeaf(IdentExpr, 12'u32, 13'u32)
    let paramB = newLeaf(IdentExpr, 15'u32, 16'u32)
    let fn = newFunctionDecl(0'u32, 30'u32, 9'u32, 1'u32, body, @[paramA, paramB])
    check fn.kind == NodeKind.FunctionDecl
    check fn.fnNameStart == 9'u32
    check fn.fnNameLen   == 1'u32
    check fn.fnBody != nil
    check fn.fnBody.kind == NodeKind.BlockStmt
    check fn.fnParams.len == 2
    check fn.fnParams[0].kind == NodeKind.IdentExpr
    check fn.fnParams[1].kind == NodeKind.IdentExpr
    check fn.fnIsAsync     == false
    check fn.fnIsGenerator == false

  test "FunctionExpr — anonymous (nameLen=0), one param":
    let body = newBlock(15'u32, 17'u32, @[])
    let paramX = newLeaf(IdentExpr, 13'u32, 14'u32)
    let fn = newFunctionExpr(0'u32, 18'u32, 0'u32, 0'u32, body, @[paramX])
    check fn.kind == NodeKind.FunctionExpr
    check fn.fnNameLen  == 0'u32
    check fn.fnBody.kind == NodeKind.BlockStmt
    check fn.fnParams.len == 1
    check fn.fnParams[0].kind == NodeKind.IdentExpr

suite "parser functions":
  test "function f(a, b) { return a; } — FunctionDecl with 2 params":
    var p = initParser("function f(a, b) { return a; }")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let fn = prog.stmts[0]
    check fn.kind == NodeKind.FunctionDecl
    check p.source[fn.fnNameStart.int ..< (fn.fnNameStart + fn.fnNameLen).int] == "f"
    check fn.fnBody.kind == NodeKind.BlockStmt
    check fn.fnBody.stmtList.len == 1
    check fn.fnBody.stmtList[0].kind == NodeKind.ReturnStmt
    check fn.fnParams.len == 2
    check fn.fnParams[0].kind == NodeKind.IdentExpr
    check fn.fnParams[1].kind == NodeKind.IdentExpr

  test "function g() {} — FunctionDecl with no params, empty body":
    var p = initParser("function g() {}")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let fn = prog.stmts[0]
    check fn.kind == NodeKind.FunctionDecl
    check p.source[fn.fnNameStart.int ..< (fn.fnNameStart + fn.fnNameLen).int] == "g"
    check fn.fnParams.len == 0
    check fn.fnBody.kind == NodeKind.BlockStmt
    check fn.fnBody.stmtList.len == 0

  test "(function () { return 1; }) — anonymous FunctionExpr in paren":
    var p = initParser("(function () { return 1; })")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let paren = prog.stmts[0]
    check paren.kind == NodeKind.Paren
    let fn = paren.inner
    check fn.kind == NodeKind.FunctionExpr
    check fn.fnNameLen == 0'u32   # anonymous
    check fn.fnParams.len == 0
    check fn.fnBody.stmtList.len == 1
    check fn.fnBody.stmtList[0].kind == NodeKind.ReturnStmt

  test "(function named(x) {}) — named FunctionExpr":
    var p = initParser("(function named(x) {})")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let fn = prog.stmts[0].inner
    check fn.kind == NodeKind.FunctionExpr
    check p.source[fn.fnNameStart.int ..< (fn.fnNameStart + fn.fnNameLen).int] == "named"
    check fn.fnParams.len == 1
    check fn.fnParams[0].kind == NodeKind.IdentExpr

  test "function h(a, b = 5, ...rest) {} — default + rest params":
    var p = initParser("function h(a, b = 5, ...rest) {}")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let fn = prog.stmts[0]
    check fn.kind == NodeKind.FunctionDecl
    check fn.fnParams.len == 3
    check fn.fnParams[0].kind == NodeKind.IdentExpr
    check fn.fnParams[0].identDefault == nil
    check fn.fnParams[1].kind == NodeKind.IdentExpr
    check fn.fnParams[1].identDefault != nil
    check fn.fnParams[1].identDefault.kind == NodeKind.NumberExpr
    check fn.fnParams[1].identDefault.numVal == 5.0
    check fn.fnParams[2].kind == NodeKind.RestParam
    check fn.fnParams[2].restArg.kind == NodeKind.IdentExpr

  test "let f = function (a) { return a; }; — FunctionExpr as var init":
    var p = initParser("let f = function (a) { return a; };")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let decl = prog.stmts[0]
    check decl.kind == NodeKind.VarDecl
    check decl.declarators.len == 1
    let fn = decl.declarators[0].init
    check fn != nil
    check fn.kind == NodeKind.FunctionExpr
    check fn.fnNameLen == 0'u32   # anonymous
    check fn.fnParams.len == 1
    check fn.fnBody.stmtList.len == 1

  test "function f(){ if(a) return b; return c; } — body with multiple stmts":
    var p = initParser("function f(){ if(a) return b; return c; }")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let fn = prog.stmts[0]
    check fn.kind == NodeKind.FunctionDecl
    check fn.fnBody.stmtList.len == 2
    check fn.fnBody.stmtList[0].kind == NodeKind.IfStmt
    check fn.fnBody.stmtList[1].kind == NodeKind.ReturnStmt

  test "function f(a, b,) {} — trailing comma in params":
    var p = initParser("function f(a, b,) {}")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let fn = prog.stmts[0]
    check fn.kind == NodeKind.FunctionDecl
    check fn.fnParams.len == 2

  test "(function(){})() — IIFE Call":
    var p = initParser("(function(){})()")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let call = prog.stmts[0]
    check call.kind == NodeKind.Call
    check call.callee.kind == NodeKind.Paren
    check call.callee.inner.kind == NodeKind.FunctionExpr

  test "[function(){}] — FunctionExpr inside array":
    var p = initParser("[function(){}]")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.Array
    check arr.elems.len == 1
    check arr.elems[0].kind == NodeKind.FunctionExpr

  test "function f(x = a ? b : c) {} — conditional as default param":
    var p = initParser("function f(x = a ? b : c) {}")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let fn = prog.stmts[0]
    check fn.kind == NodeKind.FunctionDecl
    check fn.fnParams.len == 1
    check fn.fnParams[0].kind == NodeKind.IdentExpr
    check fn.fnParams[0].identDefault != nil
    check fn.fnParams[0].identDefault.kind == NodeKind.Conditional

  test "function f(...args) { return args; } — rest-only param":
    var p = initParser("function f(...args) { return args; }")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let fn = prog.stmts[0]
    check fn.kind == NodeKind.FunctionDecl
    check fn.fnParams.len == 1
    check fn.fnParams[0].kind == NodeKind.RestParam
    check fn.fnParams[0].restArg.kind == NodeKind.IdentExpr

  test "function outer() { function inner() { return 1; } return inner; } — nested decls":
    var p = initParser("function outer() { function inner() { return 1; } return inner; }")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let outer = prog.stmts[0]
    check outer.kind == NodeKind.FunctionDecl
    check outer.fnBody.stmtList.len == 2
    let inner = outer.fnBody.stmtList[0]
    check inner.kind == NodeKind.FunctionDecl
    check outer.fnBody.stmtList[1].kind == NodeKind.ReturnStmt

suite "parser gen/async":
  test "function* g(){} — FunctionDecl with fnIsGenerator=true":
    var p = initParser("function* g(){}")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let fn = prog.stmts[0]
    check fn.kind == NodeKind.FunctionDecl
    check p.source[fn.fnNameStart.int ..< (fn.fnNameStart + fn.fnNameLen).int] == "g"
    check fn.fnIsGenerator == true
    check fn.fnIsAsync == false

  test "async function f(){} — FunctionDecl with fnIsAsync=true":
    var p = initParser("async function f(){}")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let fn = prog.stmts[0]
    check fn.kind == NodeKind.FunctionDecl
    check p.source[fn.fnNameStart.int ..< (fn.fnNameStart + fn.fnNameLen).int] == "f"
    check fn.fnIsAsync == true
    check fn.fnIsGenerator == false

  test "function* g(){ yield; } — bare yield produces YieldExpr with nil arg":
    var p = initParser("function* g(){ yield; }")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let fn = prog.stmts[0]
    check fn.kind == NodeKind.FunctionDecl
    check fn.fnIsGenerator == true
    check fn.fnBody.stmtList.len == 1
    let y = fn.fnBody.stmtList[0]
    check y.kind == NodeKind.YieldExpr
    check y.yieldArg == nil
    check y.yieldDelegate == false

  test "function* g(){ yield 1; } — yield with NumberExpr arg":
    var p = initParser("function* g(){ yield 1; }")
    let prog = p.parseProgram()
    let fn = prog.stmts[0]
    check fn.fnBody.stmtList.len == 1
    let y = fn.fnBody.stmtList[0]
    check y.kind == NodeKind.YieldExpr
    check y.yieldArg != nil
    check y.yieldArg.kind == NodeKind.NumberExpr
    check y.yieldArg.numVal == 1.0
    check y.yieldDelegate == false

  test "function* g(){ yield* x; } — yield delegate with IdentExpr arg":
    var p = initParser("function* g(){ yield* x; }")
    let prog = p.parseProgram()
    let fn = prog.stmts[0]
    let y = fn.fnBody.stmtList[0]
    check y.kind == NodeKind.YieldExpr
    check y.yieldDelegate == true
    check y.yieldArg != nil
    check y.yieldArg.kind == NodeKind.IdentExpr

  test "function* g(){ let a = yield b; } — yield as rhs of declarator":
    var p = initParser("function* g(){ let a = yield b; }")
    let prog = p.parseProgram()
    let fn = prog.stmts[0]
    check fn.fnBody.stmtList.len == 1
    let decl = fn.fnBody.stmtList[0]
    check decl.kind == NodeKind.VarDecl
    let d = decl.declarators[0]
    check d.init != nil
    check d.init.kind == NodeKind.YieldExpr
    check d.init.yieldArg.kind == NodeKind.IdentExpr

  test "async function f(){ await x; } — AwaitExpr with IdentExpr arg":
    var p = initParser("async function f(){ await x; }")
    let prog = p.parseProgram()
    let fn = prog.stmts[0]
    check fn.fnIsAsync == true
    check fn.fnBody.stmtList.len == 1
    let aw = fn.fnBody.stmtList[0]
    check aw.kind == NodeKind.AwaitExpr
    check aw.awaitArg != nil
    check aw.awaitArg.kind == NodeKind.IdentExpr

  test "async function f(){ return await g(); } — await wraps a call":
    var p = initParser("async function f(){ return await g(); }")
    let prog = p.parseProgram()
    let fn = prog.stmts[0]
    check fn.fnBody.stmtList.len == 1
    let ret = fn.fnBody.stmtList[0]
    check ret.kind == NodeKind.ReturnStmt
    check ret.retArg != nil
    check ret.retArg.kind == NodeKind.AwaitExpr
    check ret.retArg.awaitArg.kind == NodeKind.Call

  test "async function f(){ let x = await a + await b; } — two awaits in binary":
    var p = initParser("async function f(){ let x = await a + await b; }")
    let prog = p.parseProgram()
    let fn = prog.stmts[0]
    let decl = fn.fnBody.stmtList[0]
    check decl.kind == NodeKind.VarDecl
    let d = decl.declarators[0]
    check d.init != nil
    check d.init.kind == NodeKind.Binary
    check d.init.lhs.kind == NodeKind.AwaitExpr
    check d.init.rhs.kind == NodeKind.AwaitExpr

  test "yield outside generator is IdentExpr":
    var p = initParser("yield")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.IdentExpr

  test "await outside async is IdentExpr":
    var p = initParser("await")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.IdentExpr

  test "var yield = 1 — yield as var name outside generator":
    var p = initParser("var yield = 1;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let decl = prog.stmts[0]
    check decl.kind == NodeKind.VarDecl
    check decl.declarators.len == 1

  test "nested: non-gen inside gen — yield NOT a keyword in inner fn":
    var p = initParser("function* g(){ function h(){ return 1; } yield h(); }")
    let prog = p.parseProgram()
    let fn = prog.stmts[0]
    check fn.fnIsGenerator == true
    check fn.fnBody.stmtList.len == 2
    let innerFn = fn.fnBody.stmtList[0]
    check innerFn.kind == NodeKind.FunctionDecl
    check innerFn.fnIsGenerator == false
    # The outer yield is still a YieldExpr
    let y = fn.fnBody.stmtList[1]
    check y.kind == NodeKind.YieldExpr

  test "let af = async function(){ await x; } — async FunctionExpr":
    var p = initParser("let af = async function(){ await x; };")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let decl = prog.stmts[0]
    check decl.kind == NodeKind.VarDecl
    let fn = decl.declarators[0].init
    check fn != nil
    check fn.kind == NodeKind.FunctionExpr
    check fn.fnIsAsync == true
    check fn.fnBody.stmtList.len == 1
    check fn.fnBody.stmtList[0].kind == NodeKind.AwaitExpr

  test "let gf = function*(){ yield 1; } — generator FunctionExpr":
    var p = initParser("let gf = function*(){ yield 1; };")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let decl = prog.stmts[0]
    let fn = decl.declarators[0].init
    check fn != nil
    check fn.kind == NodeKind.FunctionExpr
    check fn.fnIsGenerator == true
    let y = fn.fnBody.stmtList[0]
    check y.kind == NodeKind.YieldExpr
    check y.yieldArg.kind == NodeKind.NumberExpr

  test "async is IdentExpr outside async context":
    var p = initParser("async")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.IdentExpr

  test "let async = 1 — async as var name":
    var p = initParser("let async = 1;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let decl = prog.stmts[0]
    check decl.kind == NodeKind.VarDecl

suite "parser obj methods":
  test "({ m() {} }) — simple method: ObjectProp with FunctionExpr (anonymous)":
    var p = initParser("({ m() {} })")
    let prog = p.parseProgram()
    let obj = prog.stmts[0].inner
    check obj.kind == NodeKind.Object
    check obj.props.len == 1
    let prop = obj.props[0]
    check prop.kind == NodeKind.ObjectProp
    check p.source[prop.keyStart.int ..< (prop.keyStart + prop.keyLength).int] == "m"
    check prop.computedKey == nil
    let fn = prop.propVal
    check fn != nil
    check fn.kind == NodeKind.FunctionExpr
    check fn.fnNameLen == 0'u32     # anonymous
    check fn.fnIsGenerator == false
    check fn.fnIsAsync == false
    check fn.fnBody.kind == NodeKind.BlockStmt

  test "({ m(a, b) { return a; } }) — method with params and return":
    var p = initParser("({ m(a, b) { return a; } })")
    let prog = p.parseProgram()
    let obj = prog.stmts[0].inner
    check obj.props.len == 1
    let fn = obj.props[0].propVal
    check fn.kind == NodeKind.FunctionExpr
    check fn.fnNameLen == 0'u32
    check fn.fnParams.len == 2
    check fn.fnBody.stmtList.len == 1
    check fn.fnBody.stmtList[0].kind == NodeKind.ReturnStmt

  test "({ get x() { return 1; } }) — getter: FunctionExpr named 'x'":
    var p = initParser("({ get x() { return 1; } })")
    let prog = p.parseProgram()
    let obj = prog.stmts[0].inner
    check obj.props.len == 1
    let prop = obj.props[0]
    check p.source[prop.keyStart.int ..< (prop.keyStart + prop.keyLength).int] == "x"
    check prop.computedKey == nil
    let fn = prop.propVal
    check fn.kind == NodeKind.FunctionExpr
    # getter FunctionExpr is NAMED with the property name
    check fn.fnNameLen == 1'u32
    check p.source[fn.fnNameStart.int ..< (fn.fnNameStart + fn.fnNameLen).int] == "x"
    check fn.fnParams.len == 0

  test "({ set x(v) {} }) — setter: FunctionExpr named 'x' with one param":
    var p = initParser("({ set x(v) {} })")
    let prog = p.parseProgram()
    let obj = prog.stmts[0].inner
    check obj.props.len == 1
    let prop = obj.props[0]
    check p.source[prop.keyStart.int ..< (prop.keyStart + prop.keyLength).int] == "x"
    let fn = prop.propVal
    check fn.kind == NodeKind.FunctionExpr
    check fn.fnNameLen == 1'u32
    check p.source[fn.fnNameStart.int ..< (fn.fnNameStart + fn.fnNameLen).int] == "x"
    check fn.fnParams.len == 1

  test "({ *gen() { yield 1; } }) — generator method: anonymous FunctionExpr isGenerator":
    var p = initParser("({ *gen() { yield 1; } })")
    let prog = p.parseProgram()
    let obj = prog.stmts[0].inner
    check obj.props.len == 1
    let prop = obj.props[0]
    check p.source[prop.keyStart.int ..< (prop.keyStart + prop.keyLength).int] == "gen"
    let fn = prop.propVal
    check fn.kind == NodeKind.FunctionExpr
    check fn.fnNameLen == 0'u32     # anonymous
    check fn.fnIsGenerator == true
    let y = fn.fnBody.stmtList[0]
    check y.kind == NodeKind.YieldExpr
    check y.yieldArg.kind == NodeKind.NumberExpr

  test "({ async af() { await x; } }) — async method: anonymous FunctionExpr isAsync":
    var p = initParser("({ async af() { await x; } })")
    let prog = p.parseProgram()
    let obj = prog.stmts[0].inner
    check obj.props.len == 1
    let prop = obj.props[0]
    check p.source[prop.keyStart.int ..< (prop.keyStart + prop.keyLength).int] == "af"
    let fn = prop.propVal
    check fn.kind == NodeKind.FunctionExpr
    check fn.fnNameLen == 0'u32
    check fn.fnIsAsync == true
    let aw = fn.fnBody.stmtList[0]
    check aw.kind == NodeKind.AwaitExpr

  test "({ [k]() {} }) — computed method: keyStart/Length=0, computedKey present":
    var p = initParser("({ [k]() {} })")
    let prog = p.parseProgram()
    let obj = prog.stmts[0].inner
    check obj.props.len == 1
    let prop = obj.props[0]
    check prop.keyStart == 0'u32
    check prop.keyLength == 0'u32
    check prop.computedKey != nil
    check prop.computedKey.kind == NodeKind.IdentExpr
    let fn = prop.propVal
    check fn.kind == NodeKind.FunctionExpr
    check fn.fnNameLen == 0'u32

  test "({ \"str\"() {}, 5() {} }) — string and number key methods":
    var p = initParser("({ \"str\"() {}, 5() {} })")
    let prog = p.parseProgram()
    let obj = prog.stmts[0].inner
    check obj.props.len == 2
    let p0 = obj.props[0]
    check p.source[p0.keyStart.int ..< (p0.keyStart + p0.keyLength).int] == "\"str\""
    check p0.propVal.kind == NodeKind.FunctionExpr
    let p1 = obj.props[1]
    check p.source[p1.keyStart.int ..< (p1.keyStart + p1.keyLength).int] == "5"
    check p1.propVal.kind == NodeKind.FunctionExpr

  test "({ a, m() {}, b: 2 }) — mixed shorthand + method + data prop":
    var p = initParser("({ a, m() {}, b: 2 })")
    let prog = p.parseProgram()
    let obj = prog.stmts[0].inner
    check obj.props.len == 3
    check obj.props[0].propVal.kind == NodeKind.IdentExpr    # shorthand
    check obj.props[1].propVal.kind == NodeKind.FunctionExpr # method
    check obj.props[2].propVal.kind == NodeKind.NumberExpr   # data

  test "({ get [k]() {} }) — computed getter accessor":
    var p = initParser("({ get [k]() {} })")
    let prog = p.parseProgram()
    let obj = prog.stmts[0].inner
    check obj.props.len == 1
    let prop = obj.props[0]
    # computed accessor: keyStart/Length point to 'get', computedKey = IdentExpr k
    check prop.computedKey != nil
    check prop.computedKey.kind == NodeKind.IdentExpr
    let fn = prop.propVal
    check fn.kind == NodeKind.FunctionExpr
    # computed accessor FunctionExpr is anonymous (realNameLen = 0)
    check fn.fnNameLen == 0'u32

  test "({ m() {}, get x() {}, set x(v) {} }) — method + getter + setter":
    var p = initParser("({ m() {}, get x() {}, set x(v) {} })")
    let prog = p.parseProgram()
    let obj = prog.stmts[0].inner
    check obj.props.len == 3
    check obj.props[0].propVal.kind == NodeKind.FunctionExpr
    check obj.props[0].propVal.fnNameLen == 0'u32   # method anonymous
    check obj.props[1].propVal.kind == NodeKind.FunctionExpr
    check obj.props[1].propVal.fnNameLen == 1'u32   # getter named "x"
    check obj.props[2].propVal.kind == NodeKind.FunctionExpr
    check obj.props[2].propVal.fnNameLen == 1'u32   # setter named "x"

  test "({ async *ag() { yield await x; } }) — async generator method":
    var p = initParser("({ async *ag() { yield await x; } })")
    let prog = p.parseProgram()
    let obj = prog.stmts[0].inner
    check obj.props.len == 1
    let fn = obj.props[0].propVal
    check fn.kind == NodeKind.FunctionExpr
    check fn.fnIsAsync == true
    check fn.fnIsGenerator == true
    check fn.fnNameLen == 0'u32

suite "parser arrows":
  test "x => x + 1 — single-ident ArrowFunc, expr body":
    var p = initParser("x => x + 1")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.ArrowFunc
    check arr.arrowIsAsync == false
    check arr.arrowParams.len == 1
    check arr.arrowParams[0].kind == NodeKind.IdentExpr
    check arr.arrowBody != nil
    check arr.arrowBody.kind == NodeKind.Binary
    check arr.arrowBody.binOp == TokenKind.Plus

  test "(a, b) => a — paren params, expr body":
    var p = initParser("(a, b) => a")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.ArrowFunc
    check arr.arrowParams.len == 2
    check arr.arrowParams[0].kind == NodeKind.IdentExpr
    check arr.arrowParams[1].kind == NodeKind.IdentExpr
    check arr.arrowBody != nil
    check arr.arrowBody.kind == NodeKind.IdentExpr

  test "() => {} — zero params, block body":
    var p = initParser("() => {}")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.ArrowFunc
    check arr.arrowParams.len == 0
    check arr.arrowBody != nil
    check arr.arrowBody.kind == NodeKind.BlockStmt

  test "(a) => { return a; } — single paren param, block body":
    var p = initParser("(a) => { return a; }")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.ArrowFunc
    check arr.arrowParams.len == 1
    check arr.arrowBody.kind == NodeKind.BlockStmt
    check arr.arrowBody.stmtList.len == 1
    check arr.arrowBody.stmtList[0].kind == NodeKind.ReturnStmt

  test "async x => x — async single-ident arrow":
    var p = initParser("async x => x")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.ArrowFunc
    check arr.arrowIsAsync == true
    check arr.arrowParams.len == 1
    check arr.arrowParams[0].kind == NodeKind.IdentExpr
    check arr.arrowBody.kind == NodeKind.IdentExpr

  test "a => b => c — right-assoc curried arrow":
    var p = initParser("a => b => c")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let outer = prog.stmts[0]
    check outer.kind == NodeKind.ArrowFunc
    check outer.arrowParams.len == 1
    check outer.arrowBody.kind == NodeKind.ArrowFunc
    let inner = outer.arrowBody
    check inner.arrowParams.len == 1
    check inner.arrowBody.kind == NodeKind.IdentExpr

  test "(a = 1) => a — default param in paren arrow":
    var p = initParser("(a = 1) => a")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.ArrowFunc
    check arr.arrowParams.len == 1
    check arr.arrowParams[0].kind == NodeKind.IdentExpr
    check arr.arrowParams[0].identDefault != nil
    check arr.arrowParams[0].identDefault.kind == NodeKind.NumberExpr

  test "(...r) => r — rest param arrow":
    var p = initParser("(...r) => r")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.ArrowFunc
    check arr.arrowParams.len == 1
    check arr.arrowParams[0].kind == NodeKind.RestParam
    check arr.arrowParams[0].restArg.kind == NodeKind.IdentExpr
    check arr.arrowBody.kind == NodeKind.IdentExpr

  test "f(x => x) — arrow as call argument":
    var p = initParser("f(x => x)")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let call = prog.stmts[0]
    check call.kind == NodeKind.Call
    check call.args.len == 1
    check call.args[0].kind == NodeKind.ArrowFunc

  test "[a => a, b => b] — arrows inside array":
    var p = initParser("[a => a, b => b]")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.Array
    check arr.elems.len == 2
    check arr.elems[0].kind == NodeKind.ArrowFunc
    check arr.elems[1].kind == NodeKind.ArrowFunc

  test "async () => await x — async paren arrow with await body":
    var p = initParser("async () => await x")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.ArrowFunc
    check arr.arrowIsAsync == true
    check arr.arrowParams.len == 0
    check arr.arrowBody.kind == NodeKind.AwaitExpr

  test "(a, b, c) => a + b + c — three params":
    var p = initParser("(a, b, c) => a + b + c")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arr = prog.stmts[0]
    check arr.kind == NodeKind.ArrowFunc
    check arr.arrowParams.len == 3
    check arr.arrowBody.kind == NodeKind.Binary

  test "arr.map(x => x * 2) — arrow in method call":
    var p = initParser("arr.map(x => x * 2)")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let call = prog.stmts[0]
    check call.kind == NodeKind.Call
    check call.args.len == 1
    check call.args[0].kind == NodeKind.ArrowFunc
    check call.args[0].arrowParams.len == 1

  # Non-arrow regression tests
  test "(a, b) is Paren/Sequence — NOT an arrow (no =>)":
    var p = initParser("(a, b)")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.Paren

  test "async is IdentExpr when not followed by arrow head":
    var p = initParser("async")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.IdentExpr

  test "async(x) is a Call — NOT an arrow":
    var p = initParser("async(x)")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.Call

  test "a ? b : c is Conditional — NOT affected by arrow detection":
    var p = initParser("a ? b : c")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.Conditional

suite "ast 2d-5b nodes":
  test "ArrayPattern — two PatternEntry children":
    let a = newLeaf(IdentExpr, 1'u32, 2'u32)
    let b = newLeaf(IdentExpr, 4'u32, 5'u32)
    let ea = newPatternEntry(1'u32, 2'u32, 0'u32, 0'u32, a, nil, nil, false)
    let eb = newPatternEntry(4'u32, 5'u32, 0'u32, 0'u32, b, nil, nil, false)
    let arr = newPattern(NodeKind.ArrayPattern, 0'u32, 6'u32, @[ea, eb])
    check arr.kind == NodeKind.ArrayPattern
    check arr.patEntries.len == 2
    check arr.patEntries[0].kind == NodeKind.PatternEntry
    check arr.patEntries[1].kind == NodeKind.PatternEntry
    check arr.patEntries[0].patTarget.kind == NodeKind.IdentExpr
    check arr.patEntries[1].patTarget.kind == NodeKind.IdentExpr

  test "ObjectPattern — two PatternEntry children":
    let a = newLeaf(IdentExpr, 1'u32, 2'u32)
    let c = newLeaf(IdentExpr, 9'u32, 10'u32)
    let ea = newPatternEntry(1'u32, 2'u32, 1'u32, 1'u32, a, nil, nil, false)
    let eb = newPatternEntry(9'u32, 10'u32, 6'u32, 1'u32, c, nil, nil, false)
    let obj = newPattern(NodeKind.ObjectPattern, 0'u32, 11'u32, @[ea, eb])
    check obj.kind == NodeKind.ObjectPattern
    check obj.patEntries.len == 2
    check obj.patEntries[0].patKeyStart == 1'u32
    check obj.patEntries[0].patKeyLen   == 1'u32
    check obj.patEntries[1].patKeyStart == 6'u32
    check obj.patEntries[1].patKeyLen   == 1'u32

  test "PatternEntry with default value":
    let target = newLeaf(IdentExpr, 1'u32, 2'u32)
    let dflt   = newNumber(5'u32, 6'u32, 1.0)
    let e = newPatternEntry(1'u32, 6'u32, 0'u32, 0'u32, target, dflt, nil, false)
    check e.kind == NodeKind.PatternEntry
    check e.patTarget.kind  == NodeKind.IdentExpr
    check e.patDefault.kind == NodeKind.NumberExpr
    check e.patDefault.numVal == 1.0
    check e.patComputedKey == nil
    check e.patIsRest == false

  test "PatternEntry with isRest = true":
    let target = newLeaf(IdentExpr, 3'u32, 4'u32)
    let e = newPatternEntry(0'u32, 4'u32, 0'u32, 0'u32, target, nil, nil, true)
    check e.patIsRest == true
    check e.patTarget.kind == NodeKind.IdentExpr
    check e.patDefault == nil

  test "PatternEntry with computedKey":
    let target     = newLeaf(IdentExpr, 6'u32, 7'u32)
    let computed   = newLeaf(IdentExpr, 1'u32, 2'u32)
    let e = newPatternEntry(0'u32, 7'u32, 0'u32, 0'u32, target, nil, computed, false)
    check e.patComputedKey != nil
    check e.patComputedKey.kind == NodeKind.IdentExpr

  test "PatternEntry elision — nil target":
    let e = newPatternEntry(2'u32, 3'u32, 0'u32, 0'u32, nil, nil, nil, false)
    check e.kind == NodeKind.PatternEntry
    check e.patTarget == nil

suite "parser destructuring":
  test "[a, b] = c — ArrayPattern assignment":
    var p = initParser("[a, b] = c")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0]
    check node.kind == NodeKind.Assignment
    check node.assignOp == TokenKind.Eq
    check node.target.kind == NodeKind.ArrayPattern
    check node.target.patEntries.len == 2
    check node.target.patEntries[0].patTarget.kind == NodeKind.IdentExpr
    check node.target.patEntries[1].patTarget.kind == NodeKind.IdentExpr
    check node.value.kind == NodeKind.IdentExpr

  test "({x, y} = o) — ObjectPattern assignment in paren":
    var p = initParser("({x, y} = o)")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let paren = prog.stmts[0]
    check paren.kind == NodeKind.Paren
    let node = paren.inner
    check node.kind == NodeKind.Assignment
    check node.target.kind == NodeKind.ObjectPattern
    check node.target.patEntries.len == 2
    check node.target.patEntries[0].patTarget.kind == NodeKind.IdentExpr
    check node.target.patEntries[1].patTarget.kind == NodeKind.IdentExpr
    check node.value.kind == NodeKind.IdentExpr

  test "[a, ...r] = x — rest element in ArrayPattern":
    var p = initParser("[a, ...r] = x")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0]
    check node.kind == NodeKind.Assignment
    check node.target.kind == NodeKind.ArrayPattern
    check node.target.patEntries.len == 2
    check node.target.patEntries[0].patIsRest == false
    check node.target.patEntries[0].patTarget.kind == NodeKind.IdentExpr
    check node.target.patEntries[1].patIsRest == true
    check node.target.patEntries[1].patTarget.kind == NodeKind.IdentExpr

  test "({a = 1, b: c} = o) — default and rename in ObjectPattern":
    var p = initParser("({a = 1, b: c} = o)")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let paren = prog.stmts[0]
    check paren.kind == NodeKind.Paren
    let node = paren.inner
    check node.kind == NodeKind.Assignment
    check node.target.kind == NodeKind.ObjectPattern
    check node.target.patEntries.len == 2
    # a = 1: shorthand with default
    let ea = node.target.patEntries[0]
    check ea.patTarget.kind == NodeKind.IdentExpr
    check ea.patDefault != nil
    check ea.patDefault.kind == NodeKind.NumberExpr
    check ea.patDefault.numVal == 1.0
    # b: c: rename (target = c, no default)
    let eb = node.target.patEntries[1]
    check eb.patTarget.kind == NodeKind.IdentExpr
    check eb.patDefault == nil

  test "[a, [b, c]] = x — nested ArrayPattern":
    var p = initParser("[a, [b, c]] = x")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0]
    check node.kind == NodeKind.Assignment
    check node.target.kind == NodeKind.ArrayPattern
    check node.target.patEntries.len == 2
    check node.target.patEntries[0].patTarget.kind == NodeKind.IdentExpr
    let nested = node.target.patEntries[1].patTarget
    check nested.kind == NodeKind.ArrayPattern
    check nested.patEntries.len == 2

  test "[,a] = x — elision in ArrayPattern":
    var p = initParser("[,a] = x")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0]
    check node.kind == NodeKind.Assignment
    check node.target.kind == NodeKind.ArrayPattern
    check node.target.patEntries.len == 2
    check node.target.patEntries[0].patTarget == nil   # elision
    check node.target.patEntries[1].patTarget.kind == NodeKind.IdentExpr

  test "[a = 1, b = 2] = c — defaults in ArrayPattern":
    var p = initParser("[a = 1, b = 2] = c")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0]
    check node.kind == NodeKind.Assignment
    check node.target.kind == NodeKind.ArrayPattern
    check node.target.patEntries.len == 2
    check node.target.patEntries[0].patDefault != nil
    check node.target.patEntries[0].patDefault.kind == NodeKind.NumberExpr
    check node.target.patEntries[1].patDefault != nil

  test "({...r} = o) — rest in ObjectPattern":
    var p = initParser("({...r} = o)")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0].inner
    check node.kind == NodeKind.Assignment
    check node.target.kind == NodeKind.ObjectPattern
    check node.target.patEntries.len == 1
    check node.target.patEntries[0].patIsRest == true
    check node.target.patEntries[0].patTarget.kind == NodeKind.IdentExpr

  # No-regression: standalone array/object literals stay Array/Object
  test "[1, 2, 3] alone — stays Array (not ArrayPattern)":
    var p = initParser("[1, 2, 3]")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.Array

  test "({a: 1}) alone — stays Object (not ObjectPattern)":
    var p = initParser("({a: 1})")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let paren = prog.stmts[0]
    check paren.kind == NodeKind.Paren
    check paren.inner.kind == NodeKind.Object

  test "[a, b] alone — stays Array":
    var p = initParser("[a, b]")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    check prog.stmts[0].kind == NodeKind.Array

  test "a += b — compound op does NOT reinterpret":
    var p = initParser("a += b")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let node = prog.stmts[0]
    check node.kind == NodeKind.Assignment
    check node.assignOp == TokenKind.PlusEq
    check node.target.kind == NodeKind.IdentExpr

suite "ast 2d-5c fields":
  test "Declarator.declPattern defaults to nil":
    let d = newDeclarator(0'u32, 1'u32, 0'u32, 1'u32, nil)
    check d.kind == NodeKind.Declarator
    check d.declPattern == nil

  test "Declarator.declPattern can be set and read back":
    let d = newDeclarator(0'u32, 1'u32, 0'u32, 1'u32, nil)
    let pat = newPattern(NodeKind.ArrayPattern, 0'u32, 5'u32, @[])
    d.declPattern = pat
    check d.declPattern != nil
    check d.declPattern.kind == NodeKind.ArrayPattern

  test "IdentExpr.identPattern defaults to nil":
    let id = newLeaf(IdentExpr, 0'u32, 3'u32)
    check id.kind == NodeKind.IdentExpr
    check id.identPattern == nil

  test "IdentExpr.identPattern can be set and read back":
    let id = newLeaf(IdentExpr, 0'u32, 3'u32)
    let pat = newPattern(NodeKind.ArrayPattern, 0'u32, 5'u32, @[])
    id.identPattern = pat
    check id.identPattern != nil
    check id.identPattern.kind == NodeKind.ArrayPattern

  test "TryStmt.catchPattern defaults to nil":
    let tryB = newBlock(0'u32, 3'u32, @[])
    let t = newTry(0'u32, 10'u32, tryB, nil, nil, 0'u32, 0'u32)
    check t.kind == NodeKind.TryStmt
    check t.catchPattern == nil

  test "TryStmt.catchPattern can be set and read back":
    let tryB = newBlock(0'u32, 3'u32, @[])
    let t = newTry(0'u32, 10'u32, tryB, nil, nil, 0'u32, 0'u32)
    let pat = newPattern(NodeKind.ArrayPattern, 0'u32, 5'u32, @[])
    t.catchPattern = pat
    check t.catchPattern != nil
    check t.catchPattern.kind == NodeKind.ArrayPattern

  test "existing newDeclarator init field still works after field addition":
    let initNode = newNumber(5'u32, 6'u32, 42.0)
    let d = newDeclarator(0'u32, 6'u32, 0'u32, 1'u32, initNode)
    check d.init != nil
    check d.init.numVal == 42.0
    check d.declPattern == nil

  test "existing identDefault unaffected after identPattern field addition":
    let defVal = newNumber(5'u32, 6'u32, 7.0)
    let id = AstNode(kind: IdentExpr, start: 0'u32, `end`: 1'u32, identDefault: defVal)
    check id.identDefault != nil
    check id.identDefault.numVal == 7.0
    check id.identPattern == nil

  test "existing TryStmt tryBlock/catchBlock still work after catchPattern addition":
    let tryB   = newBlock(0'u32, 3'u32, @[newLeaf(IdentExpr, 1'u32, 2'u32)])
    let catchB = newBlock(12'u32, 15'u32, @[newLeaf(IdentExpr, 13'u32, 14'u32)])
    let t = newTry(0'u32, 15'u32, tryB, catchB, nil, 8'u32, 1'u32)
    check t.tryBlock.kind == NodeKind.BlockStmt
    check t.catchBlock != nil
    check t.catchPattern == nil

suite "parser binding patterns":
  test "let [a, b] = x; — ArrayPattern binding in VarDecl":
    var p = initParser("let [a, b] = x;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let decl = prog.stmts[0]
    check decl.kind == NodeKind.VarDecl
    check decl.declarators.len == 1
    let d = decl.declarators[0]
    check d.kind == NodeKind.Declarator
    check d.nameLength == 0'u32              # pattern declarator has no plain name
    check d.declPattern != nil
    check d.declPattern.kind == NodeKind.ArrayPattern
    check d.declPattern.patEntries.len == 2
    check d.declPattern.patEntries[0].patTarget.kind == NodeKind.IdentExpr
    check d.declPattern.patEntries[1].patTarget.kind == NodeKind.IdentExpr
    check d.init != nil
    check d.init.kind == NodeKind.IdentExpr

  test "let {a, b} = o; — ObjectPattern shorthand binding":
    var p = initParser("let {a, b} = o;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let decl = prog.stmts[0]
    check decl.declarators.len == 1
    let d = decl.declarators[0]
    check d.declPattern != nil
    check d.declPattern.kind == NodeKind.ObjectPattern
    check d.declPattern.patEntries.len == 2
    check d.init != nil

  test "let {a: x, b = 2} = o; — rename and default in ObjectPattern":
    var p = initParser("let {a: x, b = 2} = o;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let d = prog.stmts[0].declarators[0]
    check d.declPattern.kind == NodeKind.ObjectPattern
    let entries = d.declPattern.patEntries
    check entries.len == 2
    # first entry: key=a, target=x (rename)
    check entries[0].patTarget.kind == NodeKind.IdentExpr
    check entries[0].patDefault == nil
    # second entry: key=b, target=b (shorthand), default=2
    check entries[1].patTarget.kind == NodeKind.IdentExpr
    check entries[1].patDefault != nil
    check entries[1].patDefault.kind == NodeKind.NumberExpr

  test "const [a, ...r] = x; — rest in ArrayPattern binding":
    var p = initParser("const [a, ...r] = x;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let d = prog.stmts[0].declarators[0]
    check d.declPattern.kind == NodeKind.ArrayPattern
    let entries = d.declPattern.patEntries
    check entries.len == 2
    check not entries[0].patIsRest
    check entries[1].patIsRest

  test "function f([a, b]) {} — array pattern param":
    var p = initParser("function f([a, b]) {}")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let fn = prog.stmts[0]
    check fn.kind == NodeKind.FunctionDecl
    check fn.fnParams.len == 1
    let param = fn.fnParams[0]
    check param.kind == NodeKind.IdentExpr
    check param.identPattern != nil
    check param.identPattern.kind == NodeKind.ArrayPattern
    check param.identPattern.patEntries.len == 2

  test "function f({x, y}) {} — object pattern param":
    var p = initParser("function f({x, y}) {}")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let fn = prog.stmts[0]
    check fn.fnParams.len == 1
    let param = fn.fnParams[0]
    check param.identPattern != nil
    check param.identPattern.kind == NodeKind.ObjectPattern
    check param.identPattern.patEntries.len == 2

  test "({a}) => a — object pattern arrow param":
    var p = initParser("({a}) => a")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arrow = prog.stmts[0]
    check arrow.kind == NodeKind.ArrowFunc
    check arrow.arrowParams.len == 1
    let param = arrow.arrowParams[0]
    check param.identPattern != nil
    check param.identPattern.kind == NodeKind.ObjectPattern

  test "([a, b]) => a — array pattern arrow param":
    var p = initParser("([a, b]) => a")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let arrow = prog.stmts[0]
    check arrow.kind == NodeKind.ArrowFunc
    check arrow.arrowParams.len == 1
    check arrow.arrowParams[0].identPattern.kind == NodeKind.ArrayPattern

  test "try { x } catch ([e]) { y } — array pattern catch param":
    var p = initParser("try { x } catch ([e]) { y }")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let t = prog.stmts[0]
    check t.kind == NodeKind.TryStmt
    check t.catchParamLen == 0'u32          # no plain identifier param
    check t.catchPattern != nil
    check t.catchPattern.kind == NodeKind.ArrayPattern
    check t.catchPattern.patEntries.len == 1

  test "let [a, [b, c]] = x; — nested array pattern":
    var p = initParser("let [a, [b, c]] = x;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let d = prog.stmts[0].declarators[0]
    check d.declPattern.kind == NodeKind.ArrayPattern
    let entries = d.declPattern.patEntries
    check entries.len == 2
    check entries[0].patTarget.kind == NodeKind.IdentExpr
    check entries[1].patTarget.kind == NodeKind.ArrayPattern
    check entries[1].patTarget.patEntries.len == 2

  test "let [, , c] = x; — elisions in array pattern binding":
    var p = initParser("let [, , c] = x;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let d = prog.stmts[0].declarators[0]
    check d.declPattern.kind == NodeKind.ArrayPattern
    let entries = d.declPattern.patEntries
    check entries.len == 3
    check entries[0].patTarget == nil       # elision
    check entries[1].patTarget == nil       # elision
    check entries[2].patTarget != nil

  test "function f(a, [b], {c}) {} — mixed plain and pattern params":
    var p = initParser("function f(a, [b], {c}) {}")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let fn = prog.stmts[0]
    check fn.fnParams.len == 3
    check fn.fnParams[0].identPattern == nil    # plain ident
    check fn.fnParams[1].identPattern != nil
    check fn.fnParams[1].identPattern.kind == NodeKind.ArrayPattern
    check fn.fnParams[2].identPattern != nil
    check fn.fnParams[2].identPattern.kind == NodeKind.ObjectPattern

  test "let {a, ...rest} = o; — rest in ObjectPattern binding":
    var p = initParser("let {a, ...rest} = o;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let d = prog.stmts[0].declarators[0]
    check d.declPattern.kind == NodeKind.ObjectPattern
    let entries = d.declPattern.patEntries
    check entries.len == 2
    check not entries[0].patIsRest
    check entries[1].patIsRest
    check entries[1].patTarget.kind == NodeKind.IdentExpr

  test "identifier bindings unaffected: let x = 1, y = 2":
    var p = initParser("let x = 1, y = 2;")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let decl = prog.stmts[0]
    check decl.declarators.len == 2
    let d0 = decl.declarators[0]
    check d0.nameLength > 0'u32
    check d0.declPattern == nil
    let d1 = decl.declarators[1]
    check d1.nameLength > 0'u32
    check d1.declPattern == nil

  test "catch (e) {}: identifier catch param unaffected":
    var p = initParser("try { a } catch (e) { b }")
    let prog = p.parseProgram()
    check prog.stmts.len == 1
    let t = prog.stmts[0]
    check t.catchParamLen == 1'u32
    check t.catchPattern == nil

# ------------------------------------------------------------------
# Phase 2e-1: class skeleton AST + dumper
# ------------------------------------------------------------------

import std/strutils

# Minimal dump walk mirroring nim_parse.nim's dumpAst for the class kinds
# (labels are "?" for all class kinds — verified vs nk_label). Only the
# shapes exercised by the 2e-1 hand-built tests are covered here.
proc dumpClass(n: AstNode, src: string, depth: int): string =
  if n == nil:
    return repeat("  ", depth) & "(null)\n"
  let ind = repeat("  ", depth)
  case n.kind
  of ClassDecl, ClassExpr:
    result = ind & "?\n"
    if n.classParent != nil: result &= dumpClass(n.classParent, src, depth+1)
    for m in n.classMembers: result &= dumpClass(m, src, depth+1)
  of MethodDef:
    result = ind & "?\n"
    result &= dumpClass(n.methodBody, src, depth+1)
    if n.methodComputedKey != nil: result &= dumpClass(n.methodComputedKey, src, depth+1)
    for prm in n.methodParams: result &= dumpClass(prm, src, depth+1)
  of StaticBlock:
    result = ind & "?\n"
    result &= dumpClass(n.staticBlockBody, src, depth+1)
  of BlockStmt:
    result = ind & "BlockStmt\n"
    for st in n.stmtList: result &= dumpClass(st, src, depth+1)
  of IdentExpr:
    result = ind & "IdentExpr \"" & src[n.start.int ..< n.`end`.int] & "\"\n"
  else:
    result = ind & "?\n"

suite "parser classes ast":
  test "ClassDecl with parent + one MethodDef dumps the indented ? tree":
    let src = "class C extends B { m(x) {} }"
    # parent = IdentExpr "B" at the byte offset of B in src
    let bPos = src.find('B').uint32
    let parent = newLeaf(IdentExpr, bPos, bPos + 1)
    # one param x; method body empty BlockStmt
    let xPos = src.find('x').uint32
    let param = newLeaf(IdentExpr, xPos, xPos + 1)
    let body = newBlock(0'u32, 0'u32, @[])
    let m = newMethodDef(0'u32, 0'u32, 0'u32, 0'u32, body, nil, @[param],
                         false, TokenKind.Eq, false, false)
    let cls = newClass(ClassDecl, 0'u32, 0'u32, 0'u32, 0'u32, parent, @[m])
    check cls.kind == NodeKind.ClassDecl
    check cls.classParent != nil
    check cls.classMembers.len == 1
    check cls.classMembers[0].kind == NodeKind.MethodDef
    check cls.classMembers[0].methodParams.len == 1
    let expected = "?\n  IdentExpr \"B\"\n  ?\n    BlockStmt\n    IdentExpr \"x\"\n"
    check dumpClass(cls, src, 0) == expected

  test "ClassExpr (no parent) with a computed-key MethodDef":
    let src = "class { [k]() {} }"
    let kPos = src.find('k').uint32
    let key = newLeaf(IdentExpr, kPos, kPos + 1)
    let body = newBlock(0'u32, 0'u32, @[])
    let m = newMethodDef(0'u32, 0'u32, 0'u32, 0'u32, body, key, @[],
                         false, TokenKind.Eq, false, false)
    let cls = newClass(ClassExpr, 0'u32, 0'u32, 0'u32, 0'u32, nil, @[m])
    check cls.kind == NodeKind.ClassExpr
    check cls.classParent == nil
    check cls.classMembers[0].methodComputedKey != nil
    # body first, THEN computed key (matches Zen-c left → third order)
    let expected = "?\n  ?\n    BlockStmt\n    IdentExpr \"k\"\n"
    check dumpClass(cls, src, 0) == expected

  test "StaticBlock dumps body only":
    let src = "class C { static {} }"
    let body = newBlock(0'u32, 0'u32, @[])
    let sb = newStaticBlock(0'u32, 0'u32, body)
    check sb.kind == NodeKind.StaticBlock
    check sb.staticBlockBody != nil
    let cls = newClass(ClassDecl, 0'u32, 0'u32, 0'u32, 0'u32, nil, @[sb])
    let expected = "?\n  ?\n    BlockStmt\n"
    check dumpClass(cls, src, 0) == expected

  test "MethodDef flags round-trip (static/accessor/async/gen)":
    let body = newBlock(0'u32, 0'u32, @[])
    let m = newMethodDef(0'u32, 0'u32, 3'u32, 5'u32, body, nil, @[],
                         true, TokenKind.KwGet, true, true)
    check m.methodIsStatic
    check m.methodAccessor == TokenKind.KwGet
    check m.methodIsAsync
    check m.methodIsGenerator
    check m.methodNameStart == 3'u32
    check m.methodNameLen == 5'u32

# ------------------------------------------------------------------
# Phase 2e-1: class skeleton parser (decl/expr/methods/static-block/super)
# ------------------------------------------------------------------

proc parseOne(src: string): AstNode =
  ## Parse `src` and return the single top-level statement (nil on error).
  var p = initParser(src)
  let prog = p.parseProgram()
  if p.hadError or prog.stmts.len != 1: return nil
  prog.stmts[0]

suite "parser classes 2e-1":
  test "class C {} — empty class decl":
    let c = parseOne("class C {}")
    check c != nil
    check c.kind == NodeKind.ClassDecl
    check c.classParent == nil
    check c.classMembers.len == 0

  test "class C extends B {} — parent recorded, no members":
    let c = parseOne("class C extends B {}")
    check c != nil
    check c.kind == NodeKind.ClassDecl
    check c.classParent != nil
    check c.classParent.kind == NodeKind.IdentExpr
    check c.classMembers.len == 0

  test "class C { m(x) { return x; } } — one method, one param":
    let c = parseOne("class C { m(x) { return x; } }")
    check c != nil
    check c.classMembers.len == 1
    let m = c.classMembers[0]
    check m.kind == NodeKind.MethodDef
    check m.methodParams.len == 1
    check m.methodAccessor == TokenKind.Eq
    check m.methodBody.kind == NodeKind.BlockStmt

  test "static / get / set — three members with correct flags":
    let c = parseOne("class C { static s() {} get g() { return 1; } set v(x) {} }")
    check c != nil
    check c.classMembers.len == 3
    check c.classMembers[0].methodIsStatic
    check c.classMembers[1].methodAccessor == TokenKind.KwGet
    check c.classMembers[2].methodAccessor == TokenKind.KwSet

  test "class C { [k]() {} } — computed key set":
    let c = parseOne("class C { [k]() {} }")
    check c != nil
    check c.classMembers.len == 1
    check c.classMembers[0].methodComputedKey != nil
    check c.classMembers[0].methodNameLen == 0'u32

  test "class C { static { let a = 1; } } — static block":
    let c = parseOne("class C { static { let a = 1; } }")
    check c != nil
    check c.classMembers.len == 1
    let sb = c.classMembers[0]
    check sb.kind == NodeKind.StaticBlock
    check sb.staticBlockBody.kind == NodeKind.BlockStmt
    check sb.staticBlockBody.stmtList.len == 1

  test "derived ctor with super() and super.m()":
    let c = parseOne("class C extends B { constructor() { super(); super.m(); } }")
    check c != nil
    check c.classParent != nil
    check c.classMembers.len == 1
    let ctorBody = c.classMembers[0].methodBody
    check ctorBody.stmtList.len == 2
    # super() is a Call whose callee is a SuperExpr
    check ctorBody.stmtList[0].kind == NodeKind.Call
    check ctorBody.stmtList[0].callee.kind == NodeKind.SuperExpr
    # super.m() is a Call of a Member of a SuperExpr
    check ctorBody.stmtList[1].kind == NodeKind.Call
    check ctorBody.stmtList[1].callee.kind == NodeKind.Member
    check ctorBody.stmtList[1].callee.recv.kind == NodeKind.SuperExpr

  test "const C = class extends B {}; — class expression":
    let d = parseOne("const C = class extends B {};")
    check d != nil
    check d.kind == NodeKind.VarDecl
    let init = d.declarators[0].init
    check init.kind == NodeKind.ClassExpr
    check init.classParent != nil

  test "generator + async + async-generator methods":
    let c = parseOne("class C { *g() {} async a() {} async *ag() {} }")
    check c != nil
    check c.classMembers.len == 3
    check c.classMembers[0].methodIsGenerator
    check c.classMembers[1].methodIsAsync
    check c.classMembers[2].methodIsAsync and c.classMembers[2].methodIsGenerator

  test "private methods #m() and get #g()":
    let c = parseOne("class C { #m() {} get #g() { return 1; } }")
    check c != nil
    check c.classMembers.len == 2
    check c.classMembers[1].methodAccessor == TokenKind.KwGet

  test "string and numeric method names":
    let c = parseOne("""class C { "s"() {} 0() {} }""")
    check c != nil
    check c.classMembers.len == 2

  test "nested class inside a method body":
    let c = parseOne("class Outer { m() { class Inner {} } }")
    check c != nil
    let body = c.classMembers[0].methodBody
    check body.stmtList.len == 1
    check body.stmtList[0].kind == NodeKind.ClassDecl

  test "extends f(x).y — member/call parent expression":
    let c = parseOne("class C extends f(x).y {}")
    check c != nil
    check c.classParent.kind == NodeKind.Member

  test "contextual words get/set/static as plain method names":
    let c = parseOne("class C { get() {} set() {} static() {} }")
    check c != nil
    check c.classMembers.len == 3
    for m in c.classMembers:
      check m.kind == NodeKind.MethodDef
      check m.methodAccessor == TokenKind.Eq
      check not m.methodIsStatic

  test "stray semicolons between members are skipped":
    let c = parseOne("class C { ; ; m() {} ; }")
    check c != nil
    check c.classMembers.len == 1
    check c.classMembers[0].kind == NodeKind.MethodDef

# ------------------------------------------------------------------
# Phase 2e-2: ClassField AST node + dumper
# ------------------------------------------------------------------

# Extend the minimal class dump walk with ClassField + NumberExpr + the
# synth-ctor shapes (Assignment/Member/Computed/ThisExpr/UndefinedExpr) so
# the hand-built 2e-2 trees round-trip.
proc dumpClass2(n: AstNode, src: string, depth: int): string =
  if n == nil:
    return repeat("  ", depth) & "(null)\n"
  let ind = repeat("  ", depth)
  case n.kind
  of ClassDecl, ClassExpr:
    result = ind & "?\n"
    if n.classParent != nil: result &= dumpClass2(n.classParent, src, depth+1)
    for m in n.classMembers: result &= dumpClass2(m, src, depth+1)
  of MethodDef:
    result = ind & "?\n"
    result &= dumpClass2(n.methodBody, src, depth+1)
    if n.methodComputedKey != nil: result &= dumpClass2(n.methodComputedKey, src, depth+1)
    for prm in n.methodParams: result &= dumpClass2(prm, src, depth+1)
  of ClassField:
    result = ind & "?\n"
    if n.fieldInit != nil: result &= dumpClass2(n.fieldInit, src, depth+1)
    if n.fieldComputedKey != nil: result &= dumpClass2(n.fieldComputedKey, src, depth+1)
  of BlockStmt:
    result = ind & "BlockStmt\n"
    for st in n.stmtList: result &= dumpClass2(st, src, depth+1)
  of Assignment:
    result = ind & "Assignment op=Eq\n"
    result &= dumpClass2(n.target, src, depth+1)
    result &= dumpClass2(n.value, src, depth+1)
  of Member:
    result = ind & "Member name=\"" & src[n.propStart.int ..< (n.propStart + n.propLength).int] & "\"\n"
    result &= dumpClass2(n.recv, src, depth+1)
  of Computed:
    result = ind & "Computed\n"
    result &= dumpClass2(n.recv, src, depth+1)
    result &= dumpClass2(n.index, src, depth+1)
  of NumberExpr:
    result = ind & "NumberExpr " & $n.numVal.int & "\n"
  of IdentExpr:
    result = ind & "IdentExpr \"" & src[n.start.int ..< n.`end`.int] & "\"\n"
  of ThisExpr:
    result = ind & "ThisExpr\n"
  of UndefinedExpr:
    result = ind & "UndefinedExpr\n"
  else:
    result = ind & "?\n"

suite "ast 2e-2 ClassField":
  test "newClassField stores fields and dumps init then computed key":
    let src = "class C { x = 1; }"
    let xPos = src.find('x').uint32
    let init = newNumber(0'u32, 0'u32, 1.0)
    let f = newClassField(xPos, xPos + 5, xPos, 1'u32, init, nil, false)
    check f.kind == NodeKind.ClassField
    check f.fieldNameStart == xPos
    check f.fieldNameLen == 1'u32
    check f.fieldInit != nil
    check f.fieldComputedKey == nil
    check f.fieldIsStatic == false
    check dumpClass2(f, src, 0) == "?\n  NumberExpr 1\n"

  test "static field carries the isStatic flag, no init dumps bare ?":
    let f = newClassField(0'u32, 0'u32, 0'u32, 1'u32, nil, nil, true)
    check f.fieldIsStatic == true
    check f.fieldInit == nil
    check dumpClass2(f, "", 0) == "?\n"

  test "computed field: init then the computed key node":
    let src = "class C { [k2] = 5; }"
    let kPos = src.find("k2").uint32
    let key = newLeaf(IdentExpr, kPos, kPos + 2)
    let init = newNumber(0'u32, 0'u32, 5.0)
    let f = newClassField(0'u32, 0'u32, 0'u32, 0'u32, init, key, false)
    check f.fieldNameLen == 0'u32
    check f.fieldComputedKey != nil
    check dumpClass2(f, src, 0) == "?\n  NumberExpr 5\n  IdentExpr \"k2\"\n"

# ------------------------------------------------------------------
# Phase 2e-2: field parsing + synthetic-constructor synthesis
# ------------------------------------------------------------------

suite "parser class fields 2e-2":
  test "instance + static + private + bare fields; synth ctor injects instance only":
    let c = parseOne("class C { x = 1; static y = 2; #p = 3; z; }")
    check c != nil
    # 4 fields + 1 synth ctor (static y EXCLUDED from injection)
    check c.classMembers.len == 5
    let ctor = c.classMembers[4]
    check ctor.kind == NodeKind.MethodDef
    let stmts = ctor.methodBody.stmtList
    check stmts.len == 3            # x, #p, z — NOT static y
    check stmts[0].target.kind == NodeKind.Member
    check stmts[0].value.kind == NodeKind.NumberExpr
    # bare `z` → this.z = UndefinedExpr
    check stmts[2].value.kind == NodeKind.UndefinedExpr

  test "computed field: synth ctor target is Computed[ThisExpr, key]; key SHARED":
    let c = parseOne("class C { [k2] = 5; }")
    check c != nil
    check c.classMembers.len == 2  # field + synth ctor
    let field = c.classMembers[0]
    let ctor = c.classMembers[1]
    let assign = ctor.methodBody.stmtList[0]
    check assign.target.kind == NodeKind.Computed
    check assign.target.recv.kind == NodeKind.ThisExpr
    # the computed-key node is the SAME object under the field and the target
    check assign.target.index == field.fieldComputedKey

  test "init PREPENDED into existing explicit ctor before its body":
    let c = parseOne("class C { x = 1; constructor() { foo(); } }")
    check c != nil
    # field + explicit ctor (no synth appended)
    check c.classMembers.len == 2
    let ctor = c.classMembers[1]
    let stmts = ctor.methodBody.stmtList
    check stmts.len == 2
    check stmts[0].kind == NodeKind.Assignment        # this.x = 1
    check stmts[1].kind == NodeKind.Call              # foo()

  test "derived class, no ctor: synth ctor has inits THEN super()":
    let c = parseOne("class C extends B { x = 1; }")
    check c != nil
    let ctor = c.classMembers[^1]
    let stmts = ctor.methodBody.stmtList
    check stmts.len == 2
    check stmts[0].kind == NodeKind.Assignment        # this.x = 1 FIRST
    check stmts[1].kind == NodeKind.Call              # super() LAST
    check stmts[1].callee.kind == NodeKind.SuperExpr

  test "derived class, explicit ctor: init prepended BEFORE explicit super()":
    let c = parseOne("class C extends B { x = 1; constructor() { super(); } }")
    check c != nil
    let ctor = c.classMembers[^1]
    let stmts = ctor.methodBody.stmtList
    check stmts.len == 2
    check stmts[0].kind == NodeKind.Assignment        # this.x = 1
    check stmts[1].kind == NodeKind.Call              # explicit super()
    check stmts[1].callee.kind == NodeKind.SuperExpr

  test "static-only class: NO synth ctor produced":
    let c = parseOne("class C { static x = 1; }")
    check c != nil
    check c.classMembers.len == 1                     # just the static field
    check c.classMembers[0].kind == NodeKind.ClassField
    check c.classMembers[0].fieldIsStatic

  test "bare field (no init): synth ctor assigns UndefinedExpr":
    let c = parseOne("class C { x }")
    check c != nil
    let ctor = c.classMembers[^1]
    check ctor.methodBody.stmtList[0].value.kind == NodeKind.UndefinedExpr

  test "two instance fields injected in source order":
    let c = parseOne("class C { x = 1; y = 2; }")
    check c != nil
    let stmts = c.classMembers[^1].methodBody.stmtList
    check stmts.len == 2
    check stmts[0].value.numVal == 1.0
    check stmts[1].value.numVal == 2.0

  test "mixed computed + named field injection":
    let c = parseOne("class C { [a] = 1; b = 2; }")
    check c != nil
    let stmts = c.classMembers[^1].methodBody.stmtList
    check stmts.len == 2
    check stmts[0].target.kind == NodeKind.Computed   # [a]
    check stmts[1].target.kind == NodeKind.Member     # b

  test "string-literal field name is UNQUOTED in the Member target":
    let c = parseOne("class C { 'x' = 1; }")
    check c != nil
    let target = c.classMembers[^1].methodBody.stmtList[0].target
    check target.kind == NodeKind.Member
    # propStart/propLength point at the unquoted `x`, not `'x'`
    let src = "class C { 'x' = 1; }"
    check src[target.propStart.int ..< (target.propStart + target.propLength).int] == "x"

  test "ctor not first member: inits still prepend into it":
    let c = parseOne("class C extends B { x = 1; m() {} constructor() { g(); } }")
    check c != nil
    # field + method + explicit ctor (no synth)
    check c.classMembers.len == 3
    let ctor = c.classMembers[2]
    let stmts = ctor.methodBody.stmtList
    check stmts.len == 2
    check stmts[0].kind == NodeKind.Assignment        # this.x = 1 prepended
    check stmts[1].kind == NodeKind.Call              # g()

  test "static field excluded, instance field injected":
    let c = parseOne("class C { static a = 1; b = 2; }")
    check c != nil
    let stmts = c.classMembers[^1].methodBody.stmtList
    check stmts.len == 1                              # only b, static a excluded
    check stmts[0].value.numVal == 2.0

  test "method-only class: no synthesis fires":
    let c = parseOne("class C { m() {} static s() {} }")
    check c != nil
    check c.classMembers.len == 2
    for m in c.classMembers:
      check m.kind == NodeKind.MethodDef

suite "parser contextual-keyword identifiers":
  # `of`/`from`/`as`/`let` lex as keyword tokens but are valid
  # IdentifierReferences in primary/operand position (Zen-c is_binding_ident).
  for kw in ["of", "from", "as"]:
    test "contextual keyword '" & kw & "' as a bare identifier reference":
      let s = parseOne(kw & ";")
      check s != nil
      check s.kind == NodeKind.IdentExpr

  test "'let' as an identifier in operand position (not statement-initial)":
    # statement-initial `let` is a declaration; in operand position it is an
    # IdentifierReference. `x = let` → Assignment whose value is IdentExpr.
    let s = parseOne("x = let")
    check s != nil
    check s.kind == NodeKind.Assignment
    check s.value.kind == NodeKind.IdentExpr

  test "contextual keyword as a call argument":
    let s = parseOne("f(from, of, as)")
    check s != nil
    check s.kind == NodeKind.Call
    check s.args.len == 3
    for a in s.args: check a.kind == NodeKind.IdentExpr

  test "contextual keyword in a binary operand":
    let s = parseOne("from + to")
    check s != nil
    check s.kind == NodeKind.Binary
    check s.lhs.kind == NodeKind.IdentExpr
    check s.rhs.kind == NodeKind.IdentExpr

  test "statement-initial 'let' still parses as a declaration (not an ident)":
    let s = parseOne("let x = 1;")
    check s != nil
    check s.kind == NodeKind.VarDecl

suite "parser for-head destructuring target":
  # A bare (non-declaration) for-of/for-in LHS is reinterpreted as an
  # assignment pattern, mirroring destructuring assignment.
  test "for ({a} of x) — object pattern binding":
    let s = parseOne("for ({a} of x) {}")
    check s != nil
    check s.kind == NodeKind.ForOfStmt
    check s.forBinding.kind == NodeKind.ObjectPattern

  test "for ([a, b] of x) — array pattern binding":
    let s = parseOne("for ([a, b] of x) {}")
    check s != nil
    check s.kind == NodeKind.ForOfStmt
    check s.forBinding.kind == NodeKind.ArrayPattern

  test "for ({a} in x) — for-in also reinterprets":
    let s = parseOne("for ({a} in x) {}")
    check s != nil
    check s.kind == NodeKind.ForInStmt
    check s.forBinding.kind == NodeKind.ObjectPattern

  test "for (const [x] of y) — declaration binding NOT reinterpreted as assignment pattern":
    let s = parseOne("for (const [x] of y) {}")
    check s != nil
    check s.kind == NodeKind.ForOfStmt
    check s.forBinding.kind == NodeKind.VarDecl

  test "for (x of y) — simple identifier LHS unchanged":
    let s = parseOne("for (x of y) {}")
    check s != nil
    check s.forBinding.kind == NodeKind.IdentExpr

# ------------------------------------------------------------------
# Phase 2f-1: functionDepth + top-level `return` is a SyntaxError
# ------------------------------------------------------------------

proc parseHadError(src: string): bool =
  ## Parse `src` to completion and report whether the parser flagged an error.
  var p = initParser(src)
  discard p.parseProgram()
  p.hadError

suite "parser early errors 2f-1: top-level return":
  test "bare `return;` at top level is rejected":
    check parseHadError("return;")

  test "`return 1;` at top level is rejected":
    check parseHadError("return 1;")

  test "`return` inside a function declaration is accepted":
    check not parseHadError("function f(){ return; }")

  test "`return 1` inside a function declaration is accepted":
    check not parseHadError("function f(){ return 1; }")

  test "`return` inside an arrow body is accepted":
    check not parseHadError("const g = () => { return 1; };")

  test "`return` inside an object method is accepted":
    check not parseHadError("({ m() { return 2; } })")

  test "`return` inside an object getter is accepted":
    check not parseHadError("({ get x() { return 3; } })")

  test "`return` inside a class method is accepted":
    check not parseHadError("class C { m() { return 4; } }")

  test "`return` inside a nested function is accepted":
    check not parseHadError("function f(){ function g(){ return 1; } return g(); }")

# ------------------------------------------------------------------
# Phase 2f-2: context-reserved bindings — `yield` may not be BOUND inside a
# generator body, `await` may not be BOUND inside an async body (Zen-c
# is_binding_ident_ctx, parser.zc:806). Params/names are parsed in the
# ENCLOSING context, so a generator's own `yield` param/name stays legal.
# ------------------------------------------------------------------

suite "parser early errors 2f-2: context-reserved bindings":
  # --- REJECT: yield bound inside a generator body ---
  test "var yield in generator body is rejected":
    check parseHadError("function* g(){ var yield; }")

  test "array-pattern leaf [yield] in generator body is rejected":
    check parseHadError("function* g(){ let [yield] = x; }")

  test "object-pattern rename {x: yield} in generator body is rejected":
    check parseHadError("function* g(){ var {x: yield} = o; }")

  test "catch(yield) in generator body is rejected":
    check parseHadError("function* g(){ try{}catch(yield){} }")

  test "class yield in generator body is rejected":
    check parseHadError("function* g(){ class yield{} }")

  test "nested fn param (yield) in generator body is rejected":
    check parseHadError("function* g(){ function inner(yield){} }")

  test "nested fn named yield in generator body is rejected":
    check parseHadError("function* g(){ function yield(){} }")

  test "arrow body var yield in generator body is rejected":
    check parseHadError("function* g(){ a => { var yield; } }")

  test "single arrow param (yield) in generator body is rejected":
    check parseHadError("function* g(){ (yield) => 1; }")

  test "for (var yield of x) in generator body is rejected":
    check parseHadError("function* g(){ for (var yield of x){} }")

  # --- REJECT: await bound inside an async body ---
  test "var await in async body is rejected":
    check parseHadError("async function a(){ var await; }")

  test "object-pattern shorthand {await} in async body is rejected":
    check parseHadError("async function a(){ const {await} = x; }")

  test "catch(await) in async body is rejected":
    check parseHadError("async function a(){ try{}catch(await){} }")

  test "nested fn named await in async body is rejected":
    check parseHadError("async function a(){ function await(){} }")

  test "for (const await in x) in async body is rejected":
    check parseHadError("async function a(){ for (const await in x){} }")

  # --- ACCEPT: enclosing-context names/params and non-binding positions ---
  test "generator's own yield param is accepted (enclosing context)":
    check not parseHadError("function* g(yield){}")

  test "generator's own name yield is accepted (enclosing context)":
    check not parseHadError("function* yield(){}")

  test "async function's own name await is accepted (enclosing context)":
    check not parseHadError("async function await(){}")

  test "async function's own await param is accepted (enclosing context)":
    check not parseHadError("async function a(await){}")

  test "yield EXPRESSION (not a binding) in generator body is accepted":
    check not parseHadError("function* g(){ var x = yield; }")

  test "yield as a label in generator body is accepted":
    check not parseHadError("function* g(){ label: yield; }")

  test "var yield in a NON-generator function is accepted":
    check not parseHadError("function f(){ var yield; }")

  test "var yield in an async-NOT-generator body is accepted (only await reserved)":
    check not parseHadError("async function a(){ var yield; }")

  test "var await in a NON-async function is accepted":
    check not parseHadError("function f(){ var await; }")

# ------------------------------------------------------------------
# Phase 2f-3a: strict-mode flag + strict binding/reference early errors +
# with-in-strict. Strict mode comes from a PROGRAM-level "use strict"
# prologue (propagating into all nested fns) and from class bodies (always
# strict, not leaking past the class). Function-body directives do NOT turn
# on strict at parse time (Zen-c parse behavior). Escaped `\uXXXX` keyword
# spellings are slice 2f-3c, out of scope here.
# ------------------------------------------------------------------

suite "parser early errors 2f-3a: strict mode":
  # --- with in strict (program prologue + class body) ---
  test "with in strict program is rejected":
    check parseHadError("\"use strict\"; with(o){}")

  test "with inside a class method is rejected (class body is strict)":
    check parseHadError("class C { m(){ with(o){} } }")

  test "with in non-strict is accepted":
    check not parseHadError("with(o){}")

  # --- eval/arguments bound in strict is rejected (references stay legal) ---
  test "var eval in strict is rejected":
    check parseHadError("\"use strict\"; var eval;")

  test "var arguments = 1 in strict is rejected":
    check parseHadError("\"use strict\"; var arguments = 1;")

  test "function param eval in strict is rejected":
    check parseHadError("\"use strict\"; function f(eval){}")

  test "function named arguments in strict is rejected":
    check parseHadError("\"use strict\"; function arguments(){}")

  test "catch(eval) in strict is rejected":
    check parseHadError("\"use strict\"; try{}catch(eval){}")

  test "var eval = 1 in non-strict is accepted":
    check not parseHadError("var eval = 1;")

  test "eval as a reference in strict is accepted":
    check not parseHadError("\"use strict\"; eval;")

  test "x = eval reference in strict is accepted":
    check not parseHadError("\"use strict\"; x = eval;")

  test "var x = arguments reference in strict is accepted":
    check not parseHadError("\"use strict\"; var x = arguments;")

  # --- future-reserved words bound in strict ---
  test "var public in strict is rejected":
    check parseHadError("\"use strict\"; var public;")

  test "function param private in strict is rejected":
    check parseHadError("\"use strict\"; function f(private){}")

  test "let interface in strict is rejected":
    check parseHadError("\"use strict\"; let interface = 1;")

  test "var static in strict is rejected":
    check parseHadError("\"use strict\"; var static;")

  test "var public in non-strict is accepted":
    check not parseHadError("var public = 1;")

  # --- yield bound in strict (even outside a generator) ---
  test "var yield in strict is rejected":
    check parseHadError("\"use strict\"; var yield;")

  # --- let as a binding is NOT future-reserved (accept) ---
  test "let x in strict is accepted":
    check not parseHadError("\"use strict\"; let x = 1;")

  test "var let in strict is accepted (let is not future-reserved)":
    check not parseHadError("\"use strict\"; var let;")

  # --- future-reserved as a REFERENCE in strict is rejected ---
  test "future-reserved reference public in strict is rejected":
    check parseHadError("\"use strict\"; public;")

  test "future-reserved reference private + 1 in strict is rejected":
    check parseHadError("\"use strict\"; private + 1;")

  test "future-reserved as arg f(interface) in strict is rejected":
    check parseHadError("\"use strict\"; f(interface);")

  test "future-reserved RHS var x = public in strict is rejected":
    check parseHadError("\"use strict\"; var x = public;")

  test "bare static reference in strict is rejected":
    check parseHadError("\"use strict\"; static;")

  # --- strict PROPAGATES into nested functions/arrows/methods ---
  test "var eval in a nested fn under strict program is rejected":
    check parseHadError("\"use strict\"; function f(){ var eval; }")

  test "var public in a nested fn under strict program is rejected":
    check parseHadError("\"use strict\"; function f(){ var public; }")

  test "var arguments in an object method under strict program is rejected":
    check parseHadError("\"use strict\"; ({ m(){ var arguments; } })")

  test "var eval in an arrow body under strict program is rejected":
    check parseHadError("\"use strict\"; () => { var eval; }")

  # --- class body is strict; eval/future-reserved bindings in methods ---
  test "var arguments in a class method is rejected":
    check parseHadError("class C { m(){ var arguments; } }")

  test "var public in a class method is rejected":
    check parseHadError("class C { m(){ var public; } }")

  # --- function-body directives do NOT turn on strict at parse time ---
  test "function-body use-strict does NOT reject var eval (parse-time)":
    check not parseHadError("function f(){ \"use strict\"; var eval; }")

  test "var eval in a plain function is accepted":
    check not parseHadError("function f(){ var eval; }")

  # --- strict does NOT leak past a class declaration ---
  test "var eval after a class decl is accepted (strict does not leak)":
    check not parseHadError("class C {}; var eval = 1;")

  # --- contextual-name regression guards (static/get/set must still work) ---
  test "static method name still parses (non-strict)":
    check not parseHadError("class C { static m(){} }")

  test "object literal { static: 1 } still parses":
    check not parseHadError("({ static: 1 })")

  test "member obj.static still parses":
    check not parseHadError("obj.static;")

  test "bare static reference in NON-strict is accepted":
    check not parseHadError("static;")

  # --- sanity: ordinary code under a strict program is fine ---
  test "ordinary var under a strict program is accepted":
    check not parseHadError("\"use strict\"; var x = 1;")

suite "parser dynamic import 2f-7":
  test "import(spec) → ImportCall with the spec as its only child":
    let s = parseOne("import('x')")
    check s != nil
    check s.kind == NodeKind.ImportCall
    check s.importSpec.kind == NodeKind.StringExpr

  test "import(spec, options) → options discarded":
    let s = parseOne("import('x', opts)")
    check s != nil
    check s.kind == NodeKind.ImportCall
    check s.importSpec.kind == NodeKind.StringExpr

  test "import.meta → ImportMetaExpr leaf":
    let s = parseOne("import.meta")
    check s != nil
    check s.kind == NodeKind.ImportMetaExpr

  test "import.meta.url → Member over ImportMetaExpr":
    let s = parseOne("import.meta.url")
    check s != nil
    check s.kind == NodeKind.Member
    check s.recv.kind == NodeKind.ImportMetaExpr

  test "import(x).then(f) → Call/Member chain over ImportCall":
    let s = parseOne("import(x).then(f)")
    check s != nil
    check s.kind == NodeKind.Call

  test "dynamic import works inside a function body":
    let s = parseOne("function f(){ return import(x); }")
    check s != nil
    check s.kind == NodeKind.FunctionDecl

  test "import.foo (not meta) is a parse error":
    var p = initParser("import.foo")
    discard p.parseProgram()
    check p.hadError

suite "parser early errors 2f-4: for-in/of binding initializer":
  proc hadErr(src: string): bool =
    var p = initParser(src); discard p.parseProgram(); p.hadError
  test "for (var x = 1 in y) — initializer is a SyntaxError":
    check hadErr("for (var x = 1 in y){}")
  test "for (let [a] = 0 of z) — pattern initializer rejected":
    check hadErr("for (let [a] = 0 of z){}")
  test "for (var x in y) — no initializer is fine":
    check not hadErr("for (var x in y){}")
  test "for (const [a,b] of y) — no initializer is fine":
    check not hadErr("for (const [a,b] of y){}")
  test "C-style for with initializer still fine":
    check not hadErr("for (var i = 0; i < n; i++){}")

suite "parser early errors 2f-4b: duplicate parameters":
  proc hadErr(src: string): bool =
    var p = initParser(src); discard p.parseProgram(); p.hadError
  test "arrow always rejects duplicate params":
    check hadErr("(a, a) => 1")
  test "object method rejects duplicate params":
    check hadErr("({ m(a, a){} })")
  test "strict function rejects duplicate params":
    check hadErr("\"use strict\"; function f(a, a){}")
  test "non-simple (default) function rejects duplicate params":
    check hadErr("function f(a, b = 1, a){}")
  test "non-simple (pattern) rejects nested duplicate":
    check hadErr("function f([a, a]){}")
  test "sloppy simple function ALLOWS duplicate params":
    check not hadErr("function f(a, a){}")
  test "sloppy simple generator ALLOWS duplicate params":
    check not hadErr("function* g(a, a){}")
  test "distinct params are fine everywhere":
    check not hadErr("(a, b) => a")
    check not hadErr("function f({a}, {b}){}")

suite "parser early errors 2f-6a: class member name restrictions":
  proc hadErr(src: string): bool =
    var p = initParser(src); discard p.parseProgram(); p.hadError
  test "duplicate constructor rejected":
    check hadErr("class C { constructor(){} constructor(){} }")
  test "special-method constructor rejected (get/set/gen/async)":
    check hadErr("class C { get constructor(){} }")
    check hadErr("class C { *constructor(){} }")
    check hadErr("class C { async constructor(){} }")
  test "static prototype method/field rejected":
    check hadErr("class C { static prototype(){} }")
    check hadErr("class C { static prototype = 1; }")
  test "field named constructor rejected (instance + static)":
    check hadErr("class C { constructor = 1; }")
    check hadErr("class C { static constructor = 1; }")
  test "#constructor rejected (method + field)":
    check hadErr("class C { #constructor(){} }")
    check hadErr("class C { #constructor = 1; }")
  test "legal members accepted":
    check not hadErr("class C { constructor(){} }")
    check not hadErr("class C { static constructor(){} }")  # static METHOD ok
    check not hadErr("class C { prototype(){} prototype = 1; }")  # only STATIC prototype restricted
    check not hadErr("class C { [\"constructor\"](){} }")  # computed skips the check

suite "parser early errors 2f-6b: undeclared private-name reference":
  proc hadErr(src: string): bool =
    var p = initParser(src); discard p.parseProgram(); p.hadError
  # --- REJECT: a private reference with no enclosing declaration ---
  test "undeclared private member in method rejected":
    check hadErr("class C { m(){ return this.#y; } }")
  test "undeclared private member with a different declared name rejected":
    check hadErr("class C { #x; m(){ return this.#y; } }")
  test "undeclared private member in delete rejected":
    check hadErr("class C { m(){ delete this.#x; } }")
  test "private member at top level (no class) rejected":
    check hadErr("function f(){ return this.#x; }")
  test "undeclared private member on arbitrary receiver rejected":
    check hadErr("class C { m(){ obj.#foo; } }")
  test "private member in extends clause (outer scope) rejected":
    check hadErr("class C extends this.#x {}")
  # --- ACCEPT: properly declared (incl. forward + nested) ---
  test "declared private member accepted":
    check not hadErr("class C { #x; m(){ return this.#x; } }")
  test "forward-referenced private field accepted":
    check not hadErr("class C { m(){ return this.#x; } #x; }")
  test "private method reference accepted":
    check not hadErr("class C { #x(){} m(){ this.#x(); } }")
  test "private accessor reference accepted":
    check not hadErr("class C { get #x(){} m(){ this.#x; } }")
  test "instance + static private both accepted":
    check not hadErr("class C { #x; static #y; m(){ this.#x + C.#y; } }")
  test "nested class: inner method sees outer private":
    check not hadErr("class Outer { #o; m(){ class Inner { #i; n(){ this.#o + this.#i; } } } }")
  test "derived class with super and private accepted":
    check not hadErr("class C extends D { #x; m(){ super.foo; this.#x; } }")
  test "extends in method scope where private is declared accepted":
    check not hadErr("class O { #x; m(){ class I extends this.#x {} } }")
  test "ordinary (non-private) members never error":
    check not hadErr("class C { #x; m(){ return this.#x; } } obj.foo; this.bar;")

suite "parser new.target + accessor-ASI (class valid-input fixes)":
  proc one(src: string): AstNode = parseOne(src)
  proc hadErr(src: string): bool =
    var p = initParser(src); discard p.parseProgram(); p.hadError
  test "new.target parses (as ThisExpr) at top level and in functions/static blocks":
    check one("new.target").kind == NodeKind.ThisExpr
    check not hadErr("function f(){ return new.target; }")
    check not hadErr("class C { static { x = new.target; } }")
    check not hadErr("new.target.foo")
    check not hadErr("new.target()")
  test "new.<not-target> is a parse error":
    check hadErr("new.foo")
  test "regular new still works":
    check one("new Foo(1)").kind == NodeKind.New
    check one("new a.b.c()").kind == NodeKind.New
  test "get/set field followed by ASI generator (get is a field, not accessor)":
    check not hadErr("class C { get\n *gen(){} }")
    check not hadErr("class C { set\n *gen(){} }")
  test "get/set accessor still recognized with a real name":
    check not hadErr("class C { get x(){ return 1; } set x(v){} }")
    check not hadErr("class C { get [k](){} }")

suite "parser early errors 2f-3c: escaped-keyword + yield/await label":
  proc hadErr(src: string): bool =
    var p = initParser(src); discard p.parseProgram(); p.hadError
  # --- REJECT: yield/await as a LabelIdentifier (bare and escaped) ---
  test "escaped yield label in generator rejected":
    check hadErr("function* g(){ \\u0079ield: ; }")
  test "escaped await label in async rejected":
    check hadErr("async function a(){ \\u0061wait: ; }")
  test "plain yield label in generator rejected":
    check hadErr("function* g(){ yield: ; }")
  test "plain await label in async rejected":
    check hadErr("async function a(){ await: ; }")
  test "plain yield label sloppy top-level rejected":
    check hadErr("yield: ;")
  test "escaped yield label sloppy top-level rejected":
    check hadErr("\\u0079ield: ;")
  # --- REJECT: escaped strict-reserved bindings + references ---
  test "escaped future-reserved binding rejected (strict)":
    check hadErr("\"use strict\"; var p\\u0075blic;")
  test "escaped eval binding rejected (strict)":
    check hadErr("\"use strict\"; var \\u0065val;")
  test "escaped future-reserved reference rejected (strict)":
    check hadErr("\"use strict\"; p\\u0075blic;")
  # --- ACCEPT: ordinary labels (bare and escaped) ---
  test "ordinary label accepted":
    check not hadErr("foo: ;")
  test "escaped ordinary label accepted":
    check not hadErr("\\u0066oo: ;")
  test "chained ordinary labels accepted":
    check not hadErr("x: y: z: ;")
  # --- ACCEPT: escaped yield/await bindings where legal ---
  test "escaped yield binding sloppy accepted":
    check not hadErr("var \\u0079ield;")
  test "escaped ordinary binding accepted":
    check not hadErr("var f\\u006fo;")
  test "eval reference stays legal (strict)":
    check not hadErr("\"use strict\"; \\u0065val;")
  test "escaped ordinary reference accepted":
    check not hadErr("f\\u006fo;")
  # --- ACCEPT: yield expression / ternary are NOT labels ---
  test "yield expression not a label":
    check not hadErr("function* g(){ yield x; }")
  test "ternary is not a label":
    check not hadErr("a ? b : c")
  test "escaped yield binding in generator (already agreed) stays agreeing":
    # NOTE: this is a REJECT (yield binding in a generator body) — kept to
    # guard against regressing the pre-existing agreement.
    check hadErr("function* g(){ var \\u0079ield; }")

suite "parser 2f-3c site-aware escaped eval/arguments (strict)":
  # Zen-c uses an escape-AWARE check at var/let/fn-name/catch/pattern/arrow-single
  # but a PLAIN byte-compare at regular-param/arrow-paren/rest/class-name — so an
  # escaped `eval` is rejected at the former and accepted at the latter.
  proc hadErr(src: string): bool =
    var p = initParser(src); discard p.parseProgram(); p.hadError
  test "escaped eval REJECTED at escape-aware sites":
    check hadErr("\"use strict\"; var \\u0065val;")
    check hadErr("\"use strict\"; function \\u0065val(){}")
    check hadErr("\"use strict\"; try{}catch(\\u0065val){}")
    check hadErr("\"use strict\"; \\u0065val => 1;")
    check hadErr("\"use strict\"; function f({x: \\u0065val}){}")
  test "escaped eval ACCEPTED at plain-compare sites":
    check not hadErr("\"use strict\"; function f(\\u0065val){}")
    check not hadErr("\"use strict\"; (\\u0065val) => 1;")
    check not hadErr("\"use strict\"; function f(...\\u0065val){}")
    check not hadErr("\"use strict\"; class \\u0065val {}")
  test "unescaped eval rejected everywhere; future-reserved escape-aware at params":
    check hadErr("\"use strict\"; function f(eval){}")
    check hadErr("\"use strict\"; class eval {}")
    check hadErr("\"use strict\"; function f(p\\u0075blic){}")
