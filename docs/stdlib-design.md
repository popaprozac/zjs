# zjs — Standard Library Design

> Direction for task #190. Captures the architectural calls; tiers are
> the roadmap, not a strict commit cadence.

## Mission

A **node-flavored, web-API-native** stdlib on top of the engine, sized
for app code (Zapp first), not Node parity. Web globals stay
WHATWG-shaped. Node-ish modules ship under the `node:` namespace.

Two orthogonal axes:

1. **Compliance**: chase **WinterTC Minimum Common API** as the
   conformance milestone — bounded surface, multi-runtime validated,
   already mostly shipped.
2. **Bundle control**: embedders pick what gets linked. Default
   `zjs_new_context()` is "complete engine"; a minimal embed
   opt-out is one API call away.

## Module taxonomy

| Layer | Form | Examples | Status |
|---|---|---|---|
| ES intrinsics | Global, always-on | `Map`, `Set`, `Promise`, `Symbol`, `Proxy`, `Reflect` | shipped |
| Web globals (small) | Global, always-on | `URL`, `URLSearchParams`, `TextEncoder/Decoder`, `console`, `queueMicrotask`, `globalThis`, `btoa`/`atob`, `structuredClone`, `performance.now` | mostly shipped |
| Web globals (heavy) | Global, opt-out at init | `fetch`/`Request`/`Response`/`Headers`, `WebSocket`, `crypto.subtle`, `Blob`/`File`/`FormData`, Streams | partial |
| Node-flavored modules | ESM, `node:` prefix | `node:fs`, `node:path`, `node:os`, `node:process`, `node:net`, `node:http`, `node:child_process`, `node:util`, `node:events`, `node:assert` | none |

**`node:` prefix is mandatory** for node-flavored modules — matches
Node 16+, makes the engine seam explicit, keeps bare `fs` etc. free
for future package-style imports.

**ESM only.** No CommonJS. We already have full ES modules.

## Bundle-control architecture

Three rings, coarsest first:

### Ring 0 — Always linked, always on

ECMA-262 core + URL/Headers + console + queueMicrotask. Language-shaped,
near-zero platform footprint. Not configurable.

### Ring 1 — Linked by default, opt-out at context init

Anything that touches the OS but has no fat dependency chain:
`fs`, `path`, `os`, `process`, `crypto.subtle` (Apple
CommonCrypto / OpenSSL — present anyway), `AbortController`, Streams.

Each module has a registration entry point:

```c
zjs_register_fs(ctx);
zjs_register_path(ctx);
zjs_register_os(ctx);
zjs_register_process(ctx, argc, argv, envp);
zjs_register_crypto_subtle(ctx);
zjs_register_streams(ctx);
```

`zjs_new_context()` calls them all. `zjs_new_minimal_context()` calls
none — the embedder cherry-picks. The registration cost is one
function-pointer write per module: negligible runtime, no #ifdef
matrix.

### Ring 2 — Build-time opt-out

Genuinely-fat dependencies that swell the binary:

| Flag | Removes |
|---|---|
| `-DZJS_NO_NETWORK` | fetch, WebSocket, `node:net`, `node:http`, Apple Foundation / NSURLSession glue, TLS link |
| `-DZJS_NO_CHILD_PROCESS` | `node:child_process`, posix_spawn glue |
| `-DZJS_NO_FS` | `node:fs`, `node:path` (rare; tiny embeds only) |

Build flags are coarse on purpose. Fine-grained selection happens at
Ring 1 via registration.

## WinterTC roadmap

Mapping WinterTC Minimum Common API to current state:

