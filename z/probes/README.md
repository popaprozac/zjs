# Language probes — the ZJS↔z-lang contract

One small Z program per finding in [`docs/z-findings.md`](../../docs/z-findings.md).
Each compiles and runs **only when its finding has landed**.

```sh
./z/probes/run.sh          # Z_LANG=/path/to/z-lang to point elsewhere
```

## Why this exists

The findings doc says what ZJS needs in prose. These say it in code, and they
are executable by both sides:

- **z-lang** gets acceptance criteria it can develop against without reading
  the engine. If a probe passes, the finding is done as far as ZJS is
  concerned.
- **ZJS** learns automatically when a workaround can be removed, instead of
  asking or guessing.

## Conventions

- One file per finding, named `g<NN>-<slug>.zs`.
- The header comment states the **requirement and the ZJS use case**, not the
  implementation.
- A probe returns a distinct nonzero code per assertion so a partial
  implementation is diagnosable: run it directly to see which check failed.
- Probes for unlanded APIs are written against the **proposed** spelling from
  the findings doc. If z-lang picks different names, that is fine and
  expected — say so and the probe is a one-line change. The *behaviour*
  asserted is the contract, not the naming.
- When a finding lands: the probe flips to LANDED, ZJS drops its workaround,
  and the workaround's `// Finding G<NN>` comment comes out with it.

Adoption sites are greppable: `grep -rn "Finding G" z/`.
