# Phase 3 (Compiler) — Overnight Report · 2026-07-07

**TL;DR:** The Nim bytecode compiler went from *scaffold* to handling the **core of the
language** overnight — expressions, all control flow, functions, **closures**, calls,
member access, `this`/`arguments`, tail calls — every implemented feature **byte-identical**
to `build/zjs disasm`. 11 slices landed + 2 fixes, all independently verified before commit.
All on `nim-phase2`; `main` untouched. Remaining: arrows/complex-params, switch/try, and
generators/async/classes.

## What landed (each byte-identical vs the `zjs disasm` oracle)

| Slice | Feature | Commit |
|---|---|---|
| 1 | Scaffold: 145-op enum, Inst/Function, disasm renderer, register model | `b1976f7` |
| 2 | Expressions: const pool, arithmetic, imm-fusion, unary | `d531f21` |
| 2b | Ternary `?:`, logical `&&`/`\|\|`/`??`, compound `+=`, `typeof`/`void`/`delete` | `dc3c015` |
| 3a | **Register discipline** + lexical locals + blocks (the foundation) | `84f2335` |
| 3b | `if`/`else` + fused compare-and-branch | `fcfdab9` |
| 3c | Loops (`while`/`do`/`for`) + rotation + `break`/`continue` | `aede5d2` |
| 4a | Non-capturing functions (decl/expr, params, MakeClosure, entry-holes) | `d0594dd` |
| 4b | **Closures / captured locals / env objects** (the hardest slice) | `f0ff95a` |
| 4c | `this` / `arguments` / `new.target` + **tail calls** | `1b8be13` |
| 5a | Member/element access + object/array literals + **IC table** | `4404208` |
| 5b | Function/method/`new` calls + `InvokeGlobal` fusion | `635b590` |
| — | Fix: global-target assignment intern order (`a = b`) | `62b92d5` |

~13 commits this run; ~114 total ahead of `main`. **Tests: 200 tcompiler / 492 tparser /
55 tlexer, all green** (parser + lexer untouched-and-verified).

## Method (unchanged, and it held)
Differential oracle: `build/zjs disasm f.js` vs `build/nim/nim-disasm f.js`, byte-for-byte.
Each slice was built by a subagent against a precise spec, then **I independently
re-verified** every target + adversarial cases + the full prior-slice regression battery +
a corpus sweep, *before* committing. Nothing was committed on a subagent's word alone.
Anything not yet implemented **cleanly emits nothing** (`hadError` → nim-missing) rather than
wrong bytecode — so a feature gap can never masquerade as a correct match.

## Corpus state (5729-file language sweep)
- `both_identical = 166`, `text_diff = 198`, `nim_missing = 4421`, `zjs_missing = 5`.
- **`nim_missing` (4421)** = files using features not yet compiled (arrows, switch/try,
  generators, classes, destructuring, spread). Correct behaviour — clean bail, not a bug.
- **`text_diff` (198)** ≈ entirely the **built-in-global-shadow** class: user code references a
  built-in global (`Symbol`, `Object`, `TypeError`, the test-harness `assert`…), the oracle
  uses that built-in's real slot (`g16`…`g57`) while Nim's stub assigns `g108+`. **Only the
  slot number (and its field padding) differs — the op structure is identical.** This is the
  documented consequence of the `USER_GLOBAL_BASE = 108` decision (option 1) and **resolves
  automatically when built-ins land** (Phase 5-6). It grows with coverage precisely because
  more files now fully compile. A handful are two other known-deferred classes: escaped
  identifier/property names (`.throw` vs `.throw` — needs `\u` decode in the IC name)
  and read-side TDZ (`ThrowIfHole`).
- **`zjs_missing` (5)** = **parser** early-error gaps (e.g. `let f; var f;` duplicate-decl),
  pre-existing and unrelated to the compiler. Not compiler over-acceptance.
- **Zero compiler-op structural diffs** were found in any per-slice adversarial verification
  (closures, calls, members, control flow all confirmed clean).

## Decisions I made (no blockers hit)
- **Sequenced dependency-first.** Discovered mid-run that the IC table + member access is the
  real foundation (closures/`this.x`/calls all need `LoadProp`/`StoreProp`), so I did 5a
  before the closure/this slices. Also split slice 3 into 3a/3b/3c and slice 4 into 4a-4c.
- **Fixed a pre-existing bug** the new tests surfaced: `a = b` interned the target global
  before the RHS (wrong slot order vs the oracle's GetValue-then-PutValue). Fixed + verified.
- **Bailed rather than guessed** on the genuinely hard closure tail: mixed own-capture +
  transitive grandparent refs, and multi-hop env chains (depth > 1). Single/deep-passthrough
  closures are byte-identical; the multi-hop cases emit nothing (tracked), never wrong bytecode.
- A bonus **tail-call rewrite** (`return f()` → `TailInvoke`) was required for byte-identity
  on a `this`-method target, so it's in — with correct tail-vs-non-tail discrimination.

## What's left in Phase 3
1. **Slice 4d** — arrow functions (lexical `this` snapshot) + default/rest/destructuring params.
2. **Slice 6** — `switch`, `try`/`catch`/`finally` (+ unwind regions; this also switches the
   tail-call suppression on inside try bodies), labeled statements + labeled break/continue
   (needs a small parser change — the parser currently discards labels).
3. **Slice 7** — generators/async bodies (`GeneratorStart`/`Yield`/`Await`) and classes
   (ctor synthesis mirroring the parser, `DefineMethod`/`SetParentCtor`/`SuperCall`).
4. **Cleanups** — read-side TDZ (`ThrowIfHole`), escaped-property-name IC decoding, `++`/`--`
   and logical-assignment (`&&=`), the built-in-shadow class (deferred to built-ins landing).

## My recommendation
Keep going the same way — 4d, 6, 7 as separate verified slices — to finish Phase 3, then
merge `nim-phase2 → nim` and open **Phase 4 (interpreter/VM)**, where the oracle shifts from
`disasm` text to *execution results*. Slices 6 and 7 are the largest remaining; 7 (classes +
generators) is where I'd want you reachable in case a structural call comes up, but nothing so
far has needed a product decision — the port has been faithful-to-`compiler.zc` throughout.

Full technical detail is in memory (`project_nim_phase3_compiler.md`) and each commit message.
