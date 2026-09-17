#!/usr/bin/env python3
"""
Allocation and collection measurements for the Z engine (macOS).

Every child process runs under a timeout; a run that exceeds it is recorded
as such and the measurement goes on. Results are written as JSON under
results/, with the revisions, flags, operation counts, and the startup
figure that was subtracted.

  run.py build-stage <commit> <out> [patch]
                                         a zjsz binary from the engine at <commit>, with an optional
                                         patch applied (cell-counters.patch gives a stage from before
                                         39bc925 the cumulative cell and slot counters)
  run.py cells <binary> <out.json>       cells and slots allocated per operation, every workload
  run.py build-stages <dir>              one per stage in stages.json
  run.py matrix <dir> <out.json>         interleaved wall time, every stage on every workload
  run.py figures <binary> <out.json>     per workload: time, collections and pauses, cells,
                                         allocator calls and bytes by site, memory now and at peak
  run.py policy <binary> <out.json>      the collection floor and survivor multiple swept
  run.py spike <before> <after> <out.json>
                                         the burst workload: time, collecting, and what holds
                                         the memory afterwards (engine, allocator, process, vmmap)

Environment: Z_LANG is the compiler checkout to build with (default ~/code/z-lang;
it must be at the revision in stages.json for the figures to be comparable).
"""
import ctypes, json, os, platform, re, shutil, statistics, subprocess, sys, tempfile, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
Z = HERE.parent.parent
ROOT = Z.parent
WORKLOADS = HERE / "workloads"
TIMEOUT = float(os.environ.get("RUN_TIMEOUT", "120"))
RUNS = int(os.environ.get("RUNS", "7"))
CORE = ["await-prim", "await-settled", "await-fresh", "await-suspended", "async-gen",
        "then-chain", "then-loop", "combinators", "churn-small", "churn-retained"]
POLICY = CORE[:1] + CORE[3:] + ["medium-live-set", "spike"]


def ops_of(name):
    first = (WORKLOADS / (name + ".js")).read_text().splitlines()[0]
    return int(re.search(r"// OPS (\d+)", first).group(1))


def run(cmd, env=None):
    """(seconds, stdout, stderr), or (None, '', 'timeout') past the bound."""
    started = time.perf_counter()
    try:
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT, env=env)
    except subprocess.TimeoutExpired:
        return None, "", "timeout"
    return time.perf_counter() - started, done.stdout, done.stderr


def median_times(binaries, path, flags=()):
    """Interleaved: one run of each binary per round, so drift hits all alike."""
    times = {b: [] for b in binaries}
    for _ in range(RUNS):
        for b in binaries:
            seconds, _, _ = run([b, "run", *flags, str(path)])
            if seconds is not None:
                times[b].append(seconds)
    return {b: (statistics.median(v) if v else None) for b, v in times.items()}


def environment():
    compiler = os.environ.get("Z_LANG", str(Path.home() / "code" / "z-lang"))
    revision = subprocess.run(["git", "-C", compiler, "rev-parse", "--short=8", "HEAD"], capture_output=True, text=True).stdout.strip()
    engine = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short=7", "HEAD"], capture_output=True, text=True).stdout.strip()
    return {"date": time.strftime("%Y-%m-%d"), "machine": platform.platform(), "processor": platform.processor(),
            "compiler_checkout_revision": revision, "tree_revision_when_measured": engine,
            "runs_per_median": RUNS, "timeout_seconds": TIMEOUT}


def build_stage(commit, out, patch=None):
    compiler = os.environ.get("Z_LANG", str(Path.home() / "code" / "z-lang"))
    native = Z / "build" / "native"
    if not native.exists():
        sys.exit("z/build/native is missing: run ./z/build.sh once first")
    with tempfile.TemporaryDirectory() as tmp:
        archive = subprocess.run(["git", "-C", str(ROOT), "archive", commit, "z"], capture_output=True, check=True).stdout
        subprocess.run(["tar", "-x", "-C", tmp], input=archive, check=True)
        shutil.copytree(native, Path(tmp) / "z" / "build" / "native")
        if patch:
            subprocess.run(["patch", "-p1", "-s", "-i", str(Path(patch).resolve())], cwd=tmp, check=True)
        built = subprocess.run(["bun", "run", "z", "build", str(Path(tmp) / "z" / "tools" / "zjsz"), "--release"],
                               cwd=compiler, capture_output=True, text=True, timeout=900)
        if built.returncode != 0:
            sys.exit(built.stdout + built.stderr)
        shutil.copy(Path(tmp) / "z" / "tools" / "zjsz" / "build" / "zjsz", out)
    print("built", commit, "->", out)


