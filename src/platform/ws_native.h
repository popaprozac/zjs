// Pluggable native WebSocket backend.
//
// Mirrors http_native.h's pattern: one set of C ABI entry points
// per-platform, each implementing a thin wrapper around the OS's
// native WebSocket primitives. Same TLS-for-free / smaller-binary /
// higher-quality argument as fetch (#202) — see
// `feedback_prefer_platform_native` memory for the rationale.
//
//   Apple   — NSURLSessionWebSocketTask  (Foundation) — ws_apple.m
//   Linux   — libwebsockets (-lwebsockets) — ws_linux.c
//   Windows — TBD (WinHTTP_WebSocket planned) — ws_stub.c at v0.1

#ifndef ZJS_WS_NATIVE_H
#define ZJS_WS_NATIVE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZjsWsHandle ZjsWsHandle;

// Event kinds drained via zjs_ws_poll. Caller frees any malloc'd
// payload fields (text, binary, reason) on receipt — see comments
// on each.
typedef enum {
    ZJS_WS_EVT_NONE         = 0,  // no events pending
    ZJS_WS_EVT_OPEN         = 1,
    ZJS_WS_EVT_MESSAGE_TEXT = 2,  // text payload in `text` (UTF-8, malloc'd)
    ZJS_WS_EVT_MESSAGE_BIN  = 3,  // binary payload in `binary` (malloc'd)
    ZJS_WS_EVT_ERROR        = 4,  // error message in `text` (malloc'd)
    ZJS_WS_EVT_CLOSE        = 5,  // code + reason (`text`, malloc'd, may be NULL)
} ZjsWsEventKind;

typedef struct {
    int kind;            // ZjsWsEventKind
    char* text;          // for TEXT/ERROR/CLOSE — UTF-8, malloc'd, caller frees
                         // for OPEN — server-selected subprotocol ("" if none)
    size_t text_len;
    uint8_t* binary;     // for BIN — malloc'd, caller frees
    size_t binary_len;
    int code;            // for CLOSE — 1000 = normal, etc.
} ZjsWsEvent;

// Open a WebSocket connection. Returns an opaque handle on success
// (caller eventually destroys with zjs_ws_destroy) or NULL on
// failure. `url` must be a `ws://` or `wss://` URL.
//
// `protocols` is an optional array of subprotocol names to offer in
// the Sec-WebSocket-Protocol header. May be NULL when protocol_count
// is 0. The server's chosen subprotocol arrives on the OPEN event's
// `text` field. `timeout_seconds` <= 0 means use the platform default.
ZjsWsHandle* zjs_ws_connect(const char* url,
                            const char** protocols,
                            size_t protocol_count,
                            int timeout_seconds);

// Send a text frame. Returns 0 on queued-for-send, -1 on error.
int zjs_ws_send_text(ZjsWsHandle* h, const char* text, size_t len);

// Send a binary frame. Returns 0 on queued-for-send, -1 on error.
int zjs_ws_send_binary(ZjsWsHandle* h, const uint8_t* bytes, size_t len);

// Close the connection (queues a Close frame). Safe to call
// multiple times; only the first has effect.
int zjs_ws_close(ZjsWsHandle* h, int code, const char* reason);

// Try to dequeue the next event. Returns ZJS_WS_EVT_NONE if no event
// is ready (non-blocking). Caller must free any allocated payload
// fields on the returned event when no longer needed.
int zjs_ws_poll(ZjsWsHandle* h, ZjsWsEvent* out_event);

// Tear down. Sends a Close frame if still open, then frees the
// handle.  Safe to call once per handle.
void zjs_ws_destroy(ZjsWsHandle* h);

#ifdef __cplusplus
}
#endif

#endif
