#!/usr/bin/env python3
"""
test262 conformance runner for zjs.

What this does:
  1. Walks the configured subset of test262 (see config.json).
  2. Parses each test's frontmatter; skips tests that need features /
     harness includes / flags we don't support.
  3. For each runnable test: concatenates the required harness files +
     the test source into a temp file and runs `./build/zjs run <tmp>`.
  4. Compares the engine's outcome (exit 0 vs throw) with the expected
     outcome (`negative:` frontmatter says "should throw this error
     type"; absence says "should not throw").
  5. Writes:
        docs/conformance/last.json       — per-test status for the run
        docs/conformance/history.jsonl   — append-only summary row
        docs/conformance/index.html      — regenerated, with embedded
                                            history + current results

What this does NOT do:
  - Run in strict and sloppy mode separately. We treat all tests as
    strict-by-default; the `noStrict` / `onlyStrict` flags don't gate
    inclusion. (Tests that fail only in one mode may be misclassified;
    the numbers are still useful as a coarse trend.)
  - Verify error MESSAGES — only the thrown type (`SyntaxError`,
    `TypeError`, etc.) is matched.
  - Time-out individual tests. zjs has no loop-counter; an infinite
    loop will hang the runner. Trim aggressively if that happens.

Usage:
    python3 scripts/test262/run.py
    python3 scripts/test262/run.py --test262 /path/to/test262
    python3 scripts/test262/run.py --filter language/expressions/addition
    python3 scripts/test262/run.py --limit 100
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT  = Path(__file__).resolve().parent.parent.parent
CONFIG     = REPO_ROOT / "scripts" / "test262" / "config.json"
ZJS_BIN    = REPO_ROOT / "build" / "zjs"
OUT_DIR    = REPO_ROOT / "docs" / "conformance"
HISTORY    = OUT_DIR / "history.jsonl"
LAST_JSON  = OUT_DIR / "last.json"
HTML_PATH  = OUT_DIR / "index.html"

DEFAULT_TEST262 = REPO_ROOT / "vendor" / "test262"

# -----------------------------------------------------------------------------
# Frontmatter parsing.
#
# Each test262 file starts with a YAML-ish block:
#   /*---
#   description: foo
#   flags: [noStrict]
#   features: [Array.prototype.flat, class]
#   includes: [sta.js, assert.js]
#   negative:
#     phase: parse
#     type: SyntaxError
#   ---*/
#
# We don't pull in a YAML library — the format is regular enough to
# parse with a few regexes for the keys we care about.
# -----------------------------------------------------------------------------

FRONTMATTER_RE = re.compile(r"/\*---\s*\n(.*?)\n---\*/", re.S)

def parse_frontmatter(src: str):
    m = FRONTMATTER_RE.search(src)
    if not m:
        return {}
    body = m.group(1)
    out = {
        "features": [],
        "flags":    [],
        "includes": [],
        "negative": None,
    }

    def parse_list(line):
        # "features: [a, b, c]" or "features: a"
        rest = line.split(":", 1)[1].strip()
        if rest.startswith("["):
            inside = rest.strip("[]")
            return [t.strip() for t in inside.split(",") if t.strip()]
        return [t.strip() for t in rest.split(",") if t.strip()]

    in_negative = False
    for raw_line in body.splitlines():
        line = raw_line.rstrip()
        if not line.strip():
            in_negative = False
            continue
        stripped = line.lstrip()
        # Track "negative:" multi-line block (phase + type sub-keys).
        if stripped.startswith("negative:"):
            in_negative = True
            out["negative"] = {"phase": None, "type": None}
            tail = stripped.split(":", 1)[1].strip()
            if tail:
                # one-line form: "negative: { phase: parse, type: SyntaxError }"
                t = re.search(r"type:\s*([A-Za-z]+)", tail)
                p = re.search(r"phase:\s*([A-Za-z]+)", tail)
                if t: out["negative"]["type"]  = t.group(1)
                if p: out["negative"]["phase"] = p.group(1)
            continue
        if in_negative and line.startswith((" ", "\t")):
            if "phase:" in stripped:
                out["negative"]["phase"] = stripped.split(":", 1)[1].strip()
            elif "type:"  in stripped:
                out["negative"]["type"]  = stripped.split(":", 1)[1].strip()
            continue
        in_negative = False
        if stripped.startswith("features:"):
            out["features"] = parse_list(stripped)
        elif stripped.startswith("flags:"):
            out["flags"] = parse_list(stripped)
        elif stripped.startswith("includes:"):
            out["includes"] = parse_list(stripped)
    return out

# -----------------------------------------------------------------------------
# Test runner
# -----------------------------------------------------------------------------

def load_config():
    with open(CONFIG) as f:
        return json.load(f)

def gather_tests(test262_root, cfg, name_filter=None):
    """Return [(rel_path, abs_path)] sorted, optionally filtered by substring."""
    found = []
    for sub in cfg["include"]:
        root = test262_root / sub
        if not root.exists():
            continue
        for p in sorted(root.rglob("*.js")):
            rel = p.relative_to(test262_root)
            if name_filter and name_filter not in str(rel):
                continue
            if "_FIXTURE" in p.name:        # fixture files, not tests
                continue
            found.append((str(rel), p))
    return found

def should_skip(meta, cfg):
    """Return a reason string if the test should be skipped, else None."""
    skip_features = set(cfg.get("skip_features", []))
    skip_flags    = set(cfg.get("skip_flags", []))
    skip_includes = set(cfg.get("skip_includes", []))

    for f in meta.get("features", []):
        if f in skip_features:
            return f"feature:{f}"
    for fl in meta.get("flags", []):
        if fl in skip_flags:
            return f"flag:{fl}"
    for inc in meta.get("includes", []):
        if inc in skip_includes:
            return f"include:{inc}"
    return None

LOCAL_HARNESS = REPO_ROOT / "scripts" / "test262" / "zjs_harness.js"

# zjs CLI prints uncaught throws as:
#     zjs: throw: <ErrorTypeName>: <message>
# This regex pulls out the type name for exact-match negative tests.
ZJS_ERROR_TYPE_RE = re.compile(r"^zjs:\s*throw:\s*([A-Za-z][A-Za-z0-9_]*)", re.M)

# Markers in stderr that indicate the throw originated from the parse
# phase (lexer / parser / compiler) rather than runtime evaluation.
PARSE_PHASE_MARKERS = ("parse error", "compile error")

def extract_error_type(stderr: str) -> str:
    m = ZJS_ERROR_TYPE_RE.search(stderr or "")
    return m.group(1) if m else ""

def is_parse_phase_error(stderr: str) -> bool:
    s = stderr or ""
    return any(mk in s for mk in PARSE_PHASE_MARKERS)

def build_source(test262_root, test_src, meta, *, strict_mode: bool):
    """Prepend the harness (shim + listed includes) and, in strict mode,
    a `"use strict";` pragma. The pragma goes BEFORE the harness so the
    whole concatenated source runs in strict mode (matching spec —
    per INTERPRETING.md the directive prefix applies to the entire
    test source, including harness includes).

    raw flag: prepend nothing. The test runs as-is with no assertions
    library and no Test262Error class — typical for tests that exercise
    behavior of the implementation's bare globals.
    """
    flags = set(meta.get("flags", []))
    if "raw" in flags:
        return test_src
    parts = []
    if strict_mode:
        parts.append('"use strict";')
    parts.append(LOCAL_HARNESS.read_text())
    if "async" in flags:
        # Test262 async protocol: the test completes when print() is
        # called with the magic 'Test262:AsyncTestComplete' line, or
        # fails when 'Test262:AsyncTestFailure:...' is printed. We don't
        # have a host `print`, so install one that throws on the failure
        # signature and otherwise records completion in a side flag the
        # runner can grep for via stdout. The CLI prints flag-state to
        # stdout for us to inspect post-run.
        parts.append(LOCAL_ASYNC_HARNESS)
    harness = test262_root / "harness"
    for inc in meta.get("includes", []):
        if inc in ("sta.js", "assert.js"):
            continue
        f = harness / inc
        if f.exists():
            parts.append(f.read_text())
    parts.append(test_src)
    return "\n".join(parts)

# Tiny print shim for async-flag tests. The test calls
# print('Test262:AsyncTestComplete') on success; we surface that to
# stdout so the runner can detect it. Failures call
# print('Test262:AsyncTestFailure:<msg>') and we convert to a throw so
# our normal "uncaught throw → fail" path kicks in.
LOCAL_ASYNC_HARNESS = r"""
var __test262_async_done = false;
function print(msg) {
  if (typeof msg === 'string') {
    if (msg.indexOf('Test262:AsyncTestFailure:') === 0) {
      throw new Test262Error(msg);
    }
    if (msg === 'Test262:AsyncTestComplete') {
      __test262_async_done = true;
      // also echo via console so the runner can see it on stdout
      try { console.log('Test262:AsyncTestComplete'); } catch (e) {}
      return;
    }
  }
  try { console.log(msg); } catch (e) {}
}
"""

def execution_modes(meta):
    """Per INTERPRETING.md §"Strict Mode", each test runs twice (sloppy
    then strict) unless a flag says otherwise:
      - raw:        sloppy only, no harness (handled separately)
      - module:     module code, no strict-prefix transform
      - noStrict:   sloppy only
      - onlyStrict: strict only
    """
    flags = set(meta.get("flags", []))
    if "raw" in flags:    return ["sloppy"]   # raw also skips harness
    if "module" in flags: return ["sloppy"]   # modules implicitly strict; we don't add the pragma
    if "onlyStrict" in flags: return ["strict"]
    if "noStrict" in flags:   return ["sloppy"]
    return ["sloppy", "strict"]

def run_one(zjs_bin, source, timeout_s):
    """Run zjs on the given source. Returns (exit_code, stderr_text, stdout_text)."""
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(source)
        path = f.name
    try:
        r = subprocess.run(
            [str(zjs_bin), "run", path],
            capture_output=True, text=True,
            timeout=timeout_s,
        )
        return r.returncode, r.stderr, r.stdout
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT", ""
    finally:
        try: os.unlink(path)
        except OSError: pass

def classify(meta, exit_code, stderr, stdout=""):
    """Map (engine outcome, expected outcome) → 'pass' or 'fail (reason)'.

    Negative tests gate on both the error TYPE (exact match against the
    constructor name in the runner's stderr) and the PHASE (parse
    vs runtime — phase: parse requires the throw to come from the
    parser/compiler, not from running code).

    Async-flag tests follow test262's print()-based protocol: the test
    completes when stdout contains 'Test262:AsyncTestComplete'; a
    'Test262:AsyncTestFailure:' prefix or absence of the completion line
    is a failure.
    """
    threw = (exit_code != 0)
    if exit_code == -1:
        return ("fail", "timeout")
    if meta.get("negative"):
        expected_type  = (meta["negative"].get("type")  or "").strip()
        expected_phase = (meta["negative"].get("phase") or "").strip()
        if not threw:
            return ("fail", f"expected {expected_phase or 'any'}-phase throw of {expected_type}, no throw")
        got_type = extract_error_type(stderr)
        if expected_type and got_type != expected_type:
            return ("fail", f"expected {expected_type}, got {got_type or stderr.strip()[:60]}")
        if expected_phase == "parse" and not is_parse_phase_error(stderr):
            return ("fail", f"expected parse-phase {expected_type}, got runtime throw")
        if expected_phase == "runtime" and is_parse_phase_error(stderr):
            return ("fail", f"expected runtime {expected_type}, got parse-phase throw")
        return ("pass", "")
    if "async" in (meta.get("flags") or []):
        if threw:
            return ("fail", stderr.strip()[:120])
        if "Test262:AsyncTestComplete" not in (stdout or ""):
            return ("fail", "async test never signaled completion")
        return ("pass", "")
    # Positive test: should not throw.
    if threw:
        return ("fail", stderr.strip()[:120])
    return ("pass", "")

# -----------------------------------------------------------------------------
# HTML report
# -----------------------------------------------------------------------------

def write_html(out_path, history, last_summary, last_failures):
    history_json   = json.dumps(history)
    failures_json  = json.dumps(last_failures[:200])
    summary_json   = json.dumps(last_summary)
    html = f"""<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>zjs test262 conformance</title>
