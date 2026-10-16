# Prior art

Kept for reference, not developed.

- `zen-c/` — the engine ZJS began as, written in Zen-c: its sources,
  build, tests, docs, and type declarations, moved here unchanged when the
  Z engine took the root (2026-10-15). The Z engine was checked against it
  (the oracles and `tools/zjs-ref.c` link its prebuilt `zen-c/build/libzjs.a`).
  Its Makefile assumes the old root layout; the `zen-c` branch keeps that
  layout buildable.
- `nim/` — the design notes of an earlier plan to port the engine to Nim.
