// EventTarget, Event, CustomEvent, DOMException.

test(() => {
  const e = new Event('x');
  assert_equals(e.type, 'x');
  assert_equals(e.bubbles, false);
  assert_equals(e.cancelable, false);
  assert_equals(e.defaultPrevented, false);
}, 'Event basic shape');

test(() => {
  const e = new Event('x', { bubbles: true, cancelable: true });
  assert_equals(e.bubbles, true);
  assert_equals(e.cancelable, true);
}, 'Event init options');

test(() => {
  const e = new Event('x', { cancelable: true });
  e.preventDefault();
  assert_true(e.defaultPrevented);
}, 'Event.preventDefault');

test(() => {
  const e = new CustomEvent('y', { detail: 42 });
  assert_equals(e.type, 'y');
  assert_equals(e.detail, 42);
}, 'CustomEvent.detail');

test(() => {
  const t = new EventTarget();
  let n = 0;
  const h = () => n++;
  t.addEventListener('x', h);
  t.dispatchEvent(new Event('x'));
  t.dispatchEvent(new Event('x'));
  assert_equals(n, 2);
}, 'addEventListener fires multiple times');

test(() => {
  const t = new EventTarget();
  let n = 0;
  const h = () => n++;
  t.addEventListener('x', h);
  t.removeEventListener('x', h);
  t.dispatchEvent(new Event('x'));
  assert_equals(n, 0);
}, 'removeEventListener stops dispatch');

test(() => {
  const t = new EventTarget();
  let n = 0;
  t.addEventListener('x', () => n++, { once: true });
  t.dispatchEvent(new Event('x'));
  t.dispatchEvent(new Event('x'));
  assert_equals(n, 1);
}, '{once:true} auto-removes');

test(() => {
  const t = new EventTarget();
  let detail = null;
  t.addEventListener('x', e => { detail = e.detail; });
  t.dispatchEvent(new CustomEvent('x', { detail: 'hi' }));
  assert_equals(detail, 'hi');
}, 'CustomEvent flows through dispatchEvent');

test(() => {
  assert_equals(typeof DOMException, 'function');
  const e = new DOMException('bad', 'SyntaxError');
  assert_equals(e.name, 'SyntaxError');
  assert_equals(e.message, 'bad');
  assert_true(e instanceof Error);
}, 'DOMException shape');

test(() => {
  const t = new EventTarget();
  const e = new Event('x', { cancelable: true });
  t.addEventListener('x', ev => ev.preventDefault());
  const result = t.dispatchEvent(e);
  assert_false(result, 'dispatchEvent returns false when preventDefault was called');
}, 'dispatchEvent returns false on preventDefault');

__zjs_wintercg_finish();
