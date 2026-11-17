# Call depth and native recursion

A call that would pass one of two limits throws a RangeError, "Maximum call
stack size exceeded", which a program can catch; the context goes on
working. Both are constants in `engine/runtime.zs`.

| Limit | Value | What it stops |
|---|---|---|
| `FRAME_LIMIT` | 10,000 frames | calls nested deeper than that, however the frames open: a call, `new`, a spread call, a generator or async function resumed, `eval`, a builtin calling back into JavaScript |
| `REGISTER_LIMIT` | 1,048,576 registers (8 MB) | an argument list of any length (a spread, `apply`, `Reflect.construct`, arguments a builtin passes on) placed further up the register stack than that: a recursion that spreads a long array into every call, or one call with that many arguments |

Neither is asked on a call that finds room: the frame limit only where the
frame stack has to grow, the register limit only where the register stack
does. The frame that passes the frame limit is opened, and sets the
interrupt countdown so that its first call or loop back-edge polls; the
poll throws. A frame's own registers (256 at most) are not held to the
register limit, so the register stack ends within 256 registers a frame of
it.

`tests/expect/call-depth.js` runs every kind of call past the limits, and
`tests/gc/call-depth.js` (under `gc-check.sh`) checks that the frame limit
stays where it is from one overflow to the next.

## The native stack

The same RangeError is thrown where the native stack runs short. A call
from one compiled function to another does not go down it; these do, and
each asks first (`Runtime.stackShort`):

| Recursion | Asked in |
|---|---|
| a call a builtin makes: a getter, a callback, a generator resumed, a bound function's target, indirect `eval`, the `Function` constructor | `callPlaced`, `constructValue`, `generatorResume`, `run` |
| a builtin over nested arrays and objects: `flat`, `JSON.stringify`, `JSON.parse` and its reviver (`join` and `String` go through `callPlaced`) | `flattenInto`, `serializeValue`, `parseValue`, `revive` |
| the parser and the lexer over nested source text | `parseStatement`, `parseAssignment`, `parseUnary`, `parsePrimary`, `parseBindingTarget`, `scanTemplateSubstitution` |
| the compiler over the tree, nested or built by the parser in a loop (`a + b + c + ...`) | `compileExpr`, `compileStmt`, `destructure`, `compileFunction`, and where a program's compile starts |
| libregexp's compiler and matcher | their own budget, 256 kB from where they were entered; on the stack the engine measured (`zjs_re_set_stack`), no further than half the reserve past the limit |

The question is one compare of the stack's address with a limit, not a
count of levels: a level costs from 0.2 kB (`flat`) to 3 kB (a function
nested in a function, in the compiler), and a thread's stack is 8 MB or
512 kB. The limit is the far end of the stack the call is running on, less
64 kB (`STACK_RESERVE`) for what runs under the last check that passed and
for raising the error. The same compare tells an address that is not on
the stack last measured, and the stack is then measured again, so a
context entered from another thread needs nothing from the embedder. Apple
platforms report a thread's stack (`zjs_host_stack_top` in
`engine/native/zjs_host.c`); elsewhere a stack is taken to start where the
engine first looks and to be 256 kB (`STACK_DEFAULT`). There is no setting
for the embedder.

The parser's checks of a finished tree and the compiler's scans, some
forty functions, recurse over the tree without asking. The tree's height
covers them: it is counted when the parse ends, by a pass that does not
recurse (`Ast.heightOf`), and the compiler's functions in the table ask
for room for a walk of a tree that tall, at 512 bytes a level
(`WALK_LEVEL` in `engine/ast.zs`; the largest frame among the forty is
336), besides their own. The parser asks the same before each walk of a
part of the tree (`Parser.walkShort`).

Deepest that works (arm64, Stage 0 build), by the stack it runs on:

| | 8 MB | 512 kB |
|---|---|---|
| a callback recursing through `map` | 4,998 (the frame limit) | 566 |
| `String` of nested arrays | 6,239 | 329 |
| `JSON.stringify` of nested arrays | 30,463 | 1,610 |
| `flat(Infinity)` | 43,157 | 2,283 |
| `JSON.parse` of nested arrays | 57,542 | 3,042 |
| nested parentheses | 9,243 | 485 |
| nested blocks, nested `if` | 8,925 | 468 |
| a chain of `+` | 7,612 | 399 |
| function expressions nested in each other | 1,697 | 88 |

Source text is refused sooner than the compiler's own recursion would
need: every level also leaves room for a walk of the whole tree, which
about halves how long a chain or how deep a nesting compiles.

Not covered: the walks over a module graph in `engine/modules.zs`
(`resolveExport`, `exportedNames`, `gatherAncestors`, `evaluateFrom`),
which go a level down for every module in a chain of imports.

`tests/expect/native-stack.js` nests data and source text past the limit;
`tests/stack_test.c` runs one context on the main thread, on a 512 kB and
a 256 kB thread, and on the main thread again, with every recursion in
the table and source at depths a tenth apart up to 100,000.
