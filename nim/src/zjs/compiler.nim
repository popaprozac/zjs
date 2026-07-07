## Compiler -- Nim port of `src/compiler.zc` (Phase 3, slice 1).
##
## Register-based tree-walking compiler. `compileExpr(node) -> reg` and
## `compileStmt(node)` mirror the Zen-c `compile_expr` / `compile_stmt`.
## High-water-mark register allocator. The compiler only *emits*
## bytecode -- no execution, no GC.
##
## Slice 1 scope: the program prologue (`LoadUndefined r0`), expression
## statements (compile to a temp, `Mov r0 <- temp`), `var` declarations
## (`DefineGlobal temp, slot`), integer / boolean / null / undefined
## literals, and the epilogue (`Return r0`).

import std/unicode
import ast, token
import bytecode

const
  ## User globals start at slot 108 in the disasm: built-ins occupy
  ## 0..107. Nim has no built-ins yet, so we stub the base here. This is
  ## the ONLY runtime-coupled constant in slice 1; revisit when built-ins
  ## land (base becomes a computed count, one place). See the Phase 3 plan.
  USER_GLOBAL_BASE* = 108'u32

type
  Compiler* = object
    src*: string                 ## source text (for identifier slices)
    code*: seq[Inst]
    constants*: seq[Constant]
    nextReg*: uint8              ## high-water-mark allocator cursor
    maxReg*: uint8               ## one-past the highest reg ever allocated
    fixedRegs*: uint8            ## params + locals reservation (r0.. slot)
    lastExprReg*: int            ## -1 if no expression yet; the completion slot
    hadError*: bool
    ## Global interning table: parallel arrays keyed by declaration order.
    ## First distinct name -> USER_GLOBAL_BASE, next -> +1, etc.
    globalNames*: seq[string]
    globalSlots*: seq[uint32]

# --- Register allocator (high-water-mark) ---------------------------

proc allocReg(c: var Compiler): uint8 =
  ## `let r = next_reg; next_reg += 1; if next_reg > max_reg: max_reg =
  ## next_reg; return r`. Returns the reg, THEN increments. max_reg is
  ## the high-water of next_reg (one-past).
  let r = c.nextReg
  if c.nextReg == 255'u8:
    c.hadError = true
  c.nextReg = c.nextReg + 1
  if c.nextReg > c.maxReg: c.maxReg = c.nextReg
  return r

proc releaseReg(c: var Compiler, r: uint8) =
  ## High-water-mark release: only if it's the top reg AND a temp.
  if r + 1 == c.nextReg and r >= c.fixedRegs:
    c.nextReg = c.nextReg - 1

proc resetTemps(c: var Compiler) =
  c.nextReg = c.fixedRegs

# --- Emit -----------------------------------------------------------

proc emit(c: var Compiler, inst: Inst) =
  c.code.add(inst)

# --- Global interning (mirrors ctx_intern_global at USER_GLOBAL_BASE) --

proc internGlobal(c: var Compiler, name: string): uint32 =
  ## Return the slot for `name`, creating a fresh slot at the next base
  ## offset if unseen. Names compare by decoded text; slice 1 has no
  ## `\u` escapes so a plain string compare suffices.
  for i in 0 ..< c.globalNames.len:
    if c.globalNames[i] == name:
      return c.globalSlots[i]
  let slot = USER_GLOBAL_BASE + uint32(c.globalNames.len)
  c.globalNames.add(name)
  c.globalSlots.add(slot)
  return slot

proc slice(c: Compiler, s, e: uint32): string =
  c.src[s.int ..< e.int]

# --- String-literal escape decoding (mirrors decode_string_body) ----
#
# The parser keeps the RAW slice (quotes included, escapes untouched).
# The const value the disasm prints is the DECODED string, so we must
# process escapes here exactly as `decode_string_body` in compiler.zc.
# Covered: line continuations (`\<LF>`, `\<CR>`, `\<CRLF>` -> nothing),
# `\xHH`, `\uHHHH`, `\u{...}` (UTF-8 encoded), the simple escapes
# `\n \t \r \b \f \v \0`, and the literal fallback (`\\ \" \'` and any
# other char -> that char). Malformed `\x`/`\u` fall through to the
# literal-fallback exactly like the C decoder (`\x` with bad hex emits
# `x`). This is the full set the C path covers.

