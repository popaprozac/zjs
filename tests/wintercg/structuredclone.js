// structuredClone.

test(() => {
  assert_equals(typeof structuredClone, 'function');
}, 'structuredClone present');

test(() => {
  const o = { a: 1, b: 'two', c: true, d: null };
  const c = structuredClone(o);
  assert_equals(c.a, 1);
  assert_equals(c.b, 'two');
  assert_equals(c.c, true);
  assert_equals(c.d, null);
}, 'primitives + plain object');

test(() => {
  const o = { x: [1, 2, { y: 3 }] };
  const c = structuredClone(o);
  c.x[2].y = 99;
  assert_equals(o.x[2].y, 3, 'original unchanged');
  assert_equals(c.x[2].y, 99);
}, 'deep clone — mutation independence');

test(() => {
  const m = new Map([['a', 1], ['b', 2]]);
  const c = structuredClone(m);
  assert_equals(c.get('a'), 1);
  assert_equals(c.get('b'), 2);
  assert_true(c instanceof Map);
}, 'Map');

test(() => {
  const s = new Set([1, 2, 3]);
  const c = structuredClone(s);
  assert_true(c.has(1));
  assert_true(c.has(2));
  assert_true(c.has(3));
  assert_true(c instanceof Set);
}, 'Set');

test(() => {
  const d = new Date(2026, 0, 15);
  const c = structuredClone(d);
  assert_true(c instanceof Date);
  assert_equals(c.valueOf(), d.valueOf());
}, 'Date');

test(() => {
  const r = /abc/gi;
  const c = structuredClone(r);
  assert_true(c instanceof RegExp);
  assert_equals(c.source, 'abc');
  assert_equals(c.flags, 'gi');
}, 'RegExp');

test(() => {
  const u = new Uint8Array([1, 2, 3]);
  const c = structuredClone(u);
  assert_true(c instanceof Uint8Array);
  assert_array_equals(Array.from(c), [1, 2, 3]);
}, 'Uint8Array');

test(() => {
  // Cycles should be preserved, not infinite-loop.
  const a = { name: 'a' };
  a.self = a;
  const c = structuredClone(a);
  assert_equals(c.name, 'a');
  assert_equals(c.self, c, 'self-reference preserved');
}, 'cyclic graph');

test(() => {
  assert_throws_dom('DataCloneError', () => structuredClone(() => 1));
}, 'function throws DataCloneError');

test(() => {
  assert_throws_dom('DataCloneError', () => structuredClone(Symbol('x')));
}, 'symbol throws DataCloneError');

__zjs_wintercg_finish();
