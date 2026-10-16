/* Bytecode through the public ABI (zjs.h): source compiled to a buffer in
   one context runs in another, compiling runs nothing, a program that
   throws reports it, and a buffer the engine refuses runs nothing. Each
   check evaluates a script that throws when its expectation fails. */
#include <stdio.h>
#include <stdlib.h>

#include "zjs.h"

static int failures = 0;

static void fail(const char *what) {
  fprintf(stderr, "bytecode: FAIL %s\n", what);
  failures += 1;
}

int main(void) {
  ZjsContext *compiling = zjs_new_context();
  ZjsContext *running = zjs_new_context();

  size_t length = 0;
  unsigned char *program = zjs_compile_to_bytecode(compiling,
    "var r = 0; function add(a, b) { return a + b; }"
    "for (var i = 0; i < 4; i++) r = add(r, i);"
    "if (r !== 6) throw new Error('wrong sum');", &length);
  if (program == NULL || length == 0) fail("compile");
  if (zjs_had_error(compiling)) fail("compile reported an error");
  /* The script never ran where it compiled, so it defined nothing. */
  zjs_eval(compiling, "if (typeof r !== 'undefined' || typeof add !== 'undefined') throw new Error('defined');");
  if (zjs_had_error(compiling)) fail("compiling defined the script's globals");

  zjs_eval_bytecode(running, program, length);
  if (zjs_had_error(running)) fail("the loaded program threw");
  zjs_eval(running, "if (r !== 6 || typeof add !== 'function' || add(2, 3) !== 5) throw new Error('globals');");
  if (zjs_had_error(running)) fail("the loaded program's globals");

  size_t throwsLength = 0;
  unsigned char *throws = zjs_compile_to_bytecode(compiling, "throw new TypeError('expected');", &throwsLength);
  zjs_eval_bytecode(running, throws, throwsLength);
  if (!zjs_had_error(running)) fail("a throw from bytecode was not reported");

  size_t markerLength = 0;
  unsigned char *marker = zjs_compile_to_bytecode(compiling, "var marker = 1;", &markerLength);
  marker[markerLength - 1] ^= 0x5A;
  zjs_eval_bytecode(running, marker, markerLength);
  if (zjs_had_error(running)) fail("a damaged buffer reported an error");
  zjs_eval(running, "if (typeof marker !== 'undefined') throw new Error('ran');");
  if (zjs_had_error(running)) fail("a damaged buffer ran");

  size_t badLength = 99;
  unsigned char *bad = zjs_compile_to_bytecode(compiling, "var = ;", &badLength);
  if (bad != NULL || badLength != 0) fail("a parse error compiled");
  if (!zjs_had_error(compiling)) fail("a parse error was not an error");

  free(program);
  free(throws);
  free(marker);
  zjs_free_context(compiling);
  zjs_free_context(running);
  if (failures > 0) return 1;
  printf("bytecode: ok\n");
  return 0;
}