proc hexVal(ch: char): int =
  if ch >= '0' and ch <= '9': int(ch) - int('0')
  elif ch >= 'a' and ch <= 'f': int(ch) - int('a') + 10
  elif ch >= 'A' and ch <= 'F': int(ch) - int('A') + 10
  else: -1

proc decodeStringBody(src: string, rawStart, rawLen: uint32): string =
  result = ""
  var i: uint32 = 0
  while i < rawLen:
    let ch = src[int(rawStart + i)]
    if ch == '\\' and i + 1 < rawLen:
      let nx = src[int(rawStart + i + 1)]
      # \<LineTerminator> — line continuation: produces nothing.
      if nx == '\x0A':                       # LF
        i += 2
        continue
      if nx == '\x0D':                       # CR / CR-LF
        if i + 2 < rawLen and src[int(rawStart + i + 2)] == '\x0A': i += 3
        else: i += 2
        continue
      # \xXX — 2-hex-digit byte.
      if nx == 'x' and i + 3 < rawLen:
        let h1 = hexVal(src[int(rawStart + i + 2)])
        let h2 = hexVal(src[int(rawStart + i + 3)])
        if h1 >= 0 and h2 >= 0:
          result.add(char((h1 shl 4) or h2))
          i += 4
          continue
      # \uXXXX / \u{...} — UTF-8 encode.
      if nx == 'u':
        var cp: uint32 = 0
        var consumed: uint32 = 0
        if i + 2 < rawLen and src[int(rawStart + i + 2)] == '{':
          var p = i + 3
          var valid = true
          while p < rawLen:
            let cc = src[int(rawStart + p)]
            if cc == '}': break
            let d = hexVal(cc)
            if d < 0: valid = false; break
            cp = cp * 16 + uint32(d)
            p += 1
          if valid and p < rawLen and src[int(rawStart + p)] == '}':
            consumed = p - i + 1
        elif i + 5 < rawLen:
          let h1 = hexVal(src[int(rawStart + i + 2)])
          let h2 = hexVal(src[int(rawStart + i + 3)])
          let h3 = hexVal(src[int(rawStart + i + 4)])
          let h4 = hexVal(src[int(rawStart + i + 5)])
          if h1 >= 0 and h2 >= 0 and h3 >= 0 and h4 >= 0:
            cp = uint32((h1 shl 12) or (h2 shl 8) or (h3 shl 4) or h4)
            consumed = 6
        if consumed > 0:
          result.add(toUTF8(Rune(int(cp))))
          i += consumed
          continue
      # Simple escapes + literal fallback.
      let mapped: char =
        case nx
        of 'n': '\x0A'
        of 't': '\x09'
        of 'r': '\x0D'
        of 'b': '\x08'
        of 'f': '\x0C'
        of 'v': '\x0B'
        of '0': '\x00'
        else: nx        # \\ \" \' and anything else: literal
      result.add(mapped)
      i += 2
    else:
      result.add(ch)
      i += 1

# --- Operator token -> Op (mirrors binary_op in compiler.zc) --------
#
# Returns `Halt` as the "unsupported" sentinel, exactly like the C.
proc binaryOp(tk: TokenKind): Op =
  case tk
  of Plus:     Add
  of Minus:    Sub
  of Star:     Mul
  of Slash:    Div
  of Percent:  Mod
  of StarStar: Pow
  of EqEq:     CmpEq
  of BangEq:   CmpNe
  of EqEqEq:   CmpStrictEq
  of BangEqEq: CmpStrictNe
  of Lt:       CmpLt
  of LtEq:     CmpLe
  of Gt:       CmpGt
  of GtEq:     CmpGe
  of Amp:      BitAnd
  of Pipe:     BitOr
  of Caret:    BitXor
  of LtLt:     Shl
  of GtGt:     Shr
  of GtGtGt:   UShr
  else:        Halt

