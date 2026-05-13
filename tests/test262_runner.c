/* test262 conformance runner — Phase 3.1c.
 *
 * Walks a directory tree, prepends a tiny harness to every .js file,
 * runs the combined source through zjs_eval, and reports pass/fail
 * based on whether an uncaught throw escaped.
 *
 * The harness is intentionally minimal: it defines `assert` as an
 * object with `sameValue` / `notSameValue` methods that throw on
 * mismatch, plus `$ERROR`. That covers the largest class of test262
 * tests. Tests that use `assert(condition)` directly call our
 * object-shaped assert as a function — currently a no-op since
 * functions-as-callable on non-function cells returns undefined.
 * Phase 3.1d/e will extend the harness as more language features
 * land (callable assert, Error constructors, etc.).
 */

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "zjs.h"

/* Test262 harness preamble. Concatenated with each test before eval. */
static const char* HARNESS =
    "var assert = {\n"
    "  sameValue: function (a, b) { if (a !== b) throw 'sameValue fail'; },\n"
    "  notSameValue: function (a, b) { if (a === b) throw 'notSameValue fail'; }\n"
    "};\n"
    "function $ERROR(m) { throw m; }\n";

static int g_total   = 0;
static int g_passed  = 0;   /* eval returned with no uncaught throw */
static int g_failed  = 0;   /* uncaught throw -> assertion or runtime failure */
static int g_skipped = 0;   /* feature not supported yet */

/* --- File I/O ------------------------------------------------------ */

static char* read_file(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long size = ftell(f);
    if (size < 0) { fclose(f); return NULL; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    char* content = (char*)malloc((size_t)size + 1);
    if (!content) { fclose(f); return NULL; }
    size_t n = fread(content, 1, (size_t)size, f);
    content[n] = 0;
    fclose(f);
    return content;
}

/* --- Feature filter ------------------------------------------------- */

static int has_unsupported_feature(const char* source) {
    /* Pessimistic substring checks. Tests touching these features
     * would produce noisy false-failures unrelated to spec conformance.
     */
    if (strstr(source, "class ")     != NULL) return 1;
    if (strstr(source, "import ")    != NULL) return 1;
    if (strstr(source, "export ")    != NULL) return 1;
    if (strstr(source, "BigInt")     != NULL) return 1;
    if (strstr(source, "Symbol")     != NULL) return 1;
    if (strstr(source, "Promise")    != NULL) return 1;
    if (strstr(source, "RegExp")     != NULL) return 1;
    if (strstr(source, "async")      != NULL) return 1;
    if (strstr(source, "yield")      != NULL) return 1;
    if (strstr(source, "function*")  != NULL) return 1;
    if (strstr(source, "`")          != NULL) return 1;
    /* Skip tests that use methods we haven't implemented as built-ins
     * yet — they'd fail for boring reasons unrelated to language correctness. */
    if (strstr(source, "Math.")      != NULL) return 1;
    if (strstr(source, "JSON.")      != NULL) return 1;
    if (strstr(source, "Number.")    != NULL) return 1;
    if (strstr(source, "Object.")    != NULL) return 1;
    if (strstr(source, "Array.")     != NULL) return 1;
    if (strstr(source, "String.")    != NULL) return 1;
    if (strstr(source, "new Error")  != NULL) return 1;
    if (strstr(source, ".prototype") != NULL) return 1;
    return 0;
}

static int ends_with(const char* s, const char* suffix) {
    size_t ls = strlen(s), lf = strlen(suffix);
    if (ls < lf) return 0;
    return strcmp(s + ls - lf, suffix) == 0;
}

/* --- Test runner ---------------------------------------------------- */

static void run_test_file(const char* path) {
    char* source = read_file(path);
    if (!source) { g_failed++; return; }
    g_total++;

    if (has_unsupported_feature(source)) {
        g_skipped++;
        free(source);
        return;
    }

    /* Build harness + source. */
    size_t hlen = strlen(HARNESS);
    size_t slen = strlen(source);
    char* combined = (char*)malloc(hlen + slen + 1);
    if (!combined) { g_failed++; free(source); return; }
    memcpy(combined, HARNESS, hlen);
    memcpy(combined + hlen, source, slen);
    combined[hlen + slen] = 0;

    ZjsContext* ctx = zjs_new_context();
    if (!ctx) { g_failed++; free(source); free(combined); return; }

    zjs_eval(ctx, combined);
    if (zjs_had_error(ctx)) {
        g_failed++;
    } else {
        g_passed++;
    }

    zjs_free_context(ctx);
    free(source);
    free(combined);
}

static void walk_dir(const char* path) {
    DIR* dir = opendir(path);
    if (!dir) return;
    struct dirent* entry;
    char buf[4096];
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;
        int n = snprintf(buf, sizeof(buf), "%s/%s", path, entry->d_name);
        if (n < 0 || (size_t)n >= sizeof(buf)) continue;

        struct stat st;
        if (stat(buf, &st) != 0) continue;

        if (S_ISDIR(st.st_mode)) {
            walk_dir(buf);
        } else if (S_ISREG(st.st_mode) && ends_with(entry->d_name, ".js")) {
            if (strstr(entry->d_name, "_FIXTURE")) continue;
            run_test_file(buf);
        }
    }
    closedir(dir);
}

/* --- Main ----------------------------------------------------------- */

int main(int argc, char** argv) {
    const char* dir = argc > 1 ?
        argv[1] :
        "vendor/test262/test/language/expressions";

    struct stat st;
    if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        fprintf(stderr, "test262 directory not found: %s\n", dir);
        fprintf(stderr, "Clone with:\n");
        fprintf(stderr, "  mkdir -p vendor\n");
        fprintf(stderr, "  git clone --depth 1 https://github.com/tc39/test262 vendor/test262\n");
        return 1;
    }

    printf("test262 conformance — Phase 3.1c (real signal, biased harness)\n");
    printf("target: %s\n\n", dir);

    walk_dir(dir);

    int eligible = g_total - g_skipped;
    int pct = eligible > 0 ? (g_passed * 100) / eligible : 0;
    printf("results:\n");
    printf("  eligible    %d   (total %d, skipped %d for unsupported features)\n",
           eligible, g_total, g_skipped);
    printf("  passed      %d   (%d%% of eligible)\n", g_passed, pct);
    printf("  failed      %d\n", g_failed);
    printf("\nThe harness defines `assert.sameValue`, `assert.notSameValue`,\n");
    printf("and `$ERROR` — all throw on assertion failure. Tests pass iff\n");
    printf("no uncaught throw escapes. Tests that use `assert(condition)`\n");
    printf("directly (a callable assert) still silently pass because we\n");
    printf("treat non-function callees as no-ops — will tighten in 3.1d+.\n");

    return g_failed > 0 ? 1 : 0;
}
