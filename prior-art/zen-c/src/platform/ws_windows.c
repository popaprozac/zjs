// Windows-native WebSocket backend — WinHTTP WebSocket (Win 8+).
//
// Mirrors src/platform/ws_apple.m's contract on top of WinHTTP's
// WebSocket API. The Apple impl uses NSURLSession's delegate
// callbacks to drive a mutex-protected event queue that the JS-side
// event loop drains per tick; we get the same shape with a single
// worker thread that runs the open-then-receive loop until close /
// error.
//
// Threading model:
//   - zjs_ws_connect creates the handle, kicks off a worker thread,
//     returns immediately. The worker performs the HTTP→WS upgrade
//     (TCP, TLS, handshake) then loops on WinHttpWebSocketReceive,
//     enqueueing events.
//   - zjs_ws_send_text / _send_binary run on the caller's thread
//     and call WinHttpWebSocketSend directly. WinHTTP permits send
//     + receive concurrently on the same handle.
//   - zjs_ws_close runs on the caller's thread, calls
//     WinHttpWebSocketShutdown to send the close frame. The
//     worker's next receive returns CLOSE_BUFFER_TYPE; we query the
//     server-side close status and enqueue a CLOSE event.
//   - zjs_ws_destroy flips the teardown flag, closes the WS handle
//     (which cancels any in-flight receive), joins the worker, and
//     frees the queue.
//
// Keepalive: WINHTTP_OPTION_WEB_SOCKET_KEEPALIVE_INTERVAL set to
// 25s after upgrade. WinHTTP auto-pings the server on that
// cadence; if a pong doesn't come back, the next receive errors
// and we synthesize CLOSE 1006 (abnormal closure) — same shape
// the Apple impl gives via its dispatch_source ping timer.
//
// Fragmented frames: WinHttpWebSocketReceive can return either a
// _MESSAGE buffer type (full message in one call) or a _FRAGMENT
// buffer type (caller reassembles). The receive loop accumulates
// fragments into a growable buffer and emits one MESSAGE_TEXT /
// MESSAGE_BIN event per complete WS message.

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <winhttp.h>
#include "ws_native.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#if defined(__GNUC__) && !defined(__clang__)
// gcc ignores #pragma comment(lib, ...); link with -lwinhttp instead.
#else
#pragma comment(lib, "winhttp.lib")
#endif

// Some older mingw headers don't define these even though the
// runtime supports them on Win 10. Define them defensively.
#ifndef WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET
#define WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET 114
#endif
#ifndef WINHTTP_OPTION_WEB_SOCKET_KEEPALIVE_INTERVAL
#define WINHTTP_OPTION_WEB_SOCKET_KEEPALIVE_INTERVAL 121
#endif
#ifndef WINHTTP_QUERY_SEC_WEBSOCKET_PROTOCOL
#define WINHTTP_QUERY_SEC_WEBSOCKET_PROTOCOL 75
#endif

typedef struct ZjsWsEventNode {
    ZjsWsEvent evt;
    struct ZjsWsEventNode* next;
} ZjsWsEventNode;

struct ZjsWsHandle {
    pthread_mutex_t lock;
    pthread_t       worker;
    int             worker_started;

    // Owned copies of caller inputs so they outlive zjs_ws_connect.
    wchar_t*        w_url;
    wchar_t*        w_host;
    wchar_t*        w_path;
    INTERNET_PORT   port;
    int             is_secure;
    wchar_t*        w_protocols;   // "p1, p2, p3" header value, or NULL
    int             timeout_seconds;

    // WinHTTP handles. h_ws is the post-upgrade handle; until upgrade
    // succeeds it's NULL and we use h_req for the upgrade request.
    HINTERNET       h_session;
    HINTERNET       h_conn;
    HINTERNET       h_req;
    HINTERNET       h_ws;

    // State flags. closed: zjs_ws_close was called. teardown:
    // zjs_ws_destroy was called — worker should exit asap.
    int             closed;
    int             open_fired;
    int             teardown;

    // FIFO event queue. ws_enqueue appends to tail, zjs_ws_poll
    // pops from head.
    ZjsWsEventNode* head;
    ZjsWsEventNode* tail;
};

// -------- utf8 / utf16 marshalling (same shape as http_windows.c) --------

