/*
 * The Z engine's regular-expression backend boundary.
 *
 * The matcher is QuickJS-NG's libregexp (vendored under
 * src/third-party/qjs-regex, shared with the reference engine). Everything
 * the Z side sees is here: scalars and opaque handles, no structs, no
 * pointers to Z memory. Patterns and inputs are UTF-8 bytes copied into
 * buffers the backend owns; results are byte offsets into the input.
 *
 * Text semantics: an all-ASCII input is matched as 8-bit code units, one
 * per byte, which is exactly what the specification's UTF-16 code units
 * would be. Any other input is transcoded to UTF-16 (a four-byte sequence
 * becomes a surrogate pair) so classes, case folding, dot, and the `u`
 * flag see code units and code points as the specification defines them;
 * offsets map back to the byte where a unit starts, and a boundary that
 * falls inside a surrogate pair rounds to the pair's sequence. Invalid
 * bytes are one unit each, valued as in Latin-1.
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

/* Results of zjs_re_exec. */
#define ZJS_RE_MATCH 1
#define ZJS_RE_NO_MATCH 0
#define ZJS_RE_OUT_OF_MEMORY (-1)
#define ZJS_RE_STEP_LIMIT (-2)
#define ZJS_RE_BAD_BYTECODE (-3)
#define ZJS_RE_STACK_LIMIT (-4)

/* The backend's scratch buffer, grown to hold at least `length` bytes and
   kept for the next call; zero when memory is out. Z fills it byte by
   byte before a compile or an exec. */
uintptr_t zjs_re_scratch(uintptr_t length);
static inline void zjs_re_buffer_store(uintptr_t buffer, uintptr_t index, uint8_t byte) {
  ((uint8_t *)buffer)[index] = byte;
}

/* Compile a pattern (UTF-8 bytes in a backend buffer) with flags; a
   handle, or zero with the error message readable byte by byte. */
uintptr_t zjs_re_compile(uintptr_t pattern, uintptr_t length, int flags);
int zjs_re_error_byte(int index);
void zjs_re_free(uintptr_t handle);
int zjs_re_capture_count(uintptr_t handle);
/* Group names in capture order, each NUL-terminated (empty for an unnamed
   group); -1 past the end. Only meaningful when the pattern has named
   groups (zjs_re_has_names). */
int zjs_re_has_names(uintptr_t handle);
int zjs_re_name_byte(uintptr_t handle, int index);

/* Match the pattern against an input (UTF-8 bytes in a backend buffer)
   from a byte offset. Returns a ZJS_RE_* result; on a match, the capture
   offsets are readable until the next exec. */
int zjs_re_exec(uintptr_t handle, uintptr_t input, uintptr_t length, uintptr_t start);
int zjs_re_capture_start(int group);
int zjs_re_capture_end(int group);

/* Limits. The stack budget bounds the matcher's and compiler's recursion
   (bytes below the entry point, default 256 KiB). The step budget, when
   non-zero, bounds one exec's work in units of ten thousand matcher
   iterations; an exhausted budget returns ZJS_RE_STEP_LIMIT. */
void zjs_re_set_stack_budget(uintptr_t bytes);
void zjs_re_set_step_budget(uintptr_t checks);

/* Accounting: compiled patterns alive, and the bytes they hold. */
uintptr_t zjs_re_live_handles(void);
uintptr_t zjs_re_live_bytes(void);

#endif
