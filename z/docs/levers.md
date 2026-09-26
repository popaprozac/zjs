# Speed and size levers

The plan for the first two goals in [goals.md](goals.md): the fastest
engine without a JIT, and small. Each lever below names what it changes,
the evidence for it, the kernels it should move, and what it does to
size. All of them are to be pursued; the order is at the end. Update a
lever's status in the same commit that moves it.

## The gap

`z/bench/speed`, `results/2026-09-26-hermes.json`, milliseconds per
kernel, against the fastest engine without a JIT on each:

| Kernel | zjsz | Fastest jit-less | Engine | Gap |
|---|---|---|---|---|
| allocation | 39 | 20 | V8 | 2.0x |
| arrays | 167 | 81 | V8 | 2.1x |
| calls | 17 | 8 | Hermes, precompiled | 2.1x |
| closures | 35 | 13 | Hermes | 2.7x |
| json | 49 | 8 | JavaScriptCore | 6.1x |
| maps | 52 | 49 | V8 | 1.1x |
| polymorphic | 20 | 17 | V8, QuickJS | 1.2x |
| properties | 46 | 25 | JavaScriptCore | 1.8x |
| regexp | 27 | 16 | JavaScriptCore | 1.7x |
| strings | 23 | 9 | JavaScriptCore, V8 | 2.6x |

Over all ten, QuickJS is 1.19 times faster than the engine, Hermes 1.25
(1.28 on precompiled bytecode), JavaScriptCore's interpreter 1.7, V8's
1.9. For size, the engine's minimal embedder is 0.69 MB of code; the
Hermes VM alone is 2.75 MB, with its compiler 3.34 MB (arm64).

## The levers

| Lever | Moves | Size | Cost | Status |
|---|---|---|---|---|
| Object model | properties, polymorphic, arrays, allocation, json | smaller | 2-3 days | open |
| Allocator and collector | allocation, strings, json, maps, closures | about even | 3-5 days | open |
| Call protocol | calls, closures, arrays, every callback | about even | 2-3 days | started |
| Bytecode quality | all | about even | 1-2 days | in progress |
| Built-in fast paths | json, strings, regexp, arrays | small growth | 1-2 days each | started |
| Precompiled bytecode | startup, and all through better bytecode | much smaller, opt-in | 3-5 days | open |
| Z upstream | all, 5-13% measured | smaller | upstream | filed |

**Object model.** A property read goes from the handle to its header in
one table, to its slots in the arena, to an attribute byte per slot in a
parallel array, with a bounds check at each step; V8 and JavaScriptCore
check the shape and load at a fixed offset. Attributes belong in the
hidden class, shared by every object of a shape, not in a byte beside
every slot; an object's slots can sit beside its header. Evidence: before
Map storage moved out of the arena, pushing attribute bytes was 13% of
number-keyed `Map.set`. Arrays could keep elements without attributes
until one is given any.

**Allocator and collector.** A cell is a header pushed into a table and
slots pushed into an arena one at a time; every string is its own
`malloc`, freed by the sweep; every collection marks and sweeps the whole
heap. V8 and JavaScriptCore allocate a young object by bumping a pointer
and let short-lived ones die cheaply. Evidence: allocation 39 ms against
V8's 20; `malloc`, `free`, and the sweep were 15-20% of the Map kernel.
A young generation, bump allocation, and strings stored in the heap are
the candidates; a different collector is in scope.

**Call protocol.** A call writes an 88-byte frame into one array and a
register window into another, and leaves the dispatch loop to reload the
new frame's state; a built-in calling back (`map`, `sort`, a comparator)
starts a nested dispatch loop. Keep the loop's state in locals across
calls and returns, give frames and registers one contiguous stack, and
let built-ins call back without nesting. Evidence: frame entry is a third
of `fib`; `sort` is a fifth of the arrays kernel, nearly all call
overhead; Hermes does calls in 8 ms to our 17. Done so far: the frame is
written once per call; an ordinary call and return switch frames inside
the dispatch loop instead of leaving it to reload the frame (closures
-20%, calls -7%). Measured 2026-09-26, callbacks from built-ins are not
the gap (`map` and `forEach` level with QuickJS, `sort` 1.2x); a plain
call is (1.7x QuickJS). In `fib` the frame protocol (enter, open, pop)
is about a quarter of the time.

