# ZJS-Nim Phase 2e (classes) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Parse ES classes — `class C {}`, `extends`, methods/accessors/static/generator/async/computed/private methods, `static {}` blocks, `super`, class expressions, AND class fields with the synthetic-constructor synthesis — byte-for-byte vs `build/zjs parse`.

**Architecture:** Two oracle-gated slices on branch `nim-phase2`. **2e-1** = class skeleton (everything EXCEPT instance fields). **2e-2** = class fields + the constructor-injection synthesis (the hard part). Object-variant AST additions with semantic, globally-unique field names; dumper walks mirror Zen-c `dump_ast` (left → right → third → children, skipping nil). `super(...)`/`super.m()` reuse the EXISTING Call/Member infra — only `super` itself is new (a `SuperExpr` primary that dumps `?`).

**Reference (Zen-c):** `src/parser.zc` `parse_class_decl` (~2703), `parse_class_expr` (~2744), `parse_class_body` (~2245, incl. synthesis ~2284-2425), `parse_method_body_pair` (~1934); `super` primary at ~4264, super-suffix in `parse_call_member` ~3705-3719. Dump walk: `tools/zjs.zc` `dump_ast` (~902) + `nk_label` (~278, returns `?` for every kind after `ForOfStmt`).

**Tech Stack:** Nim (`nim/src/zjs/ast.nim`, `nim/src/zjs/parser.nim`, `nim/tools/nim_parse.nim`), tests `nim/tests/tparser.nim`. Build: `make nim-parse`. Differential: `make nim-diffparse`.

> **BUILD GOTCHA (mandatory):** `make nim-parse` can leave a STALE binary. ALWAYS `rm -f build/nim/nim-parse && make nim-parse` before any differential test. A stale binary gave a false pass on 2d-3b.

---

## Step-0 verified dump shapes (captured from `build/zjs parse`)

All class NodeKinds dump label `?` (after the `ForOfStmt` cutoff in `nk_label`). Flags (static/get/set/async/gen) are NOT dumped. Class NAME is NOT dumped.

```
class C {}                          ?
class C extends B {}                ? / IdentExpr "B"            (parent=right, dumped first)
class C { m() {} }                  ? / [? / BlockStmt]          (MethodDef: body first, then params)
class C { m(x) {} }                 ? / [? / BlockStmt, IdentExpr "x"]
class C { static s(){} get g(){} set v(x){} }   three MethodDefs, each ?/BlockStmt(+params); flags not shown
class C { [k]() {} }                ? / [? / BlockStmt, IdentExpr "k"]   (computed key AFTER body)
class C { static { let a=1; } }     ? / [? / BlockStmt{VarDecl...}]      (StaticBlock: body only)
const C = class extends B {};       Declarator / [? / IdentExpr "B"]     (ClassExpr same shape as ClassDecl)
class C { *g(){} async a(){} async *ag(){} }    all ? / BlockStmt
super.m()                           Call / Member name="m" / ?           (? = SuperExpr; reuses Member+Call)
super()                             Call / ?                             (super() is a plain Call node)
```

**Fields + synthetic constructor (2e-2) — verified:**
```
class C { x = 1; static y = 2; #p = 3; z; }
  ?
    ? / NumberExpr 1                 (ClassField x; init=left)
    ? / NumberExpr 2                 (ClassField static y)
    ? / NumberExpr 3                 (ClassField #p)
    ?                                (ClassField z; no init → no children)
    ? / BlockStmt{                   (SYNTHETIC ctor, appended LAST)
          Assignment op=Eq / [Member name="x" / ThisExpr, NumberExpr 1]
          Assignment op=Eq / [Member name="#p" / ThisExpr, NumberExpr 3]
          Assignment op=Eq / [Member name="z" / ThisExpr, UndefinedExpr] }
        # NOTE: static y is EXCLUDED from the synth ctor (instance fields only). Order = source order of instance fields.

class C { [k2] = 5; }
  ? / [ ? / [NumberExpr 5, IdentExpr "k2"],         (ClassField: init then computed key)
        ? / BlockStmt{ Assignment / [Computed/[ThisExpr, IdentExpr "k2"], NumberExpr 5] } ]
        # the computed-key node is SHARED: appears under the ClassField (third) AND the Computed target (index).

class C { x = 1; constructor() { foo(); } }
  ? / [ ?/NumberExpr 1,                              (ClassField x stays as a child)
        ?/BlockStmt{ Assignment(this.x=1), Call/IdentExpr"foo" } ]   (init PREPENDED into existing ctor)

class C extends B { x = 1; }
  ? / [ IdentExpr "B",
        ?/NumberExpr 1,
        ?/BlockStmt{ Assignment(this.x=1), Call/? } ]   (synth ctor; inits THEN super(); super()=Call/SuperExpr)

class C extends B { x = 1; constructor() { super(); } }
  ? / [ IdentExpr "B", ?/NumberExpr 1,
        ?/BlockStmt{ Assignment(this.x=1), Call/? } ]   (init prepended BEFORE the explicit super())

class C { static x = 1; }
  ? / [ ?/NumberExpr 1 ]              (ONLY a static field → any_inst_field=false → NO synth ctor)

class C { x }
  ? / [ ?,                            (bare field, no init)
        ?/BlockStmt{ Assignment(this.x = UndefinedExpr) } ]
```

