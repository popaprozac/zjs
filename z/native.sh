#!/usr/bin/env bash
# The engine's native backend: QuickJS's libregexp and libunicode
# (vendored in engine/native/quickjs) behind the adapter in engine/native,
# built as one static library the Z targets link.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/build/native"
VENDOR="$HERE/engine/native/quickjs"
mkdir -p "$OUT"
CFLAGS=(-std=c11 -O2 -DNDEBUG -Wall -Wextra -I "$VENDOR" -I "$HERE/engine/native")
# QuickJS's sources are built as QuickJS builds them: GNU C, unsigned
# char, wrapping signed arithmetic.
VENDOR_CFLAGS=(-std=gnu11 -O2 -DNDEBUG -funsigned-char -fwrapv -w -I "$VENDOR")
# The matcher's functions start on a cache line, so its speed does not
# move with the size of whatever is linked ahead of it.
clang "${VENDOR_CFLAGS[@]}" -falign-functions=64 -c -o "$OUT/libregexp.o" "$VENDOR/libregexp.c"
clang "${VENDOR_CFLAGS[@]}" -c -o "$OUT/libunicode.o" "$VENDOR/libunicode.c"
clang "${VENDOR_CFLAGS[@]}" -c -o "$OUT/cutils.o" "$VENDOR/cutils.c"
clang "${CFLAGS[@]}" -Werror -c -o "$OUT/zjs_regexp.o" "$HERE/engine/native/zjs_regexp.c"
rm -f "$OUT/libzjsregexp.a"
ar rcs "$OUT/libzjsregexp.a" "$OUT/libregexp.o" "$OUT/libunicode.o" "$OUT/cutils.o" "$OUT/zjs_regexp.o"
echo "built: $OUT/libzjsregexp.a"
