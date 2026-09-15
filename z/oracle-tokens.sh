#!/usr/bin/env bash
# Lexer differential oracle: dump tokens from the Zen-c reference (linked
# straight from build/libzjs.a) and from the Z lexer, diff per file.
#
#   ./z/oracle-tokens.sh [file-or-dir ...]     default corpus: src/stdlib tests/wintercg
set -uo pipefail

Z_LANG="${Z_LANG:-$HOME/code/z-lang}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/build/tokens"
mkdir -p "$OUT"

if [ ! -x "$HERE/build/tokdump-ref" ]; then
  clang -std=c11 -O2 -o "$HERE/build/tokdump-ref" "$HERE/tools/tokdump-ref.c" "$ROOT/build/libzjs.a" \
    -lm -framework Foundation -framework Security -fobjc-arc -lz || exit 2
fi

# Build the Z dump once as a native binary via `z run --release` on a
# throwaway input, then reuse the cached executable for every file.
if ! (cd "$Z_LANG" && bun run z run "$HERE/tools/tokdump-z/main.zs" --release -- /dev/null) >"$OUT/build.log" 2>&1; then
  echo "Z dump tool failed to build:" >&2; grep -v '^\$' "$OUT/build.log" | head -8 >&2; exit 2
fi
Z_DUMP="$(ls -t "$HERE/tools/tokdump-z/.z-cache/run/" | grep -v '\.c$' | head -1)"
Z_DUMP="$HERE/tools/tokdump-z/.z-cache/run/$Z_DUMP"

targets=("$@"); [ ${#targets[@]} -gt 0 ] || targets=("$ROOT/src/stdlib" "$ROOT/tests/wintercg")
files=()
for t in "${targets[@]}"; do
  if [ -d "$t" ]; then while IFS= read -r f; do files+=("$f"); done < <(find "$t" -name '*.js' | sort); else files+=("$t"); fi
done

same=0; differ=0
for f in "${files[@]}"; do
  name="$(basename "$f")"
  "$HERE/build/tokdump-ref" "$f" > "$OUT/$name.ref" 2>/dev/null
  "$Z_DUMP" "$f" > "$OUT/$name.z" 2>/dev/null
  if cmp -s "$OUT/$name.ref" "$OUT/$name.z"; then
    same=$((same+1))
  else
    differ=$((differ+1))
    first="$(diff "$OUT/$name.ref" "$OUT/$name.z" | grep -m1 '^[<>]')"
    printf "  DIFF %-28s %6s ref / %6s z tokens   first: %s\n" "$name" "$(wc -l < "$OUT/$name.ref" | tr -d ' ')" "$(wc -l < "$OUT/$name.z" | tr -d ' ')" "$first"
  fi
done
echo
echo "lexer oracle: $same identical, $differ differ, of ${#files[@]} files"
echo "dumps: $OUT/<file>.{ref,z}"
[ "$differ" = 0 ]
