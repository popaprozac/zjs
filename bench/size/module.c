/* A core context running a module graph of bytecode files: no source
   compiled, so no lexer, parser, or compiler linked, only the module
   linker and loader. The root's path is the argument. */
#include "zjs.h"

int main(int argc, char **argv) {
  ZjsContext *ctx = zjs_new_core_context();
  if (argc > 1) zjs_eval_module_bytecode(ctx, argv[1]);
  int failed = zjs_had_error(ctx);
  zjs_free_context(ctx);
  return failed;
}
