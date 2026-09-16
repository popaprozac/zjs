#!/usr/bin/env bash
# Collector checks on the engine's own counters: allocation pressure
# through ordinary collections, and exact reclamation under gc().
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ZJSZ="$HERE/build/zjsz"
fail=0
stat() { echo "$1" | grep -o "$2 [0-9]*" | awk '{print $2}'; }

out="$("$ZJSZ" run --stats "$HERE/tests/gc/weak-pressure.js" 2>&1)"
cells="$(stat "$out" cells)"; cleared="$(stat "$out" weak-cleared)"; collections="$(stat "$out" collections)"
echo "gc: pressure: $(echo "$out" | head -1); cells $cells, weak-cleared $cleared, collections $collections"
echo "$out" | grep -q "held entries intact" || { echo "gc: FAIL held entries"; fail=1; }
[ "$cells" -lt 20000 ] || { echo "gc: FAIL cells not bounded ($cells)"; fail=1; }
[ "$cleared" -ge 390000 ] || { echo "gc: FAIL cleared count low ($cleared of 400000 dropped)"; fail=1; }
[ "$collections" -ge 2 ] || { echo "gc: FAIL no ordinary collections ran"; fail=1; }

out="$("$ZJSZ" run --stats --expose-gc "$HERE/tests/gc/weak-forced.js" 2>&1)"
cleared="$(stat "$out" weak-cleared)"; passes="$(stat "$out" ephemeron-passes)"
echo "gc: forced: $(echo "$out" | head -1); weak-cleared $cleared, ephemeron-passes $passes"
echo "$out" | grep -q "^kept,true" || { echo "gc: FAIL held key"; fail=1; }
[ "$cleared" = 2000 ] || { echo "gc: FAIL expected 2000 cleared, got $cleared"; fail=1; }
[ "$fail" = 0 ] && echo "gc: ok"
exit $fail
