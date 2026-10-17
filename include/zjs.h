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

/* Default constructor — ES core + every Ring-1 / Ring-2 stdlib extension
 * (EventTarget, AbortController, Blob, Streams, node:fs/path/process/os/
 * dx/child_process/net/http, etc.). Suitable for general-purpose embedding.
 */
ZjsContext* zjs_new_context(void);

/* Minimal constructor — ES core only. Skips ALL Ring-1 web globals AND
 * the `node:` module registry. Use when you're building tight (iOS
 * worker, embedded scripting) and want to opt in to just the stdlib
 * pieces you actually use. After zjs_new_minimal_context() you can
 * call any subset of the installers below, or call
 * zjs_install_stdlib_extensions() to mirror the default.
 *
 * Base built-ins (Object/Array/Function/Date/Map/Set/Promise/RegExp/
 * JSON/Math/Symbol/URL/URLSearchParams/console/the TypedArray family/
 * Proxy/Reflect/ArrayBuffer/DataView/error constructors/etc.) are
 * still present — they live in the core bootstrap.
 */
ZjsContext* zjs_new_minimal_context(void);

/* Convenience: install everything zjs_new_context would have installed
 * on top of the minimal context. Equivalent to the default constructor
 * minus the core init that already ran. */
void zjs_install_stdlib_extensions(ZjsContext* ctx);

/* Individual Ring-1 web-globals installers. Dependency order documented
 * in src/context.zc — call them in the order shown here for a clean
 * install (web_events before web_abort; web_blob requires Uint8Array
 * which is in core; web_clone requires Map + DOMException). */
void zjs_install_web_events(ZjsContext* ctx);   /* EventTarget / Event / CustomEvent / DOMException */
void zjs_install_web_abort(ZjsContext* ctx);    /* AbortController / AbortSignal — needs web_events */
void zjs_install_web_clone(ZjsContext* ctx);    /* structuredClone — needs web_events for DOMException */
void zjs_install_web_blob(ZjsContext* ctx);     /* Blob / File / FormData */
void zjs_install_web_streams(ZjsContext* ctx);  /* ReadableStream / WritableStream / TransformStream (~50KB) */

/* node: module loader entry — registers `node:fs`, `node:path`,
 * `node:process`, `node:os`, `node:dx`, `node:child_process`,
 * `node:net`, `node:http` for `import 'node:foo'` resolution. */
void ctx_register_stdlib_modules(ZjsContext* ctx);
/* node:net host-fn globals (`__zjs_net_*`) the JS bootstrap uses. */
void zjs_install_node_net_globals(ZjsContext* ctx);

/* Core constructor — the language and the builtins it cannot do without
 * (Object, Function, Array, String, Number, Boolean, Symbol, Math, the
 * error constructors, iterators and generators, the global functions).
 * Everything below is left out until installed, and an embedder that
 * never calls an installer does not link its code. A regular-expression
 * literal throws a TypeError until zjs_install_regexp; async functions run
 * but their promises have no Promise methods until zjs_install_promise.
 * zjs_new_context() is the core with every installer run. Installing a
 * feature twice does nothing the second time. */
ZjsContext* zjs_new_core_context(void);
void zjs_install_json(ZjsContext* ctx);         /* JSON */
void zjs_install_regexp(ZjsContext* ctx);       /* RegExp, and String's match / matchAll / search */
void zjs_install_date(ZjsContext* ctx);         /* Date */
void zjs_install_collections(ZjsContext* ctx);  /* Map, Set, WeakMap, WeakSet */
void zjs_install_promise(ZjsContext* ctx);      /* Promise */
void zjs_install_reflect(ZjsContext* ctx);      /* Reflect */
/* The source compiler, for eval and the Function constructor in a context
 * that has compiled no source of its own: zjs_new_context has it, and
 * zjs_eval and zjs_compile_to_bytecode bring it to any context they run
 * on. A core context that only runs bytecode (zjs_eval_bytecode) never
 * has it, so an embedder that calls none of these links no lexer, parser,
 * or compiler; in such a context eval and Function throw an EvalError. */
void zjs_install_compiler(ZjsContext* ctx);

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

/* Interrupts. The engine calls `handler(opaque)` now and then while it
 * runs JavaScript: at loop back edges and calls (once every few thousand
 * of them), on each entry into JavaScript from a builtin, and during a
 * long regular-expression match. A nonzero return stops it: an
 * uncatchable termination unwinds every JavaScript frame, past every
 * catch and finally, and no JavaScript runs until control is back with
 * the embedder. The API call in progress (zjs_eval, zjs_call,
 * zjs_eval_module_source, zjs_drain_microtasks, zjs_run_pending_timers)
 * then returns with zjs_had_error set and zjs_is_interrupted 1; jobs the
 * termination left are dropped. The context stays usable, and the
 * handler is asked again as soon as JavaScript runs.
 *
 * The handler runs on the thread running the context's JavaScript, so
 * a request from another thread is a flag the handler reads, such as an
 * atomic the other thread sets. It must not call back into the engine.
 * NULL removes it.
 *
 * zjs_is_interrupted returns 1 when the last API call that ran
 * JavaScript ended this way, and 0 otherwise.
 */
