#!/usr/bin/env bash
# The engine's native backend: libregexp (vendored, shared with the
# reference) behind the adapter in engine/native, built as one static
# library the Z targets link.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/build/native"
VENDOR="$ROOT/src/third-party/qjs-regex"
mkdir -p "$OUT"
CFLAGS=(-std=c11 -O2 -DNDEBUG -Wall -Wextra -I "$VENDOR" -I "$HERE/engine/native")
clang "${CFLAGS[@]}" -Wno-unused-parameter -Wno-sign-compare -Wno-unused-function -c -o "$OUT/libregexp.o" "$VENDOR/libregexp.c"
clang "${CFLAGS[@]}" -Wno-unused-parameter -Wno-sign-compare -Wno-unused-function -c -o "$OUT/libunicode.o" "$VENDOR/libunicode.c"
clang "${CFLAGS[@]}" -Werror -c -o "$OUT/zjs_regexp.o" "$HERE/engine/native/zjs_regexp.c"
rm -f "$OUT/libzjsregexp.a"
ar rcs "$OUT/libzjsregexp.a" "$OUT/libregexp.o" "$OUT/libunicode.o" "$OUT/zjs_regexp.o"
echo "built: $OUT/libzjsregexp.a"
