#!/usr/bin/env bash
# Collector checks on the engine's own counters: allocation pressure
# through ordinary collections, exact reclamation under gc(), and a
# register stack (the first of the roots) no larger than the calls running.
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

# A spread call's arguments leave the register stack when the call ends,
# whichever way its frame goes; left there until the caller returned, the
# expectation case's 500 rounds would take the stack to 25,000 registers.
out="$("$ZJSZ" run --stats "$HERE/tests/expect/spread-calls.js" 2>&1)"
registers="$(stat "$out" registers)"
echo "gc: spread calls: $(echo "$out" | head -1); registers $registers"
echo "$out" | grep -q "^later 4000" || { echo "gc: FAIL spread calls result"; fail=1; }
[ "$registers" -lt 1000 ] || { echo "gc: FAIL spread calls' arguments stay on the register stack ($registers registers)"; fail=1; }

# A graph mutated at random and checked every round (recorded from node):
# the same lines whatever the nursery and the slice of a full collection,
# down to a collection at every safe point with a cell or two marked at
# each, and with every collection whole.
torture=0
for setting in "" "--gc-nursery 1" "--gc-nursery 16 --gc-slice 1" "--gc-nursery 64 --gc-slice 8" "--gc-nursery 1000 --gc-slice 3" "--gc-slice 0" "--gc-nursery 0"; do
  out="$("$ZJSZ" run $setting "$HERE/tests/gc/torture.js" 2>&1)"
  if [ "$out" = "$(cat "$HERE/tests/gc/torture.expected")" ]; then torture=$((torture+1)); else echo "gc: FAIL torture ($setting)"; fail=1; fi
done
echo "gc: torture: $torture of 7 settings agree"

[ "$fail" = 0 ] && echo "gc: ok"
exit $fail
