#!/usr/bin/env bash
# Phase 1: build the Z engine, wrap it in the frozen zjs.h ABI, and link the
# existing test262 runner against it unchanged.
set -euo pipefail

Z_LANG="${Z_LANG:-$HOME/code/z-lang}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/build"

mkdir -p "$OUT"

echo "[1/4] Z engine -> libzjsz.a"
(cd "$Z_LANG" && bun run z build "$HERE/engine" >/dev/null)

echo "[2/4] ABI shim"
clang -std=c11 -Wall -Wextra -Werror -O2 -c \
  -I "$ROOT/include" -I "$HERE/engine/build" \
  -o "$OUT/zjs_shim.o" "$HERE/shim/zjs_shim.c"

echo "[3/4] libzjs.a"
rm -f "$OUT/libzjs.a"
cp "$HERE/engine/build/libzjsz.a" "$OUT/libzjs.a"
ar r "$OUT/libzjs.a" "$OUT/zjs_shim.o"
ranlib "$OUT/libzjs.a"

echo "[4/4] test262 runner (unmodified)"
clang -std=c11 -O2 -I "$ROOT/include" \
  -o "$OUT/test262_runner" "$ROOT/tests/test262_runner.c" "$OUT/libzjs.a"

echo
echo "built: $OUT/libzjs.a  ($(( $(stat -f%z "$OUT/libzjs.a") / 1024 )) KiB)"
echo "built: $OUT/test262_runner"
