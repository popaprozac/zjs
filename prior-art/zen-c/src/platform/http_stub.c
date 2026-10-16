// Fallback HTTP backend for platforms where we haven't wired in the
// OS-native stack yet. Returns a "not configured" error so fetch()
// rejects cleanly.
//
// Replaced on Apple by http_apple.m. Linux and Windows entries will
// follow (libcurl and WinHTTP respectively) — see the design notes
// in http_native.h.

#include "http_native.h"
#include <stdlib.h>
#include <string.h>

void zjs_http_response_free(ZjsHttpResponse* resp) {
    if (resp == NULL) return;
    if (resp->body != NULL) {
        free(resp->body);
        resp->body = NULL;
    }
    resp->body_len = 0;
    if (resp->resp_headers != NULL) {
        size_t n = resp->resp_header_count * 2;
        for (size_t i = 0; i < n; i++) {
            if (resp->resp_headers[i] != NULL) free(resp->resp_headers[i]);
        }
        free(resp->resp_headers);
        resp->resp_headers = NULL;
    }
    resp->resp_header_count = 0;
    resp->status = 0;
}

int zjs_http_request_sync(const ZjsHttpRequest* req,
                          ZjsHttpResponse* resp,
                          char** err_out) {
    (void)req;
    if (resp != NULL) {
        resp->status = 0;
        resp->body = NULL;
        resp->body_len = 0;
        resp->resp_headers = NULL;
        resp->resp_header_count = 0;
    }
    if (err_out) *err_out = strdup("fetch: HTTP backend not configured on this platform");
    return -1;
}
