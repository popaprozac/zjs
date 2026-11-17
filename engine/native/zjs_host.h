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

/* --- Host functions (zjs_register_host_function) ---
 *
 * When JavaScript calls one, the engine calls zjs_host_call with the
 * embedder's function, `entry` (a ZjsHostFunction), and lends it
 * `service`: a way back into the engine, for the length of the call,
 * that works on the runtime the interpreter holds. zjs_host_call keeps it
 * on this thread's list of running host calls while the function runs;
 * the shim (shim/zjs_shim.c) sends each zjs_* call the function makes on
 * its context through it, since this thread holds the context's lock and
 * taking it again would wait forever. The function's arguments come
 * through the service too (ZJS_HOST_ARGUMENT). The ZjsValue bits the
 * function returned. */
typedef uint64_t (*ZjsHostService)(uint32_t op, uint64_t a, uint64_t b, uint64_t c, uint64_t d, void *context);

uint64_t zjs_host_call(uintptr_t entry, uintptr_t handle, uint32_t slot, uint32_t argc, void *context, ZjsHostService service);

/* A running host call: its context (the handle zjs.h hands out, and the
 * slot its values carry) and the service lent to it. */
typedef struct ZjsHostCall {
  struct ZjsHostCall *outer;
  uintptr_t handle;
  uint32_t slot;
  ZjsHostService service;
  void *context;
} ZjsHostCall;

/* The innermost host call running on this thread for the context with
 * this handle, or with this slot; NULL for none. */
ZjsHostCall *zjs_host_call_for_handle(uintptr_t handle);
ZjsHostCall *zjs_host_call_for_slot(uint32_t slot);

/* What a service is asked for (engine/lib.zs, serve, has the same
 * numbers): one per zjs.h function that works on a context, with its
 * operands as words. */
#define ZJS_HOST_ARGUMENT        1  /* a: index */
#define ZJS_HOST_RESULT          2
#define ZJS_HOST_ERROR           3
#define ZJS_HOST_HAD_ERROR       4
#define ZJS_HOST_INTERRUPTED     5
#define ZJS_HOST_NEW_STRING      6  /* a: bytes, b: length */
#define ZJS_HOST_STRING_BYTES    7  /* a: value, b: where the length goes */
#define ZJS_HOST_NEW_OBJECT      8
#define ZJS_HOST_NEW_ARRAY       9  /* a: length */
#define ZJS_HOST_ARRAY_LENGTH   10  /* a: value */
#define ZJS_HOST_PIN            11  /* a: value */
#define ZJS_HOST_UNPIN          12
#define ZJS_HOST_PIN_REPLACE    13  /* a: value */
#define ZJS_HOST_ROOT           14  /* a: value */
#define ZJS_HOST_UNROOT         15  /* a: root */
#define ZJS_HOST_ROOT_GET       16  /* a: root */
#define ZJS_HOST_GET_PROPERTY   17  /* a: object, b: name, c: its length */
#define ZJS_HOST_SET_PROPERTY   18  /* a: object, b: name, c: its length, d: value */
#define ZJS_HOST_GET_ELEMENT    19  /* a: object, b: index */
#define ZJS_HOST_SET_ELEMENT    20  /* a: object, b: index, c: value */
#define ZJS_HOST_GET_GLOBAL     21  /* a: name, b: its length */
#define ZJS_HOST_SET_GLOBAL     22  /* a: name, b: its length, c: value */
#define ZJS_HOST_CALL           23  /* a: callee, b: this, c: argv, d: argc */
#define ZJS_HOST_PENDING_WORK   24
#define ZJS_HOST_GC             25
#define ZJS_HOST_CELL_COUNT     26
#define ZJS_HOST_GC_COLLECTIONS 27
#define ZJS_HOST_GC_PAUSE_TOTAL 28
#define ZJS_HOST_GC_PAUSE_MAX   29
#define ZJS_HOST_GC_CELLS_FREED 30
#define ZJS_HOST_REGISTER       31  /* a: name, b: its length, c: the function */
#define ZJS_HOST_GET_THIS       32
#define ZJS_HOST_THROW          33  /* a: value */
#define ZJS_HOST_SET_INTERRUPT  34  /* a: handler, b: its argument */
#define ZJS_HOST_REFUSE         35  /* a call not available inside a host function */

#endif
