/* See zjs_regexp.h. */
#include "zjs_regexp.h"

#include <stdatomic.h>
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
  /* Set by lre_realloc when the allocator refuses (or the injected
     limit does); the category of a failed call. */
  bool allocation_failed;
  uintptr_t allocation_count;
  uintptr_t allocation_limit;
  uintptr_t allocations_until_failure;
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
  Context *context = (Context *)opaque;
  if (size == 0) {
    free(ptr);
    return NULL;
  }
  if (context != NULL) {
    context->allocation_count += 1;
    if (context->allocation_limit != 0) {
      if (context->allocations_until_failure == 0) {
        context->allocation_failed = true;
        return NULL;
      }
      context->allocations_until_failure -= 1;
    }
  }
  void *grown = realloc(ptr, size);
  if (grown == NULL && context != NULL) context->allocation_failed = true;
  return grown;
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
  context->allocation_failed = false;
}

static void leave(Context *context) {
  context->stack_floor = 0;
}

/* --- Contexts --- */

static atomic_uintptr_t live_contexts = 0;

uintptr_t zjs_re_context_new(void) {
  Context *context = (Context *)calloc(1, sizeof(Context));
  if (context == NULL) return 0;
  context->stack_budget = 256 * 1024;
  atomic_fetch_add(&live_contexts, 1);
  return (uintptr_t)context;
}

void zjs_re_context_free(uintptr_t handle) {
  Context *context = (Context *)handle;
  if (context == NULL) return;
  free(context->scratch);
  free(context->captures);
  free(context);
  atomic_fetch_sub(&live_contexts, 1);
}

uintptr_t zjs_re_live_contexts(void) {
  return atomic_load(&live_contexts);
}

void zjs_re_set_stack_budget(uintptr_t handle, uintptr_t bytes) {
  ((Context *)handle)->stack_budget = bytes;
}

void zjs_re_set_step_budget(uintptr_t handle, uintptr_t checks) {
  ((Context *)handle)->step_budget = checks;
}

void zjs_re_set_allocation_limit(uintptr_t handle, uintptr_t count) {
  Context *context = (Context *)handle;
  context->allocation_limit = count;
  context->allocations_until_failure = count == 0 ? 0 : count - 1;
}

uintptr_t zjs_re_scratch(uintptr_t handle, uintptr_t length) {
  Context *context = (Context *)handle;
  if (length + 1 > context->scratch_capacity) {
    uintptr_t wanted = context->scratch_capacity * 2;
    if (wanted < length + 1) wanted = length + 1;
    if (wanted < 256) wanted = 256;
    uint8_t *grown = (uint8_t *)lre_realloc(context, context->scratch, wanted);
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
  bool allocation_failed = context->allocation_failed;
  leave(context);
  if (bytecode == NULL) {
    /* The category comes from what the callbacks saw. One resource limit
       is the parser's own: past 64 MiB of bytecode it reports "out of
       memory" without any allocation having been refused, and that exact
       message with no refusal is the only way that limit shows. */
    if (allocation_failed) {
      context->last_failure = ZJS_RE_OUT_OF_MEMORY;
    } else if (failure != 0) {
      context->last_failure = failure;
    } else if (strcmp(context->error_message, "out of memory") == 0) {
      context->last_failure = ZJS_RE_SIZE_LIMIT;
    } else {
      context->last_failure = ZJS_RE_SYNTAX;
    }
    return 0;
  }
  Pattern *compiled = (Pattern *)lre_realloc(context, NULL, sizeof(Pattern));
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

int zjs_re_exec(uintptr_t handle, uintptr_t pattern_handle, uintptr_t input, uintptr_t length, uintptr_t start, int wide) {
  Context *context = (Context *)handle;
  Pattern *compiled = (Pattern *)pattern_handle;
  const uint8_t *bytes = (const uint8_t *)input;
  int type = wide ? 1 : 0;
  ((uint8_t *)input)[length << type] = 0;
  context->capture_total = compiled->captures;
  if (context->capture_total > ZJS_RE_MAX_CAPTURES) return ZJS_RE_BAD_BYTECODE;
  if (context->capture_total > context->capture_slots) {
    uint8_t **grown = (uint8_t **)lre_realloc(context, context->captures, sizeof(uint8_t *) * 2 * (size_t)context->capture_total);
    if (grown == NULL) return ZJS_RE_OUT_OF_MEMORY;
    context->captures = grown;
    context->capture_slots = context->capture_total;
  }
  uint8_t **captures = context->captures;
  if (start > length) start = length;
  enter(context);
  /* Type 1 is 16-bit units; the matcher itself reads surrogate pairs as
     code points when the bytecode was compiled in unicode mode. */
  int result = lre_exec(captures, compiled->bytecode, bytes, (int)start, (int)length, type, context);
  int failure = context->last_failure;
  bool allocation_failed = context->allocation_failed;
  leave(context);
  if (result < 0) {
    if (allocation_failed) return ZJS_RE_OUT_OF_MEMORY;
    return failure != 0 ? failure : result;
  }
  if (result == 0) return ZJS_RE_NO_MATCH;
  for (int g = 0; g < context->capture_total; g++) {
    const uint8_t *from = captures[2 * g];
    const uint8_t *to = captures[2 * g + 1];
    context->capture_starts[g] = from == NULL ? -1 : (int)((from - bytes) >> type);
    context->capture_ends[g] = to == NULL ? -1 : (int)((to - bytes) >> type);
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

uintptr_t zjs_re_allocation_count(uintptr_t handle) {
  return ((Context *)handle)->allocation_count;
}

uintptr_t zjs_re_retained_bytes(uintptr_t handle) {
  Context *context = (Context *)handle;
  return context->scratch_capacity + (uintptr_t)context->capture_slots * 2 * sizeof(uint8_t *);
}
