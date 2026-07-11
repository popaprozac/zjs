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
import std/strutils
import ast, token
import bytecode

const
  ## User globals start at slot 108 in the disasm: built-ins occupy
  ## 0..107. Nim has no built-ins yet, so we stub the base here. This is
  ## the ONLY runtime-coupled constant in slice 1; revisit when built-ins
  ## land (base becomes a computed count, one place). See the Phase 3 plan.
  USER_GLOBAL_BASE* = 108'u32

  ## Per-class id base (slice 7d). The oracle assigns each user class a
  ## monotonically increasing id from a `ctx.class_id_counter` that is
  ## PRE-incremented at every `compile_class_value`: the first user class
  ## gets 25, the second 26, and so on. That base (24 before the first
  ## pre-increment) is runtime-coupled exactly like USER_GLOBAL_BASE=108 —
  ## it reflects how many internal classes the Zen-c runtime constructs
  ## before user code compiles. Nim has none yet, so we stub the base. The
  ## id is baked into every private-name mangle (`__zjs_priv_<id>_x`) and
  ## brand (`__zjs_brand_<id>`), so it must match the oracle's assignment
  ## ORDER (verify `class A{#a} class B{#b}` → 25/26, nested inner > outer).
  USER_CLASS_ID_BASE* = 25'u32

type
  ClassScope* = object
    ## One entry on the enclosing-class stack (mirrors compiler.zc's
    ## cls_stack_ids / cls_stack_names / cls_stack_kinds at a given depth).
    ## `id` is the class's assigned id; `names`/`kinds` are the parallel
    ## private-bound-name registry the resolver walks. Kind bits mirror the
    ## Zen-c encoding: 1=field, 2=method, 4=getter, 8=setter (a get+set pair
    ## is 4|8=12). Only the field kind (1) changes the PrivateCheck target
    ## (the mangled field atom vs the class brand). (Slice 7d.)
    id*:    uint32
    names*: seq[string]     ## bare private names (leading `#` stripped)
    kinds*: seq[uint8]

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
    ## Program-wide per-class id counter (slice 7d). Lives here — on the
    ## SHARED ref table — because the oracle's counter is `ctx.class_id_counter`,
    ## a single monotonic sequence spanning every class the whole compile
    ## encounters (sibling classes, nested classes inside method bodies).
    ## Pre-incremented at each compileClassValue; first class → 25. Seeded to
    ## USER_CLASS_ID_BASE-1 = 24 in compileProgram. (Mirrors compiler.zc 5038.)
    classIdCounter*: uint32

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

  UnwindRegion* = object
    ## One protected region open at the current compile point (mirrors
    ## `struct UnwindRegion` in src/compiler.zc, #402b). Slice 6b needs
    ## only two kinds:
    ##   * kind 0 = catch region — a plain try body, or the inner region
    ##     of try-catch-finally; unwinding it emits a runtime `LeaveTry`.
    ##   * kind 1 = finally-outer region — the finally body is inlined on
    ##     the way out (after the handler pop). `finallyBody` is the AST.
    ## `hasHandler` = a runtime EnterTry was emitted for it (always true
    ## for the two kinds here). The iterator-wrap kind 2 (for-of / pattern
    ## IterClose) is a later slice and not modeled.
    kind*:        uint8
    hasHandler*:  bool
    finallyBody*: AstNode
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
    ## Phase-4.8: distinguishes real iteration loops (while/do/for) from a
    ## switch frame (pushed ONLY to receive `break` patches). An unlabeled
    ## `continue` walks PAST non-iter frames to the enclosing loop, so
    ## `continue` inside a switch targets the surrounding for/while, not the
    ## switch. Default true; set false when pushing the switch frame (slice
    ## 6a). Mirrors compiler.zc LoopFrame.is_iter (#261).
    isIter*:          bool
    ## #402b: c.regionCount when this loop was pushed. A break/continue
    ## targeting this frame unwinds every region opened INSIDE the loop
    ## (index >= this) via emitUnwindRegions — LeaveTry for catch regions,
    ## BAIL for finally regions. Snapshotted in loopPush (slice 6b).
    regionDepthAtEntry*: int
    ## Slice 6c: the label attached to this frame by a preceding
    ## LabeledStmt (0/0 = unlabeled). loopPush picks it up from the
    ## compiler's pendingLabel and clears pending. A `break <label>` /
    ## `continue <label>` resolves to the frame whose (labelStart,
    ## labelLen) source-slice equals the target. Mirrors compiler.zc
    ## LoopFrame.label_start / label_length (339-340).
    labelStart*: uint32
    labelLen*:   uint32

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
    ## The `extends` expression of the class whose constructor body we are
    ## currently compiling (nil outside a derived-class ctor). Threaded from
    ## compileClassValue into the ctor's compileFunction and read by the
    ## `super(...)` compile arm to materialize the parent constructor (a
    ## LoadGlobal for `extends B`). Mirrors compiler.zc
    ## `c.enclosing_class_parent` — set on the outer compiler before the
    ## member compiles (~5033) and inherited by the child (~3929). Slice 7b.
    enclosingClassParent*: AstNode
    ## Slice 7d: the id of the class whose body we are currently compiling
    ## (-1 outside any class). Set on the outer compiler by compileClassValue
    ## before it compiles the members and INHERITED by every child ctor/method
    ## compiler (compileFunction copies it), so both emit the same
    ## `__zjs_priv_<id>_x` mangle + `__zjs_brand_<id>` for a given `#name`.
    ## Mirrors compiler.zc `c.enclosing_class_id`.
    enclosingClassId*: int
    ## Slice 7d: the enclosing-class scope stack (innermost LAST). Each frame
    ## is the class's id + its private-bound-name registry (name→kind). A
    ## `#name` access resolves by walking this stack innermost-outward for the
    ## declaring class (compiler.zc resolve_private / cls_stack_*). Copied into
    ## child compilers so a method body resolves names its class declared.
    clsStack*: seq[ClassScope]
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
    # --- Pending label for the NEXT loop frame (compiler.zc 207-208) ----
    ## Set by a LabeledStmt whose body is a loop, BEFORE compiling that
    ## body; the loop's loopPush picks it up into the frame and clears it.
    ## 0/0 = no pending label. Slice 6c.
    pendingLabelStart*: uint32
    pendingLabelLen*:   uint32
    # --- Unwind-region stack for try/catch/finally (compiler.zc #402b) --
    ## Innermost-LAST record of every protected region open at the current
    ## compile point. `regionCount` is the logical top (may be transiently
    ## lowered while a finally body compiles, so a return/break inside it
    ## can't re-inline itself — the compiler.zc truncation trick). It also
    ## doubles as the #326 tail-call suppressor: `return <call>` while
    ## `regionCount > 0` is NOT in tail position (a live handler must run
    ## first), so the InvokeGlobal fusion + TCO rewrite are suppressed.
    regions*: seq[UnwindRegion]
    regionCount*: int
    # NOTE: an abrupt completion (return/break/continue) crossing a
    # try→finally would need emit_unwind_regions to inline the finally body
    # (not ported this slice) — emitUnwindRegions sets hadError on a kind-1
    # region, surfacing the file as nim_missing instead of wrong bytecode.
    # --- Inline-cache name table (compiler.zc c.ics / c.ic_count) ------
    ## Per-function IC slots, keyed by property NAME. allocIcSlot dedups
    ## by decoded name: a repeated `.length`/`.prototype` access reuses
    ## the same slot (mirrors alloc_ic_slot's atom-pointer dedup). Index
    ## = IC slot, stored into Function.ics so disasm prints the name. The
    ## count becomes Function.icCount.
    ics*: seq[string]
    ## Slice 6d: destructuring-pattern mode flag. False = binding mode
    ## (leaf targets DECLARE a local/global — VarDecl / params); true =
    ## assignment mode (`({a}=b)` — leaf targets STORE to an existing
    ## lvalue). bindDestructureTarget branches on it. Mirrors compiler.zc
    ## Compiler.in_dstr_assign.
    inDstrAssign*: bool
    ## Slice 7e: this function body is a generator (`function*`). Drives the
    ## GeneratorStart prologue op and the Function.isGenerator header flag.
    ## Set by compileFunction from the node's gen flag; read nowhere else in
    ## the compile (the YieldExpr arm fires regardless — a yield outside a
    ## generator is a parse error). Mirrors compiler.zc Compiler.is_generator.
    isGenerator*: bool
    ## Slice 7e: this function body is async (`async function` / `async () =>`
    ## / async method). Drives the Function.isAsync header flag. Await fires
    ## regardless. Mirrors compiler.zc Compiler.is_async.
    isAsync*: bool
    ## Slice 7f: true while compiling a class STATIC element (static field
    ## initializer, static block, or a static-block Function body). In this
    ## context `super.x` resolves against the parent constructor DIRECTLY
    ## (the home object is the class constructor), NOT parent.prototype — so
    ## the member-super read/call arms skip the `.prototype` hop. Set by the
    ## static-element pass (compileClassValue) and by compileFunction for a
    ## StaticBlock body, inherited by nested bodies. Mirrors compiler.zc
    ## Compiler.in_static_element (~247).
    inStaticElement*: bool

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
    isIter: true,          # real iteration loop; switch frames flip to false
    regionDepthAtEntry: c.regionCount,   # #402b: unwind regions opened inside
    # Slice 6c: pick up a pending label from a preceding LabeledStmt, then
    # clear it so the next loop in the same scope starts unlabeled
    # (compiler.zc loop_push 524-529).
    labelStart: c.pendingLabelStart,
    labelLen:   c.pendingLabelLen,
  ))
  c.pendingLabelStart = 0
  c.pendingLabelLen = 0

proc findLabeledLoop(c: Compiler, nameStart, nameLen: uint32): int =
  ## Walk the loop stack top-down for a frame whose label source-slice
  ## equals the target label. Returns the frame index, or -1. Mirrors
  ## compiler.zc find_labeled_loop (573-587).
  if c.loopStack.len == 0 or nameLen == 0: return -1
  let target = c.src[nameStart.int ..< (nameStart + nameLen).int]
  var i = c.loopStack.len - 1
  while i >= 0:
    let fr = c.loopStack[i]
    if fr.labelLen == nameLen and nameLen > 0:
      if c.src[fr.labelStart.int ..< (fr.labelStart + fr.labelLen).int] == target:
        return i
    dec i
  -1

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

# --- Unwind-region stack (compiler.zc region_push / region_pop / ...) --
#
# `regionCount` is the logical top; the seq may hold stale slots below the
# cursor after a pop (compiler.zc keeps a flat array + count too). Push
# writes at index `regionCount` (growing the seq as needed) then bumps.

proc regionPush(c: var Compiler, kind: uint8, hasHandler: bool, body: AstNode) =
  let entry = UnwindRegion(kind: kind, hasHandler: hasHandler, finallyBody: body)
  if c.regionCount < c.regions.len:
    c.regions[c.regionCount] = entry
  else:
    c.regions.add(entry)
  c.regionCount += 1

