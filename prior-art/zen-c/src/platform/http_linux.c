// Linux-native HTTP backend — libcurl (easy interface).
//
// Mirrors src/platform/http_apple.m / http_windows.c on top of libcurl.
// libcurl gives us HTTPS, HTTP/2 (when built against nghttp2), proxy
// detection, IPv6, and cert validation against the system trust store
// — same "platform-native HTTP stack does crypto + policy for us"
// trade-off the other two backends make.
//
// Linked via `-lcurl` (set in the `//> linux: cflags:` build directives
// at the top of every entry point that imports the engine).
//
// Threading note: this file is compiled alongside http_async.c, which
// spawns one pthread per in-flight request and calls into us through
// zjs_http_request_sync. libcurl's per-easy-handle API is thread-safe
// (each thread owns its handle) and curl_global_init is gated through
// pthread_once so Promise.all of N fetches doesn't race the global
// state init.

#include "http_native.h"
#include <curl/curl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// curl_global_init is documented as thread-unsafe — serialize the very
// first call. After it returns, libcurl is safe to use concurrently
// from multiple threads as long as each thread owns its easy handle.
static pthread_once_t s_curl_init_once = PTHREAD_ONCE_INIT;
static void curl_global_init_once(void) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
}

// Growable byte buffer for the response body. Amortized doubling keeps
// realloc cost O(N) across libcurl's chunked deliveries.
typedef struct {
    char*  data;
    size_t len;
    size_t cap;
    int    oom;
} BodyBuf;

static size_t body_write_cb(char* ptr, size_t size, size_t nmemb, void* userdata) {
    BodyBuf* b = (BodyBuf*)userdata;
    size_t n = size * nmemb;
    if (n == 0) return 0;
    if (b->len + n + 1 > b->cap) {
        size_t new_cap = b->cap ? b->cap * 2 : 4096;
        while (new_cap < b->len + n + 1) new_cap *= 2;
        char* grown = (char*)realloc(b->data, new_cap);
        if (grown == NULL) { b->oom = 1; return 0; }
        b->data = grown;
        b->cap  = new_cap;
    }
    memcpy(b->data + b->len, ptr, n);
    b->len += n;
    return n;
}

// Singly-linked list of headers we collect during the request. libcurl
// fires the header callback once per header line *per response* — on
// a redirect chain that means we'd otherwise concatenate the 302's
// headers with the final 200's. Reset the accumulator each time we see
// a new HTTP/* status line so only the final response survives.
typedef struct HdrNode {
    char*           name;
    char*           value;
    struct HdrNode* next;
} HdrNode;

typedef struct {
    HdrNode* head;
    HdrNode* tail;
    size_t   count;
} HdrList;

static void hdr_list_free(HdrList* l) {
    HdrNode* n = l->head;
    while (n != NULL) {
        HdrNode* nx = n->next;
        free(n->name);
        free(n->value);
        free(n);
        n = nx;
    }
    l->head = l->tail = NULL;
    l->count = 0;
}

static int hdr_list_append(HdrList* l, const char* name, size_t nlen,
                                       const char* value, size_t vlen) {
    HdrNode* n = (HdrNode*)calloc(1, sizeof(HdrNode));
    if (n == NULL) return -1;
    n->name  = (char*)malloc(nlen + 1);
    n->value = (char*)malloc(vlen + 1);
    if (n->name == NULL || n->value == NULL) {
        free(n->name); free(n->value); free(n);
        return -1;
    }
    memcpy(n->name,  name,  nlen);  n->name[nlen]  = '\0';
    memcpy(n->value, value, vlen);  n->value[vlen] = '\0';
    if (l->tail != NULL) l->tail->next = n;
    else                  l->head      = n;
    l->tail = n;
    l->count++;
    return 0;
}

static size_t header_cb(char* buf, size_t size, size_t nitems, void* userdata) {
    HdrList* l = (HdrList*)userdata;
    size_t n = size * nitems;
    if (n == 0) return 0;

    // Strip trailing CRLF.
    size_t end = n;
    while (end > 0 && (buf[end - 1] == '\r' || buf[end - 1] == '\n')) end--;
    if (end == 0) return n;  // empty line — header/body separator

    // Status line (`HTTP/1.1 200 OK`, `HTTP/2 200`, etc.) — reset
    // accumulator so we only keep the final response's headers.
    if (end >= 5 && memcmp(buf, "HTTP/", 5) == 0) {
        hdr_list_free(l);
        return n;
    }

    // Parse "Name: Value". Folded continuation lines (leading SP/HT)
    // are rare in modern HTTP and we drop them — matches what the
    // Apple/Windows backends end up doing.
    size_t colon = 0;
    while (colon < end && buf[colon] != ':') colon++;
    if (colon == end || colon == 0) return n;  // malformed, ignore

    size_t v_start = colon + 1;
    while (v_start < end && (buf[v_start] == ' ' || buf[v_start] == '\t')) v_start++;

    (void)hdr_list_append(l, buf, colon, buf + v_start, end - v_start);
    return n;
}

