// performance.now / .timeOrigin / .mark / .measure / .getEntries*

test(() => {
  assert_equals(typeof performance, 'object');
  assert_equals(typeof performance.now, 'function');
  const a = performance.now();
  const b = performance.now();
  assert_true(typeof a === 'number');
  assert_true(b >= a);
}, 'performance.now monotonic');

test(() => {
  assert_equals(typeof performance.timeOrigin, 'number');
  assert_true(performance.timeOrigin > 0);
}, 'performance.timeOrigin');

test(() => {
  assert_equals(typeof performance.mark, 'function');
  const m = performance.mark('a');
  assert_equals(m.name, 'a');
  assert_equals(m.entryType, 'mark');
  assert_true(typeof m.startTime === 'number');
}, 'performance.mark');

test(() => {
  performance.clearMarks();
  performance.clearMeasures();
  performance.mark('s');
  performance.mark('e');
  const m = performance.measure('m', 's', 'e');
  assert_equals(m.entryType, 'measure');
  assert_equals(m.name, 'm');
  assert_true(typeof m.duration === 'number');
}, 'performance.measure between marks');

test(() => {
  performance.clearMarks();
  performance.clearMeasures();
  performance.mark('a');
  performance.measure('m1', { start: 0, duration: 10, detail: { tag: 'x' } });
  const e = performance.getEntriesByName('m1')[0];
  assert_equals(e.duration, 10);
  assert_equals(e.detail.tag, 'x');
}, 'measure with options form');

test(() => {
  performance.clearMarks();
  performance.clearMeasures();
  performance.mark('a');
  performance.mark('b');
  performance.measure('m', 'a', 'b');
  assert_equals(performance.getEntriesByType('mark').length, 2);
  assert_equals(performance.getEntriesByType('measure').length, 1);
}, 'getEntriesByType');

test(() => {
  performance.clearMarks();
  performance.mark('x');
  performance.clearMarks();
  assert_equals(performance.getEntriesByType('mark').length, 0);
}, 'clearMarks() empties all');

test(() => {
  assert_throws_dom('SyntaxError', () => performance.measure('bad', 'nonexistent'));
}, 'measure throws on unknown mark');

__zjs_wintercg_finish();
