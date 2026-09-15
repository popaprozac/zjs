/* Frozen-ABI shim: publishes the exact zjs.h signatures over the Z
 * library's uintptr_t exports.
 *
 * This exists because Z's `export c function` does not yet accept pointer
 * parameters (finding G7), and zjs.h is `ZjsContext*` throughout. The Z side
 * hands out an opaque handle; this file casts it into the pointer-shaped
 * type the frozen contract promises. The host -- test262_runner.c, Zapp,
 * embed_smoke.c -- sees no difference.
 *
 * It is deliberately mechanical. When G7 lands, or when Z grows an
 * opaque-handle export form, this file shrinks to nothing.
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "zjs.h"
#include "zjsz.h"

/* Phase 1 is single-threaded: release on the calling thread, and report
 * every thread as main. Both become real when the worker model lands. */
static void shim_enqueue_release(void *context, void *value,
                                 void (*finalize)(void *value)) {
  (void)context;
  if (finalize) finalize(value);
}

static bool shim_is_main_thread(void *context) {
  (void)context;
  return true;
}

static int g_runtime_ready = 0;

static void shim_ensure_runtime(void) {
  if (g_runtime_ready) return;
  zjsz_runtime_config config;
  config.context = NULL;
  config.enqueue_release = shim_enqueue_release;
  config.is_main_thread = shim_is_main_thread;
  zjsz_runtime_initialize(&config);
  g_runtime_ready = 1;
}

ZjsContext *zjs_new_context(void) {
  shim_ensure_runtime();
  return (ZjsContext *)(uintptr_t)zjs_z_new_context();
}

void zjs_free_context(ZjsContext *ctx) {
  zjs_z_free_context((uintptr_t)ctx);
}

ZjsValue zjs_eval(ZjsContext *ctx, const char *source) {
  zjs_z_eval((uintptr_t)ctx, source);
  ZjsValue undefined;
  undefined.bits = 10; /* OTHER_TAG | UNDEFINED_TAG */
  return undefined;
}

int zjs_had_error(ZjsContext *ctx) {
  return (int)zjs_z_had_error((uintptr_t)ctx);
}
