/* Values across the public ABI (zjs.h): numbers, booleans, null, and
 * undefined made and read with no context; what an evaluation returns
 * and what it threw; strings, objects, and arrays made by the embedder;
 * and values kept alive across collections with roots and pins. */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "zjs.h"

static int failures = 0;

#define CHECK(condition, what) \
  do { \
    if (!(condition)) { printf("FAIL: %s (line %d)\n", what, __LINE__); failures++; } \
  } while (0)

/* A string value whose UTF-8 text is exactly these bytes, with a NUL after them. */
static int text_is(ZjsValue value, const char *bytes, uint32_t length) {
  uint32_t got = 12345;
  const char *text = zjs_string_bytes(value, &got);
  return text != NULL && got == length && memcmp(text, bytes, length) == 0 && text[length] == 0;
}

static int text_says(ZjsValue value, const char *expected) {
  return text_is(value, expected, (uint32_t)strlen(expected));
}

/* How many of the kind predicates say yes: a value is of one kind at most. */
static int kinds(ZjsValue v) {
  return zjs_is_int32(v) + zjs_is_double(v) + zjs_is_bool(v) + zjs_is_null(v) + zjs_is_undefined(v) + zjs_is_cell(v);
}

static int cell_kinds(ZjsValue v) {
  return zjs_is_string(v) + zjs_is_object(v) + zjs_is_array(v) + zjs_is_function(v) + zjs_is_host_function(v);
}

/* Enough allocation for several collections, minor and full. */
static void churn(ZjsContext *ctx) {
  ZjsValue done = zjs_eval(ctx, "var junk = []; for (var i = 0; i < 300000; i++) { junk[i & 1023] = { n: i, text: 'x' + i, list: [i] }; } junk.length");
  CHECK(zjs_is_int32(done) && zjs_as_int32(done) == 1024, "the churning script ran");
}

static void immediates(void) {
  static const int32_t ints[] = { 0, 1, -1, 42, INT32_MAX, INT32_MIN };
  static const double doubles[] = { 0.5, -0.5, 3.0, 1e300, -1e-300, 4294967296.0 };
  for (size_t i = 0; i < sizeof ints / sizeof ints[0]; i++) {
    ZjsValue v = zjs_int32(ints[i]);
    CHECK(zjs_is_int32(v) && zjs_is_number(v) && !zjs_is_double(v) && kinds(v) == 1, "an int32 is an int32 and nothing else");
    CHECK(zjs_as_int32(v) == ints[i], "an int32 comes back");
    CHECK(zjs_as_double(v) == (double)ints[i], "an int32 reads as its double");
  }
  for (size_t i = 0; i < sizeof doubles / sizeof doubles[0]; i++) {
    ZjsValue v = zjs_double(doubles[i]);
    CHECK(zjs_is_double(v) && zjs_is_number(v) && !zjs_is_int32(v) && kinds(v) == 1, "a double is a double and nothing else");
    CHECK(zjs_as_double(v) == doubles[i], "a double comes back");
  }
  ZjsValue negative_zero = zjs_double(-0.0);
  CHECK(zjs_is_double(negative_zero) && zjs_as_double(negative_zero) == 0.0 && signbit(zjs_as_double(negative_zero)), "negative zero keeps its sign");
  CHECK(zjs_is_double(zjs_double(INFINITY)) && zjs_as_double(zjs_double(-INFINITY)) == -INFINITY, "the infinities");
  /* Every NaN, whatever its bits, is a double and not a cell. */
  uint64_t nan_bits[] = { 0x7FF8000000000000ULL, 0xFFF8000000000000ULL, 0xFFFFFFFFFFFFFFFFULL, 0x7FF0000000000001ULL };
  for (size_t i = 0; i < sizeof nan_bits / sizeof nan_bits[0]; i++) {
    double d;
    memcpy(&d, &nan_bits[i], sizeof d);
    ZjsValue v = zjs_double(d);
    CHECK(zjs_is_double(v) && kinds(v) == 1 && isnan(zjs_as_double(v)), "a NaN of any bits is a number");
  }
  CHECK(zjs_is_bool(zjs_bool(1)) && zjs_as_bool(zjs_bool(1)) == 1 && kinds(zjs_bool(1)) == 1, "true");
  CHECK(zjs_is_bool(zjs_bool(0)) && zjs_as_bool(zjs_bool(0)) == 0 && kinds(zjs_bool(0)) == 1, "false");
  CHECK(zjs_as_bool(zjs_bool(-7)) == 1, "any nonzero is true");
  CHECK(zjs_is_null(zjs_null()) && kinds(zjs_null()) == 1, "null");
  CHECK(zjs_is_undefined(zjs_undefined()) && kinds(zjs_undefined()) == 1, "undefined");
  CHECK(cell_kinds(zjs_int32(5)) + cell_kinds(zjs_null()) + cell_kinds(zjs_double(1.5)) == 0, "what is not a cell is no kind of cell");
  CHECK(zjs_string_bytes(zjs_int32(5), NULL) == NULL && zjs_array_length(zjs_undefined()) == 0, "nor has text or a length");
  CHECK(zjs_version() != NULL && zjs_version()[0] != 0, "a version");
}

