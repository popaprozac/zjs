// Double arithmetic — tight loop with floats. Stresses NaN-box decode
// and zjs_arith_* numeric paths (no int32 fast path).
let sum = 0.0;
let n = 500000;
for (let i = 0; i < n; i = i + 1) {
  sum = sum + 1.5;
}
sum