typedef int (*ZjsInterruptHandler)(void* opaque);
void zjs_set_interrupt_handler(ZjsContext* ctx, ZjsInterruptHandler handler, void* opaque);
int  zjs_is_interrupted(ZjsContext* ctx);

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
 * file and every module it imports, links them, evaluates them with
 * module semantics, resolves relative imports against the importing
 * module's directory (with `.` and `..` normalized), and drains the
 * microtask queue.
 *
 * Returns the module's namespace object on success — properties read
 * via zjs_get_property correspond to the module's exports.
 * On failure (file not found, parse error, an import no module
 * exports, throw during evaluation), zjs_had_error returns true and
 * zjs_get_error carries the thrown value; the return value in that
 * case is undefined. Nothing runs when a module of the graph cannot be
 * found, does not parse, or imports a name nothing exports.
 *
 * The module cache is keyed by the normalized path: a second call with
 * the same path returns the cached namespace without re-evaluating,
 * and a module that failed throws its error again. Imports are live
 * bindings, as the language has them: an import reads the exporting
 * module's binding as it is now, so a cycle that reaches a `let` or
 * `const` before its module has run it throws a ReferenceError, and a
 * function declaration is callable from any module of the graph
 * before its own module runs.
 *
 * Bare specifiers (`import "lodash"`) are treated as literal paths;
 * package.json / node_modules resolution is not built in. Embedders
 * that want node-style resolution should preprocess specifiers before
 * the import lands at this entry point.
 * --------------------------------------------------------------------- */
ZjsValue zjs_eval_module(ZjsContext* ctx, const char* abs_path);

/* -----------------------------------------------------------------------
 * Evaluate an in-memory source buffer as an ES module.
 *
 * Useful when the embedder bundles worker code (Vite, Rolldown, esbuild,
 * …) and wants to skip the disk hop, or when generating module source
 * on the fly.
 *
 *   source         module source bytes (need not be NUL-terminated)
 *   source_len     length of source in bytes
 *   virtual_path   the cache key + base for relative `import "./..."`
 *                  resolution inside the source. Does NOT need to point
 *                  at a real file — `/virtual/main.mjs` works fine for
 *                  a single self-contained bundle. Re-evaluating with
 *                  the same virtual_path returns the cached exports
 *                  without re-parsing.
 *
 * Returns the module's namespace object on success. On parse /
 * compile / link / evaluation failure, sets zjs_had_error; the thrown
 * value is zjs_get_error's.
 *
 * Bare specifiers (`import "lodash"`) still go through the same
 * resolver as zjs_eval_module — preprocess them before evaluation if
 * you need package-style lookup.
 * --------------------------------------------------------------------- */
ZjsValue zjs_eval_module_source(ZjsContext* ctx,
                                const char* source,
                                size_t source_len,
                                const char* virtual_path);

/* -----------------------------------------------------------------------
 * Set process.argv. Idiomatic call:
 *   zjs_set_process_argv(ctx, argc, argv);
 * where argc/argv match Node's convention: argv[0] = executable path,
 * argv[1] = script path, argv[2..] = user-supplied arguments.
 *
 * Each entry is interned as a ZjsString. May be called more than once
 * (subsequent calls overwrite). If never called, process.argv defaults
 * to an empty array.
 * --------------------------------------------------------------------- */
void zjs_set_process_argv(ZjsContext* ctx, uint32_t argc, char** argv);

/* -----------------------------------------------------------------------
 * Event loop — web-API Phase B (timers).
 *
 * The engine exposes its pending-work state through these three
 * functions. Embedders integrate with their own event loop (libuv,
 * dispatch, GLib, ...) by checking pending work, sleeping until the
 * next timer is due, then calling zjs_run_pending_timers.
 *
 *   zjs_has_pending_work  returns 1 if any microtask or timer is
 *                          pending. 0 = idle (host loop can exit).
 *   zjs_next_timer_ms     ms until the next timer fires, or -1 if
 *                          none. 0 means "fire now". Doesn't account
 *                          for microtasks — drain those before
 *                          asking again.
 *   zjs_run_pending_timers fires every timer whose due time has
 *                          arrived. Drains microtasks after each
 *                          timer callback (per spec). setInterval
 *                          re-arms; setTimeout deletes.
 *
 * Typical CLI-style loop:
 *
 *   while (zjs_has_pending_work(ctx)) {
 *       int64_t wait = zjs_next_timer_ms(ctx);
 *       if (wait > 0) {
 *           struct timespec ts;
 *           ts.tv_sec  = wait / 1000;
 *           ts.tv_nsec = (wait % 1000) * 1000000;
 *           nanosleep(&ts, NULL);
 *       }
 *       zjs_run_pending_timers(ctx);
 *   }
 *
 * Throws inside a timer callback get captured on zjs_had_error /
 * zjs_get_error after each fire; the loop continues unless the
 * embedder bails.
 * --------------------------------------------------------------------- */
