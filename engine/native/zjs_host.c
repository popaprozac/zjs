/* See zjs_host.h. */
#include "zjs_host.h"

int32_t zjs_host_interrupt(uintptr_t handler, uintptr_t opaque) {
  if (handler == 0) return 0;
  int (*callback)(void *) = (int (*)(void *))handler;
  return callback((void *)opaque) != 0 ? 1 : 0;
}