static wchar_t* utf8_to_wide(const char* utf8, size_t len) {
    if (utf8 == NULL) return NULL;
    if (len == 0) {
        wchar_t* empty = (wchar_t*)malloc(sizeof(wchar_t));
        if (empty != NULL) empty[0] = L'\0';
        return empty;
    }
    int in_len = (int)len;
    int wlen = MultiByteToWideChar(CP_UTF8, 0, utf8, in_len, NULL, 0);
    if (wlen <= 0) return NULL;
    wchar_t* w = (wchar_t*)malloc(((size_t)wlen + 1) * sizeof(wchar_t));
    if (w == NULL) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, utf8, in_len, w, wlen);
    w[wlen] = L'\0';
    return w;
}

static char* wide_to_utf8(const wchar_t* wide, int wlen) {
    if (wide == NULL) {
        char* empty = (char*)malloc(1);
        if (empty != NULL) empty[0] = '\0';
        return empty;
    }
    int blen = WideCharToMultiByte(CP_UTF8, 0, wide, wlen, NULL, 0, NULL, NULL);
    if (blen < 0) blen = 0;
    char* s = (char*)malloc((size_t)blen + 1);
    if (s == NULL) return NULL;
    if (blen > 0) {
        WideCharToMultiByte(CP_UTF8, 0, wide, wlen, s, blen, NULL, NULL);
    }
    s[blen] = '\0';
    return s;
}

// -------- event queue --------

static void ws_enqueue(ZjsWsHandle* h, ZjsWsEvent e) {
    ZjsWsEventNode* n = (ZjsWsEventNode*)malloc(sizeof(ZjsWsEventNode));
    if (n == NULL) return;
    n->evt = e;
    n->next = NULL;
    pthread_mutex_lock(&h->lock);
    if (h->teardown) {
        // Destroy is racing us; throw the event away (caller is gone).
        pthread_mutex_unlock(&h->lock);
        if (e.text)   free(e.text);
        if (e.binary) free(e.binary);
        free(n);
        return;
    }
    if (h->tail) { h->tail->next = n; }
    else         { h->head = n; }
    h->tail = n;
    pthread_mutex_unlock(&h->lock);
}

// Build an error string (same shape as http_windows.c's
// format_win32_error) so JS-side error messages stay consistent.
static char* format_ws_error(const char* op, DWORD code) {
    LPWSTR sys_buf = NULL;
    DWORD chars = FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
        FORMAT_MESSAGE_FROM_HMODULE | FORMAT_MESSAGE_IGNORE_INSERTS,
        GetModuleHandleW(L"winhttp.dll"),
        code, 0, (LPWSTR)&sys_buf, 0, NULL);
    char header[160];
    if (op == NULL) op = "websocket";
    snprintf(header, sizeof header, "websocket: %s failed (WinHTTP error %lu)",
             op, (unsigned long)code);
    if (chars == 0 || sys_buf == NULL) {
        if (sys_buf) LocalFree(sys_buf);
        return _strdup(header);
    }
    while (chars > 0 &&
           (sys_buf[chars - 1] == L'\r' ||
            sys_buf[chars - 1] == L'\n' ||
            sys_buf[chars - 1] == L' ')) {
        sys_buf[--chars] = L'\0';
    }
    char* tail = wide_to_utf8(sys_buf, (int)chars);
    LocalFree(sys_buf);
    if (tail == NULL) return _strdup(header);
    size_t hlen = strlen(header), tlen = strlen(tail);
    char* full = (char*)malloc(hlen + 2 + tlen + 1);
    if (full == NULL) { free(tail); return _strdup(header); }
    memcpy(full, header, hlen);
    full[hlen] = ':'; full[hlen + 1] = ' ';
    memcpy(full + hlen + 2, tail, tlen);
    full[hlen + 2 + tlen] = '\0';
    free(tail);
    return full;
}

static void enqueue_error(ZjsWsHandle* h, const char* op, DWORD code) {
    ZjsWsEvent e; memset(&e, 0, sizeof e);
    e.kind = ZJS_WS_EVT_ERROR;
    e.text = format_ws_error(op, code);
    e.text_len = e.text ? strlen(e.text) : 0;
    ws_enqueue(h, e);
}

