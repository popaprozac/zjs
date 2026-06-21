# ZJS-Nim Phase 2d-3a (function declarations/expressions + params) Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** `function` declarations + expressions with plain/default/rest params, byte-for-byte vs `build/zjs parse`. Generators/async/yield/await → 2d-3b. Pattern params (destructuring) → deferred. Object methods (now possible with FunctionExpr) → a small follow-up.

**Branch:** `nim-phase2`. **Reference:** `src/parser.zc` `parse_param_list` (~1694), `parse_function_decl` (~1823), `parse_function_expr` (~2772).

## Design (Step-0, verified)
**`IdentExpr` gains an optional default** (params like `b = 5` are an IdentExpr whose `right` is the default — verified from the oracle). So SPLIT `IdentExpr` out of the shared slice-leaf `discard` branch into its own:
```nim
of IdentExpr: identDefault*: AstNode      # nil normally; the `= expr` default in param position
```
(`newLeaf(IdentExpr, s, e)` still works — `identDefault` defaults to nil. The remaining slice-leaves StringExpr/RegexExpr/BigIntExpr/NullExpr/UndefinedExpr/ThisExpr stay in the `discard` branch.)

New branches:
```nim
of RestParam:
  restArg*: AstNode                        # the inner IdentExpr (Zen-c left)
of FunctionDecl, FunctionExpr:
  fnNameStart*, fnNameLen*: uint32         # 0/0 = anonymous (FunctionExpr only)
  fnBody*: AstNode                         # BlockStmt (Zen-c left)
  fnParams*: seq[AstNode]                  # Zen-c children
  fnIsAsync*, fnIsGenerator*: bool         # not dumped; set in 2d-3b
```
Constructors: `newRestParam(s, e, restArg)`, `newFunctionDecl(s, e, nameStart, nameLen, body, params, isAsync=false, isGenerator=false)`, `newFunctionExpr(...)` (uses `{.cast(uncheckedAssign).}` if one ctor serves both kinds, OR two separate ctors).

Labels: `FunctionDecl`/`FunctionExpr` are in `nk_label` (real). `RestParam` → `?`. `IdentExpr` keeps its quoted form.

Dumper:
```nim
of IdentExpr:
  stdout.write(&"{ind}{label} \"{slice(src, n.start, n.`end`)}\"\n")
  if n.identDefault != nil: dumpAst(n.identDefault, src, depth+1)
of RestParam:
  stdout.write(&"{ind}{label}\n")
  dumpAst(n.restArg, src, depth+1)
of FunctionDecl, FunctionExpr:
  if n.fnNameLen > 0'u32:
    stdout.write(&"{ind}{label} name=\"{slice(src, n.fnNameStart, n.fnNameStart + n.fnNameLen)}\"\n")
  else:
    stdout.write(&"{ind}{label} (anonymous)\n")
  dumpAst(n.fnBody, src, depth+1)            # body FIRST (Zen-c left)
  for prm in n.fnParams: dumpAst(prm, src, depth+1)   # then params (children)
```
(Keep the existing `StringExpr` quoted dump — split it from the old `of IdentExpr, StringExpr:` group.)

## Parser
- `parseParamList(p): seq[AstNode]` — loop until `)`/Eof: if `Ellipsis` → consume, ident=`newLeaf(IdentExpr, name)`, `newRestParam`; elif `LBrace`/`LBracket` → pattern param = DEFERRED, break; else ident=`newLeaf(IdentExpr, name.start, name.start+name.length)`, and if next is `Eq` → consume, `ident.identDefault = parseAssignmentExpr(p)` (mutate the field). Append; if next is `Comma` consume (tolerate trailing comma → if next is `)` break) else break.
- `parseFunctionDecl(p)`: consume `function`; (if `Star` → generator, 2d-3b — for 2d-3a assume no star); `nameTok = advance` (Identifier, required); `expect(LParen)`; `params = parseParamList`; `expect(RParen)`; `body = parseBlock(p)` (consumes `{ }`); `newFunctionDecl(kw.start, body.`end`, nameTok.start, nameTok.length, body, params)`.
- `parseFunctionExpr(p)`: consume `function`; (opt `Star`); optional name — if `peek().kind == Identifier` consume as name else anonymous (0/0); `expect(LParen)`; params; `expect(RParen)`; body; `newFunctionExpr(...)`.
- Wire: `parseStatement` dispatch `of KwFunction: return parseFunctionDecl(p)`. `parsePrimary` `of KwFunction: return parseFunctionExpr(p)`.

(NOTE on `return`: now testable inside function bodies — both engines build ReturnStmt. Top-level `return` stays a Zen-c parse error we don't replicate [error-reporting increment]. function_depth tracking not needed for dump parity, skip it.)

## Verified trees
`function f(a,b){return a;}`→FunctionDecl name="f"/{BlockStmt{ReturnStmt{a}}, IdentExpr a, IdentExpr b}; `function g(){}`→FunctionDecl name="g"/{BlockStmt}; `(function(){return 1;})`→Paren/FunctionExpr (anonymous)/{BlockStmt{ReturnStmt{1}}}; `(function named(x){})`→Paren/FunctionExpr name="named"/{BlockStmt, IdentExpr x}; `function h(a,b=5,...rest){}`→FunctionDecl name="h"/{BlockStmt, IdentExpr a, IdentExpr b{NumberExpr 5}, ?(RestParam){IdentExpr rest}}; `let f=function(a){return a;};`→VarDecl/Declarator f/FunctionExpr (anonymous)/{BlockStmt{ReturnStmt{a}}, IdentExpr a}.

## Task 1: AST branches + dumper (incl. IdentExpr split)
- [ ] tests (suite "ast 2d-3a") + impl. Confirm existing IdentExpr tests + the full differential suite still pass after the split. `make nim-parse` builds. commit `nim: AST + dumper — function/param/rest nodes, IdentExpr default (phase 2d-3a)`.

## Task 2: param + function parsers
- [ ] tests (suite "parser functions") + differential battery (verified trees + `function f(){ if(a) return b; return c; }`, `function f(a, b,) {}` (trailing comma), `(function(){})()` (IIFE), `[function(){}]`, `function f(x = a ? b : c) {}`, `function f(...args) { return args; }`). FAIL→impl→verify all OK; no-regression sweep; nim-diffparse.
- [ ] commit `nim: parser — function declarations/expressions + params (phase 2d-3a)`.

## Done criteria
Battery byte-clean; `return` works inside functions; IdentExpr split doesn't regress existing tests; 0 regressions. Next: 2d-3b (generators/async/yield/await), then object methods, then arrows.
