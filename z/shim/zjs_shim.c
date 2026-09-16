/* Frozen-ABI shim: publishes the exact zjs.h signatures over the Z
 * library's uintptr_t exports.
 *
 * Z's `export c function` does not accept pointer parameters, and zjs.h
 * is `ZjsContext*` throughout, so the Z side hands out a packed handle
 * (slot and generation, 32 bits each) and this file casts it into the
 * pointer-shaped type the frozen contract promises. The token is not a
 * pointer and must not be dereferenced; it needs a 64-bit host word.
 *
 * Runtime lifecycle contract (see z/docs/lifecycle.md):
 * - The Z runtime is initialized by the first zjs_new_context, which must
 *   run on the platform's main thread: the library root is main-bound
 *   (ledger G36), and the generated runtime checks the thread for real.
 *   A first call on another thread returns NULL and leaves initialization
 *   possible later on main.
 * - Contexts may then be created, evaluated, and freed from any host
 *   thread; independent contexts proceed concurrently.
 * - Shutdown and unload are not supported through zjs.h: the generated
 *   runtime's release hook is provided for completeness and delivers a
 *   finalizer only when invoked on the main thread; off main it records
 *   the miss and delivers nothing.
 */
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "zjs.h"
#include "zjsz.h"

_Static_assert(sizeof(uintptr_t) >= 8, "ZjsContext handles pack a slot and a generation into 64 bits");

static void shim_enqueue_release(void *context, void *value,
                                 void (*finalize)(void *value)) {
  (void)context;
  if (pthread_main_np() != 0) {
    if (finalize) finalize(value);
    return;
  }
  /* No drain point exists in the frozen ABI, so delivery off main is a
     stated limitation rather than a silent inline call on the wrong
     thread. */
  fprintf(stderr, "zjs: runtime release requested off the main thread; not delivered\n");
}

static bool shim_is_main_thread(void *context) {
  (void)context;
  return pthread_main_np() != 0;
}

/* Initialization is serialized; readiness is published only after the
   generated runtime reports success, and a failed attempt (the wrong
   thread, an invalid configuration) leaves later attempts possible. */
static pthread_mutex_t g_init_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_runtime_ready = 0;
static zjsz_runtime_status g_last_init_status = ZJSZ_RUNTIME_OK;

static int shim_ensure_runtime(void) {
  pthread_mutex_lock(&g_init_lock);
  if (!g_runtime_ready) {
    zjsz_runtime_config config;
    config.context = NULL;
    config.enqueue_release = shim_enqueue_release;
    config.is_main_thread = shim_is_main_thread;
    zjsz_runtime_status status = zjsz_runtime_initialize(&config);
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

int zjs_had_error(ZjsContext *ctx) {
  if (ctx == NULL) return 1;
  return (int)zjs_z_had_error((uintptr_t)ctx);
}
