# ZJS-Nim Phase 2f (parser error reporting / corpus-diff convergence) Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** Make `build/zjs parse` and `build/nim/nim-parse` AGREE on the parse-error-vs-success decision (and the AST for accepted inputs) across the test262 corpus — the gate that lets Phase-2 (`nim-phase2`) merge into `nim`. Task #26.

**Gate / measurement:** `nim/tests/measure_errparity.sh` tallies four quadrants over a file list (stderr discarded ⇒ parse-error == empty stdout). Run e.g.:
```
find vendor/test262/test/language -name '*.js' | grep -v _FIXTURE | grep -vE '/(module-code|export|import)/' | awk 'NR%30==0' | nim/tests/measure_errparity.sh
```
It writes divergence file lists to `/tmp/{nim_only,zjs_only,ast_diff}.txt`. **Always `rm -f build/nim/nim-parse && make nim-parse` first.**

**Baseline (2026-06-21, 700-file language sample, after the for-head fix 66c95ce):**
`agree=653 (both_err=33 agree_ok=620) | ast_diff=6 nim_only(missing-err)=32 zjs_only(false-err)=9` → ~93% agreement. The remaining gap, by direction:
- **nim_only = 32 — MISSING early errors (the #26 core).** Nim accepts what Zen-c rejects.
- **zjs_only = 9 — Nim FALSE errors / missing features.** All `dynamic-import` (specific forms: 2nd options arg / `import.meta.x`) + `new.target` (specific position). Basic `import("x")`/`import.meta`/`new.target` already agree.
- **ast_diff = 6 — valid-input AST bugs.** 5 dynamic-import (namespace/attributes/assignment forms) + 1 `let/syntax`.

## Required infrastructure (Zen-c parity — Nim parser currently LACKS these)
The Nim `Parser` has `hadError/noIn/inGenerator/inAsync`. Zen-c's early errors additionally use:
1. **`functionDepth: uint32`** — incremented around EVERY function/method/getter/setter/arrow body AND `static {}` block; decremented after. (Zen-c `parser.zc:42`.) Drives: top-level `return` (`parse_return`: `function_depth==0` → error), `new.target` validity, `arguments`/`super` position checks.
2. **`strict: bool`** — set by a `"use strict"` directive prologue, by class bodies (always strict), and by module mode. Drives strict-reserved-word binding errors (`implements`/`interface`/`package`/`private`/`protected`/`public`/`static`/`yield`/`let`/`eval`/`arguments`), octal-escape string errors, `with`-in-strict, etc.
3. **`inStaticBlock`/`staticBlockDepth`** — `return`/`arguments`/`await` directly in a `static {}` block are errors (Zen-c `parse_return`, `parse_method_body_pair`).
4. **`isBindingIdentCtx(p, tok): bool`** — mirror of Zen-c `is_binding_ident_ctx` (`parser.zc:805`): rejects `yield` when `inGenerator`, `await` when `inAsync` or in a static block, and (when `strict`) the strict-reserved set. Call at EVERY BindingIdentifier site: var/let/const declarators, function/method params, catch param, class name, for-binding, arrow params, import locals. (Note: the existing permissive parse of these sites must be tightened, NOT just augmented.)

## Slice map (each gated by re-running measure_errparity over the matching test262 category; watch BOTH directions — a fix must not introduce a `zjs_only` false-error)

- **2f-1 — functionDepth infra + top-level `return`.** Add `functionDepth`, bump it at every function/method/arrow/accessor body + static block. `parseReturn` errors when `functionDepth==0` (and in a static block at its own depth). Category: `statements/return`, `global-code`. Verified divergences today: `return;`, `return 1;` (zjs error, nim accepts); `function f(){ return; }` already agrees.
- **2f-2 — context-reserved bindings (`yield`/`await`).** Add `isBindingIdentCtx` + wire it into every binding site. Category: `statements/generators`, `expressions/async-generator`, `keywords`. Divergences: `function* g(){ var yield; }`, `async function f(){ var await; }`, `function* g(){ let yield = 1; }`.
- **2f-3 — strict mode + strict-reserved words.** LARGE — decompose into 3 sub-slices.
  - **Infra (shared):** add `strict: bool` to `Parser`. Port Zen-c `tokens_have_use_strict_prologue(p, from)` (parser.zc:754) — a TOKEN-level scan from token index `from` over leading StringLit-then-(`;`|StringLit) directives, true iff one is exactly `"use strict"` (12 bytes, UNescaped — escaped forms are NOT directives). Set `p.strict`: (1) program start `from=0` (parser.zc:212); (2) at EVERY function-body entry — save `p.strict`, set `p.strict = p.strict or tokensHaveUseStrictPrologue(p, <first-body-token-index>)` BEFORE parseBlock, restore after (this is why a token-level pre-scan is needed: strictness must be known before parsing the body; the body's directive is its own first statement); (3) class bodies always strict (`p.strict = true` around parseClassBody — already implicitly strict per 2e but not flagged). Note: `inGenerator`/`inAsync`/`functionDepth` save-restore already bracket these body sites — fold `strict` in alongside.
  - **2f-3a — strict binding errors (reuse the 2f-2 leaf-site wiring):** extend `checkBindingReserved` (or a sibling) for the strict cases — `yield` bound in strict (is_binding_ident_ctx:813); `eval`/`arguments` bound in strict (§13.1.1, Zen-c name_is_arguments_or_eval ~1739, check at var-decl/param/catch/fn-name BINDING sites only, NOT references); future-reserved bindings `implements/interface/package/private/protected/public/static` in strict (is_binding_ident_tok:849-857 — these are plain Identifier tokens, compare source spelling). Plus `with` statement in strict (parser.zc:1272 → error). Categories: `keywords`, `reserved-words`, `identifiers`, `statements/with`, `directive-prologue`.
  - **2f-3b — strict param / directive interactions:** duplicate params in strict (parser.zc:1795); non-simple-param-list + a "use strict" directive in the body (parser.zc:1864, `body_has_use_strict_directive`); legacy-octal / octal-escape string + directive. Categories: `function-code`, `statements/generators` (use-strict-with-non-simple-param), `literals/string`.
  - **2f-3c — escaped-keyword source spelling:** an Identifier token whose DECODED spelling is a reserved word is illegal where the keyword is (Zen-c is_binding_ident_tok:824, `ident_source_matches` handles `\uXXXX`). E.g. `yield` as a binding in a generator/strict. Needs a source-spelling matcher (plain + `\uXXXX` decode). Categories: `*-escaped.js` tests across identifiers/keywords/generators.
- **2f-4 — ASI / no-separator early errors.** Field terminator (`class C { x=1 y=2 }`), and other ASI-required-but-absent sites. Needs `hasNewlineBetween(p, posA, posB)` (newline-in-source-range). Category: `asi`, `statements/class/elements`. Today: `class C { x = 1 y = 2; }` (zjs error, nim accepts) — the field branch in `parseMethodBodyPair` currently consumes only an optional `;`.
- **2f-5 — lexer-level early errors.** Invalid string escapes (`'\'` incomplete; `"\x"` already agrees so check which escapes), hashbang `#!` only at offset 0. Category: `literals/string`, `comments/hashbang`, `line-terminators`. These are LEXER changes (the dump harness surfaces them as parse errors).
- **2f-6 — class / labeled / duplicate-binding early errors.** Duplicate labels, duplicate lexical bindings, class-specific early errors (`#constructor`, dup constructor, `super` in non-derived ctor, field named `constructor`). Category: `statements/labeled`, `statements/class`, `expressions/class`. (Some class checks were deliberately deferred from 2e — see [[project_nim_classes_modules]].)
- **2f-7 — residual feature gaps (the `zjs_only` + dynamic-import `ast_diff`).** `import(spec, options)` 2nd-arg form, `import.meta.x` member chains, `new.target` in the specific failing position, namespace/attributes dynamic-import forms. Category: `expressions/dynamic-import`, `expressions/new.target`. These are feature completions, not error reporting; bundle last.

## Method per slice
1. `rm -f build/nim/nim-parse && make nim-parse`; run measure_errparity over the FULL matching test262 category (not just the sample) to get the slice's divergence list into `/tmp/nim_only.txt` etc.
2. Read the Zen-c check (cited above) for that family; port it to the Nim parser at the same logical site.
3. TDD: add tparser unit tests (positive: still accepted; negative: now rejected via `p.hadError`).
4. Re-run measure_errparity over the category — the family's divergences go to zero, and `zjs_only` does NOT increase (no new false-errors). Also re-run the full VALID-input differential batteries from prior slices (no AST regressions).
5. Commit. Independent controller verification: adversarial both-directions sweep on a clean rebuild.

## Done criteria
measure_errparity over a broad test262 language sample shows `nim_only==0` and `zjs_only==0` and `ast_diff==0` (or a documented, justified residual). Then the full corpus diff gates the `nim-phase2 → nim` merge. After that: Phase 3 (compiler). Modules (import/export statements) remain separately blocked on exposing module-mode in the oracle CLI (a `parse --module` flag on `tools/zjs.zc` + `nim_parse.nim`) — owner decision pending.
