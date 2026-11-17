/* See zjs_host.h. */
#include "zjs_host.h"

#include <errno.h>
#if defined(__APPLE__) && !defined(ZJS_HOST_NO_STACK_BOUNDS)
#include <pthread.h>
#endif

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
