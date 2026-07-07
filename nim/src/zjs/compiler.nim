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
    captured*:   bool            ## true if a nested function captures this
                                 ## local -> it lives as a property on the
                                 ## env object, NOT in its register (slice 4b)

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
    ## Fixed register holding `this` for the current function body, or -1 if
    ## the body never references `this` (mirrors compiler.zc `c.this_reg`).
    ## Reserved AFTER params (and after argumentsReg) in the compileFunction
    ## prologue; NO prologue op is emitted (the call convention seeds it).
    ## A ThisExpr reference borrows/Movs this reg (slice 4c).
    thisReg*: int
    ## Fixed register holding the implicit `arguments` array, or -1 if the
    ## body never references `arguments` (mirrors compiler.zc
    ## `c.arguments_reg`). Reserved AFTER params, BEFORE thisReg; seeded by a
    ## `BuildArguments argumentsReg` prologue op emitted at function entry.
    argumentsReg*: int
    # --- Closure support (compiler.zc Compiler.parent/needs_env/... ) --
    ## Link to the ENCLOSING function's compiler (nil for the top-level
    ## program). Mirrors compiler.zc `parent`. Threaded so a free-variable
    ## IdentExpr inside a nested body can walk up the lexical chain to find
    ## the enclosing captured local it resolves to (outerCaptureDepth).
    ## `ptr` (not ref) so the child can mutate the parent's
    ## `hasOuterRefs` flag during the passthrough-marking walk, exactly
    ## like the C's `Compiler*` back-pointer.
    parent*: ptr Compiler
    ## True when a nested function captures one of THIS function's locals:
    ## this function must build an env object (NewObject envReg) and store
    ## captured params/locals as its properties. Mirrors compiler.zc
    ## `needs_env`.
    needsEnv*: bool
    ## The fixed register holding this function's env object, valid only
    ## when needsEnv. Mirrors compiler.zc `env_reg`.
    envReg*: uint8
    ## Set on THIS compiler whenever its body (or a nested closure inside
    ## it) references a name that resolves in a PARENT scope. Drives
    ## whether the enclosing compiler wraps us in an env-capturing
    ## MakeClosure, and whether we forward an env to our own inner
    ## closures. Mirrors compiler.zc `has_outer_refs`; copied into
    ## Function.needsEnv at function-end.
    hasOuterRefs*: bool
    ## Hoisted current-closure env for a PASSTHROUGH function (references
    ## outer captures but has no own env). Seeded once by a prologue
    ## `LoadEnv` and reused by depth==1 chain walks and the MakeClosure
    ## env operand. -1 = not allocated. Mirrors compiler.zc
    ## `cached_outer_env_reg`.
    cachedOuterEnvReg*: int
    ## The Call AST node in tail position (`return <call>`), or nil. Set by
    ## the ReturnStmt handler around the tail call's compile so
    ## compileCallInner SUPPRESSES InvokeGlobal fusion for it — the TCO
    ## rewriter matches `last op == Invoke/MethodInvoke` in place, and a
    ## fused 2-slot call there can't be rewritten. Nested calls inside the
    ## return expression compare unequal and still fuse. Mirrors compiler.zc
    ## `c.tail_call_node` (#394).
    tailCallNode*: AstNode
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
    # --- Inline-cache name table (compiler.zc c.ics / c.ic_count) ------
    ## Per-function IC slots, keyed by property NAME. allocIcSlot dedups
    ## by decoded name: a repeated `.length`/`.prototype` access reuses
    ## the same slot (mirrors alloc_ic_slot's atom-pointer dedup). Index
    ## = IC slot, stored into Function.ics so disasm prints the name. The
    ## count becomes Function.icCount.
    ics*: seq[string]

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

# --- Inline-cache slot allocation (mirrors alloc_ic_slot) -----------
#
# One IC slot per DISTINCT property name in the function. `allocIcSlot`
# dedups by name: a name already present returns its existing index; a
# new name appends (name -> next index). The C dedups by interned-atom
# pointer, which is equivalent to comparing the decoded name text — two
# textually-equal property names intern to the same atom. Property names
# here are plain identifiers (no `\u` escapes in the slice-5a corpus), so
# a direct source-slice compare matches the atom-pointer dedup.
#
# CRITICAL ORDER: a member access allocates its OWN slot BEFORE compiling
# its receiver subexpression, so outer accesses get LOWER indices than
# inner ones (`a.b.c` -> `.b`=ic#1, `.c`=ic#0; `o.x = o.y` -> `.x`=ic#0,
# `.y`=ic#1). The caller enforces this by calling allocIcSlot first.

proc allocIcSlot(c: var Compiler, name: string): int =
  for i in 0 ..< c.ics.len:
    if c.ics[i] == name:
      return i
  c.ics.add(name)
  return c.ics.len - 1

# Property LOAD by name: allocate (or reuse) the IC slot, then emit
# `LoadProp dst <- objReg.name  ic#slot` (a=dst, b=objReg, c=slot). The
# slot is allocated BEFORE the caller compiles the receiver so the alloc
# order is outer-first. Only the ic<=255 fast path is ported; a function
# accumulating >255 distinct IC names would need the LoadElem fallback
# (out of the slice-5a corpus) -- bail there.
proc emitLoadPropAtom(c: var Compiler, dst, objReg: uint8, name: string): bool =
  let ic = allocIcSlot(c, name)
  if ic > 255:
    c.hadError = true
    return false
  emit(c, instABC(LoadProp, dst, objReg, uint8(ic)))
  return true

# Property STORE by name: `StoreProp objReg.name <- valReg  ic#slot`
# (a=objReg, b=slot, c=valReg -- matches emit_store_prop_atom and the
# disasm, which reads the name from ics[b] and the value reg from c).
proc emitStorePropAtom(c: var Compiler, objReg: uint8, name: string, valReg: uint8): bool =
  let ic = allocIcSlot(c, name)
  if ic > 255:
    c.hadError = true
    return false
  emit(c, instABC(StoreProp, objReg, uint8(ic), valReg))
  return true

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

# --- Capture analysis (compiler.zc analyze_captures / scan_inner) ----
#
# A nested function that references one of THIS function's params/locals
# CAPTURES it: the captured local moves off its register onto an env
# object (a data property). analyzeCaptures walks our body for nested
# functions; scanInnerForCaptures walks each inner body, and for every
# free variable (a name NOT bound by the inner itself) that matches one
# of OUR in-scope locals, it flips that local's `captured` flag and sets
# `needsEnv`. Runs AFTER collectLocals (which assigned each local a
# register) — a captured local keeps its (now-wasted) register slot but
# is accessed through the env; that wasted slot is exactly why the
# oracle's `fixed` count includes it. Mirrors compiler.zc's
# collect-then-analyze order.

proc fnBodyOf(n: AstNode): AstNode =
  ## The statement/expression body of a nested function node.
  if n == nil: return nil
  case n.kind
  of FunctionDecl, FunctionExpr: n.fnBody
  of ArrowFunc: n.arrowBody
  else: nil

proc fnParamsOf(n: AstNode): seq[AstNode] =
  if n == nil: return @[]
  case n.kind
  of FunctionDecl, FunctionExpr: n.fnParams
  of ArrowFunc: n.arrowParams
  else: @[]

