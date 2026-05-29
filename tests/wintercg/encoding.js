// WinterTC MCA conformance probes — Encoding family.
// Covers: btoa, atob, TextEncoder, TextDecoder, TextEncoderStream,
// TextDecoderStream.

test(() => {
  assert_equals(btoa('hello'), 'aGVsbG8=');
}, 'btoa basic');

test(() => {
  assert_equals(atob('aGVsbG8='), 'hello');
}, 'atob basic');

test(() => {
  assert_equals(atob(btoa('round-trip')), 'round-trip');
}, 'atob/btoa round-trip');

test(() => {
  assert_throws_dom('InvalidCharacterError', () => atob('not_base64!'));
}, 'atob throws on bad input');

test(() => {
  const enc = new TextEncoder();
  assert_equals(enc.encoding, 'utf-8');
  const bytes = enc.encode('hi');
  assert_equals(bytes.length, 2);
  assert_equals(bytes[0], 104);
  assert_equals(bytes[1], 105);
}, 'TextEncoder shape + ASCII');

test(() => {
  const enc = new TextEncoder();
  const bytes = enc.encode('é');
  // UTF-8: 0xC3 0xA9
  assert_equals(bytes.length, 2);
  assert_equals(bytes[0], 0xC3);
  assert_equals(bytes[1], 0xA9);
}, 'TextEncoder UTF-8 multi-byte');

test(() => {
  const dec = new TextDecoder();
  assert_equals(dec.encoding, 'utf-8');
  assert_equals(dec.decode(new Uint8Array([104, 105])), 'hi');
}, 'TextDecoder basic');

test(() => {
  const dec = new TextDecoder();
  assert_equals(dec.decode(new Uint8Array([0xC3, 0xA9])), 'é');
}, 'TextDecoder UTF-8 multi-byte');

test(() => {
  assert_equals(typeof TextEncoderStream, 'function');
  assert_equals(typeof TextDecoderStream, 'function');
}, 'Encoding streams classes present');

promise_test(async () => {
  const ts = new TextEncoderStream();
  const w = ts.writable.getWriter();
  const r = ts.readable.getReader();
  await w.write('xy');
  await w.close();
  const out = await r.read();
  assert_equals(out.value.length, 2);
  assert_equals(out.value[0], 120);
  assert_equals(out.value[1], 121);
}, 'TextEncoderStream round-trip');

promise_test(async () => {
  const ds = new TextDecoderStream();
  const w = ds.writable.getWriter();
  const r = ds.readable.getReader();
  await w.write(new Uint8Array([97, 98, 99]));
  await w.close();
  const out = await r.read();
  assert_equals(out.value, 'abc');
}, 'TextDecoderStream round-trip');

__zjs_wintercg_finish();
