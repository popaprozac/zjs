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

# Force UTF-8 on stdout/stderr — Windows's default text encoding
# (cp1252) chokes on the replacement char (�) and other
# non-Latin-1 codepoints that show up in test262 failure messages.
# Python ≥ 3.7 supports `reconfigure`; safe no-op everywhere else.
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass

REPO_ROOT  = Path(__file__).resolve().parent.parent.parent
CONFIG     = REPO_ROOT / "scripts" / "test262" / "config.json"
OUT_DIR    = REPO_ROOT / "docs" / "conformance"

# Same platform-tagging convention as scripts/bench/run.py: macOS keeps
# the original (un-suffixed) filenames; Windows and Linux land in
# `-windows` / `-linux` siblings so the three streams don't pollute one
# another's history.
IS_WINDOWS  = sys.platform == "win32"
IS_LINUX    = sys.platform.startswith("linux")
if IS_WINDOWS:
    PLATFORM_TAG = "windows"
    PLATFORM_LABEL = "Windows"
elif IS_LINUX:
    PLATFORM_TAG = "linux"
    PLATFORM_LABEL = "Linux"
else:
    PLATFORM_TAG = None
    PLATFORM_LABEL = "macOS"
ZJS_BIN     = REPO_ROOT / "build" / ("zjs.exe" if IS_WINDOWS else "zjs")
_suffix     = f"-{PLATFORM_TAG}" if PLATFORM_TAG else ""
HISTORY     = OUT_DIR / f"history{_suffix}.jsonl"
LAST_JSON   = OUT_DIR / f"last{_suffix}.json"
HTML_PATH   = OUT_DIR / f"index{_suffix}.html"

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
    with open(CONFIG, encoding="utf-8") as f:
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
    harness = test262_root / "harness"
    # Always prepend test262's own sta.js + assert.js — the real harness
    # defines Test262Error, the canonical SameValue / throws semantics,
    # NaN / -0 handling, etc. We used a local shim before switch landed
    # (assert.js uses switch internally). assert.throws verifies
    # thrown.constructor against the expected ctor — every
    # *Error.prototype.constructor needs to point back at itself for
    # that to discriminate (we wire that in ctx_init_builtins).
    parts.append((harness / "sta.js").read_text(encoding="utf-8"))
    parts.append((harness / "assert.js").read_text(encoding="utf-8"))
    if "async" in flags:
        # Test262 async protocol: the test completes when print() is
        # called with the magic 'Test262:AsyncTestComplete' line, or
        # fails when 'Test262:AsyncTestFailure:...' is printed. We don't
        # have a host `print`, so install one that throws on the failure
        # signature and otherwise records completion in a side flag the
        # runner can grep for via stdout. The CLI prints flag-state to
        # stdout for us to inspect post-run.
        parts.append(LOCAL_ASYNC_HARNESS)
    for inc in meta.get("includes", []):
        if inc in ("sta.js", "assert.js"):
            continue
        f = harness / inc
        if f.exists():
            parts.append(f.read_text(encoding="utf-8"))
    parts.append(test_src)
    return "\n".join(parts)

