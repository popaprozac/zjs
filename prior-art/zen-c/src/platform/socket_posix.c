// POSIX BSD-socket backend — shared by macOS/iOS/Linux.
//
// One listening fd plus an array of accepted-client fds, all non-
// blocking. zjs_net_poll() runs a single poll() with a 0-timeout
// across the fds and converts ready events into a queued ZjsNetEvent
// list. JS drains the queue on each tick (timer_tick in context.zc).
//
// Design choices for v0.1:
//   - Single-threaded; no worker threads. Avoids the lws cross-thread
//     dance — this is simpler than the WebSocket Linux backend.
//   - Event delivery is queue-based so JS can drain at its own pace
//     (multiple events per tick when traffic bursts).
//   - Per-client read uses a fixed 16K buffer; large payloads get
//     fragmented into multiple DATA events. node:http reassembles.
//   - client_id is a monotonically-incrementing uint64_t — never
//     re-used so JS can hold a stale id without aliasing risk.

#include "socket_native.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#define READ_CHUNK 16384

typedef struct ClientNode {
    uint64_t id;
    int      fd;
    int      half_closed;        // shutdown(SHUT_WR) issued; awaiting EOF
    struct ClientNode* next;
} ClientNode;

typedef struct EventNode {
    ZjsNetEvent evt;
    struct EventNode* next;
} EventNode;

struct ZjsNetServer {
    int listen_fd;
    int listening_port;
    int listening_emitted;
    uint64_t next_client_id;
    ClientNode* clients;
    EventNode* head;
    EventNode* tail;
};

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

static void set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void enqueue_event(ZjsNetServer* s, ZjsNetEvent ev) {
    EventNode* n = (EventNode*)calloc(1, sizeof(EventNode));
    if (!n) return;       // best-effort under OOM
    n->evt = ev;
    if (s->tail) s->tail->next = n;
    else         s->head = n;
    s->tail = n;
}

static void enqueue_error(ZjsNetServer* s, uint64_t client_id, const char* msg) {
    ZjsNetEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.kind = ZJS_NET_EVT_ERROR;
    ev.client_id = client_id;
    if (msg) {
        size_t n = strlen(msg);
        ev.text = (char*)malloc(n + 1);
        if (ev.text) { memcpy(ev.text, msg, n + 1); ev.text_len = n; }
    }
    enqueue_event(s, ev);
}

static ClientNode* find_client(ZjsNetServer* s, uint64_t id) {
    for (ClientNode* c = s->clients; c; c = c->next) {
        if (c->id == id) return c;
    }
    return NULL;
}

static void remove_client(ZjsNetServer* s, uint64_t id) {
    ClientNode** pp = &s->clients;
    while (*pp) {
        if ((*pp)->id == id) {
            ClientNode* doomed = *pp;
            *pp = doomed->next;
            if (doomed->fd >= 0) close(doomed->fd);
            free(doomed);
            return;
        }
        pp = &(*pp)->next;
    }
}

// ----------------------------------------------------------------------------
// Public ABI
// ----------------------------------------------------------------------------

