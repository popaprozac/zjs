// Async ABI for non-Apple platforms — pthread wrapper around the
// platform's zjs_http_request_sync. Apple has its own native async
// impl in http_apple.m (no extra thread), so this file is NOT
// compiled into the Apple builds.
//
// One pthread per in-flight request: the worker runs the sync call,
// stashes the result under a mutex, and exits. The engine polls
// per-tick via zjs_http_request_poll.

#include "http_native.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct ZjsHttpHandle {
    pthread_t       worker;
    int             joinable;
    pthread_mutex_t lock;
    int             state;        // 0=pending 1=done -1=err
    int             cancelled;
    // Owned copies of caller inputs so they outlive `start`.
    char*           method;
    char*           url;
    char**          req_headers;
    size_t          req_header_count;
    char*           body;
    size_t          body_len;
    int             timeout_seconds;
    // Outputs.
    ZjsHttpResponse resp;
    char*           err;
};

static char* xstrdup(const char* s) {
    if (s == NULL) return NULL;
    size_t n = strlen(s) + 1;
    char* p = (char*)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

static void* http_worker(void* arg) {
    ZjsHttpHandle* h = (ZjsHttpHandle*)arg;
    ZjsHttpRequest req;
    req.method           = h->method;
    req.url              = h->url;
    req.req_headers      = (const char**)h->req_headers;
    req.req_header_count = h->req_header_count;
    req.body             = h->body;
    req.body_len         = h->body_len;
    req.timeout_seconds  = h->timeout_seconds;
    ZjsHttpResponse resp = {0};
    char* err = NULL;
    int rc = zjs_http_request_sync(&req, &resp, &err);
    pthread_mutex_lock(&h->lock);
    if (h->cancelled) {
        pthread_mutex_unlock(&h->lock);
        zjs_http_response_free(&resp);
        if (err) free(err);
        return NULL;
    }
    if (rc == 0) { h->resp = resp; h->state = 1; }
    else         { h->err  = err;  h->state = -1; }
    pthread_mutex_unlock(&h->lock);
    return NULL;
}

ZjsHttpHandle* zjs_http_request_start(const ZjsHttpRequest* req) {
    if (req == NULL || req->url == NULL) return NULL;
    ZjsHttpHandle* h = (ZjsHttpHandle*)calloc(1, sizeof(ZjsHttpHandle));
    if (h == NULL) return NULL;
    pthread_mutex_init(&h->lock, NULL);
    h->method = xstrdup(req->method ? req->method : "GET");
    h->url    = xstrdup(req->url);
    h->timeout_seconds = req->timeout_seconds;
    if (req->req_header_count > 0 && req->req_headers != NULL) {
        size_t n = req->req_header_count * 2;
        h->req_headers = (char**)calloc(n, sizeof(char*));
        for (size_t i = 0; i < n; i++) {
            h->req_headers[i] = xstrdup(req->req_headers[i]);
        }
        h->req_header_count = req->req_header_count;
    }
    if (req->body_len > 0 && req->body != NULL) {
        h->body = (char*)malloc(req->body_len);
        memcpy(h->body, req->body, req->body_len);
        h->body_len = req->body_len;
    }
    if (pthread_create(&h->worker, NULL, http_worker, h) != 0) {
        zjs_http_request_destroy(h);
        return NULL;
    }
    h->joinable = 1;
    return h;
}

int zjs_http_request_poll(ZjsHttpHandle* h, ZjsHttpResponse* out_resp, char** err_out) {
    if (h == NULL || out_resp == NULL) return -1;
    pthread_mutex_lock(&h->lock);
    int state = h->state;
    if (state == 0) { pthread_mutex_unlock(&h->lock); return 0; }
    if (state == 1) {
        *out_resp = h->resp;
        h->resp.body = NULL; h->resp.resp_headers = NULL;
        h->resp.body_len = 0; h->resp.resp_header_count = 0;
        h->resp.status = 0;
    } else {
        if (err_out) *err_out = h->err;
        h->err = NULL;
    }
    pthread_mutex_unlock(&h->lock);
    if (h->joinable) { pthread_join(h->worker, NULL); h->joinable = 0; }
    return (state == 1) ? 1 : -1;
}

void zjs_http_request_destroy(ZjsHttpHandle* h) {
    if (h == NULL) return;
    pthread_mutex_lock(&h->lock);
    h->cancelled = 1;
    int joinable = h->joinable;
    pthread_mutex_unlock(&h->lock);
    if (joinable) { pthread_join(h->worker, NULL); h->joinable = 0; }
    zjs_http_response_free(&h->resp);
    if (h->err) free(h->err);
    if (h->method) free(h->method);
    if (h->url) free(h->url);
    if (h->body) free(h->body);
    if (h->req_headers) {
        size_t n = h->req_header_count * 2;
        for (size_t i = 0; i < n; i++) {
            if (h->req_headers[i]) free(h->req_headers[i]);
        }
        free(h->req_headers);
    }
    pthread_mutex_destroy(&h->lock);
    free(h);
}
