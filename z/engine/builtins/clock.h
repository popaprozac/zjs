/* Wall clock and local time zone for the Date builtin: three scalar
   functions over libc, so the Z side never sees a struct. */
#ifndef ZJS_CLOCK_H
#define ZJS_CLOCK_H
#include <sys/time.h>
#include <time.h>
#include <math.h>

static inline double zjs_clock_now_ms(void) {
  struct timeval now;
  gettimeofday(&now, 0);
  return (double)now.tv_sec * 1000.0 + (double)(now.tv_usec / 1000);
}

/* Offset of local time from UTC, in milliseconds, at the UTC instant. */
static inline double zjs_local_offset_ms(double utc_ms) {
  if (utc_ms != utc_ms) return 0.0;
  time_t when = (time_t)floor(utc_ms / 1000.0);
  struct tm local;
  if (localtime_r(&when, &local) == 0) return 0.0;
  return (double)local.tm_gmtoff * 1000.0;
}

/* Byte `index` of the local zone abbreviation at the UTC instant, or -1 past its end. */
static inline int zjs_local_zone_byte(double utc_ms, int index) {
  if (utc_ms != utc_ms || index < 0) return -1;
  time_t when = (time_t)floor(utc_ms / 1000.0);
  struct tm local;
  if (localtime_r(&when, &local) == 0 || local.tm_zone == 0) return -1;
  const char *name = local.tm_zone;
  int at = 0;
  while (at < index) { if (name[at] == 0) return -1; at++; }
  return name[at] == 0 ? -1 : (unsigned char)name[at];
}
#endif
