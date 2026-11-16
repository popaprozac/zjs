# Collector measurements

What is behind the collector passages of [docs/levers.md](../../docs/levers.md).

| | |
|---|---|
| `workloads/` | Programs that stress a collector, each printing a checksum every engine must agree on. `binary-trees` builds and drops trees beside a long-lived one; `splay` holds a splay tree at 40,000 nodes while keys come and go (nodes die old); `fifo` replaces 100,000 records in the order they were made (all garbage is old); `old-to-young` gives 200,000 old objects fresh ones (the write barrier and the remembered set); `frames` runs a frame loop over 500,000 records and prints its longest frame; `map-churn` makes and drops Maps and Sets; `big-program` has 4,000 functions and shapes (what a collection's roots cost). |
| `run.py` | Builds of the Z engine against each other, and with `--others` against JavaScriptCore without its JIT, V8's interpreter, and QuickJS and Hermes when they are on PATH. Runs these workloads, `bench/memory/large-heap.js`, the speed kernels, and the allocation workloads. Per engine: the least cycles of `--runs` interleaved runs less the same for an empty script, and the least peak resident size; per Z build also one `--gc-stats` run for collection count, total, and pauses. |
| `results/` | Recorded runs, with the date, the load average, and each engine's command; the session directory the builds were in is written as `<scratch>`. In them `base` is the engine at `1842094`, before the collector work of 2026-11-13; `keep` the engine with minor collections that cost what survives; `inc` the engine with full collections in slices. `test262-ab.txt` has the test262 comparisons of the same builds. `promise-species.json` and `promise-fields.json` are the promise and async work of 2026-11-15: in the first `old` is the engine at `6c2db29` and `new` the one whose `then` skips the species reads no program can observe; in the second `base` is that engine (`3c16de6`), `records` allocates promises, generator objects, and iterator results with their class and finds a record at a fixed slot, and `fields` keeps a promise's fields in the promise itself. `promise-suspend.json` is the suspension work of the same day: `base` is the engine at `771b5d6`, `save` stores a suspended body's registers as one run under one barrier decision, `record` (what was kept) also stores the numbers of a generator's record with no barrier, and `cells` (not kept) instead tests for a cell before every barrier call; its instruction counts carry the comparison, the machine being busy, and `promise-suspend-placements.txt` has `base` against `record` over eight code placements. `function-own-reads.json` is the cache for a function's own properties, the same day: `base` is the engine at `1a3cb32` and `new` the one that reads an own data property of a function through the site's cache; `function-own-reads.txt` has the two over eight code placements, a control for code position, and the instructions one read takes by what is read. `function-inherited-reads.json` and `function-inherited-reads.txt` are the same for the names a function inherits or computes: `base` is the engine at `a96be99`, and this run is the first with the `borrowed-methods` kernel. `shared-loads.json` and `shared-loads.txt` are the table of reads shared by all sites: `base` is the engine at `a17e42d`, the run is the first with the `method-shapes` kernel, and the text file has the two builds over eight placements, cases of one name on several shapes with the other engines beside, and the instructions one read takes by what is read. `prototype-chains.json` and `prototype-chains.txt` are the same for names found past an object's first prototype or nowhere: `base` is the engine at `4030a32`, and the run is the first with the `prototype-chains` kernel. |

```
./build.sh
./bench/gc/run.py --runs 5 --others --out bench/gc/results/<name>.json base=<zjsz before> new=build/zjsz
./bench/gc/run.py --only splay,fifo new=build/zjsz whole=build/zjsz,--gc-slice,0
```

A build takes flags after its path, comma-separated (`--gc-nursery`,
`--gc-slice`, `--gc-growth`). The first build named is the baseline of the
`vs` column. Timing wants a quiet machine: the large-heap workloads are
bound by cache misses and move by several percent between runs, so
compare with `--runs 12` or more; for the kernels use
`bench/speed/placements.py`.

`zjsz run --gc-stats` prints the time in each phase of the collector
(`zjsz-gc-phases-us`): a minor collection's roots, remembered set, sweep,
and finish; then a full collection's end of marking, marking, weak
entries, atoms, sweep, placing, and moving; then full collections
completed, minor collections, young cells seen and survived, and
remembered holders.
