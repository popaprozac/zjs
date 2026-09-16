/* See zjs_regexp.h. */
#include "zjs_regexp.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "libregexp.h"

/* --- Host callbacks libregexp requires --- */

static uintptr_t stack_budget = 256 * 1024;
static uintptr_t stack_floor = 0;
static uintptr_t step_budget = 0;
static uintptr_t steps_left = 0;
static int last_failure = 0;

void *lre_realloc(void *opaque, void *ptr, size_t size) {
  (void)opaque;
  if (size == 0) {
    free(ptr);
    return NULL;
  }
  return realloc(ptr, size);
}

bool lre_check_stack_overflow(void *opaque, size_t alloca_size) {
  (void)opaque;
  char probe;
  uintptr_t here = (uintptr_t)&probe;
  if (stack_floor == 0) return false;
  if (here < alloca_size || here - alloca_size < stack_floor) {
    last_failure = ZJS_RE_STACK_LIMIT;
    return true;
  }
  return false;
}

int lre_check_timeout(void *opaque) {
  (void)opaque;
  if (step_budget == 0) return 0;
  if (steps_left == 0) {
    last_failure = ZJS_RE_STEP_LIMIT;
    return 1;
  }
  steps_left -= 1;
  return 0;
}

static void enter(void) {
  char probe;
  uintptr_t here = (uintptr_t)&probe;
  stack_floor = here > stack_budget ? here - stack_budget : 1;
  steps_left = step_budget;
  last_failure = 0;
}

static void leave(void) {
  stack_floor = 0;
}

void zjs_re_set_stack_budget(uintptr_t bytes) {
  stack_budget = bytes;
}

void zjs_re_set_step_budget(uintptr_t checks) {
  step_budget = checks;
}

/* --- Buffers --- */

static uint8_t *scratch = NULL;
static uintptr_t scratch_capacity = 0;

uintptr_t zjs_re_scratch(uintptr_t length) {
  if (length + 1 > scratch_capacity) {
    uintptr_t wanted = scratch_capacity * 2;
    if (wanted < length + 1) wanted = length + 1;
    if (wanted < 256) wanted = 256;
    uint8_t *grown = (uint8_t *)realloc(scratch, wanted);
    if (grown == NULL) return 0;
    scratch = grown;
    scratch_capacity = wanted;
  }
  return (uintptr_t)scratch;
}

/* --- Compiled patterns --- */

typedef struct {
  uint8_t *bytecode;
  int length;
  int captures;
  int flags;
} Pattern;

static uintptr_t live_handles = 0;
static uintptr_t live_bytes = 0;
static char error_message[128];

uintptr_t zjs_re_compile(uintptr_t pattern, uintptr_t length, int flags) {
  int bytecode_length = 0;
  /* The v flag is unicode mode with set notation. */
  if (flags & LRE_FLAG_UNICODE_SETS) flags |= LRE_FLAG_UNICODE;
  /* The parser peeks one byte past the end; the scratch has room for it. */
  ((uint8_t *)pattern)[length] = 0;
  error_message[0] = 0;
  enter();
  uint8_t *bytecode = lre_compile(&bytecode_length, error_message, (int)sizeof(error_message),
                                  (const char *)pattern, (size_t)length, flags, NULL);
  leave();
  if (bytecode == NULL) {
    if (error_message[0] == 0) strcpy(error_message, "out of memory");
    return 0;
  }
  Pattern *compiled = (Pattern *)malloc(sizeof(Pattern));
  if (compiled == NULL) {
    lre_realloc(NULL, bytecode, 0);
    strcpy(error_message, "out of memory");
    return 0;
  }
  compiled->bytecode = bytecode;
  compiled->length = bytecode_length;
  compiled->captures = lre_get_capture_count(bytecode);
  compiled->flags = lre_get_flags(bytecode);
  live_handles += 1;
  live_bytes += (uintptr_t)bytecode_length;
  return (uintptr_t)compiled;
}

int zjs_re_error_byte(int index) {
  if (index < 0 || index >= (int)sizeof(error_message)) return -1;
  unsigned char byte = (unsigned char)error_message[index];
  return byte == 0 ? -1 : (int)byte;
}

