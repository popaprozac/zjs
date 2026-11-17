/* Host functions across the public ABI (zjs.h): C called from JavaScript,
 * with its arguments, receiver, value, and throw; every zjs_* call made
 * on the context from inside one, nested host functions and nested
 * contexts among them; what is refused there; and an interrupt that
 * stops JavaScript a host function called. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "zjs.h"

static int failures = 0;

#define CHECK(condition, what) \
  do { \
    if (!(condition)) { printf("FAIL: %s (line %d)\n", what, __LINE__); failures++; } \
  } while (0)

static int is_int(ZjsValue value, int32_t expected) {
  return zjs_is_number(value) && zjs_as_double(value) == (double)expected;
}

static int text_says(ZjsValue value, const char *expected) {
  uint32_t length = 0;
  const char *text = zjs_string_bytes(value, &length);
  return text != NULL && length == strlen(expected) && memcmp(text, expected, length) == 0;
}

static ZjsValue text(ZjsContext *ctx, const char *bytes) {
  return zjs_new_string(ctx, bytes, (uint32_t)strlen(bytes));
}

static int error_says(ZjsContext *ctx, const char *name) {
  ZjsValue error = zjs_get_error(ctx);
  uint32_t root = zjs_root(ctx, error);
  int same = zjs_had_error(ctx) == 1 && zjs_is_object(error) && text_says(zjs_get_property(ctx, error, "name"), name);
  zjs_unroot(ctx, root);
  return same;
}

static int truthy(ZjsContext *ctx, const char *source) {
  return zjs_as_bool(zjs_eval(ctx, source)) && zjs_had_error(ctx) == 0;
}

/* --- Host functions the tests register --- */

static ZjsValue host_add(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  (void)ctx;
  double total = 0;
  for (uint32_t i = 0; i < argc; i++) total += zjs_as_double(argv[i]);
  return zjs_double(total);
}

static ZjsValue host_count(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  (void)ctx;
  (void)argv;
  return zjs_int32((int32_t)argc);
}

static ZjsValue host_this(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  (void)argv;
  (void)argc;
  return zjs_get_this(ctx);
}

static ZjsValue host_throw(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  zjs_throw(ctx, argc > 0 ? argv[0] : text(ctx, "thrown by C"));
  return zjs_int32(99);
}

/* Builds an object from what the engine lends it: a string made here, its
   argument's property, an array, a global; then reads them back. */
static ZjsValue host_build(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  if (argc < 1) return zjs_undefined();
  ZjsValue made = zjs_new_object(ctx);
  zjs_pin(ctx, made);
  zjs_set_property(ctx, made, "name", text(ctx, "built"));
  zjs_set_property(ctx, made, "x2", zjs_int32(zjs_as_int32(zjs_get_property(ctx, argv[0], "x")) * 2));
  ZjsValue list = zjs_new_array(ctx, 2);
  zjs_set_property(ctx, made, "list", list);
  zjs_set_element(ctx, list, 0, text(ctx, "zero"));
  zjs_set_element(ctx, list, 1, zjs_get_global(ctx, "seed"));
  zjs_set_global(ctx, "fromHost", text(ctx, "set in C"));
  int read_back = text_says(zjs_get_property(ctx, made, "name"), "built")
    && zjs_array_length(list) == 2
    && text_says(zjs_get_element(ctx, list, 0), "zero")
    && zjs_had_error(ctx) == 0;
  zjs_set_property(ctx, made, "readBack", zjs_bool(read_back));
  zjs_unpin(ctx);
  return made;
}

/* Calls its first argument with the rest, and reports what the call left. */
static ZjsValue host_apply(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  if (argc < 1) return zjs_undefined();
  ZjsValue result = zjs_call(ctx, argv[0], zjs_undefined(), argv + 1, argc - 1);
  if (zjs_had_error(ctx)) {
    ZjsValue report = zjs_new_object(ctx);
    zjs_set_property(ctx, report, "caught", zjs_get_error(ctx));
    return report;
  }
  return result;
}