| WinterTC item | Status | Tier |
|---|---|---|
| `URL` / `URLSearchParams` | ✅ shipped | — |
| `fetch` / `Request` / `Response` / `Headers` | ✅ shipped | — |
| `TextEncoder` / `TextDecoder` | ✅ shipped | — |
| `crypto.getRandomValues` | ✅ shipped | — |
| Timers (`setTimeout` etc.) | ✅ shipped | — |
| `WebSocket` | ✅ shipped | — |
| `console` | ✅ shipped | — |
| `globalThis` / `queueMicrotask` | ✅ shipped | — |
| `crypto.randomUUID` | ✅ shipped | — |
| `crypto.subtle.digest` (SHA-1/256/384/512) | ✅ shipped | — |
| `crypto.subtle` HMAC sign/verify | ❌ | Tier 2 follow-up (#252) |
| `AbortController` / `AbortSignal` | ✅ shipped | — |
| `structuredClone` | ✅ shipped | — |
| `btoa` / `atob` | ✅ shipped | — |
| `performance.now` / `performance.timeOrigin` | ✅ shipped | — |
| `EventTarget` / `Event` / `CustomEvent` | ✅ shipped | — |
| `DOMException` | ✅ shipped | — |
| `reportError` | ✅ shipped | — |
| `Blob` / `File` / `FormData` | ✅ shipped | — |
| WHATWG Streams | ✅ shipped | — |

Closing Tiers 2 and 3 = WinterTC-compliant. Conformance suite at
<https://github.com/wintercg/api-test> gives a measurable number to
sit alongside the test262 dashboard.

## Tier 1 — bootstrap minimum ✅ shipped

Shipped in Phase 5.0. All four modules registered via the builtin
module loader; per-module status:

1. **`node:fs` + `node:fs/promises`** ✅ — read/write/readdir/stat/
   lstat/mkdir({recursive})/unlink/rm({recursive,force})/copyFile/
   rename/access + exists. Errors carry `.code`/`.errno`/`.syscall`/
   `.path`. Sync I/O backed by POSIX (Apple/Linux); promise variants
   wrap settled results (real async via thread pool is a follow-up).
2. **`node:path`** ✅ — POSIX `join`/`resolve`/`normalize`/`dirname`/
   `basename`/`extname`/`parse`/`format`/`isAbsolute`/`relative`
   + `sep`/`delimiter`. Pure JS, inlined source.
3. **`node:process`** ✅ — `argv`/`env`/`platform`/`arch`/`pid`/
   `versions`/`cwd`/`chdir`/`exit`/`hrtime`/`nextTick`. Also
   `globalThis.process` (Node convention). Embedders set argv via
   the new `zjs_set_process_argv(ctx, argc, argv)` ABI; the CLI
   wires it for `zjs run/module`.
4. **`node:os`** ✅ — `tmpdir`/`homedir`/`platform`/`arch`/`type`/
   `release`/`hostname`/`cpus`/`totalmem`/`freemem`/`userInfo`/`EOL`.
   Apple via sysctlbyname + mach `host_statistics64`; Linux via
   `<sys/sysinfo.h>` + `/proc/cpuinfo`.

## Tier 2 — WinterTC web globals ✅ shipped (except HMAC)

- ✅ `AbortController` / `AbortSignal` (+ `.timeout`, `.any`, `.abort`,
  `.throwIfAborted`); pre-aborted-signal fast-path in `fetch`
- ✅ `crypto.subtle.digest` (SHA-1/256/384/512 via Apple CommonCrypto /
  Linux OpenSSL / Windows BCrypt); `crypto.randomUUID`
- ❌ `crypto.subtle.sign` / `verify` (HMAC) — follow-up #252
- ✅ `structuredClone` (deep-copy with cycle preservation; throws
  `DataCloneError` on functions/symbols)
- ✅ `EventTarget` / `Event` / `CustomEvent`
- ✅ `DOMException` (with legacy `.code` map)
- ✅ `performance.now` / `performance.timeOrigin`
- ✅ `btoa` / `atob`
- ✅ `reportError`

## Tier 3 — networking, streams, real-app features

- ✅ `Blob`, `File`, `FormData`
- ✅ WHATWG `ReadableStream` / `WritableStream` / `TransformStream`
  (+ `CountQueuingStrategy` / `ByteLengthQueuingStrategy`). Pipe
  + async-iter wired. BYOB and `.tee()` deferred — neither has a
  current consumer.
- ❌ `node:net` (TCP), `node:http` (server)
- ❌ `node:child_process` (spawn)
- ❌ DX: `node:util`, `node:events`, `node:assert`

## Implementation notes

- **Where modules live**: built-in. Registered into the engine context
  during `zjs_new_context()`. JS source for pure-JS modules (`node:path`)
  is inlined as a `static const char*` and compiled to bytecode on
  first import.
- **AOT-friendly**: built-in modules participate in the same module
  resolution path as user code, so the AOT bundle format (already in
  place) covers them.
- **Lazy compile**: pure-JS modules compile on first import, not on
  context init. Native-backed modules register their `Object` shell
  eagerly but populate methods as host functions (already the pattern).
- **`node:` resolver**: small special case in the module loader —
  short-circuit before path resolution, look up the registered
  internal module, return its `Module` record.
- **Permission model**: deferred. Today registration is the only
  capability gate. A Deno-style permission layer can live above
  registration when there's a real need.

## Open questions (decide as we go)

- **Streams flavor**: WHATWG only, or `node:stream` shim on top? Lean
  WHATWG-only initially; add a thin shim if a real consumer needs it.
- **`Buffer`**: alias of `Uint8Array` with extra methods, or skip?
  Skip for now — `Uint8Array` covers the use cases and Node code
  increasingly uses it directly.
- **`fs.watch`**: kqueue/inotify/ReadDirectoryChangesW per platform.
  Defer until Tier 3 since no current consumer needs it.
