# Linux port — gaps and path forward

Hand-off doc for the Linux platform pass. The macOS and Windows tracks
are both in good shape; Linux is currently the laggard — it builds
and runs the language core, but every OS-native feature (`fetch`,
`WebSocket`) falls back to a stub. This is a punch list for closing
that gap, written from a host that's already done the Windows pass.

`docs/platform-port-status.md` is the *current state* matrix. **This
doc is the *roadmap*** — what to do, in what order, with file
locations, library choices, and test commands. Read both.

## What's already in place (don't re-do)

All of the cross-cutting plumbing is done. The Linux track inherits:

- **Cross-platform shims** in `src/platform/portability.h`:
  `zjs_realpath` / `zjs_gmtime_r` / `zjs_timegm` / `zjs_random_bytes`
  / `zjs_peak_rss_bytes`. The Linux branches are wired up — except
  one landmine, [see below](#csprng-on-older-glibc).
- **Native HTTP ABI** in `src/platform/http_native.h`:
  `zjs_http_request_sync` + the async trio (`_start`/`_poll`/`_destroy`).
- **Native WebSocket ABI** in `src/platform/ws_native.h`: `zjs_ws_connect`
  + `_send_text` / `_send_binary` / `_close` / `_poll` / `_destroy`.
- **Async wrapper** in `src/platform/http_async.c`: pthread-per-request
  wrapper around `zjs_http_request_sync`. Linux compiles this; macOS
  has its own NSURLSession-native async impl; Windows has its own
  WinHTTP-native async impl (callback state machine in `http_windows.c`).
  Once libcurl is wired in, Linux can either keep the pthread wrap or
  switch to libcurl's multi-handle (analogous to the Windows callback
  approach) — see item 1 for the trade-off.
- **Engine-side glue**: `host_fetch` in `src/context.zc` (around line
  9080) drives the async ABI, polls per tick, settles the JS Promise.
  Nothing platform-aware in there — once `http_linux.c` exists and
  is linked, `fetch()` from JS works.
- **JS-side fetch surface**: `Headers` (get/set/has/append/delete +
  forEach/keys/values/entries/@@iterator), `Response` (status / ok /
  statusText / url / headers / text / arrayBuffer / json). Comes
  from the recent Windows runtime-gaps branch — no Linux work needed
  to consume it.

## Items to implement

### 1. `fetch` HTTP/HTTPS backend → libcurl

**Why first**: every other web-API features (WebSocket, future
EventSource, future fs/net) all sit on top of an HTTP-capable host.
And it unblocks the whole test surface that exercises `fetch`.

**Current state**: `src/platform/http_stub.c` returns `"fetch: HTTP
backend not configured on this platform"` on every call. The async
wrapper still spins up a pthread and calls it — so every fetch
rejects with that string after one thread spawn.

