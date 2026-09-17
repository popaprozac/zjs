// Allocation attribution by call site, for a process it is inserted into:
//
//   clang -O2 -dynamiclib -o alloc-attr.dylib alloc-attr.c
//   DYLD_INSERT_LIBRARIES=alloc-attr.dylib ATTR_OUT=sites.txt zjsz run file.js
//
// Where malloc-count.c counts calls, this attributes each malloc, calloc,
// and realloc to the first frames outside the allocator's own plumbing
// (Z's array growth and string helpers), by count and by bytes requested,
// and keeps the bytes live (by malloc_size) and their peak.
//
//   ATTR_OUT    file for the report (default stderr)
//   ATTR_DEPTH  frames that identify a site, 1 to 8 (default 4)
//   ATTR_TOP    sites printed, most calls first (default 25)
//   ATTR_RAW    set to keep the plumbing frames
//   ATTR_BIG    set to print every free of 8 MB or more with live bytes
//
// The report is one `ATTR` line of totals, then for each site a `SITE`
// line (kind, count, bytes, average) and its frames, symbolized with
// dladdr, so the binary must keep its symbols. macOS; measurement only.
#include <dlfcn.h>
#include <execinfo.h>
#include <malloc/malloc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
  __attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_##_replacee \
  __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

#define MAX_DEPTH 8
#define TABLE (1u << 16)
typedef struct { uint64_t key; void *frames[MAX_DEPTH]; int depth; uint64_t count, bytes; int kind; } Site;
static Site table[TABLE];
static uint64_t n_malloc, n_calloc, n_realloc, n_free, b_total, live, peak;
static __thread int busy;
static int depth_wanted = 4, skip_names = 1;

static int plumbing(void *addr) {
  Dl_info info;
  if (!dladdr(addr, &info) || !info.dli_sname) return 0;
  const char *n = info.dli_sname;
  // Z's array growth and string helpers sit between the engine and malloc.
  return strstr(n, "z_array_") || strstr(n, "z_rt_alloc") || strstr(n, "z_alloc") || strstr(n, "_grow") || strstr(n, "reserve")
      || strstr(n, "z_string_") || strstr(n, "z_mem") || strstr(n, "realloc") || strstr(n, "malloc") || strstr(n, "calloc");
}

static void record(size_t size, int kind) {
  void *raw[32];
  int n = backtrace(raw, 32);
  int start = 2; // record, the hook
  if (skip_names) { while (start < n - 1 && plumbing(raw[start])) start++; }
  uint64_t key = 1469598103934665603ull ^ (uint64_t)kind;
  int depth = 0;
  void *frames[MAX_DEPTH];
  for (int i = start; i < n && depth < depth_wanted; i++) { frames[depth++] = raw[i]; key = (key ^ (uint64_t)raw[i]) * 1099511628211ull; }
  uint32_t at = (uint32_t)(key >> 17) & (TABLE - 1);
  for (uint32_t probe = 0; probe < TABLE; probe++) {
    Site *s = &table[(at + probe) & (TABLE - 1)];
    if (s->count == 0) { s->key = key; s->depth = depth; s->kind = kind; memcpy(s->frames, frames, sizeof(void *) * depth); }
    if (s->key == key) { s->count++; s->bytes += size; return; }
  }
}

static void *hook_malloc(size_t size) {
  void *p = malloc(size);
  if (busy) return p;
  busy = 1; n_malloc++; b_total += size; live += malloc_size(p); if (live > peak) peak = live; record(size, 0); busy = 0;
  return p;
}
static void *hook_calloc(size_t count, size_t size) {
  void *p = calloc(count, size);
  if (busy) return p;
  busy = 1; n_calloc++; b_total += count * size; live += malloc_size(p); if (live > peak) peak = live; record(count * size, 1); busy = 0;
  return p;
}
static void *hook_realloc(void *old, size_t size) {
  size_t before = old ? malloc_size(old) : 0;
  void *p = realloc(old, size);
  if (busy) return p;
  busy = 1; n_realloc++; b_total += size; live += malloc_size(p); live -= before; if (live > peak) peak = live; record(size, 2); busy = 0;
  return p;
}
static int trace_big;
static void hook_free(void *p) {
  if (p && !busy) {
    size_t sz = malloc_size(p);
    n_free++; live -= sz;
    if (trace_big && sz >= (8u << 20)) { busy = 1; fprintf(stderr, "BIGFREE %zu MB, live now %llu MB\n", sz >> 20, live >> 20); busy = 0; }
  }
  free(p);
}
DYLD_INTERPOSE(hook_malloc, malloc)
DYLD_INTERPOSE(hook_calloc, calloc)
DYLD_INTERPOSE(hook_realloc, realloc)
DYLD_INTERPOSE(hook_free, free)

static int by_count(const void *a, const void *b) { const Site *x = a, *y = b; return x->count < y->count ? 1 : x->count > y->count ? -1 : 0; }

__attribute__((constructor)) static void setup(void) {
  const char *d = getenv("ATTR_DEPTH"); if (d) depth_wanted = atoi(d);
  if (depth_wanted < 1) depth_wanted = 1; if (depth_wanted > MAX_DEPTH) depth_wanted = MAX_DEPTH;
  const char *r = getenv("ATTR_RAW"); if (r) skip_names = 0;
  if (getenv("ATTR_BIG")) trace_big = 1;
}

__attribute__((destructor)) static void report(void) {
  busy = 1;
  const char *t = getenv("ATTR_TOP"); int top = t ? atoi(t) : 25;
  const char *out = getenv("ATTR_OUT"); FILE *f = out ? fopen(out, "w") : stderr; if (!f) f = stderr;
  fprintf(f, "ATTR malloc=%llu calloc=%llu realloc=%llu free=%llu requested_bytes=%llu live_at_exit=%llu peak_live=%llu\n",
          n_malloc, n_calloc, n_realloc, n_free, b_total, live, peak);
  qsort(table, TABLE, sizeof(Site), by_count);
  static const char *kinds[] = { "malloc", "calloc", "realloc" };
  for (int i = 0; i < top && table[i].count; i++) {
    fprintf(f, "SITE %s count=%llu bytes=%llu avg=%.1f\n", kinds[table[i].kind], table[i].count, table[i].bytes, (double)table[i].bytes / (double)table[i].count);
    for (int k = 0; k < table[i].depth; k++) {
      Dl_info info; const char *name = "?"; long off = 0;
      if (dladdr(table[i].frames[k], &info) && info.dli_sname) { name = info.dli_sname; off = (long)((char *)table[i].frames[k] - (char *)info.dli_saddr); }
      fprintf(f, "    %s+%ld\n", name, off);
    }
  }
  if (f != stderr) fclose(f);
}