static void results(ZjsContext *ctx) {
  ZjsValue v = zjs_eval(ctx, "1 + 2");
  CHECK(zjs_is_int32(v) && zjs_as_int32(v) == 3 && zjs_had_error(ctx) == 0, "an integer result");
  v = zjs_eval(ctx, "0.5 + 0.25");
  CHECK(zjs_is_double(v) && zjs_as_double(v) == 0.75, "a fraction");
  v = zjs_eval(ctx, "7 > 3");
  CHECK(zjs_is_bool(v) && zjs_as_bool(v), "a boolean");
  CHECK(zjs_is_null(zjs_eval(ctx, "null")), "null as a result");
  CHECK(zjs_is_undefined(zjs_eval(ctx, "void 0")), "undefined as a result");
  CHECK(zjs_is_undefined(zjs_eval(ctx, "var declared = 1;")), "a statement with no value");

  v = zjs_eval(ctx, "'h\\u00e9' + 'llo ' + 1");
  CHECK(zjs_is_string(v) && zjs_is_cell(v) && cell_kinds(v) == 1 && kinds(v) == 1, "a string result is a string and nothing else");
  CHECK(text_says(v, "h\xC3\xA9llo 1"), "its text as UTF-8");
  CHECK(text_says(zjs_eval(ctx, "'\\u{1F600}!'"), "\xF0\x9F\x98\x80!"), "a character outside the basic plane");
  CHECK(text_is(zjs_eval(ctx, "'a\\0b'"), "a\0b", 3), "a NUL inside a string");
  CHECK(text_says(zjs_eval(ctx, "''"), ""), "the empty string");
  CHECK(text_says(zjs_eval(ctx, "'x'.repeat(5000)[4999] + 'y'.repeat(3)"), "xyyy"), "a string made at run time");
  uint32_t long_length = 0;
  const char *long_text = zjs_string_bytes(zjs_eval(ctx, "'ab'.repeat(40000)"), &long_length);
  CHECK(long_text != NULL && long_length == 80000 && long_text[79999] == 'b' && long_text[80000] == 0, "a long string");

  v = zjs_eval(ctx, "({ a: 1 })");
  CHECK(zjs_is_object(v) && cell_kinds(v) == 1, "an object");
  v = zjs_eval(ctx, "[1, 2, 3]");
  CHECK(zjs_is_array(v) && cell_kinds(v) == 1 && zjs_array_length(v) == 3, "an array and its length");
  CHECK(zjs_array_length(zjs_eval(ctx, "new Array(70000)")) == 70000, "a long array's length");
  v = zjs_eval(ctx, "(function named() {})");
  CHECK(zjs_is_function(v) && zjs_is_callable(v) && cell_kinds(v) == 1, "a function");
  v = zjs_eval(ctx, "(() => 1)");
  CHECK(zjs_is_function(v) && zjs_is_callable(v), "an arrow function");
  v = zjs_eval(ctx, "Math.max");
  CHECK(zjs_is_host_function(v) && zjs_is_callable(v) && !zjs_is_function(v), "a builtin function");
  v = zjs_eval(ctx, "Symbol('s')");
  CHECK(zjs_is_cell(v) && cell_kinds(v) == 0, "a symbol is a cell of none of the kinds");
  CHECK(zjs_is_object(zjs_eval(ctx, "new Map()")) && zjs_is_object(zjs_eval(ctx, "/x/g")) && zjs_is_object(zjs_eval(ctx, "new Date(0)")), "other objects are objects");
  CHECK(zjs_is_object(zjs_eval(ctx, "Promise.resolve(1)")) && zjs_is_object(zjs_eval(ctx, "new String('boxed')")), "a promise and a wrapper are objects");
  CHECK(zjs_array_length(zjs_eval(ctx, "({ length: 5 })")) == 0, "what is not an array has no array length");

  /* What a program threw. */
  v = zjs_eval(ctx, "throw new RangeError('no')");
  CHECK(zjs_is_undefined(v) && zjs_had_error(ctx) == 1, "a throw returns undefined and is reported");
  CHECK(zjs_is_object(zjs_get_error(ctx)), "the error that was thrown");
  v = zjs_eval(ctx, "throw 'only text'");
  CHECK(zjs_had_error(ctx) == 1 && text_says(zjs_get_error(ctx), "only text"), "a thrown string");
  v = zjs_eval(ctx, "throw 7");
  CHECK(zjs_is_int32(zjs_get_error(ctx)) && zjs_as_int32(zjs_get_error(ctx)) == 7, "a thrown number");
  v = zjs_eval(ctx, "var = ;");
  CHECK(zjs_is_undefined(v) && zjs_had_error(ctx) == 1 && zjs_is_object(zjs_get_error(ctx)), "source that does not parse");
  v = zjs_eval(ctx, "40 + 2");
  CHECK(zjs_as_int32(v) == 42 && zjs_had_error(ctx) == 0 && zjs_is_undefined(zjs_get_error(ctx)), "the next evaluation clears the error");

  /* The other evaluators return their value too. */
  size_t length = 0;
  unsigned char *program = zjs_compile_to_bytecode(ctx, "6 * 7", &length);
  CHECK(program != NULL && length > 0, "a program compiled to bytecode");
  if (program != NULL) {
    v = zjs_eval_bytecode(ctx, program, length);
    CHECK(zjs_is_int32(v) && zjs_as_int32(v) == 42, "bytecode's result");
    free(program);
  }
  const char *module = "export const answer = 42;";
  v = zjs_eval_module_source(ctx, module, strlen(module), "/virtual/abi-values.mjs");
  CHECK(zjs_is_object(v) && zjs_had_error(ctx) == 0, "a module's namespace");
}

