# Language probes — the ZJS↔z-lang contract

One small Z program per finding in [`docs/z-findings.md`](../../docs/z-findings.md).
Each compiles and runs **only when its finding has landed**.

```sh
./z/probes/run.sh                  # verified run: refuses unless z-lang is at the pin and clean
./z/probes/run.sh --allow-drift    # explore against whatever is checked out; labelled UNVERIFIED
./z/probes/run.sh --record         # rewrite baseline.txt from a verified run
Z_LANG=/path/to/z-lang PROBE_TIMEOUT=60 ./z/probes/run.sh
```

## Outcomes

Failures are classified, never collapsed into "pending":

| Outcome | Meaning |
|---|---|
| `LANDED` | compiled and ran clean |
| `COMPILER-REJECTED` | `z check` refused it — a Z diagnostic, saved to the log |
| `BACKEND-REJECTED` | Z accepted it, the generated C failed to compile. A Z error escaping to clang is itself a bug (see G13c) |
| `RUNTIME-FAIL` | compiled, then a probe assertion or `z test` expectation failed; the probe's exit code says which assertion |
| `TIMEOUT` | exceeded `PROBE_TIMEOUT` seconds (default 60) |
| `REGRESSION` | was `LANDED` in `baseline.txt`, is not now. Runner exits 1 |

Probes containing a `test "..."` declaration run under `z test`; the rest
under `z run`. `z run` excludes test declarations, so an expectation
regression is invisible to it.

## Verified runs

A run is **verified** only when the z-lang checkout is at the revision in
`z/Z_LANG_REVISION` **and** has no uncommitted changes. Otherwise the runner
refuses (exit 2) — a mid-edit tree cannot produce acceptance evidence. It
never switches, resets, or writes to the shared compiler checkout.
`--allow-drift` runs anyway for exploration, labelled `UNVERIFIED`, and can
never write the baseline.

Logs land in `.results/<probe>.log` (gitignored, regenerated each run).
Probe build caches stay inside this directory (`.z-cache/`, gitignored), never
in z-lang's.

## Known runner limitations

- On `TIMEOUT` the alarm kills the compiler process, but a probe binary it
  already launched can be orphaned and keep running. Kill it by name.
- Stage 0 only. Probes run through `bun run z`, not the native compiler; a
  pass is not a claim of native-compiler parity.
- Detail columns are the first matching diagnostic line, truncated. Read the
  log for the full output.

## Why this exists

The findings doc says what ZJS needs in prose. These say it in code, and they
are executable by both sides:

- **z-lang** gets acceptance criteria it can develop against without reading
  the engine. If a probe passes, the finding is done as far as ZJS is
  concerned.
- **ZJS** learns automatically when a workaround can be removed, instead of
  asking or guessing.

## Status, and what a probe is not

Probes for unlanded findings are written against a **proposed** spelling. A
probe is evidence and an acceptance case — it is **not an approved API**. The
status ladder in the findings doc governs that:

    proposed -> approved -> implemented -> consumer-verified

A probe flipping to LANDED is the *evidence* for `consumer-verified`; the
status only advances once ZJS actually drops the workaround and records the
commit.

`g02` is the worked example. It was proposed as a `std/bits` module with free
functions; z-lang shipped methods on the primitives instead. The probe was
rewritten to match, and nothing was lost — the asserted behaviour was the
contract all along.

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