static char* format_curl_error(const char* op, CURLcode code, const char* errbuf) {
    const char* msg = (errbuf != NULL && errbuf[0] != '\0')
                      ? errbuf
                      : curl_easy_strerror(code);
    if (msg == NULL) msg = "";
    const char* op_s = (op != NULL) ? op : "request";
    size_t need = 64 + strlen(op_s) + strlen(msg);
    char* out = (char*)malloc(need);
    if (out == NULL) {
        char* fb = (char*)malloc(32);
        if (fb != NULL) strcpy(fb, "fetch: out of memory");
        return fb;
    }
    snprintf(out, need, "fetch: %s failed (libcurl error %d): %s",
             op_s, (int)code, msg);
    return out;
}

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
    if (resp != NULL) {
        resp->status = 0;
        resp->body = NULL;
        resp->body_len = 0;
        resp->resp_headers = NULL;
        resp->resp_header_count = 0;
    }
    if (err_out) *err_out = NULL;

    if (req == NULL || req->url == NULL) {
        if (err_out) *err_out = strdup("fetch: missing url");
        return -1;
    }

    pthread_once(&s_curl_init_once, curl_global_init_once);

    CURL* curl = curl_easy_init();
    if (curl == NULL) {
        if (err_out) *err_out = strdup("fetch: curl_easy_init failed");
        return -1;
    }

    int rc = -1;
    BodyBuf body = {0};
    HdrList hdrs = {0};
    struct curl_slist* slist = NULL;
    char errbuf[CURL_ERROR_SIZE];
    errbuf[0] = '\0';

    curl_easy_setopt(curl, CURLOPT_URL,            req->url);
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER,    errbuf);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS,      10L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL,       1L);  // safe in threads
    curl_easy_setopt(curl, CURLOPT_USERAGENT,      "zjs/0.0.1");
    // Advertise gzip/deflate (and br if libcurl was built against
    // libbrotli) — empty string means "all libcurl supports". Matches
    // NSURLSession / WinHTTP, which both decompress transparently.
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    // Restrict to http(s) — protects against `file://`/`gopher://`
    // smuggling through user-supplied URLs.
#if LIBCURL_VERSION_NUM >= 0x075500
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR,        "http,https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR,  "http,https");
#else
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS,
                     (long)(CURLPROTO_HTTP | CURLPROTO_HTTPS));
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS,
                     (long)(CURLPROTO_HTTP | CURLPROTO_HTTPS));
#endif

    int timeout = (req->timeout_seconds > 0) ? req->timeout_seconds : 30;
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, (long)timeout);

    const char* method = (req->method && req->method[0]) ? req->method : "GET";
    if (strcmp(method, "GET") == 0) {
        curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
    } else if (strcmp(method, "HEAD") == 0) {
        curl_easy_setopt(curl, CURLOPT_NOBODY, 1L);
    } else if (strcmp(method, "POST") == 0) {
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
    } else {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
    }

    if (req->body != NULL && req->body_len > 0) {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS,         req->body);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE,
                         (curl_off_t)req->body_len);
    } else if (strcmp(method, "POST") == 0 || strcmp(method, "PUT") == 0) {
        // Method expects a body but caller didn't supply one — set an
        // explicit empty body so libcurl emits "Content-Length: 0"
        // instead of chunked.
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS,         "");
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)0);
    }

    if (req->req_headers != NULL && req->req_header_count > 0) {
        for (size_t i = 0; i < req->req_header_count; i++) {
            const char* name  = req->req_headers[2*i];
            const char* value = req->req_headers[2*i + 1];
            if (name == NULL || value == NULL) continue;
            size_t nl = strlen(name);
            size_t vl = strlen(value);
            char* line = (char*)malloc(nl + 2 + vl + 1);
            if (line == NULL) {
                if (err_out) *err_out = strdup("fetch: out of memory");
                goto done;
            }
            memcpy(line, name, nl);
            line[nl]     = ':';
            line[nl + 1] = ' ';
            memcpy(line + nl + 2, value, vl);
            line[nl + 2 + vl] = '\0';
            struct curl_slist* nxt = curl_slist_append(slist, line);
            free(line);
            if (nxt == NULL) {
                if (err_out) *err_out = strdup("fetch: curl_slist_append failed");
                goto done;
            }
            slist = nxt;
        }
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, slist);
    }

    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION,  body_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA,      &body);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, header_cb);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA,     &hdrs);

    CURLcode cr = curl_easy_perform(curl);
    if (cr != CURLE_OK) {
        if (err_out) *err_out = format_curl_error("request", cr, errbuf);
        goto done;
    }
    if (body.oom) {
        if (err_out) *err_out = strdup("fetch: out of memory reading response body");
        goto done;
    }

    long status_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status_code);
    resp->status = (int)status_code;

    if (body.len > 0) {
        resp->body     = body.data;
        resp->body_len = body.len;
        body.data      = NULL;  // ownership transferred
    }

    if (hdrs.count > 0) {
        char** flat = (char**)calloc(hdrs.count * 2, sizeof(char*));
        if (flat != NULL) {
            size_t i = 0;
            for (HdrNode* n = hdrs.head; n != NULL; n = n->next, i++) {
                flat[i * 2]     = n->name;   n->name  = NULL;  // transfer
                flat[i * 2 + 1] = n->value;  n->value = NULL;
            }
            resp->resp_headers      = flat;
            resp->resp_header_count = hdrs.count;
        }
    }

    rc = 0;

done:
    if (slist != NULL) curl_slist_free_all(slist);
    if (curl  != NULL) curl_easy_cleanup(curl);
    if (body.data != NULL) free(body.data);
    hdr_list_free(&hdrs);

    if (rc != 0) {
        zjs_http_response_free(resp);
        return -1;
    }
    return 0;
}