static void made_here(ZjsContext *ctx) {
  ZjsValue hello = zjs_new_string(ctx, "hello", 5);
  CHECK(zjs_is_string(hello) && text_says(hello, "hello"), "a string made by the embedder");
  CHECK(zjs_new_string(ctx, "hello", 5).bits == hello.bits, "the same text is the same string");
  CHECK(zjs_new_string(ctx, "hello world", 5).bits == hello.bits, "the length says where the text ends");
  CHECK(zjs_new_string(ctx, "hellp", 5).bits != hello.bits, "other text is another string");
  CHECK(text_says(zjs_new_string(ctx, "", 0), "") && text_says(zjs_new_string(ctx, NULL, 0), ""), "the empty string, from no bytes");
  CHECK(text_is(zjs_new_string(ctx, "a\0b", 3), "a\0b", 3), "a NUL inside");
  CHECK(text_says(zjs_new_string(ctx, "h\xC3\xA9 \xF0\x9F\x98\x80", 8), "h\xC3\xA9 \xF0\x9F\x98\x80"), "UTF-8 in is UTF-8 out");
  const char *once = zjs_string_bytes(hello, NULL);
  CHECK(once != NULL && zjs_string_bytes(hello, NULL) == once, "a string's bytes stay where they are");
  ZjsValue from_program = zjs_eval(ctx, "'hel' + 'lo'");
  CHECK(text_says(from_program, "hello"), "a program's string of the same text");

  ZjsValue object = zjs_new_object(ctx);
  CHECK(zjs_is_object(object) && cell_kinds(object) == 1, "an object made by the embedder");
  CHECK(zjs_new_object(ctx).bits != object.bits, "each a new one");
  ZjsValue array = zjs_new_array(ctx, 4);
  CHECK(zjs_is_array(array) && zjs_array_length(array) == 4, "an array of four");
  CHECK(zjs_array_length(zjs_new_array(ctx, 0)) == 0 && zjs_array_length(zjs_new_array(ctx, 5000)) == 5000, "of none, and of many");
}

