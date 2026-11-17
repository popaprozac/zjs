/* Properties, elements, globals, and calls across the public ABI
 * (zjs.h), with what a throw inside one of them leaves; the jobs a call
 * queues; and the collector's calls and figures. */
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

/* The message of the context's error, when it is an Error. */
static int error_says(ZjsContext *ctx, const char *name) {
  ZjsValue error = zjs_get_error(ctx);
  uint32_t root = zjs_root(ctx, error);
  int same = zjs_had_error(ctx) == 1 && zjs_is_object(error) && text_says(zjs_get_property(ctx, error, "name"), name);
  zjs_unroot(ctx, root);
  return same;
}

static void properties(ZjsContext *ctx) {
  ZjsValue object = zjs_new_object(ctx);
  uint32_t kept = zjs_root(ctx, object);
  CHECK(zjs_is_undefined(zjs_get_property(ctx, object, "absent")) && zjs_had_error(ctx) == 0, "a property that is not there");
  zjs_set_property(ctx, object, "count", zjs_int32(1));
  zjs_set_property(ctx, object, "label", text(ctx, "h\xC3\xA9"));
  zjs_set_property(ctx, object, "ratio", zjs_double(0.5));
  zjs_set_property(ctx, object, "none", zjs_null());
  zjs_set_property(ctx, object, "", zjs_bool(1));
  CHECK(is_int(zjs_get_property(ctx, object, "count"), 1), "a number set and read");
  CHECK(text_says(zjs_get_property(ctx, object, "label"), "h\xC3\xA9"), "a string set and read");
  CHECK(zjs_as_double(zjs_get_property(ctx, object, "ratio")) == 0.5 && zjs_is_null(zjs_get_property(ctx, object, "none")), "a fraction and null");
  CHECK(zjs_as_bool(zjs_get_property(ctx, object, "")), "the empty name");
  zjs_set_property(ctx, object, "count", zjs_int32(2));
  CHECK(is_int(zjs_get_property(ctx, object, "count"), 2), "a property written again");
  ZjsValue inner = zjs_new_object(ctx);
  zjs_set_property(ctx, inner, "depth", zjs_int32(2));
  zjs_set_property(ctx, object, "inner", inner);
  CHECK(is_int(zjs_get_property(ctx, zjs_get_property(ctx, object, "inner"), "depth"), 2), "an object held by an object");
  zjs_set_global(ctx, "made", object);
  CHECK(text_says(zjs_eval(ctx, "JSON.stringify(made)"), "{\"count\":2,\"label\":\"h\xC3\xA9\",\"ratio\":0.5,\"none\":null,\"\":true,\"inner\":{\"depth\":2}}"), "as a program sees it, in the order it was written");

  /* Read as a program's `obj.name` reads: prototypes, accessors, primitives. */
  ZjsValue derived = zjs_eval(ctx, "Object.create({ inherited: 7, get viaGetter() { return this.own * 2; } }, { own: { value: 21, writable: true } })");
  CHECK(is_int(zjs_get_property(ctx, derived, "inherited"), 7) && is_int(zjs_get_property(ctx, derived, "viaGetter"), 42), "an inherited property and a getter");
  ZjsValue watched = zjs_eval(ctx, "({ set stored(v) { this.got = v + 1; }, fixed: 1 })");
  uint32_t watched_root = zjs_root(ctx, watched);
  zjs_set_property(ctx, watched, "stored", zjs_int32(4));
  CHECK(is_int(zjs_get_property(ctx, watched, "got"), 5), "a setter runs");
  CHECK(is_int(zjs_get_property(ctx, zjs_eval(ctx, "[1, 2, 3]"), "length"), 3), "an array's length");
  CHECK(is_int(zjs_get_property(ctx, text(ctx, "hello"), "length"), 5), "a string's length");
  CHECK(zjs_is_callable(zjs_get_property(ctx, zjs_int32(5), "toFixed")), "a number's method");
  CHECK(text_says(zjs_get_property(ctx, zjs_eval(ctx, "(function named() {})"), "name"), "named"), "a function's name");

  ZjsValue frozen = zjs_eval(ctx, "Object.freeze({ fixed: 1 })");
  zjs_set_property(ctx, frozen, "fixed", zjs_int32(2));
  zjs_set_property(ctx, frozen, "added", zjs_int32(3));
  CHECK(is_int(zjs_get_property(ctx, frozen, "fixed"), 1) && zjs_is_undefined(zjs_get_property(ctx, frozen, "added")) && zjs_had_error(ctx) == 0, "a frozen object is left as it is, quietly");
  zjs_set_property(ctx, zjs_int32(5), "x", zjs_int32(1));
  CHECK(zjs_had_error(ctx) == 0, "a write to a number does nothing");

  /* A throw inside a read or a write is the context's error. */
  CHECK(zjs_is_undefined(zjs_get_property(ctx, zjs_null(), "x")) && error_says(ctx, "TypeError"), "a property of null");
  CHECK(is_int(zjs_get_property(ctx, object, "count"), 2) && zjs_had_error(ctx) == 1, "a read that works leaves the error there");
  CHECK(is_int(zjs_eval(ctx, "1"), 1) && zjs_had_error(ctx) == 0, "an evaluation clears it");
  ZjsValue thrower = zjs_eval(ctx, "({ get bad() { throw new RangeError('from a getter'); }, set worse(v) { throw 'from a setter'; } })");
  uint32_t thrower_root = zjs_root(ctx, thrower);
  CHECK(zjs_is_undefined(zjs_get_property(ctx, thrower, "bad")) && error_says(ctx, "RangeError"), "a getter that throws");
  zjs_eval(ctx, "0");
  zjs_set_property(ctx, thrower, "worse", zjs_int32(1));
  CHECK(zjs_had_error(ctx) == 1 && text_says(zjs_get_error(ctx), "from a setter"), "a setter that throws");
  zjs_eval(ctx, "0");
  zjs_set_property(ctx, zjs_undefined(), "x", zjs_int32(1));
  CHECK(error_says(ctx, "TypeError"), "a write to undefined");
  zjs_eval(ctx, "0");
  zjs_unroot(ctx, thrower_root);
  zjs_unroot(ctx, watched_root);
  zjs_unroot(ctx, kept);
}

