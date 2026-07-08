# ZJS Nim Phase 4 — Interpreter / VM Implementation Plan

> **For agentic workers:** Port `src/interpreter.zc` (the bytecode VM) to Nim. The oracle
> shifts from disasm TEXT to **execution results** — `nim-eval '<src>'` output must match
> `build/zjs eval '<src>'`. All work on `nim-phase4` (→ `nim`); **never touch `main`** (Zapp's
> working Zen-c engine). Only add `nim/`, `docs/`, additive `nim-*` Makefile targets.

**Goal:** a Nim bytecode interpreter that executes the bytecode the Phase-3 compiler emits and
produces the **same completion-value output as `zjs eval`**, byte-for-byte, across the language.

**Architecture:** register-based dispatch loop over the `Inst` array (from `bytecode.nim`). A
call stack of frames (register file + ip + function). Globals in a slot array. Value ops
(arithmetic/comparison/coercion) grow incrementally alongside the ops that need them. No GC yet
(arena/leak is fine for the differential; real GC = Phase 5).

**Tech Stack:** Nim (`--mm:arc -d:release`), reusing `nim/src/zjs/{value,bytecode,compiler,parser,lexer}.nim`.

---

## Method / oracle
- `build/zjs eval '<src>'` prints the program's completion value (last-expression value in r0).
  `nim-eval` does lex → parse → `compileProgram` → **execute** → print the completion value the
  same way. Differential: `diff <(build/zjs eval "$s") <(build/nim/nim-eval "$s")`.
- New harness `nim/tests/measure_evalparity.sh` (mirror measure_diffdisasm.sh) over test262
  fragments / a curated battery.
- **Bails become "can't-run"**: if the VM hits an unimplemented op it errors cleanly (empty
  stdout / nonzero exit) → classified as nim-missing, NEVER a wrong result. Same discipline as
  the compiler — a wrong execution result is worse than an honest bail.

## The Phase-4 vs Phase-5 boundary (design)
- **Phase 4 (VM):** the dispatch loop, frames/call stack, register file, globals array, control
  flow, and the value ops for **primitives** (number/bool/null/undefined/string) — arithmetic,
  comparison, the `typeof`/coercion needed by the ops. Enough to run programs that don't need the
  heap object model or built-ins.
- **Phase 5 (runtime core):** the real object model (property get/set, hidden classes), GC +
  `Rooted[T]`, Realm, and the built-in intrinsics. `NewObject`/`LoadProp`/method calls/`new`
  need this — the VM will bail on them until Phase 5, executing primitive/control-flow programs
  first. (A minimal object model may get pulled forward if the differential needs it early.)

## Slices (differential-gated, like Phase 2/3)
1. **Minimal VM (THIS SLICE):** `Frame` (regs seq, ip, function), the dispatch loop, and handlers
   for: `LoadUndefined/LoadNull/LoadTrue/LoadFalse/LoadInt/LoadConst/Mov/Return/Halt`,
   `DefineGlobal/LoadGlobal/StoreGlobal` (a globals slot array), integer/double **arithmetic**
   (`Add/Sub/Mul/Div/Mod/Neg` + `AddImm/SubImm`), **comparison** (`CmpEq/Ne/StrictEq/StrictNe/
   Lt/Le/Gt/Ge` + `*Imm`), bitwise/shift, `LogicalNot`/`BitNot`, and control flow (`Jmp`,
   `JmpIfTrue/False`, the fused `JmpIf(Not)*` compare-and-branch carriers, `JmpIfNullish`).
   Completion-value **printing** for number/bool/null/undefined/string (match `zjs eval`'s
   formatting exactly — reuse the `%g`-matching float format from the parser/disasm). `nim-eval`
   CLI + Makefile target + `measure_evalparity.sh`.
   Targets: `1+2` → 3; `40+2`; `let x=40; x+2`; `5>3?"a":"b"`; `2*3+4`; `10%3`; `1<2`;
   `var a=1; a=a+1; a`; `true && false`; `1?2:3`; `-5`; `(1+2)*3`; `"x"` (string completion).
2. **Functions / calls:** push/pop frames, `Invoke/MethodInvoke/InvokeGlobal/NewInvoke` (VM
   side), `MakeClosure`, params/returns, recursion (`function fib(n){...} fib(10)`), tail calls.
3. **Strings & primitive coercion:** string concat (`"a"+"b"`), `ToNumber`/`ToString`/
   `ToPrimitive`, `typeof`, template literals — the primitive coercion ladder.
4. **Object model (Phase-5 forward-pull as needed):** `NewObject/NewArray/LoadProp/StoreProp/
   LoadElem/StoreElem` + a minimal object rep + the IC execution. Then methods/`this`/`new`.
5. **Control-flow completeness in execution:** try/throw/catch/finally unwinding, generators
   (suspend/resume), async/microtasks — the runtime protocols.
6. **Then Phase 5 proper:** GC + `Rooted[T]`, hidden classes, Realm, built-in intrinsics.

## Validation
- Per slice: unit tests (execute a Function, assert result) + differential vs `zjs eval` on a
  battery + a corpus sample. `text_diff`/`wrong-result` must be 0; unimplemented → nim-missing.
- Phase done enough to merge when the primitive+function+object+string execution matches `zjs
  eval` across a broad corpus sample (built-ins-dependent programs remain nim-missing until Phase 5).
