#!/usr/bin/env bash
# Native-compiler probes: one small Z program per gap between Stage 0 and
# the native compiler that the engine has hit. Each is accepted by Stage 0
# at the pin; each is listed here because the native compiler bootstrapped
# from the same revision rejects it. A probe lands only when the gap is
# closed, so the set is the acceptance criterion for the native build.
#
#   Z_BIN=<native z> ./z/probes/native/run.sh
#   Z_BIN=<native z> Z_LANG=<clean clone at the pin> ./z/probes/native/run.sh
#
# Z_BIN is the native compiler binary, bootstrapped from the pinned
# revision (`bun run bootstrap <output>` in a clean clone at
# z/Z_LANG_REVISION). The runner records what it was given; it cannot
# verify the binary's provenance, so the report names the binary's digest
# and its `z version` line, and the caller states the revision. With
# Z_LANG set, each probe is also checked by Stage 0 there, so a probe
# that neither compiler accepts is not mistaken for a native gap.
#
# Outcomes, never collapsed into one:
#   LANDED             compiled natively and ran clean
#   COMPILER-REJECTED  `z check` refused it (the gap is open); an internal
#                      compiler error is reported as such, it is a compiler
#                      defect and not a diagnostic
#   BACKEND-REJECTED   Z accepted it, the generated C did not build (the gap
#                      is open, in emission or the toolchain command)
#   RUNTIME-FAIL n     built, and an assertion failed: the probe's exit code
#   CRASH sig n        built, and the program died of a signal (a trap, abort)
#   TIMEOUT            exceeded PROBE_TIMEOUT seconds (default 60)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -n "${Z_BIN:-}" ] && [ -x "$Z_BIN" ] || { echo "Z_BIN must name the native compiler binary" >&2; exit 2; }
TIMEOUT="${PROBE_TIMEOUT:-60}"
RESULTS="$HERE/.results"; mkdir -p "$RESULTS"; rm -f "$RESULTS"/*.log "$RESULTS"/*.bin
# alarm() survives exec, so the timer applies to the process itself.
bounded() { perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$@"; }

echo "native compiler: $Z_BIN"
echo "  $("$Z_BIN" version 2>&1 | head -1)"
echo "  sha256 $(shasum -a 256 "$Z_BIN" | cut -c1-16)…"
if [ -n "${Z_LANG:-}" ]; then
  echo "Stage 0 cross-check: $Z_LANG @ $(git -C "$Z_LANG" rev-parse --short HEAD)$(git -C "$Z_LANG" status --porcelain --untracked-files=no | grep -q . && echo ' (modified)')"
fi
echo

landed=0; open=0; other=0; kinds=""
# Helper modules a probe imports live under modules/ and are not probes.
for probe in "$HERE"/*.zs; do
  name="$(basename "$probe" .zs)"; log="$RESULTS/$name.log"; bin="$RESULTS/$name.bin"
  stage0=""
  if [ -n "${Z_LANG:-}" ]; then
    if (cd "$Z_LANG" && bounded bun run z check "$probe") >"$RESULTS/$name.stage0.log" 2>&1; then stage0="stage 0 accepts"; else stage0="STAGE 0 REJECTS TOO"; fi
  fi
  if ! (cd "$HERE" && bounded "$Z_BIN" check "$probe") >"$log" 2>&1; then
    status="COMPILER-REJECTED"; open=$((open+1))
    detail="$(grep -oE 'internal compiler error.*|error.*' "$log" | head -1 | sed "s#$HERE/##g" | cut -c1-88)"
  elif ! (cd "$HERE" && bounded "$Z_BIN" build "$probe" "$bin") >>"$log" 2>&1; then
    status="BACKEND-REJECTED"; open=$((open+1))
    detail="$(grep -oE '\.c:[0-9]+:[0-9]+: error: .*|error.*' "$log" | head -1 | cut -c1-72)"
  else
    bounded "$bin" >>"$log" 2>&1; rc=$?
    if [ "$rc" = 0 ]; then status="LANDED"; landed=$((landed+1)); detail=""
    elif [ "$rc" = 142 ]; then status="TIMEOUT"; other=$((other+1)); detail="exceeded ${TIMEOUT}s"
    elif [ "$rc" -gt 128 ]; then status="CRASH"; other=$((other+1)); detail="signal $((rc-128))"
    else status="RUNTIME-FAIL"; other=$((other+1)); detail="exit $rc"
    fi
  fi
  [ "$status" = LANDED ] || kinds="$kinds $status"
  printf "  %-36s %-18s %s%s\n" "$name" "$status" "$detail" "${stage0:+   [$stage0]}"
done
echo
# Every probe that did not land is an open gap; the kinds say where it is open.
breakdown="$(echo "$kinds" | tr ' ' '\n' | grep . | sort | uniq -c | awk '{printf "%s%d %s", sep, $1, $2; sep=", "}')"
echo "landed: $landed   open: $((open+other))${breakdown:+ ($breakdown)}"
