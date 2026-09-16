/*
 * The Z engine's regular-expression backend boundary.
 *
 * The matcher is QuickJS-NG's libregexp (vendored under
 * src/third-party/qjs-regex, shared with the reference engine). Everything
 * the Z side sees is here: scalars and opaque handles, no structs, no
 * pointers to Z memory. Patterns and inputs are copied into a buffer the
 * backend owns; results are code-unit offsets into the input.
 *
 * All mutable state -- the scratch buffer, the last exec's captures, the
 * last failure and its message, the limits, the accounting -- belongs to a
 * context the caller creates, so independent runtimes never share any of
 * it. libregexp's `opaque` parameter carries the context into its host
 * callbacks. Compiled patterns are separate objects; the context that
 * compiled one need not be the one that runs it.
 *
 * Text: inputs arrive as the engine stores them, Latin-1 bytes or UTF-16
 * units, which are exactly libregexp's 8-bit and 16-bit modes, so nothing
 * is transcoded and offsets are code-unit indices as the specification
 * defines them. Patterns arrive as UTF-8 (generalized: a lone surrogate
 * is its three-byte form), which is what libregexp's parser reads.
 */
#ifndef ZJS_REGEXP_H
#define ZJS_REGEXP_H

#include <stdint.h>

/* Flags match the RegExp letters: d g i m s u y v. */
#define ZJS_RE_GLOBAL 1
#define ZJS_RE_IGNORE_CASE 2
#define ZJS_RE_MULTILINE 4
#define ZJS_RE_DOT_ALL 8
#define ZJS_RE_UNICODE 16
#define ZJS_RE_STICKY 32
#define ZJS_RE_HAS_INDICES 64
#define ZJS_RE_UNICODE_SETS 256

/* Results of zjs_re_exec, and the failure categories of zjs_re_compile. */
#define ZJS_RE_MATCH 1
#define ZJS_RE_NO_MATCH 0
#define ZJS_RE_OUT_OF_MEMORY (-1)
#define ZJS_RE_STEP_LIMIT (-2)
#define ZJS_RE_BAD_BYTECODE (-3)
#define ZJS_RE_STACK_LIMIT (-4)
#define ZJS_RE_SYNTAX (-5)

/* A context: created once per runtime, freed at its teardown (which
   releases the scratch buffer and capture storage, not the patterns). */
uintptr_t zjs_re_context_new(void);
void zjs_re_context_free(uintptr_t context);

/* The context's scratch buffer, grown to hold at least `length` bytes and
   kept for the next call; zero when memory is out. Z fills it byte by
   byte before a compile or an exec. */
uintptr_t zjs_re_scratch(uintptr_t context, uintptr_t length);
static inline void zjs_re_buffer_store(uintptr_t buffer, uintptr_t index, uint8_t byte) {
  ((uint8_t *)buffer)[index] = byte;
}

/* Compile a pattern (UTF-8 bytes in the scratch buffer, a lone surrogate
   in its generalized three-byte form) with flags: a
   handle, or zero with the failure category in zjs_re_failure and, for a
   syntax failure, libregexp's message readable byte by byte. */
uintptr_t zjs_re_compile(uintptr_t context, uintptr_t pattern, uintptr_t length, int flags);
int zjs_re_failure(uintptr_t context);
int zjs_re_error_byte(uintptr_t context, int index);
void zjs_re_free(uintptr_t handle);
int zjs_re_capture_count(uintptr_t handle);
/* Group names in capture order, each NUL-terminated (empty for an unnamed
   group); -1 past the end. Only meaningful when the pattern has named
   groups (zjs_re_has_names). */
int zjs_re_has_names(uintptr_t handle);
int zjs_re_name_byte(uintptr_t handle, int index);

/* Match the pattern against an input of `length` code units in the
   scratch buffer -- one byte per unit (Latin-1) or, with `wide`, two
   bytes per unit little-endian (UTF-16) -- from a unit offset. Returns a
   ZJS_RE_* result; on a match, the capture offsets (in units) are
   readable from the context until its next exec. */
int zjs_re_exec(uintptr_t context, uintptr_t handle, uintptr_t input, uintptr_t length, uintptr_t start, int wide);
int zjs_re_capture_start(uintptr_t context, int group);
int zjs_re_capture_end(uintptr_t context, int group);

/* Limits, per context. The stack budget bounds the matcher's and
   compiler's recursion (bytes below the entry point, default 256 KiB). The
   step budget, when non-zero, bounds one exec's work in units of ten
   thousand matcher iterations; an exhausted budget returns
   ZJS_RE_STEP_LIMIT. */
void zjs_re_set_stack_budget(uintptr_t context, uintptr_t bytes);
void zjs_re_set_step_budget(uintptr_t context, uintptr_t checks);

/* Accounting, per context: compiled patterns alive and the bytes they
   hold (patterns compiled through it, until freed), and the scratch and
   transcoding memory it retains. */
uintptr_t zjs_re_live_handles(uintptr_t context);
uintptr_t zjs_re_live_bytes(uintptr_t context);
uintptr_t zjs_re_retained_bytes(uintptr_t context);

#endif
