// Apple-native WebSocket backend — NSURLSessionWebSocketTask.
//
// Per-WebSocket NSURLSession with a delegate so we get proper
// didOpenWithProtocol / didCloseWithCode callbacks (the only path
// for reading the server's chosen subprotocol). Events are buffered
// into a mutex-protected linked list; the JS-side event loop drains
// via zjs_ws_poll on each tick.
//
// Foundation framework is already in zjs.dylib for fetch — TLS / wss
// / proxy / IPv6 / system trust come along for free.

#import <Foundation/Foundation.h>
#include "ws_native.h"
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

typedef struct ZjsWsEventNode {
    ZjsWsEvent evt;
    struct ZjsWsEventNode* next;
} ZjsWsEventNode;

@class ZjsWsDelegate;

struct ZjsWsHandle {
    void* session;               // NSURLSession* (retained)
    void* task;                  // NSURLSessionWebSocketTask* (retained)
    void* delegate;              // ZjsWsDelegate* (retained)
    pthread_mutex_t lock;
    ZjsWsEventNode* head;
    ZjsWsEventNode* tail;
    int closed;                  // 1 once close has been requested
    int open_fired;              // 1 once an OPEN event has been enqueued
    // Keep-alive ping/pong timer. Apple's NSURLSessionWebSocketTask
    // does NOT auto-send client pings — many intermediaries (load
    // balancers, NAT routers) drop idle WS connections after 30-60s
    // without one. Source fires every 25s and sends a ping; if the
    // pong handler comes back with an error we synthesize a CLOSE
    // event with code 1006 (abnormal closure).
    dispatch_source_t ping_timer;
};

static void ws_enqueue(ZjsWsHandle* h, ZjsWsEvent e) {
    ZjsWsEventNode* n = (ZjsWsEventNode*)malloc(sizeof(ZjsWsEventNode));
    n->evt = e;
    n->next = NULL;
    pthread_mutex_lock(&h->lock);
    if (h->tail) { h->tail->next = n; }
    else         { h->head = n; }
    h->tail = n;
    pthread_mutex_unlock(&h->lock);
}

static char* dup_nsstr(NSString* s) {
    if (s == nil) return NULL;
    const char* utf8 = [s UTF8String];
    return strdup(utf8 ? utf8 : "");
}

@interface ZjsWsDelegate : NSObject <NSURLSessionWebSocketDelegate>
@property (nonatomic, assign) ZjsWsHandle* handle;
@end

@implementation ZjsWsDelegate

- (void)URLSession:(NSURLSession *)session
     webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
  didOpenWithProtocol:(NSString *)protocol {
    if (self.handle == NULL) return;
    if (self.handle->open_fired) return;
    self.handle->open_fired = 1;
    ZjsWsEvent e = {0};
    e.kind = ZJS_WS_EVT_OPEN;
    if (protocol != nil && protocol.length > 0) {
        e.text = dup_nsstr(protocol);
        e.text_len = e.text ? strlen(e.text) : 0;
    } else {
        // Empty string so JS gets "" not undefined when no subprotocol negotiated.
        e.text = strdup("");
        e.text_len = 0;
    }
    ws_enqueue(self.handle, e);
}

- (void)URLSession:(NSURLSession *)session
     webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
   didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
              reason:(NSData *)reason {
    if (self.handle == NULL) return;
    ZjsWsEvent e = {0};
    e.kind = ZJS_WS_EVT_CLOSE;
    e.code = (int)closeCode;
    if (reason != nil && reason.length > 0) {
        char* buf = (char*)malloc(reason.length + 1);
        memcpy(buf, reason.bytes, reason.length);
        buf[reason.length] = 0;
        e.text = buf;
        e.text_len = reason.length;
    }
    ws_enqueue(self.handle, e);
}

// Surface lower-level transport errors (DNS, TLS, refused, timeout).
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (self.handle == NULL || error == nil) return;
    // Don't duplicate a close that already arrived via didCloseWithCode.
    if (self.handle->closed) return;
    ZjsWsEvent e = {0};
    e.kind = ZJS_WS_EVT_ERROR;
    e.text = dup_nsstr([error localizedDescription]);
    e.text_len = e.text ? strlen(e.text) : 0;
    ws_enqueue(self.handle, e);
}
@end

static void ws_arm_receive(ZjsWsHandle* h);

