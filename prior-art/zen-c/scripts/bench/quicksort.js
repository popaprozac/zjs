// Quicksort on a pseudo-random integer array. Stresses recursion,
// array indexing, swaps, comparison-and-branch — closer to a real
// sort kernel than the synthetic micro-benches.
function rand(seed) {
  let s = seed;
  return function () {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    return s;
  };
}

function quicksort(arr, lo, hi) {
  if (lo >= hi) return;
  let pivot = arr[(lo + hi) >> 1];
  let i = lo;
  let j = hi;
  while (i <= j) {
    while (arr[i] < pivot) i = i + 1;
    while (arr[j] > pivot) j = j - 1;
    if (i <= j) {
      let t = arr[i];
      arr[i] = arr[j];
      arr[j] = t;
      i = i + 1;
      j = j - 1;
    }
  }
  quicksort(arr, lo, j);
  quicksort(arr, i, hi);
}

let n = 30000;
let rng = rand(12345);
let arr = [];
for (let i = 0; i < n; i = i + 1) arr[i] = rng();

quicksort(arr, 0, n - 1);

// Verify sorted (returns boolean cheaply; no print to keep runner fast).
let ok = true;
for (let i = 1; i < n; i = i + 1) {
  if (arr[i - 1] > arr[i]) { ok = false; break; }
}
ok
