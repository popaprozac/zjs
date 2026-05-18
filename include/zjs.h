#ifndef ZJS_H
#define ZJS_H

#include <stdint.h>
#include <stddef.h>

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

/* Cell-tag predicates — disambiguate which heap-kind a cell is. */
int zjs_is_string(ZjsValue v);
int zjs_is_object(ZjsValue v);
int zjs_is_array(ZjsValue v);
int zjs_is_function(ZjsValue v);     /* user-defined Function */
int zjs_is_host_function(ZjsValue v);
int zjs_is_callable(ZjsValue v);     /* user fn OR host fn */

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

/* Garbage collection.
 *
 * zjs_gc triggers a full stop-the-world mark-sweep. The engine runs
 * GC automatically at instruction boundaries when allocation pressure
 * exceeds an adaptive threshold; this function is for tests + manual
 * memory pressure control.
 *
 * zjs_cell_count returns the number of live heap cells at the moment
 * of the call. Useful for verifying GC frees what it should.
 */
void         zjs_gc(ZjsContext* ctx);
unsigned int zjs_cell_count(ZjsContext* ctx);

/* GC instrumentation — cumulative since context creation. Lets
 * embedders + benchmark harnesses see how often GC runs and how
 * long it pauses. Useful as a baseline before swapping in a
 * different collector.
 *
 *   collections      total number of GC runs
 *   pause_ns_total   sum of all pauses, in nanoseconds
 *   pause_ns_max     worst single pause, in nanoseconds
 *   cells_freed      total cells reclaimed across all runs
 */
unsigned int zjs_gc_collections(ZjsContext* ctx);
uint64_t     zjs_gc_pause_ns_total(ZjsContext* ctx);
uint64_t     zjs_gc_pause_ns_max(ZjsContext* ctx);
unsigned int zjs_gc_cells_freed(ZjsContext* ctx);

/* -----------------------------------------------------------------------
 * Heap value constructors.
 *
 * Each returns a freshly-allocated cell rooted via the context's cell
 * list; lifetime is tied to the JS engine's reachability graph (any
 * value you hand back to JS, store on a JS object, or store on a global
 * is reachable; an orphaned cell held only on the C stack will survive
 * until the next GC and may be collected after that).
 *
 * If you need to hand a value back to JS later, store it in a JS-level
 * binding (e.g. set it as a property on globalThis via zjs_set_property)
 * so the GC can see it.
 * --------------------------------------------------------------------- */

/* Make a JS string from a byte slice. `data` does not need to be
 * null-terminated; `length` is in bytes. Interned automatically — two
 * calls with the same bytes return the same underlying cell. */
ZjsValue zjs_new_string(ZjsContext* ctx, const char* data, uint32_t length);

/* Fresh empty plain object ({}). */
ZjsValue zjs_new_object(ZjsContext* ctx);

/* Fresh array with `length` slots, all initialized to undefined. */
ZjsValue zjs_new_array(ZjsContext* ctx, uint32_t length);

/* -----------------------------------------------------------------------
 * String inspection.
 *
 * Returns a pointer to the string's internal UTF-8 byte buffer (null-
 * terminated, but the length may include embedded nulls). The pointer
 * remains valid as long as the string cell is reachable from JS or
 * held in a JS-level binding; if you let GC reclaim the cell the
 * pointer becomes dangling.
 *
 * If `out_length` is non-NULL, the length in bytes is written there.
 * Returns NULL if `v` is not a string.
 * --------------------------------------------------------------------- */
const char* zjs_string_bytes(ZjsValue v, uint32_t* out_length);

/* -----------------------------------------------------------------------
 * Property access.
 *
 * zjs_get_property reads the named property using the same algorithm as
 * `obj.name` in source — walks the prototype chain, fires accessors,
 * coerces non-object hosts. Returns undefined for missing keys.
 *
 * zjs_set_property assigns to the named property on `obj`. Plain
 * assignment semantics: creates the property if absent, walks the proto
 * chain to find setter accessors, transitions hidden classes.
 *
 * zjs_get_element / zjs_set_element are the indexed equivalents for
 * arrays and array-like objects.
 * --------------------------------------------------------------------- */
ZjsValue zjs_get_property(ZjsContext* ctx, ZjsValue obj, const char* name);
void     zjs_set_property(ZjsContext* ctx, ZjsValue obj, const char* name, ZjsValue value);
ZjsValue zjs_get_element(ZjsContext* ctx, ZjsValue obj, uint32_t index);
void     zjs_set_element(ZjsContext* ctx, ZjsValue obj, uint32_t index, ZjsValue value);

/* Array length, or 0 if `v` is not an array. */
uint32_t zjs_array_length(ZjsValue v);

/* -----------------------------------------------------------------------
 * Globals.
 *
 * Read/write a binding on the global object. The setter creates the
 * binding if absent. Names are NUL-terminated C strings.
 * --------------------------------------------------------------------- */
ZjsValue zjs_get_global(ZjsContext* ctx, const char* name);
void     zjs_set_global(ZjsContext* ctx, const char* name, ZjsValue value);

