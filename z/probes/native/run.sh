#!/usr/bin/env bash
# Native-compiler probes: one small Z program per gap between Stage 0 and
# the native compiler that the engine has hit. Each is accepted by Stage 0
# at the pin; each is listed here because the native compiler bootstrapped
# from the same revision rejects it.
#
#   Z_BIN=<native z> ./z/probes/native/run.sh
#
# Z_BIN is the native compiler binary, bootstrapped from the pinned
# revision (`bun run bootstrap <output>` in a clean clone at
# z/Z_LANG_REVISION). The runner records what it was given; it cannot
# verify the binary's provenance, so the report names the binary's digest
# and its `z version` line, and the caller states the revision.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -n "${Z_BIN:-}" ] && [ -x "$Z_BIN" ] || { echo "Z_BIN must name the native compiler binary" >&2; exit 2; }
RESULTS="$HERE/.results"; mkdir -p "$RESULTS"; rm -f "$RESULTS"/*.log
echo "native compiler: $Z_BIN"
echo "  $("$Z_BIN" version 2>&1 | head -1)"
echo "  sha256 $(shasum -a 256 "$Z_BIN" | cut -c1-16)…"
echo
landed=0; rejected=0
for probe in "$HERE"/*.zs; do
  name="$(basename "$probe" .zs)"; log="$RESULTS/$name.log"
  if (cd "$HERE" && "$Z_BIN" run "$probe") >"$log" 2>&1; then
    status="LANDED"; landed=$((landed+1)); detail=""
  else
    status="REJECTED"; rejected=$((rejected+1))
    detail="$(grep -o 'error.*' "$log" | head -1 | cut -c1-80)"
  fi
  printf "  %-40s %-9s %s\n" "$name" "$status" "$detail"
done
echo
echo "landed: $landed   rejected: $rejected   (Stage 0 at the pin accepts every probe here)"