<style>
  body {{ font: 14px/1.4 -apple-system, BlinkMacSystemFont, sans-serif;
          max-width: 960px; margin: 2em auto; padding: 0 1em; color: #222; }}
  h1 {{ font-size: 1.4em; margin-bottom: 0.2em; }}
  .sub {{ color: #666; margin-bottom: 1.5em; }}
  .card {{ background: #fafafa; border: 1px solid #eee; border-radius: 6px;
           padding: 1em 1.25em; margin-bottom: 1.25em; }}
  .stat {{ display: inline-block; margin-right: 2em; }}
  .stat .n {{ font-size: 1.8em; font-weight: 600; display: block; }}
  .stat .l {{ color: #666; font-size: 0.85em; }}
  .pass {{ color: #2c7; }} .fail {{ color: #c44; }} .skip {{ color: #999; }}
  svg {{ display: block; }}
  table {{ border-collapse: collapse; width: 100%; font-size: 12px; }}
  th, td {{ text-align: left; padding: 4px 8px; border-bottom: 1px solid #eee; }}
  th {{ background: #f5f5f5; }}
  td.path {{ font-family: ui-monospace, SFMono-Regular, monospace; }}
  td.reason {{ color: #888; }}
  details {{ margin-top: 1em; }}
</style>

<h1>zjs — test262 conformance</h1>
<p class="sub">Generated <span id="when"></span>. Curated subset of test262; configuration in
<code>scripts/test262/config.json</code>. Numbers exclude tests skipped due to
unsupported features or harness includes.</p>

<div class="card">
  <div class="stat"><span class="n pass" id="pass">–</span><span class="l">passing</span></div>
  <div class="stat"><span class="n fail" id="fail">–</span><span class="l">failing</span></div>
  <div class="stat"><span class="n skip" id="skip">–</span><span class="l">skipped</span></div>
  <div class="stat"><span class="n" id="rate">–</span><span class="l">pass rate</span></div>
</div>

<div class="card">
  <strong>Test counts over time</strong>
  <div class="legend" style="margin: 0.4em 0; font-size: 0.85em; color: #666;">
    <span style="color:#2c7;">● passing</span> &nbsp;
    <span style="color:#c44;">● failing</span> &nbsp;
    <span style="color:#999;">● skipped</span>
  </div>
  <div id="chart"></div>
</div>

<details>
  <summary>First failures (up to 200)</summary>
  <table id="failures-table">
    <thead><tr><th>Test</th><th>Reason</th></tr></thead>
    <tbody></tbody>
  </table>
</details>

<script id="history-data" type="application/json">{history_json}</script>
<script id="failures-data" type="application/json">{failures_json}</script>
<script id="summary-data" type="application/json">{summary_json}</script>
<script>
  const history  = JSON.parse(document.getElementById('history-data').textContent);
  const failures = JSON.parse(document.getElementById('failures-data').textContent);
  const summary  = JSON.parse(document.getElementById('summary-data').textContent);

  document.getElementById('pass').textContent = summary.passed;
  document.getElementById('fail').textContent = summary.failed;
  document.getElementById('skip').textContent = summary.skipped;
  const denom = summary.passed + summary.failed;
  document.getElementById('rate').textContent =
    denom ? ((summary.passed / denom) * 100).toFixed(1) + '%' : '–';
  document.getElementById('when').textContent = summary.when || '';

  // SVG chart of passing / failing / skipped counts over time.
  const W = 900, H = 260, P = 40;
  function chart() {{
    if (!history.length) {{
      document.getElementById('chart').textContent = '(no history yet)';
      return;
    }}
    // Pick a nice round y-max above the biggest point we plot.
    let maxCount = 0;
    for (const r of history) {{
      maxCount = Math.max(maxCount, r.passed, r.failed, r.skipped);
    }}
    // Round up to a clean tick boundary (250, 500, 1000, 2000, ...).
    const niceSteps = [100, 250, 500, 1000, 2000, 5000];
    let step = niceSteps[niceSteps.length - 1];
    for (const s of niceSteps) {{
      if (Math.ceil(maxCount / s) * s <= s * 6) {{ step = s; break; }}
    }}
    const yMax = Math.max(step * 2, Math.ceil(maxCount / step) * step);
    const yMin = 0;

    const xs = (i) => P + (i / Math.max(history.length - 1, 1)) * (W - 2*P);
    const ys = (v) => H - P - ((v - yMin) / (yMax - yMin)) * (H - 2*P);

    let svg = `<svg viewBox="0 0 ${{W}} ${{H}}" width="100%">`;
    // axes
    svg += `<line x1="${{P}}" y1="${{H-P}}" x2="${{W-P}}" y2="${{H-P}}" stroke="#999"/>`;
    svg += `<line x1="${{P}}" y1="${{P}}"   x2="${{P}}"   y2="${{H-P}}" stroke="#999"/>`;
    // gridlines + y labels
    for (let v = 0; v <= yMax; v += step) {{
      const y = ys(v);
      svg += `<line x1="${{P}}" y1="${{y}}" x2="${{W-P}}" y2="${{y}}" stroke="#eee"/>`;
      svg += `<text x="${{P-6}}" y="${{y+3}}" text-anchor="end" fill="#888" font-size="10">${{v}}</text>`;
    }}

    // One series helper. Plots a polyline + last-value label.
    // (Drop per-point circles — once enough runs accumulate they fuzz
    // into a band and the polyline reads cleaner on its own.)
    function series(key, color) {{
      const pts = history.map((r, i) => ({{ x: xs(i), y: ys(r[key]), v: r[key], when: r.when }}));
      const d = pts.map(p => `${{p.x}},${{p.y}}`).join(' ');
      let out = `<polyline points="${{d}}" fill="none" stroke="${{color}}" stroke-width="1.5"/>`;
      const last = pts[pts.length - 1];
      out += `<text x="${{last.x + 6}}" y="${{last.y + 4}}" font-size="11" fill="${{color}}">${{last.v}}</text>`;
      return out;
    }}
    svg += series('passed',  '#2c7');
    svg += series('failed',  '#c44');
    svg += series('skipped', '#999');

    svg += '</svg>';
    document.getElementById('chart').innerHTML = svg;
  }}
  chart();

  const tbody = document.querySelector('#failures-table tbody');
  for (const f of failures) {{
    const tr = document.createElement('tr');
    tr.innerHTML = `<td class="path">${{f.path}}</td><td class="reason">${{f.reason || ''}}</td>`;
    tbody.appendChild(tr);
  }}
</script>
</html>
"""
    out_path.write_text(html)

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--test262", type=Path, default=DEFAULT_TEST262,
                    help="Path to the test262 checkout (default: vendor/test262)")
    ap.add_argument("--filter", type=str, default=None,
                    help="Only run tests whose path contains this substring")
    ap.add_argument("--limit",  type=int, default=0,
                    help="Limit total tests run (0 = no limit)")
    ap.add_argument("--timeout", type=float, default=5.0,
                    help="Per-test timeout in seconds")
    ap.add_argument("--no-record", action="store_true",
                    help="Run tests but don't append to history / write HTML")
    ap.add_argument("--quiet", action="store_true",
                    help="Don't print per-failure lines")
    args = ap.parse_args()

    if not ZJS_BIN.exists():
        print(f"error: {ZJS_BIN} not found — run `make` first", file=sys.stderr)
        return 2
    if not args.test262.exists():
        print(f"error: test262 not found at {args.test262}", file=sys.stderr)
        print(f"hint: clone it: git clone --depth=1 https://github.com/tc39/test262 {args.test262}", file=sys.stderr)
        return 2

    cfg = load_config()
    tests = gather_tests(args.test262, cfg, args.filter)
    if args.limit > 0:
        tests = tests[:args.limit]

    passed, failed, skipped = 0, 0, 0
    failure_log = []
    skipped_counts = {}

    for i, (rel, abs_path) in enumerate(tests):
        try:
            src = abs_path.read_text()
        except UnicodeDecodeError:
            skipped += 1
            skipped_counts["non-utf8"] = skipped_counts.get("non-utf8", 0) + 1
            continue
        meta = parse_frontmatter(src)
        skip_reason = should_skip(meta, cfg)
        if skip_reason:
            skipped += 1
            skipped_counts[skip_reason] = skipped_counts.get(skip_reason, 0) + 1
            continue

        # Per INTERPRETING.md: run each test in every applicable mode
        # (sloppy + strict by default; flags can restrict to one). A
        # test PASSES only when every scheduled mode passes. The first
        # failing mode determines the reported reason.
        modes = execution_modes(meta)
        verdict = "pass"
        reason  = ""
        failing_mode = ""
        for mode in modes:
            full = build_source(args.test262, src, meta,
                                strict_mode=(mode == "strict"))
            exit_code, stderr, stdout = run_one(ZJS_BIN, full, args.timeout)
            v, r = classify(meta, exit_code, stderr, stdout)
            if v != "pass":
                verdict = v
                reason  = r
                failing_mode = mode
                break
        if verdict == "pass":
            passed += 1
        else:
            failed += 1
            tagged_reason = f"[{failing_mode}] {reason}" if len(modes) > 1 else reason
            failure_log.append({"path": rel, "reason": tagged_reason})
            if not args.quiet:
                print(f"FAIL {rel}\n   {tagged_reason}")

        if (i + 1) % 100 == 0:
            print(f"... {i+1}/{len(tests)}  pass={passed} fail={failed} skip={skipped}",
                  file=sys.stderr)

    when = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    summary = {
        "when":    when,
        "total":   passed + failed + skipped,
        "passed":  passed,
        "failed":  failed,
        "skipped": skipped,
    }

    print()
    print(f"=== test262 summary ({when}) ===")
    print(f"  passed:  {passed}")
    print(f"  failed:  {failed}")
    print(f"  skipped: {skipped}")
    if passed + failed > 0:
        print(f"  pass rate: {passed / (passed + failed) * 100:.1f}%")

    if args.no_record:
        return 0

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # Append summary row.
    with open(HISTORY, "a") as f:
        f.write(json.dumps(summary) + "\n")

    # Full per-test results (truncate failures to 1000 entries).
    LAST_JSON.write_text(json.dumps({
        "summary":  summary,
        "failures": failure_log[:1000],
        "skip_counts": skipped_counts,
    }, indent=2))

    # Regenerate the HTML with embedded history.
    history = []
    with open(HISTORY) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try: history.append(json.loads(line))
            except json.JSONDecodeError: pass
    write_html(HTML_PATH, history, summary, failure_log)
    print(f"\nReport: {HTML_PATH.relative_to(REPO_ROOT)}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
