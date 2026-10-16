# zjs Phase 3.0a — Bytecode + Interpreter MVP

> First slice of Phase 3. Connects every layer end-to-end:
> lexer → parser → AST → **bytecode compiler → interpreter** → NaN-box value.
>
> When this lands, `zjs eval "1 + 2 * 3"` actually evaluates and returns
> the value `7`, not a Phase-0 stub.

## Scope

In scope:
- Bytecode design: uniform 4-byte instructions (`{op:u8, a:u8, b:u8, c:u8}`); operands re-interpreted per opcode
- Constants pool on each `Function`
- Globals (top-level `var`/`let`/`const`) — stored in a per-context table; bytecode references globals by slot index (resolved at compile time)
- Number arithmetic on int32 and double, with overflow-to-double promotion
- Comparison operators with type-correct semantics
- Unary `! ~ + -`
- Logical `&& || ??` via branching (no short-circuit opcodes)
- Control flow: `if/else`, `while`, `for` (C-style), block scoping
- The result of a program is the last evaluated expression-statement value
- `zjs eval <source>` actually evaluates
- `zjs disas <source>` prints the compiled bytecode
- Pure-C smoke tests for `zjs_eval` of numeric programs
- Zen-c interpreter test runner

Out of scope (Phase 3.0b / 3.0c / 3.1):
- **Functions** — declarations, calls, return — Phase 3.0b
- **test262** — wired up in Phase 3.0c, after the interpreter runs
- **Strings**, **arrays**, **objects** — Phase 3.1 (need heap + GC)
- **Closures / nested functions / `this`** — later
- **Real GC** — no heap objects yet, so no GC needed
- **Inline caches** — no property access yet
- **Computed-goto dispatch** — Hermes-style dispatch is the *direction*, but Zen-c's `match` is what we use for v0 readability. The interpreter is structured so a future swap to computed-goto inside a `raw{}` block is a clean refactor.

## Architecture

```
                          ZjsContext
                           ┌──────────────────────┐
                           │ globals: GlobalEntry[]│
                           └──────────────────────┘

zjs_eval(ctx, source)
    │
    ▼
  lex tokens ─► parse AST ─► compile Function ─► interpret(ctx, function)
                                                          │
                                                          ▼
                                                    ZjsValue
```

Compiler holds a reference to the context so it can intern global names
into shared slot indices. The function's bytecode encodes slot indices
directly; the runtime does a constant-time array lookup.

## Bytecode (uniform 4-byte instructions)

```
struct Inst { op: u8; a: u8; b: u8; c: u8; }
```

Operand layout per opcode (just the load-bearing ones — full list in `bytecode.zc`):

| Opcode | a | b | c |
|---|---|---|---|
| `LoadConst` | dst reg | const_idx low | const_idx high |
| `LoadInt` (small) | dst reg | imm low (i16) | imm high (i16) |
| `LoadUndefined` | dst reg | — | — |
| `LoadNull` / `LoadTrue` / `LoadFalse` | dst reg | — | — |
| `Mov` | dst | src | — |
| `Add` / `Sub` / `Mul` / `Div` / `Mod` / `Pow` | dst | lhs | rhs |
| `Eq` / `Ne` / `StrictEq` / `StrictNe` / `Lt` / `Le` / `Gt` / `Ge` | dst | lhs | rhs |
| `BitAnd` / `BitOr` / `BitXor` / `Shl` / `Shr` / `UShr` | dst | lhs | rhs |
| `Neg` / `BitNot` / `LogicalNot` | dst | src | — |
| `Jmp` | — | offset low (i16) | offset high (i16) |
| `JmpIfTrue` / `JmpIfFalse` | src | offset low | offset high |
| `DefineGlobal` / `StoreGlobal` | src | slot low (u16) | slot high (u16) |
| `LoadGlobal` | dst | slot low | slot high |
| `Return` | src | — | — |

`Return src` is the universal "exit the interpret loop with regs[src] as the value." Top-level programs emit `Return last_expr_reg` at the end.

## Register allocation

Per-function high-water-mark allocator. Locals (function parameters in Phase 3.0b; nothing yet in 3.0a since we have no functions) get fixed registers at scope entry. Temporaries are allocated and freed in LIFO order as expressions evaluate.

For 3.0a, every program is "the main function" with no parameters. All declarations go to globals. Register file is for expression temporaries only — typically small (<16 registers per program).

## Number arithmetic

`zjs_add(a, b)`, `zjs_sub`, etc. — handle int32 + int32 fast path with overflow detection (promote to double if int32 + int32 overflows), and double fallback for any operand that isn't int32. If either operand isn't a number, result is `NaN` (a double).

`zjs_to_bool` — ECMA-262 ToBoolean: false for `false`, `null`, `undefined`, `0`, `NaN`, empty string (when we have strings); true otherwise.

## Verification

`make test` continues to pass everything from Phases 0–2.5, plus new
verification:

- `zjs eval "42"` → prints `42`
- `zjs eval "1 + 2 * 3"` → `7`
- `zjs eval "let x = 10; let y = 20; x + y"` → `30`
- `zjs eval "if (1) 42; else 0"` → `42`
- `zjs eval "let s = 0; let i = 1; while (i <= 10) { s = s + i; i = i + 1; } s"` → `55`
- `zjs eval "let s = 0; for (let i = 1; i <= 10; i = i + 1) s = s + i; s"` → `55`

Plus the C smoke test exercises `zjs_eval` and validates the returned `ZjsValue` round-trips through the existing predicates/unboxers.

## Files

- `src/bytecode.zc` — Op enum, Inst struct, Function struct, encode/decode helpers
- `src/compiler.zc` — AST walker emitting bytecode
- `src/interpreter.zc` — dispatch loop + per-opcode handlers
- `src/context.zc` — extended with globals table + function ownership
- `src/value.zc` — arithmetic + ToBoolean helpers
- `src/eval.zc` — wire lex → parse → compile → interpret
- `tools/zjs.zc` — `eval` now real; new `disas` subcommand
- `tests/embed_smoke.c` — eval tests
- `tests/interpreter_test.zc` — Zen-c eval-result assertions
- `Makefile` — interpreter_test target

## What's next

- **Phase 3.0b** — Functions: declarations, calls, return, locals, recursion. Adds `Call`, `Return` (as cross-function), function values via NaN-box cell pointers.
- **Phase 3.0c** — test262 wiring. Even at 1% pass rate it becomes the spec dashboard.
- **Phase 3.1** — Strings + arrays + objects. Requires heap + GC. Probably the biggest single phase yet.
