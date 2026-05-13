#ifndef ZJS_H
#define ZJS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -----------------------------------------------------------------------
 * Engine context — opaque handle.
 * --------------------------------------------------------------------- */

typedef struct ZjsContext ZjsContext;

ZjsContext* zjs_new_context(void);
void        zjs_free_context(ZjsContext* ctx);

/* -----------------------------------------------------------------------
 * Value — 64-bit NaN-boxed immediate.
 *
 * Layout (JSC convention):
 *   - int32          : NumberTag | (uint32_t)i           = 0xfffe0000_iiiiiiii
 *   - double         : u64_bits(d) + DoubleEncodeOffset    in 0x0002…0xfffc
 *   - cell (pointer) : low 48 bits, high 16 = 0           = 0x0000_pppppppppppp
 *   - null           : 0x0000000000000002
 *   - undefined      : 0x000000000000000a
 *   - false          : 0x0000000000000006
 *   - true           : 0x0000000000000007
 *
 * The struct wrapper exists only to keep the C type system honest. The
 * underlying representation is a single 64-bit value. Pass-by-value;
 * it's the same size and ABI as `uint64_t`.
 * --------------------------------------------------------------------- */

typedef struct {
    uint64_t bits;
} ZjsValue;

/* Constructors — immediate values only. Cell constructors land with the
 * heap subsystem (Phase 5+). */
ZjsValue zjs_int32(int32_t i);
ZjsValue zjs_double(double d);
ZjsValue zjs_bool(int b);          /* 0 = false, anything else = true */
ZjsValue zjs_null(void);
ZjsValue zjs_undefined(void);

/* Type predicates — return 0 or 1. Cheap (one or two ALU ops each). */
int zjs_is_int32(ZjsValue v);
int zjs_is_double(ZjsValue v);
int zjs_is_number(ZjsValue v);     /* int32 OR double */
int zjs_is_bool(ZjsValue v);
int zjs_is_null(ZjsValue v);
int zjs_is_undefined(ZjsValue v);
int zjs_is_cell(ZjsValue v);

/* Unboxers — undefined behavior if the matching predicate is false.
 * The caller is responsible for the type check. */
int32_t zjs_as_int32(ZjsValue v);
double  zjs_as_double(ZjsValue v);
int     zjs_as_bool(ZjsValue v);

/* -----------------------------------------------------------------------
 * Evaluation.
 * --------------------------------------------------------------------- */

ZjsValue    zjs_eval(ZjsContext* ctx, const char* source);
const char* zjs_version(void);

/* Uncaught-throw detection. After zjs_eval, the host can check
 * zjs_had_error to determine whether the program ended with an
 * uncaught throw, and zjs_get_error to read the thrown value.
 *
 * When zjs_eval returns normally, zjs_had_error returns 0.
 */
int         zjs_had_error(ZjsContext* ctx);
ZjsValue    zjs_get_error(ZjsContext* ctx);

#ifdef __cplusplus
}
#endif

#endif
