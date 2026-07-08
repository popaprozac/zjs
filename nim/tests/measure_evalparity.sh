#!/usr/bin/env bash
# Measure EXECUTION AGREEMENT between the Zen-c reference (build/zjs eval)
# and the Nim VM (build/nim/nim-eval) over a corpus. This is the
# differential oracle for Phase-4 slice 1: the Nim completion-value print
# must match `build/zjs eval '<src>'` BYTE-FOR-BYTE for the arithmetic /
# control-flow subset.
#
# Both binaries take JS SOURCE as argv[1] (NOT a file path). For a corpus
# of .js files we pass the file CONTENTS as the source argument.
#
# The quadrants:
#   both_identical - both produced output, byte-for-byte identical    (WIN)
#   wrong_result   - both produced output, but they DIFFER            (BUG -- must be 0)
#   nim_missing    - zjs produced output, nim empty/nonzero           (unimplemented op / built-in -- expected)
#   zjs_missing    - nim produced output, zjs empty/nonzero           (should be ~0; nim over-runs)
#
# Usage (corpus of file paths, one per line):
#   find vendor/test262/test/language/expressions -name '*.js' \
#     | grep -v _FIXTURE | awk 'NR%40==0' \
#     | bash nim/tests/measure_evalparity.sh
#
# Or a plain expression list (one JS expression per line), via LIST mode:
#   printf '1+2\n10/2\n' | MODE=expr bash nim/tests/measure_evalparity.sh
#
# Writes divergence lists to /tmp/{eval_wrong_result,eval_nim_missing,eval_zjs_missing}.txt.
set -uo pipefail
ZENC=${ZENC:-build/zjs}
NIM=${NIM:-build/nim/nim-eval}
MODE=${MODE:-file}   # file: each input line is a path; expr: each line is source
both_identical=0; wrong_result=0; nim_missing=0; zjs_missing=0; both_err=0; total=0
: > /tmp/eval_wrong_result.txt; : > /tmp/eval_nim_missing.txt; : > /tmp/eval_zjs_missing.txt
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if [ "$MODE" = expr ]; then
    src="$line"; label="$line"
  else
    [ -f "$line" ] || continue
    src=$(cat "$line"); label="$line"
  fi
  total=$((total+1))
  a=$("$ZENC" eval "$src" 2>/dev/null); ar=$?
  b=$("$NIM"  "$src"      2>/dev/null); br=$?
  # "empty" = nonzero exit OR no stdout (a bail / throw / crash).
  ae=$([ "$ar" != 0 ] && echo 1 || echo 0)
  be=$([ "$br" != 0 ] && echo 1 || echo 0)
  if   [ "$ae" = 1 ] && [ "$be" = 1 ]; then both_err=$((both_err+1))
  elif [ "$ae" = 0 ] && [ "$be" = 0 ]; then
    if [ "$a" = "$b" ]; then both_identical=$((both_identical+1))
    else wrong_result=$((wrong_result+1)); echo "$label" >> /tmp/eval_wrong_result.txt; fi
  elif [ "$ae" = 0 ] && [ "$be" = 1 ]; then nim_missing=$((nim_missing+1)); echo "$label" >> /tmp/eval_nim_missing.txt
  else                                       zjs_missing=$((zjs_missing+1)); echo "$label" >> /tmp/eval_zjs_missing.txt
  fi
done
echo "total=$total | both_identical=$both_identical wrong_result=$wrong_result nim_missing=$nim_missing zjs_missing=$zjs_missing both_err=$both_err"
