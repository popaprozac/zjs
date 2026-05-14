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

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
BENCH_DIR = REPO_ROOT / "scripts" / "bench"
ZJS_BIN   = REPO_ROOT / "build" / "zjs"
OUT_DIR   = REPO_ROOT / "docs" / "perf"
HISTORY   = OUT_DIR / "history.jsonl"
LAST_JSON = OUT_DIR / "last.json"
HTML_PATH = OUT_DIR / "index.html"

def collect_benches(name_filter):
    found = []
    for p in sorted(BENCH_DIR.glob("*.js")):
        name = p.stem
        if name_filter and name_filter not in name:
            continue
        found.append((name, p))
    return found

def time_one(zjs_bin, path, iters):
    samples = []
    for _ in range(iters):
        t0 = time.perf_counter()
        r = subprocess.run([str(zjs_bin), "run", str(path)],
                           capture_output=True, text=True)
        t1 = time.perf_counter()
        if r.returncode != 0:
            return None, r.stderr.strip()[:120]
        samples.append(t1 - t0)
    samples.sort()
    return {
        "min":    samples[0],
        "median": samples[len(samples) // 2],
        "max":    samples[-1],
        "iters":  iters,
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
    html = f"""<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>zjs benchmarks</title>
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
  td.bench {{ font-family: ui-monospace, SFMono-Regular, monospace; }}
  td.ms {{ text-align: right; font-variant-numeric: tabular-nums; }}
  td.delta {{ text-align: right; font-variant-numeric: tabular-nums; }}
  td.delta.up   {{ color: #c44; }}   /* slower = bad */
  td.delta.down {{ color: #2c7; }}   /* faster = good */
  svg {{ display: block; }}
  .charts {{ display: grid; grid-template-columns: 1fr 1fr; gap: 1em; }}
  .chart-box {{ background: #fff; border: 1px solid #eee; padding: 0.5em; border-radius: 4px; }}
  .chart-box h3 {{ font-size: 13px; margin: 0 0 4px 8px; font-family: ui-monospace, monospace; color: #444; }}
</style>

<h1>zjs — benchmarks</h1>
<p class="sub">End-to-end wall-clock per script (parse + compile + interpret).
zjs-vs-zjs over time. Numbers are median of N iterations.</p>

<div class="card">
  <strong>Latest run</strong> &mdash; <span id="when"></span> @ <code id="sha"></code>
  <table id="latest-table" style="margin-top: 0.5em;">
    <thead><tr><th>Benchmark</th><th class="ms">Median ms</th><th class="ms">Min ms</th><th class="ms">Max ms</th><th class="delta">Δ vs first</th></tr></thead>
    <tbody></tbody>
  </table>
</div>

<div class="card">
  <strong>Per-benchmark history</strong> (median ms over time — lower is better)
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
    svg += `<polyline points="${{d}}" fill="none" stroke="${{color}}" stroke-width="2"/>`;
    points.forEach((p, i) => {{
      svg += `<circle cx="${{xs(i)}}" cy="${{ys(p.ms)}}" r="2.5" fill="${{color}}"><title>${{p.when}} @ ${{p.sha}}: ${{p.ms.toFixed(2)}}ms</title></circle>`;
    }});
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
    out_path.write_text(html)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters",  type=int, default=5)
    ap.add_argument("--filter", type=str, default=None)
    ap.add_argument("--no-record", action="store_true")
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
        with open(HISTORY) as f:
            for line in f:
                line = line.strip()
                if not line: continue
                row = json.loads(line)
                for r in row.get("results", []):
                    first_baseline.setdefault(r["name"], r.get("median"))
                if first_baseline: break

    results = []
    for name, path in benches:
        stats, err = time_one(ZJS_BIN, path, args.iters)
        if stats is None:
            print(f"FAIL {name}: {err}", file=sys.stderr)
            continue
        baseline = first_baseline.get(name)
        results.append({
            "name": name,
            "median": stats["median"],
            "min":    stats["min"],
            "max":    stats["max"],
            "iters":  stats["iters"],
            "baseline_median": baseline,
        })
        delta_str = ""
        if baseline:
            pct = (stats["median"] - baseline) / baseline * 100
            sign = "+" if pct >= 0 else ""
            delta_str = f"  ({sign}{pct:.1f}% vs first)"
        print(f"{name:20s}  {stats['median']*1000:7.2f} ms  (min {stats['min']*1000:6.2f}, max {stats['max']*1000:6.2f}){delta_str}")

    when = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    sha  = commit_short_sha()
    summary = {"when": when, "sha": sha, "results": results}

    if args.no_record:
        return 0

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with open(HISTORY, "a") as f:
        f.write(json.dumps(summary) + "\n")
    LAST_JSON.write_text(json.dumps(summary, indent=2))

    history = []
    with open(HISTORY) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try: history.append(json.loads(line))
            except json.JSONDecodeError: pass
    write_html(HTML_PATH, history, summary)
    print(f"\nReport: {HTML_PATH.relative_to(REPO_ROOT)}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
