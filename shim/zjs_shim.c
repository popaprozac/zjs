/* Frozen-ABI shim: publishes the exact zjs.h signatures over the Z
 * library's uintptr_t exports.
 *
 * Z's `export c function` does not accept pointer parameters, and zjs.h
 * is `ZjsContext*` throughout, so the Z side hands out a packed handle
 * (slot and generation, 32 bits each) and this file casts it into the
 * pointer-shaped type the frozen contract promises. The token is not a
 * pointer and must not be dereferenced; it needs a 64-bit host word.
 *
 * Runtime lifecycle contract (see docs/lifecycle.md):
 * - The Z runtime is initialized by the first zjs_new_context, on
 *   whichever host thread makes it: the library root is a shareable
 *   class, so the generated header requires neither a main-thread proof
 *   nor a release hook (both requirement flags are zero, asserted below).
 * - Contexts may then be created, evaluated, and freed from any host
 *   thread; independent contexts proceed concurrently.
 * - Shutdown and unload are not supported through zjs.h; the generated
 *   runtime's shutdown entry exists and is exercised by the lifecycle
 *   test, but nothing in the frozen ABI reaches it.
 */
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "zjs.h"
#include "zjsz.h"
#include "../engine/native/zjs_host.h"

_Static_assert(sizeof(uintptr_t) >= 8, "ZjsContext handles pack a slot and a generation into 64 bits");
_Static_assert(ZJSZ_RUNTIME_REQUIRES_MAIN_THREAD == 0, "the library root must stay main-independent: no main-thread hook is provided");
_Static_assert(ZJSZ_RUNTIME_REQUIRES_ENQUEUE_RELEASE == 0, "the library root must stay main-independent: no release hook is provided");

/* Inside a host function, a call on its own context goes through the
   service the engine lent the function for the call (zjs_host.h): this
   thread holds the context's lock, so the call cannot take it. Calls that
   would run a program or change the context's setup are refused there
   (zjs_host_refuse): the context's error says so. */
static ZjsHostCall *zjs_inside(ZjsContext *ctx) { return zjs_host_call_for_handle((uintptr_t)ctx); }

static uint64_t zjs_serve(ZjsHostCall *call, uint32_t op, uint64_t a, uint64_t b, uint64_t c, uint64_t d) {
  return call->service(op, a, b, c, d, call->context);
}

static int zjs_host_refuse(ZjsContext *ctx) {
  ZjsHostCall *call = zjs_inside(ctx);
  if (call == NULL) return 0;
  zjs_serve(call, ZJS_HOST_REFUSE, 0, 0, 0, 0);
  return 1;
}

/* Initialization is serialized; readiness is published only after the
   generated runtime reports success, and a failed attempt (an invalid
   configuration) leaves later attempts possible. */
static pthread_mutex_t g_init_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_runtime_ready = 0;
static zjsz_runtime_status g_last_init_status = ZJSZ_RUNTIME_OK;

static int shim_ensure_runtime(void) {
  pthread_mutex_lock(&g_init_lock);
  if (!g_runtime_ready) {
    zjsz_runtime_status status = zjsz_runtime_initialize(NULL);
    if (status == ZJSZ_RUNTIME_OK || status == ZJSZ_RUNTIME_ALREADY_INITIALIZED) {
      g_runtime_ready = 1;
    }
    g_last_init_status = status;
  }
  int ready = g_runtime_ready;
  pthread_mutex_unlock(&g_init_lock);
  return ready;
}

/* The status of the last initialization attempt: a shim-level accessor,
   since the frozen header has no lifecycle status. */
int zjs_shim_init_status(void) {
  pthread_mutex_lock(&g_init_lock);
  int status = (int)g_last_init_status;
  pthread_mutex_unlock(&g_init_lock);
  return status;
}

ZjsContext *zjs_new_context(void) {
  if (!shim_ensure_runtime()) return NULL;
  return (ZjsContext *)(uintptr_t)zjs_z_new_context();
}

ZjsContext *zjs_new_core_context(void) {
  if (!shim_ensure_runtime()) return NULL;
  return (ZjsContext *)(uintptr_t)zjs_z_new_core_context();
}

/* Each installer is its own function, so an embedder links only those it
   calls. */
