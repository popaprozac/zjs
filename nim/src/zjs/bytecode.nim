## Bytecode types -- Nim port of `src/bytecode.zc` (Phase 3, slice 1).
##
## Uniform 4-byte instruction: { op:Op; a,b,c: uint8 }. Operands are
## reinterpreted per opcode. `bcU16 = b | (c<<8)`; `bcI16` is the
## sign-extended 16-bit form.
##
## One `Function` per compiled unit (the top-level program is also a
## Function). It owns its bytecode, its constant pool, and its register
## count. No execution, no GC -- the compiler only emits.

type
  ## Op enum -- mirrors the Op enum order in `src/bytecode.zc` EXACTLY.
  ## Ordinals matter for AOT / the interpreter; the disasm uses names,
  ## which come from a positional table (interpreter.zc `zjs_op_names`)
  ## verified aligned with this order (145 ops).
  Op* = enum
    Halt
    # Loads & moves
    LoadConst
    LoadInt
    LoadUndefined
    LoadHole
    ThrowIfHole
    LoadNull
    LoadTrue
    LoadFalse
    Mov
    # Globals
    DefineGlobal
    LoadGlobal
    StoreGlobal
    LoadGlobalOrUndefined
    # `with`
    WithEnter
    WithLeave
    WithLookup
    # Binary arithmetic
    Add
    Sub
    Mul
    Div
    Mod
    Pow
    # Fused arithmetic-with-immediate
    AddImm
    SubImm
    # Fused comparison-with-immediate
    CmpLtImm
    CmpLeImm
    CmpGtImm
    CmpGeImm
    BitAnd
    BitOr
    BitXor
    Shl
    Shr
    UShr
    # Comparison
    CmpEq
    CmpNe
    CmpStrictEq
    CmpStrictNe
    CmpLt
    CmpLe
    CmpGt
    CmpGe
    # Unary
    Neg
    BitNot
    LogicalNot
    # Control flow
    Jmp
    JmpIfTrue
    JmpIfFalse
    JmpIfNotNullish
    JmpIfNullish
    # Fused compare-and-branch (branch when comparison is false)
    JmpIfNotLt
    JmpIfNotLe
    JmpIfNotGt
    JmpIfNotGe
    JmpIfNotLtImm
    JmpIfNotLeImm
    JmpIfNotGtImm
    JmpIfNotGeImm
    JmpIfNotEq
    JmpIfNotNe
    JmpIfNotStrictEq
    JmpIfNotStrictNe
    # Return
    Return
    # Calls
    Invoke
    TailInvoke
    # Inline-cached property access
    LoadProp
    StoreProp
    # Specialized built-in calls
    MathSqrt
    MathAbs
    MathFloor
    MathCeil
    # Iteration setup
    IterPrepare
    ArrayLength
    DeleteElem
    BuildArguments
    BuildRestArgs
    # ES modules
    ImportBind
    ExportBind
    DynamicImport
    ImportMeta
    # async / await
    Await
    # Generators
    Yield
    GeneratorStart
    TemplateObject
    # Spread support
    ArrayPush
    ArraySpread
    ObjectSpread
    ArrayRestFrom
    AssertCoercible
    # Live iterator protocol
    IterGet
    IterGetAsync
    IterStep
    IterRestCollect
    IterClose
    IterNextRaw
    # Variadic-call dispatch
    SpreadInvoke
    SpreadMethodInvoke
    SpreadNewInvoke
    # Method calls
    MethodInvoke
    TailMethodInvoke
    # Closures / accessors
    DefineGetter
    DefineSetter
    DefineMethodGetter
    DefineMethodSetter
    MakeClosure
    LoadEnv
    LoadCallee
    # Heap-cell creation + access
    NewRegex
    NewRegexR
    NewObject
    NewArray
    LoadElem
    StoreElem
    # Exceptions
    Throw
    EnterTry
    LeaveTry
    # Prototype chain + new
    In
    Instanceof
    LoadThis
    LoadNewTarget
    NewInvoke
    # Type introspection
    Typeof
    # Class machinery
    SetProto
    SuperCall
    DefineMethod
    DefineMethodComputed
    SetParentCtor
    SetFunctionName
    InitObjData
    SpreadSuperCall
    # Inverse-polarity fused compare-and-branch (branch when true)
    JmpIfLt
    JmpIfLe
    JmpIfGt
    JmpIfGe
    JmpIfLtImm
    JmpIfLeImm
    JmpIfGtImm
    JmpIfGeImm
    # Fused global-callee call
    InvokeGlobal
    # Private-element brand check
    PrivateCheck
    # Compile-time-provable TypeError throw
    ThrowTypeError
    # strict-mode global store
    StoreGlobalStrict
    # IteratorClose with a THROW completion
    IterCloseQuiet
    # generator return-completion dispatch
    JmpIfNotGenReturn

  Inst* = object
    op*: Op
    a*, b*, c*: uint8

  ## Constant-pool entry. Slice 1 never populates the pool, but the
  ## kinds mirror what `disasm_function` distinguishes (int / double /
  ## string / function).
  ConstKind* = enum
    ckInt
    ckDouble
    ckString
    ckFunction

  Constant* = object
    case kind*: ConstKind
    of ckInt:      i*: int32
    of ckDouble:   d*: float64
    of ckString:   s*: string
    of ckFunction: fn*: Function

  ## Side table paralleling the runtime globals[] array: index = global
  ## slot, value = the declared global's name. Slots below
  ## USER_GLOBAL_BASE (the built-ins) are unnamed in this Nim build.
  GlobalName* = object
    slot*: uint32
    name*: string

  Function* = ref object
    code*: seq[Inst]
    constants*: seq[Constant]
    registerCount*: uint32
    fixedRegs*: uint32
    paramCount*: uint32
    ## ECMA-262 ExpectedArgumentCount (Function.length backing): the index
    ## of the first param with a default initializer or the rest param, or
    ## paramCount if none (mirrors compiler.zc `Function.expected_arg_count`,
    ## src ~4407-4419). NOT printed by disasm; set for later runtime phases.
    expectedArgCount*: uint32
    constCount*: uint32
    icCount*: uint32
    isAsync*: bool
    isGenerator*: bool
    isArrow*: bool
    isClassCtor*: bool
    ## Default derived constructor: a class `extends Parent` with NO explicit
    ## constructor. Its body is the minimal `LoadCallee; LoadUndefined;
    ## Return` — the runtime performs the implicit `super(...args)`. Set by
    ## the class-value codegen (compiler.zc `is_default_derived_ctor`,
    ## ~5111-5113). NOT printed by disasm (no header text), so it doesn't
    ## affect the byte-for-byte oracle; carried for later runtime phases.
    isDefaultDerivedCtor*: bool
    ## Repurposed exactly as compiler.zc's `Function.needs_env` (slice
    ## 4b): "this function body references at least one OUTER-scope name"
    ## (i.e. the compiler's `has_outer_refs`), NOT "this function has its
    ## own env object". The ENCLOSING compiler reads this at the
    ## MakeClosure emit site to decide whether to wrap the child in an
    ## env-capturing MakeClosure (needsEnv/arrow) or the in-place
    ## no-capture form. See compile.zc ~4454.
    needsEnv*: bool
    ## The register the VM seeds with `this` on frame entry, or -1 if the
    ## body never references `this` (mirrors the compiler's `c.this_reg`;
    ## interpreter.zc seeds regs[this_reg] from the receiver — "No prologue
    ## Op::LoadThis"). The compiler reserves it AFTER params; the VM's
    ## MethodInvoke passes the receiver as `this`, a plain call passes
    ## undefined. Default -1 = no this reg (e.g. the top-level program).
    thisReg*: int
    ## Names for the global slots this function references, so disasm can
    ## print `; <name>` for the global ops. Keyed by slot number.
    globalNames*: seq[GlobalName]
    ## Inline-cache name table (mirrors `Function.ics` in bytecode.zc).
    ## Index = IC slot; value = the property NAME the slot caches. LoadProp
    ## reads `ics[c]`, StoreProp reads `ics[b]` (see nim_disasm). Built by
    ## the compiler's allocIcSlot; icCount == ics.len.
    ics*: seq[string]