int     zjs_has_pending_work(ZjsContext* ctx);
int64_t zjs_next_timer_ms(ZjsContext* ctx);
void    zjs_run_pending_timers(ZjsContext* ctx);

/* Drain pending microtasks now. Use after C-side resolution of a
 * Promise (uv I/O completion, native event arrival, …) so the
 * `.then` continuations run before the next host work item. Idempotent
 * when the queue is empty; safe to call at any time.
 *
 * zjs_run_pending_timers and the end of zjs_eval already drain
 * microtasks for you. This entry point is for the cases between
 * those — typically: host code calls into JS, that JS resolves a
 * Promise, control returns to host code that wants the .then chain
 * to have already fired. */
void    zjs_drain_microtasks(ZjsContext* ctx);

/* -----------------------------------------------------------------------
 * Strong roots — keep a JS value alive across event-loop ticks.
 *
 * Embedders that hold a JS value across a uv I/O completion, a
 * setInterval-style handler, or any other tick boundary use these to
 * tell the GC the value is still in use. Returns an opaque handle
 * (a small u32); zjs_unroot releases it.
 *
 * Typical use:
 *
 *     // C side, owning a JS callback across ticks:
 *     uint32_t cb_handle = zjs_root(ctx, js_callback_value);
 *     store_in_struct(my_handler_ctx, cb_handle);
 *     // ... time passes; uv callback fires ...
 *     ZjsValue cb = zjs_root_get(ctx, my_handler_ctx->cb_handle);
 *     zjs_call(ctx, cb, zjs_undefined(), NULL, 0);
 *     // Done with it:
 *     zjs_unroot(ctx, my_handler_ctx->cb_handle);
 *
 * Multiple zjs_root calls with the same value each return an
 * independent handle. After zjs_unroot, the handle is invalid; do not
 * pass a freed handle to zjs_root_get (the slot may have been
 * reassigned to a different value).
 * --------------------------------------------------------------------- */
uint32_t zjs_root(ZjsContext* ctx, ZjsValue value);
void     zjs_unroot(ZjsContext* ctx, uint32_t handle);
ZjsValue zjs_root_get(ZjsContext* ctx, uint32_t handle);

/* -----------------------------------------------------------------------
 * Scoped roots — stack-discipline GC protection for transient values.
 *
 * IMPORTANT lifetime rule: any ZjsValue you receive from a zjs_* call
 * (eval, call, get_property, get_element, new_string, …) is live only
 * until your NEXT zjs_* call that can allocate. The engine's mark-
 * sweep GC may fire inside that next call to reclaim cells your C
 * stack still holds but the GC root walk can't see.
 *
 * For recursive walkers — your favorite shape is `keys = zjs_call
 * (Object.keys, obj); for (i...) walk(zjs_get_property(obj, keys[i]))`
 * — protect each held value with zjs_pin / zjs_unpin:
 *
 *     void walk_object(ZjsContext* ctx, ZjsValue obj) {
 *         ZjsValue keys = call_object_keys(ctx, obj);
 *         zjs_pin(ctx, keys);              // keys is now a GC root
 *         uint32_t n = zjs_array_length(keys);
 *         for (uint32_t i = 0; i < n; i++) {
 *             ZjsValue child = zjs_get_property(ctx, obj,
 *                                  c_str(zjs_get_element(ctx, keys, i)));
 *             walk(ctx, child);            // may recurse, may allocate
 *         }
 *         zjs_unpin(ctx);                  // keys can be reclaimed now
 *     }
 *
 * Stack discipline: every zjs_pin MUST be paired with exactly one
 * zjs_unpin in the same C function (or its callees). zjs_pin_replace
 * overwrites the top slot — useful in loops that allocate a fresh
 * value each iteration (push once, replace each iter, pop at end).
 *
 * vs zjs_root: zjs_root is the heavyweight handle-based form for
 * values held across event-loop ticks (uv I/O callbacks, timers).
 * zjs_pin is the lightweight stack-based form for values held across
 * a couple of host-API calls inside one C frame. They use separate
 * stacks; you can mix them.
 * --------------------------------------------------------------------- */
void zjs_pin(ZjsContext* ctx, ZjsValue value);
void zjs_unpin(ZjsContext* ctx);
void zjs_pin_replace(ZjsContext* ctx, ZjsValue value);

#ifdef __cplusplus
}
#endif

#endif
