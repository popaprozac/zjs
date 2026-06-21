#!/usr/bin/env bash
# Measure parse success/error AGREEMENT between the Zen-c reference (build/zjs
# parse) and the Nim port (build/nim/nim-parse) over a corpus, tallied into
# the four meaningful quadrants. This is the gate for the parser
# error-reporting increment (#26): a clean Phase-2 -> nim merge needs the
# corpus diff to converge.
#
# stderr is discarded, so a parse error == empty stdout. No valid program
# dumps empty (even an empty source dumps "Program"), so empty-stdout <=>
# parse error. The four quadrants:
#   both_err   - both reject            (agree)
#   agree_ok   - both accept, same AST  (agree)
#   ast_diff   - both accept, DIFFERENT AST   (valid-input parity bug)
#   nim_only   - zjs rejects, nim accepts     (#26 core: MISSING early error)
#   zjs_only   - zjs accepts, nim rejects     (Nim FALSE error / missing feature)
#
# Usage:  nim/tests/measure_errparity.sh < filelist     # one .js path per line
#   e.g.  find vendor/test262/test/language -name '*.js' | grep -v _FIXTURE \
#           | grep -vE '/(module-code|export|import)/' | awk 'NR%30==0' \
#           | nim/tests/measure_errparity.sh
# Writes the divergence file lists to /tmp/{nim_only,zjs_only,ast_diff}.txt.
set -uo pipefail
ZENC=${ZENC:-build/zjs}
NIM=${NIM:-build/nim/nim-parse}
both_err=0; agree_ok=0; ast_diff=0; zjs_only=0; nim_only=0; total=0
: > /tmp/nim_only.txt; : > /tmp/zjs_only.txt; : > /tmp/ast_diff.txt
while IFS= read -r f; do
  [ -f "$f" ] || continue
  total=$((total+1))
  src=$(cat "$f")
  a=$("$ZENC" parse "$src" 2>/dev/null)
  b=$("$NIM"  "$src"      2>/dev/null)
  ae=$([ -z "$a" ] && echo 1 || echo 0)
  be=$([ -z "$b" ] && echo 1 || echo 0)
  if   [ "$ae" = 1 ] && [ "$be" = 1 ]; then both_err=$((both_err+1))
  elif [ "$ae" = 0 ] && [ "$be" = 0 ]; then
    if [ "$a" = "$b" ]; then agree_ok=$((agree_ok+1)); else ast_diff=$((ast_diff+1)); echo "$f" >> /tmp/ast_diff.txt; fi
  elif [ "$ae" = 1 ] && [ "$be" = 0 ]; then nim_only=$((nim_only+1)); echo "$f" >> /tmp/nim_only.txt
  else                                       zjs_only=$((zjs_only+1)); echo "$f" >> /tmp/zjs_only.txt
  fi
done
agree=$((both_err+agree_ok))
echo "total=$total agree=$agree (both_err=$both_err agree_ok=$agree_ok) | ast_diff=$ast_diff nim_only(missing-err)=$nim_only zjs_only(false-err)=$zjs_only"