# --- Operand encode / decode ----------------------------------------

proc instBcU16*(i: Inst): uint16 {.inline.} =
  ## bc = b | (c << 8)
  uint16(i.b) or (uint16(i.c) shl 8)

proc instBcI16*(i: Inst): int32 {.inline.} =
  ## Sign-extend the 16-bit operand into a signed int32.
  let v = uint32(i.b) or (uint32(i.c) shl 8)
  if (v and 0x8000'u32) != 0'u32:
    cast[int32](v or 0xffff0000'u32)
  else:
    int32(v)

# --- Inst constructors (mirror make_inst_* in bytecode.zc) ----------

proc instA*(op: Op, a: uint8): Inst {.inline.} =
  Inst(op: op, a: a, b: 0, c: 0)

proc instAB*(op: Op, a, b: uint8): Inst {.inline.} =
  Inst(op: op, a: a, b: b, c: 0)

proc instABC*(op: Op, a, b, c: uint8): Inst {.inline.} =
  Inst(op: op, a: a, b: b, c: c)

proc instAU16*(op: Op, a: uint8, v: uint16): Inst {.inline.} =
  Inst(op: op, a: a, b: uint8(v and 0xff'u16), c: uint8((v shr 8) and 0xff'u16))

proc instAI16*(op: Op, a: uint8, v: int32): Inst {.inline.} =
  let u = uint16(uint32(v) and 0xffff'u32)
  Inst(op: op, a: a, b: uint8(u and 0xff'u16), c: uint8((u shr 8) and 0xff'u16))

proc instU16*(op: Op, v: uint16): Inst {.inline.} =
  Inst(op: op, a: 0, b: uint8(v and 0xff'u16), c: uint8((v shr 8) and 0xff'u16))

proc instI16*(op: Op, v: int32): Inst {.inline.} =
  let u = uint16(uint32(v) and 0xffff'u32)
  Inst(op: op, a: 0, b: uint8(u and 0xff'u16), c: uint8((u shr 8) and 0xff'u16))
