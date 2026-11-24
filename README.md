# ZJS

An embeddable JavaScript engine written in [Z](https://github.com/popaprozac/z).
A host links `libzjs.a` and drives it through the C ABI in `include/zjs.h`;
`zjsz` is the command-line runner.

## Goals

In order:

1. **Small, with features opt-in.** The core is ECMAScript; the optional
   builtins, and web APIs and the like, are installers an embedder links
   only when it calls them.
2. **The fastest engine without a JIT**, on every device, iOS included.
3. **Embeddable and portable** the way QuickJS is.
4. **A JIT, opt-in**, last.

All development is in Z. The engine ZJS began as, written in Zen-c, is in
[`prior-art/zen-c/`](prior-art/zen-c/): it is not developed, and the
oracles diff the Z engine against it. The `zen-c` branch keeps it in its
original, buildable layout, with its design and phase docs.

## Building

The scripts compile with Z's Stage 0 compiler in the z-lang checkout
`$Z_LANG` names (default `~/code/z-lang`), at the revision in
`Z_LANG_REVISION`; `Z_BIN` names a native compiler binary to use instead
(`zc.sh`). The scripts and gates run on macOS arm64; what the engine's C
needs elsewhere is in [`docs/portability.md`](docs/portability.md).

```sh
./build.sh                      # libzjs.a, zjsz, and the test binaries into build/, then the ABI tests
Z_BIN=<native z> ./build.sh     # the same, built by a native compiler binary
```

## Testing

| Command | What it checks |
|---|---|
| `./build.sh` | builds, then runs the ABI tests (`tests/*_test.c`), `./expect.sh`, and `./gc-check.sh` |
| `./expect.sh` | expectation cases recorded from node (`tests/expect/`), each run three ways: plainly, collecting at every safe point, and from a bytecode file |
| `./gc-check.sh` | the collector, on the engine's own counters (`tests/gc/`) |
| `./test262-ab.py BEFORE AFTER` | test262 on two builds of the engine, and the tests whose outcome differs |
| `./test262-fyi.py ZJSZ OUT.jsonl` | test262 whole, counted the way test262.fyi counts engines |
| `./oracle.sh` | differential oracle against the Zen-c engine, synthetic corpus |
| `./oracle-tokens.sh`, `./oracle-ast.sh`, `./oracle-eval.sh` | the lexer, parser, and evaluation, diffed against the Zen-c engine |
| `./probes/run.sh` | Z language probes ([`probes/README.md`](probes/README.md)) |
| `Z_BIN=<native z> ./probes/native/run.sh` | programs Stage 0 accepts that a native compiler rejects |
| `cd ~/code/z-lang && bun run z test ~/code/zjs/engine/heap.zs` | a module's unit tests |

test262 is not vendored:
`git clone --depth 1 https://github.com/tc39/test262 vendor/test262`.

## Running

```sh
./build/zjsz run file.js                 # a script; a module with .mjs or --module
./build/zjsz compile in.js -o out.zbc    # a bytecode file; --module for a module's
./build/zjsz run out.zbc                 # run a bytecode file
./build/zjsz dump file.js                # the bytecode each function compiles to
```

`zjsz run` flags:

| Flag | What it does |
|---|---|
| `--module` | run the file as an ES module (a `.mjs` file always is) |
| `--include FILE` | run a script first, in the same realm; repeatable, in order |
| `--via-bytecode` | compile the source to a bytecode file and run that (each module of a graph through a module file) |
| `--no-compiler` | load modules from bytecode files only, as an embedder without the compiler does |
| `--stats` | slots, cells, dictionaries, collections, weak entries cleared, ephemeron passes, register stack growth |
| `--gc-stats` | every collection timed: count, total, pause percentiles, cells and slots allocated, storage in use, time per collector phase |
| `--mem-stats` | storage alive, in use, and held by capacity; the allocator's in use and reserved; resident and footprint now, resident peak |
| `--gc-nursery N` | cells allocated between minor collections; 1 collects at every safe point (tests), 0 makes every collection full |
| `--gc-slice N` | the marking one slice of a full collection does, in cells; 0 collects whole |
| `--gc-floor N`, `--gc-growth P` | the full-collection policy's floor in cells promoted and survivor multiple in percent (measurement) |
| `--dict-threshold N` | property count at which an object leaves its hidden class (measurement) |
| `--expose-gc` | a global `gc()` that collects everything (tests) |

## Embedding

A host includes `include/zjs.h` and links `build/libzjs.a`, which holds the
engine, the ABI shim, and the regular-expression backend:

```sh
clang -std=c11 -I include host.c build/libzjs.a -o host
```

[`docs/lifecycle.md`](docs/lifecycle.md) covers contexts and threads,
values, calls, host functions, and the opt-in installers;
[`docs/modules.md`](docs/modules.md) and
[`docs/bytecode-files.md`](docs/bytecode-files.md) cover ES modules and
running precompiled bytecode.

## Layout

| Path | What |
|---|---|
| `engine/lexer.zs`, `parser.zs`, `ast.zs` | source bytes to tokens to an index-linked AST |
| `engine/compiler.zs`, `bytecode.zs`, `compile.zs` | AST to bytecode; the front end as `eval` and `Function` reach it |
| `engine/runtime.zs` | per-context state, the interpreter loop, the object model |
| `engine/value.zs`, `heap.zs` | NaN-boxed values; the handle-based cell heap and its collector |
| `engine/text.zs`, `number_text.zs`, `regex.zs`, `stack.zs` | strings as UTF-16 code units; number to text and back; the regex backend boundary; the native stack's limit |
| `engine/modules.zs`, `module_files.zs`, `bytecode_file.zs` | ES modules and their file loader; bytecode files |
| `engine/builtins.zs`, `engine/builtins/` | builtins, one module per family, each with its installer |
| `engine/lib.zs` | the context registry and the C ABI exports |
| `engine/native/` | the C the engine links: the regex adapter over QuickJS's `libregexp` and `libunicode` (`quickjs/`), the host's stack |
| `include/zjs.h`, `shim/zjs_shim.c` | the frozen embedding ABI, and its exact signatures over the Z exports |
| `tools/zjsz/` | the command-line runner |
| `tools/*dump-ref.c`, `tools/*dump-z/`, `tools/zjs-ref.c` | the oracles' dumps from each engine, and the reference engine's runner |
| `tools/alloc-attr.c`, `tools/malloc-count.c` | allocator attribution and call counts, inserted into a process |
| `tests/` | ABI tests (`*_test.c`), expectation cases (`expect/`), collector checks (`gc/`), oracle corpora (`eval-corpus/`, `parse-corpus/`, `wintercg/`), module and bytecode fixtures, the test262 runner |
| `scripts/test262/` | test262 harness assembly, the curated subset (`config.json`), classification |
| `scripts/ryu-tables.py` | makes and checks the powers-of-five tables in `engine/number_text.zs` |
| `bench/` | measurement harnesses: `speed`, `gc`, `alloc`, `memory`, and `size` (`./bench/size/embedders.sh`: minimal embedders' linked size) |
| `probes/` | one Z program per language gap the engine has hit |
| `spike/` | value-representation and dispatch variants measured against each other (`./spike/run.sh`) |
| `prior-art/zen-c/` | the Zen-c reference engine; not developed |

## Documentation

| Doc | What |
|---|---|
| [`docs/lifecycle.md`](docs/lifecycle.md) | embedding: contexts and threads, installers, values, properties and calls, host functions, what of `zjs.h` is not implemented |
| [`docs/modules.md`](docs/modules.md) | ES modules |
| [`docs/bytecode-files.md`](docs/bytecode-files.md) | bytecode files, and the runtime without a compiler |
| [`docs/allocation.md`](docs/allocation.md) | the collector |
| [`docs/weak-collections.md`](docs/weak-collections.md) | WeakMap and WeakSet in the collector |
| [`docs/call-depth.md`](docs/call-depth.md) | the limits on call depth and native recursion |
| [`docs/portability.md`](docs/portability.md) | platforms the engine builds and runs on, and their gaps |
| [`bench/speed`](bench/speed/README.md), [`gc`](bench/gc/README.md), [`alloc`](bench/alloc/README.md), [`memory`](bench/memory/README.md) | running the measurement harnesses |
| [`probes/README.md`](probes/README.md) | the Z language probes |