void zjs_install_json(ZjsContext *ctx) { if (ctx != NULL && !zjs_host_refuse(ctx)) zjs_z_install_json((uintptr_t)ctx); }
void zjs_install_regexp(ZjsContext *ctx) { if (ctx != NULL && !zjs_host_refuse(ctx)) zjs_z_install_regexp((uintptr_t)ctx); }
void zjs_install_date(ZjsContext *ctx) { if (ctx != NULL && !zjs_host_refuse(ctx)) zjs_z_install_date((uintptr_t)ctx); }
void zjs_install_collections(ZjsContext *ctx) { if (ctx != NULL && !zjs_host_refuse(ctx)) zjs_z_install_collections((uintptr_t)ctx); }
void zjs_install_promise(ZjsContext *ctx) { if (ctx != NULL && !zjs_host_refuse(ctx)) zjs_z_install_promise((uintptr_t)ctx); }
void zjs_install_reflect(ZjsContext *ctx) { if (ctx != NULL && !zjs_host_refuse(ctx)) zjs_z_install_reflect((uintptr_t)ctx); }
void zjs_install_compiler(ZjsContext *ctx) { if (ctx != NULL && !zjs_host_refuse(ctx)) zjs_z_install_compiler((uintptr_t)ctx); }

void zjs_free_context(ZjsContext *ctx) {
  if (ctx == NULL) return;
  zjs_z_free_context((uintptr_t)ctx);
}

/* --- Values ---
 *
 * A ZjsValue's bits are the engine's own for a number, a boolean, null,
 * and undefined, so those are made and read here with no call into the
 * engine. A cell is the engine's handle with two things the Z side packs
 * above it (engine/lib.zs, "Values across the ABI"): the slot of the
 * context it belongs to, and its kind, which the cell predicates below
 * read. */
#define ZJS_NUMBER_TAG    0xFFFE000000000000ULL
#define ZJS_DOUBLE_OFFSET 0x0002000000000000ULL
#define ZJS_NOT_CELL      (ZJS_NUMBER_TAG | 2ULL)
#define ZJS_NULL          2ULL
#define ZJS_FALSE         6ULL
#define ZJS_TRUE          7ULL
#define ZJS_UNDEFINED     10ULL
#define ZJS_KIND(v)       ((unsigned)(((v).bits >> 45) & 7u))
#define ZJS_SLOT(v)       ((uint32_t)(((v).bits >> 34) & 2047u))
enum { ZJS_KIND_STRING = 1, ZJS_KIND_OBJECT = 2, ZJS_KIND_ARRAY = 3, ZJS_KIND_FUNCTION = 4, ZJS_KIND_HOST_FUNCTION = 5 };

static ZjsValue zjs_bits(uint64_t bits) {
  ZjsValue value;
  value.bits = bits;
  return value;
}

ZjsValue zjs_int32(int32_t i) { return zjs_bits(ZJS_NUMBER_TAG | (uint32_t)i); }

/* Every NaN goes in as the one NaN the engine keeps: another's bits, with
   the offset added, could read as something that is not a number. */
ZjsValue zjs_double(double d) {
  uint64_t bits;
  if (d != d) return zjs_bits(0x7FF8000000000000ULL + ZJS_DOUBLE_OFFSET);
  memcpy(&bits, &d, sizeof bits);
  return zjs_bits(bits + ZJS_DOUBLE_OFFSET);
}

ZjsValue zjs_bool(int b) { return zjs_bits(b ? ZJS_TRUE : ZJS_FALSE); }
ZjsValue zjs_null(void) { return zjs_bits(ZJS_NULL); }
ZjsValue zjs_undefined(void) { return zjs_bits(ZJS_UNDEFINED); }

int zjs_is_int32(ZjsValue v) { return (v.bits & ZJS_NUMBER_TAG) == ZJS_NUMBER_TAG; }
int zjs_is_double(ZjsValue v) { return (v.bits & ZJS_NUMBER_TAG) != 0 && (v.bits & ZJS_NUMBER_TAG) != ZJS_NUMBER_TAG; }
int zjs_is_number(ZjsValue v) { return (v.bits & ZJS_NUMBER_TAG) != 0; }
int zjs_is_bool(ZjsValue v) { return v.bits == ZJS_TRUE || v.bits == ZJS_FALSE; }
int zjs_is_null(ZjsValue v) { return v.bits == ZJS_NULL; }
int zjs_is_undefined(ZjsValue v) { return v.bits == ZJS_UNDEFINED; }
int zjs_is_cell(ZjsValue v) { return (v.bits & ZJS_NOT_CELL) == 0 && v.bits != 0; }

