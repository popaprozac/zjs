#!/usr/bin/env python3
"""
test262 counted the way test262.fyi counts it, so the number compares with
the engines on that dashboard. The rules are its runner's
(github.com/test262-fyi/data: runner/read.js, runner/index.js, util.js and
controller/oom-killer.js), not test262.py's:

- One test is one file under test/, every directory (harness/ too), files
  named *_FIXTURE* left out. No feature or directory is skipped.
- The source as run, joined with no separators: "use strict" for onlyStrict,
  doneprintHandle.js for async, the files an inline `includes: [...]` names,
  the host runtime (RUNTIME below), assert.js, sta.js, the test. A raw test
  runs as it is. Flags come from an inline `flags: [...]` or a `  - x` list.
- A file passes if its run passes and, unless it is module, onlyStrict,
  noStrict or raw, a second run with "use strict" prepended passes too.
- A run fails if it exits nonzero, is killed (10 s, or 1 GiB resident), or
  prints "error", "exception" or "panic" in any case. A negative test passes
  when its run fails that way and the output holds the expected type's name;
  the phase is not checked. An async test also needs
  Test262:AsyncTestComplete in its output.

Each run's source is written beside the test as <test>.zjs, as the dashboard
does, so that relative imports resolve; give a copy of the suite when
something else reads the tree. One JSON line a file to OUT.

Usage:
    ./test262-fyi.py ZJSZ OUT.jsonl [--suite DIR] [--prefix test/built-ins] [--jobs N]
"""
import argparse
import concurrent.futures
import json
import os
import re
import signal
import subprocess
import sys
import threading
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent

# The host hooks of INTERPRETING.md that zjsz has, in the form the
# dashboard's adapters give them (Hermes, Nova, njs: evalScript is eval).
# zjsz has no createRealm, agent, IsHTMLDDA or AbstractModuleSource.
RUNTIME = r"""function print(s) { console.log(s); }
var $262 = {
  detachArrayBuffer: function (buffer) { if (!buffer.detached) buffer.transfer(); },
  evalScript: function (code) { return (0, eval)(code); },
  gc: function () { gc(); },
  global: globalThis
};
"""

TIMEOUT_S = 10                     # util.js: spawnSync's timeout
MEMORY_LIMIT = 1024 * 1024 * 1024  # oom-killer.js: resident bytes

# read.js's regexes in JavaScript's meaning: with the m flag, ^ and $ meet
# any line terminator and . matches none, so a CRLF file's frontmatter
# reads as it does there (5 files at aae8cf6).
_T = "\n\r  "
_D, _B, _E = f"[^{_T}]", f"(?:(?<=[{_T}])|\\A)", f"(?=[{_T}]|\\Z)"
FLAGS = re.compile(_B + r"flags: \[(" + _D + r"*)\]" + _E)
FLAG_LIST = re.compile(_B + r"flags:\n(  - " + _D + r"*\s*\n)+")
INCLUDES = re.compile(_B + r"includes: \[(" + _D + r"*)\]" + _E)
NEGATIVE = re.compile(_B + r"negative:\s*\n\s*phase:\s*(" + _D + r"*)\s*\n\s*type:\s*(" + _D + r"*)\s*" + _E)


def preludes_of(harness):
    """harness/*.js and harness/<dir>/*.js by name, as index.js reads them."""
    out = {}
    for p in sorted(harness.iterdir()):
        if p.is_dir() and "." not in p.name:
            for q in sorted(p.glob("*.js")):
                out[f"{p.name}/{q.name}"] = q.read_bytes().decode("utf-8", "replace")
        elif p.name.endswith(".js"):
            out[p.name] = p.read_bytes().decode("utf-8", "replace")
    return out


def read_test(src, preludes):
    """read.js for one file: (source as run, flags, negative, strict rerun).
    negative is None for a positive test, else the type name ("" checks none)."""
    m = FLAGS.search(src)
    raw = m.group(1) if m else None
    if not raw and "flags:" in src:
        m = FLAG_LIST.search(src)
        raw = m.group(0).replace("\n  - ", ",")[7:-1] if m else None
    flags = {x.strip() for x in raw.split(",")} if raw else set()
    m = INCLUDES.search(src)
    if "raw" not in flags:
        src = (('"use strict";\n' if "onlyStrict" in flags else "")
               + (preludes["doneprintHandle.js"] if "async" in flags else "")
               + "".join(preludes.get(x.strip(), "") for x in (m.group(1) if m else "").split(","))
               + RUNTIME + preludes["assert.js"] + preludes["sta.js"] + src)
    m = NEGATIVE.search(src)  # on the assembled source, as read.js does
    negative = m.group(2) if m else ("" if "negative" in flags else None)
    rerun = not flags & {"module", "onlyStrict", "noStrict", "raw"}
    return src, flags, negative, rerun


def passed(negative, flags, failed, output):
    """index.js's verdict on one run."""
    low = output.lower()
    has_error = failed or "error" in low or "exception" in low or "panic" in low
    if negative is not None:
        return has_error and (not negative or negative in output)
    return not has_error and ("async" not in flags or "Test262:AsyncTestComplete" in output)


