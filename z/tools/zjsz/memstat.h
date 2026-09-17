/* What the allocator and the kernel report for this process, for
   `zjsz run --mem-stats`. macOS: malloc zone statistics over every zone,
   the task's current resident size and physical footprint, and the peak
   resident size. Measurement only; nothing in the engine reads these. */
#ifndef ZJSZ_MEMSTAT_H
#define ZJSZ_MEMSTAT_H
#include <libproc.h>
#include <malloc/malloc.h>
#include <sys/resource.h>
#include <unistd.h>

/* Bytes in blocks the program holds. */
static inline double zjsz_alloc_in_use(void) {
  malloc_statistics_t stats;
  malloc_zone_statistics(0, &stats);
  return (double)stats.size_in_use;
}

/* Bytes the allocator has reserved from the system, held or not. */
static inline double zjsz_alloc_reserved(void) {
  malloc_statistics_t stats;
  malloc_zone_statistics(0, &stats);
  return (double)stats.size_allocated;
}

static inline double zjsz_alloc_peak_in_use(void) {
  malloc_statistics_t stats;
  malloc_zone_statistics(0, &stats);
  return (double)stats.max_size_in_use;
}

static inline double zjsz_resident_now(void) {
  struct rusage_info_v2 info;
  if (proc_pid_rusage(getpid(), RUSAGE_INFO_V2, (rusage_info_t *)&info) != 0) return 0.0;
  return (double)info.ri_resident_size;
}

static inline double zjsz_footprint_now(void) {
  struct rusage_info_v2 info;
  if (proc_pid_rusage(getpid(), RUSAGE_INFO_V2, (rusage_info_t *)&info) != 0) return 0.0;
  return (double)info.ri_phys_footprint;
}

static inline double zjsz_resident_peak(void) {
  struct rusage usage;
  if (getrusage(RUSAGE_SELF, &usage) != 0) return 0.0;
  return (double)usage.ru_maxrss;
}
#endif
