/* The embedding lifecycle, exercised through the frozen zjs.h ABI with
   the library's internal counters as witnesses. Built and run by
   build.sh. Orderings are fixed with condition variables, not sleeps;
   overlap between independent contexts is shown by wall time. */
#include <malloc/malloc.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "zjs.h"
#include "zjs_regexp.h"
#include "zjsz.h"

static int failures = 0;
#define CHECK(condition, what) do { if (!(condition)) { failures++; fprintf(stderr, "lifecycle: FAIL %s\n", what); } } while (0)

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

/* 2. Independent contexts overlap: two long evaluations on two threads
   take about as long as one. */
typedef struct { ZjsContext *ctx; int ok; } Worker;
static void *evaluate_long(void *argument) {
  Worker *worker = (Worker *)argument;
  zjs_eval(worker->ctx, LONG_SCRIPT);
  worker->ok = zjs_had_error(worker->ctx) == 0;
  return NULL;
}
static void overlap(void) {
  Worker a = { zjs_new_context(), 0 }, b = { zjs_new_context(), 0 };
  double t = now_seconds();
  evaluate_long(&a);
  double single = now_seconds() - t;
  pthread_t ta, tb;
  t = now_seconds();
  pthread_create(&ta, NULL, evaluate_long, &a);
  pthread_create(&tb, NULL, evaluate_long, &b);
  pthread_join(ta, NULL);
  pthread_join(tb, NULL);
  double both = now_seconds() - t;
  CHECK(a.ok && b.ok, "overlap: both evaluations succeed");
  CHECK(both < single * 1.6, "overlap: two contexts in parallel take about one context's time");
  printf("lifecycle: one context %.3fs, two concurrently %.3fs\n", single, both);
  zjs_free_context(a.ctx);
  zjs_free_context(b.ctx);
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
  pthread_create(&ta, NULL, evaluate_add, ctx);
  pthread_create(&tb, NULL, evaluate_add, ctx);
  pthread_join(ta, NULL);
  pthread_join(tb, NULL);
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
  pthread_mutex_lock(&race->lock);
  while (race->stage < stage) pthread_cond_wait(&race->changed, &race->lock);
  pthread_mutex_unlock(&race->lock);
}
static void advance(Race *race, int stage) {
  pthread_mutex_lock(&race->lock);
  race->stage = stage;
  pthread_cond_broadcast(&race->changed);
  pthread_mutex_unlock(&race->lock);
}
/* The evaluator holds the context lock across a long script; the freer
   runs once the evaluator is known to be inside. The evaluator marks
   admission by an evaluation that sets a global, then runs the long one:
   the freer waits for the first result, so the long evaluation is either
   admitted or queued behind an admitted call when free runs. */
static void *free_after_admission_evaluator(void *argument) {
  Race *race = (Race *)argument;
  zjs_eval(race->ctx, "var admitted = 1;");
  advance(race, 1);
  zjs_eval(race->ctx, LONG_SCRIPT);
  race->evaluator_error = zjs_had_error(race->ctx);
  return NULL;
}
static void free_after_admission(void) {
  Race race = { zjs_new_context(), PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0, 0 };
  uintptr_t native_before = zjs_re_live_contexts();
  pthread_t evaluator;
  pthread_create(&evaluator, NULL, free_after_admission_evaluator, &race);
  wait_for(&race, 1);
  zjs_free_context(race.ctx);           /* returns without waiting for the evaluation */
  CHECK(zjs_had_error(race.ctx) == 1, "free after admission: the handle is stale at once");
  pthread_join(evaluator, NULL);
  /* had_error on a stale handle reports 1; the evaluator saw its own
     result through the reference it held: no crash, no refusal. */
  CHECK(zjs_re_live_contexts() == native_before - 1, "free after admission: native context destroyed once the evaluation returned");
  printf("lifecycle: free after admission: evaluator finished with error flag %d, native contexts %lu\n", race.evaluator_error, (unsigned long)zjs_re_live_contexts());
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
  pthread_create(&evaluator, NULL, free_before_lookup_evaluator, &race);
  zjs_free_context(race.ctx);
  advance(&race, 2);
  pthread_join(evaluator, NULL);
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

int main(void) {
  ZjsContext *probe = zjs_new_context();
  CHECK(probe != NULL, "initialization on the main thread");
  zjs_free_context(probe);
  cycles();
  overlap();
  serialization();
  free_after_admission();
  free_before_lookup();
  stale_handles();
  pending_jobs();
  printf("lifecycle: created %llu, detached %llu, live %u, native contexts %lu\n", (unsigned long long)zjs_z_created_contexts(), (unsigned long long)zjs_z_detached_contexts(), zjs_z_live_contexts(), (unsigned long)zjs_re_live_contexts());
  CHECK(zjs_z_live_contexts() == 0 && zjs_re_live_contexts() == 0, "final: nothing left alive");
  if (failures != 0) { fprintf(stderr, "lifecycle: %d failures\n", failures); return 1; }
  printf("lifecycle: ok\n");
  return 0;
}