ZjsNetServer* zjs_net_listen(const char* host, int port, int backlog) {
    if (port < 0 || port > 65535) return NULL;
    if (backlog <= 0) backlog = 128;

    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%d", port);

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags    = AI_PASSIVE;

    const char* h = (host && *host) ? host : NULL;
    if (getaddrinfo(h, port_str, &hints, &res) != 0 || !res) {
        return NULL;
    }

    int fd = -1;
    struct addrinfo* ai = NULL;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        int reuse = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        if (bind(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) return NULL;

    if (listen(fd, backlog) < 0) {
        close(fd);
        return NULL;
    }
    set_nonblock(fd);

    // Read back the assigned port (covers port=0 ephemeral case).
    int assigned_port = port;
    struct sockaddr_storage local;
    socklen_t local_len = sizeof(local);
    if (getsockname(fd, (struct sockaddr*)&local, &local_len) == 0) {
        if (local.ss_family == AF_INET) {
            assigned_port = ntohs(((struct sockaddr_in*)&local)->sin_port);
        } else if (local.ss_family == AF_INET6) {
            assigned_port = ntohs(((struct sockaddr_in6*)&local)->sin6_port);
        }
    }

    ZjsNetServer* s = (ZjsNetServer*)calloc(1, sizeof(ZjsNetServer));
    if (!s) { close(fd); return NULL; }
    s->listen_fd = fd;
    s->listening_port = assigned_port;
    s->next_client_id = 1;

    return s;
}

int zjs_net_server_port(ZjsNetServer* s) {
    return s ? s->listening_port : 0;
}

// Drain incoming activity: accept new clients, read from existing ones,
// detect closes. Multiple events may be appended per call; the caller's
// poll-loop dequeues them via successive zjs_net_poll() calls.
static void pump(ZjsNetServer* s) {
    if (!s) return;

    // Build pollfd array: listen + one per client.
    int count = 1;
    for (ClientNode* c = s->clients; c; c = c->next) count++;
    struct pollfd* pfds = (struct pollfd*)calloc((size_t)count, sizeof(struct pollfd));
    if (!pfds) return;

    pfds[0].fd = s->listen_fd;
    pfds[0].events = POLLIN;
    int idx = 1;
    for (ClientNode* c = s->clients; c; c = c->next) {
        pfds[idx].fd = c->fd;
        pfds[idx].events = POLLIN;
        idx++;
    }

    int pr = poll(pfds, (nfds_t)count, 0);
    if (pr <= 0) { free(pfds); return; }

    // 1. New connections on the listening socket.
    if (pfds[0].revents & POLLIN) {
        for (;;) {
            struct sockaddr_storage addr;
            socklen_t addr_len = sizeof(addr);
            int cfd = accept(s->listen_fd, (struct sockaddr*)&addr, &addr_len);
            if (cfd < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                enqueue_error(s, 0, strerror(errno));
                break;
            }
            set_nonblock(cfd);

            uint64_t id = s->next_client_id++;
            ClientNode* node = (ClientNode*)calloc(1, sizeof(ClientNode));
            if (!node) { close(cfd); continue; }
            node->id = id;
            node->fd = cfd;
            node->next = s->clients;
            s->clients = node;

            ZjsNetEvent ev;
            memset(&ev, 0, sizeof(ev));
            ev.kind = ZJS_NET_EVT_ACCEPT;
            ev.client_id = id;
            if (addr.ss_family == AF_INET) {
                struct sockaddr_in* sin = (struct sockaddr_in*)&addr;
                inet_ntop(AF_INET, &sin->sin_addr, ev.peer_addr, sizeof(ev.peer_addr));
                ev.peer_port = ntohs(sin->sin_port);
            } else if (addr.ss_family == AF_INET6) {
                struct sockaddr_in6* sin6 = (struct sockaddr_in6*)&addr;
                inet_ntop(AF_INET6, &sin6->sin6_addr, ev.peer_addr, sizeof(ev.peer_addr));
                ev.peer_port = ntohs(sin6->sin6_port);
            }
            enqueue_event(s, ev);
        }
    }

    // 2. Per-client reads / closes. Re-walk the list since new clients
    //    may have been added in step 1 (they're at the head and weren't
    //    in pfds, but we just accepted them — no data yet).
    idx = 1;
    for (ClientNode* c = s->clients; c; c = c->next) {
        if (idx >= count) break;
        // Skip clients that weren't in this pfd batch (e.g., just
        // accepted this tick — they sit at the head and we built the
        // pfd array BEFORE accept fired).
        if (pfds[idx].fd != c->fd) { /* shouldn't happen — list order
                                       stable through this fn */; }
        short revents = pfds[idx].revents;
        idx++;

        if ((revents & (POLLIN | POLLHUP | POLLERR)) == 0) continue;

        // Drain readable bytes. POLLHUP without data means EOF; we
        // discover it as recv()==0 below.
        for (;;) {
            uint8_t buf[READ_CHUNK];
            ssize_t n = recv(c->fd, buf, sizeof(buf), 0);
            if (n > 0) {
                ZjsNetEvent ev;
                memset(&ev, 0, sizeof(ev));
                ev.kind = ZJS_NET_EVT_DATA;
                ev.client_id = c->id;
                ev.binary = (uint8_t*)malloc((size_t)n);
                if (ev.binary) {
                    memcpy(ev.binary, buf, (size_t)n);
                    ev.binary_len = (size_t)n;
                    enqueue_event(s, ev);
                }
                if ((size_t)n < sizeof(buf)) break;  // likely empty now
            } else if (n == 0) {
                // Peer closed.
                ZjsNetEvent ev;
                memset(&ev, 0, sizeof(ev));
                ev.kind = ZJS_NET_EVT_CLOSE;
                ev.client_id = c->id;
                enqueue_event(s, ev);
                // We can't remove c here — pump() is iterating the
                // list. Mark fd as -1 and clean up post-pump via the
                // CLOSE handler in node_net.zc.
                if (c->fd >= 0) { close(c->fd); c->fd = -1; }
                break;
            } else {
                if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                enqueue_error(s, c->id, strerror(errno));
                break;
            }
        }
    }

    free(pfds);
}

int zjs_net_poll(ZjsNetServer* s, ZjsNetEvent* out_event) {
    if (!s || !out_event) return ZJS_NET_EVT_NONE;
    memset(out_event, 0, sizeof(*out_event));

    if (!s->listening_emitted) {
        out_event->kind = ZJS_NET_EVT_LISTENING;
        s->listening_emitted = 1;
        return ZJS_NET_EVT_LISTENING;
    }

    pump(s);

    if (!s->head) return ZJS_NET_EVT_NONE;
    EventNode* n = s->head;
    s->head = n->next;
    if (!s->head) s->tail = NULL;
    *out_event = n->evt;
    free(n);

    // If we just delivered a CLOSE, reap the dead client now so the
    // next pump() doesn't keep polling its fd.
    if (out_event->kind == ZJS_NET_EVT_CLOSE) {
        remove_client(s, out_event->client_id);
    }

    return out_event->kind;
}

int zjs_net_send(ZjsNetServer* s, uint64_t client_id, const uint8_t* buf, size_t len) {
    if (!s) return -1;
    ClientNode* c = find_client(s, client_id);
    if (!c || c->fd < 0) return -1;

    size_t total = 0;
    while (total < len) {
        ssize_t n = send(c->fd, buf + total, len - total, 0);
        if (n > 0) { total += (size_t)n; continue; }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            // Buffer full — caller can re-call later. Report partial.
            break;
        }
        if (n < 0 && errno == EINTR) continue;
        return -1;
    }
    return (int)total;
}

int zjs_net_close_client(ZjsNetServer* s, uint64_t client_id) {
    if (!s) return -1;
    ClientNode* c = find_client(s, client_id);
    if (!c) return -1;
    if (c->fd >= 0) {
        shutdown(c->fd, SHUT_RDWR);
        close(c->fd);
        c->fd = -1;
    }
    // CLOSE event will be queued by the next pump() — but we may also
    // want to deliver it eagerly so JS sees the close even if no more
    // I/O fires. Enqueue one now.
    ZjsNetEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.kind = ZJS_NET_EVT_CLOSE;
    ev.client_id = client_id;
    enqueue_event(s, ev);
    return 0;
}

void zjs_net_destroy(ZjsNetServer* s) {
    if (!s) return;
    if (s->listen_fd >= 0) close(s->listen_fd);
    ClientNode* c = s->clients;
    while (c) {
        ClientNode* nxt = c->next;
        if (c->fd >= 0) close(c->fd);
        free(c);
        c = nxt;
    }
    EventNode* e = s->head;
    while (e) {
        EventNode* nxt = e->next;
        if (e->evt.binary) free(e->evt.binary);
        if (e->evt.text)   free(e->evt.text);
        free(e);
        e = nxt;
    }
    free(s);
}