static void elements(ZjsContext *ctx) {
  ZjsValue array = zjs_new_array(ctx, 3);
  uint32_t kept = zjs_root(ctx, array);
  zjs_set_global(ctx, "list", array);
  CHECK(zjs_is_undefined(zjs_get_element(ctx, array, 0)) && zjs_as_bool(zjs_eval(ctx, "list.length === 3 && 0 in list && 2 in list && list[1] === undefined")), "a new array's elements are there and undefined");
  zjs_set_element(ctx, array, 1, zjs_int32(5));
  zjs_set_element(ctx, array, 2, text(ctx, "two"));
  CHECK(is_int(zjs_get_element(ctx, array, 1), 5) && text_says(zjs_get_element(ctx, array, 2), "two"), "elements set and read");
  CHECK(zjs_is_undefined(zjs_get_element(ctx, array, 99)) && zjs_had_error(ctx) == 0, "an element past the end");
  zjs_set_element(ctx, array, 10, zjs_bool(1));
  CHECK(zjs_array_length(array) == 11 && zjs_as_bool(zjs_get_element(ctx, array, 10)) && zjs_as_bool(zjs_eval(ctx, "!(5 in list) && list.length === 11")), "a write past the end lengthens it, leaving holes");
  ZjsValue object = zjs_new_object(ctx);
  zjs_set_element(ctx, object, 7, zjs_int32(70));
  zjs_set_element(ctx, object, 3000000000u, zjs_int32(30));
  CHECK(is_int(zjs_get_element(ctx, object, 7), 70) && is_int(zjs_get_property(ctx, object, "7"), 70), "an object's element is its property of that name");
  CHECK(is_int(zjs_get_element(ctx, object, 3000000000u), 30) && is_int(zjs_get_property(ctx, object, "3000000000"), 30), "an index past the int32 range");
  CHECK(text_says(zjs_get_element(ctx, text(ctx, "abc"), 1), "b") && zjs_is_undefined(zjs_get_element(ctx, text(ctx, "abc"), 3)), "a string's characters");
  CHECK(is_int(zjs_get_element(ctx, zjs_eval(ctx, "[10, 20, 30]"), 2), 30), "a program's array");
  zjs_set_property(ctx, array, "12", zjs_int32(120));
  zjs_set_property(ctx, array, "012", zjs_int32(1));
  CHECK(zjs_array_length(array) == 13 && is_int(zjs_get_property(ctx, array, "12"), 120) && is_int(zjs_get_element(ctx, array, 12), 120), "a name that is an index is the element; one that only looks like it is not");
  CHECK(zjs_is_undefined(zjs_get_element(ctx, zjs_undefined(), 0)) && error_says(ctx, "TypeError"), "an element of undefined");
  zjs_eval(ctx, "0");
  zjs_unroot(ctx, kept);
}

