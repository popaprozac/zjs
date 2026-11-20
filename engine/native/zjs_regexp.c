/* See zjs_regexp.h. */
#include "zjs_regexp.h"

#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "libregexp.h"
#include "zjs_host.h"

/* libregexp caps a pattern at 255 groups. */
#define ZJS_RE_MAX_CAPTURES 255
/* The longest literal a pattern's facts keep (see readFacts): a part of a
   literal every match holds is as good a filter. */
#define ZJS_RE_LITERAL_MAX 32
/* The widest range of starts a literal's place may leave to try. */
#define ZJS_RE_WINDOW_MAX 8

/* libregexp's opcodes and their sizes, from the header it is built with. */
typedef enum {
#define DEF(id, size) ZJS_REOP_##id,
#include "libregexp-opcode.h"
#undef DEF
  ZJS_REOP_COUNT
} ReOp;

static const uint8_t op_sizes[ZJS_REOP_COUNT] = {
#define DEF(id, size) size,
#include "libregexp-opcode.h"
#undef DEF
};

typedef struct {
  /* Limits and the state of the call in progress. */
  uintptr_t stack_budget;
  uintptr_t stack_low;
  uintptr_t stack_size;
  uintptr_t stack_reach;
  uintptr_t stack_floor;
  uintptr_t step_budget;
  uintptr_t steps_left;
  /* The embedder's interrupt handler and its argument, or 0. */
  uintptr_t interrupt_handler;
  uintptr_t interrupt_opaque;
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
  /* Capture pointers the matcher needs: two per capture and its own
     registers. */
  int alloc_count;
  int flags;
  /* The group names, one NUL-terminated name per capture after the
     first (empty for an unnamed one): the library follows each name
     with a scope byte, which this form leaves out. NULL for none. */
  char *names;
  int names_length;
  Context *owner;
  /* What every match holds, read from the bytecode once (readFacts), for
     a search (see search for where each holds). `placed` is a literal that begins between
     placed_min and placed_max units after the match does; `required` is
     the longest literal it holds anywhere; a literal's bytes are lowercase
     where `*_fold` marks an ASCII letter of either case. Lengths of 0 for
     none. `anchored`: it can begin only at the input's start. */
  uint8_t placed[ZJS_RE_LITERAL_MAX];
  uint8_t placed_fold[ZJS_RE_LITERAL_MAX];
  int placed_length;
  int placed_min;
  int placed_max;
  uint8_t required[ZJS_RE_LITERAL_MAX];
  uint8_t required_fold[ZJS_RE_LITERAL_MAX];
  int required_length;
  bool anchored;
  /* The same pattern without its search loop: one try at the position it
     is given. Made when the facts name the positions worth trying. */
  uint8_t *twin;
  int twin_length;
} Pattern;

static void readFacts(Pattern *compiled);
static bool makeTwin(Pattern *compiled, Context *context);

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

int lre_check_stack_overflow(void *opaque, size_t alloca_size) {
  Context *context = (Context *)opaque;
  char probe;
  uintptr_t here = (uintptr_t)&probe;
  if (context == NULL || context->stack_floor == 0) return 0;
  if (here < alloca_size || here - alloca_size < context->stack_floor) {
    context->last_failure = ZJS_RE_STACK_LIMIT;
    return 1;
  }
  return 0;
}

