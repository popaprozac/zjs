#!/usr/bin/env python3
"""The tables of docs/allocation.md, from results/*.json. Nothing is measured here."""
import json
from pathlib import Path
R = Path(__file__).resolve().parent / "results"
load = lambda name: json.loads((R / name).read_text())
NAMES = {"await-prim": "await of a primitive", "await-settled": "await of one settled promise", "await-fresh": "await of a fresh settled promise",
         "await-suspended": "await of a pending promise", "async-gen": "async generator value", "then-chain": "then-link on a pending chain",
         "then-loop": "settle loop (new Promise + then)", "combinators": "combinator element (all, race)", "churn-small": "small-live-set churn",
         "churn-retained": "churn against 300,000 retained", "medium-live-set": "60,000 live cells", "spike": "after a burst"}

matrix = load("matrix.json")
stages = [s["name"] for s in matrix["stages"]]
print("### Incremental effect, ns per operation\n")
print("| Workload | " + " | ".join(stages) + " | first to last |")
print("|---|" + "---|" * (len(stages) + 1))
for w, row in matrix["workloads"].items():
    v = [row["ns_per_operation"][s] for s in stages]
    cell = lambda x: "failed" if x is None else "%.0f" % x
    change = "" if v[0] is None or v[-1] is None else "%+.0f%%" % (100 * (v[-1] - v[0]) / v[0])
    print("| %s | %s | %s |" % (NAMES[w], " | ".join(cell(x) for x in v), change))
print("\nStartup subtracted, ms: " + ", ".join("%s %.1f" % (s, matrix["startup_seconds_subtracted"][s] * 1000) for s in stages))

base, final = load("figures-base.json"), load("figures-final.json")
cb, ca = load("cells-before.json"), load("cells-after.json")
print("\n### Per operation, first stage to last\n")
print("| Workload | Cells | Slots | Allocator calls | Allocator bytes requested | Collections | Collecting, ms | Pause p50 / p99 / max, us | Peak resident, MB |")
print("|---|---|---|---|---|---|---|---|---|")
for w in base["workloads"]:
    b, f = base["workloads"][w], final["workloads"][w]
    ops = b["operations"]
    calls = lambda x: (x["allocator"]["malloc_calls"] + x["allocator"]["calloc_calls"] + x["allocator"]["realloc_calls"]) / ops
    gb, gf = b["collection"], f["collection"]
    print("| %s | %.0f to %.0f | %.0f to %.0f | %.2f to %.2f | %.0f to %.0f | %d to %d | %.1f to %.1f | %d / %d / %d to %d / %d / %d | %.1f to %.1f |" % (
        NAMES[w], cb["workloads"][w]["cells_per_operation"], ca["workloads"][w]["cells_per_operation"],
        cb["workloads"][w]["slots_per_operation"], ca["workloads"][w]["slots_per_operation"], calls(b), calls(f),
        b["allocator"]["bytes_requested"] / ops, f["allocator"]["bytes_requested"] / ops, gb["collections"], gf["collections"],
        gb["collecting_us"] / 1000, gf["collecting_us"] / 1000, gb["pause_p50_us"], gb["pause_p99_us"], gb["pause_max_us"],
        gf["pause_p50_us"], gf["pause_p99_us"], gf["pause_max_us"], b["peak_resident_kib_by_time_l"] / 1024, f["peak_resident_kib_by_time_l"] / 1024))

print("\n### Where the first stage's allocator calls came from (calls per operation, by site)\n")
for w in ("await-prim", "await-suspended", "async-gen", "combinators"):
    b = base["workloads"][w]; ops = b["operations"]
    print("**%s**" % NAMES[w])
    for site in b["allocator"]["sites"][:6]:
        per = site["calls"] / ops
        if per >= 0.05:
            print("- %.2f %s, %.0f bytes: %s" % (per, site["kind"], site["bytes_requested"] / ops, " < ".join(site["frames"])))
    print()

print("### Storage at the end of the run, last stage, KiB\n")
print("| Workload | Alive at last collection | In use | Held: arena | spare arena | table | strings | other | Allocator in use | Allocator reserved | Resident now | Footprint now | Resident peak |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for w, f in final["workloads"].items():
    m = f["memory_kib_at_end_of_run"]
    print("| %s | %d | %d | %d | %d | %d | %d | %d | %d | %d | %d | %d | %d |" % (NAMES[w], m["live_at_last_collection_kib"], m["in_use_kib"], m["held_arena_kib"],
          m["held_spare_arena_kib"], m["held_table_kib"], m["held_strings_kib"], m["held_other_kib"], m["allocator_in_use_kib"], m["allocator_reserved_kib"],
          m["resident_now_kib"], m["footprint_now_kib"], m["resident_peak_kib"]))

policy = load("policy.json")
print("\n### Policy sweep\n")
print("| Workload | Policy | Wall, ms | Collections | Collecting, ms | Pause p50 / p99 / max, us | Resident now, MB | Resident peak, MB |")
print("|---|---|---|---|---|---|---|---|")
for w, rows in policy["workloads"].items():
    for label, r in rows.items():
        g, m = r["collection"], r["memory_kib_at_end_of_run"]
        print("| %s | %s | %.1f | %d | %.1f | %d / %d / %d | %.1f | %.1f |" % (NAMES[w], label, r["wall_seconds"] * 1000, g["collections"], g["collecting_us"] / 1000,
              g["pause_p50_us"], g["pause_p99_us"], g["pause_max_us"], m["resident_now_kib"] / 1024, m["resident_peak_kib"] / 1024))

spike = load("spike.json")
print("\n### After a burst\n")
for label, r in spike["runs"].items():
    g, a = r["collection"], r["address_space_after_the_burst"]
    print("**%s**: %.0f ms; %d collections, %.0f ms collecting, pause p50 %d us, max %d us." % (label, r["wall_seconds"] * 1000, g["collections"], g["collecting_us"] / 1000, g["pause_p50_us"], g["pause_max_us"]))
    print("- address space while idling after the burst: footprint now %s; default zone allocated %s of %s; regions (virtual / resident / dirty): %s" % (
        a["physical_footprint_now"], a["default_zone"]["allocated"], a["default_zone"]["virtual"],
        "; ".join("%s %s / %s / %s" % (k, v["virtual"], v["resident"], v["dirty"]) for k, v in a["regions"].items() if k.startswith("MALLOC_LARGE") or k.startswith("MALLOC_REALLOC"))))
    if r["memory_kib_at_end_of_run"]:
        print("- engine and allocator at the end of the run, KiB: " + ", ".join("%s %d" % (k.replace("_kib", "").replace("_", " "), v) for k, v in r["memory_kib_at_end_of_run"].items()))
    print()