# Tiny print shim for async-flag tests. The test calls
# print('Test262:AsyncTestComplete') on success; we surface that to
# stdout so the runner can detect it. Failures call
# print('Test262:AsyncTestFailure:<msg>') and we convert to a throw so
# our normal "uncaught throw → fail" path kicks in.
LOCAL_ASYNC_HARNESS = r"""
var __test262_async_done = false;
// IMPORTANT: the failure path must NOT throw. $DONE is almost always
// invoked from inside a .then() callback (e.g. `p.then($DONE, $DONE)`),
// so a throw here becomes an *unhandled promise rejection* — which the
// engine surfaces silently (exit 0, no stdout). That masked every
// failing async test as the generic "never signaled completion" and hid
// its real reason. Instead, record the verdict to stdout and let the
// runner classify. $DONE is made idempotent so the first verdict wins
// (matches the spec's "first call decides" intent the throw used to
// enforce by aborting the chain).
function print(msg) {
  if (typeof msg === 'string' &&
      (msg.indexOf('Test262:AsyncTestFailure:') === 0 ||
       msg === 'Test262:AsyncTestComplete')) {
    if (msg === 'Test262:AsyncTestComplete') { __test262_async_done = true; }
    try { console.log(msg); } catch (e) {}
    return;
  }
  try { console.log(msg); } catch (e) {}
}
// $DONE: ECMAScript-shaped callback used by promiseHelper.js and
// many async tests in place of print. $DONE() → success;
// $DONE(error) → failure carrying the thrown value.
function $DONE(error) {
  if (__test262_async_done) { return; }   // first verdict wins; no-op after
  if (error) {
    __test262_async_done = true;
    var name = (error && typeof error === 'object' && 'name' in error)
                 ? error.name : 'Test262Error';
    var msg  = (error && typeof error === 'object' && 'message' in error)
                 ? error.message : String(error);
    print('Test262:AsyncTestFailure:' + name + ': ' + msg);
  } else {
    print('Test262:AsyncTestComplete');
  }
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

def run_one(zjs_bin, source, timeout_s, aot=False):
    """Run zjs on the given source. Returns (exit_code, stderr_text, stdout_text).

    In aot mode: compile the source to a .zbc bytecode file first, then
    run THAT instead of the .js. Used by `--aot` to flush out any
    serialization gaps — a regression vs the non-aot run means an op or
    Function field isn't round-tripping correctly.
    """
    # Force UTF-8 on the tempfile — test262 sources are UTF-8, and on
    # Windows the default text-mode encoding (cp1252) chokes on the
    # full Unicode range (arrows, math symbols, etc).
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False,
                                     encoding="utf-8") as f:
        f.write(source)
        path = f.name
    zbc_path = path + ".zbc"
    try:
        if aot:
            # Compile to bytecode. If the compile itself fails (parser
            # error, syntax-error-on-purpose tests, etc.) we still
            # return that as the engine outcome — same shape classify()
            # expects from a runtime throw. The bytecode-eval branch
            # below only runs on successful compile.
            cr = subprocess.run(
                [str(zjs_bin), "compile", path, "-o", zbc_path],
                capture_output=True,
                timeout=timeout_s,
            )
            if cr.returncode != 0:
                return cr.returncode, cr.stderr.decode("utf-8", errors="replace"), \
                       cr.stdout.decode("utf-8", errors="replace")
            run_target = zbc_path
        else:
            run_target = path

        # Capture as bytes so tests with non-UTF8 throws (intentional or
        # accidental) don't blow up the runner's decoder. Decode with
        # errors="replace" to keep classify happy.
        r = subprocess.run(
            [str(zjs_bin), "run", run_target],
            capture_output=True,
            timeout=timeout_s,
        )
        return r.returncode, r.stderr.decode("utf-8", errors="replace"), r.stdout.decode("utf-8", errors="replace")
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT", ""
    finally:
        for p in (path, zbc_path):
            try: os.unlink(p)
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
        out = stdout or ""
        # The harness now records a failure verdict on stdout instead of
        # throwing it into a swallowed microtask. Surface the real reason.
        fidx = out.find("Test262:AsyncTestFailure:")
        if fidx >= 0:
            line = out[fidx:].splitlines()[0]
            reason = line[len("Test262:AsyncTestFailure:"):].strip()
            return ("fail", ("async: " + reason)[:120])
        if "Test262:AsyncTestComplete" not in out:
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
    platform_label = (last_summary.get("platform") or "macOS").strip()
    html = f"""<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>zjs test262 conformance — {platform_label}</title>
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