proc regionPushCatch(c: var Compiler) =
  regionPush(c, 0'u8, true, nil)

proc regionPushFinally(c: var Compiler, body: AstNode) =
  regionPush(c, 1'u8, true, body)

proc regionPop(c: var Compiler) =
  if c.regionCount > 0: c.regionCount -= 1

proc emitUnwindRegions(c: var Compiler, targetDepth: int) =
  ## Emit the runtime exit sequence for leaving every region above
  ## `targetDepth`, innermost-first (mirrors compiler.zc
  ## emit_unwind_regions). Slice 6b ports ONLY the catch-region case: pop
  ## its handler with `LeaveTry`. A finally-outer region (kind 1) would
  ## need the finally body inlined here (with the region_count truncation
  ## trick) — NOT ported, so we BAIL (hadError) rather than emit divergent
  ## bytecode for an abrupt completion crossing a try→finally. The
  ## iterator-wrap kind 2 isn't modeled at all in this slice.
  var i = c.regionCount - 1
  while i >= targetDepth:
    let kind = c.regions[i].kind
    if kind == 1'u8:
      # Abrupt completion (return/break/continue) crossing a finally —
      # emit_unwind_regions must inline the finally body here. Deferred.
      c.hadError = true
      return
    if c.regions[i].hasHandler:
      emit(c, instA(LeaveTry, 0))
    dec i

proc emitReturnSequence(c: var Compiler, r: uint8) =
  ## The function-exit tail (compiler.zc emit_return_sequence): unwind
  ## every open region in nesting order, then `Return r`. `r` is protected
  ## across the unwind via fixedRegs (finally-body inlining could clobber
  ## temps — not reached in this slice since kind-1 bails). When
  ## regionCount == 0 this is just a bare `Return r` (the pre-6b behavior).
  if c.regionCount > 0:
    let savedFixed = c.fixedRegs
    if r + 1 > c.fixedRegs: c.fixedRegs = r + 1
    emitUnwindRegions(c, 0)
    c.fixedRegs = savedFixed
  emit(c, instA(Return, r))

proc emitYieldWithReturnDispatch(c: var Compiler, dst, src: uint8) =
  ## #402a (slice 7e): wrap a Yield with the return-completion dispatch. The
  ## JmpIfNotGenReturn MUST be the op right after Yield (the generator's
  ## saved_ip lands on it); a `.return(v)` resume falls through into the
  ## inline return path with v already in `dst`, while a normal resume takes
  ## the branch past the return sequence. Mirrors compiler.zc
  ## emit_yield_with_return_dispatch (~564-569).
  emit(c, instAB(Yield, dst, src))
  let skip = emit(c, instI16(JmpIfNotGenReturn, 0))
  emitReturnSequence(c, dst)
  patchJump(c, skip)

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

proc emitLoadNameString(c: var Compiler, name: string): uint8 =
  ## Materialize a string atom into a fresh register via LoadConst, returning
  ## the register (mirrors compiler.zc emit_load_name_string ~2736). Used by
  ## the member-super arms, which read `super.x` through a LoadElem keyed by
  ## a string CONST (not an IC slot) — the oracle's exact op shape.
  c.constants.add(Constant(kind: ckString, s: name))
  let r = allocReg(c)
  emit(c, instAU16(LoadConst, r, uint16(c.constants.len - 1)))
  return r

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

# --- Untagged-template escape validation (mirrors template_escapes_are_valid,
# compiler.zc ~3682). An invalid \x / \u / legacy-octal escape in an
# UNTAGGED template is a SyntaxError; the caller sets hadError so the case
# surfaces as nim-missing, never a false match. Only scans; decoding
# reuses decodeStringBody.
proc templateEscapesAreValid(src: string, start, length: uint32): bool =
  var i: uint32 = 0
  while i < length:
    let ch = src[int(start + i)]
    if ch != '\\':
      i += 1
      continue
    if i + 1 >= length: return false
    let nx = src[int(start + i + 1)]
    if nx == 'x':
      if i + 3 >= length: return false
      if hexVal(src[int(start + i + 2)]) < 0 or hexVal(src[int(start + i + 3)]) < 0:
        return false
      i += 4
      continue
    # Legacy octal / decimal escapes \1..\9, and \0 followed by a digit.
    if nx >= '1' and nx <= '9': return false
    if nx == '0' and i + 2 < length:
      let look = src[int(start + i + 2)]
      if look >= '0' and look <= '9': return false
    if nx == 'u':
      if i + 2 >= length: return false
      let after = src[int(start + i + 2)]
      if after == '{':
        var p: uint32 = i + 3
        var cp: uint32 = 0
        var sawDigit = false
        while p < length:
          let cc = src[int(start + p)]
          if cc == '}': break
          let d = hexVal(cc)
          if d < 0: return false
          cp = cp * 16 + uint32(d)
          if cp > 1114111'u32: return false
          sawDigit = true
          p += 1
        if not sawDigit: return false
        if p >= length or src[int(start + p)] != '}': return false
        i = p + 1
        continue
      else:
        if i + 5 >= length: return false
        if hexVal(src[int(start + i + 2)]) < 0 or hexVal(src[int(start + i + 3)]) < 0 or
           hexVal(src[int(start + i + 4)]) < 0 or hexVal(src[int(start + i + 5)]) < 0:
          return false
        i += 6
        continue
    # All other escapes are valid in a template body.
    i += 2
  true

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

# Compound-assignment operator token -> binary Op (mirrors the `op` ladder
# in compile_assignment / compile_assignment_to_property). Returns `Halt`
# for a token that isn't an arithmetic/bitwise compound assignment (the
# logical-assign `&&= ||= ??=` forms are handled separately upstream).
proc compoundAssignOp(tk: TokenKind): Op =
  case tk
  of PlusEq:    Add
  of MinusEq:   Sub
  of StarEq:    Mul
  of SlashEq:   Div
  of PercentEq: Mod
  of StarStarEq: Pow
  of AmpEq:     BitAnd
  of PipeEq:    BitOr
  of CaretEq:   BitXor
  of LtLtEq:    Shl
  of GtGtEq:    Shr
  of GtGtGtEq:  UShr
  else:         Halt

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
  of ThisExpr:
    # Plain `this` places directly with a single Mov from the hoisted
    # this-reg (compiler.zc try_place_simple ~1307-1312). `new.target`
    # (newTarget) is not hoisted, and a body with no this-reg falls back.
    if node.newTarget: return false
    if c.thisReg < 0: return false
    emit(c, instAB(Mov, slot, uint8(c.thisReg)))
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

proc collectPatternLocals(c: var Compiler, pat: AstNode) =
  ## Walk a binding pattern and register each contained name as a
  ## function/script-scope local, in source order (mirrors compiler.zc
  ## collect_pattern_locals). Recurses through nested patterns; each leaf
  ## IdentExpr allocs a fixed register at the CURRENT scope. Slice 6d:
  ## OBJECT patterns only (array patterns bail later at the compile site,
  ## but pre-registering their idents here is harmless — the compile pass
  ## sets hadError before any of them are used).
  if pat == nil: return
  case pat.kind
  of IdentExpr:
    discard allocAndAddLocalScoped(c, pat.start, pat.`end` - pat.start, c.curScopeId)
  of ObjectPattern, ArrayPattern:
    for entry in pat.patEntries:
      if entry != nil and entry.kind == PatternEntry and entry.patTarget != nil:
        collectPatternLocals(c, entry.patTarget)
  else:
    discard

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
      elif decl.declPattern != nil:
        # Destructuring declarator (`let {a} = …`). Pre-register every
        # name the pattern introduces (source order), then mark them TDZ
        # (+ const) for let/const — mirrors compiler.zc collect_locals'
        # `decl.third != NULL` arm. Snapshot the added range.
        let before = c.locals.len
        collectPatternLocals(c, decl.declPattern)
        if not isVarKind:
          for pli in before ..< c.locals.len:
            c.locals[pli].isTdz = true
            if node.declKind == KwConst: c.locals[pli].isConst = true
  of FunctionDecl:
    # Script-top FunctionDecl creates a globalThis property, NOT a
    # script-scope lexical binding (handled by the global emit path).
    # A function/module body registers the function-name local so
    # sibling statements resolve it (mirrors compiler.zc collect_locals'
    # FunctionDecl arm). The body has its own scope — don't recurse.
    if c.isFunction and not c.isScript and node.fnNameLen > 0:
      discard allocAndAddLocalScoped(c, node.fnNameStart, node.fnNameLen, 0'u32)
  of ClassDecl:
    # A ClassDecl is ALWAYS lexical, even at script-top (mirrors
    # compiler.zc collect_locals ~6925-6930). Register the class name as a
    # local in the CURRENT scope so the binding Mov (compileStmt ClassDecl)
    # resolves it. Its members have their own scopes — don't recurse.
    if c.isFunction and node.classNameLen > 0:
      discard allocAndAddLocalScoped(c, node.classNameStart, node.classNameLen, c.curScopeId)
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
  of LabeledStmt:
    # Descend into the labeled body so a `let`/`const` inside a labeled
    # block (`L: { let x; }`) gets its register pre-allocated in the same
    # walk order the compile pass uses. Mirrors compiler.zc collect_locals'
    # generic `node.left` descent for LabeledStmt (7060). Slice 6c.
    collectLocals(c, node.labeled)
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
  of SwitchStmt:
    # A switch's CaseBlock is ONE lexical scope shared by every clause, so
    # the case-body statements are collected in the CURRENT scope (a nested
    # BlockStmt inside a case still opens its own scope via its own arm).
    # Recurse into every case's body statements so a case-body `let`/`const`
    # (via a nested block) gets its register pre-allocated. Mirrors
    # compiler.zc collect_locals' SwitchStmt handling (case children walked
    # in the enclosing scope).
    for cnode in node.cases:
      if cnode != nil and cnode.kind == SwitchCase:
        for s in cnode.caseBody:
          collectLocals(c, s)
  of TryStmt:
    # Try/catch: a simple-identifier catch parameter binds as a local in
    # the current scope (mirrors compiler.zc collect_locals' TryStmt arm,
    # gated on c.is_function — true at both program-top-script and function
    # scope). This reserves the register that keeps numbering stable; the
    # ACTUAL catch-body binding is re-allocated in the TryStmt compile
    # handler (added_catch_local), so the collected slot is otherwise
    # unused (the same reserve-then-rebind pattern as captured locals).
    # A destructuring catch param (catchPattern) needs collect_pattern_locals
    # (not ported) — the compile handler BAILs on that shape, so leaving it
    # uncollected here is safe. Then descend all three blocks so nested
    # var/let/const get their registers.
    if c.isFunction and node.catchParamLen > 0:
      let nm = c.slice(node.catchParamStart, node.catchParamStart + node.catchParamLen)
      if findLocalIndex(c, nm) < 0:
        discard allocAndAddLocalScoped(c, node.catchParamStart, node.catchParamLen, c.curScopeId)
    collectLocals(c, node.tryBlock)
    collectLocals(c, node.catchBlock)
    collectLocals(c, node.finallyBlock)
  of Program:
    for s in node.stmts:
      collectLocals(c, s)
  else:
    discard

# --- Function shape gate + capture pre-scan (slice 4a / 4e) ---------
#
# The compilable param envelope grew across slices. 4a compiled ONLY
# plain-identifier params; 4e adds DEFAULT (`a = expr`) and REST
# (`...rest`) params (see paramsCompilable). Everything else must set
# hadError so the file surfaces as nim_missing (never a false
# byte-match): destructuring params (`{a}` / `[a]`), async / generator,
# and — the big one — a nested function that CAPTURES one of this
# function's locals (needs an env object: slice 4b). Non-capturing
# nested functions are fine and compile independently.

proc paramsAreSimple(params: seq[AstNode]): bool =
  ## Every formal is a plain identifier: no default (`=`), no binding
  ## pattern (`{}`/`[]`), no rest (`...`). Mirrors the parser's
  ## paramsAreSimple but also rejects rest (a RestParam node). Retained
  ## as the "no prologue needed" fast predicate for callers that want to
  ## know a param list is arity-only.
  for prm in params:
    if prm == nil: return false
    if prm.kind != IdentExpr: return false            # RestParam / pattern
    if prm.identDefault != nil: return false          # `a = 1`
    if prm.identPattern != nil: return false          # `{a}` / `[a]`
  return true

proc paramsCompilable(params: seq[AstNode]): bool =
  ## Slice 4e envelope: a param list compileFunction can lower. Permits
  ## plain-ident params, default params (`a = expr`), and a trailing rest
  ## param (`...rest`, an IdentExpr rest binding). BAILS on destructuring
  ## (a `{}`/`[]` pattern via identPattern, or a RestParam whose bound arg
  ## is a pattern) — the iterator / AssertCoercible fan-out is a separate
  ## slice. A default value that is itself a destructuring target lives on
  ## the default expr (compiled as a plain expression); only PARAM-position
  ## patterns are refused here.
  for prm in params:
    if prm == nil: return false
    case prm.kind
    of IdentExpr:
      # A destructuring binding surfaces as identPattern on the param.
      # Slice 6d permits an OBJECT-pattern param (`function f({x})`); slice
      # 6e adds an ARRAY-pattern param (`function f([x])`) — both fan out
      # through the same pattern-param path. A DEFAULTED pattern param
      # (`{x} = {}` / `[x] = []`) still bails: a pattern default's
      # undefined-check + AssertCoercible interleaving is untested here.
      if prm.identPattern != nil:
        if prm.identPattern.kind notin {ObjectPattern, ArrayPattern}: return false
        if prm.identDefault != nil: return false
    of RestParam:
      # Only a plain-ident rest binding is supported; `...[a]` / `...{a}`
      # need pattern fan-out (deferred). restArg is the bound target.
      let ra = prm.restArg
      if ra == nil: return false
      if ra.kind != IdentExpr: return false
      if ra.identPattern != nil: return false
    else:
      return false
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

proc catchBodyFnMentions(c: Compiler, n: AstNode, name: string): bool =
  ## Does any NESTED function (FunctionDecl/Expr/Arrow) inside `n` reference
  ## `name`? Used by the TryStmt handler to detect a catch parameter
  ## captured by a closure in the catch body — which needs env-object
  ## binding (out of the slice-6b corpus) so we BAIL. Only descends into
  ## function subtrees; a bare same-name mention outside a closure is fine
  ## (the register bind handles it).
  if n == nil: return false
  if n.kind in {FunctionDecl, FunctionExpr, ArrowFunc}:
    return subtreeMentionsName(c, n, name)
  for ch in childNodes(n):
    if catchBodyFnMentions(c, ch, name): return true
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
  ## The statement/expression body of a nested function node. A MethodDef
  ## (class constructor / method — slice 7a) shares the FunctionExpr shape:
  ## methodBody is the BlockStmt, methodParams the formals (mirrors
  ## compiler.zc, where MethodDef reuses node.left/node.children).
  if n == nil: return nil
  case n.kind
  of FunctionDecl, FunctionExpr: n.fnBody
  of ArrowFunc: n.arrowBody
  of MethodDef: n.methodBody
  of StaticBlock: n.staticBlockBody   # slice 7f: block compiled as its own fn
  else: nil

proc fnParamsOf(n: AstNode): seq[AstNode] =
  if n == nil: return @[]
  case n.kind
  of FunctionDecl, FunctionExpr: n.fnParams
  of ArrowFunc: n.arrowParams
  of MethodDef: n.methodParams
  of StaticBlock: @[]                 # slice 7f: a static block takes no params
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
proc compileFunction(src: string, node: AstNode, enclosing: var Compiler,
                     isClassCtor: bool = false): Function
# Object / array literals recurse into compileExpr (defined just below),
# so forward-declare them here.
proc compileExpr(c: var Compiler, node: AstNode): uint8
# UpdateExpression (`++x`/`--x`/`x++`/`x--`) codegen — the Unary (prefix) and
# Postfix arms both dispatch here; implemented after compileExpr.
proc compileUpdate(c: var Compiler, node: AstNode, isPrefix: bool): uint8
proc compileObjectLiteral(c: var Compiler, node: AstNode): uint8
proc compileArrayLiteral(c: var Compiler, node: AstNode): uint8
# compileObjectLiteral applies NamedEvaluation to anon-function values;
# maybeInferAnonName is defined later, so forward-declare it.
proc maybeInferAnonName(c: var Compiler, initExpr: AstNode, valReg: uint8,
                        targetName: string)
# Function / method / new calls (slice 5b). compileCall reads the outer
# preferred-dst as its ret_hint (mirrors compiler.zc compile_call).
proc compileCall(c: var Compiler, node: AstNode): uint8
# Object destructuring (slice 6d): the Assignment path (`({a}=b)`) calls
# destructurePattern, which is defined after maybeInferAnonName.
proc destructurePattern(c: var Compiler, pat: AstNode, srcReg: uint8)
proc compileNew(c: var Compiler, node: AstNode): uint8
# Class value (slice 7a): compiles a ClassDecl/ClassExpr to the register
# holding the constructor. Defined after compileFunction (which it calls
# for the ctor + each method), so forward-declare it here.
proc compileClassValue(c: var Compiler, node: AstNode): uint8

# --- Private-name machinery (slice 7d, mirrors compiler.zc ~4877-5006) ----
#
# A private member `#name` in class N is keyed on the mangled hidden atom
# `__zjs_priv_<classId>_<name-after-#>`. The class also carries a brand atom
# `__zjs_brand_<classId>` installed on every instance at construction; a
# private ACCESS emits Op::PrivateCheck against it (or, for a private FIELD,
# against the field's own mangled atom — §7.3.30 PrivateGet precision, the
# field isn't installed until its DefineField runs). All this comes "for
# free" through the existing StoreProp/LoadProp/DefineMethod paths ONCE the
# name is mangled and the classId is right, plus a PrivateCheck at each site.
# Defined here (before compileExpr) so the access-site compile arms can call
# them; internMethodNameAtom (the declaration-site mangler) lives near the
# class-value code and reuses manglePrivateWithId.

proc isPrivateName(c: Compiler, nameStart, nameLen: uint32): bool =
  ## `#`-prefixed. Mirrors compiler.zc is_private_name (~4877).
  nameLen > 0 and c.src[nameStart.int] == '#'

proc manglePrivateWithId(c: Compiler, nameStart, nameLen: uint32, classId: uint32): string =
  ## `__zjs_priv_<classId>_<body>` where body = name after the leading `#`.
  ## Mirrors compiler.zc mangle_with_id / mangle_private_name (~4931/4889).
  let body = c.slice(nameStart + 1, nameStart + nameLen)
  "__zjs_priv_" & $classId & "_" & body

proc brandAtomFor(classId: uint32): string =
  ## `__zjs_brand_<classId>`. Mirrors the emit_private_check snprintf (~4985).
  "__zjs_brand_" & $classId

proc resolvePrivate(c: Compiler, nameStart, nameLen: uint32,
                    outId: var uint32, outKind: var uint8): string =
  ## Resolve a `#name` ACCESS through the enclosing-class scope stack
  ## (innermost outward), returning the mangled atom for the DECLARING class
  ## and writing that class's id + the element's kind bits. An unmatched name
  ## returns "" (caller arms hadError: SyntaxError — private name must be
  ## declared in an enclosing class). Mirrors compiler.zc resolve_private (~4952).
  outId = 0; outKind = 0
  let bare = c.slice(nameStart + 1, nameStart + nameLen)
  var lvl = c.clsStack.len - 1
  while lvl >= 0:
    let sc = c.clsStack[lvl]
    for i in 0 ..< sc.names.len:
      if sc.names[i] == bare:
        outId = sc.id
        outKind = sc.kinds[i]
        return manglePrivateWithId(c, nameStart, nameLen, sc.id)
    dec lvl
  return ""    # caller sets hadError

proc emitPrivateCheck(c: var Compiler, objReg: uint8, classId: uint32) =
  ## `PrivateCheck objReg, <const idx>` where the const is the class brand
  ## atom. The const is added but never rendered by disasm (default branch
  ## prints only a/b/c/u16), so its index — driven by const-pool order — is
  ## what must match. Mirrors compiler.zc emit_private_check (~4980).
  c.constants.add(Constant(kind: ckString, s: brandAtomFor(classId)))
  let idx = uint16(c.constants.len - 1)
  emit(c, instAU16(PrivateCheck, objReg, idx))

proc emitPrivateAccessCheck(c: var Compiler, objReg: uint8, classId: uint32,
                            kind: uint8, mangled: string) =
  ## §7.3.30/31 precision: a private FIELD (kind==1) presence-checks its OWN
  ## mangled atom (it's installed one-at-a-time in textual order); a private
  ## method/accessor checks the class brand (installed all-at-once). Mirrors
  ## compiler.zc emit_private_access_check (~4998).
  if kind == 1'u8:
    c.constants.add(Constant(kind: ckString, s: mangled))
    let idx = uint16(c.constants.len - 1)
    emit(c, instAU16(PrivateCheck, objReg, idx))
    return
  emitPrivateCheck(c, objReg, classId)

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
  of TemplatePartExpr:
    # A raw literal segment of an untagged template (compiler.zc
    # compile_template_part ~3635): start/end are the RAW bounds (no
    # backticks). Validate escapes (invalid → SyntaxError → hadError), then
    # LoadConst the decoded body.
    let rawStart = node.start
    let rawLen = if node.`end` > node.start: node.`end` - node.start else: 0'u32
    if not templateEscapesAreValid(c.src, rawStart, rawLen):
      c.hadError = true
      return 0
    let s = decodeStringBody(c.src, rawStart, rawLen)
    c.constants.add(Constant(kind: ckString, s: s))
    let dst = allocReg(c)
    emit(c, instAU16(LoadConst, dst, uint16(c.constants.len - 1)))
    return dst
  of TemplateExpr:
    # Untagged template literal (compiler.zc compile_template_lit ~3880):
    # children alternate part / expr / part / … (both ends are parts).
    # Compile the first, then Add each subsequent child onto the running
    # accumulator — string concat once any operand is a string.
    if node.tparts.len == 0:
      c.constants.add(Constant(kind: ckString, s: ""))
      let dst = allocReg(c)
      emit(c, instAU16(LoadConst, dst, uint16(c.constants.len - 1)))
      return dst
    var acc = compileExpr(c, node.tparts[0])
    var i = 1
    while i < node.tparts.len:
      let nextR = compileExpr(c, node.tparts[i])
      let dst = allocReg(c)
      emit(c, instABC(Add, dst, acc, nextR))
      if nextR + 1 == c.nextReg: c.nextReg = c.nextReg - 1
      if acc + 1 == c.nextReg: c.nextReg = c.nextReg - 1
      acc = dst
      inc i
    return acc
  of Paren:
    return compileExpr(c, node.inner)
  of Unary:
    # slice 2b adds typeof / void / delete. ++/-- (PlusPlus/MinusMinus)
    # and unary `+` remain later slices -- refuse them so they surface as
    # nim-missing, never a false match.
    # --- delete (compiler.zc ~1918) ----------------------------------
    # `delete obj.name` / `delete obj[expr]` break the receiver + key out
    # (NOT the loaded value) and emit DeleteElem dst, objReg, keyReg. The
    # member key is a LoadConst of the property-name string (the ELEMENT
    # path, like compound member assignment). A bare-ident delete resolving
    # to a LOCAL emits LoadFalse; anything else (unresolved name / non-
    # reference) emits LoadTrue. `delete obj.#x` (private) is a SyntaxError
    # -> deferred. Only the plain Member/Computed/bare-ident shapes here.
    if node.unOp == KwDelete:
      var operand = node.operand
      # Walk through Paren wrappers to probe for a private member (early
      # SyntaxError -> refuse). is_private_name is a `#`-prefixed name.
      var probe = operand
      while probe != nil and probe.kind == Paren:
        probe = probe.inner
      if probe != nil and probe.kind == Member and probe.propLength > 0 and
         c.src[probe.propStart.int] == '#':
        c.hadError = true
        return 0
      if operand != nil and operand.kind == Member:
        let objReg = compileExpr(c, operand.recv)
        let name = c.slice(operand.propStart, operand.propStart + operand.propLength)
        c.constants.add(Constant(kind: ckString, s: name))
        let keyReg = allocReg(c)
        emit(c, instAU16(LoadConst, keyReg, uint16(c.constants.len - 1)))
        let dst = allocReg(c)
        emit(c, instABC(DeleteElem, dst, objReg, keyReg))
        releaseReg(c, keyReg)
        releaseReg(c, objReg)
        if c.nextReg <= dst: c.nextReg = dst + 1
        return dst
      if operand != nil and operand.kind == Computed:
        let objReg = compileExpr(c, operand.recv)
        let keyReg = compileExpr(c, operand.index)
        let dst = allocReg(c)
        emit(c, instABC(DeleteElem, dst, objReg, keyReg))
        releaseReg(c, keyReg)
        releaseReg(c, objReg)
        if c.nextReg <= dst: c.nextReg = dst + 1
        return dst
      # `delete bareIdent`: a local binding is non-deletable -> LoadFalse;
      # anything else -> LoadTrue. (OptionalMember/OptionalComputed and
      # other non-reference operands fall to the LoadTrue path.)
      if operand != nil and operand.kind == IdentExpr:
        let nm = c.slice(operand.start, operand.`end`)
        if findLocalIndex(c, nm) >= 0:
          let dst = allocReg(c)
          emit(c, instA(LoadFalse, dst))
          return dst
      let dst = allocReg(c)
      emit(c, instA(LoadTrue, dst))
      return dst
    # --- typeof (compiler.zc ~1978) ----------------------------------
    # `typeof bareGlobal` must NOT throw on an undeclared name: detect an
    # IdentExpr operand (unwrapping Paren) resolving to NO local/outer and
    # load via LoadGlobalOrUndefined, then Typeof. Non-ident (or local/
    # outer) operands compile normally then Typeof.
    if node.unOp == KwTypeof and node.operand != nil:
      var operand = node.operand
      while operand != nil and operand.kind == Paren:
        operand = operand.inner
      if operand != nil and operand.kind == IdentExpr:
        let nm = c.slice(operand.start, operand.`end`)
        let localIdx = findLocalIndex(c, nm)
        var outerIdx = -1
        if localIdx < 0 and c.parent != nil:
          let oi = findLocalIndex(c.parent[], nm)
          if oi >= 0 and c.parent[].locals[oi].captured: outerIdx = oi
        if localIdx < 0 and outerIdx < 0:
          let slot = internGlobal(c, nm)
          let srcG = allocReg(c)
          emit(c, instAU16(LoadGlobalOrUndefined, srcG, uint16(slot)))
          let dstG = allocReg(c)
          emit(c, instAB(Typeof, dstG, srcG))
          releaseReg(c, srcG)
          if c.nextReg <= dstG: c.nextReg = dstG + 1
          return dstG
    # --- typeof (non-ident) / void / arithmetic-negate family --------
    case node.unOp
    of Minus, Plus, Bang, Tilde, KwTypeof, KwVoid:
      # Unary `+` (Plus) joins the family in slice 3: it is ToNumber(x),
      # lowered to `x - 0` (SubImm) below — the SubImm handler runs the
      # same coercion ladder (true→1, "5"→5) as zjs_arith_sub.
      discard
    of PlusPlus, MinusMinus:
      # Prefix `++x` / `--x`: shared UpdateExpression codegen, returns the
      # NEW value. (Postfix `x++`/`x--` is a separate NodeKind.Postfix arm.)
      return compileUpdate(c, node, isPrefix = true)
    else:
      c.hadError = true
      return 0
    let src = compileExpr(c, node.operand)
    # void <expr>: evaluate the operand (done) then yield undefined.
    if node.unOp == KwVoid:
      releaseReg(c, src)
      let dst = allocReg(c)
      emit(c, instA(LoadUndefined, dst))
      return dst
    # typeof <non-ident-expr>: Typeof dst, src.
    if node.unOp == KwTypeof:
      let dst = allocReg(c)
      emit(c, instAB(Typeof, dst, src))
      releaseReg(c, src)
      return dst
    # Unary plus: ToNumber(x) via `x - 0` (SubImm dst, src, 0) — matches
    # compiler.zc ~2014-2024.
    if node.unOp == Plus:
      let dst = allocReg(c)
      emit(c, instABC(SubImm, dst, src, 0))
      releaseReg(c, src)
      if c.nextReg <= dst: c.nextReg = dst + 1
      return dst
    let dst = allocReg(c)
    let op =
      case node.unOp
      of Minus: Neg
      of Bang:  LogicalNot
      else:     BitNot        # Tilde
    emit(c, instABC(op, dst, src, 0))
    return dst
  of Binary:
    # `in` / `instanceof` are keyword tokens routed through Binary (they
    # aren't arithmetic ops, so binaryOp returns Halt). Mirrors compiler.zc
    # ~2066-2100. Slice 7d handles the `#x in obj` brand-check special case;
    # the general `a in b` / `a instanceof b` forms are a straightforward
    # In/Instanceof emit.
    if node.binOp == KwIn or node.binOp == KwInstanceof:
      # Brand check `#x in obj`: the parser builds a Member with recv==nil
      # holding the `#x` slice. Resolve to the mangled atom, LOAD it as the
      # LHS (a string const), then `In dst, lhsAtom, rhsObj` tests existence
      # of that hidden key. Mirrors compiler.zc ~2070-2091.
      if node.binOp == KwIn and node.lhs != nil and node.lhs.kind == Member and
         node.lhs.recv == nil and
         isPrivateName(c, node.lhs.propStart, node.lhs.propLength):
        var inId: uint32
        var inKind: uint8
        let mangled = resolvePrivate(c, node.lhs.propStart, node.lhs.propLength, inId, inKind)
        if mangled.len == 0:
          c.hadError = true
          return 0
        c.constants.add(Constant(kind: ckString, s: mangled))
        let l = allocReg(c)
        emit(c, instAU16(LoadConst, l, uint16(c.constants.len - 1)))
        let r = compileExpr(c, node.rhs)
        let dst = allocReg(c)
        emit(c, instABC(In, dst, l, r))
        releaseReg(c, r)
        releaseReg(c, l)
        if c.nextReg <= dst: c.nextReg = dst + 1
        return dst
      let l = compileExpr(c, node.lhs)
      let r = compileExpr(c, node.rhs)
      let dst = allocReg(c)
      let op = if node.binOp == KwIn: In else: Instanceof
      emit(c, instABC(op, dst, l, r))
      releaseReg(c, r)
      releaseReg(c, l)
      if c.nextReg <= dst: c.nextReg = dst + 1
      return dst
    let opKind = binaryOp(node.binOp)
    if opKind == Halt:
      # Any remaining unsupported binary op -- later slices.
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
  of Logical:
    # Short-circuit `a && b` / `a || b` / `a ?? b`. Compile the LHS into a
    # WRITABLE result reg (`dst`), branch PAST the RHS on short-circuit,
    # then compile the RHS into a fresh reg and `Mov dst <- rhs`. The LHS
    # and RHS share the SAME dst. Because we scribble the RHS through dst,
    # it must NOT be a borrowed local reg, and no outer preferred-dst hint
    # may reach it: clear borrowLocalOk + preferredDst around the LHS read
    # (restored after). Mirrors compiler.zc compile_logical (~2278).
    let savedBorrow = c.borrowLocalOk
    let savedPd = c.preferredDst
    c.borrowLocalOk = false
    c.preferredDst = -1
    let dst = compileExpr(c, node.lhs)
    let jmpOp =
      case node.binOp
      of PipePipe:         JmpIfTrue
      of QuestionQuestion: JmpIfNotNullish
      else:                JmpIfFalse    # AmpAmp
    let jmpIdx = emit(c, instAI16(jmpOp, dst, 0))
    let savedNext = c.nextReg
    let rhs = compileExpr(c, node.rhs)
    emit(c, instAB(Mov, dst, rhs))
    c.nextReg = savedNext
    patchJump(c, jmpIdx)
    c.borrowLocalOk = savedBorrow
    c.preferredDst = savedPd
    return dst
  of Conditional:
    # `test ? consequent : alternate`. Materialize both branches into the
    # SAME register (dst); JmpIfFalse skips the consequent. An outer
    # preferred-dst hint (e.g. from `result = cond ? a : result + b`) would
    # cause the first inner alloc_dst to clobber the hint target before the
    # alt branch reads it, so save+clear here (the Conditional uses
    # alloc_reg, not the hint). The condition is compiled as a plain
    # expression + JmpIfFalse -- it does NOT fuse relational compares (the
    # oracle emits Cmp* + JmpIfFalse, not JmpIfNot*). Mirrors compiler.zc
    # Conditional arm (~2206).
    let savedPd = c.preferredDst
    c.preferredDst = -1
    let dst = allocReg(c)
    let testR = compileExpr(c, node.cond)
    let jmpElse = emit(c, instAI16(JmpIfFalse, testR, 0))
    releaseReg(c, testR)
    let savedNext = c.nextReg
    let consR = compileExpr(c, node.conseq)
    if consR != dst: emit(c, instAB(Mov, dst, consR))
    c.nextReg = savedNext
    let jmpEnd = emit(c, instI16(Jmp, 0))
    patchJump(c, jmpElse)
    let altR = compileExpr(c, node.alt)
    if altR != dst: emit(c, instAB(Mov, dst, altR))
    c.nextReg = savedNext
    patchJump(c, jmpEnd)
    if c.nextReg <= dst: c.nextReg = dst + 1
    c.preferredDst = savedPd
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
    # --- Destructuring assignment: `({a, b} = src)` -> pattern fan-out --
    # Only plain `=` permits patterns (the parser only reinterprets an
    # Object/Array LHS under Eq). The RHS evaluates ONCE into `r`;
    # destructurePattern in assignment mode dispatches each target through
    # the LHS-expression store chain. Returns the RHS reg (the assignment's
    # value). ArrayPattern targets bail inside destructurePattern.
    if target.kind in {ObjectPattern, ArrayPattern} and node.assignOp == Eq:
      let r = compileExpr(c, node.value)
      let saved = c.inDstrAssign
      c.inDstrAssign = true
      destructurePattern(c, target, r)
      c.inDstrAssign = saved
      return r
    if target.kind == ArrayPattern:
      # Array destructuring with a compound assign op — separate slice.
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
      # Slice 7d: `this.#x = rhs` — resolve to the mangled atom for the IC.
      # The PrivateCheck (if any) runs AFTER the RHS evaluates (§13.15.2 step
      # order), and is SKIPPED for the parser-synthesized field-init
      # (assignIsFieldInit — compiler.zc's `target.num != 1.0` guard), whose
      # StoreProp CREATES the mangled own prop. Writing a private method
      # (kind==2) or getter-only accessor (kind==4) is a TypeError — deferred.
      var name: string
      var isPriv = false
      var privId: uint32
      var privKind: uint8
      if isPrivateName(c, target.propStart, target.propLength):
        name = resolvePrivate(c, target.propStart, target.propLength, privId, privKind)
        if name.len == 0:
          c.hadError = true
          return 0
        if not node.assignIsFieldInit and privKind in {2'u8, 4'u8}:
          c.hadError = true      # write to private method / getter-only — deferred
          return 0
        isPriv = true
      else:
        name = c.slice(target.propStart, target.propStart + target.propLength)
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
      # PrivateSet presence check — after RHS, before StoreProp; not for the
      # synthesized DefineField (creates the prop). Mirrors compiler.zc 3171.
      if isPriv and not node.assignIsFieldInit:
        emitPrivateAccessCheck(c, objReg, privId, privKind, name)
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
    # --- Compound member/computed target: `obj.x op= rhs` / `obj[i] op= rhs`
    # Mirrors compile_assignment_to_property's compound path. QUIRK: even a
    # Member target goes through the ELEMENT path (LoadConst key + LoadElem/
    # StoreElem), NOT the IC LoadProp/StoreProp. compile_property_target
    # loads receiver into obj_r then the key (LoadConst for Member, index
    # expr for Computed); then LoadElem cur, op, StoreElem. Logical-assign
    # (`&&= ||= ??=`) is deferred here.
    if (target.kind == Member or target.kind == Computed) and node.assignOp != Eq:
      let op = compoundAssignOp(node.assignOp)
      if op == Halt:
        c.hadError = true      # logical-assign / unknown -- deferred
        return 0
      # Private member (`obj.#x op= rhs`) -> deferred.
      if target.kind == Member and target.propLength > 0 and
         c.src[target.propStart.int] == '#':
        c.hadError = true
        return 0
      # compile_property_target: obj_r then key_r.
      let objReg = compileExpr(c, target.recv)
      var keyReg: uint8
      if target.kind == Member:
        let name = c.slice(target.propStart, target.propStart + target.propLength)
        c.constants.add(Constant(kind: ckString, s: name))
        keyReg = allocReg(c)
        emit(c, instAU16(LoadConst, keyReg, uint16(c.constants.len - 1)))
      else:
        keyReg = compileExpr(c, target.index)
      # cur = LoadElem obj_r, key_r; rhs; op dst, cur, rhs; StoreElem.
      let cur = allocReg(c)
      emit(c, instABC(LoadElem, cur, objReg, keyReg))
      let rhsR = compileExpr(c, node.value)
      let dst = allocReg(c)
      emit(c, instABC(op, dst, cur, rhsR))
      emit(c, instABC(StoreElem, objReg, keyReg, dst))
      releaseReg(c, rhsR)
      releaseReg(c, cur)
      if c.nextReg <= dst: c.nextReg = dst + 1
      return dst
    if target.kind != IdentExpr:
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
    # --- Compound ident assignment: `a op= rhs` (op != Eq) ------------
    # Mirrors compile_assignment's compound path (~2594): load current
    # value into `cur`, compile rhs, `op dst, cur, rhs`, store back, return
    # dst. Uses the GENERAL binary op (no imm fusion -- `a += 1` emits a
    # LoadInt + Add, not AddImm). Logical-assign (`&&= ||= ??=`) and const
    # targets are deferred. TDZ ThrowIfHole is out of the current corpus
    # (a body-top compound assign to an uninitialized let); refuse it.
    if node.assignOp != Eq:
      let op = compoundAssignOp(node.assignOp)
      if op == Halt:
        c.hadError = true      # logical-assign / unknown -- deferred
        return 0
      # const target -> TypeError guard (later slice); refuse.
      if localIdx >= 0 and c.locals[localIdx].isConst:
        c.hadError = true
        return 0
      # cur = current value (local Mov / captured-env LoadProp / outer-env
      # LoadProp / global LoadGlobal).
      let cur = allocReg(c)
      if localIdx >= 0:
        if capturedLocal:
          let er = envForLocal(c, localIdx)
          discard emitLoadPropAtom(c, cur, er, name)
        else:
          # A TDZ-uninitialized local would need a ThrowIfHole guard; out
          # of the current corpus -- refuse rather than emit an unguarded
          # load. (Params + initialized locals are fine.)
          if c.locals[localIdx].isTdz:
            c.hadError = true
            return cur
          emit(c, instAB(Mov, cur, c.locals[localIdx].reg))
      elif outerDepth > 0:
        let envR = emitEnvChainWalk(c, outerDepth)
        discard emitLoadPropAtom(c, cur, envR, name)
        releaseReg(c, envR)
      else:
        let slot = internGlobal(c, name)
        emit(c, instAU16(LoadGlobal, cur, uint16(slot)))
      # rhs, then the binary op into a fresh dst, then store back.
      let rhsR = compileExpr(c, node.value)
      let dst = allocReg(c)
      emit(c, instABC(op, dst, cur, rhsR))
      if localIdx >= 0:
        if capturedLocal:
          let er = envForLocal(c, localIdx)
          discard emitStorePropAtom(c, er, name, dst)
        else:
          emit(c, instAB(Mov, c.locals[localIdx].reg, dst))
      elif outerDepth > 0:
        let envR = emitEnvChainWalk(c, outerDepth)
        discard emitStorePropAtom(c, envR, name, dst)
        releaseReg(c, envR)
      else:
        let slot = internGlobal(c, name)
        emit(c, instAU16(StoreGlobal, dst, uint16(slot)))
      releaseReg(c, rhsR)
      releaseReg(c, cur)
      if c.nextReg <= dst: c.nextReg = dst + 1
      return dst
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
    # compile_function_value: compile the body into a fresh Function,
    # append it to OUR const pool, LoadConst it into a fresh reg. If the
    # inner referenced any outer-scope name (f.needsEnv carries the
    # inner's has_outer_refs) — OR it's an ARROW — wrap it in MakeClosure
    # with the current env; otherwise the LoadConst reg IS the value (no
    # wrap). Uses allocReg, NOT allocDst. Mirrors compiler.zc
    # compile_function_value.
    #
    # Arrows ALWAYS wrap (compiler.zc ~4538 `if f.needs_env || f.is_arrow`)
    # even when non-capturing: MakeClosure is where the creation-time
    # `this` snapshot lands (cl.captured_this). A bare `() => 1` reads no
    # outer scope but still needs the wrap so the arrow's `this`/`arguments`
    # bind lexically to the enclosing frame. For a non-capturing arrow the
    # env operand is closureEnvReg = 0 (unused by the closure).
    let f = compileFunction(c.src, node, c)
    if f == nil:
      c.hadError = true
      return allocReg(c)
    c.constants.add(Constant(kind: ckFunction, fn: f))
    let idx = uint16(c.constants.len - 1)
    let dst = allocReg(c)
    emit(c, instAU16(LoadConst, dst, idx))
    if f.needsEnv or f.isArrow:
      let clsReg = allocReg(c)
      let env = closureEnvReg(c)
      emit(c, instABC(MakeClosure, clsReg, dst, env.reg))
      if env.isTemp: releaseReg(c, env.reg)
      releaseReg(c, dst)
      if c.nextReg <= clsReg: c.nextReg = clsReg + 1
      return clsReg
    return dst
  of Member:
    # Slice 7f: `super.x` (bare property read) — the receiver is a SuperExpr.
    # Read the property off the enclosing class's parent: instance context →
    # `parent.prototype.x`; static context → `parent.x` directly. The lookups
    # are LoadElem keyed by string CONSTS (emitLoadNameString), NOT IC slots
    # — the oracle's exact shape (compiler.zc compile_member ~2827-2851). A
    # `super.x` outside a class-with-parent (enclosingClassParent == nil) is a
    # SyntaxError (bail), matching the C guard.
    if node.recv != nil and node.recv.kind == SuperExpr:
      if c.enclosingClassParent == nil:
        c.hadError = true
        return allocReg(c)
      # `super.#x` — a PrivateName on SuperProperty is a SyntaxError
      # (ECMA-262 — the Nim parser doesn't reject it, so bail here to match
      # the oracle's parse error instead of over-accepting).
      if isPrivateName(c, node.propStart, node.propLength):
        c.hadError = true
        return allocReg(c)
      let parentR = compileExpr(c, c.enclosingClassParent)
      var holderR = parentR
      if not c.inStaticElement:
        let protoKey = emitLoadNameString(c, "prototype")
        holderR = allocReg(c)
        emit(c, instABC(LoadElem, holderR, parentR, protoKey))
        if protoKey + 1 == c.nextReg: c.nextReg = c.nextReg - 1
        if parentR != holderR and parentR + 1 == c.nextReg: c.nextReg = c.nextReg - 1
      let name = c.slice(node.propStart, node.propStart + node.propLength)
      let keyR = emitLoadNameString(c, name)
      let dst = allocDst(c)
      emit(c, instABC(LoadElem, dst, holderR, keyR))
      if keyR + 1 == c.nextReg: c.nextReg = c.nextReg - 1
      if holderR + 1 == c.nextReg: c.nextReg = c.nextReg - 1
      if c.nextReg <= dst: c.nextReg = dst + 1
      return dst
    # `obj.name` -> LoadProp. Mirrors compile_member's IC fast path. The
    # IC slot is allocated BEFORE the receiver is compiled (outer-first
    # order). LoadProp reads obj before writing dst, so the receiver may
    # borrow; dst honors the caller's preferred-dst hint. OptionalMember
    # (`?.`) is a later slice -- refuse it (not in this arm).
    # Slice 7d: `this.#x` — the property is a PrivateName. Resolve it to the
    # mangled `__zjs_priv_<id>_x` atom (the IC name), then emit a PrivateCheck
    # on the receiver BEFORE the LoadProp (compiler.zc ~2863-2903). A getter-
    # only accessor read is a TypeError (kind==8) — out of the 7d corpus, bail.
    var name: string
    var isPriv = false
    var privId: uint32
    var privKind: uint8
    if isPrivateName(c, node.propStart, node.propLength):
      name = resolvePrivate(c, node.propStart, node.propLength, privId, privKind)
      if name.len == 0:
        c.hadError = true      # unresolved private name — SyntaxError
        return 0
      if privKind == 8'u8:     # setter-only private accessor read — deferred
        c.hadError = true
        return 0
      isPriv = true
    else:
      name = c.slice(node.propStart, node.propStart + node.propLength)
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
    if isPriv:
      emitPrivateAccessCheck(c, objReg, privId, privKind, name)
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
  of ClassExpr:
    # `class {}` / `class Name {}` as an expression value (slice 7a).
    # compileClassValue returns the register holding the constructor;
    # NamedEvaluation at the assignment site (maybeInferAnonName) sets an
    # anonymous class-expression's .name. Mirrors compiler.zc ~2200.
    return compileClassValue(c, node)
  of AwaitExpr:
    # `await x` (slice 7e). Compile the operand into a reg, then
    # `Await dst <- src`. The dst is a fresh temp (allocReg, not allocDst —
    # a live preferred-dst hint must not be stolen). Mirrors compiler.zc
    # ~1869-1875. The src-release peephole (`if src+1==next_reg && src!=dst`)
    # frees the operand temp when it was the top reg — matching the C exactly.
    let src = compileExpr(c, node.awaitArg)
    let dst = allocReg(c)
    emit(c, instAB(Await, dst, src))
    if src + 1 == c.nextReg and src != dst: c.nextReg = c.nextReg - 1
    return dst
  of YieldExpr:
    # `yield` / `yield expr` / `yield* expr` (slice 7e). Mirrors compiler.zc
    # ~1890-1913. yield* (delegating) DEFERS — its iterator-delegation loop
    # (IterGet + step/await/yield) is a separate slice; bail so the file
    # surfaces as nim_missing rather than a wrong suspend sequence.
    if node.yieldDelegate:
      c.hadError = true
      return 0
    # Plain `yield` (bare or with operand). Bare `yield` yields undefined.
    var src: uint8 = 0
    if node.yieldArg != nil:
      src = compileExpr(c, node.yieldArg)
    else:
      src = allocReg(c)
      emit(c, instA(LoadUndefined, src))
    let dst = allocReg(c)
    # #402a — Yield + return-completion dispatch (JmpIfNotGenReturn + the
    # inline return sequence).
    emitYieldWithReturnDispatch(c, dst, src)
    if src + 1 == c.nextReg and src != dst: c.nextReg = c.nextReg - 1
    return dst
  of Postfix:
    # Postfix `x++` / `x--`: shared UpdateExpression codegen, returns the
    # OLD value.
    return compileUpdate(c, node, isPrefix = false)
  else:
    # Not yet supported.
    c.hadError = true
    return 0

# --- UpdateExpression: `++x` / `--x` / `x++` / `x--` ----------------
#
# Shared codegen for prefix (NodeKind.Unary, unOp PlusPlus/MinusMinus) and
# postfix (NodeKind.Postfix). `++` → AddImm, `--` → SubImm, imm=1. The core
# is the compound-assignment shape (load current → op → store back) but with
# an imm-fused increment and an old-vs-new result:
#   * POSTFIX returns the OLD value (the reg holding the pre-update read).
#   * PREFIX returns the NEW value (the op's dst).
#
# PREFIX also redundantly EVALUATES the operand once BEFORE the update — a
# reference quirk replicated for byte-identity: for an ident this is a second
# load into the same reg (the throwaway temp is released, so the real `cur`
# load reuses it); for a member it RE-EVALUATES the whole base + reloads the
# prop; in a borrow context (e.g. `return ++x`) the throwaway read borrows the
# local and emits nothing, collapsing the two loads into one. All of this is
# matched by feeding the throwaway through compileExpr with the AMBIENT borrow
# AND preferred-dst setting: a caller's arg-slot hint (`isNaN(++x)`) drops the
# throwaway's first load straight into the arg slot, exactly as the reference
# does — so preferredDst is deliberately NOT cleared here (the compound-assign
# path likewise leaves it untouched, and allocReg — used for cur/dst — never
# consumes it, so the postfix path returns its natural reg regardless).
#
# Targets: global ident / non-captured register local (Mov borrow-copy),
# member `o.x` (IC LoadProp/StoreProp — NOT the element path the compound
# member assign uses), computed `a[i]` (LoadElem/StoreElem, base+index
# evaluated once). Captured / outer-env locals, private members `o.#x`, const
# and TDZ-uninitialized locals BAIL cleanly (they'd need env prop stores /
# ThrowIfHole guards — out of this slice).
proc compileUpdate(c: var Compiler, node: AstNode, isPrefix: bool): uint8 =
  let target = node.operand
  if target == nil:
    c.hadError = true
    return 0
  let op = if node.unOp == PlusPlus: AddImm else: SubImm
  # === Member target `o.x` -> IC LoadProp / StoreProp (shared ic slot) ===
  if target.kind == Member:
    # `super.x++` / private `o.#x++` -> deferred.
    if target.recv != nil and target.recv.kind == SuperExpr:
      c.hadError = true
      return 0
    if isPrivateName(c, target.propStart, target.propLength):
      c.hadError = true
      return 0
    let name = c.slice(target.propStart, target.propStart + target.propLength)
    if isPrefix:
      # Redundant eval: the whole member expression (base + LoadProp); the
      # base is re-evaluated below (the reference quirk).
      let tmp = compileExpr(c, target)
      if c.hadError: return 0
      releaseReg(c, tmp)
    let objReg = compileExpr(c, target.recv)
    if c.hadError: return 0
    let cur = allocReg(c)
    if not emitLoadPropAtom(c, cur, objReg, name): return 0
    let dst = allocReg(c)
    emit(c, instABC(op, dst, cur, 1))
    if not emitStorePropAtom(c, objReg, name, dst): return 0
    if isPrefix:
      if c.nextReg <= dst: c.nextReg = dst + 1
      return dst
    releaseReg(c, dst)
    return cur
  # === Computed target `a[i]` -> LoadElem / StoreElem (base+index once) ===
  if target.kind == Computed:
    if isPrefix:
      let tmp = compileExpr(c, target)
      if c.hadError: return 0
      releaseReg(c, tmp)
    let objReg = compileExpr(c, target.recv)
    let keyReg = compileExpr(c, target.index)
    if c.hadError: return 0
    let cur = allocReg(c)
    emit(c, instABC(LoadElem, cur, objReg, keyReg))
    let dst = allocReg(c)
    emit(c, instABC(op, dst, cur, 1))
    emit(c, instABC(StoreElem, objReg, keyReg, dst))
    if isPrefix:
      if c.nextReg <= dst: c.nextReg = dst + 1
      return dst
    releaseReg(c, dst)
    return cur
  # === Ident target: global / non-captured register local ===
  if target.kind != IdentExpr:
    c.hadError = true
    return 0
  let name = c.slice(target.start, target.`end`)
  let localIdx = findLocalIndex(c, name)
  if localIdx >= 0:
    # Captured (env-slot), const (TypeError), or TDZ-uninitialized locals
    # would need the env prop store / a ThrowIfHole guard — deferred.
    if c.locals[localIdx].captured or c.locals[localIdx].isConst or
       c.locals[localIdx].isTdz:
      c.hadError = true
      return 0
  elif outerCaptureDepth(c, name) > 0:
    # Outer captured local (enclosing-function env property) — deferred.
    c.hadError = true
    return 0
  # Prefix redundant operand eval (throwaway; ambient borrow → the local
  # borrow collapses it away in a `return ++x` context).
  if isPrefix:
    let tmp = compileExpr(c, target)
    if c.hadError: return 0
    releaseReg(c, tmp)
  # cur = the current value. A local is Mov-copied into a fresh temp (never
  # borrowed) so the OLD value survives the store-back into the local's reg.
  let cur = allocReg(c)
  if localIdx >= 0:
    emit(c, instAB(Mov, cur, c.locals[localIdx].reg))
  else:
    let slot = internGlobal(c, name)
    emit(c, instAU16(LoadGlobal, cur, uint16(slot)))
  let dst = allocReg(c)
  emit(c, instABC(op, dst, cur, 1))
  # Store the new value back (local Mov / global StoreGlobal).
  if localIdx >= 0:
    emit(c, instAB(Mov, c.locals[localIdx].reg, dst))
  else:
    let slot = internGlobal(c, name)
    emit(c, instAU16(StoreGlobal, dst, uint16(slot)))
  if isPrefix:
    if c.nextReg <= dst: c.nextReg = dst + 1
    return dst
  releaseReg(c, dst)
  return cur

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
    # Method shorthand `k(){}` / accessor `get k(){}`: the parser
    # synthesizes a FunctionExpr whose SLICE begins exactly at the key token
    # (fn.start == keyStart), and the oracle lowers it via DefineMethod /
    # DefineGetter — DEFERRED, bail. A DATA property whose VALUE is a
    # function (`k: function(){}`) has its FunctionExpr starting at the
    # `function` keyword (after the colon), so fn.start != keyStart — that IS
    # compilable (LoadConst + SetFunctionName + InitObjData), matching the
    # oracle. This narrowing is what lets object methods reach the VM's
    # MethodInvoke (slice B2).
    if prop.propVal != nil and prop.propVal.kind == FunctionExpr and
       prop.propVal.start == prop.keyStart:
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
  # `super(...)` in a derived-class constructor (slice 7b). Emits Op::SuperCall
  # which preserves the current `this` / new-target; the parent constructor is
  # materialized by compiling the enclosing class's `extends` expression into
  # the call-frame base (mirrors compiler.zc ~5784-5854). Spread-super
  # (`super(...args)`) → SpreadSuperCall is DEFERRED (bail). A `super()`
  # outside a derived ctor (no enclosingClassParent) is a bail, matching the
  # C's `c.enclosing_class_parent == NULL` SyntaxError guard.
  if callee != nil and callee.kind == SuperExpr:
    if c.enclosingClassParent == nil:
      c.hadError = true; return 0
    # Contiguous call frame: regs[base] = parent ctor, regs[base+1..] = args.
    let base = c.nextReg
    let slotsNeeded = 1 + argCount
    for _ in 0 ..< slotsNeeded:
      discard allocReg(c)
    # Parent ctor into regs[base] via preferred_dst so a LoadGlobal writes
    # the slot directly (the `extends B` global case). A non-global parent
    # expression compiles normally and Movs into base if it lands elsewhere.
    c.preferredDst = int(base)
    let parentR = compileExpr(c, c.enclosingClassParent)
    c.preferredDst = -1
    if parentR != base:
      emit(c, instAB(Mov, base, parentR))
      if parentR + 1 == c.nextReg: c.nextReg = c.nextReg - 1
    # Args into regs[base+1..]. Uses preferred_dst + compileExpr (NOT
    # tryPlaceSimple) — matching compiler.zc's super-arg loop, so a bare
    # local arg yields the defensive-read Mov pair the oracle emits.
    var j = 0
    while j < argCount:
      let targetSlot = base + 1'u8 + uint8(j)
      c.preferredDst = int(targetSlot)
      let argR = compileExpr(c, node.args[j])
      c.preferredDst = -1
      if argR != targetSlot:
        emit(c, instAB(Mov, targetSlot, argR))
        if argR + 1 == c.nextReg: c.nextReg = c.nextReg - 1
      j += 1
    emit(c, instABC(SuperCall, base, base, uint8(argCount)))
    c.nextReg = base + 1
    if c.nextReg > c.maxReg: c.maxReg = c.nextReg
    return base
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

    # Slice 7f: super-rooted member call — `super.m(...)` / `super[e](...)`.
    # The receiver is the CURRENT `this` (Mov from this_reg in a static
    # element, else LoadThis); the METHOD is looked up on the enclosing
    # class's parent (instance → parent.prototype; static → parent itself),
    # via LoadElem keyed by a string CONST (compiler.zc ~5921-5955).
    let isSuperMember = callee.recv != nil and callee.recv.kind == SuperExpr
    if isSuperMember:
      if c.enclosingClassParent == nil:
        c.hadError = true; return base
      # `super.#x()` — PrivateName on SuperProperty is a SyntaxError; bail to
      # match the oracle's parse error (the Nim parser doesn't reject it).
      if callee.kind == Member and
         isPrivateName(c, callee.propStart, callee.propLength):
        c.hadError = true; return base
      # Receiver = current `this`.
      if c.inStaticElement and c.thisReg >= 0:
        emit(c, instAB(Mov, base + 1, uint8(c.thisReg)))
      else:
        emit(c, instA(LoadThis, base + 1))
      # Method holder: instance → parent.prototype; static → parent ctor.
      let parentR = compileExpr(c, c.enclosingClassParent)
      var holderR = parentR
      if not c.inStaticElement:
        let protoKey = emitLoadNameString(c, "prototype")
        holderR = allocReg(c)
        emit(c, instABC(LoadElem, holderR, parentR, protoKey))
        if protoKey + 1 == c.nextReg: c.nextReg = c.nextReg - 1
        if parentR != holderR and parentR + 1 == c.nextReg: c.nextReg = c.nextReg - 1
      if callee.kind == Member:
        let mname = c.slice(callee.propStart, callee.propStart + callee.propLength)
        let key2 = emitLoadNameString(c, mname)
        emit(c, instABC(LoadElem, base, holderR, key2))
        if key2 + 1 == c.nextReg: c.nextReg = c.nextReg - 1
      else:
        # `super[e](...)` — computed key.
        let key3 = compileExpr(c, callee.index)
        emit(c, instABC(LoadElem, base, holderR, key3))
        if key3 + 1 == c.nextReg: c.nextReg = c.nextReg - 1
      if holderR + 1 == c.nextReg: c.nextReg = c.nextReg - 1
    else:
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
        # Slice 7d: `this.#m()` — resolve the private name to the mangled atom,
        # PrivateCheck the receiver (regs[base+1]) BEFORE loading the method
        # (compiler.zc ~5973-5996). Reading a setter-only accessor (kind==8) as
        # a callee is a TypeError — deferred.
        var name: string
        var isPriv = false
        var privId: uint32
        var privKind: uint8
        if isPrivateName(c, callee.propStart, callee.propLength):
          name = resolvePrivate(c, callee.propStart, callee.propLength, privId, privKind)
          if name.len == 0:
            c.hadError = true; return base
          if privKind == 8'u8:
            c.hadError = true; return base
          isPriv = true
        else:
          name = c.slice(callee.propStart, callee.propStart + callee.propLength)
        let ic = allocIcSlot(c, name)
        if ic > 255:
          c.hadError = true; return base
        if isPriv:
          emitPrivateAccessCheck(c, base + 1, privId, privKind, name)
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
  of ClassExpr:    isAnon = expr.classNameLen == 0
  else:            isAnon = false
  if not isAnon: return
  # An anonymous class EXPRESSION with an explicit `static name` member
  # already owns its .name property; ECMA-262 NamedEvaluation must NOT
  # override it (compiler.zc ~6716-6728). Skip the SetFunctionName then.
  if expr.kind == ClassExpr:
    for m in expr.classMembers:
      if m == nil: continue
      if m.kind == MethodDef and m.methodIsStatic and m.methodNameLen == 4 and
         c.slice(m.methodNameStart, m.methodNameStart + m.methodNameLen) == "name":
        return
      if m.kind == ClassField and m.fieldIsStatic and m.fieldNameLen == 4 and
         c.slice(m.fieldNameStart, m.fieldNameStart + m.fieldNameLen) == "name":
        return
  # LoadConst the name string, then SetFunctionName val, nameReg.
  c.constants.add(Constant(kind: ckString, s: targetName))
  let nameReg = allocReg(c)
  emit(c, instAU16(LoadConst, nameReg, uint16(c.constants.len - 1)))
  emit(c, instAB(SetFunctionName, valReg, nameReg))
  releaseReg(c, nameReg)

# --- Object destructuring (slice 6d; mirrors compiler.zc) -----------
#
# `let {x, y} = o` / `({a} = b)` / `function f({x})`. The value is in
# `srcReg`; destructurePattern emits `AssertCoercible srcReg` then fans
# each entry into a `LoadProp`/`LoadElem` temp, applies the optional
# default, and binds the target. ARRAY patterns (iterator protocol) are
# a separate later slice — a pattern that IS or CONTAINS one BAILs.

proc destructureObject(c: var Compiler, pat: AstNode, srcReg: uint8)

proc patternEntryKeyName(c: Compiler, entry: AstNode): string =
  ## Static key of an object-pattern entry (identifier / string / number
  ## key). Unlike compile_object_literal (which strips a string key's
  ## quotes), a destructuring pattern interns the RAW key token slice —
  ## quotes included — as the property atom (compiler.zc destructure_object
  ## passes `c.source + entry.name_start` for `entry.name_length` bytes, and
  ## the parser sets those to the whole key TOKEN). So `let {"a-b": v}` keys
  ## on the 5-byte `"a-b"` and the disasm prints `r.\"a-b\"`. Empty when the
  ## entry has no static key (computed / rest).
  let ks = entry.patKeyStart
  let kl = entry.patKeyLen
  if kl == 0: return ""
  return c.slice(ks, ks + kl)

proc bindDestructureTarget(c: var Compiler, target: AstNode, valReg: uint8) =
  ## Bind the value in `valReg` to a destructuring leaf target. A nested
  ## object pattern recurses; a nested ARRAY pattern BAILs. Binding mode
  ## (inDstrAssign=false) declares a local/global; assignment mode stores
  ## to an existing Member / Computed / ident lvalue. Mirrors compiler.zc
  ## bind_destructure_target (the slice-6d subset: no TDZ/const store
  ## guards, no outer-capture assignment — those shapes aren't in-corpus
  ## and would need ThrowIfHole / env chains not ported here).
  if target == nil: return
  let k = target.kind
  if k == ObjectPattern or k == ArrayPattern:
    destructurePattern(c, target, valReg)
    return
  if c.inDstrAssign:
    # Assignment mode: the target is any LHSExpression.
    if k == Member:
      # Private member (`obj.#x`) store — out of corpus.
      if target.propLength > 0 and c.src[target.propStart.int] == '#':
        c.hadError = true
        return
      let objR = compileExpr(c, target.recv)
      let name = c.slice(target.propStart, target.propStart + target.propLength)
      discard emitStorePropAtom(c, objR, name, valReg)
      releaseReg(c, objR)
      return
    if k == Computed:
      let objR = compileExpr(c, target.recv)
      let keyR = compileExpr(c, target.index)
      emit(c, instABC(StoreElem, objR, keyR, valReg))
      releaseReg(c, keyR)
      releaseReg(c, objR)
      return
    if k != IdentExpr:
      c.hadError = true
      return
    let nm = c.slice(target.start, target.`end`)
    let lidx = findLocalIndex(c, nm)
    if lidx >= 0:
      # A const / TDZ target would need a PutValue guard (TypeError /
      # ThrowIfHole) — out of corpus; refuse rather than emit an unguarded
      # store.
      if c.locals[lidx].isConst or c.locals[lidx].isTdz:
        c.hadError = true
        return
      if c.locals[lidx].captured:
        let er = envForLocal(c, lidx)
        discard emitStorePropAtom(c, er, nm, valReg)
      else:
        emit(c, instAB(Mov, c.locals[lidx].reg, valReg))
      return
    # Outer-capture assignment target — needs an env chain walk + store
    # guard; out of corpus. Bail rather than diverge.
    if outerCaptureDepth(c, nm) > 0:
      c.hadError = true
      return
    # Global target (non-strict StoreGlobal; strict form not modeled here).
    let slot = internGlobal(c, nm)
    emit(c, instAU16(StoreGlobal, valReg, uint16(slot)))
    return
  # Binding mode: leaf must be a plain identifier.
  if k != IdentExpr:
    c.hadError = true
    return
  let name = c.slice(target.start, target.`end`)
  if c.isFunction:
    let lidx = findLocalIndex(c, name)
    if lidx < 0:
      # Script-scope `var {a} = …`: collect_locals skips top-level var, so
      # the name has no pre-registered local; the spec puts it on
      # globalThis — DefineGlobal, matching the plain-var declarator path.
      if c.isScript:
        let slot = internGlobal(c, name)
        emit(c, instAU16(DefineGlobal, valReg, uint16(slot)))
        return
      c.hadError = true
      return
    if c.locals[lidx].captured:
      let er = envForLocal(c, lidx)
      discard emitStorePropAtom(c, er, name, valReg)
    else:
      emit(c, instAB(Mov, c.locals[lidx].reg, valReg))
    # #330 TDZ: this binding is now initialized so a later entry's default
    # referencing it reads the value.
    if c.locals[lidx].isTdz: c.locals[lidx].isTdz = false
  else:
    let slot = internGlobal(c, name)
    emit(c, instAU16(DefineGlobal, valReg, uint16(slot)))

proc applyDestructureDefault(c: var Compiler, vR: uint8, defaultExpr, target: AstNode) =
  ## If the entry carries `= default`, emit in place:
  ##   tmp = alloc; undefR = alloc; LoadUndefined undefR
  ##   CmpStrictEq tmp, vR, undefR; JmpIfFalse tmp -> skip
  ##   <compute default>; Mov vR <- default; skip:
  ## vR is a caller-owned temp. tmp is allocated BEFORE undefR (lower reg)
  ## but LoadUndefined for undefR emits first — matches compiler.zc's
  ## alloc-then-emit order. Mirrors apply_destructure_default.
  if defaultExpr == nil: return
  let tmp = allocReg(c)
  let undefR = allocReg(c)
  emit(c, instA(LoadUndefined, undefR))
  emit(c, instABC(CmpStrictEq, tmp, vR, undefR))
  releaseReg(c, undefR)
  let skip = emit(c, instAI16(JmpIfFalse, tmp, 0))
  releaseReg(c, tmp)
  let init = compileExpr(c, defaultExpr)
  if init != vR: emit(c, instAB(Mov, vR, init))
  # ECMA-262 NamedEvaluation: an anonymous callable default bound to a
  # simple-ident target gets that name.
  if target != nil and target.kind == IdentExpr and target.`end` > target.start:
    maybeInferAnonName(c, defaultExpr, vR, c.slice(target.start, target.`end`))
  patchJump(c, skip)

proc destructureObject(c: var Compiler, pat: AstNode, srcReg: uint8) =
  for entry in pat.patEntries:
    if c.hadError: return
    if entry == nil or entry.kind != PatternEntry:
      c.hadError = true
      return
    if entry.patIsRest:
      # Object rest `{...r}`: copy own enumerable props of src into a fresh
      # object, then delete each statically-named key declared BEFORE this
      # rest binding. Mirrors compiler.zc destructure_object's rest arm.
      let saved = c.nextReg
      let dstR = allocReg(c)
      emit(c, instA(NewObject, dstR))
      emit(c, instAB(ObjectSpread, dstR, srcReg))
      for prev in pat.patEntries:
        if prev == entry: break
        if prev != nil and prev.kind == PatternEntry and not prev.patIsRest:
          let pn = patternEntryKeyName(c, prev)
          if pn.len > 0:
            c.constants.add(Constant(kind: ckString, s: pn))
            let keyR = allocReg(c)
            emit(c, instAU16(LoadConst, keyR, uint16(c.constants.len - 1)))
            let trash = allocReg(c)
            emit(c, instABC(DeleteElem, trash, dstR, keyR))
            releaseReg(c, trash)
            releaseReg(c, keyR)
      bindDestructureTarget(c, entry.patTarget, dstR)
      c.nextReg = saved
      if c.nextReg > c.maxReg: c.maxReg = c.nextReg
      continue

    let vR = allocReg(c)
    if entry.patKeyLen > 0:
      # Static key (identifier / string / number) -> LoadProp with an IC.
      let name = patternEntryKeyName(c, entry)
      if name.len == 0:
        c.hadError = true
        releaseReg(c, vR)
        return
      discard emitLoadPropAtom(c, vR, srcReg, name)
    elif entry.patComputedKey != nil:
      # Computed key `[e]` -> LoadElem.
      let keyR = compileExpr(c, entry.patComputedKey)
      emit(c, instABC(LoadElem, vR, srcReg, keyR))
      releaseReg(c, keyR)
    else:
      c.hadError = true
      releaseReg(c, vR)
      return
    applyDestructureDefault(c, vR, entry.patDefault, entry.patTarget)
    bindDestructureTarget(c, entry.patTarget, vR)
    releaseReg(c, vR)

proc destructureArray(c: var Compiler, pat: AstNode, srcReg: uint8) =
  ## `let [a, b] = c` / `([a, b] = c)` / `let [a, ...r] = c`. Runs the
  ## iterator protocol: GetIterator(src) then IteratorStep / IteratorClose
  ## per element (§13.15.5.3). Mirrors compiler.zc destructure_array.
  ##
  ## Shape (verified against the oracle):
  ##   IterGet   iter <- src
  ##   LoadFalse done
  ##   EnterTry  catch, <ph>            (region wraps element binding)
  ##   per entry: IterStep val <- iter, done ; (default?) ; bind
  ##     elision (patTarget==nil) still emits IterStep, binds nothing
  ##     rest → IterRestCollect val <- iter, done (drains; last entry)
  ##   region_pop; LeaveTry; Jmp -> normalClose
  ##   <handler>: IterCloseQuiet iter, done ; Throw catch
  ##   normalClose (only when NO rest): IterClose iter, done
  ##
  ## catch_reg is pushed below fixed_regs so element temps can't clobber
  ## the caught value; the bump is PERMANENT (matches the C — it isn't
  ## restored). A rest binding always drains the iterator, so the final
  ## IterClose is omitted (the C's `!saw_rest` gate).
  let iterR = allocReg(c)
  emit(c, instAB(IterGet, iterR, srcReg))
  let doneR = allocReg(c)
  emit(c, instA(LoadFalse, doneR))

  let catchReg = allocReg(c)
  if catchReg + 1 > c.fixedRegs: c.fixedRegs = catchReg + 1
  let enterIdx = emit(c, instAI16(EnterTry, catchReg, 0))
  regionPushCatch(c)

  var sawRest = false
  for entry in pat.patEntries:
    if c.hadError: return
    if entry == nil or entry.kind != PatternEntry:
      c.hadError = true
      return
    if entry.patIsRest:
      # ...rest: drain remaining elements into a fresh array.
      let savedNext = c.nextReg
      let dstR = allocReg(c)
      emit(c, instABC(IterRestCollect, dstR, iterR, doneR))
      bindDestructureTarget(c, entry.patTarget, dstR)
      c.nextReg = savedNext
      if c.nextReg > c.maxReg: c.maxReg = c.nextReg
      sawRest = true
      continue
    # Pull the next value; IterStep sets vR (or undefined when done) and done.
    let vR = allocReg(c)
    emit(c, instABC(IterStep, vR, iterR, doneR))
    if entry.patTarget == nil:
      # Elision — the slot was consumed, bind nothing.
      releaseReg(c, vR)
      continue
    applyDestructureDefault(c, vR, entry.patDefault, entry.patTarget)
    bindDestructureTarget(c, entry.patTarget, vR)
    releaseReg(c, vR)

  regionPop(c)
  emit(c, instA(LeaveTry, 0))
  let skipHandler = emit(c, instI16(Jmp, 0))
  patchJump(c, enterIdx)
  emit(c, instAB(IterCloseQuiet, iterR, doneR))
  emit(c, instA(Throw, catchReg))
  patchJump(c, skipHandler)

  # NormalCompletion IteratorClose: skipped when a rest binding drained it.
  if not sawRest:
    emit(c, instAB(IterClose, iterR, doneR))
  releaseReg(c, catchReg)
  releaseReg(c, doneR)
  releaseReg(c, iterR)

proc destructurePattern(c: var Compiler, pat: AstNode, srcReg: uint8) =
  ## Spec: at the head of every destructuring step the value must be
  ## RequireObjectCoercible — null/undefined throw TypeError before any
  ## property extraction. Mirrors compiler.zc destructure_pattern.
  if pat == nil: return
  emit(c, instA(AssertCoercible, srcReg))
  if pat.kind == ObjectPattern:
    destructureObject(c, pat, srcReg)
    return
  if pat.kind == ArrayPattern:
    destructureArray(c, pat, srcReg)
    return
  c.hadError = true

# --- Statements -----------------------------------------------------

proc compileVarDecl(c: var Compiler, node: AstNode) =
  ## Handles all three decl kinds at script top level:
  ##   * `var x = <e>`  -> DefineGlobal (slice 1)
  ##   * `let`/`const`  -> bind to the pre-allocated local register
  ## Destructuring declarators are a later slice.
  for decl in node.declarators:
    if decl.kind != Declarator: continue
    if decl.nameLength == 0:
      # Destructuring declarator: decl.declPattern is the pattern, decl.init
      # the initializer. Compile the RHS into a temp, destructure (binding
      # mode), release. `let {a};` (no init) is invalid in the spec — the
      # parser never produces it; a pattern with no init is a silent no-op.
      # Mirrors compiler.zc's VarDecl `decl.name_length==0 && decl.third`
      # arm (~7318).
      if decl.declPattern == nil:
        c.hadError = true; return
      if decl.init != nil:
        let r = compileExpr(c, decl.init)
        destructurePattern(c, decl.declPattern, r)
        releaseReg(c, r)
        if c.hadError: return
      continue
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
  of SwitchStmt:
    # `switch (disc) { case t: ...; default: ...; }`. Lowered as an
    # if-else DISPATCH CHAIN (NOT a jump table). Mirrors compiler.zc's
    # SwitchStmt arm (~7529):
    #   disc_r = disc
    #   for each NON-default case i in order:
    #     test_r = case_i_test; CmpStrictEq cmp, disc_r, test_r
    #     JmpIfTrue cmp -> body_i           (forward placeholder)
    #   Jmp -> default body (if any) else switch end
    #   bodies in SOURCE order (default wherever it appears); fall through
    #   unless a `break` Jmps to the end.
    #
    # `break` inside a body targets the switch end via a loop frame pushed
    # with isIter=false, so a `continue` inside walks PAST it to the
    # enclosing iteration loop (#261). Labeled break/continue and switch
    # inside a try-region are later slices -- the parser drops labels so a
    # labeled break arrives here unlabeled (correct target for the corpus).

    # BAIL: a case-body `let`/`const` whose name ALSO exists as an enclosing
    # lexical binding is a shadowing edge (the CaseBlock shares scope_id with
    # the enclosing scope in collect_locals, so two same-name bindings
    # interfere). The reference's capture analysis resolves such a closure
    # capture to the OUTER binding (marking it captured) via subtle scope
    # timing we don't model here; matching it byte-for-byte is out of the
    # slice-6a corpus. Refuse rather than emit divergent bytecode -- surfaces
    # as nim_missing (capture/TDZ scope class), never a false byte-match.
    for cnode in node.cases:
      if cnode == nil or cnode.kind != SwitchCase: continue
      for s in cnode.caseBody:
        if s != nil and s.kind == VarDecl and
           (s.declKind == KwLet or s.declKind == KwConst):
          for d in s.declarators:
            if d.kind == Declarator and d.nameLength > 0:
              let nm = c.slice(d.nameStart, d.nameStart + d.nameLength)
              # The case-body `let x` is itself in the locals table (added by
              # collectLocals in the enclosing scope). A SHADOW exists when a
              # SECOND active binding of the same name is present — i.e. an
              # enclosing `let x` declared outside the switch. Count active
              # same-name locals; >=2 means the shadow trigger.
              var activeCount = 0
              for lc in c.locals:
                if lc.name == nm and scopeIdIsActive(c, lc.scopeId):
                  inc activeCount
              if activeCount >= 2:
                c.hadError = true; return

    # 1. Completion pre-init (top level, like `if`): an empty-body switch
    #    yields undefined, so reset the completion reg before the dispatch.
    if c.atProgramTop and c.lastExprReg >= 0:
      emit(c, instA(LoadUndefined, uint8(c.lastExprReg)))

    # 2. Discriminant into a register, kept live across every comparison.
    let discR = compileExpr(c, node.switchDisc)

    # 3. Dispatch chain. For each case (source order): a non-default case
    #    compiles its test, CmpStrictEq, and a forward JmpIfTrue whose
    #    patch index we record; a default case records its position (first
    #    default wins) and gets no test op. The bodies aren't emitted yet,
    #    so the jumps are placeholders patched in step 6.
    let n = node.cases.len
    var caseLabelPatches = newSeq[int](n)   # JmpIfTrue index per case (-1 = default)
    var defaultIdx = -1
    for cj in 0 ..< n:
      let cnode = node.cases[cj]
      if cnode == nil or cnode.kind != SwitchCase:
        c.hadError = true; return
      if cnode.caseTest == nil:
        # default: no dispatch test; the no-match Jmp targets its body.
        if defaultIdx < 0: defaultIdx = cj
        caseLabelPatches[cj] = -1
      else:
        let testR = compileExpr(c, cnode.caseTest)
        let cmpR = allocReg(c)
        emit(c, instABC(CmpStrictEq, cmpR, discR, testR))
        releaseReg(c, testR)
        let idx = emit(c, instAI16(JmpIfTrue, cmpR, 0))
        releaseReg(c, cmpR)
        caseLabelPatches[cj] = idx
    releaseReg(c, discR)
    resetTemps(c)

    # 4. No case matched -> jump to the default body (if present) else the
    #    switch end. Placeholder patched in step 6 once positions are known.
    let toDefaultOrEnd = emit(c, instI16(Jmp, 0))

    # 5. Push a loop frame (isIter=false) so `break` inside a body patches
    #    to the switch end; `continue` walks past it to the enclosing loop.
    loopPush(c)
    c.loopStack[c.loopStack.len - 1].isIter = false

    # 6. Emit each case body in SOURCE order, recording where each starts so
    #    the dispatch jumps can be patched to it. Bodies fall through (no
    #    automatic jump between them); a `break` inside adds a break patch.
    var bodyStarts = newSeq[uint32](n)
    for bi in 0 ..< n:
      bodyStarts[bi] = uint32(c.code.len)
      let cnode = node.cases[bi]
      for s in cnode.caseBody:
        if c.hadError: break
        compileStmt(c, s)
      if c.hadError: break
    let endLabel = uint32(c.code.len)

    if c.hadError:
      loopPop(c)
      return

    # 7. Patch each non-default case's JmpIfTrue to its body start, and the
    #    no-match Jmp to the default body (or the switch end). Offsets are
    #    relative to the instruction AFTER the 1-slot jump (base = idx+1).
    for pi in 0 ..< n:
      if caseLabelPatches[pi] >= 0:
        let jIdx = caseLabelPatches[pi]
        let inst = c.code[jIdx]
        let off = int32(bodyStarts[pi]) - (int32(jIdx) + 1)
        c.code[jIdx] = instAI16(inst.op, inst.a, off)
    let dest = if defaultIdx >= 0: bodyStarts[defaultIdx] else: endLabel
    block:
      let inst2 = c.code[toDefaultOrEnd]
      let off2 = int32(dest) - (int32(toDefaultOrEnd) + 1)
      c.code[toDefaultOrEnd] = instI16(inst2.op, off2)

    # 8. Patch every `break` to the switch end, then pop the frame.
    for bp in c.loopStack[c.loopStack.len - 1].breakPatches:
      patchJump(c, bp)
    loopPop(c)
  of BreakStmt:
    # `break` (unlabeled) targets the innermost frame; `break <label>`
    # resolves to the matching labeled frame (loop OR labeled-block). A
    # `break` with no enclosing loop/label frame is a SyntaxError ->
    # hadError. Mirrors compiler.zc BreakStmt (8180-8196).
    if c.loopStack.len == 0:
      c.hadError = true; return
    var frameIdx = c.loopStack.len - 1
    if node.breakLabelLen > 0:
      frameIdx = findLabeledLoop(c, node.breakLabelStart, node.breakLabelLen)
      if frameIdx < 0:
        c.hadError = true; return
    # #402b: unwind every region opened INSIDE the target frame before
    # jumping — LeaveTry per catch region; a crossed finally region BAILs
    # (its inline-finally-body path is not ported this slice).
    emitUnwindRegions(c, c.loopStack[frameIdx].regionDepthAtEntry)
    if c.hadError: return
    let jmpIdx = emit(c, instI16(Jmp, 0))
    c.loopStack[frameIdx].breakPatches.add(jmpIdx)
  of ContinueStmt:
    if c.loopStack.len == 0:
      c.hadError = true; return
    var top: int
    if node.breakLabelLen > 0:
      # `continue <label>` targets the matching labeled LOOP frame
      # (find_labeled_loop; a labeled block frame that isn't a loop has
      # no continue target — the loop-set-continue path below still runs
      # against whatever frame matched, mirroring compiler.zc which
      # searches the same label stack).
      top = findLabeledLoop(c, node.breakLabelStart, node.breakLabelLen)
      if top < 0:
        c.hadError = true; return
    else:
      # Unlabeled continue targets the innermost ITERATION loop; walk past
      # switch frames (which push only to receive breaks). Mirrors
      # compiler.zc's is_iter walk (#261).
      top = c.loopStack.len - 1
      while top >= 0 and not c.loopStack[top].isIter:
        dec top
      if top < 0:
        c.hadError = true; return
    # #402b: unwind regions opened inside the target loop (LeaveTry per
    # catch region; finally region BAILs). Uses the TARGET frame's entry
    # depth so a continue past a switch frame still unwinds correctly.
    emitUnwindRegions(c, c.loopStack[top].regionDepthAtEntry)
    if c.hadError: return
    if c.loopStack[top].haveContinue:
      emitJumpBack(c, Jmp, c.loopStack[top].continueTarget)
    else:
      # Target not yet known (for-style loops: `continue` runs the update
      # step, positioned after the body). Emit a placeholder, patched at
      # loopSetContinue time. Record it on the TARGET iteration frame.
      let jmpIdx = emit(c, instI16(Jmp, 0))
      c.loopStack[top].continuePatches.add(jmpIdx)
  of LabeledStmt:
    # `label: <stmt>`. Mirrors compiler.zc LabeledStmt (8231-8274).
    let inner = node.labeled
    let ik = if inner != nil: inner.kind else: EmptyStmt
    let isLoopTarget =
      ik in {WhileStmt, DoWhileStmt, ForStmt, ForInStmt, ForOfStmt}
    if isLoopTarget:
      # Stash the label so the loop's loopPush() picks it up into its
      # frame; then a `break/continue <label>` inside resolves to it.
      c.pendingLabelStart = node.labelStart
      c.pendingLabelLen = node.labelLen
      compileStmt(c, inner)
      c.pendingLabelStart = 0
      c.pendingLabelLen = 0
    else:
      # Labeled non-loop (block, if, try, plain statement). Push a
      # synthetic loop frame carrying the label so a `break <label>` inside
      # the body patches out to the position immediately after the inner
      # statement. NOTE: isIter is left at loopPush's default `true`,
      # matching compiler.zc (8255-8258 sets ONLY the label) — a stray
      # unlabeled `continue` would target it with nowhere to land, but
      # `continue` against a labeled non-loop is a SyntaxError not yet
      # enforced. Byte-for-byte fidelity requires the same default.
      loopPush(c)
      let frameIdx = c.loopStack.len - 1
      c.loopStack[frameIdx].labelStart = node.labelStart
      c.loopStack[frameIdx].labelLen = node.labelLen
      # loopPush already cleared pending; nothing inherits this label.
      compileStmt(c, inner)
      # Patch every break that targeted this frame to here (after the body).
      for bp in c.loopStack[frameIdx].breakPatches:
        patchJump(c, bp)
      loopPop(c)
  of ClassDecl:
    # A class declaration (slice 7a). compileClassValue builds the
    # constructor + prototype + methods and returns the ctor register;
    # bind the class name. A ClassDecl is ALWAYS lexical (§10.2 — even at
    # script-top), so `c.isFunction` (true for both program-top-script and
    # function bodies) binds to the pre-allocated local register that
    # collectLocals reserved. Mirrors compiler.zc ~7417-7437. The
    # captured-name / module-global paths (env StoreProp / DefineGlobal)
    # are out of the slice-7a corpus.
    let r = compileClassValue(c, node)
    if c.hadError:
      resetTemps(c)
      return
    if c.isFunction:
      let name = c.slice(node.classNameStart, node.classNameStart + node.classNameLen)
      let lidx = findLocalIndex(c, name)
      if lidx >= 0:
        if c.locals[lidx].captured:
          # A class name captured by a nested closure lives on the env
          # object — env chain / StoreProp not exercised here; bail.
          c.hadError = true
        else:
          emit(c, instAB(Mov, c.locals[lidx].reg, r))
    else:
      # Module context (non-function) — a class-global DefineGlobal; out of
      # the current corpus (the program compiler is always is_function).
      c.hadError = true
    releaseReg(c, r)
    resetTemps(c)
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
  of ThrowStmt:
    # `throw expr` -> compile the operand, `Throw r`, release. Mirrors
    # compiler.zc's ThrowStmt arm (~8277).
    let r = compileExpr(c, node.throwArg)
    emit(c, instA(Throw, r))
    releaseReg(c, r)
    resetTemps(c)
  of TryStmt:
    # try/catch/finally (slice 6b). Mirrors compiler.zc's TryStmt arm
    # (~8285). Two shapes: no-finally (a single EnterTry whose handler is
    # the catch body) and finally (an OUTER EnterTry wrapping the try[+catch],
    # whose handler stashes the thrown value + a rethrow flag and falls into
    # the finally body). See the inline comments below.
    #
    # ECMA-262 14.15.8 step 6: TryStatement returns UpdateEmpty with
    # undefined when the try produced an empty completion — mirror the
    # if/while heads by resetting the top-level completion reg first.
    if c.atProgramTop and c.lastExprReg >= 0:
      emit(c, instA(LoadUndefined, uint8(c.lastExprReg)))

    let hasCatch = node.catchBlock != nil
    let hasFinally = node.finallyBlock != nil

    # Destructuring catch param (`catch({e})` / `catch([e])`) -> DEFERRED
    # (destructure_pattern / collect_pattern_locals not ported). Surfaces
    # as nim_missing rather than a wrong bind.
    if hasCatch and node.catchPattern != nil:
      c.hadError = true
      return

    # CAPTURED catch param -> DEFERRED. When a nested closure in the catch
    # body references the catch parameter, the binding must live on an env
    # object (LoadProp/StoreProp), not a plain register — the captured-local
    # machinery for a block-scoped catch param is out of the slice-6b
    # corpus. Scan the whole catch body for a nested-function subtree that
    # mentions the catch-param name and BAIL rather than emit a register
    # bind the closure can't see (scope-catch-param-lex-close). Simple-ident
    # catch only.
    if hasCatch and node.catchParamLen > 0 and node.catchBlock != nil:
      let cpName = c.slice(node.catchParamStart, node.catchParamStart + node.catchParamLen)
      if catchBodyFnMentions(c, node.catchBlock, cpName):
        c.hadError = true
        return

    # Catch parameter is scoped to the catch block (§14.15.3). Allocate a
    # register up front (EnterTry deposits the thrown value there) but only
    # register it as a name-resolvable local while compiling the catch body
    # — snapshot/restore locals.len so outer code can't see it. A fresh
    # register is ALWAYS allocated (never reuse an outer same-name local),
    # matching compiler.zc so nested try/catch don't alias.
    var catchReg: uint8 = 0
    var addedCatchLocal = false
    let savedLocalCount = c.locals.len
    if hasCatch and node.catchParamLen > 0:
      catchReg = allocReg(c)
      addedCatchLocal = true
      if catchReg + 1 > c.fixedRegs: c.fixedRegs = catchReg + 1
    elif hasCatch:
      # Optional catch binding (`catch { … }`) — still need a sink register
      # for EnterTry to deposit the thrown value so it doesn't clobber a
      # live local.
      catchReg = allocReg(c)
      if catchReg + 1 > c.fixedRegs: c.fixedRegs = catchReg + 1

    # #401 inc6 — env restore on catch entry. Snapshot env_reg before
    # EnterTry and restore it at every handler entry (a throw out of a
    # per-iter env would otherwise leave env_reg stale). Only fires when
    # this function has its own env (needsEnv) — out of the tested corpus,
    # but ported for fidelity.
    var envSaveReg = -1
    if c.needsEnv:
      let esr = allocReg(c)
      if esr + 1 > c.fixedRegs: c.fixedRegs = esr + 1
      emit(c, instAB(Mov, esr, c.envReg))
      envSaveReg = int(esr)

    if not hasFinally:
      # --- try/catch, no finally (compiler.zc ~8343) ------------------
      let enterIdx = emit(c, instAI16(EnterTry, catchReg, 0))
      # Catch region open during the try body: a `return f()` inside is
      # not in tail position, and `return`/`break`/`continue` pop this
      # handler first (emitReturnSequence / emitUnwindRegions).
      regionPushCatch(c)
      compileStmt(c, node.tryBlock)
      regionPop(c)
      if c.hadError: return
      emit(c, instA(LeaveTry, 0))
      let skipIdx = emit(c, instI16(Jmp, 0))
      patchJump(c, enterIdx)
      if envSaveReg >= 0:
        emit(c, instAB(Mov, c.envReg, uint8(envSaveReg)))
      # Catch entry: reset the result register so an empty catch body
      # produces undefined (UpdateEmpty per spec).
      if c.atProgramTop and c.lastExprReg >= 0:
        emit(c, instA(LoadUndefined, uint8(c.lastExprReg)))
      # Bind the catch parameter for the catch body only.
      if addedCatchLocal:
        addLocalScoped(c, node.catchParamStart, node.catchParamLen, uint32(catchReg), c.curScopeId)
      compileStmt(c, node.catchBlock)
      if addedCatchLocal: c.locals.setLen(savedLocalCount)
      if c.hadError: return
      patchJump(c, skipIdx)
      return

    # --- try/finally (± catch) (compiler.zc ~8375) --------------------
    # Wrap (try [+ catch]) in an OUTER try whose handler stashes the
    # thrown value + rethrow flag and falls into the finally block. After
    # finally, if the flag is set, re-throw.
    let pendingReg = allocReg(c)
    let flagReg = allocReg(c)
    if flagReg + 1 > c.fixedRegs: c.fixedRegs = flagReg + 1
    # Initialize flag = false (covers the no-exception path).
    emit(c, instA(LoadFalse, flagReg))

    # Outer try: any uncaught throw from the try/catch body lands at
    # outerHandler with the thrown value in pendingReg.
    let outerEnter = emit(c, instAI16(EnterTry, pendingReg, 0))

    # The finally-outer region: a return/break/continue inside the try or
    # catch arms must pop this handler FIRST and inline the finally body —
    # NOT ported this slice, so emitUnwindRegions BAILs when it crosses a
    # kind-1 region. Get the normal-completion + throw paths byte-exact;
    # abrupt-in-finally is deferred.
    regionPushFinally(c, node.finallyBlock)

    if hasCatch:
      # Inner try: throws from the try body land in catchReg.
      let innerEnter = emit(c, instAI16(EnterTry, catchReg, 0))
      regionPushCatch(c)
      compileStmt(c, node.tryBlock)
      regionPop(c)
      if c.hadError: return
      emit(c, instA(LeaveTry, 0))
      let skipCatch = emit(c, instI16(Jmp, 0))
      patchJump(c, innerEnter)
      if envSaveReg >= 0:
        emit(c, instAB(Mov, c.envReg, uint8(envSaveReg)))
      # Reset result register on catch entry per UpdateEmpty.
      if c.atProgramTop and c.lastExprReg >= 0:
        emit(c, instA(LoadUndefined, uint8(c.lastExprReg)))
      # Catch parameter bound for the catch body only.
      if addedCatchLocal:
        addLocalScoped(c, node.catchParamStart, node.catchParamLen, uint32(catchReg), c.curScopeId)
      compileStmt(c, node.catchBlock)
      if addedCatchLocal: c.locals.setLen(savedLocalCount)
      if c.hadError: return
      patchJump(c, skipCatch)
    else:
      # No catch — the outer try catches throws from the try body directly
      # and routes them to the finally re-throw path.
      compileStmt(c, node.tryBlock)
      if c.hadError: return

    regionPop(c)   # finally-outer region closes here

    emit(c, instA(LeaveTry, 0))   # pop outer

    # Normal (or post-catch) exit: skip the handler entry.
    let skipOuter = emit(c, instI16(Jmp, 0))
    patchJump(c, outerEnter)
    if envSaveReg >= 0:
      emit(c, instAB(Mov, c.envReg, uint8(envSaveReg)))
    # Outer handler entry — pendingReg holds the thrown value. Mark the
    # flag so we re-throw after the finally.
    emit(c, instA(LoadTrue, flagReg))
    patchJump(c, skipOuter)

    # Save the try/catch body's result so try-finally spec semantics apply:
    # if finally completes normally, the body's completion wins (empty →
    # undefined). Reset result_reg before the finally so an empty finally
    # doesn't contribute a value.
    var bodySave = -1
    if c.atProgramTop and c.lastExprReg >= 0:
      let saveReg = allocReg(c)
      if saveReg + 1 > c.fixedRegs: c.fixedRegs = saveReg + 1
      emit(c, instAB(Mov, saveReg, uint8(c.lastExprReg)))
      emit(c, instA(LoadUndefined, uint8(c.lastExprReg)))
      bodySave = int(saveReg)

    # Finally body runs on both paths.
    compileStmt(c, node.finallyBlock)
    if c.hadError: return

    # After finally completes normally, restore the body's value
    # (UpdateEmpty(B, undefined)). Abrupt finally completions take a
    # different path and never reach this Mov.
    if bodySave >= 0:
      emit(c, instAB(Mov, uint8(c.lastExprReg), uint8(bodySave)))
      releaseReg(c, uint8(bodySave))

    # If we arrived via the outer handler, re-throw pendingReg.
    let afterFinally = emit(c, instAI16(JmpIfFalse, flagReg, 0))
    emit(c, instA(Throw, pendingReg))
    patchJump(c, afterFinally)
    return
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
      # the return expression compare unequal and still fuse.
      # #326/#402b: a `return` while a try/catch/finally region is open is
      # NOT in tail position (the handler must run first — emitReturnSequence
      # unwinds it), so suppress BOTH the fusion-suppressor flag and the TCO
      # rewrite when regionCount > 0 (mirrors compiler.zc's region_count==0
      # gate on the tail-call arms).
      let isTailCandidate = node.retArg.kind == Call and c.regionCount == 0
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
    # #402b: unwind every open region (LeaveTry per catch region; finally
    # region BAILs — abrupt-in-finally deferred) then Return. Reduces to a
    # bare `Return r` when regionCount == 0 (the pre-6b behavior).
    emitReturnSequence(c, r)
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
  ## The nodes to WALK for the collect-locals / capture-analysis pre-passes.
  ## The outer braces ARE the function scope, so we iterate the BlockStmt's
  ## children directly (never re-entering a block scope for them) — mirrors
  ## compiler.zc's "walk INTO node.left's children" for a block body, and
  ## "walk node.left directly" for an arrow's CONCISE (expression) body
  ## (compiler.zc ~4064/4083). collect_locals is a no-op on the concise
  ## expression (no var/let/const there), but analyze_captures MUST descend
  ## it to mark params captured by a nested closure. The compile step (5)
  ## special-cases the concise body via `body.kind != BlockStmt`, so this
  ## single-element list is never re-compiled through the stmt loop.
  let body = fnBodyOf(node)
  if body == nil: return @[]
  if body.kind == BlockStmt: return body.stmtList
  return @[body]

proc compileFunction(src: string, node: AstNode, enclosing: var Compiler,
                     isClassCtor: bool = false): Function =
  ## Compile a FunctionDecl / FunctionExpr / ArrowFunc / MethodDef body
  ## into its own Function (own code / consts / regs / paramCount).
  ## Mirrors compiler.zc compile_function for the slice-4a/4d envelope:
  ## simple params, no default/rest/destructure, no async/generator.
  ## `this`/`arguments` inheritance is handled by the shared
  ## bodyUsesThis/bodyUsesArguments pre-scans (which descend into arrows)
  ## + the arrow-always MakeClosure. Any feature outside that envelope
  ## sets hadError -> returns nil so the enclosing compile bails
  ## (surfacing as nim_missing, never a false match). `enclosing` shares
  ## its global-intern table with the child so global slots stay in one
  ## namespace program-wide.
  ##
  ## Slice 7a: MethodDef nodes (class methods + the class constructor) and
  ## a synthesized empty-ctor FunctionExpr share this path via fnBodyOf /
  ## fnParamsOf. `isClassCtor` flags the resulting Function (disasm header
  ## " class-ctor") and enables the LoadCallee self-name bind for the
  ## synthesized empty ctor (a named anonymous FunctionExpr), which class
  ## codegen builds so `class C {}` names itself C inside the ctor.
  let isArrow = node.kind == ArrowFunc
  let isMethod = node.kind == MethodDef
  let isStaticBlock = node.kind == StaticBlock

  # --- Envelope gate ------------------------------------------------
  # Arrow params/body live in a different AST variant (arrowParams /
  # arrowBody / arrowIsAsync); regular functions use fnParams / fnBody /
  # fnIsAsync|fnIsGenerator; a MethodDef uses methodIsAsync/methodIsGenerator.
  # fnParamsOf / fnBodyOf abstract the shape.
  # Slice 7e: generator (`function*` / `*m(){}`) and async (`async function`
  # / `async () =>` / `async m(){}`) bodies now compile — determine the two
  # flags from the node shape (arrows have no generator form). yield* and
  # async generators DEFER at the compile site (see the YieldExpr arm).
  var kindIsGenerator = false
  var kindIsAsync = false
  if isArrow:
    kindIsAsync = node.arrowIsAsync
  elif isMethod:
    kindIsAsync = node.methodIsAsync
    kindIsGenerator = node.methodIsGenerator
  elif isStaticBlock:
    # Slice 7f: a static block is a plain synchronous, non-generator body,
    # BUT the oracle marks its Function `is_async=true` — a quirk of the C's
    # overloaded `node.bool_value`: the parser sets StaticBlock.bool_value=true
    # (meaning "is a static element"), and compile_function's non-MethodDef
    # branch reads `kind_is_async = node.bool_value` (compiler.zc ~4310, ~4473).
    # So the block Function's disasm header carries " async". Replicate it
    # exactly (no generator — StaticBlock.num is 0, so kind_is_generator stays
    # false). This has no runtime effect for the empty-arg immediate invoke.
    kindIsAsync = true
  else:
    kindIsAsync = node.fnIsAsync
    kindIsGenerator = node.fnIsGenerator
  let params = fnParamsOf(node)
  # Slice 4e envelope: plain-ident, default (`a = expr`), and rest
  # (`...rest`) params. Destructuring params still bail (nim_missing).
  if not paramsCompilable(params):
    return nil
  # A NAMED function expression binds its own name as a self-referencing
  # local visible inside the body (§15.7.1), seeded via a LoadCallee
  # prologue (compiler.zc bind_callee_local). That machinery is slice
  # 4b — bail so `(function foo(){})` surfaces as nim_missing, not a
  # false byte-match. FunctionDecl names bind in the ENCLOSING scope and
  # get NO LoadCallee, so decls with a name are fine. Arrows are always
  # anonymous — no self-binding name.
  #
  # EXCEPTION (slice 7a): the class-ctor path builds a synthesized empty
  # ctor as a NAMED FunctionExpr (name = class name) precisely so
  # bind_callee_local fires and emits LoadCallee — that's the oracle shape
  # for `class C {}`. So allow a named FunctionExpr through when isClassCtor.
  let bindCalleeLocal = node.kind == FunctionExpr and node.fnNameLen > 0
  if bindCalleeLocal and not isClassCtor:
    return nil
  let body = fnBodyOf(node)

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
    # Inherit the enclosing derived-class parent so a `super(...)` inside
    # this body compiles the parent constructor (compiler.zc ~3929). Only
    # a class ctor / method body sees a non-nil value (set on the outer
    # compiler by compileClassValue before it compiles the members). Slice 7b.
    enclosingClassParent: enclosing.enclosingClassParent,
    # Slice 7d: inherit the enclosing class id + private-name scope stack so a
    # `this.#x` / `#m()` inside this body mangles + resolves against the
    # declaring class (compiler.zc copies parent.enclosing_class_id +
    # cls_stack_* into the child, ~3930-3946).
    enclosingClassId: enclosing.enclosingClassId,
    clsStack: enclosing.clsStack,
    # Slice 7e: generator / async flags (computed from the node above).
    isGenerator: kindIsGenerator,
    isAsync: kindIsAsync,
    # Slice 7f: a static-block body runs in static-super context (super.x
    # resolves against the parent constructor directly, NOT parent.prototype).
    # ONLY a StaticBlock body sets this — regular method / ctor bodies do NOT
    # inherit it (compiler.zc resets in_static_element=false at init ~375 and
    # sets it only for a StaticBlock node ~3961-3964). Static FIELD inits are
    # compiled inline on the OUTER compiler (which carries the flag), so their
    # nested funcs likewise don't inherit — matching the C.
    inStaticElement: isStaticBlock,
  )

  # 1. Bind params to the low fixed regs r0..rN-1 in declaration order.
  #    The rest param (always last if present, parser-enforced) also gets
  #    a register but is seeded by Op::BuildRestArgs in the prologue rather
  #    than a caller-supplied arg — so `param_count`/`paramCount` reflects
  #    only the REGULAR params (the arity for the header + BuildRestArgs
  #    first-index). Mirrors compiler.zc's regular_param_count / rest_reg
  #    (src/compiler.zc ~3969-4033).
  var paramNames: seq[string] = @[]
  var regularParamCount: uint32 = 0
  var hasRest = false
  var restReg: uint8 = 0
  # Pass 1: allocate the parameter registers contiguously at the bottom of
  # the register file. A DESTRUCTURING param (IdentExpr with identPattern)
  # records a zero-length-name PLACEHOLDER local so the default-init /
  # env-mirroring / destructure loops keep their param-order indexing
  # (mirrors compiler.zc ~3993 `add_local(c, p.start, 0, reg)`). Its inner
  # names are collected in pass 2 (below), AFTER all param regs.
  for p in params:
    if p.kind == RestParam:
      # Rest binding: its own register, param_count NOT incremented.
      let ra = p.restArg               # plain-ident target (gated above)
      restReg = allocReg(c)
      hasRest = true
      addLocalScoped(c, ra.start, ra.`end` - ra.start, uint32(restReg), 0'u32)
      c.locals[c.locals.len - 1].isParam = true
    elif p.kind == IdentExpr and p.identPattern != nil:
      # Destructuring-pattern param placeholder (object or array; a
      # defaulted pattern param bailed in paramsCompilable).
      paramNames.add("")
      let reg = allocReg(c)
      addLocalScoped(c, p.start, 0'u32, uint32(reg), 0'u32)
      c.locals[c.locals.len - 1].isParam = true
      regularParamCount += 1
    else:
      let nm = c.slice(p.start, p.`end`)
      paramNames.add(nm)
      let reg = allocReg(c)
      addLocalScoped(c, p.start, p.`end` - p.start, uint32(reg), 0'u32)
      c.locals[c.locals.len - 1].isParam = true
      regularParamCount += 1
  c.paramCount = regularParamCount

  # 1b. Named-FunctionExpr self-name bind (compiler.zc bind_callee_local,
  #     ~4041-4048). Reached only via the slice-7a class-ctor path (the
  #     synthesized empty ctor is a named FunctionExpr): allocate a fixed
  #     register AFTER params, add it as a local named after the class, and
  #     mark it fixed. The value is seeded by a LoadCallee prologue op
  #     emitted below (matching the empty-ctor oracle `LoadCallee r0`).
  var calleeReg: uint8 = 0
  if bindCalleeLocal:
    calleeReg = allocReg(c)
    addLocalScoped(c, node.fnNameStart, node.fnNameLen, uint32(calleeReg), 0'u32)
    if calleeReg + 1 > c.fixedRegs: c.fixedRegs = calleeReg + 1

  # Pass 2: inner pattern-binding locals come AFTER all param registers so
  # the caller's arg-passing layout stays contiguous. destructurePattern
  # (below, after default-init) fans the param value into them. Mirrors
  # compiler.zc ~4017-4026.
  for p in params:
    if p.kind != RestParam and p.kind == IdentExpr and p.identPattern != nil:
      collectPatternLocals(c, p.identPattern)

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

  # 4a-rest. Rest param (slice 4e): build the array from
  #          args_base[regularParamCount..argc] into restReg. `param_count`
  #          (= regularParamCount) is the first-rest index operand. Emitted
  #          here (after BuildArguments / cached-env LoadEnv, before env
  #          NewObject + default-init) to match compiler.zc ~4159-4162.
  if hasRest:
    emit(c, instAB(BuildRestArgs, restReg, uint8(regularParamCount)))

  # 4a-callee. Named-FunctionExpr self-name seed (compiler.zc ~4163-4167).
  #            Load the current callee into the self-binding local. Slice
  #            7a reaches this only for the synthesized empty class ctor
  #            (a captured callee — nested closure over the class name —
  #            would need env mirroring, out of this corpus). Emitted after
  #            BuildRestArgs, before default-init, matching the C order.
  if bindCalleeLocal:
    emit(c, instA(LoadCallee, calleeReg))

  # 4a-def. Default initializers for regular params (slice 4e): for each
  #         param with a default, `param === undefined ? <default> : param`,
  #         in declaration order. Mirrors compiler.zc's default-init loop
  #         (src/compiler.zc ~4179-4231). Sequence per defaulted param:
  #           LoadUndefined undefR          (sentinel)
  #           CmpStrictEq   tmp, paramReg, undefR
  #           JmpIfFalse    tmp -> <skip>   (arg present -> keep it)
  #           LoadHole      paramReg        (#330 TDZ: param is in its own
  #                                          TDZ while its default runs, so a
  #                                          self-reference hits ThrowIfHole)
  #           <compute default into initR>
  #           Mov paramReg <- initR         (only if initR != paramReg)
  #         <skip>: both paths converge with paramReg initialized. `tmp` is
  #         allocated BEFORE `undefR` (so tmp gets the lower temp reg) but
  #         LoadUndefined for undefR is emitted first — matching the C's
  #         alloc-then-emit order exactly. Rest params carry no default and
  #         are skipped. Runs BEFORE env NewObject (compiler.zc order).
  # Regular-param names in declaration order — for the self/forward-ref
  # TDZ guard below. A default that references its OWN param, or a LATER
  # param (still in TDZ), must emit a ThrowIfHole in C. We don't port
  # ThrowIfHole, so we BAIL (nim_missing) on those shapes rather than emit
  # an unguarded read; a reference to an EARLIER (already-initialized)
  # param — `function f(a, b = a)` — is fine and compiles.
  var regularNames: seq[string] = @[]
  for p in params:
    if p.kind != RestParam:
      regularNames.add(c.slice(p.start, p.`end`))

  var localIdx = 0
  var regIdx = 0
  for p in params:
    if p.kind == RestParam:
      continue
    if p.identDefault != nil:
      # Self / forward param reference in the default → the referenced
      # binding is in its TDZ; C guards with ThrowIfHole. Not ported: bail.
      var refsTdzParam = false
      var k = regIdx
      while k < regularNames.len:
        if subtreeMentionsName(c, p.identDefault, regularNames[k]):
          refsTdzParam = true
          break
        k += 1
      if refsTdzParam:
        c.hadError = true
        return nil
      let paramReg = c.locals[localIdx].reg
      let tmp = allocReg(c)
      let undefR = allocReg(c)
      emit(c, instA(LoadUndefined, undefR))
      emit(c, instABC(CmpStrictEq, tmp, paramReg, undefR))
      releaseReg(c, undefR)
      let skipIdx = emit(c, instAI16(JmpIfFalse, tmp, 0))
      releaseReg(c, tmp)
      # #330 TDZ ref-self: seed the param reg with the hole on the
      # default-taken branch and mark it uninitialized. (A self-reference
      # would hit ThrowIfHole in C — we've already bailed those above, so
      # this LoadHole is dead by construction but is emitted unconditionally
      # to match the oracle byte-for-byte.) Simple named non-captured param.
      let isSimpleParam = p.`end` > p.start and not c.locals[localIdx].captured
      if isSimpleParam:
        c.locals[localIdx].isTdz = true
        emit(c, instA(LoadHole, paramReg))
      let initR = compileExpr(c, p.identDefault)
      if initR != paramReg:
        emit(c, instAB(Mov, paramReg, initR))
      if initR + 1 == c.nextReg:
        c.nextReg = c.nextReg - 1
      resetTemps(c)
      patchJump(c, skipIdx)
      # Both paths converge here initialized — body reads skip the check.
      if isSimpleParam:
        c.locals[localIdx].isTdz = false
    localIdx += 1
    regIdx += 1

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

  # 4a'''. Pattern-param fan-out (slice 6d). Runs AFTER env init so
  #        bindDestructureTarget can StoreProp into envReg for captured
  #        inner bindings, and BEFORE the function-top TDZ hole seed
  #        (matching compiler.zc ~4275). Each object-pattern param's value
  #        (in its placeholder register) is destructured into its inner
  #        locals. localIdx tracks param order; a pattern param's src reg is
  #        the placeholder local's register.
  block:
    var localIdx = 0
    for p in params:
      if p.kind == RestParam:
        continue
      if p.kind == IdentExpr and p.identPattern != nil:
        let paramReg = c.locals[localIdx].reg
        destructurePattern(c, p.identPattern, paramReg)
      inc localIdx

  # 3z. Generator prologue terminator (slice 7e). ECMA-262 runs
  #     FunctionDeclarationInstantiation (the prologue above: BuildArguments,
  #     env, pattern-param fan-out) at the INITIAL call to a generator, then
  #     returns the iterator suspended at GeneratorStart; the body only runs
  #     on the first .next(). Emitted AFTER the pattern-param fan-out and
  #     BEFORE the function-top TDZ hole seed — mirrors compiler.zc ~4297-4316
  #     (section 3z, which precedes the `tz` hole loop at ~4344). Async
  #     functions have NO GeneratorStart.
  if c.isGenerator:
    emit(c, instA(GeneratorStart, 0))

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
    # Arrow CONCISE (expression) body: `x => expr`. Compile the expression
    # to a register and Return it directly (compiler.zc ~4370-4373). A
    # regular function body is always a BlockStmt, so only arrows reach
    # here. `x=>x` → `Mov r1<-r0; Return r1`; `()=>1` → `LoadInt r0=1;
    # Return r0`; `(a,b)=>a+b` → `Add r2,r0,r1; Return r2`.
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

  # ECMA-262 ExpectedArgumentCount: walk params left-to-right, stop at the
  # first with a default initializer or the rest binding (compiler.zc
  # ~4408-4419). NOT printed by disasm; set for later runtime phases.
  var eac: uint32 = 0
  for p in params:
    if p.kind == RestParam: break
    if p.identDefault != nil: break
    eac += 1

  var f = Function(
    code: c.code,
    constants: c.constants,
    registerCount: uint32(c.maxReg) + 1'u32,
    fixedRegs: c.fixedRegs,
    paramCount: c.paramCount,
    expectedArgCount: eac,
    constCount: uint32(c.constants.len),
    icCount: uint32(c.ics.len),
    ics: c.ics,
    # Repurposed: "body references an outer-scope name" (compiler.zc
    # ~4454). The ENCLOSING compiler reads this at MakeClosure to decide
    # whether to env-wrap us.
    needsEnv: c.hasOuterRefs,
    # The reg the VM seeds with `this` on frame entry (reserved after params
    # iff the body uses `this`), or -1. Carried into the emitted Function so
    # MethodInvoke / call frames can seed the receiver (slice B2).
    thisReg: c.thisReg,
    # Arrow flag drives the disasm " arrow" header and (at runtime) the
    # MakeClosure creation-time `this` snapshot. Set from the node kind
    # (compiler.zc ~4459 `f.is_arrow = node.kind == ArrowFunc`).
    isArrow: isArrow,
    # Class-constructor flag: the disasm header prints " class-ctor". Set
    # by the class-value codegen (compiler.zc ~5108). Slice 7a.
    isClassCtor: isClassCtor,
    # Slice 7e: generator / async header flags (compiler.zc ~4470-4474).
    isGenerator: c.isGenerator,
    isAsync: c.isAsync,
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

# --- Class value (slice 7a: base classes, methods, fields) ----------
#
# Mirrors compiler.zc compile_class_value (~5008) for the BASE-class
# subset: an empty class, instance/static plain methods, an explicit or
# synthesized constructor, and instance fields (which the parser injects
# into the synthesized ctor body as `this.f = init`, so they compile for
# free through the ctor). Emits:
#     LoadConst  ctorReg  <- const#0 = <ctor Function>
#     LoadProp   protoReg <- ctorReg.prototype  ic#0
#     (per method) LoadConst methodReg; DefineMethod target, nameIc, methodReg
#     return ctorReg
# The caller (ClassDecl stmt / ClassExpr expr) binds/returns ctorReg.
#
# DEFERRED (set hadError -> nim_missing, never wrong bytecode): extends /
# super (classParent != nil), getters/setters, computed method keys,
# private members (#x), static blocks, static fields, and generator/async
# methods. Each is detected up-front and bails the whole class.

proc classMemberIsConstructor(c: Compiler, m: AstNode): bool =
  ## Is this MethodDef the class constructor? A non-static MethodDef whose
  ## literal name is "constructor", OR the parser's synthesized ctor
  ## (methodNameLen == 0, injected when instance fields exist without an
  ## explicit ctor). A STATIC "constructor" is an ordinary static member.
  ## Mirrors compiler.zc's is_ctor derivation (~5018-5024).
  if m == nil or m.kind != MethodDef: return false
  if m.methodIsStatic: return false
  # A computed-key method (`[e](){}`) also has methodNameLen == 0 but is
  # NEVER the constructor (the ctor is matched by the literal name
  # "constructor"). Mirrors compiler.zc's is_computed_name guard (~5187).
  if m.methodComputedKey != nil: return false
  if m.methodNameLen == 0: return true      # synthesized (parser sentinel)
  if m.methodNameLen == 11'u32 and
     c.slice(m.methodNameStart, m.methodNameStart + m.methodNameLen) == "constructor":
    return true
  return false

proc subtreeHasDirectEval(c: Compiler, n: AstNode): bool =
  ## Does this subtree contain a direct-eval call — a `Call` whose callee is
  ## the bare identifier `eval`? A direct eval inside a DERIVED class body
  ## forces the class-scope bindings (the class name + its parent) into a
  ## captured env so the evaluated code can see them; the derived ctor is
  ## then wrapped in a MakeClosure and its `super(...)` reads the parent
  ## through that env (LoadEnv + LoadProp) instead of a plain LoadGlobal.
  ## That class-scope env-capture machinery is out of slice 7b, so a derived
  ## class body containing a direct eval BAILS (nim_missing) rather than emit
  ## the LoadGlobal-shaped super that diverges from the oracle.
  if n == nil: return false
  if n.kind == Call and n.callee != nil and n.callee.kind == IdentExpr and
     c.slice(n.callee.start, n.callee.`end`) == "eval":
    return true
  for ch in childNodes(n):
    if subtreeHasDirectEval(c, ch): return true
  return false

proc subtreeHasMemberSuper(n: AstNode): bool =
  ## Does this subtree contain a `super.prop` / `super[expr]` member access
  ## (a Member/Computed/OptionalMember/OptionalComputed whose receiver is a
  ## SuperExpr)? Slice 7b handles `super(...)` CALLS but DEFERS super
  ## PROPERTY access (a distinct op path). Detected up-front so any class
  ## whose ctor/method body touches `super.x` bails cleanly (nim_missing).
  ## Does NOT descend into nested non-arrow function bodies (they have their
  ## own `super` binding — but an arrow inherits it; being conservative and
  ## descending everywhere only makes us bail more, which is safe).
  if n == nil: return false
  case n.kind
  of Member, Computed, OptionalMember, OptionalComputed:
    if n.recv != nil and n.recv.kind == SuperExpr: return true
  else: discard
  for ch in childNodes(n):
    if subtreeHasMemberSuper(ch): return true
  return false

proc collectPatternNames(c: Compiler, pat: AstNode, acc: var seq[string]) =
  ## Collect every binding name a destructuring pattern introduces (leaf
  ## IdentExpr targets), recursing through nested patterns.
  if pat == nil: return
  case pat.kind
  of IdentExpr:
    if pat.`end` > pat.start: acc.add(c.slice(pat.start, pat.`end`))
  of ObjectPattern, ArrayPattern:
    for e in pat.patEntries:
      if e != nil and e.kind == PatternEntry and e.patTarget != nil:
        collectPatternNames(c, e.patTarget, acc)
  else: discard

proc collectBoundNamesShallow(c: Compiler, n: AstNode, acc: var seq[string]) =
  ## Collect names DECLARED (var/let/const/function/class) in `n` WITHOUT
  ## descending into nested function bodies OR into arbitrary expressions (an
  ## assignment `x = 1` does NOT declare `x`). Used by the strict-global-store
  ## detector to distinguish a bare-ident assignment to a LOCAL (safe) from
  ## one to a GLOBAL (needs StoreGlobalStrict — a strict-only op Nim doesn't
  ## model yet, so the enclosing member must bail rather than emit StoreGlobal).
  if n == nil: return
  case n.kind
  of VarDecl:
    for d in n.declarators:
      if d.kind == Declarator and d.nameLength > 0:
        acc.add(c.slice(d.nameStart, d.nameStart + d.nameLength))
      elif d.kind == Declarator and d.declPattern != nil:
        collectPatternNames(c, d.declPattern, acc)
  of FunctionDecl:
    if n.fnNameLen > 0: acc.add(c.slice(n.fnNameStart, n.fnNameStart + n.fnNameLen))
  of ClassDecl:
    if n.classNameLen > 0: acc.add(c.slice(n.classNameStart, n.classNameStart + n.classNameLen))
  of FunctionExpr, ArrowFunc: return          # own scope — don't descend
  # Only descend through STATEMENT containers (a bare expression can't
  # introduce a binding). This keeps `x = 1` from spuriously marking `x` bound.
  of BlockStmt:
    for s in n.stmtList: collectBoundNamesShallow(c, s, acc)
  of IfStmt:
    collectBoundNamesShallow(c, n.thenStmt, acc)
    collectBoundNamesShallow(c, n.elseStmt, acc)
  of WhileStmt: collectBoundNamesShallow(c, n.whileBody, acc)
  of DoWhileStmt: collectBoundNamesShallow(c, n.doBody, acc)
  of ForStmt:
    collectBoundNamesShallow(c, n.forInit, acc)
    collectBoundNamesShallow(c, n.forBody, acc)
  of ForInStmt, ForOfStmt:
    collectBoundNamesShallow(c, n.forBinding, acc)
    collectBoundNamesShallow(c, n.forInOfBody, acc)
  of LabeledStmt: collectBoundNamesShallow(c, n.labeled, acc)
  of SwitchStmt:
    for cs in n.cases:
      if cs != nil and cs.kind == SwitchCase:
        for s in cs.caseBody: collectBoundNamesShallow(c, s, acc)
  of TryStmt:
    collectBoundNamesShallow(c, n.tryBlock, acc)
    collectBoundNamesShallow(c, n.catchBlock, acc)
    collectBoundNamesShallow(c, n.finallyBlock, acc)
  else: discard

proc subtreeHasStrictGlobalStore(c: Compiler, n: AstNode, bound: seq[string],
                                 descendFns: bool): bool =
  ## Does this STRICT body contain an assignment / update whose target is a
  ## bare IdentExpr that is NOT locally bound (`bound`) — i.e. a store to a
  ## global that, in strict mode, the oracle lowers to StoreGlobalStrict?
  ## Nim always emits the non-strict StoreGlobal (strict form unmodeled), so a
  ## strict body that contains one would diverge — the caller BAILS instead.
  ##   * `descendFns=false` (method/ctor bodies): a nested function's OWN
  ##     strictness is settled at its own compile — don't descend.
  ##   * `descendFns=true` (STATIC BLOCK bodies): strict propagates into every
  ##     nested function, so their global stores diverge too — descend.
  if n == nil: return false
  case n.kind
  of Assignment:
    if n.target != nil and n.target.kind == IdentExpr:
      let nm = c.slice(n.target.start, n.target.`end`)
      if nm notin bound: return true
  of Unary, Postfix:
    # `++x` / `x++` / `--x` / `x--` on a bare global → strict global store.
    if n.unOp in {PlusPlus, MinusMinus} and n.operand != nil and
       n.operand.kind == IdentExpr:
      let nm = c.slice(n.operand.start, n.operand.`end`)
      if nm notin bound: return true
  of FunctionDecl, FunctionExpr, ArrowFunc:
    if not descendFns: return false           # own scope / own strictness
  else: discard
  for ch in childNodes(n):
    if subtreeHasStrictGlobalStore(c, ch, bound, descendFns): return true
  return false

proc collectAllBoundNames(c: Compiler, n: AstNode, acc: var seq[string]) =
  ## Collect EVERY declared name across the whole subtree INCLUDING nested
  ## function params + their locals (for the static-block full-descent strict
  ## check). Over-approximates "bound" (a name declared in one nested function
  ## counts as bound everywhere), which only makes the strict-store check bail
  ## LESS — but the static-block corpus that matters here has no legitimate
  ## cross-scope bare-global store, so this is safe in practice and errs toward
  ## fewer false bails on well-formed blocks.
  if n == nil: return
  case n.kind
  of FunctionDecl, FunctionExpr:
    if n.fnNameLen > 0: acc.add(c.slice(n.fnNameStart, n.fnNameStart + n.fnNameLen))
    for p in n.fnParams: collectPatternNames(c, (if p.kind == RestParam: p.restArg else: p), acc)
    collectAllBoundNames(c, n.fnBody, acc)
    return
  of ArrowFunc:
    for p in n.arrowParams: collectPatternNames(c, (if p.kind == RestParam: p.restArg else: p), acc)
    collectAllBoundNames(c, n.arrowBody, acc)
    return
  else: discard
  # Declarations at this level.
  var shallow: seq[string] = @[]
  collectBoundNamesShallow(c, n, shallow)
  for s in shallow: acc.add(s)
  for ch in childNodes(n): collectAllBoundNames(c, ch, acc)

proc staticBlockNameOffends(c: Compiler, nameStart, nameLen: uint32): bool =
  ## A static-block binding name that is a SyntaxError (§15.7.1): `arguments`
  ## is banned, and `await` is reserved as a BindingIdentifier inside a static
  ## init block. Escape-aware decode isn't needed for the common corpus, but
  ## `arguments` decodes to `arguments` — decode the slice first.
  if nameLen == 0: return false
  let raw = c.slice(nameStart, nameStart + nameLen)
  # cheap: if it contains no backslash, compare directly; else decode.
  let nm = if '\\' in raw: decodeStringBody(c.src, nameStart, nameLen) else: raw
  return nm == "arguments" or nm == "await"

proc staticBlockRefsArgumentsOrAwait(c: Compiler, n: AstNode): bool =
  ## Does the static-block subtree REFERENCE `arguments` / bind `await` at its
  ## own level (not inside a nested ordinary function, which has its own
  ## `arguments`)? A nested class's computed keys DO evaluate in the block
  ## scope, so descend into those. Conservative bail for the §15.7.1 early
  ## errors the Nim parser over-accepts once static blocks compile.
  if n == nil: return false
  case n.kind
  of IdentExpr:
    if staticBlockNameOffends(c, n.start, n.`end` - n.start): return true
  of ClassDecl:
    # `class await {}` — a class BINDING named `await` inside a static block.
    if staticBlockNameOffends(c, n.classNameStart, n.classNameLen): return true
  of VarDecl:
    for d in n.declarators:
      if d.kind == Declarator and d.nameLength > 0 and
         staticBlockNameOffends(c, d.nameStart, d.nameLength): return true
  of FunctionDecl, FunctionExpr, ArrowFunc:
    return false                              # own `arguments` binding
  else: discard
  for ch in childNodes(n):
    if staticBlockRefsArgumentsOrAwait(c, ch): return true
  return false

proc blockHasDupLexical(c: Compiler, body: AstNode): bool =
  ## Top-level duplicate lexical binding OR let/const-vs-var clash in a block
  ## (§15.7.1 / §14.2.1). Only the block's OWN statement list is scanned (a
  ## nested block has its own scope). Detects `let x; let x;` and `let x; var x;`.
  if body == nil or body.kind != BlockStmt: return false
  var lexNames: seq[string] = @[]
  var varNames: seq[string] = @[]
  for s in body.stmtList:
    if s == nil or s.kind != VarDecl: continue
    let isVar = s.declKind == KwVar
    for d in s.declarators:
      if d.kind != Declarator or d.nameLength == 0: continue
      let nm = c.slice(d.nameStart, d.nameStart + d.nameLength)
      if isVar:
        if nm in lexNames: return true        # var clashes a prior let/const
        varNames.add(nm)
      else:
        if nm in lexNames or nm in varNames: return true   # dup lexical / clash
        lexNames.add(nm)
  return false

proc subtreeHasDupLabel(c: Compiler, n: AstNode, enclosing: var seq[string]): bool =
  ## A LabeledStatement whose label duplicates an enclosing label is a
  ## SyntaxError (§14.13.1). Walk the label nesting; a nested class's static
  ## block is a fresh label scope (its own compile handles it). Don't descend
  ## into nested functions (fresh label scope).
  if n == nil: return false
  case n.kind
  of LabeledStmt:
    if n.labelLen > 0:
      let lbl = c.slice(n.labelStart, n.labelStart + n.labelLen)
      if lbl in enclosing: return true
      enclosing.add(lbl)
      let r = subtreeHasDupLabel(c, n.labeled, enclosing)
      enclosing.setLen(enclosing.len - 1)
      return r
  of FunctionDecl, FunctionExpr, ArrowFunc:
    return false
  else: discard
  for ch in childNodes(n):
    if subtreeHasDupLabel(c, ch, enclosing): return true
  return false

proc staticBlockHasEarlyError(c: Compiler, body: AstNode): bool =
  ## Combined §15.7.1 static-block early-error gate: banned `arguments`/`await`,
  ## duplicate lexical bindings / let-var clash, and duplicate labels. These
  ## are parse-phase SyntaxErrors the Nim parser doesn't enforce for a static
  ## block nested in a function; bail so Nim doesn't over-accept.
  if body == nil: return false
  if staticBlockRefsArgumentsOrAwait(c, body): return true
  if blockHasDupLexical(c, body): return true
  var lbls: seq[string] = @[]
  if subtreeHasDupLabel(c, body, lbls): return true
  return false

proc subtreeHasTopLevelReturn(n: AstNode): bool =
  ## Does this static-block body contain a `return` statement at its OWN
  ## level (NOT inside a nested function)? A static block is a `[~Return]`
  ## context (ECMA-262 §15.7.1) — a top-level `return` is a SyntaxError the
  ## oracle's parser rejects. The Nim parser doesn't clear the return-legal
  ## flag when a static block nests inside a function, so it over-accepts;
  ## detect + bail here to avoid the `zjs_missing` over-accept.
  if n == nil: return false
  case n.kind
  of ReturnStmt: return true
  of FunctionDecl, FunctionExpr, ArrowFunc: return false   # own return context
  else: discard
  for ch in childNodes(n):
    if subtreeHasTopLevelReturn(ch): return true
  return false

proc staticBodyDivergesStrict(c: Compiler, body: AstNode,
                              descendFns: bool = false): bool =
  ## True if a STRICT static-block / method body would emit a strict-only
  ## global store (bail signal). Gathers the body's bindings, then scans for a
  ## bare-global assignment/update target. Static blocks pass descendFns=true
  ## (strict propagates into nested functions; collect their bindings too).
  if body == nil: return false
  var bound: seq[string] = @[]
  if descendFns: collectAllBoundNames(c, body, bound)
  else:          collectBoundNamesShallow(c, body, bound)
  return subtreeHasStrictGlobalStore(c, body, bound, descendFns)

# --- Method-name canonicalization (mirrors intern_method_name_atom) --
#
# A class-member name may be an identifier (`m`), a string literal
# (`"m"`), or a numeric literal (`0` / `0x10` / `1.5`). The parser stores
# the RAW source slice (quotes / digits included) in methodNameStart/Len.
# The atom the runtime keys on is the CANONICAL name: a string literal has
# its quotes stripped + escapes decoded; a numeric literal is ToString'd
# (integral values print without a decimal point). Mirrors compiler.zc
# intern_method_name_atom (~4606). Used both for the IC slot of a plain
# string/number method (DefineMethod) and the const-pool key of an
# accessor (DefineMethodGetter/Setter). Private (`#`) names are handled
# upstream (deferred to slice 7d), so only the three public forms here.

proc parseIntPrefixC(digits: string, base: int): float64 =
  ## Base-N integer accumulation (hex/bin/oct), mirroring the parser's
  ## parseIntPrefix. Local copy so the compiler stays parser-independent.
  var acc = 0.0
  for ch in digits:
    var d: int
    if ch >= '0' and ch <= '9': d = ord(ch) - ord('0')
    elif ch >= 'a' and ch <= 'f': d = ord(ch) - ord('a') + 10
    elif ch >= 'A' and ch <= 'F': d = ord(ch) - ord('A') + 10
    else: return acc
    acc = acc * float64(base) + float64(d)
  acc

proc parseNumberLiteralC(src: string, start, length: uint32): float64 =
  ## Local port of the parser's parseNumberLiteral (strip `_` separators,
  ## dispatch on the 0x/0b/0o prefix, else decimal via parseFloat).
  var buf = newStringOfCap(int(length))
  var i = 0'u32
  while i < length:
    let ch = src[int(start + i)]
    if ch != '_': buf.add(ch)
    inc i
  if buf.len >= 2 and buf[0] == '0':
    let c1 = buf[1]
    if c1 == 'x' or c1 == 'X': return parseIntPrefixC(buf[2 .. ^1], 16)
    if c1 == 'b' or c1 == 'B': return parseIntPrefixC(buf[2 .. ^1], 2)
    if c1 == 'o' or c1 == 'O': return parseIntPrefixC(buf[2 .. ^1], 8)
  parseFloat(buf)

proc cSnprintfG(buf: cstring, n: csize_t, fmt: cstring): cint
  {.importc: "snprintf", header: "<stdio.h>", varargs, discardable.}

proc formatGprec(d: float64, prec: cint): string =
  ## C `%.*g` for a given precision. The numeric-name canonicalization must
  ## match the C intern_method_name_atom snprintf byte-for-byte, and Nim's
  ## `formatFloat(ffDefault)` diverges (keeps a trailing `.`, prefers the
  ## exponent form), so we call libc directly — the same routine the oracle
  ## uses.
  var buf: array[48, char]
  let n = cSnprintfG(cast[cstring](addr buf[0]), 48, cstring("%.*g"), prec, d)
  let ln = if n < 0: 0 elif n > 47: 47 else: int(n)
  result = newString(ln)
  for i in 0 ..< ln: result[i] = buf[i]

proc numberNameToString(d: float64): string =
  ## ECMA-262 Number::toString for a finite double, matching the C
  ## snprintf ladder in intern_method_name_atom: integral values in the
  ## safe range print as `%lld`; otherwise the shortest `%.*g` that
  ## round-trips. Only class-member numeric NAMES reach here.
  if d == float64(int64(d)) and d >= -1e15 and d <= 1e15:
    return $int64(d)
  # Shortest round-tripping decimal (mirrors the prec 1..17 `%g` scan).
  for prec in cint(1) .. cint(17):
    let s = formatGprec(d, prec)
    if parseFloat(s) == d:
      return s
  return formatGprec(d, 17)

proc internMethodNameAtom(c: Compiler, nameStart, nameLen: uint32): string =
  ## Canonical member name for `nameStart..nameStart+nameLen`.
  if nameLen == 0: return ""
  let first = c.src[nameStart.int]
  # PrivateName: mangle to the per-class hidden key (compiler.zc
  # intern_method_name_atom ~4611). Uses the CURRENT class id — declaration
  # sites always mangle with the enclosing class. (Slice 7d.)
  if first == '#':
    if c.enclosingClassId < 0: return ""   # not in a class (caller bails)
    return manglePrivateWithId(c, nameStart, nameLen, uint32(c.enclosingClassId))
  # NumberLit: leading digit, or `.` followed by a digit.
  let isNumeric =
    (first >= '0' and first <= '9') or
    (first == '.' and nameLen > 1 and
     c.src[(nameStart + 1).int] >= '0' and c.src[(nameStart + 1).int] <= '9')
  if isNumeric:
    return numberNameToString(parseNumberLiteralC(c.src, nameStart, nameLen))
  # StringLit: surrounded by quotes -> strip + decode the body.
  if first == '"' or first == '\'':
    if nameLen < 2: return ""
    return decodeStringBody(c.src, nameStart + 1, nameLen - 2)
  # Identifier / keyword: the source slice is the canonical name.
  return c.slice(nameStart, nameStart + nameLen)

proc classValueUnsupported(c: Compiler, node: AstNode): bool =
  ## True if this class contains any construct slice 7a/7b defers. Checked
  ## before emitting anything so the whole class bails cleanly.
  ## Slice 7b: `extends B` + `super(...)` calls are now SUPPORTED.
  ## Slice 7f: member-super READS (`super.x`) and CALLS (`super.m(...)` /
  ## `super[e](...)`) are SUPPORTED — the compile arms (compileExpr Member,
  ## compileCall isMethod) emit the LoadElem-off-parent.prototype shape and
  ## bail (hadError) on the still-deferred forms below (they recompile the
  ## bare SuperExpr leaf, which errors):
  ##   * `super.x = v` write   — Member-target assignment recompiles the recv
  ##   * `super[e]` bare read  — the Computed arm recompiles the recv
  ##   * `super.m(...args)`    — callHasSpreadArg bails before the super arm
  ## Static blocks (`static { ... }`) are SUPPORTED (own Function + immediate
  ## MethodInvoke recv=ctor, in source order with static fields).
  #
  # Slice 7f: member-super is byte-exact ONLY when the parent is a plain
  # GLOBAL identifier (`extends B`, B a global) — the compile arms recompile
  # `enclosingClassParent` as a LoadGlobal. When the parent is a LEXICAL
  # binding (e.g. `class B {} class C extends B {…super…}` — B is a
  # script-scope class local), the oracle builds a CLASS-SCOPE env: it wraps
  # the super-using method in a MakeClosure and reads the parent through the
  # env (NewObject + StoreProp env.B + LoadProp env.B). That class-scope
  # env-capture machinery is out of this slice, so BAIL any class that uses
  # member-super whose parent isn't a bare global identifier.
  block memberSuperEnvGate:
    var hasMemberSuper = false
    for m in node.classMembers:
      if m != nil and subtreeHasMemberSuper(m): hasMemberSuper = true; break
    if hasMemberSuper:
      let p = node.classParent
      # Parent must be a bare identifier that resolves to a GLOBAL (not a
      # local / captured binding) from the current compiler's scope.
      if p == nil or p.kind != IdentExpr:
        return true
      let pname = c.slice(p.start, p.`end`)
      if findLocalIndex(c, pname) >= 0: return true    # local parent → env-cap
      # A parent captured from an ENCLOSING function scope also forces env
      # capture. Walk the parent-compiler chain: any same-name local up the
      # chain means the parent is a captured binding, not a global.
      var pc = c.parent
      while pc != nil:
        if findLocalIndex(pc[], pname) >= 0: return true
        pc = pc[].parent
  # A derived class whose body contains a direct eval forces class-scope
  # env-capture (parent read through the env in super) — out of slice 7b.
  if node.classParent != nil:
    for m in node.classMembers:
      if m != nil and subtreeHasDirectEval(c, m): return true
  for m in node.classMembers:
    if m == nil: return true
    case m.kind
    of MethodDef:
      # Slice 7c: get/set accessors and computed method keys are SUPPORTED.
      # Slice 7e: async / generator methods now compile too — the class emit
      # path (LoadConst + DefineMethod) is byte-identical to a plain method
      # (verified against the oracle); only the nested Function body + its
      # header flags differ, which compileFunction handles. A generator/async
      # ACCESSOR is a parse error, so there's no gen/async-accessor
      # interaction to guard here.
      # Slice 7d: INSTANCE private methods (`#m(){}`) + private accessors
      # (`get/set #x`) are SUPPORTED (DefineMethod / DefineMethodGetter/Setter
      # with the mangled key). STATIC private members (`static #m(){}`) are
      # DEFERRED — the static-private receiver install is a distinct path.
      if m.methodComputedKey == nil and m.methodNameLen > 0 and
         c.src[m.methodNameStart.int] == '#' and m.methodIsStatic: return true
      # Slice 7f: a class method body is STRICT. Member-super is now enabled,
      # so a method whose body touches `super.x` is no longer blanket-bailed —
      # but if that (newly-enabled) body ALSO contains a strict-only global
      # store, Nim would emit StoreGlobal where the oracle emits
      # StoreGlobalStrict. Bail such a member to avoid the divergence. (This
      # only fires for member-super bodies — the pre-existing strict-store gap
      # in plain non-super methods is orthogonal and out of this slice.)
      if subtreeHasMemberSuper(m.methodBody) and
         staticBodyDivergesStrict(c, m.methodBody): return true
    of ClassField:
      # Slice 7c: static fields (plain + computed key) are now SUPPORTED.
      # Instance fields are lowered via the synthesized ctor (7a); a
      # computed INSTANCE-field key is not byte-validated there, so bail.
      if not m.fieldIsStatic and m.fieldComputedKey != nil: return true
      # Slice 7d: INSTANCE private fields (`#x = 1`) are SUPPORTED (lowered
      # through the synthesized ctor as a mangled StoreProp). STATIC private
      # fields (`static #x`) are DEFERRED (static-private receiver path).
      if m.fieldComputedKey == nil and m.fieldNameLen > 0 and
         c.src[m.fieldNameStart.int] == '#' and m.fieldIsStatic: return true
    of StaticBlock:
      # Slice 7f: a static initialization block is SUPPORTED (compiled as its
      # own Function, invoked immediately with `this`=ctor, in source order
      # with static fields). A block that CAPTURES outer scope (its Function
      # would be needsEnv) is refused at the compile site — compileFunction
      # returns a needsEnv Function and the static-element pass bails.
      # A static block body is STRICT (class body); if it would emit a
      # strict-only global store (`static { x = 1 }`, OR a global store inside
      # a nested function — strict propagates) — an op Nim doesn't model —
      # bail rather than diverge (StoreGlobalStrict vs StoreGlobal).
      if staticBodyDivergesStrict(c, m.staticBlockBody, descendFns = true): return true
      # A top-level `return` in a static block is a SyntaxError the Nim parser
      # over-accepts when the block nests in a function — bail to match the
      # oracle (which parse-errors), avoiding a `zjs_missing` over-accept.
      if subtreeHasTopLevelReturn(m.staticBlockBody): return true
      # Other §15.7.1 static-block parse-phase early errors the Nim parser
      # doesn't enforce (banned arguments/await, dup lexical / let-var clash,
      # dup labels) — bail to avoid over-accepting.
      if staticBlockHasEarlyError(c, m.staticBlockBody): return true
    else:
      return true
  return false

proc compileClassValue(c: var Compiler, node: AstNode): uint8 =
  # 0b. Slice 7d: assign this class its id from the shared program-wide
  #     counter FIRST — the oracle's compile_class_value pre-increments
  #     ctx.class_id_counter UNCONDITIONALLY at the top (compiler.zc 5038),
  #     before any bail. Doing it before classValueUnsupported keeps the id
  #     ASSIGNMENT ORDER identical to the oracle even when Nim bails on a
  #     class the oracle would id — a bail returns nil for the whole program
  #     (nim_missing, never wrong bytecode), but this keeps a future slice
  #     that lifts a bail from silently shifting ids.
  c.globals.classIdCounter = c.globals.classIdCounter + 1
  let thisClassId = c.globals.classIdCounter

  # Bail on any deferred construct before emitting anything.
  if classValueUnsupported(c, node):
    c.hadError = true
    return allocReg(c)

  # 0. Slice 7b: publish the `extends` expression on THIS compiler for the
  #    duration of the member compiles, so a `super(...)` inside the ctor
  #    body resolves the parent constructor (compileFunction inherits it into
  #    the child). Restored at the end. Mirrors compiler.zc ~5031-5033.
  let savedClassParent = c.enclosingClassParent
  c.enclosingClassParent = node.classParent

  #     Publish the id + an enclosing-class-scope frame BEFORE compiling any
  #     member, so the ctor body's `this.#x = init` mangle and every
  #     method-body private access resolve against THIS class. (7d)
  let savedClassId = c.enclosingClassId
  let savedStackLen = c.clsStack.len
  c.enclosingClassId = int(thisClassId)
  # Pre-scan private members → the private-bound-name registry (name→kind).
  # Kind bits mirror compiler.zc (~5057-5063): 1=field, 2=method, 4=getter,
  # 8=setter; a get+set pair merges to 4|8. A name that is BOTH a getter and
  # a setter is registered once with the merged kind. (Slice 7d.)
  var scope = ClassScope(id: thisClassId, names: @[], kinds: @[])
  for m in node.classMembers:
    if m == nil: continue
    var pStart, pLen: uint32
    var isPriv = false
    if m.kind == MethodDef and m.methodComputedKey == nil and
       isPrivateName(c, m.methodNameStart, m.methodNameLen):
      pStart = m.methodNameStart; pLen = m.methodNameLen; isPriv = true
    elif m.kind == ClassField and m.fieldComputedKey == nil and
         isPrivateName(c, m.fieldNameStart, m.fieldNameLen):
      pStart = m.fieldNameStart; pLen = m.fieldNameLen; isPriv = true
    if not isPriv: continue
    let bare = c.slice(pStart + 1, pStart + pLen)
    var kindBit: uint8 = 1                        # field
    if m.kind == MethodDef:
      case m.methodAccessor
      of KwGet: kindBit = 4
      of KwSet: kindBit = 8
      else:     kindBit = 2
    var found = -1
    for i in 0 ..< scope.names.len:
      if scope.names[i] == bare: found = i; break
    if found >= 0:
      # Duplicate PrivateBoundName — a SyntaxError UNLESS it's a matching
      # get+set accessor pair (compiler.zc 5071-5079). Any other duplicate
      # (#m/#m, #x field twice, method+field, get+get, …) is an early error.
      let prevk = scope.kinds[found]
      let pairOk = (prevk == 4'u8 and kindBit == 8'u8) or
                   (prevk == 8'u8 and kindBit == 4'u8)
      if not pairOk:
        # Restore inline (the scope frame isn't pushed yet; the template that
        # does this is defined below). The whole program compile returns nil.
        c.enclosingClassParent = savedClassParent
        c.enclosingClassId = savedClassId
        c.hadError = true
        return allocReg(c)
      scope.kinds[found] = prevk or kindBit
    else:
      scope.names.add(bare)
      scope.kinds.add(kindBit)
  c.clsStack.add(scope)

  # Restore all enclosing-class state (parent + id + scope stack) on the way
  # out. Called at every return so a SIBLING class starts fresh and gets the
  # next id (compiler.zc 5406-5408). On an error path the whole program
  # compile returns nil, so restoration there is merely tidy.
  template restoreClassState() =
    c.enclosingClassParent = savedClassParent
    c.enclosingClassId = savedClassId
    if c.clsStack.len > savedStackLen: c.clsStack.setLen(savedStackLen)

  # 1. Find the constructor MethodDef (explicit or parser-synthesized).
  var ctorNode: AstNode = nil
  for m in node.classMembers:
    if classMemberIsConstructor(c, m):
      ctorNode = m

  # 2. Compile the constructor Function. An explicit / synthesized ctor is
  #    a MethodDef (no LoadCallee). If ABSENT (no fields, no explicit
  #    ctor), synthesize an empty NAMED FunctionExpr carrying the class
  #    name so compileFunction's bind_callee_local fires -> LoadCallee
  #    (matching the `class C {}` oracle). An anonymous class expr
  #    (classNameLen == 0) synthesizes a name-less FunctionExpr -> no
  #    LoadCallee. Mirrors compiler.zc ~5089-5106.
  var ctorFn: Function
  if ctorNode != nil:
    ctorFn = compileFunction(c.src, ctorNode, c, isClassCtor = true)
  else:
    let empty = newFunctionExpr(node.classNameStart, node.classNameStart,
                                node.classNameStart, node.classNameLen,
                                nil, @[], false, false)
    ctorFn = compileFunction(c.src, empty, c, isClassCtor = true)
  if ctorFn == nil:
    restoreClassState()
    c.hadError = true
    return allocReg(c)
  # Default derived ctor (extends + NO explicit constructor): mark so the
  # runtime forwards args to the parent ctor. Its body is the minimal
  # LoadCallee; LoadUndefined; Return already produced by compileFunction.
  # NOT printed by disasm — no byte effect. Mirrors compiler.zc ~5111-5113.
  if ctorNode == nil and node.classParent != nil:
    ctorFn.isDefaultDerivedCtor = true

  # 3. LoadConst the ctor Function into ctorReg. A ctor that captures outer
  #    scope would need a MakeClosure wrap (compiler.zc ~5141-5148) — out of
  #    the base-class corpus (a ctor body referencing an enclosing local),
  #    so refuse rather than emit an unvalidated wrap.
  if ctorFn.needsEnv:
    c.hadError = true
    return allocReg(c)
  c.constants.add(Constant(kind: ckFunction, fn: ctorFn))
  let ctorReg = allocReg(c)
  emit(c, instAU16(LoadConst, ctorReg, uint16(c.constants.len - 1)))

  # 4. Load `<ctor>.prototype` once into protoReg for all instance methods
  #    (compiler.zc ~5168-5175). ic#0 = "prototype".
  let protoIc = allocIcSlot(c, "prototype")
  if protoIc > 255:
    c.hadError = true
    return ctorReg
  let protoReg = allocReg(c)
  emit(c, instABC(LoadProp, protoReg, ctorReg, uint8(protoIc)))

  # 5. Attach each non-constructor method. Instance methods -> prototype
  #    (target = protoReg); static methods -> the constructor itself
  #    (target = ctorReg). Mirrors compiler.zc ~5178-5311. Three shapes,
  #    all with `LoadConst methodReg` first:
  #      * plain method (ident / string / number name) -> DefineMethod with
  #        the canonicalized name in an IC slot (a=target, b=nameIc, c=mReg).
  #      * get/set accessor -> LoadConst keyReg <- name-string const, then
  #        DefineMethodGetter/Setter (a=target, b=keyReg, c=mReg). The key
  #        is a CONST (materialized via LoadConst), NOT an IC slot.
  #      * computed key `[e](){}` -> compile the key EXPRESSION into keyReg,
  #        then DefineMethodComputed / Getter / Setter (a=target, b=keyReg,
  #        c=mReg). Fields are handled in the static-elements pass below.
  for m in node.classMembers:
    if m == nil: continue
    if m.kind == ClassField: continue          # fields handled separately
    if classMemberIsConstructor(c, m): continue
    if m.kind == StaticBlock:
      # Slice 7f QUIRK: the oracle's method-attach loop does NOT skip a
      # StaticBlock (only ClassField is skipped — compiler.zc ~5182), so a
      # static block gets a PHANTOM DefineMethod here in ADDITION to its real
      # immediate-invoke in the static-element pass below. The block Function
      # is thus compiled TWICE (two distinct const-pool entries). The phantom
      # attaches to the CONSTRUCTOR (StaticBlock.bool_value=true → static) with
      # the EMPTY name atom in an IC slot (name_length==0). We replicate it
      # byte-for-byte:  LoadConst mReg; DefineMethod ctorReg, emptyNameIc, mReg.
      let pfn = compileFunction(c.src, m, c)
      if pfn == nil or pfn.needsEnv:
        c.hadError = true
        return ctorReg
      c.constants.add(Constant(kind: ckFunction, fn: pfn))
      let phantomReg = allocReg(c)
      emit(c, instAU16(LoadConst, phantomReg, uint16(c.constants.len - 1)))
      let emptyIc = allocIcSlot(c, "")
      if emptyIc > 255:
        c.hadError = true
        return ctorReg
      emit(c, instABC(DefineMethod, ctorReg, uint8(emptyIc), phantomReg))
      releaseReg(c, phantomReg)
      continue
    if m.kind != MethodDef: continue           # (guarded unsupported above)
    let mfn = compileFunction(c.src, m, c)
    if mfn == nil:
      c.hadError = true
      return ctorReg
    if mfn.needsEnv:
      # A method capturing outer scope needs a MakeClosure wrap — out of
      # the base-class corpus. Refuse rather than diverge.
      c.hadError = true
      return ctorReg
    c.constants.add(Constant(kind: ckFunction, fn: mfn))
    let methodReg = allocReg(c)
    emit(c, instAU16(LoadConst, methodReg, uint16(c.constants.len - 1)))
    let target = if m.methodIsStatic: ctorReg else: protoReg
    if m.methodComputedKey != nil:
      # Computed key: evaluate the expression at runtime into keyReg.
      let keyReg = compileExpr(c, m.methodComputedKey)
      case m.methodAccessor
      of KwGet: emit(c, instABC(DefineMethodGetter, target, keyReg, methodReg))
      of KwSet: emit(c, instABC(DefineMethodSetter, target, keyReg, methodReg))
      else:     emit(c, instABC(DefineMethodComputed, target, keyReg, methodReg))
      releaseReg(c, keyReg)
      releaseReg(c, methodReg)
      continue
    # Non-computed name: canonicalize (strip quotes / ToString numbers).
    let mname = internMethodNameAtom(c, m.methodNameStart, m.methodNameLen)
    if m.methodAccessor == KwGet or m.methodAccessor == KwSet:
      # Accessor: the key is a string CONST loaded into its own register.
      c.constants.add(Constant(kind: ckString, s: mname))
      let keyReg = allocReg(c)
      emit(c, instAU16(LoadConst, keyReg, uint16(c.constants.len - 1)))
      if m.methodAccessor == KwGet:
        emit(c, instABC(DefineMethodGetter, target, keyReg, methodReg))
      else:
        emit(c, instABC(DefineMethodSetter, target, keyReg, methodReg))
      releaseReg(c, keyReg)
    else:
      # Plain method: name in an IC slot -> DefineMethod.
      let mIc = allocIcSlot(c, mname)
      if mIc > 255:
        c.hadError = true
        return ctorReg
      emit(c, instABC(DefineMethod, target, uint8(mIc), methodReg))
    releaseReg(c, methodReg)

  # 6. `extends Parent` (slice 7b): chain Child.prototype.[[Prototype]] =
  #    Parent.prototype AND record the parent constructor on the child ctor
  #    (so Object.getPrototypeOf(Child) === Parent). Evaluated AFTER methods
  #    so they land on the child's own prototype, and while protoReg is still
  #    live (parentReg / parentProtoReg allocate above it). Mirrors
  #    compiler.zc ~5314-5339. Emits:
  #      LoadGlobal    parentReg      <- Parent          (extends B: a global)
  #      LoadProp      parentProtoReg <- parentReg.prototype  ic#0 (reused)
  #      SetProto      a=parentProtoReg, b=protoReg
  #      SetParentCtor a=ctorReg,        b=parentReg
  #    `extends null` (LoadNull + SetProto, no SetParentCtor) is a distinct
  #    shape not in the 7b corpus — DEFER (bail) rather than emit unvalidated.
  if node.classParent != nil:
    if node.classParent.kind == NullExpr:
      c.hadError = true
      restoreClassState()
      return ctorReg
    # Parent expression -> parentReg. No preferred_dst (fresh reg), matching
    # compiler.zc's bare `compile_expr(c, cls_node.right)`. For `extends B`
    # this is a LoadGlobal into the freshly-allocated reg.
    let parentReg = compileExpr(c, node.classParent)
    # "prototype" IC dedups to ic#0 (already allocated above for the child's
    # own prototype load) — the reuse the oracle relies on.
    let parentProtoIc = allocIcSlot(c, "prototype")
    let parentProtoReg = allocReg(c)
    if parentProtoIc <= 255:
      emit(c, instABC(LoadProp, parentProtoReg, parentReg, uint8(parentProtoIc)))
      emit(c, instAB(SetProto, parentProtoReg, protoReg))
    else:
      c.hadError = true
    emit(c, instAB(SetParentCtor, ctorReg, parentReg))
    releaseReg(c, parentProtoReg)
    if parentReg + 1 == c.nextReg: c.nextReg = c.nextReg - 1

  # 7. Static ELEMENTS (slice 7c/7f): static field initializers AND static
  #    initialization blocks, run at class-definition time in SOURCE ORDER
  #    (INTERLEAVED — a single loop), each with `this` bound to the
  #    constructor. Instance fields are lowered via the ctor body (7a);
  #    only the static half is emitted here. Mirrors compiler.zc ~5341-5400.
  #    `this` is routed to ctorReg for the duration (so `this` inside a
  #    static init reads the constructor); borrowLocalOk is cleared so ctorReg
  #    is never handed out as a scratch dst; inStaticElement is set so a
  #    `super.x` in a static field init resolves against parent (not
  #    parent.prototype). Emits:
  #      * static block `static { ... }` -> compile the block as its OWN
  #        Function (own var/lexical env), LoadConst it, then invoke it
  #        immediately with `this`=ctor:
  #          Mov base <- blockFnReg;  Mov recv <- ctorReg;
  #          MethodInvoke base, base, argc=0            (compiler.zc ~5358-5373)
  #      * plain field `static x = e`    -> compile e -> valReg;
  #                                          StoreProp ctorReg.x <- valReg (IC)
  #      * computed    `static [k] = e`  -> compile e -> valReg; compile k ->
  #                                          keyReg; StoreElem ctorReg,key,val
  #    The value is compiled BEFORE the computed key (compiler.zc order).
  let savedThisReg = c.thisReg
  let savedBorrow  = c.borrowLocalOk
  let savedStaticEl = c.inStaticElement
  c.thisReg = int(ctorReg)
  c.borrowLocalOk = false
  c.inStaticElement = true
  template restoreStaticState() =
    c.thisReg = savedThisReg
    c.borrowLocalOk = savedBorrow
    c.inStaticElement = savedStaticEl
  for m in node.classMembers:
    if m == nil: continue
    if m.kind == StaticBlock:
      # Compile the block body as its own Function (compile_function_value):
      # append to the const pool, LoadConst into blockFnReg. A block that
      # captures outer scope (needsEnv) would need a MakeClosure wrap — out
      # of the 7f corpus, so refuse rather than emit an unvalidated wrap.
      let blockFn = compileFunction(c.src, m, c)
      if blockFn == nil or blockFn.needsEnv:
        c.hadError = true
        restoreStaticState()
        restoreClassState()
        return ctorReg
      c.constants.add(Constant(kind: ckFunction, fn: blockFn))
      let blockFnReg = allocReg(c)
      emit(c, instAU16(LoadConst, blockFnReg, uint16(c.constants.len - 1)))
      let base = allocReg(c)       # callee slot
      let recv = allocReg(c)       # base+1 — the `this` receiver
      emit(c, instAB(Mov, base, blockFnReg))
      emit(c, instAB(Mov, recv, ctorReg))
      emit(c, instABC(MethodInvoke, base, base, 0))
      releaseReg(c, recv)
      releaseReg(c, base)
      releaseReg(c, blockFnReg)
      continue
    if m.kind != ClassField: continue
    if not m.fieldIsStatic: continue           # instance fields via ctor
    # Value: the initializer, or `undefined` when absent (`static x;`).
    var valReg: uint8
    if m.fieldInit != nil:
      valReg = compileExpr(c, m.fieldInit)
    else:
      valReg = allocReg(c)
      emit(c, instA(LoadUndefined, valReg))
    if m.fieldComputedKey != nil:
      let keyReg = compileExpr(c, m.fieldComputedKey)
      emit(c, instABC(StoreElem, ctorReg, keyReg, valReg))
      releaseReg(c, keyReg)
    else:
      let fname = internMethodNameAtom(c, m.fieldNameStart, m.fieldNameLen)
      if not emitStorePropAtom(c, ctorReg, fname, valReg):
        restoreStaticState()
        restoreClassState()
        return ctorReg
    releaseReg(c, valReg)
  restoreStaticState()

  releaseReg(c, protoReg)
  restoreClassState()
  return ctorReg

# --- Program --------------------------------------------------------

proc hoistPatternGlobals(c: var Compiler, pat: AstNode) =
  ## Pre-intern every binding name a `var` destructuring pattern introduces,
  ## in source order, so its global slot precedes the initializer's globals
  ## (mirrors compiler.zc hoist_pattern_globals).
  if pat == nil: return
  case pat.kind
  of IdentExpr:
    if pat.`end` > pat.start:
      discard internGlobal(c, c.slice(pat.start, pat.`end`))
  of ObjectPattern, ArrayPattern:
    for entry in pat.patEntries:
      if entry != nil and entry.kind == PatternEntry and entry.patTarget != nil:
        hoistPatternGlobals(c, entry.patTarget)
  else: discard

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
        elif decl.kind == Declarator and decl.declPattern != nil:
          # Destructuring `var {a} = …` at script scope: pre-intern every
          # contained binding name so its global slot precedes the RHS's
          # globals (mirrors hoist_pattern_globals).
          hoistPatternGlobals(c, decl.declPattern)
    elif stmt.kind == FunctionDecl and stmt.fnNameLen > 0:
      discard internGlobal(c, c.slice(stmt.fnNameStart, stmt.fnNameStart + stmt.fnNameLen))
    elif stmt.kind == ClassDecl and stmt.classNameLen > 0:
      # A script-top ClassDecl RESERVES a global slot for its name in the
      # hoist pass (compiler.zc hoist_program_decls ~8872-8878), even though
      # the class itself binds LEXICALLY (a register, via the Mov in the
      # ClassDecl compile arm — never DefineGlobal'd). The reservation is
      # what makes the ctor body's first real global land one slot LATER
      # (`class C { y = x }` → C reserves g108, so `x` reads g109). A
      # ClassExpr reserves nothing (compiler.zc ~8879) — matches the
      # anonymous-class oracle where the field-init global starts at g108.
      discard internGlobal(c, c.slice(stmt.classNameStart, stmt.classNameStart + stmt.classNameLen))

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
    # Seed the shared class-id counter to USER_CLASS_ID_BASE-1 (24): the
    # first compileClassValue pre-increments to 25, matching the oracle.
    globals: GlobalTable(classIdCounter: USER_CLASS_ID_BASE - 1),
    scopeStack: @[0'u32],
    curScopeId: 0,
    nextScopeId: 1,
    enclosingClassId: -1,            # not inside any class at program top (7d)
    clsStack: @[],
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
    # Program top has no `this` register (c.thisReg == -1); the VM seeds
    # nothing. Set explicitly so the field isn't the int default 0 (= reg 0).
    thisReg: c.thisReg,
  )
  if f.registerCount == 0: f.registerCount = 1
  if f.fixedRegs > f.registerCount: f.fixedRegs = f.registerCount
  # Attach the shared global-name side table so disasm can print `; <name>`.
  for i in 0 ..< c.globals.names.len:
    f.globalNames.add(GlobalName(slot: c.globals.slots[i], name: c.globals.names[i]))
  return f
