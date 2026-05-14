// Integer hot loop — tight dispatch + integer arithmetic + comparison.
// Stresses: Op::Add, Op::CmpLt, Op::JmpIfFalse, opcode dispatch overhead.
let sum = 0;
let n = 1000000;
for (let i = 0; i < n; i = i + 1) {
  sum = sum + i;
}
sum