static void kept(ZjsContext *ctx) {
  /* A root keeps a value through collections; the handle reads it back. */
  ZjsValue made = zjs_eval(ctx, "'kept ' + 'alive ' + Math.sqrt(16)");
  uint32_t root = zjs_root(ctx, made);
  CHECK(root != 0, "a root");
  const char *before = zjs_string_bytes(made, NULL);
  churn(ctx);
  ZjsValue back = zjs_root_get(ctx, root);
  CHECK(back.bits == made.bits && text_says(back, "kept alive 4"), "a rooted string after collections");
  CHECK(zjs_string_bytes(back, NULL) == before, "and its bytes are where they were");

  uint32_t second = zjs_root(ctx, zjs_eval(ctx, "({ tag: 'second' })"));
  uint32_t third = zjs_root(ctx, zjs_int32(-3));
  CHECK(second != 0 && third != 0 && second != root && third != second, "roots are separate");
  churn(ctx);
  CHECK(zjs_is_object(zjs_root_get(ctx, second)) && zjs_as_int32(zjs_root_get(ctx, third)) == -3, "each holds its own");
  CHECK(text_says(zjs_root_get(ctx, root), "kept alive 4"), "the first still holds");

  zjs_unroot(ctx, second);
  CHECK(zjs_is_undefined(zjs_root_get(ctx, second)), "a root given back holds nothing");
  zjs_unroot(ctx, second);
  uint32_t reused = zjs_root(ctx, zjs_bool(1));
  CHECK(reused == second && zjs_as_bool(zjs_root_get(ctx, reused)), "its place is used again");
  uint32_t fresh = zjs_root(ctx, zjs_null());
  CHECK(fresh != reused && fresh != root && fresh != third, "giving back twice frees one place");
  CHECK(zjs_is_undefined(zjs_root_get(ctx, 0)) && zjs_is_undefined(zjs_root_get(ctx, 99999)), "no such root");
  zjs_unroot(ctx, 0);
  zjs_unroot(ctx, 99999);
  zjs_unroot(ctx, root);
  zjs_unroot(ctx, third);
  zjs_unroot(ctx, reused);
  zjs_unroot(ctx, fresh);

  /* A pin keeps the value the C frame holds. */
  ZjsValue pinned = zjs_eval(ctx, "'pinned ' + [1, 2, 3].join('-')");
  zjs_pin(ctx, pinned);
  churn(ctx);
  CHECK(text_says(pinned, "pinned 1-2-3"), "a pinned string after collections");
  ZjsValue replaced = zjs_eval(ctx, "'replaced ' + [4, 5].join('+')");
  zjs_pin_replace(ctx, replaced);
  zjs_pin(ctx, zjs_eval(ctx, "[10, 20, 30]"));
  churn(ctx);
  CHECK(text_says(replaced, "replaced 4+5"), "the value a pin was replaced with");
  zjs_unpin(ctx);
  churn(ctx);
  CHECK(text_says(replaced, "replaced 4+5"), "still pinned under the one that was popped");
  zjs_unpin(ctx);
  zjs_unpin(ctx);
  zjs_pin_replace(ctx, zjs_int32(1));
  zjs_unpin(ctx);
  zjs_unpin(ctx);
  CHECK(zjs_as_int32(zjs_eval(ctx, "1 + 1")) == 2, "unpinning with nothing pinned does no harm");
}

