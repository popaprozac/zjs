// Array build + for-of iteration. Exercises NewArray, StoreElem,
// IterPrepare, ArrayLength, LoadElem.
let arr = [];
let n = 50000;
for (let i = 0; i < n; i = i + 1) {
  arr[i] = i;
}
let sum = 0;
for (let v of arr) {
  sum = sum + v;
}
sum
