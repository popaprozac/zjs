# zjs — Realm Refactor Design (Runtime / Realm split)

> Decision-capture for giving zjs **multiple realms sharing one heap** — the
> `JSRuntime` / `JSContext` model QuickJS already uses. Unblocks `$262.createRealm`
> (test262), **ShadowRealm** (TC39 stage 3), and `node:vm`, and closes the
> "is this a serious engine?" architectural gap vs our peer QuickJS.

## Why — and the correction to the earlier "defer" call

An earlier note in [`project_longterm_plays`] / the JIT design study called
cross-realm **"architecturally prohibitive, defer."** That was too strong, and
it rested on a **wrong premise**: it treated realms as *separate heaps* and
worried that cross-realm references would break zjs's NaN-boxed GC ownership.

**That is not how realms work.** The canonical model — QuickJS's — is:

- **`JSRuntime`** owns the **heap, GC, and atom/string-intern table**.
- **`JSContext`** is a **realm**: its own global object + its own intrinsics
  (`Object.prototype`, `Array`, the error constructors, …).
- **Many `JSContext` share one `JSRuntime`.** An object created in realm A and
  referenced from realm B is fine — they live in **one shared heap**. No
  ownership problem. quickjs-ng's ShadowRealm is built directly on this.

zjs's `ZjsContext` today **conflates runtime and realm** — it holds the heap +
GC *and* the globals + intrinsics as singletons. That conflation is the only
real obstacle, and the fix is exactly the split QuickJS already shipped. So:
**not prohibitive — a real but well-trodden refactor a sibling engine has
already validated.** This doc supersedes the "defer" call.

### Three reasons not to punt it (the user's instinct, made concrete)
1. **Credibility / peer-parity.** QuickJS — the engine zjs is most directly a
   peer to — has realms. ShadowRealm is stage 3. Lacking the *architecture*
   (not just the ~130 tests) reads as "toy."
2. **Calcification.** Every feature that writes `ctx.array_proto` deepens the
   singleton assumption. ~423 such intrinsic references exist today; the count
   only grows.
3. **JIT timing — the clincher.** The JIT design study's own revisit-trigger:
   *"before finalizing the JIT's intrinsic-speculation design, so realm-keying
   is a known guard extension, not a retrofit."* The JIT is approaching. Realms
   **after** a JIT that bakes in singleton intrinsic speculation = pay twice.
   Doing the split **before** JIT implementation is the cheap window — now.

## What the tagged representation already gives us for free

A pleasant consequence of NaN-boxing + distinct cell tags: **brand checks are
realm-agnostic by construction.** `Array.isArray(x)` tests `TAG_ARRAY`, not
`x`'s prototype identity — so it already returns the spec-correct answer for an
array from *another* realm. Same for `typeof`, the internal-slot brand checks
(Map/Set/Promise/Date/…), and JSON/ToString tag dispatch. The cross-realm tests
that fail today fail for lack of a *second realm to construct*, not because the
brand machinery is realm-coupled. This meaningfully shrinks the precision tail.

## The split — concrete field partition of `ZjsContext`

### `ZjsRuntime` (shared heap + engine state; one per agent)
- **Heap / GC**: `cells`, `young_cells` (+ counts/caps), `slot_pool`/`attr_pool`/
  `obj_pool` freelists, `rem_set`, all `gc_*` stats + thresholds,
  `cells_since_*`.
- **Shape graph root**: `empty_class` (hidden classes are heap-level, shared).
- **Atom / string intern table** (interning is global to the heap).
- **Global Symbol registry** (`Symbol.for`/`keyFor` — per spec this is shared
  ACROSS realms: `Symbol.for("x")` in two realms is the *same* symbol).
- **Job queue**: `microtask_queue` (one per agent, shared across realms).
- **VM execution state** (one running execution): `reg_stack`, `frames`,
  `temp_roots`, `roots`, `root_frames`, `ctx_try_stack`, `pending_throw_*`,
  `host_this`, `new_target_*`, `current_closure`, `with_objs`/`with_count`,
  `invoke_arg_buffer`, `active_compiler`, `write_rejected`, `had_error`.
- **Runtime-wide optimization flags**: `any_proxy_alive`, `any_exotic_proto`.
- **`current_realm: ZjsRealm*`** — the realm of the currently-executing code
  (set on call, see below). This is the new field that makes intrinsic lookups
  realm-correct.
- **`realms: ZjsRealm**`** — list of all live realms (for GC roots).

### `ZjsRealm` (per-realm globals + intrinsics)
- `globals` (+ count/cap), `global_this_obj`.
- Every intrinsic prototype/constructor: `object_proto`, `array_proto`,
  `function_proto`, `string_proto`, `fn_call_v`, `fn_apply_v`,
  `promise_ctor_proto`, `regexp_proto`, `generator_proto`, `map_proto`,
  `set_proto`, `weakmap_proto`, `weakset_proto`, `date_proto`, `symbol_proto`,
  `url_proto`, `usp_proto`, the 9 TypedArray protos, `array_buffer_proto`,
  `data_view_proto`, `typed_array_proto`, `typed_array_ctor`, `websocket_proto`,
  and the rest of the `*_proto` / `*_ctor` family.

The mechanical heart of the refactor is moving the ~423 `ctx.<intrinsic>`
references to a realm-scoped access (see Phase 1).

## Which realm does an operation use?

This is the subtlety the cross-realm tests actually check.

- **Most built-in algorithms** use the **current realm** (the running function's
  `[[Realm]]`) — e.g. an error thrown by `Array.prototype.X` is constructed with
  the *current* realm's `%TypeError%`.
