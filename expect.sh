#!/usr/bin/env bash
# Expectation cases: each tests/expect/<name>.js runs on the Z engine
# (with --expose-gc), and again collecting at every safe point, and its
# combined output must equal <name>.expected both times,
# recorded from node --expose-gc and checked by hand. Focused regression cases for behaviour
# the differential oracle cannot cover (where the reference is wrong).
#
#   ./expect.sh            # run all
#   ./expect.sh --record   # write .expected from node for new cases
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ZJSZ="$HERE/build/zjsz"
RECORD=0
[ "${1:-}" = "--record" ] && RECORD=1
passed=0; failed=0
for js in "$HERE"/tests/expect/*.js; do
  name="$(basename "$js" .js)"
  expected="$HERE/tests/expect/$name.expected"
  if [ "$RECORD" = 1 ] && [ ! -f "$expected" ]; then
    node --expose-gc "$js" > "$expected" 2>&1
    echo "recorded $name"
  fi
  actual="$("$ZJSZ" run --expose-gc "$js" 2>&1)"
  # The same again with a collection at every safe point: a value a
  # builtin holds unrooted across one is freed there.
  collected="$("$ZJSZ" run --expose-gc --gc-nursery 1 "$js" 2>&1)"
  if [ "$actual" = "$(cat "$expected")" ] && [ "$collected" = "$actual" ]; then
    passed=$((passed+1))
  elif [ "$actual" != "$(cat "$expected")" ]; then
    failed=$((failed+1))
    echo "FAIL $name"
    diff <(echo "$actual") "$expected" | head -6
  else
    failed=$((failed+1))
    echo "FAIL $name (collecting at every safe point)"
    diff <(echo "$collected") "$expected" | head -6
  fi
done
echo "expect: $passed passed, $failed failed"
[ "$failed" = 0 ]
