// try/catch overhead with no thrown exceptions. Measures cost of
// EnterTry/LeaveTry on the hot path.
let n = 200000;
let sum = 0;
for (let i = 0; i < n; i = i + 1) {
  try {
    sum = sum + i;
  } catch (e) {
    sum = -1;
  }
}
sum
