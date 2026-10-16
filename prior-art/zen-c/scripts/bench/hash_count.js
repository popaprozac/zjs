// Word-frequency count over a synthetic text. Exercises object
// property add/lookup on a growing hidden-class shape + string keys —
// a hash-map workload that mirrors real-world JS patterns.
let words = ["apple", "banana", "cherry", "date", "elderberry",
             "fig", "grape", "honeydew", "kiwi", "lemon",
             "mango", "nectarine", "orange", "papaya", "quince",
             "raspberry", "strawberry", "tangerine", "ugli", "vanilla",
             "watermelon", "xigua", "yellowfruit", "zucchini"];

let n = 30000;
let counts = {};
let seed = 1;
for (let i = 0; i < n; i = i + 1) {
  seed = (seed * 1103515245 + 12345) & 0x7fffffff;
  let w = words[seed % words.length];
  let c = counts[w];
  if (c === undefined) counts[w] = 1;
  else                 counts[w] = c + 1;
}

let total = 0;
for (let i = 0; i < words.length; i = i + 1) {
  let v = counts[words[i]];
  if (v !== undefined) total = total + v;
}
total