**What to build**: `src/platform/http_linux.c` implementing
`zjs_http_request_sync` + `zjs_http_response_free` against libcurl's
easy interface. Use `http_apple.m` and `http_windows.c` as
references — same response shape (`int status`, `char* body` +
`size_t body_len`, flat `char** resp_headers` of `[name, value, ...]`),
same error contract (`-1` + malloc'd `err_out` string).

Sketch:

```c
// curl_easy_init → curl_easy_setopt for URL / method / body / headers
// CURLOPT_WRITEFUNCTION → writes to a growable buffer (amortized
//   doubling; mirror http_windows.c's pattern).
// CURLOPT_HEADERFUNCTION → per-header callback; split on first `:`
//   into the flat [name, value, ...] array.
// curl_easy_perform → blocks until done.
// curl_easy_getinfo(CURLINFO_RESPONSE_CODE, ...) → status.
// On non-CURLE_OK, *err_out = strdup(curl_easy_strerror(code)).
```

**Build wiring** (apply to **every** `.zc` entry point — directives
don't propagate across imports):

- `src/lib.zc:22` — `//> linux: cflags: src/platform/http_linux.c …`
  (replace `http_stub.c` with `http_linux.c`).
- `tools/zjs.zc`, `tests/{lexer,parser,interpreter}_test.zc` — same swap.
- `src/lib.zc:30`-ish — add a `//> linux: link: -lcurl` line (mirrors
  the Windows `-lbcrypt -lpsapi -lwinhttp` line two lines below).

**TLS / certs**: libcurl picks up the system CA bundle on
Debian/Ubuntu (`/etc/ssl/certs/ca-certificates.crt`) automatically.
Verify with `curl https://api.github.com/zen` from the shell first.

**Test**:

```bash
./build/zjs eval "fetch('https://api.github.com/zen').then(r => r.text()).then(t => console.log(t))"
./build/zjs eval "Promise.all([fetch('https://api.github.com/zen'), fetch('https://api.github.com/zen')]).then(rs => Promise.all(rs.map(r => r.text()))).then(console.log)"
./build/zjs eval "fetch('https://httpbin.org/post',{method:'POST',body:'hi'}).then(r=>r.json()).then(j=>console.log(j.data))"
```

### 2. `WebSocket` backend → libwebsockets

**Current state**: `src/platform/ws_stub.c` — `zjs_ws_connect` returns
`NULL`; everything else returns `-1` / `ZJS_WS_EVT_NONE`. JS-land
gets a `WebSocket` object that immediately errors.

**What to build**: `src/platform/ws_linux.c` against libwebsockets.
Two design references exist now:

- `ws_apple.m` — NSURLSessionWebSocketTask, callback-driven event
  queue, `dispatch_source` ping every 25s
- `ws_windows.c` — WinHTTP WebSocket API, dedicated worker thread
  runs the receive loop, `WINHTTP_OPTION_WEB_SOCKET_KEEPALIVE_INTERVAL`
  handles ping/pong automatically

Both feed a per-handle, mutex-protected event queue that the engine
drains via `zjs_ws_poll` per tick. The Windows impl is the closer
analog for a libwebsockets-backed Linux impl since libwebsockets
also expects a service loop on a worker thread (`lws_service`).
Key points to mirror:

- Per-handle event queue (linked list, mutex-protected) — required
  by the async *poll-from-main-thread* shape `ws_native.h` defines.
- Worker thread runs the receive/service loop; each WS message
  enqueues a `ZjsWsEvent`.
- Client-initiated ping every 25s + CLOSE 1006 if the pong errors.
  libwebsockets has `LWS_CALLBACK_CLIENT_RECEIVE_PONG` and supports
  per-connection ping interval via `lws_set_timer_usecs`.
- Fragmented frames: accumulate into a growable buffer and emit one
  MESSAGE_TEXT / MESSAGE_BIN event per complete WS message.

**Library choice**: libwebsockets is the workhorse but heavyweight
(~250 KB statically linked). Alternative: hand-rolled framing on
top of an OpenSSL TLS pipe. Recommend libwebsockets — same trade-off
as picking WinHTTP over a hand-rolled WS impl on Windows.

**Test**:

```bash
./build/zjs eval "let ws = new WebSocket('wss://echo.websocket.org'); ws.onopen = () => ws.send('hi'); ws.onmessage = m => { console.log('got:', m.data); ws.close(); }; ws.onclose = e => console.log('closed', e.code)"
```

### 3. Bench + test262 runners — Linux output paths

**Current state**: both runners detect Windows (`sys.platform == 'win32'`)
and route to `-windows` suffixed files. They treat anything else as
macOS, including Linux — which would **pollute the macOS history**
the moment a Linux run lands.

**Files**: `scripts/bench/run.py:39-43`, `scripts/test262/run.py:54-58`.

**Fix**: extend the platform detection so Linux gets its own suffix.
Pattern:

```python
if sys.platform.startswith("linux"):
    PLATFORM_TAG = "linux"
elif sys.platform == "win32":
    PLATFORM_TAG = "windows"
else:
    PLATFORM_TAG = None    # macOS keeps original filenames
ZJS_BIN = REPO_ROOT / "build" / "zjs"
```

And the per-run platform label (`"platform": "Linux" if sys.platform.startswith("linux") else ...`)
in the JSON output, plus the HTML title badge.

Generated files become:
- `docs/perf/{history,last,index}-linux.{jsonl,json,html}`
- `docs/conformance/{history,last,index}-linux.{jsonl,json,html}`

Add README pointers (`README.md:44` and `:46`) next to the Windows
ones already there.

### 4. CSPRNG on older glibc

`portability.h:79` calls `arc4random_buf` on every non-Windows
platform. Glibc gained that symbol in **2.36 (Aug 2022)**. On
Ubuntu 20.04 / 22.04 LTS, RHEL ≤ 8, anything older — it's not
there. Build fails with an undefined-reference at link time.

**Two options**:
1. Link `-lbsd` and `#include <bsd/stdlib.h>` for `arc4random_buf`.
   Requires `apt install libbsd-dev` on Debian/Ubuntu.
2. Add a third arm to the `#ifdef`: prefer `arc4random_buf` if
   available (probe via `__GLIBC_PREREQ(2, 36)`), else fall through
   to `getrandom(2)` from `<sys/random.h>` (Linux 3.17+, glibc 2.25+).

Recommend **option 2** — no new system dependency, no apt requirement
documented in the README.

### 5. Validate the build directives

`src/lib.zc:22-23`, `tools/zjs.zc`, and the three `tests/*_test.zc`
files each carry their own per-platform `//> linux: …` block. zc
parses directives **per file** — they do not propagate across
imports. After editing `src/lib.zc`, grep:

```bash
grep -rn '//> linux' src tools tests
```

and update every match. Windows hit this same trap (commit
`e829b15 feat(fetch): WinHTTP backend`).

### 6. Add a Makefile path for Windows + run `make` on Linux

The current `Makefile` already has a non-Apple else-branch (line
26-30) that lists `http_stub.c http_async.c ws_stub.c`. After
landing items 1+2, swap those for `http_linux.c http_async.c ws_linux.c`
and append `-lcurl -lwebsockets` to `PLATFORM_LDFLAGS`. The
`build/zjs` binary builds via plain `make` (not `zc build` —
that's a Windows-only path because we don't have a `make` on the
default MinGW install).

## Known landmines from the Windows port

Recorded because Linux *might* hit a different form of these:

- **Python default text encoding**: Windows defaults to cp1252.
  Linux defaults to UTF-8 — you should be fine, but if you ever see
  a `UnicodeEncodeError` from a Python ≥ 3.7 runner, double-check
  any `open()`/`write_text()` call has `encoding="utf-8"`. The
  test262 + bench runners already do.
- **zc parser circular-import false positive**: on Windows, two
  `import "string.h"` statements (in `src/context.zc` + `tools/zjs.zc`)
  triggered a false circular-import error because mingw doesn't
  canonicalize header paths. macOS dodges this; Linux's gcc
  *probably* does too via the same canonicalization, but if you see
  `circular import` on something that clearly isn't circular, that's
  the bug. Worked around in commit `fb8e774` by removing a duplicate
  import — left as a hint for upstream zc.
- **`platform/portability.h` include resolution**: zc generates a
  `build/zjs.c` and invokes gcc from the project root with
  `-Itools`. So `#include "platform/portability.h"` in
  `src/context.zc` would fail (Linux gcc resolves quoted includes
  relative to the generated file's dir, not the source). Use
  `#include "../src/platform/portability.h"` — see `tools/zjs.zc:29`
  for the working form.

## Sanity checkpoints

After each item, run:

```bash
./build/zjs eval "1 + 1"              # core engine
./build/zjs eval "fetch('https://api.github.com/zen').then(r=>r.text()).then(console.log)"   # item 1
./build/zjs eval "let ws=new WebSocket('wss://echo.websocket.org'); ws.onmessage=m=>console.log(m.data); ws.onopen=()=>ws.send('ping')"   # item 2
make test                              # in-tree assertions (should be ~941)
make test262                           # full conformance run; lands in -linux file
```

The conformance pass rate should track macOS/Windows closely — any
big delta points to a platform-specific bug in the new backend (most
commonly: HTTP body decoding, UTF-8 round-trip on stderr, or pthread
ordering).

## Recent runtime work to be aware of

The Windows runtime-gaps branch (this branch, `feat/windows-runtime-gaps`,
which lands shortly after this doc) adds:

- `Response.prototype.json()` → parses body through `host_json_parse`,
  rejects the returned Promise with `SyntaxError` on malformed JSON.
- `Headers.prototype.forEach` / `keys` / `values` / `entries` +
  `@@iterator` defaulting to `entries`.
- WinHTTP-native async fetch (replaces `http_async.c` on Windows).
- WinHTTP-native WebSocket (`ws_windows.c`).

The first two are platform-agnostic — they live in `src/context.zc`
and run unchanged on Linux. The last two are Windows-only but the
design patterns transfer directly to libcurl + libwebsockets on
Linux (see items 1 + 2).