static void enqueue_close(ZjsWsHandle* h, int code, const char* reason, size_t reason_len) {
    ZjsWsEvent e; memset(&e, 0, sizeof e);
    e.kind = ZJS_WS_EVT_CLOSE;
    e.code = code;
    if (reason != NULL && reason_len > 0) {
        char* buf = (char*)malloc(reason_len + 1);
        if (buf != NULL) {
            memcpy(buf, reason, reason_len);
            buf[reason_len] = 0;
            e.text = buf;
            e.text_len = reason_len;
        }
    }
    ws_enqueue(h, e);
}

// Read the server-selected Sec-WebSocket-Protocol header off the
// upgrade response and enqueue an OPEN event with it. Spec says the
// header is at most one token; if absent we report "".
static void enqueue_open_with_subprotocol(ZjsWsHandle* h) {
    if (h->open_fired) return;
    h->open_fired = 1;
    ZjsWsEvent e; memset(&e, 0, sizeof e);
    e.kind = ZJS_WS_EVT_OPEN;
    DWORD bytes = 0;
    WinHttpQueryHeaders(h->h_req,
                        WINHTTP_QUERY_SEC_WEBSOCKET_PROTOCOL,
                        WINHTTP_HEADER_NAME_BY_INDEX,
                        WINHTTP_NO_OUTPUT_BUFFER,
                        &bytes,
                        WINHTTP_NO_HEADER_INDEX);
    if (bytes > 0 && GetLastError() == ERROR_INSUFFICIENT_BUFFER) {
        wchar_t* w = (wchar_t*)malloc(bytes);
        if (w != NULL) {
            if (WinHttpQueryHeaders(h->h_req,
                                    WINHTTP_QUERY_SEC_WEBSOCKET_PROTOCOL,
                                    WINHTTP_HEADER_NAME_BY_INDEX,
                                    w,
                                    &bytes,
                                    WINHTTP_NO_HEADER_INDEX)) {
                e.text = wide_to_utf8(w, -1);
                e.text_len = e.text ? strlen(e.text) : 0;
            }
            free(w);
        }
    }
    if (e.text == NULL) {
        e.text = _strdup("");
        e.text_len = 0;
    }
    ws_enqueue(h, e);
}

