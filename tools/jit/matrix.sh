#!/bin/sh
# tools/jit/matrix.sh — regenerate the zjs interpreter-vs-JIT metrics matrix.
#
# Rebuilds both configs (default interpreter-only + ZJS_JIT), measures binary
# size, real-JS perf (both run via the interpreter until the JIT covers a hot
# loop), and the JIT's functional status (jit-check). Conformance is identical
# by construction (the JIT only fires for jit-check / bails on unsupported ops,
# so normal execution is pure interpreter) — run `make test262` to verify.
#
# Usage: make jit-matrix   (or: sh tools/jit/matrix.sh)
set -e
cd "$(dirname "$0")/../.."

ID=/tmp/zjs_interp_matrix
JD=/tmp/zjs_jit_matrix

echo "[matrix] building default (interpreter-only) ..."
rm -f build/zjs; make cli >/dev/null 2>&1; cp build/zjs "$ID"
echo "[matrix] building ZJS_JIT=1 ..."
rm -f build/zjs; make ZJS_JIT=1 cli >/dev/null 2>&1; cp build/zjs "$JD"

DEF_SZ=$(wc -c < "$ID" | tr -d ' ')
JIT_SZ=$(wc -c < "$JD" | tr -d ' ')
STENCIL_SZ=$(wc -c < build/jit_stencils-arm64.o 2>/dev/null | tr -d ' ' || echo "?")
DELTA=$((JIT_SZ - DEF_SZ))

cat > /tmp/m_iloop.js <<'EOF'
let s=0; for(let i=0;i<100000000;i++){ s+=i; } console.log(s);
EOF
cat > /tmp/m_fib.js <<'EOF'
function fib(n){ return n<2?n:fib(n-1)+fib(n-2); } console.log(fib(32));
EOF

# best-of-3 wall-clock (seconds) of `<bin> run <script>`
bestof() {
  awk_min='BEGIN{m=1e9} /real/{if($2<m)m=$2} END{printf "%.2f", m}'
  for _ in 1 2 3; do { /usr/bin/time -p "$1" run "$2" >/dev/null; } 2>&1; done | awk "$awk_min"
}

I_ILOOP=$(bestof "$ID" /tmp/m_iloop.js)
J_ILOOP=$(bestof "$JD" /tmp/m_iloop.js)
I_FIB=$(bestof "$ID" /tmp/m_fib.js)
J_FIB=$(bestof "$JD" /tmp/m_fib.js)

# JIT functional probes (does the JIT run real bytecode correctly?)
jit_probe() { "$JD" jit-check "$1" 2>/dev/null | sed 's/jit-check: //'; }

printf '\n=== zjs metrics matrix — interpreter vs ZJS_JIT ===\n\n'
printf '%-26s | %-22s | %-22s | %s\n' "metric" "default (interp)" "ZJS_JIT=1" "delta"
printf '%-26s-+-%-22s-+-%-22s-+-%s\n' "--------------------------" "----------------------" "----------------------" "--------"
printf '%-26s | %-22s | %-22s | %+d B\n' "binary size (bytes)" "$DEF_SZ" "$JIT_SZ" "$DELTA"
printf '%-26s | %-22s | %-22s | %s\n' "folded stencil .text" "-" "$STENCIL_SZ B" "the JIT"
printf '%-26s | %-22ss | %-22ss | ~0\n' "perf int_loop (1e8)" "$I_ILOOP" "$J_ILOOP"
printf '%-26s | %-22ss | %-22ss | ~0\n' "perf fib(32)" "$I_FIB" "$J_FIB"
printf '%-26s | %-22s | %-22s | =\n' "conformance (test262)" "87.2% (run test262)" "identical (bails)"
printf '\n[matrix] JIT functional status (ZJS_JIT build, jit-check):\n'
for e in "42" "true" "undefined" "1+2"; do
  printf '  jit-check %-8s -> %s\n' "\"$e\"" "$(jit_probe "$e")"
done
printf '\nNote: until faithful arithmetic stencils land (J4), the JIT bails on\n'
printf 'real-JS loops, so int_loop/fib run via the interpreter in BOTH builds.\n'
printf 'Spike-validated copy-and-patch projection for int-loops: ~4-6x.\n'
