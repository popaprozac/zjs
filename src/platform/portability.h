// Cross-platform shims for non-portable C library calls. Each entry
// is an inline wrapper around either the POSIX function (used on
// macOS / iOS / Linux) or the Windows equivalent. Keeps the engine
// proper free of `#ifdef _WIN32` clutter at call sites.
//
// Convention: shim names are `zjs_*` mirroring the POSIX shape.
// Windows linkage requirements are recorded as build-directive
// comments at the top of files that import this header (see
// src/lib.zc + tools/zjs.zc).

#ifndef ZJS_PLATFORM_PORTABILITY_H
#define ZJS_PLATFORM_PORTABILITY_H

#include <stdint.h>
#include <stddef.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#  include <windows.h>
#  include <bcrypt.h>
#  include <psapi.h>
#  ifndef PATH_MAX
#    define PATH_MAX _MAX_PATH
#  endif
#else
#  include <sys/resource.h>
#  include <limits.h>
   // arc4random_buf landed in glibc 2.36 (Aug 2022). On older Linux
   // (Ubuntu 20.04 / 22.04 LTS, RHEL ≤ 8) and on non-glibc libcs (musl)
   // it's missing, which becomes an undefined-reference at link time.
   // Fall back to getrandom(2) — Linux 3.17+, glibc 2.25+, also in
   // musl ≥ 1.1.20.
#  if defined(__linux__)
#    include <features.h>
#    if !defined(__GLIBC_PREREQ) || !__GLIBC_PREREQ(2, 36)
#      include <sys/random.h>
#      include <errno.h>
#      define ZJS_USE_GETRANDOM 1
#    endif
#  endif
#endif

// realpath(path, resolved) — canonicalize a filesystem path.
// `resolved` must point to a buffer of at least PATH_MAX bytes.
// Returns `resolved` on success, NULL on failure (sets errno).
static inline char* zjs_realpath(const char* path, char* resolved) {
#ifdef _WIN32
    return _fullpath(resolved, path, _MAX_PATH);
#else
    return realpath(path, resolved);
#endif
}

// gmtime_r-style: decompose seconds-since-epoch into a `struct tm`
// in UTC. Returns the `out` pointer on success, NULL on failure.
// MSVC's gmtime_s has a different signature; this wraps both.
static inline struct tm* zjs_gmtime_r(const time_t* t, struct tm* out) {
#ifdef _WIN32
    if (gmtime_s(out, t) == 0) return out;
    return NULL;
#else
    return gmtime_r(t, out);
#endif
}

// timegm — inverse of gmtime, assuming UTC. Windows has _mkgmtime.
static inline time_t zjs_timegm(struct tm* t) {
#ifdef _WIN32
    return _mkgmtime(t);
#else
    return timegm(t);
#endif
}

