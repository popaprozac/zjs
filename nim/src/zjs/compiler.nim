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
  GlobalTable* = ref object
    ## The program-wide global-name interning namespace. ONE table is
    ## shared by the top-level program compiler AND every nested-function
    ## child compiler (mirrors compiler.zc's single `ctx.realm.globals`),
    ## so a global read inside a function body (`function f(){ return a }`)
    ## interns into the SAME slot sequence as the program's own globals.
    ## Without sharing, the child's `a` would restart at slot 108 and the
    ## disasm slot numbers would diverge from the oracle.
    names*: seq[string]
    slots*: seq[uint32]

  Local* = object
    ## One lexical binding (mirrors `struct Local` in src/compiler.zc).
    ## Slice 3a only needs name/reg/scope + const/tdz flags for
    ## script-scope let/const at the top level; captured/env-spill and
    ## the full TDZ machinery arrive with function bodies (slice 4).
    nameStart*:  uint32
    nameLength*: uint32
    reg*:        uint8
    scopeId*:    uint32
    name*:       string          ## decoded name text (atom-equivalent compare)
    isConst*:    bool
    isTdz*:      bool
    isParam*:    bool            ## true for a formal parameter (slice 4a)

  LoopFrame* = object
    ## One iteration-loop context (mirrors `struct LoopFrame` in
    ## src/compiler.zc). Pushed on loop entry, popped on exit. Slice 3c
    ## ports the break/continue back-patch machinery for the plain loop
    ## shapes; labels + switch + try-region unwinding arrive later.
    ##   * `continueTarget` — bytecode offset a `continue` jumps to (the
    ##     test-top for a top-tested while, or the update step for a for).
    ##   * `haveContinue` — false until loopSetContinue publishes the
    ##     target; while false, `continue` emits a placeholder recorded
    ##     in continuePatches, patched when the target becomes known.
    ##   * `breakPatches` — indices of placeholder `Jmp`s a `break`
    ##     emitted; patched to the loop end on loop exit.
    continueTarget*:  uint32
    haveContinue*:    bool
    breakPatches*:    seq[int]
    continuePatches*: seq[int]

  Compiler* = object
    src*: string                 ## source text (for identifier slices)
    code*: seq[Inst]
    constants*: seq[Constant]
    nextReg*: uint8              ## high-water-mark allocator cursor
    maxReg*: uint8               ## one-past the highest reg ever allocated
    fixedRegs*: uint8            ## params + locals reservation (r0.. slot)
    lastExprReg*: int            ## -1 if no expression yet; the completion slot
    hadError*: bool
    ## Global interning table: SHARED (ref) across the program compiler
    ## and all nested-function child compilers. First distinct name ->
    ## USER_GLOBAL_BASE, next -> +1, etc.
    globals*: GlobalTable
    # --- Register machinery ported from compiler.zc (slice 3a) ---------
    ## "preferred destination" hint (compiler.zc `preferred_dst`). -1 =
    ## none. allocDst() consumes it, resetting to -1, so a caller that
    ## knows where a result should land (assignment RHS / decl init) gets
    ## the terminal ALU op to write there directly.
    preferredDst*: int
    ## When set, IdentExpr's local-read path may hand back the local's
    ## reg DIRECTLY (Mov-elision) instead of a defensive Mov. Set only by
    ## callers that proved the surrounding expression won't mutate the
    ## read local before its result is consumed (compiler.zc
    ## `borrow_local_ok`).
    borrowLocalOk*: bool
    ## Lexical locals table (script-scope let/const at top level). Grown
    ## in declaration order by collectLocals; each entry owns a fixed reg.
    locals*: seq[Local]
    ## True on the top-level compiler when running a *script* (not a
    ## module). Forces let/const/class to bind to registers while `var`
    ## and FunctionDecls stay on globalThis. Mirrors compiler.zc
    ## `is_function` + `is_script`.
    isFunction*: bool
    isScript*: bool
    ## True ONLY on the top-level program compiler (mirrors compiler.zc
    ## `c.parent == NULL`). Gates the ECMA-262 completion-value machinery
    ## (the `LoadUndefined <result>` resets before if/loops and the
    ## expression-statement Mov-into-result). A nested function has no
    ## completion register: `return` produces its result, so these resets
    ## must NOT fire in a function body. Slice 4a.
    atProgramTop*: bool
    ## Parameter count for a function body (0 for the program). Backs the
    ## Function.paramCount and the function-top hole-seed start index (a
    ## param is never TDZ-seeded — its value arrives from the caller).
    paramCount*: uint32
    # --- Lexical scope tracker (compiler.zc scope_stack / *_scope_id) --
    scopeStack*:  seq[uint32]
    curScopeId*:  uint32
    nextScopeId*: uint32
    # --- Loop context stack for break / continue (compiler.zc) --------
    ## Pushed on entry to a while/do/for, popped on exit. The top frame
    ## owns the pending break/continue back-patches for the innermost
    ## loop. Slice 3c ports the unlabeled-loop subset (labeled break /
    ## continue, switch frames, and try-region unwinding are later).
    loopStack*: seq[LoopFrame]

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

proc allocDst(c: var Compiler): uint8 =
  ## Returns the caller-preferred dst register if one is queued, else a
  ## freshly-allocated temp. Always clears the hint so nested
  ## sub-expressions allocate their own scratch (compiler.zc `alloc_dst`).
  if c.preferredDst >= 0:
    let r = uint8(c.preferredDst)
    c.preferredDst = -1
    return r
  return allocReg(c)

# --- Emit -----------------------------------------------------------

proc emit(c: var Compiler, inst: Inst): int {.discardable.} =
  ## Append an instruction, returning its index (mirrors compiler.zc
  ## `emit`, which returns the slot so callers can back-patch jumps).
  c.code.add(inst)
  return c.code.len - 1

# --- Fused-branch classification + forward-jump patching -------------

proc isFusedBranchOp(op: Op): bool =
  ## The 2-slot compare-and-branch family (op in slot J, i16 offset in
  ## the J+1 carrier). Mirrors compiler.zc `is_fused_branch_op`.
  op in {
    JmpIfNotLt, JmpIfNotLe, JmpIfNotGt, JmpIfNotGe,
    JmpIfNotLtImm, JmpIfNotLeImm, JmpIfNotGtImm, JmpIfNotGeImm,
    JmpIfNotEq, JmpIfNotNe, JmpIfNotStrictEq, JmpIfNotStrictNe,
    JmpIfLt, JmpIfLe, JmpIfGt, JmpIfGe,
    JmpIfLtImm, JmpIfLeImm, JmpIfGtImm, JmpIfGeImm,
  }

proc patchJump(c: var Compiler, jmpIdx: int) =
  ## Back-patch the forward jump/branch at `jmpIdx` so it lands on the
  ## current end-of-code. Offsets are relative to the instruction AFTER
  ## the jump (the interpreter bumps ip then adds the offset). For a
  ## 2-slot fused branch the offset lives in the J+1 CARRIER and the base
  ## is J+2. Mirrors compiler.zc `patch_jump`.
  let here = int32(c.code.len)
  let inst = c.code[jmpIdx]
  if isFusedBranchOp(inst.op):
    let off2 = here - (int32(jmpIdx) + 2)
    let carrier = c.code[jmpIdx + 1]
    c.code[jmpIdx + 1] = instI16(carrier.op, off2)
    return
  let off = here - (int32(jmpIdx) + 1)
  c.code[jmpIdx] = instAI16(inst.op, inst.a, off)

# --- Backward jumps to a KNOWN target (compiler.zc emit_jump_back*) --
#
# Loop back-edges land on a target already emitted, so the offset is
# known at emit time (no back-patch). Base is J+1 -- the interpreter
# bumps ip past the 1-slot jump then adds the offset.

proc emitJumpBack(c: var Compiler, op: Op, targetIdx: uint32) =
  let here = int32(c.code.len)
  let off = int32(targetIdx) - (here + 1)
  emit(c, instI16(op, off))

