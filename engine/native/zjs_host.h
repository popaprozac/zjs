/* Calls from the engine into its embedder, through the hooks zjs.h lets
 * an embedder install. The engine holds a hook as two words, the
 * function's address and its argument, since Z passes no pointers; this
 * is where they become a call again. And what the engine asks the
 * platform about the thread it is running on. */
#ifndef ZJS_HOST_H
#define ZJS_HOST_H

#include <stdint.h>

/* zjs_set_interrupt_handler's callback: 1 when it asks the engine to
 * stop (it returned nonzero), 0 otherwise, and 0 with no handler. */
int32_t zjs_host_interrupt(uintptr_t handler, uintptr_t opaque);

/* The calling thread's stack: the address it starts at (its high end;
 * stacks grow down) and its size in bytes. Both 0 where the platform does
 * not tell; the engine then takes the stack to start where it first looks
 * and to be a default size (STACK_DEFAULT in engine/runtime.zs). */
uintptr_t zjs_host_stack_top(void);
uintptr_t zjs_host_stack_size(void);

/* A word no two threads alive at once share. */
uintptr_t zjs_host_thread(void);

#endif
