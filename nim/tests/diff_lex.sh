#!/usr/bin/env bash
# Diff the Nim lexer dump vs the Zen-c `zjs lex` over a corpus.
# Usage: nim/tests/diff_lex.sh            # built-in snippets
#        nim/tests/diff_lex.sh <dir>      # every .js file under <dir>
set -uo pipefail
ZENC=build/zjs
NIMLEX=build/nim/nim-lex
fails=0; total=0
check() {  # $1 = source string
  total=$((total+1))
  local a b
  a=$("$ZENC" lex "$1" 2>/dev/null)
  b=$("$NIMLEX" "$1" 2>/dev/null)
  if [ "$a" != "$b" ]; then
    fails=$((fails+1))
    echo "DIFF on: $1"
    diff <(printf '%s' "$a") <(printf '%s' "$b") | head -20
  fi
}
if [ $# -ge 1 ]; then
  while IFS= read -r f; do check "$(cat "$f")"; done < <(find "$1" -name '*.js' | head -500)
else
  for s in 'let x = 1 + 2;' 'a===b' 'x ??= y' 'f(`a${b}c`)' '0xFFn' '/re/gi' 'a?.b' '#priv'; do check "$s"; done
fi
echo "diff_lex: $((total-fails))/$total identical, $fails differing"
exit $fails
