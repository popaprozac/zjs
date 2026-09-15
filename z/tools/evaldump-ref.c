/* Reference eval dump: evaluate a file through the Zen-c engine's public
 * API and print a canonical rendering of the completion value (or the
 * uncaught error). The Z engine's dump must match it byte-for-byte on the
 * same input. This is the behavioral oracle for the compiler and
 * interpreter, where bytecode is deliberately allowed to differ. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "zjs.h"

static void render(ZjsContext *ctx, ZjsValue v) {
  if (zjs_is_undefined(v)) { printf("undefined\n"); return; }
  if (zjs_is_null(v)) { printf("null\n"); return; }
  if (zjs_is_bool(v)) { printf("%s\n", zjs_as_bool(v) ? "true" : "false"); return; }
  if (zjs_is_int32(v)) { printf("int32 %d\n", zjs_as_int32(v)); return; }
  if (zjs_is_double(v)) {
    double d = zjs_as_double(v); uint64_t bits; memcpy(&bits, &d, sizeof bits);
    printf("double %llu\n", (unsigned long long)bits); return;
  }
  if (zjs_is_string(v)) {
    uint32_t n = 0; const char *b = zjs_string_bytes(v, &n);
    printf("string %u ", n); fwrite(b, 1, n, stdout); printf("\n"); return;
  }
  if (zjs_is_array(v)) { printf("array\n"); return; }
  if (zjs_is_function(v) || zjs_is_host_function(v)) { printf("function\n"); return; }
  if (zjs_is_object(v)) { printf("object\n"); return; }
  printf("cell\n");
  (void)ctx;
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: evaldump-ref <file.js>\n"); return 2; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 2; }
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  char *src = malloc((size_t)n + 1);
  if (fread(src, 1, (size_t)n, f) != (size_t)n) { perror("read"); return 2; }
  src[n] = 0; fclose(f);
  ZjsContext *ctx = zjs_new_context();
  ZjsValue result = zjs_eval(ctx, src);
  if (zjs_had_error(ctx)) { printf("throw "); render(ctx, zjs_get_error(ctx)); }
  else { printf("value "); render(ctx, result); }
  zjs_free_context(ctx);
  return 0;
}
