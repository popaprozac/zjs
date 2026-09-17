#!/usr/bin/env python3
"""
Allocation and collection measurements for the Z engine (macOS).

Every child process runs under a timeout in its own process group, so a
timeout kills its descendants too. A sample that times out or exits
non-zero is a failure: it is recorded with its exit status and the tail of
its stderr, and the cell it belongs to gets no median, never a figure made
from the runs that happened to succeed. Results are written as JSON under
results/, with the revisions, flags, operation counts, the startup figure
that was subtracted, and the provenance of every binary measured.

A stage is built only from a compiler checkout at the revision stages.json
names, with nothing modified; RUN_ALLOW_DRIFT=1 builds anyway and marks
the binary's provenance unverified. The native backend objects the build
reuses (z/build/native) are recorded by digest and by the revision that
last touched their sources.

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
  run.py test                            the runner's own tests (a failing binary, a timeout)

Environment: Z_LANG is the compiler checkout to build with (default ~/code/z-lang;
it must be at the revision in stages.json for the figures to be comparable).
"""
import hashlib, json, os, platform, re, shutil, signal, statistics, subprocess, sys, tempfile, time
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
    """One child, in its own process group, under the timeout. Returns a sample:
    seconds, returncode, timed_out, stdout, stderr. A timeout kills the whole
    group, descendants included; the sample then has no seconds and no exit."""
    started = time.perf_counter()
    child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, start_new_session=True)
    try:
        out, err = child.communicate(timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(child.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.communicate()
        return {"seconds": None, "returncode": None, "timed_out": True, "stdout": "", "stderr": ""}
    return {"seconds": time.perf_counter() - started, "returncode": child.returncode, "timed_out": False, "stdout": out, "stderr": err}


def ok(sample):
    return not sample["timed_out"] and sample["returncode"] == 0


def failure_of(sample, cmd):
    """What went wrong, for the record."""
    if sample["timed_out"]:
        return {"command": cmd, "timed_out": True, "timeout_seconds": TIMEOUT}
    return {"command": cmd, "returncode": sample["returncode"], "stderr_tail": sample["stderr"][-400:]}


def median_times(binaries, path, flags=()):
    """Interleaved: one run of each binary per round, so drift hits all alike.
    A binary with any failed sample gets no median, only its failures."""
    samples = {b: [] for b in binaries}
    for _ in range(RUNS):
        for b in binaries:
            cmd = [b, "run", *flags, str(path)]
            samples[b].append((cmd, run(cmd)))
    result = {}
    for b, runs in samples.items():
        failures = [failure_of(s, cmd) for cmd, s in runs if not ok(s)]
        if failures:
            result[b] = {"seconds": None, "failures": failures, "successful_samples": len(runs) - len(failures)}
        else:
            result[b] = {"seconds": statistics.median(s["seconds"] for _, s in runs), "failures": [], "successful_samples": len(runs)}
    return result


def seconds_of(timed, b):
    return timed[b]["seconds"]


def compiler_checkout():
    return os.environ.get("Z_LANG", str(Path.home() / "code" / "z-lang"))


def git(directory, *args):
    return subprocess.run(["git", "-C", str(directory), *args], capture_output=True, text=True).stdout.strip()


def environment():
    return {"date": time.strftime("%Y-%m-%d"), "machine": platform.platform(), "processor": platform.processor(),
            "compiler_checkout": compiler_checkout(), "compiler_checkout_revision": git(compiler_checkout(), "rev-parse", "--short=8", "HEAD"),
            "compiler_checkout_clean": git(compiler_checkout(), "status", "--porcelain") == "",
            "runs_per_median": RUNS, "timeout_seconds": TIMEOUT}


def provenance_of(binary):
    """The sidecar build-stage wrote beside the binary, if any, plus the binary's digest."""
    sidecar = Path(str(binary) + ".provenance.json")
    record = json.loads(sidecar.read_text()) if sidecar.exists() else {"note": "no build record: not built by this runner"}
    record["binary_sha256"] = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
    return record


def native_backend_provenance():
    """The reused native backend objects: their digests, and the revision that last touched their sources."""
    native = Z / "build" / "native"
    files = {}
    for f in sorted(native.iterdir()):
        if f.is_file():
            files[f.name] = hashlib.sha256(f.read_bytes()).hexdigest()
    return {"directory": "z/build/native", "reused_as_is": True, "built_by": "z/native.sh, at the tree revision below, before the stages were built",
            "sources_last_changed_at": git(ROOT, "log", "-1", "--format=%h", "--", "z/engine/native", "z/native.sh"),
            "tree_revision_when_reused": git(ROOT, "rev-parse", "--short=7", "HEAD"), "files_sha256": files}


def require_pinned_compiler():
    """The compiler must be at the revision stages.json names, with nothing modified."""
    wanted = stages()["compiler"]["revision"]
    checkout = compiler_checkout()
    actual = git(checkout, "rev-parse", "--short=8", "HEAD")
    dirty = git(checkout, "status", "--porcelain") != ""
    verified = actual.startswith(wanted) and not dirty
    if not verified and os.environ.get("RUN_ALLOW_DRIFT") != "1":
        sys.exit("refusing to build: %s is at %s%s, stages.json wants %s clean (RUN_ALLOW_DRIFT=1 builds anyway, marked unverified)"
                 % (checkout, actual, " with modifications" if dirty else "", wanted))
    return {"checkout": checkout, "revision": actual, "clean": not dirty, "wanted": wanted, "verified": verified}


def build_stage(commit, out, patch=None):
    compiler = compiler_checkout()
    pin = require_pinned_compiler()
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
    record = {"engine_commit": commit, "engine_commit_full": git(ROOT, "rev-parse", commit), "patch": patch, "compiler": pin,
              "build": "bun run z build z/tools/zjsz --release", "evidence": "Stage 0" if pin["verified"] else "Stage 0, UNVERIFIED: compiler checkout not at the clean pin",
              "native_backend": native_backend_provenance(), "built_at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    Path(str(out) + ".provenance.json").write_text(json.dumps(record, indent=1) + "\n")
    print("built", commit, "->", out, "(%s)" % record["evidence"])


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
        per = {}
        for n, b in zip(names, binaries):
            per[n] = None if wall[b]["seconds"] is None or startup[b]["seconds"] is None else (wall[b]["seconds"] - startup[b]["seconds"]) * 1e9 / ops
        rows[workload] = {"operations": ops, "wall_seconds": {n: wall[b]["seconds"] for n, b in zip(names, binaries)},
                          "failures": {n: wall[b]["failures"] for n, b in zip(names, binaries) if wall[b]["failures"]},
                          "ns_per_operation": per}
        print(workload, " ".join(("%7.0f" % per[n]) if per[n] is not None else " failed" for n in names), flush=True)
    result = {"what": "Incremental effect of each stage on top of all earlier ones, in this order; median wall time, interleaved runs, startup subtracted. A cell with failures has no figure.",
              "environment": environment(), "compiler": info["compiler"], "build": info["build"], "stages": info["stages"],
              "binaries": {n: provenance_of(b) for n, b in zip(names, binaries)},
              "flags": [], "startup_seconds_subtracted": {n: startup[b]["seconds"] for n, b in zip(names, binaries)},
              "startup_failures": {n: startup[b]["failures"] for n, b in zip(names, binaries) if startup[b]["failures"]}, "workloads": rows}
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
    """The engine's own figures. A stage binary from before --mem-stats existed is run without it.
    A run that fails gives (None, None, failure)."""
    cmd = [binary, "run", "--gc-stats", "--mem-stats", *flags, str(path)]
    sample = run(cmd)
    if "zjsz-gc:" not in sample["stderr"]:
        cmd = [binary, "run", "--gc-stats", *flags, str(path)]
        sample = run(cmd)
    if not ok(sample):
        return None, None, failure_of(sample, cmd)
    return parse_gc(sample["stderr"]), parse_mem(sample["stderr"]), None


def attribution(binary, path, flags=()):
    dylib = HERE / "results" / ".alloc-attr.dylib"
    if not dylib.exists():
        subprocess.run(["clang", "-O2", "-dynamiclib", "-o", str(dylib), str(Z / "tools" / "alloc-attr.c")], check=True)
    with tempfile.NamedTemporaryFile("r", suffix=".txt") as report:
        env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(dylib), ATTR_OUT=report.name, ATTR_DEPTH="3", ATTR_TOP="12")
        cmd = [binary, "run", *flags, str(path)]
        sample = run(cmd, env=env)
        text = Path(report.name).read_text()
    if not ok(sample):
        return {"failure": failure_of(sample, cmd)}
    head = re.search(r"ATTR malloc=(\d+) calloc=(\d+) realloc=(\d+) free=(\d+) requested_bytes=(\d+) live_at_exit=(\d+) peak_live=(\d+)", text)
    if not head:
        return {"failure": {"command": cmd, "note": "no attribution report"}}
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
    sample = run(["/usr/bin/time", "-l", binary, "run", str(path)])
    m = re.search(r"(\d+)\s+maximum resident set size", sample["stderr"])
    return int(m.group(1)) // 1024 if ok(sample) and m else None


def cmd_figures(binary, out):
    startup = median_times([binary], WORKLOADS / "empty.js")[binary]
    rows = {}
    for workload in CORE:
        path = WORKLOADS / (workload + ".js")
        ops = ops_of(workload)
        wall = median_times([binary], path)[binary]
        collection, memory, failure = instrumented(binary, path)
        per = None if wall["seconds"] is None or startup["seconds"] is None else (wall["seconds"] - startup["seconds"]) * 1e9 / ops
        rows[workload] = {"operations": ops, "wall_seconds": wall["seconds"], "ns_per_operation": per, "timing_failures": wall["failures"],
                          "collection": collection, "memory_kib_at_end_of_run": memory, "instrumented_failure": failure,
                          "peak_resident_kib_by_time_l": peak_resident(binary, path),
                          "allocator": attribution(binary, path)}
        a = rows[workload]["allocator"]
        if per is None or collection is None or "failure" in a:
            print("%-16s FAILED %s" % (workload, json.dumps(wall["failures"] or failure or a.get("failure"))[:200]), flush=True)
            continue
        print("%-16s %6.0f ns/op  cells/op %5.2f  allocator calls/op %5.2f bytes/op %7.1f" % (
            workload, per, (collection["cells_allocated"] or 0) / ops,
            (a["malloc_calls"] + a["calloc_calls"] + a["realloc_calls"]) / ops, a["bytes_requested"] / ops), flush=True)
    result = {"what": "One binary, every workload: uninstrumented median wall time with startup subtracted; then, from separate instrumented runs, the engine's collection figures (--gc-stats), its storage figures at the end of the run (--mem-stats), and the allocator's calls and bytes by calling site (tools/alloc-attr.c). A failed run is recorded as such and gives no figure.",
              "environment": environment(), "binary": binary, "binary_provenance": provenance_of(binary), "flags_for_timing": [], "flags_for_collection_and_memory": ["--gc-stats", "--mem-stats"],
              "startup_seconds_subtracted": startup["seconds"], "startup_failures": startup["failures"], "workloads": rows}
    Path(out).write_text(json.dumps(result, indent=1) + "\n")


def cmd_cells(binary, out):
    rows = {}
    for workload in CORE:
        ops = ops_of(workload)
        collection, _, failure = instrumented(binary, WORKLOADS / (workload + ".js"))
        if failure:
            rows[workload] = {"operations": ops, "failure": failure}
            print("%-16s FAILED" % workload, flush=True)
            continue
        rows[workload] = {"operations": ops, "cells_allocated": collection["cells_allocated"], "slots_allocated": collection["slots_allocated"],
                          "cells_per_operation": collection["cells_allocated"] / ops, "slots_per_operation": collection["slots_allocated"] / ops}
        print("%-16s cells/op %6.2f  slots/op %7.2f" % (workload, rows[workload]["cells_per_operation"], rows[workload]["slots_per_operation"]), flush=True)
    Path(out).write_text(json.dumps({"what": "Engine cells and slots allocated, cumulative over the run, per operation.", "environment": environment(), "binary": binary, "binary_provenance": provenance_of(binary), "workloads": rows}, indent=1) + "\n")


def cmd_policy(binary, out):
    policies = [("floor-1024", ["--gc-floor", "1024"]), ("default-4096-200", []), ("floor-16384", ["--gc-floor", "16384"]),
                ("floor-65536", ["--gc-floor", "65536"]), ("growth-150", ["--gc-growth", "150"]), ("growth-300", ["--gc-growth", "300"])]
    rows = {}
    for workload in POLICY:
        path = WORKLOADS / (workload + ".js")
        rows[workload] = {}
        for label, flags in policies:
            wall = median_times([binary], path, flags)[binary]
            collection, memory, failure = instrumented(binary, path, flags)
            rows[workload][label] = {"flags": flags, "wall_seconds": wall["seconds"], "timing_failures": wall["failures"], "collection": collection, "memory_kib_at_end_of_run": memory, "instrumented_failure": failure}
            if wall["seconds"] is None or failure:
                print("%-16s %-17s FAILED" % (workload, label), flush=True)
                continue
            g = collection; m = memory
            print("%-16s %-17s %8.1f ms %6d collections %8.1f ms collecting  pause p50 %6d max %7d us  peak resident %7.1f MB" % (
                workload, label, wall["seconds"] * 1000, g["collections"], g["collecting_us"] / 1000, g["pause_p50_us"], g["pause_max_us"], m["resident_peak_kib"] / 1024), flush=True)
    result = {"what": "The collection policy's floor (cells) and survivor multiple (percent) swept; the default is 4096 and 200. A failed cell is recorded as such.",
              "environment": environment(), "binary": binary, "binary_provenance": provenance_of(binary), "workloads": rows}
    Path(out).write_text(json.dumps(result, indent=1) + "\n")


def vmmap_summary(binary, path, seconds=4.0):
    """The address space of a run still in progress: which region types are resident."""
    child = subprocess.Popen([binary, "run", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    time.sleep(seconds)
    text = subprocess.run(["vmmap", "--summary", str(child.pid)], capture_output=True, text=True, timeout=60).stdout
    os.killpg(os.getpgid(child.pid), signal.SIGKILL)
    child.communicate()
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
        collection, memory, failure = instrumented(binary, path)
        rows[label] = {"binary": binary, "binary_provenance": provenance_of(binary), "wall_seconds": wall[binary]["seconds"], "timing_failures": wall[binary]["failures"],
                       "collection": collection, "memory_kib_at_end_of_run": memory, "instrumented_failure": failure,
                       "address_space_after_the_burst": vmmap_summary(binary, WORKLOADS / "spike-hold.js")}
        print(label, json.dumps(rows[label], indent=1), flush=True)
    result = {"what": "Two million objects held and dropped, then three million short-lived ones. The memory figures are read at the end of the run and, for the address space, while a copy of the workload idles after the burst: they are the present state, not a high-water mark.",
              "environment": environment(), "runs": rows}
    Path(out).write_text(json.dumps(result, indent=1) + "\n")


def cmd_test():
    """A binary that exits non-zero yields no median, only failures; a binary that hangs is killed
    with its descendants at the timeout and yields a timeout failure."""
    global TIMEOUT
    with tempfile.TemporaryDirectory() as tmp:
        failing = Path(tmp) / "failing"
        failing.write_text("#!/bin/sh\necho 'zjs: throw: Error: no' >&2\nexit 3\n")
        failing.chmod(0o755)
        marker = "runner-test-descendant-%d" % os.getpid()
        hanging = Path(tmp) / "hanging"
        hanging.write_text("#!/bin/sh\n(exec -a %s sleep 300) &\nsleep 300\n" % marker)
        hanging.chmod(0o755)
        quick = Path(tmp) / "quick"
        quick.write_text("#!/bin/sh\nexit 0\n")
        quick.chmod(0o755)
        saved = TIMEOUT
        TIMEOUT = 1.0
        try:
            timed = median_times([str(failing), str(quick)], WORKLOADS / "empty.js")
            assert timed[str(failing)]["seconds"] is None, "a failing binary must get no median"
            assert timed[str(failing)]["failures"][0]["returncode"] == 3, timed[str(failing)]
            assert "zjs: throw" in timed[str(failing)]["failures"][0]["stderr_tail"]
            assert timed[str(quick)]["seconds"] is not None and not timed[str(quick)]["failures"]
            sample = run([str(hanging), "run", str(WORKLOADS / "empty.js")])
            assert sample["timed_out"] and sample["seconds"] is None and sample["returncode"] is None, sample
            time.sleep(0.3)
            alive = subprocess.run(["pgrep", "-f", marker], capture_output=True, text=True).stdout.strip()
            assert alive == "", "a descendant survived the timeout: pids %s" % alive
            collection, memory, failure = instrumented(str(failing), WORKLOADS / "empty.js")
            assert collection is None and failure["returncode"] == 3
        finally:
            TIMEOUT = saved
            subprocess.run(["pkill", "-f", marker], capture_output=True)
    print("runner tests: ok")


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) in (3, 4) and args[0] == "build-stage":
        build_stage(args[1], args[2], args[3] if len(args) == 4 else None)
    elif len(args) == 3 and args[0] == "cells":
        cmd_cells(args[1], args[2])
    elif len(args) == 1 and args[0] == "test":
        cmd_test()
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
