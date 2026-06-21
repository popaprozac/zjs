# ZJS-Nim Phase 2a (Lexer) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure-Nim lexer that tokenizes JS source into the same token stream as the Zen-c lexer — validated **byte-for-byte against `zjs lex`** (the differential oracle).

**Architecture:** Oracle-first. Build the differential harness and a Nim `nim-lex` token-dump tool BEFORE the lexer is complete, so every increment of lexer logic is immediately checked against the running Zen-c engine. The lexer lives in the idiomatic register (clean Nim), but tokens are a flat slice type (`kind, start, length`) — no per-token allocation — matching Zen-c for both fidelity and perf. Port the logic of `src/lexer.zc`; the differential harness over a real test262 corpus is the acceptance gate.

**Tech Stack:** Nim 2.2.10, the existing `zjs lex` CLI (Zen-c reference), `std/unittest`, a shell diff harness.

**Branch:** `nim-phase2` (off `nim`). This is the first increment of Phase 2 (lexer); Phase 2 also includes AST + parser (later increments 2b–2d), and merges to `nim` only when the whole phase is done.

**Reference:** Design `docs/superpowers/specs/2026-06-20-zjs-nim-migration-design.md`. Zen-c sources to port from: `src/token.zc` (the `TokenKind` enum + `Token` struct), `src/lexer.zc` (1018 LOC of tokenization rules — THE spec for behavior).

---

## The differential oracle (verified)

`build/zjs lex '<source>'` (Zen-c) prints one line per token:
```
%-12s  start=%-4u  length=%-4u  text="%.*s"\n
```
e.g. for `let x = 1 + 2;`:
```
KwLet         start=0     length=3     text="let"
Identifier    start=4     length=1     text="x"
Eq            start=6     length=1     text="="
NumberLit     start=8     length=1     text="1"
Plus          start=10    length=1     text="+"
NumberLit     start=12    length=1     text="2"
Semicolon     start=13    length=1     text=";"
Eof           start=14    length=0     text=""
```
The kind name is the **enum variant name**. So if the Nim `TokenKind` mirrors Zen-c's variant names exactly, Nim's `$kind` yields a matching string and the dumps diff cleanly.

**Acceptance:** `nim-lex '<src>'` output == `build/zjs lex '<src>'` output, byte-for-byte, over a corpus.

---

## File Structure

| File | Responsibility |
|---|---|
| `nim/src/zjs/token.nim` | `TokenKind` enum (mirrors `src/token.zc`) + `Token` slice type. Pure data. |
| `nim/src/zjs/lexer.nim` | The lexer: `Lexer` object + `nextToken` + `tokenizeAll`. Idiomatic Nim port of `src/lexer.zc`. |
| `nim/tools/nim_lex.nim` | CLI dump tool — reads source from argv, prints the `zjs lex` format. The Nim differential dumper. |
| `nim/tests/tlexer.nim` | `std/unittest` tests for the lexer (token kinds, slices, edge cases). |
| `nim/tests/diff_lex.sh` | Differential harness: run a JS corpus through `build/zjs lex` and `nim-lex`, diff. |
| `Makefile` | Targets: `nim-lex` (build the dumper), `nim-difflex` (run the harness). |

---

## Task 1: Token model (enum + slice type)

**Files:** Create `nim/src/zjs/token.nim`, Create `nim/tests/tlexer.nim`.

- [ ] **Step 1: Write the failing test** — `nim/tests/tlexer.nim`:

```nim
import std/unittest
import ../src/zjs/token

suite "token model":
  test "TokenKind variant names stringify to match Zen-c dump names":
    check $TokenKind.KwLet == "KwLet"
    check $TokenKind.Eq == "Eq"
    check $TokenKind.NumberLit == "NumberLit"
    check $TokenKind.Eof == "Eof"
    check $TokenKind.QuestionQuestionEq == "QuestionQuestionEq"

  test "Token is a flat slice (kind, start, length)":
    let t = Token(kind: TokenKind.Identifier, start: 4'u32, length: 1'u32)
    check t.kind == TokenKind.Identifier
    check t.start == 4'u32
    check t.length == 1'u32
```

