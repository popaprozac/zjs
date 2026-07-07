#!/usr/bin/env bash
# Measure DISASM AGREEMENT between the Zen-c reference (build/zjs disasm) and
# the Nim port (build/nim/nim-disasm) over a corpus. This is the differential
# oracle for the Phase-3 bytecode-compiler slices: the Nim disasm output must
# match `build/zjs disasm <file>` BYTE-FOR-BYTE.
#
# Both binaries read a FILE PATH (unlike `zjs parse`, which takes source as an
# argument). A compile/parse failure == empty stdout + nonzero exit.
#
# The four quadrants:
#   both_identical - both produced output, byte-for-byte identical   (WIN)
#   text_diff      - both produced output, but they DIFFER            (BUG -- must be ~0)
#   nim_missing    - zjs produced output, nim empty/error             (unimplemented op -- expected during slices)
#   zjs_missing    - nim produced output, zjs empty/error             (should be ~0; nim over-accepts)
#
# Usage:  nim/tests/measure_diffdisasm.sh < filelist     # one .js path per line
#   e.g.  find vendor/test262/test/language/expressions -name '*.js' \
#           | grep -v _FIXTURE | awk 'NR%40==0' \
#           | nim/tests/measure_diffdisasm.sh
# Writes the divergence file lists to /tmp/{disasm_text_diff,disasm_nim_missing,disasm_zjs_missing}.txt.
set -uo pipefail
ZENC=${ZENC:-build/zjs}
NIM=${NIM:-build/nim/nim-disasm}
both_identical=0; text_diff=0; nim_missing=0; zjs_missing=0; both_err=0; total=0
: > /tmp/disasm_text_diff.txt; : > /tmp/disasm_nim_missing.txt; : > /tmp/disasm_zjs_missing.txt
while IFS= read -r f; do
  [ -f "$f" ] || continue
  total=$((total+1))
  a=$("$ZENC" disasm "$f" 2>/dev/null)
  b=$("$NIM"  "$f"        2>/dev/null)
  ae=$([ -z "$a" ] && echo 1 || echo 0)   # 1 == zjs empty (parse/compile error)
  be=$([ -z "$b" ] && echo 1 || echo 0)   # 1 == nim empty (parse/compile error)
  if   [ "$ae" = 1 ] && [ "$be" = 1 ]; then both_err=$((both_err+1))
  elif [ "$ae" = 0 ] && [ "$be" = 0 ]; then
    if [ "$a" = "$b" ]; then both_identical=$((both_identical+1))
    else text_diff=$((text_diff+1)); echo "$f" >> /tmp/disasm_text_diff.txt; fi
  elif [ "$ae" = 0 ] && [ "$be" = 1 ]; then nim_missing=$((nim_missing+1)); echo "$f" >> /tmp/disasm_nim_missing.txt
  else                                       zjs_missing=$((zjs_missing+1)); echo "$f" >> /tmp/disasm_zjs_missing.txt
  fi
done
echo "total=$total | both_identical=$both_identical text_diff=$text_diff nim_missing=$nim_missing zjs_missing=$zjs_missing both_err=$both_err"