// Perform the HTTP→WS upgrade and complete the handshake. Returns 0
// on success (h->h_ws set), -1 on failure (error enqueued).
static int do_upgrade(ZjsWsHandle* h) {
    h->h_session = WinHttpOpen(L"zjs/0.0.1",
                               WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                               WINHTTP_NO_PROXY_NAME,
                               WINHTTP_NO_PROXY_BYPASS,
                               0);
    if (h->h_session == NULL) {
        enqueue_error(h, "session open", GetLastError());
        return -1;
    }
    int timeout = (h->timeout_seconds > 0) ? h->timeout_seconds : 30;
    DWORD ms = (DWORD)timeout * 1000u;
    WinHttpSetTimeouts(h->h_session, (int)ms, (int)ms, (int)ms, (int)ms);

    h->h_conn = WinHttpConnect(h->h_session, h->w_host, h->port, 0);
    if (h->h_conn == NULL) {
        enqueue_error(h, "connect", GetLastError());
        return -1;
    }

    DWORD req_flags = h->is_secure ? WINHTTP_FLAG_SECURE : 0;
    h->h_req = WinHttpOpenRequest(h->h_conn,
                                  L"GET",
                                  h->w_path,
                                  NULL,
                                  WINHTTP_NO_REFERER,
                                  WINHTTP_DEFAULT_ACCEPT_TYPES,
                                  req_flags);
    if (h->h_req == NULL) {
        enqueue_error(h, "open request", GetLastError());
        return -1;
    }

    if (h->w_protocols != NULL && h->w_protocols[0] != L'\0') {
        // Add Sec-WebSocket-Protocol with the comma-separated subprotocols.
        size_t pre = wcslen(L"Sec-WebSocket-Protocol: ");
        size_t prot = wcslen(h->w_protocols);
        wchar_t* hdr = (wchar_t*)malloc((pre + prot + 3) * sizeof(wchar_t));
        if (hdr != NULL) {
            wcscpy(hdr, L"Sec-WebSocket-Protocol: ");
            wcscat(hdr, h->w_protocols);
            wcscat(hdr, L"\r\n");
            WinHttpAddRequestHeaders(h->h_req, hdr, (DWORD)-1L,
                                     WINHTTP_ADDREQ_FLAG_ADD |
                                     WINHTTP_ADDREQ_FLAG_REPLACE);
            free(hdr);
        }
    }

    // Mark the request as a WebSocket upgrade. Must be set BEFORE
    // SendRequest. The option takes no buffer (NULL, 0) — its mere
    // presence is the signal.
    if (!WinHttpSetOption(h->h_req,
                          WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET,
                          NULL,
                          0)) {
        enqueue_error(h, "set upgrade option", GetLastError());
        return -1;
    }

    if (!WinHttpSendRequest(h->h_req,
                            WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            WINHTTP_NO_REQUEST_DATA, 0,
                            0, 0)) {
        enqueue_error(h, "send request", GetLastError());
        return -1;
    }
    if (!WinHttpReceiveResponse(h->h_req, NULL)) {
        enqueue_error(h, "receive response", GetLastError());
        return -1;
    }

    // The server must have returned a 101 Switching Protocols for the
    // upgrade to succeed. If it returned anything else, surface it as
    // an error; WinHttpWebSocketCompleteUpgrade would also fail.
    DWORD status_code = 0;
    DWORD status_size = sizeof status_code;
    if (!WinHttpQueryHeaders(h->h_req,
                             WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             WINHTTP_HEADER_NAME_BY_INDEX,
                             &status_code,
                             &status_size,
                             WINHTTP_NO_HEADER_INDEX)) {
        enqueue_error(h, "query upgrade status", GetLastError());
        return -1;
    }
    if (status_code != 101) {
        ZjsWsEvent e; memset(&e, 0, sizeof e);
        e.kind = ZJS_WS_EVT_ERROR;
        char buf[96];
        snprintf(buf, sizeof buf,
                 "websocket: upgrade refused (HTTP %lu)",
                 (unsigned long)status_code);
        e.text = _strdup(buf);
        e.text_len = strlen(buf);
        ws_enqueue(h, e);
        return -1;
    }

    h->h_ws = WinHttpWebSocketCompleteUpgrade(h->h_req, 0);
    if (h->h_ws == NULL) {
        enqueue_error(h, "complete upgrade", GetLastError());
        return -1;
    }

    // Auto-ping every 25 seconds; WinHTTP handles the ping/pong on
    // its own and only surfaces an error to subsequent receives if
    // the pong never comes back. Matches the Apple keepalive shape.
    DWORD keepalive_ms = 25000;
    WinHttpSetOption(h->h_ws,
                     WINHTTP_OPTION_WEB_SOCKET_KEEPALIVE_INTERVAL,
                     &keepalive_ms, sizeof keepalive_ms);

    enqueue_open_with_subprotocol(h);
    return 0;
}