- [ ] **Step 2: Run, verify it fails** — `nim c -r --mm:arc --hints:off nim/tests/tlexer.nim` → FAIL (module not found).

- [ ] **Step 3: Write `nim/src/zjs/token.nim`.** Mirror EVERY variant of the `TokenKind` enum in `src/token.zc` (read that file), in the SAME ORDER and with the SAME NAMES (so `$kind` matches the Zen-c dump). The enum begins:

```nim
## Token model — mirrors src/token.zc. A Token is a flat slice into the
## source (kind + start + length); no decoded value. Variant names MUST
## match src/token.zc exactly so `$kind` reproduces the `zjs lex` dump.

type
  TokenKind* = enum
    Eof, Invalid,
    Identifier, NumberLit, BigIntLit, StringLit, RegexLit, TemplateLit,
    KwVar, KwLet, KwConst,
    KwFunction, KwReturn,
    KwIf, KwElse,
    KwFor, KwWhile, KwDo,
    KwBreak, KwContinue,
    KwClass, KwExtends, KwSuper, KwNew, KwThis,
    KwTrue, KwFalse, KwNull, KwUndefined,
    KwTypeof, KwDelete, KwVoid, KwIn, KwOf, KwInstanceof,
    KwThrow, KwTry, KwCatch, KwFinally,
    KwSwitch, KwCase, KwDefault,
    KwWith,
    KwAsync, KwAwait, KwYield,
    KwImport, KwExport, KwFrom, KwAs,
    KwGet, KwSet,
    LParen, RParen, LBracket, RBracket, LBrace, RBrace,
    Comma, Semicolon, Colon, Dot, Ellipsis, Arrow, Tilde,
    Question, QuestionDot, QuestionQuestion, QuestionQuestionEq,
    Bang, BangEq, BangEqEq, Eq, EqEq, EqEqEq,
    Lt, LtEq, LtLt, LtLtEq, Gt, GtEq, GtGt, GtGtEq, GtGtGt, GtGtGtEq,
    Plus, PlusEq, PlusPlus, Minus, MinusEq, MinusMinus,
    Star, StarEq, StarStar, StarStarEq, Slash, SlashEq, Percent, PercentEq,
    Amp, AmpAmp, AmpEq, AmpAmpEq, Pipe, PipePipe, PipeEq, PipePipeEq,
    Caret, CaretEq,
    PrivateName

  Token* = object
    kind*: TokenKind
    start*: uint32
    length*: uint32

proc tokenEof*(at: uint32): Token {.inline.} =
  Token(kind: Eof, start: at, length: 0'u32)
proc tokenInvalid*(at: uint32): Token {.inline.} =
  Token(kind: Invalid, start: at, length: 1'u32)
```

CRITICAL: cross-check the variant list against `src/token.zc` lines 9-83 — it must be identical (names + order). A mismatch silently breaks the differential dump.

- [ ] **Step 4: Run, verify it passes** — `nim c -r --mm:arc --hints:off nim/tests/tlexer.nim` → PASS.

- [ ] **Step 5: Commit** — `git add nim/src/zjs/token.nim nim/tests/tlexer.nim && git commit -m "nim: token model — TokenKind enum + slice type (phase 2a)"`

---

## Task 2: Differential dumper + harness (the oracle, before the lexer)

Build the Nim token-dumper and the diff harness FIRST, against a temporary stub lexer, so the oracle is live for Tasks 3-5.

**Files:** Create `nim/src/zjs/lexer.nim` (stub), Create `nim/tools/nim_lex.nim`, Create `nim/tests/diff_lex.sh`, Modify `Makefile`.

- [ ] **Step 1: Stub lexer** — `nim/src/zjs/lexer.nim`:

