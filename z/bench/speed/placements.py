#!/usr/bin/env python3
"""Cycles compared over several placements of the dispatch loop's code.

A change to one arm of the dispatch loop moves every other arm, and one
placement alone can swing a kernel by 10% either way, which hides the
change itself. This builds a generated zjsz.c N times, the k-th with k
no-ops at the top of runFrames (every arm shifted by 4k bytes), and times
two such sets against each other.

  ./z/bench/speed/placements.py build z/tools/zjsz/.z-cache/build/zjsz.c /tmp/after
  ./z/bench/speed/placements.py compare /tmp/before /tmp/after z/bench/speed/kernels/*.js

`build` wants the native backend built (./z/build.sh or z/native.sh) and
runs from the repository root. `compare` runs every placement of both
twice, interleaved, and prints the median over placements of each one's
faster run, the change (the geometric mean over placements), and its
spread over placements.
"""
import concurrent.futures
import os
import statistics
import subprocess
import sys

ENTRY = ("Z___z_module_2_RunResult Z___z_module_2_Runtime_runFrames("
         "Z___z_module_2_Runtime *self, uint32_t entryDepth) {")
COUNT = 8


def build(source, prefix, count):
    text = open(source).read()
    at = text.index(ENTRY) + len(ENTRY)

    def one(k):
        c_path = "%s-%d.c" % (prefix, k)
        with open(c_path, "w") as out:
            out.write(text[:at] + '\n  __asm__ volatile("' + "nop\\n" * k + '");\n' + text[at:])
        subprocess.run(["clang", "-std=c11", "-O2", "-DNDEBUG", "-w",
                        "-I", "z/tools/zjsz", "-I", "z/engine", "-I", "z/engine/builtins", "-I", "z/engine/native",
                        "-o", "%s-%d" % (prefix, k), c_path, "-L", "z/build/native", "-lzjsregexp"], check=True)
        os.remove(c_path)

    with concurrent.futures.ThreadPoolExecutor() as pool:
        list(pool.map(one, range(count)))


def cycles(binary, script):
    run = subprocess.run(["/usr/bin/time", "-l", binary, "run", script],
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    for line in run.stderr.splitlines():
        if "cycles elapsed" in line:
            return int(line.split()[0])
    raise SystemExit("no cycle count from %s %s" % (binary, script))


def compare(before, after, scripts, count):
    for script in scripts:
        a = {k: [] for k in range(count)}
        b = {k: [] for k in range(count)}
        for _ in range(2):
            for k in range(count):
                a[k].append(cycles("%s-%d" % (before, k), script))
                b[k].append(cycles("%s-%d" % (after, k), script))
        # Each placement's faster run, which a busy moment cannot inflate;
        # the change is the geometric mean over placements.
        best_a = [min(a[k]) for k in range(count)]
        best_b = [min(b[k]) for k in range(count)]
        ratios = [best_b[k] / best_a[k] for k in range(count)]
        change = statistics.geometric_mean(ratios)
        name = os.path.splitext(os.path.basename(script))[0]
        print("%-14s %12.0f %12.0f %+6.1f%%   over placements %+.1f..%+.1f%%"
              % (name, statistics.median(best_a), statistics.median(best_b), (change - 1) * 100,
                 (min(ratios) - 1) * 100, (max(ratios) - 1) * 100))


def main(args):
    if len(args) >= 3 and args[0] == "build":
        build(args[1], args[2], int(args[3]) if len(args) > 3 else COUNT)
    elif len(args) >= 4 and args[0] == "compare":
        compare(args[1], args[2], args[3:], COUNT)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