/* Calls a function that throws, keeps the error, then makes a call that
   works, which clears it. */
static ZjsValue host_errors(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  if (argc < 2) return zjs_undefined();
  int seen = zjs_had_error(ctx) == 0;
  ZjsValue failed = zjs_call(ctx, argv[0], zjs_undefined(), NULL, 0);
  seen = seen && zjs_is_undefined(failed) && zjs_had_error(ctx) == 1 && text_says(zjs_get_error(ctx), "from JS");
  zjs_get_property(ctx, zjs_new_object(ctx), "nothing");
  seen = seen && zjs_had_error(ctx) == 1;
  zjs_get_property(ctx, zjs_null(), "x");
  zjs_gc(ctx);
  for (int i = 0; i < 50000; i++) zjs_new_object(ctx);
  seen = seen && error_says(ctx, "TypeError");
  ZjsValue fine = zjs_call(ctx, argv[1], zjs_undefined(), NULL, 0);
  seen = seen && is_int(fine, 7) && zjs_had_error(ctx) == 0 && zjs_is_undefined(zjs_get_error(ctx));
  return zjs_bool(seen);
}

/* Makes an error, reads a getter that calls another host function (a
   read that works leaves the error as it was), and finds its own receiver
   and error as they were. */
static ZjsValue host_state_kept(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  if (argc < 1) return zjs_undefined();
  zjs_get_property(ctx, zjs_undefined(), "x");
  int inner = is_int(zjs_get_property(ctx, argv[0], "viaHost"), 5);
  int kept = inner && error_says(ctx, "TypeError");
  zjs_set_global(ctx, "stateKept", zjs_bool(kept));
  return zjs_get_this(ctx);
}

/* Collects with nothing but the call holding its arguments, then makes
   enough cells that a freed one would be given out again. */
static ZjsValue host_collect_with(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  if (argc < 1) return zjs_undefined();
  zjs_gc(ctx);
  for (int i = 0; i < 50000; i++) zjs_new_object(ctx);
  return zjs_get_property(ctx, argv[0], "fresh");
}

/* What may not run inside a host function. */
static ZjsValue host_refused(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  (void)argv;
  (void)argc;
  int refused = zjs_is_undefined(zjs_eval(ctx, "1 + 1")) && error_says(ctx, "TypeError");
  size_t length = 5;
  refused = refused && zjs_compile_to_bytecode(ctx, "1", &length) == NULL && length == 0 && zjs_had_error(ctx) == 1;
  zjs_install_json(ctx);
  refused = refused && zjs_had_error(ctx) == 1;
  return zjs_bool(refused);
}

/* Queues a job through JavaScript; it waits for the outermost call. */
static ZjsValue host_queue(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  if (argc < 1) return zjs_undefined();
  zjs_call(ctx, argv[0], zjs_undefined(), NULL, 0);
  int pending = zjs_has_pending_work(ctx);
  zjs_drain_microtasks(ctx);
  int still = zjs_has_pending_work(ctx);
  ZjsValue ran = zjs_get_global(ctx, "jobRan");
  return zjs_bool(pending == 1 && still == 1 && zjs_is_bool(ran) && !zjs_as_bool(ran));
}

/* Strings made, read, and collected while JavaScript is suspended. */
static ZjsValue host_strings(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  (void)argv;
  (void)argc;
  int good = 1;
  unsigned int before = zjs_gc_collections(ctx);
  for (int i = 0; i < 600; i++) {
    char buffer[32];
    snprintf(buffer, sizeof buffer, "host string %d", i);
    ZjsValue made = text(ctx, buffer);
    good = good && text_says(made, buffer);
    if (i % 200 == 199) zjs_gc(ctx);
  }
  good = good && zjs_gc_collections(ctx) >= before + 3 && zjs_cell_count(ctx) > 0
    && zjs_gc_pause_ns_total(ctx) >= zjs_gc_pause_ns_max(ctx);
  uint32_t root = zjs_root(ctx, text(ctx, "rooted in C"));
  zjs_gc(ctx);
  good = good && text_says(zjs_root_get(ctx, root), "rooted in C");
  zjs_unroot(ctx, root);
  return zjs_bool(good);
}