def stages():
    return json.loads((HERE / "stages.json").read_text())


def cmd_build_stages(directory):
    Path(directory).mkdir(parents=True, exist_ok=True)
    for stage in stages()["stages"]:
        build_stage(stage["commit"], str(Path(directory) / ("zjsz-" + stage["name"])))


def cmd_matrix(directory, out):
    info = stages()
    names = [s["name"] for s in info["stages"]]
    binaries = [str(Path(directory) / ("zjsz-" + n)) for n in names]
    startup = median_times(binaries, WORKLOADS / "empty.js")
    rows = {}
    for workload in CORE:
        ops = ops_of(workload)
        wall = median_times(binaries, WORKLOADS / (workload + ".js"))
        rows[workload] = {"operations": ops,
                          "wall_seconds": {n: wall[b] for n, b in zip(names, binaries)},
                          "ns_per_operation": {n: (wall[b] - startup[b]) * 1e9 / ops for n, b in zip(names, binaries)}}
        print(workload, " ".join("%7.0f" % rows[workload]["ns_per_operation"][n] for n in names), flush=True)
    result = {"what": "Incremental effect of each stage on top of all earlier ones, in this order; median wall time, interleaved runs, startup subtracted.",
              "environment": environment(), "compiler": info["compiler"], "build": info["build"], "stages": info["stages"],
              "flags": [], "startup_seconds_subtracted": {n: startup[b] for n, b in zip(names, binaries)}, "workloads": rows}
    Path(out).write_text(json.dumps(result, indent=1) + "\n")


def parse_gc(stderr):
    m = re.search(r"zjsz-gc: collections (\d+) total-us (\d+) p50-us (\d+) p95-us (\d+) p99-us (\d+) max-us (\d+)(?: cells-allocated (\d+) slots-allocated (\d+))? in-use-kib (\d+)", stderr)
    if not m:
        return None
    keys = ["collections", "collecting_us", "pause_p50_us", "pause_p95_us", "pause_p99_us", "pause_max_us", "cells_allocated", "slots_allocated", "engine_in_use_kib"]
    return {k: (int(v) if v is not None else None) for k, v in zip(keys, m.groups())}


def parse_mem(stderr):
    m = re.search(r"zjsz-mem: (.*)", stderr)
    if not m:
        return None
    parts = m.group(1).split()
    return {parts[i].replace("-", "_"): int(parts[i + 1]) for i in range(0, len(parts), 2)}


def instrumented(binary, path, flags=()):
    """The engine's own figures. A stage binary from before --mem-stats existed is run without it."""
    _, _, stderr = run([binary, "run", "--gc-stats", "--mem-stats", *flags, str(path)])
    if "zjsz-gc:" not in stderr:
        _, _, stderr = run([binary, "run", "--gc-stats", *flags, str(path)])
    return parse_gc(stderr), parse_mem(stderr)


