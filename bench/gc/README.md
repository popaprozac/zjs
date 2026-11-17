# Collector measurements

Collector workloads, and the harness that runs them against builds of the
engine and other engines. The collector is described in
[docs/allocation.md](../../docs/allocation.md).

| | |
|---|---|
| `workloads/` | Programs that stress a collector, each printing a checksum every engine must agree on. `binary-trees` builds and drops trees beside a long-lived one; `splay` holds a splay tree at 40,000 nodes while keys come and go (nodes die old); `fifo` replaces 100,000 records in the order they were made (all garbage is old); `old-to-young` gives 200,000 old objects fresh ones (the write barrier and the remembered set); `frames` runs a frame loop over 500,000 records and prints its longest frame; `map-churn` makes and drops Maps and Sets; `big-program` has 4,000 functions and shapes (what a collection's roots cost). |
| `run.py` | Builds of the Z engine against each other, and with `--others` against JavaScriptCore without its JIT, V8's interpreter, and QuickJS and Hermes when they are on PATH. Runs these workloads, `bench/memory/large-heap.js`, the speed kernels, and the allocation workloads. Per engine: the least cycles of `--runs` interleaved runs less the same for an empty script, and the least peak resident size; per Z build also one `--gc-stats` run for collection count, total, and pauses. |
| `results/` | Recorded runs, with the date, the load average, and each engine's command; the session directory the builds were in is written as `<scratch>`. In each, the first build (`base` or `old`) is the engine before the change measured, and the others are named for the change. A `.txt` beside a `.json` has the same builds over eight code placements, the cases with the other engines beside, and the instructions one operation takes. `test262-ab.txt` has the test262 comparisons of the builds. |

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
