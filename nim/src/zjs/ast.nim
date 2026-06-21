## AST -- object variant (Phase 2b). Discriminant = full NodeKind (names mirror
## src/ast.zc). of-branches grouped by shape; SEMANTIC field names; globally
## unique (Nim requires it); Nim-managed (ref + seq + arc -- host-side data).

import token

type
  NodeKind* = enum
    # Root
    Program,
    # Atoms
    NumberExpr,
    BigIntExpr,
    StringExpr,
    TemplateExpr,
    TemplatePartExpr,
    TaggedTemplate,
    BoolExpr,
    NullExpr,
    UndefinedExpr,
    HoleExpr,
    ThisExpr,
    IdentExpr,
    RegexExpr,
    # Operators
    Binary,
    Logical,
    Unary,
    Postfix,
    Conditional,
    Assignment,
    # Access
    Call,
    OptionalCall,
    New,
    Member,
    OptionalMember,
    Computed,
    OptionalComputed,
    # Aggregates
    Sequence,
    Array,
    Object,
    ObjectProp,
    Paren,
    # Statements
    BlockStmt,
    VarDecl,
    Declarator,
    IfStmt,
    ReturnStmt,
    WhileStmt,
    DoWhileStmt,
    WithStmt,
    ForStmt,
    BreakStmt,
    ContinueStmt,
    EmptyStmt,
    LabeledStmt,
    # Functions + iteration
    FunctionDecl,
    FunctionExpr,
    ArrowFunc,
    ForInStmt,
    ForOfStmt,
    # Exceptions
    ThrowStmt,
    TryStmt,
    # Classes
    ClassDecl,
    ClassExpr,
    MethodDef,
    SuperExpr,
    SuperCall,
    # Function-parameter shapes
    RestParam,
    Spread,
    # async/await
    AwaitExpr,
    # Generators
    YieldExpr,
    # Destructuring
    ObjectPattern,
    ArrayPattern,
    PatternEntry,
    # Public class fields
    ClassField,
    # Class static initialization block
    StaticBlock,
    # switch statement
    SwitchStmt,
    SwitchCase,
    # ES modules
    ImportDecl,
    ImportClause,
    ExportDecl,
    ExportClause,
    ImportCall,
    ImportMetaExpr

  AstNode* = ref object
    start*, `end`*: uint32              ## `end` is a Nim keyword -- backtick-escaped
    case kind*: NodeKind
    of NumberExpr: numVal*: float64
    of BoolExpr: boolVal*: bool
    # Leaf nodes: value lives in the source slice start..end, no extra fields
    of StringExpr: discard
    of IdentExpr:
      identDefault*: AstNode        # nil normally; the `= expr` default when used as a param
    of RegexExpr: discard
    of BigIntExpr: discard
    of NullExpr: discard
    of UndefinedExpr: discard
    of ThisExpr: discard
    of Binary, Logical:
      binOp*: TokenKind
      lhs*, rhs*: AstNode
    of Unary, Postfix:
      unOp*: TokenKind
      operand*: AstNode
    of Assignment:
      assignOp*: TokenKind
      target*, value*: AstNode
    of Paren:
      inner*: AstNode
    of VarDecl:
      declKind*: TokenKind              ## KwLet / KwConst / KwVar
      declarators*: seq[AstNode]
    of Declarator:
      nameStart*, nameLength*: uint32
      init*: AstNode                    ## initializer, or nil
    of Program:
      stmts*: seq[AstNode]
    of Member, OptionalMember, Computed, OptionalComputed:
      recv*: AstNode                    # receiver/object (Zen-c `left`)
      propStart*, propLength*: uint32   # Member/OptionalMember: property-name slice (Computed: unused, 0)
      index*: AstNode                   # Computed/OptionalComputed: `[expr]` index (Member: nil)
    of Call, OptionalCall, New:
      callee*: AstNode                  # Zen-c `left`
      args*: seq[AstNode]               # Zen-c `children`
    of Spread:
      spreadArg*: AstNode               # `...expr` inner (Zen-c `left`)
    of Conditional:
      cond*, conseq*, alt*: AstNode     # test ? consequent : alternate
    of Sequence:
      items*: seq[AstNode]
    of Array:
      elems*: seq[AstNode]
    of Object:
      props*: seq[AstNode]
    of ObjectProp:
      keyStart*, keyLength*: uint32   # raw key slice (incl. quotes for strings); 0/0 = computed
      propVal*: AstNode               # the value (shorthand → IdentExpr of the key)
      computedKey*: AstNode           # the `[expr]` key; nil unless computed
    of TemplateExpr:
      tparts*: seq[AstNode]             # alternating TemplatePartExpr / expr
    of TaggedTemplate:
      tag*: AstNode
      tmpl*: AstNode
    of BlockStmt:    stmtList*: seq[AstNode]
    of IfStmt:       ifCond*, thenStmt*, elseStmt*: AstNode    # elseStmt nil if no else
    of WhileStmt:    whileCond*, whileBody*: AstNode
    of DoWhileStmt:  doBody*, doCond*: AstNode
    of ForStmt:      forInit*, forTest*, forUpdate*, forBody*: AstNode  # init/test/update may be nil
    of ReturnStmt:   retArg*: AstNode                          # nil for bare return
    of ThrowStmt:    throwArg*: AstNode
    of LabeledStmt:
      labelStart*, labelLen*: uint32
      labeled*: AstNode
    of ForInStmt, ForOfStmt:
      forBinding*, forIterable*, forInOfBody*: AstNode
    of SwitchStmt:
      switchDisc*: AstNode
      cases*: seq[AstNode]
    of SwitchCase:
      caseTest*: AstNode                 # nil for `default:`
      caseBody*: seq[AstNode]
    of TryStmt:
      tryBlock*, catchBlock*, finallyBlock*: AstNode    # catch/finally nil if absent
      catchParamStart*, catchParamLen*: uint32          # identifier catch param (0/0 = none)
    of WithStmt:
      withObj*, withBody*: AstNode
    of RestParam:
      restArg*: AstNode
    of FunctionDecl, FunctionExpr:
      fnNameStart*, fnNameLen*: uint32
      fnBody*: AstNode
      fnParams*: seq[AstNode]
      fnIsAsync*, fnIsGenerator*: bool
    of YieldExpr:
      yieldArg*: AstNode        # nil for bare `yield`
      yieldDelegate*: bool
    of AwaitExpr:
      awaitArg*: AstNode
    of ArrowFunc:
      arrowBody*: AstNode
      arrowParams*: seq[AstNode]
      arrowIsAsync*: bool
    else: discard                       ## kinds implemented in later increments