proc bodyDeclaresName(c: Compiler, node: AstNode, name: string): bool =
  ## Does this subtree declare `name` as a var/let/const or a nested
  ## FunctionDecl name? Does NOT descend into nested function bodies
  ## (they own their own scope). Mirrors compiler.zc body_declares_name.
  if node == nil: return false
  case node.kind
  of VarDecl:
    for d in node.declarators:
      if d.kind == Declarator and d.nameLength > 0 and
         c.slice(d.nameStart, d.nameStart + d.nameLength) == name:
        return true
    return false
  of FunctionDecl:
    if node.fnNameLen > 0 and
       c.slice(node.fnNameStart, node.fnNameStart + node.fnNameLen) == name:
      return true
    return false          # don't descend
  of FunctionExpr, ArrowFunc:
    return false
  else:
    for ch in childNodes(node):
      if bodyDeclaresName(c, ch, name): return true
    return false

proc nameIsLocalOfFunction(c: Compiler, fnNode: AstNode, name: string): bool =
  ## Is `name` bound by the nested function `fnNode` itself (a param or a
  ## body-declared binding)? If so it is NOT a capture of our scope.
  ## Mirrors compiler.zc name_is_local_of_function.
  for p in fnParamsOf(fnNode):
    if p != nil and p.kind == IdentExpr and c.identName(p) == name:
      return true
  return bodyDeclaresName(c, fnBodyOf(fnNode), name)

proc scanInnerForCaptures(c: var Compiler, fnNode: AstNode, body: AstNode) =
  ## Walk the nested function `fnNode`'s `body`; for each free-variable
  ## IdentExpr (read OR assignment target) whose name isn't local to the
  ## inner and matches one of OUR in-scope locals, mark that local
  ## captured + set needsEnv. Descends nested function bodies so
  ## transitive captures are found (fnNode is kept as the immediate inner
  ## for the "is-local-of-inner" gate, matching compiler.zc's
  ## conservative approach). Mirrors compiler.zc scan_inner_for_captures.
  if body == nil: return
  case body.kind
  of IdentExpr:
    let name = c.identName(body)
    if not nameIsLocalOfFunction(c, fnNode, name):
      let idx = findLocalIndex(c, name)
      if idx >= 0:
        c.locals[idx].captured = true
        c.needsEnv = true
    return
  of Assignment:
    let target = body.target
    if target != nil and target.kind == IdentExpr:
      let name = c.identName(target)
      if not nameIsLocalOfFunction(c, fnNode, name):
        let idx = findLocalIndex(c, name)
        if idx >= 0:
          c.locals[idx].captured = true
          c.needsEnv = true
    elif target != nil:
      scanInnerForCaptures(c, fnNode, target)
    if body.value != nil:
      scanInnerForCaptures(c, fnNode, body.value)
    return
  of FunctionDecl, FunctionExpr, ArrowFunc:
    # Descend into the deeper nested function body, keeping the DEEPER
    # function as the is-local gate (matches C: `scan_inner(c, body, body.left)`).
    let inner = fnBodyOf(body)
    if inner != nil:
      scanInnerForCaptures(c, body, inner)
    return
  else:
    for ch in childNodes(body):
      scanInnerForCaptures(c, fnNode, ch)

proc analyzeCaptures(c: var Compiler, node: AstNode) =
  ## Walk OUR body for nested functions; scan each for captures of our
  ## locals. Enters block/for scopes (by reused id) so a closure declared
  ## inside a block sees that block's let/const as in-scope. Mirrors
  ## compiler.zc analyze_captures.
  if node == nil: return
  case node.kind
  of BlockStmt:
    enterScopeReuse(c, node)
    for s in node.stmtList:
      analyzeCaptures(c, s)
    exitScope(c)
  of ForStmt:
    enterScopeReuse(c, node)
    analyzeCaptures(c, node.forInit)
    analyzeCaptures(c, node.forTest)
    analyzeCaptures(c, node.forUpdate)
    analyzeCaptures(c, node.forBody)
    exitScope(c)
  of FunctionDecl, FunctionExpr, ArrowFunc:
    let inner = fnBodyOf(node)
    if inner != nil:
      scanInnerForCaptures(c, node, inner)
  else:
    for ch in childNodes(node):
      analyzeCaptures(c, ch)

# --- Outer-capture resolution (compiler.zc outer_capture_depth / ... ) -
#
# When a body references a free variable not bound locally, walk the
# lexical compiler chain to find the first ANCESTOR whose CAPTURED local
# matches. Returns the env depth (1 = c.parent). The slice-4b corpus has
# no per-iteration envs, so `per_iter_depth` is always 0 and env_for_local
# is a pure `envReg` borrow. Passthrough intermediates between us and the
# owning ancestor are marked hasOuterRefs so their MakeClosure forwards
# the env via LoadEnv.

proc compilerHasOwnEnv(c: ptr Compiler): bool =
  ## An ancestor contributes an env-chain hop only if it has its OWN env.
  ## needsEnv is set iff some local is captured, so this matches
  ## compiler.zc compiler_has_own_env (which scans for a captured local).
  c != nil and c.needsEnv

proc detectOuterRefs(c: var Compiler, body: AstNode): bool =
  ## Does `body` (descending into nested closures) reference any name
  ## that is NOT a local of `c` but IS a local of some ancestor? Drives
  ## hasOuterRefs = "this function forwards / receives an env". Mirrors
  ## compiler.zc detect_outer_refs. Called only when c.parent != nil.
  if body == nil: return false
  if body.kind == IdentExpr:
    let nm = c.identName(body)
    if findLocalIndex(c, nm) >= 0: return false
    var anc = c.parent
    while anc != nil:
      if findLocalIndex(anc[], nm) >= 0: return true
      anc = anc[].parent
    return false
  # For a nested function, descend ONLY its body (not its param binding
  # occurrences), matching compiler.zc's `detect_outer_refs(c, body.left)`.
  if body.kind in {FunctionDecl, FunctionExpr, ArrowFunc}:
    return detectOuterRefs(c, fnBodyOf(body))
  for ch in childNodes(body):
    if detectOuterRefs(c, ch): return true
  return false

proc outerCaptureDepth(c: var Compiler, name: string): uint32 =
  ## Depth (>=1) of the enclosing env that owns captured local `name`, or
  ## 0 if none. Marks passthrough intermediates hasOuterRefs. Mirrors
  ## compiler.zc outer_capture_depth (per-iter hop correction omitted:
  ## no per-iter envs in this slice).
  var anc = c.parent
  var envDepth: uint32 = 0
  while anc != nil:
    let oi = findLocalIndex(anc[], name)
    if oi >= 0 and anc[].locals[oi].captured:
      # Mark every passthrough intermediate from c.parent up to (not
      # including) anc as hasOuterRefs so their MakeClosure forwards env.
      var mark = c.parent
      while mark != anc:
        mark[].hasOuterRefs = true
        mark = mark[].parent
      return envDepth + 1
    if compilerHasOwnEnv(anc): envDepth += 1
    anc = anc[].parent
  return 0

proc emitEnvChainWalk(c: var Compiler, depth: uint32): uint8 =
  ## A register holding the env `depth` levels up. depth==1 with a cached
  ## prologue reg returns it (borrow); otherwise LoadEnv into a fresh temp
  ## then chase `__outer__` (depth-1 times). Mirrors compiler.zc
  ## emit_env_chain_walk. The slice-4b corpus only reaches depth 1, so the
  ## __outer__ chase never emits; a deeper walk would need the OUTER_ENV_KEY
  ## atom + IC slot (not ported — those cases are single-hop here).
  if depth == 1 and c.cachedOuterEnvReg >= 0:
    return uint8(c.cachedOuterEnvReg)
  let envR = allocReg(c)
  emit(c, instA(LoadEnv, envR))
  if depth > 1:
    # Multi-hop __outer__ chase is out of the slice-4b corpus — refuse
    # rather than emit wrong bytecode.
    c.hadError = true
  return envR

