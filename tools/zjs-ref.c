/* Reference command line for the differential test262 run: `zjs-ref run
 * <file>`. The same contract as tools/zjs.zc, built against the public
 * ABI so no Zen-c toolchain is needed: exit 0 when the program completes,
 * otherwise `zjs: throw: <name>: <message>` on stderr and exit 1. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "zjs.h"

static void write_string(ZjsValue v) {
  uint32_t n = 0; const char *b = zjs_string_bytes(v, &n);
  fwrite(b, 1, n, stderr);
}

int main(int argc, char **argv) {
  if (argc < 3 || strcmp(argv[1], "run") != 0) { fprintf(stderr, "usage: zjs-ref run <file>\n"); return 2; }
  FILE *f = fopen(argv[2], "rb");
  if (!f) { perror(argv[2]); return 2; }
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  char *src = malloc((size_t)n + 1);
  if (fread(src, 1, (size_t)n, f) != (size_t)n) { perror("read"); return 2; }
  src[n] = 0; fclose(f);
  ZjsContext *ctx = zjs_new_context();
  zjs_eval(ctx, src);
  int rc = 0;
  if (zjs_had_error(ctx)) {
    ZjsValue err = zjs_get_error(ctx);
    fputs("zjs: throw: ", stderr);
    if (zjs_is_object(err)) {
      ZjsValue name = zjs_get_property(ctx, err, "name");
      ZjsValue msg = zjs_get_property(ctx, err, "message");
      if (zjs_is_string(name)) write_string(name); else fputs("(unknown)", stderr);
      if (zjs_is_string(msg)) { fputs(": ", stderr); write_string(msg); }
    } else if (zjs_is_string(err)) {
      write_string(err);
    } else {
      fputs("(non-object)", stderr);
    }
    fputc('\n', stderr);
    rc = 1;
  }
  zjs_free_context(ctx);
  return rc;
}
