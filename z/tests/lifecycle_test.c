/* The embedding lifecycle, exercised through the frozen zjs.h ABI with
   the library's internal counters as witnesses. Built and run by
   build.sh. Orderings are fixed with condition variables, not sleeps;
   overlap between independent contexts is shown by wall time. The
   runtime is initialized by the first ABI call on a worker thread and
   shut down on another: the library has no main-thread requirement. */
#include <malloc/malloc.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "zjs.h"
#include "zjs_regexp.h"
#include "zjs_testing.h"
#include "zjsz.h"

/* Shim-level, not in the frozen header: the last initialization status. */
int zjs_shim_init_status(void);

_Static_assert(ZJSZ_RUNTIME_REQUIRES_MAIN_THREAD == 0, "worker-first initialization needs a main-independent library");
_Static_assert(ZJSZ_RUNTIME_REQUIRES_ENQUEUE_RELEASE == 0, "worker-first initialization needs a main-independent library");

static int failures = 0;
#define CHECK(condition, what) do { if (!(condition)) { failures++; fprintf(stderr, "lifecycle: FAIL %s\n", what); } } while (0)
#define MUST(call, what) do { if ((call) != 0) { failures++; fprintf(stderr, "lifecycle: FAIL %s\n", what); } } while (0)

static double now_seconds(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static const char *LONG_SCRIPT = "var s = 0; for (var i = 0; i < 4000000; i++) { s = (s + i) | 0; } s;";

/* 1. Create, evaluate, destroy, a thousand times: no growth. */
static void cycles(void) {
  size_t used_after_first = 0;
  unsigned long long detached_before = zjs_z_detached_contexts();
  for (int i = 0; i < 1000; i++) {
    ZjsContext *ctx = zjs_new_context();
    CHECK(ctx != NULL, "cycle: context");
    zjs_eval(ctx, "var a = [1, 2, 3].map(function (x) { return x * 2; }); /a+/.test('caaat') && a.join(',') === '2,4,6';");
    CHECK(zjs_had_error(ctx) == 0, "cycle: eval");
    zjs_free_context(ctx);
    if (i == 0) used_after_first = mstats().bytes_used;
  }
  size_t used_after_last = mstats().bytes_used;
  CHECK(zjs_z_live_contexts() == 0, "cycle: live contexts back to zero");
  CHECK(zjs_re_live_contexts() == 0, "cycle: native regex contexts back to zero");
  CHECK(zjs_z_detached_contexts() == detached_before + 1000, "cycle: detached count");
  CHECK(used_after_last <= used_after_first + 2 * 1024 * 1024, "cycle: heap in use bounded");
  printf("lifecycle: 1000 cycles, %zu -> %zu bytes in use, native contexts %lu\n", used_after_first, used_after_last, (unsigned long)zjs_re_live_contexts());
}

/* 2. Independent contexts overlap. Proof by synchronization: each
   evaluator pauses at its gate while holding its context lock, and the
   test observes both paused at once before resuming either. The timing
   of two long evaluations against one is printed as a benchmark, not
   asserted. */
typedef struct { ZjsContext *ctx; zjs_gate gate; int result; } Gated;
static void *evaluate_gated(void *argument) {
  Gated *gated = (Gated *)argument;
  gated->result = zjs_z_eval_gated((uintptr_t)gated->ctx, (const uint8_t *)"var v = 1;", strlen("var v = 1;"), (uintptr_t)&gated->gate);
  return NULL;
}
typedef struct { ZjsContext *ctx; int ok; } Worker;
static void *evaluate_long(void *argument) {
  Worker *worker = (Worker *)argument;
  zjs_eval(worker->ctx, LONG_SCRIPT);
  worker->ok = zjs_had_error(worker->ctx) == 0;
  return NULL;
}
static void overlap(void) {
  Gated a, b;
  a.ctx = zjs_new_context(); zjs_gate_init(&a.gate); a.result = -2;
  b.ctx = zjs_new_context(); zjs_gate_init(&b.gate); b.result = -2;
  pthread_t ta, tb;
  MUST(pthread_create(&ta, NULL, evaluate_gated, &a), "pthread_create");
  MUST(pthread_create(&tb, NULL, evaluate_gated, &b), "pthread_create");
  int a_arrived = zjs_gate_await_arrival(&a.gate);
  int b_arrived = zjs_gate_await_arrival(&b.gate);
  /* Both evaluations are inside their locked work now. */
  CHECK(a_arrived && b_arrived, "overlap: two contexts inside their evaluations at once");
  zjs_gate_resume(&a.gate);
  zjs_gate_resume(&b.gate);
  MUST(pthread_join(ta, NULL), "pthread_join");
  MUST(pthread_join(tb, NULL), "pthread_join");
  CHECK(a.result == 0 && b.result == 0, "overlap: both gated evaluations completed without error");
  zjs_free_context(a.ctx);
  zjs_free_context(b.ctx);
  /* Benchmark line: one long evaluation, then two on two threads. */
  Worker wa = { zjs_new_context(), 0 }, wb = { zjs_new_context(), 0 };
  double t = now_seconds();
  evaluate_long(&wa);
  double single = now_seconds() - t;
  t = now_seconds();
  MUST(pthread_create(&ta, NULL, evaluate_long, &wa), "pthread_create");
  MUST(pthread_create(&tb, NULL, evaluate_long, &wb), "pthread_create");
  MUST(pthread_join(ta, NULL), "pthread_join");
  MUST(pthread_join(tb, NULL), "pthread_join");
  double both = now_seconds() - t;
  CHECK(wa.ok && wb.ok, "overlap: both long evaluations succeed");
  printf("lifecycle: one context %.3fs, two concurrently %.3fs (benchmark, not asserted)\n", single, both);
  zjs_free_context(wa.ctx);
  zjs_free_context(wb.ctx);
}

/* 3. One context serializes: two threads adding to one global never
   interleave inside an evaluation. */
static void *evaluate_add(void *argument) {
  ZjsContext *ctx = (ZjsContext *)argument;
  for (int i = 0; i < 200; i++) zjs_eval(ctx, "for (var k = 0; k < 1000; k++) { total = total + 1; }");
  return NULL;
}
static void serialization(void) {
  ZjsContext *ctx = zjs_new_context();
  zjs_eval(ctx, "var total = 0;");
  pthread_t ta, tb;
  MUST(pthread_create(&ta, NULL, evaluate_add, ctx), "pthread_create");
  MUST(pthread_create(&tb, NULL, evaluate_add, ctx), "pthread_create");
  MUST(pthread_join(ta, NULL), "pthread_join");
  MUST(pthread_join(tb, NULL), "pthread_join");
  zjs_eval(ctx, "if (total !== 400000) throw new Error('interleaved: ' + total);");
  CHECK(zjs_had_error(ctx) == 0, "serialization: total is exact");
  CHECK(zjs_z_eval_count((uintptr_t)ctx) == 402, "serialization: every evaluation counted");
  zjs_free_context(ctx);
}

/* 4 and 5. free against an in-flight evaluation, both orderings. */
typedef struct {
  ZjsContext *ctx;
  pthread_mutex_t lock;
  pthread_cond_t changed;
  int stage; /* 0 start; 1 evaluator admitted; 2 freer done */
  int evaluator_error;
} Race;
static void wait_for(Race *race, int stage) {
  struct timespec deadline;
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += ZJS_GATE_LIMIT_SECONDS;
  pthread_mutex_lock(&race->lock);
  while (race->stage < stage) {
    if (pthread_cond_timedwait(&race->changed, &race->lock, &deadline) != 0) {
      CHECK(0, "race: waited past the limit");
      break;
    }
  }
  pthread_mutex_unlock(&race->lock);
}
static void advance(Race *race, int stage) {
  pthread_mutex_lock(&race->lock);
  race->stage = stage;
  pthread_cond_broadcast(&race->changed);
  pthread_mutex_unlock(&race->lock);
}
/* The evaluator is admitted (lookup and retain done, context lock
   taken) and pauses at the gate. The freer then frees the handle: it
   returns at once, the handle is stale, and the native context is still
   alive because the admitted evaluation holds its reference. Resumed, the
   evaluation completes and reports its own result through that
   reference; only then is the context destroyed. */
static void *free_after_admission_evaluator(void *argument) {
  Gated *gated = (Gated *)argument;
  gated->result = zjs_z_eval_gated((uintptr_t)gated->ctx, (const uint8_t *)LONG_SCRIPT, strlen(LONG_SCRIPT), (uintptr_t)&gated->gate);
  return NULL;
}
static void free_after_admission(void) {
  Gated gated;
  gated.ctx = zjs_new_context(); zjs_gate_init(&gated.gate); gated.result = -2;
  uintptr_t native_before = zjs_re_live_contexts();
  pthread_t evaluator;
  MUST(pthread_create(&evaluator, NULL, free_after_admission_evaluator, &gated), "pthread_create");
  CHECK(zjs_gate_await_arrival(&gated.gate), "free after admission: the evaluator arrived at the gate");
  zjs_free_context(gated.ctx);
  CHECK(zjs_had_error(gated.ctx) == 1, "free after admission: the handle is stale at once");
  CHECK(zjs_re_live_contexts() == native_before, "free after admission: the admitted evaluation keeps the context alive");
  zjs_gate_resume(&gated.gate);
  MUST(pthread_join(evaluator, NULL), "pthread_join");
  CHECK(gated.result == 0, "free after admission: the admitted evaluation completed without error");
  CHECK(zjs_re_live_contexts() == native_before - 1, "free after admission: native context destroyed once the evaluation returned");
  printf("lifecycle: free after admission: evaluation completed (result %d), native contexts %lu\n", gated.result, (unsigned long)zjs_re_live_contexts());
}
static void *free_before_lookup_evaluator(void *argument) {
  Race *race = (Race *)argument;
  wait_for(race, 2);
  zjs_eval(race->ctx, "var x = 1;");
  race->evaluator_error = zjs_had_error(race->ctx);
  return NULL;
}
static void free_before_lookup(void) {
  Race race = { zjs_new_context(), PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0, 0 };
  pthread_t evaluator;
  MUST(pthread_create(&evaluator, NULL, free_before_lookup_evaluator, &race), "pthread_create");
  zjs_free_context(race.ctx);
  advance(&race, 2);
  MUST(pthread_join(evaluator, NULL), "pthread_join");
  CHECK(race.evaluator_error == 1, "free before lookup: the evaluation is refused");
}

/* 6. A freed slot reused by a newer context does not answer the old handle. */
static void stale_handles(void) {
  ZjsContext *first = zjs_new_context();
  zjs_free_context(first);
  ZjsContext *second = zjs_new_context();
  CHECK(((uintptr_t)second & 0xFFFFFFFFu) == ((uintptr_t)first & 0xFFFFFFFFu), "stale: the slot is reused");
  CHECK(second != first, "stale: the handle differs by generation");
  zjs_eval(second, "var fresh = 2;");
  CHECK(zjs_had_error(second) == 0, "stale: the new context works");
  CHECK(zjs_had_error(first) == 1, "stale: the old handle is refused");
  zjs_free_context(first);               /* a no-op */
  CHECK(zjs_had_error(second) == 0, "stale: freeing the old handle leaves the new context alone");
  zjs_free_context(second);
  zjs_free_context(second);              /* double free, a no-op */
  zjs_free_context(NULL);
}

/* 7. Promise jobs drain within the evaluation that queued them. */
static void pending_jobs(void) {
  ZjsContext *ctx = zjs_new_context();
  zjs_eval(ctx, "var seen = 0; Promise.resolve(5).then(function (v) { seen = v; });");
  zjs_eval(ctx, "if (seen !== 5) throw new Error('job not drained');");
  CHECK(zjs_had_error(ctx) == 0, "jobs: the reaction ran before control returned");
  zjs_eval(ctx, "Promise.resolve().then(function () { seen = 9; });");
  zjs_free_context(ctx);                 /* nothing pending to discard */
  CHECK(zjs_z_live_contexts() == 0, "jobs: context gone");
}

/* 0. Worker-first: the first ABI call, the one that initializes the
   runtime, runs on a host thread that is not main. */
static void *first_context(void *unused) {
  (void)unused;
  ZjsContext *ctx = zjs_new_context();
  if (ctx == NULL) return (void *)(uintptr_t)0;
  zjs_eval(ctx, "1 + 1");
  int ok = zjs_had_error(ctx) == 0;
  zjs_free_context(ctx);
  return (void *)(uintptr_t)ok;
}

static void worker_first_initialization(void) {
  /* Nothing is published yet: the generated runtime says so without
     entering (an exported call before initialization would trap). */
  CHECK(zjsz_runtime_shutdown() == ZJSZ_RUNTIME_NOT_INITIALIZED, "runtime not initialized before the first call");
  pthread_t worker;
  void *status = NULL;
  MUST(pthread_create(&worker, NULL, first_context, NULL), "pthread_create");
  MUST(pthread_join(worker, &status), "pthread_join");
  CHECK((uintptr_t)status == 1, "initialization by the first call on a worker thread");
  CHECK(zjs_shim_init_status() == (int)ZJSZ_RUNTIME_OK, "worker initialization status ok");
  CHECK(zjsz_runtime_initialize(NULL) == ZJSZ_RUNTIME_ALREADY_INITIALIZED, "runtime published after worker initialization");
}

/* 8. Shutdown on a worker: the generated runtime's shutdown entry (not
   reachable through zjs.h) closes the root on a host thread that is
   neither main nor the initializing one; the root's registry, grown to
   hold many freed slots, is released with it. */
static void *shut_down(void *unused) {
  (void)unused;
  return (void *)(uintptr_t)zjsz_runtime_shutdown();
}

static void worker_shutdown(void) {
  enum { GROWN = 512 };
  ZjsContext *contexts[GROWN];
  for (int i = 0; i < GROWN; i++) contexts[i] = zjs_new_context();
  for (int i = 0; i < GROWN; i++) zjs_free_context(contexts[i]);
  CHECK(zjs_z_live_contexts() == 0, "shutdown: no live contexts");
  size_t used_before = mstats().bytes_used;
  pthread_t worker;
  void *status = NULL;
  MUST(pthread_create(&worker, NULL, shut_down, NULL), "pthread_create");
  MUST(pthread_join(worker, &status), "pthread_join");
  CHECK((uintptr_t)status == ZJSZ_RUNTIME_OK, "shutdown on a worker thread");
  CHECK(zjsz_runtime_initialize(NULL) == ZJSZ_RUNTIME_SHUT_DOWN, "runtime reports shut down afterwards");
  size_t used_after = mstats().bytes_used;
  CHECK(used_after + 8 * 1024 <= used_before, "shutdown: the root's registry released");
  CHECK(zjs_re_live_contexts() == 0, "shutdown: native contexts zero");
  printf("lifecycle: shutdown on a worker, %zu -> %zu bytes in use\n", used_before, used_after);
}

int main(void) {
  worker_first_initialization();
  cycles();
  overlap();
  serialization();
  free_after_admission();
  free_before_lookup();
  stale_handles();
  pending_jobs();
  printf("lifecycle: created %llu, detached %llu, live %u, native contexts %lu\n", (unsigned long long)zjs_z_created_contexts(), (unsigned long long)zjs_z_detached_contexts(), zjs_z_live_contexts(), (unsigned long)zjs_re_live_contexts());
  CHECK(zjs_z_live_contexts() == 0 && zjs_re_live_contexts() == 0, "final: nothing left alive");
  worker_shutdown();
  if (failures != 0) { fprintf(stderr, "lifecycle: %d failures\n", failures); return 1; }
  printf("lifecycle: ok\n");
  return 0;
}