proc envForLocal(c: var Compiler, li: int): uint8 =
  ## The env register that OWNS captured local `li`. No per-iter envs in
  ## this slice, so this is always the plain envReg borrow (compiler.zc
  ## env_for_local's `per_iter_envs_open <= lp` fast path).
  return c.envReg

type ClosureEnvReg = object
  ## The env register to pass in a MakeClosure emitted inside `c`, plus
  ## whether it's a caller-owned temp to release. Mirrors compiler.zc
  ## ClosureEnvReg / closure_env_reg.
  reg: uint8
  isTemp: bool

proc closureEnvReg(c: var Compiler): ClosureEnvReg =
  ## Env operand for a MakeClosure emitted inside `c`:
  ##   * own env (needsEnv)        -> c.envReg (borrow)
  ##   * passthrough (hasOuterRefs) -> the cached prologue reg if set,
  ##     else a fresh LoadEnv temp
  ##   * neither                    -> 0 (unused by the closure)
  ## Mirrors compiler.zc closure_env_reg.
  if c.needsEnv:
    return ClosureEnvReg(reg: c.envReg, isTemp: false)
  if c.hasOuterRefs:
    if c.cachedOuterEnvReg >= 0:
      return ClosureEnvReg(reg: uint8(c.cachedOuterEnvReg), isTemp: false)
    let temp = allocReg(c)
    emit(c, instA(LoadEnv, temp))
    return ClosureEnvReg(reg: temp, isTemp: true)
  return ClosureEnvReg(reg: 0, isTemp: false)

# --- `this` / `arguments` pre-scan (slice 4c) -----------------------
#
# Mirrors compiler.zc body_uses_this / body_uses_arguments. Both walk the
# function body but STOP at nested non-arrow function boundaries (a nested
# FunctionDecl/FunctionExpr has its OWN this/arguments). body_uses_this
# does NOT stop at ArrowFunc (arrows inherit `this`), and returns false for
# a `new.target` ThisExpr (newTarget=true) — new.target needs no this-reg
# reservation. body_uses_arguments STOPS at ArrowFunc too for the reserve
# gate, but note arrows still inherit `arguments` semantically — arrows are
# deferred (they bail), so the distinction is moot for 4c.

proc bodyUsesThis(n: AstNode): bool =
  ## True if this subtree references plain `this` (not `new.target`), not
  ## crossing into a nested FunctionDecl/FunctionExpr body. Mirrors
  ## compiler.zc body_uses_this exactly.
  if n == nil: return false
  if n.kind in {FunctionDecl, FunctionExpr}: return false
  if n.kind == ThisExpr: return not n.newTarget
  for ch in childNodes(n):
    if bodyUsesThis(ch): return true
  return false

proc bodyUsesArguments(c: Compiler, n: AstNode): bool =
  ## True if this subtree references the identifier `arguments`, not
  ## crossing into a nested FunctionDecl/FunctionExpr/ArrowFunc body.
  ## Mirrors compiler.zc body_uses_arguments exactly.
  if n == nil: return false
  if n.kind in {FunctionDecl, FunctionExpr, ArrowFunc}: return false
  if n.kind == IdentExpr:
    return c.identName(n) == "arguments"
  for ch in childNodes(n):
    if bodyUsesArguments(c, ch): return true
  return false

proc hasArgumentsLocal(c: Compiler): bool =
  ## Does the locals table already have a binding named "arguments"? A
  ## user-declared `arguments` (var/let/const/param/function) shadows the
  ## implicit one, so no argumentsReg is reserved. Mirrors compiler.zc
  ## has_arguments_local.
  for lc in c.locals:
    if lc.name == "arguments": return true
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
# Object / array literals recurse into compileExpr (defined just below),
# so forward-declare them here.
proc compileExpr(c: var Compiler, node: AstNode): uint8
proc compileObjectLiteral(c: var Compiler, node: AstNode): uint8
proc compileArrayLiteral(c: var Compiler, node: AstNode): uint8
# compileObjectLiteral applies NamedEvaluation to anon-function values;
# maybeInferAnonName is defined later, so forward-declare it.
proc maybeInferAnonName(c: var Compiler, initExpr: AstNode, valReg: uint8,
                        targetName: string)
