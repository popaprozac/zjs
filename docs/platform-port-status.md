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
| `node:fs` / `node:fs/promises` | ✅ POSIX (`node_fs.zc`) | ✅ same | ✅ POSIX | ✅ MinGW CRT + small shims | Sync I/O under the hood, promise variants wrap settled results. MinGW-w64 ships unistd/dirent/sys-stat, so most of the POSIX surface compiles as-is; Windows shims: `lstat`→`stat` (isSymbolicLink() always false), `mkdir` drops mode, `rename`→`MoveFileEx(REPLACE_EXISTING)` for POSIX overwrite semantics, `O_BINARY` on every open (text mode would CRLF-mangle bytes), both separators in recursive mkdir. Stat field `st_birthtimespec` is Apple-only — Linux/Windows fall back to `st_ctime`. |
| `node:process` + `globalThis.process` | ✅ POSIX (`node_process.zc`) | ✅ same | ✅ POSIX | ✅ MinGW CRT as-is | argv/env/platform/arch/cwd/chdir/exit/hrtime/nextTick/versions/pid. MinGW supplies getcwd/chdir/environ/clock_gettime — zero Windows-specific code needed. |
| `node:os` | ✅ Apple `<sys/sysctl.h>` + mach `host_statistics64` (`node_os.zc`) | ✅ same | ✅ `<sys/sysinfo.h>` + `/proc/cpuinfo` | ✅ Win32 (`GetTempPathA`/`RtlGetVersion`/`GetComputerNameExA`/`GlobalMemoryStatusEx`/`GetNativeSystemInfo` + registry `CentralProcessor\0`) | tmpdir/homedir/platform/arch/type/release/EOL/cpus/totalmem/freemem/hostname/userInfo. cpus() returns the same model+speed N times — true per-core data deferred. Windows matches Node semantics: uid/gid −1, shell null, type `Windows_NT`, release from RtlGetVersion (true build, not the compat-manifest lie). |
| `crypto.subtle.digest` + HMAC sign/verify | ✅ CommonCrypto (`portability.h::zjs_digest_oneshot` + `zjs_hmac_oneshot`) | ✅ same | ✅ OpenSSL `<openssl/sha.h>` + `<openssl/hmac.h>` | ✅ BCrypt (verified: SHA-256 + RFC 4231 HMAC vectors) | digest returns `Uint8Array` (spec says ArrayBuffer; close enough for now). importKey accepts `'raw'` format only; algorithm.name must be `'HMAC'`. Constant-time verify. |
| `crypto.subtle.encrypt`/`decrypt` (AES-GCM) + `generateKey` + `exportKey('raw')` | ✅ vendored pure-C (`src/third-party/aes-gcm/aes_gcm.c`, ~330 LOC, dispatched via `portability.h::zjs_aes_gcm_oneshot`) | ✅ same | ✅ OpenSSL `EVP_CIPHER` (AES-{128,256}-GCM) | ✅ BCrypt (`BCRYPT_AES_ALGORITHM` + `BCRYPT_CHAIN_MODE_GCM`) | 12-byte IV, 16-byte tag only (spec defaults). Apple SDK doesn't expose `kCCModeGCM`, so we vendor a self-contained table-based AES + GHASH impl instead of using Apple's private SPI. `generateKey` fills via `BCryptGenRandom` / `arc4random_buf` / `/dev/urandom` depending on platform. |
| `node:child_process` (spawnSync / execSync / execFileSync + async wrappers) | ✅ POSIX (`process_posix.c` — `fork`/`execvp`/`poll`/`waitpid`) | ⚠️ compiles but runtime-fails under sandbox (matches Node behavior) | ✅ POSIX | ✅ `CreateProcessA` + anonymous pipes (`process_windows.c`) | Sync trio first. Spawn-and-capture lives behind `process_native.h` (same pattern as http/ws/socket); node_child_process.zc only marshals argv/results. execSync shells via `%COMSPEC% /d /s /c` on Windows, `/bin/sh -c` elsewhere. Cmdline quoting follows the MSVCRT parsing rules. True async `spawn()` with ChildProcess EventEmitter deferred — needs streams pipe + event-loop integration. Errors carry `.code` ('ENOENT', 'EACCES', etc.), `.errno`, `.syscall`. |
| `node:net` + `node:http` (server side) | ✅ POSIX BSD sockets (`socket_posix.c` — `socket`/`bind`/`listen`/`accept`/`poll`/`recv`/`send`) | ✅ same (sockets work in iOS sandbox) | ✅ same POSIX path | ✅ Winsock2 (`socket_windows.c` — `WSAPoll`/`ioctlsocket`/`closesocket`, `SO_EXCLUSIVEADDRUSE`) | Single-threaded `poll()` inside the event-loop tick; events queued and drained per-tick via `ctx_net_pump_all` alongside fetch/WS. Server-side only — `net.connect`, keep-alive, chunked transfer-encoding all deferred. Windows verified end-to-end: http server response fetched over loopback via WinHTTP. |
| Temporal IANA time-zone offset + host tz id (`ZonedDateTime`, `Temporal.Now`) | ✅ `setenv($TZ)`+`tzset`+`localtime_r`→`tm_gmtoff`; host id via `readlink(/etc/localtime)` (`portability.h::zjs_tz_offset_seconds` / `zjs_host_timezone_id`) | ✅ same | ✅ same POSIX path (glibc/musl ship tzdata under `/usr/share/zoneinfo`) | ✅ OS `icu.dll` (Win10 1903+), lazy `LoadLibrary` — no import lib, no bundled tzdata; pre-1903 machines fall back to the UTC stub | DST-correct (verified vs Node: America/New_York EST↔EDT; Windows additionally verified the 2026-03-08 spring-forward gap resolves per Temporal 'compatible'). The transient global-`$TZ` mutation is safe because zjs is single-threaded. Windows host id via `ucal_getDefaultTimeZone`. |
| `crypto.subtle.deriveBits`/`deriveKey` (PBKDF2 + HKDF) | ✅ portable C over `zjs_hmac_oneshot` (`portability.h::zjs_pbkdf2_oneshot` / `zjs_hkdf_oneshot`) | ✅ same | ✅ same (HMAC is OpenSSL underneath) | ✅ BCrypt underneath (verified: RFC 6070 PBKDF2 + RFC 5869 HKDF vectors) | Both KDFs are written in terms of `zjs_hmac_oneshot`, so they inherit whatever HMAC backend the platform has — no extra platform code. PBKDF2 = RFC 2898, HKDF = RFC 5869. |
| `node:zlib` (`*Sync` gzip/deflate/raw + callback async) + `CompressionStream`/`DecompressionStream` | ✅ system `<zlib.h>` (`-lz`) via `portability.h::zjs_zlib_compress`/`zjs_zlib_decompress` | ✅ same (zlib ships in the iOS SDK) | ✅ system `<zlib.h>` (`-lz`) | ✅ MinGW-w64's bundled `libz.a` (`-lz`) | One-shot codec (no streaming zlib state): `windowBits` selects zlib(15)/gzip(15+16)/raw(-15). `CompressionStream` buffers all chunks and (de)compresses on flush — correct for whole-body piping, not true chunked streaming. Guarded by `__has_include(<zlib.h>)` (`ZJS_HAS_ZLIB`). macOS note: zc ignores `link:`/`-l*` on the command's cflags, so `-lz` is passed on the `zc build` line via the `ZC_LINK` make var. |

