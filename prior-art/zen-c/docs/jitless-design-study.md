# zjs — Jitless-First Design Study

> Phase 1 deliverable. Synthesizes parallel design studies of Hermes,
> QuickJS, and JSC's LLInt into concrete decisions for zjs.

## Mission recap

zjs is a **jitless-first** ECMA-262 engine: the interpreter is the engine,
not a warmup stage for a JIT. JIT support is *additive*, opt-in, and
only on platforms that allow runtime codegen. We want spec conformance
+ recent TC39 + clean embeddability + a future batteries-included
runtime layer (`fetch`, `WebSocket`, etc.) modelled on txiki.js.

Every decision below is graded by one question: **does this make the
interpreter faster or smaller without precluding JIT later?**

## Decisions at a glance

| # | Topic | Recommendation | Lifted from |
|---|---|---|---|
| 1 | Value representation | NaN-box, 64-bit, JSC's `OtherTag`-bit layout | JSC LLInt |
| 2 | Bytecode shape | Register-based; packed-struct-per-opcode union | Hermes |
| 3 | Operand width encoding | Width-specialized opcodes (`Jmp` / `JmpLong`) | Hermes |
| 4 | Dispatch | Computed-goto via `goto *table[op]` in one function | Hermes |
| 5 | Inline caches | Side-table on CodeBlock; monomorphic; patched in-place | LLInt + Hermes |
| 6 | Object model | Hidden-class transition tree; 5 inline slots | Hermes |
| 7 | GC | Stop-the-world mark-sweep, single generation | Hermes (direction) |
| 8 | Strings | Latin-1/UCS-2 dual storage + atom interning | QuickJS + Hermes |
| 9 | AOT bundle | mmap-ready bytecode bundle, zero-copy load | Hermes |
| 10 | Spec coverage | test262 wired up from first running interpreter | own decision |
| 11 | Runtime layer | Separate above-engine layer, txiki-style | user intent |

## How to read this document

Each decision section has: **Recommendation**, **Why** (cross-engine
evidence), **Reconsider if** (what would flip the call), and **Refs**
(primary-source files worth reading when implementing). Recommendations
aren't commitments — they're the default we'll start from. Anything
flagged is fair game to revisit when the relevant code exists.

---

## 1. Value representation — NaN-boxed JSValue, JSC layout

**Recommendation:** 64-bit NaN-boxing using JSC's encoding:
`NumberTag = 0xfffe000000000000`, `OtherTag = 0x2`. Doubles get
`+DoubleEncodeOffset` added so they land in the `0x0002…0xFFFC` range;
int32s are `NumberTag | (uint32_t)i`; pointers occupy the low 48 bits
unaltered; `null/undefined/true/false/empty` are small constants with
`OtherTag` set. `isCell()`, `isInt32()`, `isDouble()` each compile to
one or two ALU ops.

**Why this over Hermes's or QuickJS's:**
- **JSC vs Hermes:** Hermes uses a 16-bit high tag and *has no SmallInt fast path* — every JS number is a double through NaN-boxing
  (`HermesValue.h:422-423`, `isNumber() { return isDouble(); }`). JSC's int32 fast path matters: integer-typed loops are the easy 5-10×
  speedup on a non-JIT engine. Take it.
- **JSC vs QuickJS:** QuickJS uses a tagged-union *struct* on 64-bit by default — 16 bytes per value, simpler decode but doubles
  cost an extra load (`quickjs.h:228-231`). For a register-machine bytecode where values live in a giant call-frame array,
  16-byte values double the GC scan cost and trash L1. NaN-box is 8 bytes.
- **Pinned masks:** the two NaN-box constants (`NumberTag`, `NotCellMask`) live in callee-saved registers in LLInt
  (`LowLevelInterpreter.asm:99-102`). We replicate this by binding them to `register`-keyword locals in the interpreter
  function and hoping the C compiler keeps them resident — `musttail` dispatch helps because there's no spill point.

**Reconsider if:**
- We seriously target 32-bit ISAs (no), which would force the tag-payload-pair layout.
- We add a Symbol-rich pure-spec mode — then we need to make sure `Symbol` and `BigInt` fit cleanly (JSC reserves dedicated immediate tags;
  Hermes uses an extended 4-bit `ETag`).