void zjs_re_free(uintptr_t handle) {
  Pattern *compiled = (Pattern *)handle;
  if (compiled == NULL) return;
  live_handles -= 1;
  live_bytes -= (uintptr_t)compiled->length;
  lre_realloc(NULL, compiled->bytecode, 0);
  free(compiled);
}

int zjs_re_capture_count(uintptr_t handle) {
  return ((Pattern *)handle)->captures;
}

int zjs_re_has_names(uintptr_t handle) {
  return (((Pattern *)handle)->flags & LRE_FLAG_NAMED_GROUPS) != 0;
}

int zjs_re_name_byte(uintptr_t handle, int index) {
  Pattern *compiled = (Pattern *)handle;
  const char *names = lre_get_groupnames(compiled->bytecode);
  if (names == NULL || index < 0) return -1;
  /* Names occupy (captures - 1) NUL-terminated strings; walk to the end. */
  const char *cursor = names;
  int remaining = compiled->captures - 1;
  int total = 0;
  while (remaining > 0) {
    int len = (int)strlen(cursor) + 1;
    total += len;
    cursor += len;
    remaining -= 1;
  }
  if (index >= total) return -1;
  return (int)(unsigned char)names[index];
}

/* --- Matching --- */

/* libregexp caps a pattern at 255 groups. */
#define ZJS_RE_MAX_CAPTURES 255
static uint8_t **captures = NULL;
static int capture_slots = 0;
static int capture_starts[ZJS_RE_MAX_CAPTURES];
static int capture_ends[ZJS_RE_MAX_CAPTURES];
static int capture_total = 0;

static uint16_t *units = NULL;
static uint32_t *unit_bytes = NULL; /* unit_bytes[k] = byte where unit k starts; [count] = length */
static uintptr_t unit_capacity = 0;

static bool reserve_units(uintptr_t count) {
  if (count + 1 <= unit_capacity) return true;
  uintptr_t wanted = (count + 1) * 2;
  uint16_t *new_units = (uint16_t *)realloc(units, wanted * sizeof(uint16_t));
  if (new_units == NULL) return false;
  units = new_units;
  uint32_t *new_bytes = (uint32_t *)realloc(unit_bytes, wanted * sizeof(uint32_t));
  if (new_bytes == NULL) return false;
  unit_bytes = new_bytes;
  unit_capacity = wanted;
  return true;
}

/* The length of a well-formed UTF-8 sequence at `at`, or 0. */
static int sequence_length(const uint8_t *bytes, uintptr_t length, uintptr_t at) {
  uint8_t lead = bytes[at];
  int need;
  uint32_t min;
  if (lead < 0x80) return 1;
  if (lead >= 0xC2 && lead <= 0xDF) { need = 1; min = 0x80; }
  else if (lead >= 0xE0 && lead <= 0xEF) { need = 2; min = 0x800; }
  else if (lead >= 0xF0 && lead <= 0xF4) { need = 3; min = 0x10000; }
  else return 0;
  if (at + (uintptr_t)need >= length) return 0;
  uint32_t value = lead & (0x3F >> need);
  for (int k = 1; k <= need; k++) {
    uint8_t next = bytes[at + (uintptr_t)k];
    if ((next & 0xC0) != 0x80) return 0;
    value = (value << 6) | (next & 0x3F);
  }
  if (value < min || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) return 0;
  return need + 1;
}

/* Transcode to UTF-16 units with the byte map; the unit count. */
static uintptr_t transcode(const uint8_t *bytes, uintptr_t length) {
  uintptr_t at = 0;
  uintptr_t count = 0;
  while (at < length) {
    int len = sequence_length(bytes, length, at);
    if (len <= 1) {
      units[count] = bytes[at];
      unit_bytes[count] = (uint32_t)at;
      count += 1;
      at += 1;
      continue;
    }
    uint32_t value = bytes[at] & (0x3F >> (len - 1));
    for (int k = 1; k < len; k++) value = (value << 6) | (bytes[at + (uintptr_t)k] & 0x3F);
    if (value >= 0x10000) {
      value -= 0x10000;
      units[count] = (uint16_t)(0xD800 + (value >> 10));
      unit_bytes[count] = (uint32_t)at;
      count += 1;
      units[count] = (uint16_t)(0xDC00 + (value & 0x3FF));
      unit_bytes[count] = (uint32_t)(at + (uintptr_t)len);
      count += 1;
    } else {
      units[count] = (uint16_t)value;
      unit_bytes[count] = (uint32_t)at;
      count += 1;
    }
    at += (uintptr_t)len;
  }
  unit_bytes[count] = (uint32_t)length;
  return count;
}