# --- Expressions ----------------------------------------------------

proc compileExpr(c: var Compiler, node: AstNode): uint8 =
  if node == nil:
    return 0
  case node.kind
  of NumberExpr:
    let dst = allocReg(c)
    let v = node.numVal
    let i = int32(v)
    if float64(i) == v and i >= -32768 and i <= 32767:
      emit(c, instAI16(LoadInt, dst, i))
    elif float64(i) == v:
      c.constants.add(Constant(kind: ckInt, i: i))
      emit(c, instAU16(LoadConst, dst, uint16(c.constants.len - 1)))
    else:
      c.constants.add(Constant(kind: ckDouble, d: v))
      emit(c, instAU16(LoadConst, dst, uint16(c.constants.len - 1)))
    return dst
  of BoolExpr:
    let dst = allocReg(c)
    if node.boolVal: emit(c, instA(LoadTrue, dst))
    else:            emit(c, instA(LoadFalse, dst))
    return dst
  of NullExpr:
    let dst = allocReg(c)
    emit(c, instA(LoadNull, dst))
    return dst
  of UndefinedExpr:
    let dst = allocReg(c)
    emit(c, instA(LoadUndefined, dst))
    return dst
  of IdentExpr:
    # Slice 2: script-top identifier reads resolve to globals (no
    # locals/with/capture yet -- those are later slices). Mirrors the
    # `3. Fall through to globals` branch of compile_expr's IdentExpr.
    let name = c.slice(node.start, node.`end`)
    let slot = internGlobal(c, name)
    let dst = allocReg(c)
    emit(c, instAU16(LoadGlobal, dst, uint16(slot)))
    return dst
  of StringExpr:
    # node.start/end include the surrounding quotes. Decode the body to
    # get the const value; the disasm prints the DECODED string.
    let rawStart = node.start + 1
    let rawEnd = if node.`end` > 0: node.`end` - 1 else: node.start + 1
    let rawLen = if rawEnd > rawStart: rawEnd - rawStart else: 0'u32
    let s = decodeStringBody(c.src, rawStart, rawLen)
    c.constants.add(Constant(kind: ckString, s: s))
    let dst = allocReg(c)
    emit(c, instAU16(LoadConst, dst, uint16(c.constants.len - 1)))
    return dst
  of Paren:
    return compileExpr(c, node.inner)
  of Unary:
    # typeof/void/delete/++/-- are later slices -- refuse them so they
    # surface as nim-missing, never a false match.
    case node.unOp
    of Minus, Bang, Tilde:
      discard
    else:
      c.hadError = true
      return 0
    let src = compileExpr(c, node.operand)
    let dst = allocReg(c)
    let op =
      case node.unOp
      of Minus: Neg
      of Bang:  LogicalNot
      else:     BitNot        # Tilde
    emit(c, instABC(op, dst, src, 0))
    return dst
  of Binary:
    let opKind = binaryOp(node.binOp)
    if opKind == Halt:
      # `in`/`instanceof` and any unsupported binary op -- later slices.
      c.hadError = true
      return 0
    # RHS-immediate fusion: `x OP N` where N is an integral literal in
    # [-128, 127] and OP is one of {+,-,<,<=,>,>=}. LHS-immediate does
    # NOT fuse. Mirrors the fused-immediate fast path in compile_expr.
    let fusable =
      opKind in {Add, Sub, CmpLt, CmpLe, CmpGt, CmpGe}
    if fusable and node.rhs != nil and node.rhs.kind == NumberExpr:
      let v = node.rhs.numVal
      let iv = int32(v)
      if float64(iv) == v and iv >= -128 and iv <= 127:
        let fusedOp =
          case opKind
          of Add:   AddImm
          of Sub:   SubImm
          of CmpLt: CmpLtImm
          of CmpLe: CmpLeImm
          of CmpGt: CmpGtImm
          else:     CmpGeImm    # CmpGe
        let src = compileExpr(c, node.lhs)
        let dst = allocReg(c)
        emit(c, instABC(fusedOp, dst, src, uint8(int8(iv))))
        return dst
    let l = compileExpr(c, node.lhs)
    let r = compileExpr(c, node.rhs)
    let dst = allocReg(c)
    emit(c, instABC(opKind, dst, l, r))
    return dst
  else:
    # Not yet supported.
    c.hadError = true
    return 0