/* -----------------------------------------------------------------------
 * Host functions — C callbacks callable from JS.
 *
 * Signature:
 *   ZjsValue my_callback(ZjsContext* ctx, ZjsValue* argv, uint32_t argc);
 *
 * Inside the callback:
 *   - argv[i] holds the i'th argument; missing args show up as undefined.
 *   - argc is the number of args passed.
 *   - To read `this`, call zjs_get_this(ctx).
 *   - To signal a JS-level throw, store the value via zjs_throw and
 *     return zjs_undefined().
 *   - To return a value normally, just return it.
 *
 * zjs_register_host_function installs the callback as a global named
 * `name` (callable as `name(...)` from JS). Returns the host-function
 * value, which you can also stash via zjs_set_property if you want it
 * reachable through a different name.
 * --------------------------------------------------------------------- */
typedef ZjsValue (*ZjsHostFunction)(ZjsContext* ctx, ZjsValue* argv, uint32_t argc);

ZjsValue zjs_register_host_function(ZjsContext* ctx, const char* name, ZjsHostFunction fn);

/* The current `this` value while a host callback is executing. Outside
 * a callback this returns undefined. */
ZjsValue zjs_get_this(ZjsContext* ctx);

/* Signal a JS-level throw from inside a host callback. The thrown
 * value is recorded; the host callback should return zjs_undefined()
 * shortly after. The next op the interpreter runs will see the
 * pending throw and unwind. */
void zjs_throw(ZjsContext* ctx, ZjsValue value);

/* -----------------------------------------------------------------------
 * Calling JS from C.
 *
 * zjs_call invokes `callee` (which must be a JS function, closure, or
 * host function) with `this_val` as `this` and `argv[0..argc)` as args.
 * Returns the return value. If the call throws an uncaught exception,
 * zjs_had_error becomes true and the thrown value is available via
 * zjs_get_error; the returned value in that case is undefined.
 * --------------------------------------------------------------------- */
ZjsValue zjs_call(ZjsContext* ctx, ZjsValue callee, ZjsValue this_val, ZjsValue* argv, uint32_t argc);

/* -----------------------------------------------------------------------
 * AOT-compiled bytecode.
 *
 * Pre-parsed programs ship as a byte buffer with a "ZJSb" magic
 * header (produced by `zjs compile in.js -o out.zbc`). zjs_eval_bytecode
 * deserializes the buffer, rebinds global-slot references to the
 * current context, and runs the program as if it were the top-level
 * script — top-level `this` is bound to the global object, microtasks
 * drain after the body, and uncaught throws land on
 * zjs_had_error / zjs_get_error the same way zjs_eval reports them.
 *
 * `data` is the raw bytes; `len` is the buffer length. Returns the
 * program's final expression value (or undefined). On a malformed
 * file (wrong magic, version mismatch, truncated), returns undefined
 * without setting had_error — distinguish a bad file from a thrown
 * program by checking the return + had_error together.
 *
 * The deserialized Function* is registered with the context's GC, so
 * its lifetime tracks the context. Callers don't need to free it
 * separately; freeing the context tears it down.
 * --------------------------------------------------------------------- */
ZjsValue zjs_eval_bytecode(ZjsContext* ctx, const unsigned char* data, size_t len);

/* Compile source to a bytecode buffer in memory. On success returns
 * a pointer to a fresh malloc'd buffer (caller frees with free()),
 * writes the byte count to *out_len, and returns 0. On parse/compile
 * failure leaves *out_len = 0, sets zjs_had_error, and returns NULL.
 *
 * Equivalent to running `zjs compile` but in-process: useful for
 * embedders that want to AOT cache scripts the first time they're
 * seen, then play back the bytecode on subsequent runs.
 */
unsigned char* zjs_compile_to_bytecode(ZjsContext* ctx, const char* source, size_t* out_len);

/* -----------------------------------------------------------------------
 * ES modules.
 *
 * Load and evaluate an ES module (import/export). `abs_path` is the
 * absolute filesystem path to the entry module. The engine reads the
 * file, parses + compiles, evaluates the body with module semantics,
 * resolves relative imports against the entry's directory (with `./`
 * and `../` normalized), and drains the microtask queue.
 *
 * Returns the module's exports object on success — properties read
 * via zjs_get_property correspond to the module's named exports.
 * On failure (file not found, parse error, throw during evaluation),
 * zjs_had_error returns true and zjs_get_error carries the thrown
 * value; the return value in that case is undefined.
 *
 * The module cache is keyed by abs_path: a second call with the same
 * path returns the cached exports without re-evaluating. Cycles are
 * supported with the "partially-populated exports" model — an
 * import that re-enters an in-flight module sees `undefined` for
 * names not yet exported.
 *
 * Bare specifiers (`import "lodash"`) are treated as literal paths;
 * package.json / node_modules resolution is not built in. Embedders
 * that want node-style resolution should preprocess specifiers before
 * the import lands at this entry point.
 * --------------------------------------------------------------------- */
ZjsValue zjs_eval_module(ZjsContext* ctx, const char* abs_path);

#ifdef __cplusplus
}
#endif

#endif
