# ZJS

An embeddable JavaScript engine written in [Z](https://github.com/popaprozac/z).
A host links `libzjs.a` and drives it through the C ABI in `include/zjs.h`;
`zjsz` is the command-line runner.

All development is in Z. The engine ZJS began as, written in Zen-c, is kept
in [`prior-art/zen-c/`](prior-art/zen-c/) as prior art and the behavioral
oracle the Z engine was checked against; it is not developed (the `zen-c`
branch keeps it in its original, buildable layout). [`prior-art/nim/`](prior-art/nim/)
holds the design notes of an earlier Nim plan.

The goals, in order: small, with web APIs and the like opt-in; the fastest
engine without a JIT, iOS included; embeddable and portable the way QuickJS
is; a JIT, opt-in, last. Where the engine stands against each, measured:
[`docs/goals.md`](docs/goals.md).

## Building and testing

The scripts compile with Z's Stage 0 compiler in the z-lang checkout `$Z_LANG`
names (default `~/code/z-lang`), at the revision in `Z_LANG_REVISION`;
`Z_BIN` names a native compiler binary to use instead (`zc.sh`).

```sh
./build.sh                      # engine + shim + libzjs.a + runner, and the ABI tests
Z_BIN=<native z> ./build.sh     # the same, built by a native compiler binary
./expect.sh                     # expectation cases recorded from node (tests/expect),
                                #   each also run collecting at every safe point and
                                #   from a bytecode file
./gc-check.sh                   # collector checks on engine counters (tests/gc)
./test262-ab.py BEFORE AFTER    # test262, two builds of the engine, and what differs
./test262-fyi.py ZJSZ OUT.jsonl # test262 whole, counted as test262.fyi counts engines
./oracle.sh                     # differential oracle, synthetic corpus
./oracle-tokens.sh              # lexer oracle: diff token dumps, both engines
./oracle-ast.sh                 # parser oracle: diff AST dumps, both engines
./oracle-eval.sh                # behavioral oracle: diff eval results, both engines
./probes/run.sh                 # Z language probes (probes/README.md)
Z_BIN=<native z> ./probes/native/run.sh   # programs Stage 0 accepts that a native compiler rejects
cd ~/code/z-lang && bun run z test ~/code/zjs/engine/heap.zs   # unit tests
```

test262 is not vendored:
`git clone --depth 1 https://github.com/tc39/test262 vendor/test262`.

The runner:

```sh
./build/zjsz run file.js        # a script; a module with .mjs or --module
./build/zjsz compile in.js -o out.zbc   # a bytecode file, run with zjsz run out.zbc
./build/zjsz dump file.js       # the bytecode each function compiles to
```

`zjsz run` flags:

| Flag | What it does |
|---|---|
| `--stats` | slots, cells, dictionaries, collections, weak entries cleared, ephemeron passes, register stack growth |
| `--gc-stats` | every collection timed: count, total, pause percentiles, cells and slots allocated, storage in use, time per collector phase |
| `--mem-stats` | storage alive, in use, and held by capacity; the allocator's in use and reserved; resident and footprint now, resident peak |
| `--gc-nursery N` | cells allocated between minor collections; 1 collects at every safe point (tests), 0 makes every collection full |
| `--gc-slice N` | the marking one slice of a full collection does, in cells; 0 collects whole |
| `--gc-floor N`, `--gc-growth P` | the full-collection policy's floor in cells promoted and survivor multiple in percent (measurement) |
| `--dict-threshold N` | property count at which an object leaves its hidden class (measurement) |
| `--expose-gc` | a global `gc()` that collects everything (tests) |

## Layout

| Path | What |
|---|---|
| `engine/lexer.zs`, `parser.zs`, `ast.zs` | source bytes to tokens to an index-linked AST |
| `engine/compiler.zs`, `bytecode.zs`, `compile.zs` | AST to bytecode; the front end as `eval` and `Function` reach it |
| `engine/runtime.zs` | per-context state, the interpreter loop, the object model |
| `engine/value.zs`, `heap.zs` | NaN-boxed values; the handle-based cell heap and its collector |
| `engine/text.zs`, `number_text.zs`, `regex.zs`, `stack.zs` | strings as UTF-16 code units; a double's shortest digits (Ryu) and their Number::toString layout; the regex backend boundary; the native stack's limit |
| `engine/modules.zs`, `module_files.zs`, `bytecode_file.zs` | ES modules and their file loader; bytecode files |
| `engine/builtins.zs`, `engine/builtins/` | builtins, one module per family, each with its installer |
| `engine/lib.zs` | the context registry and the C ABI exports |
| `engine/native/` | the C the engine links: the regex adapter over QuickJS's `libregexp` and `libunicode` (`quickjs/`), the host's stack |
| `include/zjs.h`, `shim/zjs_shim.c` | the frozen embedding ABI, and its exact signatures over the Z exports |
| `tools/zjsz/` | the command-line runner |
| `tools/*dump-ref.c`, `tools/*dump-z/`, `tools/zjs-ref.c` | the oracles' dumps from each engine, and the reference engine's runner |
| `tools/alloc-attr.c`, `tools/malloc-count.c` | allocator attribution and call counts, inserted into a process |
| `tests/` | ABI tests (`*_test.c`), expectation cases (`expect/`), collector checks (`gc/`), oracle corpora (`eval-corpus/`, `parse-corpus/`), the test262 runner |
| `scripts/test262/` | test262 harness assembly, curated subset, classification |
| `scripts/ryu-tables.py` | makes and checks the powers-of-five tables in `engine/number_text.zs` |
| `bench/` | measurement harnesses: `speed`, `gc`, `alloc`, `memory`, `size` |
| `probes/` | one Z program per language gap the engine has hit |
| `spike/` | the Phase 0 dispatch and heap measurements (`./spike/run.sh`) |
| `prior-art/` | the Zen-c reference engine and the Nim notes; not developed |

## Documentation

| Doc | What |
|---|---|
| [`docs/lifecycle.md`](docs/lifecycle.md) | embedding: contexts and threads, values, properties and calls, host functions, what of `zjs.h` is not implemented |
| [`docs/modules.md`](docs/modules.md) | ES modules |
| [`docs/bytecode-files.md`](docs/bytecode-files.md) | bytecode files, and the runtime without a compiler |
| [`docs/allocation.md`](docs/allocation.md) | the collector |
| [`docs/weak-collections.md`](docs/weak-collections.md) | WeakMap and WeakSet in the collector |
| [`docs/call-depth.md`](docs/call-depth.md) | the limits on call depth and native recursion |
| [`docs/goals.md`](docs/goals.md) | size, speed, and portability, measured |
| `bench/*/README.md`, [`probes/README.md`](probes/README.md) | running the measurement harnesses and the language probes |
