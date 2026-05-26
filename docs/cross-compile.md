# Cross-compile experiment — `zc` native vs `zig cc` (2026-05-18)

Investigation: does swapping `zc`'s default C backend for `zig cc`
buy us anything? Specifically — smaller binaries, faster builds,
and cleaner cross-compile to iOS / Linux / Windows.

Conclusion: **zig cc is a strict drop-in win for size and a usable
cross-compile toolchain for Linux + macOS-x86_64. Windows needs three
small POSIX shims; iOS needs more SDK plumbing than the experiment
covered.** Perf is identical (zig cc *is* clang under the hood).

Zen-c officially supports Zig as a backend at 100% test-suite parity
with GCC/Clang — see [Compiler Support & Compatibility][zenc-compat]
in the upstream README. The compatibility table:

| Compiler | Pass rate | Supported features        |
|----------|:---------:|---------------------------|
| GCC      | 100%      | All                       |
| Clang    | 100%      | All                       |
| Zig      | 100%      | All (uses `zig cc`)       |
| TCC      | 98%       | Most, no Intel ASM        |

[zenc-compat]: https://github.com/zenc-lang/zenc#compiler-support--compatibility

## The mechanic

`zc` accepts `--cc <command>` to swap the C compiler driver. Both
backends accept the same input (Zen-c's transpiled C11), so:

```bash
# Default (system clang + libsystem on macOS)
zc build --release tools/zjs.zc -o build/zjs

# zig cc as the driver, host target — official short form
zc build --release --cc zig tools/zjs.zc -o build/zjs.zigcc

# Cross-compile — the short form doesn't carry through extra flags,
# so use the explicit 'zig cc -target ...' form here.
zc build --release --cc 'zig cc -target aarch64-linux-musl -s' tools/zjs.zc -o build/zjs.linux.arm64
zc build --release --cc 'zig cc -target x86_64-linux-musl  -s' tools/zjs.zc -o build/zjs.linux.x64
zc build --release --cc 'zig cc -target x86_64-macos'         tools/zjs.zc -o build/zjs.macos.x64
```

The `-s` flag is forwarded by zig cc to the linker for symbol-strip,
which trims the static-Linux binary from ~5 MB to ~700 KB.

## Results

| Target                                       | Binary size (release, stripped) | Status |
|----------------------------------------------|--------------------------------:|:------:|
| macOS arm64 (system clang via `zc`)          | 961 KB                          |   ✅   |
| macOS arm64 (`zig cc`)                       | 856 KB (**−11%**)               |   ✅   |
| Linux arm64 (`zig cc -target`, static musl)  | 983 KB (`make cross-linux-arm64`) |   ✅   |
| Linux x86_64 (`zig cc -target`, static musl) | 1039 KB (`make cross-linux-x64`) |   ✅   |
| macOS x86_64 (`zig cc -target`)              | needs Apple SDK plumbing       |   ⚠️   |

**Note (2026-05-18):** Numbers re-measured after Phase D.0 (fetch via
NSURLSession on Apple). Native macOS zig cc still gives the documented
~10% size win.

### Linux cross-compile — `make cross-linux-{arm64,x64}` (resolved 2026-05-26)

Two compounding problems blocked Linux cross-builds; #206 batched
the fixes together:

1. `zc` keys platform directives off the **host** OS, not zig's
   `-target` flag — so on a Mac host, `//> macos: framework:
   Foundation` was always applied, even when targeting Linux. Fix:
   stage the source tree into `build/cross-stage/`, sed-strip
   `//> macos:` / `//> ios:` lines, and rename `//> linux:` →
   `//> macos:` so the host-tagged dispatch picks them up.
2. Once zc was applying the right directives, the linker needed
   `libcurl` and `libwebsockets` (Linux's fetch/WebSocket backends)
   which zig cc's musl sysroot doesn't ship. Fix: also sed-substitute
   `http_linux.c`/`ws_linux.c` with the existing `http_stub.c`/
   `ws_stub.c` so fetch / WebSocket on cross-built binaries cleanly
   return "not configured" — and drop `-lcurl -lwebsockets`.
3. Three smaller portability fixes baked into `portability.h`:
   - `__GLIBC_PREREQ` was tested without first checking `defined()`;
     musl doesn't define the macro and zig's clang front-end refuses
     the empty function-call form. Split into nested `#if`.
   - `<openssl/sha.h>` is now `__has_include`-gated; missing OpenSSL
     turns `zjs_digest_oneshot` / `zjs_hmac_oneshot` into stub returns
     instead of build failures.
   - Renamed a `si_ptr` local in `context.zc` — musl `<signal.h>`
     defines `si_ptr` as a struct-field macro, so name collisions
     happen whenever node:child_process pulls in signal.h at TU scope.

| Windows x86_64 (`zig cc -target *-windows-gnu`) | —                   |  ⚠️ POSIX gaps |
| iOS device arm64                    | —                               |  ⚠️ needs SDK plumbing |
| iOS simulator arm64                 | —                               |  ⚠️ needs SDK plumbing |

## Perf — clang vs zig cc on the host

Best-of-3 wall-clock around `zjs run <bench.js>`, macOS arm64:

| Bench         | clang (ms) | zig cc (ms) | ratio |
|---------------|-----------:|------------:|------:|
| richards      |        169 |         167 | 1.01× |
| splay         |        207 |         208 | 1.00× |
| fib_recursive |        116 |         111 | 1.05× |
| int_loop_big  |         72 |          73 | 0.99× |
| nbody         |         95 |          94 | 1.01× |
| object_alloc  |         15 |          14 | 1.07× |
| mandelbrot    |         51 |          53 | 0.96× |

Within wall-clock noise across the board. Makes sense — `zig cc` is
clang frontend + LLVM backend, same code generator as Apple's system
clang. The size win comes from how `zig cc` links against
musl/system libc rather than from codegen differences.

## Windows gap — three POSIX functions to shim

Building for `x86_64-windows-gnu` produces 7 errors, all from 3
unique POSIX-only symbols mingw doesn't provide:

```
zjs.c:6477: undeclared 'realpath'
zjs.c:26601: undeclared 'gmtime_r'    (3 callers)
zjs.c:26750: undeclared 'timegm'      (3 callers)
```

Windows equivalents are well-known:

- `realpath(path, NULL)` → `_fullpath(NULL, path, 0)` (allocates) or
  `GetFullPathNameA`.
- `gmtime_r(&t, &tm)` → `gmtime_s(&tm, &t)` (note: argument order
  inverted vs the POSIX-named `_r`).
- `timegm(&tm)` → `_mkgmtime(&tm)`.

Two-or-three `raw { #ifdef _WIN32 ... }` guards in `src/context.zc`
around the Date methods + a `tools/zjs.zc` shim for module loading
should close the gap. Out of scope for this experiment.

## iOS — resolved (2026-05-26)

Both prior approaches hit zc's `--cc` plumbing:

1. **`zig cc -target aarch64-ios -isysroot $SDK`** — zig's `aarch64-ios`
   target doesn't pick up the macOS-style `-isysroot`; the include
   path search misses iOS SDK headers and fails at `<stdio.h>`.
2. **xcrun-resolved `clang -arch arm64 -isysroot $SDK -mios-version-min=15`
   passed as `zc build --cc '...'`** — produced 0-byte output. The actual
   cause: when the iOS SDK path runs ~102 characters, zc truncates the
   `--cc` argument at a fixed internal limit; clang reports a sysroot it
   never received (`/Applications/Xcode.app/Contents/De`) and the build
   never reaches the link phase. Even when we worked around the truncation
   (`--cc` pointing to a wrapper script), zc's link step passed `--static`
   to Apple's `ld`, which rejects it (`-static` is the Apple form).

**Working approach (#270, doc: `docs/ios.md`):** skip zc's link plumbing
entirely. Run `zc transpile` once to emit C, then drive `clang` ourselves
for each iOS arch with the right `-arch / -isysroot / -m...version-min`
triple, and pack the resulting `.o` files with `ar rcs`. Same pattern the
macOS `libzjs.a` Makefile target already uses; iOS is just three more
arches (device-arm64, sim-arm64, sim-x64) fed into `lipo` and
`xcodebuild -create-xcframework`.

Targets: `make ios-device`, `ios-simulator`, `ios-xcframework`, `ios-all`.
Output: `build/ios/zjs.xcframework` — drop into Xcode.

## When to switch

The default `Makefile` still uses `clang` via `zc`'s native backend
because:

- On macOS, the 12% size win is real but not enough to motivate a
  toolchain swap for the default dev loop.
- Build time is ~3× slower with `zig cc` (18 s vs 6 s) — zig's
  hermetic-toolchain dance has a fixed startup cost the system
  toolchain avoids.

`zig cc` is the right call when:

- Producing a release for a *non-host* platform (Linux server,
  Linux container, Apple Silicon → Intel mac).
- Distributing static binaries — `zig cc` + musl makes "drop the
  ELF, run anywhere" trivial.
- Cross-checking codegen against a different toolchain.

## How to use it ad-hoc

```bash
# Linux arm64 static, stripped, ~675 KB
zc build --release --cc 'zig cc -target aarch64-linux-musl -s' \
  tools/zjs.zc -o build/zjs.linux.arm64

# Linux x86_64 static, stripped, ~720 KB
zc build --release --cc 'zig cc -target x86_64-linux-musl -s' \
  tools/zjs.zc -o build/zjs.linux.x64

# macOS x86_64 (for arm64 → x86_64 universal binary), ~525 KB
zc build --release --cc 'zig cc -target x86_64-macos' \
  tools/zjs.zc -o build/zjs.macos.x64
```

Same `--cc` mechanic works for `make` invocations by passing
`ZC_FLAGS='-w --release --cc "zig cc -target ..."'` (note the inner
quotes — `--cc`'s argument is one shell word).

## Release plan — dual builds

Once the dust settles on iOS + Windows shims, the intent is to ship
two release flavors per platform:

| Flavor | Toolchain | Audience |
|--------|-----------|----------|
| `zjs-X.Y.Z-<plat>-clang.tar.gz` | System clang / GCC via `zc` | Embedders building locally, matches host libc. |
| `zjs-X.Y.Z-<plat>-zig.tar.gz`   | `zc --cc 'zig cc -target ...'` | Static-musl Linux, portable distribution, smaller macOS binaries. |

The size win (−12% on macOS arm64) and the static-musl Linux story
are individually worth the second flavor; bundled they're a clean
"download-and-run" story for non-host environments. CI is the gating
work — `make cross` doesn't exist yet, and producing the binaries
reliably requires the toolchain matrix.

A small `make cross-zig` target wrapping the four working zig-cc
recipes above is the natural next step. Cosmopolitan / APE
(`cosmocc` toolchain) is a more ambitious alternative — one binary
that runs on macOS + Linux + Windows + BSD across x86_64 + arm64 —
worth a follow-up experiment after the basic dual-release pipeline
is real.