static void globals(ZjsContext *ctx) {
  CHECK(zjs_is_undefined(zjs_get_global(ctx, "neverDeclared")) && zjs_had_error(ctx) == 0, "a global that is not there is undefined, not an error");
  zjs_set_global(ctx, "fromC", zjs_int32(7));
  CHECK(is_int(zjs_eval(ctx, "fromC + 1"), 8) && zjs_as_bool(zjs_eval(ctx, "globalThis.fromC === 7 && 'fromC' in globalThis")), "a global set here is one to a program");
  zjs_eval(ctx, "var declared = 5; function helper() { return 'helped'; }");
  CHECK(is_int(zjs_get_global(ctx, "declared"), 5) && zjs_is_function(zjs_get_global(ctx, "helper")), "a program's var and function are globals here");
  zjs_set_global(ctx, "declared", zjs_int32(9));
  CHECK(is_int(zjs_eval(ctx, "declared"), 9), "and can be written");
  zjs_eval(ctx, "globalThis.viaObject = 'assigned'");
  CHECK(text_says(zjs_get_global(ctx, "viaObject"), "assigned"), "a property of the global object");
  CHECK(zjs_is_object(zjs_get_global(ctx, "Math")) && zjs_is_callable(zjs_get_global(ctx, "parseInt")), "the builtins");
  zjs_set_global(ctx, "replaced", text(ctx, "first"));
  zjs_set_global(ctx, "replaced", text(ctx, "second"));
  CHECK(text_says(zjs_get_global(ctx, "replaced"), "second"), "set twice");
}

static int interrupt_now(void *opaque) {
  return *(int *)opaque;
}

