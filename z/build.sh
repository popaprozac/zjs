#!/usr/bin/env bash
# Phase 1: build the Z engine, wrap it in the frozen zjs.h ABI, and link the
# existing test262 runner against it unchanged.
set -euo pipefail

Z_LANG="${Z_LANG:-$HOME/code/z-lang}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/build"

mkdir -p "$OUT"

echo "[0/6] native backend"
"$HERE/native.sh" >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Werror -I "$HERE/engine/native" -o "$OUT/native/regex_contexts" "$HERE/tests/regex_contexts.c" "$OUT/native/libzjsregexp.a"
"$OUT/native/regex_contexts"

echo "[1/6] Z engine -> libzjsz.a"
(cd "$Z_LANG" && bun run z build "$HERE/engine" >/dev/null)

echo "[2/6] ABI shim"
clang -std=c11 -Wall -Wextra -Werror -O2 -c \
  -I "$ROOT/include" -I "$HERE/engine/build" \
  -o "$OUT/zjs_shim.o" "$HERE/shim/zjs_shim.c"

echo "[3/6] libzjs.a (engine, shim, and the native backend in one archive)"
rm -f "$OUT/libzjs.a"
cp "$HERE/engine/build/libzjsz.a" "$OUT/libzjs.a"
ar r "$OUT/libzjs.a" "$OUT/zjs_shim.o" "$OUT/native/libregexp.o" "$OUT/native/libunicode.o" "$OUT/native/zjs_regexp.o"
ranlib "$OUT/libzjs.a"

echo "[3b/6] lifecycle test (its own build of the library, with the test-only gate; not shipped)"
(cd "$Z_LANG" && bun run z build "$HERE/tests/lifecycle" >/dev/null)
clang -std=c11 -O2 -Wall -Wextra -Werror -I "$ROOT/include" -I "$HERE/tests/lifecycle/build" -I "$HERE/engine/native" \
  -o "$OUT/lifecycle_test" "$HERE/tests/lifecycle_test.c" "$HERE/tests/lifecycle/build/libzjsz.a" \
  "$OUT/zjs_shim.o" "$OUT/native/libregexp.o" "$OUT/native/libunicode.o" "$OUT/native/zjs_regexp.o"
"$OUT/lifecycle_test"

echo "[4/6] test262 runner (unmodified)"
clang -std=c11 -O2 -I "$ROOT/include" \
  -o "$OUT/test262_runner" "$ROOT/tests/test262_runner.c" "$OUT/libzjs.a"

echo "[5/6] zjsz command line (Z engine)"
if ! (cd "$Z_LANG" && bun run z build "$HERE/tools/zjsz" --release) >"$OUT/zjsz-build.log" 2>&1; then
  cat "$OUT/zjsz-build.log"; exit 1
fi
cp "$HERE/tools/zjsz/build/zjsz" "$OUT/zjsz"

echo "[6/6] zjs-ref command line (reference engine, public ABI)"
clang -std=c11 -O2 -I "$ROOT/include" \
  -o "$OUT/zjs-ref" "$HERE/tools/zjs-ref.c" "$ROOT/build/libzjs.a" \
  -lm -framework Foundation -framework Security -fobjc-arc -lz

echo
echo "built: $OUT/libzjs.a  ($(( $(stat -f%z "$OUT/libzjs.a") / 1024 )) KiB)"
echo "built: $OUT/test262_runner  $OUT/zjsz  $OUT/zjs-ref"
