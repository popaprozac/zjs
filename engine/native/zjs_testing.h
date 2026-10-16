/*
 * Test-only synchronization for the lifecycle evidence: a gate the C test
 * owns, passed to the engine as a scalar, at which an evaluation pauses
 * after it has been admitted and has taken its context lock, until the
 * test resumes it. Nothing here is part of the embedding ABI.
 */
#ifndef ZJS_TESTING_H
#define ZJS_TESTING_H

#include <pthread.h>
#include <stdint.h>
#include <time.h>

typedef struct zjs_gate {
  pthread_mutex_t lock;
  pthread_cond_t changed;
  int arrived;
  int resume;
} zjs_gate;

static inline void zjs_gate_init(zjs_gate *gate) {
  pthread_mutex_init(&gate->lock, 0);
  pthread_cond_init(&gate->changed, 0);
  gate->arrived = 0;
  gate->resume = 0;
}

/* Waits are bounded: a gate that is not resumed or never arrived at
   within the limit reports failure instead of hanging a build. */
#define ZJS_GATE_LIMIT_SECONDS 30

static inline int zjs_gate_wait_until(zjs_gate *gate, int *flag) {
  struct timespec deadline;
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += ZJS_GATE_LIMIT_SECONDS;
  while (!*flag) {
    if (pthread_cond_timedwait(&gate->changed, &gate->lock, &deadline) != 0) return *flag;
  }
  return 1;
}

/* Called by the engine (gate == 0 means no gate): mark arrival, wait for
   the test's resume; proceeds anyway after the limit. */
static inline void zjs_gate_arrive(uintptr_t handle) {
  zjs_gate *gate = (zjs_gate *)handle;
  if (gate == 0) return;
  pthread_mutex_lock(&gate->lock);
  gate->arrived = 1;
  pthread_cond_broadcast(&gate->changed);
  zjs_gate_wait_until(gate, &gate->resume);
  pthread_mutex_unlock(&gate->lock);
}

/* Called by the test: 1 once the engine has arrived, 0 on timeout. */
static inline int zjs_gate_await_arrival(zjs_gate *gate) {
  pthread_mutex_lock(&gate->lock);
  int arrived = zjs_gate_wait_until(gate, &gate->arrived);
  pthread_mutex_unlock(&gate->lock);
  return arrived;
}

static inline void zjs_gate_resume(zjs_gate *gate) {
  pthread_mutex_lock(&gate->lock);
  gate->resume = 1;
  pthread_cond_broadcast(&gate->changed);
  pthread_mutex_unlock(&gate->lock);
}

#endif