---

## Linker requirements

| Platform | Required flags | Frameworks/libs pulled in |
|---|---|---|
| macOS / iOS | `-framework Foundation` (set in build directives) | Foundation, CoreFoundation, libobjc, CoreFoundation runloop |
| Linux | `-lpthread -lcurl -lwebsockets` (set in build directives + Makefile) | libcurl (HTTP/HTTPS), libwebsockets (WS), pthread (async wrapper) |
| Windows | `-lbcrypt -lpsapi -lwinhttp -lws2_32 -lz` (set in build directives) | bcrypt.dll (CSPRNG + crypto.subtle), psapi.dll (peak RSS), winhttp.dll (HTTP/WS), ws2_32.dll (node:net), MinGW libz.a (node:zlib); icu.dll loaded at runtime for time zones |

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
| Windows | MinGW-w64 (zc currently doesn't compile under MSVC) | none — `winhttp.dll` / `bcrypt.dll` / `psapi.dll` / `ws2_32.dll` / `icu.dll` ship with the OS; zlib.h + libz.a and all Win32 headers come with MinGW-w64 | install [MSYS2](https://www.msys2.org/) + `pacman -S mingw-w64-x86_64-toolchain` (or the MinGW-Builds toolchain via scoop). Build with `powershell -File scripts\build-windows.ps1` — the Makefile is POSIX-only and fails loud on Windows. |

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

socket_native.h      Public C ABI for node:net/http TCP servers
socket_posix.c       POSIX BSD sockets (Apple + iOS + Linux)
socket_windows.c     Winsock2 (Windows only)

process_native.h     Public C ABI for child_process spawn-and-capture
process_posix.c      fork/execvp/poll/waitpid (Apple + iOS + Linux)
process_windows.c    CreateProcessA + anonymous pipes (Windows only)

portability.h        Cross-platform shims (realpath, gmtime_r, random,
                     peak RSS, zlib one-shots, tz lookups — ICU-backed
                     on Windows via lazy-loaded icu.dll)
```

One exception lives inline in `src/context.zc`: the nursery-chunk
allocator (`zjs_aligned_chunk_alloc/free`, gen-GC #386) needs
size-aligned 64KB blocks — `posix_memalign`/`free` on POSIX,
`_aligned_malloc`/`_aligned_free` on Windows. The `#ifdef _WIN32` is
contained in one raw block next to the ASan poisoning shim.

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

## Windows gap matrix — 2026-06-12

Measured at `windows-port` HEAD: Windows test262 **24520/27629** vs
macOS **24539/27568** (same commit, both 90.1%-class); WinterCG MCA
**103/103 on both**; macOS verification of the branch = 0 curated
regressions. The asymmetric diff (normalized paths): **61 tests fail
ONLY on Windows, 10 only on macOS**. The gaps below are ordered by
recommended attack order.

### Engine / conformance gaps (the 61 Windows-only test262 failures)

| # | Gap | Tests | Signature | Likely cause / fix |
|---|-----|------:|-----------|--------------------|
| 1 | `Error.prototype.stack` accessor not installed | ~32 | `built-ins/Error/prototype/stack/getter-*` — `gOPD(Error.prototype,'stack').get/.set` is undefined | The stack-accessor install is gated behind a POSIX-only backtrace guard that MinGW doesn't satisfy. Install the accessor pair unconditionally (the GETTER can return a minimal string; the tests exercise the *descriptor shape*, not unwind quality). |
| 2 | ±Infinity / NaN in `f64 -> integer` casts | ~15 | `Array.prototype` flat/includes/every/slice/lastIndexOf with `Infinity` args or 2^32-class lengths; `String.prototype` siblings | `(i64)inf` is UB — clang-on-Darwin saturates, MinGW/gcc x64 produces INT64_MIN-flavored garbage. Audit `to_integer_or_infinity` + every raw f64 cast in length/index clamping; add explicit `isinf/isnan` guards BEFORE the cast (portable + spec-correct on all platforms). |
| 3 | Parse errors on Windows only | 7 | `SyntaxError: parse error` on tests that parse fine on macOS | Almost certainly CRLF: git `autocrlf` rewrites on checkout and a lexer path mishandles `\r` (or the test bytes genuinely differ). Fix BOTH: add `vendor/test262/** -text` to `.gitattributes`, and audit the lexer for `\r\n` tolerance (real-world Windows source files will have CRLF regardless). |
| 4 | `Date` "Invalid time value" | 2 | Date/prototype edge values | MSVCRT `localtime`/`mktime` reject years outside 1970–3000-ish ranges the POSIX functions accept. Route extreme-year math through the engine's own proleptic calendar (already present for Temporal) instead of the CRT. |
| 5 | Harness enumeration drift | — | Windows run: 27,629 total / 367 skipped vs 27,568 / 338 | +61 totals and +29 skips means the runner discovers/skips a slightly different file set on NTFS (case sensitivity / symlinked fixtures). Worth one look so the per-platform dashboards count the same denominator. |

### Runtime-layer gaps (Windows-specific behavior)

| Surface | Gap | Severity |
|---------|-----|----------|
| `node:fs` | `lstat` shimmed to `stat` — `isSymbolicLink()` always false; NTFS junctions/symlinks invisible | Low until fs consumers need it; fix = `GetFileAttributesW` + `FILE_ATTRIBUTE_REPARSE_POINT` |
| `node:os` | `cpus()` returns model+speed of core 0 repeated N times | Cosmetic; `GetLogicalProcessorInformationEx` when needed |
| Temporal | Pre-Win10-1903 machines (no `icu.dll`) silently fall back to the UTC stub | Acceptable; documented. Could warn once at startup |
| `child_process` | `execSync` quoting follows MSVCRT rules — programs that parse their own cmdline (notably `cmd.exe` builtins with carets, msys tools) may split differently | Documented; revisit if real scripts hit it |
| Console / TTY | No VT-mode enable on legacy conhost (ANSI colors in REPL/errors); `isatty` semantics differ | Cosmetic; `SetConsoleMode(ENABLE_VIRTUAL_TERMINAL_PROCESSING)` one-liner |

### Build & artifact gaps (Windows lags the macOS release shape)

| Artifact / lever | macOS | Windows | Gap cost |
|------------------|-------|---------|----------|
| Release CLI | `make cli-pgo` (canonical: −21% runtime, −22% size vs plain) | `build-windows.ps1` plain `-O3` only | Windows ships the *slow, large* shape — PGO via MinGW gcc (`-fprofile-generate/use`) is the single biggest Windows perf+size lever; mirrors `pgo` target into the ps1 |
| Embedder artifacts | `libzjs.a` / `libzjs.dylib` / `lib-pgo` + tier flags (`ZJS_TIER`, `ZJS_NO_*`) | none — CLI only | Blocks zapp-on-Windows embedding; ps1 needs `lib-static` mode compiling `libzjs.c` with `ZJS_TIER_DEFINES` |
| Embed smoke (`tests/embed_smoke.c`, 399 asserts) | gates every arc | never run on Windows | Follows from the lib gap; it's the embedder ABI gate |
| JIT (`cli-jit`, opt-in) | builds + 23k-test identical | unported (stencil pipeline assumes clang/Mach-O-or-ELF toolchain) | Fine to defer — jitless-first is the product stance and PGO comes first |
| Toolchain | clang | MinGW-w64 only (zc doesn't emit MSVC-compatible C yet) | Acceptable; document — but it's why #2 above exists (gcc UB differences) |
| `make bench` / cross-engine SNAPSHOT | PGO-canonical, 23/23 vs QuickJS | runner records exist but on plain build, different hardware | Re-baseline only after Windows PGO lands; until then Windows perf numbers aren't comparable to the headline |

### Cross-platform debts surfaced by the port (not Windows-specific)

- `Buffer.prototype.toString()` comma-joins bytes instead of UTF-8
  decoding (`execSync().toString()` is unusable everywhere) — known
  `TAG_UINT8_ARRAY` family, repros identically on macOS main.
- `child_process` async `spawn()` + ChildProcess EventEmitter — deferred
  on every platform (needs stream pipes + event-loop integration).
- `net.connect` (client sockets), keep-alive, chunked transfer-encoding —
  server-side-only on every platform.
- `CompressionStream` buffers whole-body rather than chunked streaming —
  every platform.

**Recommended order:** engine row 2 (UB casts — it's a latent bug on
every gcc target incl. Linux), then row 1 + 3 (cheap, +39 tests), then
Windows PGO + `lib-static` in the ps1 (closes the release-shape gap and
unblocks zapp-on-Windows), then the runtime-layer rows opportunistically.

### Web-API surface — verification depth (added after review)

The "WinterCG 103/103 on both" line above is a SMOKE suite, not
exhaustive coverage. Per-API status:

| Web API | Windows impl | Suite coverage | Gap |
|---------|-------------|----------------|-----|
| AbortController/Signal, Blob/File/FormData, Event/EventTarget/CustomEvent/DOMException, TextEncoder/Decoder(+streams), Streams(+BYOB/tee), structuredClone, performance.*, timers, URL/URLSearchParams | pure JS/engine — same code as macOS | ✅ wintercg areas pass 103/103 both platforms | none known |
| `crypto.subtle` (digest/HMAC/AES-GCM/PBKDF2/HKDF) | BCrypt backend | ✅ wintercg + RFC test vectors | none known |
| `fetch` | WinHTTP async | ⚠️ suite tests SHAPES + `data:` URLs only (by design, no network in CI); live TLS/redirect/streaming verified once via the port's loopback test | thin live-path coverage — applies to every platform, but Windows's WinHTTP state machine is the newest code |
| **WebSocket** | WinHTTP WebSocket (`ws_windows.c`, 740 lines) | ❌ **no wintercg area exists for WebSocket on ANY platform** — the only gate is zapp's `verify-zjs-worker-fetch.sh`, which is macOS-only | the single biggest web-API verification debt; a `websocket` area with a loopback echo server would gate all three backends |
| `navigator.*` | absent everywhere | — | parked (WinterTC navigator-registry, by design) |

### stdlib surface — Windows status per module

| Module | Kind | Windows status |
|--------|------|----------------|
| `node:buffer`, `node:stream`, `node:url`, `node:dx` | pure JS | ✅ platform-neutral by construction |
| **`node:path`** | pure JS | ❌ **POSIX personality hardcoded**: `sep='/'`, `delimiter=':'`, and `path.win32`/`path.posix` namespaces DON'T exist (despite the comment in node_path.zc). On Windows: `delimiter:':'` mangles `PATH` splitting on drive-letter colons; `isAbsolute`/`resolve`/`parse` don't understand `C:\` or UNC paths. **Top stdlib gap** — Node semantics want the win32 personality as default on Windows with both namespaces exported |
| `node:fs`(+promises) | platform-backed | ✅ ported (CRT+shims); symlink visibility gap noted above |
| `node:os` | platform-backed | ✅ ported (Win32); cpus() detail gap noted above |
| `node:process` | platform-backed | ✅ MinGW CRT as-is |
| `node:child_process` | platform-backed | ✅ sync trio (`CreateProcessA`); async `spawn()` deferred everywhere |
| `node:net` / `node:http` | platform-backed | ✅ server-side (Winsock2); client `connect`, keep-alive, chunked TE deferred everywhere |
| `node:zlib` + Compression/DecompressionStream | platform-backed | ✅ MinGW libz; whole-body (non-chunked) everywhere |
| `node:tty` | platform-backed | ✅ `isatty` only (v0.1 surface everywhere); Windows VT-mode note above |
