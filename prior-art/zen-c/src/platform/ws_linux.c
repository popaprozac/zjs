// Linux-native WebSocket backend — libwebsockets (lws).
//
// Mirrors src/platform/ws_apple.m's design: one event queue per
// handle, drained by JS on every tick via zjs_ws_poll. lws differs
// from NSURLSession in two ways that drive the structure here:
//
//   1. lws is single-threaded — its `lws_service` loop must run on a
//      dedicated thread that owns the lws_context. We spawn one pthread
//      per WS handle; that thread runs the service loop until the
//      connection closes or the engine destroys the handle.
//
//   2. Sending is asynchronous and must originate from the service
//      thread inside an LWS_CALLBACK_CLIENT_WRITEABLE callback. Main
//      thread (the JS interpreter) instead enqueues an outgoing message
//      under a mutex, then calls `lws_cancel_service` to wake the
//      worker; the worker requests a writable callback, and the actual
//      `lws_write` happens inside that callback.
//
// Keep-alive ping/pong is deferred — see docs/platform-port-status.md.
// The lws default behavior is to NOT send client pings; long idle WS
// connections through aggressive NATs may drop. Matches the v0.1
// Apple ship state before dispatch_source timers were wired in.
//
// Linked via `-lwebsockets` (set in the `//> linux: link:` build
// directives at the top of every entry point that imports the engine).

#include "ws_native.h"
#include <libwebsockets.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// -----------------------------------------------------------------------------
// Outgoing message queue — populated by main thread, drained by worker
// thread inside LWS_CALLBACK_CLIENT_WRITEABLE.
// -----------------------------------------------------------------------------

typedef struct OutMsg {
    uint8_t* buf;       // owned; includes LWS_PRE pad. Payload starts at buf+LWS_PRE.
    size_t   len;       // payload byte count (NOT including LWS_PRE).
    int      kind;      // 0 = text, 1 = binary, 2 = close
    int      close_code;
    struct OutMsg* next;
} OutMsg;

// -----------------------------------------------------------------------------
// Incoming event queue — fed by lws callbacks running on the worker
// thread, drained by JS on the main thread via zjs_ws_poll.
// -----------------------------------------------------------------------------

typedef struct ZjsWsEventNode {
    ZjsWsEvent             evt;
    struct ZjsWsEventNode* next;
} ZjsWsEventNode;

struct ZjsWsHandle {
    pthread_t worker;
    int       joinable;

    struct lws_context* context;
    struct lws*         wsi;           // borrowed; lws owns the wsi lifetime

    pthread_mutex_t lock;

    // Owned copies of caller inputs that lws references into until
    // the connection is established. lws's `client_connect_info`
    // takes borrowed pointers; we must keep them alive until at
    // least LWS_CALLBACK_CLIENT_ESTABLISHED or _CONNECTION_ERROR.
    char* url_buf;                     // mutated by lws_parse_uri
    char* host_buf;                    // copy of the host segment
    char* path_buf;                    // copy of the path (leading '/')
    char* proto_csv;                   // comma-joined subprotocols, or NULL

    // Event queues
    ZjsWsEventNode* in_head;
    ZjsWsEventNode* in_tail;
    OutMsg*         out_head;
    OutMsg*         out_tail;

    // Receive-fragment accumulator. lws can deliver one logical
    // message across multiple LWS_CALLBACK_CLIENT_RECEIVE callbacks;
    // accumulate until lws_is_final_fragment().
    uint8_t* frag_buf;
    size_t   frag_len;
    size_t   frag_cap;
    int      frag_is_binary;

    int closed;                        // 1 once user requested close
    int open_fired;                    // 1 once an OPEN has been enqueued
    int conn_failed;                   // 1 once a CONNECTION_ERROR fired
    int worker_should_exit;            // 1 to break the service loop

    // Close-frame info captured from PEER_INITIATED_CLOSE so we can
    // surface the real code/reason to JS in the CLOSED callback.
    int   peer_close_code;
    char* peer_close_reason;
    size_t peer_close_reason_len;
    int   peer_close_seen;
};

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

