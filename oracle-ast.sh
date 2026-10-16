#!/usr/bin/env bash
# Parser differential oracle: dump the AST from the Zen-c reference (linked
# straight from prior-art/zen-c/build/libzjs.a) and from the Z parser, diff per file.
#
#   ./oracle-ast.sh [file-or-dir ...]     default corpus: prior-art/zen-c/src/stdlib tests/wintercg
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE"
OUT="$HERE/build/ast"
mkdir -p "$OUT"
. "$HERE/zc.sh"

if [ ! -x "$HERE/build/astdump-ref" ]; then
  clang -std=c11 -O2 -o "$HERE/build/astdump-ref" "$HERE/tools/astdump-ref.c" "$ROOT/prior-art/zen-c/build/libzjs.a" \
    -lm -framework Foundation -framework Security -fobjc-arc -lz || exit 2
fi

if ! zc run "$HERE/tools/astdump-z/main.zs" --release -- /dev/null >"$OUT/build.log" 2>&1; then
  echo "Z dump tool failed to build:" >&2; grep -v '^\$' "$OUT/build.log" | head -8 >&2; exit 2
fi
# The executable `z run` left in its cache, whichever driver built it.
Z_DUMP="$(find "$HERE/tools/astdump-z/.z-cache/run" -maxdepth 1 -type f -perm +111 -print0 | xargs -0 ls -t | head -1)"

targets=("$@"); [ ${#targets[@]} -gt 0 ] || targets=("$ROOT/prior-art/zen-c/src/stdlib" "$ROOT/tests/wintercg")
files=()
for t in "${targets[@]}"; do
  if [ -d "$t" ]; then while IFS= read -r f; do files+=("$f"); done < <(find "$t" \( -name '*.js' -o -name '*.mjs' \) | sort); else files+=("$t"); fi
done

same=0; differ=0
for f in "${files[@]}"; do
  name="$(basename "$f")"
  # .mjs files are parsed as modules by both engines.
  flag=""; case "$f" in *.mjs) flag="--module";; esac
  "$HERE/build/astdump-ref" "$f" $flag > "$OUT/$name.ref" 2>/dev/null
  "$Z_DUMP" "$f" $flag > "$OUT/$name.z" 2>/dev/null
  if cmp -s "$OUT/$name.ref" "$OUT/$name.z"; then
    same=$((same+1))
  else
    differ=$((differ+1))
    line="$(diff "$OUT/$name.ref" "$OUT/$name.z" | grep -m1 '^[0-9]' | cut -d' ' -f1)"
    first="$(diff "$OUT/$name.ref" "$OUT/$name.z" | grep -m2 '^[<>]' | tr '\n' ' ')"
    printf "  DIFF %-28s %6s ref / %6s z lines   at %s: %s\n" "$name" "$(wc -l < "$OUT/$name.ref" | tr -d ' ')" "$(wc -l < "$OUT/$name.z" | tr -d ' ')" "$line" "$first"
  fi
done
echo
echo "parser oracle: $same identical, $differ differ, of ${#files[@]} files"
echo "dumps: $OUT/<file>.{ref,z}"
[ "$differ" = 0 ]
