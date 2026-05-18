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

int zjs_http_get_sync(const char* url,
                      int* status_out,
                      char** body_out,
                      size_t* body_len_out,
                      char** err_out) {
    if (status_out)   *status_out   = 0;
    if (body_out)     *body_out     = NULL;
    if (body_len_out) *body_len_out = 0;
    if (err_out)      *err_out      = NULL;

    if (url == NULL) {
        if (err_out) *err_out = strdup("fetch: url is NULL");
        return -1;
    }

    @autoreleasepool {
        NSString* urlStr = [NSString stringWithUTF8String:url];
        // Use percent-encoded init path: callers pass already-encoded URLs.
        NSURL* nsurl = [NSURL URLWithString:urlStr];
        if (nsurl == nil) {
            if (err_out) *err_out = strdup("fetch: invalid URL");
            return -1;
        }

        NSURLRequest* req =
            [NSURLRequest requestWithURL:nsurl
                             cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                         timeoutInterval:30.0];

        __block NSData* respData = nil;
        __block NSURLResponse* respResp = nil;
        __block NSError* respErr = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        NSURLSession* session = [NSURLSession sharedSession];
        NSURLSessionDataTask* task =
            [session dataTaskWithRequest:req
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
            if (status_out) *status_out = (int)[httpResp statusCode];
        } else {
            // Non-HTTP (e.g., file://) — treat as 200 so callers can read the body.
            if (status_out) *status_out = 200;
        }

        NSUInteger len = (respData == nil) ? 0 : [respData length];
        if (len == 0) {
            if (body_out)     *body_out     = NULL;
            if (body_len_out) *body_len_out = 0;
            return 0;
        }
        char* buf = (char*)malloc(len);
        if (buf == NULL) {
            if (err_out) *err_out = strdup("fetch: out of memory");
            return -1;
        }
        memcpy(buf, [respData bytes], len);
        if (body_out)     *body_out     = buf;
        if (body_len_out) *body_len_out = (size_t)len;
        return 0;
    }
}