int lre_check_timeout(void *opaque) {
  Context *context = (Context *)opaque;
  if (context == NULL) return 0;
  /* libregexp asks once every 10000 backtracks: often enough to stop a
     catastrophic pattern promptly, rarely enough to cost nothing. */
  if (zjs_host_interrupt(context->interrupt_handler, context->interrupt_opaque)) {
    context->last_failure = ZJS_RE_INTERRUPTED;
    return 1;
  }
  if (context->step_budget == 0) return 0;
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
  if (here - context->stack_low < context->stack_size && context->stack_floor < context->stack_reach) context->stack_floor = context->stack_reach;
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

void zjs_re_set_stack(uintptr_t handle, uintptr_t low, uintptr_t size, uintptr_t floor) {
  Context *context = (Context *)handle;
  context->stack_low = low;
  context->stack_size = size;
  context->stack_reach = floor;
}

void zjs_re_set_interrupt(uintptr_t handle, uintptr_t handler, uintptr_t opaque) {
  ((Context *)handle)->interrupt_handler = handler;
  ((Context *)handle)->interrupt_opaque = opaque;
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
  compiled->alloc_count = lre_get_alloc_count(bytecode);
  compiled->flags = lre_get_flags(bytecode);
  readFacts(compiled);
  compiled->twin = NULL;
  compiled->twin_length = 0;
  compiled->names = NULL;
  compiled->names_length = 0;
  const char *names = lre_get_groupnames(bytecode);
  if (names != NULL) {
    /* Each name is followed by LRE_GROUP_NAME_TRAILER_LEN bytes counting
       its NUL: keep the NUL, drop the rest. */
    size_t total = 0;
    const char *cursor = names;
    for (int g = 1; g < compiled->captures; g++) {
      size_t len = strlen(cursor);
      total += len + 1;
      cursor += len + LRE_GROUP_NAME_TRAILER_LEN;
    }
    compiled->names = (char *)lre_realloc(context, NULL, total == 0 ? 1 : total);
    if (compiled->names == NULL) {
      lre_realloc(NULL, bytecode, 0);
      lre_realloc(NULL, compiled, 0);
      context->last_failure = ZJS_RE_OUT_OF_MEMORY;
      return 0;
    }
    cursor = names;
    size_t at = 0;
    for (int g = 1; g < compiled->captures; g++) {
      size_t len = strlen(cursor);
      memcpy(compiled->names + at, cursor, len + 1);
      at += len + 1;
      cursor += len + LRE_GROUP_NAME_TRAILER_LEN;
    }
    compiled->names_length = (int)total;
  }
  if (!makeTwin(compiled, context)) {
    if (compiled->names != NULL) lre_realloc(NULL, compiled->names, 0);
    lre_realloc(NULL, bytecode, 0);
    lre_realloc(NULL, compiled, 0);
    context->last_failure = ZJS_RE_OUT_OF_MEMORY;
    return 0;
  }
  compiled->owner = context;
  context->live_handles += 1;
  context->live_bytes += (uintptr_t)bytecode_length + (uintptr_t)compiled->twin_length;
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
    compiled->owner->live_bytes -= (uintptr_t)compiled->length + (uintptr_t)compiled->twin_length;
  }
  lre_realloc(NULL, compiled->bytecode, 0);
  if (compiled->twin != NULL) lre_realloc(NULL, compiled->twin, 0);
  if (compiled->names != NULL) lre_realloc(NULL, compiled->names, 0);
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
  if (compiled->names == NULL || index < 0 || index >= compiled->names_length) return -1;
  return (int)(unsigned char)compiled->names[index];
}

/* --- What every match holds --- */

static uint32_t read_u32(const uint8_t *at) {
  uint32_t value;
  memcpy(&value, at, sizeof value);
  return value;
}

static uint16_t read_u16(const uint8_t *at) {
  uint16_t value;
  memcpy(&value, at, sizeof value);
  return value;
}

/* The bytes an op at `pos` takes, as libregexp's own walks count them. */
static int op_length(const uint8_t *code, int pos) {
  int op = code[pos];
  int length = op_sizes[op];
  switch (op) {
  case ZJS_REOP_range:
  case ZJS_REOP_range_i:
    length += read_u16(code + pos + 1) * 4;
    break;
  case ZJS_REOP_range32:
  case ZJS_REOP_range32_i:
    length += read_u16(code + pos + 1) * 8;
    break;
  case ZJS_REOP_back_reference:
  case ZJS_REOP_back_reference_i:
  case ZJS_REOP_backward_back_reference:
  case ZJS_REOP_backward_back_reference_i:
    length += code[pos + 1];
    break;
  default:
    break;
  }
  return length;
}

/* Where the op at `pos` may jump, or -1 for an op that only falls through. */
static long jump_target(const uint8_t *code, int pos) {
  switch (code[pos]) {
  case ZJS_REOP_goto:
  case ZJS_REOP_split_goto_first:
  case ZJS_REOP_split_next_first:
  case ZJS_REOP_lookahead:
  case ZJS_REOP_negative_lookahead:
    return (long)pos + 5 + (int32_t)read_u32(code + pos + 1);
  case ZJS_REOP_loop:
    return (long)pos + 6 + (int32_t)read_u32(code + pos + 2);
  case ZJS_REOP_loop_split_goto_first:
  case ZJS_REOP_loop_split_next_first:
  case ZJS_REOP_loop_check_adv_split_goto_first:
  case ZJS_REOP_loop_check_adv_split_next_first:
    return (long)pos + 10 + (int32_t)read_u32(code + pos + 6);
  default:
    return -1;
  }
}

/* A literal run, its bytes, and how far after the match's start it may begin
   (max -1: no bound). */
