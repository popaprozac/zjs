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
   // (Ubuntu 20.04 / 22.04 LTS, RHEL ≤ 8) and on non-glibc libcs (musl,
   // which is what zig cc's `-target *-linux-musl` ships) it's missing
   // — becomes an undefined-reference at link time. Fall back to
   // getrandom(2): Linux 3.17+, glibc 2.25+, musl ≥ 1.1.20.
   //
   // The nested form is deliberate: the preprocessor evaluates BOTH
   // sides of `||` before short-circuiting, so `!__GLIBC_PREREQ(2, 36)`
   // on a libc that doesn't define the macro still tokenizes — and
   // zig cc's preprocessor (clang front-end) rejects the empty-macro
   // function-call form. Splitting into a defined() gate and a nested
   // version-check keeps the second clause out of the token stream
   // when GLIBC_PREREQ isn't a thing.
#  if defined(__linux__)
#    include <features.h>
#    if defined(__GLIBC_PREREQ)
#      if !__GLIBC_PREREQ(2, 36)
#        define ZJS_USE_GETRANDOM 1
#      endif
#    else
#      define ZJS_USE_GETRANDOM 1   /* musl / uClibc / etc. */
#    endif
#    if defined(ZJS_USE_GETRANDOM)
#      include <sys/random.h>
#      include <errno.h>
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
#elif defined(__has_include) && __has_include(<openssl/sha.h>)
#  include <openssl/sha.h>
#  define ZJS_HAS_OPENSSL_SHA 1
#else
   // No crypto backend available (zig cc cross to musl without an
   // OpenSSL sysroot, etc.). crypto.subtle.digest will return -1 and
   // surface as a TypeError from the JS API; embedders that need it
   // ship a -lcrypto sysroot or use a host-clang build.
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
#elif defined(ZJS_HAS_OPENSSL_SHA)
    switch (algo) {
        case 1:   SHA1((const unsigned char*)data, len, out);   *out_len = SHA_DIGEST_LENGTH;    return 0;
        case 256: SHA256((const unsigned char*)data, len, out); *out_len = SHA256_DIGEST_LENGTH; return 0;
        case 384: SHA384((const unsigned char*)data, len, out); *out_len = SHA384_DIGEST_LENGTH; return 0;
        case 512: SHA512((const unsigned char*)data, len, out); *out_len = SHA512_DIGEST_LENGTH; return 0;
        default:  return -1;
    }
#else
    (void)algo; (void)data; (void)len; (void)out; (void)out_len;
    return -1;
#endif
}

// One-shot HMAC. Same algo codes as zjs_digest_oneshot (1, 256, 384,
// 512). Writes the MAC bytes to `out`, sets `*out_len` to the digest
// size. Returns 0 on success, -1 on unsupported algorithm.
#if defined(__APPLE__)
#  include <CommonCrypto/CommonHMAC.h>
#elif !defined(_WIN32) && defined(__has_include) && __has_include(<openssl/hmac.h>)
#  include <openssl/hmac.h>
#  define ZJS_HAS_OPENSSL_HMAC 1
#endif

