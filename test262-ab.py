#!/usr/bin/env python3
"""
A/B over test262: two builds of the Z engine, every test in the curated
subset in every execution mode, and the tests whose outcome differs.

The evidence behind "0 regressions, N fixes" in a commit message. Uses the
harness assembly and pass/fail rules in scripts/test262/run.py, a 5 s
timeout per test. Without a directory it runs the curated subset in
scripts/test262/config.json; a directory is run whole, whether or not the
subset includes it (RegExp, for one, is outside it). --aot runs AFTER
through bytecode files (each module of a graph through a module file), so
one build given twice shows what differs from source; a script that does
not compile is reported by `zjsz compile` without its error type, so its
negative SyntaxError tests show as regressions there.

Usage:
    ./test262-ab.py BEFORE AFTER                        # the curated subset
    ./test262-ab.py BEFORE AFTER test/built-ins/RegExp  # one directory
    ./test262-ab.py ZJSZ ZJSZ --aot [DIRECTORY]         # from bytecode
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE
sys.path.insert(0, str(ROOT / "scripts" / "test262"))
import run as ref  # noqa: E402

aot = "--aot" in sys.argv
args = [a for a in sys.argv[1:] if a != "--aot"]
if len(args) not in (2, 3):
    sys.exit(__doc__.strip().split("\n\n")[-1])
before, after = args[0], args[1]
prefix = args[2] if len(args) == 3 else ""
suite = ROOT / "vendor" / "test262"
cfg = ref.load_config()
if prefix:
    cfg["include"] = [prefix.rstrip("/")]
regressions, fixes, total = [], [], 0
for rel, path in ref.gather_tests(suite, cfg, None):
    if not rel.startswith(prefix):
        continue
    src = path.read_text(encoding="utf-8", errors="replace")
    meta = ref.parse_frontmatter(src)
    if ref.should_skip(meta, cfg):
        continue
    for mode in ref.execution_modes(meta):
        total += 1
        full, module_path = ref.assemble(suite, src, meta, path, strict_mode=(mode == "strict"))
        where = ref.script_directory(meta, path)
        old, _ = ref.classify(meta, *ref.run_one(before, full, 5.0, module_path=module_path, script_dir=where))
        new, reason = ref.classify(meta, *ref.run_one(after, full, 5.0, aot=aot, module_path=module_path, script_dir=where))
        if old == "pass" and new != "pass":
            regressions.append(f"{rel} [{mode}]: {reason}")
        elif old != "pass" and new == "pass":
            fixes.append(f"{rel} [{mode}]")
print(f"tests: {total}  regressions: {len(regressions)}  fixes: {len(fixes)}")
for line in regressions:
    print("REGRESSION", line)
for line in fixes:
    print("FIXED", line)
