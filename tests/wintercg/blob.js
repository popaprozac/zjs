// Blob + File + FormData.

test(() => {
  const b = new Blob(['hello, ', 'world']);
  assert_equals(b.size, 12);
}, 'Blob concatenates string parts');

test(() => {
  const b = new Blob(['x'], { type: 'text/plain' });
  assert_equals(b.type, 'text/plain');
}, 'Blob type option');

promise_test(async () => {
  const b = new Blob(['abc']);
  const text = await b.text();
  assert_equals(text, 'abc');
}, 'Blob.text()');

promise_test(async () => {
  const b = new Blob([new Uint8Array([1, 2, 3, 4])]);
  // arrayBuffer() may be missing if not wired
  if (typeof b.arrayBuffer !== 'function') {
    throw new Error('Blob.arrayBuffer not implemented');
  }
  const ab = await b.arrayBuffer();
  assert_true(ab != null);
}, 'Blob.arrayBuffer()');

test(() => {
  const b = new Blob(['abcdef']);
  const sliced = b.slice(1, 4);
  assert_equals(sliced.size, 3);
}, 'Blob.slice');

test(() => {
  const f = new File(['hi'], 'a.txt', { type: 'text/plain' });
  assert_equals(f.name, 'a.txt');
  assert_equals(f.size, 2);
  assert_equals(f.type, 'text/plain');
  assert_true(f instanceof Blob);
}, 'File extends Blob');

test(() => {
  const fd = new FormData();
  fd.append('a', '1');
  fd.append('b', '2');
  assert_equals(fd.get('a'), '1');
  assert_equals(fd.get('b'), '2');
}, 'FormData append + get');

test(() => {
  const fd = new FormData();
  fd.append('k', 'v1');
  fd.append('k', 'v2');
  const all = fd.getAll('k');
  assert_equals(all.length, 2);
  assert_equals(all[0], 'v1');
  assert_equals(all[1], 'v2');
}, 'FormData getAll');

test(() => {
  const fd = new FormData();
  fd.set('a', 'first');
  fd.set('a', 'second');
  assert_equals(fd.getAll('a').length, 1);
  assert_equals(fd.get('a'), 'second');
}, 'FormData set replaces');

test(() => {
  const fd = new FormData();
  fd.append('a', '1');
  fd.append('b', '2');
  fd.delete('a');
  assert_false(fd.has('a'));
  assert_true(fd.has('b'));
}, 'FormData delete');

test(() => {
  const fd = new FormData();
  fd.append('x', '1');
  fd.append('y', '2');
  const entries = [];
  for (const [k, v] of fd) entries.push(k + '=' + v);
  assert_equals(entries.length, 2);
}, 'FormData iteration');

__zjs_wintercg_finish();
