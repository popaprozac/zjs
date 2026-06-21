# ZJS-Nim Phase 2d-3b (generators / async / yield / await) Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** `function*` generators + `yield`/`yield*`, `async function` + `await`, byte-for-byte vs `build/zjs parse`. Generator/async-ness is NOT dumped (flags only); `yield`/`await` are `?`-labeled expression nodes.

**Branch:** `nim-phase2`. **Reference:** `src/parser.zc` `parse_assignment` yield path (~3161), the await branch in `parse_primary` (~4158), `parse_function_decl`/`parse_function_expr` (`*`/async handling), `parse_statement` `async function` dispatch (~471).

## Design (Step-0, verified)
New variant branches (`nim/src/zjs/ast.nim`):
```nim
of YieldExpr:
  yieldArg*: AstNode        # operand; nil for bare `yield`
  yieldDelegate*: bool      # true for `yield*` (not dumped)
of AwaitExpr:
  awaitArg*: AstNode
```
Constructors: `newYield(s, e, arg, delegate)`, `newAwait(s, e, arg)`. Both kinds → `?` (not in nk_label).

Dumper:
```nim
of YieldExpr:
  stdout.write(&"{ind}{label}\n")
  if n.yieldArg != nil: dumpAst(n.yieldArg, src, depth+1)
of AwaitExpr:
  stdout.write(&"{ind}{label}\n")
  dumpAst(n.awaitArg, src, depth+1)
```

## Parser — context flags + gen/async/yield/await
Add to `Parser`: `inGenerator*: bool`, `inAsync*: bool` (zero-init false).

**Function gen/async detection + context scoping** (modify `parseFunctionDecl`/`parseFunctionExpr` from 2d-3a):
- After consuming `function`, if `peek().kind == Star` → consume, `isGenerator = true`.
- The async-ness comes from the CALLER (an `async` prefix). Add an `isAsync` param to both (default false).
- Around the BODY parse: save/set/restore `inGenerator`/`inAsync` to THIS function's gen/async (NOT inherited — a non-generator nested in a generator must NOT see `yield` as a keyword):
  ```nim
  let savedG = p.inGenerator; let savedA = p.inAsync
  p.inGenerator = isGenerator; p.inAsync = isAsync
  let body = parseBlock(p)
  p.inGenerator = savedG; p.inAsync = savedA
  ```
- Pass `isGenerator`/`isAsync` into `newFunctionDecl`/`newFunctionExpr` (the flags exist on the node).

**async dispatch:**
- `parseStatement`: `KwAsync` with `p.toks[p.pos+1].kind == KwFunction` → consume `async`, `return parseFunctionDecl(p, isAsync = true)`. (Keep this BEFORE the labeled/expression fall-through.)
- `parsePrimary`: `KwAsync` with next `KwFunction` → consume `async`, `return parseFunctionExpr(p, isAsync = true)`. (Plain `async` as an identifier still works — only treat it as a prefix when followed by `function`.)

**yield** — in `parseAssignmentExpr`, at the TOP (before `parseConditional`):
```nim
if p.peek().kind == KwYield and p.inGenerator:
  let kw = p.advance()
  var delegate = false
  if p.peek().kind == Star: discard p.advance(); delegate = true
  var arg: AstNode = nil
  var endPos = kw.start + kw.length
  let nk = p.peek().kind
  if delegate or nk notin {Semicolon, RParen, RBracket, RBrace, Comma, Colon, Eof}:
    arg = parseAssignmentExpr(p)
    if arg != nil: endPos = arg.`end`
  return newYield(kw.start, endPos, arg, delegate)
```

**await** — in `parseUnary`, at the TOP (before the other prefix-operator checks):
```nim
if p.peek().kind == KwAwait and p.inAsync:
  let kw = p.advance()
  let operand = parseUnary(p)
  return newAwait(kw.start, (if operand != nil: operand.`end` else: kw.start), operand)
```

**for await** (minor): in `parseFor`, right after consuming `for`, if `peek().kind == KwAwait and p.inAsync` → consume it (sets the await flag — not dumped; the resulting ForOfStmt dumps identically). Skip if not inAsync.

## Verified trees (all inside a gen/async function)
`function* g(){ yield; }`→FunctionDecl/{BlockStmt{`?`(YieldExpr, no child)}}; `yield 1;`→`?`/{NumberExpr 1}; `yield* x;`→`?`/{IdentExpr x}; `let a = yield b;`→Declarator a/`?`/{b}; `async function f(){ await x; }`→FunctionDecl/{BlockStmt{`?`(AwaitExpr)/{x}}}; `return await g();`→ReturnStmt/`?`/{Call}; `await a + await b`→Binary(Plus)/{`?`{a}, `?`{b}}.

## Task 1 (single combined task)
**Files:** `ast.nim`, `nim_parse.nim`, `parser.nim`, `tparser.nim`.
- [ ] tests (suite "parser gen/async"): the verified trees. FAIL→impl.
- [ ] add YieldExpr/AwaitExpr branches + constructors + dumper; add inGenerator/inAsync flags; gen/async detection + context scoping; yield in parseAssignmentExpr; await in parseUnary; async dispatch; for-await consume.
- [ ] differential battery (the verified trees + `function* g(){ yield a; yield* b; return c; }`, `async function f(){ for await (x of y) z; }`, `function f(){ var yield = 1; }` (yield as ident in NON-generator — must stay IdentExpr!), `async function f(){ var await = 1; }`? NO — await is reserved in async; use `function f(){ var await = 1; }` (await as ident in NON-async)). All OK.
- [ ] CRITICAL no-regression: `yield` / `await` as plain identifiers OUTSIDE gen/async must still parse as IdentExpr (e.g. `yield`, `await`, `var yield = 1`, `f(await)`). Sweep these.
- [ ] commit `nim: parser — generators/async/yield/await (phase 2d-3b)`.

## Done criteria
Battery byte-clean; `yield`/`await` are keywords ONLY inside gen/async (else IdentExpr); nested non-gen function inside a generator doesn't treat `yield` as a keyword; 0 regressions. Next: object methods (FunctionExpr now available), then arrows + destructuring.
