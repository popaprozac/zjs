# Allocation and collection measurements

What is behind [docs/allocation.md](../../docs/allocation.md).

| | |
|---|---|
| `workloads/` | The programs. The first line of each is `// OPS <count> : <what one operation is>`; every per-operation figure divides by that count. `empty.js` is the startup that is subtracted. |
| `stages.json` | The stages of the matrix: name, engine commit, what changed, and the compiler revision and build command. |
| `run.py` | The runner. Builds a `zjsz` from the engine at a commit, runs every child process under a timeout (`RUN_TIMEOUT`, default 120 s), takes medians of `RUNS` (default 7) interleaved runs, and writes JSON. |
| `cell-counters.patch` | The cumulative cell and slot counters, for building a stage from before they existed (`39bc925`). |
| `tables.py` | Renders the document's tables from `results/`. It measures nothing. |
| `results/` | The measurements, with the machine, date, revisions, flags, operation counts, and the startup figure subtracted recorded in each file. |
| `../../tools/alloc-attr.c` | Allocator attribution by calling site: calls and bytes requested per site, bytes live and their peak. |

Evidence level: every binary was built by the Stage 0 compiler (the
TypeScript compiler run under bun) at the z-lang revision in
`stages.json`. Nothing here was measured with a native compiler build.

Reading the matrix: a stage is the engine at one commit and differs from
the stage before it by that commit only, so a column is the incremental
effect of its change on top of all the earlier ones, in that order. The
stages interact, and no other order was measured.

Timing uses no measurement flag. Collection figures (`--gc-stats`),
storage figures (`--mem-stats`), and allocator attribution come from
separate runs. macOS only: the attribution tool is a dyld interposer, and
the storage figures use `malloc_zone_statistics`, `proc_pid_rusage`, and
`vmmap`.

The commands are at the end of the document.
