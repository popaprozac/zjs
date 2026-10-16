/* Calls from the engine into its embedder, through the hooks zjs.h lets
 * an embedder install. The engine holds a hook as two words, the
 * function's address and its argument, since Z passes no pointers; this
 * is where they become a call again. */
#ifndef ZJS_HOST_H
#define ZJS_HOST_H

#include <stdint.h>

/* zjs_set_interrupt_handler's callback: 1 when it asks the engine to
 * stop (it returned nonzero), 0 otherwise, and 0 with no handler. */
int32_t zjs_host_interrupt(uintptr_t handler, uintptr_t opaque);

#endif
