# zjs AOT bytecode (`.zbc`) — v1

Pre-parsed programs are bytes a host loads at runtime, skipping
lex/parse/compile. Equivalent to QuickJS's `qjsc` output or Hermes's
`.hbc`, but smaller in scope: zjs writes a single top-level function
tree, with nested functions inlined recursively as `Value`s in the
constants pool. There is no module/symbol table, no debug-info section,
and no relocation table — globals are remapped by name at load time.

The implementation is `src/aot.zc`. If this doc and that file disagree,
the file wins.

## Producing and consuming

```bash
# CLI: source → bytecode
zjs compile script.js -o script.zbc

# CLI: run a .zbc (auto-detected by the ZJSb magic)
zjs run script.zbc
```

```c
/* C ABI: in-process compile + replay */
size_t n = 0;
unsigned char* bc = zjs_compile_to_bytecode(ctx, source, &n);
ZjsValue result = zjs_eval_bytecode(ctx, bc, n);
free(bc);
```

A buffer produced in one context is valid input to **any** zjs context
of the same engine version. Globals are written by name, not by slot, so
their numeric indices don't need to line up across contexts.

## Endianness, integers, alignment

Every multi-byte integer on disk is **little-endian**. Reads/writes are
byte-at-a-time, so there is no alignment requirement; embedders can
`mmap` a `.zbc` and hand the buffer straight to `zjs_eval_bytecode`.

Convention used below:

