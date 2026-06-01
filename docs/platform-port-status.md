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
| `fetch` (async — Promise.all parallelism) | ✅ NSURLSession completion handlers | ✅ same | ⚠️ pthread-wraps sync via `http_async.c` | ✅ WinHTTP-native (`WINHTTP_FLAG_ASYNC` + status callback in `http_windows.c`) | Apple + Windows skip the extra thread; Linux still does thread-per-request. |
| `WebSocket` | ✅ `NSURLSessionWebSocketTask` (`ws_apple.m`) | ✅ same | ✅ libwebsockets (`ws_linux.c`) | ✅ WinHTTP WebSocket (`ws_windows.c`) | All three platforms native |
| WebSocket keep-alive (ping/pong) | ✅ `dispatch_source` ping every 25s | ✅ same | ⚠️ deferred — lws's default is no client ping | ✅ `WINHTTP_OPTION_WEB_SOCKET_KEEPALIVE_INTERVAL` (25s) | Pong-error → CLOSE 1006 |
| Cross-platform shims (realpath / gmtime_r / random / RSS) | ✅ POSIX | ✅ POSIX | ✅ POSIX | ✅ Win32 (`portability.h`: `_fullpath` / `gmtime_s` / `BCryptGenRandom` / `GetProcessMemoryInfo`) | Single header, no platform code outside the `#ifdef` |
| Event-loop wait | ✅ `CFRunLoopRunInMode` (required for fetch async) | ✅ same | _n/a_ (`nanosleep`) | _n/a_ (`nanosleep`) | Apple-only because NSURLSession's completion needs the runloop |
| iOS cross-compile (libzjs.a + xcframework) | ✅ `make ios-all` (Makefile drives `clang -arch arm64 -isysroot $IOS_SDK -m{iphoneos,ios-simulator}-version-min=15.0`) | ✅ same toolchain, three slices: device-arm64, sim-arm64, sim-x64 | _n/a_ | _n/a_ | Output: `build/ios/zjs.xcframework` for drop-in Xcode use. Doc: `docs/ios.md` |
| zig cc cross-compile to non-Apple | ✅ native macOS (~11% smaller stripped vs system clang) | _n/a_ | ✅ via `make cross-linux-arm64` / `cross-linux-x64` — static-musl, fetch/WS stubbed | ❌ POSIX-shim gaps (realpath/gmtime_r/timegm) | `make cross-stage_with_target` sed-renames `//> linux:` directives to `//> macos:` so zc (host-tagged) applies them; swaps http_linux/ws_linux for stubs (drops -lcurl/-lwebsockets). Apple SDK headers are not bundled, so crypto.subtle + fetch live behind `__has_include(<openssl/sha.h>)` guards on the cross builds (stubbed when missing). |
| `node:fs` / `node:fs/promises` | ✅ POSIX (`node_fs.zc`) | ✅ same | ✅ POSIX | ❌ not yet — needs `<windows.h>` / `_open` / `FindFirstFile` variants | Sync I/O under the hood, promise variants wrap settled results. POSIX-only today: `open`/`read`/`write`/`stat`/`lstat`/`opendir`/`readdir`/`mkdir`/`unlink`/`rename`/`access`. Stat field `st_birthtimespec` is Apple-only — Linux falls back to `st_ctime`. |
| `node:process` + `globalThis.process` | ✅ POSIX (`node_process.zc`) | ✅ same | ✅ POSIX | ❌ needs `_getcwd` / `_chdir` / `GetEnvironmentStringsW` / `QueryPerformanceCounter` | argv/env/platform/arch/cwd/chdir/exit/hrtime/nextTick/versions/pid. `extern char** environ` works on all POSIX targets but Windows needs `_environ` or `GetEnvironmentStrings`. |
| `node:os` | ✅ Apple `<sys/sysctl.h>` + mach `host_statistics64` (`node_os.zc`) | ✅ same | ✅ `<sys/sysinfo.h>` + `/proc/cpuinfo` | ❌ needs `GetSystemInfo` / `GlobalMemoryStatusEx` / `GetComputerNameExA` | tmpdir/homedir/platform/arch/type/release/EOL/cpus/totalmem/freemem/hostname/userInfo. cpus() returns the same model+speed N times — true per-core data deferred. |
| `crypto.subtle.digest` + HMAC sign/verify | ✅ CommonCrypto (`portability.h::zjs_digest_oneshot` + `zjs_hmac_oneshot`) | ✅ same | ✅ OpenSSL `<openssl/sha.h>` + `<openssl/hmac.h>` | ⚠️ BCrypt wired but unbuilt | digest returns `Uint8Array` (spec says ArrayBuffer; close enough for now). importKey accepts `'raw'` format only; algorithm.name must be `'HMAC'`. Constant-time verify. |
| `crypto.subtle.encrypt`/`decrypt` (AES-GCM) + `generateKey` + `exportKey('raw')` | ✅ vendored pure-C (`src/third-party/aes-gcm/aes_gcm.c`, ~330 LOC, dispatched via `portability.h::zjs_aes_gcm_oneshot`) | ✅ same | ✅ OpenSSL `EVP_CIPHER` (AES-{128,256}-GCM) | ✅ BCrypt (`BCRYPT_AES_ALGORITHM` + `BCRYPT_CHAIN_MODE_GCM`) | 12-byte IV, 16-byte tag only (spec defaults). Apple SDK doesn't expose `kCCModeGCM`, so we vendor a self-contained table-based AES + GHASH impl instead of using Apple's private SPI. `generateKey` fills via `BCryptGenRandom` / `arc4random_buf` / `/dev/urandom` depending on platform. |
| `node:child_process` (spawnSync / execSync / execFileSync + async wrappers) | ✅ POSIX (`node_child_process.zc` — `fork`/`execvp`/`poll`/`waitpid`) | ⚠️ compiles but runtime-fails under sandbox (matches Node behavior) | ✅ POSIX | ❌ needs `CreateProcess` + anonymous pipes + `WaitForSingleObject` shim | Sync trio first. True async `spawn()` with ChildProcess EventEmitter deferred — needs streams pipe + event-loop integration. Errors carry `.code` ('ENOENT', 'EACCES', etc.), `.errno`, `.syscall`. |
| `node:net` + `node:http` (server side) | ✅ POSIX BSD sockets (`socket_posix.c` — `socket`/`bind`/`listen`/`accept`/`poll`/`recv`/`send`) | ✅ same (sockets work in iOS sandbox) | ✅ same POSIX path | ❌ needs Winsock2 shim (`WSAStartup`/`WSAPoll`/closesocket) | Single-threaded `poll()` inside the event-loop tick; events queued and drained per-tick via `ctx_net_pump_all` alongside fetch/WS. Server-side only — `net.connect`, keep-alive, chunked transfer-encoding all deferred. |
| Temporal IANA time-zone offset + host tz id (`ZonedDateTime`, `Temporal.Now`) | ✅ `setenv($TZ)`+`tzset`+`localtime_r`→`tm_gmtoff`; host id via `readlink(/etc/localtime)` (`portability.h::zjs_tz_offset_seconds` / `zjs_host_timezone_id`) | ✅ same | ✅ same POSIX path (glibc/musl ship tzdata under `/usr/share/zoneinfo`) | ⚠️ stubbed to UTC — IANA names aren't valid `$TZ` on Windows; needs ICU (`ucal_getOffset`) or bundled tzdata | DST-correct (verified vs Node: America/New_York EST↔EDT). The transient global-`$TZ` mutation is safe because zjs is single-threaded. `zjs_host_timezone_id` resolves the `/etc/localtime` symlink's `zoneinfo/` suffix. |
| `crypto.subtle.deriveBits`/`deriveKey` (PBKDF2 + HKDF) | ✅ portable C over `zjs_hmac_oneshot` (`portability.h::zjs_pbkdf2_oneshot` / `zjs_hkdf_oneshot`) | ✅ same | ✅ same (HMAC is OpenSSL underneath) | ⚠️ same status as HMAC (BCrypt wired but unbuilt) | Both KDFs are written in terms of `zjs_hmac_oneshot`, so they inherit whatever HMAC backend the platform has — no extra platform code. PBKDF2 = RFC 2898, HKDF = RFC 5869. |
| `node:zlib` (`*Sync` gzip/deflate/raw + callback async) + `CompressionStream`/`DecompressionStream` | ✅ system `<zlib.h>` (`-lz`) via `portability.h::zjs_zlib_compress`/`zjs_zlib_decompress` | ✅ same (zlib ships in the iOS SDK) | ✅ system `<zlib.h>` (`-lz`) | ❌ stubbed — returns -1; needs zlib via vcpkg or the Compression API | One-shot codec (no streaming zlib state): `windowBits` selects zlib(15)/gzip(15+16)/raw(-15). `CompressionStream` buffers all chunks and (de)compresses on flush — correct for whole-body piping, not true chunked streaming. Guarded by `#if !defined(_WIN32) && __has_include(<zlib.h>)` (`ZJS_HAS_ZLIB`). macOS note: zc ignores `link:`/`-l*` on the command's cflags, so `-lz` is passed on the `zc build` line via the `ZC_LINK` make var. |

