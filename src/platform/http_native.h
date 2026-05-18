// Pluggable native HTTP backend for `fetch`.
//
// One symbol — `zjs_http_get_sync` — that each platform implements
// against its OS-native networking stack. Keeps the engine free of
// TLS plumbing (CA bundles, ciphersuite policy, version pinning) and
// gives us HTTPS / HTTP/2 / proxy / IPv6 / cert validation for free
// on platforms where the OS already provides them.
//
//   Apple   — NSURLSession (Foundation.framework) — see http_apple.m
//   Linux   — TBD (libcurl planned) — see http_stub.c at v0.1
//   Windows — TBD (WinHTTP planned) — see http_stub.c at v0.1

#ifndef ZJS_HTTP_NATIVE_H
#define ZJS_HTTP_NATIVE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Synchronous GET. Blocks the calling thread until the request
// completes or fails.
//
// Returns 0 on transport success (any status code — caller must
// inspect *status_out to know whether the server returned 2xx).
// Returns -1 on transport failure (connection refused, DNS error,
// TLS handshake failure, etc.); *err_out is filled with a malloc'd
// UTF-8 string that the caller must free().
//
// On transport success:
//   *status_out   = HTTP status code (e.g. 200, 404)
//   *body_out     = malloc'd response body. Caller frees with free().
//                   May be NULL when body_len_out == 0.
//   *body_len_out = body length in bytes (NOT including a null
//                   terminator — the body is binary-safe).
int zjs_http_get_sync(const char* url,
                      int* status_out,
                      char** body_out,
                      size_t* body_len_out,
                      char** err_out);

#ifdef __cplusplus
}
#endif

#endif
