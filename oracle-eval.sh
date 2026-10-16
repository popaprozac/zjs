#!/usr/bin/env bash
# Behavioral oracle: evaluate each file through the Zen-c reference (linked
# straight from prior-art/zen-c/build/libzjs.a) and through the Z engine, and diff the
# canonical rendering of the completion value or uncaught error.
#
#   ./oracle-eval.sh [file-or-dir ...]    default corpus: tests/eval-corpus
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE"
OUT="$HERE/build/eval"
. "$HERE/zc.sh"
mkdir -p "$OUT"

if [ ! -x "$HERE/build/evaldump-ref" ]; then
  clang -std=c11 -O2 -I "$ROOT/include" -o "$HERE/build/evaldump-ref" "$HERE/tools/evaldump-ref.c" "$ROOT/prior-art/zen-c/build/libzjs.a" \
    -lm -framework Foundation -framework Security -fobjc-arc -lz || exit 2
fi

"$HERE/native.sh" >/dev/null
if ! zc build "$HERE/tools/evaldump-z" --release >"$OUT/build.log" 2>&1; then
  echo "Z dump tool failed to build:" >&2; grep -v '^\$' "$OUT/build.log" | head -8 >&2; exit 2
fi
Z_DUMP="$HERE/tools/evaldump-z/build/evaldump-z"

targets=("$@"); [ ${#targets[@]} -gt 0 ] || targets=("$HERE/tests/eval-corpus")
files=()
for t in "${targets[@]}"; do
  if [ -d "$t" ]; then while IFS= read -r f; do files+=("$f"); done < <(find "$t" \( -name '*.js' -o -name '*.mjs' \) | sort); else files+=("$t"); fi
done

same=0; differ=0
for f in "${files[@]}"; do
  name="$(basename "$f")"
  "$HERE/build/evaldump-ref" "$f" > "$OUT/$name.ref" 2>/dev/null
  "$Z_DUMP" "$f" > "$OUT/$name.z" 2>/dev/null
  if cmp -s "$OUT/$name.ref" "$OUT/$name.z"; then
    same=$((same+1))
  else
    differ=$((differ+1))
    line="$(diff "$OUT/$name.ref" "$OUT/$name.z" | grep -m1 '^[0-9]' | cut -d' ' -f1)"
    first="$(diff "$OUT/$name.ref" "$OUT/$name.z" | grep -m2 '^[<>]' | tr '\n' ' ')"
    printf "  DIFF %-24s ref: %-34s z: %s\n" "$name" "$(head -1 "$OUT/$name.ref")" "$(head -1 "$OUT/$name.z")"
  fi
done
echo
echo "eval oracle: $same identical, $differ differ, of ${#files[@]} files"
echo "dumps: $OUT/<file>.{ref,z}"
[ "$differ" = 0 ]