- **`[[Realm]]` is captured per function** at creation. On invocation, the
  runtime saves `current_realm`, sets it to the callee's realm, restores on
  return. (Closures/Function* gain a `realm` field; host functions too.)
- **Species / `OrdinaryCreateFromConstructor`** derive the realm from a *specific
  object's* constructor (`ArraySpeciesCreate` uses the receiver's constructor's
  realm), not the current realm — these are the per-operation precision cases.
- **`new` from a cross-realm constructor**: `[[Prototype]]` comes from
  `Get(newTarget, "prototype")` — already realm-correct because it reads the
  actual constructor's `.prototype` value.

## GC over realms

The heap is shared (one runtime). The collector's root scan iterates **all
realms** in `runtime.realms`, marking each realm's `global_this_obj`, globals
table, and intrinsic protos — plus the (unchanged) VM stacks/temp-roots. Because
references are intra-heap, a cross-realm edge is an ordinary mark edge; nothing
about the non-moving mark-sweep or the generational young/old split changes.
A realm is collectable when unreachable (ShadowRealm GC) — a later refinement;
v1 can keep realms alive for the runtime's lifetime.

## Phasing — keep `make cli` + test262 green at every step

0. **Introduce `ZjsRealm` as a thin wrapper that IS today's singleton.** `ctx`
   owns exactly one realm (`ctx.realm`). Behaviorally identical. Establishes the
   type + accessors.
1. **Mechanically migrate the ~423 `ctx.<intrinsic>` → `ctx.realm.<intrinsic>`.**
   Large but behavior-neutral; gate in batches by subsystem (object/array/TA/
   Promise/…). Zero conformance delta expected per batch.
2. **Split heap state into `ZjsRuntime`** (or keep `ZjsContext` as the runtime
   and let it own `current_realm` + `realms[]`). GC root scan iterates realms.
   Still one realm → behavior-neutral.
3. **Thread `[[Realm]]`**: function/closure/host-fn gain a `realm`; call sites
   save/restore `runtime.current_realm`; intrinsic lookups (`new Array`, error
   ctors, `%TypedArray%`, species) read `current_realm` (or the operand's realm).
   Still one realm → behavior-neutral, but now realm-correct *by construction*.
4. **`createRealm`**: factor the intrinsic bootstrap (`ctx_init_builtins`) so it
   populates a *given* `ZjsRealm`; add `runtime_new_realm()` that builds a fresh
   realm on the shared runtime. Expose `$262.createRealm()` → `{ global,
   evalScript, … }` in the test262 harness object (also the natural seam for a
   future `ShadowRealm` / `node:vm`).
5. **Cross-realm precision**: walk the failing cross-realm test262 with real
   realms now constructable — fix the per-operation realm-selection cases
   (species, error ctors, `%ThrowTypeError%` identity, iterator protocols).
   This is where the ~130 tests actually convert.

Phases 0–3 are behavior-neutral plumbing (the bulk, gateable at zero delta);
the conformance payoff arrives at 4–5.

## Cost / risk — honest

- **Biggest structural refactor on zjs's board** — a multi-session arc, not a
  commit. Touches bootstrap, every intrinsic access, and the GC root set.
- **But mostly mechanical** once the struct split + accessor exist (Phase 1 is
  find/replace-shaped), and **de-risked by phasing** — every phase keeps the
  suite green, and Phases 0–3 add zero behavior.
- **The tagged-brand property** (above) removes a whole class of would-be
  cross-realm bugs.
- **Binary size**: `ZjsRealm` is one allocation per realm; the single-realm
  common case grows by one pointer indirection on intrinsic access (negligible;
  `ctx.realm` is hot and cached).

## Sequencing recommendation

**Slot this as the next major architectural arc, interleaved with the
conformance push and landed BEFORE JIT implementation.** Rationale: it's the
credibility/peer-parity item; it's materially cheaper before the JIT bakes in
intrinsic speculation; and Phases 0–3 are low-risk plumbing that can proceed
while conformance grinding continues on the side. The JIT's already-documented
"identity/shape-guard, never a singleton" principle becomes *load-bearing* once
realms exist — which is the point.

## Open questions (resolve in the relevant phase)
- Keep `ZjsContext` as the runtime (minimal renames) vs introduce a distinct
  `ZjsRuntime` type? (Lean: keep `ZjsContext` = runtime, add `ctx.realm` +
  `ctx.realms[]` — smallest diff.)
- Where exactly does `current_realm` get saved/restored — only at the unified
  call boundary, or also at `new`/Reflect.apply/proxy-trap entries? (Audit the
  call sites that today read `ctx.<intrinsic>`.)
- Realm GC lifecycle for ShadowRealm (collectable realms) — defer past v1?
- `node:vm` surface vs `$262.createRealm` vs `ShadowRealm` — one internal
  `runtime_new_realm` primitive, three public skins. Build the primitive first.

## Refs
- **QuickJS** `JSRuntime` / `JSContext` (the model); **quickjs-ng** ShadowRealm.
- ECMA-262 §9.3 Realms, §9.6 `InitializeHostDefinedRealm`; the ShadowRealm
  proposal; test262 `$262.createRealm` (harness `sta.js`/`$262`).
- In-repo: [`jit-design-study.md`](./jit-design-study.md) (the realm-aware guard
  principle this makes load-bearing), [`jitless-design-study.md`](./jitless-design-study.md),
  [`gc-experiment.md`](./gc-experiment.md) (the shared heap this extends).