# --- Statements -----------------------------------------------------

proc compileVarDecl(c: var Compiler, node: AstNode) =
  ## Slice 1: script-top `var x = <e>` -> DefineGlobal. `let`/`const`
  ## and destructuring are later slices.
  for decl in node.declarators:
    if decl.kind != Declarator: continue
    if decl.nameLength == 0:
      c.hadError = true; return
    let name = c.slice(decl.nameStart, decl.nameStart + decl.nameLength)
    let slot = internGlobal(c, name)
    if decl.init != nil:
      let r = compileExpr(c, decl.init)
      emit(c, instAU16(DefineGlobal, r, uint16(slot)))
      releaseReg(c, r)
  resetTemps(c)

proc compileStmt(c: var Compiler, node: AstNode) =
  if node == nil: return
  case node.kind
  of VarDecl:
    if node.declKind == KwVar:
      compileVarDecl(c, node)
    else:
      c.hadError = true
  else:
    # Default: an expression statement. At the program top level, Mov
    # the result into the reserved completion slot (lastExprReg).
    let r = compileExpr(c, node)
    if c.lastExprReg >= 0:
      let dst = uint8(c.lastExprReg)
      if r != dst: emit(c, instAB(Mov, dst, r))
    else:
      c.lastExprReg = int(r)
    resetTemps(c)

# --- Program --------------------------------------------------------

proc hoistProgramGlobals(c: var Compiler, root: AstNode) =
  ## Only `var` hoists into the global object (mirrors
  ## hoist_program_decls). Interning here fixes slot order to match
  ## declaration order, independent of when the DefineGlobal emits.
  if root == nil: return
  for stmt in root.stmts:
    if stmt != nil and stmt.kind == VarDecl and stmt.declKind == KwVar:
      for decl in stmt.declarators:
        if decl.kind == Declarator and decl.nameLength > 0:
          discard internGlobal(c, c.slice(decl.nameStart, decl.nameStart + decl.nameLength))

proc compileProgram*(src: string, root: AstNode): Function =
  ## Compile the top-level program. Mirrors compile_program: reserve r0
  ## as the completion slot, `LoadUndefined r0`, fixed_regs = 1, then the
  ## statements, then `Return r0`.
  var c = Compiler(
    src: src,
    nextReg: 0,
    maxReg: 0,
    fixedRegs: 0,
    lastExprReg: -1,
    hadError: false,
  )

  # Reserve the program-result register.
  let resultReg = allocReg(c)
  emit(c, instA(LoadUndefined, resultReg))
  c.fixedRegs = resultReg + 1
  c.lastExprReg = int(resultReg)

  if root != nil and root.kind == Program:
    hoistProgramGlobals(c, root)
    for stmt in root.stmts:
      if c.hadError: break
      compileStmt(c, stmt)
  else:
    c.hadError = true

  emit(c, instA(Return, resultReg))

  if c.hadError:
    return nil

  var f = Function(
    code: c.code,
    constants: c.constants,
    registerCount: uint32(c.maxReg) + 1'u32,
    fixedRegs: uint32(c.fixedRegs),
    paramCount: 0,
    constCount: uint32(c.constants.len),
    icCount: 0,
  )
  if f.registerCount == 0: f.registerCount = 1
  if f.fixedRegs > f.registerCount: f.fixedRegs = f.registerCount
  # Attach the global-name side table so disasm can print `; <name>`.
  for i in 0 ..< c.globalNames.len:
    f.globalNames.add(GlobalName(slot: c.globalSlots[i], name: c.globalNames[i]))
  return f
