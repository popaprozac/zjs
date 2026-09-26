#!/usr/bin/env python3
"""Jitless speed: the kernels in kernels/ on the Z engine and on the jit-less
engines an embedder would otherwise choose.

Each kernel ends by assigning `result`; the runner appends a line printing it,
so every engine must agree on the checksum or its time is not reported. Each
engine's figure is the median of RUNS interleaved runs less the same median
for an empty script (the startup figure, recorded beside it). A run that
fails or times out is a failure, never a sample.

  run.py [out.json]            measure every engine present, print a table
  ZJSZ=/path/to/zjsz run.py    measure another build of the Z engine

Engines, each measured only when it is present:
  zjsz         z/build/zjsz run            the Z engine (built by z/build.sh)
  zjs-ref      z/build/zjs-ref run         the Zen-c reference engine
  jsc-nojit    jsc --useJIT=false          JavaScriptCore's interpreter, what
                                           iOS runs when JIT is unavailable
  v8-jitless   node --jitless              V8's Ignition interpreter
  quickjs      qjs                         QuickJS, if a qjs is on PATH
"""
import json, math, os, shutil, statistics, sys, tempfile, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "alloc"))
import run as runner  # the hardened child runner: process groups, timeouts, failures kept apart

Z = HERE.parent.parent
KERNELS = HERE / "kernels"
RUNS = int(os.environ.get("RUNS", "5"))
JSC = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"
PRINT = '\n;(typeof console !== "undefined" && console.log ? console.log : print)(String(result));\n'


def engines():
    found = {}
    zjsz = os.environ.get("ZJSZ", str(Z / "build" / "zjsz"))
    if Path(zjsz).exists():
        found["zjsz"] = lambda path: [zjsz, "run", path]
    if (Z / "build" / "zjs-ref").exists():
        found["zjs-ref"] = lambda path: [str(Z / "build" / "zjs-ref"), "run", path]
    if Path(JSC).exists():
        found["jsc-nojit"] = lambda path: [JSC, "--useJIT=false", path]
    if shutil.which("node"):
        found["v8-jitless"] = lambda path: ["node", "--jitless", path]
    if shutil.which("qjs"):
        found["quickjs"] = lambda path: ["qjs", path]
    return found


def measure(commands, path):
    """Interleaved runs; per engine the median seconds, the checksum, or the failure."""
    samples = {name: [] for name in commands}
    for _ in range(RUNS):
        for name, command in commands.items():
            samples[name].append(runner.run(command(path)))
    result = {}
    for name, runs in samples.items():
        failed = [s for s in runs if not runner.ok(s)]
        if failed:
            result[name] = {"seconds": None, "failure": runner.failure_of(failed[0], commands[name](path))}
            continue
        outputs = {s["stdout"].strip().split("\n")[-1] if s["stdout"].strip() else "" for s in runs}
        result[name] = {"seconds": statistics.median(s["seconds"] for s in runs), "checksum": outputs.pop() if len(outputs) == 1 else None}
    return result


def main():
    commands = engines()
    tmp = Path(tempfile.mkdtemp(prefix="zjs-speed-"))
    empty = tmp / "empty.js"
    empty.write_text("var result = 0;" + PRINT)
    startup = measure(commands, str(empty))
    rows = {}
    for kernel in sorted(KERNELS.glob("*.js")):
        path = tmp / kernel.name
        path.write_text(kernel.read_text() + PRINT)
        timed = measure(commands, str(path))
        reference = timed.get("zjsz", {}).get("checksum")
        row = {}
        for name, figure in timed.items():
            if figure["seconds"] is None:
                row[name] = {"ms": None, "note": "failed", "failure": figure["failure"]}
            elif figure["checksum"] != reference:
                row[name] = {"ms": None, "note": "checksum %r, zjsz %r" % (figure["checksum"], reference)}
            else:
                row[name] = {"ms": max(0.0, (figure["seconds"] - startup[name]["seconds"]) * 1000.0)}
        rows[kernel.stem] = row
        print(kernel.stem, json.dumps({k: (round(v["ms"], 1) if v["ms"] is not None else v["note"]) for k, v in row.items()}), flush=True)
    shutil.rmtree(tmp)

    names = list(commands)
    print()
    print("%-12s" % "kernel" + "".join("%12s" % n for n in names))
    for kernel, row in rows.items():
        print("%-12s" % kernel + "".join("%12s" % ("%.0f" % row[n]["ms"] if row[n]["ms"] is not None else "-") for n in names))
    print("%-12s" % "startup" + "".join("%12s" % ("%.1f" % (startup[n]["seconds"] * 1000.0) if startup[n]["seconds"] else "-") for n in names))
    # Geometric mean of each engine's time relative to zjsz, over the kernels both finished.
    print("%-12s" % "vs zjsz" + "".join("%12s" % geomean_ratio(rows, n) for n in names))
    print("(ms per kernel, startup subtracted; 'vs zjsz' is the geometric mean of engine time / zjsz time; above 1 means zjsz is faster)")
    print("load average: %.1f" % os.getloadavg()[0])

    if len(sys.argv) > 1:
        Path(sys.argv[1]).write_text(json.dumps({
            "what": "Jitless speed kernels, ms per kernel with each engine's startup subtracted, median of interleaved runs.",
            "date": time.strftime("%Y-%m-%d"), "runs_per_median": RUNS, "load_average": os.getloadavg()[0],
            "startup_ms": {n: (startup[n]["seconds"] * 1000.0 if startup[n]["seconds"] else None) for n in names},
            "kernels": rows}, indent=1) + "\n")


def geomean_ratio(rows, name):
    logs = [math.log(row[name]["ms"] / row["zjsz"]["ms"]) for row in rows.values()
            if row.get(name, {}).get("ms") and row.get("zjsz", {}).get("ms")]
    return "%.2f" % math.exp(sum(logs) / len(logs)) if logs else "-"


if __name__ == "__main__":
    main()
