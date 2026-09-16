/* See zjs_regexp.h. */
#include "zjs_regexp.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "libregexp.h"

/* libregexp caps a pattern at 255 groups. */
#define ZJS_RE_MAX_CAPTURES 255

typedef struct {
  /* Limits and the state of the call in progress. */
  uintptr_t stack_budget;
  uintptr_t stack_floor;
  uintptr_t step_budget;
  uintptr_t steps_left;
  int last_failure;
  char error_message[128];
  /* The scratch buffer Z fills. */
  uint8_t *scratch;
  uintptr_t scratch_capacity;
  /* The last exec's captures. */
  uint8_t **captures;
  int capture_slots;
  int capture_starts[ZJS_RE_MAX_CAPTURES];
  int capture_ends[ZJS_RE_MAX_CAPTURES];
  int capture_total;
  /* Transcoding storage for non-ASCII inputs. */
  uint16_t *units;
  uint32_t *unit_bytes; /* unit_bytes[k] = byte where unit k starts; [count] = length */
  uintptr_t unit_capacity;
  /* Accounting. */
  uintptr_t live_handles;
  uintptr_t live_bytes;
} Context;

typedef struct {
  uint8_t *bytecode;
  int length;
  int captures;
  int flags;
  Context *owner;
} Pattern;

/* --- Host callbacks libregexp requires; `opaque` is the context --- */

void *lre_realloc(void *opaque, void *ptr, size_t size) {
  (void)opaque;
  if (size == 0) {
    free(ptr);
    return NULL;
  }
  return realloc(ptr, size);
}

bool lre_check_stack_overflow(void *opaque, size_t alloca_size) {
  Context *context = (Context *)opaque;
  char probe;
  uintptr_t here = (uintptr_t)&probe;
  if (context == NULL || context->stack_floor == 0) return false;
  if (here < alloca_size || here - alloca_size < context->stack_floor) {
    context->last_failure = ZJS_RE_STACK_LIMIT;
    return true;
  }
  return false;
}

int lre_check_timeout(void *opaque) {
  Context *context = (Context *)opaque;
  if (context == NULL || context->step_budget == 0) return 0;
  if (context->steps_left == 0) {
    context->last_failure = ZJS_RE_STEP_LIMIT;
    return 1;
  }
  context->steps_left -= 1;
  return 0;
}

static void enter(Context *context) {
  char probe;
  uintptr_t here = (uintptr_t)&probe;
  context->stack_floor = here > context->stack_budget ? here - context->stack_budget : 1;
  context->steps_left = context->step_budget;
  context->last_failure = 0;
}

static void leave(Context *context) {
  context->stack_floor = 0;
}

/* --- Contexts --- */

uintptr_t zjs_re_context_new(void) {
  Context *context = (Context *)calloc(1, sizeof(Context));
  if (context == NULL) return 0;
  context->stack_budget = 256 * 1024;
  return (uintptr_t)context;
}

void zjs_re_context_free(uintptr_t handle) {
  Context *context = (Context *)handle;
  if (context == NULL) return;
  free(context->scratch);
  free(context->captures);
  free(context->units);
  free(context->unit_bytes);
  free(context);
}

void zjs_re_set_stack_budget(uintptr_t handle, uintptr_t bytes) {
  ((Context *)handle)->stack_budget = bytes;
}

void zjs_re_set_step_budget(uintptr_t handle, uintptr_t checks) {
  ((Context *)handle)->step_budget = checks;
}

uintptr_t zjs_re_scratch(uintptr_t handle, uintptr_t length) {
  Context *context = (Context *)handle;
  if (length + 1 > context->scratch_capacity) {
    uintptr_t wanted = context->scratch_capacity * 2;
    if (wanted < length + 1) wanted = length + 1;
    if (wanted < 256) wanted = 256;
    uint8_t *grown = (uint8_t *)realloc(context->scratch, wanted);
    if (grown == NULL) return 0;
    context->scratch = grown;
    context->scratch_capacity = wanted;
  }
  return (uintptr_t)context->scratch;
}