typedef struct {
  uint8_t bytes[ZJS_RE_LITERAL_MAX];
  uint8_t fold[ZJS_RE_LITERAL_MAX];
  int length;
  int min;
  int max;
} Run;

/* A run ends: it may be the literal to search for or the one to require. */
static void end_run(Pattern *compiled, const Run *run) {
  if (run->length == 0) return;
  if (run->max >= 0 && run->max - run->min <= ZJS_RE_WINDOW_MAX) {
    /* Longer finds fewer false starts; a narrower window, fewer tries. */
    int score = run->length * 4 - (run->max - run->min);
    int held = compiled->placed_length * 4 - (compiled->placed_max - compiled->placed_min);
    if (compiled->placed_length == 0 || score > held) {
      memcpy(compiled->placed, run->bytes, (size_t)run->length);
      memcpy(compiled->placed_fold, run->fold, (size_t)run->length);
      compiled->placed_length = run->length;
      compiled->placed_min = run->min;
      compiled->placed_max = run->max;
    }
  }
  if (run->length > compiled->required_length) {
    memcpy(compiled->required, run->bytes, (size_t)run->length);
    memcpy(compiled->required_fold, run->fold, (size_t)run->length);
    compiled->required_length = run->length;
  }
}

static void no_facts(Pattern *compiled) {
  compiled->placed_length = 0;
  compiled->required_length = 0;
  compiled->anchored = false;
}

/* Whether an op reads one unit of input. */
static bool reads_unit(int op) {
  switch (op) {
  case ZJS_REOP_char:
  case ZJS_REOP_char_i:
  case ZJS_REOP_char32:
  case ZJS_REOP_char32_i:
  case ZJS_REOP_dot:
  case ZJS_REOP_any:
  case ZJS_REOP_space:
  case ZJS_REOP_not_space:
  case ZJS_REOP_range:
  case ZJS_REOP_range_i:
  case ZJS_REOP_range32:
  case ZJS_REOP_range32_i:
    return true;
  default:
    return false;
  }
}

/* The facts every match of a searching pattern holds, from one walk over
   the body between `save_start 0` and `save_end 0`. An op on the
   body's top level runs on every path to a match; one inside a region a
   forward jump spans (an alternative, an optional repetition, a lookahead
   or lookbehind, which may be negative) may not, and is passed over. A
   backward jump closes a loop whose body ran once already. Literal bytes
   are a run of `char` ops of a byte's value, or of `char_i` ops of an
   ASCII one: the letter in either case, or the byte itself, since no
   other unit canonicalizes to ASCII (outside unicode mode none does; in
   it U+017F and U+212A do, which search allows for); ops that read no input (captures' marks and the assertions)
   leave a run whole, and anything else ends it. Along the way the walk
   counts the units read before each op, least and most: a region adds up
   to its ops that read a unit (a lookaround, nothing), a loop or a back
   reference takes away the bound. A start-of-input assertion before any
   input is read anchors the match. A shape the walk does not know leaves
   no facts. */
