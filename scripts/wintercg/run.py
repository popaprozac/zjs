#!/usr/bin/env python3
"""
WinterTC Minimum Common API conformance runner for zjs.

There's no upstream `wintercg/api-test` repo (verified — the WinterTC55
org has 18 repos, none of them a test suite), so we ship our own
probes under `tests/wintercg/`. Each probe is a WPT-shaped .js file
calling test() / promise_test() / assert_* helpers from the harness
at scripts/wintercg/zjs_harness.js.

The runner:
  1. Concatenates the harness + each probe file
  2. Runs it under `./build/zjs run`
  3. Greps the @@WINTERCG_RESULTS_BEGIN@@…@@WINTERCG_RESULTS_END@@
     JSON blob the harness emits
  4. Aggregates per-area pass/fail
  5. Writes docs/wintercg/{last.json, history.jsonl, index.html}

Usage:
    python3 scripts/wintercg/run.py
    python3 scripts/wintercg/run.py --filter encoding
"""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT  = Path(__file__).resolve().parent.parent.parent
HARNESS    = REPO_ROOT / "scripts" / "wintercg" / "zjs_harness.js"
TESTS_DIR  = REPO_ROOT / "tests" / "wintercg"
OUT_DIR    = REPO_ROOT / "docs" / "wintercg"

# Same platform-tagging convention as scripts/test262/run.py and
# scripts/bench/run.py: macOS keeps the original (un-suffixed) output
# filenames; Windows and Linux land in `-windows` / `-linux` siblings.
IS_WINDOWS = sys.platform == "win32"
IS_LINUX   = sys.platform.startswith("linux")
PLATFORM_TAG = "windows" if IS_WINDOWS else ("linux" if IS_LINUX else None)
_suffix    = f"-{PLATFORM_TAG}" if PLATFORM_TAG else ""

def _host_subdir():
    """build/<os>-<arch> — matches build-windows.ps1 + the Makefile BUILD_DIR."""
    import platform as _pf
    os_ = "win" if IS_WINDOWS else ("linux" if IS_LINUX else "macos")
    m = _pf.machine().lower()
    arch = "arm64" if m in ("arm64", "aarch64") else ("x64" if m in ("x86_64", "amd64") else m)
    return f"{os_}-{arch}"

def _resolve_zjs(stem="zjs"):
    exe = stem + (".exe" if IS_WINDOWS else "")
    sub = REPO_ROOT / "build" / _host_subdir() / exe
    return sub if sub.exists() else REPO_ROOT / "build" / exe

ZJS_BIN    = _resolve_zjs()

RESULT_BEGIN = "@@WINTERCG_RESULTS_BEGIN@@"
RESULT_END   = "@@WINTERCG_RESULTS_END@@"

def run_probe(probe_path: Path, timeout: float = 30.0):
    """Run a single probe file; return {area, totals, results}."""
    src = HARNESS.read_text(encoding="utf-8") + "\n" + probe_path.read_text(encoding="utf-8")
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".js", delete=False, encoding="utf-8"
    ) as tf:
        tf.write(src)
        tmp_path = Path(tf.name)
    try:
        proc = subprocess.run(
            [str(ZJS_BIN), "run", str(tmp_path)],
            capture_output=True, text=True, timeout=timeout, encoding="utf-8",
            errors="replace",
        )
    except subprocess.TimeoutExpired:
        return {
            "area": probe_path.stem,
            "totals": {"pass": 0, "fail": 0, "timeout": 1, "error": 0},
            "results": [{"name": "(probe timed out)", "status": "timeout", "message": ""}],
            "stderr": "",
        }
    finally:
        try: tmp_path.unlink()
        except OSError: pass

    out = proc.stdout or ""
    err = proc.stderr or ""
    begin = out.find(RESULT_BEGIN)
    end   = out.find(RESULT_END)
    if begin < 0 or end < 0 or end < begin:
        return {
            "area": probe_path.stem,
            "totals": {"pass": 0, "fail": 0, "timeout": 0, "error": 1},
            "results": [{
                "name": "(probe crashed before reporting)",
                "status": "error",
                "message": err.strip()[-400:],
            }],
            "stderr": err,
        }
    blob = out[begin + len(RESULT_BEGIN):end].strip()
    try:
        data = json.loads(blob)
    except json.JSONDecodeError as e:
        return {
            "area": probe_path.stem,
            "totals": {"pass": 0, "fail": 0, "timeout": 0, "error": 1},
            "results": [{
                "name": "(probe output not parseable)",
                "status": "error",
                "message": f"{e}: {blob[:200]}",
            }],
            "stderr": err,
        }
    totals = dict(data.get("totals", {}))
    totals.setdefault("pass", 0)
    totals.setdefault("fail", 0)
    totals.setdefault("timeout", 0)
    totals.setdefault("error", 0)
    return {
        "area": probe_path.stem,
        "totals": totals,
        "results": data.get("results", []),
        "stderr": err,
    }


