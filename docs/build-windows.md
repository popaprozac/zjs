# Building zjs on Windows

The `Makefile` is POSIX-only (it branches on `uname`, uses symlinks,
and assumes a POSIX shell), so on Windows the build goes through
`scripts/build-windows.ps1` instead. It produces the same artifacts:
the `zjs.exe` CLI and the `libzjs.a` static archive for embedding.

> macOS / Linux contributors: use the `Makefile` (`make cli`,
> `make lib-static`, `make test`). This page is Windows-only.

## Prerequisites

| Tool | Why | Install |
|---|---|---|
| **MinGW-w64** (gcc + ar) | zc's C backend; the C ABI consumer compiler. zc does **not** emit MSVC-compatible C yet, so MSVC/clang-cl are not supported. | [MSYS2](https://www.msys2.org/) → `pacman -S mingw-w64-x86_64-toolchain`, or the MinGW-Builds toolchain via scoop (`scoop install mingw`). |
| **Zen-c** (`zc`) | Transpiles the `.zc` engine to C. Not in any distro repo. | Install from the upstream Zen-c release; put `zc.exe` on `PATH`. |
| **Python 3** | Embeds the JS stdlib (`tools/embed_js.py`) and drives the test/bench runners. | python.org or scoop. |

No external libraries are needed — every native dependency ships with
Windows (`bcrypt.dll`, `psapi.dll`, `winhttp.dll`, `ws2_32.dll`,
`icu.dll`) or with MinGW-w64 (`zlib.h` + `libz.a`, all Win32 headers).

`zc` finds its `std/` either from `$ZC_ROOT` or from the directory
holding `zc.exe`. The build script auto-derives it; set `ZC_ROOT`
yourself only if `zc` lives apart from its `std/`.

## Build the CLI

```powershell
powershell -File scripts\build-windows.ps1
```

Output: `build\zjs.exe`. Add `-DebugBuild` for an `-O0 -g` build.

The script (a) creates a `std` junction to `$ZC_ROOT\std` — zc resolves
`std/` against the current directory, so this is the Windows
equivalent of the Makefile's `ln -sfn`; (b) embeds `src\stdlib\*.js`
into `*.gen.h` headers; (c) runs `zc build` on `tools\zjs.zc`. The
Windows platform sources and link libraries come from the
`//> windows:` build directives inside `tools\zjs.zc` and `src\lib.zc`.

```powershell
build\zjs.exe eval "1 + 2"
build\zjs.exe run path\to\script.js
build\zjs.exe module path\to\module.mjs
```

## Build the static library (embedding)

```powershell
powershell -File scripts\build-windows.ps1 -Lib
```

Output: `build\libzjs.a` (~3.25 MB). The `-Lib` mode mirrors `make
lib-static` + `make smoke-static`: it `zc transpile`s the engine to one
C translation unit, compiles it together with the four Windows platform
units (`http_windows`, `ws_windows`, `socket_windows`,
`process_windows`) plus the vendored qjs-regex and aes-gcm sources,
archives them with `ar`, then **links and runs `tests\embed_smoke.c`
against the archive** — the 399-assert C ABI gate. A successful run
prints `[smoke] 399 passed, 0 failed`.

### Linking a host program against `libzjs.a`

The public C ABI is in `include\zjs.h` (see `tests\embed_smoke.c` for a
worked example):

```c
#include "zjs.h"
ZjsContext* ctx = zjs_new_context();
ZjsValue v = zjs_eval(ctx, "1 + 2");
/* inspect via zjs_is_int32 / zjs_as_int32 ... */
zjs_free_context(ctx);
```

Link line:

```
gcc -static -Iinclude your_host.c build/libzjs.a -lm \
    -lbcrypt -lpsapi -lwinhttp -lws2_32 -lz -o your_host.exe
```

- **`-static` is required** (or ship `libwinpthread-1.dll` /
  `libgcc_s_seh-1.dll` next to the exe): `http_windows.c`'s async fetch
  path uses MinGW's pthreads, so a dynamically-linked consumer fails to
  start with a missing-DLL error. The `zjs.exe` CLI is statically
  linked by zc and has no such dependency.
- The five `-l` libraries map to: `bcrypt` (CSPRNG + `crypto.subtle`),
  `psapi` (peak RSS), `winhttp` (`fetch` / WebSocket), `ws2_32`
  (`node:net`), `z` (`node:zlib`). `icu.dll` (Temporal time zones) is
  loaded at runtime, not linked.

## Running the test suites

```powershell
# test262 (clone the suite once to vendor\test262)
git clone --depth 1 https://github.com/tc39/test262.git vendor\test262
python3 scripts\test262\run.py            # full suite; writes docs\conformance\*-windows*
python3 scripts\test262\run.py --filter Array\prototype   # subset

# WinterCG Minimum Common API
python3 scripts\wintercg\run.py           # writes docs\wintercg\*-windows*

# Benchmarks (add --compare for a cross-engine table if qjs/node/etc. are on PATH)
python3 scripts\bench\run.py
```

All three runners platform-tag their output (`-windows` suffix) so the
Windows streams don't collide with the macOS/Linux dashboards.

## Troubleshooting

**`missing terminating " character` across every `*.gen.h`** — a CRLF
checkout leaked `\r` bytes into the embedded C string literals.
`tools/embed_js.py` normalizes CRLF→LF, so this is fixed; if you see it,
your `*.gen.h` are stale — delete `src\stdlib\*.gen.h` and rebuild.

**`fatal error: sys/utsname.h` (or `sys/wait.h`, `poll.h`)** — you're
building an out-of-date tree; these POSIX-only includes were replaced
with platform shims. Pull latest.

**The CLI exits 127 with no output when run from a host program** — see
the `-static` note above; the consumer is missing `libwinpthread-1.dll`.

**`make` errors with "POSIX-only"** — that's intentional. Use
`scripts\build-windows.ps1`.

## What's not yet wired on Windows

- **PGO** — the CLI is a plain `-O3` build. The macOS PGO path
  (`make cli-pgo`, ~−21% runtime) hasn't been ported to the MinGW
  `-fprofile-generate`/`-fprofile-use` flow yet.
- **JIT** — the opt-in copy-and-patch JIT's stencil pipeline assumes
  clang + Mach-O/ELF; Windows runs the (default) interpreter only.
