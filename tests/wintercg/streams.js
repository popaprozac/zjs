// WHATWG Streams — ReadableStream, WritableStream, TransformStream,
// tee, BYOB.

test(() => {
  assert_equals(typeof ReadableStream, 'function');
  assert_equals(typeof WritableStream, 'function');
  assert_equals(typeof TransformStream, 'function');
}, 'Stream constructors present');

promise_test(async () => {
  const rs = new ReadableStream({
    start(ctrl) { ctrl.enqueue('a'); ctrl.enqueue('b'); ctrl.close(); },
  });
  const reader = rs.getReader();
  const r1 = await reader.read();
  assert_equals(r1.value, 'a');
  assert_false(r1.done);
  const r2 = await reader.read();
  assert_equals(r2.value, 'b');
  const r3 = await reader.read();
  assert_true(r3.done);
}, 'ReadableStream basic read');

promise_test(async () => {
  const rs = new ReadableStream({
    start(ctrl) { ctrl.enqueue(1); ctrl.enqueue(2); ctrl.close(); },
  });
  const collected = [];
  for await (const v of rs) collected.push(v);
  assert_array_equals(collected, [1, 2]);
}, 'ReadableStream async iteration');

promise_test(async () => {
  const rs = new ReadableStream({
    start(ctrl) { ctrl.enqueue('a'); ctrl.enqueue('b'); ctrl.close(); },
  });
  const [a, b] = rs.tee();
  const readAll = async (s) => {
    const r = s.getReader();
    const out = [];
    while (true) {
      const v = await r.read();
      if (v.done) return out;
      out.push(v.value);
    }
  };
  const [ra, rb] = await Promise.all([readAll(a), readAll(b)]);
  assert_array_equals(ra, ['a', 'b']);
  assert_array_equals(rb, ['a', 'b']);
}, 'ReadableStream.tee');

promise_test(async () => {
  const ts = new TransformStream({
    transform(chunk, controller) { controller.enqueue(chunk * 2); },
  });
  const w = ts.writable.getWriter();
  const r = ts.readable.getReader();
  w.write(3);
  w.close();
  const out = await r.read();
  assert_equals(out.value, 6);
}, 'TransformStream basic');

promise_test(async () => {
  // BYOB consumer: type:'bytes' stream + getReader({mode:'byob'})
  const rs = new ReadableStream({
    type: 'bytes',
    start(ctrl) {
      ctrl.enqueue(new Uint8Array([1, 2, 3, 4, 5]));
      ctrl.close();
    },
  });
  const reader = rs.getReader({ mode: 'byob' });
  const buf = new Uint8Array(3);
  const r1 = await reader.read(buf);
  assert_equals(r1.value.length, 3);
  assert_equals(r1.value[0], 1);
  const r2 = await reader.read(new Uint8Array(3));
  // remaining 2 bytes
  assert_equals(r2.value.length, 2);
  assert_equals(r2.value[0], 4);
}, 'ReadableStream BYOB reader');

test(() => {
  const rs = new ReadableStream({ start(ctrl) {} });
  assert_throws_js(TypeError, () => rs.getReader({ mode: 'byob' }));
}, 'BYOB rejected on default stream');

__zjs_wintercg_finish();