ZjsWsHandle* zjs_ws_connect(const char* url,
                            const char** protocols,
                            size_t protocol_count,
                            int timeout_seconds) {
    if (url == NULL) return NULL;
    NSString* urlStr = [NSString stringWithUTF8String:url];
    NSURL* nsurl = [NSURL URLWithString:urlStr];
    if (nsurl == nil) return NULL;

    ZjsWsHandle* h = (ZjsWsHandle*)calloc(1, sizeof(ZjsWsHandle));
    pthread_mutex_init(&h->lock, NULL);

    ZjsWsDelegate* delegate = [[ZjsWsDelegate alloc] init];
    delegate.handle = h;
    h->delegate = (__bridge_retained void*)delegate;

    NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
    if (timeout_seconds > 0) {
        config.timeoutIntervalForRequest = (NSTimeInterval)timeout_seconds;
    }
    NSURLSession* session = [NSURLSession sessionWithConfiguration:config
                                                          delegate:delegate
                                                     delegateQueue:nil];
    h->session = (__bridge_retained void*)session;

    NSURLSessionWebSocketTask* task = nil;
    if (protocols != NULL && protocol_count > 0) {
        NSMutableArray* protoArr = [NSMutableArray arrayWithCapacity:protocol_count];
        for (size_t i = 0; i < protocol_count; i++) {
            if (protocols[i] != NULL) {
                NSString* p = [NSString stringWithUTF8String:protocols[i]];
                if (p != nil) [protoArr addObject:p];
            }
        }
        task = [session webSocketTaskWithURL:nsurl protocols:protoArr];
    } else {
        task = [session webSocketTaskWithURL:nsurl];
    }
    h->task = (__bridge_retained void*)task;
    [task resume];
    ws_arm_receive(h);

    // Start the keep-alive ping timer — fires every 25s. Send a
    // ping and watch for the pong's err — if it fails we synthesize
    // a CLOSE event with code 1006 (abnormal closure). The timer
    // uses a global queue so the main thread's runloop state
    // doesn't matter; cancel happens in zjs_ws_destroy via
    // dispatch_source_cancel.
    h->ping_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
    uint64_t interval = 25ULL * NSEC_PER_SEC;
    dispatch_source_set_timer(h->ping_timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval, 1ULL * NSEC_PER_SEC);
    dispatch_source_set_event_handler(h->ping_timer, ^{
        if (h->closed || h->task == NULL) return;
        NSURLSessionWebSocketTask* t = (__bridge NSURLSessionWebSocketTask*)h->task;
        [t sendPingWithPongReceiveHandler:^(NSError* err) {
            if (err != nil && !h->closed) {
                ZjsWsEvent e = {0};
                e.kind = ZJS_WS_EVT_CLOSE;
                e.code = 1006;
                e.text = strdup("ping timeout");
                e.text_len = strlen("ping timeout");
                ws_enqueue(h, e);
            }
        }];
    });
    dispatch_resume(h->ping_timer);

    return h;
}

static void ws_arm_receive(ZjsWsHandle* h) {
    NSURLSessionWebSocketTask* task = (__bridge NSURLSessionWebSocketTask*)h->task;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage* msg, NSError* err) {
        if (err != nil) {
            ZjsWsEvent e = {0};
            if ([err.domain isEqualToString:NSURLErrorDomain] && err.code == NSURLErrorNetworkConnectionLost) {
                e.kind = ZJS_WS_EVT_CLOSE;
                e.code = 1006;
                e.text = strdup("connection lost");
                e.text_len = strlen("connection lost");
            } else {
                e.kind = ZJS_WS_EVT_ERROR;
                e.text = dup_nsstr([err localizedDescription]);
                e.text_len = e.text ? strlen(e.text) : 0;
            }
            ws_enqueue(h, e);
            return;
        }
        ZjsWsEvent e = {0};
        if (msg.type == NSURLSessionWebSocketMessageTypeString) {
            e.kind = ZJS_WS_EVT_MESSAGE_TEXT;
            e.text = dup_nsstr(msg.string);
            e.text_len = e.text ? strlen(e.text) : 0;
        } else {
            e.kind = ZJS_WS_EVT_MESSAGE_BIN;
            NSUInteger n = [msg.data length];
            uint8_t* buf = (uint8_t*)malloc(n);
            if (n > 0) memcpy(buf, [msg.data bytes], n);
            e.binary = buf;
            e.binary_len = (size_t)n;
        }
        ws_enqueue(h, e);
        ws_arm_receive(h);
    }];
}

int zjs_ws_send_text(ZjsWsHandle* h, const char* text, size_t len) {
    if (h == NULL || h->task == NULL || text == NULL) return -1;
    NSURLSessionWebSocketTask* task = (__bridge NSURLSessionWebSocketTask*)h->task;
    NSString* s = [[NSString alloc] initWithBytes:text length:len encoding:NSUTF8StringEncoding];
    if (s == nil) return -1;
    NSURLSessionWebSocketMessage* msg = [[NSURLSessionWebSocketMessage alloc] initWithString:s];
    [task sendMessage:msg completionHandler:^(NSError* err) {
        if (err != nil) {
            ZjsWsEvent e = {0};
            e.kind = ZJS_WS_EVT_ERROR;
            e.text = dup_nsstr([err localizedDescription]);
            e.text_len = e.text ? strlen(e.text) : 0;
            ws_enqueue(h, e);
        }
    }];
    return 0;
}

