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

int zjs_http_get_sync(const char* url,
                      int* status_out,
                      char** body_out,
                      size_t* body_len_out,
                      char** err_out) {
    (void)url;
    if (status_out)   *status_out   = 0;
    if (body_out)     *body_out     = NULL;
    if (body_len_out) *body_len_out = 0;
    if (err_out)      *err_out      = strdup("fetch: HTTP backend not configured on this platform");
    return -1;
}
