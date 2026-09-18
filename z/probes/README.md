# Language probes

One small Z program per language gap the engine has hit. Each compiles and
runs **only when the gap is closed**, so the set doubles as acceptance
criteria for z-lang and as the engine's signal that a workaround can come out.

```sh
./z/probes/run.sh                  # verified run: refuses unless z-lang is at the pin and clean
./z/probes/run.sh --allow-drift    # explore against whatever is checked out; labelled UNVERIFIED
./z/probes/run.sh --record         # rewrite baseline.txt from a verified run
Z_LANG=/path/to/z-lang PROBE_TIMEOUT=60 ./z/probes/run.sh
```

The narrative for each gap -- what the engine needs and why -- lives in
[`docs/z-findings.md`](../../docs/z-findings.md), which names the probe for
each entry.

## Outcomes

Failures are classified, never collapsed into "pending":

| Outcome | Meaning |
|---|---|
| `LANDED` | compiled and ran clean |
| `COMPILER-REJECTED` | `z check` refused it -- a Z diagnostic, saved to the log |
| `BACKEND-REJECTED` | Z accepted it, the generated C failed to compile. A Z error escaping to clang is itself a bug |
| `RUNTIME-FAIL` | compiled, then a probe assertion or `z test` expectation failed; the probe's exit code says which assertion |
| `TIMEOUT` | exceeded `PROBE_TIMEOUT` seconds (default 60) |
| `REGRESSION` | was `LANDED` in `baseline.txt`, is not now. Runner exits 1 |

Probes containing a `test "..."` declaration run under `z test`; the rest
under `z run`. `z run` excludes test declarations, so an expectation
regression is invisible to it.

## Verified runs

A run is **verified** only when the z-lang checkout is at the revision in
`z/Z_LANG_REVISION` **and** has no uncommitted changes. Otherwise the runner
refuses (exit 2) -- a mid-edit tree cannot produce acceptance evidence. It
never switches, resets, or writes to the shared compiler checkout.
`--allow-drift` runs anyway for exploration, labelled `UNVERIFIED`, and can
never write the baseline.

Logs land in `.results/<probe>.log` (gitignored, regenerated each run).
Probe build caches stay inside this directory (`.z-cache/`, gitignored), never
in z-lang's.

## Conventions

- One file per gap, named for the gap, not for a ticket.
- The header comment states the **requirement and the engine's use case**,
  not the implementation.
- A probe returns a distinct nonzero code per assertion so a partial
  implementation is diagnosable: run it directly to see which check failed.
- Probes for unlanded APIs are written against a **proposed** spelling and say
  so. If z-lang picks different names, that is fine and expected; the
  asserted behaviour is the contract, not the naming.
- A probe passing is evidence. A gap is closed only once the engine drops its
  workaround.

## Known runner limitations

- On `TIMEOUT` the alarm kills the compiler process, but a probe binary it
  already launched can be orphaned and keep running. Kill it by name.
- Stage 0 only. Probes run through `bun run z`, not the native compiler; a
  pass is not a claim of native-compiler parity. The probes under
  `native/` are the other direction: programs Stage 0 accepts at the pin
  that a native compiler bootstrapped from the same revision rejects, run
  with `Z_BIN=<native z> ./z/probes/native/run.sh`.
- Detail columns are the first matching diagnostic line, truncated. Read the
  log for the full output.