static void calls(ZjsContext *ctx) {
  ZjsValue add = zjs_eval(ctx, "(function (a, b) { var k = this ? this.k : 0; return a + b + (k || 0); })");
  uint32_t add_root = zjs_root(ctx, add);
  ZjsValue two[2] = { zjs_int32(2), zjs_int32(3) };
  CHECK(is_int(zjs_call(ctx, add, zjs_undefined(), two, 2), 5) && zjs_had_error(ctx) == 0, "a function called with two arguments");
  ZjsValue receiver = zjs_eval(ctx, "({ k: 10 })");
  add = zjs_root_get(ctx, add_root);
  CHECK(is_int(zjs_call(ctx, add, receiver, two, 2), 15), "and with a receiver");
  ZjsValue words[2];
  words[0] = text(ctx, "con");
  words[1] = text(ctx, "cat");
  CHECK(text_says(zjs_call(ctx, zjs_root_get(ctx, add_root), zjs_undefined(), words, 2), "concat0"), "with strings");
  CHECK(zjs_is_number(zjs_call(ctx, zjs_root_get(ctx, add_root), zjs_undefined(), NULL, 0)), "with no arguments");
  CHECK(zjs_is_number(zjs_call(ctx, zjs_root_get(ctx, add_root), zjs_undefined(), two, 1)), "with fewer than it names");

  ZjsValue max = zjs_get_property(ctx, zjs_get_global(ctx, "Math"), "max");
  ZjsValue three[3] = { zjs_int32(1), zjs_int32(9), zjs_int32(4) };
  CHECK(is_int(zjs_call(ctx, max, zjs_undefined(), three, 3), 9), "a builtin");
  ZjsValue many[300];
  for (int i = 0; i < 300; i++) many[i] = zjs_int32(i);
  ZjsValue sum = zjs_eval(ctx, "(function () { var total = 0; for (var i = 0; i < arguments.length; i++) total += arguments[i]; return total; })");
  CHECK(is_int(zjs_call(ctx, sum, zjs_undefined(), many, 300), 44850), "three hundred arguments");
  ZjsValue counter = zjs_eval(ctx, "(function () { var n = 0; return function () { n++; return n; }; })()");
  uint32_t counter_root = zjs_root(ctx, counter);
  zjs_call(ctx, zjs_root_get(ctx, counter_root), zjs_undefined(), NULL, 0);
  zjs_call(ctx, zjs_root_get(ctx, counter_root), zjs_undefined(), NULL, 0);
  CHECK(is_int(zjs_call(ctx, zjs_root_get(ctx, counter_root), zjs_undefined(), NULL, 0), 3), "a closure keeps its state between calls");
  ZjsValue made = zjs_call(ctx, zjs_eval(ctx, "(function (n) { return { doubled: n * 2, list: [n, n] }; })"), zjs_undefined(), two, 1);
  CHECK(zjs_is_object(made) && is_int(zjs_get_property(ctx, made, "doubled"), 4), "an object returned");
  ZjsValue method = zjs_eval(ctx, "({ k: 3, twice() { return this.k * 2; } })");
  uint32_t method_root = zjs_root(ctx, method);
  CHECK(is_int(zjs_call(ctx, zjs_get_property(ctx, method, "twice"), zjs_root_get(ctx, method_root), NULL, 0), 6), "a method called on its object");
  zjs_unroot(ctx, method_root);

  /* What a call threw. */
  ZjsValue thrower = zjs_eval(ctx, "(function (what) { throw what === 1 ? new RangeError('one') : what; })");
  uint32_t thrower_root = zjs_root(ctx, thrower);
  ZjsValue one[1] = { zjs_int32(1) };
  CHECK(zjs_is_undefined(zjs_call(ctx, thrower, zjs_undefined(), one, 1)) && error_says(ctx, "RangeError"), "a call that throws returns undefined and reports it");
  one[0] = text(ctx, "thrown text");
  zjs_call(ctx, zjs_root_get(ctx, thrower_root), zjs_undefined(), one, 1);
  CHECK(zjs_had_error(ctx) == 1 && text_says(zjs_get_error(ctx), "thrown text"), "a thrown string");
  CHECK(is_int(zjs_call(ctx, zjs_root_get(ctx, add_root), zjs_undefined(), two, 2), 5) && zjs_had_error(ctx) == 0 && zjs_is_undefined(zjs_get_error(ctx)), "the next call clears the error");
  CHECK(zjs_is_undefined(zjs_call(ctx, zjs_int32(5), zjs_undefined(), NULL, 0)) && error_says(ctx, "TypeError"), "what is not a function");
  CHECK(zjs_is_undefined(zjs_call(ctx, zjs_eval(ctx, "({})"), zjs_undefined(), NULL, 0)) && error_says(ctx, "TypeError"), "nor is an object");
  zjs_unroot(ctx, thrower_root);

  /* The jobs a call queues have run when it returns. */
  ZjsValue later = zjs_eval(ctx, "var ran = 0; (function () { Promise.resolve().then(function () { ran += 1; }).then(function () { ran += 10; }); return 'returned'; })");
  CHECK(text_says(zjs_call(ctx, later, zjs_undefined(), NULL, 0), "returned") && is_int(zjs_get_global(ctx, "ran"), 11), "a call's jobs run before it returns");
  CHECK(zjs_has_pending_work(ctx) == 0, "and none is left");
  ZjsValue awaited = zjs_eval(ctx, "var awaitedValue; (async function (n) { awaitedValue = (await n) + 1; return 'done'; })");
  one[0] = zjs_int32(41);
  CHECK(zjs_is_object(zjs_call(ctx, awaited, zjs_undefined(), one, 1)) && is_int(zjs_get_global(ctx, "awaitedValue"), 42), "an async function runs to its end");

  /* A getter's jobs wait for a drain. */
  ZjsValue queuing = zjs_eval(ctx, "var drained = 'no'; ({ get later() { Promise.resolve().then(function () { drained = 'yes'; }); return 1; } })");
  uint32_t queuing_root = zjs_root(ctx, queuing);
  CHECK(is_int(zjs_get_property(ctx, queuing, "later"), 1) && zjs_has_pending_work(ctx) == 1, "a getter's job is pending after the read");
  CHECK(text_says(zjs_get_global(ctx, "drained"), "no"), "and has not run");
  zjs_drain_microtasks(ctx);
  CHECK(zjs_has_pending_work(ctx) == 0 && text_says(zjs_get_global(ctx, "drained"), "yes"), "a drain runs it");
  zjs_drain_microtasks(ctx);
  CHECK(zjs_has_pending_work(ctx) == 0 && zjs_had_error(ctx) == 0, "a drain with nothing queued");
  zjs_get_property(ctx, zjs_root_get(ctx, queuing_root), "later");
  CHECK(zjs_has_pending_work(ctx) == 1 && is_int(zjs_eval(ctx, "1"), 1) && zjs_has_pending_work(ctx) == 0, "or the next evaluation does");
  zjs_unroot(ctx, queuing_root);

  /* The interrupt handler stops a call as it stops an evaluation. */
  int stop = 1;
  ZjsValue forever = zjs_eval(ctx, "(function () { for (;;) {} })");
  zjs_set_interrupt_handler(ctx, interrupt_now, &stop);
  CHECK(zjs_is_undefined(zjs_call(ctx, forever, zjs_undefined(), NULL, 0)) && zjs_had_error(ctx) == 1 && zjs_is_interrupted(ctx) == 1, "an endless call is stopped");
  stop = 0;
  CHECK(is_int(zjs_call(ctx, zjs_root_get(ctx, add_root), zjs_undefined(), two, 2), 5) && zjs_had_error(ctx) == 0 && zjs_is_interrupted(ctx) == 0, "and the context goes on");
  ZjsValue spinning = zjs_eval(ctx, "({ get spin() { for (;;) {} } })");
  stop = 1;
  CHECK(zjs_is_undefined(zjs_get_property(ctx, spinning, "spin")) && zjs_had_error(ctx) == 1 && zjs_is_interrupted(ctx) == 1, "an endless getter is stopped");
  stop = 0;
  zjs_set_interrupt_handler(ctx, NULL, NULL);
  CHECK(is_int(zjs_eval(ctx, "2 + 2"), 4) && zjs_is_interrupted(ctx) == 0, "and the context goes on again");
  zjs_unroot(ctx, counter_root);
  zjs_unroot(ctx, add_root);
}

