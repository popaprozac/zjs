# Platform port status

Running ledger of features that have platform-specific implementations.
Lets you batch up Windows/Linux porting work after a stretch of
macOS development instead of bouncing between machines per commit.

**Reading this:**
- ✅ Native implementation, behaves as expected.
- ⚠️ Stub or fallback — compiles + runs but doesn't do the real thing
  (returns "not configured" error, or silently no-ops).
- ❌ Doesn't compile or hard-fails at runtime.
- _n/a_ — platform doesn't need this piece.

**Updating this:**
- When a macOS-only commit lands, add (or update) a row here.
- When a non-Apple impl lands, flip its cell to ✅.
- Pure-portable C code (most of the engine) doesn't need a row.

---

## Feature matrix

| Feature | macOS | iOS | Linux | Windows | Notes |
|---|---|---|---|---|---|
| `fetch` (sync HTTP/HTTPS) | ✅ NSURLSession (`http_apple.m`) | ✅ same | ✅ libcurl (`http_linux.c`) | ✅ WinHTTP (`http_windows.c`) | All three use the OS-native trust store |
| `fetch` (async — Promise.all parallelism) | ✅ NSURLSession completion handlers | ✅ same | ⚠️ pthread-wraps sync via `http_async.c` | ⚠️ pthread-wraps sync via `http_async.c` | Apple skips the extra thread. Linux/Windows work but use a thread per in-flight request. |
| `WebSocket` | ✅ `NSURLSessionWebSocketTask` (`ws_apple.m`) | ✅ same | ❌ stub (`ws_stub.c`) | ❌ stub (`ws_stub.c`) | #205 — libwebsockets / WinHTTP_WebSocket planned |
| WebSocket keep-alive (ping/pong) | ✅ `dispatch_source` ping every 25s | ✅ same | ⚠️ deferred until Linux WS lands | ⚠️ deferred until Windows WS lands | Pong-error → CLOSE 1006 |
| Cross-platform shims (realpath / gmtime_r / random / RSS) | ✅ POSIX | ✅ POSIX | ✅ POSIX | ✅ Win32 (`portability.h`: `_fullpath` / `gmtime_s` / `BCryptGenRandom` / `GetProcessMemoryInfo`) | Single header, no platform code outside the `#ifdef` |
| Event-loop wait | ✅ `CFRunLoopRunInMode` (required for fetch async) | ✅ same | _n/a_ (`nanosleep`) | _n/a_ (`nanosleep`) | Apple-only because NSURLSession's completion needs the runloop |
| iOS cross-compile | ✅ via zapp's xcrun pattern | — | _n/a_ | _n/a_ | Re-verify when iOS target is exercised |
| zig cc cross-compile to non-Apple | ✅ native macOS | _n/a_ | ❌ broken (#206) | ❌ broken (#206) | `//> macos: framework: Foundation` directive leaks into target when zig cc cross-compiles from a Mac host |

---

## Linker requirements

| Platform | Required flags | Frameworks/libs pulled in |
|---|---|---|
| macOS / iOS | `-framework Foundation` (set in build directives) | Foundation, CoreFoundation, libobjc, CoreFoundation runloop |
| Linux | `-lpthread -lcurl` (set in build directives + Makefile) | libcurl (HTTP/HTTPS), pthread (async wrapper) |
| Windows | `-lbcrypt -lpsapi -lwinhttp` (set in build directives) | bcrypt.dll (CSPRNG), psapi.dll (peak RSS), winhttp.dll (HTTP) |

---

## Build prerequisites

These are the dev packages a contributor needs installed *before*
`make` will succeed. Roll into the README's build section when one
exists.

| Platform | Toolchain | Native libs (dev headers) | Install one-liner |
|---|---|---|---|
| macOS | Xcode CLT (or `clang` + `make` via Homebrew) | none — Foundation ships with the OS | `xcode-select --install` |
| Linux (Fedora / RHEL) | `gcc` + `make` (group `c-development`) | `libcurl-devel`, `libwebsockets-devel` *(once WS lands)* | `sudo dnf install -y gcc make libcurl-devel libwebsockets-devel` |
| Linux (Debian / Ubuntu) | `build-essential` | `libcurl4-openssl-dev`, `libwebsockets-dev` *(once WS lands)* | `sudo apt install -y build-essential libcurl4-openssl-dev libwebsockets-dev` |
| Linux (Arch) | `base-devel` | `curl`, `libwebsockets` *(once WS lands)* | `sudo pacman -S base-devel curl libwebsockets` |
| Linux (Alpine) | `build-base` | `curl-dev`, `libwebsockets-dev` *(once WS lands)* | `apk add build-base curl-dev libwebsockets-dev` |
| Windows | MinGW-w64 (zc currently doesn't compile under MSVC) | none — `winhttp.dll` / `bcrypt.dll` / `psapi.dll` ship with the OS, headers come with MinGW-w64 | install [MSYS2](https://www.msys2.org/) + `pacman -S mingw-w64-x86_64-toolchain` |

**All platforms also need** Zen-c (`zc`) on `$PATH`. That's not in any
distro repo — install it from the upstream zenc release before
running `make`.

---

## File map

Per-platform implementations live under `src/platform/`:

```
http_native.h        Public C ABI — same signatures on all platforms
http_apple.m         NSURLSession sync + native async (Apple only)
http_windows.c       WinHTTP sync (Windows only — async via http_async.c thread-wrap)
http_linux.c         libcurl sync (Linux only — async via http_async.c thread-wrap)
http_stub.c          "Not configured" returns (compiled into no live build now)
http_async.c         pthread-wrap of sync → async ABI; compiled on Linux + Windows only

ws_native.h          Public C ABI for WebSocket
ws_apple.m           NSURLSessionWebSocketTask (Apple only)
ws_stub.c            "Not configured" returns (Linux + Windows until native lands)

portability.h        Cross-platform shims (realpath, gmtime_r, random, peak RSS)
```

The engine code (`src/context.zc` etc.) only ever calls the `*_native.h`
entry points + the `zjs_*` shims from `portability.h` — never touches a
platform-specific header directly.

---

## Known divergences worth tracking

- **Async fetch parallelism**: Apple uses NSURLSession's native completion
  handlers (one thread total managed by the OS). Linux/Windows currently
  use one pthread per in-flight request via `http_async.c`. Functionally
  equivalent; resource profile differs at high concurrency.
- **HTTPS / TLS**: Apple gets system trust store + HTTP/2 + proxy
  detection from NSURLSession. Windows gets the same from WinHTTP.
  Linux gets the same from libcurl (whatever TLS backend the distro
  built it against — OpenSSL on most, GnuTLS on a few).
- **Test262 conformance**: tracked per-platform via `history-<platform>.jsonl`
  and `index-<platform>.html` under `docs/conformance/`.
- **Bench numbers**: same — `docs/perf/history.jsonl` is macOS;
  `history-windows.jsonl` is Windows. Different hardware so comparisons
  across columns aren't meaningful; only same-platform-over-time is.