static void* ws_worker(void* arg) {
    ZjsWsHandle* h = (ZjsWsHandle*)arg;

    if (do_upgrade(h) != 0) {
        // Upgrade failed — error event already enqueued. Worker
        // exits; destroy will free everything.
        return NULL;
    }

    // Per-message accumulator. WinHTTP can split a single message
    // into multiple _FRAGMENT chunks; we glue them back together and
    // emit one TEXT/BIN event per complete message.
    char*  acc      = NULL;
    size_t acc_len  = 0;
    size_t acc_cap  = 0;
    int    acc_kind = 0; // 0=none, 2=text, 3=bin (matches ZJS_WS_EVT_*)

    enum { CHUNK_SIZE = 4096 };

    for (;;) {
        if (h->teardown) break;

        // Grow accumulator to make room for one more CHUNK_SIZE.
        if (acc_len + CHUNK_SIZE > acc_cap) {
            size_t new_cap = acc_cap ? acc_cap * 2 : CHUNK_SIZE;
            while (new_cap < acc_len + CHUNK_SIZE) new_cap *= 2;
            char* grown = (char*)realloc(acc, new_cap);
            if (grown == NULL) {
                ZjsWsEvent e; memset(&e, 0, sizeof e);
                e.kind = ZJS_WS_EVT_ERROR;
                e.text = _strdup("websocket: out of memory");
                e.text_len = e.text ? strlen(e.text) : 0;
                ws_enqueue(h, e);
                break;
            }
            acc = grown;
            acc_cap = new_cap;
        }

        DWORD got = 0;
        WINHTTP_WEB_SOCKET_BUFFER_TYPE btype;
        DWORD rc = WinHttpWebSocketReceive(h->h_ws,
                                           acc + acc_len,
                                           CHUNK_SIZE,
                                           &got,
                                           &btype);
        if (rc != NO_ERROR) {
            if (h->teardown || h->closed) {
                // Destroy / close raced us — exit quietly. If the
                // local close hasn't fired its CLOSE event yet
                // because the server didn't ack with a close frame,
                // synthesize one with 1006 (abnormal closure).
                if (h->closed && !h->open_fired) {
                    // shouldn't happen — open_fired must be set
                    // before we entered the loop
                } else if (h->closed) {
                    enqueue_close(h, 1006, "connection closed", 17);
                }
                break;
            }
            enqueue_error(h, "receive", rc);
            break;
        }

        acc_len += got;

        if (btype == WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE) {
            acc_kind = ZJS_WS_EVT_MESSAGE_TEXT;
            continue;
        }
        if (btype == WINHTTP_WEB_SOCKET_BINARY_FRAGMENT_BUFFER_TYPE) {
            acc_kind = ZJS_WS_EVT_MESSAGE_BIN;
            continue;
        }

        if (btype == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE ||
            btype == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE) {
            ZjsWsEvent e; memset(&e, 0, sizeof e);
            int kind = (btype == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE)
                       ? ZJS_WS_EVT_MESSAGE_TEXT
                       : ZJS_WS_EVT_MESSAGE_BIN;
            // Fold in any prior fragments — if acc_kind disagrees
            // with the final kind we still trust the final type.
            e.kind = kind;
            if (kind == ZJS_WS_EVT_MESSAGE_TEXT) {
                char* buf = (char*)malloc(acc_len + 1);
                if (buf != NULL) {
                    memcpy(buf, acc, acc_len);
                    buf[acc_len] = 0;
                    e.text = buf;
                    e.text_len = acc_len;
                }
            } else {
                uint8_t* buf = (uint8_t*)malloc(acc_len > 0 ? acc_len : 1);
                if (buf != NULL) {
                    if (acc_len > 0) memcpy(buf, acc, acc_len);
                    e.binary = buf;
                    e.binary_len = acc_len;
                }
            }
            ws_enqueue(h, e);
            acc_len = 0;
            acc_kind = 0;
            continue;
        }

        if (btype == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) {
            USHORT code = 1005;            // "No Status Rcvd" default
            BYTE   reason_buf[123];        // WS reason max is 123 bytes
            DWORD  reason_len = 0;
            DWORD qrc = WinHttpWebSocketQueryCloseStatus(h->h_ws,
                                                         &code,
                                                         reason_buf,
                                                         sizeof reason_buf,
                                                         &reason_len);
            (void)qrc;
            enqueue_close(h, (int)code,
                          reason_len > 0 ? (const char*)reason_buf : NULL,
                          (size_t)reason_len);
            break;
        }

        // Unknown buffer type — protocol violation. Surface and exit.
        ZjsWsEvent e; memset(&e, 0, sizeof e);
        e.kind = ZJS_WS_EVT_ERROR;
        char buf[96];
        snprintf(buf, sizeof buf,
                 "websocket: unknown buffer type %d", (int)btype);
        e.text = _strdup(buf);
        e.text_len = strlen(buf);
        ws_enqueue(h, e);
        break;
    }

    free(acc);
    return NULL;
}

