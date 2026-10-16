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
out="$("$ZJSZ" run --stats "$HERE/tests/gc/async-pressure.js" 2>&1)"
collections="$(stat "$out" collections)"
echo "gc: async: $(echo "$out" | head -1); collections $collections"
echo "$out" | grep -q "^ab,y1,y2,d1,d2x,end:d3y" || { echo "gc: FAIL async bodies under pressure"; fail=1; }
[ "$collections" -ge 3 ] || { echo "gc: FAIL too few collections in async pressure ($collections)"; fail=1; }

out="$("$ZJSZ" run --stats "$HERE/tests/gc/job-release.js" 2>&1)"
cells="$(stat "$out" cells)"
echo "gc: jobs: $(echo "$out" | head -1); cells $cells"
echo "$out" | grep -q "^settled 5000250000 100000" || { echo "gc: FAIL settle loop result"; fail=1; }
[ "$cells" -lt 20000 ] || { echo "gc: FAIL finished jobs are still held ($cells cells)"; fail=1; }

out="$("$ZJSZ" run --stats "$HERE/tests/gc/promise-pressure.js" 2>&1)"
cells="$(stat "$out" cells)"; collections="$(stat "$out" collections)"
echo "gc: promise: $(echo "$out" | head -1); cells $cells, collections $collections"
echo "$out" | grep -q "^promise rounds intact 1500" || { echo "gc: FAIL promise rounds under pressure"; fail=1; }
[ "$collections" -ge 100 ] || { echo "gc: FAIL too few collections in promise pressure ($collections)"; fail=1; }
[ "$cells" -lt 20000 ] || { echo "gc: FAIL settled promise work is still held ($cells cells)"; fail=1; }

[ "$fail" = 0 ] && echo "gc: ok"
exit $fail
