// URL + URLSearchParams.

test(() => {
  const u = new URL('https://example.com/path?q=1');
  assert_equals(u.protocol, 'https:');
  assert_equals(u.hostname, 'example.com');
  assert_equals(u.pathname, '/path');
  assert_equals(u.search, '?q=1');
}, 'URL basic parts');

test(() => {
  const u = new URL('/rel', 'https://example.com/base/');
  assert_equals(u.href, 'https://example.com/rel');
}, 'URL relative resolve');

test(() => {
  const u = new URL('https://user:pass@host:8080/p?a=1#x');
  assert_equals(u.username, 'user');
  assert_equals(u.password, 'pass');
  assert_equals(u.host, 'host:8080');
  assert_equals(u.port, '8080');
  assert_equals(u.hash, '#x');
}, 'URL credentials/port/hash');

test(() => {
  assert_throws_js(TypeError, () => new URL('not-a-url'));
}, 'URL invalid throws TypeError');

test(() => {
  const u = new URL('https://example.com/');
  u.pathname = '/changed';
  assert_equals(u.pathname, '/changed');
  assert_equals(u.href, 'https://example.com/changed');
}, 'URL setter updates href');

test(() => {
  const sp = new URLSearchParams('a=1&b=2');
  assert_equals(sp.get('a'), '1');
  assert_equals(sp.get('b'), '2');
  assert_equals(sp.get('missing'), null);
}, 'URLSearchParams parse + get');

test(() => {
  const sp = new URLSearchParams();
  sp.append('k', 'v1');
  sp.append('k', 'v2');
  assert_equals(sp.getAll('k').length, 2);
  assert_equals(sp.getAll('k')[1], 'v2');
}, 'URLSearchParams append + getAll');

test(() => {
  const sp = new URLSearchParams('a=1&b=2&c=3');
  sp.delete('b');
  assert_false(sp.has('b'));
  assert_true(sp.has('a'));
  assert_true(sp.has('c'));
}, 'URLSearchParams delete');

test(() => {
  const sp = new URLSearchParams();
  sp.set('x', '1');
  sp.set('x', '2');
  assert_equals(sp.getAll('x').length, 1);
  assert_equals(sp.get('x'), '2');
}, 'URLSearchParams set replaces');

test(() => {
  const sp = new URLSearchParams('a=1&b=2');
  assert_equals(sp.toString(), 'a=1&b=2');
}, 'URLSearchParams toString');

test(() => {
  const sp = new URLSearchParams('a=1&b=hello%20world');
  assert_equals(sp.get('b'), 'hello world');
}, 'URLSearchParams percent-decode');

__zjs_wintercg_finish();