static void readFacts(Pattern *compiled) {
  no_facts(compiled);
  const uint8_t *code = compiled->bytecode;
  if ((compiled->flags & LRE_FLAG_STICKY) != 0) return;
  long end = 8 + (long)read_u32(code + 4);
  int pos = 8;
  /* The search loop libregexp puts before a non-sticky pattern. */
  if (end < 21 || code[pos] != ZJS_REOP_split_goto_first || code[pos + 5] != ZJS_REOP_any || code[pos + 6] != ZJS_REOP_goto) return;
  pos += 11;
  if (code[pos] != ZJS_REOP_save_start || code[pos + 1] != 0) return;
  pos += 2;
  Run run;
  run.length = 0;
  /* Units read before this op on the top level, least and most. */
  int least = 0;
  int most = 0;
  /* While pos is below region_end, it is inside a region a jump spans:
     whether that region is a lookaround, the ops in it that read a unit,
     and whether it holds a loop or a back reference. */
  long region_end = 0;
  bool region_looks = false;
  int region_reads = 0;
  bool region_unbounded = false;
  while (pos < end) {
    int op = code[pos];
    if (op >= ZJS_REOP_COUNT) return;
    int length = op_length(code, pos);
    if (pos + length > end) return;
    long target = jump_target(code, pos);
    if (pos < region_end) {
      if (target > region_end) region_end = target;
      if (target >= 0 && target <= pos) region_unbounded = true;
      if (reads_unit(op)) region_reads += 1;
      if (op >= ZJS_REOP_back_reference && op <= ZJS_REOP_backward_back_reference_i) region_unbounded = true;
      pos += length;
      if (pos >= region_end && !region_looks && most >= 0) most = region_unbounded ? -1 : most + region_reads;
      continue;
    }
    int literal = -1;
    bool fold = false;
    if (op == ZJS_REOP_char) {
      uint16_t unit = read_u16(code + pos + 1);
      if (unit <= 0xFF) literal = unit;
    } else if (op == ZJS_REOP_char_i) {
      uint16_t unit = read_u16(code + pos + 1);
      if ((unit >= 'A' && unit <= 'Z') || (unit >= 'a' && unit <= 'z')) {
        literal = unit | 0x20;
        fold = true;
      } else if (unit < 0x80) {
        literal = unit;
      }
    }
    if (literal >= 0) {
      if (run.length == 0) {
        run.min = least;
        run.max = most;
      }
      if (run.length < ZJS_RE_LITERAL_MAX) {
        run.bytes[run.length] = (uint8_t)literal;
        run.fold[run.length] = fold;
        run.length += 1;
      }
      least += 1;
      if (most >= 0) most += 1;
      pos += length;
      continue;
    }
    switch (op) {
    case ZJS_REOP_save_start:
    case ZJS_REOP_save_reset:
    case ZJS_REOP_word_boundary:
    case ZJS_REOP_word_boundary_i:
    case ZJS_REOP_not_word_boundary:
    case ZJS_REOP_not_word_boundary_i:
    case ZJS_REOP_line_start_m:
    case ZJS_REOP_line_end:
    case ZJS_REOP_line_end_m:
      pos += length;
      continue;
    case ZJS_REOP_line_start:
      if (least == 0 && most == 0) compiled->anchored = true;
      pos += length;
      continue;
    case ZJS_REOP_save_end:
      if (code[pos + 1] != 0) {
        pos += length;
        continue;
      }
      /* The body's end. */
      end_run(compiled, &run);
      return;
    case ZJS_REOP_prev:
    case ZJS_REOP_match:
    case ZJS_REOP_lookahead_match:
    case ZJS_REOP_negative_lookahead_match:
      /* Not a shape a body's top level has. */
      no_facts(compiled);
      return;
    default:
      break;
    }
    /* Anything else reads input or decides the path: the run ends. */
    end_run(compiled, &run);
    run.length = 0;
    if (reads_unit(op)) {
      least += 1;
      if (most >= 0) most += 1;
    } else if (op >= ZJS_REOP_back_reference && op <= ZJS_REOP_backward_back_reference_i) {
      most = -1;
    }
    if (target > pos) {
      region_end = target;
      region_looks = op == ZJS_REOP_lookahead || op == ZJS_REOP_negative_lookahead;
      region_reads = 0;
      region_unbounded = false;
    } else if (target >= 0) {
      /* A loop's close: its body may run again. */
      most = -1;
    }
    pos += length;
  }
  /* The walk ran off the end without the body's close. */
  no_facts(compiled);
}

/* The pattern without its search loop, for one try at a given position:
   the header, then the body as it is (its jumps are relative). None when
   the facts name no positions to try. False when its memory is refused,
   which fails the compile as any refused allocation does. */
static bool makeTwin(Pattern *compiled, Context *context) {
  if (compiled->placed_length == 0 && !compiled->anchored) return true;
  int length = compiled->length - 11;
  uint8_t *twin = (uint8_t *)lre_realloc(context, NULL, (size_t)length);
  if (twin == NULL) return false;
  memcpy(twin, compiled->bytecode, 8);
  memcpy(twin + 8, compiled->bytecode + 19, (size_t)(length - 8));
  uint16_t flags = (uint16_t)(read_u16(twin) | LRE_FLAG_STICKY);
  memcpy(twin, &flags, sizeof flags);
  uint32_t body = read_u32(twin + 4) - 11;
  memcpy(twin + 4, &body, sizeof body);
  compiled->twin = twin;
  compiled->twin_length = length;
  return true;
}

/* The unit at `index` of input of 8- or 16-bit units. */
static unsigned unit_at(const uint8_t *input, int type, uintptr_t index) {
  if (type == 0) return input[index];
  uint16_t unit;
  memcpy(&unit, input + 2 * index, sizeof unit);
  return unit;
}

/* Whether `literal` is at unit `at`: a folded byte matches its ASCII letter
   in either case (only those two units have it, with 0x20 set). */
static bool literal_at(const uint8_t *input, int type, uintptr_t at, const uint8_t *literal, const uint8_t *fold, int length) {
  for (int k = 0; k < length; k++) {
    unsigned unit = unit_at(input, type, at + (uintptr_t)k);
    if (fold[k]) unit |= 0x20;
    if (unit != literal[k]) return false;
  }
  return true;
}

