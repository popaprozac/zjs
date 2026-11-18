#!/usr/bin/env python3
"""Jitless speed: the kernels in kernels/ on the Z engine and on the jit-less
engines an embedder would otherwise choose.

Each kernel ends by assigning `result`; the runner appends a line printing it,
so every engine must agree on the checksum or its time is not reported. Each
engine's figure is the median of RUNS interleaved runs less the same median
for an empty script (the startup figure, recorded beside it). A run that
fails or times out is a failure, never a sample.

  run.py [out.json]            measure every engine present, print a table
  run.py v8 [out.json]         the V8 benchmark suite (v8/), scored by its own harness
  ZJSZ=/path/to/zjsz run.py    measure another build of the Z engine

Engines, each measured only when it is present:
  zjsz         build/zjsz run            the Z engine (built by build.sh)
  zjs-ref      build/zjs-ref run         the Zen-c reference engine
  jsc-nojit    jsc --useJIT=false          JavaScriptCore's interpreter, what
                                           iOS runs when JIT is unavailable
  v8-jitless   node --jitless              V8's Ignition interpreter
  quickjs      qjs                         QuickJS, if a qjs is on PATH
  hermes       hermes -Xes6-class          Hermes from source, if hermes is on PATH
  hermes-hbc   hvm -Xes6-class (.hbc)      Hermes on bytecode precompiled with
                                           hermesc -O before timing, as a React
                                           Native app ships it
"""
import json, math, os, re, shutil, statistics, sys, tempfile, time
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
    # Hermes 0.13 parses classes only with -Xes6-class.
    if shutil.which("hermes"):
        found["hermes"] = lambda path: ["hermes", "-Xes6-class", path]
    if shutil.which("hermesc") and shutil.which("hvm"):
        found["hermes-hbc"] = lambda path: ["hvm", "-Xes6-class", path + ".hbc"]
    return found


def precompile(commands, path):
    """Bytecode for the engines that run it, made before any timing."""
    if "hermes-hbc" in commands:
        runner.run(["hermesc", "-Xes6-class", "-O", "-emit-binary", "-out", path + ".hbc", path])


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
    precompile(commands, str(empty))
    startup = measure(commands, str(empty))
    rows = {}
    for kernel in sorted(KERNELS.glob("*.js")):
        path = tmp / kernel.name
        path.write_text(kernel.read_text() + PRINT)
        precompile(commands, str(path))
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


V8 = HERE / "v8"
V8_PROGRAMS = ["richards", "deltablue", "crypto", "raytrace", "earley-boyer", "regexp", "splay", "navier-stokes"]
# run.js calls print(); node and zjsz have only console.log.
V8_PRINT = 'if (typeof print === "undefined") var print = function (s) { console.log(s); };\n'


def v8_score(sample, cmd):
    """One run's score from run.js's own report, or why it has none: run.js prints
    the Score line only when every benchmark ran and passed its own checks."""
    if not runner.ok(sample):
        return None, runner.failure_of(sample, cmd)
    found = re.search(r"^Score \(version \d+\): ([0-9.]+)$", sample["stdout"], re.M)
    if not found:
        return None, (sample["stdout"].strip().split("\n") or [""])[0][:200]
    return float(found.group(1)), None


def v8(out):
    """Each program alone with base.js and run.js's harness, one process per program
    and engine, RUNS interleaved rounds; per program the median of the suite's own
    score (higher is better), and the total as the suite computes it, the geometric
    mean of the programs' scores. A run that fails, times out, or fails the
    program's own checks is a failure, never a sample. Every run is under
    `ulimit -t` as well as the wall-clock timeout."""
    commands = engines()
    tmp = Path(tempfile.mkdtemp(prefix="zjs-v8-"))
    harness = "".join(line for line in (V8 / "run.js").read_text().splitlines(True) if not line.startswith("load("))
    limit = ["/bin/sh", "-c", 'ulimit -t %d && exec "$@"' % runner.TIMEOUT, "sh"]
    rows = {}
    for program in V8_PROGRAMS:
        path = tmp / (program + ".js")
        path.write_text(V8_PRINT + (V8 / "base.js").read_text() + (V8 / (program + ".js")).read_text() + harness)
        precompile(commands, str(path))
        scores = {name: [] for name in commands}
        for _ in range(RUNS):
            for name, command in commands.items():
                scores[name].append(v8_score(runner.run(limit + command(str(path))), command(str(path))))
        row = {}
        for name, runs in scores.items():
            failed = [why for score, why in runs if score is None]
            row[name] = {"score": None, "failure": failed[0]} if failed else {"score": statistics.median(s for s, _ in runs)}
        rows[program] = row
        print(program, json.dumps({k: v["score"] if v["score"] is not None else v["failure"] for k, v in row.items()}), flush=True)
    shutil.rmtree(tmp)

    names = list(commands)
    totals = {}
    for name in names:
        got = [rows[p][name]["score"] for p in V8_PROGRAMS if rows[p][name]["score"]]
        totals[name] = math.exp(sum(map(math.log, got)) / len(got)) if len(got) == len(V8_PROGRAMS) else None
    ratios = {}
    for name in names:
        logs = [math.log(rows[p]["zjsz"]["score"] / rows[p][name]["score"]) for p in V8_PROGRAMS
                if rows[p][name]["score"] and rows[p].get("zjsz", {}).get("score")]
        ratios[name] = math.exp(sum(logs) / len(logs)) if logs else None
    print()
    print("%-14s" % "program" + "".join("%12s" % n for n in names))
    for program, row in rows.items():
        print("%-14s" % program + "".join("%12s" % ("%.0f" % row[n]["score"] if row[n]["score"] else "-") for n in names))
    print("%-14s" % "score" + "".join("%12s" % ("%.0f" % totals[n] if totals[n] else "-") for n in names))
    print("%-14s" % "vs zjsz" + "".join("%12s" % ("%.2f" % ratios[n] if ratios[n] else "-") for n in names))
    print("(the suite's own scores, higher is better; 'score' is their geometric mean, only when every program ran;")
    print(" 'vs zjsz' is the geometric mean of zjsz score / engine score over the programs both ran; above 1 means zjsz is faster)")
    print("load average: %.1f" % os.getloadavg()[0])

    if out:
        Path(out).write_text(json.dumps({
            "what": "V8 benchmark suite version 7 (bench/speed/v8), each program in its own process, the median of each "
                    "engine's score from the suite's own harness; higher is better.",
            "date": time.strftime("%Y-%m-%d"), "runs_per_median": RUNS, "load_average": os.getloadavg()[0],
            "score": totals, "vs_zjsz": ratios, "programs": rows}, indent=1) + "\n")


if __name__ == "__main__":
    if sys.argv[1:2] == ["v8"]:
        v8(sys.argv[2] if len(sys.argv) > 2 else None)
    else:
        main()