proc newProgram*(s, e: uint32, stmts: seq[AstNode] = @[]): AstNode =
  ## Construct a Program node.
  AstNode(kind: Program, start: s, `end`: e, stmts: stmts)

proc newNumber*(s, e: uint32, v: float64): AstNode =
  ## Construct a NumberExpr node.
  AstNode(kind: NumberExpr, start: s, `end`: e, numVal: v)

proc newBool*(s, e: uint32, v: bool): AstNode =
  ## Construct a BoolExpr node.
  AstNode(kind: BoolExpr, start: s, `end`: e, boolVal: v)

proc newLeaf*(kind: NodeKind, s, e: uint32): AstNode =
  ## String/Ident/Regex/BigInt (value = slice) + Null/Undefined/This (nullary).
  AstNode(kind: kind, start: s, `end`: e)

proc newBinary*(kind: NodeKind, s, e: uint32, op: TokenKind, lhs, rhs: AstNode): AstNode =
  ## Construct a Binary or Logical node; kind must be Binary or Logical.
  {.cast(uncheckedAssign).}:
    result = AstNode(kind: kind, start: s, `end`: e, binOp: op, lhs: lhs, rhs: rhs)

proc newUnary*(kind: NodeKind, s, e: uint32, op: TokenKind, operand: AstNode): AstNode =
  ## Construct a Unary or Postfix node; kind must be Unary or Postfix.
  {.cast(uncheckedAssign).}:
    result = AstNode(kind: kind, start: s, `end`: e, unOp: op, operand: operand)

proc newAssignment*(s, e: uint32, op: TokenKind, target, value: AstNode): AstNode =
  ## Construct an Assignment node.
  AstNode(kind: Assignment, start: s, `end`: e, assignOp: op, target: target, value: value)

proc newParen*(s, e: uint32, inner: AstNode): AstNode =
  ## Construct a Paren node.
  AstNode(kind: Paren, start: s, `end`: e, inner: inner)

proc newVarDecl*(s, e: uint32, declKind: TokenKind, declarators: seq[AstNode]): AstNode =
  ## Construct a VarDecl node.
  AstNode(kind: VarDecl, start: s, `end`: e, declKind: declKind, declarators: declarators)

