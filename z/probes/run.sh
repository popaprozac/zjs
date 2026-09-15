#!/usr/bin/env bash
# Executable acceptance criteria for docs/z-findings.md.
#
# Each probe is a small Z program that compiles and runs only when its
# finding has landed. Outcomes are classified, not collapsed:
#
#   LANDED             probe compiled and ran clean
#   COMPILER-REJECTED  `z check` refused it (Z diagnostic, saved to log)
#   BACKEND-REJECTED   Z accepted it, the generated C failed to compile --
#                      a Z error escaping to clang, which is itself a bug
#   RUNTIME-FAIL       compiled, then a probe assertion or test failed
#   TIMEOUT            exceeded PROBE_TIMEOUT seconds
#   REGRESSION         was LANDED in baseline.txt, is not now
#
# A verified run requires the z-lang checkout to be at the pinned revision
# (z/Z_LANG_REVISION) AND clean. Otherwise the runner refuses, because a
# mid-edit tree cannot produce acceptance evidence. It never switches or
# resets the shared compiler checkout. --allow-drift runs anyway, labelled
# UNVERIFIED, and can never write the baseline.
#
# A probe passing is evidence. Consumer verification still requires real
# adoption in the engine and a recorded commit.
#
#   ./run.sh [--allow-drift] [--record]
#   Z_LANG=...         compiler checkout (default ~/code/z-lang)
#   PROBE_TIMEOUT=60   seconds per compiler invocation
set -uo pipefail

Z_LANG="${Z_LANG:-$HOME/code/z-lang}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RESULTS="$HERE/.results"
BASELINE="$HERE/baseline.txt"
TIMEOUT="${PROBE_TIMEOUT:-60}"
ALLOW_DRIFT=0; RECORD=0
for arg in "$@"; do
  case "$arg" in
    --allow-drift) ALLOW_DRIFT=1 ;;
    --record) RECORD=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$RESULTS"
rm -f "$RESULTS"/*.log

# --- Pin enforcement -------------------------------------------------------
actual="$(cd "$Z_LANG" && git rev-parse --short HEAD)"
pinned="$(head -1 "$HERE/../Z_LANG_REVISION" 2>/dev/null | tr -d '[:space:]')"
dirty="$(cd "$Z_LANG" && git status --porcelain --untracked-files=no | head -1)"
verified=1
reason=""
[ "$actual" = "$pinned" ] || { verified=0; reason="checkout is $actual, pin is $pinned"; }
[ -z "$dirty" ] || { verified=0; reason="${reason:+$reason; }working tree has uncommitted changes"; }

echo "z-lang @ $actual   pin: $pinned"
if [ "$verified" = 0 ]; then
  if [ "$ALLOW_DRIFT" = 1 ]; then
    echo "UNVERIFIED RUN: $reason"
    echo "  results below are exploratory and will not be recorded"
    RECORD=0
  else
    echo "REFUSED: $reason"
    echo "  acceptance evidence needs the pinned, clean revision."
    echo "  advance z/Z_LANG_REVISION deliberately, or pass --allow-drift to explore."
    exit 2
  fi
fi
echo

# --- Helpers ---------------------------------------------------------------
# alarm() survives exec, so the timer applies to the compiler process itself.
bounded() { perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$@"; }

baseline_status() {
  [ -f "$BASELINE" ] || { echo ""; return; }
  awk -v n="$1" '$1 == n { print $2 }' "$BASELINE"
}

# --- Run -------------------------------------------------------------------
declare -a names statuses details
counts_landed=0; counts_other=0; counts_regress=0

for probe in "$HERE"/*.zs; do
  name="$(basename "$probe" .zs)"
  log="$RESULTS/$name.log"
  mode="run"
  grep -q '^test "' "$probe" && mode="test"

  status=""; detail=""
  # Stage A: does Z accept it?
  if ! (cd "$Z_LANG" && bounded bun run z check "$probe") >"$log" 2>&1; then
    status="COMPILER-REJECTED"
    detail="$(grep -o 'error.*' "$log" | head -1 | cut -c1-70)"
  else
    # Stage B: does it build and run?
    (cd "$Z_LANG" && bounded bun run z "$mode" "$probe") >>"$log" 2>&1
    rc=$?
    if [ "$rc" = 0 ]; then
      status="LANDED"
    elif [ "$rc" = 142 ]; then
      status="TIMEOUT"; detail="exceeded ${TIMEOUT}s"
    elif grep -qE '\.c:[0-9]+:[0-9]+: error:|[0-9]+ errors? generated' "$log"; then
      status="BACKEND-REJECTED"
      detail="$(grep -oE '\.c:[0-9]+:[0-9]+: error: .*' "$log" | head -1 | sed 's/^\.c:[0-9]*:[0-9]*: error: //' | cut -c1-60)"
    else
      status="RUNTIME-FAIL"
      if [ "$mode" = test ]; then
        detail="$(grep -E 'expected .* to equal|test result' "$log" | head -1 | cut -c1-60)"
      else
        code="$(grep -oE 'exited with code [0-9]+' "$log" | grep -oE '[0-9]+$')"
        detail="probe returned ${code:-$rc}"
      fi
    fi
  fi

  was="$(baseline_status "$name")"
  if [ "$was" = "LANDED" ] && [ "$status" != "LANDED" ]; then
    detail="was LANDED at baseline; now $status${detail:+: $detail}"
    status="REGRESSION"
  fi

  names+=("$name"); statuses+=("$status"); details+=("$detail")
  case "$status" in
    LANDED) counts_landed=$((counts_landed+1)) ;;
    REGRESSION) counts_regress=$((counts_regress+1)) ;;
    *) counts_other=$((counts_other+1)) ;;
  esac
  printf "  %-32s %-18s %s\n" "$name" "$status" "$detail"
done

echo
echo "$counts_landed landed, $counts_other not landed, $counts_regress regressions"
[ "$verified" = 1 ] && echo "verified against pinned clean revision $pinned" || echo "UNVERIFIED"
echo "logs: $RESULTS/<probe>.log"

# --- Baseline --------------------------------------------------------------
if [ "$RECORD" = 1 ]; then
  {
    echo "# probe status at z-lang $pinned (clean). Written by run.sh --record."
    for i in "${!names[@]}"; do echo "${names[$i]} ${statuses[$i]}"; done
  } > "$BASELINE"
  echo "baseline recorded: $BASELINE"
fi

[ "$counts_regress" = 0 ] || exit 1
exit 0