**Refs:**
- `WebKit/Source/JavaScriptCore/runtime/JSCJSValue.h:398-509` — the canonical layout
- `hermes/include/hermes/VM/HermesValue.h:10-96` — useful contrast (no SmallInt)
- `quickjs/quickjs.h:228-231` and `:144-188` — tagged-union vs NaN-boxed variants in one engine

---

## 2. Bytecode shape — register, packed-struct-per-opcode

**Recommendation:** Register-based bytecode where every operand is a slot
index into the current call frame. Each opcode is a `packed struct` of
its operands; all such structs are unioned together as a single `Inst`
type, and the bytecode buffer is logically `Inst*`. Operand "decode" is
a struct-field load at a constant offset from `ip` — no shift/mask
plumbing.

**Why:**
- **Register vs stack:** Hermes and JSC are both register-machines. QuickJS is stack-based and pays for it on hot ops — every
  push/pop is a load/store. For a non-JIT engine, fewer interpreter instructions per source operation = direct speedup. Register
  machines also play better with the IC side-table model in §4: every source slot has a stable identity across the function body.
- **Packed-struct-per-op (Hermes's trick):** the bytecode buffer is a `union { iAddN_t addN; iGetById_t getById; ... }`
  (`Inst.h:25-89`). Inside an opcode handler you write `ip->iAddN.op2` and the C compiler emits a single load at a constant
  offset. No `LEB128`, no per-operand width flag, no manual `(ip[1] | ip[2]<<8)` plumbing. The cleanest expression of
  "fixed-layout-per-opcode" in any engine I looked at.
- **Compiler-friendly:** the layout is plain C / Zen-c structs. No code generator, no offline assembler. Build-system stays small.

**Reconsider if:**
- We grow >250 opcodes (then prefix-byte widening like LLInt's `op_wide16/32` is the only way to keep the dispatch tables sane).
- Bytecode density becomes a problem on disk — QuickJS's short forms (`push_0..7`, `get_loc0..3`, `call0..3`) halve typical bundle size with ~30 extra opcodes. Easy to add later.

**Refs:**
- `hermes/include/hermes/Inst/Inst.h:25-89` — the union trick
- `hermes/include/hermes/BCGen/HBC/BytecodeList.def` — the source-of-truth opcode list
- `WebKit/Source/JavaScriptCore/bytecode/BytecodeList.rb` — for comparison; LLInt drives a Ruby DSL that emits C++ structs + asm
- `quickjs/quickjs-opcode.h:289-362` — the short-form opcode menu

---

## 3. Operand-width encoding — width-specialized opcodes

**Recommendation:** When a register/constant operand might exceed 8 bits,
emit a parallel "long" opcode (`Mov` + `MovLong`, `Jmp` + `JmpLong`,
`GetById` + `GetByIdLong`). The compiler picks the narrowest variant
that fits; the interpreter handles each as a distinct opcode with a
distinct struct layout.

**Why this over LLInt-style prefix bytes:**
- **Hermes:** one opcode per width per operation (`BytecodeList.def`). Three dispatch tables degenerate to one. Operand decode stays
  a single struct-field load.
- **LLInt:** `op_wide16` / `op_wide32` prefix toggles all operands in the next instruction wider (`Instruction.h:80-145`).
  Three parallel dispatch tables. Saves one byte per wide instruction over Hermes's approach, but adds a branch per dispatch and
  a build-time decision: same opcode handler logic, three asm copies. Worth it for LLInt because they amortize across V8-style
  JIT tiers. We won't.

**Reconsider if:** we end up with too many opcodes to comfortably maintain three-or-more widths per op (>50 wide-eligible opcodes
× 3 widths = the LLInt regime; tractable but tedious).

**Refs:** `BytecodeList.def` (Hermes) vs `Instruction.h:80-145` + `LowLevelInterpreter.asm:487-497` (LLInt) — same problem, two
mature solutions, ours is the simpler one.

---

## 4. Dispatch — computed-goto in one function (Hermes pattern)

**Recommendation:** Single big `interpret()` function. Each opcode is a
labeled block. Dispatch is `goto *opcodeTable[ip->op]` at the end of
every block. `#ifndef ZJS_HAVE_COMPUTED_GOTO` falls back to
`switch (ip->op)` so any C compiler can build it.

```c
static void* opcodeTable[OP_COUNT] = {
    [OP_LOAD_CONST] = &&op_load_const,
    [OP_ADD] = &&op_add,
    // ...
};
DISPATCH;
op_load_const: { ... }; ip += sizeof(InstLoadConst); DISPATCH;
op_add:        { ... }; ip += sizeof(InstAdd);       DISPATCH;
```

**Why this and not `musttail` tail-call'd handlers:**
- **Musttail (the alternative)** would put each handler in its own
  function and end every one with `[[clang::musttail]] return
  next_handler(...)`. Theoretically nicer: the C compiler treats the
  hot constants (NaN-box masks, metadata base) as callee-saves implicitly
  because every handler sees the same argument set. LLInt-class
  register pinning in portable C.
- **But it's a fragile bet for a hobby project.** Musttail needs Clang
  ≥ 13, isn't on gcc/MSVC, and depends on whatever C the Zen-c
  transpiler emits being tail-call-eligible (Zen-c might add cleanup
  shims for moved values that break it). If musttail silently
  degrades to a regular call, we get the function-call overhead
  *plus* worse register pressure than one big function.
- **Hermes's choice has billions of device-shipments of evidence.** Same
  dispatch-perf ceiling on real workloads. Zero toolchain risk.
- **One-function structure is also better for the doc-driven design
  we're using.** Adding a new opcode = a new labeled block + a table
  entry. No new function, no header churn, no inlining surprises.

**Reconsider if:**
- We see ≥ 1.2× perf headroom from musttail on benchmarks once the
  interpreter is mature. The source structure (one labeled block per
  opcode) is mechanically convertible to per-function handlers.
- Hermes itself moves to a tail-call model — they have the data we
  don't.

**Refs:**
- `hermes/lib/VM/Interpreter.cpp:1059-1142` — the canonical version
- `quickjs/quickjs.c:17387-17402` — `#define DIRECT_DISPATCH` toggle for switch fallback
- `WebKit/Source/JavaScriptCore/llint/LowLevelInterpreter.asm` — for context on what we're choosing *not* to do

---

## 5. Inline caches — side-table metadata, monomorphic, patched in place

**Recommendation:** Each CodeBlock owns a `Metadata` side table.
Bytecode is immutable; metadata is mutable. Property-access opcodes
(`GetById`, `PutById`, etc.) carry a small operand (1 byte is plenty
to start) that indexes into the metadata table. The IC entry is
`{ HiddenClass* class, uint32_t slot }` (or `Unset`); on a miss the
slow path overwrites those two fields. That's it. No mprotect, no
icache flush, no codegen.

**Why:**
- **This is the load-bearing trick for non-JIT perf.** Property access without ICs makes a spec-grade engine 3–10× slower than
  necessary on real code. QuickJS skips ICs and uses a per-shape open-hashed prop table instead
  (`quickjs.c:5730-5752`) — fast for QuickJS's small scale but not as fast as a one-instruction structure-check.
- **Hermes and JSC both do this, with the same data flowing through different shapes.** Hermes: 8 bytes per cache entry stored
  on `CodeBlock::propertyCache()` (`PropertyCache.h:21-30`). JSC: 16-byte `GetByIdMetadata` union with overlapping fields for
  different cache modes (`GetByIdMetadata.h:34-103`, with a memorable union-overlap hack where the mode byte hides in the high
  bits of the cached pointer because `JSObject*` has zero high bytes on Apple).
- **Bytecode stays mmap-able.** Critical for §9 (AOT bundle). ICs in the bytecode stream would force COW pages on every IC update.

**Reconsider if:**
- Polymorphism dominates hot sites — then add a small inline PIC chain (2-3 entries) before falling back to slow path. The
  side-table can grow per-site without disturbing the bytecode.
- Memory pressure on the metadata table — Hermes uses an 8-bit cache index with `0` meaning "don't cache" so the compiler can
  prune obviously-megamorphic sites.

**Refs:**
- `hermes/include/hermes/VM/PropertyCache.h` and `CodeBlock.h:270-279` — small and clean
- `WebKit/Source/JavaScriptCore/bytecode/GetByIdMetadata.h:34-103` — the production version with mode flags
- `WebKit/Source/JavaScriptCore/bytecode/MetadataTable.h:41-44` — the two-tier offset table for metadata indexing

---

## 6. Object model — transition-tree hidden classes, 5 inline slots

**Recommendation:** Each object carries a `HiddenClass*`. Transitions
on add-property are recorded in a per-class transition map keyed on
`(Symbol, PropertyFlags)`. First 5 properties live in inline storage
on the object; the rest spill to a `PropStorage` array. Property maps
are lazy — materialized on first lookup, then stolen from parent to
child when a transition happens so most classes don't keep their own
copy.

**Why:**
- **This is exactly Hermes's model** (`HiddenClass.h:69-122`, `JSObject.h:377`) and it's the cleanest expression of "fast
  property access in a spec-grade engine without going full V8."
- **Plays directly with §5.** ICs cache `{HiddenClass*, slot}` — the class identity check is one pointer compare, then a slot
  load. Sub-nanosecond fast path.
- **Dictionary mode for stragglers.** When an object accumulates >~64 properties or sees a delete, switch to a per-object class
  with a hash map. Same pattern as V8 and Hermes. Keeps the common case fast and the pathological case from being O(n).
- **Why not QuickJS-style hash-consed shapes?** QuickJS interns shapes runtime-wide so two objects with the same property order
  share a `JSShape*` (`quickjs.c:4730-4760`). Elegant but it adds a hash-cons step on every transition. The transition tree
  pays off the same lookup cost without the consing — and the IC slot operand binds to the class pointer either way.

**Reconsider if:**
- Lots of small objects with identical layout fill the heap — then hash-consing shapes (QuickJS-style) is a memory win on top of the tree.
- We want pure-AOT mode where shapes are known at compile time → flat property dictionaries might be simpler than transition trees.

**Refs:**
- `hermes/include/hermes/VM/HiddenClass.h:69-122`
- `hermes/include/hermes/VM/JSObject.h:377` (`DIRECT_PROPERTY_SLOTS = 5`)
- `quickjs/quickjs.c:910-925` (`JSShape` definition) and `:4730-4760` (hash-consing)

---

## 7. GC — stop-the-world mark-sweep, single generation

**Recommendation:** Tracing GC from the start. Single space, free-list
allocation, conservative-on-stack precise-on-heap marking. Standard
tri-color mark phase walks roots (call stack + globals + native
references), then a linear sweep returns dead memory to the free list.
**No write barriers** — single generation, so old→new pointers don't
need tracking.

```
mark:  for root in roots: mark_recursive(root)
sweep: for slot in heap:  if not marked: free(slot)
                          else: unmark(slot)
```

~300 LOC to get running. The right shape to evolve from.

**Why not refcount + cycle collector (QuickJS's choice, original doc's recommendation):**

The previous version of this doc recommended QuickJS-style refcount. On
re-examination against the project's stated mission ("claw back perf
from JIT"), that's the wrong call. The reasoning:

- **Refcount cost is per-value-write.** Every `let x = y` is
  `INCREF(y); DECREF(old_x)` — 4-6 ALU ops plus a possible cleanup
  branch on every store. In an interpreter where dispatch time
  dominates, that's the cost we *can't* afford. Mark-sweep moves the
  cost to periodic pauses where it's amortized.
- **Both reference engines for our design space rejected refcount.**
  Hermes (jitless, iOS-first, the closest design neighbor) uses Hades —
  generational concurrent mark-sweep with compaction. JSC uses Riptide
  (generational). QuickJS uses refcount; QuickJS is the "small + simple
  + good enough" reference, not the "claw back JIT-class perf" reference.
- **No write barriers** in a single-generation mark-sweep means every
  value-write path is still one store — same dispatch-loop cost as
  refcount's "no barriers" claim, but without the per-write refcount
  arithmetic.
- **Migration cost.** Refcount → mark-sweep is essentially a rewrite of
  the value lifecycle. Mark-sweep → generational → concurrent is an
  evolution of one subsystem. Better long-term path.
- **WeakRef/FinalizationRegistry are easier under mark-sweep**, not
  harder. The original concern was inverted — mark phase already has
  reachability info; weak refs just get checked during sweep.

**What we're explicitly accepting:**
- **Pauses.** Single-generation stop-the-world means full-heap mark
  every cycle. For small heaps and interpreter-bound workloads this is
  microseconds. For larger heaps it becomes noticeable — but by then
  we'll have profile data to drive the generational evolution.
- **More code than refcount.** ~300 LOC for mark-sweep vs ~150 for
  refcount + ~200 for cycle collector. Net wash, and the mark-sweep
  code is more reusable.

**Evolution path:**
1. Single-space mark-sweep (this phase)
2. Add generations (young / old) + write barriers when allocation rate exceeds GC throughput
3. Incremental marking when pauses become noticeable
4. Concurrent marking when incremental isn't enough
5. Compaction when fragmentation becomes a problem

We commit to (1) now. (2)–(5) are each their own future plan.

**Reconsider if:**
- Allocation rate ends up extreme and mark pauses dominate — then jump straight to generational rather than incrementalizing.
- Cycle-free workloads dominate forever (unlikely in modern JS) — then refcount looks better in retrospect. Acceptable risk.

**Refs:**
- `hermes/include/hermes/VM/HadesGC.h:37-51` — the long-term target
- `WebKit/Source/JavaScriptCore/heap/` — JSC's GC
- For the v0 implementation: any introductory tracing-GC writeup; the design space here is well-understood. The interesting choices are layout, not algorithm.

---

## 8. Strings — Latin-1 / UCS-2 dual storage + atom interning

**Recommendation:** `JSString` carries an `is_wide : 1` flag — bodies
are `uint8_t*` (Latin-1) or `uint16_t*` (UCS-2). Never UTF-8 internally.
Property names and identifiers go through an `Atom` table — a runtime-wide
hash that maps a string to a 32-bit ID; subsequent identity comparisons
are integer compares. No ropes in v0.

**Why:**
- **Latin-1/UCS-2 is what JS specs as `String`** (16-bit code units). UTF-8 internally forces every `.length` and `s[i]` to walk the
  string. QuickJS spells this choice out (`quickjs.c:517-534`) and it's why their per-character ops are constant-time.
- **Atom interning everywhere a property name appears.** Hermes uses `LENGTH_FLAG_UNIQUED` as a per-string marker
  (`StringPrimitive.h:84-98`); QuickJS uses a separate `JSAtom` u32 (`quickjs.c:244-248`). Both make property lookup an `int ==
  int` compare against a slot tag instead of a `memcmp`.
- **No ropes in v0.** Hermes's `BufferedStringPrimitive` (the rope-equivalent) is only used for chained `concat ≥ 256 chars`
  (`StringPrimitive.h:30-125`). Profile first; the common short-string case is flat-buffer and benefits zero from ropes.

**Reconsider if:**
- We end up running concat-heavy benchmarks (template strings in tight loops, big JSON building) → add ropes as a tag
  variant (QuickJS's `JS_TAG_STRING_ROPE`).
- We need UTF-8 round-trip without surrogate pair fidelity → unlikely; the spec is 16-bit and that's what hosts expect.

**Refs:**
- `quickjs/quickjs.c:517-534` — dual storage
- `hermes/include/hermes/VM/StringPrimitive.h:30-125` — subclass hierarchy
- `quickjs/quickjs.c:244-248` — atom table

---

## 9. AOT bytecode bundle — mmap-ready, zero-copy load

**Recommendation:** Define a `.zjsbc` bundle format from the *first
working interpreter*. Structure (cribbed from Hermes's `.hbc`): fixed
header with magic + section offset table → function metadata →
string-kinds RLE → identifier hashes → string offset table → string
storage blob → array-buffer constants → bytecode functions → footer
with file hash. Sections aligned to page boundaries; the loader does
`mmap()` and casts. No parsing at runtime.

**Why this should land early, not late:**
- **Highest-leverage perf decision for embedded scenarios.** Cold-start time for embedded JS is dominated by parse+compile.
  Hermes ships `.hbc` and skips both phases at load.
- **Forces clean boundaries.** Having to serialize bytecode + strings + constants disciplines the in-memory representations.
  If you can't `mmap()` the bytecode, your CodeBlock has hidden mutable state that probably shouldn't be there.
- **Plays directly with §5 (ICs).** ICs live in the per-instance MetadataTable, never the bytecode → the bytecode pages stay
  read-only and shareable across realms.
- **Plays with §11 (runtime layer).** A `.zjsbc` artifact is what a future build tool like `zjsc` produces; the runtime layer's
  CLI can just `mmap` and run.

**Bundle format specifics (Hermes-derived):**
- Magic: pick our own constant (the user's `popaprozac` org gives us liberty here — something like `0x7A6A73`-padded).
- Little-endian only — no host portability needed at runtime; cross-compile is the answer.
- Identifier strings deduped + interned at build time (Hermes's "uniqued" flag).
- Section order chosen so the runtime's hot pages are the first read.
- SHA1 (or BLAKE3) footer for integrity.

**Reconsider if:**
- We add a JIT and the JIT wants to write back into the file (it shouldn't — keep tier-specific data in side tables).
- Embedders need to ship bundles that work across host endianness (rare; we'll cross-compile).

**Refs:**
- `hermes/include/hermes/BCGen/HBC/BytecodeFileFormat.h:27-423` — the entire format definition
- `hermes/doc/Design.md:170-176` — rationale

---

## 10. Spec coverage — test262 from the first running interpreter

**Recommendation:** Wire test262 into the build as soon as the
interpreter can execute *any* expression. Even a 1% pass rate is
useful. Track pass-rate by feature area (functions, classes, async,
proxies, etc.) instead of overall — gives a clearer map of "where
should I work next."

**Why:**
- **You can't be "spec compliant and new-features friendly" without a dashboard.** test262 is the only objective signal.
- **It's free leverage.** The test262 harness is well-documented and there's prior art (Hermes, QuickJS, Boa all integrate it).
- **It catches regressions cheaply.** Easier than writing engine-specific tests for spec corners.

**Reconsider if:** never. This one's settled.

**Refs:**
- `https://github.com/tc39/test262`
- `quickjs/test262_*.txt` — exclude list patterns
- `hermes/test/test262/` — harness integration

---

## 11. Runtime layer — separate, txiki-modeled, deferred

**Recommendation:** Engine core (this project) stays pure ECMA-262.
A *separate* runtime layer — call it `zjs-runtime` for now — adds:
`fetch`, `WebSocket`, `Timers` (`setTimeout`/`queueMicrotask`),
`TextEncoder`/`Decoder`, `crypto.subtle`, `URL`. The runtime layer
consumes the engine's embed API like any external host. It's a
separate concern, separate plan, separate build artifact.

**Why now, even though we're not building it yet:**
- **It's load-bearing on embed-API design.** The engine needs to expose: (a) host functions that return promises and can be
  resolved asynchronously from outside the engine, (b) ArrayBuffer with external (host-owned) backing data, (c) hooks for
  draining the microtask queue when a libuv event lands, (d) threadsafe-function-style cross-thread completion. txiki.js
  has all of these. We need to make sure our `zjs.h` and our Bare libjs adapter (Phase 7) cover them.
- **It's the user's first use case** (per zapp/bare-js direction). The user explicitly cited txiki as a draw for that
  combination of engine + sensible defaults.
- **Studying txiki now informs the engine API.** Look at how txiki.js wires libcurl into `fetch`, libuv into Timers, etc.

**Reconsider if:** the engine API turns out to need redesign for this. Worth a check at the end of Phase 7 (Bare libjs adapter)
before committing to it.

**Refs:**
- `https://github.com/saghul/txiki.js` — the canonical reference
- `zapp/vendor/txiki.js` (if checked out locally) — for the integration patterns

---

## What zjs intentionally is NOT

- **Not a multi-tier engine.** No Sparkplug, no TurboFan, no Maglev, no DFG/FTL. A possible future JIT is a single optional
  tier-2, not a stack.
- **Not the smallest possible engine.** QuickJS owns that crown. We'd rather have a transition-tree object model and an
  IC side-table than save 100 KB.
- **Not a Hermes drop-in.** Different process model (not bound to React Native), different bytecode (we get to design it),
  different value rep (`OtherTag` bit > `ETag` for our use).
- **Not a research playground for novel GC algorithms.** Refcount + cycle collector to start. Mark-sweep when there's a
  measured reason. Generational when there's a measured reason. No premature concurrent or incremental work.
- **Not pretending iOS support comes for free.** iOS gets the interpreter; the JIT path is JIT-allowed-platforms only.

## Implementation order for Phase 2+

Decisions form a dependency graph. Build them in the order they unblock the next:

```
              ┌────────────────────────────────┐
              │  Phase 1 (this doc) — DONE     │
              └────────────────────────────────┘
                              │
                              ▼
        ┌─────────────────────────────────────────────┐
        │  Phase 2 — Value rep + lexer + parser        │
        │  (Decisions 1, 2 fixed before any execution) │
        └─────────────────────────────────────────────┘
                              │
                              ▼
        ┌─────────────────────────────────────────────┐
        │  Phase 3 — Bytecode compiler + interpreter   │
        │  dispatch tail-call shape verified           │
        │  (Decisions 2, 3, 4 + test262 harness)       │
        └─────────────────────────────────────────────┘
                              │
                              ▼
        ┌─────────────────────────────────────────────┐
        │  Phase 4 — Object model + ICs                │
        │  (Decisions 5, 6 land together — the IC      │
        │  scheme drives the hidden-class API)         │
        └─────────────────────────────────────────────┘
                              │
                              ▼
        ┌─────────────────────────────────────────────┐
        │  Phase 5 — GC                                │
        │  (Decision 7. Engine works before this,      │
        │  just leaks. That's fine for v0 dev.)        │
        └─────────────────────────────────────────────┘
                              │
                              ▼
        ┌─────────────────────────────────────────────┐
        │  Phase 6 — AOT bundle + strings + atoms      │
        │  (Decisions 8, 9. Strings overlap a lot      │
        │  with bundle format.)                        │
        └─────────────────────────────────────────────┘
                              │
                              ▼
        ┌─────────────────────────────────────────────┐
        │  Phase 7 — Bare libjs adapter                │
        │  (existing plan step. Engine ABI matures.)   │
        └─────────────────────────────────────────────┘
                              │
                              ▼
        ┌─────────────────────────────────────────────┐
        │  Phase 8 — Runtime layer (zjs-runtime)       │
        │  (Decision 11. txiki-modeled. Separate repo  │
        │  or top-level dir.)                          │
        └─────────────────────────────────────────────┘
                              │
                              ▼
        ┌─────────────────────────────────────────────┐
        │  Phase 9 — JIT (only if/when motivated)      │
        └─────────────────────────────────────────────┘
```

## Open questions left for the relevant phase

- **Bytecode endianness for the bundle** — pick one (LE) and don't byteswap. Decided here. The bigger question is
  what magic constant to use; defer to bundle implementation.
- **Microtask queue ownership** — the engine owns it for correctness, but the runtime layer needs a hook to drain it
  on event-loop ticks. API shape: TBD when runtime starts.
- **WeakRef + FinalizationRegistry** — straightforward under mark-sweep (weak slots checked during sweep). Spec details to walk when the time comes.
- **Symbol representation** — sub-question of §1; defer until we hit Symbol-using code in test262.
- **Source-map / debug-info story** — Hermes ships a separate debug-info section in `.hbc`; we'll want one. Defer to bundle phase.
- **Whether to write our own dtoa or use Bellard's** — QuickJS uses a heavily-modified `dtoa`. Probably copy.

## File-reference index — prior art bookmarks

**Hermes** (`github.com/facebook/hermes`)
- Bytecode layout: `include/hermes/Inst/Inst.h`, `include/hermes/BCGen/HBC/BytecodeList.def`
- Bundle format: `include/hermes/BCGen/HBC/BytecodeFileFormat.h`
- Interpreter: `lib/VM/Interpreter.cpp` (~3700 lines, computed-goto + switch fallback)
- Value rep: `include/hermes/VM/HermesValue.h`
- Object model: `include/hermes/VM/HiddenClass.h`, `include/hermes/VM/JSObject.h`
- GC (target end-state): `include/hermes/VM/HadesGC.h`
- IC: `include/hermes/VM/PropertyCache.h`, `include/hermes/VM/CodeBlock.h`
- Design doc: `doc/Design.md`

**QuickJS** (`github.com/bellard/quickjs`)
- One file: `quickjs.c` (~60K lines — read the structure, not the whole)
- Opcode list: `quickjs-opcode.h`
- Public API: `quickjs.h`
- Value rep: `quickjs.h:144-231`
- Object model / shapes: `quickjs.c:910-925, 4730-4760`
- Cycle collector: `quickjs.c:6009-6023`

**JSC LLInt** (`github.com/WebKit/WebKit`)
- Asm interpreter: `Source/JavaScriptCore/llint/LowLevelInterpreter.asm`, `LowLevelInterpreter64.asm`
- Bytecode DSL: `Source/JavaScriptCore/bytecode/BytecodeList.rb`
- IC metadata: `Source/JavaScriptCore/bytecode/MetadataTable.h`, `GetByIdMetadata.h`
- Value rep: `Source/JavaScriptCore/runtime/JSCJSValue.h`
- CLoop fallback: `Source/JavaScriptCore/offlineasm/cloop.rb`

**txiki.js** (`github.com/saghul/txiki.js`) — for Phase 8 (runtime layer) reference. Not for engine-core decisions.

---

*This doc is a starting point. Every recommendation here is fair game to revisit once the next phase produces code that talks back.*