// --- parse ws://host[:port]/path?query ---
// WinHttpCrackUrl doesn't recognize ws/wss as schemes, so we convert
// them to http/https for parsing and remember whether the original
// scheme was secure.
static int parse_ws_url(const char* url, wchar_t** out_w_url,
                        wchar_t** out_host, wchar_t** out_path,
                        INTERNET_PORT* out_port, int* out_secure) {
    if (url == NULL) return -1;
    size_t ulen = strlen(url);
    int    secure = 0;
    const char* rest = NULL;
    if (ulen >= 6 && memcmp(url, "wss://", 6) == 0) {
        secure = 1; rest = url + 6;
    } else if (ulen >= 5 && memcmp(url, "ws://", 5) == 0) {
        secure = 0; rest = url + 5;
    } else {
        return -1;
    }

    // Rebuild URL as http/https for WinHttpCrackUrl.
    const char* prefix = secure ? "https://" : "http://";
    size_t pl = strlen(prefix), rl = strlen(rest);
    char* swapped = (char*)malloc(pl + rl + 1);
    if (swapped == NULL) return -1;
    memcpy(swapped, prefix, pl);
    memcpy(swapped + pl, rest, rl);
    swapped[pl + rl] = '\0';

    wchar_t* w_url = utf8_to_wide(swapped, strlen(swapped));
    free(swapped);
    if (w_url == NULL) return -1;

    URL_COMPONENTS uc;
    memset(&uc, 0, sizeof uc);
    uc.dwStructSize = sizeof uc;
    uc.dwSchemeLength    = (DWORD)-1;
    uc.dwHostNameLength  = (DWORD)-1;
    uc.dwUrlPathLength   = (DWORD)-1;
    uc.dwExtraInfoLength = (DWORD)-1;
    if (!WinHttpCrackUrl(w_url, 0, 0, &uc)) {
        free(w_url);
        return -1;
    }
    wchar_t* w_host = (wchar_t*)malloc(((size_t)uc.dwHostNameLength + 1) * sizeof(wchar_t));
    if (w_host == NULL) { free(w_url); return -1; }
    memcpy(w_host, uc.lpszHostName, uc.dwHostNameLength * sizeof(wchar_t));
    w_host[uc.dwHostNameLength] = L'\0';

    size_t path_chars = (size_t)uc.dwUrlPathLength + (size_t)uc.dwExtraInfoLength;
    if (path_chars == 0) path_chars = 1;
    wchar_t* w_path = (wchar_t*)malloc((path_chars + 1) * sizeof(wchar_t));
    if (w_path == NULL) { free(w_url); free(w_host); return -1; }
    if (uc.dwUrlPathLength == 0 && uc.dwExtraInfoLength == 0) {
        w_path[0] = L'/'; w_path[1] = L'\0';
    } else {
        size_t off = 0;
        if (uc.dwUrlPathLength > 0) {
            memcpy(w_path + off, uc.lpszUrlPath,
                   uc.dwUrlPathLength * sizeof(wchar_t));
            off += uc.dwUrlPathLength;
        }
        if (uc.dwExtraInfoLength > 0) {
            memcpy(w_path + off, uc.lpszExtraInfo,
                   uc.dwExtraInfoLength * sizeof(wchar_t));
            off += uc.dwExtraInfoLength;
        }
        w_path[off] = L'\0';
    }

    *out_w_url = w_url;
    *out_host  = w_host;
    *out_path  = w_path;
    *out_port  = uc.nPort;
    *out_secure = secure;
    return 0;
}

// --- public ABI ---

ZjsWsHandle* zjs_ws_connect(const char* url,
                            const char** protocols,
                            size_t protocol_count,
                            int timeout_seconds) {
    if (url == NULL) return NULL;

    ZjsWsHandle* h = (ZjsWsHandle*)calloc(1, sizeof(ZjsWsHandle));
    if (h == NULL) return NULL;
    pthread_mutex_init(&h->lock, NULL);
    h->timeout_seconds = timeout_seconds;

    if (parse_ws_url(url, &h->w_url, &h->w_host, &h->w_path,
                     &h->port, &h->is_secure) != 0) {
        zjs_ws_destroy(h);
        return NULL;
    }

    if (protocols != NULL && protocol_count > 0) {
        size_t total = 0;
        for (size_t i = 0; i < protocol_count; i++) {
            if (protocols[i] == NULL) continue;
            total += strlen(protocols[i]) + 2; // ", "
        }
        if (total > 0) {
            char* csv = (char*)malloc(total + 1);
            if (csv != NULL) {
                size_t off = 0;
                for (size_t i = 0; i < protocol_count; i++) {
                    if (protocols[i] == NULL) continue;
                    size_t n = strlen(protocols[i]);
                    if (off > 0) { csv[off++] = ','; csv[off++] = ' '; }
                    memcpy(csv + off, protocols[i], n);
                    off += n;
                }
                csv[off] = '\0';
                h->w_protocols = utf8_to_wide(csv, off);
                free(csv);
            }
        }
    }

    if (pthread_create(&h->worker, NULL, ws_worker, h) != 0) {
        zjs_ws_destroy(h);
        return NULL;
    }
    h->worker_started = 1;
    return h;
}