def attribution(binary, path, flags=()):
    dylib = HERE / "results" / ".alloc-attr.dylib"
    if not dylib.exists():
        subprocess.run(["clang", "-O2", "-dynamiclib", "-o", str(dylib), str(Z / "tools" / "alloc-attr.c")], check=True)
    with tempfile.NamedTemporaryFile("r", suffix=".txt") as report:
        env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(dylib), ATTR_OUT=report.name, ATTR_DEPTH="3", ATTR_TOP="12")
        run([binary, "run", *flags, str(path)], env=env)
        text = Path(report.name).read_text()
    head = re.search(r"ATTR malloc=(\d+) calloc=(\d+) realloc=(\d+) free=(\d+) requested_bytes=(\d+) live_at_exit=(\d+) peak_live=(\d+)", text)
    if not head:
        return None
    sites = []
    for kind, count, size, frames in re.findall(r"SITE (\w+) count=(\d+) bytes=(\d+) avg=[\d.]+\n((?:    .*\n)+)", text):
        sites.append({"kind": kind, "calls": int(count), "bytes_requested": int(size),
                      "frames": [f.strip().split("+")[0] for f in frames.strip().split("\n")]})
    keys = ["malloc_calls", "calloc_calls", "realloc_calls", "free_calls", "bytes_requested", "allocator_live_at_exit", "allocator_peak_live"]
    totals = {k: int(v) for k, v in zip(keys, head.groups())}
    totals["sites"] = sites
    return totals


def peak_resident(binary, path):
    """The high-water resident size, from /usr/bin/time -l: for a binary that cannot report its own."""
    _, _, stderr = run(["/usr/bin/time", "-l", binary, "run", str(path)])
    m = re.search(r"(\d+)\s+maximum resident set size", stderr)
    return int(m.group(1)) // 1024 if m else None


def cmd_figures(binary, out):
    startup = median_times([binary], WORKLOADS / "empty.js")[binary]
    rows = {}
    for workload in CORE:
        path = WORKLOADS / (workload + ".js")
        ops = ops_of(workload)
        wall = median_times([binary], path)[binary]
        collection, memory = instrumented(binary, path)
        rows[workload] = {"operations": ops, "wall_seconds": wall, "ns_per_operation": (wall - startup) * 1e9 / ops,
                          "collection": collection, "memory_kib_at_end_of_run": memory,
                          "peak_resident_kib_by_time_l": peak_resident(binary, path),
                          "allocator": attribution(binary, path)}
        a = rows[workload]["allocator"]
        print("%-16s %6.0f ns/op  cells/op %5.2f  allocator calls/op %5.2f bytes/op %7.1f" % (
            workload, rows[workload]["ns_per_operation"], (rows[workload]["collection"]["cells_allocated"] or 0) / ops,
            (a["malloc_calls"] + a["calloc_calls"] + a["realloc_calls"]) / ops, a["bytes_requested"] / ops), flush=True)
    result = {"what": "One binary, every workload: uninstrumented median wall time with startup subtracted; then, from separate instrumented runs, the engine's collection figures (--gc-stats), its storage figures at the end of the run (--mem-stats), and the allocator's calls and bytes by calling site (tools/alloc-attr.c).",
              "environment": environment(), "binary": binary, "flags_for_timing": [], "flags_for_collection_and_memory": ["--gc-stats", "--mem-stats"],
              "startup_seconds_subtracted": startup, "workloads": rows}
    Path(out).write_text(json.dumps(result, indent=1) + "\n")


def cmd_cells(binary, out):
    rows = {}
    for workload in CORE:
        ops = ops_of(workload)
        collection, _ = instrumented(binary, WORKLOADS / (workload + ".js"))
        rows[workload] = {"operations": ops, "cells_allocated": collection["cells_allocated"], "slots_allocated": collection["slots_allocated"],
                          "cells_per_operation": collection["cells_allocated"] / ops, "slots_per_operation": collection["slots_allocated"] / ops}
        print("%-16s cells/op %6.2f  slots/op %7.2f" % (workload, rows[workload]["cells_per_operation"], rows[workload]["slots_per_operation"]), flush=True)
    Path(out).write_text(json.dumps({"what": "Engine cells and slots allocated, cumulative over the run, per operation.", "environment": environment(), "binary": binary, "workloads": rows}, indent=1) + "\n")