int zjs_is_string(ZjsValue v) { return zjs_is_cell(v) && ZJS_KIND(v) == ZJS_KIND_STRING; }
int zjs_is_object(ZjsValue v) { return zjs_is_cell(v) && ZJS_KIND(v) == ZJS_KIND_OBJECT; }
int zjs_is_array(ZjsValue v) { return zjs_is_cell(v) && ZJS_KIND(v) == ZJS_KIND_ARRAY; }
int zjs_is_function(ZjsValue v) { return zjs_is_cell(v) && ZJS_KIND(v) == ZJS_KIND_FUNCTION; }
int zjs_is_host_function(ZjsValue v) { return zjs_is_cell(v) && ZJS_KIND(v) == ZJS_KIND_HOST_FUNCTION; }
int zjs_is_callable(ZjsValue v) { return zjs_is_function(v) || zjs_is_host_function(v); }

int32_t zjs_as_int32(ZjsValue v) { return (int32_t)(uint32_t)v.bits; }

/* An int32 reads as its double too, so that a number is one call to read. */
double zjs_as_double(ZjsValue v) {
  double d;
  uint64_t bits;
  if (zjs_is_int32(v)) return (double)zjs_as_int32(v);
  bits = v.bits - ZJS_DOUBLE_OFFSET;
  memcpy(&d, &bits, sizeof d);
  return d;
}

int zjs_as_bool(ZjsValue v) { return v.bits == ZJS_TRUE; }

const char *zjs_version(void) { return "0.1.0"; }

/* --- Evaluation: each returns what the program produced, undefined when
   it threw (zjs_get_error then has what was thrown). --- */

ZjsValue zjs_eval(ZjsContext *ctx, const char *source) {
  if (ctx == NULL || source == NULL || zjs_host_refuse(ctx)) return zjs_undefined();
  zjs_z_eval((uintptr_t)ctx, (const uint8_t *)source, strlen(source));
  return zjs_bits(zjs_z_result((uintptr_t)ctx));
}

/* A buffer the engine refuses (another engine's, damaged) runs nothing
   and is not an error. */
ZjsValue zjs_eval_bytecode(ZjsContext *ctx, const unsigned char *data, size_t len) {
  if (ctx == NULL || data == NULL || zjs_host_refuse(ctx)) return zjs_undefined();
  zjs_z_eval_bytecode((uintptr_t)ctx, (const uint8_t *)data, len);
  return zjs_bits(zjs_z_result((uintptr_t)ctx));
}

/* The module's namespace object. */
ZjsValue zjs_eval_module(ZjsContext *ctx, const char *abs_path) {
  if (ctx == NULL || abs_path == NULL || zjs_host_refuse(ctx)) return zjs_undefined();
  zjs_z_eval_module((uintptr_t)ctx, (const uint8_t *)abs_path, strlen(abs_path));
  return zjs_bits(zjs_z_result((uintptr_t)ctx));
}

/* As zjs_eval_module, the graph's modules module bytecode files: nothing
   it reaches installs or links the compiler. */
ZjsValue zjs_eval_module_bytecode(ZjsContext *ctx, const char *abs_path) {
  if (ctx == NULL || abs_path == NULL || zjs_host_refuse(ctx)) return zjs_undefined();
  zjs_z_eval_module_bytecode((uintptr_t)ctx, (const uint8_t *)abs_path, strlen(abs_path));
  return zjs_bits(zjs_z_result((uintptr_t)ctx));
}

ZjsValue zjs_eval_module_source(ZjsContext *ctx, const char *source, size_t source_len, const char *virtual_path) {
  if (ctx == NULL || source == NULL || virtual_path == NULL || zjs_host_refuse(ctx)) return zjs_undefined();
  zjs_z_eval_module_source((uintptr_t)ctx, (const uint8_t *)source, source_len, (const uint8_t *)virtual_path, strlen(virtual_path));
  return zjs_bits(zjs_z_result((uintptr_t)ctx));
}

ZjsValue zjs_get_error(ZjsContext *ctx) {
  if (ctx == NULL) return zjs_undefined();
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return zjs_bits(zjs_serve(call, ZJS_HOST_ERROR, 0, 0, 0, 0));
  return zjs_bits(zjs_z_error((uintptr_t)ctx));
}

/* --- Cells --- */

