/* The native stack's limit, through the public ABI (zjs.h): one context
   run on the main thread, on threads with small stacks, and on the main
   thread again. Recursion deeper than the stack it is running on ends in
   a RangeError the script catches, on each of them, and the limit is the
   thread's own: a small stack stops sooner, and the main thread's depth
   is back afterwards.

   Every recursion counts down from a bound, so an engine with no limit
   reaches the bottom and fails the check without running away. */
#include <pthread.h>
#include <stdio.h>

#include "zjs.h"

static int failures = 0;

static void fail(const char *what, const char *why) {
  fprintf(stderr, "stack: FAIL %s: %s\n", what, why);
  failures += 1;
}

/* Defined once; `depths()` runs each kind of native recursion to its
   RangeError and answers how deep the first got, or throws when one of
   them ends any other way. */
static const char *SETUP =
    "var reached = 0;"
    "function limited(what, run) {"
    "  try { run(); } catch (e) {"
    "    if (e instanceof RangeError) return;"
    "    throw new Error(what + ' threw ' + e);"
    "  }"
    "  throw new Error(what + ' reached the end');"
    "}"
    /* A callback: the dispatch loop entered again a level. */
    "function through(n) { reached = n; return n === 0 ? 0 : [n].map(function (m) { return through(m - 1); })[0]; }"
    "var nested = [1]; for (var i = 0; i < 100000; i++) nested = [nested];"
    /* A builtin constructor reached with a new target (super() to Array),
       a level of the native stack each time: the stack runs out on the way
       into it, among other places, and the next plain call of a builtin
       must still be a plain call. */
    "class Sub extends Array { constructor(n) { super(); if (n > 0) Reflect.construct(Sub, [n - 1]); } }"
    "function from(extra, n) { return extra === 0 ? Reflect.construct(Sub, [n]) : [0].map(function () { return from(extra - 1, n); })[0]; }"
    "class Plain { constructor(n) { if (n > 0) Reflect.construct(Plain, [n - 1]); } }"
    "function* nest(n) { yield n === 0 ? 0 : nest(n - 1).next().value + 1; }"
    /* What may run to its end or be refused, as the stack allows. */
    "function sound(what, run) {"
    "  try { run(); } catch (e) {"
    "    if (!(e instanceof RangeError) && !(e instanceof SyntaxError)) throw new Error(what + ' threw ' + e);"
    "  }"
    "}"
    /* The same source or data at depths a tenth apart. A check asks for
       room when the recursion under it begins, and that recursion takes
       more a level than the check counts: without the check further
       down, some rung lands where the first lets it through and the
       stack then runs out. */
    "function ladder(what, make) {"
    "  for (var n = 100; n < 100000; n = Math.ceil(n * 1.1)) sound(what, function () { make(n); });"
    "}"
    "function depths() {"
    "  limited('a callback', function () { through(100000); });"
    "  var deepest = 100000 - reached;"
    "  limited('join', function () { String(nested); });"
    "  limited('flat', function () { nested.flat(Infinity); });"
    "  limited('JSON.stringify', function () { JSON.stringify(nested); });"
    "  limited('JSON.parse', function () { JSON.parse('['.repeat(100000) + ']'.repeat(100000)); });"
    "  limited('the parser', function () { eval('!'.repeat(100000) + '1'); });"
    "  limited('the compiler', function () { eval('1' + '+1'.repeat(100000)); });"
    "  limited('a regular expression', function () { new RegExp('(?:'.repeat(100000) + 'a' + ')'.repeat(100000)); });"
    "  limited('Reflect.construct', function () { new Plain(100000); });"
    "  limited('a generator', function () { nest(100000).next(); });"
    "  limited('a chain of yield', function () { eval('(function*(){' + 'yield '.repeat(100000) + '1})'); });"
    /* Two thousand classes each extending the next: too deep to parse on
       the small stacks, and few enough to compile where it does parse. */
    "  sound('class heritage', function () { eval('(' + 'class extends '.repeat(2000) + 'Object' + '{}'.repeat(2000) + ')'); });"
    "  ladder('a chain of +', function (n) { eval('1' + '+1'.repeat(n)); });"
    "  ladder('nested try', function (n) { eval('try{'.repeat(n) + '}catch(e){}'.repeat(n)); });"
    "  ladder('nested patterns', function (n) { eval('var ' + '['.repeat(n) + 'p' + ']'.repeat(n) + '=[]'); });"
    "  ladder('a reviver', function (n) { JSON.parse('['.repeat(n) + ']'.repeat(n), function (k, v) { return v; }); });"
    "  for (var extra = 0; extra < 8; extra++) {"
    "    limited('a constructor', function () { from(extra, 100000); });"
    "    if (Object.getPrototypeOf(Array(1)) !== Array.prototype) throw new Error('a plain call made as a construction');"
    "  }"
    /* With little stack left: the error itself, and work after it. */
    "  function bottom(n) {"
    "    try { return [n].map(function (m) { return bottom(m + 1); })[0]; }"
    "    catch (e) {"
    "      try { new RegExp('(?:'.repeat(100000) + 'a' + ')'.repeat(100000)); } catch (inner) { }"
    "      return [n, String(e), JSON.stringify({ a: [1] }), /b+/.test('abb')].length;"
    "    }"
    "  }"
    "  if (bottom(0) !== 4) throw new Error('at the bottom');"
    "  return deepest;"
    "}";

typedef struct {
  ZjsContext *ctx;
  const char *what;
  int depth;
} Run;

static void *measure(void *arg) {
  Run *run = (Run *)arg;
  ZjsValue depth = zjs_eval(run->ctx, "depths()");
  if (zjs_had_error(run->ctx)) {
    fail(run->what, "a recursion did not end in a RangeError the script caught");
  } else if (!zjs_is_int32(depth) || zjs_as_int32(depth) <= 0) {
    fail(run->what, "no depth");
  } else {
    run->depth = zjs_as_int32(depth);
  }
  return NULL;
}

static void on_thread(Run *run, size_t stack_bytes) {
  pthread_attr_t attr;
  pthread_t thread;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, stack_bytes);
  if (pthread_create(&thread, &attr, measure, run) != 0) {
    fail(run->what, "no thread");
  } else {
    pthread_join(thread, NULL);
  }
  pthread_attr_destroy(&attr);
}

int main(void) {
  ZjsContext *ctx = zjs_new_context();
  zjs_eval(ctx, SETUP);
  if (zjs_had_error(ctx)) fail("setup", "threw");

  Run first = {ctx, "the main thread", 0};
  Run half = {ctx, "a 512 kB thread", 0};
  Run quarter = {ctx, "a 256 kB thread", 0};
  Run again = {ctx, "the main thread again", 0};
  measure(&first);
  on_thread(&half, 512 * 1024);
  on_thread(&quarter, 256 * 1024);
  measure(&again);

  if (failures == 0) {
    if (half.depth >= first.depth) fail("a 512 kB thread", "went as deep as the main thread");
    if (quarter.depth >= half.depth) fail("a 256 kB thread", "went as deep as a 512 kB thread");
    if (again.depth != first.depth) fail("the main thread again", "not the depth it reached before");
  }

  zjs_free_context(ctx);
  if (failures == 0) printf("stack: ok (%d levels on the main thread, %d on 512 kB, %d on 256 kB)\n", first.depth, half.depth, quarter.depth);
  return failures == 0 ? 0 : 1;
}
