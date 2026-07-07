# ZJS Nim Phase 3 — Compiler (AST → bytecode) Implementation Plan

> **For agentic workers:** Port `src/compiler.zc` + `src/bytecode.zc` to Nim, producing
> **byte-identical `zjs disasm` output**. Differential-oracle method (same as the parser).
> All work stays on `nim-phase2` (→ `nim`); **never touch `main`** — it stays the working
> Zen-c engine Zapp pulls today. Only add `nim/`, `docs/`, and additive `nim-*` Makefile targets.

**Goal:** a Nim compiler whose `nim-disasm` output matches `build/zjs disasm` byte-for-byte
across the test262 corpus.

**Architecture:** register-based tree-walking compiler. `compileExpr(node) -> reg` and
`compileStmt(node)` mirror Zen-c `compile_expr` / `compile_stmt`. High-water-mark register
allocator. Constant pool holds numbers / strings / nested `Function`s. No execution, no GC —
the compiler only *emits* bytecode.

**Tech Stack:** Nim (`--mm:arc -d:release`), reusing `nim/src/zjs/{ast,parser,lexer,token,value}.nim`.

---

## Key decisions (approved 2026-07-06)

- **Oracle:** `build/zjs disasm f.js` vs `build/nim/nim-disasm f.js`. New `make nim-disasm`
  target + `make nim-diffdisasm` harness (mirror `measure_errparity.sh`).
- **Global slots (`g108`):** the disasm shows user globals starting at slot 108 (built-ins
  occupy 0–107). Nim has no built-ins yet, so **stub the user-global base to a single named
  constant `USER_GLOBAL_BASE = 108`** in the compiler's global-interning table. Revisit when
  built-ins land in Phase 5-6 (base becomes a computed count, one place). This is the ONLY
  runtime-coupled number; registers/constants/ops/closures are all deterministic from the AST.
- **What "byte-identical" means:** the *disasm text*, not the binary `.zbc`. AOT
  serialization (`aot.zc`) is a later, separate slice.

## Bytecode facts (from `src/bytecode.zc`)

- **`Inst { op: Op; a,b,c: u8 }`** — 4 bytes. `bc_u16 = b | (c<<8)`; `bc_i16` = sign-extended `bc_u16`.
- **Op enum — 128 ops, THIS ORDER** (ordinals matter for Phase 4; disasm uses names):
  ```
  Halt LoadConst LoadInt LoadUndefined LoadHole ThrowIfHole LoadNull LoadTrue LoadFalse Mov
  DefineGlobal LoadGlobal StoreGlobal LoadGlobalOrUndefined WithEnter WithLeave WithLookup
  Add AddImm SubImm CmpLtImm CmpLeImm CmpGtImm CmpGeImm BitAnd Shl CmpEq CmpLt Neg
  Jmp JmpIfTrue JmpIfFalse JmpIfNotNullish JmpIfNullish JmpIfNotLt JmpIfNotLe JmpIfNotGt
  JmpIfNotGe JmpIfNotLtImm JmpIfNotLeImm JmpIfNotGtImm JmpIfNotGeImm JmpIfNotEq JmpIfNotNe
  JmpIfNotStrictEq JmpIfNotStrictNe Return Invoke TailInvoke LoadProp StoreProp MathSqrt
  MathAbs MathFloor MathCeil IterPrepare ArrayLength DeleteElem BuildArguments BuildRestArgs
  ImportBind ExportBind DynamicImport ImportMeta Await Yield GeneratorStart TemplateObject
  ArrayPush ArraySpread ObjectSpread ArrayRestFrom AssertCoercible IterGet IterGetAsync
  IterStep IterRestCollect IterClose IterNextRaw SpreadInvoke SpreadMethodInvoke
  SpreadNewInvoke MethodInvoke TailMethodInvoke DefineGetter DefineSetter DefineMethodGetter
  DefineMethodSetter MakeClosure LoadEnv LoadCallee NewRegex NewRegexR NewObject NewArray
  LoadElem StoreElem Throw EnterTry LeaveTry In Instanceof LoadThis LoadNewTarget NewInvoke
  Typeof SetProto SuperCall DefineMethod DefineMethodComputed SetParentCtor SetFunctionName
  InitObjData SpreadSuperCall JmpIfLt JmpIfLe JmpIfGt JmpIfGe JmpIfLtImm JmpIfLeImm
  JmpIfGtImm JmpIfGeImm InvokeGlobal PrivateCheck ThrowTypeError StoreGlobalStrict
  IterCloseQuiet JmpIfNotGenReturn
  ```
  NOTE: `Add` then `AddImm`/`SubImm` then `BitAnd Shl` then `CmpEq CmpLt Neg` — the enum is a
  CURATED subset (not every arithmetic/cmp op has a distinct opcode; e.g. only `Add` among
  Add/Sub/Mul — Sub etc. reuse via general paths). Copy the order EXACTLY from bytecode.zc.