# Function / method / new calls (slice 5b). compileCall reads the outer
# preferred-dst as its ret_hint (mirrors compiler.zc compile_call).
proc compileCall(c: var Compiler, node: AstNode): uint8
proc compileNew(c: var Compiler, node: AstNode): uint8

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
      # 1a. Captured local — read through the env that OWNS it as a
      # property. Mirrors compiler.zc's IdentExpr captured arm
      # (~1678-1687): a fresh temp, LoadProp dst <- env.name.
      if c.locals[localIdx].captured:
        let dst = allocReg(c)
        let er = envForLocal(c, localIdx)
        discard emitLoadPropAtom(c, dst, er, name)
        return dst
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
    # 2a. Implicit `arguments` — only inside a function that uses it AND
    # where no real local of the same name was hoisted (compile_function
    # set c.argumentsReg in that case). A reference Movs the reg into a
    # fresh temp (mirrors compiler.zc ~1717-1724). Uses allocReg (not
    # allocDst): a defensive read must not steal a live hint (#395).
    if c.argumentsReg >= 0 and name == "arguments":
      let dst = allocReg(c)
      emit(c, instAB(Mov, dst, uint8(c.argumentsReg)))
      return dst
    # 2b. Walk the lexical compiler chain for an outer captured local
    # (depth 1 = c.parent). Resolves `x` inside an inner closure that
    # captured the enclosing function's `x`: LoadEnv then LoadProp
    # dst <- env.name. Mirrors compiler.zc ~1727-1738.
    let depth = outerCaptureDepth(c, name)
    if depth > 0:
      c.hasOuterRefs = true
      let envR = emitEnvChainWalk(c, depth)
      let dst = allocReg(c)
      discard emitLoadPropAtom(c, dst, envR, name)
      releaseReg(c, envR)
      if c.nextReg <= dst: c.nextReg = dst + 1
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
    # Slice 3a: plain `=` to a script-scope local / global target.
    # Slice 5a adds Member (`obj.name = rhs`) and Computed
    # (`obj[idx] = rhs`) targets. Compound (`+=` etc.) and destructuring
    # assignment are later slices -- refuse them.
    let target = node.target
    if target == nil:
      c.hadError = true
      return 0
    # --- Member target: `obj.name = rhs` -> StoreProp -----------------
    if target.kind == Member and node.assignOp == Eq:
      # Mirrors compile_assignment_to_property's IC fast path. The IC
      # slot for `.name` is allocated FIRST (before the receiver / RHS),
      # so on `o.x = o.y` the target `.x` takes ic#0 and the RHS's `.y`
      # takes ic#1. StoreProp reads obj+value before writing, so the
      # receiver may always borrow, and the RHS may borrow when the
      # receiver read is pure. No preferred-dst hint reaches the RHS.
      let name = c.slice(target.propStart, target.propStart + target.propLength)
      let ic = allocIcSlot(c, name)
      if ic > 255:
        c.hadError = true
        return 0
      let savedBorrow = c.borrowLocalOk
      let rhsPure = exprIsSimplePure(node.value)
      let lhsPure = exprIsSimplePure(target.recv)
      # #395: `this.x = ANY rhs` — thisReg is written exactly once, at frame
      # entry; no RHS can rebind it, and StoreProp only reads objReg. So
      # borrow unconditionally when the receiver is `this` (compiler.zc
      # ~3152-3157 `obj_is_this`). Distinguishes plain `this` from
      # `new.target` (which is not a stable-reg receiver).
      let objIsThis = target.recv != nil and target.recv.kind == ThisExpr and
                      not target.recv.newTarget
      if rhsPure or objIsThis: c.borrowLocalOk = true
      let objReg = compileExpr(c, target.recv)
      if lhsPure: c.borrowLocalOk = true
      else:       c.borrowLocalOk = savedBorrow
      let v = compileExpr(c, node.value)
      c.borrowLocalOk = savedBorrow
      emit(c, instABC(StoreProp, objReg, uint8(ic), v))
      return v
    # --- Computed target: `obj[idx] = rhs` -> StoreElem ---------------
    if target.kind == Computed and node.assignOp == Eq:
      # Mirrors compile_property_target + the Eq arm: receiver, index,
      # then RHS into fresh temps; StoreElem obj, key, val (a=obj, b=key,
      # c=val). The assignment value is the RHS reg.
      let objReg = compileExpr(c, target.recv)
      let keyReg = compileExpr(c, target.index)
      let v = compileExpr(c, node.value)
      emit(c, instABC(StoreElem, objReg, keyReg, v))
      return v
    if target.kind != IdentExpr or node.assignOp != Eq:
      c.hadError = true
      return 0
    let name = c.slice(target.start, target.`end`)
    let localIdx = findLocalIndex(c, name)
    let capturedLocal = localIdx >= 0 and c.locals[localIdx].captured
    # Resolve to an OUTER captured local (inner closure assigning to the
    # enclosing function's captured var) when we have no local binding.
    var outerDepth: uint32 = 0
    if localIdx < 0:
      outerDepth = outerCaptureDepth(c, name)
      if outerDepth > 0: c.hasOuterRefs = true
    if localIdx < 0 and outerDepth == 0:
      # Global target (non-strict): the RHS is evaluated FIRST — and its
      # globals interned — BEFORE the target's slot, matching Zen-c's
      # GetValue-then-PutValue order so global-slot numbering stays canonical
      # (`a = b` → b=g108, a=g109). compiler.zc pins preferred_dst = -1 for
      # globals (the store reads the temp), so the RHS never takes a caller hint.
      # Strict-mode StoreGlobalStrict / with-object PutValue are later.
      let savedPd = c.preferredDst
      c.preferredDst = -1
      let r = compileExpr(c, node.value)
      c.preferredDst = savedPd
      let slot = internGlobal(c, name)
      emit(c, instAU16(StoreGlobal, r, uint16(slot)))
      return r
    # const bindings reject all later assignments (TypeError) -- later
    # slice; refuse for now so we don't emit an unguarded store.
    if localIdx >= 0 and c.locals[localIdx].isConst:
      c.hadError = true
      return 0
    # Captured / outer target: the store goes to an env PROPERTY, so the
    # RHS gets NO preferred-dst hint (StoreProp reads a temp), mirroring
    # compiler.zc's `c.preferred_dst = -1` for these arms (~2557).
    if capturedLocal:
      let savedPd = c.preferredDst
      c.preferredDst = -1
      let r = compileExpr(c, node.value)
      c.preferredDst = savedPd
      let er = envForLocal(c, localIdx)
      discard emitStorePropAtom(c, er, name, r)
      return r
    if outerDepth > 0:
      let savedPd = c.preferredDst
      c.preferredDst = -1
      let r = compileExpr(c, node.value)
      c.preferredDst = savedPd
      let envR = emitEnvChainWalk(c, outerDepth)
      discard emitStorePropAtom(c, envR, name, r)
      releaseReg(c, envR)
      return r
    let localReg = c.locals[localIdx].reg
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
    # ArrowFunc still bails (its creation-time `this` snapshot + concise
    # body are out of the slice-4b corpus); only plain FunctionExpr is
    # compiled here, now WITH the env-capturing MakeClosure form.
    if node.kind == ArrowFunc:
      c.hadError = true
      return 0
    # compile_function_value: compile the body into a fresh Function,
    # append it to OUR const pool, LoadConst it into a fresh reg. If the
    # inner referenced any outer-scope name (f.needsEnv carries the
    # inner's has_outer_refs), wrap it in MakeClosure with the current
    # env; otherwise the LoadConst reg IS the value (no wrap). Uses
    # allocReg, NOT allocDst. Mirrors compiler.zc compile_function_value.
    let f = compileFunction(c.src, node, c)
    if f == nil:
      c.hadError = true
      return allocReg(c)
    c.constants.add(Constant(kind: ckFunction, fn: f))
    let idx = uint16(c.constants.len - 1)
    let dst = allocReg(c)
    emit(c, instAU16(LoadConst, dst, idx))
    if f.needsEnv:
      let clsReg = allocReg(c)
      let env = closureEnvReg(c)
      emit(c, instABC(MakeClosure, clsReg, dst, env.reg))
      if env.isTemp: releaseReg(c, env.reg)
      releaseReg(c, dst)
      if c.nextReg <= clsReg: c.nextReg = clsReg + 1
      return clsReg
    return dst
  of Member:
    # `obj.name` -> LoadProp. Mirrors compile_member's IC fast path. The
    # IC slot is allocated BEFORE the receiver is compiled (outer-first
    # order). LoadProp reads obj before writing dst, so the receiver may
    # borrow; dst honors the caller's preferred-dst hint. OptionalMember
    # (`?.`) is a later slice -- refuse it (not in this arm).
    let name = c.slice(node.propStart, node.propStart + node.propLength)
    let ic = allocIcSlot(c, name)
    if ic > 255:
      c.hadError = true
      return 0
    let savedPd = c.preferredDst
    c.preferredDst = -1
    let savedBorrow = c.borrowLocalOk
    c.borrowLocalOk = true
    let objReg = compileExpr(c, node.recv)
    c.borrowLocalOk = savedBorrow
    c.preferredDst = savedPd
    let dst = allocDst(c)
    emit(c, instABC(LoadProp, dst, objReg, uint8(ic)))
    releaseReg(c, objReg)
    if c.nextReg <= dst: c.nextReg = dst + 1
    return dst
  of Computed:
    # `obj[idx]` -> LoadElem dst, objReg, idxReg. NO IC. Mirrors
    # compile_computed: receiver then index into fresh temps, LoadElem,
    # release both. OptionalComputed (`?.[]`) is a later slice.
    let objReg = compileExpr(c, node.recv)
    let idxReg = compileExpr(c, node.index)
    let dst = allocReg(c)
    emit(c, instABC(LoadElem, dst, objReg, idxReg))
    releaseReg(c, idxReg)
    releaseReg(c, objReg)
    if c.nextReg <= dst: c.nextReg = dst + 1
    return dst
  of Object:
    return compileObjectLiteral(c, node)
  of Array:
    return compileArrayLiteral(c, node)
  of Call:
    return compileCall(c, node)
  of New:
    return compileNew(c, node)
  of ThisExpr:
    # `new.target` (newTarget=true) reads fresh via LoadNewTarget — NOT
    # hoistable (the ctor-call flag flips across nested calls). Mirrors
    # compiler.zc's ThisExpr `node.bool_value` arm (~2179-2185).
    if node.newTarget:
      let dst = allocReg(c)
      emit(c, instA(LoadNewTarget, dst))
      return dst
    # Plain `this`: hand back the function-entry hoisted reg when
    # borrowLocalOk (the caller proved the value is consumed before any
    # re-bind — and this_reg is written once at frame entry anyway),
    # else a defensive Mov. compile_function always sets thisReg for a
    # body that uses `this`, so the LoadThis fallback (thisReg<0) never
    # fires here. Mirrors compiler.zc ~2187-2198.
    if c.thisReg >= 0:
      if c.borrowLocalOk:
        return uint8(c.thisReg)
      let dst = allocReg(c)
      emit(c, instAB(Mov, dst, uint8(c.thisReg)))
      return dst
    # No hoisted this_reg (shouldn't happen for a 4c body that uses
    # `this`, since compile_function reserves it) — fall back to LoadThis.
    let dst = allocReg(c)
    emit(c, instA(LoadThis, dst))
    return dst
  else:
    # Not yet supported.
    c.hadError = true
    return 0