proc emitJumpBackIf(c: var Compiler, op: Op, src: uint8, targetIdx: uint32) =
  let here = int32(c.code.len)
  let off = int32(targetIdx) - (here + 1)
  emit(c, instAI16(op, src, off))

# --- Loop context stack (compiler.zc loop_push / loop_pop / ...) -----

proc loopPush(c: var Compiler) =
  c.loopStack.add(LoopFrame(
    continueTarget: 0, haveContinue: false,
    breakPatches: @[], continuePatches: @[],
  ))

proc loopPop(c: var Compiler) =
  if c.loopStack.len > 0:
    c.loopStack.setLen(c.loopStack.len - 1)

proc loopSetContinue(c: var Compiler, target: uint32) =
  ## Publish the continue target and patch every continue placeholder
  ## queued before it was known (the ForStmt deferred pattern: `continue`
  ## targets the update step, positioned AFTER the body). Mirrors
  ## compiler.zc loop_set_continue.
  if c.loopStack.len == 0: return
  let top = c.loopStack.len - 1
  c.loopStack[top].continueTarget = target
  c.loopStack[top].haveContinue = true
  for jmpIdx in c.loopStack[top].continuePatches:
    patchJump(c, jmpIdx)

proc loopAddBreak(c: var Compiler, jmpIdx: int) =
  if c.loopStack.len == 0: return
  c.loopStack[c.loopStack.len - 1].breakPatches.add(jmpIdx)

proc loopAddContinuePatch(c: var Compiler, jmpIdx: int) =
  if c.loopStack.len == 0: return
  c.loopStack[c.loopStack.len - 1].continuePatches.add(jmpIdx)

# --- Global interning (mirrors ctx_intern_global at USER_GLOBAL_BASE) --

proc internGlobal(c: var Compiler, name: string): uint32 =
  ## Return the slot for `name` from the SHARED global table, creating a
  ## fresh slot at the next base offset if unseen. Names compare by
  ## decoded text; slice 1 has no `\u` escapes so a plain string compare
  ## suffices.
  let g = c.globals
  for i in 0 ..< g.names.len:
    if g.names[i] == name:
      return g.slots[i]
  let slot = USER_GLOBAL_BASE + uint32(g.names.len)
  g.names.add(name)
  g.slots.add(slot)
  return slot

proc slice(c: Compiler, s, e: uint32): string =
  c.src[s.int ..< e.int]

# --- Lexical scope tracker (mirrors compiler.zc scope_stack) ---------
#
# Both the collect-locals pre-pass and compile walk the AST in the same
# order. Blocks carry a `blockScopeId` assigned once at collect time and
# re-entered by id in compile (enter_scope_reuse) — so `let` inside a
# block resolves to the block's scope in both walks. scope 0 is the
# function/script-top scope; `var` always binds there.

proc enterScope(c: var Compiler) =
  let newId = c.nextScopeId
  c.nextScopeId += 1
  c.scopeStack.add(newId)
  c.curScopeId = newId

proc enterScopeAssign(c: var Compiler, node: AstNode) =
  ## Collect-pass scope entry: issue a fresh id AND record it on the node.
  enterScope(c)
  if node != nil:
    case node.kind
    of BlockStmt: node.blockScopeId = c.curScopeId
    of ForStmt:   node.forScopeId = c.curScopeId
    else: discard

proc enterScopeReuse(c: var Compiler, node: AstNode) =
  ## Compile-pass: re-enter the id assigned at collect time. Falls back
  ## to a fresh id for nodes the collect pass never reached (0 = none).
  let assignedId =
    if node == nil: 0'u32
    elif node.kind == BlockStmt: node.blockScopeId
    elif node.kind == ForStmt: node.forScopeId
    else: 0'u32
  if assignedId == 0:
    enterScope(c)
    return
  c.scopeStack.add(assignedId)
  c.curScopeId = assignedId

proc exitScope(c: var Compiler) =
  if c.scopeStack.len > 1:
    c.scopeStack.setLen(c.scopeStack.len - 1)
    c.curScopeId = c.scopeStack[c.scopeStack.len - 1]

