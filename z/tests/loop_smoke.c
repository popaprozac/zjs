/* Phase 1 smoke: proves state really crosses the frozen ABI into Z-owned
 * storage and back -- not merely that the program links. */
#include <stdio.h>
#include <stdint.h>
#include "zjs.h"
#include "zjsz.h"

int main(void) {
    int failures = 0;
    ZjsContext *a = zjs_new_context();
    ZjsContext *b = zjs_new_context();

    if (a == NULL || b == NULL)  { printf("FAIL: null context\n"); failures++; }
    if (a == b)                  { printf("FAIL: handles not distinct\n"); failures++; }
    if (zjs_had_error(a) != 0)   { printf("FAIL: fresh context has error\n"); failures++; }

    zjs_eval(a, "1 + 1");
    zjs_eval(a, "2 + 2");
    zjs_eval(b, "3 + 3");

    /* Programs evaluate now: no error, and the completion value is the
     * NaN-boxed int32 result (NUMBER_TAG | value). */
    if (zjs_had_error(a) != 0)   { printf("FAIL: eval reported an error\n"); failures++; }
    if (zjs_z_last_result_bits((uintptr_t)a) != (0xFFFE000000000000ULL | 4)) {
        printf("FAIL: context a result bits %llx\n", (unsigned long long)zjs_z_last_result_bits((uintptr_t)a)); failures++;
    }
    if (zjs_z_last_result_bits((uintptr_t)b) != (0xFFFE000000000000ULL | 6)) {
        printf("FAIL: context b result bits %llx\n", (unsigned long long)zjs_z_last_result_bits((uintptr_t)b)); failures++;
    }
    /* An undeclared name is an uncaught throw. */
    zjs_eval(b, "nope");
    if (zjs_had_error(b) != 1)   { printf("FAIL: reference error not reported\n"); failures++; }
    zjs_eval(b, "3 + 3");

    /* Per-context state must be independent, and must have survived the
     * round trip through the Z-owned registry. */
    uint64_t ca = zjs_z_eval_count((uintptr_t)a);
    uint64_t cb = zjs_z_eval_count((uintptr_t)b);
    if (ca != 2) { printf("FAIL: context a eval count %llu, want 2\n", (unsigned long long)ca); failures++; }
    if (cb != 3) { printf("FAIL: context b eval count %llu, want 3\n", (unsigned long long)cb); failures++; }

    /* Each context owns a heap; numeric programs allocate no cells. */
    if (zjs_z_heap_cells((uintptr_t)a) != 0) { printf("FAIL: numeric eval allocated cells\n"); failures++; }

    zjs_free_context(a);
    zjs_free_context(b);

    printf(failures ? "loop smoke: %d FAILURES\n" : "loop smoke: ok (%d failures)\n", failures);
    return failures ? 1 : 0;
}
