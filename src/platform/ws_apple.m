// Apple-native WebSocket backend — NSURLSessionWebSocketTask.
//
// Receive is naturally one-shot async on Apple's API — we re-arm
// receiveMessageWithCompletionHandler after each event. Events are
// buffered into a mutex-protected linked list and the JS-side event
// loop drains via zjs_ws_poll on each tick. Same Foundation framework
// already in zjs.dylib for fetch — TLS / wss / proxy / IPv6 / system
// trust come along for free.

#import <Foundation/Foundation.h>
#include "ws_native.h"
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

typedef struct ZjsWsEventNode {
    ZjsWsEvent evt;
    struct ZjsWsEventNode* next;
} ZjsWsEventNode;

struct ZjsWsHandle {
    void* task;                  // NSURLSessionWebSocketTask* (retained)
    pthread_mutex_t lock;
    ZjsWsEventNode* head;
    ZjsWsEventNode* tail;
    int closed;                  // 1 once close has been requested
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

static void ws_arm_receive(ZjsWsHandle* h);

ZjsWsHandle* zjs_ws_connect(const char* url) {
    if (url == NULL) return NULL;
    NSString* urlStr = [NSString stringWithUTF8String:url];
    NSURL* nsurl = [NSURL URLWithString:urlStr];
    if (nsurl == nil) return NULL;

    ZjsWsHandle* h = (ZjsWsHandle*)calloc(1, sizeof(ZjsWsHandle));
    pthread_mutex_init(&h->lock, NULL);

    NSURLSession* session = [NSURLSession sharedSession];
    NSURLSessionWebSocketTask* task = [session webSocketTaskWithURL:nsurl];
    // Retain bridge — ARC will keep it alive while held in handle.
    h->task = (__bridge_retained void*)task;
    [task resume];
    ws_arm_receive(h);

    // Apple's API doesn't expose an explicit open callback through
    // NSURLSession; the first successful receive (or send) implies
    // the upgrade completed. To match WebSocket spec semantics, fire
    // a synthetic OPEN event once the task transitions to running.
    // Schedule it on the global queue so it lands before any
    // subsequent message events.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        // Brief sleep to let the upgrade complete. v0.1 hack — proper
        // path would observe NSURLSessionTaskDelegate's
        // didOpenWithProtocol via a session delegate.
        usleep(50000);
        ZjsWsEvent open_evt = {0};
        open_evt.kind = ZJS_WS_EVT_OPEN;
        ws_enqueue(h, open_evt);
    });

    return h;
}

static void ws_arm_receive(ZjsWsHandle* h) {
    NSURLSessionWebSocketTask* task = (__bridge NSURLSessionWebSocketTask*)h->task;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage* msg, NSError* err) {
        if (err != nil) {
            ZjsWsEvent e = {0};
            // EOF / close translates to a close event with the task's
            // reported code if available.
            if ([err.domain isEqualToString:NSURLErrorDomain] && err.code == NSURLErrorNetworkConnectionLost) {
                e.kind = ZJS_WS_EVT_CLOSE;
                e.code = 1006;  // abnormal closure
                e.text = strdup("connection lost");
                e.text_len = strlen("connection lost");
            } else {
                e.kind = ZJS_WS_EVT_ERROR;
                e.text = dup_nsstr([err localizedDescription]);
                e.text_len = e.text ? strlen(e.text) : 0;
            }
            ws_enqueue(h, e);
            return;  // don't re-arm — connection done.
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

    // Fire a close event so the JS-side handlers run.
    ZjsWsEvent e = {0};
    e.kind = ZJS_WS_EVT_CLOSE;
    e.code = code;
    if (reason != NULL && reason[0]) {
        e.text = strdup(reason);
        e.text_len = strlen(reason);
    }
    ws_enqueue(h, e);
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
    if (!h->closed && h->task != NULL) {
        NSURLSessionWebSocketTask* task = (__bridge NSURLSessionWebSocketTask*)h->task;
        [task cancel];
    }
    if (h->task != NULL) {
        NSURLSessionWebSocketTask* task = (__bridge_transfer NSURLSessionWebSocketTask*)h->task;
        (void)task;  // ARC drops the retain here.
        h->task = NULL;
    }
    // Drain pending events.
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
