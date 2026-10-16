# zjs Phase 3.1d — Mark-Sweep Garbage Collection

> Replaces the per-context "every cell stays alive until
> zjs_free_context" model with a real tracing collector. Brings the
> engine into line with the design study (Hermes-direction: simple
> stop-the-world mark-sweep first; generational and concurrent later
> if there's measured demand).

## Scope

In scope:
- `mark: u8` bit added to `CellHeader`
- Per-context GC state: growable root-frame stack, allocation threshold
- `interpret()` pushes its `regs` as a root frame at entry, pops on exit
- `gc_mark_value` walks a cell graph transitively (objects, arrays, functions, strings; host functions have no children)
- `gc_sweep` walks `ctx.cells`, frees unmarked cells (dispatched by `type_tag`), compacts the live list
- Trigger: at the top of every dispatch-loop iteration, if `cells_since_gc >= gc_threshold`. Threshold adapts to `2 × live_count` after each collection (prevents thrashing on growth)
- Public C ABI additions:
  - `void zjs_gc(ZjsContext* ctx)` — manual collection (for tests + diagnostics)
  - `unsigned int zjs_cell_count(ZjsContext* ctx)` — live cell count

Out of scope (later):
- **Atom interning** — string deduplication. Would speed up property-name compare on object lookup; deferred until a profile says it matters.
- **Incremental / concurrent marking** — stop-the-world is fine for the program sizes we hit.
- **Generational collection** — comes once we have a measured allocation-rate problem.
- **Compaction** — sweep keeps existing addresses; no objects move. Fragmentation is the trade-off.
- **Write barriers** — none needed without generations.

## Roots

The root set for a GC pass is:
1. Every value in `ctx.globals[]`
2. `ctx.last_error`
3. Every register file currently on the active call chain — i.e., one frame per active `interpret()` invocation
4. Constants pools of every reachable `Function` (reached transitively from the above)

(3) is the load-bearing addition. We add a `GcRootFrame { regs, reg_count }` stack to the context. Each `interpret()` call pushes on entry, pops on exit via `defer`. Recursion depth = JS call depth, so the stack grows dynamically.

## When GC runs

Only at instruction boundaries. The dispatch loop checks at the top:

```
while ip < f.code_len {
    if cells_since_gc >= gc_threshold { gc_run(ctx); reset; }
    if throwing { ... unwind ... }
    let inst = f.code[ip];
    ...
}
```

This is safe because at instruction boundaries, every live value is
either in a register (rooted via the active frame), in globals, or
reachable transitively from those.

Crucially, GC does *not* run during:
- Compilation (the compiler allocates string cells for property names; those need to be reachable via the constants pool which only finishes population after the Function is fully built; running GC mid-compile would collect them)
- Inside a single instruction (host functions allocate cells while returning, etc.)

## Verification

`zjs_gc` + `zjs_cell_count` enable direct test assertions:

```c
ZjsContext* ctx = zjs_new_context();
unsigned initial = zjs_cell_count(ctx);

/* Generate garbage: each iteration creates a fresh string that's
 * immediately unreachable when the next assignment overwrites it. */
for (int i = 0; i < 1000; i++) zjs_eval(ctx, "let s = 'iter' + 99");

unsigned high = zjs_cell_count(ctx);
zjs_gc(ctx);
unsigned after = zjs_cell_count(ctx);

assert(high > initial);   /* cells did accumulate */
assert(after < high);     /* gc freed some */
```

`make test` continues green; cell counts drop after manual GC.

## What's next

- **Phase 3.1f** — atom interning, more built-ins (`Object.keys`, `Array.prototype.push`, `String.prototype.indexOf`, ...). Both grow the test262 pass rate.
- **Phase 3.2** — prototype chain (so `instanceof` works), function-with-properties (so real `assert` works), `console.log`.
- **Phase 3.3+** — JIT, eventually.