static inline int zjs_hmac_oneshot(int algo,
                                   const void* key, size_t key_len,
                                   const void* data, size_t data_len,
                                   unsigned char* out, size_t* out_len) {
#if defined(__APPLE__)
    CCHmacAlgorithm cc_algo;
    switch (algo) {
        case 1:   cc_algo = kCCHmacAlgSHA1;   *out_len = CC_SHA1_DIGEST_LENGTH;   break;
        case 256: cc_algo = kCCHmacAlgSHA256; *out_len = CC_SHA256_DIGEST_LENGTH; break;
        case 384: cc_algo = kCCHmacAlgSHA384; *out_len = CC_SHA384_DIGEST_LENGTH; break;
        case 512: cc_algo = kCCHmacAlgSHA512; *out_len = CC_SHA512_DIGEST_LENGTH; break;
        default:  return -1;
    }
    CCHmac(cc_algo, key, key_len, data, data_len, out);
    return 0;
#elif defined(_WIN32)
    const wchar_t* alg = NULL;
    switch (algo) {
        case 1:   alg = BCRYPT_SHA1_ALGORITHM;   break;
        case 256: alg = BCRYPT_SHA256_ALGORITHM; break;
        case 384: alg = BCRYPT_SHA384_ALGORITHM; break;
        case 512: alg = BCRYPT_SHA512_ALGORITHM; break;
        default:  return -1;
    }
    BCRYPT_ALG_HANDLE h = NULL;
    if (BCryptOpenAlgorithmProvider(&h, alg, NULL,
                                    BCRYPT_ALG_HANDLE_HMAC_FLAG) != 0) return -1;
    DWORD dlen = 0, cb = 0;
    BCryptGetProperty(h, BCRYPT_HASH_LENGTH, (PUCHAR)&dlen, sizeof(dlen), &cb, 0);
    BCRYPT_HASH_HANDLE hh = NULL;
    if (BCryptCreateHash(h, &hh, NULL, 0, (PUCHAR)key, (ULONG)key_len, 0) != 0) {
        BCryptCloseAlgorithmProvider(h, 0);
        return -1;
    }
    BCryptHashData(hh, (PUCHAR)data, (ULONG)data_len, 0);
    BCryptFinishHash(hh, out, dlen, 0);
    BCryptDestroyHash(hh);
    BCryptCloseAlgorithmProvider(h, 0);
    *out_len = (size_t)dlen;
    return 0;
#elif defined(ZJS_HAS_OPENSSL_HMAC)
    const EVP_MD* md = NULL;
    switch (algo) {
        case 1:   md = EVP_sha1();   break;
        case 256: md = EVP_sha256(); break;
        case 384: md = EVP_sha384(); break;
        case 512: md = EVP_sha512(); break;
        default:  return -1;
    }
    unsigned int olen = 0;
    if (!HMAC(md, key, (int)key_len, (const unsigned char*)data, data_len, out, &olen)) {
        return -1;
    }
    *out_len = (size_t)olen;
    return 0;
#else
    (void)algo; (void)key; (void)key_len; (void)data; (void)data_len;
    (void)out; (void)out_len;
    return -1;
#endif
}

// ---------------------------------------------------------------------
// AES-GCM one-shot. Backend-specific implementation gated by whichever
// crypto library is actually reachable from the C compile environment:
//
//   - Linux:   OpenSSL EVP_aes_*_gcm (libcrypto)
//   - Windows: BCrypt with BCRYPT_CHAIN_MODE_GCM
//   - Apple:   NOT YET WIRED. Apple's public SDK does NOT expose
//              `kCCModeGCM` or `kCCParameterAuthTag` through
//              <CommonCrypto/CommonCryptor.h>; CryptoKit is Swift-only.
//              The path forward is a vendored constant-time pure-C
//              AES-GCM impl (BearSSL aes_ct + ghash_ctmul64 shape) that
//              works on iOS without a system-framework dependency.
//              Tracked as a follow-up. Until then this returns -1 on
//              Apple and the JS layer surfaces it as OperationError.
// ---------------------------------------------------------------------
static inline int zjs_aes_gcm_oneshot(int encrypt,
                                      const void* key, size_t key_len,
                                      const void* iv,  size_t iv_len,
                                      const void* aad, size_t aad_len,
                                      const void* in,  size_t in_len,
                                      void* out,
                                      unsigned char tag[16]) {
    if (iv_len != 12) return -1;
    if (key_len != 16 && key_len != 24 && key_len != 32) return -1;

#if defined(_WIN32)
    BCRYPT_ALG_HANDLE alg = NULL;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_AES_ALGORITHM, NULL, 0) != 0)
        return -1;
    if (BCryptSetProperty(alg, BCRYPT_CHAINING_MODE,
                          (PUCHAR)BCRYPT_CHAIN_MODE_GCM,
                          sizeof(BCRYPT_CHAIN_MODE_GCM), 0) != 0) {
        BCryptCloseAlgorithmProvider(alg, 0); return -1;
    }
    BCRYPT_KEY_HANDLE bk = NULL;
    if (BCryptGenerateSymmetricKey(alg, &bk, NULL, 0,
                                   (PUCHAR)key, (ULONG)key_len, 0) != 0) {
        BCryptCloseAlgorithmProvider(alg, 0); return -1;
    }
    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
    BCRYPT_INIT_AUTH_MODE_INFO(info);
    info.pbNonce = (PUCHAR)iv; info.cbNonce = (ULONG)iv_len;
    info.pbAuthData = (PUCHAR)aad; info.cbAuthData = (ULONG)aad_len;
    info.pbTag = (PUCHAR)tag; info.cbTag = 16;
    ULONG written = 0;
    NTSTATUS rc;
    if (encrypt) {
        rc = BCryptEncrypt(bk, (PUCHAR)in, (ULONG)in_len, &info,
                           NULL, 0, (PUCHAR)out, (ULONG)in_len, &written, 0);
    } else {
        rc = BCryptDecrypt(bk, (PUCHAR)in, (ULONG)in_len, &info,
                           NULL, 0, (PUCHAR)out, (ULONG)in_len, &written, 0);
    }
    BCryptDestroyKey(bk);
    BCryptCloseAlgorithmProvider(alg, 0);
    return rc == 0 ? 0 : -1;

