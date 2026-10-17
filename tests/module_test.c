/* ES modules through the public ABI (zjs.h): a module graph read from
   files, a module from memory importing those files, the cache that
   keeps each module evaluated once, and the errors a graph reports.
   Each check evaluates a script that throws when its expectation fails.
   The module files are written to the directory given as argv[1]. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zjs.h"

static int failures = 0;

static void fail(const char *what) {
  fprintf(stderr, "module: FAIL %s\n", what);
  failures += 1;
}

static char directory[1024];

static const char *path_of(const char *name) {
  static char path[2048];
  snprintf(path, sizeof path, "%s/%s", directory, name);
  return path;
}

static void write_file(const char *name, const char *text) {
  FILE *file = fopen(path_of(name), "w");
  if (file == NULL) {
    fail("writing a module file");
    return;
  }
  fputs(text, file);
  fclose(file);
}

static void check(ZjsContext *ctx, const char *script, const char *what) {
  zjs_eval(ctx, script);
  if (zjs_had_error(ctx)) fail(what);
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: module_test <directory>\n");
    return 2;
  }
  snprintf(directory, sizeof directory, "%s", argv[1]);
  write_file("counter.mjs",
    "export let count = 1;\n"
    "export function bump() { count = count + 1; }\n"
    "globalThis.counterRuns = (globalThis.counterRuns || 0) + 1;\n");
  write_file("main.mjs",
    "import { count, bump } from './counter.mjs';\n"
    "import * as counter from './sub/../counter.mjs';\n"
    "bump();\n"
    "globalThis.seen = [count, counter.count];\n"
    "globalThis.mainRuns = (globalThis.mainRuns || 0) + 1;\n");
  write_file("missing.mjs", "import { x } from './nowhere.mjs';\nglobalThis.missingRan = true;\n");
  write_file("unexported.mjs", "import { nothing } from './counter.mjs';\nglobalThis.unexportedRan = true;\n");
  write_file("throws.mjs", "globalThis.throwsRuns = (globalThis.throwsRuns || 0) + 1;\nthrow new RangeError('expected');\n");

  ZjsContext *ctx = zjs_new_context();
  zjs_eval_module(ctx, path_of("main.mjs"));
  if (zjs_had_error(ctx)) fail("main.mjs threw");
  check(ctx, "if (seen[0] !== 2 || seen[1] !== 2 || counterRuns !== 1) throw new Error('graph');", "the graph's live bindings");

  /* Evaluated once: a second call, by another spelling of the path, runs nothing. */
  char again[2048];
  snprintf(again, sizeof again, "%s/./main.mjs", directory);
  zjs_eval_module(ctx, again);
  if (zjs_had_error(ctx)) fail("main.mjs again threw");
  check(ctx, "if (mainRuns !== 1 || counterRuns !== 1) throw new Error('ran twice');", "the cache");

  /* A module from memory imports the same counter. */
  const char *source = "import { count, bump } from './counter.mjs';\nbump();\nglobalThis.fromMemory = count;\n";
  char virtual_path[2048];
  snprintf(virtual_path, sizeof virtual_path, "%s/virtual.mjs", directory);
  zjs_eval_module_source(ctx, source, strlen(source), virtual_path);
  if (zjs_had_error(ctx)) fail("the module from memory threw");
  check(ctx, "if (fromMemory !== 3 || counterRuns !== 1) throw new Error('memory');", "a module from memory");

  /* A graph that cannot load or link runs nothing. */
  zjs_eval_module(ctx, path_of("missing.mjs"));
  if (!zjs_had_error(ctx)) fail("a missing import was not an error");
  zjs_eval_module(ctx, path_of("unexported.mjs"));
  if (!zjs_had_error(ctx)) fail("an import nothing exports was not an error");
  check(ctx, "if (typeof missingRan !== 'undefined' || typeof unexportedRan !== 'undefined') throw new Error('ran');", "a graph that failed to link ran");

  /* A module that throws fails, and throws again without running again. */
  zjs_eval_module(ctx, path_of("throws.mjs"));
  if (!zjs_had_error(ctx)) fail("a throw was not reported");
  zjs_eval_module(ctx, path_of("throws.mjs"));
  if (!zjs_had_error(ctx)) fail("a failed module did not throw again");
  check(ctx, "if (throwsRuns !== 1) throw new Error('reran');", "a failed module ran again");

  const char *broken = "export let = 1;";
  zjs_eval_module_source(ctx, broken, strlen(broken), "/virtual/broken.mjs");
  if (!zjs_had_error(ctx)) fail("a parse error was not an error");

  zjs_free_context(ctx);
  if (failures != 0) return 1;
  printf("module: ok\n");
  return 0;
}
