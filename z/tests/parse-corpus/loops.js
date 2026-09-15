for (var i = 0; i < 10; i++) { total += i; }
for (let j = 0, k = 10; j < k; j++, k--) ;
for (;;) { break; }
for (const key in obj) { if (key) continue; }
for (var v of list) f(v);
for (x of list) ;
for (x in obj) ;
for (const [a, b] of pairs) {}
for (let { c, d } of records) {}
for ([m, n] of pairs) {}
for (x = 0; x < 3; x++) y = x in z;
outer: for (var a = 0; a < 3; a++) { inner: for (var b = 0; b < 3; b++) { if (b) continue outer; else break inner; } }
async function loop() { for await (const item of stream) { use(item); } }