| Token       | Meaning                                                  |
|-------------|----------------------------------------------------------|
| `u8`/`u32`/`u64` | unsigned little-endian integer of that width        |
| `i32`       | signed 32-bit, two's complement, little-endian            |
| `ZjsString` | `u32 length, u8[length] bytes` — no NUL terminator        |
| `Value`     | tagged value, see [Value tags](#value-tags)               |

## Top-level container

```
ZjsBytecode :=
  u8[4]  MAGIC       'Z','J','S','b'
  u32    VERSION     currently 1; mismatched versions are rejected
  FunctionBlock TOP_FUNCTION
```

The top function is the script body. Its top-level `this` is bound to
the global object by `zjs_run_function` (the same setup as `zjs_eval`).

## FunctionBlock

Written field-by-field in this order. There are no padding bytes between
fields.

```
FunctionBlock :=
  u32                    globals_count            -- M
  ZjsString[M]           global_names              -- by slot index

  u32                    code_len                  -- N instructions
  Inst[N]                code                      -- 4 bytes each

  u32                    const_count               -- K
  Value[K]               constants

  u32                    ic_count                  -- I
  ZjsString[I]           ic_names                  -- IC data ships cold

  u32                    register_count
  u32                    fixed_regs
  u32                    param_count
  u32                    expected_arg_count

  u8                     flags                     -- see [Flag bits]
  u8                     env_reg                   -- meaningful iff NEEDS_ENV

  Value                  parent_ctor               -- undefined unless derived-class ctor

  u32                    template_count            -- T
  -- when T > 0:
  u32                    total_segments            -- S
  u32[T+1]               seg_start                 -- monotonic, [0]=0, [T]=S
  TemplateSegment[S]     segments                  -- flat, per the seg_start spans
```

### Globals remap

The compiler bakes per-context global slot numbers into bytecode
operands. Those numbers are unstable across contexts (slot 7 in the
compile context might be slot 3 — or unused — in the load context),
so the wire format ships the **name** of every slot referenced by any
global op (`LoadGlobal`, `LoadGlobalOrUndefined`, `StoreGlobal`,
`DefineGlobal`).

- `globals_count` is `1 + max(slot)` over those ops; if no global op is
  used, `globals_count` is 0.
- For each `i in [0, globals_count)` the writer emits `global_names[i]`
  from the compile-context's slot table. Unreferenced gaps within the
  range are written as a zero-length string.

At load time `aot_read_function` interns each name into the **load**
context (yielding a fresh slot index), builds a `compile→load` remap
table, and rewrites the `bc_u16` operand of every global op accordingly
before installing the code on the `Function*`. After this rewrite the
interpreter is identical to a fresh-from-source path.

### Code

The in-memory `Inst` struct is `{ Op op; u8 a; u8 b; u8 c; }`. Zen-c
lowers `Op` to a C `int`, so the struct is **8 bytes** of in-memory
padding, not 4. The wire format is the canonical 4-byte form
`{ u8 op, u8 a, u8 b, u8 c }` — written/read field-by-field, never as a
`memcpy` of the struct. Operands such as `bc_u16` are packed across
`a`/`b`/`c` exactly as the interpreter expects.

### Constants

Each entry is a `Value` (see below). Nested functions appear here as
`tag = function`, recursing through `FunctionBlock`. Hidden classes are
*not* serialized — they're discovered at runtime from the IC path.

### Inline caches

`ic_names[j]` is the property atom for IC slot `j`. The rest of an IC
entry (`classes`, `slots`, `proto_cls`) is **not** serialized; entries
are initialized cold and warm up on the first hit, identical to the
fresh-source path. The motivation is portability: a hidden class is
context-local and meaningless across contexts.

### Tagged-template tables

`template_count` is the number of `${…}`-style tagged-template call
sites in the function. When > 0:

- `total_segments` is the flattened segment count across all sites.
- `seg_start` slices the flat array by site (so site `t` owns segments
  `[seg_start[t], seg_start[t+1])`).
- Each `TemplateSegment` is:

  ```
  u8         cooked_valid    -- 0 if cooked is invalid-escape sentinel
  ZjsString  cooked_or_empty -- empty when cooked_valid == 0
  ZjsString  raw
  ```

  Cooked/raw arrays are re-frozen on first use, same as the fresh-source
  path. Per-site cached `{cooked,raw}` array pairs are *not* persisted.

## Flag bits

`flags` is a bitfield over the `FunctionBlock`'s execution mode:

| Bit  | Name                          | Meaning                                          |
|------|-------------------------------|--------------------------------------------------|
| 0x01 | `NEEDS_ENV`                   | function captures an environment (closure)        |
| 0x02 | `IS_CLASS_CONSTRUCTOR`        | invoked via `new` on a class                      |
| 0x04 | `IS_METHOD`                   | shorthand method (no `[[Construct]]`)             |
| 0x08 | `IS_DEFAULT_DERIVED_CTOR`     | auto-generated `constructor(...args){super(...args)}` |
| 0x10 | `USES_ARGUMENTS`              | references `arguments`                            |
| 0x20 | `HAS_REST_PARAM`              | last param is `...rest`                           |
| 0x40 | `IS_ASYNC`                    | `async` function                                   |
| 0x80 | `IS_GENERATOR`                | `function*` generator                              |

`parent_ctor` is the resolved super constructor for default-derived
class constructors; for everything else it serializes as `undefined`.

## Value tags

```
Value := u8 tag, payload:
  0x00 int32      i32
  0x01 double     u64 bit pattern (IEEE 754, memcpy through u64)
  0x02 bool       u8 (0 or 1)
  0x03 null       —
  0x04 undefined  —
  0x05 string     ZjsString
  0x06 function   FunctionBlock (recursive)
```

Unknown tags abort the read (returns `NULL` from
`aot_deserialize_program`; the embed ABI surfaces this as `undefined`
without setting `had_error` — distinguish "bad file" from "program
threw" by checking the return value and `zjs_had_error` together).

## What is *not* in the file

By design, none of the following persist:

- **Hidden classes** — runtime-discovered from shape transitions; the
  IC path repopulates them on first hit.
- **IC data** — same reason; only the property name is durable.
- **Tagged-template cached array pairs** — re-frozen on first use.
- **Function `.prototype` / `.props` expandos** — start empty.
- **Atom pointers** — names re-intern at load time.

If you need to ship hot state, run the program once and snapshot the
context — not the bytecode.

## Versioning policy

- `VERSION` is a `u32` that increments by 1 on **any** incompatible
  change to the wire format. There are no minor versions; readers do not
  attempt to tolerate forward differences.
- A loader rejects any buffer whose `VERSION` does not equal the engine's
  built-in version. The embed ABI returns `undefined` without setting
  `had_error`; the CLI prints a versioning error and exits non-zero.
- The `MAGIC` (`'Z','J','S','b'`) is also load-bearing — it sniffs a
  bytecode buffer vs. source so the CLI can auto-detect file type.

A change counts as incompatible if it adds, removes, reorders, or
retypes any field in the wire format; renames an op code; or changes
the `Op`-byte encoding. A change that affects only in-memory layout
(struct padding, enum widening) is **not** incompatible — the wire
format is explicit and decoupled from the host's representation by
design.

When bumping the version:

1. Increment `ZJS_AOT_VERSION` in `src/aot.zc`.
2. Update this doc's "v1" → new version and amend the [Top-level
   container](#top-level-container) / `FunctionBlock` sections.
3. Add a `tests/embed_smoke.c` case that exercises the new field on a
   freshly-compiled buffer.
4. Note the breaking change in the engine release.

Older `.zbc` files are not auto-migrated. The intended workflow is to
re-compile from source after an engine upgrade; pinning a zjs version
to a `.zbc` is on the embedder.

## Known caveats

- The format is not stable across **engines** — only across contexts of
  the same zjs build. A `.zbc` produced by another JS engine cannot be
  loaded.
- There is no integrity check (no CRC, no signature). Embedders that
  load bytecode from untrusted sources should hash the buffer with a
  hash they trust. A malformed file is detected (`r.err`), but the
  guarantee is "safe to fail," not "safe to trust."
- Op-code identity is tied to the in-tree `Op` enum. Reordering ops
  *is* a wire-format break and requires a version bump.

## Reference: layout at a glance

```
+---------------------------------------------------------------+
| 'Z'  'J'  'S'  'b'  | VERSION u32                             |  <- header
+---------------------------------------------------------------+
| globals_count u32                                              |
|   global_names[M]   (ZjsString each)                           |
+---------------------------------------------------------------+
| code_len u32                                                   |
|   code[N]            (u8 op, u8 a, u8 b, u8 c)                 |
+---------------------------------------------------------------+
| const_count u32                                                |
|   constants[K]       (Value each — recursive)                  |
+---------------------------------------------------------------+
| ic_count u32                                                   |
|   ic_names[I]        (ZjsString each)                          |
+---------------------------------------------------------------+
| register_count u32   fixed_regs u32                            |
| param_count u32      expected_arg_count u32                    |
+---------------------------------------------------------------+
| flags u8   env_reg u8                                           |
| parent_ctor (Value)                                             |
+---------------------------------------------------------------+
| template_count u32                                              |
|   total_segments u32                                            |
|   seg_start[T+1]   (u32 each)                                   |
|   segments[S]      (u8 valid, ZjsString cooked, ZjsString raw)  |
+---------------------------------------------------------------+
```
