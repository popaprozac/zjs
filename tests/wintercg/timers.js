// Timers — setTimeout, setInterval, clearTimeout, clearInterval,
// queueMicrotask.

promise_test(async () => {
  const t0 = Date.now();
  await new Promise(r => setTimeout(r, 20));
  const dt = Date.now() - t0;
  assert_true(dt >= 15, `dt=${dt} should be >= 15ms`);
}, 'setTimeout fires after delay');

promise_test(async () => {
  let fired = false;
  const id = setTimeout(() => fired = true, 1);
  clearTimeout(id);
  await new Promise(r => setTimeout(r, 30));
  assert_false(fired);
}, 'clearTimeout cancels');

promise_test(async () => {
  let n = 0;
  const id = setInterval(() => n++, 5);
  await new Promise(r => setTimeout(r, 30));
  clearInterval(id);
  const after = n;
  await new Promise(r => setTimeout(r, 30));
  assert_true(n >= 2, `n=${n} should be >= 2 after 30ms with 5ms interval`);
  assert_equals(n, after, 'no further ticks after clearInterval');
}, 'setInterval + clearInterval');

promise_test(async () => {
  let order = [];
  queueMicrotask(() => order.push('mt'));
  order.push('sync');
  await Promise.resolve();
  assert_array_equals(order, ['sync', 'mt']);
}, 'queueMicrotask runs after sync code');

promise_test(async () => {
  let order = [];
  setTimeout(() => order.push('to'), 0);
  queueMicrotask(() => order.push('mt'));
  await new Promise(r => setTimeout(r, 20));
  // Microtasks should drain before setTimeout(0).
  assert_equals(order[0], 'mt');
  assert_equals(order[1], 'to');
}, 'queueMicrotask before setTimeout(0)');

__zjs_wintercg_finish();