Key synthesis rules (mirror `parse_class_body` ~2284-2425):
- `any_inst_field` = any ClassField with `isStatic == false`. Synthesis only runs when true.
- `ctor_idx` = index of the non-static MethodDef whose name is exactly `constructor` (11 bytes). (The synth ctor itself counts once created.)
- If `any_inst_field` and NO explicit ctor → synthesize a MethodDef: empty BlockStmt body (name len 0). If `is_derived`, body starts with one child = `super()` (a `Call` whose callee is a `SuperExpr`). Append the synth ctor as the LAST member.
- If `any_inst_field` and an explicit/synth ctor exists → PREPEND, before the ctor body's existing children, one `this.<name> = <init|undefined>` Assignment per **instance** field in source order. Static fields are skipped. The ClassField nodes REMAIN as separate members (still dumped).
- Per-field target: computed (`fieldNameLen==0` and `fieldComputedKey!=nil`) → `Computed(recv=ThisExpr, index=<shared computed key>)`; else → `Member(recv=ThisExpr, name=fieldNameStart/Len)`. `this` = a fresh `ThisExpr` at the field's start. init = `fieldInit`, or a fresh `UndefinedExpr` at the field's start when nil.

---

## AST field names (globally unique — Nim variant requirement)

Add to the `case kind` variant in `ast.nim` (currently these kinds fall through `else: discard`):