ZjsValue zjs_new_string(ZjsContext *ctx, const char *data, uint32_t length) {
  if (ctx == NULL || (data == NULL && length != 0)) return zjs_undefined();
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return zjs_bits(zjs_serve(call, ZJS_HOST_NEW_STRING, (uintptr_t)(data != NULL ? data : ""), length, 0, 0));
  return zjs_bits(zjs_z_new_string((uintptr_t)ctx, (const uint8_t *)(data != NULL ? data : ""), length));
}

/* A UTF-8 copy of the string that the context keeps while the string
   lives, with a NUL after it (docs/lifecycle.md). */
const char *zjs_string_bytes(ZjsValue v, uint32_t *out_length) {
  size_t length = 0;
  uintptr_t address;
  if (out_length != NULL) *out_length = 0;
  if (!zjs_is_string(v)) return NULL;
  ZjsHostCall *call = zjs_host_call_for_slot(ZJS_SLOT(v));
  if (call != NULL) address = (uintptr_t)zjs_serve(call, ZJS_HOST_STRING_BYTES, v.bits, (uintptr_t)&length, 0, 0);
  else address = zjs_z_string_bytes(ZJS_SLOT(v), v.bits, (uintptr_t)&length);
  if (address != 0 && out_length != NULL) *out_length = (uint32_t)length;
  return (const char *)address;
}

ZjsValue zjs_new_object(ZjsContext *ctx) {
  if (ctx == NULL) return zjs_undefined();
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return zjs_bits(zjs_serve(call, ZJS_HOST_NEW_OBJECT, 0, 0, 0, 0));
  return zjs_bits(zjs_z_new_object((uintptr_t)ctx));
}

ZjsValue zjs_new_array(ZjsContext *ctx, uint32_t length) {
  if (ctx == NULL) return zjs_undefined();
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return zjs_bits(zjs_serve(call, ZJS_HOST_NEW_ARRAY, length, 0, 0, 0));
  return zjs_bits(zjs_z_new_array((uintptr_t)ctx, length));
}

uint32_t zjs_array_length(ZjsValue v) {
  if (!zjs_is_array(v)) return 0;
  ZjsHostCall *call = zjs_host_call_for_slot(ZJS_SLOT(v));
  if (call != NULL) return (uint32_t)zjs_serve(call, ZJS_HOST_ARRAY_LENGTH, v.bits, 0, 0, 0);
  return zjs_z_array_length(ZJS_SLOT(v), v.bits);
}

/* --- Properties, globals, and calls: each may run JavaScript, and a
   throw is the context's error (zjs_had_error, zjs_get_error), the call
   answering undefined. --- */

ZjsValue zjs_get_property(ZjsContext *ctx, ZjsValue obj, const char *name) {
  if (ctx == NULL || name == NULL) return zjs_undefined();
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return zjs_bits(zjs_serve(call, ZJS_HOST_GET_PROPERTY, obj.bits, (uintptr_t)name, strlen(name), 0));
  return zjs_bits(zjs_z_get_property((uintptr_t)ctx, obj.bits, (const uint8_t *)name, strlen(name)));
}

void zjs_set_property(ZjsContext *ctx, ZjsValue obj, const char *name, ZjsValue value) {
  if (ctx == NULL || name == NULL) return;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) { zjs_serve(call, ZJS_HOST_SET_PROPERTY, obj.bits, (uintptr_t)name, strlen(name), value.bits); return; }
  zjs_z_set_property((uintptr_t)ctx, obj.bits, (const uint8_t *)name, strlen(name), value.bits);
}

ZjsValue zjs_get_element(ZjsContext *ctx, ZjsValue obj, uint32_t index) {
  if (ctx == NULL) return zjs_undefined();
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return zjs_bits(zjs_serve(call, ZJS_HOST_GET_ELEMENT, obj.bits, index, 0, 0));
  return zjs_bits(zjs_z_get_element((uintptr_t)ctx, obj.bits, index));
}

void zjs_set_element(ZjsContext *ctx, ZjsValue obj, uint32_t index, ZjsValue value) {
  if (ctx == NULL) return;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) { zjs_serve(call, ZJS_HOST_SET_ELEMENT, obj.bits, index, value.bits, 0); return; }
  zjs_z_set_element((uintptr_t)ctx, obj.bits, index, value.bits);
}

ZjsValue zjs_get_global(ZjsContext *ctx, const char *name) {
  if (ctx == NULL || name == NULL) return zjs_undefined();
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return zjs_bits(zjs_serve(call, ZJS_HOST_GET_GLOBAL, (uintptr_t)name, strlen(name), 0, 0));
  return zjs_bits(zjs_z_get_global((uintptr_t)ctx, (const uint8_t *)name, strlen(name)));
}