/* The first unit starting at or after the byte offset. */
static uintptr_t unit_at_byte(uintptr_t count, uintptr_t byte) {
  uintptr_t low = 0;
  uintptr_t high = count;
  while (low < high) {
    uintptr_t mid = low + (high - low) / 2;
    if (unit_bytes[mid] < byte) low = mid + 1; else high = mid;
  }
  return low;
}

int zjs_re_exec(uintptr_t handle, uintptr_t input, uintptr_t length, uintptr_t start) {
  Pattern *compiled = (Pattern *)handle;
  const uint8_t *bytes = (const uint8_t *)input;
  ((uint8_t *)input)[length] = 0;
  capture_total = compiled->captures;
  if (capture_total > ZJS_RE_MAX_CAPTURES) return ZJS_RE_BAD_BYTECODE;
  if (capture_total > capture_slots) {
    uint8_t **grown = (uint8_t **)realloc(captures, sizeof(uint8_t *) * 2 * (size_t)capture_total);
    if (grown == NULL) return ZJS_RE_OUT_OF_MEMORY;
    captures = grown;
    capture_slots = capture_total;
  }
  bool ascii = true;
  for (uintptr_t k = 0; k < length; k++) {
    if (bytes[k] >= 0x80) { ascii = false; break; }
  }
  if (start > length) start = length;
  int result;
  enter();
  if (ascii) {
    result = lre_exec(captures, compiled->bytecode, bytes, (int)start, (int)length, 0, NULL);
    leave();
    if (result < 0) return last_failure != 0 ? last_failure : result;
    if (result == 0) return ZJS_RE_NO_MATCH;
    for (int g = 0; g < capture_total; g++) {
      const uint8_t *from = captures[2 * g];
      const uint8_t *to = captures[2 * g + 1];
      capture_starts[g] = from == NULL ? -1 : (int)(from - bytes);
      capture_ends[g] = to == NULL ? -1 : (int)(to - bytes);
    }
    return ZJS_RE_MATCH;
  }
  if (!reserve_units(length)) { leave(); return ZJS_RE_OUT_OF_MEMORY; }
  uintptr_t count = transcode(bytes, length);
  uintptr_t start_unit = unit_at_byte(count, start);
  /* Type 1 is 16-bit units; the matcher itself reads surrogate pairs as
     code points when the bytecode was compiled in unicode mode. */
  result = lre_exec(captures, compiled->bytecode, (const uint8_t *)units, (int)start_unit, (int)count, 1, NULL);
  leave();
  if (result < 0) return last_failure != 0 ? last_failure : result;
  if (result == 0) return ZJS_RE_NO_MATCH;
  for (int g = 0; g < capture_total; g++) {
    const uint8_t *from = captures[2 * g];
    const uint8_t *to = captures[2 * g + 1];
    if (from == NULL || to == NULL) {
      capture_starts[g] = -1;
      capture_ends[g] = -1;
    } else {
      uintptr_t from_unit = (uintptr_t)(from - (const uint8_t *)units) / 2;
      uintptr_t to_unit = (uintptr_t)(to - (const uint8_t *)units) / 2;
      capture_starts[g] = (int)unit_bytes[from_unit];
      capture_ends[g] = (int)unit_bytes[to_unit];
    }
  }
  return ZJS_RE_MATCH;
}

int zjs_re_capture_start(int group) {
  if (group < 0 || group >= capture_total) return -1;
  return capture_starts[group];
}

int zjs_re_capture_end(int group) {
  if (group < 0 || group >= capture_total) return -1;
  return capture_ends[group];
}

uintptr_t zjs_re_live_handles(void) {
  return live_handles;
}

uintptr_t zjs_re_live_bytes(void) {
  return live_bytes;
}
