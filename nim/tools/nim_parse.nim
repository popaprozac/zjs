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
  of IdentExpr:
    stdout.write(&"{ind}{label} \"{slice(src, n.start, n.`end`)}\"\n")
    if n.identDefault != nil: dumpAst(n.identDefault, src, depth+1)
    if n.identPattern != nil: dumpAst(n.identPattern, src, depth+1)
  of StringExpr:
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
    if n.declPattern != nil: dumpAst(n.declPattern, src, depth+1)
  of Paren:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.inner, src, depth+1)
  of Program:
    stdout.write(&"{ind}{label}\n")
    for s in n.stmts: dumpAst(s, src, depth+1)
  of Member, OptionalMember:
    stdout.write(&"{ind}{label} name=\"{slice(src, n.propStart, n.propStart + n.propLength)}\"\n")
    if n.recv != nil: dumpAst(n.recv, src, depth+1)   # recv nil = `#x in obj` brand-check LHS
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
  of TemplateExpr:
    stdout.write(&"{ind}{label}\n")
    for c in n.tparts: dumpAst(c, src, depth+1)
  of TaggedTemplate:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.tag, src, depth+1)
    dumpAst(n.tmpl, src, depth+1)
  of BlockStmt:
    stdout.write(&"{ind}{label}\n")
    for st in n.stmtList: dumpAst(st, src, depth+1)
  of IfStmt:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.ifCond, src, depth+1)
    dumpAst(n.thenStmt, src, depth+1)
    if n.elseStmt != nil: dumpAst(n.elseStmt, src, depth+1)
  of WhileStmt:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.whileCond, src, depth+1)
    dumpAst(n.whileBody, src, depth+1)
  of DoWhileStmt:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.doBody, src, depth+1)
    dumpAst(n.doCond, src, depth+1)
  of ForStmt:
    stdout.write(&"{ind}{label}\n")
    if n.forInit   != nil: dumpAst(n.forInit,   src, depth+1)
    if n.forTest   != nil: dumpAst(n.forTest,   src, depth+1)
    if n.forUpdate != nil: dumpAst(n.forUpdate, src, depth+1)
    dumpAst(n.forBody, src, depth+1)
  of ReturnStmt:
    stdout.write(&"{ind}{label}\n")
    if n.retArg != nil: dumpAst(n.retArg, src, depth+1)
  of ThrowStmt:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.throwArg, src, depth+1)
  of LabeledStmt:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.labeled, src, depth+1)
  of ForInStmt, ForOfStmt:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.forBinding, src, depth+1)
    dumpAst(n.forIterable, src, depth+1)
    dumpAst(n.forInOfBody, src, depth+1)
  of SwitchStmt:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.switchDisc, src, depth+1)
    for c in n.cases: dumpAst(c, src, depth+1)
  of SwitchCase:
    stdout.write(&"{ind}{label}\n")
    if n.caseTest != nil: dumpAst(n.caseTest, src, depth+1)
    for st in n.caseBody: dumpAst(st, src, depth+1)
  of TryStmt:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.tryBlock, src, depth+1)
    if n.catchBlock != nil: dumpAst(n.catchBlock, src, depth+1)
    if n.finallyBlock != nil: dumpAst(n.finallyBlock, src, depth+1)
    if n.catchPattern != nil: dumpAst(n.catchPattern, src, depth+1)
  of WithStmt:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.withObj, src, depth+1)
    dumpAst(n.withBody, src, depth+1)
  of RestParam:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.restArg, src, depth+1)
  of FunctionDecl, FunctionExpr:
    if n.fnNameLen > 0'u32:
      stdout.write(&"{ind}{label} name=\"{slice(src, n.fnNameStart, n.fnNameStart + n.fnNameLen)}\"\n")
    else:
      stdout.write(&"{ind}{label} (anonymous)\n")
    dumpAst(n.fnBody, src, depth+1)
    for prm in n.fnParams: dumpAst(prm, src, depth+1)
  of YieldExpr:
    stdout.write(&"{ind}{label}\n")
    if n.yieldArg != nil: dumpAst(n.yieldArg, src, depth+1)
  of AwaitExpr:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.awaitArg, src, depth+1)
  of ArrowFunc:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.arrowBody, src, depth+1)
    for prm in n.arrowParams: dumpAst(prm, src, depth+1)
  of ArrayPattern, ObjectPattern:
    stdout.write(&"{ind}{label}\n")
    for en in n.patEntries: dumpAst(en, src, depth+1)
  of PatternEntry:
    stdout.write(&"{ind}{label}\n")
    if n.patTarget != nil: dumpAst(n.patTarget, src, depth+1)
    if n.patDefault != nil: dumpAst(n.patDefault, src, depth+1)
    if n.patComputedKey != nil: dumpAst(n.patComputedKey, src, depth+1)
  of ClassDecl, ClassExpr:
    stdout.write(&"{ind}{label}\n")
    if n.classParent != nil: dumpAst(n.classParent, src, depth+1)
    for m in n.classMembers: dumpAst(m, src, depth+1)
  of MethodDef:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.methodBody, src, depth+1)
    if n.methodComputedKey != nil: dumpAst(n.methodComputedKey, src, depth+1)
    for prm in n.methodParams: dumpAst(prm, src, depth+1)
  of StaticBlock:
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.staticBlockBody, src, depth+1)
  of ClassField:                                 # (2e-2)
    stdout.write(&"{ind}{label}\n")
    if n.fieldInit != nil: dumpAst(n.fieldInit, src, depth+1)
    if n.fieldComputedKey != nil: dumpAst(n.fieldComputedKey, src, depth+1)
  of ImportCall:                                 # (2f-7) dynamic import(spec)
    stdout.write(&"{ind}{label}\n")
    dumpAst(n.importSpec, src, depth+1)
  else:  # NullExpr/UndefinedExpr/ThisExpr/ImportMetaExpr + BigIntExpr/RegexExpr (label-only "?")
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
