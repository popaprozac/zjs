#!/usr/bin/env python3
"""Collector experiments: builds of the Z engine against each other and
against the other engines, on workloads that stress a collector.

  run.py [--out results/x.json] [--runs N] [--only a,b] [--others] name=path/to/zjsz[,flag,...] ...

The first build named is the baseline. Each workload runs RUNS times per
engine, interleaved, under /usr/bin/time -l: the figure for time is the
least cycles of the runs less the least for an empty script (a busy
moment cannot shorten a run), for memory the least peak resident size.
Each Z build also runs once with --gc-stats for its collection count,
total, and pauses, and that run is never timed. --others adds
JavaScriptCore without its JIT, V8's interpreter, and QuickJS and Hermes
when they are on PATH. An engine whose output differs from the
baseline's gets no figure.
"""
import json, os, shutil, statistics, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
JSC = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"
EMPTY = ROOT / "bench" / "alloc" / "workloads" / "empty.js"
FIELDS = {"maximum resident set size": "rss", "instructions retired": "instructions",
          "cycles elapsed": "cycles", "peak memory footprint": "footprint"}


def workloads(only):
    found = sorted((HERE / "workloads").glob("*.js"))
    found += [ROOT / "bench" / "memory" / "large-heap.js"]
    found += sorted((ROOT / "bench" / "speed" / "kernels").glob("*.js"))
    found += [p for p in sorted((ROOT / "bench" / "alloc" / "workloads").glob("*.js")) if p.name not in ("empty.js", "spike-hold.js")]
    return [p for p in found if not only or p.stem in only]


def timed(command):
    run = subprocess.run(["/usr/bin/time", "-l"] + command, capture_output=True, text=True, timeout=300)
    sample = {"ok": run.returncode == 0, "out": run.stdout.strip().split("\n")[0] if run.stdout.strip() else ""}
    for line in run.stderr.splitlines():
        for label, key in FIELDS.items():
            if line.strip().endswith(label):
                sample[key] = int(line.split()[0])
        if line.startswith("zjsz-gc:"):
            words = line.split()
            sample["gc"] = {words[i]: int(words[i + 1]) for i in range(1, len(words) - 1, 2)}
    return sample


def measure(engines, path, runs):
    samples = {name: [] for name in engines}
    for _ in range(runs):
        for name, command in engines.items():
            samples[name].append(timed(command + [str(path)]))
    return samples


def main(args):
    out, runs, only, others, builds = None, 5, None, False, {}
    while args:
        arg = args.pop(0)
        if arg == "--out": out = args.pop(0)
        elif arg == "--runs": runs = int(args.pop(0))
        elif arg == "--only": only = set(args.pop(0).split(","))
        elif arg == "--others": others = True
        elif "=" in arg:
            name, rest = arg.split("=", 1)
            path, *flags = rest.split(",")
            builds[name] = [os.path.abspath(path), "run"] + flags
        else: raise SystemExit(__doc__)
    if not builds: raise SystemExit(__doc__)
    engines = dict(builds)
    if others:
        if Path(JSC).exists(): engines["jsc-nojit"] = [JSC, "--useJIT=false"]
        if shutil.which("node"): engines["v8-jitless"] = ["node", "--jitless"]
        if shutil.which("qjs"): engines["quickjs"] = ["qjs"]
        if shutil.which("hermes"): engines["hermes"] = ["hermes", "-Xes6-class"]
    base = next(iter(builds))
    startup = {name: min(s["cycles"] for s in runs_) for name, runs_ in measure(engines, EMPTY, runs).items()}
    record = {"date": time.strftime("%Y-%m-%d %H:%M"), "load": os.getloadavg()[0], "runs": runs,
              "engines": {n: " ".join(c) for n, c in engines.items()}, "startup_cycles": startup, "workloads": {}}
    ratios = {name: [] for name in engines}
    print("%-16s %-12s %9s %7s %8s %7s %7s %8s %8s" % ("workload", "engine", "Mcycles", "vs", "rss MB", "gcs", "gc ms", "p99 us", "max us"))
    for path in workloads(only):
        samples = measure(engines, path, runs)
        want = samples[base][0]["out"].split(" ")[0]
        row = {}
        for name, runs_ in samples.items():
            if not all(s["ok"] and s["out"].split(" ")[0] == want for s in runs_):
                row[name] = {"failed": runs_[0]["out"][:60]}
                continue
            row[name] = {"cycles": min(s["cycles"] for s in runs_) - startup[name],
                         "instructions": min(s["instructions"] for s in runs_),
                         "rss": min(s["rss"] for s in runs_)}
            if name in builds:
                row[name]["gc"] = timed(builds[name] + ["--gc-stats", str(path)]).get("gc")
        for name, cell in row.items():
            if "failed" in cell:
                print("%-16s %-12s failed: %s" % (path.stem, name, cell["failed"]))
                continue
            vs = cell["cycles"] / row[base]["cycles"]
            ratios[name].append(vs)
            gc = cell.get("gc") or {}
            print("%-16s %-12s %9.1f %+6.1f%% %8.1f %7s %7s %8s %8s" % (
                path.stem, name, cell["cycles"] / 1e6, (vs - 1) * 100, cell["rss"] / 1048576,
                gc.get("collections", ""), "%.1f" % (gc["total-us"] / 1000) if gc else "", gc.get("p99-us", ""), gc.get("max-us", "")))
        record["workloads"][path.stem] = row
    print()
    for name, values in ratios.items():
        if values: print("%-12s geometric mean vs %s: %.3f over %d" % (name, base, statistics.geometric_mean(values), len(values)))
    record["geomean_vs_base"] = {n: statistics.geometric_mean(v) for n, v in ratios.items() if v}
    if out:
        Path(out).write_text(json.dumps(record, indent=1) + "\n")


if __name__ == "__main__":
    main(sys.argv[1:])
