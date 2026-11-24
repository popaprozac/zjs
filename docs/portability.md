# Portability

The engine is the C the Z compiler emits, the regular-expression backend
(QuickJS's `libregexp` and `libunicode`, in `engine/native/quickjs/`), and
a little C written by hand (`engine/native/`, `shim/`). `build.sh` and
every gate run on macOS arm64; no script here builds or tests another
platform.

## What the C needs

- The C standard library.
- POSIX threads: a mutex, a once, and a thread key in `shim/zjs_shim.c`
  and `engine/native/zjs_host.c`, for the shim's initialization and the
  host calls running on each thread ([`lifecycle.md`](lifecycle.md)).
- POSIX time, in `engine/builtins/clock.h` (Date, and the collector's
  clock): `gettimeofday`, `clock_gettime` with `CLOCK_MONOTONIC`, and
  `localtime_r` with `tm_gmtoff` and `tm_zone`.
- 64-bit pointers: a context handle packs a slot and a generation into
  64 bits, and the shim asserts it at compile time.

The emitted C defines `_POSIX_C_SOURCE` itself on every platform but
Apple's and Windows.

The engine generates no code at run time and maps no writable executable
memory, so it runs where a JIT may not, iOS apps among them. Nothing needs
the main thread: the shim asserts at compile time that the library root
asks for no main-thread or release hook, so the first call may come from
any thread.

## By platform

| Platform | What differs |
|---|---|
| macOS, iOS | The native stack's bounds come from the thread (`pthread_get_stackaddr_np`, `pthread_get_stacksize_np` in `engine/native/zjs_host.c`). |
| Linux and other POSIX | No stack bounds are read: the engine takes a stack to be 256 kB below where it first looks ([`call-depth.md`](call-depth.md)), so a thread with less can overflow before the RangeError is thrown. |
| Windows | No POSIX threads or time: the shim, `zjs_host.c`, and `clock.h` need Windows versions. |
| 32-bit targets, wasm32 | The shim's 64-bit assert fails. |

## Locale

Text to number goes through the C library's `strtod`, which follows the
host's `LC_NUMERIC`: an embedder that sets a comma-decimal locale gets
wrong numeric literals, `Number()`, `parseFloat`, and `JSON.parse`. Number
to text does not depend on the locale: the shortest digits are computed in
Z (Ryu, `engine/number_text.zs`), and `toFixed`, `toExponential`, and
`toPrecision` take only the digits and the exponent from the C library's
exact formatting.