int zjs_ws_send_binary(ZjsWsHandle* h, const uint8_t* bytes, size_t len) {
    if (h == NULL || h->task == NULL || bytes == NULL) return -1;
    NSURLSessionWebSocketTask* task = (__bridge NSURLSessionWebSocketTask*)h->task;
    NSData* d = [NSData dataWithBytes:bytes length:len];
    NSURLSessionWebSocketMessage* msg = [[NSURLSessionWebSocketMessage alloc] initWithData:d];
    [task sendMessage:msg completionHandler:^(NSError* err) {
        if (err != nil) {
            ZjsWsEvent e = {0};
            e.kind = ZJS_WS_EVT_ERROR;
            e.text = dup_nsstr([err localizedDescription]);
            e.text_len = e.text ? strlen(e.text) : 0;
            ws_enqueue(h, e);
        }
    }];
    return 0;
}

int zjs_ws_close(ZjsWsHandle* h, int code, const char* reason) {
    if (h == NULL || h->task == NULL) return -1;
    if (h->closed) return 0;
    h->closed = 1;
    NSURLSessionWebSocketTask* task = (__bridge NSURLSessionWebSocketTask*)h->task;
    NSData* reason_data = nil;
    if (reason != NULL && reason[0]) {
        reason_data = [NSData dataWithBytes:reason length:strlen(reason)];
    }
    [task cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)code reason:reason_data];
    // The delegate's didCloseWithCode will deliver the user-visible
    // CLOSE event with whatever the server actually sent.
    return 0;
}

int zjs_ws_poll(ZjsWsHandle* h, ZjsWsEvent* out_event) {
    if (h == NULL || out_event == NULL) return ZJS_WS_EVT_NONE;
    pthread_mutex_lock(&h->lock);
    ZjsWsEventNode* n = h->head;
    if (n == NULL) { pthread_mutex_unlock(&h->lock); return ZJS_WS_EVT_NONE; }
    h->head = n->next;
    if (h->head == NULL) h->tail = NULL;
    pthread_mutex_unlock(&h->lock);
    *out_event = n->evt;
    free(n);
    return out_event->kind;
}

void zjs_ws_destroy(ZjsWsHandle* h) {
    if (h == NULL) return;
    // Mark closed early so any in-flight ping completion skips
    // the enqueue path before we tear down.
    h->closed = 1;
    // Cancel the keep-alive ping timer first. dispatch_source_cancel
    // is synchronous-with-pending-handlers — if a ping's event
    // handler is mid-execution it'll finish, but no new handlers
    // fire after this returns.
    if (h->ping_timer != NULL) {
        dispatch_source_cancel(h->ping_timer);
        h->ping_timer = NULL;
    }
    if (h->task != NULL) {
        NSURLSessionWebSocketTask* task = (__bridge NSURLSessionWebSocketTask*)h->task;
        [task cancel];
    }
    // Sever the delegate's back-pointer to prevent it firing onto a
    // freed handle if a callback is in flight.
    if (h->delegate != NULL) {
        ZjsWsDelegate* d = (__bridge ZjsWsDelegate*)h->delegate;
        d.handle = NULL;
    }
    if (h->task != NULL) {
        NSURLSessionWebSocketTask* task = (__bridge_transfer NSURLSessionWebSocketTask*)h->task;
        (void)task;
        h->task = NULL;
    }
    if (h->session != NULL) {
        NSURLSession* session = (__bridge_transfer NSURLSession*)h->session;
        [session invalidateAndCancel];
        (void)session;
        h->session = NULL;
    }
    if (h->delegate != NULL) {
        ZjsWsDelegate* d = (__bridge_transfer ZjsWsDelegate*)h->delegate;
        (void)d;
        h->delegate = NULL;
    }
    pthread_mutex_lock(&h->lock);
    ZjsWsEventNode* n = h->head;
    while (n != NULL) {
        ZjsWsEventNode* next = n->next;
        if (n->evt.text) free(n->evt.text);
        if (n->evt.binary) free(n->evt.binary);
        free(n);
        n = next;
    }
    h->head = h->tail = NULL;
    pthread_mutex_unlock(&h->lock);
    pthread_mutex_destroy(&h->lock);
    free(h);
}
