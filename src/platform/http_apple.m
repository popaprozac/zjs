// Apple-native HTTP backend — NSURLSession.
//
// Synchronous wrapper around NSURLSession's async API; we wait on a
// dispatch semaphore so the caller can stay on its own thread without
// having to integrate with the runloop. fetch() is documented as
// synchronous at v0.1 so this matches the engine's promise.
//
// HTTPS / HTTP/2 / proxy detection / IPv6 / system trust store all
// come for free from Foundation — that's the whole point of going
// platform-native. Linked via -framework Foundation in src/lib.zc's
// build directives.

#import <Foundation/Foundation.h>
#include "http_native.h"
#include <stdlib.h>
#include <string.h>

static char* dup_cstring_from_nsstring(NSString* s) {
    if (s == nil) return strdup("");
    const char* utf8 = [s UTF8String];
    return strdup(utf8 ? utf8 : "");
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

    @autoreleasepool {
        NSString* urlStr = [NSString stringWithUTF8String:req->url];
        NSURL* nsurl = [NSURL URLWithString:urlStr];
        if (nsurl == nil) {
            if (err_out) *err_out = strdup("fetch: invalid URL");
            return -1;
        }

        int timeout = (req->timeout_seconds > 0) ? req->timeout_seconds : 30;
        NSMutableURLRequest* mreq =
            [NSMutableURLRequest requestWithURL:nsurl
                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                timeoutInterval:(NSTimeInterval)timeout];

        const char* method = (req->method && req->method[0]) ? req->method : "GET";
        [mreq setHTTPMethod:[NSString stringWithUTF8String:method]];

        if (req->req_headers != NULL && req->req_header_count > 0) {
            for (size_t i = 0; i < req->req_header_count; i++) {
                const char* name  = req->req_headers[2*i];
                const char* value = req->req_headers[2*i + 1];
                if (name == NULL || value == NULL) continue;
                NSString* ns_name  = [NSString stringWithUTF8String:name];
                NSString* ns_value = [NSString stringWithUTF8String:value];
                [mreq setValue:ns_value forHTTPHeaderField:ns_name];
            }
        }

        if (req->body != NULL && req->body_len > 0) {
            NSData* body_data = [NSData dataWithBytes:req->body length:req->body_len];
            [mreq setHTTPBody:body_data];
        }

        __block NSData* respData = nil;
        __block NSURLResponse* respResp = nil;
        __block NSError* respErr = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        NSURLSession* session = [NSURLSession sharedSession];
        NSURLSessionDataTask* task =
            [session dataTaskWithRequest:mreq
                       completionHandler:^(NSData* d, NSURLResponse* r, NSError* e) {
                respData = d;
                respResp = r;
                respErr  = e;
                dispatch_semaphore_signal(sem);
            }];
        [task resume];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

        if (respErr != nil) {
            if (err_out) *err_out = dup_cstring_from_nsstring([respErr localizedDescription]);
            return -1;
        }

        if ([respResp isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse* httpResp = (NSHTTPURLResponse*)respResp;
            resp->status = (int)[httpResp statusCode];

            NSDictionary* hdrs = [httpResp allHeaderFields];
            NSUInteger pair_count = [hdrs count];
            if (pair_count > 0) {
                char** flat = (char**)calloc(pair_count * 2, sizeof(char*));
                size_t idx = 0;
                for (NSString* key in hdrs) {
                    NSString* val = [hdrs objectForKey:key];
                    flat[idx++] = dup_cstring_from_nsstring(key);
                    flat[idx++] = dup_cstring_from_nsstring(val);
                }
                resp->resp_headers = flat;
                resp->resp_header_count = (size_t)pair_count;
            }
        } else {
            // Non-HTTP (e.g., file://) — treat as 200 with no headers.
            resp->status = 200;
        }

        NSUInteger len = (respData == nil) ? 0 : [respData length];
        if (len > 0) {
            char* buf = (char*)malloc(len);
            if (buf == NULL) {
                if (err_out) *err_out = strdup("fetch: out of memory");
                zjs_http_response_free(resp);
                return -1;
            }
            memcpy(buf, [respData bytes], len);
            resp->body = buf;
            resp->body_len = (size_t)len;
        }
        return 0;
    }
}

// =====================================================================
// Async ABI — Apple native. NSURLSession is already async; we just
// don't wait. The completion handler stashes the result on the
// handle under a mutex. Engine's event loop polls per-tick.
//
// Pairs with the CFRunLoop-driven wait in tools/zjs.zc — without that,
// the completion handler's queue never gets a chance to run because
// the main thread is in nanosleep (servicing nothing).
// =====================================================================

#include <pthread.h>

struct ZjsHttpHandle {
    pthread_mutex_t lock;
    int state;                // 0=pending 1=done -1=err
    void* session;            // NSURLSession*
    void* task;               // NSURLSessionDataTask*
    ZjsHttpResponse resp;
    char* err;
};

ZjsHttpHandle* zjs_http_request_start(const ZjsHttpRequest* req) {
    if (req == NULL || req->url == NULL) return NULL;
    @autoreleasepool {
        NSString* urlStr = [NSString stringWithUTF8String:req->url];
        NSURL* nsurl = [NSURL URLWithString:urlStr];
        if (nsurl == nil) return NULL;

        int timeout = (req->timeout_seconds > 0) ? req->timeout_seconds : 30;
        NSMutableURLRequest* mreq =
            [NSMutableURLRequest requestWithURL:nsurl
                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                timeoutInterval:(NSTimeInterval)timeout];
        const char* method = (req->method && req->method[0]) ? req->method : "GET";
        [mreq setHTTPMethod:[NSString stringWithUTF8String:method]];
        if (req->req_headers != NULL && req->req_header_count > 0) {
            for (size_t i = 0; i < req->req_header_count; i++) {
                const char* nm = req->req_headers[2*i];
                const char* vl = req->req_headers[2*i + 1];
                if (nm == NULL || vl == NULL) continue;
                [mreq setValue:[NSString stringWithUTF8String:vl]
                  forHTTPHeaderField:[NSString stringWithUTF8String:nm]];
            }
        }
        if (req->body != NULL && req->body_len > 0) {
            [mreq setHTTPBody:[NSData dataWithBytes:req->body length:req->body_len]];
        }

        ZjsHttpHandle* h = (ZjsHttpHandle*)calloc(1, sizeof(ZjsHttpHandle));
        pthread_mutex_init(&h->lock, NULL);

        NSURLSession* session = [NSURLSession sharedSession];
        h->session = (__bridge_retained void*)session;

        NSURLSessionDataTask* task =
            [session dataTaskWithRequest:mreq
                       completionHandler:^(NSData* d, NSURLResponse* r, NSError* e) {
                ZjsHttpResponse local = {0};
                char* lerr = NULL;
                int rc;
                if (e != nil) {
                    lerr = dup_cstring_from_nsstring([e localizedDescription]);
                    rc = -1;
                } else {
                    if ([r isKindOfClass:[NSHTTPURLResponse class]]) {
                        NSHTTPURLResponse* httpResp = (NSHTTPURLResponse*)r;
                        local.status = (int)[httpResp statusCode];
                        NSDictionary* hdrs = [httpResp allHeaderFields];
                        NSUInteger pair_count = [hdrs count];
                        if (pair_count > 0) {
                            char** flat = (char**)calloc(pair_count * 2, sizeof(char*));
                            size_t idx = 0;
                            for (NSString* key in hdrs) {
                                NSString* val = [hdrs objectForKey:key];
                                flat[idx++] = dup_cstring_from_nsstring(key);
                                flat[idx++] = dup_cstring_from_nsstring(val);
                            }
                            local.resp_headers = flat;
                            local.resp_header_count = (size_t)pair_count;
                        }
                    } else {
                        local.status = 200;
                    }
                    NSUInteger len = (d == nil) ? 0 : [d length];
                    if (len > 0) {
                        char* buf = (char*)malloc(len);
                        memcpy(buf, [d bytes], len);
                        local.body = buf;
                        local.body_len = (size_t)len;
                    }
                    rc = 0;
                }
                pthread_mutex_lock(&h->lock);
                if (rc == 0) { h->resp = local; h->state = 1; }
                else         { h->err  = lerr;  h->state = -1; }
                pthread_mutex_unlock(&h->lock);
            }];
        h->task = (__bridge_retained void*)task;
        [task resume];
        return h;
    }
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
    return (state == 1) ? 1 : -1;
}

void zjs_http_request_destroy(ZjsHttpHandle* h) {
    if (h == NULL) return;
    if (h->task != NULL) {
        NSURLSessionDataTask* task = (__bridge NSURLSessionDataTask*)h->task;
        [task cancel];
        (__bridge_transfer NSURLSessionDataTask*)h->task;
        h->task = NULL;
    }
    if (h->session != NULL) {
        (__bridge_transfer NSURLSession*)h->session;
        h->session = NULL;
    }
    zjs_http_response_free(&h->resp);
    if (h->err) free(h->err);
    pthread_mutex_destroy(&h->lock);
    free(h);
}
