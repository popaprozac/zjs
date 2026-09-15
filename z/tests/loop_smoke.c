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

    /* Phase 1 evaluates nothing, so every program must report an error. */
    if (zjs_had_error(a) != 1)   { printf("FAIL: eval did not record error\n"); failures++; }

    /* Per-context state must be independent, and must have survived the
     * round trip through the Z-owned registry. */
    uint64_t ca = zjs_z_eval_count((uintptr_t)a);
    uint64_t cb = zjs_z_eval_count((uintptr_t)b);
    if (ca != 2) { printf("FAIL: context a eval count %llu, want 2\n", (unsigned long long)ca); failures++; }
    if (cb != 1) { printf("FAIL: context b eval count %llu, want 1\n", (unsigned long long)cb); failures++; }

    zjs_free_context(a);
    zjs_free_context(b);

    printf(failures ? "loop smoke: %d FAILURES\n" : "loop smoke: ok (%d failures)\n", failures);
    return failures ? 1 : 0;
}