/* Bits no call ever returned: the engine takes them for undefined. */
static void strangers(ZjsContext *ctx) {
  ZjsValue object = zjs_eval(ctx, "({})");
  uint32_t kept = zjs_root(ctx, object);
  ZjsValue far = object, marker, hole, nothing;
  far.bits = (object.bits & ~0x3FFFFFFFFULL) | (0xFFFFFFF0ULL << 2);
  marker.bits = 0x10002;
  hole.bits = 0x20002;
  nothing.bits = 0;
  uint32_t first = zjs_root(ctx, far);
  uint32_t root = first;
  CHECK(zjs_is_undefined(zjs_root_get(ctx, root)), "a handle past the heap's end");
  zjs_unroot(ctx, root);
  root = zjs_root(ctx, marker);
  CHECK(root == first && zjs_is_undefined(zjs_root_get(ctx, root)), "one of the engine's own markers");
  zjs_unroot(ctx, root);
  root = zjs_root(ctx, hole);
  CHECK(root == first && zjs_is_undefined(zjs_root_get(ctx, root)), "the other");
  zjs_unroot(ctx, root);
  root = zjs_root(ctx, nothing);
  CHECK(root == first && zjs_is_undefined(zjs_root_get(ctx, root)) && !zjs_is_cell(nothing), "and zero");
  zjs_unroot(ctx, root);
  root = zjs_root(ctx, zjs_int32(1));
  CHECK(root == first, "each gave its place back");
  zjs_unroot(ctx, root);
  far.bits = (object.bits & ~(7ULL << 45)) | (1ULL << 45);
  CHECK(zjs_string_bytes(far, NULL) == NULL, "an object called a string has no text");
  far.bits = (object.bits & ~(7ULL << 45)) | (3ULL << 45);
  CHECK(zjs_array_length(far) == 0, "nor, called an array, a length");
  CHECK(zjs_is_object(zjs_root_get(ctx, kept)), "the real one is unharmed");
  zjs_unroot(ctx, kept);
}

/* Many strings read, with collections between: each read gives that
   string's text, though handles of dead strings are given out again. */
static void many_strings(ZjsContext *ctx) {
  char source[64], expected[64];
  int wrong = 0;
  for (int round = 0; round < 6; round++) {
    for (int i = 0; i < 400; i++) {
      snprintf(source, sizeof source, "'s' + (%d * 1000 + %d) + '\u00e9'", round, i);
      snprintf(expected, sizeof expected, "s%d\xC3\xA9", round * 1000 + i);
      if (!text_says(zjs_eval(ctx, source), expected)) wrong++;
    }
    churn(ctx);
  }
  CHECK(wrong == 0, "every string read back as itself");
}