proc resetScopeWalk(c: var Compiler) =
  ## Reset the scope STACK before re-walking. Ids stay assigned on nodes;
  ## nextScopeId stays monotonic so a fresh fallback id can't collide.
  c.scopeStack.setLen(0)
  c.scopeStack.add(0'u32)
  c.curScopeId = 0

proc scopeIdIsActive(c: Compiler, scopeId: uint32): bool =
  for s in c.scopeStack:
    if s == scopeId: return true
  return false

# --- Locals table ---------------------------------------------------

proc addLocalScoped(c: var Compiler, nameStart, nameLength, reg, scopeId: uint32) =
  let nm = if nameLength > 0: c.slice(nameStart, nameStart + nameLength) else: ""
  c.locals.add(Local(
    nameStart: nameStart, nameLength: nameLength,
    reg: uint8(reg), scopeId: scopeId, name: nm,
  ))

proc allocAndAddLocalScoped(c: var Compiler, nameStart, nameLength, scopeId: uint32): uint8 =
  ## Combined alloc-and-register (compiler.zc alloc_and_add_local_scoped).
  ## Slice 3a omits env-spill: script-scope locals never approach the
  ## 192-reg watermark. Returns the register.
  let reg = allocReg(c)
  addLocalScoped(c, nameStart, nameLength, uint32(reg), scopeId)
  return reg

proc findLocalIndex(c: Compiler, name: string): int =
  ## Index in c.locals, or -1. Walks top-down so a more recent binding
  ## shadows an earlier same-name one; skips entries whose scope is no
  ## longer active (that's how a block-scoped `let` stops shadowing once
  ## the block exits). Compares by decoded name text.
  var i = c.locals.len - 1
  while i >= 0:
    if c.locals[i].name == name and scopeIdIsActive(c, c.locals[i].scopeId):
      return i
    dec i
  return -1

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

# --- Simple-pure predicate + terminal placement (compiler.zc) -------

proc exprIsSimplePure(n: AstNode): bool =
  ## "This subtree has no observable writes / calls / coercions that
  ## could mutate a sibling local" (compiler.zc expr_is_simple_pure).
  ## Conservative; gates borrow_local_ok.
  if n == nil: return true
  case n.kind
  of NumberExpr, StringExpr, BoolExpr, NullExpr, UndefinedExpr,
     ThisExpr, IdentExpr:
    return true
  of Member, OptionalMember:
    return exprIsSimplePure(n.recv)
  else:
    return false

proc tryPlaceSimple(c: var Compiler, node: AstNode, slot: uint8): bool =
  ## Terminal placement of a bare-simple read directly into `slot`
  ## (compiler.zc try_place_simple). Handles Paren-wrapped local idents,
  ## `this`, and numeric literals. Returns false when the node isn't a
  ## simple terminal (caller falls back to the preferred-dst path).
  if node == nil: return false
  case node.kind
  of Paren:
    return tryPlaceSimple(c, node.inner, slot)
  of IdentExpr:
    let name = c.slice(node.start, node.`end`)
    let li = findLocalIndex(c, name)
    if li < 0: return false
    if c.locals[li].reg == slot: return true    # already there
    emit(c, instAB(Mov, slot, c.locals[li].reg))
    return true
  of NumberExpr:
    let v = node.numVal
    let iv = int32(v)
    if float64(iv) == v and iv >= -32768 and iv <= 32767:
      emit(c, instAI16(LoadInt, slot, iv))
    elif float64(iv) == v:
      c.constants.add(Constant(kind: ckInt, i: iv))
      emit(c, instAU16(LoadConst, slot, uint16(c.constants.len - 1)))
    else:
      c.constants.add(Constant(kind: ckDouble, d: v))
      emit(c, instAU16(LoadConst, slot, uint16(c.constants.len - 1)))
    return true
  else:
    return false

# --- Collect-locals pre-pass (mirrors compiler.zc collect_locals) ----
#
# Pre-allocates a fixed register for every script-scope let/const (in
# declaration order) BEFORE the completion slot is reserved, so locals
# take the low regs. Only handles the node shapes slice 3a compiles:
# BlockStmt (fresh scope) and VarDecl (let/const → local, var → skipped
# at script top). var/function/class-global bindings are handled by the
# existing global path.

proc collectLocals(c: var Compiler, node: AstNode) =
  if node == nil: return
  case node.kind
  of VarDecl:
    let isVarKind = node.declKind == KwVar
    # Script-top `var x` stays on globalThis; let/const become locals.
    if c.isScript and isVarKind: return
    let scopeId = if isVarKind: 0'u32 else: c.curScopeId
    for decl in node.declarators:
      if decl.kind != Declarator: continue
      if decl.nameLength > 0:
        discard allocAndAddLocalScoped(c, decl.nameStart, decl.nameLength, scopeId)
        if not isVarKind: c.locals[c.locals.len - 1].isTdz = true
        if node.declKind == KwConst: c.locals[c.locals.len - 1].isConst = true
  of FunctionDecl:
    # Script-top FunctionDecl creates a globalThis property, NOT a
    # script-scope lexical binding (handled by the global emit path).
    # A function/module body registers the function-name local so
    # sibling statements resolve it (mirrors compiler.zc collect_locals'
    # FunctionDecl arm). The body has its own scope — don't recurse.
    if c.isFunction and not c.isScript and node.fnNameLen > 0:
      discard allocAndAddLocalScoped(c, node.fnNameStart, node.fnNameLen, 0'u32)
  of BlockStmt:
    enterScopeAssign(c, node)
    for s in node.stmtList:
      collectLocals(c, s)
    exitScope(c)
  of IfStmt:
    # The then/else statements may introduce their own block scopes with
    # let/const locals — recurse so those get pre-allocated registers,
    # matching the collect walk order (compiler.zc collect_locals).
    collectLocals(c, node.thenStmt)
    collectLocals(c, node.elseStmt)
  of WhileStmt:
    collectLocals(c, node.whileBody)
  of DoWhileStmt:
    collectLocals(c, node.doBody)
  of ForStmt:
    # The for-statement owns a fresh scope so its init `let`/`const`
    # (and any let/const in the body) don't leak past the loop. Enter it
    # at collect time (recording the id on the ForStmt node) and re-enter
    # by id in compile -- matching compiler.zc's enter_scope_assign /
    # enter_scope_reuse for ForStmt.
    enterScopeAssign(c, node)
    collectLocals(c, node.forInit)
    collectLocals(c, node.forBody)
    exitScope(c)
  of Program:
    for s in node.stmts:
      collectLocals(c, s)
  else:
    discard

# --- Function shape gate + capture pre-scan (slice 4a) --------------
#
# Slice 4a compiles ONLY non-capturing functions with simple (plain
# ident) params. Anything outside that envelope must set hadError so
# the file surfaces as nim_missing (never a false byte-match): default
# / pattern / rest params, async / generator, `arguments` / `this`
# usage, and — the big one — a nested function that CAPTURES one of
# this function's locals (needs an env object: slice 4b). Non-capturing
# nested functions are fine and compile independently.

proc paramsAreSimple(params: seq[AstNode]): bool =
  ## Every formal is a plain identifier: no default (`=`), no binding
  ## pattern (`{}`/`[]`), no rest (`...`). Mirrors the parser's
  ## paramsAreSimple but also rejects rest (a RestParam node).
  for prm in params:
    if prm == nil: return false
    if prm.kind != IdentExpr: return false            # RestParam / pattern
    if prm.identDefault != nil: return false          # `a = 1`
    if prm.identPattern != nil: return false          # `{a}` / `[a]`
  return true

proc identName(c: Compiler, n: AstNode): string =
  ## Source slice for a bare IdentExpr (its declared/referenced name).
  c.slice(n.start, n.`end`)

proc subtreeMentionsName(c: Compiler, n: AstNode, name: string): bool =
  ## Does any IdentExpr in this subtree reference `name`? Conservative
  ## (a shadowed inner binding of the same name is a false positive,
  ## which just makes us bail — safe). Descends nested function bodies:
  ## a capture from an inner closure is exactly what we must detect.
  if n == nil: return false
  if n.kind == IdentExpr:
    return c.identName(n) == name
  for ch in childNodes(n):
    if subtreeMentionsName(c, ch, name): return true
  return false

proc bodyReferencesAnyLocal(c: Compiler, body: AstNode, names: seq[string]): bool =
  ## True if the function `body` (its statements) mentions any name in
  ## `names` (the enclosing function's params + lexicals). Used as the
  ## capture bail: a non-empty match means an env object would be
  ## required (slice 4b), so we refuse to compile the outer function.
  if body == nil: return false
  for nm in names:
    if subtreeMentionsName(c, body, nm): return true
  return false

proc blockNeedsEntryHole(c: Compiler, blk: AstNode, name: string): bool =
  ## #387: must this block seed the TDZ hole for `name` at entry?
  ## Source-order scan of the block's DIRECT children (a block's own
  ## let/const declarations are always direct children):
  ##   * hit the simple named declarator first -> decl runs before any
  ##     read -> hole is dead -> false;
  ##   * hit any mention of the name first -> a pre-decl read may observe
  ##     the slot -> true;
  ##   * declarator not found as a simple name -> true (conservative).
  ## Mirrors compiler.zc block_needs_entry_hole EXACTLY.
  for stmt in blk.stmtList:
    if stmt != nil and stmt.kind == VarDecl and
       (stmt.declKind == KwLet or stmt.declKind == KwConst):
      for d in stmt.declarators:
        if d.kind == Declarator:
          if d.nameLength > 0 and
             c.slice(d.nameStart, d.nameStart + d.nameLength) == name:
            return false        # declaration reached before any read
          # Earlier declarator's initializer / pattern may read it.
          if subtreeMentionsName(c, d, name): return true
    elif subtreeMentionsName(c, stmt, name):
      return true
  return true                   # decl not found as a simple declarator

# Forward decls: the recursive body compile calls compileStmt, and the
# nested-function shape gate below calls compileFunctionValue.
proc compileStmt(c: var Compiler, node: AstNode)
proc compileFunction(src: string, node: AstNode, enclosing: var Compiler): Function

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
    let name = c.slice(node.start, node.`end`)
    # 1. Try our own locals first (script-scope let/const).
    let localIdx = findLocalIndex(c, name)
    if localIdx >= 0:
      # Non-captured local — hand back the local's reg directly when
      # borrowLocalOk is set (the caller proved the surrounding
      # expression won't mutate this local before its result is
      # consumed). Otherwise emit a defensive Mov.
      if c.borrowLocalOk:
        return c.locals[localIdx].reg
      # NOTE (#395): deliberately allocReg, NOT allocDst — an
      # operand-position defensive read stealing a live hint writes the
      # hint target before later reads of it in the same expression.
      let dst = allocReg(c)
      emit(c, instAB(Mov, dst, c.locals[localIdx].reg))
      return dst
    # 3. Fall through to globals (compiler.zc `3. Fall through to
    # globals`). Uses allocDst so a terminal read consumes a queued hint.
    let slot = internGlobal(c, name)
    let dst = allocDst(c)
    emit(c, instAU16(LoadGlobal, dst, uint16(slot)))
    if c.nextReg <= dst: c.nextReg = dst + 1
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
        # Honor caller's preferred dst BEFORE recursing so the LHS read
        # doesn't leak the hint inwards (compiler.zc). borrowLocalOk is
        # set around the LHS read: the RHS is a literal, so the LHS
        # local's reg is safe to hand back and reuse as the dst.
        let savedPd = c.preferredDst
        c.preferredDst = -1
        let savedBorrow = c.borrowLocalOk
        c.borrowLocalOk = true
        let src = compileExpr(c, node.lhs)
        c.borrowLocalOk = savedBorrow
        c.preferredDst = savedPd
        let dst = allocDst(c)
        emit(c, instABC(fusedOp, dst, src, uint8(int8(iv))))
        releaseReg(c, src)
        if c.nextReg <= dst: c.nextReg = dst + 1
        return dst
    # Borrow optimization: if the RHS is side-effect-free we can hand
    # back LHS's local reg directly. Then the LHS read may also borrow if
    # its operands are pure, so set the flag around both reads. Mirrors
    # compile_expr's general Binary path exactly.
    let rhsPure = exprIsSimplePure(node.rhs)
    let lhsPure = exprIsSimplePure(node.lhs)
    let savedPd = c.preferredDst
    c.preferredDst = -1
    let savedBorrow = c.borrowLocalOk
    if rhsPure: c.borrowLocalOk = true
    let l = compileExpr(c, node.lhs)
    if not rhsPure: c.borrowLocalOk = savedBorrow
    if lhsPure: c.borrowLocalOk = true
    let r = compileExpr(c, node.rhs)
    c.borrowLocalOk = savedBorrow
    c.preferredDst = savedPd
    let dst = allocDst(c)
    emit(c, instABC(opKind, dst, l, r))
    releaseReg(c, r)
    releaseReg(c, l)
    if c.nextReg <= dst: c.nextReg = dst + 1
    return dst
  of Assignment:
    # Slice 3a: only plain `=` to a script-scope local target. Member /
    # global / compound / destructuring assignment are later slices --
    # refuse them so they surface as nim-missing, never a false match.
    let target = node.target
    if target == nil or target.kind != IdentExpr or node.assignOp != Eq:
      c.hadError = true
      return 0
    let name = c.slice(target.start, target.`end`)
    let localIdx = findLocalIndex(c, name)
    if localIdx < 0:
      # Global target (non-strict): compile the RHS to a fresh temp, then
      # StoreGlobal. compiler.zc pins preferred_dst = -1 for globals (the
      # store reads the temp), so the RHS never takes a caller hint.
      # Strict-mode StoreGlobalStrict / with-object PutValue are later.
      let slot = internGlobal(c, name)
      let savedPd = c.preferredDst
      c.preferredDst = -1
      let r = compileExpr(c, node.value)
      c.preferredDst = savedPd
      emit(c, instAU16(StoreGlobal, r, uint16(slot)))
      return r
    let localReg = c.locals[localIdx].reg
    # const bindings reject all later assignments (TypeError) -- later
    # slice; refuse for now so we don't emit an unguarded store.
    if c.locals[localIdx].isConst:
      c.hadError = true
      return 0
    # For a local target, hand the RHS a preferred-dst hint so the final
    # ALU op writes straight into localReg -- skips the tail Mov on
    # `local = expr`. #395: bare-simple RHS (local ident / number) is a
    # terminal read -- place it directly, skipping both the defensive
    # temp and the tail Mov.
    let savedPd = c.preferredDst
    if tryPlaceSimple(c, node.value, localReg):
      c.preferredDst = savedPd
      return localReg
    c.preferredDst = int(localReg)
    let r = compileExpr(c, node.value)
    c.preferredDst = savedPd
    if r != localReg:
      # RHS didn't take our hint (e.g. it was a bare ident returning a
      # borrowed reg) -- fall back to Mov.
      emit(c, instAB(Mov, localReg, r))
    return r
  of FunctionExpr, ArrowFunc:
    # Slice 4a: only non-capturing, non-arrow FunctionExpr. ArrowFunc
    # always wraps in MakeClosure (for the `this` snapshot) — deferred
    # to 4b — so refuse it here.
    if node.kind == ArrowFunc:
      c.hadError = true
      return 0
    # compile_function_value: compile the body into a fresh Function,
    # append it to OUR const pool, LoadConst it into a fresh reg. A
    # non-capturing body has needs_env == false, so NO MakeClosure wrap
    # (that's the arrow / captured-env path in 4b). Note: uses allocReg,
    # NOT allocDst — compiler.zc's compile_function_value never consumes
    # a caller's preferred_dst hint, so `let h = function(){}` lands the
    # LoadConst in a fresh temp and Movs into h afterward.
    let f = compileFunction(c.src, node, c)
    if f == nil:
      c.hadError = true
      return allocReg(c)
    c.constants.add(Constant(kind: ckFunction, fn: f))
    let idx = uint16(c.constants.len - 1)
    let dst = allocReg(c)
    emit(c, instAU16(LoadConst, dst, idx))
    return dst
  else:
    # Not yet supported.
    c.hadError = true
    return 0

# --- Fused compare-and-branch (mirrors try_emit_cmp_branch_if_false) -
#
# Try to fuse a comparison condition into a single compare-and-branch
# dispatch (Cmp + JmpIfFalse -> JmpIfNot*). The 2-inst encoding emits the
# fused op then a placeholder carrier for the offset; patchJump fills it
# in. Returns the index of the fused op so the caller can patchJump it,
# or -1 when the cond isn't a fusable comparison (caller falls back to the
# plain compile_expr + JmpIfFalse path). All fused branches jump when the
# comparison is FALSE (i.e. skip the then-branch).

proc tryEmitCmpBranchIfFalse(c: var Compiler, cond: AstNode): int =
  if cond == nil or cond.kind != Binary:
    return -1
  let opKind = binaryOp(cond.binOp)
  let isRelational =
    opKind in {CmpLt, CmpLe, CmpGt, CmpGe}
  let isEquality =
    opKind in {CmpEq, CmpNe, CmpStrictEq, CmpStrictNe}
  if not isRelational and not isEquality:
    return -1
  # Nullish peephole: `x == null`/`x != null`/`x == undefined`/`x !=
  # undefined` (and operand-swapped). Loose-equality against null checks
  # nullishness (null == undefined). Emits single-slot JmpIf(Not)Nullish
  # on the non-literal operand -- drops the LoadNull/LoadUndefined pair.
  if opKind == CmpEq or opKind == CmpNe:
    let lIsNullishLit = cond.lhs != nil and
      (cond.lhs.kind == NullExpr or cond.lhs.kind == UndefinedExpr)
    let rIsNullishLit = cond.rhs != nil and
      (cond.rhs.kind == NullExpr or cond.rhs.kind == UndefinedExpr)
    if lIsNullishLit or rIsNullishLit:
      let target = if rIsNullishLit: cond.lhs else: cond.rhs
      let savedBorrow = c.borrowLocalOk
      c.borrowLocalOk = true
      let src = compileExpr(c, target)
      c.borrowLocalOk = savedBorrow
      # For `x == null` run the body when x IS nullish, so JmpIfNotNullish
      # jumps to else when x is NOT nullish; `x != null` is the inverse.
      let fusedOp = if opKind == CmpEq: JmpIfNotNullish else: JmpIfNullish
      let idx = emit(c, instAI16(fusedOp, src, 0))
      releaseReg(c, src)
      return idx
  # RHS small-int literal fast path: fused JmpIfNot*Imm. Only relational
  # variants have *Imm encodings -- equality with a small int still goes
  # through the reg-reg form.
  if isRelational and cond.rhs != nil and cond.rhs.kind == NumberExpr:
    let v = cond.rhs.numVal
    let iv = int32(v)
    if float64(iv) == v and iv >= -128 and iv <= 127:
      # RHS is a literal -- LHS is safe to borrow.
      let savedBorrow = c.borrowLocalOk
      c.borrowLocalOk = true
      let src = compileExpr(c, cond.lhs)
      c.borrowLocalOk = savedBorrow
      let immByte = uint8(int8(iv))
      let fusedOp =
        case opKind
        of CmpLt: JmpIfNotLtImm
        of CmpLe: JmpIfNotLeImm
        of CmpGt: JmpIfNotGtImm
        else:     JmpIfNotGeImm    # CmpGe
      let idx = emit(c, instABC(fusedOp, src, immByte, 0))
      emit(c, instI16(Jmp, 0))    # placeholder carrier; patchJump fills it
      releaseReg(c, src)
      return idx
  # General reg-reg form: JmpIfNotXx reads both operands before branching
  # -- borrow is always safe.
  let savedBorrow = c.borrowLocalOk
  c.borrowLocalOk = true
  let l = compileExpr(c, cond.lhs)
  let r = compileExpr(c, cond.rhs)
  c.borrowLocalOk = savedBorrow
  let fusedOp =
    case opKind
    of CmpLt:       JmpIfNotLt
    of CmpLe:       JmpIfNotLe
    of CmpGt:       JmpIfNotGt
    of CmpGe:       JmpIfNotGe
    of CmpEq:       JmpIfNotEq
    of CmpNe:       JmpIfNotNe
    of CmpStrictEq: JmpIfNotStrictEq
    else:           JmpIfNotStrictNe    # CmpStrictNe
  let idx = emit(c, instABC(fusedOp, l, r, 0))
  emit(c, instI16(Jmp, 0))              # placeholder carrier
  releaseReg(c, r)
  releaseReg(c, l)
  return idx

# --- Loop-rotation: relational back-edge (compiler.zc) --------------
#
# A loop whose condition is a fusable RELATIONAL compare (< <= > >=) is
# ROTATED to test-at-bottom: the back-edge is a TRUE-polarity fused
# branch (JmpIf{Lt,Le,Gt,Ge}[Imm]) that jumps BACK to the body head
# when the compare holds, and falls through to the loop exit otherwise.
# Slice 3c ports the bare-relational subset; `&&`-chain rotation
# (compiler.zc cond_is_rotatable's Logical arm) is a later slice.

proc condIsRelationalFusible(cond: AstNode): bool =
  ## Mirrors compiler.zc cond_is_relational_fusible: a bare Binary whose
  ## operator is one of the four relationals. Equality is NOT rotatable
  ## (no TRUE-polarity Eq/Ne back-edge op family).
  if cond == nil or cond.kind != Binary: return false
  binaryOp(cond.binOp) in {CmpLt, CmpLe, CmpGt, CmpGe}

proc condIsRotatable(cond: AstNode): bool =
  ## Slice 3c: rotatable iff bare-relational. The compiler.zc `&&`-chain
  ## arm (leading conjuncts exit forward, relational tail branches back)
  ## is deferred -- a plain `a && b` while-condition falls to the
  ## test-at-top path (and if unfusable, to nim-missing).
  condIsRelationalFusible(cond)

proc emitCmpBranchBackIfTrue(c: var Compiler, cond: AstNode, bodyHead: uint32) =
  ## Emit the rotated loop's bottom test: a fused compare that branches
  ## BACK to bodyHead when TRUE (mirrors compiler.zc
  ## emit_cmp_branch_back_if_true). The offset is known at emit time and
  ## baked into the J+1 carrier directly; the branch base is J+2 (the
  ## instruction after the carrier). Caller guarantees the cond is
  ## relational-fusible.
  let opKind = binaryOp(cond.binOp)
  # RHS small-int literal -> JmpIf*Imm.
  if cond.rhs != nil and cond.rhs.kind == NumberExpr:
    let v = cond.rhs.numVal
    let iv = int32(v)
    if float64(iv) == v and iv >= -128 and iv <= 127:
      # RHS is a literal -- LHS is safe to borrow.
      let savedBorrow = c.borrowLocalOk
      c.borrowLocalOk = true
      let src = compileExpr(c, cond.lhs)
      c.borrowLocalOk = savedBorrow
      let immByte = uint8(int8(iv))
      let fusedOp =
        case opKind
        of CmpLt: JmpIfLtImm
        of CmpLe: JmpIfLeImm
        of CmpGt: JmpIfGtImm
        else:     JmpIfGeImm    # CmpGe
      let j = emit(c, instABC(fusedOp, src, immByte, 0))
      let off = int32(bodyHead) - (int32(j) + 2)
      emit(c, instI16(Jmp, off))
      releaseReg(c, src)
      return
  # Reg-reg form -- both operands read before branching, borrow safe.
  let savedBorrow = c.borrowLocalOk
  c.borrowLocalOk = true
  let l = compileExpr(c, cond.lhs)
  let r = compileExpr(c, cond.rhs)
  c.borrowLocalOk = savedBorrow
  let fusedOp =
    case opKind
    of CmpLt: JmpIfLt
    of CmpLe: JmpIfLe
    of CmpGt: JmpIfGt
    else:     JmpIfGe          # CmpGe
  let j = emit(c, instABC(fusedOp, l, r, 0))
  let off = int32(bodyHead) - (int32(j) + 2)
  emit(c, instI16(Jmp, off))
  releaseReg(c, r)
  releaseReg(c, l)

# --- Name inference (ECMA-262 NamedEvaluation / SetFunctionName) ----

proc maybeInferAnonName(c: var Compiler, initExpr: AstNode, valReg: uint8,
                        targetName: string) =
  ## If `initExpr` is an ANONYMOUS function-ish value bound to a named
  ## target, emit the SetFunctionName step: LoadConst <name> into a
  ## fresh reg, then `SetFunctionName valReg, nameReg`. Peels through
  ## Paren (`(function(){})`) but not Sequence/Assignment. Named
  ## function expressions (`function f(){}` as expr) already have a name
  ## and are skipped. Mirrors compiler.zc maybe_infer_anon_name (the
  ## FunctionExpr/ArrowFunc/ClassExpr-anon arms; 4a only reaches the
  ## anonymous-FunctionExpr case).
  if initExpr == nil or targetName.len == 0: return
  var expr = initExpr
  while expr != nil and expr.kind == Paren:
    expr = expr.inner
  if expr == nil: return
  var isAnon = false
  case expr.kind
  of FunctionExpr: isAnon = expr.fnNameLen == 0
  of ArrowFunc:    isAnon = true
  else:            isAnon = false
  if not isAnon: return
  # LoadConst the name string, then SetFunctionName val, nameReg.
  c.constants.add(Constant(kind: ckString, s: targetName))
  let nameReg = allocReg(c)
  emit(c, instAU16(LoadConst, nameReg, uint16(c.constants.len - 1)))
  emit(c, instAB(SetFunctionName, valReg, nameReg))
  releaseReg(c, nameReg)

# --- Statements -----------------------------------------------------

proc compileVarDecl(c: var Compiler, node: AstNode) =
  ## Handles all three decl kinds at script top level:
  ##   * `var x = <e>`  -> DefineGlobal (slice 1)
  ##   * `let`/`const`  -> bind to the pre-allocated local register
  ## Destructuring declarators are a later slice.
  for decl in node.declarators:
    if decl.kind != Declarator: continue
    if decl.nameLength == 0:
      # Destructuring declarator (declPattern != nil) -- later slice.
      c.hadError = true; return
    let name = c.slice(decl.nameStart, decl.nameStart + decl.nameLength)
    # Script-top `var x` keeps global semantics; collectLocals skipped
    # it, so it must not fall into the local path.
    let isScriptVar = c.isScript and node.declKind == KwVar
    if c.isFunction and not isScriptVar:
      # Local -- register was pre-allocated by collectLocals.
      let lidx = findLocalIndex(c, name)
      if lidx < 0:
        c.hadError = true; return
      let lreg = c.locals[lidx].reg
      if decl.init != nil:
        # #395: bare-simple initializer (local ident / number) is a
        # terminal read -- place directly into lreg, skipping the temp
        # and the tail Mov.
        if tryPlaceSimple(c, decl.init, lreg):
          discard
        else:
          # Otherwise hand the initializer a preferred-dst hint so its
          # terminal op writes lreg directly -- kills the tail Mov on
          # `let x = <expr>`. (A FunctionExpr init ignores the hint —
          # compile_function_value uses allocReg — so it lands in a temp
          # and the tail Mov below binds it.)
          let savedPd = c.preferredDst
          c.preferredDst = int(lreg)
          let r = compileExpr(c, decl.init)
          c.preferredDst = savedPd
          # ECMA-262 NamedEvaluation: `let h = function(){}` names the
          # anonymous function "h" BEFORE the binding store.
          maybeInferAnonName(c, decl.init, r, name)
          if r != lreg:
            emit(c, instAB(Mov, lreg, r))
          releaseReg(c, r)
      # No initializer (`let x;`): reg stays undefined -- slice 3a's
      # targets always initialize, so nothing to emit here.
    else:
      # Script-top `var` (or non-function context) -> globalThis.
      let slot = internGlobal(c, name)
      if decl.init != nil:
        let r = compileExpr(c, decl.init)
        # ECMA-262 NamedEvaluation: `var g = function(){}` names it "g".
        maybeInferAnonName(c, decl.init, r, name)
        emit(c, instAU16(DefineGlobal, r, uint16(slot)))
        releaseReg(c, r)
  resetTemps(c)

proc compileStmt(c: var Compiler, node: AstNode) =
  if node == nil: return
  case node.kind
  of BlockStmt:
    # Re-enter the scope id collectLocals assigned to this block.
    enterScopeReuse(c, node)
    # #330/#387 TDZ: seed this block's own let/const regs with the hole
    # so a read BEFORE the declaration throws — but only when
    # blockNeedsEntryHole finds a possible pre-decl read (the common
    # `let t = expr;` shape never observes the hole). Only non-captured
    # register locals in THIS scope; captured/env-slot TDZ is stage-3.
    # At script top these gates coincide with the slice-3 behavior (all
    # block targets there return false), so no regression.
    for hi in 0 ..< c.locals.len:
      if c.locals[hi].scopeId == c.curScopeId and
         c.locals[hi].isTdz and not c.locals[hi].isParam:
        if blockNeedsEntryHole(c, node, c.locals[hi].name):
          emit(c, instA(LoadHole, c.locals[hi].reg))
    for s in node.stmtList:
      if c.hadError: break
      compileStmt(c, s)
    exitScope(c)
  of VarDecl:
    compileVarDecl(c, node)
  of IfStmt:
    # ECMA-262 14.6.7 step 7: Return UpdateEmpty(stmtCompletion, undefined).
    # At the top level, reset the completion register before the branch so
    # an empty-body `if` produces undefined (not the prior value); the
    # branch's expression statements overwrite it. Mirrors compile_if.
    # (Gated on `atProgramTop` == compiler.zc `c.parent == NULL`: a
    # function body has no completion register, so no reset fires there.)
    if c.atProgramTop and c.lastExprReg >= 0:
      emit(c, instA(LoadUndefined, uint8(c.lastExprReg)))
    var jmpElse = tryEmitCmpBranchIfFalse(c, node.ifCond)
    if jmpElse < 0:
      let condReg = compileExpr(c, node.ifCond)
      jmpElse = emit(c, instAI16(JmpIfFalse, condReg, 0))
      releaseReg(c, condReg)
    resetTemps(c)

    compileStmt(c, node.thenStmt)   # then branch

    if node.elseStmt != nil:
      let jmpEnd = emit(c, instI16(Jmp, 0))
      patchJump(c, jmpElse)
      compileStmt(c, node.elseStmt)
      patchJump(c, jmpEnd)
    else:
      patchJump(c, jmpElse)
  of WhileStmt:
    # ECMA-262 completion reset (top level only): an empty-iteration
    # while yields undefined, not the prior completion value.
    if c.atProgramTop and c.lastExprReg >= 0:
      emit(c, instA(LoadUndefined, uint8(c.lastExprReg)))
    if condIsRotatable(node.whileCond):
      # Rotated (test-at-bottom) shape -- kills the unconditional
      # back-edge Jmp. `Jmp -> test`, body_head, <body>, test:, then a
      # TRUE-polarity fused branch back to body_head (fall-through =
      # exit). Mirrors compile_while's rotated arm.
      let entryJmp = emit(c, instI16(Jmp, 0))
      let bodyHead = uint32(c.code.len)
      loopPush(c)
      # No loopSetContinue yet: `continue` must run the bottom test,
      # whose position isn't known until after the body. Continues queue
      # placeholders (the ForStmt deferred pattern).
      compileStmt(c, node.whileBody)
      patchJump(c, entryJmp)                    # test: = current position
      loopSetContinue(c, uint32(c.code.len))
      emitCmpBranchBackIfTrue(c, node.whileCond, bodyHead)
      resetTemps(c)
      for bp in c.loopStack[c.loopStack.len - 1].breakPatches:
        patchJump(c, bp)
      loopPop(c)
    else:
      # Plain condition -> test-at-top: JmpIfFalse->end, body, back-edge
      # Jmp->test-top. `continue` targets the test-top.
      let loopTop = uint32(c.code.len)
      loopPush(c)
      loopSetContinue(c, loopTop)
      var jmpExit = tryEmitCmpBranchIfFalse(c, node.whileCond)
      if jmpExit < 0:
        let condReg = compileExpr(c, node.whileCond)
        jmpExit = emit(c, instAI16(JmpIfFalse, condReg, 0))
        releaseReg(c, condReg)
      resetTemps(c)
      compileStmt(c, node.whileBody)
      emitJumpBack(c, Jmp, loopTop)
      patchJump(c, jmpExit)
      for bp in c.loopStack[c.loopStack.len - 1].breakPatches:
        patchJump(c, bp)
      loopPop(c)
  of DoWhileStmt:
    if c.atProgramTop and c.lastExprReg >= 0:
      emit(c, instA(LoadUndefined, uint8(c.lastExprReg)))
    let loopTop = uint32(c.code.len)
    # continue targets the test, only known after the body.
    loopPush(c)
    compileStmt(c, node.doBody)
    let testAt = uint32(c.code.len)
    loopSetContinue(c, testAt)
    # do-while ALWAYS compiles the condition to a register and emits a
    # single-slot JmpIfTrue back-edge -- compile_do does NOT rotate (no
    # cond_is_rotatable check), so a relational condition still lowers to
    # Cmp* + JmpIfTrue, not a fused true-polarity branch.
    let condReg = compileExpr(c, node.doCond)
    emitJumpBackIf(c, JmpIfTrue, condReg, loopTop)
    releaseReg(c, condReg)
    resetTemps(c)
    for bp in c.loopStack[c.loopStack.len - 1].breakPatches:
      patchJump(c, bp)
    loopPop(c)
  of ForStmt:
    # Re-enter the for-statement's collect-assigned scope so the init's
    # let/const (and any let/const in the body) don't leak past the loop.
    enterScopeReuse(c, node)
    # init (expression statement or let/const/var decl)
    if node.forInit != nil:
      compileStmt(c, node.forInit)
    # ECMA-262 ForBodyEvaluation step 1: V <- undefined AFTER init, so
    # the init's expression value doesn't leak into the completion.
    if c.atProgramTop and c.lastExprReg >= 0:
      emit(c, instA(LoadUndefined, uint8(c.lastExprReg)))
    if node.forTest != nil and condIsRotatable(node.forTest):
      # Rotated for-loop: `Jmp -> test` skips body AND update on the
      # first iteration. body_head, <body>, update_at (continue target),
      # <update>, test:, JmpIf*->body_head (fall-through = exit).
      let entryJmp = emit(c, instI16(Jmp, 0))
      let bodyHead = uint32(c.code.len)
      loopPush(c)
      if node.forBody != nil:
        compileStmt(c, node.forBody)
      let updateAt = uint32(c.code.len)
      loopSetContinue(c, updateAt)
      if node.forUpdate != nil:
        let ru = compileExpr(c, node.forUpdate)
        releaseReg(c, ru)
        resetTemps(c)
      patchJump(c, entryJmp)                    # test:
      emitCmpBranchBackIfTrue(c, node.forTest, bodyHead)
      resetTemps(c)
      for bp in c.loopStack[c.loopStack.len - 1].breakPatches:
        patchJump(c, bp)
      loopPop(c)
    else:
      # Test-at-top (or no test -> `for(;;)`). Empty test => unconditional
      # back Jmp. `continue` targets the update step (below the body).
      let loopTop = uint32(c.code.len)
      loopPush(c)
      var jmpExit = -1
      if node.forTest != nil:
        jmpExit = tryEmitCmpBranchIfFalse(c, node.forTest)
        if jmpExit < 0:
          let condReg = compileExpr(c, node.forTest)
          jmpExit = emit(c, instAI16(JmpIfFalse, condReg, 0))
          releaseReg(c, condReg)
        resetTemps(c)
      if node.forBody != nil:
        compileStmt(c, node.forBody)
      let updateAt = uint32(c.code.len)
      loopSetContinue(c, updateAt)
      if node.forUpdate != nil:
        let ru = compileExpr(c, node.forUpdate)
        releaseReg(c, ru)
        resetTemps(c)
      emitJumpBack(c, Jmp, loopTop)
      if jmpExit >= 0: patchJump(c, jmpExit)
      for bp in c.loopStack[c.loopStack.len - 1].breakPatches:
        patchJump(c, bp)
      loopPop(c)
    exitScope(c)
  of BreakStmt:
    # Unlabeled break to the innermost loop. Labeled break is out of
    # scope (the parser discards labels) -> falls here as an unlabeled
    # break, which is the correct target for the slice-3c corpus. A
    # `break` with no enclosing loop is a SyntaxError -> hadError.
    if c.loopStack.len == 0:
      c.hadError = true; return
    let jmpIdx = emit(c, instI16(Jmp, 0))
    loopAddBreak(c, jmpIdx)
  of ContinueStmt:
    if c.loopStack.len == 0:
      c.hadError = true; return
    let top = c.loopStack.len - 1
    if c.loopStack[top].haveContinue:
      emitJumpBack(c, Jmp, c.loopStack[top].continueTarget)
    else:
      # Target not yet known (for-style loops: `continue` runs the update
      # step, positioned after the body). Emit a placeholder, patched at
      # loopSetContinue time.
      let jmpIdx = emit(c, instI16(Jmp, 0))
      loopAddContinuePatch(c, jmpIdx)
  of FunctionDecl:
    # A function declaration. Compile the body into a fresh Function,
    # append it to the const pool, LoadConst it, then wrap in
    # MakeClosure so each enclosing invocation yields a distinct
    # function value (compiler.zc: nested FunctionDecls ALWAYS wrap; the
    # non-captures form emits the in-place `MakeClosure dst, dst, dst`,
    # where dst doubles as fn-src AND env-src — zero extra register
    # pressure). Finally bind: script-top -> DefineGlobal on globalThis;
    # a function-body decl -> Mov into the pre-allocated local. Captures
    # (needs_env) are slice 4b; compileFunction bails there.
    let f = compileFunction(c.src, node, c)
    if f == nil:
      c.hadError = true
      return
    c.constants.add(Constant(kind: ckFunction, fn: f))
    let idx = uint16(c.constants.len - 1)
    var r = allocReg(c)
    emit(c, instAU16(LoadConst, r, idx))
    # Non-capturing form: in-place MakeClosure (dst=src=env). 4a never
    # produces needs_env functions, so this is the only path.
    emit(c, instABC(MakeClosure, r, r, r))
    let name = c.slice(node.fnNameStart, node.fnNameStart + node.fnNameLen)
    let isScriptDecl = c.isScript
    if c.isFunction and not isScriptDecl:
      # Function/module body: bind to the pre-allocated local register.
      let lidx = findLocalIndex(c, name)
      if lidx >= 0:
        emit(c, instAB(Mov, c.locals[lidx].reg, r))
    else:
      # Script-top FunctionDecl -> property on globalThis.
      let slot = internGlobal(c, name)
      emit(c, instAU16(DefineGlobal, r, uint16(slot)))
    releaseReg(c, r)
    resetTemps(c)
  of ReturnStmt:
    # `return expr` / `return;`. Slice 4a: no try/finally regions, so
    # emit_return_sequence reduces to a bare `Return r` (compiler.zc
    # emit_return_sequence with region_count == 0). Tail-call rewriting
    # (TailInvoke/TailMethodInvoke) is deferred — calls aren't in 4a.
    # `return` outside a function is a SyntaxError; the parser accepts it
    # at program top, so refuse here rather than emit a bogus Return.
    if c.atProgramTop:
      c.hadError = true
      return
    var r: uint8
    if node.retArg != nil:
      # Borrow the source reg directly for a bare IdentExpr — Return
      # consumes the value immediately, so IdentExpr's defensive Mov is
      # dead weight (compiler.zc sets borrow_local_ok around the read).
      let savedBorrow = c.borrowLocalOk
      c.borrowLocalOk = true
      r = compileExpr(c, node.retArg)
      c.borrowLocalOk = savedBorrow
    else:
      r = allocReg(c)
      emit(c, instA(LoadUndefined, r))
    emit(c, instA(Return, r))
    c.lastExprReg = int(r)
    resetTemps(c)
  of EmptyStmt:
    discard
  else:
    # Default: an expression statement. At the program top level, Mov
    # the result into the reserved completion slot (lastExprReg); inside
    # a function `return` produces the result, so we just remember the
    # last register for diagnostics (compiler.zc `c.parent == NULL`
    # split). The gate is atProgramTop, not merely lastExprReg >= 0.
    let r = compileExpr(c, node)
    if c.atProgramTop and c.lastExprReg >= 0:
      let dst = uint8(c.lastExprReg)
      if r != dst: emit(c, instAB(Mov, dst, r))
    else:
      c.lastExprReg = int(r)
    resetTemps(c)

# --- Function bodies (slice 4a: non-capturing) ----------------------

proc functionBodyStmts(node: AstNode): seq[AstNode] =
  ## The function body's top-level statement list. The outer braces ARE
  ## the function scope, so we iterate the BlockStmt's children directly
  ## (never re-entering a block scope for them) — mirrors compiler.zc's
  ## "walk INTO node.left's children" for the body.
  let body = node.fnBody
  if body == nil: return @[]
  if body.kind == BlockStmt: return body.stmtList
  return @[body]

proc compileFunction(src: string, node: AstNode, enclosing: var Compiler): Function =
  ## Compile a FunctionDecl / FunctionExpr body into its own Function
  ## (own code / consts / regs / paramCount). Mirrors compiler.zc
  ## compile_function for the slice-4a envelope: simple params, no
  ## captures, no `this`/`arguments`/async/generator/default/rest. Any
  ## feature outside that envelope sets hadError -> returns nil so the
  ## enclosing compile bails (surfacing as nim_missing, never a false
  ## match). `enclosing` shares its global-intern table with the child
  ## so global slots stay in one namespace program-wide.

  # --- Envelope gate ------------------------------------------------
  if node.fnIsAsync or node.fnIsGenerator:
    return nil
  if not paramsAreSimple(node.fnParams):
    return nil
  # A NAMED function expression binds its own name as a self-referencing
  # local visible inside the body (§15.7.1), seeded via a LoadCallee
  # prologue (compiler.zc bind_callee_local). That machinery is slice
  # 4b — bail so `(function foo(){})` surfaces as nim_missing, not a
  # false byte-match. FunctionDecl names bind in the ENCLOSING scope and
  # get NO LoadCallee, so decls with a name are fine.
  if node.kind == FunctionExpr and node.fnNameLen > 0:
    return nil
  let body = node.fnBody

  var c = Compiler(
    src: src,
    nextReg: 0, maxReg: 0, fixedRegs: 0,
    lastExprReg: -1, hadError: false,
    preferredDst: -1, borrowLocalOk: false,
    isFunction: true, isScript: false,
    atProgramTop: false,
    globals: enclosing.globals,      # SHARED global namespace (see GlobalTable)
    scopeStack: @[0'u32], curScopeId: 0, nextScopeId: 1,
  )

  # 1. Bind params to the low fixed regs r0..rN-1 in declaration order.
  var paramNames: seq[string] = @[]
  for p in node.fnParams:
    let nm = c.slice(p.start, p.`end`)
    paramNames.add(nm)
    let reg = allocReg(c)
    addLocalScoped(c, p.start, p.`end` - p.start, uint32(reg), 0'u32)
    c.locals[c.locals.len - 1].isParam = true
  c.paramCount = uint32(node.fnParams.len)

  # 2. Hoist body var/let/const into fixed locals. The body's own braces
  #    ARE the function scope, so walk its children directly (matching
  #    compiler.zc, so a body-top `let` lands in scope 0, not a nested
  #    block scope). collectLocals(BlockStmt) would open a fresh scope —
  #    wrong — so iterate the children ourselves.
  for s in functionBodyStmts(node):
    collectLocals(c, s)

  # 2b. Capture bail. Any nested function whose body references one of
  #     OUR params/lexicals needs an env object (slice 4b) — refuse.
  #     Walk our body for nested functions and test their bodies against
  #     our binding names. (analyze_captures' role, reduced to a bail.)
  var localNames = paramNames
  for lc in c.locals:
    if not lc.isParam and lc.name.len > 0:
      localNames.add(lc.name)
  proc anyNestedCaptures(c: Compiler, n: AstNode, names: seq[string]): bool =
    if n == nil: return false
    if n.kind in {FunctionDecl, FunctionExpr, ArrowFunc}:
      let innerBody =
        if n.kind == ArrowFunc: n.arrowBody else: n.fnBody
      if bodyReferencesAnyLocal(c, innerBody, names): return true
      # A nested fn can also nest further — but if it captured OUR names
      # we'd have caught it above; deeper nesting that reaches us is also
      # covered because bodyReferencesAnyLocal descends nested bodies.
      return false
    for ch in childNodes(n):
      if anyNestedCaptures(c, ch, names): return true
    return false
  if body != nil and anyNestedCaptures(c, body, localNames):
    return nil

  # 3. Locals are now fixed; temps live above this watermark.
  c.fixedRegs = c.nextReg
  # Reset scope tracking so compileStmt re-enters block ids matching
  # what collectLocals assigned.
  resetScopeWalk(c)

  # 3b. Also gate on `this` / `arguments` usage anywhere in the body —
  #     those need the LoadThis/BuildArguments prologue machinery (4b+).
  proc mentionsThisOrArguments(c: Compiler, n: AstNode): bool =
    if n == nil: return false
    # Don't descend into nested non-arrow functions: they have their own
    # `this`/`arguments`. (Arrows inherit — but arrows already bail.)
    if n.kind in {FunctionDecl, FunctionExpr}: return false
    if n.kind == ThisExpr: return true
    if n.kind == IdentExpr and c.identName(n) == "arguments": return true
    for ch in childNodes(n):
      if mentionsThisOrArguments(c, ch): return true
    return false
  if body != nil and mentionsThisOrArguments(c, body):
    return nil

  # 4. Function-top TDZ hole seeding. ECMA-262: a body-top let/const is
  #    seeded with LoadHole before its initializer. Params are never
  #    seeded (their value arrives from the caller). Unlike a nested
  #    block (which gates on blockNeedsEntryHole), the function-top seed
  #    is UNCONDITIONAL for every is_tdz non-param local — matching
  #    compiler.zc's `tz = param_count .. local_count` loop, which holes
  #    even locals that live in nested blocks (their block handler then
  #    decides whether to RE-hole).
  for li in 0 ..< c.locals.len:
    if c.locals[li].isTdz and not c.locals[li].isParam:
      emit(c, instA(LoadHole, c.locals[li].reg))

  # 5. Compile the body statements (function-decl-first two-pass, like
  #    the program: hoisted FunctionDecls emit before other statements).
  let stmts = functionBodyStmts(node)
  if body != nil and body.kind != BlockStmt:
    # Arrow concise body path — but arrows bail above, so a non-block
    # body here is unexpected; treat defensively as an expression whose
    # value is returned.
    let r = compileExpr(c, body)
    emit(c, instA(Return, r))
  else:
    for s in stmts:
      if c.hadError: break
      if s != nil and s.kind == FunctionDecl:
        compileStmt(c, s)
    for s in stmts:
      if c.hadError: break
      if s == nil or s.kind != FunctionDecl:
        compileStmt(c, s)

  # 6. Ensure a trailing Return. If control can fall off the end, emit
  #    `LoadUndefined r; Return r` (compiler.zc need_return).
  var needReturn = true
  if c.code.len > 0 and c.code[c.code.len - 1].op == Return:
    needReturn = false
  if needReturn:
    let r = allocReg(c)
    emit(c, instA(LoadUndefined, r))
    emit(c, instA(Return, r))

  if c.hadError:
    return nil

  var f = Function(
    code: c.code,
    constants: c.constants,
    registerCount: uint32(c.maxReg) + 1'u32,
    fixedRegs: c.fixedRegs,
    paramCount: c.paramCount,
    constCount: uint32(c.constants.len),
    icCount: 0,
  )
  # register_count floor: at least param_count (compiler.zc clamp).
  if f.registerCount < f.paramCount: f.registerCount = f.paramCount
  if f.registerCount == 0: f.registerCount = 1
  if f.fixedRegs > f.registerCount: f.fixedRegs = f.registerCount
  # Attach the SHARED global table so disasm resolves slots this body
  # references (extra entries for globals it doesn't touch are inert —
  # disasm only looks up slots that appear in ops).
  for i in 0 ..< c.globals.names.len:
    f.globalNames.add(GlobalName(slot: c.globals.slots[i], name: c.globals.names[i]))
  return f

# --- Program --------------------------------------------------------

proc hoistProgramGlobals(c: var Compiler, root: AstNode) =
  ## `var` AND script-top FunctionDecl hoist into the global object
  ## (mirrors hoist_program_decls). Interning here fixes slot order to
  ## match declaration order, independent of when the DefineGlobal
  ## emits — so a forward reference (`f(); function f(){}`) and the
  ## globals a function body reads both get their canonical slots.
  if root == nil: return
  for stmt in root.stmts:
    if stmt == nil: continue
    if stmt.kind == VarDecl and stmt.declKind == KwVar:
      for decl in stmt.declarators:
        if decl.kind == Declarator and decl.nameLength > 0:
          discard internGlobal(c, c.slice(decl.nameStart, decl.nameStart + decl.nameLength))
    elif stmt.kind == FunctionDecl and stmt.fnNameLen > 0:
      discard internGlobal(c, c.slice(stmt.fnNameStart, stmt.fnNameStart + stmt.fnNameLen))

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
    preferredDst: -1,
    borrowLocalOk: false,
    # Script mode (the common case). Top-level let/const bind to a
    # script-scope lexical env (= register slots); `var` and FunctionDecl
    # stay on globalThis. Mirrors compile_program's else-branch.
    isFunction: true,
    isScript: true,
    atProgramTop: true,
    globals: GlobalTable(),
    scopeStack: @[0'u32],
    curScopeId: 0,
    nextScopeId: 1,
  )

  # Lexical pre-allocation: collect_locals gives each top-level let/const
  # a low FIXED reg in declaration order BEFORE the completion slot is
  # reserved, so the completion slot lands AFTER the locals.
  if root != nil and root.kind == Program:
    collectLocals(c, root)
  # Reset scope tracking so compileStmt re-enters each block with the
  # same ids collectLocals just assigned.
  resetScopeWalk(c)

  # Reserve a stable program-result register (the completion slot).
  let resultReg = allocReg(c)
  emit(c, instA(LoadUndefined, resultReg))
  c.fixedRegs = resultReg + 1
  c.lastExprReg = int(resultReg)

  if root != nil and root.kind == Program:
    hoistProgramGlobals(c, root)
    # ECMA-262 §10.2.11: function declarations are evaluated at scope
    # entry (calling them before their textual position is valid). Two
    # passes over the top level: emit FunctionDecl statements first (in
    # source order), then the rest, skipping the already-emitted decls.
    for stmt in root.stmts:
      if c.hadError: break
      if stmt != nil and stmt.kind == FunctionDecl:
        compileStmt(c, stmt)
    for stmt in root.stmts:
      if c.hadError: break
      if stmt == nil or stmt.kind != FunctionDecl:
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
  # Attach the shared global-name side table so disasm can print `; <name>`.
  for i in 0 ..< c.globals.names.len:
    f.globalNames.add(GlobalName(slot: c.globals.slots[i], name: c.globals.names[i]))
  return f