```nim
## The lexer — a single forward pass producing flat Token slices.
## Idiomatic Nim port of src/lexer.zc. Tokens slice into `source`.
import token

type
  Lexer* = object
    source*: string
    pos*: int

proc initLexer*(source: string): Lexer = Lexer(source: source, pos: 0)

proc nextToken*(lx: var Lexer): Token =
  ## STUB (Task 2): emit Eof immediately. Real tokenization in Task 3+.
  tokenEof(lx.source.len.uint32)

iterator tokens*(lx: var Lexer): Token =
  ## Yields every token through and including the final Eof.
  while true:
    let t = lx.nextToken()
    yield t
    if t.kind == Eof: break
```

- [ ] **Step 2: The Nim dumper** — `nim/tools/nim_lex.nim` — must match `zjs lex` format EXACTLY (`%-12s  start=%-4u  length=%-4u  text="%.*s"`):

```nim
## nim-lex: dump the token stream in the exact format of `zjs lex`, for
## byte-diffing against the Zen-c reference (the differential oracle).
import std/[os, strformat]
import ../src/zjs/lexer
import ../src/zjs/token

proc main() =
  let src = if paramCount() >= 1: paramStr(1) else: ""
  var lx = initLexer(src)
  for t in lx.tokens():
    let text = src[t.start.int ..< (t.start + t.length).int]
    # %-12s  start=%-4u  length=%-4u  text="..."  (two spaces between fields)
    stdout.write(&"{($t.kind):<12}  start={($t.start):<4}  length={($t.length):<4}  text=\"{text}\"\n")

main()
```
NOTE: verify the spacing against a real `zjs lex` line in Step 4 — the Zen-c format is `%-12s` then TWO spaces, `start=%-4u` then TWO spaces, etc. Adjust the template until a one-token diff is empty.

- [ ] **Step 3: Differential harness** — `nim/tests/diff_lex.sh`:

```bash
#!/usr/bin/env bash
# Diff the Nim lexer dump vs the Zen-c `zjs lex` over a corpus.
# Usage: nim/tests/diff_lex.sh            # built-in snippets
#        nim/tests/diff_lex.sh <dir>      # every .js file under <dir>
set -uo pipefail
ZENC=build/zjs
NIMLEX=build/nim/nim-lex
fails=0; total=0
check() {  # $1 = source string
  total=$((total+1))
  local a b
  a=$("$ZENC" lex "$1" 2>/dev/null)
  b=$("$NIMLEX" "$1" 2>/dev/null)
  if [ "$a" != "$b" ]; then
    fails=$((fails+1))
    echo "DIFF on: $1"
    diff <(printf '%s' "$a") <(printf '%s' "$b") | head -20
  fi
}
if [ $# -ge 1 ]; then
  while IFS= read -r f; do check "$(cat "$f")"; done < <(find "$1" -name '*.js' | head -500)
else
  for s in 'let x = 1 + 2;' 'a===b' 'x ??= y' 'f(`a${b}c`)' '0xFFn' '/re/gi' 'a?.b' '#priv'; do check "$s"; done
fi
echo "diff_lex: $((total-fails))/$total identical, $fails differing"
exit $fails
```
Make it executable: `chmod +x nim/tests/diff_lex.sh`.

