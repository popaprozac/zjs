/* Two threads, two backend contexts, no shared state: each compiles its
   own pattern and matches ten thousand times, checking every capture, and
   the accounting stays per context. Built and run by build.sh. */
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include "zjs_regexp.h"

typedef struct {
  const char *pattern;
  const char *input;
  int expect_start;
  int expect_end;
  int expect_group_start;
  int failures;
  uintptr_t handles;
} Job;

static void *run(void *argument) {
  Job *job = (Job *)argument;
  uintptr_t context = zjs_re_context_new();
  size_t pattern_length = strlen(job->pattern);
  uintptr_t scratch = zjs_re_scratch(context, pattern_length);
  memcpy((void *)scratch, job->pattern, pattern_length);
  uintptr_t handle = zjs_re_compile(context, scratch, pattern_length, 0);
  if (handle == 0) { job->failures += 1000000; return NULL; }
  size_t input_length = strlen(job->input);
  for (int round = 0; round < 10000; round++) {
    uintptr_t buffer = zjs_re_scratch(context, input_length);
    memcpy((void *)buffer, job->input, input_length);
    int result = zjs_re_exec(context, handle, buffer, input_length, 0, 0);
    if (result != ZJS_RE_MATCH) { job->failures++; continue; }
    if (zjs_re_capture_start(context, 0) != job->expect_start) job->failures++;
    if (zjs_re_capture_end(context, 0) != job->expect_end) job->failures++;
    if (zjs_re_capture_start(context, 1) != job->expect_group_start) job->failures++;
  }
  job->handles = zjs_re_live_handles(context);
  zjs_re_free(handle);
  if (zjs_re_live_handles(context) != 0) job->failures++;
  zjs_re_context_free(context);
  return NULL;
}

int main(void) {
  Job first = { "(b+)c", "aabbbcd", 2, 6, 2, 0, 0 };
  Job second = { "x(y)?z", "..xz..", 2, 4, -1, 0, 0 };
  pthread_t threads[2];
  pthread_create(&threads[0], NULL, run, &first);
  pthread_create(&threads[1], NULL, run, &second);
  pthread_join(threads[0], NULL);
  pthread_join(threads[1], NULL);
  if (first.failures != 0 || second.failures != 0 || first.handles != 1 || second.handles != 1) {
    fprintf(stderr, "regex contexts: failures %d %d handles %lu %lu\n", first.failures, second.failures,
            (unsigned long)first.handles, (unsigned long)second.handles);
    return 1;
  }
  printf("regex contexts: two threads, two contexts, 20000 matches, isolated\n");
  return 0;
}
