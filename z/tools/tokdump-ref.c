/* Reference token dump: links the Zen-c engine's exported tokenize_into and
 * prints one `kind start length` triple per line. This is the lexer oracle;
 * the Z lexer's dump must match it byte-for-byte on the same input.
 *
 * Token layout must mirror src/token.zc: { TokenKind kind; u32 start; u32 length; }
 * with the enum emitted as a C int. Validated by tools/oracle-tokens.sh on a
 * known input before any diff is trusted. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { int32_t kind; uint32_t start; uint32_t length; } Token;
extern size_t tokenize_into(const char *source, size_t len, Token *out, size_t cap);

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: tokdump-ref <file.js>\n"); return 2; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 2; }
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  char *src = malloc((size_t)n + 1);
  if (fread(src, 1, (size_t)n, f) != (size_t)n) { perror("read"); return 2; }
  src[n] = 0; fclose(f);
  size_t cap = (size_t)n + 16;
  Token *toks = malloc(cap * sizeof(Token));
  size_t count = tokenize_into(src, (size_t)n, toks, cap);
  for (size_t i = 0; i < count; i++)
    printf("%d %u %u\n", toks[i].kind, toks[i].start, toks[i].length);
  return 0;
}
