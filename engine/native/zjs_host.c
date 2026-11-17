/* See zjs_host.h. */
#include "zjs_host.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>

#include "../../include/zjs.h"

int32_t zjs_host_interrupt(uintptr_t handler, uintptr_t opaque) {
  if (handler == 0) return 0;
  int (*callback)(void *) = (int (*)(void *))handler;
  return callback((void *)opaque) != 0 ? 1 : 0;
}

/* shortcut: only Apple platforms report the stack; add pthread_getattr_np
 * here when the engine ships somewhere else. ZJS_HOST_NO_STACK_BOUNDS
 * builds the other side on an Apple platform, to test it. */
#if defined(__APPLE__) && !defined(ZJS_HOST_NO_STACK_BOUNDS)
uintptr_t zjs_host_stack_top(void) {
  return (uintptr_t)pthread_get_stackaddr_np(pthread_self());
}

uintptr_t zjs_host_stack_size(void) {
  return (uintptr_t)pthread_get_stacksize_np(pthread_self());
}
#else
uintptr_t zjs_host_stack_top(void) { return 0; }
uintptr_t zjs_host_stack_size(void) { return 0; }
#endif

/* Where this thread keeps errno: every thread has its own, and asking
 * imports nothing new (a thread-local variable of the engine's own cost
 * 230,000 instructions at process launch). */
uintptr_t zjs_host_thread(void) {
  return (uintptr_t)&errno;
}

/* This thread's running host calls, innermost first, kept as a
 * thread-specific value rather than a C thread-local (see
 * zjs_host_thread). Its key is made by the first host call, so a process
 * that calls none asks nothing; until then no thread has any. */
static pthread_once_t zjs_host_calls_once = PTHREAD_ONCE_INIT;
static pthread_key_t zjs_host_calls_key;
static atomic_int zjs_host_calls_made = 0;

static void zjs_host_calls_create(void) {
  if (pthread_key_create(&zjs_host_calls_key, NULL) != 0) abort();
  atomic_store_explicit(&zjs_host_calls_made, 1, memory_order_release);
}

static ZjsHostCall *zjs_host_calls_here(void) {
  if (!atomic_load_explicit(&zjs_host_calls_made, memory_order_acquire)) return NULL;
  return (ZjsHostCall *)pthread_getspecific(zjs_host_calls_key);
}

static void zjs_host_calls_set(ZjsHostCall *calls) {
  if (pthread_setspecific(zjs_host_calls_key, calls) != 0) abort();
}

/* The arguments go on this stack when there are few, else in memory that
 * is given back when the function returns. */
#define ZJS_HOST_FEW_ARGUMENTS 8

uint64_t zjs_host_call(uintptr_t entry, uintptr_t handle, uint32_t slot, uint32_t argc, void *context, ZjsHostService service) {
  pthread_once(&zjs_host_calls_once, zjs_host_calls_create);
  ZjsValue few[ZJS_HOST_FEW_ARGUMENTS];
  ZjsValue *argv = few;
  if (argc > ZJS_HOST_FEW_ARGUMENTS) {
    argv = (ZjsValue *)malloc(sizeof(ZjsValue) * argc);
    if (argv == NULL) abort();
  }
  for (uint32_t index = 0; index < argc; index++) {
    argv[index].bits = service(ZJS_HOST_ARGUMENT, index, 0, 0, 0, context);
  }
  ZjsHostCall call = { zjs_host_calls_here(), handle, slot, service, context };
  zjs_host_calls_set(&call);
  ZjsValue result = ((ZjsHostFunction)entry)((ZjsContext *)handle, argv, argc);
  zjs_host_calls_set(call.outer);
  if (argv != few) free(argv);
  return result.bits;
}

ZjsHostCall *zjs_host_call_for_handle(uintptr_t handle) {
  for (ZjsHostCall *call = zjs_host_calls_here(); call != NULL; call = call->outer) {
    if (call->handle == handle) return call;
  }
  return NULL;
}

ZjsHostCall *zjs_host_call_for_slot(uint32_t slot) {
  for (ZjsHostCall *call = zjs_host_calls_here(); call != NULL; call = call->outer) {
    if (call->slot == slot) return call;
  }
  return NULL;
}
