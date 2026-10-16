#!/usr/bin/env python3
"""
Differential test262 run: the reference engine and the Z engine, through
the reference runner's own harness assembly and classification.

Reuses scripts/test262/run.py for frontmatter parsing, harness
concatenation (sta.js + assert.js + includes), the strict/sloppy execution
modes, the curated subset in config.json, and the pass/fail rules. Only
the binaries differ: build/zjs-ref (reference, through the public ABI)
and build/zjsz (Z).

Usage:
    ./test262.py                          # the whole curated subset
    ./test262.py --filter language/expressions/addition
    ./test262.py --limit 200 --only-z      # skip the reference run
"""
import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE
sys.path.insert(0, str(ROOT / "scripts" / "test262"))
import run as ref  # noqa: E402

REF_BIN = HERE / "build" / "zjs-ref"
Z_BIN = HERE / "build" / "zjsz"


def run_engine(binary, source, timeout):
    exit_code, stderr, stdout = ref.run_one(binary, source, timeout)
    return exit_code, stderr, stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--test262", type=Path, default=ROOT / "vendor" / "test262")
    ap.add_argument("--include", action="append", help="suite directory (relative to the checkout) to run instead of the curated list; repeatable")
    ap.add_argument("--filter", type=str, default=None)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--timeout", type=float, default=5.0)
    ap.add_argument("--only-z", action="store_true", help="run the Z engine only")
    ap.add_argument("--show", type=int, default=25,
                    help="how many reference-pass / Z-fail tests to list")
    args = ap.parse_args()

    if not Z_BIN.exists():
        print(f"error: {Z_BIN} not found -- run ./build.sh", file=sys.stderr)
        return 2
    have_ref = REF_BIN.exists() and not args.only_z
    if not have_ref and not args.only_z:
        print(f"note: {REF_BIN} not found; running the Z engine only", file=sys.stderr)
    if not args.test262.exists():
        print(f"error: test262 not found at {args.test262}", file=sys.stderr)
        return 2

    cfg = ref.load_config()
    if args.include:
        cfg["include"] = args.include
    tests = ref.gather_tests(args.test262, cfg, args.filter)
    if args.limit:
        tests = tests[: args.limit]

    total = 0
    skipped = 0
    ref_pass = 0
    z_pass = 0
    both_pass = 0
    regressions = []   # reference passes, Z fails
    gains = []         # Z passes, reference fails
    for rel, path in tests:
        src = path.read_text(encoding="utf-8", errors="replace")
        meta = ref.parse_frontmatter(src)
        if ref.should_skip(meta, cfg):
            skipped += 1
            continue
        for mode in ref.execution_modes(meta):
            total += 1
            full = ref.build_source(args.test262, src, meta, strict_mode=(mode == "strict"))
            z_status, z_reason = ref.classify(meta, *run_engine(Z_BIN, full, args.timeout))
            if z_status == "pass":
                z_pass += 1
            if have_ref:
                r_status, r_reason = ref.classify(meta, *run_engine(REF_BIN, full, args.timeout))
                if r_status == "pass":
                    ref_pass += 1
                if r_status == "pass" and z_status == "pass":
                    both_pass += 1
                elif r_status == "pass":
                    regressions.append((f"{rel} [{mode}]", z_reason))
                elif z_status == "pass":
                    gains.append((f"{rel} [{mode}]", r_reason))

    print(f"tests run: {total} (skipped by config: {skipped})")
    if have_ref:
        print(f"reference passed: {ref_pass}   z passed: {z_pass}   both: {both_pass}   "
              f"gap: {ref_pass - z_pass}")
        print(f"reference-pass / z-fail: {len(regressions)}   z-pass / reference-fail: {len(gains)}")
        for name, reason in regressions[: args.show]:
            print(f"  Z FAIL  {name}: {reason}")
    else:
        print(f"z passed: {z_pass}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