static ZjsValue host_twice(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  (void)ctx;
  return zjs_int32(argc > 0 ? zjs_as_int32(argv[0]) * 2 : 0);
}

/* Registers another host function from inside this one. */
static ZjsValue host_register(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  (void)argv;
  (void)argc;
  return zjs_register_host_function(ctx, "twiceLater", host_twice);
}

/* --- Interrupts --- */

static int stop_now = 0;

static int interrupt_when_asked(void *opaque) {
  (void)opaque;
  return stop_now;
}

/* Arms the interrupt handler from inside a host function. */
static ZjsValue host_arm(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  (void)argv;
  (void)argc;
  zjs_set_interrupt_handler(ctx, interrupt_when_asked, NULL);
  return zjs_undefined();
}

/* Calls an endless function with the handler armed, then tries more. */
static ZjsValue host_spin(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  if (argc < 1) return zjs_undefined();
  stop_now = 1;
  zjs_call(ctx, argv[0], zjs_undefined(), NULL, 0);
  int stopped = zjs_had_error(ctx) == 1 && zjs_is_interrupted(ctx) == 1;
  zjs_call(ctx, argv[0], zjs_undefined(), NULL, 0);
  stopped = stopped && zjs_is_interrupted(ctx) == 1;
  zjs_set_global(ctx, "spinSaw", zjs_bool(stopped));
  zjs_throw(ctx, text(ctx, "not thrown: the termination goes on"));
  return zjs_int32(1);
}

/* --- Two contexts --- */

static ZjsContext *outer_context = NULL;

/* Registered on the inner context: reads a global of the outer one, whose
   host function is running further up this thread. */
static ZjsValue host_read_outer(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  (void)ctx;
  (void)argv;
  (void)argc;
  return zjs_int32(zjs_as_int32(zjs_get_global(outer_context, "outerValue")) + 1);
}

/* Registered on the outer context: runs a script on the inner one. */
static ZjsValue host_enter_inner(ZjsContext *ctx, ZjsValue *argv, uint32_t argc) {
  (void)ctx;
  (void)argc;
  ZjsContext *inner = (ZjsContext *)(uintptr_t)zjs_as_double(argv[0]);
  return zjs_int32(zjs_as_int32(zjs_eval(inner, "readOuter() * 10")));
}

/* --- The tests --- */