static void ws_enqueue_locked(ZjsWsHandle* h, ZjsWsEvent e) {
    ZjsWsEventNode* n = (ZjsWsEventNode*)calloc(1, sizeof(ZjsWsEventNode));
    if (n == NULL) return;
    n->evt = e;
    if (h->in_tail) h->in_tail->next = n;
    else            h->in_head       = n;
    h->in_tail = n;
}

static void ws_enqueue(ZjsWsHandle* h, ZjsWsEvent e) {
    pthread_mutex_lock(&h->lock);
    ws_enqueue_locked(h, e);
    pthread_mutex_unlock(&h->lock);
}

static char* xstrdup_or_null(const char* s) {
    if (s == NULL) return NULL;
    size_t n = strlen(s) + 1;
    char* p = (char*)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

// -----------------------------------------------------------------------------
// lws callback — fires on the worker thread for every connection event.
// -----------------------------------------------------------------------------

static int ws_callback(struct lws* wsi, enum lws_callback_reasons reason,
                       void* user, void* in, size_t len) {
    (void)user;
    ZjsWsHandle* h = (ZjsWsHandle*)lws_get_opaque_user_data(wsi);
    if (h == NULL) return 0;

    switch (reason) {

    case LWS_CALLBACK_CLIENT_ESTABLISHED: {
        if (h->open_fired) break;
        h->open_fired = 1;
        // Server's chosen subprotocol comes back in the wsi's selected
        // protocol. Match Apple's "empty string when none negotiated"
        // contract so JS sees "" not undefined.
        const struct lws_protocols* p = lws_get_protocol(wsi);
        const char* sub = (p && p->name) ? p->name : "";
        // We named our default protocol "" in `protocols[]` below to
        // permit a no-subprotocol handshake. When the server picks
        // ours, lws may report it as "" — keep that as "" for JS.
        if (strcmp(sub, "default") == 0) sub = "";
        ZjsWsEvent e = {0};
        e.kind     = ZJS_WS_EVT_OPEN;
        e.text     = strdup(sub);
        e.text_len = e.text ? strlen(e.text) : 0;
        ws_enqueue(h, e);
        // If main thread already queued outgoing messages before the
        // handshake completed, ask for a writeable callback now.
        pthread_mutex_lock(&h->lock);
        int has_out = (h->out_head != NULL);
        pthread_mutex_unlock(&h->lock);
        if (has_out) lws_callback_on_writable(wsi);
        break;
    }

    case LWS_CALLBACK_CLIENT_RECEIVE: {
        int is_binary = lws_frame_is_binary(wsi);
        // Append this fragment to the accumulator.
        size_t need = h->frag_len + len;
        if (need + 1 > h->frag_cap) {
            size_t new_cap = h->frag_cap ? h->frag_cap * 2 : 4096;
            while (new_cap < need + 1) new_cap *= 2;
            uint8_t* grown = (uint8_t*)realloc(h->frag_buf, new_cap);
            if (grown == NULL) break;  // OOM; drop fragment, connection will likely error
            h->frag_buf = grown;
            h->frag_cap = new_cap;
        }
        if (h->frag_len == 0) h->frag_is_binary = is_binary;
        if (len > 0) memcpy(h->frag_buf + h->frag_len, in, len);
        h->frag_len += len;

        if (lws_is_final_fragment(wsi)) {
            ZjsWsEvent e = {0};
            if (h->frag_is_binary) {
                e.kind = ZJS_WS_EVT_MESSAGE_BIN;
                uint8_t* payload = (uint8_t*)malloc(h->frag_len ? h->frag_len : 1);
                if (payload != NULL) {
                    if (h->frag_len > 0) memcpy(payload, h->frag_buf, h->frag_len);
                    e.binary     = payload;
                    e.binary_len = h->frag_len;
                }
            } else {
                e.kind = ZJS_WS_EVT_MESSAGE_TEXT;
                char* payload = (char*)malloc(h->frag_len + 1);
                if (payload != NULL) {
                    if (h->frag_len > 0) memcpy(payload, h->frag_buf, h->frag_len);
                    payload[h->frag_len] = '\0';
                    e.text     = payload;
                    e.text_len = h->frag_len;
                }
            }
            ws_enqueue(h, e);
            h->frag_len = 0;
        }
        break;
    }

    case LWS_CALLBACK_CLIENT_WRITEABLE: {
        // Dequeue one outgoing message and write it. lws will fire
        // another WRITEABLE if we request one — keep pulling until
        // the queue is empty.
        pthread_mutex_lock(&h->lock);
        OutMsg* m = h->out_head;
        if (m != NULL) {
            h->out_head = m->next;
            if (h->out_head == NULL) h->out_tail = NULL;
        }
        int more = (h->out_head != NULL);
        pthread_mutex_unlock(&h->lock);
        if (m == NULL) break;

        if (m->kind == 2) {
            // Close — translate to an lws close.
            unsigned char close_payload[125];
            size_t cp_len = 0;
            close_payload[0] = (unsigned char)((m->close_code >> 8) & 0xFF);
            close_payload[1] = (unsigned char)(m->close_code & 0xFF);
            cp_len = 2;
            if (m->buf != NULL && m->len > 0) {
                size_t reason_len = m->len;
                if (reason_len > sizeof(close_payload) - 2) {
                    reason_len = sizeof(close_payload) - 2;
                }
                memcpy(close_payload + 2, m->buf + LWS_PRE, reason_len);
                cp_len += reason_len;
            }
            lws_close_reason(wsi, (enum lws_close_status)m->close_code,
                             close_payload + 2, cp_len - 2);
            // Returning -1 from the callback tells lws to actually
            // close — but we want the close frame sent first. lws will
            // emit it via the queued lws_close_reason on the next loop.
            if (m->buf) free(m->buf);
            free(m);
            return -1;
        }

        enum lws_write_protocol wp = (m->kind == 1) ? LWS_WRITE_BINARY : LWS_WRITE_TEXT;
        int n = lws_write(wsi, m->buf + LWS_PRE, m->len, wp);
        if (n < 0) {
            ZjsWsEvent e = {0};
            e.kind = ZJS_WS_EVT_ERROR;
            e.text = strdup("websocket: lws_write failed");
            e.text_len = e.text ? strlen(e.text) : 0;
            ws_enqueue(h, e);
            free(m->buf);
            free(m);
            return -1;
        }
        free(m->buf);
        free(m);
        if (more) lws_callback_on_writable(wsi);
        break;
    }

    case LWS_CALLBACK_CLIENT_CONNECTION_ERROR: {
        if (h->conn_failed) break;
        h->conn_failed = 1;
        ZjsWsEvent e = {0};
        e.kind = ZJS_WS_EVT_ERROR;
        if (in != NULL && len > 0) {
            // lws hands us a non-NUL-terminated buffer for the error
            // reason — copy + NUL-terminate ourselves rather than
            // pulling in strndup (which needs _POSIX_C_SOURCE).
            e.text = (char*)malloc(len + 1);
            if (e.text != NULL) {
                memcpy(e.text, in, len);
                e.text[len] = '\0';
                e.text_len = len;
            }
        } else {
            e.text = strdup("websocket: connection error");
            e.text_len = e.text ? strlen(e.text) : 0;
        }
        ws_enqueue(h, e);
        // Also synthesize a CLOSE 1006 so JS-land sees the connection
        // go away even if the OPEN event never fired.
        ZjsWsEvent c = {0};
        c.kind = ZJS_WS_EVT_CLOSE;
        c.code = 1006;
        c.text = strdup("abnormal closure");
        c.text_len = c.text ? strlen(c.text) : 0;
        ws_enqueue(h, c);
        h->worker_should_exit = 1;
        break;
    }

    case LWS_CALLBACK_WS_PEER_INITIATED_CLOSE: {
        // Capture the peer's close frame *before* CLIENT_CLOSED fires
        // so we can surface the real code/reason to JS. `in` is the
        // 2-byte code (network order) followed by optional reason.
        if (in != NULL && len >= 2) {
            const unsigned char* p = (const unsigned char*)in;
            h->peer_close_code = (p[0] << 8) | p[1];
            if (len > 2) {
                size_t rl = len - 2;
                h->peer_close_reason = (char*)malloc(rl + 1);
                if (h->peer_close_reason != NULL) {
                    memcpy(h->peer_close_reason, p + 2, rl);
                    h->peer_close_reason[rl] = '\0';
                    h->peer_close_reason_len = rl;
                }
            }
        }
        h->peer_close_seen = 1;
        // Return 0 so lws echoes the close and shuts the connection
        // down cleanly. CLIENT_CLOSED will deliver our user-visible
        // CLOSE event below.
        return 0;
    }

    case LWS_CALLBACK_CLIENT_CLOSED: {
        ZjsWsEvent e = {0};
        e.kind = ZJS_WS_EVT_CLOSE;
        if (h->peer_close_seen && h->peer_close_code != 0) {
            e.code = h->peer_close_code;
            e.text = h->peer_close_reason;
            e.text_len = h->peer_close_reason_len;
            h->peer_close_reason = NULL;  // ownership transferred to event
            h->peer_close_reason_len = 0;
        } else {
            // No close frame from peer — 1005 ("no status received")
            // per RFC 6455, matching the WHATWG WebSocket spec mapping.
            e.code = 1005;
        }
        ws_enqueue(h, e);
        h->worker_should_exit = 1;
        break;
    }

    default:
        break;
    }
    return 0;
}

// EVENT_WAIT_CANCELLED fires with wsi == NULL (it's a context-wide
// event, not per-connection), so we can't get back to the handle from
// inside the callback. Instead, the worker thread re-checks the
// outgoing queue between every lws_service tick — `lws_cancel_service`
// from the main thread just wakes the service loop early, and the
// post-tick check below requests the writeable callback. Keeping
// lws_callback_on_writable invocations on the worker thread is the
// only lws-supported pattern for cross-thread sends.

// One protocol entry — named "default" because lws requires a non-NULL
// name. When the user passes subprotocols, we override `protocol` in
// the client_connect_info to a comma-joined list which lws negotiates
// against this protocol's callback.
static const struct lws_protocols protocols[] = {
    { "default", ws_callback, 0, 65536, 0, NULL, 0 },
    LWS_PROTOCOL_LIST_TERM
};

// -----------------------------------------------------------------------------
// Worker thread — owns the lws_context's service loop.
// -----------------------------------------------------------------------------

static void* ws_worker(void* arg) {
    ZjsWsHandle* h = (ZjsWsHandle*)arg;
    while (!h->worker_should_exit) {
        // 50ms gives reasonable send-latency without burning CPU.
        // lws_cancel_service from the main thread wakes us early
        // whenever new outgoing data lands.
        int rc = lws_service(h->context, 50);
        if (rc < 0) break;
        pthread_mutex_lock(&h->lock);
        int has_out = (h->out_head != NULL);
        pthread_mutex_unlock(&h->lock);
        if (has_out && h->wsi != NULL) {
            lws_callback_on_writable(h->wsi);
        }
    }
    return NULL;
}

// -----------------------------------------------------------------------------
// Public ABI
// -----------------------------------------------------------------------------

ZjsWsHandle* zjs_ws_connect(const char* url,
                            const char** user_protocols,
                            size_t protocol_count,
                            int timeout_seconds) {
    (void)timeout_seconds; // lws doesn't expose a per-connect timeout in 4.x;
                           // could wire CONNECT2 retry policy later.
    if (url == NULL) return NULL;

    ZjsWsHandle* h = (ZjsWsHandle*)calloc(1, sizeof(ZjsWsHandle));
    if (h == NULL) return NULL;
    pthread_mutex_init(&h->lock, NULL);

    // lws_parse_uri mutates its input — make a writable copy.
    h->url_buf = xstrdup_or_null(url);
    if (h->url_buf == NULL) goto fail;

    const char* prot = NULL;
    const char* host = NULL;
    int         port = 0;
    const char* path = NULL;
    if (lws_parse_uri(h->url_buf, &prot, &host, &port, &path) != 0) {
        goto fail;
    }
    int use_ssl = 0;
    if (prot != NULL) {
        if      (strcmp(prot, "wss")   == 0) use_ssl = 1;
        else if (strcmp(prot, "https") == 0) use_ssl = 1;
        else if (strcmp(prot, "ws")    != 0 && strcmp(prot, "http") != 0) goto fail;
    }
    if (host == NULL) goto fail;
    h->host_buf = xstrdup_or_null(host);
    if (h->host_buf == NULL) goto fail;

    // lws_parse_uri strips the leading '/' from the path; restore it.
    size_t plen = path ? strlen(path) : 0;
    h->path_buf = (char*)malloc(plen + 2);
    if (h->path_buf == NULL) goto fail;
    h->path_buf[0] = '/';
    if (plen > 0) memcpy(h->path_buf + 1, path, plen);
    h->path_buf[plen + 1] = '\0';

    // Build the comma-joined subprotocol list lws expects on `protocol`.
    if (user_protocols != NULL && protocol_count > 0) {
        size_t total = 0;
        for (size_t i = 0; i < protocol_count; i++) {
            if (user_protocols[i] != NULL) total += strlen(user_protocols[i]) + 2;
        }
        if (total > 0) {
            h->proto_csv = (char*)malloc(total);
            if (h->proto_csv == NULL) goto fail;
            size_t off = 0;
            for (size_t i = 0; i < protocol_count; i++) {
                if (user_protocols[i] == NULL) continue;
                size_t pl = strlen(user_protocols[i]);
                if (off > 0) {
                    h->proto_csv[off++] = ',';
                    h->proto_csv[off++] = ' ';
                }
                memcpy(h->proto_csv + off, user_protocols[i], pl);
                off += pl;
            }
            h->proto_csv[off] = '\0';
        }
    }

    struct lws_context_creation_info info;
    memset(&info, 0, sizeof info);
    info.port      = CONTEXT_PORT_NO_LISTEN;
    info.protocols = protocols;
    info.gid       = -1;
    info.uid       = -1;
    info.options   = LWS_SERVER_OPTION_DO_SSL_GLOBAL_INIT;

    h->context = lws_create_context(&info);
    if (h->context == NULL) goto fail;

    struct lws_client_connect_info ccinfo;
    memset(&ccinfo, 0, sizeof ccinfo);
    ccinfo.context        = h->context;
    ccinfo.address        = h->host_buf;
    ccinfo.port           = port;
    ccinfo.path           = h->path_buf;
    ccinfo.host           = h->host_buf;
    ccinfo.origin         = h->host_buf;
    ccinfo.protocol       = h->proto_csv;   // NULL means "no subprotocol"
    ccinfo.ssl_connection = use_ssl ? LCCSCF_USE_SSL : 0;
    ccinfo.opaque_user_data = h;

    h->wsi = lws_client_connect_via_info(&ccinfo);
    if (h->wsi == NULL) goto fail;

    if (pthread_create(&h->worker, NULL, ws_worker, h) != 0) {
        // Worker spawn failed — tear down the context. Don't try to
        // free the wsi directly; lws will release it with the context.
        lws_context_destroy(h->context);
        h->context = NULL;
        goto fail;
    }
    h->joinable = 1;
    return h;

fail:
    if (h != NULL) {
        if (h->context != NULL) lws_context_destroy(h->context);
        free(h->url_buf);
        free(h->host_buf);
        free(h->path_buf);
        free(h->proto_csv);
        pthread_mutex_destroy(&h->lock);
        free(h);
    }
    return NULL;
}

static int enqueue_outgoing(ZjsWsHandle* h, int kind,
                            const void* payload, size_t len,
                            int close_code) {
    OutMsg* m = (OutMsg*)calloc(1, sizeof(OutMsg));
    if (m == NULL) return -1;
    m->kind       = kind;
    m->len        = len;
    m->close_code = close_code;
    if (len > 0) {
        m->buf = (uint8_t*)malloc(LWS_PRE + len);
        if (m->buf == NULL) { free(m); return -1; }
        memcpy(m->buf + LWS_PRE, payload, len);
    }
    pthread_mutex_lock(&h->lock);
    if (h->out_tail) h->out_tail->next = m;
    else             h->out_head       = m;
    h->out_tail = m;
    pthread_mutex_unlock(&h->lock);

    // Wake the service loop so it processes the queue. Safe to call
    // from any thread — that's its whole reason to exist.
    if (h->context != NULL) lws_cancel_service(h->context);
    return 0;
}

int zjs_ws_send_text(ZjsWsHandle* h, const char* text, size_t len) {
    if (h == NULL || text == NULL) return -1;
    if (h->closed) return -1;
    return enqueue_outgoing(h, 0, text, len, 0);
}

int zjs_ws_send_binary(ZjsWsHandle* h, const uint8_t* bytes, size_t len) {
    if (h == NULL || bytes == NULL) return -1;
    if (h->closed) return -1;
    return enqueue_outgoing(h, 1, bytes, len, 0);
}

int zjs_ws_close(ZjsWsHandle* h, int code, const char* reason) {
    if (h == NULL) return -1;
    if (h->closed) return 0;
    h->closed = 1;
    size_t rlen = (reason != NULL) ? strlen(reason) : 0;
    return enqueue_outgoing(h, 2, reason, rlen, code);
}

int zjs_ws_poll(ZjsWsHandle* h, ZjsWsEvent* out_event) {
    if (h == NULL || out_event == NULL) return ZJS_WS_EVT_NONE;
    pthread_mutex_lock(&h->lock);
    ZjsWsEventNode* n = h->in_head;
    if (n == NULL) {
        pthread_mutex_unlock(&h->lock);
        return ZJS_WS_EVT_NONE;
    }
    h->in_head = n->next;
    if (h->in_head == NULL) h->in_tail = NULL;
    pthread_mutex_unlock(&h->lock);
    *out_event = n->evt;
    free(n);
    return out_event->kind;
}

void zjs_ws_destroy(ZjsWsHandle* h) {
    if (h == NULL) return;

    // Tell the worker to stop and wake it. lws_cancel_service is safe
    // to call from any thread.
    h->worker_should_exit = 1;
    if (h->context != NULL) lws_cancel_service(h->context);

    if (h->joinable) {
        pthread_join(h->worker, NULL);
        h->joinable = 0;
    }

    if (h->context != NULL) {
        lws_context_destroy(h->context);
        h->context = NULL;
    }

    // Drain leftover events the JS side never picked up.
    pthread_mutex_lock(&h->lock);
    ZjsWsEventNode* in = h->in_head;
    while (in != NULL) {
        ZjsWsEventNode* next = in->next;
        if (in->evt.text)   free(in->evt.text);
        if (in->evt.binary) free(in->evt.binary);
        free(in);
        in = next;
    }
    h->in_head = h->in_tail = NULL;
    OutMsg* out = h->out_head;
    while (out != NULL) {
        OutMsg* next = out->next;
        if (out->buf) free(out->buf);
        free(out);
        out = next;
    }
    h->out_head = h->out_tail = NULL;
    pthread_mutex_unlock(&h->lock);

    if (h->frag_buf)          free(h->frag_buf);
    if (h->url_buf)           free(h->url_buf);
    if (h->host_buf)          free(h->host_buf);
    if (h->path_buf)          free(h->path_buf);
    if (h->proto_csv)         free(h->proto_csv);
    if (h->peer_close_reason) free(h->peer_close_reason);
    pthread_mutex_destroy(&h->lock);
    free(h);
}
