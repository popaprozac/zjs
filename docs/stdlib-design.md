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
| `crypto.randomUUID` | 🟡 partial | Tier 2 |
| `crypto.subtle` (digest, HMAC sign/verify) | ❌ | Tier 2 |
| `AbortController` / `AbortSignal` | ❌ | Tier 2 |
| `structuredClone` | ❌ | Tier 2 |
| `btoa` / `atob` | ❌ | Tier 2 |
| `performance.now` / `performance.timeOrigin` | ❌ | Tier 2 |
| `EventTarget` / `Event` / `CustomEvent` | ❌ | Tier 2 |
| `DOMException` | ❌ | Tier 2 |
| `reportError` | ❌ | Tier 2 |
| `Blob` / `File` / `FormData` | ❌ | Tier 3 |
| WHATWG Streams | ❌ | Tier 3 |

Closing Tiers 2 and 3 = WinterTC-compliant. Conformance suite at
<https://github.com/wintercg/api-test> gives a measurable number to
sit alongside the test262 dashboard.

## Tier 1 — bootstrap minimum (next)

Goal: make zjs runnable as an app-script host. Order of work:

1. **`node:fs/promises`** + small sync subset
   - Promise-first surface: `readFile`, `writeFile`, `readdir`,
     `stat`, `mkdir` (`{recursive}`), `unlink`, `rm` (`{recursive,force}`),
     `copyFile`, `rename`, `access`
   - Sync subset for startup: `readFileSync`, `writeFileSync`,
     `existsSync`, `statSync`
   - Defer: streams, watch, file handles. Streams land with Tier 3.
   - Apple-native first (`NSFileManager` / posix). Linux/Windows shims
     in the platform-port-status loop.

2. **`node:path`** — pure JS, inline source. `posix` + `win32` flavors,
   default = host. `join`, `resolve`, `normalize`, `dirname`,
   `basename`, `extname`, `parse`/`format`, `isAbsolute`, `relative`,
   `sep`, `delimiter`.

3. **`node:process`** — promote/unify what's already global:
   `argv`, `env`, `cwd()`, `chdir()`, `exit(code)`, `platform`,
   `arch`, `versions`, `pid`, `hrtime`, `nextTick(cb)` (microtask).

4. **`node:os`** — `tmpdir()`, `homedir()`, `platform()`, `arch()`,
   `type()`, `release()`, `EOL`, `cpus()`, `totalmem()`, `freemem()`,
   `userInfo()`, `hostname()`.

## Tier 2 — finish WinterTC

In rough order of leverage:

- `AbortController` / `AbortSignal` — cascades into fetch/timers/streams
- `crypto.subtle.digest` (sha-1/256/384/512), `crypto.randomUUID`
- `crypto.subtle.sign` / `verify` (HMAC)
- `structuredClone` (deep-copy primitive)
- `EventTarget` / `Event` / `CustomEvent`
- `DOMException`
- `performance.now` / `performance.timeOrigin`
- `btoa` / `atob`
- `reportError`

## Tier 3 — networking, streams, real-app features

- WHATWG `ReadableStream` / `WritableStream` / `TransformStream`
- `Blob`, `File`, `FormData`
- `node:net` (TCP), `node:http` (server)
- `node:child_process` (spawn)
- DX: `node:util`, `node:events`, `node:assert`

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
