/*
 * QuickJS libregexp / libunicode runtime callbacks.
 *
 * Three hooks the library requires the host to provide:
 *   - lre_realloc        : malloc / realloc / free behind one signature
 *   - lre_check_stack_overflow : called during recursive compile/match
 *   - lre_check_timeout  : called inside the exec inner loop
 *
 * The library's TEST harness defines stub versions of these inside
 * libregexp.c under #ifdef TEST. Production builds (us) supply them
 * here instead.
 *
 * Also re-exports lre_check_timeout / lre_check_stack_overflow under
 * the names the linker expects. zjs has no preemption, no debug
 * timeouts, and no stack-budget knobs today — these are all trivial.
 * If we later want to bound long-running regexes, this is the spot
 * to plumb a flag in.
 */

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdbool.h>

void *lre_realloc(void *opaque, void *ptr, size_t size)
{
    (void)opaque;
    if (size == 0) {
        free(ptr);
        return NULL;
    }
    return realloc(ptr, size);
}

bool lre_check_stack_overflow(void *opaque, size_t alloca_size)
{
    (void)opaque;
    (void)alloca_size;
    /* No host-side stack budget enforced. Library has its own bytecode-level
     * recursion limits (CAPTURE_COUNT_MAX, BC_STACK_MAX); those guard the
     * actual blow-ups in practice. */
    return false;
}

int lre_check_timeout(void *opaque)
{
    (void)opaque;
    /* No interrupt mechanism wired today; never time out. */
    return 0;
}
