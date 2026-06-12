// Winsock2 backend — Windows implementation of socket_native.h.
//
// Direct port of socket_posix.c's single-threaded design: one
// listening SOCKET plus an array of accepted-client SOCKETs, all
// non-blocking. zjs_net_poll() runs a single WSAPoll() with a
// 0-timeout and converts ready events into the same queued
// ZjsNetEvent list. Differences from the POSIX file are mechanical:
//   - SOCKET / INVALID_SOCKET instead of int / -1
//   - ioctlsocket(FIONBIO) instead of fcntl(O_NONBLOCK)
//   - closesocket() instead of close()
//   - WSAGetLastError()/WSAEWOULDBLOCK instead of errno/EAGAIN
//   - one-time WSAStartup on first listen
//
// Linked via `-lws2_32` (windows link directive in lib.zc/zjs.zc).

#ifdef _WIN32

#include "socket_native.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define READ_CHUNK 16384

typedef struct ClientNode {
    uint64_t id;
    SOCKET   fd;
    struct ClientNode* next;
} ClientNode;

typedef struct EventNode {
    ZjsNetEvent evt;
    struct EventNode* next;
} EventNode;

struct ZjsNetServer {
    SOCKET listen_fd;
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

static int wsa_ensure_started(void) {
    static int started = 0;
    if (started) return 1;
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 0;
    started = 1;
    return 1;
}

static void set_nonblock(SOCKET fd) {
    u_long mode = 1;
    ioctlsocket(fd, FIONBIO, &mode);
}

static void enqueue_event(ZjsNetServer* s, ZjsNetEvent ev) {
    EventNode* n = (EventNode*)calloc(1, sizeof(EventNode));
    if (!n) return;       // best-effort under OOM
    n->evt = ev;
    if (s->tail) s->tail->next = n;
    else         s->head = n;
    s->tail = n;
}

static void enqueue_error(ZjsNetServer* s, uint64_t client_id, int wsa_err) {
    ZjsNetEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.kind = ZJS_NET_EVT_ERROR;
    ev.client_id = client_id;
    char msg[64];
    snprintf(msg, sizeof(msg), "winsock error %d", wsa_err);
    size_t n = strlen(msg);
    ev.text = (char*)malloc(n + 1);
    if (ev.text) { memcpy(ev.text, msg, n + 1); ev.text_len = n; }
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
            if (doomed->fd != INVALID_SOCKET) closesocket(doomed->fd);
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
    if (!wsa_ensure_started()) return NULL;

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

    SOCKET fd = INVALID_SOCKET;
    struct addrinfo* ai = NULL;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd == INVALID_SOCKET) continue;
        // Note: SO_REUSEADDR on Windows allows port hijacking (unlike
        // POSIX, where it only skips TIME_WAIT). SO_EXCLUSIVEADDRUSE
        // is the safe equivalent of the POSIX default.
        int excl = 1;
        setsockopt(fd, SOL_SOCKET, SO_EXCLUSIVEADDRUSE,
                   (const char*)&excl, sizeof(excl));
        if (bind(fd, ai->ai_addr, (int)ai->ai_addrlen) == 0) break;
        closesocket(fd);
        fd = INVALID_SOCKET;
    }
    freeaddrinfo(res);
    if (fd == INVALID_SOCKET) return NULL;

    if (listen(fd, backlog) != 0) {
        closesocket(fd);
        return NULL;
    }
    set_nonblock(fd);

    // Read back the assigned port (covers port=0 ephemeral case).
    int assigned_port = port;
    struct sockaddr_storage local;
    int local_len = sizeof(local);
    if (getsockname(fd, (struct sockaddr*)&local, &local_len) == 0) {
        if (local.ss_family == AF_INET) {
            assigned_port = ntohs(((struct sockaddr_in*)&local)->sin_port);
        } else if (local.ss_family == AF_INET6) {
            assigned_port = ntohs(((struct sockaddr_in6*)&local)->sin6_port);
        }
    }

    ZjsNetServer* s = (ZjsNetServer*)calloc(1, sizeof(ZjsNetServer));
    if (!s) { closesocket(fd); return NULL; }
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
    WSAPOLLFD* pfds = (WSAPOLLFD*)calloc((size_t)count, sizeof(WSAPOLLFD));
    if (!pfds) return;

    pfds[0].fd = s->listen_fd;
    pfds[0].events = POLLRDNORM;
    int idx = 1;
    for (ClientNode* c = s->clients; c; c = c->next) {
        pfds[idx].fd = c->fd;
        pfds[idx].events = POLLRDNORM;
        idx++;
    }

    int pr = WSAPoll(pfds, (ULONG)count, 0);
    if (pr <= 0) { free(pfds); return; }

    // 1. New connections on the listening socket.
    if (pfds[0].revents & POLLRDNORM) {
        for (;;) {
            struct sockaddr_storage addr;
            int addr_len = sizeof(addr);
            SOCKET cfd = accept(s->listen_fd, (struct sockaddr*)&addr, &addr_len);
            if (cfd == INVALID_SOCKET) {
                int e = WSAGetLastError();
                if (e == WSAEWOULDBLOCK) break;
                enqueue_error(s, 0, e);
                break;
            }
            set_nonblock(cfd);

            uint64_t id = s->next_client_id++;
            ClientNode* node = (ClientNode*)calloc(1, sizeof(ClientNode));
            if (!node) { closesocket(cfd); continue; }
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

    // 2. Per-client reads / closes. Same list-order assumption as the
    //    POSIX backend: clients accepted in step 1 sit at the head and
    //    weren't in this pfd batch.
    idx = 1;
    for (ClientNode* c = s->clients; c; c = c->next) {
        if (idx >= count) break;
        if (pfds[idx].fd != c->fd) { /* list order stable through this fn */ }
        SHORT revents = pfds[idx].revents;
        idx++;

        if ((revents & (POLLRDNORM | POLLHUP | POLLERR)) == 0) continue;

        // Drain readable bytes. POLLHUP without data means EOF; we
        // discover it as recv()==0 below.
        for (;;) {
            char buf[READ_CHUNK];
            int n = recv(c->fd, buf, (int)sizeof(buf), 0);
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
                // Can't remove c mid-iteration — mark and reap on the
                // CLOSE delivery in zjs_net_poll, like the POSIX file.
                if (c->fd != INVALID_SOCKET) { closesocket(c->fd); c->fd = INVALID_SOCKET; }
                break;
            } else {
                int e = WSAGetLastError();
                if (e == WSAEWOULDBLOCK) break;
                // Hard reset (WSAECONNRESET etc.) → surface as CLOSE
                // after the error so JS tears the socket down.
                enqueue_error(s, c->id, e);
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
    // next pump() doesn't keep polling its socket.
    if (out_event->kind == ZJS_NET_EVT_CLOSE) {
        remove_client(s, out_event->client_id);
    }

    return out_event->kind;
}

int zjs_net_send(ZjsNetServer* s, uint64_t client_id, const uint8_t* buf, size_t len) {
    if (!s) return -1;
    ClientNode* c = find_client(s, client_id);
    if (!c || c->fd == INVALID_SOCKET) return -1;

    size_t total = 0;
    while (total < len) {
        int n = send(c->fd, (const char*)buf + total, (int)(len - total), 0);
        if (n > 0) { total += (size_t)n; continue; }
        if (n == SOCKET_ERROR && WSAGetLastError() == WSAEWOULDBLOCK) {
            // Buffer full — caller can re-call later. Report partial.
            break;
        }
        return -1;
    }
    return (int)total;
}

int zjs_net_close_client(ZjsNetServer* s, uint64_t client_id) {
    if (!s) return -1;
    ClientNode* c = find_client(s, client_id);
    if (!c) return -1;
    if (c->fd != INVALID_SOCKET) {
        shutdown(c->fd, SD_BOTH);
        closesocket(c->fd);
        c->fd = INVALID_SOCKET;
    }
    // Deliver the CLOSE eagerly so JS sees it even if no more I/O fires.
    ZjsNetEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.kind = ZJS_NET_EVT_CLOSE;
    ev.client_id = client_id;
    enqueue_event(s, ev);
    return 0;
}

void zjs_net_destroy(ZjsNetServer* s) {
    if (!s) return;
    if (s->listen_fd != INVALID_SOCKET) closesocket(s->listen_fd);
    ClientNode* c = s->clients;
    while (c) {
        ClientNode* nxt = c->next;
        if (c->fd != INVALID_SOCKET) closesocket(c->fd);
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

#endif // _WIN32