# --- Object & array literals (mirrors compile_object/array_literal) --

proc objectPropKeyName(c: Compiler, prop: AstNode): string =
  ## The (decoded) key string for a plain `key: value` ObjectProp. For a
  ## quoted-string key the C strips the surrounding quotes and interns the
  ## RAW inner bytes -- no escape decoding (compiler.zc's "Real escape
  ## decoding is still TODO"), so `{"a\nb": 1}` keys on the 4 source bytes
  ## a,\,n,b. For an identifier / number key it's the raw slice. Returns
  ## "" only when the caller has already rejected the prop shape.
  let ks = prop.keyStart
  let kl = prop.keyLength
  if kl == 0: return ""
  let first = c.src[ks.int]
  if first == '"' or first == '\'':
    if kl < 2: return ""
    return c.slice(ks + 1, ks + kl - 1)
  return c.slice(ks, ks + kl)

proc compileObjectLiteral(c: var Compiler, node: AstNode): uint8 =
  ## `{ k: v, ... }` -> NewObject dst; per property LoadConst "k" into a
  ## key reg, compile the value, InitObjData dst, keyReg, valReg. Only
  ## plain `identifier: value` / `"string": value` / `number: value`
  ## props are compiled; every other shape (computed keys, shorthand,
  ## methods, get/set accessors, spread, __proto__) is DEFERRED -- bail to
  ## hadError so the file surfaces as nim_missing, never a false byte-
  ## match. Mirrors compile_object_literal's data-property path; the
  ## release_reg pattern lets each prop reuse the same key/val temps.
  let dst = allocReg(c)
  emit(c, instA(NewObject, dst))
  for prop in node.props:
    if c.hadError: return dst
    if prop == nil:
      c.hadError = true; return dst
    # Spread `{...x}` -> deferred.
    if prop.kind == Spread:
      c.hadError = true; return dst
    if prop.kind != ObjectProp:
      c.hadError = true; return dst
    # Computed key `[e]: v` (keyLength==0, computedKey set) -> deferred.
    if prop.computedKey != nil or prop.keyLength == 0:
      c.hadError = true; return dst
    # Method / get / set -> the value is a FunctionExpr synthesized by the
    # parser (`k(){}`, `get k(){}`). Deferred.
    if prop.propVal != nil and prop.propVal.kind == FunctionExpr:
      c.hadError = true; return dst
    # Shorthand `{a}` / shorthand-with-default `{a = e}`: the value is a
    # bare IdentExpr (or Assignment) whose slice coincides with the key.
    # The parser gives shorthand the same key/value slice; a default-
    # shorthand wraps an Assignment. Both are DEFERRED. `k: v` (data)
    # always has a distinct value slice or a non-ident/assignment value.
    if prop.propVal != nil and prop.propVal.kind == Assignment:
      c.hadError = true; return dst
    if prop.propVal != nil and prop.propVal.kind == IdentExpr and
       prop.propVal.start == prop.keyStart and
       prop.propVal.`end` == prop.keyStart + prop.keyLength:
      # Shorthand: value ident occupies the exact key slice.
      c.hadError = true; return dst
    # __proto__ colon-form proto setter -> deferred (SetProto path).
    let keyName = objectPropKeyName(c, prop)
    if keyName.len == 0:
      c.hadError = true; return dst
    let firstKeyByte = c.src[prop.keyStart.int]
    if keyName == "__proto__" and firstKeyByte != '"' and firstKeyByte != '\'':
      c.hadError = true; return dst
    # Data property: LoadConst key, compile value, InitObjData.
    c.constants.add(Constant(kind: ckString, s: keyName))
    let keyReg = allocReg(c)
    emit(c, instAU16(LoadConst, keyReg, uint16(c.constants.len - 1)))
    let valReg = compileExpr(c, prop.propVal)
    # ECMA-262 NamedEvaluation: an anonymous function on the RHS of
    # `{ key: <init> }` is named "key". (compile_object_literal calls
    # maybe_infer_anon_name for data props.)
    maybeInferAnonName(c, prop.propVal, valReg, keyName)
    emit(c, instABC(InitObjData, dst, keyReg, valReg))
    releaseReg(c, valReg)
    releaseReg(c, keyReg)
  if c.nextReg <= dst: c.nextReg = dst + 1
  return dst

proc compileArrayLiteral(c: var Compiler, node: AstNode): uint8 =
  ## `[e0, e1, ...]` -> pack elements into CONSECUTIVE registers, then
  ## `NewArray dst, firstReg, count` (a=base(dst), b=base, c=count). The
  ## result reuses base (the interpreter copies elements out before
  ## writing dst). Mirrors compile_array_literal's fixed-shape path. The
  ## empty `[]` case emits `NewArray dst, 0, 0`. Spread `[...x]`, holes
  ## `[1,,2]`, and large (>32) literals are DEFERRED -- bail.
  let count = node.elems.len
  if count == 0:
    let dst = allocReg(c)
    emit(c, instABC(NewArray, dst, 0, 0))
    return dst
  # Spread / hole / large -> deferred (dynamic-build path not ported).
  for el in node.elems:
    if el == nil or el.kind == Spread:
      c.hadError = true
      return allocReg(c)
  if count > 32:
    c.hadError = true
    return allocReg(c)
  # Reserve `count` consecutive slots for the elements.
  let base = c.nextReg
  for _ in 0 ..< count:
    discard allocReg(c)
  var j = 0
  while j < count:
    let elemReg = compileExpr(c, node.elems[j])
    let target = base + uint8(j)
    if elemReg != target:
      emit(c, instAB(Mov, target, elemReg))
      releaseReg(c, elemReg)
    j += 1
  emit(c, instABC(NewArray, base, base, uint8(count)))
  c.nextReg = base + 1
  if c.nextReg > c.maxReg: c.maxReg = c.nextReg
  return base

# --- Function / method / new calls (slice 5b) -----------------------
#
# The call-frame register discipline is the crux (compiler.zc
# compile_call_inner). A call reserves a CONTIGUOUS block starting at
# base = next_reg:
#   * plain call  -> regs[base]=callee, regs[base+1..]=args
#   * method call -> regs[base]=method, regs[base+1]=recv, regs[base+2..]=args
#   * new         -> regs[base]=callee, regs[base+1..]=args
# The result lands in `base` (or a ret_hint below base, #395), then temps
# free back to base+1 (or base when the result went to ret_hint).
#
# ret_hint == the outer preferred_dst: Invoke/MethodInvoke/NewInvoke carry
# an explicit ret_dst operand (inst.a), so `f(g())` and `x = f()` write the
# result straight into the target with NO post-call Mov. New itself never
# threads ret_hint (compiler.zc's New arm always returns base + a post-Mov).

# fusion_arg_is_pure: is this arg safe to evaluate AFTER the fused
# InvokeGlobal callee-slot is chosen? Whitelist: literals / this / a
# LOCAL ident (env slots are data props, no user code) / Paren / sign-not
# Unary / arithmetic-comparison-bitwise Binary over pure operands. A
# GLOBAL ident is IMPURE (its ObjectRecord fallback can invoke a
# globalThis accessor) -- so `f(a,b)` with global args does NOT fuse.
proc fusionArgIsPure(c: Compiler, node: AstNode): bool =
  if node == nil: return false
  case node.kind
  of NumberExpr, StringExpr, BoolExpr, NullExpr, UndefinedExpr, ThisExpr:
    return true
  of IdentExpr:
    let name = c.slice(node.start, node.`end`)
    return findLocalIndex(c, name) >= 0
  of Paren:
    return fusionArgIsPure(c, node.inner)
  of Unary:
    case node.unOp
    of Minus, Plus, Bang, Tilde:
      return fusionArgIsPure(c, node.operand)
    else:
      return false
  of Binary:
    if binaryOp(node.binOp) == Halt: return false
    return fusionArgIsPure(c, node.lhs) and fusionArgIsPure(c, node.rhs)
  else:
    return false

