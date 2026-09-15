/* Reference AST dump: links the Zen-c engine's exported parse_program and
 * prints one line per node in preorder. The Z parser's dump must match it
 * byte-for-byte on the same input.
 *
 * Struct layouts mirror src/ast.zc and src/parser.zc field-for-field; enums
 * are C ints. Validated on a known input by tools/oracle-ast.sh before any
 * diff is trusted. The Parser is opaque here -- only the result's root and
 * error flag are read. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct AstNode AstNode;
struct AstNode {
  int32_t kind;
  uint32_t start, end;
  int32_t op;
  double num;
  bool bool_value;
  AstNode *left, *right, *third;
  AstNode **children;
  uint32_t children_count;
  uint32_t name_start, name_length;
  uint32_t scope_id;
};
typedef struct { AstNode *root; void *parser; bool had_error; } ParseResult;
extern ParseResult parse_program_with(const char *source, size_t len, bool is_module);

static void dump(const AstNode *n, int depth) {
  if (!n) { printf("%d -\n", depth); return; }
  /* num is printed as its IEEE-754 bits: exact, and reproducible from Z
   * through f64.toBits without any float formatting. */
  uint64_t bits; memcpy(&bits, &n->num, sizeof bits);
  printf("%d %d %u %u %d %llu %d %u %u %u\n", depth, n->kind, n->start, n->end,
         n->op, (unsigned long long)bits, n->bool_value ? 1 : 0, n->name_start,
         n->name_length, n->children_count);
  dump(n->left, depth + 1);
  dump(n->right, depth + 1);
  dump(n->third, depth + 1);
  for (uint32_t i = 0; i < n->children_count; i++) dump(n->children[i], depth + 1);
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: astdump-ref <file.js> [--module]\n"); return 2; }
  bool is_module = argc > 2;
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 2; }
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  char *src = malloc((size_t)n + 1);
  if (fread(src, 1, (size_t)n, f) != (size_t)n) { perror("read"); return 2; }
  src[n] = 0; fclose(f);
  ParseResult r = parse_program_with(src, (size_t)n, is_module);
  printf("error %d\n", r.had_error ? 1 : 0);
  if (!r.had_error) dump(r.root, 0);
  return 0;
}