```nim
of ClassDecl, ClassExpr:
  classNameStart*, classNameLen*: uint32     # NOT dumped; kept for semantic fidelity
  classParent*: AstNode                      # `extends` expr (Zen-c right); nil if none
  classMembers*: seq[AstNode]                # Zen-c children
of MethodDef:
  methodNameStart*, methodNameLen*: uint32   # NOT dumped (0/0 = computed)
  methodBody*: AstNode                       # Zen-c left (BlockStmt)
  methodComputedKey*: AstNode                # Zen-c third (computed key; nil)
  methodParams*: seq[AstNode]                # Zen-c children
  methodIsStatic*: bool                      # NOT dumped (Zen-c bool_value)
  methodAccessor*: TokenKind                 # Eq (plain) / KwGet / KwSet — NOT dumped (Zen-c op)
  methodIsAsync*, methodIsGenerator*: bool   # NOT dumped (Zen-c num encoding)
of StaticBlock:
  staticBlockBody*: AstNode                  # Zen-c left (BlockStmt)
of ClassField:                               # (2e-2)
  fieldNameStart*, fieldNameLen*: uint32     # NOT dumped (0/0 = computed)
  fieldInit*: AstNode                        # Zen-c left (initializer; nil if none)
  fieldComputedKey*: AstNode                 # Zen-c third (computed key; nil)
  fieldIsStatic*: bool                       # NOT dumped (Zen-c bool_value)
```
`SuperExpr` stays a label-only leaf (no branch needed — it falls through `else: discard` in the variant and the dumper's `else`, printing `?`). `SuperCall` is never produced by the parser; leave it in `else: discard`.

Constructors (add after `newPatternEntry`):
```nim
proc newClass*(kind: NodeKind, s, e, nameStart, nameLen: uint32, parent: AstNode, members: seq[AstNode]): AstNode =
  ## kind ∈ {ClassDecl, ClassExpr}
  {.cast(uncheckedAssign).}:
    result = AstNode(kind: kind, start: s, `end`: e, classNameStart: nameStart,
                     classNameLen: nameLen, classParent: parent, classMembers: members)

proc newMethodDef*(s, e, nameStart, nameLen: uint32, body, computedKey: AstNode,
                   params: seq[AstNode], isStatic: bool, accessor: TokenKind,
                   isAsync, isGenerator: bool): AstNode =
  AstNode(kind: MethodDef, start: s, `end`: e, methodNameStart: nameStart, methodNameLen: nameLen,
          methodBody: body, methodComputedKey: computedKey, methodParams: params,
          methodIsStatic: isStatic, methodAccessor: accessor,
          methodIsAsync: isAsync, methodIsGenerator: isGenerator)

proc newStaticBlock*(s, e: uint32, body: AstNode): AstNode =
  AstNode(kind: StaticBlock, start: s, `end`: e, staticBlockBody: body)

proc newClassField*(s, e, nameStart, nameLen: uint32, init, computedKey: AstNode, isStatic: bool): AstNode =  ## 2e-2
  AstNode(kind: ClassField, start: s, `end`: e, fieldNameStart: nameStart, fieldNameLen: nameLen,
          fieldInit: init, fieldComputedKey: computedKey, fieldIsStatic: isStatic)
```

Dumper additions (`nim_parse.nim`, before the final `else:`):
```nim
of ClassDecl, ClassExpr:
  stdout.write(&"{ind}{label}\n")
  if n.classParent != nil: dumpAst(n.classParent, src, depth+1)
  for m in n.classMembers: dumpAst(m, src, depth+1)
of MethodDef:
  stdout.write(&"{ind}{label}\n")
  dumpAst(n.methodBody, src, depth+1)
  if n.methodComputedKey != nil: dumpAst(n.methodComputedKey, src, depth+1)
  for prm in n.methodParams: dumpAst(prm, src, depth+1)
of StaticBlock:
  stdout.write(&"{ind}{label}\n")
  dumpAst(n.staticBlockBody, src, depth+1)
of ClassField:                                 # (2e-2)
  stdout.write(&"{ind}{label}\n")
  if n.fieldInit != nil: dumpAst(n.fieldInit, src, depth+1)
  if n.fieldComputedKey != nil: dumpAst(n.fieldComputedKey, src, depth+1)
```
`SuperExpr` needs NO dumper case (the existing `else:` prints `?`). Verify `nkLabel(SuperExpr) == "?"` (it must — SuperExpr is after ForOfStmt in `labels.nim`).

---

## Slice 2e-1 — class skeleton (NO instance fields)

Covers: `class C {}`, `extends`, named/computed/private methods, get/set accessors, static methods, generator/async/async-generator methods, `static {}` blocks, `super.x`/`super()`, class expressions, nested classes. Instance fields are 2e-2; in 2e-1 a field (name not followed by `(`) is allowed to fail (hits `expect(LParen)` → `hadError`) — the 2e-1 battery has no fields.

### Parser additions (`parser.nim`)

**Forward declarations** (near the other forward decls ~163-170): `proc parseClassDecl(p: var Parser): AstNode`, `proc parseClassExpr(p: var Parser): AstNode`, `proc parseClassBody(p: var Parser, isDerived: bool): seq[AstNode]`, `proc parseMethodBodyPair(p: var Parser): AstNode`.

**`super` primary** — in `parsePrimary` add a case (next to `of KwThis:`):
```nim
of KwSuper:
  discard p.advance()
  return newLeaf(SuperExpr, t.start, t.start + t.length)
```
(The `super.x` / `super()` suffixes are already handled by the existing member/call suffix loop in `parseCallMember`. No `in_derived_constructor` guard — that is error-only, deferred to the error-reporting increment.)

**`class` expression** — in `parsePrimary` add:
```nim
of KwClass:
  return parseClassExpr(p)
```

**`class` statement** — in `parseStatement`'s `case`, add:
```nim
of KwClass: return parseClassDecl(p)
```

**`parseClassDecl`** (port of `parse_class_decl` ~2703, permissive — skip the binding-ident/strict early-error checks):
```nim
proc parseClassDecl(p: var Parser): AstNode =
  let kw = p.advance()                      # 'class'
  let nameTok = p.advance()                 # class name (binding ident)
  var parent: AstNode = nil
  if p.peek().kind == KwExtends:
    discard p.advance()
    parent = parseCallMember(p)             # LeftHandSideExpression
    if parent == nil: return nil
  let members = parseClassBody(p, parent != nil)
  let endPos = if members.len > 0: members[^1].`end` else: p.peek().start
  return newClass(ClassDecl, kw.start, endPos, nameTok.start, nameTok.length, parent, members)
```

**`parseClassExpr`** (port of `parse_class_expr` ~2744 — name is OPTIONAL, only a plain `Identifier`):
```nim
proc parseClassExpr(p: var Parser): AstNode =
  let kw = p.advance()                      # 'class'
  var nameStart = 0'u32
  var nameLen = 0'u32
  if p.peek().kind == Identifier:
    let nt = p.advance()
    nameStart = nt.start; nameLen = nt.length
  var parent: AstNode = nil
  if p.peek().kind == KwExtends:
    discard p.advance()
    parent = parseCallMember(p)
    if parent == nil: return nil
  let members = parseClassBody(p, parent != nil)
  let endPos = if members.len > 0: members[^1].`end` else: p.peek().start
  return newClass(ClassExpr, kw.start, endPos, nameStart, nameLen, parent, members)
```
> Confirm the exact name of the existing member/call entry proc (the port of `parse_call_member`) — it is referenced by optional-chaining code from 2c-1. Grep `parseCallMember`/`parseLeftHandSide` in `parser.nim` and use the actual name in both `extends` sites.

**`parseClassBody`** (2e-1 form — loop only, NO synthesis; synthesis added in 2e-2):
```nim
proc parseClassBody(p: var Parser, isDerived: bool): seq[AstNode] =
  if not p.expect(LBrace): return @[]
  var members: seq[AstNode]
  while p.peek().kind notin {RBrace, Eof}:
    if p.peek().kind == Semicolon:          # skip empty `;` separators
      discard p.advance(); continue
    let m = parseMethodBodyPair(p)
    if m == nil: p.hadError = true; break
    members.add(m)
  discard p.expect(RBrace)
  return members
```

**`parseMethodBodyPair`** (port of `parse_method_body_pair` ~1934; 2e-1 = method + static-block paths; the field branch is added in 2e-2 where marked). Use the existing `isPropertyNameStart` (line 566), `parseParamList`, `parseBlock`, `parseAssignmentExpr`, and the `p.toks[p.pos+1]` lookahead. Compute a `static`/`get`/`set` slice via `p.source[tok.start.int ..< (tok.start+tok.length).int]` (same idiom as `parseObject` line 634):
```nim
proc parseMethodBodyPair(p: var Parser): AstNode =
  let mutStart = p.peek().start
  # --- optional `static` ---
  var isStatic = false
  block:
    let first = p.peek()
    if first.kind == Identifier and first.length == 6'u32 and
       p.source[first.start.int ..< (first.start+first.length).int] == "static":
      # static { ... } block
      if p.toks[p.pos + 1].kind == LBrace:
        discard p.advance()                 # consume 'static'
        let sg = p.inGenerator; let sa = p.inAsync
        p.inGenerator = false; p.inAsync = false
        let body = parseBlock(p)
        p.inGenerator = sg; p.inAsync = sa
        if body == nil: return nil
        return newStaticBlock(mutStart, body.`end`, body)
      # `static <name>` / `static [` / `static *` / `static #x`
      let k2 = p.toks[p.pos + 1].kind
      if isPropertyNameStart(k2) or k2 == LBracket or k2 == Star or k2 == PrivateName:
        discard p.advance(); isStatic = true
  # --- optional `async` (async method) ---
  var isAsync = false
  if p.peek().kind == KwAsync:
    let k2 = p.toks[p.pos + 1].kind
    if isPropertyNameStart(k2) or k2 == LBracket or k2 == PrivateName or k2 == Star:
      discard p.advance(); isAsync = true
  # --- optional `*` (generator method) ---
  var isGen = false
  if p.peek().kind == Star:
    discard p.advance(); isGen = true
  # --- optional `get`/`set` accessor (not after async) ---
  var accessor = Eq                         # Eq sentinel = plain method
  if not isAsync:
    let id2 = p.peek()
    if id2.kind == Identifier and id2.length == 3'u32:
      let txt = p.source[id2.start.int ..< (id2.start+id2.length).int]
      if (txt == "get" or txt == "set"):
        let k2 = p.toks[p.pos + 1].kind
        if isPropertyNameStart(k2) or k2 == LBracket or k2 == PrivateName:
          discard p.advance()
          accessor = (if txt == "get": KwGet else: KwSet)
  # --- method name OR computed key ---
  var computedKey: AstNode = nil
  let nameTok = p.peek()
  if nameTok.kind == LBracket:
    discard p.advance()
    computedKey = parseAssignmentExpr(p)
    if computedKey == nil: return nil
    if not p.expect(RBracket): return nil
  else:
    # accept any property-name token or PrivateName (permissive; #constructor
    # early-error deferred to the error-reporting increment)
    if not isPropertyNameStart(nameTok.kind) and nameTok.kind != PrivateName:
      p.hadError = true; return nil
    discard p.advance()
  # === 2e-2 INSERTION POINT: field branch goes here (see slice 2e-2) ===
  # --- method: params + body ---
  let sg = p.inGenerator; let sa = p.inAsync
  p.inAsync = isAsync; p.inGenerator = isGen
  if not p.expect(LParen):
    p.inGenerator = sg; p.inAsync = sa; return nil
  let params = parseParamList(p)
  if not p.expect(RParen):
    p.inGenerator = sg; p.inAsync = sa; return nil
  let body = parseBlock(p)
  p.inGenerator = sg; p.inAsync = sa
  if body == nil: return nil
  return newMethodDef(mutStart, body.`end`,
                      (if computedKey != nil: 0'u32 else: nameTok.start),
                      (if computedKey != nil: 0'u32 else: nameTok.length),
                      body, computedKey, params, isStatic, accessor, isAsync, isGen)
```
> NOTE: `isPropertyNameStart` (line 568) currently includes `LBracket` and `Star`. That is fine for the lookahead checks above. Confirm `PrivateName` is a real `TokenKind` (the lexer emits it — see [[project_nim_classes_modules]]); if the enum name differs, use the actual one.

### Verified trees (2e-1)
`class C {}`→`?`. `class C extends B {}`→`?`/IdentExpr"B". `class C { m(x){return x;} }`→`?`/[`?`/BlockStmt{ReturnStmt/IdentExpr"x"}, IdentExpr"x"]. `class C { static s(){} get g(){return 1;} set v(x){} }`→three MethodDefs. `class C { [k](){} }`→`?`/[`?`/BlockStmt, IdentExpr"k"]. `class C { static { let a=1; } }`→`?`/[`?`/BlockStmt{VarDecl/Declarator"a"/NumberExpr1}]. `class C extends B { constructor(){ super(); super.m(); } }`→`?`/[IdentExpr"B", `?`/BlockStmt{Call/`?`, Call/Member"m"/`?`}]. `const C = class extends B {};`→VarDecl/Declarator"C"/[`?`/IdentExpr"B"]. `class C { *g(){} async a(){} async *ag(){} }`→three `?`/BlockStmt. `class C { #m(){} get #g(){return 1;} }`→two MethodDefs. `class C { "s"(){} 0(){} }`→two MethodDefs. `class Outer { m(){ class Inner {} } }`→nested `?`.

### Task 2e-1.1: AST branches + constructors + dumper
**Files:** `nim/src/zjs/ast.nim`, `nim/tools/nim_parse.nim`, `nim/tests/tparser.nim`.
- [ ] Add the `ClassDecl/ClassExpr`, `MethodDef`, `StaticBlock` of-branches to the variant (NOT ClassField yet — that's 2e-2). Add `newClass`, `newMethodDef`, `newStaticBlock`. Add the three dumper cases. (`SuperExpr` needs nothing.)
- [ ] Unit tests (suite "parser classes ast"): construct a ClassDecl with a parent + one MethodDef by hand, dump, assert the indented `?` tree. Construct a StaticBlock, assert.
- [ ] `rm -f build/nim/nim-parse && make nim-parse` builds clean. Full existing differential battery still byte-clean (regression guard).
- [ ] Commit: `nim: AST + dumper — class skeleton nodes (ClassDecl/Expr/MethodDef/StaticBlock) (phase 2e-1)`.

### Task 2e-1.2: parser (class decl/expr/body/method + super + dispatch)
**Files:** `nim/src/zjs/parser.nim`, `nim/tests/tparser.nim`.
- [ ] Add forward decls; `of KwSuper:`/`of KwClass:` in `parsePrimary`; `of KwClass:` in `parseStatement`; impl `parseClassDecl`/`parseClassExpr`/`parseClassBody`(no synth)/`parseMethodBodyPair`(method+static-block).
- [ ] Unit tests (suite "parser classes 2e-1") for each verified tree above.
- [ ] **CLEAN rebuild** then differential battery — every verified tree, byte-clean vs `build/zjs parse '<src>'`. Add: `class C extends f(x).y {}` (member/call parent), `class C { async *['x'](){} }`, `class C { static get g(){return 1;} }`, `class C { get(){} set(){} static(){} }` (contextual words as method names), `class C { ; ; m(){} ; }` (stray semicolons).
- [ ] No-regression: object literals/methods/accessors (2d-4), arrow funcs, `this`, member/call chains all unaffected. Sweep `({get(){}})`, `a.b.c`, `x => x`, `new f()`.
- [ ] Commit: `nim: parser — class skeleton (decl/expr/methods/static-block/super) (phase 2e-1)`.

### Done criteria (2e-1)
Battery byte-clean (classes without instance fields); object/member/super expressions unaffected; 0 regressions.

---

## Slice 2e-2 — class fields + synthetic constructor

Adds the ClassField branch to `parseMethodBodyPair` and the synthesis post-process to `parseClassBody`. This is the byte-parity-critical part.

### AST + dumper
- [ ] Add the `of ClassField:` variant branch + `newClassField` + the `of ClassField:` dumper case (all listed in the AST section above).

### Parser — field branch in `parseMethodBodyPair`
Insert at the `=== 2e-2 INSERTION POINT ===` marker (after the name/computed-key is consumed, BEFORE the method params/body). Port of `parse_method_body_pair` ~2071-2152:
```nim
  # --- field vs method: `(` here means method; otherwise it's a class field ---
  if p.peek().kind != LParen and accessor == Eq and not isAsync and not isGen:
    var initExpr: AstNode = nil
    if p.peek().kind == Eq:
      discard p.advance()
      initExpr = parseAssignmentExpr(p)
      if initExpr == nil: return nil
    # field terminator: optional `;` (ASI / newline early-errors are error-only, deferred)
    if p.peek().kind == Semicolon: discard p.advance()
    let fieldEnd = if initExpr != nil: initExpr.`end`
                   elif computedKey != nil: computedKey.`end`
                   else: nameTok.start + nameTok.length
    return newClassField(mutStart, fieldEnd,
                         (if computedKey != nil: 0'u32 else: nameTok.start),
                         (if computedKey != nil: 0'u32 else: nameTok.length),
                         initExpr, computedKey, isStatic)
```
> A string-literal field name (`'x' = 1`) in Zen-c stores the UNQUOTED slice (start+1, len-2). For 2e-2 keep it simple: store the raw `nameTok` slice — but ADD a differential case `class C { 'x' = 1; }` to the battery; if it diverges, replicate the unquote (only for `nameTok.kind == StringLit and length >= 2`: nameStart+1, nameLen-2). Resolve via the oracle, do not guess.

### Parser — synthesis in `parseClassBody`
Replace the 2e-1 `parseClassBody` body's tail (after the member loop + `expect(RBrace)`, before `return`) with the synthesis. Port of `parse_class_body` ~2284-2425:
```nim
  discard p.expect(RBrace)
  # --- synthesize / inject instance-field initializers into the constructor ---
  var ctorIdx = -1
  var anyInstField = false
  for i, m in members:
    if m.kind == ClassField and not m.fieldIsStatic: anyInstField = true
    if m.kind == MethodDef and not m.methodIsStatic and m.methodNameLen == 11'u32 and
       p.source[m.methodNameStart.int ..< (m.methodNameStart+m.methodNameLen).int] == "constructor":
      if ctorIdx < 0: ctorIdx = i           # first constructor wins (dup = error, deferred)
  if anyInstField:
    # 1. ensure a constructor exists (synthesize when absent)
    if ctorIdx < 0:
      let anchor = if members.len > 0: members[0].start else: 0'u32
      var bodyStmts: seq[AstNode]
      if isDerived:
        let superExpr = newLeaf(SuperExpr, anchor, anchor)
        bodyStmts.add(newCall(Call, anchor, anchor, superExpr, @[]))
      let block = newBlock(anchor, anchor, bodyStmts)
      let synth = newMethodDef(anchor, anchor, anchor, 0'u32, block, nil, @[],
                               false, Eq, false, false)
      members.add(synth)
      ctorIdx = members.len - 1
    # 2. prepend `this.<name> = <init|undefined>` for each INSTANCE field (source order)
    let ctor = members[ctorIdx]
    if ctor.methodBody != nil and ctor.methodBody.kind == BlockStmt:
      var inits: seq[AstNode]
      for m in members:
        if m.kind == ClassField and not m.fieldIsStatic:
          let thisE = newLeaf(ThisExpr, m.start, m.start)
          var target: AstNode
          if m.fieldNameLen == 0'u32 and m.fieldComputedKey != nil:
            target = newComputed(Computed, m.start, m.`end`, thisE, m.fieldComputedKey)  # SHARED key node
          else:
            target = newMember(Member, m.start, m.`end`, m.fieldNameStart, m.fieldNameLen, thisE)
          let initVal = if m.fieldInit != nil: m.fieldInit
                        else: newLeaf(UndefinedExpr, m.start, m.start)
          inits.add(newAssignment(m.start, initVal.`end`, Eq, target, initVal))
      ctor.methodBody.stmtList = inits & ctor.methodBody.stmtList
  return members
```
> `ctor.methodBody.stmtList = inits & ...` mutates the shared `BlockStmt` ref in place (matches Zen-c rewriting `block.children`). `members` must be a `var` (it is — a local `seq`).

### Verified trees (2e-2) — all from the Step-0 capture
`class C { x=1; static y=2; #p=3; z; }`, `class C { [k2]=5; }`, `class C { x=1; constructor(){foo();} }`, `class C extends B { x=1; }`, `class C extends B { x=1; constructor(){super();} }`, `class C { static x=1; }`, `class C { x }` — each must match `build/zjs parse` byte-for-byte (trees in Step-0 above).

### Task 2e-2.1: ClassField AST + dumper
**Files:** `ast.nim`, `nim_parse.nim`, `tparser.nim`.
- [ ] Add `of ClassField:` variant branch, `newClassField`, dumper case. Unit test: construct a ClassField with init, dump → `?`/NumberExpr. `rm -f build/nim/nim-parse && make nim-parse`. Existing battery byte-clean.
- [ ] Commit: `nim: AST + dumper — ClassField node (phase 2e-2)`.

### Task 2e-2.2: field parsing + synthetic-constructor synthesis
**Files:** `parser.nim`, `tparser.nim`.
- [ ] Add the field branch in `parseMethodBodyPair`; add the synthesis tail in `parseClassBody`.
- [ ] Unit tests (suite "parser class fields 2e-2") for each verified tree.
- [ ] **CLEAN rebuild** then differential battery — every verified tree + `class C { 'x' = 1; }` (string-name field, resolve unquote via oracle), `class C { x = 1; y = 2; }` (two inits, order), `class C { [a]=1; b=2; }` (mixed computed+named injection), `class C extends B { x=1; m(){} constructor(){g();} }` (ctor not first; inits prepend into it), `class C { static a=1; b=2; }` (static excluded, instance injected). All byte-clean.
- [ ] No-regression: 2e-1 method-only classes unchanged; object literals (a field-free `{x:1}`) unaffected; the synthesis must NOT fire when there are zero instance fields.
- [ ] Commit: `nim: parser — class fields + synthetic constructor (phase 2e-2)`.

### Done criteria (2e-2)
Every field/synth-ctor tree byte-clean; static-only classes produce NO synth ctor; method-only classes unchanged; 0 regressions. **Completes classes.** Next: modules (import/export), then error-reporting completion (#26).

---

## Independent verification (controller, after each slice)
After the subagent commits, the controller (me) runs an INDEPENDENT adversarial differential sweep on a CLEAN rebuild — novel compositions not in the subagent's battery (deeply nested classes, class-in-arg, class expr in ternary, mixed static/instance/computed/private fields with an explicit derived ctor, getter+field same name). Byte-parity vs `build/zjs parse` is the gate; subagent self-reports are NOT trusted (a subagent misreported "12/12" on 2d-3b that a clean rebuild refuted).
