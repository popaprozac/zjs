#ifndef PROBE_LEND_H
#define PROBE_LEND_H
#include <stdint.h>
/* Calls back twice within the call and keeps nothing. */
typedef int32_t (*ProbeLendCallback)(int32_t value, void *context);
static inline int32_t probe_lend_twice(int32_t value, void *context, ProbeLendCallback callback) {
  return callback(callback(value, context), context);
}
#endif