static void calling(ZjsContext *ctx) {
  ZjsValue add = zjs_register_host_function(ctx, "add", host_add);
  CHECK(zjs_is_host_function(add) && zjs_is_callable(add) && !zjs_is_function(add), "a host function value");
  CHECK(is_int(zjs_eval(ctx, "add(2, 3)"), 5), "called from JavaScript");
  CHECK(truthy(ctx, "typeof add === 'function' && add.name === 'add' && globalThis.add === add"), "a global function named as registered");
  ZjsValue two[2] = { zjs_int32(4), zjs_double(0.5) };
  CHECK(zjs_as_double(zjs_call(ctx, zjs_get_global(ctx, "add"), zjs_undefined(), two, 2)) == 4.5, "and from C");
  zjs_register_host_function(ctx, "count", host_count);
  CHECK(is_int(zjs_eval(ctx, "count()"), 0) && is_int(zjs_eval(ctx, "count(1, 'two', {}, [], null)"), 5), "argc is what was passed");
  CHECK(is_int(zjs_eval(ctx, "add(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20)"), 210), "twenty arguments");
  CHECK(is_int(zjs_eval(ctx, "add(...[1, 2, 3], ...[4])"), 10), "a spread call");
  CHECK(truthy(ctx, "[5, 6].map(count).join() === '3,3' && [1, 2, 3].map(function (v) { return add(v, v); }).join() === '2,4,6'"), "passed to a builtin, which calls it");
  CHECK(is_int(zjs_eval(ctx, "add.call(null, 20, 22)"), 42) && is_int(zjs_eval(ctx, "add.apply(null, [40, 2])"), 42), "through call and apply");
  CHECK(is_int(zjs_eval(ctx, "add.bind(null, 40)(2)"), 42), "bound");
  CHECK(zjs_is_undefined(zjs_eval(ctx, "new add(1)")) && error_says(ctx, "TypeError"), "not a constructor");

  zjs_register_host_function(ctx, "self", host_this);
  CHECK(truthy(ctx, "var holder = { self: self }; holder.self() === holder"), "a method's receiver");
  CHECK(truthy(ctx, "self.call(7) === 7 && self() === undefined"), "the receiver given");
  CHECK(zjs_is_undefined(zjs_get_this(ctx)), "no receiver outside a host function");

  zjs_register_host_function(ctx, "thrower", host_throw);
  CHECK(truthy(ctx, "var caught; try { thrower('a value'); } catch (e) { caught = e; } caught === 'a value'"), "zjs_throw is a throw JavaScript catches");
  CHECK(truthy(ctx, "try { thrower(new RangeError('typed')); false } catch (e) { e instanceof RangeError && e.message === 'typed' }"), "an Error thrown");
  CHECK(zjs_is_undefined(zjs_eval(ctx, "thrower(); 'not reached'")) && zjs_had_error(ctx) == 1 && text_says(zjs_get_error(ctx), "thrown by C"), "uncaught, it is the evaluation's error");
  zjs_throw(ctx, zjs_int32(1));
  CHECK(is_int(zjs_eval(ctx, "1"), 1) && zjs_had_error(ctx) == 0, "zjs_throw outside a host function does nothing");
}

static void inside(ZjsContext *ctx) {
  zjs_register_host_function(ctx, "build", host_build);
  CHECK(truthy(ctx, "var seed = 'seeded'; var b = build({ x: 21 }); b.name === 'built' && b.x2 === 42 && b.list[0] === 'zero' && b.list[1] === 'seeded' && b.readBack === true"), "properties, elements, strings, and globals from inside");
  CHECK(truthy(ctx, "fromHost === 'set in C'"), "a global set from inside");

  zjs_register_host_function(ctx, "apply", host_apply);
  CHECK(is_int(zjs_eval(ctx, "apply(function (a, b) { return a * b; }, 6, 7)"), 42), "a call into JavaScript from inside");
  CHECK(is_int(zjs_eval(ctx, "apply(function (n) { return apply(function (m) { return add(m, 1); }, n * 10); }, 4)"), 41), "host and JavaScript frames nested three deep");
  CHECK(truthy(ctx, "var report = apply(function () { throw new TypeError('inner'); }); report.caught instanceof TypeError && report.caught.message === 'inner'"), "a throw from a call inside is the host function's to handle");
  CHECK(zjs_had_error(ctx) == 0, "and not the evaluation's");
  CHECK(truthy(ctx, "var depth = 0; function down(n) { depth++; return n === 0 ? self.call('bottom') : apply(down, n - 1); } down(30) === 'bottom' && depth === 31"), "thirty host calls nested, each with its own receiver");

  zjs_register_host_function(ctx, "stateKept", host_state_kept);
  CHECK(truthy(ctx, "var keeper = { m: stateKept }; keeper.m({ get viaHost() { return self.call(5); } }) === keeper && stateKept === true"), "a host function's receiver and error come back after a nested one");

  zjs_register_host_function(ctx, "collectWith", host_collect_with);
  CHECK(truthy(ctx, "collectWith(...[{ fresh: 'kept' + 1 }]) === 'kept1'"), "a spread argument survives a collection inside");
  CHECK(truthy(ctx, "function* fresh() { for (var i = 0; i < 12; i++) yield { fresh: 'made ' + i }; } collectWith(...fresh()) === 'made 0'"), "and twelve that only the call holds");

  zjs_register_host_function(ctx, "errors", host_errors);
  CHECK(truthy(ctx, "errors(function () { throw 'from JS'; }, function () { return 7; })"), "inside, an error stays until a call that works");

  zjs_register_host_function(ctx, "refused", host_refused);
  CHECK(truthy(ctx, "refused()"), "evaluating, compiling, and installing are refused inside");
  CHECK(is_int(zjs_eval(ctx, "40 + 2"), 42), "and work again outside");

  zjs_register_host_function(ctx, "queue", host_queue);
  CHECK(truthy(ctx, "var jobRan = false; queue(function () { Promise.resolve().then(function () { jobRan = true; }); }) && jobRan === false"), "a job queued inside waits, and a drain inside does not run it");
  CHECK(truthy(ctx, "jobRan === true"), "it ran before the evaluation returned");

  zjs_register_host_function(ctx, "strings", host_strings);
  CHECK(truthy(ctx, "var keep = { a: [1, 2, 3] }; strings() && keep.a.length === 3"), "strings made and read, and collections, inside");

  zjs_register_host_function(ctx, "registerMore", host_register);
  CHECK(truthy(ctx, "typeof registerMore() === 'function' && twiceLater(21) === 42"), "a host function registered from inside one");
}