/* --- Compiled patterns --- */

uintptr_t zjs_re_compile(uintptr_t handle, uintptr_t pattern, uintptr_t length, int flags) {
  Context *context = (Context *)handle;
  int bytecode_length = 0;
  context->error_message[0] = 0;
  /* The v flag is unicode mode with set notation. */
  if (flags & LRE_FLAG_UNICODE_SETS) flags |= LRE_FLAG_UNICODE;
  /* The parser peeks one byte past the end; the scratch has room for it. */
  ((uint8_t *)pattern)[length] = 0;
  enter(context);
  uint8_t *bytecode = lre_compile(&bytecode_length, context->error_message, (int)sizeof(context->error_message),
                                  (const char *)pattern, (size_t)length, flags, context);
  int failure = context->last_failure;
  leave(context);
  if (bytecode == NULL) {
    /* A syntax failure carries a message; a resource failure does not. */
    if (failure != 0) {
      context->last_failure = failure;
    } else if (context->error_message[0] == 0) {
      context->last_failure = ZJS_RE_OUT_OF_MEMORY;
    } else {
      context->last_failure = ZJS_RE_SYNTAX;
    }
    return 0;
  }
  Pattern *compiled = (Pattern *)malloc(sizeof(Pattern));
  if (compiled == NULL) {
    lre_realloc(NULL, bytecode, 0);
    context->last_failure = ZJS_RE_OUT_OF_MEMORY;
    return 0;
  }
  compiled->bytecode = bytecode;
  compiled->length = bytecode_length;
  compiled->captures = lre_get_capture_count(bytecode);
  compiled->flags = lre_get_flags(bytecode);
  compiled->owner = context;
  context->live_handles += 1;
  context->live_bytes += (uintptr_t)bytecode_length;
  context->last_failure = 0;
  return (uintptr_t)compiled;
}

int zjs_re_failure(uintptr_t handle) {
  return ((Context *)handle)->last_failure;
}

int zjs_re_error_byte(uintptr_t handle, int index) {
  Context *context = (Context *)handle;
  if (index < 0 || index >= (int)sizeof(context->error_message)) return -1;
  unsigned char byte = (unsigned char)context->error_message[index];
  return byte == 0 ? -1 : (int)byte;
}

