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

/* libregexp stops at 64 MiB of bytecode: a pattern of that many single
   characters must come back as the size limit, not syntax or memory. */
static int size_limit_is_distinct(void) {
  uintptr_t context = zjs_re_context_new();
  size_t length = 40u * 1024u * 1024u;
  uintptr_t scratch = zjs_re_scratch(context, length);
  if (scratch == 0) { zjs_re_context_free(context); return 1; }
  memset((void *)scratch, 'a', length);
  uintptr_t handle = zjs_re_compile(context, scratch, length, 0);
  int failure = zjs_re_failure(context);
  int ok = handle == 0 && failure == ZJS_RE_SIZE_LIMIT;
  if (handle != 0) zjs_re_free(handle);
  /* And a plain syntax failure stays syntax. */
  const char *bad = "(";
  uintptr_t small = zjs_re_scratch(context, 1);
  memcpy((void *)small, bad, 1);
  if (zjs_re_compile(context, small, 1, 0) != 0 || zjs_re_failure(context) != ZJS_RE_SYNTAX) ok = 0;
  zjs_re_context_free(context);
  if (!ok) fprintf(stderr, "regex size limit: failure category %d\n", failure);
  return ok ? 0 : 1;
}

int main(void) {
  if (size_limit_is_distinct() != 0) return 1;
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
  printf("regex contexts: two threads, two contexts, 20000 matches, isolated; size limit distinct\n");
  return 0;
}