killed = set()  # pids the memory watcher killed


def watch_memory(test_dir, stop):
    """oom-killer.js: every 0.5 s, kill a run over the limit."""
    while not stop.wait(0.5):
        ps = subprocess.run(["ps", "-axo", "pid=,rss=,command="], capture_output=True, text=True).stdout
        for line in ps.splitlines():
            m = re.match(r"\s*(\d+)\s+(\d+)\s+(.+)", line)
            if m and test_dir in m.group(3) and int(m.group(2)) * 1024 >= MEMORY_LIMIT:
                try:
                    os.kill(int(m.group(1)), signal.SIGKILL)
                    killed.add(int(m.group(1)))
                except OSError:
                    pass


def run(zjsz, path, source, module):
    """One run: (failed, output, why). ulimit -t backs up the timeout."""
    tmp = str(path) + ".zjs"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(source)
    cmd = ["/bin/sh", "-c", 'ulimit -t 30; exec "$0" "$@"', zjsz, "run", "--expose-gc"]
    cmd += ["--module", tmp] if module else [tmp]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            out, err = proc.communicate(timeout=TIMEOUT_S)
            why = "memory" if proc.pid in killed else f"exit {proc.returncode}"
        except subprocess.TimeoutExpired:
            proc.kill()
            out, err = proc.communicate()
            why = "timeout"
    finally:
        os.unlink(tmp)
    output = out.decode("utf-8", "replace") + "\n" + err.decode("utf-8", "replace")
    return proc.returncode != 0 or why == "timeout", output, why


def one(zjsz, test_dir, preludes, path):
    source, flags, negative, rerun = read_test(path.read_bytes().decode("utf-8", "replace"), preludes)
    runs = []
    for strict in ([False, True] if rerun else [False]):
        failed, output, why = run(zjsz, path, '"use strict";\n' + source if strict else source, "module" in flags)
        ok = passed(negative, flags, failed, output)
        runs.append({"strict": strict, "why": "" if ok else (why + ": " + " ".join(output.split())[:120]).strip()})
        if not ok:  # index.js: pass &&= run(...) skips the strict copy
            break
    return {"file": str(path.relative_to(test_dir)), "pass": all(not r["why"] for r in runs), "runs": runs}


def check():
    pre = {"doneprintHandle.js": "D;", "assert.js": "A;", "sta.js": "S;", "a.js": "I;"}
    src, flags, neg, rerun = read_test("/*---\nflags: [onlyStrict, async]\nincludes: [a.js]\n---*/\nx;", pre)
    assert flags == {"onlyStrict", "async"} and not rerun and neg is None
    assert src == '"use strict";\nD;I;' + RUNTIME + "A;S;/*---\nflags: [onlyStrict, async]\nincludes: [a.js]\n---*/\nx;"
    _, flags, neg, rerun = read_test("/*---\nflags:\n  - noStrict\n  - module\nnegative:\n  phase: parse\n  type: SyntaxError\n---*/", pre)
    assert flags == {"noStrict", "module"} and neg == "SyntaxError" and not rerun
    src, _, _, rerun = read_test("/*---\r\nincludes: [a.js]\r\n---*/\r\n", pre)
    assert src.startswith("I;") and rerun
    assert passed("SyntaxError", set(), True, "zjs: throw: SyntaxError: x") and not passed("TypeError", set(), True, "SyntaxError")
    assert not passed(None, set(), False, "an Error printed") and passed(None, set(), False, "")
    assert not passed(None, {"async"}, False, "") and passed(None, {"async"}, False, "Test262:AsyncTestComplete\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.strip().split("\n\n")[0])
    ap.add_argument("zjsz")
    ap.add_argument("out")
    ap.add_argument("--suite", default=str(ROOT / "vendor" / "test262"))
    ap.add_argument("--prefix", default="test/", help="only files under this path of the suite")
    ap.add_argument("--jobs", type=int, default=8)
    a = ap.parse_args()
    check()
    suite = Path(a.suite).resolve()
    test_dir = suite / "test"
    preludes = preludes_of(suite / "harness")
    paths = sorted(p for p in (suite / a.prefix).rglob("*.js") if "_FIXTURE" not in p.name)
    zjsz = str(Path(a.zjsz).resolve())
    stop = threading.Event()
    threading.Thread(target=watch_memory, args=(str(test_dir), stop), daemon=True).start()
    total, passes = Counter(), Counter()
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as pool, open(a.out, "w") as out:
        for row in pool.map(lambda p: one(zjsz, test_dir, preludes, p), paths):
            out.write(json.dumps(row) + "\n")
            top = row["file"].split("/")[0]
            total[top] += 1
            passes[top] += row["pass"]
    stop.set()
    for top in sorted(total):
        print(f"{top:10} {passes[top]:6} / {total[top]:6}  {100 * passes[top] / total[top]:5.1f}%")
    n, p = sum(total.values()), sum(passes.values())
    print(f"{'total':10} {p:6} / {n:6}  {100 * p / n:5.1f}%")


if __name__ == "__main__":
    main()