proc callArgsFusionPure(c: Compiler, node: AstNode): bool =
  for a in node.args:
    if not fusionArgIsPure(c, a): return false
  return true

proc callHasSpreadArg(node: AstNode): bool =
  for a in node.args:
    if a != nil and a.kind == Spread: return true
  return false

proc compileCallInner(c: var Compiler, node: AstNode, retHint: int): uint8 =
  let callee = node.callee
  let isMethod = callee != nil and (callee.kind == Member or callee.kind == Computed)
  let argCount = node.args.len

  # DEFER: spread args, super callee, optional chains -> bail (nim_missing).
  # Optional callee shapes are distinct node kinds (OptionalMember/
  # OptionalComputed) that never reach the Member/Computed compile arms.
  if callHasSpreadArg(node):
    c.hadError = true; return 0
  if callee != nil and callee.kind == SuperExpr:
    c.hadError = true; return 0
  if callee != nil and callee.kind in {OptionalMember, OptionalComputed, OptionalCall}:
    c.hadError = true; return 0
  # Math.sqrt/abs/floor/ceil intrinsic fusion is DEFERRED -- the plain
  # method-call path below still produces correct bytecode for those
  # (LoadGlobal+LoadProp+MethodInvoke), but the oracle would emit the
  # specialized op. So bail on the exact intrinsic shape to stay honest.
  if isMethod and callee.kind == Member and argCount == 1 and
     callee.recv != nil and callee.recv.kind == IdentExpr and
     c.slice(callee.recv.start, callee.recv.`end`) == "Math" and
     findLocalIndex(c, "Math") < 0:
    let mname = c.slice(callee.propStart, callee.propStart + callee.propLength)
    if mname in ["sqrt", "abs", "floor", "ceil"]:
      c.hadError = true; return 0

  if isMethod:
    # Method call: regs[base]=method, regs[base+1]=recv, regs[base+2..]=args.
    let slotsNeeded = 2 + argCount
    let base = c.nextReg
    for _ in 0 ..< slotsNeeded:
      discard allocReg(c)

    # Receiver into regs[base+1]. A bare-simple receiver places directly
    # (one Mov, no defensive temp); otherwise preferred_dst so the recv
    # expression's terminal op writes base+1 directly.
    if not tryPlaceSimple(c, callee.recv, base + 1):
      c.preferredDst = int(base + 1)
      let recvR = compileExpr(c, callee.recv)
      c.preferredDst = -1
      if recvR != base + 1:
        emit(c, instAB(Mov, base + 1, recvR))
        releaseReg(c, recvR)

    # Load the method into regs[base].
    if callee.kind == Member:
      let name = c.slice(callee.propStart, callee.propStart + callee.propLength)
      let ic = allocIcSlot(c, name)
      if ic > 255:
        c.hadError = true; return base
      emit(c, instABC(LoadProp, base, base + 1, uint8(ic)))
    else:
      # Computed: LoadElem regs[base], recv, key.
      let keyR = compileExpr(c, callee.index)
      emit(c, instABC(LoadElem, base, base + 1, keyR))
      releaseReg(c, keyR)

    # Args into regs[base+2..].
    var j = 0
    while j < argCount:
      let targetSlot = base + 2'u8 + uint8(j)
      if tryPlaceSimple(c, node.args[j], targetSlot):
        j += 1
        continue
      c.preferredDst = int(targetSlot)
      let argR = compileExpr(c, node.args[j])
      c.preferredDst = -1
      if argR != targetSlot:
        emit(c, instAB(Mov, targetSlot, argR))
        releaseReg(c, argR)
      j += 1

    # #395 result-targeting: a hinted result register becomes the ret_dst
    # operand (inst.a); the whole window frees. ret_hint is always below
    # base (allocated before the window).
    if retHint >= 0:
      emit(c, instABC(MethodInvoke, uint8(retHint), base, uint8(argCount)))
      c.nextReg = base
      if c.nextReg > c.maxReg: c.maxReg = c.nextReg
      return uint8(retHint)
    emit(c, instABC(MethodInvoke, base, base, uint8(argCount)))
    c.nextReg = base + 1
    if c.nextReg > c.maxReg: c.maxReg = c.nextReg
    return base

  # Plain call: regs[base] = callee, regs[base+1..] = args.
  let base = c.nextReg
  for _ in 0 .. argCount:            # base .. base+argCount inclusive
    discard allocReg(c)

  # Bare-local-ident callee places directly; otherwise preferred_dst=base
  # so a LoadGlobal/LoadProp/etc callee writes directly into the slot.
  let calleePlaced = tryPlaceSimple(c, node.callee, base)
  var r = base
  if not calleePlaced:
    c.preferredDst = int(base)
    r = compileExpr(c, node.callee)
    c.preferredDst = -1

  # #394 InvokeGlobal fusion. If the callee compiled to a single terminal
  # `LoadGlobal base, slot` AND every arg is pure, pop that LoadGlobal
  # (nothing references its slot yet) and remember the slot; the fused
  # 2-slot InvokeGlobal is emitted after the args. Tail-call rewriting is
  # deferred, so there's no tail_call_node guard (statement calls are not
  # in tail position; ReturnStmt call tails aren't in the slice-5b corpus).
  var fuseSlot = -1
  if r == base and c.code.len > 0 and
     c.code[c.code.len - 1].op == LoadGlobal and
     c.code[c.code.len - 1].a == base and
     node != c.tailCallNode and              # #394: don't fuse a tail call
     callArgsFusionPure(c, node):
    fuseSlot = int(instBcU16(c.code[c.code.len - 1]))
    c.code.setLen(c.code.len - 1)

  if r != base:
    emit(c, instAB(Mov, base, r))
    releaseReg(c, r)

  var j = 0
  while j < argCount:
    let targetSlot = base + 1'u8 + uint8(j)
    if tryPlaceSimple(c, node.args[j], targetSlot):
      j += 1
      continue
    c.preferredDst = int(targetSlot)
    let argR = compileExpr(c, node.args[j])
    c.preferredDst = -1
    if argR != targetSlot:
      emit(c, instAB(Mov, targetSlot, argR))
      releaseReg(c, argR)
    j += 1

  # #395 result-targeting -- see the MethodInvoke twin above.
  let ret = if retHint >= 0: uint8(retHint) else: base
  if fuseSlot >= 0:
    emit(c, instABC(InvokeGlobal, ret, base, uint8(argCount)))
    # Carrier: u16 global slot in a Jmp placeholder (the JmpIf*
    # convention). Never dispatched -- the handler skips past it.
    emit(c, instU16(Jmp, uint16(fuseSlot)))
  else:
    emit(c, instABC(Invoke, ret, base, uint8(argCount)))

  if retHint >= 0:
    c.nextReg = base
    if c.nextReg > c.maxReg: c.maxReg = c.nextReg
    return ret
  c.nextReg = base + 1
  if c.nextReg > c.maxReg: c.maxReg = c.nextReg
  return base