- [ ] **Step 4: Makefile targets + first run.** Add to the Nim section of `Makefile`:
```makefile
NIM_LEXBIN := $(NIM_OUT)/nim-lex
nim-lex: $(NIM_LEXBIN)
$(NIM_LEXBIN): $(NIM_SRCS) nim/tools/nim_lex.nim | $(NIM_OUT)
	$(NIM) c --mm:arc -d:release --hints:off --out:$(NIM_LEXBIN) nim/tools/nim_lex.nim

nim-difflex: nim-lex cli
	@bash nim/tests/diff_lex.sh

.PHONY: nim-lex nim-difflex
```
Run: `make nim-lex && build/nim/nim-lex 'x'` — expect a single `Eof  start=1  length=0  text=""` line (stub). Compare ONE token's formatting to `build/zjs lex 'x'`'s Eof line and fix the dumper template until the Eof lines match byte-for-byte. (The stub only emits Eof, so only the Eof line can be compared yet — that's enough to lock the format.)

- [ ] **Step 5: Commit** — `git add nim/src/zjs/lexer.nim nim/tools/nim_lex.nim nim/tests/diff_lex.sh Makefile && git commit -m "nim: lexer stub + differential dump harness vs zjs lex (phase 2a)"`

---

## Task 3: Lexer core — whitespace, identifiers, keywords, numbers, punctuators

Port the core of `src/lexer.zc`. The differential harness is the gate: after this task, the built-in snippets that use only these token classes must diff clean.

**Files:** Modify `nim/src/zjs/lexer.nim`, Modify `nim/tests/tlexer.nim`.

- [ ] **Step 1: Add unit tests** (append to `nim/tests/tlexer.nim`) covering: cursor over `let x = 1`; keyword vs identifier (`let` → KwLet, `lets` → Identifier); each punctuator class incl. the longest-match cases (`>>>=`, `??=`, `===`, `...`, `?.`); number forms (`0`, `123`, `1.5`, `0xFF`, `1e10`); `#priv` → PrivateName; whitespace/line-comment/block-comment skipping. Use the `tokens` iterator and assert `(kind, start, length)` per token. (Write concrete `check` assertions — model them on the `zjs lex` output for each input.)

- [ ] **Step 2: Run, verify they fail** (stub emits only Eof).

- [ ] **Step 3: Implement the core in `nim/src/zjs/lexer.nim`.** Port from `src/lexer.zc`: the cursor primitives (`peek`/`peekAt`/`advance`), `skipTrivia` (whitespace incl. the Unicode whitespace + `\r`/`\n` line terminators + `//` and `/* */` comments — see `src/lexer.zc` `skip_trivia`), the main `nextToken` dispatch, identifier/keyword scan (with the keyword lookup — mirror Zen-c's keyword matcher), number scan (decimal/hex/octal/binary/float/exponent/BigInt `n` suffix), the punctuator longest-match ladder, and `#`-private-name. Keep tokens as slices (set `start`/`length`, never copy text). **Do NOT implement strings/templates/regex yet** (Tasks 4-5) — emit `Invalid` or leave a clearly-marked gap for those lead bytes (`"` `'` `` ` `` `/`-as-regex).

- [ ] **Step 4: Run unit tests → PASS. Then run the differential harness** on the built-in snippets that avoid strings/templates/regex:
```bash
make nim-difflex
```
Expect the non-string/template/regex snippets to diff clean. (Some built-ins use `/re/`, `` ` ``, etc. — those will still differ until Tasks 4-5; that's expected. Focus on `let x = 1 + 2;`, `a===b`, `x ??= y`, `0xFFn`, `a?.b`, `#priv` diffing clean.)

- [ ] **Step 5: Commit** — `git add nim/src/zjs/lexer.nim nim/tests/tlexer.nim && git commit -m "nim: lexer core — trivia, idents, keywords, numbers, punctuators (phase 2a)"`

---

## Task 4: Strings + templates

**Files:** Modify `nim/src/zjs/lexer.nim`, Modify `nim/tests/tlexer.nim`.

- [ ] **Step 1: Unit tests** for: `'single'`, `"double"`, escapes (`'a\\nb'`, `"\\u0041"`, `'\\x41'`), unterminated string → `Invalid`, and templates `` `plain` ``, `` `a${b}c` ``, nested `` `${`x`}` `` (the TemplateLit slice spans the WHOLE backtick literal — see `src/lexer.zc` `scan_template`). Assert `(kind, start, length)` against `zjs lex` output for each.

- [ ] **Step 2: Run, verify the string/template tests fail.**

- [ ] **Step 3: Implement** `scanString` and `scanTemplate` in `nim/src/zjs/lexer.nim`, porting `src/lexer.zc`'s `scan_string` / `scan_template` / `scan_template_substitution`. The template scanner must balance `${ }` and handle nested templates + strings + comments inside substitutions (mirror the Zen-c logic faithfully — including the regex-in-substitution handling from `scan_template_substitution`).

- [ ] **Step 4: Run unit tests → PASS. Differential harness** — `f(\`a${b}c\`)` and string snippets must now diff clean.

- [ ] **Step 5: Commit** — `git add -u && git commit -m "nim: lexer strings + template literals (phase 2a)"`

---

## Task 5: Regex vs division (the context-sensitive token)

`/` is either division or a regex-literal opener depending on the previous significant token (ECMA-262 §12.2.1 InputElementDiv vs InputElementRegExp). Port `src/lexer.zc`'s `expect_regex` / `prev_kind` / `crossed_newline` machinery.

**Files:** Modify `nim/src/zjs/lexer.nim`, Modify `nim/tests/tlexer.nim`.

- [ ] **Step 1: Unit tests** for: `a / b` (two Slash-divisions), `/re/gi` at expression start (RegexLit), `return /x/` (RegexLit after a keyword), `x = /y/` (RegexLit after `=`), `a[0] / b` (Slash after `]`), `}\n/re/` (RegexLit — `}` + newline → ASI → regex), `{} / x` (Slash after `}` no newline). Char-class and escape cases: `/[/]/`, `/a\\/b/`. Assert against `zjs lex`.

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** the regex/division decision in `nextToken`: track `expectRegex`, `prevKind`, `crossedNewline` exactly as `src/lexer.zc` (the `expect_regex_after(kind)` table, the `}`-newline refinement, and `scanRegex` with char-class `[...]` and escape handling). This is the trickiest token — port it carefully and lean on the differential harness.

- [ ] **Step 4: Run unit tests → PASS. Differential harness** — `/re/gi` must diff clean; ALL built-in snippets now identical.

- [ ] **Step 5: Commit** — `git add -u && git commit -m "nim: lexer regex-vs-division context sensitivity (phase 2a)"`

---

## Task 6: Corpus acceptance — byte-identical tokens over real test262

The real gate: tokenize a large real-JS corpus through both engines and confirm zero diffs.

**Files:** none (uses the harness).

- [ ] **Step 1: Run the differential harness over a test262 corpus sample:**
```bash
make nim-lex cli
bash nim/tests/diff_lex.sh vendor/test262/test/language/expressions
```
Expected: `diff_lex: N/N identical, 0 differing`. Investigate and fix any diffs (each is a localized lexer bug — the Zen-c output is the reference). Re-run until clean.

- [ ] **Step 2: Widen the corpus** to a broader slice and re-run:
```bash
bash nim/tests/diff_lex.sh vendor/test262/test/language
```
Expected: 0 differing. (test262 files with intentional syntax errors may produce `Invalid` tokens in both — that still diffs clean as long as both engines agree.)

- [ ] **Step 3: Commit a record** of the corpus result (optional: append a note to the plan or a `nim/PHASE2A.md`), then:
```bash
git commit --allow-empty -m "nim: lexer differential parity vs Zen-c over test262 language/ corpus (phase 2a complete)"
```

---

## Done criteria

- `make nim-difflex` reports 0 differing on the built-in snippets.
- `bash nim/tests/diff_lex.sh vendor/test262/test/language` reports **0 differing** — the Nim lexer produces byte-identical tokens to the Zen-c lexer over a real corpus.
- `nim c -r nim/tests/tlexer.nim` passes.

This completes the lexer. Next increment: **Phase 2b — AST node types (idiomatic Nim object variants) + parser skeleton**, with `zjs parse` as the differential oracle for the parse tree.