static void two_contexts(ZjsContext *a) {
  ZjsContext *b = zjs_new_context();
  ZjsValue from_b = zjs_eval(b, "'from b'");
  ZjsValue array_b = zjs_eval(b, "[1, 2]");
  uint32_t kept_b = zjs_root(b, array_b);
  CHECK(text_says(from_b, "from b") && zjs_array_length(array_b) == 2, "a value knows its context");
  /* Another context does not take it. */
  uint32_t root = zjs_root(a, from_b);
  CHECK(zjs_is_undefined(zjs_root_get(a, root)), "a context refuses another's cell");
  zjs_unroot(a, root);
  root = zjs_root(a, zjs_int32(9));
  CHECK(zjs_as_int32(zjs_root_get(a, root)) == 9, "but numbers belong to none");
  zjs_unroot(a, root);
  zjs_unroot(b, kept_b);
  zjs_free_context(b);
  CHECK(zjs_string_bytes(from_b, NULL) == NULL && zjs_array_length(array_b) == 0, "a freed context's values answer nothing");
  CHECK(zjs_is_undefined(zjs_eval(b, "1")) && zjs_is_undefined(zjs_new_string(b, "x", 1)) && zjs_root(b, zjs_int32(1)) == 0, "nor does the freed context");

  CHECK(zjs_is_undefined(zjs_eval(NULL, "1")) && zjs_is_undefined(zjs_get_error(NULL)), "no context at all");
  CHECK(zjs_is_undefined(zjs_new_string(NULL, "x", 1)) && zjs_is_undefined(zjs_new_object(NULL)) && zjs_is_undefined(zjs_new_array(NULL, 1)), "makes nothing");
  CHECK(zjs_root(NULL, zjs_int32(1)) == 0 && zjs_is_undefined(zjs_root_get(NULL, 1)), "and keeps nothing");
  zjs_pin(NULL, zjs_int32(1));
  zjs_unpin(NULL);

  /* A core context has the same values. */
  ZjsContext *core = zjs_new_core_context();
  CHECK(zjs_as_int32(zjs_eval(core, "20 + 22")) == 42 && text_says(zjs_eval(core, "'core'"), "core"), "a core context's results");
  zjs_free_context(core);
}

/* Eleven bits of a cell name its context's slot, so the cells of a
   context in a slot past the 2,047th name none. A context within the
   limit still refuses them, and the far one still takes its own. */
static void past_the_slot_limit(ZjsContext *a) {
  enum { MORE = 2048 };
  static ZjsContext *made[MORE];
  for (int i = 0; i < MORE; i++) made[i] = zjs_new_core_context();
  ZjsContext *far = made[MORE - 1];
  CHECK(far != NULL, "a context past the 2,047th slot");
  ZjsValue theirs = zjs_eval(far, "({ tag: 7 })");
  uint32_t kept = zjs_root(far, theirs);
  CHECK(zjs_is_object(theirs) && zjs_as_int32(zjs_get_property(far, theirs, "tag")) == 7, "takes its own cells");
  uint32_t root = zjs_root(a, theirs);
  CHECK(zjs_is_undefined(zjs_root_get(a, root)), "a context within the limit refuses them");
  zjs_unroot(a, root);
  root = zjs_root(far, zjs_eval(a, "({ tag: 8 })"));
  CHECK(zjs_is_undefined(zjs_root_get(far, root)), "as the far one refuses its");
  zjs_unroot(far, root);
  CHECK(zjs_string_bytes(zjs_eval(far, "'far'"), NULL) == NULL, "a far string has no text for the call that is given no context");
  zjs_unroot(far, kept);
  for (int i = 0; i < MORE; i++) zjs_free_context(made[i]);
}

int main(void) {
  immediates();
  ZjsContext *ctx = zjs_new_context();
  CHECK(ctx != NULL, "a context");
  results(ctx);
  made_here(ctx);
  kept(ctx);
  strangers(ctx);
  many_strings(ctx);
  two_contexts(ctx);
  past_the_slot_limit(ctx);
  zjs_free_context(ctx);
  printf(failures ? "abi values: %d FAILURES\n" : "abi values: ok (%d failures)\n", failures);
  return failures ? 1 : 0;
}