def render_html(summary: dict) -> str:
    rows = []
    for area in summary["areas"]:
        t = area["totals"]
        n = sum(t.values())
        pct = (100.0 * t["pass"] / n) if n else 0.0
        color = "#0a0" if t["fail"] + t.get("error", 0) + t.get("timeout", 0) == 0 else "#a00"
        rows.append(
            f"<tr><td>{area['area']}</td>"
            f"<td style='color:{color}'>{t['pass']}/{n}</td>"
            f"<td>{pct:.0f}%</td>"
            f"<td>{t['fail']}</td>"
            f"<td>{t.get('error',0)}</td>"
            f"<td>{t.get('timeout',0)}</td></tr>"
        )
    rows_html = "\n".join(rows)
    t = summary["totals"]
    n = sum(t.values())
    pct = (100.0 * t["pass"] / n) if n else 0.0
    return (
        "<!doctype html>\n<html><head><meta charset='utf-8'>"
        "<title>zjs — WinterTC MCA conformance</title>"
        "<style>"
        "body{font-family:-apple-system,system-ui,sans-serif;max-width:800px;"
        "margin:2em auto;padding:0 1em;color:#222}"
        "h1{font-size:1.5em}"
        "table{border-collapse:collapse;width:100%;margin:1em 0}"
        "th,td{text-align:left;padding:0.4em 0.8em;border-bottom:1px solid #ddd}"
        "th{background:#f5f5f5}"
        ".totals{font-size:1.2em;padding:0.6em 0.8em;background:#f5f5f5;"
        "border-radius:4px}"
        "</style></head><body>"
        "<h1>zjs — WinterTC Minimum Common API conformance</h1>"
        f"<p>{summary['when']} · zjs build at {summary['zjs_bin']}</p>"
        "<div class='totals'>"
        f"<strong>Overall:</strong> {t['pass']}/{n} pass ({pct:.1f}%) · "
        f"fail {t['fail']} · error {t.get('error',0)} · timeout {t.get('timeout',0)}"
        "</div><table>"
        "<tr><th>Area</th><th>Pass</th><th>%</th><th>Fail</th><th>Err</th><th>T/O</th></tr>"
        f"{rows_html}</table>"
        "<p style='color:#888;font-size:0.9em'>"
        "Probes live in <code>tests/wintercg/</code> · harness at "
        "<code>scripts/wintercg/zjs_harness.js</code> · re-run with "
        "<code>make wintercg</code>.</p>"
        "</body></html>\n"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--filter", help="Only run probes whose stem contains this substring.")
    ap.add_argument("--verbose", action="store_true", help="Print per-test detail.")
    args = ap.parse_args()

    if not ZJS_BIN.exists():
        build_hint = ("powershell -File scripts\\build-windows.ps1"
                      if IS_WINDOWS else "make cli")
        sys.stderr.write(f"error: {ZJS_BIN} not found. Run `{build_hint}` first.\n")
        return 2
    if not HARNESS.exists():
        sys.stderr.write(f"error: harness not found at {HARNESS}\n")
        return 2
    if not TESTS_DIR.exists():
        sys.stderr.write(f"error: no probes under {TESTS_DIR}\n")
        return 2

    probes = sorted(TESTS_DIR.glob("*.js"))
    if args.filter:
        probes = [p for p in probes if args.filter in p.stem]
    if not probes:
        sys.stderr.write("error: no probes matched.\n")
        return 1

    print(f"running {len(probes)} probe(s)…")
    areas = []
    overall = {"pass": 0, "fail": 0, "timeout": 0, "error": 0}
    for p in probes:
        area = run_probe(p)
        for k, v in area["totals"].items():
            overall[k] = overall.get(k, 0) + v
        areas.append(area)
        t = area["totals"]
        n = sum(t.values())
        bad = t["fail"] + t.get("error", 0) + t.get("timeout", 0)
        status_blob = "OK " if bad == 0 else "FAIL"
        print(f"  [{status_blob}] {area['area']:18s}  {t['pass']:3d}/{n:<3d}")
        if args.verbose or bad > 0:
            for r in area["results"]:
                if r["status"] != "pass":
                    print(f"        - {r['status']}: {r['name']}: {r['message']}")

    when = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    summary = {
        "when": when,
        "zjs_bin": str(ZJS_BIN),
        "totals": overall,
        "areas": areas,
    }
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUT_DIR / f"last{_suffix}.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    history_path = OUT_DIR / f"history{_suffix}.jsonl"
    history_row = {
        "when": when,
        "totals": overall,
        "by_area": {a["area"]: a["totals"] for a in areas},
    }
    with history_path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(history_row) + "\n")
    (OUT_DIR / f"index{_suffix}.html").write_text(render_html(summary), encoding="utf-8")

    n = sum(overall.values())
    pct = (100.0 * overall["pass"] / n) if n else 0.0
    print()
    print(f"=== wintercg summary ({when}) ===")
    print(f"  pass:    {overall['pass']}")
    print(f"  fail:    {overall['fail']}")
    print(f"  error:   {overall.get('error', 0)}")
    print(f"  timeout: {overall.get('timeout', 0)}")
    print(f"  rate:    {pct:.1f}%")
    print(f"Report: {OUT_DIR / 'index.html'}")
    return 0 if overall["fail"] == 0 and overall.get("error", 0) == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
