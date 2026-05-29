// AbortController + AbortSignal.

test(() => {
  const ac = new AbortController();
  assert_false(ac.signal.aborted);
  assert_equals(ac.signal.reason, undefined);
}, 'AbortController initial state');

test(() => {
  const ac = new AbortController();
  ac.abort();
  assert_true(ac.signal.aborted);
}, 'AbortController.abort flips signal');

test(() => {
  const ac = new AbortController();
  let fired = false;
  ac.signal.addEventListener('abort', () => fired = true);
  ac.abort();
  assert_true(fired);
}, 'abort fires signal event');

test(() => {
  const ac = new AbortController();
  ac.abort('reason-x');
  assert_equals(ac.signal.reason, 'reason-x');
}, 'abort(reason) sets .reason');

test(() => {
  const ac = new AbortController();
  ac.abort();
  assert_throws_dom('AbortError', () => ac.signal.throwIfAborted());
}, 'throwIfAborted when aborted');

test(() => {
  const ac = new AbortController();
  ac.signal.throwIfAborted();  // should not throw
  assert_true(true);
}, 'throwIfAborted no-op when fresh');

test(() => {
  // AbortSignal.abort() static — pre-aborted signal.
  assert_equals(typeof AbortSignal.abort, 'function');
  const s = AbortSignal.abort('static-reason');
  assert_true(s.aborted);
  assert_equals(s.reason, 'static-reason');
}, 'AbortSignal.abort() static');

promise_test(async () => {
  // AbortSignal.timeout() — pre-built signal that auto-aborts.
  assert_equals(typeof AbortSignal.timeout, 'function');
  const s = AbortSignal.timeout(5);
  assert_false(s.aborted);
  await new Promise(r => setTimeout(r, 30));
  assert_true(s.aborted);
}, 'AbortSignal.timeout fires');

test(() => {
  // AbortSignal.any() — short-circuits when one input is already aborted.
  assert_equals(typeof AbortSignal.any, 'function');
  const a = new AbortController();
  const b = AbortSignal.abort('b');
  const any = AbortSignal.any([a.signal, b]);
  assert_true(any.aborted);
}, 'AbortSignal.any with pre-aborted member');

__zjs_wintercg_finish();
