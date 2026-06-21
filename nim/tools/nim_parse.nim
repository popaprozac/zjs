import std/[os, strformat, strutils]
import ../src/zjs/[ast, parser]
import labels   # nkLabel, tkLabel — shared with nim_lex

proc slice(src: string, s, e: uint32): string = src[s.int ..< e.int]

proc dumpAst(n: AstNode, src: string, depth: int) =
  if n == nil:
    stdout.write(repeat("  ", depth) & "(null)\n"); return
  let ind = repeat("  ", depth)
  let label = nkLabel(n.kind)        # mirrors nk_label incl. "?" gap — NOT $kind
  case n.kind
  of NumberExpr:
    stdout.write(&"{ind}{label} {n.numVal:g}\n")        # :g == C %g (verified)
  of BoolExpr:
    stdout.write(&"{ind}{label} {(if n.boolVal: \"true\" else: \"false\")}\n")
  of IdentExpr, StringExpr:                              # ONLY these two are quoted
    stdout.write(&"{ind}{label} \"{slice(src, n.start, n.`end`)}\"\n")
  of Binary, Logical:
    stdout.write(&"{ind}{label} op={tkLabel(n.binOp)}\n")
    dumpAst(n.lhs, src, depth+1)
    dumpAst(n.rhs, src, depth+1)
  of Unary, Postfix:
    stdout.write(&"{ind}{label} op={tkLabel(n.unOp)}\n")
    dumpAst(n.operand, src, depth+1)
  of Assignment:
    stdout.write(&"{ind}{label} op={tkLabel(n.assignOp)}\n")
    dumpAst(n.target, src, depth+1)
    dumpAst(n.value, src, depth+1)
  of VarDecl:
    stdout.write(&"{ind}{label} op={tkLabel(n.declKind)}\n")
    for d in n.declarators: dumpAst(d, src, depth+1)
  of Declarator:
    stdout.write(&"{ind}{label} name=\"{slice(src, n.nameStart, n.nameStart + n.nameLength)}\"\n")
    if n.init != nil: dumpAst(n.init, src, depth+1)
  of Paren:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.inner, src, depth+1)
  of Program:
    stdout.write(&"{ind}{label}\n")
    for s in n.stmts: dumpAst(s, src, depth+1)
  of Member, OptionalMember:
    stdout.write(&"{ind}{label} name=\"{slice(src, n.propStart, n.propStart + n.propLength)}\"\n")
    dumpAst(n.recv, src, depth+1)
  of Computed, OptionalComputed:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.recv, src, depth+1)
    dumpAst(n.index, src, depth+1)
  of Call, OptionalCall, New:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.callee, src, depth+1)
    for a in n.args: dumpAst(a, src, depth+1)
  of Spread:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.spreadArg, src, depth+1)
  of Conditional:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.cond, src, depth+1)
    dumpAst(n.conseq, src, depth+1)
    dumpAst(n.alt, src, depth+1)
  of Sequence:
    stdout.write(&"{ind}{label}\n")
    for it in n.items: dumpAst(it, src, depth+1)
  of Array:
    stdout.write(&"{ind}{label}\n")
    for el in n.elems: dumpAst(el, src, depth+1)
  of Object:
    stdout.write(&"{ind}{label}\n")
    for pr in n.props: dumpAst(pr, src, depth+1)
  of ObjectProp:
    stdout.write(&"{ind}{label} name=\"{slice(src, n.keyStart, n.keyStart + n.keyLength)}\"\n")
    dumpAst(n.propVal, src, depth+1)
    if n.computedKey != nil: dumpAst(n.computedKey, src, depth+1)
  else:  # NullExpr/UndefinedExpr/ThisExpr + BigIntExpr/RegexExpr (label-only "?")
    stdout.write(&"{ind}{label}\n")

proc main() =
  let src = if paramCount() >= 1: paramStr(1) else: ""
  var p = initParser(src)
  let root = p.parseProgram()
  if p.hadError:
    stderr.write("zjs: parse error\n")
    quit(1)
  dumpAst(root, src, 0)

main()
