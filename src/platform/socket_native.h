// Pluggable native TCP-socket backend — drives node:net + node:http.
//
//   Apple   — POSIX BSD sockets (socket_posix.c)
//   iOS     — same (POSIX inside the app sandbox)
//   Linux   — same
//   Windows — Winsock2 (socket_windows.c)
//
// Single-threaded design: each Server owns a listening fd + a list of
// accepted-client fds, all non-blocking. JS drains events on every
// event-loop tick via zjs_net_poll. No background threads — keeps
// memory ordering simple and matches how the WebSocket Apple backend
// integrates into the same tick.

#ifndef ZJS_SOCKET_NATIVE_H
#define ZJS_SOCKET_NATIVE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZjsNetServer ZjsNetServer;

// Event kinds returned by zjs_net_poll. Multiple events may be drained
// per tick; the caller loops until ZJS_NET_EVT_NONE.
typedef enum {
    ZJS_NET_EVT_NONE       = 0,
    ZJS_NET_EVT_ACCEPT     = 1,  // new client; client_id populated
    ZJS_NET_EVT_DATA       = 2,  // bytes available; client_id + binary + binary_len
    ZJS_NET_EVT_CLOSE      = 3,  // peer closed; client_id
    ZJS_NET_EVT_ERROR      = 4,  // socket-level error; client_id (0 = server-level)
                                 // text is malloc'd; caller frees
    ZJS_NET_EVT_LISTENING  = 5,  // bind+listen succeeded (once per server)
} ZjsNetEventKind;

typedef struct {
    int        kind;          // ZjsNetEventKind
    uint64_t   client_id;     // 0 = server-level event; non-zero = per-client
    uint8_t*   binary;        // for DATA — malloc'd, caller frees
    size_t     binary_len;
    char*      text;          // for ERROR — malloc'd, caller frees
    size_t     text_len;
    char       peer_addr[48]; // for ACCEPT — IPv4/IPv6 numeric string
    int        peer_port;     // for ACCEPT
} ZjsNetEvent;

// Open a listening socket. `host` may be NULL (binds to 0.0.0.0) or
// "127.0.0.1" / "0.0.0.0" / "::" / ip-literal etc. Port 0 picks an
// ephemeral port — read it back via zjs_net_server_port() after
// LISTENING fires. Returns NULL on bind/listen failure.
//
// Backlog is the listen() argument; pass 0 for the platform default.
ZjsNetServer* zjs_net_listen(const char* host, int port, int backlog);

// Read back the OS-assigned port (useful for port=0). Returns the
// actual listening port, or 0 if not yet listening.
int zjs_net_server_port(ZjsNetServer* s);

// Drain one event from the server's queue. Returns ZJS_NET_EVT_NONE
// when the queue is empty. Caller must free `text` / `binary` if set.
int zjs_net_poll(ZjsNetServer* s, ZjsNetEvent* out_event);

// Send bytes to a specific client. Returns the number of bytes
// queued for send (may be less than `len` on partial), or -1 on
// error (closed client, etc.).
int zjs_net_send(ZjsNetServer* s, uint64_t client_id, const uint8_t* buf, size_t len);

// Half-close (or fully close) a client connection. After this returns
// the server will deliver a CLOSE event for the client; the id stays
// reserved until the JS handle is GC'd.
int zjs_net_close_client(ZjsNetServer* s, uint64_t client_id);

// Stop listening, close all clients, free the server. Safe to call
// once per handle. Pending events are discarded.
void zjs_net_destroy(ZjsNetServer* s);

#ifdef __cplusplus
}
#endif

#endif
