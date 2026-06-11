#!/usr/bin/env python3
"""
zjs perf benchmark runner.

Walks scripts/bench/*.js, times each script under `./build/zjs run`,
records the median over a few iterations, appends to a history file,
and regenerates an HTML report.

Each benchmark script is a complete JS program. The runner times the
whole `zjs run <file>` invocation (parse + compile + interpret), so
the resulting number is end-to-end wall-clock — useful for tracking
zjs-vs-zjs deltas over commits, not for cross-engine comparison.

Usage:
    python3 scripts/bench/run.py
    python3 scripts/bench/run.py --iters 7         # default 5
    python3 scripts/bench/run.py --filter int      # only matching names
    python3 scripts/bench/run.py --no-record       # don't append history
"""

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# Force UTF-8 on stdout/stderr — bench output rarely needs it but
# the few characters in the labels (Δ, ×) trip cp1252 on Windows.
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
BENCH_DIR = REPO_ROOT / "scripts" / "bench"
OUT_DIR   = REPO_ROOT / "docs" / "perf"

# Platform-specific output stream: macOS keeps the original (un-suffixed)
# filenames; Windows and Linux land in `-windows` / `-linux` siblings so
# the three streams don't interleave on the same history chart. Same
# idea for the report title further down.
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
# #392: canonical bench numbers come from the PGO build (`make cli-pgo`).
# $ZJS_BIN overrides; otherwise prefer build/zjs-pgo when present, falling
# back to the plain dev build.
_default_bin = REPO_ROOT / "build" / ("zjs.exe" if IS_WINDOWS else "zjs")
_pgo_bin     = REPO_ROOT / "build" / "zjs-pgo"
ZJS_BIN    = Path(os.environ["ZJS_BIN"]) if os.environ.get("ZJS_BIN") else (_pgo_bin if _pgo_bin.exists() else _default_bin)
# Optional second binary built WITH the copy-and-patch JIT (`make cli-jit`).
# When present it shows up as a JIT column in the solo run and a "zjs-jit"
# engine in --compare, so the interpreter-vs-JIT delta is visible per bench.
# Absent on non-JIT arches → benches behave exactly as before.
ZJS_JIT_BIN = REPO_ROOT / "build" / ("zjs-jit.exe" if IS_WINDOWS else "zjs-jit")
_suffix    = f"-{PLATFORM_TAG}" if PLATFORM_TAG else ""
HISTORY    = OUT_DIR / f"history{_suffix}.jsonl"
LAST_JSON  = OUT_DIR / f"last{_suffix}.json"
HTML_PATH  = OUT_DIR / f"index{_suffix}.html"

def collect_benches(name_filter):
    found = []
    for p in sorted(BENCH_DIR.glob("*.js")):
        name = p.stem
        if name_filter and name_filter not in name:
            continue
        found.append((name, p))
    return found

_BODY_MARKER = "__zjs_body_ms="

# Engine-agnostic timer prelude. node / bun / deno / zjs all have
# performance.now() (sub-ms precision). qjs / hermes / shermes / boa
# only have Date.now() (integer-ms precision), so benches that run
# in <5ms get rounded ugly there — accept the noise on those rows;
# the >10ms benches (richards, splay, nbody, fib_recursive) are
# where cross-engine comparison is meaningful anyway. Probe at
# runtime so the same wrapped script works everywhere — startup-
# discrimination must be uniform or the numbers stop being apples-
# to-apples.
_TIMER_PRELUDE = (
    "var __zjs_now = (typeof performance === 'object' "
    "&& typeof performance.now === 'function') "
    "? function(){ return performance.now(); } "
    ": function(){ return Date.now(); };\n"
    "var __zjs_bench_t0 = __zjs_now();\n"
)
_TIMER_EPILOGUE = (
    "console.log('" + _BODY_MARKER + "' + (__zjs_now() - __zjs_bench_t0));\n"
)

def _wrap_bench_source(path):
    """Wrap a bench script with timer markers so the runner can
    separate body-time from process-startup overhead. Engine-agnostic
    so the same wrapping works under qjs / node / bun for the
    compare-mode runs."""
    original = path.read_text()
    return _TIMER_PRELUDE + original.rstrip() + "\n" + _TIMER_EPILOGUE

