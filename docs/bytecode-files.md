# Bytecode files

A program compiled once and loaded later, so a runtime can skip the
lexer, parser, and compiler -- or link without them. The lever is in
[levers.md](levers.md) (Precompiled bytecode); the embedding calls are
the ones the ABI already declares, `zjs_compile_to_bytecode` and
`zjs_eval_bytecode` (`include/zjs.h`), and the command line's
`zjsz compile in.js -o out.zbc` and `zjsz run out.zbc`.

The Zen-C engine's format (`prior-art/zen-c/docs/aot-bytecode-format.md`)
is the starting point. What changes: the Z engine's functions are a flat
table rather than a tree of function values, its strings are atoms, it
marks hoisted globals defined when a script starts rather than when it
compiles, and the file carries a checksum.

## What a compiled program is

`compileProgram` adds functions to the runtime's table in order: each
nested function reserves its index before its body compiles, and the
script itself comes last. A program is the run of indices from the table's
length before the compile to the script's index. Each is a `FunctionCode`
(`engine/bytecode.zs`). Its fields are one of three kinds:

- Plain data, written as it is: register, parameter, and argument counts,
  `thisReg`, the flags (arrow, async, generator, strict, class
  constructor, derived, method), the eval sites (names as bytes, slots,
  depths).
- Handles into the runtime that compiled it, written as what they stand
  for and made again on load:
  - atoms (string constants, property names, the function's name, a
    regular expression's source and flags, a private name's
    description) -- written as their text;
  - function cells in the constants -- written as the function's
    position in the program;
  - template objects, frozen arrays built at compile time -- written as
    their cooked and raw strings;
  - global slots in instruction operands (`loadGlobal`,
    `loadGlobalOrUndefined`, `storeGlobal`, `storeGlobalStrict`,
    `defineGlobal`) -- written as indices into a table of names.
- State the runtime derives on install, not written: the code's place in
  the code segment, the property caches, the leaf flag.

A constant of any other kind, or an atom the engine keeps hidden from
programs, makes the compile to bytecode fail, so a new kind cannot be
written wrongly without notice.

## Globals declared at start

The compiler marks a script's hoisted `var`, function, and class names
as defined globals while it compiles. A compile that is not followed by
a run -- `zjs_compile_to_bytecode` -- would leave them defined in the
compiling context, and a script that fails to compile part way leaves
some of them defined too. Instead the script's `FunctionCode` lists the
global slots it declares, and `Runtime.run` defines them before the
first instruction, which is when the specification has them made
(GlobalDeclarationInstantiation). The file writes the list as name-table
indices.

## Layout

Little-endian throughout, no alignment, no padding.

```
File :=
  u8[4]  magic            'Z' 'J' 'S' 'b'
  u32    formatVersion    1
  u32    instructionSet   INSTRUCTION_SET_VERSION (engine/bytecode.zs)
  u32    payloadLength
  u32    checksum         FNV-1a over the payload
  Payload

Payload :=
  u32 stringCount,   String[stringCount]
  u32 globalCount,   u32[globalCount]       name: string index
  u32 functionCount, Function[functionCount] the script last

String :=
  u8  kind            0 Latin-1 bytes, 1 UTF-16 units
  u32 length          in bytes or units
  bytes or units

Function :=
  u32 name            string index, or 0xFFFFFFFF for none
  u32 registerCount, u32 fixedRegs, u32 paramCount, i32 thisReg,
  u32 expectedArgCount
  u16 flags           arrow 1, async 2, generator 4, strict 8,
                      class constructor 16, derived 32, method 64
  u32 codeLength,     Inst[codeLength]      op, a, b, c, d: 5 bytes
  u32 constantCount,  Constant[constantCount]
  u32 nameCount,      u32[nameCount]        property names: string indices
  u32 declaredCount,  u32[declaredCount]    global indices (the script only)
  u32 evalSiteCount,  EvalSite[evalSiteCount]

Constant := u8 tag, then
  0 int32     i32
  1 double    u64 bits
  2 string    u32 string index
  3 function  u32 function index in this file
  4 template  u32 count, u32[count] cooked (string index, or 0xFFFFFFFF
              for undefined), u32[count] raw (string indices)
  5 hole
```

`EvalSite` writes its fields in declaration order: the names' bytes, then
each level with its bindings.

`INSTRUCTION_SET_VERSION` changes whenever an opcode, an operand, or an
instruction's meaning does; a test pins it beside the opcode count, so
adding an opcode fails that test until the version moves. A file of
another format or instruction-set version is refused, not translated:
an embedder ships bytecode built by the engine it links.

## Loading

The loader reads the whole file before it changes the runtime: magic,
both versions, the payload's length and checksum, and every count and
index against what the file holds -- a string, global, or function index
in range, an opcode below the opcode count, a register count of at most
256, a known string kind and constant tag. A file that fails any check
is refused with nothing added to the runtime. Then it interns the
strings, finds or adds each global by name, reserves the functions'
indices together, makes the constants (function cells for the reserved
indices, template objects from their strings), rewrites global operands
to this runtime's slots, and installs each function as the compiler
would have. A loaded script runs exactly as one compiled from source.

## Trust

The checks catch a corrupted, truncated, or mismatched file. They do not
make bytecode from an untrusted source safe to run. The interpreter
reads registers, the code segment, property caches, and environment
slots without bounds checks, relying on what the compiler guarantees:
every register operand below the function's register count, every jump
inside its code, every environment hop and slot inside the chain the
code runs against. A file that breaks those can make the engine read or
write outside its arrays. Proving them for a file means a verifier
that follows each function's environment chain through its control flow
and into the functions it creates -- code the runtime without a
compiler would carry, and time every load would spend. QuickJS and
Hermes take the same position: bytecode comes from the application's own
build. Untrusted bytecode is out of scope until a verifier is asked for.

## The runtime without a compiler

What the lever saves comes from linking without the front end. Outside
the compiler itself, three places reached it: `lib.zs`'s `evaluate`,
`eval` (`builtins/global.zs`), and the `Function` constructor
(`builtins/function.zs`). Now the runtime reaches it through two
function-typed fields, `scriptCompiler` and `evalCompiler`, whose
defaults answer that there is none; `installCompiler` (`compile.zs`)
sets them. `eval` and `Function` compile through them and, without a
compiler, throw an EvalError saying the context runs bytecode only.

`zjs_new_context` installs the compiler, and `zjs_eval` and
`zjs_compile_to_bytecode` install it in the context they run on, since
they compile source themselves; `zjs_install_compiler` gives one to a
context that has done neither. A core context that only runs bytecode
never references the front end, so the linker drops it from the same
`libzjs.a`: no separate library is built.

Linked and dead-stripped (`bench/size/embedders.sh`, macOS arm64, z-lang
`1b105418`):

| Embedder | `__text` | `__TEXT` |
|---|---|---|
| `zjs_new_context`, `zjs_eval` | 736,276 | 786,432 |
| `zjs_new_core_context`, `zjs_eval` | 548,148 | 573,440 |
| `zjs_new_core_context`, `zjs_eval_bytecode` | 365,904 | 393,216 |

Bytecode only, the core is 182 KB (33%) smaller: the lexer, parser,
compiler, and the bytecode writer are gone, and only the loader remains.

## Evidence

- Round trip: every expectation case and the test262 subset compiled,
  written, loaded into a fresh runtime, and run, with the same outcomes
  as from source.
- The loader's refusals: truncated files, each byte flipped, wrong
  magic and versions, out-of-range indices.
- Load time against parse and compile time for the speed kernels and a
  large script.
