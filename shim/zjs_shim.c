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

_Static_assert(sizeof(uintptr_t) >= 8, "ZjsContext handles pack a slot and a generation into 64 bits");
_Static_assert(ZJSZ_RUNTIME_REQUIRES_MAIN_THREAD == 0, "the library root must stay main-independent: no main-thread hook is provided");
_Static_assert(ZJSZ_RUNTIME_REQUIRES_ENQUEUE_RELEASE == 0, "the library root must stay main-independent: no release hook is provided");

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
void zjs_install_json(ZjsContext *ctx) { if (ctx != NULL) zjs_z_install_json((uintptr_t)ctx); }
void zjs_install_regexp(ZjsContext *ctx) { if (ctx != NULL) zjs_z_install_regexp((uintptr_t)ctx); }
void zjs_install_date(ZjsContext *ctx) { if (ctx != NULL) zjs_z_install_date((uintptr_t)ctx); }
void zjs_install_collections(ZjsContext *ctx) { if (ctx != NULL) zjs_z_install_collections((uintptr_t)ctx); }
void zjs_install_promise(ZjsContext *ctx) { if (ctx != NULL) zjs_z_install_promise((uintptr_t)ctx); }
void zjs_install_reflect(ZjsContext *ctx) { if (ctx != NULL) zjs_z_install_reflect((uintptr_t)ctx); }
void zjs_install_compiler(ZjsContext *ctx) { if (ctx != NULL) zjs_z_install_compiler((uintptr_t)ctx); }

void zjs_free_context(ZjsContext *ctx) {
  if (ctx == NULL) return;
  zjs_z_free_context((uintptr_t)ctx);
}

/* Placeholder return: the engine's NaN-box layout is not mapped onto
   ZjsValue yet, so every evaluation reports undefined here; the harness
   reads zjs_had_error. */
ZjsValue zjs_eval(ZjsContext *ctx, const char *source) {
  if (ctx != NULL) zjs_z_eval((uintptr_t)ctx, (const uint8_t *)source, strlen(source));
  ZjsValue undefined;
  undefined.bits = 10; /* OTHER_TAG | UNDEFINED_TAG */
  return undefined;
}

/* As zjs_eval: the program's value is not mapped onto ZjsValue yet. A
   buffer the engine refuses (another engine's, damaged) runs nothing and
   is not an error. */
ZjsValue zjs_eval_bytecode(ZjsContext *ctx, const unsigned char *data, size_t len) {
  if (ctx != NULL && data != NULL) zjs_z_eval_bytecode((uintptr_t)ctx, (const uint8_t *)data, len);
  ZjsValue undefined;
  undefined.bits = 10; /* OTHER_TAG | UNDEFINED_TAG */
  return undefined;
}

/* As zjs_eval: the module's namespace is not mapped onto ZjsValue yet. */
ZjsValue zjs_eval_module(ZjsContext *ctx, const char *abs_path) {
  if (ctx != NULL && abs_path != NULL) zjs_z_eval_module((uintptr_t)ctx, (const uint8_t *)abs_path, strlen(abs_path));
  ZjsValue undefined;
  undefined.bits = 10; /* OTHER_TAG | UNDEFINED_TAG */
  return undefined;
}

/* As zjs_eval_module, the graph's modules module bytecode files: nothing
   it reaches installs or links the compiler. */
ZjsValue zjs_eval_module_bytecode(ZjsContext *ctx, const char *abs_path) {
  if (ctx != NULL && abs_path != NULL) zjs_z_eval_module_bytecode((uintptr_t)ctx, (const uint8_t *)abs_path, strlen(abs_path));
  ZjsValue undefined;
  undefined.bits = 10; /* OTHER_TAG | UNDEFINED_TAG */
  return undefined;
}

ZjsValue zjs_eval_module_source(ZjsContext *ctx, const char *source, size_t source_len, const char *virtual_path) {
  if (ctx != NULL && source != NULL && virtual_path != NULL) {
    zjs_z_eval_module_source((uintptr_t)ctx, (const uint8_t *)source, source_len, (const uint8_t *)virtual_path, strlen(virtual_path));
  }
  ZjsValue undefined;
  undefined.bits = 10; /* OTHER_TAG | UNDEFINED_TAG */
  return undefined;
}

unsigned char *zjs_compile_to_bytecode(ZjsContext *ctx, const char *source, size_t *out_len) {
  if (out_len != NULL) *out_len = 0;
  if (ctx == NULL || source == NULL) return NULL;
  size_t length = 0;
  uintptr_t buffer = zjs_z_compile_to_bytecode((uintptr_t)ctx, (const uint8_t *)source, strlen(source), (uintptr_t)&length);
  if (out_len != NULL) *out_len = length;
  return (unsigned char *)buffer;
}

/* The handler runs on the thread evaluating ctx, so it sees no engine
   state from another thread; it is handed to the Z side as two words. */
void zjs_set_interrupt_handler(ZjsContext *ctx, ZjsInterruptHandler handler, void *opaque) {
  if (ctx == NULL) return;
  zjs_z_set_interrupt_handler((uintptr_t)ctx, (uintptr_t)handler, (uintptr_t)opaque);
}

int zjs_is_interrupted(ZjsContext *ctx) {
  if (ctx == NULL) return 0;
  return (int)zjs_z_was_interrupted((uintptr_t)ctx);
}

int zjs_had_error(ZjsContext *ctx) {
  if (ctx == NULL) return 1;
  return (int)zjs_z_had_error((uintptr_t)ctx);
}