- **`Function`** (the compile unit): `code[]`, `code_len`, `constants[]`, `const_count`,
  `register_count`, `fixed_regs`, `param_count`, `this_reg (i32, -1=unused)`,
  `expected_arg_count`, `is_async/is_generator/is_arrow/is_class_constructor`, `ics[]/ic_count`.

## Disasm text format (from `tools/zjs.zc:726` `disasm_function`) — MATCH EXACTLY

Header (note the TWO spaces after `%s`, and trailing flags only when set):
```
\n=== <label>  code_len=<n> regs=<n> fixed=<n> params=<n> consts=<n> ics=<n>[ async][ generator][ arrow][ class-ctor] ===\n
```
Per instruction: `fprintf("%5zu  %-20s", index, opname)` then op-specific operands:
- global ops (`DefineGlobal/LoadGlobal/StoreGlobal/LoadGlobalOrUndefined/StoreGlobalStrict`):
  `r%-3u g%-4u ; %.*s`  (a, slot, global name)
- `LoadConst`: `r%-3u const#%u` + ` = %d` | ` = %g` | ` = "%.24s%s"` (…) | ` = <function>`
- `LoadInt`: `r%-3u = %d` (i16)
- `Jmp`: `-> %zd` (target = i+1+off)
- `JmpIfTrue/JmpIfFalse/JmpIfNullish/JmpIfNotNullish`: `r%-3u -> %zd`
- fused branch (2-slot, consumes carrier J+1): `r%-3u r%-3u -> %lld  [carrier@%zu]` (or `r%-3u imm=%-4d -> …` for *Imm); `i += 1`
- `InvokeGlobal` (2-slot): `r%-3u <- g%u(base=r%u argc=%u)  [carrier@%zu] ; %.*s`; `i += 1`
- `Invoke/NewInvoke`: `r%-3u <- base=r%u argc=%u`
- `MethodInvoke`: `r%-3u <- base=r%u recv=r%u argc=%u` (recv = b+1)
- `TailInvoke/TailMethodInvoke`: `base=r%u argc=%u`
- `LoadProp`: `r%-3u <- r%u.%s  ic#%u` (name from `ics[c].name`)
- `StoreProp`: `r%u.%s <- r%-3u  ic#%u` (name from `ics[b].name`; args a, name, c, b)
- `Mov`: `r%-3u <- r%u`
- `AddImm/SubImm/CmpLtImm/CmpLeImm/CmpGtImm/CmpGeImm`: `r%-3u <- r%u, imm=%d` (c as i8)
- `Return`: `r%u`
- default: `a=%-3u b=%-3u c=%-3u | u16=%u i16=%d`
Then `'\n'`. After the code loop, **recurse into const-pool functions** in order:
label `<label>/const#%u`, top-level label = `<program>`.

## New Nim files
- `nim/src/zjs/bytecode.nim` — `Op` enum (128, exact order), `Inst`, `Function` (ref object),
  `instBcU16/instBcI16`, encode helpers.
