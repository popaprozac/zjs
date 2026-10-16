/* The interrupt handler, through the public ABI (zjs.h): the engine asks
   it while JavaScript runs, a nonzero answer ends the evaluation with a
   termination no catch or finally sees, and the context stays usable.
   Built against either engine's libzjs.a. Each check that runs to
   completion evaluates a script that throws when its expectation fails. */
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

#include "zjs.h"

typedef struct {
  int calls;
  int stop_after; /* stop on this call; 0 never */
} Gate;

static int gate_handler(void *opaque) {
  Gate *gate = (Gate *)opaque;
  gate->calls += 1;
  return gate->stop_after > 0 && gate->calls >= gate->stop_after;
}

static int failures = 0;

static void fail(const char *what, const char *why) {
  fprintf(stderr, "interrupt: FAIL %s: %s\n", what, why);
  failures += 1;
}

/* A script that must complete. */
static void runs(ZjsContext *ctx, Gate *gate, const char *what, const char *script) {
  gate->calls = 0;
  gate->stop_after = 0;
  zjs_eval(ctx, script);
  if (zjs_had_error(ctx)) fail(what, "threw");
  if (zjs_is_interrupted(ctx)) fail(what, "reported an interrupt");
}

/* A script the handler must stop. */
static void stops(ZjsContext *ctx, Gate *gate, const char *what, const char *script) {
  gate->calls = 0;
  gate->stop_after = 3;
  zjs_eval(ctx, script);
  if (!zjs_had_error(ctx)) fail(what, "no error");
  if (!zjs_is_interrupted(ctx)) fail(what, "not reported as interrupted");
  if (gate->calls != 3) fail(what, "the handler was asked again after it said stop");
}

static atomic_int g_cancel = 0;

static int flag_handler(void *opaque) {
  (void)opaque;
  return atomic_load_explicit(&g_cancel, memory_order_acquire);
}

static void *cancel_later(void *arg) {
  (void)arg;
  struct timespec pause = {0, 50 * 1000 * 1000};
  nanosleep(&pause, NULL);
  atomic_store_explicit(&g_cancel, 1, memory_order_release);
  return NULL;
}

int main(void) {
  ZjsContext *ctx = zjs_new_context();
  if (ctx == NULL) {
    fprintf(stderr, "interrupt: no context\n");
    return 1;
  }
  Gate gate = {0, 0};
  zjs_set_interrupt_handler(ctx, gate_handler, &gate);

  runs(ctx, &gate, "a loop the handler lets run",
       "var s = 0; for (var i = 0; i < 1000000; i++) s += i; if (s !== 499999500000) throw 1;");
  if (gate.calls == 0) fail("a loop the handler lets run", "the handler was never asked");

  stops(ctx, &gate, "an endless loop", "while (true) {}");
  runs(ctx, &gate, "the context after a termination", "if (1 + 1 !== 2) throw 1;");

  stops(ctx, &gate, "a loop inside try, catch, and finally",
        "var reached = 0; try { while (true) {} } catch (e) { reached = 1; } finally { reached = 2; }");
  runs(ctx, &gate, "no catch or finally ran", "if (reached !== 0) throw reached;");

  stops(ctx, &gate, "an endless callback from a builtin",
        "var afterEach = 0; [1, 2, 3].forEach(function () { while (true) {} }); afterEach = 1;");
  runs(ctx, &gate, "the builtin's caller did not go on", "if (afterEach !== 0) throw 1;");

  stops(ctx, &gate, "a promise executor, which would turn a throw into a rejection",
        "var afterPromise = 0; new Promise(function () { while (true) {} }); afterPromise = 1;");
  runs(ctx, &gate, "the executor's caller did not go on", "if (afterPromise !== 0) throw 1;");

  stops(ctx, &gate, "an endless promise job after the script",
        "var synchronous = 0; Promise.resolve().then(function () { while (true) {} }); synchronous = 1;");
  runs(ctx, &gate, "the script itself completed", "if (synchronous !== 1) throw 1;");

  stops(ctx, &gate, "an async function",
        "var afterAsync = 0; async function spin() { while (true) {} } spin(); afterAsync = 1;");
  runs(ctx, &gate, "the async function's caller did not go on", "if (afterAsync !== 0) throw 1;");

  stops(ctx, &gate, "a generator driven by for-of",
        "function* forever() { while (true) yield 1; } for (var v of forever()) {}");

  stops(ctx, &gate, "a catastrophic regular expression",
        "/(a+)+$/.test('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!');");

  runs(ctx, &gate, "an ordinary throw is still catchable",
       "var caught = 0; try { throw new Error('x'); } catch (e) { caught = 1; } if (caught !== 1) throw 1;");
  gate.calls = 0;
  gate.stop_after = 0;
  zjs_eval(ctx, "throw new Error('plain');");
  if (!zjs_had_error(ctx) || zjs_is_interrupted(ctx)) fail("an uncaught throw", "reported as an interrupt");

  /* The embedder's case: another thread asks, through a flag the handler
     reads. */
  zjs_set_interrupt_handler(ctx, flag_handler, NULL);
  pthread_t canceller;
  pthread_create(&canceller, NULL, cancel_later, NULL);
  zjs_eval(ctx, "while (true) {}");
  pthread_join(canceller, NULL);
  if (!zjs_had_error(ctx) || !zjs_is_interrupted(ctx)) fail("a request from another thread", "did not stop");

  zjs_set_interrupt_handler(ctx, NULL, NULL);
  zjs_eval(ctx, "for (var j = 0; j < 100000; j++) {}");
  if (zjs_had_error(ctx) || zjs_is_interrupted(ctx)) fail("with the handler removed", "did not run");

  zjs_free_context(ctx);
  if (failures == 0) printf("interrupt: ok\n");
  return failures == 0 ? 0 : 1;
}