// Cryptographically secure random bytes. On Apple/BSD we use
// arc4random_buf (no error path); on Windows BCryptGenRandom; we
// abort on Windows-side failure rather than partially-filling the
// caller's buffer (matches arc4random_buf's "always succeeds"
// contract).
static inline void zjs_random_bytes(void* buf, size_t len) {
#ifdef _WIN32
    NTSTATUS s = BCryptGenRandom(NULL, (PUCHAR)buf, (ULONG)len,
                                  BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    if (s != 0) {
        // BCryptGenRandom failure on a healthy machine is unrecoverable.
        // Zero the buffer rather than leaving it uninitialized.
        memset(buf, 0, len);
    }
#elif defined(ZJS_USE_GETRANDOM)
    // getrandom can short-read on EINTR — loop until the request is
    // fully satisfied or a non-recoverable error occurs.
    size_t off = 0;
    while (off < len) {
        ssize_t n = getrandom((char*)buf + off, len - off, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            memset(buf, 0, len);
            return;
        }
        off += (size_t)n;
    }
#else
    arc4random_buf(buf, len);
#endif
}

// One-shot message digest. Writes `digest_len` bytes into `out`.
//   algo: 1=SHA-1 (20), 256, 384, 512
// Returns 0 on success, -1 on unknown algorithm or backend failure.
// Apple: CommonCrypto. Linux: OpenSSL (libcrypto, already linked via
// libcurl). Windows: BCrypt.
#if defined(__APPLE__)
#  include <CommonCrypto/CommonDigest.h>
#elif defined(_WIN32)
#  include <bcrypt.h>
#else
#  include <openssl/sha.h>
#endif

static inline int zjs_digest_oneshot(int algo, const void* data, size_t len,
                                     unsigned char* out, size_t* out_len) {
#if defined(__APPLE__)
    switch (algo) {
        case 1:
            CC_SHA1((const unsigned char*)data, (CC_LONG)len, out);
            *out_len = CC_SHA1_DIGEST_LENGTH;
            return 0;
        case 256:
            CC_SHA256((const unsigned char*)data, (CC_LONG)len, out);
            *out_len = CC_SHA256_DIGEST_LENGTH;
            return 0;
        case 384:
            CC_SHA384((const unsigned char*)data, (CC_LONG)len, out);
            *out_len = CC_SHA384_DIGEST_LENGTH;
            return 0;
        case 512:
            CC_SHA512((const unsigned char*)data, (CC_LONG)len, out);
            *out_len = CC_SHA512_DIGEST_LENGTH;
            return 0;
        default:
            return -1;
    }
#elif defined(_WIN32)
    const wchar_t* alg = NULL;
    switch (algo) {
        case 1:   alg = BCRYPT_SHA1_ALGORITHM; break;
        case 256: alg = BCRYPT_SHA256_ALGORITHM; break;
        case 384: alg = BCRYPT_SHA384_ALGORITHM; break;
        case 512: alg = BCRYPT_SHA512_ALGORITHM; break;
        default: return -1;
    }
    BCRYPT_ALG_HANDLE h = NULL;
    if (BCryptOpenAlgorithmProvider(&h, alg, NULL, 0) != 0) return -1;
    DWORD dlen = 0, cb = 0;
    BCryptGetProperty(h, BCRYPT_HASH_LENGTH, (PUCHAR)&dlen, sizeof(dlen), &cb, 0);
    if (BCryptHash(h, NULL, 0, (PUCHAR)data, (ULONG)len, out, dlen) != 0) {
        BCryptCloseAlgorithmProvider(h, 0);
        return -1;
    }
    BCryptCloseAlgorithmProvider(h, 0);
    *out_len = (size_t)dlen;
    return 0;
#else
    switch (algo) {
        case 1:   SHA1((const unsigned char*)data, len, out);   *out_len = SHA_DIGEST_LENGTH;    return 0;
        case 256: SHA256((const unsigned char*)data, len, out); *out_len = SHA256_DIGEST_LENGTH; return 0;
        case 384: SHA384((const unsigned char*)data, len, out); *out_len = SHA384_DIGEST_LENGTH; return 0;
        case 512: SHA512((const unsigned char*)data, len, out); *out_len = SHA512_DIGEST_LENGTH; return 0;
        default:  return -1;
    }
#endif
}

// Peak resident set size in bytes since process start. Used by
// `--gc-stats` to report a memory-usage upper bound. Returns 0 if
// the platform query fails.
static inline uint64_t zjs_peak_rss_bytes(void) {
#ifdef _WIN32
    PROCESS_MEMORY_COUNTERS pmc;
    if (GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc))) {
        return (uint64_t)pmc.PeakWorkingSetSize;
    }
    return 0;
#else
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) != 0) return 0;
#  ifdef __APPLE__
    // macOS: ru_maxrss is bytes.
    return (uint64_t)ru.ru_maxrss;
#  else
    // Linux + BSDs: ru_maxrss is kilobytes.
    return (uint64_t)ru.ru_maxrss * 1024ULL;
#  endif
#endif
}

#endif