static void interrupted(ZjsContext *ctx) {
  zjs_register_host_function(ctx, "spin", host_spin);
  zjs_register_host_function(ctx, "arm", host_arm);
  stop_now = 0;
  ZjsValue result = zjs_eval(ctx, "var after = 0; var spinSaw = false; arm(); spin(function () { for (;;) {} }); after = 1;");
  CHECK(zjs_is_undefined(result) && zjs_had_error(ctx) == 1 && zjs_is_interrupted(ctx) == 1, "an endless call inside a host function stops the evaluation");
  CHECK(error_says(ctx, "Error") && zjs_is_object(zjs_get_error(ctx)), "its error is the termination, not what the host function threw");
  stop_now = 0;
  zjs_set_interrupt_handler(ctx, NULL, NULL);
  CHECK(truthy(ctx, "spinSaw === true && after === 0"), "the host function saw it, and nothing after it ran");
  CHECK(zjs_is_interrupted(ctx) == 0, "and the context goes on");
}

static void contexts(ZjsContext *ctx) {
  ZjsContext *inner = zjs_new_context();
  outer_context = ctx;
  zjs_register_host_function(inner, "readOuter", host_read_outer);
  zjs_register_host_function(ctx, "enterInner", host_enter_inner);
  zjs_set_global(ctx, "innerContext", zjs_double((double)(uintptr_t)inner));
  CHECK(is_int(zjs_eval(ctx, "var outerValue = 4; enterInner(innerContext)"), 50), "a host function runs another context, whose host function reads this one");
  CHECK(is_int(zjs_eval(inner, "readOuter()"), 5), "the inner context's host function, called on its own");
  zjs_free_context(inner);
}

static void nothing(ZjsContext *live) {
  CHECK(zjs_is_undefined(zjs_register_host_function(NULL, "x", host_add)), "no context");
  CHECK(zjs_is_undefined(zjs_register_host_function(live, NULL, host_add)), "no name");
  CHECK(zjs_is_undefined(zjs_register_host_function(live, "x", NULL)), "no function");
  CHECK(zjs_is_undefined(zjs_get_this(NULL)), "no receiver for no context");
  zjs_throw(NULL, zjs_int32(1));
  ZjsContext *freed = zjs_new_context();
  zjs_free_context(freed);
  CHECK(zjs_is_undefined(zjs_register_host_function(freed, "x", host_add)), "a freed context");
}

int main(void) {
  ZjsContext *ctx = zjs_new_context();
  CHECK(ctx != NULL, "a context");
  calling(ctx);
  inside(ctx);
  interrupted(ctx);
  contexts(ctx);
  nothing(ctx);
  zjs_free_context(ctx);
  printf(failures ? "abi host: %d FAILURES\n" : "abi host: ok (%d failures)\n", failures);
  return failures ? 1 : 0;
}