int zjs_ws_send_text(ZjsWsHandle* h, const char* text, size_t len) {
    if (h == NULL || h->h_ws == NULL || text == NULL) return -1;
    if (h->closed || h->teardown) return -1;
    DWORD rc = WinHttpWebSocketSend(h->h_ws,
                                    WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
                                    (PVOID)text,
                                    (DWORD)len);
    if (rc != NO_ERROR) {
        enqueue_error(h, "send text", rc);
        return -1;
    }
    return 0;
}

int zjs_ws_send_binary(ZjsWsHandle* h, const uint8_t* bytes, size_t len) {
    if (h == NULL || h->h_ws == NULL || bytes == NULL) return -1;
    if (h->closed || h->teardown) return -1;
    DWORD rc = WinHttpWebSocketSend(h->h_ws,
                                    WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE,
                                    (PVOID)bytes,
                                    (DWORD)len);
    if (rc != NO_ERROR) {
        enqueue_error(h, "send binary", rc);
        return -1;
    }
    return 0;
}

int zjs_ws_close(ZjsWsHandle* h, int code, const char* reason) {
    if (h == NULL || h->h_ws == NULL) return -1;
    if (h->closed) return 0;
    h->closed = 1;
    USHORT status = (USHORT)((code >= 1000 && code <= 4999) ? code : 1000);
    DWORD  rlen = (reason != NULL) ? (DWORD)strlen(reason) : 0;
    if (rlen > 123) rlen = 123;
    WinHttpWebSocketShutdown(h->h_ws, status, (PVOID)reason, rlen);
    // CLOSE event arrives via the worker's receive loop when the
    // server's close frame comes back (or via the abnormal-close
    // synthesis path if the connection dies first).
    return 0;
}

int zjs_ws_poll(ZjsWsHandle* h, ZjsWsEvent* out_event) {
    if (h == NULL || out_event == NULL) return ZJS_WS_EVT_NONE;
    pthread_mutex_lock(&h->lock);
    ZjsWsEventNode* n = h->head;
    if (n == NULL) {
        pthread_mutex_unlock(&h->lock);
        return ZJS_WS_EVT_NONE;
    }
    h->head = n->next;
    if (h->head == NULL) h->tail = NULL;
    pthread_mutex_unlock(&h->lock);
    *out_event = n->evt;
    free(n);
    return out_event->kind;
}

void zjs_ws_destroy(ZjsWsHandle* h) {
    if (h == NULL) return;
    pthread_mutex_lock(&h->lock);
    h->teardown = 1;
    pthread_mutex_unlock(&h->lock);

    // Closing the WS handle cancels any in-flight receive in the
    // worker thread, which will then exit. Close the request handle
    // too in case the upgrade is still in flight.
    if (h->h_ws)      { WinHttpCloseHandle(h->h_ws);      h->h_ws = NULL; }
    if (h->h_req)     { WinHttpCloseHandle(h->h_req);     h->h_req = NULL; }
    if (h->h_conn)    { WinHttpCloseHandle(h->h_conn);    h->h_conn = NULL; }
    if (h->h_session) { WinHttpCloseHandle(h->h_session); h->h_session = NULL; }

    if (h->worker_started) {
        pthread_join(h->worker, NULL);
        h->worker_started = 0;
    }

    // Drain remaining events.
    ZjsWsEventNode* n = h->head;
    while (n != NULL) {
        ZjsWsEventNode* next = n->next;
        if (n->evt.text)   free(n->evt.text);
        if (n->evt.binary) free(n->evt.binary);
        free(n);
        n = next;
    }
    h->head = h->tail = NULL;

    if (h->w_url)       free(h->w_url);
    if (h->w_host)      free(h->w_host);
    if (h->w_path)      free(h->w_path);
    if (h->w_protocols) free(h->w_protocols);
    pthread_mutex_destroy(&h->lock);
    free(h);
}