def cmd_policy(binary, out):
    policies = [("floor-1024", ["--gc-floor", "1024"]), ("default-4096-200", []), ("floor-16384", ["--gc-floor", "16384"]),
                ("floor-65536", ["--gc-floor", "65536"]), ("growth-150", ["--gc-growth", "150"]), ("growth-300", ["--gc-growth", "300"])]
    rows = {}
    for workload in POLICY:
        path = WORKLOADS / (workload + ".js")
        rows[workload] = {}
        for label, flags in policies:
            wall = median_times([binary], path, flags)[binary]
            collection, memory = instrumented(binary, path, flags)
            rows[workload][label] = {"flags": flags, "wall_seconds": wall, "collection": collection, "memory_kib_at_end_of_run": memory}
            g = rows[workload][label]["collection"]; m = rows[workload][label]["memory_kib_at_end_of_run"]
            print("%-16s %-17s %8.1f ms %6d collections %8.1f ms collecting  pause p50 %6d max %7d us  peak resident %7.1f MB" % (
                workload, label, wall * 1000, g["collections"], g["collecting_us"] / 1000, g["pause_p50_us"], g["pause_max_us"], m["resident_peak_kib"] / 1024), flush=True)
    result = {"what": "The collection policy's floor (cells) and survivor multiple (percent) swept; the default is 4096 and 200.",
              "environment": environment(), "binary": binary, "workloads": rows}
    Path(out).write_text(json.dumps(result, indent=1) + "\n")


def vmmap_summary(binary, path, seconds=4.0):
    """The address space of a run still in progress: which region types are resident."""
    child = subprocess.Popen([binary, "run", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(seconds)
    text = subprocess.run(["vmmap", "--summary", str(child.pid)], capture_output=True, text=True, timeout=60).stdout
    child.kill()
    regions = {}
    for line in text.splitlines():
        m = re.match(r"^(MALLOC[\w ()]*?|Stack|TOTAL)\s+([\d.]+[KMG])\s+([\d.]+[KMG])\s+([\d.]+[KMG])", line)
        if m:
            regions[m.group(1).strip()] = {"virtual": m.group(2), "resident": m.group(3), "dirty": m.group(4)}
    foot = re.search(r"Physical footprint:\s+([\d.]+[KMG])", text)
    zone = re.search(r"DefaultMallocZone\S*\s+([\d.]+[KMG])\s+[\d.]+[KMG]\s+[\d.]+[KMG]\s+[\d.]+[KMG]\s+\d+\s+([\d.]+[KMG])", text)
    return {"physical_footprint_now": foot.group(1) if foot else None,
            "default_zone": {"virtual": zone.group(1), "allocated": zone.group(2)} if zone else None, "regions": regions}


def cmd_spike(before, after, out):
    path = WORKLOADS / "spike.js"
    wall = median_times([before, after], path)
    rows = {}
    for label, binary in (("before", before), ("after", after)):
        collection, memory = instrumented(binary, path)
        rows[label] = {"binary": binary, "wall_seconds": wall[binary], "collection": collection,
                       "memory_kib_at_end_of_run": memory,
                       "address_space_after_the_burst": vmmap_summary(binary, WORKLOADS / "spike-hold.js")}
        print(label, json.dumps(rows[label], indent=1), flush=True)
    result = {"what": "Two million objects held and dropped, then three million short-lived ones. The memory figures are read at the end of the run and, for the address space, while a copy of the workload idles after the burst: they are the present state, not a high-water mark.",
              "environment": environment(), "runs": rows}
    Path(out).write_text(json.dumps(result, indent=1) + "\n")


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) in (3, 4) and args[0] == "build-stage":
        build_stage(args[1], args[2], args[3] if len(args) == 4 else None)
    elif len(args) == 3 and args[0] == "cells":
        cmd_cells(args[1], args[2])
    elif len(args) == 2 and args[0] == "build-stages":
        cmd_build_stages(args[1])
    elif len(args) == 3 and args[0] == "matrix":
        cmd_matrix(args[1], args[2])
    elif len(args) == 3 and args[0] == "figures":
        cmd_figures(args[1], args[2])
    elif len(args) == 3 and args[0] == "policy":
        cmd_policy(args[1], args[2])
    elif len(args) == 4 and args[0] == "spike":
        cmd_spike(args[1], args[2], args[3])
    else:
        sys.exit(__doc__)