/* The first unit index of [from, length) where `literal` occurs, or -1.
   Over bytes, memchr finds the literal's first byte that matches only
   itself, and the rest is checked around it. */
static long find_literal(const uint8_t *input, int type, uintptr_t from, uintptr_t length, const uint8_t *literal, const uint8_t *fold, int literal_length) {
  if (from > length || length - from < (uintptr_t)literal_length) return -1;
  uintptr_t last = length - (uintptr_t)literal_length;
  int anchor = 0;
  while (anchor < literal_length && fold[anchor]) anchor++;
  uintptr_t at = from;
  if (type != 0 || anchor == literal_length) {
    for (; at <= last; at++) {
      if (literal_at(input, type, at, literal, fold, literal_length)) return (long)at;
    }
    return -1;
  }
  while (at <= last) {
    const uint8_t *hit = (const uint8_t *)memchr(input + at + anchor, literal[anchor], (size_t)(last - at) + 1);
    if (hit == NULL) return -1;
    at = (uintptr_t)(hit - input) - (uintptr_t)anchor;
    if (literal_at(input, 0, at, literal, fold, literal_length)) return (long)at;
    at += 1;
  }
  return -1;
}

static bool any_fold(const uint8_t *fold, int length) {
  for (int k = 0; k < length; k++) {
    if (fold[k]) return true;
  }
  return false;
}

/* A search the facts can answer or narrow, as lre_exec answers it: 1 for
   a match (its captures written), 0 for none, below 0 for a failure. A
   match must hold the required literal, so with none past `start` there is
   none. The placed literal's every occurrence names the few starts a match
   using it can have, each tried once with the twin, in order: the first
   that matches is the leftmost match. An anchored pattern has one start.
   Over 16-bit units in unicode mode an op may read a surrogate pair, the
   matcher may step back into one from `start`, and a folded letter has
   other units (U+212A is k): there only an exact required literal holds. */
static int search(Pattern *compiled, Context *context, uint8_t **captures, const uint8_t *input, uintptr_t start, uintptr_t length, int type) {
  bool code_points = type != 0 && (compiled->flags & (LRE_FLAG_UNICODE | LRE_FLAG_UNICODE_SETS)) != 0;
  if (compiled->required_length > 0 && !(code_points && any_fold(compiled->required_fold, compiled->required_length))
      && find_literal(input, type, start, length, compiled->required, compiled->required_fold, compiled->required_length) < 0) {
    return 0;
  }
  if (code_points || (compiled->placed_length == 0 && !compiled->anchored)) {
    return lre_exec(captures, compiled->bytecode, input, (int)start, (int)length, type, context);
  }
  if (compiled->anchored) {
    if (start > 0) return 0;
    return lre_exec(captures, compiled->twin, input, 0, (int)length, type, context);
  }
  uintptr_t next = start;
  uintptr_t from = start + (uintptr_t)compiled->placed_min;
  while (true) {
    long found = find_literal(input, type, from, length, compiled->placed, compiled->placed_fold, compiled->placed_length);
    if (found < 0) return 0;
    uintptr_t at = (uintptr_t)found;
    uintptr_t low = at >= (uintptr_t)compiled->placed_max ? at - (uintptr_t)compiled->placed_max : 0;
    if (low < next) low = next;
    uintptr_t high = at - (uintptr_t)compiled->placed_min;
    for (uintptr_t candidate = low; candidate <= high; candidate++) {
      int result = lre_exec(captures, compiled->twin, input, (int)candidate, (int)length, type, context);
      if (result != 0) return result;
    }
    next = high + 1;
    from = at + 1;
  }
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
  if (compiled->alloc_count > context->capture_slots) {
    uint8_t **grown = (uint8_t **)lre_realloc(context, context->captures, sizeof(uint8_t *) * (size_t)compiled->alloc_count);
    if (grown == NULL) return ZJS_RE_OUT_OF_MEMORY;
    context->captures = grown;
    context->capture_slots = compiled->alloc_count;
  }
  uint8_t **captures = context->captures;
  if (start > length) start = length;
  enter(context);
  /* Type 1 is 16-bit units; the matcher itself reads surrogate pairs as
     code points when the bytecode was compiled in unicode mode. */
  /* The facts may answer the search, or narrow the starts to try. */
  int result = search(compiled, context, captures, bytes, start, length, type);
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
  return context->scratch_capacity + (uintptr_t)context->capture_slots * sizeof(uint8_t *);
}