proc compileCall(c: var Compiler, node: AstNode): uint8 =
  # Outer's preferred_dst refers to the call's RESULT register -- not an
  # internal slot. Save + clear at the boundary so inner compile_expr calls
  # don't see a stale hint. #395: the hint threads through as ret_hint --
  # Invoke/MethodInvoke carry an explicit ret_dst operand, so the result
  # writes straight into the target with no post-call Mov. When inner takes
  # the hint (returns it), leave it consumed; otherwise restore.
  let outerPd = c.preferredDst
  c.preferredDst = -1
  let r = compileCallInner(c, node, outerPd)
  if outerPd >= 0 and r == uint8(outerPd):
    c.preferredDst = -1
  else:
    c.preferredDst = outerPd
  return r

proc compileNew(c: var Compiler, node: AstNode): uint8 =
  # `new F(args)`: reserve a contiguous block (callee + args), compile the
  # callee into base (a temp then Mov base<-callee -- New does NOT use
  # preferred_dst for the callee), args into base+1.., then NewInvoke.
  # New never threads ret_hint: it clears preferred_dst across the body and
  # always returns base (compiler.zc's New arm). DEFER spread new args.
  if callHasSpreadArg(node):
    c.hadError = true; return 0
  let newOuterPd = c.preferredDst
  c.preferredDst = -1

  let argCount = node.args.len
  let base = c.nextReg
  for _ in 0 .. argCount:            # base .. base+argCount inclusive
    discard allocReg(c)

  # Callee -- may be a Member (`new x.y()`); compileExpr handles both.
  let r = compileExpr(c, node.callee)
  if r != base:
    emit(c, instAB(Mov, base, r))
    releaseReg(c, r)

  var j = 0
  while j < argCount:
    let argR = compileExpr(c, node.args[j])
    let target = base + 1'u8 + uint8(j)
    if argR != target:
      emit(c, instAB(Mov, target, argR))
      releaseReg(c, argR)
    j += 1

  emit(c, instABC(NewInvoke, base, base, uint8(argCount)))
  c.nextReg = base + 1
  if c.nextReg > c.maxReg: c.maxReg = c.nextReg
  c.preferredDst = newOuterPd
  return base

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
      let cap = c.locals[lidx].captured
      let lreg = c.locals[lidx].reg
      if decl.init != nil:
        # Captured local: its value lives as an env property, not the
        # (wasted) register. The initializer gets NO preferred-dst hint
        # (StoreProp reads a temp), then `StoreProp env.x <- r`. Mirrors
        # compiler.zc ~7376-7386.
        if cap:
          let savedPd = c.preferredDst
          c.preferredDst = -1
          let r = compileExpr(c, decl.init)
          c.preferredDst = savedPd
          maybeInferAnonName(c, decl.init, r, name)
          let er = envForLocal(c, lidx)
          discard emitStorePropAtom(c, er, name, r)
          releaseReg(c, r)
        # #395: bare-simple initializer (local ident / number) is a
        # terminal read -- place directly into lreg, skipping the temp
        # and the tail Mov.
        elif tryPlaceSimple(c, decl.init, lreg):
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
    # A captured local lives on the env (a data property), not a
    # register, so it is NOT hole-seeded here — env-slot TDZ is stage-3
    # (compiler.zc ~7296 gates on `!captured`).
    for hi in 0 ..< c.locals.len:
      if c.locals[hi].scopeId == c.curScopeId and
         c.locals[hi].isTdz and not c.locals[hi].isParam and
         not c.locals[hi].captured:
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
    # function value (compiler.zc: nested FunctionDecls ALWAYS wrap). The
    # non-captures form emits the in-place `MakeClosure dst, dst, dst`
    # (dst doubles as fn-src AND env-src — zero extra register pressure);
    # a body that references outer scope (f.needsEnv) wraps with the
    # current env in a fresh reg. Finally bind: script-top -> DefineGlobal
    # on globalThis; a function-body decl -> Mov (or env StoreProp when
    # the decl name is itself captured) into its binding.
    let f = compileFunction(c.src, node, c)
    if f == nil:
      c.hadError = true
      return
    c.constants.add(Constant(kind: ckFunction, fn: f))
    let idx = uint16(c.constants.len - 1)
    var r = allocReg(c)
    emit(c, instAU16(LoadConst, r, idx))
    if not f.needsEnv:
      # Non-capturing form: in-place MakeClosure (dst=src=env).
      emit(c, instABC(MakeClosure, r, r, r))
    else:
      # The inner reads outer scope — wrap with the current env in a
      # fresh reg (compiler.zc ~7460-7467).
      let clsReg = allocReg(c)
      let env = closureEnvReg(c)
      emit(c, instABC(MakeClosure, clsReg, r, env.reg))
      if env.isTemp: releaseReg(c, env.reg)
      releaseReg(c, r)
      r = clsReg
    let name = c.slice(node.fnNameStart, node.fnNameStart + node.fnNameLen)
    let isScriptDecl = c.isScript
    if c.isFunction and not isScriptDecl:
      # Function/module body: bind to the pre-allocated local. A captured
      # decl name lives on the env object; otherwise into its register.
      let lidx = findLocalIndex(c, name)
      if lidx >= 0:
        if c.locals[lidx].captured:
          let er = envForLocal(c, lidx)
          discard emitStorePropAtom(c, er, name, r)
        else:
          emit(c, instAB(Mov, c.locals[lidx].reg, r))
    else:
      # Script-top FunctionDecl -> property on globalThis.
      let slot = internGlobal(c, name)
      emit(c, instAU16(DefineGlobal, r, uint16(slot)))
    releaseReg(c, r)
    resetTemps(c)
  of ReturnStmt:
    # `return expr` / `return;`. Slice 4c has no try/finally regions, so
    # emit_return_sequence reduces to a bare `Return r` (compiler.zc
    # emit_return_sequence with region_count == 0).
    # `return` outside a function is a SyntaxError; the parser accepts it
    # at program top, so refuse here rather than emit a bogus Return.
    if c.atProgramTop:
      c.hadError = true
      return
    var r: uint8
    if node.retArg != nil:
      # #394: a `return <call>` is a tail-call rewrite candidate. Flag the
      # Call node so compileCallInner skips InvokeGlobal fusion for it —
      # the TCO rewriter matches `last op == Invoke/MethodInvoke` in place,
      # and a fused 2-slot call there can't be rewritten. Nested calls in
      # the return expression compare unequal and still fuse. (region_count
      # == 0 always in this slice: no try/finally yet.)
      let isTailCandidate = node.retArg.kind == Call
      if isTailCandidate:
        c.tailCallNode = node.retArg
      # Borrow the source reg directly for a bare IdentExpr — Return
      # consumes the value immediately, so IdentExpr's defensive Mov is
      # dead weight (compiler.zc sets borrow_local_ok around the read).
      let savedBorrow = c.borrowLocalOk
      c.borrowLocalOk = true
      r = compileExpr(c, node.retArg)
      c.borrowLocalOk = savedBorrow
      c.tailCallNode = nil
      # Phase 3.9h-C tail-call optimization. If `return` returns a direct
      # call's result and the last emitted op is Invoke / MethodInvoke,
      # rewrite it to its Tail variant IN PLACE and STILL emit the trailing
      # Return (dead for ordinary callees — the Tail op replaces the frame
      # and breaks before Return runs). Mirrors compiler.zc ~8145-8170.
      if isTailCandidate and c.code.len > 0:
        let lastOp = c.code[c.code.len - 1].op
        if lastOp == Invoke:
          c.code[c.code.len - 1].op = TailInvoke
        elif lastOp == MethodInvoke:
          c.code[c.code.len - 1].op = TailMethodInvoke
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
    thisReg: -1, argumentsReg: -1,   # set in the prologue if the body uses them
    parent: addr enclosing,          # lexical chain for outer-capture resolution
    needsEnv: false, envReg: 0, hasOuterRefs: false, cachedOuterEnvReg: -1,
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

  # 2b. Capture analysis (slice 4b). Walk our body for nested functions;
  #     each free variable they reference that matches one of OUR locals
  #     marks that local `captured` and sets needsEnv. Reset the scope
  #     tracker first so ids line up with what collectLocals assigned
  #     (both walks must produce the same scope id at each syntactic
  #     point). Mirrors compiler.zc's analyze_captures pass.
  resetScopeWalk(c)
  for s in functionBodyStmts(node):
    analyzeCaptures(c, s)
  # 2c. Reset again so compileStmt below re-issues matching ids.
  resetScopeWalk(c)

  # 2b'. Transitive outer refs: does our body (including nested closures)
  #      reach past us into ancestor scope? Sets hasOuterRefs — we then
  #      either receive an env from our caller (we're a Closure) and/or
  #      forward one to our inner closures. Does NOT itself allocate an
  #      env (only needsEnv does). Mirrors compiler.zc 2b' / detect_outer_refs.
  if body != nil and c.parent != nil and detectOuterRefs(c, body):
    c.hasOuterRefs = true

  # 2c'. If we need an env object for OWN captures, reserve its register.
  #      Passthroughs (hasOuterRefs but no own captures) forward the
  #      caller's env at MakeClosure time — no allocation here.
  if c.needsEnv:
    c.envReg = allocReg(c)

  # 2d. `arguments` — if the body references it AND no local of that name
  #     was hoisted (a user `arguments` binding shadows the implicit one),
  #     reserve a register AFTER the params. The array itself is built by
  #     the BuildArguments prologue op below. Mirrors compiler.zc 2d
  #     (need_args → arguments_reg = alloc_reg). Slice 4c.
  let needArgs = body != nil and bodyUsesArguments(c, body) and
                 not hasArgumentsLocal(c)
  if needArgs:
    c.argumentsReg = int(allocReg(c))

  # 2e. `this` — if the body references plain `this` (not `new.target`),
  #     reserve a register AFTER params (and AFTER argumentsReg — matching
  #     compiler.zc's 2d-then-2e order). NO prologue op is emitted for
  #     `this`: the interpreter seeds regs[this_reg] from ctx.host_this on
  #     frame entry (compiler.zc ~2125-2130, "No prologue Op::LoadThis").
  let needThis = body != nil and bodyUsesThis(body)
  if needThis:
    c.thisReg = int(allocReg(c))

  # 2f. Hoist current-closure.env for a PASSTHROUGH (references outer
  #     captures but has no own env). emitEnvChainWalk's depth==1 then
  #     returns this stable reg and closureEnvReg forwards it, skipping a
  #     fresh LoadEnv per access. Mirrors compiler.zc 2f.
  if c.hasOuterRefs and not c.needsEnv:
    c.cachedOuterEnvReg = int(allocReg(c))

  # 3. Locals are now fixed; temps live above this watermark.
  c.fixedRegs = c.nextReg
  # Reset scope tracking so compileStmt re-enters block ids matching
  # what collectLocals assigned.
  resetScopeWalk(c)

  # 4a. `arguments` prologue: emit `BuildArguments argumentsReg` as the
  #     FIRST body op (compiler.zc ~4148). `this` gets no prologue op.
  if c.argumentsReg >= 0:
    emit(c, instA(BuildArguments, uint8(c.argumentsReg)))

  # 4a'. Seed the cached outer-env reg once (compiler.zc ~4153) so
  #      depth==1 chain walks and MakeClosure env operands read it directly.
  if c.cachedOuterEnvReg >= 0:
    emit(c, instA(LoadEnv, uint8(c.cachedOuterEnvReg)))

  # 4a''. Env construction (compiler.zc ~4232). `NewObject envReg`, then
  #       if we ALSO forward an outer env, chain it via the __outer__ key,
  #       then mirror each captured PARAM's value into the env by name
  #       (body let/const captured locals get stored when their VarDecl
  #       runs). No captured params reach this in the current corpus, but
  #       the loop mirrors compiler.zc's env-init exactly. __outer__ chain
  #       + captured-param mirroring only fire outside the tested shapes.
  if c.needsEnv:
    emit(c, instA(NewObject, c.envReg))
    if c.hasOuterRefs:
      # Chain to the enclosing env via the __outer__ key so deeper
      # closures reach past us. Out of the tested corpus (a function with
      # BOTH own captures AND transitive outer refs); refuse rather than
      # emit an unvalidated OUTER_ENV_KEY store.
      c.hadError = true
    else:
      var j = 0
      while j < c.locals.len:
        if c.locals[j].isParam and c.locals[j].captured and c.locals[j].name.len > 0:
          discard emitStorePropAtom(c, c.envReg, c.locals[j].name, c.locals[j].reg)
        inc j

  # 4. Function-top TDZ hole seeding. ECMA-262: a body-top let/const is
  #    seeded with LoadHole before its initializer. Params are never
  #    seeded (their value arrives from the caller). Unlike a nested
  #    block (which gates on blockNeedsEntryHole), the function-top seed
  #    is UNCONDITIONAL for every is_tdz non-param local — matching
  #    compiler.zc's `tz = param_count .. local_count` loop, which holes
  #    even locals that live in nested blocks (their block handler then
  #    decides whether to RE-hole).
  #    Captured locals live on the env (a data property), not a register,
  #    so they are NOT hole-seeded here (compiler.zc ~4346 skips captured).
  for li in 0 ..< c.locals.len:
    if c.locals[li].isTdz and not c.locals[li].isParam and not c.locals[li].captured:
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
    icCount: uint32(c.ics.len),
    ics: c.ics,
    # Repurposed: "body references an outer-scope name" (compiler.zc
    # ~4454). The ENCLOSING compiler reads this at MakeClosure to decide
    # whether to env-wrap us.
    needsEnv: c.hasOuterRefs,
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
    thisReg: -1, argumentsReg: -1,   # program top has no this/arguments regs
    parent: nil,                     # top-level program has no lexical parent
    needsEnv: false, envReg: 0, hasOuterRefs: false, cachedOuterEnvReg: -1,
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
  # Capture analysis: a top-level FunctionDecl/FunctionExpr may capture a
  # script-scope let/const, which then lives on a program-level env
  # object. collect-then-analyze (mirrors compile_program's script arm);
  # if any local is captured, reserve envReg BEFORE the result reg so the
  # layout matches (locals, env, then completion slot).
  resetScopeWalk(c)
  if root != nil and root.kind == Program:
    analyzeCaptures(c, root)
  if c.needsEnv:
    c.envReg = allocReg(c)
  # Reset scope tracking so compileStmt re-enters each block with the
  # same ids collectLocals just assigned.
  resetScopeWalk(c)

  # Reserve a stable program-result register (the completion slot).
  let resultReg = allocReg(c)
  emit(c, instA(LoadUndefined, resultReg))
  c.fixedRegs = resultReg + 1
  c.lastExprReg = int(resultReg)

  # Script-scope env construction: instantiate the env object right after
  # the result-reg prologue so subsequent captured-local VarDecls can
  # StoreProp into it. Mirrors compile_program ~8968.
  if c.needsEnv:
    emit(c, instA(NewObject, c.envReg))

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
    icCount: uint32(c.ics.len),
    ics: c.ics,
  )
  if f.registerCount == 0: f.registerCount = 1
  if f.fixedRegs > f.registerCount: f.fixedRegs = f.registerCount
  # Attach the shared global-name side table so disasm can print `; <name>`.
  for i in 0 ..< c.globals.names.len:
    f.globalNames.add(GlobalName(slot: c.globals.slots[i], name: c.globals.names[i]))
  return f