The dispatch loop's shape belongs to this lever too. It is one large
function in the generated C, and the C compiler's register allocation
across it is fragile: adding one instruction's arm, which the kernel
never executes, made properties 20% and polymorphic 14% slower
(2026-09-26). The loop should keep only the hot instructions' bodies in
line, with the rest in functions of their own, so a new instruction
costs nothing where it is not used. Done: the forty rarely executed
instructions (generators, await, super, private names, spreads, rest,
arguments, delete, throw, regular-expression literals) run in a
function of their own; adding an unused instruction now costs 7% where
it cost 20%, not nothing.

**Bytecode quality.** The compiler emits one instruction per construct
and copies more than it needs to: the closures loop runs 14 instructions
an iteration, 5 of them copies into call slots or a reload of the loop
bound. Evidence: Hermes, whose optimizing compiler removes these, runs
closures in 13 ms to our 35. Done so far: immediate operands for
arithmetic, comparisons, bitwise and shift operators; fused
compare-and-branch, whose literal takes 24 bits; negated literals folded
to constants; `x op= e` into a register local as one instruction;
receivers, arguments, literals, unary results, `new`, and function
values compiled into their destination (strings kernel -25%
instructions, maps -5%, the rest -3% or unchanged). Left: the callee and
the arguments of a call copied into a contiguous block (a call form that
names its callee register), string constants as operands, stores into
environments straight from the source register. A method call cannot
look its method up after the arguments are evaluated (the specification
reads it first), so the fusion available is the receiver copy with the
lookup; tried as `getMethod`, it saved about 1% where it applied and set
off the dispatch-loop fragility under Call protocol, so it waits for the
loop's restructuring.

**Built-in fast paths.** JSON is the widest gap (6x): parse should reuse
the hidden class of the previous object with the same keys, stringify
should walk an object's shape instead of looking each key up.
ToString(Number) formats a double through up to 17 `snprintf` and
`strtod` passes. Regular-expression results still build every capture
string eagerly. Done so far: in-place element reads in the callback
walks, the inherited-method cache, string and number concatenation,
native Map and Set tables, JSON in one buffer, regular expressions that
build a match array only when a program sees it.

**Precompiled bytecode.** Hermes compiles at the application's build
time and ships bytecode, so it pays no parse on the device and can
afford optimizing passes. As an opt-in for embedders, a bytecode format
the engine loads would let a runtime link without the lexer, parser, and
compiler, which are 29% of the engine (about 170 KB), and would let the
compiler spend more time on the bytecode above. Needs a versioned format
and a loader that validates what it is given. After bytecode quality, so
the format is not fixed too early.

**Z upstream** (docs/z-findings.md). Appending a run of elements or of
one repeated value in a single call, for every allocation and copy the
heap makes; locale-independent conversion between numbers and text,
which would also replace the formatting passes above; build-time
selection, for opt-in features and platform code. Two now measured as
worth several percent everywhere (2026-09-26): an inlining hint, since
clang will not inline even two-line helpers into the dispatch loop
(forcing five inline: calls -9%, properties, closures, and arrays -5%);
and unchecked element access where an invariant checked once makes the
per-access check redundant (every bounds check off: -6% to -13% on every
kernel; the register file and instruction fetch alone: properties -8%,
closures -6%, calls -5%).

## Order

1. Bytecode quality
2. Call protocol
3. Object model and allocator together, as one redesign of the heap
4. Built-in fast paths, JSON first, alongside the others
5. Precompiled bytecode and the runtime without a compiler

## Tried and not kept

- Direct-threaded dispatch (computed goto), measured 2026-09-26 by
  rewriting the generated C by hand: slower on Apple silicon (polymorphic
  +39%, properties +24%, calls +6%). The cost is in what each
  instruction does, not in the dispatch branch.
