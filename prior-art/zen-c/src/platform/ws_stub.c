// Fallback WebSocket backend for platforms without a native impl.
// Returns NULL from connect; everything else is a no-op.

#include "ws_native.h"
#include <stdlib.h>

struct ZjsWsHandle { int unused; };

ZjsWsHandle* zjs_ws_connect(const char* url,
                            const char** protocols,
                            size_t protocol_count,
                            int timeout_seconds) {
    (void)url; (void)protocols; (void)protocol_count; (void)timeout_seconds;
    return NULL;
}

int zjs_ws_send_text(ZjsWsHandle* h, const char* text, size_t len) {
    (void)h; (void)text; (void)len; return -1;
}

int zjs_ws_send_binary(ZjsWsHandle* h, const uint8_t* bytes, size_t len) {
    (void)h; (void)bytes; (void)len; return -1;
}

int zjs_ws_close(ZjsWsHandle* h, int code, const char* reason) {
    (void)h; (void)code; (void)reason; return -1;
}

int zjs_ws_poll(ZjsWsHandle* h, ZjsWsEvent* out_event) {
    (void)h; (void)out_event; return ZJS_WS_EVT_NONE;
}

void zjs_ws_destroy(ZjsWsHandle* h) {
    if (h) free(h);
}