static void collector(ZjsContext *ctx) {
  unsigned int collections = zjs_gc_collections(ctx);
  unsigned int freed = zjs_gc_cells_freed(ctx);
  ZjsValue kept = zjs_eval(ctx, "var held = []; for (var i = 0; i < 20000; i++) held.push({ n: i }); ({ survivor: 'kept ' + held.length })");
  uint32_t root = zjs_root(ctx, kept);
  unsigned int full = zjs_cell_count(ctx);
  CHECK(full > 20000, "twenty thousand objects are cells");
  zjs_gc(ctx);
  CHECK(zjs_gc_collections(ctx) > collections, "a collection is counted");
  CHECK(zjs_cell_count(ctx) > 20000, "what a program holds survives it");
  CHECK(text_says(zjs_get_property(ctx, zjs_root_get(ctx, root), "survivor"), "kept 20000"), "and what the embedder rooted");
  zjs_eval(ctx, "held = null");
  zjs_gc(ctx);
  CHECK(zjs_cell_count(ctx) + 20000 <= full, "what nothing holds is given back");
  CHECK(zjs_gc_cells_freed(ctx) >= freed + 20000, "and counted");
  CHECK(text_says(zjs_get_property(ctx, zjs_root_get(ctx, root), "survivor"), "kept 20000"), "the rooted one is still there");
  CHECK(zjs_gc_pause_ns_total(ctx) > 0 && zjs_gc_pause_ns_max(ctx) > 0 && zjs_gc_pause_ns_max(ctx) <= zjs_gc_pause_ns_total(ctx), "the pauses were timed");
  uint64_t before = zjs_gc_pause_ns_total(ctx);
  zjs_gc(ctx);
  zjs_gc(ctx);
  CHECK(zjs_gc_pause_ns_total(ctx) > before && zjs_gc_collections(ctx) >= collections + 4, "each collection adds to them");
  zjs_unroot(ctx, root);
}

