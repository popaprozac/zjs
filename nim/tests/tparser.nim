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
