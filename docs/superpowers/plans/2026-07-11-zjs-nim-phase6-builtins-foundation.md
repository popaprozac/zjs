# ZJS Nim Phase 6 — Built-ins Foundation (slot registry + native fns + console.log/dtoa)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.
> This is the FOUNDATION of Phase 6 (built-in intrinsics). Byte-identical/exact-match
> discipline holds: `nim-disasm` must match `build/zjs disasm` byte-for-byte and `nim-eval`
> must match `build/zjs eval`, OR bail cleanly — NEVER emit wrong bytecode / a wrong value.
> All work on `nim-phase4` (→ `nim`); **never touch `main`**. Only edit `nim/`, `docs/`,
> additive `nim-*` Makefile targets. This is a PORT of the shipped Zen-c design.

**Goal:** the mechanism that lets built-in intrinsics exist — a compiler builtin-global **slot
registry** matching Zen-c's exact g0–g107 assignment, a **native-function representation + call
path** in the VM, and the first natives (`console.log`) with real number formatting (**dtoa**).
This resolves the dominant remaining disasm-parity blocker (builtins numbered as user globals)
and unblocks every subsequent intrinsic slice.

**Architecture:** three differential-gated slices. Slice 1 is compiler-only (slot numbering).
Slice 2 adds the runtime native mechanism. Slice 3 wires the first user-visible native + dtoa.

---

## Recon findings (already gathered — do not re-derive)

**Builtin globals are slot bindings, not globalThis own-props.** Zen-c stores standard builtins
in the realm's slot table (`realm.globals[slot]`, the DeclarativeRecord half), interned in a
FIXED registration order at realm init. User code starts at **g108** (`USER_GLOBAL_BASE`).
`getOwnPropertyNames(globalThis)` shows only the runtime-layer object-props (`process`, `Blob`,
…) — NOT the builtins. Probe the slot for a name via `disasm` of `var __=NAME;` → the
`LoadGlobal … ; NAME` slot.

Partial map already probed (authoritative extraction is slice-1 step 1):
```
g0 globalThis  g1 Error  g2 NaN  g3 Infinity  g5 isNaN  g6 isFinite  g7 parseFloat
g8 parseInt  g9 Array  g10 Boolean  g11 Number  g12 String  g13 ReferenceError
g14 TypeError  g15 RangeError  g17 Function  g18 Date  g19 RegExp  g20 Symbol
g23 Map  g24 Set  g25 WeakMap  g26 WeakSet  g27 Proxy  g28 Reflect  g29 Promise
g30 ArrayBuffer  g31 Uint8Array  g32 Int8Array  g33 Uint8ClampedArray  g34 Int16Array
g35 Uint16Array  g36 Int32Array  g37 Uint32Array  g38 Float32Array  g39 Float64Array
g40 DataView  g41 BigInt  g42 BigInt64Array  g43 BigUint64Array  g49 WeakRef
g50 FinalizationRegistry  g51 EvalError  g52 URIError  g53 SyntaxError  g54 AggregateError
g56 Math  g57 Object  g58 JSON  g59 Temporal  g60 console  g61 queueMicrotask
g66 escape  g67 unescape  g68 encodeURI  g69 encodeURIComponent  g70 decodeURI
g71 decodeURIComponent  g89 structuredClone
```
Gaps (g4, g16, g21–22, g44–48, g55, g62–65, g72–88, g90–107) are un-probed builtin names
(`eval`, timers, codecs, `TextEncoder`, `URL`, `crypto`, well-known-symbol holders, etc.).
`Atomics`/`Intl`/`SharedArrayBuffer` are ABSENT in Zen-c (resolve to a user slot) — do NOT
register them. **The complete authoritative map is extracted in slice 1 from the ordered
registration in `src/context.zc` (the `ctx_register_host_function` / global-define sequence).**

**Host-function representation (Zen-c, `src/context.zc:3993`):** a `ZjsHostFunction` cell,
`type_tag = TAG_HOST_FUNCTION`, fields `fn_ptr` (C signature
`ZjsValue (*)(ZjsContext*, ZjsValue* args, uint32_t argc)`), `name`, `proto_override`,
`is_constructor`, `realm`. `ctx_register_host_function(name, fn)` creates it + stashes in a
global slot; `ctx_make_host_function(name, fn)` creates it WITHOUT a slot (for object
properties like `Math.abs`). `.length`/constructability come from the arity variant.