void zjs_re_free(uintptr_t handle) {
  Pattern *compiled = (Pattern *)handle;
  if (compiled == NULL) return;
  if (compiled->owner != NULL) {
    compiled->owner->live_handles -= 1;
    compiled->owner->live_bytes -= (uintptr_t)compiled->length;
  }
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

static bool reserve_units(Context *context, uintptr_t count) {
  if (count + 1 <= context->unit_capacity) return true;
  uintptr_t wanted = (count + 1) * 2;
  uint16_t *new_units = (uint16_t *)realloc(context->units, wanted * sizeof(uint16_t));
  if (new_units == NULL) return false;
  context->units = new_units;
  uint32_t *new_bytes = (uint32_t *)realloc(context->unit_bytes, wanted * sizeof(uint32_t));
  if (new_bytes == NULL) return false;
  context->unit_bytes = new_bytes;
  context->unit_capacity = wanted;
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
static uintptr_t transcode(Context *context, const uint8_t *bytes, uintptr_t length) {
  uint16_t *units = context->units;
  uint32_t *unit_bytes = context->unit_bytes;
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
static uintptr_t unit_at_byte(const uint32_t *unit_bytes, uintptr_t count, uintptr_t byte) {
  uintptr_t low = 0;
  uintptr_t high = count;
  while (low < high) {
    uintptr_t mid = low + (high - low) / 2;
    if (unit_bytes[mid] < byte) low = mid + 1; else high = mid;
  }
  return low;
}

int zjs_re_exec(uintptr_t handle, uintptr_t pattern_handle, uintptr_t input, uintptr_t length, uintptr_t start) {
  Context *context = (Context *)handle;
  Pattern *compiled = (Pattern *)pattern_handle;
  const uint8_t *bytes = (const uint8_t *)input;
  ((uint8_t *)input)[length] = 0;
  context->capture_total = compiled->captures;
  if (context->capture_total > ZJS_RE_MAX_CAPTURES) return ZJS_RE_BAD_BYTECODE;
  if (context->capture_total > context->capture_slots) {
    uint8_t **grown = (uint8_t **)realloc(context->captures, sizeof(uint8_t *) * 2 * (size_t)context->capture_total);
    if (grown == NULL) return ZJS_RE_OUT_OF_MEMORY;
    context->captures = grown;
    context->capture_slots = context->capture_total;
  }
  uint8_t **captures = context->captures;
  bool ascii = true;
  for (uintptr_t k = 0; k < length; k++) {
    if (bytes[k] >= 0x80) { ascii = false; break; }
  }
  if (start > length) start = length;
  int result;
  enter(context);
  if (ascii) {
    result = lre_exec(captures, compiled->bytecode, bytes, (int)start, (int)length, 0, context);
    int failure = context->last_failure;
    leave(context);
    if (result < 0) return failure != 0 ? failure : result;
    if (result == 0) return ZJS_RE_NO_MATCH;
    for (int g = 0; g < context->capture_total; g++) {
      const uint8_t *from = captures[2 * g];
      const uint8_t *to = captures[2 * g + 1];
      context->capture_starts[g] = from == NULL ? -1 : (int)(from - bytes);
      context->capture_ends[g] = to == NULL ? -1 : (int)(to - bytes);
    }
    return ZJS_RE_MATCH;
  }
  if (!reserve_units(context, length)) { leave(context); return ZJS_RE_OUT_OF_MEMORY; }
  uintptr_t count = transcode(context, bytes, length);
  uintptr_t start_unit = unit_at_byte(context->unit_bytes, count, start);
  /* Type 1 is 16-bit units; the matcher itself reads surrogate pairs as
     code points when the bytecode was compiled in unicode mode. */
  const uint8_t *units = (const uint8_t *)context->units;
  result = lre_exec(captures, compiled->bytecode, units, (int)start_unit, (int)count, 1, context);
  int failure = context->last_failure;
  leave(context);
  if (result < 0) return failure != 0 ? failure : result;
  if (result == 0) return ZJS_RE_NO_MATCH;
  for (int g = 0; g < context->capture_total; g++) {
    const uint8_t *from = captures[2 * g];
    const uint8_t *to = captures[2 * g + 1];
    if (from == NULL || to == NULL) {
      context->capture_starts[g] = -1;
      context->capture_ends[g] = -1;
    } else {
      uintptr_t from_unit = (uintptr_t)(from - units) / 2;
      uintptr_t to_unit = (uintptr_t)(to - units) / 2;
      context->capture_starts[g] = (int)context->unit_bytes[from_unit];
      context->capture_ends[g] = (int)context->unit_bytes[to_unit];
    }
  }
  return ZJS_RE_MATCH;
}

int zjs_re_capture_start(uintptr_t handle, int group) {
  Context *context = (Context *)handle;
  if (group < 0 || group >= context->capture_total) return -1;
  return context->capture_starts[group];
}

int zjs_re_capture_end(uintptr_t handle, int group) {
  Context *context = (Context *)handle;
  if (group < 0 || group >= context->capture_total) return -1;
  return context->capture_ends[group];
}

uintptr_t zjs_re_live_handles(uintptr_t handle) {
  return ((Context *)handle)->live_handles;
}

uintptr_t zjs_re_live_bytes(uintptr_t handle) {
  return ((Context *)handle)->live_bytes;
}

uintptr_t zjs_re_retained_bytes(uintptr_t handle) {
  Context *context = (Context *)handle;
  return context->scratch_capacity + context->unit_capacity * (sizeof(uint16_t) + sizeof(uint32_t)) +
         (uintptr_t)context->capture_slots * 2 * sizeof(uint8_t *);
}