void zjs_set_global(ZjsContext *ctx, const char *name, ZjsValue value) {
  if (ctx == NULL || name == NULL) return;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) { zjs_serve(call, ZJS_HOST_SET_GLOBAL, (uintptr_t)name, strlen(name), value.bits, 0); return; }
  zjs_z_set_global((uintptr_t)ctx, (const uint8_t *)name, strlen(name), value.bits);
}

/* The function's value, undefined when it threw; the jobs it queued have
   run by the time this returns, unless it was called from inside a host
   function: they run when the call that entered the engine returns. */
ZjsValue zjs_call(ZjsContext *ctx, ZjsValue callee, ZjsValue this_val, ZjsValue *argv, uint32_t argc) {
  if (ctx == NULL || (argv == NULL && argc != 0)) return zjs_undefined();
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) {
    zjs_serve(call, ZJS_HOST_CALL, callee.bits, this_val.bits, (uintptr_t)argv, argc);
    return zjs_bits(zjs_serve(call, ZJS_HOST_RESULT, 0, 0, 0, 0));
  }
  zjs_z_call((uintptr_t)ctx, callee.bits, this_val.bits, (uintptr_t)argv, argc);
  return zjs_bits(zjs_z_result((uintptr_t)ctx));
}

/* Inside a host function this does nothing: the jobs run when the call
   that entered the engine returns. */
void zjs_drain_microtasks(ZjsContext *ctx) { if (ctx != NULL && zjs_inside(ctx) == NULL) zjs_z_drain_microtasks((uintptr_t)ctx); }

int zjs_has_pending_work(ZjsContext *ctx) {
  if (ctx == NULL) return 0;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return (int)zjs_serve(call, ZJS_HOST_PENDING_WORK, 0, 0, 0, 0);
  return (int)zjs_z_has_pending_work((uintptr_t)ctx);
}

/* --- The collector --- */

void zjs_gc(ZjsContext *ctx) {
  if (ctx == NULL) return;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) { zjs_serve(call, ZJS_HOST_GC, 0, 0, 0, 0); return; }
  zjs_z_gc((uintptr_t)ctx);
}

unsigned int zjs_cell_count(ZjsContext *ctx) {
  if (ctx == NULL) return 0;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return (unsigned int)zjs_serve(call, ZJS_HOST_CELL_COUNT, 0, 0, 0, 0);
  return zjs_z_heap_cells((uintptr_t)ctx);
}

unsigned int zjs_gc_collections(ZjsContext *ctx) {
  if (ctx == NULL) return 0;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return (unsigned int)zjs_serve(call, ZJS_HOST_GC_COLLECTIONS, 0, 0, 0, 0);
  return zjs_z_gc_collections((uintptr_t)ctx);
}

uint64_t zjs_gc_pause_ns_total(ZjsContext *ctx) {
  if (ctx == NULL) return 0;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return (uint64_t)zjs_serve(call, ZJS_HOST_GC_PAUSE_TOTAL, 0, 0, 0, 0);
  return zjs_z_gc_pause_total((uintptr_t)ctx);
}

uint64_t zjs_gc_pause_ns_max(ZjsContext *ctx) {
  if (ctx == NULL) return 0;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return (uint64_t)zjs_serve(call, ZJS_HOST_GC_PAUSE_MAX, 0, 0, 0, 0);
  return zjs_z_gc_pause_max((uintptr_t)ctx);
}

unsigned int zjs_gc_cells_freed(ZjsContext *ctx) {
  if (ctx == NULL) return 0;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return (unsigned int)zjs_serve(call, ZJS_HOST_GC_CELLS_FREED, 0, 0, 0, 0);
  return zjs_z_gc_cells_freed((uintptr_t)ctx);
}

/* --- Values kept across calls --- */

void zjs_pin(ZjsContext *ctx, ZjsValue value) {
  if (ctx == NULL) return;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) { zjs_serve(call, ZJS_HOST_PIN, value.bits, 0, 0, 0); return; }
  zjs_z_pin((uintptr_t)ctx, value.bits);
}

void zjs_unpin(ZjsContext *ctx) {
  if (ctx == NULL) return;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) { zjs_serve(call, ZJS_HOST_UNPIN, 0, 0, 0, 0); return; }
  zjs_z_unpin((uintptr_t)ctx);
}

