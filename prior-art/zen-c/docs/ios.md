# iOS — embedding zjs in an iOS app

zjs ships an `.xcframework` you can drop into Xcode. The framework
bundles `libzjs.a` for two iOS slices — physical device (`arm64`) and
the iOS Simulator (fat `arm64 + x86_64`) — so Xcode picks the right
one automatically based on the build target.

No part of this depends on `zapp`, JavaScriptCore, or any specific
host framework. zjs is a standalone interpreter; anything that can
link a static C library can host it.

## Prerequisites

- macOS with Xcode (or just the Command Line Tools — `xcode-select
  --install`). The Makefile resolves SDK paths via `xcrun`.
- Zen-c (`zc`) on `$PATH` — same toolchain you need for the macOS
  build. See the project README for installation.
- A target iOS version of **15.0 or later**. Older deployment
  targets are deliberately not supported — we use `nanosleep` and
  Grand Central Dispatch idioms that pre-15 SDKs lack.

## Building

```sh
make ios-all
```

Equivalent to `make ios-xcframework`. Output:

```
build/ios/
├── device/libzjs.a                # arm64, iPhoneOS SDK
├── simulator-arm64/libzjs.a       # arm64, iPhoneSimulator SDK
├── simulator-x64/libzjs.a         # x86_64, iPhoneSimulator SDK
├── simulator/libzjs.a             # lipo'd fat of the two simulator arches
└── zjs.xcframework/               # ← what you embed in Xcode
    ├── Info.plist
    ├── ios-arm64/{Headers/, libzjs.a}
    └── ios-arm64_x86_64-simulator/{Headers/, libzjs.a}
```

Granular targets are available if you only need one slice:

```sh
make ios-device              # arm64 device only
make ios-simulator           # fat arm64+x86_64 simulator
make ios-simulator-arm64     # Apple Silicon Mac sim
make ios-simulator-x64       # Intel Mac sim
make ios-xcframework         # all of the above + xcframework bundle
```

The build runs `zc transpile` once per arch (deterministic; safe
to parallelize) and drives `clang` directly with the right
`-arch / -isysroot / -m{iphoneos,ios-simulator}-version-min`
combination. We bypass `zc build`'s `--cc` plumbing on iOS because
long SDK paths (`/Applications/Xcode.app/Contents/Developer/...`)
trip an internal length limit and produce empty output.

## Embedding in an iOS app (Xcode)

1. Drag `build/ios/zjs.xcframework` into your Xcode project. When
   prompted, check **Copy items if needed** and add it to your
   app target.

2. In the target's **General → Frameworks, Libraries, and Embedded
   Content** section, verify `zjs.xcframework` is listed with
   **Do Not Embed** (it's a static library, not a dynamic one).

3. Add `-framework Foundation` to the target's **Other Linker
   Flags** (Build Settings). zjs's fetch and WebSocket backends
   use `NSURLSession`. You also need `-framework CoreFoundation`
   if you don't already have it transitively.

4. Include the C header from anywhere in your code:
   ```c
   #include "zjs.h"
   ```
   Or from Swift:
   ```swift
   import zjs   // Swift import name matches the xcframework
   ```

5. Use the public API:
   ```c
   ZjsContext* ctx = zjs_new_context();
   ZjsValue v = zjs_eval(ctx, "1 + 2");
   // ... inspect v via zjs_is_int32 / zjs_as_int32 etc. ...
   zjs_free_context(ctx);
   ```

   The full public ABI is in `include/zjs.h`. See `tests/embed_smoke.c`
   for a worked example.

## Linker flags (manual / SwiftPM consumers)

If you're not going through Xcode's GUI:

```
-Lbuild/ios/zjs.xcframework/ios-arm64        # device target
-Lbuild/ios/zjs.xcframework/ios-arm64_x86_64-simulator   # simulator target
-lzjs
-framework Foundation
-framework CoreFoundation
```

`Foundation` is required for `fetch` (NSURLSession) and
`WebSocket` (NSURLSessionWebSocketTask). Without it, you'll see
unresolved `_OBJC_CLASS_$_NSURL...` symbols at link time. If your
app doesn't use those APIs from JS, link Foundation anyway — the
symbol references are baked into the static lib and the linker
needs the framework even if the code paths are cold.

`CoreFoundation` is needed for `CFRunLoopRunInMode` (zjs's
async-fetch dispatch — the event-loop pump's Apple path).

## What works on iOS

| Feature | Status |
|---|---|
| Engine (parse, compile, interpret, GC, modules) | ✅ |
| `fetch` (HTTP/HTTPS, sync + async) | ✅ via `NSURLSession` |
| `WebSocket` (`wss://`) | ✅ via `NSURLSessionWebSocketTask` |
| `crypto.subtle.digest` + HMAC | ✅ via CommonCrypto |
| `node:fs`, `node:path`, `node:process`, `node:os` | ✅ POSIX |
| `node:net`, `node:http` (server-side) | ⚠️ Compiles, but iOS sandbox typically denies `bind()` on TCP ports — the API exists, you just won't usually be able to listen. Matches Node-on-iOS expectations. |
| `node:child_process` | ⚠️ Compiles, but the iOS sandbox blocks `fork()` / `execvp()` — calls fail with `EPERM` at runtime. Same shape as Node behaves. |
| `Math.*`, `JSON.*`, `Date.*`, `Map`, `Set`, `Proxy`, `Reflect`, `Symbol`, `Promise`, `async/await`, generators | ✅ |
| Test262 conformance | 85.7% (same as macOS — same engine) |

## What doesn't work

- **JIT** — there is none. zjs is jitless-first by design (iOS
  forbids `mmap(PROT_EXEC)` outside of `JavaScriptCore`'s system
  sandbox), so the interpreter is what you get. Perf is in the
  Hermes/QuickJS class — see `docs/perf/index.html`.
- **`zjs run`** (the CLI) — not built for iOS. iOS apps embed
  `libzjs.a`; there's no shell to run a `.js` file from.

## Troubleshooting

**"iPhoneOS SDK not found"** — `xcrun --sdk iphoneos
--show-sdk-path` returned empty. Install Xcode (the App Store
version, not just CLT) or accept the license: `sudo xcodebuild
-license accept`.

**Linker error: `ld: warning: reducing alignment of section
__DATA,__common`** — harmless. A 32K-aligned static buffer in the
engine gets quietly aligned down to the iOS max of 16K. The
binary still works correctly. (Fix-pending: reduce that buffer's
alignment requirement upstream.)

**Unresolved `_NSURL...` symbols** — you forgot to link Foundation.
Add `-framework Foundation` to your linker flags or check the
Xcode "Link Binary With Libraries" build phase.

**App Store submission** — `zjs.xcframework` is App Store-safe.
The static lib doesn't ship any prohibited APIs (no
`mmap(PROT_EXEC)`, no private framework calls, no dynamic-code
loading). The same warning Apple gives about JIT engines applies
to other engines, not zjs — we're explicitly an interpreter.