proc newDeclarator*(s, e, nameStart, nameLength: uint32, init: AstNode): AstNode =
  ## Construct a Declarator node; init may be nil (no initializer).
  AstNode(kind: Declarator, start: s, `end`: e,
          nameStart: nameStart, nameLength: nameLength, init: init)

proc newMember*(kind: NodeKind, s, e, propStart, propLength: uint32, recv: AstNode): AstNode =
  ## kind ∈ {Member, OptionalMember}. propStart/propLength are the property name slice.
  {.cast(uncheckedAssign).}:
    result = AstNode(kind: kind, start: s, `end`: e, recv: recv,
                     propStart: propStart, propLength: propLength, index: nil)

proc newComputed*(kind: NodeKind, s, e: uint32, recv, index: AstNode): AstNode =
  ## kind ∈ {Computed, OptionalComputed}
  {.cast(uncheckedAssign).}:
    result = AstNode(kind: kind, start: s, `end`: e, recv: recv,
                     propStart: 0'u32, propLength: 0'u32, index: index)

proc newCall*(kind: NodeKind, s, e: uint32, callee: AstNode, args: seq[AstNode]): AstNode =
  ## kind ∈ {Call, OptionalCall, New}
  {.cast(uncheckedAssign).}:
    result = AstNode(kind: kind, start: s, `end`: e, callee: callee, args: args)

proc newSpread*(s, e: uint32, spreadArg: AstNode): AstNode =
  ## Construct a Spread node.
  AstNode(kind: Spread, start: s, `end`: e, spreadArg: spreadArg)

proc newConditional*(s, e: uint32, cond, conseq, alt: AstNode): AstNode =
  ## Construct a Conditional node (test ? consequent : alternate).
  AstNode(kind: Conditional, start: s, `end`: e, cond: cond, conseq: conseq, alt: alt)

proc newSequence*(s, e: uint32, items: seq[AstNode]): AstNode =
  ## Construct a Sequence node (comma operator).
  AstNode(kind: Sequence, start: s, `end`: e, items: items)

proc newArray*(s, e: uint32, elems: seq[AstNode]): AstNode =
  ## Construct an Array literal node.
  AstNode(kind: Array, start: s, `end`: e, elems: elems)

proc newObject*(s, e: uint32, props: seq[AstNode]): AstNode =
  ## Construct an Object literal node.
  AstNode(kind: Object, start: s, `end`: e, props: props)

proc newObjectProp*(s, e, keyStart, keyLength: uint32, propVal, computedKey: AstNode): AstNode =
  ## Construct an ObjectProp node. computedKey may be nil (non-computed property).
  AstNode(kind: ObjectProp, start: s, `end`: e, keyStart: keyStart,
          keyLength: keyLength, propVal: propVal, computedKey: computedKey)

proc newTemplateExpr*(s, e: uint32, tparts: seq[AstNode]): AstNode =
  ## Construct a TemplateExpr node; tparts alternates TemplatePartExpr / expression.
  AstNode(kind: TemplateExpr, start: s, `end`: e, tparts: tparts)

proc newTaggedTemplate*(s, e: uint32, tag, tmpl: AstNode): AstNode =
  ## Construct a TaggedTemplate node; tmpl must be a TemplateExpr.
  AstNode(kind: TaggedTemplate, start: s, `end`: e, tag: tag, tmpl: tmpl)

proc newBlock*(s, e: uint32, stmtList: seq[AstNode]): AstNode =
  ## Construct a BlockStmt node.
  AstNode(kind: BlockStmt, start: s, `end`: e, stmtList: stmtList)

proc newIf*(s, e: uint32, ifCond, thenStmt, elseStmt: AstNode): AstNode =
  ## Construct an IfStmt node; elseStmt may be nil.
  AstNode(kind: IfStmt, start: s, `end`: e, ifCond: ifCond, thenStmt: thenStmt, elseStmt: elseStmt)

proc newWhile*(s, e: uint32, whileCond, whileBody: AstNode): AstNode =
  ## Construct a WhileStmt node.
  AstNode(kind: WhileStmt, start: s, `end`: e, whileCond: whileCond, whileBody: whileBody)

proc newDoWhile*(s, e: uint32, doBody, doCond: AstNode): AstNode =
  ## Construct a DoWhileStmt node; body comes before condition.
  AstNode(kind: DoWhileStmt, start: s, `end`: e, doBody: doBody, doCond: doCond)

proc newFor*(s, e: uint32, forInit, forTest, forUpdate, forBody: AstNode): AstNode =
  ## Construct a ForStmt node; forInit/forTest/forUpdate may be nil.
  AstNode(kind: ForStmt, start: s, `end`: e, forInit: forInit, forTest: forTest,
          forUpdate: forUpdate, forBody: forBody)

