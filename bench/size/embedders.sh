#!/usr/bin/env bash
# The engine's size as an embedder links it: minimal programs over the
# frozen ABI, linked against build/libzjs.a and dead-stripped, their
# segment sizes (nothing stripped). Run after ./build.sh.
#   source    zjs_new_context and zjs_eval
#   core      zjs_new_core_context and zjs_eval
#   bytecode  zjs_new_core_context and zjs_eval_bytecode: no compiler
#   module    zjs_new_core_context and zjs_eval_module_bytecode: no
#             compiler, the module linker and file loader
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/build/size"
mkdir -p "$OUT"
for name in source core bytecode module; do
  clang -std=c11 -O2 -Wall -Wextra -Werror -I "$ROOT/include" -Wl,-dead_strip \
    -o "$OUT/$name" "$HERE/$name.c" "$ROOT/build/libzjs.a"
done
printf '%-10s %10s %8s\n' embedder __TEXT __DATA
for name in source core bytecode module; do
  size "$OUT/$name" | awk -v n="$name" 'NR == 2 { printf "%-10s %10d %8d\n", n, $1, $2 }'
done
