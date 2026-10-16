/* Counts allocator calls in a process: DYLD_INSERT_LIBRARIES this dylib
   and the totals print to stderr at exit. Measurement only. */
#include <stdio.h>
#include <stdlib.h>

static unsigned long mallocs, callocs, reallocs, frees;

static void *counting_malloc(size_t size) { mallocs++; return malloc(size); }
static void *counting_calloc(size_t count, size_t size) { callocs++; return calloc(count, size); }
static void *counting_realloc(void *pointer, size_t size) { reallocs++; return realloc(pointer, size); }
static void counting_free(void *pointer) { frees++; free(pointer); }

__attribute__((used)) static const struct { const void *replacement; const void *original; }
interposers[] __attribute__((section("__DATA,__interpose"))) = {
  { (const void *)counting_malloc, (const void *)malloc },
  { (const void *)counting_calloc, (const void *)calloc },
  { (const void *)counting_realloc, (const void *)realloc },
  { (const void *)counting_free, (const void *)free },
};

__attribute__((destructor)) static void report(void) {
  fprintf(stderr, "ALLOC malloc=%lu calloc=%lu realloc=%lu free=%lu\n", mallocs, callocs, reallocs, frees);
}
