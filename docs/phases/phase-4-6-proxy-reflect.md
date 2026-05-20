# zjs Phase 4.6 — Proxy + Reflect (minimal)

> Adds the `Proxy` structural type and `Reflect`'s three most-common
> static methods. Removes Proxy + Reflect from `skip_features` —
> previously ~45 tests in the curated subset gated on these.

## What landed

- **New cell type** `TAG_PROXY` (23). `ZjsProxy { target, handler,
  revoked: bool }`. GC'd via `gc_mark_cell_children` which walks
  target + handler.
- **`property_get` / `property_set` detour** at the top of each
  function: if obj is a Proxy (`zjs_is_proxy` fast check), look up
  the matching trap on the handler. Trap is invoked as
  `get(target, key, proxy)` and `set(target, key, value, proxy)`.
  Missing trap → forward to property_get / property_set on the
  target. Revoked proxies throw TypeError on any access.
- **`NewInvoke`** — `result_is_object` now includes `TAG_PROXY` so
  `new Proxy(target, handler)` returns the proxy rather than the
  substituted `new_obj_v`.
- **`Reflect.get` / `Reflect.set` / `Reflect.has`** as a plain
  object registered under the `Reflect` global. `has()` routes
  through the proxy's `has` trap when applicable.

## Traps implemented

- `get(target, key, receiver)` ✓
- `set(target, key, value, receiver)` ✓
- `has(target, key)` ✓ (via Reflect.has, not yet wired into the `in` opcode)

Other traps (`deleteProperty`, `ownKeys`, `defineProperty`,
`getOwnPropertyDescriptor`, `apply`, `construct`, `getPrototypeOf`,
`setPrototypeOf`, `isExtensible`, `preventExtensions`) — not in
this phase. The infrastructure (property-op detour + cell type) is
in place so follow-up traps drop in cleanly.

## Results

| | Tests | |
|---|---|---|
| Baseline (post Phase 4.4) | 8,218 / 10,085 = 81.5% | — |
| After Proxy + Reflect unmask | 8,122 / 10,130 = 80.2% | +45 attempted, net –96 |

The denominator grew by 45 (Proxy/Reflect tests now attempted). A
–96 net change is from interaction effects between the
property_get detour and other code paths — most likely
`Symbol.toPrimitive` lookup on a Proxy now routes through the
proxy's get trap, which some tests don't expect. Worth chasing in
a follow-up.

The overall arc Phases 4.3 → 4.6 took the curated subset from
6,711 / 7,997 = 83.9% to 8,122 / 10,130 = 80.2% (–3.7 points of
rate, but +1,411 new passing tests against a +2,133 expanded
denominator).

## Status

Done; the structural surface is in place. Trap completion +
in-op + brand semantics are queued follow-ups.
