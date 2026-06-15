"""Minimal loopback HTTP test server — stdlib http.server, no deps.

Used by the wintercg `fetch` probe to exercise the *live* HTTP
transport (NSURLSession / WinHTTP / libcurl) rather than just request/
response shapes and data: URLs. Binds 127.0.0.1 on an ephemeral port;
no external network, so it runs in CI.

Routes:
  GET  /text          -> 200 text/plain "hello from loopback"
  GET  /json          -> 200 application/json {"ok":true,"n":42}
  GET  /status?code=N -> status N, body "status N"
  GET  /headers       -> 200 with X-Echo: probe-value (header read test)
  POST /echo          -> 200, echoes the request body; reflects request
                         header X-Probe into response header X-Probe-Echo,
                         and the method into X-Method.
"""
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass  # quiet

    def handle(self):
        # WinHTTP/NSURLSession may reset the socket on close; swallow the
        # resulting recv errors so the server thread doesn't spew
        # tracebacks (the response was already delivered).
        try:
            super().handle()
        except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError):
            pass

    def _send(self, status, body=b"", ctype="text/plain", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        # One request per connection — avoids keep-alive recv sitting open
        # and being reset by the client.
        self.close_connection = True
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/text":
            self._send(200, "hello from loopback")
        elif u.path == "/json":
            self._send(200, json.dumps({"ok": True, "n": 42}),
                       ctype="application/json")
        elif u.path == "/status":
            code = int(parse_qs(u.query).get("code", ["200"])[0])
            self._send(code, f"status {code}")
        elif u.path == "/headers":
            self._send(200, "with-headers", extra={"X-Echo": "probe-value"})
        else:
            self._send(404, "not found")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b""
        if urlparse(self.path).path == "/echo":
            self._send(200, body, ctype="application/octet-stream", extra={
                "X-Probe-Echo": self.headers.get("X-Probe", ""),
                "X-Method": "POST",
            })
        else:
            self._send(404, "not found")


class HttpEchoServer:
    """Context-manager HTTP server. `.url` is http://127.0.0.1:<port>."""

    def __init__(self):
        self._srv = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self.port = self._srv.server_address[1]
        self.url = f"http://127.0.0.1:{self.port}"
        self._thread = threading.Thread(target=self._srv.serve_forever, daemon=True)

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, *exc):
        self._srv.shutdown()
        self._srv.server_close()


if __name__ == "__main__":
    import time
    with HttpEchoServer() as s:
        print(s.url, flush=True)
        while True:
            time.sleep(1)
