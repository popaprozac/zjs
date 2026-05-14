// Sieve of Eratosthenes up to 200k. Array indexing + arithmetic +
// nested loop — closer to realistic numeric code than int_loop.
let n = 200000;
let primes = [];
for (let i = 0; i <= n; i = i + 1) primes[i] = true;
primes[0] = false;
primes[1] = false;
for (let i = 2; i * i <= n; i = i + 1) {
  if (primes[i]) {
    for (let j = i * i; j <= n; j = j + i) primes[j] = false;
  }
}
let count = 0;
for (let i = 0; i <= n; i = i + 1) if (primes[i]) count = count + 1;
count
