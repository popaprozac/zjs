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
    of IdentExpr: discard
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
