#!/usr/bin/env bash
# Spike harness: emit each Z variant to C, compile every variant with the
# same clang -O2 the Z --release path uses, verify all produce an identical
# checksum, then report median wall time and stripped binary size.
set -euo pipefail

Z_LANG="${Z_LANG:-$HOME/code/z-lang}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-/tmp/zjs-spike}"
SAMPLES="${SAMPLES:-7}"
export SPIKE_N="${SPIKE_N:-1000000}"

mkdir -p "$OUT"

Z_VARIANTS=(v-inline-ptr v-inline-pool v-inline-ptr-wide v-table-ptr v-rawc-ptr)

echo "building..."
for v in "${Z_VARIANTS[@]}"; do
  [ -f "$HERE/$v.zs" ] || continue
  (cd "$Z_LANG" && bun run z emit "$HERE/$v.zs" > "$OUT/$v.c" 2>/dev/null)
  clang -O2 -o "$OUT/$v" "$OUT/$v.c"
done
clang -O2 -o "$OUT/baseline" "$HERE/baseline.c"

median() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }

printf "\n%-22s %12s %12s %10s  %s\n" VARIANT "MEDIAN(ms)" "REL" "SIZE(KiB)" CHECKSUM
run_one() {
  local name="$1" bin="$2" times=() out=""
  for _ in $(seq "$SAMPLES"); do
    out="$("$bin")"
    times+=("$(sed 's/.*ns=//' <<<"$out")")
  done
  local ns; ns=$(printf '%s\n' "${times[@]}" | median)
  local sum; sum="$(sed 's/.* result=\([-0-9]*\).*/\1/' <<<"$out")"
  strip -S "$bin" 2>/dev/null || true
  local kib; kib=$(( $(stat -f%z "$bin") / 1024 ))
  echo "$name $ns $kib $sum"
}

BASE_NS=""
RESULTS=()
line="$(run_one baseline "$OUT/baseline")"
BASE_NS=$(awk '{print $2}' <<<"$line")
RESULTS+=("$line")
for v in "${Z_VARIANTS[@]}"; do
  [ -x "$OUT/$v" ] || continue
  RESULTS+=("$(run_one "$v" "$OUT/$v")")
done

for r in "${RESULTS[@]}"; do
  set -- $r
  awk -v n="$1" -v ns="$2" -v kib="$3" -v sum="$4" -v base="$BASE_NS" \
    'BEGIN{printf "%-22s %12.2f %11.3fx %10d  %s\n", n, ns/1e6, ns/base, kib, sum}'
done

echo
echo "checksums must all match; n=$SPIKE_N, samples=$SAMPLES, clang -O2"
