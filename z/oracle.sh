#!/usr/bin/env bash
# Differential oracle: run the same corpus through the shipping Zen-c engine
# and the Z engine with the *same unmodified runner*, and diff.
#
# The reference side links build/libzjs.a directly, so it needs no Zen-c
# toolchain -- the generated C is already frozen in build/. That keeps the
# oracle available on any machine that can compile C.
#
# Usage: ./z/oracle.sh [corpus-dir]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/build"
CORPUS="${1:-$HERE/tests/fixture262}"

mkdir -p "$OUT"

if [ ! -f "$ROOT/build/libzjs.a" ]; then
  echo "reference engine missing: build/libzjs.a" >&2
  echo "build it with: make lib" >&2
  exit 1
fi

echo "building reference runner (Zen-c engine)..."
clang -std=c11 -O2 -I "$ROOT/include" -o "$OUT/runner_ref" \
  "$ROOT/tests/test262_runner.c" "$ROOT/build/libzjs.a" \
  -lm -framework Foundation -framework Security -fobjc-arc -lz

echo "building Z runner..."
"$HERE/build.sh" >/dev/null

summary() { sed -n '/^results:/,/^  failed/p' | tr -s ' '; }

"$OUT/runner_ref" "$CORPUS" > "$OUT/ref.out" 2>&1 || true
"$OUT/test262_runner" "$CORPUS" > "$OUT/z.out" 2>&1 || true

echo
echo "corpus: $CORPUS"
echo "--- reference (Zen-c) ---"
summary < "$OUT/ref.out"
echo "--- z ---"
summary < "$OUT/z.out"

ref_pass=$(grep -Eo 'passed +[0-9]+' "$OUT/ref.out" | awk '{print $2}')
z_pass=$(grep -Eo 'passed +[0-9]+' "$OUT/z.out" | awk '{print $2}')
echo
echo "reference passed: ${ref_pass:-?}   z passed: ${z_pass:-?}   gap: $(( ${ref_pass:-0} - ${z_pass:-0} ))"
echo
echo "The gap is the migration. Phase 1 expects it to equal the reference total."
