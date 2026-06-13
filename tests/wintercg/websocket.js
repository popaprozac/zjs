// WebSocket — WHATWG client API against a loopback RFC 6455 echo server
// (the wintercg runner injects globalThis.__WS_ECHO_URL). Exercises the
// platform client backend: ws_apple.m / ws_linux.c / ws_windows.c.

const ECHO_URL = globalThis.__WS_ECHO_URL;

// --- small promise bridges over the event-handler API ----------------

function withTimeout(promise, ms, label) {
  return Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error("timeout: " + label)), ms)),
  ]);
}

function open(url) {
  return withTimeout(new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.onopen = () => resolve(ws);
    ws.onerror = () => reject(new Error("onerror before open"));
  }), 5000, "open");
}

function nextMessage(ws) {
  return withTimeout(new Promise((resolve) => {
    ws.onmessage = (e) => resolve(e.data);
  }), 5000, "message");
}

function nextClose(ws) {
  return withTimeout(new Promise((resolve) => {
    ws.onclose = (e) => resolve(e);
  }), 5000, "close");
}

// --- tests -----------------------------------------------------------

test(() => {
  assert_equals(typeof WebSocket, "function", "WebSocket is a constructor");
  assert_equals(WebSocket.CONNECTING, 0);
  assert_equals(WebSocket.OPEN, 1);
  assert_equals(WebSocket.CLOSING, 2);
  assert_equals(WebSocket.CLOSED, 3);
}, "WebSocket constructor + readyState constants");

promise_test(async () => {
  const ws = await open(ECHO_URL);
  assert_equals(ws.readyState, WebSocket.OPEN, "OPEN after onopen");
  assert_equals(ws.url, ECHO_URL, "url reflects the constructor argument");
  ws.close();
}, "connect: readyState OPEN and url set");

promise_test(async () => {
  const ws = await open(ECHO_URL);
  ws.send("hello echo");
  const data = await nextMessage(ws);
  assert_equals(data, "hello echo", "text frame echoes verbatim");
  ws.close();
}, "text frame round-trip");

promise_test(async () => {
  const ws = await open(ECHO_URL);
  const out = new Uint8Array([0, 1, 2, 250, 255, 42]);
  ws.send(out);
  const data = await nextMessage(ws);
  // The engine surfaces binary frames as a Uint8Array.
  assert_true(data instanceof Uint8Array || data instanceof ArrayBuffer,
              "binary frame arrives as Uint8Array/ArrayBuffer");
  const view = data instanceof ArrayBuffer ? new Uint8Array(data) : data;
  assert_equals(view.length, out.length, "binary length preserved");
  let same = true;
  for (let i = 0; i < out.length; i++) if (view[i] !== out[i]) same = false;
  assert_true(same, "binary bytes echo verbatim");
  ws.close();
}, "binary frame round-trip");

promise_test(async () => {
  const ws = await open(ECHO_URL);
  // Send three, collect three — order must be preserved.
  const got = [];
  ws.onmessage = (e) => got.push(e.data);
  ws.send("one");
  ws.send("two");
  ws.send("three");
  await withTimeout(new Promise((resolve) => {
    const iv = setInterval(() => {
      if (got.length >= 3) { clearInterval(iv); resolve(); }
    }, 5);
  }), 5000, "three messages");
  assert_array_equals(got.slice(0, 3), ["one", "two", "three"], "FIFO order");
  ws.close();
}, "multiple frames preserve order");

promise_test(async () => {
  const ws = await open(ECHO_URL);
  const closed = nextClose(ws);
  ws.close(1000);
  const ev = await closed;
  assert_equals(ws.readyState, WebSocket.CLOSED, "CLOSED after close event");
  // Some backends can't echo the exact client-initiated code (documented
  // lws limitation surfaces 1005); accept 1000 or the no-status 1005.
  assert_true(ev.code === 1000 || ev.code === 1005,
              "close code is 1000 (or 1005 no-status): " + ev.code);
}, "clean close fires close event");

promise_test(async () => {
  // addEventListener path (not just the onX setter).
  const ws = await open(ECHO_URL);
  const data = await withTimeout(new Promise((resolve) => {
    ws.addEventListener("message", (e) => resolve(e.data));
    ws.send("via addEventListener");
  }), 5000, "addEventListener message");
  assert_equals(data, "via addEventListener");
  ws.close();
}, "addEventListener('message')");

__zjs_wintercg_finish();
