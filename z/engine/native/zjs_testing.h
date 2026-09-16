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

/* Called by the engine (gate == 0 means no gate): mark arrival, wait for
   the test's resume. */
static inline void zjs_gate_arrive(uintptr_t handle) {
  zjs_gate *gate = (zjs_gate *)handle;
  if (gate == 0) return;
  pthread_mutex_lock(&gate->lock);
  gate->arrived = 1;
  pthread_cond_broadcast(&gate->changed);
  while (!gate->resume) pthread_cond_wait(&gate->changed, &gate->lock);
  pthread_mutex_unlock(&gate->lock);
}

/* Called by the test. */
static inline void zjs_gate_await_arrival(zjs_gate *gate) {
  pthread_mutex_lock(&gate->lock);
  while (!gate->arrived) pthread_cond_wait(&gate->changed, &gate->lock);
  pthread_mutex_unlock(&gate->lock);
}

static inline void zjs_gate_resume(zjs_gate *gate) {
  pthread_mutex_lock(&gate->lock);
  gate->resume = 1;
  pthread_cond_broadcast(&gate->changed);
  pthread_mutex_unlock(&gate->lock);
}

#endif
