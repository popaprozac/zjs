// Pluggable native HTTP backend for `fetch`.
//
// One entry point — `zjs_http_request_sync` — that each platform
// implements against its OS-native networking stack. Keeps the
// engine free of TLS plumbing (CA bundles, ciphersuite policy,
// version pinning) and gives us HTTPS / HTTP/2 / proxy / IPv6 / cert
// validation for free on platforms where the OS already provides
// them.
//
//   Apple   — NSURLSession (Foundation.framework) — see http_apple.m
//   Windows — WinHTTP (winhttp.lib) — see http_windows.c
//   Linux   — TBD (libcurl planned) — see http_stub.c at v0.1

#ifndef ZJS_HTTP_NATIVE_H
#define ZJS_HTTP_NATIVE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Request — caller fills out, passes a pointer to zjs_http_request_sync.
// All pointers are borrowed (not freed by the backend); the strings
// must remain valid until the call returns.
typedef struct {
    const char* method;        // "GET", "POST", "PUT", etc. NULL => "GET".
    const char* url;           // Required. UTF-8.
    const char** req_headers;  // Flat [name0, value0, name1, value1, ...].
                               // UTF-8 cstrings. May be NULL when count==0.
    size_t req_header_count;   // Number of name/value PAIRS — array length is 2*N.
    const char* body;          // Request body bytes (binary-safe). May be NULL.
    size_t body_len;           // Bytes in `body`. 0 => no body.
    int timeout_seconds;       // 0 => backend default (30s).
} ZjsHttpRequest;

// Response — backend fills out. Caller frees the allocations as
// noted on each field. `status_text` is convenience only — most
// callers prefer numeric status.
typedef struct {
    int status;                // HTTP status code (0 only when err_out is set).
    char* body;                // malloc'd response body. NULL when body_len==0.
                               // Caller frees with free().
    size_t body_len;           // Body length in bytes (binary-safe).
    char** resp_headers;       // malloc'd flat [name, value, ...]; each entry
                               // is itself malloc'd. Caller frees each entry
                               // then frees the array. May be NULL.
    size_t resp_header_count;  // Number of pairs (array length is 2*N).
} ZjsHttpResponse;

// Synchronous request. Blocks the calling thread until the request
// completes or fails.
//
// Returns 0 on transport success (any status code — caller must
// inspect resp->status to know whether the server returned 2xx).
// Returns -1 on transport failure (connection refused, DNS error,
// TLS handshake failure, etc.); *err_out is filled with a malloc'd
// UTF-8 string that the caller must free().
int zjs_http_request_sync(const ZjsHttpRequest* req,
                          ZjsHttpResponse* resp,
                          char** err_out);

// Convenience helper: free everything `resp` owns and zero the
// struct. Safe to call on a partially-filled response (NULL pointers
// are skipped).
void zjs_http_response_free(ZjsHttpResponse* resp);

// =====================================================================
// Async ABI — Promise.all parallelism. Engine stashes (handle, promise)
// in a pending list and polls every event-loop tick.
//   Apple   — NSURLSession async (no extra thread)
//   Windows/Linux — pthread-wrap of zjs_http_request_sync
// =====================================================================
typedef struct ZjsHttpHandle ZjsHttpHandle;
ZjsHttpHandle* zjs_http_request_start(const ZjsHttpRequest* req);
int  zjs_http_request_poll(ZjsHttpHandle* h, ZjsHttpResponse* out_resp, char** err_out);
void zjs_http_request_destroy(ZjsHttpHandle* h);

#ifdef __cplusplus
}
#endif

#endif
