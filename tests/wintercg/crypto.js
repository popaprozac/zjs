// crypto / crypto.subtle / SubtleCrypto.

test(() => {
  assert_equals(typeof crypto, 'object');
  assert_equals(typeof crypto.randomUUID, 'function');
  const u = crypto.randomUUID();
  assert_equals(typeof u, 'string');
  // RFC 4122 v4 shape: 8-4-4-4-12 hex with version 4 + variant 8/9/a/b
  assert_equals(u.length, 36);
  assert_true(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(u),
    `randomUUID format: ${u}`);
}, 'crypto.randomUUID format');

test(() => {
  assert_equals(typeof crypto.getRandomValues, 'function');
  const buf = new Uint8Array(16);
  const r = crypto.getRandomValues(buf);
  assert_equals(r, buf, 'returns same buffer');
  // Not all 16 bytes should equal zero (probability 2^-128).
  let allZero = true;
  for (let i = 0; i < buf.length; i++) if (buf[i] !== 0) { allZero = false; break; }
  assert_false(allZero, 'should be filled with randomness');
}, 'crypto.getRandomValues');

promise_test(async () => {
  assert_equals(typeof crypto.subtle, 'object');
  assert_equals(typeof crypto.subtle.digest, 'function');
  const data = new TextEncoder().encode('hello');
  const hash = await crypto.subtle.digest('SHA-256', data);
  // SHA-256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
  assert_equals(hash.length, 32);
  assert_equals(hash[0], 0x2c);
  assert_equals(hash[1], 0xf2);
}, 'crypto.subtle.digest SHA-256');

promise_test(async () => {
  const data = new TextEncoder().encode('hi');
  const hash = await crypto.subtle.digest('SHA-1', data);
  assert_equals(hash.length, 20);
}, 'crypto.subtle.digest SHA-1');

promise_test(async () => {
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode('secret'),
    { name: 'HMAC', hash: 'SHA-256' }, true, ['sign', 'verify']
  );
  assert_equals(key.type, 'secret');
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode('msg'));
  assert_equals(sig.length, 32);
  const ok = await crypto.subtle.verify('HMAC', key, sig, new TextEncoder().encode('msg'));
  assert_true(ok);
}, 'crypto.subtle.importKey + HMAC sign/verify');

promise_test(async () => {
  assert_equals(typeof crypto.subtle.generateKey, 'function');
  const k = await crypto.subtle.generateKey(
    { name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt']
  );
  assert_equals(k.type, 'secret');
  assert_true(k.extractable);
}, 'crypto.subtle.generateKey AES-GCM');

promise_test(async () => {
  assert_equals(typeof crypto.subtle.exportKey, 'function');
  const k = await crypto.subtle.generateKey(
    { name: 'AES-GCM', length: 128 }, true, ['encrypt']
  );
  const raw = await crypto.subtle.exportKey('raw', k);
  assert_equals(raw.length, 16);
}, 'crypto.subtle.exportKey raw');

promise_test(async () => {
  // AES-GCM encrypt+decrypt is wired API-wise but the Apple platform
  // backend is deferred (see commit history). Skip the round-trip
  // assertion if the backend rejects with OperationError.
  const k = await crypto.subtle.generateKey(
    { name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt']
  );
  const iv = new Uint8Array(12);
  crypto.getRandomValues(iv);
  let ct;
  try {
    ct = await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv }, k, new TextEncoder().encode('hello')
    );
  } catch (e) {
    if (e && e.name === 'OperationError') {
      // Backend not wired on this platform — record as a known limitation.
      throw new Error('AES-GCM backend not wired on this platform');
    }
    throw e;
  }
  assert_equals(ct.length, 5 + 16);
  const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, k, ct);
  assert_equals(new TextDecoder().decode(pt), 'hello');
}, 'crypto.subtle AES-GCM encrypt/decrypt round-trip');

__zjs_wintercg_finish();
