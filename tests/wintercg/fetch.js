// fetch / Request / Response / Headers — shapes, data: URLs, and the
// LIVE HTTP transport (NSURLSession / WinHTTP / libcurl).
//
// The live-path tests hit a loopback HTTP server the wintercg runner
// starts and injects as globalThis.__HTTP_ECHO_URL — no external
// network. They skip cleanly if that global is absent (probe run
// standalone). data: URLs still give a deterministic round-trip
// without a server.

test(() => {
  assert_equals(typeof fetch, 'function');
  assert_equals(typeof Headers, 'function');
  assert_equals(typeof Request, 'function');
  assert_equals(typeof Response, 'function');
}, 'fetch globals present');

test(() => {
  const h = new Headers();
  h.set('Content-Type', 'application/json');
  assert_equals(h.get('content-type'), 'application/json',
    'lookup is case-insensitive');
}, 'Headers case-insensitive');

test(() => {
  const h = new Headers({ a: '1', b: '2' });
  assert_equals(h.get('a'), '1');
  assert_equals(h.get('b'), '2');
}, 'Headers init from object');

test(() => {
  const h = new Headers();
  h.append('x', '1');
  h.append('x', '2');
  // append: comma-separated combined value per spec
  assert_equals(h.get('x'), '1, 2');
}, 'Headers append combines');

test(() => {
  const h = new Headers({ x: '1' });
  h.delete('x');
  assert_false(h.has('x'));
}, 'Headers delete');

test(() => {
  const r = new Request('https://example.com/', { method: 'POST' });
  assert_equals(r.url, 'https://example.com/');
  assert_equals(r.method, 'POST');
}, 'Request shape');

test(() => {
  const r = new Response('hi', { status: 201, statusText: 'Created' });
  assert_equals(r.status, 201);
  assert_equals(r.statusText, 'Created');
  assert_true(r.ok);
}, 'Response shape');

test(() => {
  const r = new Response('', { status: 500 });
  assert_false(r.ok);
}, 'Response .ok=false on 5xx');

promise_test(async () => {
  const r = new Response('hello');
  const text = await r.text();
  assert_equals(text, 'hello');
}, 'Response.text()');

promise_test(async () => {
  const r = new Response(JSON.stringify({ a: 1 }));
  const obj = await r.json();
  assert_equals(obj.a, 1);
}, 'Response.json()');

promise_test(async () => {
  const r = await fetch('data:text/plain,hello');
  assert_equals(r.status, 200);
  const text = await r.text();
  assert_equals(text, 'hello');
}, 'fetch data: URL');

promise_test(async () => {
  const r = await fetch('data:application/json,' + encodeURIComponent('{"x":1}'));
  const obj = await r.json();
  assert_equals(obj.x, 1);
}, 'fetch data: JSON');

// --- live HTTP transport (loopback server) ---------------------------

const BASE = globalThis.__HTTP_ECHO_URL;

promise_test(async () => {
  if (!BASE) return;  // standalone run, no server injected
  const r = await fetch(BASE + '/text');
  assert_equals(r.status, 200, 'status 200');
  assert_true(r.ok, 'ok true on 2xx');
  assert_true((r.headers.get('content-type') || '').indexOf('text/plain') === 0,
              'content-type text/plain');
  assert_equals(await r.text(), 'hello from loopback', 'body matches');
}, 'fetch live GET text');

promise_test(async () => {
  if (!BASE) return;
  const r = await fetch(BASE + '/json');
  assert_equals(r.status, 200);
  const obj = await r.json();
  assert_equals(obj.ok, true, 'json.ok');
  assert_equals(obj.n, 42, 'json.n');
}, 'fetch live GET json + Response.json()');

promise_test(async () => {
  if (!BASE) return;
  const r = await fetch(BASE + '/status?code=404');
  assert_equals(r.status, 404, 'status 404');
  assert_false(r.ok, 'ok false on 4xx');
}, 'fetch live non-2xx status');

promise_test(async () => {
  if (!BASE) return;
  const r = await fetch(BASE + '/headers');
  assert_equals(r.headers.get('x-echo'), 'probe-value',
                'custom response header readable (case-insensitive)');
}, 'fetch live response headers');

promise_test(async () => {
  if (!BASE) return;
  const r = await fetch(BASE + '/echo', {
    method: 'POST',
    headers: { 'X-Probe': 'sentinel' },
    body: 'request body bytes',
  });
  assert_equals(r.status, 200);
  assert_equals(r.headers.get('x-method'), 'POST', 'server saw POST');
  assert_equals(r.headers.get('x-probe-echo'), 'sentinel',
                'request header reached the server');
  assert_equals(await r.text(), 'request body bytes', 'request body echoed');
}, 'fetch live POST body + request headers');

__zjs_wintercg_finish();
