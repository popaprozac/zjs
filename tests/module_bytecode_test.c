/* ES modules from bytecode through the public ABI, on a core context:
   zjs_eval_module_bytecode runs a graph of module files (live bindings,
   top-level await, import(), import.meta), keeps each module evaluated
   once, and refuses a graph with a module left as source or one that
   cannot be found. build.sh compiles tests/module_bytecode/ into the
   directory given (plain.mjs stays source), and checks that this binary
   links no compiler. */
#include <stdio.h>

#include "zjs.h"

static int failures = 0;

static void fail(const char *what) {
  fprintf(stderr, "module bytecode: FAIL %s\n", what);
  failures += 1;
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: module_bytecode_test <directory>\n");
    return 2;
  }
  char path[2048];
  ZjsContext *ctx = zjs_new_core_context();

  snprintf(path, sizeof path, "%s/main.mjs", argv[1]);
  zjs_eval_module_bytecode(ctx, path);
  if (zjs_had_error(ctx)) fail("main.mjs threw");
  /* Evaluated once: main throws if it runs again. */
  zjs_eval_module_bytecode(ctx, path);
  if (zjs_had_error(ctx)) fail("main.mjs ran again");

  snprintf(path, sizeof path, "%s/source-import.mjs", argv[1]);
  zjs_eval_module_bytecode(ctx, path);
  if (!zjs_had_error(ctx)) fail("a module left as source compiled without a compiler");

  snprintf(path, sizeof path, "%s/missing.mjs", argv[1]);
  zjs_eval_module_bytecode(ctx, path);
  if (!zjs_had_error(ctx)) fail("a missing import was not an error");

  zjs_free_context(ctx);
  if (failures != 0) return 1;
  printf("module bytecode: ok\n");
  return 0;
}