- `nim/src/zjs/compiler.nim` — `Compiler` object (code seq, constants seq, next_reg/max_reg/
  fixed_regs, locals, globals table w/ `USER_GLOBAL_BASE`), `compileExpr`/`compileStmt`,
  `compileProgram(ast) -> Function`.
- `nim/tools/nim_disasm.nim` — the dumper (exact format above); label recursion.
- `nim/tests/tcompiler.nim` — unit tests (assert on disasm text).
- Makefile: `nim-disasm` target + `nim-diffdisasm` harness script `nim/tests/measure_diffdisasm.sh`.

---

## Slice 1 — scaffold + trivial program (THIS SLICE)

**Target:** byte-identical disasm for `var x = 1;`, `1;`, `var x=1; var y=2;`, `true;`.
Reference outputs (from `build/zjs disasm`):
```
=== <program>  code_len=4 regs=3 fixed=1 params=0 consts=0 ics=0 ===
    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0
    1  LoadInt             r1   = 1
    2  DefineGlobal        r1   g108  ; x
    3  Return              r0
```
Semantics to replicate (verify against `compiler.zc`):
- Program prologue: `LoadUndefined r0` (r0 = completion slot, part of `fixed_regs=1`).
- Expression statement: compile expr into a temp, then `Mov r0 <- temp` (completion value).
- `var x = <e>;`: compile `<e>` into temp, `DefineGlobal temp, slot`; slot from the global
  table starting at `USER_GLOBAL_BASE=108`, incrementing per distinct declared global name.
- Program epilogue: `Return r0`.
- **`register_count=3` baseline** for trivial programs — investigate how `compiler.zc`
  finalizes `register_count` (it is NOT simply max_reg+1; there's a reservation). Match it.
- Temp watermark **resets between statements** (both `var` stmts reuse `r1`).
- `LoadInt` only for i16-range ints; `LoadTrue/LoadFalse/LoadNull/LoadUndefined` for literals
  (these have NO special disasm case → print via the `default` `a= b= c= | u16= i16=` branch).

Steps: (1) `bytecode.nim` Op/Inst/Function. (2) `nim_disasm.nim` matching the format on a
hand-built Function (test the formatter first). (3) `compiler.nim` register alloc + global
table + `compileProgram` handling ExpressionStmt / VarDecl(var) / literals / IdentExpr.
(4) `nim-disasm` CLI + Makefile target. (5) Differential on the 4 targets → byte-identical.
(6) `nim-diffdisasm` harness over a small corpus sample; commit.

## Later slices (sketch — detail per-slice at start, like Phase 2)
2. **Expressions** — LoadConst (number/string const pool), Add & the arithmetic subset,
   AddImm/SubImm fusion, unary Neg/Not, comparisons, the temp watermark discipline.
3. **Statements** — let/const (lexical → registers in script scope), blocks, if (Jmp/JmpIf*),
   while/for (+ loop rotation / bottom-test — see `project_loop_rotation`), the fused branches.
4. **Functions + closures** — `compile_function`, params→fixed regs, locals, `MakeClosure`,
   nested Function in the const pool + disasm recursion, `Return`, `this_reg`.
5. **Calls / members / literals** — Invoke/MethodInvoke/InvokeGlobal (+ carriers), LoadProp/
   StoreProp + IC slots (`ics`), NewObject/NewArray/object+array literals, computed.
6. **Control-flow completeness** — switch, try/catch/finally (EnterTry/LeaveTry + unwind
   regions — see `project_402_unwind_bugs`), labels/break/continue, `with`.
7. **Generators/async + classes** — GeneratorStart/Yield/Await, class ctor synthesis (mirror
   the parser's synthetic ctor), DefineMethod/SetParentCtor/SuperCall, private brands.

## Validation
- Per slice: unit tests (disasm text asserts) + differential on a targeted battery + a corpus
  sample via `nim-diffdisasm` (nim_only / zjs_only / text_diff must trend to 0).
- Phase done: full test262 corpus `disasm` diff clean → then Phase 4 (interpreter/VM).
