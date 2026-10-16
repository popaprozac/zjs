/* A core context running a bytecode file it was handed: no source
   compiled, so no lexer, parser, or compiler linked. The file is read
   from the path given; with none, an empty buffer (refused). */
#include <stdio.h>
#include <stdlib.h>

#include "zjs.h"

int main(int argc, char **argv) {
  unsigned char *data = NULL;
  size_t length = 0;
  if (argc > 1) {
    FILE *file = fopen(argv[1], "rb");
    if (file == NULL) return 2;
    fseek(file, 0, SEEK_END);
    length = (size_t)ftell(file);
    fseek(file, 0, SEEK_SET);
    data = malloc(length == 0 ? 1 : length);
    if (data == NULL || fread(data, 1, length, file) != length) return 2;
    fclose(file);
  }
  ZjsContext *ctx = zjs_new_core_context();
  zjs_eval_bytecode(ctx, data, length);
  int failed = zjs_had_error(ctx);
  zjs_free_context(ctx);
  free(data);
  return failed;
}