static void nothing(ZjsContext *live) {
  ZjsContext *other = zjs_new_context();
  ZjsValue theirs = zjs_eval(other, "({ theirs: 1 })");
  ZjsValue their_fn = zjs_eval(other, "(function () { return 1; })");
  /* Another context's cell is undefined to this one. */
  CHECK(zjs_is_undefined(zjs_get_property(live, theirs, "theirs")) && zjs_had_error(live) == 1, "another context's object has no properties here");
  zjs_eval(live, "0");
  CHECK(zjs_is_undefined(zjs_call(live, their_fn, zjs_undefined(), NULL, 0)) && zjs_had_error(live) == 1, "nor can its function be called here");
  zjs_eval(live, "0");
  zjs_set_global(live, "borrowed", theirs);
  CHECK(zjs_is_undefined(zjs_get_global(live, "borrowed")), "nor stored here");
  zjs_free_context(other);
  CHECK(zjs_is_undefined(zjs_get_global(other, "Math")) && zjs_is_undefined(zjs_call(other, their_fn, zjs_undefined(), NULL, 0)) && zjs_cell_count(other) == 0, "a freed context answers nothing");
  zjs_set_global(other, "x", zjs_int32(1));
  zjs_set_property(other, theirs, "x", zjs_int32(1));
  zjs_set_element(other, theirs, 0, zjs_int32(1));
  zjs_drain_microtasks(other);
  zjs_gc(other);
  CHECK(zjs_has_pending_work(other) == 0 && zjs_gc_collections(other) == 0 && zjs_gc_pause_ns_total(other) == 0 && zjs_gc_cells_freed(other) == 0, "and does nothing");

  ZjsValue one = zjs_int32(1);
  CHECK(zjs_is_undefined(zjs_get_property(NULL, one, "x")) && zjs_is_undefined(zjs_get_element(NULL, one, 0)) && zjs_is_undefined(zjs_get_global(NULL, "x")), "no context reads nothing");
  CHECK(zjs_is_undefined(zjs_call(NULL, one, one, NULL, 0)) && zjs_has_pending_work(NULL) == 0 && zjs_cell_count(NULL) == 0, "calls nothing");
  CHECK(zjs_is_undefined(zjs_get_property(live, one, NULL)) && zjs_is_undefined(zjs_get_global(live, NULL)), "nor does no name");
  CHECK(zjs_is_undefined(zjs_call(live, one, one, NULL, 3)), "nor arguments that are not there");
  zjs_set_property(NULL, one, "x", one);
  zjs_set_property(live, one, NULL, one);
  zjs_set_element(NULL, one, 0, one);
  zjs_set_global(NULL, "x", one);
  zjs_set_global(live, NULL, one);
  zjs_drain_microtasks(NULL);
  zjs_gc(NULL);

  /* A core context with no Promise installed still calls. */
  ZjsContext *core = zjs_new_core_context();
  ZjsValue twice = zjs_eval(core, "(function (x) { return x * 2; })");
  CHECK(is_int(zjs_call(core, twice, zjs_undefined(), &one, 1), 2), "a call on a core context");
  zjs_set_global(core, "seen", zjs_int32(3));
  CHECK(is_int(zjs_eval(core, "seen + 1"), 4), "and its globals");
  zjs_free_context(core);

  /* A context freed with a job queued drops it. */
  ZjsContext *busy = zjs_new_context();
  zjs_get_property(busy, zjs_eval(busy, "({ get later() { Promise.resolve().then(function () {}); return 1; } })"), "later");
  CHECK(zjs_has_pending_work(busy) == 1, "a job is queued");
  zjs_free_context(busy);
  CHECK(zjs_has_pending_work(busy) == 0, "and gone with its context");
}

int main(void) {
  ZjsContext *ctx = zjs_new_context();
  CHECK(ctx != NULL, "a context");
  properties(ctx);
  elements(ctx);
  globals(ctx);
  calls(ctx);
  collector(ctx);
  nothing(ctx);
  zjs_free_context(ctx);
  printf(failures ? "abi calls: %d FAILURES\n" : "abi calls: ok (%d failures)\n", failures);
  return failures ? 1 : 0;
}
