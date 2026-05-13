# zjs Phase 3.1a — Heap Infrastructure + Strings

> First slice of Phase 3.1. Introduces a cell-header model that
> everything heap-allocated will share (functions, strings, and
> eventually objects/arrays), plus the simplest heap-allocated value
> type: strings. No GC yet; the per-context allocation list holds
> cells until `zjs_free_context`. That's acceptable for hobby-pace
> evaluation and unblocks the next sub-slices (objects, arrays, then
> throw + real test262 signal).

## Scope

In scope:
- `CellHeader { type_tag: u8 }` — first field of every heap-allocated cell
- Type tags: `TAG_FUNCTION = 0`, `TAG_STRING = 1`
- `ZjsContext.cells` — unified tracking list for all cells; freed in `zjs_free_context` via type-tag dispatch
- `ZjsString` — heap-allocated, length-prefixed, UTF-8 byte-transparent
- `zjs_is_string`, `zjs_is_function` — predicates that dereference a cell pointer and check its tag
- Compile-time **escape decoding** for string literals: `\n \t \r \\ \" \' \0 \b \f \v`
- **String concat** via `+`: if either operand is a string, ToString the other and produce a fresh string cell
- **ToString** for int32 / double / bool / null / undefined / string
- ToBoolean for strings (already covered: empty = false, otherwise true)
- Strict + loose equality for strings (byte-compare)
- CLI `print_value` prints strings without quotes (since they're already strings)

Out of scope (later sub-slices):
- Real mark-sweep GC — comes once we have multiple cell kinds and lifetime gets harder to reason about with the simple list
- String property access (`.length`, indexing, `String.prototype.*`) — Phase 3.1b/c
- String interning / atom table — Phase 3.1c (helps `===` and property-name lookup)
- Unicode escapes (`\xHH`, `\u{HHHH}`)
- Template literals — needs lexer cooperation, deferred

## Cell layout

```c
struct CellHeader {
    uint8_t type_tag;     // TAG_FUNCTION or TAG_STRING
    uint8_t _pad;          // align; future GC mark bit will live here
};

struct ZjsString {
    CellHeader header;     // { type_tag = TAG_STRING }
    uint32_t   length;     // byte length (UTF-8 transparent)
    char*      data;       // null-terminated, owned
};

struct Function {
    CellHeader header;     // { type_tag = TAG_FUNCTION }
    // ... existing fields ...
};
```

Function gets `CellHeader` as its first field — the existing pointer-as-cell pattern already worked because every cell was a function. Now `(CellHeader*)cell_ptr` is always valid and gives the type tag.

## Module ownership

| Module | Owns |
|---|---|
| `value.zc` | `CellHeader`, `ZjsString`, predicates, allocation helpers, `zjs_to_string`, `string_free_void` |
| `bytecode.zc` | `Function` struct (now with `CellHeader` header field), `function_free_void` |
| `context.zc` | `cells` tracking list, `ctx_register_cell`, `ctx_intern_string`, `zjs_string_concat`, free dispatch in `zjs_free_context` |
| `interpreter.zc` | `Op::Add` handler dispatches string-concat path when either operand is a string |
| `compiler.zc` | `StringExpr` handler — decodes escapes at compile time, interns the string, emits `LoadConst` |

`value.zc` doesn't import `context.zc` (would be a cycle). Anything that allocates on a context (string concat, ToString of non-string) is owned by `context.zc` and takes `ZjsContext*` as a parameter.

## Verification

`make test` continues to pass everything from prior phases, plus:

- `zjs eval "'hello'"` → `hello`
- `zjs eval "'hello' + ' world'"` → `hello world`
- `zjs eval "'a' + 1"` → `a1`
- `zjs eval "1 + 'b'"` → `1b`
- `zjs eval "'foo' === 'foo'"` → `true`
- `zjs eval "'foo' !== 'bar'"` → `true`
- `zjs eval "if ('') 1; else 2"` → `2`
- `zjs eval "if ('a') 1; else 2"` → `1`
- `zjs eval "let s = 'hello\\nworld'; s"` → prints `hello` newline `world`

Plus tests in `interpreter_test.zc` (`check_string` helper) and `embed_smoke.c`.

## What's next

- **Phase 3.1b** — Objects + property access + arrays. Hidden classes vs. dictionary-mode; for first cut, dictionary-mode object property dicts to avoid the hidden-class complexity. Arrays as a special object kind with dense indexed storage.
- **Phase 3.1c** — Throw / try / catch + atom-interned property names. Stack unwinding.
- **Phase 3.1d** — Real mark-sweep GC. Walks the live call-stack register files as the root set.
- **Phase 3.1e** — test262 with real signal. Load `harness/assert.js` as preamble, count actual assertion pass/fail.