**Nim VM call path (`nim/src/zjs/vm.nim`):** registers are a `VmVal` variant —
`vkVal(ZjsValue)` / `vkString` / `vkFunction(fn: Function, env)`. **No native case yet.**
`vmGlobals: seq[VmVal]` is the slot array (threadvar). `Invoke`/`InvokeGlobal`/`MethodInvoke`/
`NewInvoke` dispatch on a `vkFunction` callee (push a JS frame). A native callee needs a new
representation + a new dispatch arm that calls the Nim proc instead of pushing a frame.

---

## Slice 1 — builtin-global slot registry (compiler-only)

**Files:** `nim/src/zjs/compiler.nim` (global interning); a new `nim/src/zjs/builtins_globals.nim`
(the name→slot table) or a const table in compiler.nim.

**Step 1 — extract the authoritative g0–g107 map.** From `src/context.zc`, read the ordered
realm-init registration sequence (grep `ctx_register_host_function` / `ctx_intern_global` /
`ctx_define_global*` calls in init order) AND cross-check every entry empirically:
```
for b in <name>; do printf 'var __=%s;' "$b" > /tmp/p.js
  build/zjs disasm /tmp/p.js 2>/dev/null | awk -v n="$b" '/LoadGlobal/&&$0~("; "n"$"){for(i=1;i<=NF;i++)if($i~/^g[0-9]+$/){print substr($i,2),n;exit}}'
done | sort -n
```
Fill EVERY gap g0–g107 (probe candidate names: `eval`, `setTimeout`, `setInterval`,
`clearTimeout`, `clearInterval`, `setImmediate`, `atob`, `btoa`, `TextEncoder`, `TextDecoder`,
`URL`, `URLSearchParams`, `fetch`, `Headers`, `Request`, `Response`, `AbortController`,
`AbortSignal`, `Event`, `EventTarget`, `performance`, `crypto`, `WebAssembly`, `Iterator`,
`gc`, `print`, …). The table must reproduce Zen-c's map EXACTLY; a missing/wrong entry =
divergent disasm.

**Step 2 — consult the table in `internGlobal`.** When the compiler interns a global name,
FIRST look it up in the builtin table: a hit returns the fixed builtin slot; a miss allocates
the next user slot at/after g108 (current behavior). This mirrors `ctx_intern_global` — Zen-c
pre-registers builtins so their slots are already assigned before user code interns anything.
The user-slot counter must still START at 108 (do not renumber user globals).

**Oracle / targets:** disasm parity on builtin-referencing programs — the diffs that were
"builtin-slot gap" now vanish:
```
diff <(build/zjs disasm t) <(build/nim/nim-disasm t)   # t references isNaN/String/Math/Object/JSON/…
```
Byte-identical for: `var x=isNaN;`, `String(1)` (disasm only — eval still bails, no runtime value
yet), `Math.floor`, `Object.keys`, `JSON.stringify`, `console.log`, mixed user+builtin
(`var f=Object; var g=f;` → Object=g57, f=g108, g=g109). Re-run the test262 incr/decr + broad
sweeps: the ~72 builtin-slot `text_diff`s should drop toward 0. NOTE: eval of these still bails
(the slot has no value until slice 2) — that is correct; slice 1 is disasm-only.

---

## Slice 2 — native-function representation + call path (runtime)

**Files:** `nim/src/zjs/gc.nim` (a HostFunction cell OR reuse FunctionCell with a native marker),
`nim/src/zjs/vm.nim` (VmVal native case, install-into-globals, Invoke dispatch), a
`nim/src/zjs/builtins.nim` (the native registration table).

