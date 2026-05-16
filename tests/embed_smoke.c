/* Pure-C embed smoke test for the NaN-boxed value API.
 *
 * Validates that the C-ABI surface declared in include/zjs.h faithfully
 * round-trips every immediate value kind, including edge cases (INT_MIN,
 * INT_MAX, ±0.0, NaN, infinity, subnormals). If this passes, the binary
 * layout of ZjsValue matches the documented JSC NaN-box convention and
 * any host that talks to zjs through the header gets correct values.
 */

#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zjs.h"

/* -----------------------------------------------------------------------
 * Tiny test harness — no deps.
 * --------------------------------------------------------------------- */

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(cond, fmt, ...)                                                  \
    do {                                                                       \
        if (cond) {                                                            \
            g_pass++;                                                          \
        } else {                                                               \
            g_fail++;                                                          \
            fprintf(stderr, "[FAIL] %s:%d  " fmt "\n",                         \
                    __FILE__, __LINE__, ##__VA_ARGS__);                        \
        }                                                                     \
    } while (0)

/* -----------------------------------------------------------------------
 * Layout sanity.
 * --------------------------------------------------------------------- */

static void test_layout(void) {
    CHECK(sizeof(ZjsValue) == 8, "ZjsValue is %zu bytes, expected 8",
          sizeof(ZjsValue));

    /* Singletons must match the documented constants byte-for-byte. */
    CHECK(zjs_null().bits      == 0x0000000000000002ull, "null bits");
    CHECK(zjs_undefined().bits == 0x000000000000000aull, "undefined bits");
    CHECK(zjs_bool(0).bits     == 0x0000000000000006ull, "false bits");
    CHECK(zjs_bool(1).bits     == 0x0000000000000007ull, "true bits");
    CHECK(zjs_bool(42).bits    == 0x0000000000000007ull, "true bits (nonzero)");
}

/* -----------------------------------------------------------------------
 * Int32 roundtrip — including signed-range edges.
 * --------------------------------------------------------------------- */

static void test_int32(void) {
    int32_t cases[] = {
        0, 1, -1, 2, -2, 42, -42, 1234567, -1234567,
        INT32_MAX, INT32_MIN, INT32_MAX - 1, INT32_MIN + 1,
    };
    size_t n = sizeof(cases) / sizeof(cases[0]);
    for (size_t i = 0; i < n; i++) {
        int32_t want = cases[i];
        ZjsValue v = zjs_int32(want);
        CHECK(zjs_is_int32(v),     "int32(%d) not int32", want);
        CHECK(zjs_is_number(v),    "int32(%d) not number", want);
        CHECK(!zjs_is_double(v),   "int32(%d) reported as double", want);
        CHECK(!zjs_is_bool(v),     "int32(%d) reported as bool", want);
        CHECK(!zjs_is_null(v),     "int32(%d) reported as null", want);
        CHECK(!zjs_is_undefined(v),"int32(%d) reported as undefined", want);
        CHECK(!zjs_is_cell(v),     "int32(%d) reported as cell", want);

        int32_t got = zjs_as_int32(v);
        CHECK(got == want, "int32 roundtrip: want=%d got=%d", want, got);

        /* Bit-level: top 32 bits must be NumberTag's top 32. */
        CHECK((v.bits >> 32) == 0xfffe0000u,
              "int32(%d) bits=0x%016llx has wrong high tag",
              want, (unsigned long long)v.bits);
    }
}

/* -----------------------------------------------------------------------
 * Double roundtrip — including all the weird floating-point edges.
 * --------------------------------------------------------------------- */

static int doubles_equal(double a, double b) {
    /* Bit-equal — distinguishes +0.0 from -0.0, accepts NaN==NaN if
     * the bit patterns match. */
    uint64_t ua, ub;
    memcpy(&ua, &a, sizeof(ua));
    memcpy(&ub, &b, sizeof(ub));
    return ua == ub;
}

static void test_double(void) {
    double cases[] = {
        0.0, -0.0, 1.0, -1.0, 1.5, -1.5, 3.141592653589793,
        DBL_MIN, DBL_MAX, -DBL_MAX,
        DBL_EPSILON, DBL_MIN / 2.0,  /* subnormal */
        INFINITY, -INFINITY,
        NAN,
    };
    size_t n = sizeof(cases) / sizeof(cases[0]);
    for (size_t i = 0; i < n; i++) {
        double want = cases[i];
        ZjsValue v = zjs_double(want);
        CHECK(zjs_is_double(v),    "double(%g) not double", want);
        CHECK(zjs_is_number(v),    "double(%g) not number", want);
        CHECK(!zjs_is_int32(v),    "double(%g) reported as int32", want);
        CHECK(!zjs_is_bool(v),     "double(%g) reported as bool", want);
        CHECK(!zjs_is_null(v),     "double(%g) reported as null", want);
        CHECK(!zjs_is_undefined(v),"double(%g) reported as undefined", want);
        CHECK(!zjs_is_cell(v),     "double(%g) reported as cell", want);

        double got = zjs_as_double(v);
        CHECK(doubles_equal(got, want),
              "double roundtrip: want=%g got=%g", want, got);
    }
}

/* -----------------------------------------------------------------------
 * Singletons (null, undefined, true, false).
 * --------------------------------------------------------------------- */

static void test_singletons(void) {
    ZjsValue n = zjs_null();
    CHECK(zjs_is_null(n),       "null not null");
    CHECK(!zjs_is_undefined(n), "null reported as undefined");
    CHECK(!zjs_is_bool(n),      "null reported as bool");
    CHECK(!zjs_is_number(n),    "null reported as number");
    CHECK(!zjs_is_cell(n),      "null reported as cell");

    ZjsValue u = zjs_undefined();
    CHECK(zjs_is_undefined(u),  "undefined not undefined");
    CHECK(!zjs_is_null(u),      "undefined reported as null");
    CHECK(!zjs_is_bool(u),      "undefined reported as bool");
    CHECK(!zjs_is_number(u),    "undefined reported as number");
    CHECK(!zjs_is_cell(u),      "undefined reported as cell");

    ZjsValue t = zjs_bool(1);
    CHECK(zjs_is_bool(t),       "true not bool");
    CHECK(zjs_as_bool(t) == 1,  "true unboxes to %d", zjs_as_bool(t));
    CHECK(!zjs_is_int32(t),     "true reported as int32");

    ZjsValue f = zjs_bool(0);
    CHECK(zjs_is_bool(f),       "false not bool");
    CHECK(zjs_as_bool(f) == 0,  "false unboxes to %d", zjs_as_bool(f));
}

/* -----------------------------------------------------------------------
 * Mutual exclusion — every value is exactly one kind.
 * --------------------------------------------------------------------- */

static int kind_count(ZjsValue v) {
    return (zjs_is_int32(v)     ? 1 : 0)
         + (zjs_is_double(v)    ? 1 : 0)
         + (zjs_is_bool(v)      ? 1 : 0)
         + (zjs_is_null(v)      ? 1 : 0)
         + (zjs_is_undefined(v) ? 1 : 0)
         + (zjs_is_cell(v)      ? 1 : 0);
}

static void test_mutual_exclusion(void) {
    ZjsValue samples[] = {
        zjs_int32(0),    zjs_int32(INT32_MAX),  zjs_int32(INT32_MIN),
        zjs_double(0.0), zjs_double(NAN),       zjs_double(INFINITY),
        zjs_bool(0),     zjs_bool(1),
        zjs_null(),      zjs_undefined(),
    };
    size_t n = sizeof(samples) / sizeof(samples[0]);
    for (size_t i = 0; i < n; i++) {
        int k = kind_count(samples[i]);
        CHECK(k == 1,
              "sample %zu has %d kinds (bits=0x%016llx)",
              i, k, (unsigned long long)samples[i].bits);
        /* is_number must be exactly is_int32 || is_double. */
        int composite = zjs_is_int32(samples[i]) || zjs_is_double(samples[i]);
        CHECK(zjs_is_number(samples[i]) == composite,
              "is_number disagrees with int32||double for sample %zu", i);
    }
}

/* -----------------------------------------------------------------------
 * End-to-end through the engine — the original Phase 0 smoke check,
 * but now exercising the real value path.
 * --------------------------------------------------------------------- */

static void test_engine_path(void) {
    printf("[smoke] zjs version: %s\n", zjs_version());

    ZjsContext* ctx = zjs_new_context();
    CHECK(ctx != NULL, "zjs_new_context returned NULL");
    if (!ctx) return;

    /* Now that Phase 3.0a is live, zjs_eval actually evaluates. */
    struct {
        const char* source;
        int expected;
    } cases[] = {
        { "1 + 1",                                                              2 },
        { "1 + 2 * 3",                                                          7 },
        { "(1 + 2) * 3",                                                        9 },
        { "10 - 4 - 3",                                                         3 },
        { "2 ** 8",                                                           256 },
        { "100 / 4",                                                           25 },
        { "10 % 3",                                                             1 },
        { "-5 + 10",                                                            5 },
        { "!0",                                                                 1 },
        { "!1",                                                                 0 },
        { "1 < 2",                                                              1 },
        { "2 < 1",                                                              0 },
        { "3 === 3",                                                            1 },
        { "3 === 4",                                                            0 },
        { "1 & 3",                                                              1 },
        { "1 | 2",                                                              3 },
        { "5 ^ 3",                                                              6 },
        { "1 << 4",                                                            16 },
        { "16 >> 2",                                                            4 },
        { "let a = 5; let b = 7; a + b",                                       12 },
        { "let x = 1; x = x + 41; x",                                          42 },
        { "let x = 10; x += 5; x",                                             15 },
        { "if (1) 7; else 99",                                                  7 },
        { "if (0) 7; else 99",                                                 99 },
        { "let s = 0; let i = 1; while (i <= 10) { s = s + i; i = i + 1; } s",55 },
        { "let s = 0; for (let i = 1; i <= 10; i = i + 1) s = s + i; s",      55 },
        { "let n = 0; do { n = n + 1; } while (n < 5); n",                      5 },

        /* Functions (Phase 3.0b) */
        { "function f() { return 42; } f()",                                   42 },
        { "function add(a, b) { return a + b; } add(3, 4)",                     7 },
        { "function fact(n) { if (n <= 1) return 1; return n * fact(n - 1); } fact(5)", 120 },
        { "function fib(n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); } fib(10)", 55 },
        { "let inc = x => x + 1; inc(41)",                                     42 },
        { "let f = function(x) { return x * 2; }; f(21)",                      42 },
        { "function sum(n) { let s = 0; for (let i = 1; i <= n; i = i + 1) s = s + i; return s; } sum(100)", 5050 },
    };
    size_t n = sizeof(cases) / sizeof(cases[0]);
    for (size_t i = 0; i < n; i++) {
        ZjsValue v = zjs_eval(ctx, cases[i].source);
        int got = zjs_is_int32(v) ? zjs_as_int32(v) :
                  zjs_is_double(v) ? (int)zjs_as_double(v) :
                  zjs_is_bool(v) ? zjs_as_bool(v) : -1;
        if (got != cases[i].expected) {
            g_fail++;
            fprintf(stderr, "[eval FAIL] %-60s expected %d, got %d\n",
                    cases[i].source, cases[i].expected, got);
        } else {
            g_pass++;
        }
    }

    zjs_free_context(ctx);
}

/* -----------------------------------------------------------------------
 * Phase 3.1c — uncaught-throw detection through the public C ABI.
 * --------------------------------------------------------------------- */

/* -----------------------------------------------------------------------
 * Phase 3.1d — mark-sweep GC. Verify cells get freed.
 * --------------------------------------------------------------------- */

/* -----------------------------------------------------------------------
 * Phase 3.1f — atom interning. Property names + string literals should
 * dedupe across evaluations, measurably reducing cell allocations.
 * --------------------------------------------------------------------- */

static void test_atom_interning(void) {
    ZjsContext* ctx = zjs_new_context();

    /* Baseline after first object literal — installs atoms "foo", "bar". */
    zjs_eval(ctx, "var o1 = {foo: 1, bar: 2}");
    unsigned after_first = zjs_cell_count(ctx);

    /* Second object literal with the same property names. Without atom
     * interning each name would have allocated a fresh string; with
     * interning the names hit the table. Only the new object cell + 2
     * value temporaries grow the heap. */
    zjs_eval(ctx, "var o2 = {foo: 3, bar: 4}");
    unsigned after_second = zjs_cell_count(ctx);
    unsigned grew = after_second - after_first;

    /* The exact delta depends on Function constants pool, etc., but it
     * should be small — definitely smaller than allocating two fresh
     * "foo" + "bar" strings (which used to be 4 cells minimum). */
    CHECK(grew <= 3, "second {foo,bar} literal should reuse atoms (grew=%u)", grew);

    /* Property access still works after GC (atoms are pinned). */
    zjs_gc(ctx);
    ZjsValue f1 = zjs_eval(ctx, "o1.foo");
    ZjsValue f2 = zjs_eval(ctx, "o2.foo");
    CHECK(zjs_is_int32(f1) && zjs_as_int32(f1) == 1, "o1.foo readable post-GC");
    CHECK(zjs_is_int32(f2) && zjs_as_int32(f2) == 3, "o2.foo readable post-GC");

    /* String literals also intern: the same source-level "shared"
     * appearing across two evals lands on the same ZjsString*. We can
     * observe this indirectly — `s1 === s2` is content-equality, but
     * the cell count between the two evals shouldn't grow by a string. */
    zjs_eval(ctx, "var s1 = 'shared'");
    unsigned a = zjs_cell_count(ctx);
    zjs_eval(ctx, "var s2 = 'shared'");
    unsigned b = zjs_cell_count(ctx);
    CHECK(b - a <= 1, "second 'shared' literal should hit the atom table (grew=%u)", b - a);

    /* And `===` between them returns true via the pointer fast path. */
    ZjsValue eq = zjs_eval(ctx, "s1 === s2");
    CHECK(zjs_is_bool(eq) && zjs_as_bool(eq) == 1, "atom-equal strings are ===");

    zjs_free_context(ctx);
}

/* -----------------------------------------------------------------------
 * Phase 3.2a — hidden classes. Two objects with the same property-add
 * sequence should share their HiddenClass (observable: second object
 * adds fewer cells because the classes were already created).
 * --------------------------------------------------------------------- */

static void test_hidden_class_sharing(void) {
    ZjsContext* ctx = zjs_new_context();

    unsigned before_first = zjs_cell_count(ctx);
    zjs_eval(ctx, "var p1 = {x: 1, y: 2}");
    unsigned after_first = zjs_cell_count(ctx);

    zjs_eval(ctx, "var p2 = {x: 3, y: 4}");
    unsigned after_second = zjs_cell_count(ctx);

    unsigned first_delta  = after_first  - before_first;
    unsigned second_delta = after_second - after_first;

    /* The first {x,y} allocates: a Function for the program, atoms
     * "p1"/"x"/"y", the object itself, and two HiddenClass cells
     * (after-x, after-x-y).
     *
     * The second {x,y} allocates: a Function for the program, the
     * "p2" atom, the object itself. The two hidden classes are
     * reused.
     *
     * So the second delta should be strictly less than the first. */
    CHECK(second_delta < first_delta,
          "shape-shared second object adds fewer cells (first=%u, second=%u)",
          first_delta, second_delta);

    /* Properties are still correctly readable on both. */
    ZjsValue v1 = zjs_eval(ctx, "p1.x + p1.y");
    ZjsValue v2 = zjs_eval(ctx, "p2.x + p2.y");
    CHECK(zjs_is_int32(v1) && zjs_as_int32(v1) == 3, "p1.x+p1.y == 3");
    CHECK(zjs_is_int32(v2) && zjs_as_int32(v2) == 7, "p2.x+p2.y == 7");

    /* Reassignment doesn't churn classes (existing slot, just writes value). */
    zjs_eval(ctx, "p1.x = 100");
    ZjsValue v3 = zjs_eval(ctx, "p1.x");
    CHECK(zjs_is_int32(v3) && zjs_as_int32(v3) == 100, "p1.x updated to 100");

    /* GC keeps the shared class alive while objects reference it. */
    zjs_gc(ctx);
    ZjsValue v4 = zjs_eval(ctx, "p2.y");
    CHECK(zjs_is_int32(v4) && zjs_as_int32(v4) == 4, "p2.y still 4 after GC");

    zjs_free_context(ctx);
}

/* -----------------------------------------------------------------------
 * Phase 3.2b — inline caches. Behavioral checks only (perf is not
 * directly observable from C without timing). We verify that:
 *   - hot loops over a same-shape property work
 *   - bouncing between two shapes through the same site still works
 *     (cache thrashes but stays correct)
 *   - GC keeps cached classes alive
 * --------------------------------------------------------------------- */

static void test_inline_caches(void) {
    ZjsContext* ctx = zjs_new_context();

    /* Hot loop: thousands of accesses through the same `p.x` site.
     * After the first iteration the IC is warm and every subsequent
     * access takes the fast path. Result is the sum 1..1000. */
    ZjsValue sum = zjs_eval(ctx,
        "let p = {x: 0}; "
        "for (let i = 1; i <= 1000; i = i + 1) p.x = p.x + i; "
        "p.x");
    CHECK(zjs_is_int32(sum) && zjs_as_int32(sum) == 500500,
          "hot-loop property sum 1..1000 == 500500");

    /* Polymorphic site — same source line `p.v` seeing two different
     * shapes. Each miss patches the cache; we just want correctness. */
    ZjsValue poly = zjs_eval(ctx,
        "function read(p) { return p.v } "
        "let a = {v: 7}; "
        "let b = {q: 1, v: 11}; "          /* different shape than `a` */
        "read(a) + read(b) + read(a) + read(b)");
    CHECK(zjs_is_int32(poly) && zjs_as_int32(poly) == 36,
          "polymorphic site stays correct under shape bounce (got %d)",
          zjs_as_int32(poly));

    /* StoreProp IC path on existing property — repeated writes through
     * the same site warm the cache and exercise the fast write path. */
    ZjsValue stored = zjs_eval(ctx,
        "let o = {n: 0}; "
        "function bump() { o.n = o.n + 1 } "
        "for (let i = 0; i < 100; i = i + 1) bump(); "
        "o.n");
    CHECK(zjs_is_int32(stored) && zjs_as_int32(stored) == 100,
          "store-prop hot loop reaches 100");

    /* New-property path through a StoreProp site. First write
     * transitions the class; subsequent writes (same shape) hit the
     * IC fast path. */
    ZjsValue trans = zjs_eval(ctx,
        "let a = {}; let b = {}; let c = {}; "
        "function mark(o) { o.tag = 'set' } "
        "mark(a); mark(b); mark(c); "
        "a.tag + b.tag + c.tag");
    CHECK(zjs_is_string(trans), "store-prop transition path produces strings");

    /* GC across an IC. After GC, the cached class must still be
     * reachable through the function's IC table — so the next access
     * either hits the cache or repopulates it correctly. */
    zjs_eval(ctx, "var q = {a: 1, b: 2}; q.a; q.b");
    zjs_gc(ctx);
    ZjsValue after = zjs_eval(ctx, "q.a + q.b");
    CHECK(zjs_is_int32(after) && zjs_as_int32(after) == 3, "IC survives GC");

    zjs_free_context(ctx);
}

static void test_gc(void) {
    ZjsContext* ctx = zjs_new_context();
    unsigned baseline = zjs_cell_count(ctx);

    /* Each iteration creates a fresh string that becomes unreachable
     * once the next loop body assigns to s. After enough iterations
     * the cell count should rise above baseline. */
    for (int i = 0; i < 200; i++) {
        zjs_eval(ctx, "var s = 'iter' + 99");
    }
    unsigned grown = zjs_cell_count(ctx);
    CHECK(grown > baseline, "cells should accumulate (baseline=%u, grown=%u)",
          baseline, grown);

    /* Force a collection — most of the per-iteration garbage should drop. */
    zjs_gc(ctx);
    unsigned after = zjs_cell_count(ctx);
    CHECK(after < grown, "gc should free unreachable cells (grown=%u, after=%u)",
          grown, after);
    CHECK(after <= baseline + 16,
          "gc should drop back close to baseline (baseline=%u, after=%u)",
          baseline, after);

    /* Liveness: values held via globals survive collection. The most
     * direct test is to allocate something, GC, then read it back. */
    zjs_eval(ctx, "var keep = []; for (let i = 0; i < 20; i = i + 1) keep[i] = 'item' + i");
    zjs_gc(ctx);
    ZjsValue len = zjs_eval(ctx, "keep.length");
    CHECK(zjs_is_int32(len) && zjs_as_int32(len) == 20,
          "live array's length survives GC");
    ZjsValue first = zjs_eval(ctx, "keep[0]");
    CHECK(zjs_is_string(first), "live array's elements still readable post-GC");

    /* A nested reachable graph: { x: { y: 'deep' } } via global. GC,
     * then reach in. */
    zjs_eval(ctx, "var nested = { x: { y: 'deep value' } }");
    zjs_gc(ctx);
    ZjsValue deep = zjs_eval(ctx, "nested.x.y");
    CHECK(zjs_is_string(deep), "deeply nested string survives GC");

    zjs_free_context(ctx);
}

static void test_throw_abi(void) {
    ZjsContext* ctx = zjs_new_context();

    /* Caught: had_error stays false. */
    ZjsValue r1 = zjs_eval(ctx, "try { throw 42 } catch (e) { e + 1 }");
    CHECK(!zjs_had_error(ctx), "caught throw should not flag had_error");
    CHECK(zjs_is_int32(r1) && zjs_as_int32(r1) == 43, "caught throw value chain");

    /* Uncaught: had_error becomes true, get_error returns the thrown value. */
    zjs_eval(ctx, "throw 99");
    CHECK(zjs_had_error(ctx), "uncaught throw should flag had_error");
    ZjsValue err = zjs_get_error(ctx);
    CHECK(zjs_is_int32(err) && zjs_as_int32(err) == 99, "thrown value readable");

    /* A subsequent successful eval clears had_error. */
    zjs_eval(ctx, "1 + 1");
    CHECK(!zjs_had_error(ctx), "had_error should clear after a clean eval");

    zjs_free_context(ctx);
}

/* -----------------------------------------------------------------------
 * Main.
 * --------------------------------------------------------------------- */

int main(void) {
    test_layout();
    test_int32();
    test_double();
    test_singletons();
    test_mutual_exclusion();
    test_engine_path();
    test_throw_abi();
    test_atom_interning();
    test_hidden_class_sharing();
    test_inline_caches();
    test_gc();

    printf("[smoke] %d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
