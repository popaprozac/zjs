"""Minimal RFC 6455 WebSocket echo server — stdlib socket only, no deps.

Used by the wintercg `websocket` probe to exercise the platform
WebSocket *client* backends (ws_apple.m / ws_linux.c / ws_windows.c)
against a known-correct peer, with no external network. Binds to
127.0.0.1 on an ephemeral port; echoes every text/binary frame back
verbatim; replies to a client Close with a Close (echoing the code).

Not a general-purpose server: one connection handler per accept, runs
in a background thread, handles exactly the frames the probe sends.
"""
import base64
import hashlib
import socket
import struct
import threading

_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def _accept_key(client_key: str) -> str:
    digest = hashlib.sha1((client_key + _GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def _read_http_headers(conn) -> dict:
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = conn.recv(1024)
        if not chunk:
            return {}
        buf += chunk
        if len(buf) > 65536:
            return {}
    headers = {}
    for line in buf.split(b"\r\n")[1:]:
        if b":" in line:
            k, _, v = line.partition(b":")
            headers[k.strip().lower().decode("latin1")] = v.strip().decode("latin1")
    return headers


def _recv_exact(conn, n: int) -> bytes:
    out = b""
    while len(out) < n:
        chunk = conn.recv(n - len(out))
        if not chunk:
            return b""
        out += chunk
    return out


def _read_frame(conn):
    """Return (opcode, payload) or (None, None) on EOF/error."""
    hdr = _recv_exact(conn, 2)
    if len(hdr) < 2:
        return None, None
    b0, b1 = hdr[0], hdr[1]
    opcode = b0 & 0x0F
    masked = (b1 & 0x80) != 0
    length = b1 & 0x7F
    if length == 126:
        ext = _recv_exact(conn, 2)
        if len(ext) < 2:
            return None, None
        length = struct.unpack("!H", ext)[0]
    elif length == 127:
        ext = _recv_exact(conn, 8)
        if len(ext) < 8:
            return None, None
        length = struct.unpack("!Q", ext)[0]
    mask = _recv_exact(conn, 4) if masked else b""
    payload = _recv_exact(conn, length) if length else b""
    if len(payload) < length:
        return None, None
    if masked:
        payload = bytes(payload[i] ^ mask[i % 4] for i in range(len(payload)))
    return opcode, payload


def _build_frame(opcode: int, payload: bytes) -> bytes:
    """Server frames are unmasked."""
    out = bytearray([0x80 | opcode])
    n = len(payload)
    if n < 126:
        out.append(n)
    elif n < 65536:
        out.append(126)
        out += struct.pack("!H", n)
    else:
        out.append(127)
        out += struct.pack("!Q", n)
    out += payload
    return bytes(out)


def _handle(conn):
    try:
        headers = _read_http_headers(conn)
        key = headers.get("sec-websocket-key")
        if not key:
            conn.close()
            return
        accept = _accept_key(key)
        resp = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
        )
        conn.sendall(resp.encode("ascii"))
        while True:
            opcode, payload = _read_frame(conn)
            if opcode is None:
                break
            if opcode == 0x8:  # close — echo it back, then stop
                code = payload[:2] if len(payload) >= 2 else b""
                conn.sendall(_build_frame(0x8, code))
                break
            elif opcode == 0x9:  # ping -> pong
                conn.sendall(_build_frame(0xA, payload))
            elif opcode in (0x1, 0x2):  # text / binary -> echo same opcode
                conn.sendall(_build_frame(opcode, payload))
            # ignore pong (0xA) and continuation (0x0) — probe doesn't send them
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


class WsEchoServer:
    """Context-manager echo server. `.url` is ws://127.0.0.1:<port>."""

    def __init__(self):
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(8)
        self.port = self._sock.getsockname()[1]
        self.url = f"ws://127.0.0.1:{self.port}"
        self._stop = False
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def _serve(self):
        while not self._stop:
            try:
                conn, _ = self._sock.accept()
            except OSError:
                break
            threading.Thread(target=_handle, args=(conn,), daemon=True).start()

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, *exc):
        self._stop = True
        try:
            self._sock.close()
        except OSError:
            pass


if __name__ == "__main__":
    # Manual smoke: print the URL and serve until Ctrl-C.
    import time
    with WsEchoServer() as s:
        print(s.url, flush=True)
        while True:
            time.sleep(1)