**Step 1 — native representation.** Port `TAG_HOST_FUNCTION`: a GC `HostFunctionCell`
(CellHeader + a Nim proc pointer + name + arity + isConstructor), boxed to a `ZjsValue`
(so it lives uniformly in a global slot AND as an object property later, like Zen-c). Native
proc signature (Nim analogue of `(ctx, args, argc) -> ZjsValue`):
`proc(heap: var GcHeap, args: openArray[VmVal], thisv: VmVal): VmVal`. Add a VmVal path:
either a `vkNative` case OR unbox the cell in `resolveCallee`. Mark it in `markVmVal`/`markCell`
(leaf — the proc pointer isn't a GC cell; name is host memory).

**Step 2 — registration + install.** A table `[(slot, name, proc, arity, isCtor)]` for the
natives implemented so far. At VM init (where `vmGlobals` is sized), install each into
`vmGlobals[slot]`. Sizing: `vmGlobals` must cover g0..(maxUserSlot) — builtin slots are < 108,
so ensure the array is ≥ 108 + user count and pre-seeded with the natives; unregistered builtin
slots (no native yet) stay `undefined` (referencing them bails/undefined exactly as an
unimplemented builtin should).

**Step 3 — call dispatch.** In `Invoke`/`InvokeGlobal`/`MethodInvoke`/`NewInvoke`, when the
callee resolves to a native: marshal the argument registers into `openArray[VmVal]`, call the
proc with `thisv`, place the returned `VmVal` in the destination register. Do NOT push a JS
frame. Respect the fused carriers exactly as the JS-callee path does. `new`-invoking a native
and `.length`/name introspection can bail cleanly for now (later slice) — but a plain call must
work.

**Validation:** register ONE trivial probe native (e.g. a temporary `__nativeId(x)` returning
its arg, or reuse a real one) and assert `nim-eval` calls it and returns correctly. No disasm
change (calls already compile to Invoke/InvokeGlobal). Keep the probe only if it maps to a real
Zen-c builtin slot; otherwise remove before commit and validate via slice 3's `console.log`.

---

## Slice 3 — `console.log` + dtoa (first user-visible native + real number output)

**Files:** `nim/src/zjs/dtoa.nim` (new — port `js_double_to_chars`), `nim/src/zjs/builtins.nim`
(`console` object + `log`), `nim/tools/nim_eval.nim` (completion-value double formatting),
`nim/src/zjs/vm.nim` (number→string uses dtoa).

**Step 1 — dtoa.** Port Zen-c's `js_double_to_chars` / `zjs_double_to_chars` (the `%g`-family
shortest-round-trip formatter). Non-integer doubles, large/small magnitudes (`5e+11`), `-0`,
`Infinity`/`NaN` must match `build/zjs eval` byte-for-byte. Oracle:
```
for v in 3.14 0.1 5e11 1e-7 -0 123456789012345 0.0001 1/3; do
  diff <(build/zjs eval "$v") <(build/nim/nim-eval "$v"); done
```
This also flips the completion-value formatter (the current inspect only handles int-valued
doubles) and any string coercion that produces a non-integer number.

**Step 2 — `console` object + `log`.** Register `console` at its builtin slot (g60) as an object
with a `log` native property (via the make-as-property path). `console.log(...args)` formats each
arg (reuse the `inspectValue` formatter, but TOP-LEVEL strings print UNQUOTED — Node/zjs
`console.log("hi")` → `hi`, not `"hi"`) joined by spaces, writes a line to stdout. Match
`build/zjs eval 'console.log(...)'` output byte-for-byte (capture zjs's exact separator, nested
formatting, and trailing newline).

**Oracle / targets:** exact-match `nim-eval` vs `zjs eval`:
```
console.log("hello")                 -> hello
console.log(1, 2, 3)                 -> 1 2 3
console.log({a:1,b:[2,3]})           -> { a: 1, b: [ 2, 3 ] }   (match zjs's exact spacing)
console.log(3.14)                    -> 3.14
console.log(true, null, undefined)
var s=0; for(var i=0;i<3;i++){ console.log(i); } s
```
Plus the dtoa battery. Run the broad corpus sweep — `console.log`-driven test262 harness output
(`$DONE`, `print`) should start matching where it previously bailed.

---

## Validation (whole foundation)

- Per slice: `rm -f build/nim/nim-* && make nim-disasm nim-eval` (stale binaries lie) → disasm
  and/or eval differential + the existing suites (tgc/tvm/tcompiler/tparser) with zero
  regressions. `text_diff`/`wrong_result` must be 0; unimplemented → clean bail.
- Foundation done when: builtin references disasm byte-identical (slice 1), natives call
  correctly (slice 2), and `console.log` + non-integer numbers eval byte-identical (slice 3).
- This unblocks the **core-intrinsics** arc (Object/Array/Function/String/Number/Math/JSON/Error/
  Symbol) — each an additive native-registration slice on this foundation — and then the test262
  **execution** differential becomes the whole-engine oracle.

## Follow-ups (explicitly deferred)
- `new`-invoking natives, native `.length`/`.name` introspection, `Function.prototype` on natives.
- Well-known-symbol builtin slots + the runtime-layer globals (timers/fetch/codecs) — Ring 2/3.
- The captured-top-level-lexical env-promotion compiler-fidelity gap (tracked from Phase 3).