proc newReturn*(s, e: uint32, retArg: AstNode): AstNode =
  ## Construct a ReturnStmt node; retArg may be nil for bare `return;`.
  AstNode(kind: ReturnStmt, start: s, `end`: e, retArg: retArg)

proc newThrow*(s, e: uint32, throwArg: AstNode): AstNode =
  ## Construct a ThrowStmt node.
  AstNode(kind: ThrowStmt, start: s, `end`: e, throwArg: throwArg)

proc newLabeled*(s, e, labelStart, labelLen: uint32, labeled: AstNode): AstNode =
  ## Construct a LabeledStmt node; labelStart/labelLen are the label identifier slice.
  AstNode(kind: LabeledStmt, start: s, `end`: e, labelStart: labelStart, labelLen: labelLen, labeled: labeled)

proc newForInOf*(kind: NodeKind, s, e: uint32, binding, iterable, body: AstNode): AstNode =
  ## kind ∈ {ForInStmt, ForOfStmt}
  {.cast(uncheckedAssign).}:
    result = AstNode(kind: kind, start: s, `end`: e,
                     forBinding: binding, forIterable: iterable, forInOfBody: body)

proc newSwitch*(s, e: uint32, disc: AstNode, cases: seq[AstNode]): AstNode =
  ## Construct a SwitchStmt node.
  AstNode(kind: SwitchStmt, start: s, `end`: e, switchDisc: disc, cases: cases)

proc newSwitchCase*(s, e: uint32, test: AstNode, body: seq[AstNode]): AstNode =
  ## Construct a SwitchCase node; test is nil for `default:`.
  AstNode(kind: SwitchCase, start: s, `end`: e, caseTest: test, caseBody: body)

proc newTry*(s, e: uint32, tryBlock, catchBlock, finallyBlock: AstNode,
             catchParamStart, catchParamLen: uint32): AstNode =
  ## Construct a TryStmt node; catchBlock/finallyBlock may be nil if absent.
  AstNode(kind: TryStmt, start: s, `end`: e, tryBlock: tryBlock, catchBlock: catchBlock,
          finallyBlock: finallyBlock, catchParamStart: catchParamStart, catchParamLen: catchParamLen)

proc newWith*(s, e: uint32, obj, body: AstNode): AstNode =
  ## Construct a WithStmt node.
  AstNode(kind: WithStmt, start: s, `end`: e, withObj: obj, withBody: body)

proc newRestParam*(s, e: uint32, restArg: AstNode): AstNode =
  ## Construct a RestParam node (`...ident` in a parameter list).
  AstNode(kind: RestParam, start: s, `end`: e, restArg: restArg)

proc newFunctionDecl*(s, e, nameStart, nameLen: uint32, body: AstNode, params: seq[AstNode],
                      isAsync = false, isGenerator = false): AstNode =
  ## Construct a FunctionDecl node.
  AstNode(kind: FunctionDecl, start: s, `end`: e, fnNameStart: nameStart, fnNameLen: nameLen,
          fnBody: body, fnParams: params, fnIsAsync: isAsync, fnIsGenerator: isGenerator)

proc newFunctionExpr*(s, e, nameStart, nameLen: uint32, body: AstNode, params: seq[AstNode],
                      isAsync = false, isGenerator = false): AstNode =
  ## Construct a FunctionExpr node; nameLen=0 means anonymous.
  AstNode(kind: FunctionExpr, start: s, `end`: e, fnNameStart: nameStart, fnNameLen: nameLen,
          fnBody: body, fnParams: params, fnIsAsync: isAsync, fnIsGenerator: isGenerator)

proc newYield*(s, e: uint32, arg: AstNode, delegate: bool): AstNode =
  ## Construct a YieldExpr node; arg is nil for bare `yield`.
  AstNode(kind: YieldExpr, start: s, `end`: e, yieldArg: arg, yieldDelegate: delegate)

proc newAwait*(s, e: uint32, arg: AstNode): AstNode =
  ## Construct an AwaitExpr node.
  AstNode(kind: AwaitExpr, start: s, `end`: e, awaitArg: arg)

proc newArrow*(s, e: uint32, body: AstNode, params: seq[AstNode], isAsync: bool): AstNode =
  ## Construct an ArrowFunc node.
  AstNode(kind: ArrowFunc, start: s, `end`: e, arrowBody: body, arrowParams: params, arrowIsAsync: isAsync)