<h1>zjs — test262 conformance <span style="font-size:0.65em;color:#888;font-weight:normal;">({platform_label})</span></h1>
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
    out_path.write_text(html, encoding="utf-8")

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
    ap.add_argument("--record-filter", action="store_true",
                    help="Allow recording even with --filter/--limit. By default "
                         "partial runs are quarantined from the dashboard since "
                         "their numbers aren't comparable to the full sweep.")
    ap.add_argument("--quiet", action="store_true",
                    help="Don't print per-failure lines")
    ap.add_argument("--full-suite", action="store_true",
                    help="Override config: run all of test/language/ + "
                         "test/built-ins/ with NO feature skips. Reports "
                         "the test262.fyi-style 'absolute methodology' "
                         "number — missing-feature failures count as "
                         "failures, not skips. Forces --no-record so it "
                         "doesn't pollute the curated dashboard.")
    ap.add_argument("--aot", action="store_true",
                    help="Round-trip every test through the AOT pipeline: "
                         "compile to .zbc, then eval the bytecode. Used to "
                         "validate AOT serializer/deserializer coverage. "
                         "Forces --no-record (these numbers aren't the "
                         "conformance dashboard's).")
    args = ap.parse_args()

    if not ZJS_BIN.exists():
        print(f"error: {ZJS_BIN} not found — run `make` first", file=sys.stderr)
        return 2
    if not args.test262.exists():
        print(f"error: test262 not found at {args.test262}", file=sys.stderr)
        print(f"hint: clone it: git clone --depth=1 https://github.com/tc39/test262 {args.test262}", file=sys.stderr)
        return 2

    cfg = load_config()
    if args.full_suite:
        # Match the test262.fyi methodology: full language + built-ins,
        # exclude intl402 (Intl is its own optional opt-in) and annexB
        # (legacy/host-optional). Zero out the feature skip-list so
        # missing-feature tests run and count as failures rather than
        # being filtered out — the point of this mode is honest framing.
        cfg = dict(cfg)
        cfg["include"] = ["test/language", "test/built-ins"]
        cfg["skip_features"] = []
        cfg["skip_includes"] = []
        args.no_record = True
        print("[full-suite] running against test/language + test/built-ins "
              "with no feature skips. This does NOT update the curated "
              "dashboard — it's a one-shot 'where are we vs the full spec' "
              "measurement.", file=sys.stderr)
    if args.aot:
        args.no_record = True
        print("[aot] every test compiled to .zbc then run from bytecode. "
              "Counts AOT-pipeline regressions vs the normal run.",
              file=sys.stderr)

    tests = gather_tests(args.test262, cfg, args.filter)
    if args.limit > 0:
        tests = tests[:args.limit]

    passed, failed, skipped = 0, 0, 0
    failure_log = []
    skipped_counts = {}

    for i, (rel, abs_path) in enumerate(tests):
        try:
            src = abs_path.read_text(encoding="utf-8")
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
            exit_code, stderr, stdout = run_one(ZJS_BIN, full, args.timeout, aot=args.aot)
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
        "platform": PLATFORM_LABEL,
    }

    print()
    print(f"=== test262 summary ({when}) ===")
    print(f"  passed:  {passed}")
    print(f"  failed:  {failed}")
    print(f"  skipped: {skipped}")
    if passed + failed > 0:
        print(f"  pass rate: {passed / (passed + failed) * 100:.1f}%")

    if args.aot:
        # AOT mode skips the main dashboard but writes its own failure
        # dump so a follow-up diff can isolate serialization gaps.
        aot_path = OUT_DIR / "last-aot.json"
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        with open(aot_path, "w", encoding="utf-8") as f:
            json.dump({"summary": summary, "failures": failure_log}, f, indent=2)
        print(f"\nAOT failure log: {aot_path}")
    if args.no_record:
        return 0

    # Partial runs (filter/limit) get quarantined from the main dashboard
    # by default: their pass-counts aren't comparable to the full sweep
    # and the trend line dips spuriously if they land in history.jsonl.
    # Pass --record-filter to opt back in if you actually want a row.
    partial = bool(args.filter) or args.limit > 0
    if partial and not args.record_filter:
        print()
        print("note: partial run (filter/limit set) — not recording to "
              "history / dashboard.")
        print("      Pass --record-filter to override, or run without "
              "filter for a real measurement.")
        return 0

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # Append summary row.
    with open(HISTORY, "a", encoding="utf-8") as f:
        f.write(json.dumps(summary) + "\n")

    # Full per-test results (truncate failures to 1000 entries).
    LAST_JSON.write_text(json.dumps({
        "summary":  summary,
        "failures": failure_log,
        "skip_counts": skipped_counts,
    }, indent=2), encoding="utf-8")

    # Regenerate the HTML with embedded history.
    history = []
    with open(HISTORY, encoding="utf-8") as f:
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
