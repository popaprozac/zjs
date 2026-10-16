/* A core context (no optional builtins), running source. */
#include "zjs.h"

int main(void) {
  ZjsContext *ctx = zjs_new_core_context();
  zjs_eval(ctx, "var x = 1 + 2;");
  int failed = zjs_had_error(ctx);
  zjs_free_context(ctx);
  return failed;
}