#elif !defined(__APPLE__) && defined(__has_include) && __has_include(<openssl/evp.h>)
#  include <openssl/evp.h>
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return -1;
    const EVP_CIPHER* cip = (key_len == 16) ? EVP_aes_128_gcm()
                          : (key_len == 24) ? EVP_aes_192_gcm()
                                            : EVP_aes_256_gcm();
    int rc = -1, ilen = 0, flen = 0;
    if (EVP_CipherInit_ex(ctx, cip, NULL, NULL, NULL, encrypt) != 1) goto done;
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, (int)iv_len, NULL) != 1) goto done;
    if (EVP_CipherInit_ex(ctx, NULL, NULL, (const unsigned char*)key,
                          (const unsigned char*)iv, encrypt) != 1) goto done;
    if (aad_len > 0) {
        if (EVP_CipherUpdate(ctx, NULL, &ilen,
                             (const unsigned char*)aad, (int)aad_len) != 1) goto done;
    }
    if (in_len > 0) {
        if (EVP_CipherUpdate(ctx, (unsigned char*)out, &ilen,
                             (const unsigned char*)in, (int)in_len) != 1) goto done;
    }
    if (!encrypt) {
        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, tag) != 1) goto done;
    }
    if (EVP_CipherFinal_ex(ctx, (unsigned char*)out + ilen, &flen) != 1) goto done;
    if (encrypt) {
        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, tag) != 1) goto done;
    }
    rc = 0;
done:
    EVP_CIPHER_CTX_free(ctx);
    return rc;

#else
    (void)encrypt; (void)key; (void)key_len; (void)iv; (void)iv_len;
    (void)aad; (void)aad_len; (void)in; (void)in_len; (void)out; (void)tag;
    return -1;
#endif
}

// Random bytes. Backend for generateKey (and the digest path's IV
// generation in future). Returns 0 on success, -1 if the platform
// RNG isn't reachable.
//
// Apple: forward-declare SecRandomCopyBytes so we skip pulling in
// <Security/SecRandom.h> — that header transitively drags MacTypes
// which collides with our zen-c emitted struct names. The symbol
// lives in Security.framework which is already linked.
#if defined(__APPLE__)
extern int SecRandomCopyBytes(void* rnd, size_t count, void* bytes);
#endif

static inline int zjs_random_bytes_oneshot(void* out, size_t len) {
#if defined(__APPLE__)
    return SecRandomCopyBytes((void*)0, len, out) == 0 ? 0 : -1;
#elif defined(_WIN32)
    return BCryptGenRandom(NULL, (PUCHAR)out, (ULONG)len,
                           BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0 ? 0 : -1;
#else
    FILE* f = fopen("/dev/urandom", "rb");
    if (!f) return -1;
    size_t got = fread(out, 1, len, f);
    fclose(f);
    return got == len ? 0 : -1;
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