void zjs_pin_replace(ZjsContext *ctx, ZjsValue value) {
  if (ctx == NULL) return;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) { zjs_serve(call, ZJS_HOST_PIN_REPLACE, value.bits, 0, 0, 0); return; }
  zjs_z_pin_replace((uintptr_t)ctx, value.bits);
}

uint32_t zjs_root(ZjsContext *ctx, ZjsValue value) {
  if (ctx == NULL) return 0;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return (uint32_t)zjs_serve(call, ZJS_HOST_ROOT, value.bits, 0, 0, 0);
  return zjs_z_root((uintptr_t)ctx, value.bits);
}

void zjs_unroot(ZjsContext *ctx, uint32_t handle) {
  if (ctx == NULL) return;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) { zjs_serve(call, ZJS_HOST_UNROOT, handle, 0, 0, 0); return; }
  zjs_z_unroot((uintptr_t)ctx, handle);
}

ZjsValue zjs_root_get(ZjsContext *ctx, uint32_t handle) {
  if (ctx == NULL) return zjs_undefined();
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return zjs_bits(zjs_serve(call, ZJS_HOST_ROOT_GET, handle, 0, 0, 0));
  return zjs_bits(zjs_z_root_get((uintptr_t)ctx, handle));
}

unsigned char *zjs_compile_to_bytecode(ZjsContext *ctx, const char *source, size_t *out_len) {
  if (out_len != NULL) *out_len = 0;
  if (ctx == NULL || source == NULL || zjs_host_refuse(ctx)) return NULL;
  size_t length = 0;
  uintptr_t buffer = zjs_z_compile_to_bytecode((uintptr_t)ctx, (const uint8_t *)source, strlen(source), (uintptr_t)&length);
  if (out_len != NULL) *out_len = length;
  return (unsigned char *)buffer;
}

/* The handler runs on the thread evaluating ctx, so it sees no engine
   state from another thread; it is handed to the Z side as two words. */
void zjs_set_interrupt_handler(ZjsContext *ctx, ZjsInterruptHandler handler, void *opaque) {
  if (ctx == NULL) return;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) { zjs_serve(call, ZJS_HOST_SET_INTERRUPT, (uintptr_t)handler, (uintptr_t)opaque, 0, 0); return; }
  zjs_z_set_interrupt_handler((uintptr_t)ctx, (uintptr_t)handler, (uintptr_t)opaque);
}

int zjs_is_interrupted(ZjsContext *ctx) {
  if (ctx == NULL) return 0;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return (int)zjs_serve(call, ZJS_HOST_INTERRUPTED, 0, 0, 0, 0);
  return (int)zjs_z_was_interrupted((uintptr_t)ctx);
}

int zjs_had_error(ZjsContext *ctx) {
  if (ctx == NULL) return 1;
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return (int)zjs_serve(call, ZJS_HOST_HAD_ERROR, 0, 0, 0, 0);
  return (int)zjs_z_had_error((uintptr_t)ctx);
}

/* --- Host functions: C called from JavaScript (zjs_host.h says how a
   call made from inside one reaches the engine). --- */

ZjsValue zjs_register_host_function(ZjsContext *ctx, const char *name, ZjsHostFunction fn) {
  if (ctx == NULL || name == NULL || fn == NULL) return zjs_undefined();
  ZjsHostCall *call = zjs_inside(ctx);
  if (call != NULL) return zjs_bits(zjs_serve(call, ZJS_HOST_REGISTER, (uintptr_t)name, strlen(name), (uintptr_t)fn, 0));
  return zjs_bits(zjs_z_register_host_function((uintptr_t)ctx, (const uint8_t *)name, strlen(name), (uintptr_t)fn));
}

/* The receiver of the host function running on this thread for ctx;
   undefined outside one. */
ZjsValue zjs_get_this(ZjsContext *ctx) {
  ZjsHostCall *call = ctx != NULL ? zjs_inside(ctx) : NULL;
  if (call == NULL) return zjs_undefined();
  return zjs_bits(zjs_serve(call, ZJS_HOST_GET_THIS, 0, 0, 0, 0));
}

/* Thrown when the host function returns; nothing outside one. */
void zjs_throw(ZjsContext *ctx, ZjsValue value) {
  ZjsHostCall *call = ctx != NULL ? zjs_inside(ctx) : NULL;
  if (call != NULL) zjs_serve(call, ZJS_HOST_THROW, value.bits, 0, 0, 0);
}
