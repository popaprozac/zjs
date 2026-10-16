// Regex matching workload — runs several patterns against a
// generated corpus, exercising the TRE backend's compile + match path.
let corpus = "";
for (let i = 0; i < 200; i = i + 1) {
  corpus = corpus + "the quick brown fox jumps over the lazy dog 12345 ";
  corpus = corpus + "foo@bar.example name=John id=" + i + " ";
  corpus = corpus + "lorem ipsum dolor sit amet, consectetur adipiscing elit. ";
}

let total = 0;
let rounds = 80;
for (let r = 0; r < rounds; r = r + 1) {
  let m1 = corpus.match(/[a-z]+@[a-z\.]+/g);
  let m2 = corpus.match(/[0-9]+/g);
  let m3 = corpus.match(/name=[A-Za-z]+/g);
  total = total
        + (m1 ? m1.length : 0)
        + (m2 ? m2.length : 0)
        + (m3 ? m3.length : 0);
}
total
