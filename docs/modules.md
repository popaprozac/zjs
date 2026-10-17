# ES modules

`import` and `export` as the specification has them: live bindings,
modules linked before any of them runs, cycles, namespace objects. The
parser has read module syntax for some time; this is the rest. The
embedding calls are the ones the ABI declares, `zjs_eval_module` and
`zjs_eval_module_source` (`include/zjs.h`), and `zjsz run` takes a
module (`.mjs`, or `--module`).

The Zen-C engine's model, which `zjs.h` described, gave each module an
exports object that cycles saw "partially populated". That is not the
language: an import is a binding that reads the exporting module's
binding as it is now, a `let` read before it is initialized throws, and a
function declaration is callable from another module before its own
module has run. This follows the specification instead, and `zjs.h`'s
text now says so.

## Modules in the runtime

A module record per module the runtime has loaded (`Runtime.modules`), kept
by its key (the resolved specifier: the normalized path for files, the
virtual path given to `zjs_eval_module_source`):

- its compiled function and what the compiler found: the modules it
  requests, by specifier, each once; its imports (module, imported name or
  namespace, the slot of its binding); its local exports (exported name,
  the binding's slot); its indirect exports (exported name, module,
  imported name or namespace), which an exported import also is; and its
  star exports (module);
- the record each request resolved to;
- its generator and environment, made when it is linked;
- its namespace object, made the first time one is asked for;
- its status (new, linked, evaluating, evaluated, failed) and the error
  it failed with, which every later import of it throws again.

The collector marks every record's keys, names, generator, environment,
namespace, and error.

## Compiling a module

A module compiles to a generator function (`compileModule`). Calling it
makes the module's environment, every top-level binding in it, since
another module may import any of them; its first step creates its
function declarations (callable from any module from then on) and sets
its `let`, `const`, and `class` bindings to the hole, and stops at a
yield the compiler adds; its second step runs the module's statements.
Linking takes the first step, evaluation the second. Every top-level
lexical binding starts as the hole, whatever the module itself reads
first: another module may read it before its declaration runs.

An imported binding is two environment slots: the environment of the
module it resolved to, and the binding's slot there, written when the
module links. It compiles to `importBind`, which reads through them, so
a read sees the binding as it is, the hole (a ReferenceError) included;
a namespace re-exported by name (`export * as ns`) is held in a
one-slot array of its own. Assigning to an import is a TypeError, as
for any immutable binding. `import * as ns` binds the namespace object
of the module named, a constant once linked.

`export default <expression>` binds `*default*`, spelled by the
`default` keyword's span, which no program can name; `export default
function f` is a declaration of `f`, hoisted, and `export default class
C` binds `C`. An anonymous default function or class is named
`default`.

The compiler reaches what it does only for a module -- declaring its
imports, checking its redeclarations, recording its exports, hoisting
its exported functions, compiling its export statements -- through a
function argument of `compileFunction`, and a runtime has a module
compiler only once `installModuleCompiler` gives it one: a front end
that compiles only scripts links none of it. Such an embedder's
`__TEXT` grows by under 5 KB (the parser's module syntax and
`compileFunction`'s module branches; 10.7 KB before the split), a
bytecode-only one's by 1.2 KB (the runtime's `importBind` and the
marking of module records).

Module code is strict. Its early errors: a function declaration at its
top level is lexical, so it may not share a name with another
declaration or an import; an import may not be named `eval` or
`arguments`; a name is exported once; an exported name the module does
not bind, and a string export name with a lone surrogate, are errors;
`new.target` is not in a function.

## Linking and evaluation

Loading reads every module a graph names, breadth first, through the
runtime's loader, before anything is linked: a module that does not
parse, or one that cannot be found, fails the whole graph with nothing
run.

Linking calls each new module's function and takes its first step, so
every environment exists and every function declaration is made, then
resolves every import by ResolveExport: the module's own exports, then
its indirect exports, then its star exports, `default` never through a
star, and a name two stars provide differently ambiguous. An import, or
an indirect export, that resolves to nothing or to an ambiguity is a
SyntaxError, raised before any module runs; the graph's modules are
then new again, to be linked afresh.

Evaluation is the specification's depth-first walk, a module's
requested modules before it and each module once, the strongly
connected components of a cycle finishing together. A module that
throws fails, and so does every module still evaluating with it.

The namespace object has no prototype, is not extensible, carries
`@@toStringTag` "Module", and holds the module's exports that resolve,
in code-unit order. Each export is a writable, enumerable,
non-configurable data property holding the binding's value as it is
now: reading it, asking for its descriptor, `hasOwnProperty`,
`Object.keys`, and `for-in` all throw a ReferenceError while the binding
is uninitialized. Nothing about an export changes: a definition that
asks for what it already is succeeds and any other fails, `[[Set]]` and
`delete` fail, and so does `Object.freeze`. Underneath, an export is an
accessor whose getter holds the binding's environment and slot; a flag
on the object (`FLAG_NAMESPACE`) makes `[[GetOwnProperty]]`,
`[[DefineOwnProperty]]`, `hasOwnProperty`, and key enumeration present
it as the data property, at no cost to any other object.

## The loader

The runtime resolves and reads modules through a hook it holds, as it
reaches its compiler: given a specifier and the referring module's key,
the key it names and its source, or not found (a TypeError, "Cannot
find module"). The file loader (`engine/module_files.zs`), set by
`zjs_eval_module`, `zjs_eval_module_source`, and `zjsz`, resolves a
relative specifier (`./`, `../`) against the referrer's directory, takes
any other as a path as written, normalizes `.` and `..`, and reads the
file. node-style resolution is the embedder's. A runtime that never
loads a file links no file access.

## Later

- `import.meta`: an object per module, its `url` the module's key as a
  `file:` URL for a file.
- Dynamic `import()`: a promise for the namespace, the module loaded,
  linked, and evaluated as a static one is.
- Top-level `await`: a module's evaluation as an async function's,
  the walk waiting on the components it reaches.
- Bytecode files for modules: the format holds scripts only.

## Evidence

- test262: the runner runs a module test from its own file, so that its
  relative and self imports resolve, with the harness as a script
  included first (`zjsz run --include harness.js --module test.js`), and
  the curated subset now includes `language/module-code`, `import`, and
  `export`. Of their 318 runs, skipping top-level await and the
  proposals (import defer, attributes, text and bytes imports, source
  phase), all 318 pass.
- Expectation cases `module-live-bindings`, `module-cycles`,
  `module-reexports`, and `module-namespace-object`, recorded from node,
  each run twice (collecting at every safe point the second time).
- `tests/module_test.c`: the ABI's two entries, the cache, a module from
  memory importing files, and load, link, and evaluation errors.
- The Vite build of `ipodos`, which imports across its chunks: next.