def time_one(zjs_bin, path, iters):
    """Run a bench `iters` times. Each iteration spawns a fresh zjs
    process; the wrapped script reports the body-only time via a
    stdout marker, and the subprocess wall-clock minus that gives us
    startup. We track both separately so engine-init regressions
    don't pollute the bench-body trend graphs."""
    body_samples = []
    wall_samples = []
    wrapped_src = _wrap_bench_source(path)
    # Write to a per-run temp file — zjs CLI takes a path, not stdin.
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as tf:
        tf.write(wrapped_src)
        wrapped_path = tf.name
    try:
        for _ in range(iters):
            t0 = time.perf_counter()
            r = subprocess.run([str(zjs_bin), "run", wrapped_path],
                               capture_output=True, text=True)
            t1 = time.perf_counter()
            if r.returncode != 0:
                return None, r.stderr.strip()[:120]
            wall_samples.append(t1 - t0)
            # Find the body marker — last occurrence wins so a bench
            # that prints "__zjs_body_ms=..." itself can't fool us.
            body_ms = None
            for line in r.stdout.splitlines():
                idx = line.find(_BODY_MARKER)
                if idx >= 0:
                    try:
                        body_ms = float(line[idx + len(_BODY_MARKER):])
                    except ValueError:
                        pass
            if body_ms is None:
                return None, "missing body marker in stdout"
            body_samples.append(body_ms / 1000.0)  # ms → seconds
    finally:
        try:
            os.remove(wrapped_path)
        except OSError:
            pass
    # Compute startup per-iteration BEFORE sorting — otherwise zip()
    # pairs the i-th smallest wall with the i-th smallest body, which
    # mixes iterations and biases the result.
    startup_samples = sorted(w - b for w, b in zip(wall_samples, body_samples))
    body_samples.sort()
    wall_samples.sort()
    return {
        "min":          body_samples[0],
        "median":       body_samples[len(body_samples) // 2],
        "max":          body_samples[-1],
        "iters":        iters,
        # Wall-clock total (body + startup) for back-compat / sanity.
        "wall_median":  wall_samples[len(wall_samples) // 2],
        # Startup = wall − body, the bit we want to track on its own
        # graph instead of letting it pollute body trends.
        "startup_min":    startup_samples[0],
        "startup_median": startup_samples[len(startup_samples) // 2],
    }, None

def commit_short_sha():
    try:
        r = subprocess.run(["git", "rev-parse", "--short=10", "HEAD"],
                           cwd=str(REPO_ROOT), capture_output=True, text=True, check=True)
        return r.stdout.strip()
    except Exception:
        return "?"

def write_html(out_path, history, latest):
    history_json = json.dumps(history)
    latest_json  = json.dumps(latest)
    platform_label = (latest.get("platform") or "macOS").strip()
    html = f"""<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>zjs benchmarks — {platform_label}</title>
<style>
  body {{ font: 14px/1.4 -apple-system, BlinkMacSystemFont, sans-serif;
          max-width: 1100px; margin: 2em auto; padding: 0 1em; color: #222; }}
  h1 {{ font-size: 1.4em; margin-bottom: 0.2em; }}
  .sub {{ color: #666; margin-bottom: 1.5em; }}
  .card {{ background: #fafafa; border: 1px solid #eee; border-radius: 6px;
           padding: 1em 1.25em; margin-bottom: 1.25em; }}
  table {{ border-collapse: collapse; width: 100%; font-size: 13px; }}
  th, td {{ text-align: left; padding: 6px 8px; border-bottom: 1px solid #eee; }}
  th {{ background: #f5f5f5; }}
  th.ms, th.delta {{ text-align: right; }}
  td.bench {{ font-family: ui-monospace, SFMono-Regular, monospace; }}
  td.ms {{ text-align: right; font-variant-numeric: tabular-nums; }}
  td.delta {{ text-align: right; font-variant-numeric: tabular-nums; }}
  td.delta.up   {{ color: #c44; }}   /* slower = bad */
  td.delta.down {{ color: #2c7; }}   /* faster = good */
  svg {{ display: block; overflow: visible; }}
  .charts {{ display: grid; grid-template-columns: 1fr 1fr; gap: 1em; }}
  .chart-box {{ background: #fff; border: 1px solid #eee; padding: 0.5em; border-radius: 4px; }}
  .chart-box h3 {{ font-size: 13px; margin: 0 0 4px 8px; font-family: ui-monospace, monospace; color: #444; }}
</style>

<h1>zjs — benchmarks <span style="font-size:0.65em;color:#888;font-weight:normal;">({platform_label})</span></h1>
<p class="sub">Body-only execution per script (parse + compile + interpret),
measured with a <code>performance.now()</code> wrapper inside the script
so process-startup overhead doesn't pollute the trend. Startup is
tracked separately below.</p>

<div class="card">
  <strong>Latest run</strong> &mdash; <span id="when"></span> @ <code id="sha"></code>
  <table id="latest-table" style="margin-top: 0.5em;">
    <thead><tr><th>Benchmark</th><th class="ms">Median ms</th><th class="ms">Min ms</th><th class="ms">Max ms</th><th class="delta">Δ vs first</th></tr></thead>
    <tbody></tbody>
  </table>
</div>

<div class="card">
  <strong>Process startup overhead</strong>
  (median across benches per commit — measures
  <code>zjs run &lt;script&gt;</code> launch + ctx_init_builtins, with the
  bench body subtracted via the in-script timer. Spiking here means
  context init grew, even if individual benches look stable.)
  <div id="startup-chart" style="margin-top: 0.5em;"></div>
</div>

<div class="card">
  <strong>Per-benchmark history</strong> (body-only median ms over time — lower is better)
  <div id="charts" class="charts" style="margin-top: 0.5em;"></div>
</div>

<script id="history-data" type="application/json">{history_json}</script>
<script id="latest-data"  type="application/json">{latest_json}</script>
<script>
  const history = JSON.parse(document.getElementById('history-data').textContent);
  const latest  = JSON.parse(document.getElementById('latest-data').textContent);

  document.getElementById('when').textContent = latest.when || '';
  document.getElementById('sha').textContent  = latest.sha  || '';

  // Pick a per-bench color from a small palette so the eye can track
  // them across charts.
  function colorFor(name) {{
    const palette = ['#2c7','#36a','#c47','#a84','#5a5','#48c','#c4a','#974','#284'];
    let h = 0;
    for (let i = 0; i < name.length; i++) h = (h * 33 + name.charCodeAt(i)) >>> 0;
    return palette[h % palette.length];
  }}

  // Latest-results table
  const tbody = document.querySelector('#latest-table tbody');
  for (const r of latest.results || []) {{
    const tr = document.createElement('tr');
    let delta = '';
    let dcls  = '';
    if (r.baseline_median) {{
      const pct = (r.median - r.baseline_median) / r.baseline_median * 100;
      const sign = pct >= 0 ? '+' : '';
      delta = `${{sign}}${{pct.toFixed(1)}}%`;
      dcls = pct >  2 ? 'up' : (pct < -2 ? 'down' : '');
    }}
    tr.innerHTML = `
      <td class="bench">${{r.name}}</td>
      <td class="ms">${{(r.median * 1000).toFixed(2)}}</td>
      <td class="ms">${{(r.min    * 1000).toFixed(2)}}</td>
      <td class="ms">${{(r.max    * 1000).toFixed(2)}}</td>
      <td class="delta ${{dcls}}">${{delta}}</td>`;
    tbody.appendChild(tr);
  }}

  // Process-startup chart. Each history row has many results; each
  // result has its own startup_median (≈identical within a row since
  // every bench spawns the same zjs process). Plot the median across
  // benches per row so a single line summarizes "how long does a
  // bare zjs invocation take" over time.
  (function() {{
    const Wsw = 980, Hsw = 130, Psw = 30;
    const points = [];
    for (const row of history) {{
      const ms_vals = (row.results || [])
        .map(r => (r.startup_median || 0) * 1000)
        .filter(v => v > 0);
      if (!ms_vals.length) continue;
      ms_vals.sort((a, b) => a - b);
      points.push({{ when: row.when, sha: row.sha,
                     ms: ms_vals[Math.floor(ms_vals.length / 2)] }});
    }}
    const host = document.getElementById('startup-chart');
    if (!points.length) {{
      host.innerHTML = '<em style="color:#888">No startup data yet — run the bench after this commit to populate.</em>';
      return;
    }}
    let yMax = 0;
    for (const p of points) yMax = Math.max(yMax, p.ms);
    yMax = Math.max(yMax * 1.1, 1);
    const xs = i => Psw + (i / Math.max(points.length - 1, 1)) * (Wsw - 2*Psw);
    const ys = v => Hsw - Psw - (v / yMax) * (Hsw - 2*Psw);
    let svg = `<svg viewBox="0 0 ${{Wsw}} ${{Hsw}}" width="100%">`;
    svg += `<line x1="${{Psw}}" y1="${{Hsw-Psw}}" x2="${{Wsw-Psw}}" y2="${{Hsw-Psw}}" stroke="#999"/>`;
    svg += `<line x1="${{Psw}}" y1="${{Psw}}"     x2="${{Psw}}"      y2="${{Hsw-Psw}}" stroke="#999"/>`;
    for (let v = 0; v <= yMax; v += yMax/4) {{
      const y = ys(v);
      svg += `<line x1="${{Psw}}" y1="${{y}}" x2="${{Wsw-Psw}}" y2="${{y}}" stroke="#eee"/>`;
      svg += `<text x="${{Psw-4}}" y="${{y+3}}" text-anchor="end" fill="#888" font-size="9">${{v.toFixed(1)}}</text>`;
    }}
    const d = points.map((p, i) => `${{xs(i)}},${{ys(p.ms)}}`).join(' ');
    svg += `<polyline points="${{d}}" fill="none" stroke="#c47" stroke-width="1.5"/>`;
    const last = points[points.length - 1];
    svg += `<text x="${{xs(points.length - 1) + 4}}" y="${{ys(last.ms)+4}}" font-size="10" fill="#c47">${{last.ms.toFixed(2)}}ms</text>`;
    svg += '</svg>';
    host.innerHTML = svg;
  }})();

  // Per-benchmark line charts.
  const benchNames = new Set();
  for (const row of history) {{
    for (const r of (row.results || [])) benchNames.add(r.name);
  }}
  const W = 480, H = 130, P = 30;
  const charts = document.getElementById('charts');
  for (const name of [...benchNames].sort()) {{
    const points = [];
    for (const row of history) {{
      const r = (row.results || []).find(x => x.name === name);
      if (r) points.push({{ when: row.when, sha: row.sha, ms: r.median * 1000 }});
    }}
    if (!points.length) continue;
    let yMax = 0;
    for (const p of points) yMax = Math.max(yMax, p.ms);
    yMax = Math.max(yMax * 1.1, 1);
    const xs = i => P + (i / Math.max(points.length - 1, 1)) * (W - 2*P);
    const ys = v => H - P - (v / yMax) * (H - 2*P);
    let svg = `<svg viewBox="0 0 ${{W}} ${{H}}" width="100%">`;
    svg += `<line x1="${{P}}" y1="${{H-P}}" x2="${{W-P}}" y2="${{H-P}}" stroke="#999"/>`;
    svg += `<line x1="${{P}}" y1="${{P}}"   x2="${{P}}"   y2="${{H-P}}" stroke="#999"/>`;
    for (let v = 0; v <= yMax; v += yMax/4) {{
      const y = ys(v);
      svg += `<line x1="${{P}}" y1="${{y}}" x2="${{W-P}}" y2="${{y}}" stroke="#eee"/>`;
      svg += `<text x="${{P-4}}" y="${{y+3}}" text-anchor="end" fill="#888" font-size="9">${{v.toFixed(1)}}</text>`;
    }}
    const color = colorFor(name);
    const d = points.map((p, i) => `${{xs(i)}},${{ys(p.ms)}}`).join(' ');
    svg += `<polyline points="${{d}}" fill="none" stroke="${{color}}" stroke-width="1.5"/>`;
    const last = points[points.length - 1];
    svg += `<text x="${{xs(points.length - 1) + 4}}" y="${{ys(last.ms)+4}}" font-size="10" fill="${{color}}">${{last.ms.toFixed(1)}}ms</text>`;
    svg += '</svg>';
    const box = document.createElement('div');
    box.className = 'chart-box';
    box.innerHTML = `<h3>${{name}}</h3>${{svg}}`;
    charts.appendChild(box);
  }}
</script>
</html>
"""
    out_path.write_text(html, encoding="utf-8")

DEFAULT_OTHER_ENGINES = [
    # name,     binary (resolved via PATH),       extra args before script
    # Peer interpreters first (similar design space — no JIT by default,
    # embeddable), then AOT-compiled and JIT engines for ceiling refs.
    # Kiesel is dropped — orders-of-magnitude slower per run, not a
    # real competitor on this benchmark suite. Add `kiesel` back here
    # if a future release closes the gap.
    #
    # `hermes` is the direct design-space peer: Meta's jitless,
    # embeddable, iOS-target interpreter. Same mission as zjs. `-O`
    # enables Hermes's compile-time optimizations (still a bytecode
    # interpreter at runtime).
    #
    # `shermes` (Static Hermes) compiles JS → C → native; not an
    # interpreter peer but a useful AOT-ceiling reference for what
    # native-compiled JS looks like on the same scripts.
    ("qjs",     "qjs",                              []),
    ("boa",     "boa",                              []),
    ("hermes",  "/usr/local/bin/hermes",            ["-O"]),
    ("shermes", "/usr/local/bin/shermes",           ["-O", "-exec"]),
    ("node",    "node",                             []),
    ("bun",     "bun",                              []),
    ("deno",    str(Path.home() / ".deno/bin/deno"), ["run", "-q"]),
]

def time_engine(label, bin_path, extra_args, script_path, iters):
    """Time `<bin> <args...> <script>` N times under another engine.
    Uses the same body-marker wrapper as time_one so cross-engine
    comparisons exclude startup overhead — otherwise zjs's
    ctx_init_builtins cost shows up as engine-vs-engine speed
    differences, which is misleading."""
    body_samples = []
    wrapped_src = _wrap_bench_source(script_path)
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as tf:
        tf.write(wrapped_src)
        wrapped_path = tf.name
    try:
        for _ in range(iters):
            try:
                r = subprocess.run(
                    [bin_path] + list(extra_args) + [wrapped_path],
                    capture_output=True, text=True, timeout=30.0,
                )
            except (FileNotFoundError, subprocess.TimeoutExpired):
                return None
            if r.returncode != 0:
                return None
            # Parse the body marker. If the engine's stdout chunked
            # weirdly or the wrap didn't take, treat as a miss and
            # bail rather than corrupting the comparison.
            body_ms = None
            for line in r.stdout.splitlines():
                idx = line.find(_BODY_MARKER)
                if idx >= 0:
                    try:
                        body_ms = float(line[idx + len(_BODY_MARKER):])
                    except ValueError:
                        pass
            if body_ms is None:
                return None
            body_samples.append(body_ms / 1000.0)
    finally:
        try:
            os.remove(wrapped_path)
        except OSError:
            pass
    body_samples.sort()
    return {
        "min":    body_samples[0],
        "median": body_samples[len(body_samples) // 2],
        "max":    body_samples[-1],
        "iters":  iters,
    }

def write_compare_html(out_path, summary, bench_names, engine_names):
    summary_json = json.dumps(summary)
    benches_json = json.dumps(bench_names)
    engines_json = json.dumps(engine_names)
    html = f"""<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>zjs vs other engines</title>
<style>
  body {{ font: 14px/1.4 -apple-system, BlinkMacSystemFont, sans-serif;
          max-width: 1100px; margin: 2em auto; padding: 0 1em; color: #222; }}
  h1 {{ font-size: 1.4em; margin-bottom: 0.2em; }}
  .sub {{ color: #666; margin-bottom: 1.5em; }}
  .card {{ background: #fafafa; border: 1px solid #eee; border-radius: 6px;
           padding: 1em 1.25em; margin-bottom: 1.25em; }}
  table {{ border-collapse: collapse; width: 100%; font-size: 13px; }}
  th, td {{ text-align: left; padding: 6px 8px; border-bottom: 1px solid #eee; }}
  th {{ background: #f5f5f5; }}
  th.ms, th.ratio {{ text-align: right; }}
  td.bench {{ font-family: ui-monospace, SFMono-Regular, monospace; }}
  td.ms {{ text-align: right; font-variant-numeric: tabular-nums; }}
  td.ratio {{ text-align: right; font-variant-numeric: tabular-nums; color: #888; }}
  /* zjs/engine ratio cell coloring: <1 means zjs is faster (green),
     >1 means zjs is slower (red). Saturation scales with magnitude
     so a 0.5x win reads stronger than a 0.9x. */
  td.ratio.faster {{ color: #1f7a3a; font-weight: 500; }}
  td.ratio.slower {{ color: #b8311a; font-weight: 500; }}
  .legend {{ display: flex; gap: 1.25em; font-size: 12px; color: #555;
             margin: 0.4em 0 0.8em; flex-wrap: wrap; }}
  .legend .item {{ cursor: pointer; user-select: none;
                   padding: 2px 4px; border-radius: 3px;
                   transition: opacity 0.12s; }}
  .legend .item.off {{ opacity: 0.35; text-decoration: line-through; }}
  .legend .item:hover {{ background: #eee; }}
  .legend .sw {{ display: inline-block; width: 10px; height: 10px;
                 margin-right: 4px; vertical-align: middle; border-radius: 2px; }}
  .legend .hint {{ color: #888; font-style: italic; margin-left: 0.5em; }}
  .toggle {{ font-size: 12px; color: #666; margin-bottom: 0.6em; }}
  .toggle label {{ margin-right: 1em; cursor: pointer; }}
  svg {{ overflow: visible; }}
  svg text.bench-label {{ font: 12px ui-monospace, SFMono-Regular, monospace;
                          fill: #333; }}
  svg text.tick {{ font: 11px sans-serif; fill: #777; }}
  svg text.bar-val {{ font: 11px sans-serif; fill: #333; }}
  svg line.grid {{ stroke: #e8e8e8; stroke-width: 1; }}
  svg line.axis {{ stroke: #aaa; stroke-width: 1; }}
</style>

<h1>zjs vs other engines</h1>
<p class="sub">Snapshot of <span id="when"></span> @ <code id="sha"></code>.
Median wall-clock per script (lower is better). Includes engine startup —
JIT-heavy engines have small absolute numbers because the iterations
in our scripts are too short to repay JIT cost.</p>

<div class="card">
  <table id="compare-table">
    <thead><tr id="thead-row"></tr></thead>
    <tbody></tbody>
  </table>
</div>

<div class="card">
  <div class="legend" id="legend"></div>
  <div class="toggle">
    <label><input type="radio" name="scale" value="linear" checked> linear</label>
    <label><input type="radio" name="scale" value="log"> log scale</label>
  </div>
  <svg id="chart" width="1040" height="40" role="img" aria-label="bench comparison"></svg>
</div>

<script id="data" type="application/json">{summary_json}</script>
<script id="benches" type="application/json">{benches_json}</script>
<script id="engines" type="application/json">{engines_json}</script>
<script>
  const data    = JSON.parse(document.getElementById('data').textContent);
  const benches = JSON.parse(document.getElementById('benches').textContent);
  const engines = JSON.parse(document.getElementById('engines').textContent);

  document.getElementById('when').textContent = data.when || '';
  document.getElementById('sha').textContent  = data.sha  || '';

  const thead = document.getElementById('thead-row');
  thead.innerHTML = '<th>Benchmark</th>' + engines.map(e => `<th class="ms">${{e}} ms</th>`).join('') +
    engines.filter(e => e !== 'zjs').map(e => `<th class="ratio">zjs / ${{e}}</th>`).join('');

  const tbody = document.querySelector('#compare-table tbody');
  for (const name of benches) {{
    const row = data.results.find(r => r.name === name) || {{name, engines: {{}}}};
    let html = `<td class="bench">${{name}}</td>`;
    for (const e of engines) {{
      const v = row.engines[e];
      html += `<td class="ms">${{v == null ? '—' : (v * 1000).toFixed(2)}}</td>`;
    }}
    const zjs_v = row.engines["zjs"];
    for (const e of engines.filter(x => x !== 'zjs')) {{
      const o = row.engines[e];
      if (zjs_v && o) {{
        const ratio = zjs_v / o;
        // <1: zjs is faster (green). >1: zjs is slower (red).
        // 5% deadband around 1.0 stays neutral gray so near-ties
        // don't read as a meaningful win/loss.
        const cls = ratio < 0.95 ? 'faster'
                  : ratio > 1.05 ? 'slower'
                  : '';
        html += `<td class="ratio ${{cls}}">${{ratio.toFixed(2)}}×</td>`;
      }} else {{
        html += `<td class="ratio">—</td>`;
      }}
    }}
    const tr = document.createElement('tr');
    tr.innerHTML = html;
    tbody.appendChild(tr);
  }}

  // --- Grouped bar chart per benchmark -----------------------------
  // One row per bench; one bar per engine within the row, side-by-side.
  // Bars scaled to the slowest engine on that bench so even fast engines
  // are visible. Toggle linear/log via the radio above.
  const palette = {{
    zjs:     '#d65a31',
    qjs:     '#3b82f6',
    boa:     '#06b6d4',
    hermes:  '#f97316',
    shermes: '#facc15',
    kiesel:  '#f59e0b',
    node:    '#10b981',
    bun:     '#a855f7',
    deno:    '#000000',
  }};
  const fallbackPalette = ['#888', '#666', '#444', '#bbb'];
  function colorFor(engine, idx) {{
    return palette[engine] || fallbackPalette[idx % fallbackPalette.length];
  }}

  // Engine visibility — clicking a legend item hides that engine's
  // bars and drops it from the auto-scale calculation. State lives in
  // a Set; the bar chart redraws on each toggle.
  const visible = new Set(engines);
  const legend = document.getElementById('legend');
  function renderLegend() {{
    legend.innerHTML = engines.map((e, i) => {{
      const c = colorFor(e, i);
      const off = visible.has(e) ? '' : ' off';
      return `<span class="item${{off}}" data-engine="${{e}}">`
           + `<span class="sw" style="background:${{c}}"></span>${{e}}</span>`;
    }}).join('') + `<span class="hint">click to toggle</span>`;
    for (const el of legend.querySelectorAll('.item')) {{
      el.addEventListener('click', () => {{
        const name = el.getAttribute('data-engine');
        if (visible.has(name)) {{
          if (visible.size > 1) visible.delete(name); // keep at least one
        }} else {{
          visible.add(name);
        }}
        renderLegend();
        drawChart();
      }});
    }}
  }}
  renderLegend();

  const svg = document.getElementById('chart');
  const SVG_NS = 'http://www.w3.org/2000/svg';

  function el(name, attrs, text) {{
    const n = document.createElementNS(SVG_NS, name);
    for (const k in attrs) n.setAttribute(k, attrs[k]);
    if (text != null) n.textContent = text;
    return n;
  }}

  function getValues(benchName) {{
    const row = data.results.find(r => r.name === benchName);
    if (!row) return {{}};
    return row.engines || {{}};
  }}

  function drawChart() {{
    while (svg.firstChild) svg.removeChild(svg.firstChild);
    const scaleMode = document.querySelector('input[name=scale]:checked').value;
    const shownEngines = engines.filter(e => visible.has(e));

    // Layout constants. rowH shrinks when engines are hidden so the
    // chart compacts vertically.
    const padL = 130, padR = 40, padT = 24, padB = 28;
    const rowH = 18 * shownEngines.length + 12;
    const width  = 1040;
    const innerW = width - padL - padR;
    const height = padT + rowH * benches.length + padB;
    svg.setAttribute('width', width);
    svg.setAttribute('height', height);
    svg.setAttribute('viewBox', `0 0 ${{width}} ${{height}}`);

    // Find the slowest reading across all benches and *visible* engines
    // for scale — hiding kiesel rescales the chart to the remaining
    // engines, which is the main reason to toggle in the first place.
    let maxMs = 0;
    for (const name of benches) {{
      const v = getValues(name);
      for (const e of shownEngines) {{
        if (v[e] != null && v[e] * 1000 > maxMs) maxMs = v[e] * 1000;
      }}
    }}
    if (maxMs <= 0) return;

    const minLog = 0.1; // ms — floor for log-scale clarity
    function xFor(ms) {{
      if (ms == null) return null;
      if (scaleMode === 'log') {{
        const lo = Math.log10(minLog);
        const hi = Math.log10(Math.max(maxMs, minLog * 10));
        const v  = Math.log10(Math.max(ms, minLog));
        return padL + innerW * (v - lo) / (hi - lo);
      }} else {{
        return padL + innerW * (ms / maxMs);
      }}
    }}

    // Grid + ticks.
    const ticks = scaleMode === 'log'
      ? [0.1, 1, 10, 100, 1000].filter(t => t <= maxMs * 1.2)
      : (function () {{
          const n = 5;
          const out = [];
          for (let i = 1; i <= n; i++) out.push(maxMs * i / n);
          return out;
        }})();
    for (const t of ticks) {{
      const x = xFor(t);
      if (x == null) continue;
      svg.appendChild(el('line', {{
        class: 'grid',
        x1: x, x2: x, y1: padT - 4, y2: height - padB,
      }}));
      svg.appendChild(el('text', {{
        class: 'tick', x: x, y: height - padB + 14, 'text-anchor': 'middle',
      }}, t < 10 ? t.toFixed(1) : Math.round(t).toString()));
    }}
    // Axis line
    svg.appendChild(el('line', {{
      class: 'axis', x1: padL, x2: width - padR,
      y1: height - padB, y2: height - padB,
    }}));
    svg.appendChild(el('text', {{
      class: 'tick', x: (padL + width - padR) / 2, y: height - 6,
      'text-anchor': 'middle',
    }}, 'milliseconds (median wall-clock)'));

    // Rows.
    benches.forEach((name, bi) => {{
      const y0 = padT + bi * rowH;
      const v  = getValues(name);
      svg.appendChild(el('text', {{
        class: 'bench-label', x: padL - 8, y: y0 + rowH / 2,
        'text-anchor': 'end', 'dominant-baseline': 'middle',
      }}, name));

      shownEngines.forEach((e, ei) => {{
        const ms = v[e] != null ? v[e] * 1000 : null;
        const yy = y0 + 6 + ei * 18;
        if (ms == null) return;
        const xEnd = xFor(ms);
        const w    = Math.max(1, xEnd - padL);
        // Palette index is the original engine position so colors
        // stay stable across toggles.
        const origIdx = engines.indexOf(e);
        svg.appendChild(el('rect', {{
          x: padL, y: yy, width: w, height: 14,
          fill: colorFor(e, origIdx), rx: 2, ry: 2,
        }}));
        svg.appendChild(el('text', {{
          class: 'bar-val', x: xEnd + 4, y: yy + 11,
        }}, ms < 10 ? ms.toFixed(2) + 'ms' : ms.toFixed(1) + 'ms'));
      }});
    }});
  }}

  drawChart();
  document.querySelectorAll('input[name=scale]').forEach(r =>
    r.addEventListener('change', drawChart));
</script>
</html>
"""
    out_path.write_text(html, encoding="utf-8")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters",  type=int, default=5)
    ap.add_argument("--filter", type=str, default=None)
    ap.add_argument("--no-record", action="store_true")
    ap.add_argument("--compare", action="store_true",
                    help="also run benches under qjs/boa/hermes/shermes/node/bun/deno (whichever are available); write docs/perf/compare.html")
    args = ap.parse_args()

    if not ZJS_BIN.exists():
        print(f"error: {ZJS_BIN} missing — run `make` first", file=sys.stderr)
        return 2

    benches = collect_benches(args.filter)
    if not benches:
        print("no benchmarks found", file=sys.stderr)
        return 1

    # Pull baseline from the first row of history (we use "first" as the
    # ground-truth reference — the delta column says "how much faster /
    # slower than the very first run we recorded").
    first_baseline = {}
    if HISTORY.exists():
        with open(HISTORY, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line: continue
                row = json.loads(line)
                for r in row.get("results", []):
                    first_baseline.setdefault(r["name"], r.get("median"))
                if first_baseline: break

    jit_avail = ZJS_JIT_BIN.exists()
    if jit_avail:
        print(f"[bench] JIT binary present ({ZJS_JIT_BIN.name}) — timing interpreter vs JIT")

    results = []
    for name, path in benches:
        stats, err = time_one(ZJS_BIN, path, args.iters)
        if stats is None:
            print(f"FAIL {name}: {err}", file=sys.stderr)
            continue
        # Same bench under the JIT binary (if built).
        jit_median = None
        if jit_avail:
            jstats, _jerr = time_one(ZJS_JIT_BIN, path, args.iters)
            if jstats is not None:
                jit_median = jstats["median"]
        baseline = first_baseline.get(name)
        results.append({
            "name": name,
            "median": stats["median"],
            "min":    stats["min"],
            "max":    stats["max"],
            "iters":  stats["iters"],
            "baseline_median": baseline,
            # New since 2026-05-19: separate startup vs body so the
            # body trend doesn't get pulled around by ctx_init_builtins
            # cost. wall_median is the original "total subprocess
            # time" metric kept for backwards compat.
            "wall_median":     stats.get("wall_median", stats["median"]),
            "startup_min":     stats.get("startup_min", 0.0),
            "startup_median":  stats.get("startup_median", 0.0),
            # Optional JIT median (None unless build/zjs-jit exists). Extra key
            # — the solo HTML/history readers ignore it.
            "jit_median":      jit_median,
        })
        delta_str = ""
        if baseline:
            pct = (stats["median"] - baseline) / baseline * 100
            sign = "+" if pct >= 0 else ""
            delta_str = f"  ({sign}{pct:.1f}% vs first)"
        startup_str = ""
        sm = stats.get("startup_median")
        if sm is not None and sm > 0:
            startup_str = f"  startup={sm*1000:.2f}ms"
        jit_str = ""
        if jit_median is not None and jit_median > 0:
            spd = stats["median"] / jit_median
            jit_str = f"  jit={jit_median*1000:7.2f}ms ({spd:.2f}x)"
        print(f"{name:20s}  {stats['median']*1000:7.2f} ms  (min {stats['min']*1000:6.2f}, max {stats['max']*1000:6.2f}){jit_str}{startup_str}{delta_str}")

    when = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    sha  = commit_short_sha()
    summary = {"when": when, "sha": sha, "results": results,
               "platform": PLATFORM_LABEL,
               "bin": ZJS_BIN.name}   # zjs-pgo = canonical since #392

    if not args.no_record:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        with open(HISTORY, "a", encoding="utf-8") as f:
            f.write(json.dumps(summary) + "\n")
        LAST_JSON.write_text(json.dumps(summary, indent=2), encoding="utf-8")

        history = []
        with open(HISTORY, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line: continue
                try: history.append(json.loads(line))
                except json.JSONDecodeError: pass
        write_html(HTML_PATH, history, summary)
        print(f"\nReport: {HTML_PATH.relative_to(REPO_ROOT)}")

    if args.compare:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        # Run each bench under every available reference engine, write
        # a separate one-shot comparison HTML.
        engine_names = ["zjs"]
        compare_results = []
        for name, path in benches:
            engines_data = {"zjs": next((r["median"] for r in results if r["name"] == name), None)}
            # zjs's own JIT variant lands right after the interpreter column.
            jm = next((r.get("jit_median") for r in results if r["name"] == name), None)
            if jm is not None:
                engines_data["zjs-jit"] = jm
                if "zjs-jit" not in engine_names:
                    engine_names.append("zjs-jit")
            for ename, ebin, eargs in DEFAULT_OTHER_ENGINES:
                stats = time_engine(ename, ebin, eargs, path, args.iters)
                if stats is not None:
                    engines_data[ename] = stats["median"]
                    if ename not in engine_names:
                        engine_names.append(ename)
            compare_results.append({"name": name, "engines": engines_data})
            engine_str = "  ".join(
                f"{e}={engines_data[e]*1000:7.2f}ms"
                if e in engines_data and engines_data[e] is not None
                else f"{e}=    -   "
                for e in engine_names
            )
            print(f"{name:20s}  {engine_str}")
        compare_summary = {
            "when": when, "sha": sha,
            "results": compare_results,
        }
        compare_path = OUT_DIR / "compare.html"
        write_compare_html(compare_path, compare_summary,
                           [r["name"] for r in compare_results], engine_names)
        (OUT_DIR / "compare.json").write_text(json.dumps(compare_summary, indent=2), encoding="utf-8")
        print(f"Cross-engine report: {compare_path.relative_to(REPO_ROOT)}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
