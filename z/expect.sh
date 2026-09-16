#!/usr/bin/env bash
# Expectation cases: each z/tests/expect/<name>.js runs on the Z engine
# (with --expose-gc) and its combined output must equal <name>.expected,
# recorded from node --expose-gc and checked by hand. Focused regression cases for behaviour
# the differential oracle cannot cover (where the reference is wrong).
#
#   ./z/expect.sh            # run all
#   ./z/expect.sh --record   # write .expected from node for new cases
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
  if [ "$actual" = "$(cat "$expected")" ]; then
    passed=$((passed+1))
  else
    failed=$((failed+1))
    echo "FAIL $name"
    diff <(echo "$actual") "$expected" | head -6
  fi
done
echo "expect: $passed passed, $failed failed"
[ "$failed" = 0 ]