---

## Linker requirements

| Platform | Required flags | Frameworks/libs pulled in |
|---|---|---|
| macOS / iOS | `-framework Foundation` (set in build directives) | Foundation, CoreFoundation, libobjc, CoreFoundation runloop |
| Linux | `-lpthread -lcurl -lwebsockets` (set in build directives + Makefile) | libcurl (HTTP/HTTPS), libwebsockets (WS), pthread (async wrapper) |
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
http_windows.c       WinHTTP sync + native async (Windows only)
http_linux.c         libcurl sync (Linux only — async via http_async.c thread-wrap)
http_stub.c          "Not configured" returns (compiled into no live build now)
http_async.c         pthread-wrap of sync → async ABI; compiled on Linux only
                     (Apple and Windows have their own native async paths)

ws_native.h          Public C ABI for WebSocket
ws_apple.m           NSURLSessionWebSocketTask (Apple only)
ws_linux.c           libwebsockets client (Linux only)
ws_windows.c         WinHTTP WebSocket API (Windows only)
ws_stub.c            "Not configured" returns (no live build uses it now)

portability.h        Cross-platform shims (realpath, gmtime_r, random, peak RSS)
```

The engine code (`src/context.zc` etc.) only ever calls the `*_native.h`
entry points + the `zjs_*` shims from `portability.h` — never touches a
platform-specific header directly.

---

## Known divergences worth tracking

- **Async fetch parallelism**: Apple uses NSURLSession's native completion
  handlers; Windows uses WinHTTP's `WINHTTP_FLAG_ASYNC` + status-callback
  state machine — both leverage the OS's I/O completion pool, no extra
  threads per request. Linux still uses one pthread per in-flight
  request via `http_async.c`. Functionally equivalent; resource profile
  differs at high concurrency.
- **HTTPS / TLS**: Apple gets system trust store + HTTP/2 + proxy
  detection from NSURLSession. Windows gets the same from WinHTTP.
  Linux gets the same from libcurl (whatever TLS backend the distro
  built it against — OpenSSL on most, GnuTLS on a few).
- **WebSocket close codes**: Apple surfaces the exact close code from
  the server (NSURLSessionWebSocketTask delivers it via the delegate).
  Linux captures peer-initiated closes via
  `LWS_CALLBACK_WS_PEER_INITIATED_CLOSE`, but for client-initiated
  closes lws 4.5 doesn't expose the echoed code back to us — so a
  successful client-side `ws.close(1000)` surfaces as `1005`
  ("no status received") in the JS event. Acceptable for v0.1.
- **Test262 conformance**: tracked per-platform via `history-<platform>.jsonl`
  and `index-<platform>.html` under `docs/conformance/`.
- **Bench numbers**: same — `docs/perf/history.jsonl` is macOS;
  `history-windows.jsonl` is Windows. Different hardware so comparisons
  across columns aren't meaningful; only same-platform-over-time is.
