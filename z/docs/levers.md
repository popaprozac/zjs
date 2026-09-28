# Speed and size levers

The plan for the first two goals in [goals.md](goals.md): the fastest
engine without a JIT, and small. Each lever below names what it changes,
the evidence for it, the kernels it should move, and what it does to
size. All of them are to be pursued; the order is at the end. Update a
lever's status in the same commit that moves it.

## The gap

`z/bench/speed`, `results/2026-09-28.json` (engine `4143c54`, load
3.8), milliseconds per kernel, against the fastest engine without a JIT
on each, and the first measurement of this plan
(`results/2026-09-26-hermes.json`):

| Kernel | zjsz | then | Fastest jit-less | Engine | Gap |
|---|---|---|---|---|---|
| allocation | 21 | 39 | 23 | JavaScriptCore | ahead |
| arrays | 106 | 167 | 83 | V8 | 1.3x |
| calls | 11 | 17 | 8 | Hermes, precompiled | 1.4x |
| closures | 22 | 35 | 13 | Hermes, from source and precompiled | 1.6x |
| json | 19 | 49 | 8 | JavaScriptCore | 2.4x |
| maps | 42 | 52 | 52 | Hermes, precompiled | ahead |
| polymorphic | 17 | 20 | 18 | QuickJS, V8 | ahead |
| properties | 36 | 46 | 25 | JavaScriptCore | 1.5x |
| regexp | 23 | 27 | 18 | JavaScriptCore | 1.3x |
| strings | 16 | 23 | 11 | JavaScriptCore | 1.5x |

Over all ten the engine is 1.33 times faster than QuickJS (QuickJS was
1.19 times faster when this plan began) and 1.27 times faster than
Hermes run from source, 1.24 precompiled (1.25 and 1.28 faster then);
JavaScriptCore's interpreter is 1.09 times faster (1.7), V8's 1.10
(1.9). For size, the engine's minimal embedder is about 0.70 MB of
code; the Hermes VM alone is 2.75 MB, with its compiler 3.34 MB
(arm64).

## The levers

| Lever | Moves | Size | Cost | Status |
|---|---|---|---|---|
| Object model | properties, polymorphic, arrays, allocation, json | smaller | 2-3 days | started |
| Allocator and collector | allocation, strings, json, maps, closures; memory | about even | 3-5 days | young generation done |
| Call protocol | calls, closures, arrays, every callback | about even | 2-3 days | started |
| Bytecode quality | all | about even | 1-2 days | calls, stores, loops done |
| Built-in fast paths | json, strings, regexp, arrays | small growth | 1-2 days each | JSON, strings, regexp done; arrays next |
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
until one is given any. Done so far: an object literal's property with
a name known at compile time defines through a cached transition at its
site (allocation -6.5%); JSON reads objects through their shapes. Attributes
now belong to shapes: a hidden class keeps its properties' attributes
and transitions are keyed by name and attributes; changing an existing
property's attributes replays the class chain with that one changed, so
slots stay put and objects reconfigured alike share the result (no
dictionary fallback, which prototypes with non-enumerable methods could
not afford). Dictionary objects keep attributes per pair; an array's
elements have the default ones unless a flag says a side table holds
them. The attribute byte per slot is gone from allocation, slot growth,
and collection, and a cache hit no longer checks attributes, since the
class it matched fixes them (loads never cache an accessor; a store
checks the attributes the entry recorded). Peak memory for 300,000 small
objects -9.6%. An object literal's property now has a cache of its own:
it had shared one with every read of the same name in the function, and
the two evicted each other every iteration (allocation -19%).

**Allocator and collector.** A cell is a header pushed into a table and
slots pushed into an arena one at a time; every string is its own
`malloc`, freed by the sweep; every collection marks and sweeps the whole
heap. V8 and JavaScriptCore allocate a young object by bumping a pointer
and let short-lived ones die cheaply. Evidence: allocation 39 ms against
V8's 20; `malloc`, `free`, and the sweep were 15-20% of the Map kernel.
A young generation, bump allocation, and strings stored in the heap are
the candidates; a different collector is in scope. Done so far: strings
of up to 256 bytes live in a byte arena, written in place and dropped by
not being copied, compacted only once it holds twice its live bytes
(strings -17%, maps -16%, regexp -8%); malloc and free went from 12-26%
of those kernels to 1-4%. A young generation (2026-09-26): minor
collections every 16,384 cells trace from the roots only into young
cells, sweep only the young ones, and slide the young slots and string
bytes still in use down their arenas; a write barrier lists an old cell
given a young one (a large cell by the slot alone). On a program keeping
400,000 records alive under churn (`z/bench/memory`), peak resident
memory 247 -> 117 MB (QuickJS 131, Hermes 67, JavaScriptCore 188, V8
240), 95th-percentile pause 20 -> 0.2 ms, total collection time about
even; on the speed kernels, interleaved medians of eleven runs at load
4.3: regexp -10.8%, allocation -4.6%, calls -2.1%, maps +2.7%,
polymorphic +1.8%, the rest within 1.1%. Finding the collector's
latent bugs took running everything with a collection at every safe
point; the expectation cases now always run that way too. The barrier has to
stay inside the C compiler's inlining budget for the slot store: one
bounds check more put it over (cost 225 of 225) and cost properties and
arrays 3%. Peak memory (2026-09-26): a full collection compacts in
place, sliding the survivors' slot ranges and string bytes down in arena
order, where it copied them into a fresh arena; the arena and the handle
table grow four times at a step. On macOS the allocator keeps a freed
large block resident, so each copy or move had cost the old block's size
for good: 117 -> about 100 MB on the large heap (67 with the allocator's
cache disabled, what Hermes uses; at 1.2 million records 339 -> 249).
Left: every allocation pushes its slots one call at a time (Z has no
bulk append); growth that does not move (Z upstream: reserved address
space or remapping); cell headers are 20 bytes.

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
is about a quarter of the time. Then (2026-09-27): a return from an
ordinary call (no generator, no object under construction) pops its
frame field by field instead of copying the whole record out, and a
frame's arguments are copied with indices clang can prove in range. In
cycles averaged over eight placements: calls -7.1%, arrays -2.7%
(map/filter/reduce -3.9%), closures -2.0%, maps, properties, regexp
-1%, allocation +2.7% and json +1.0% (both within their placement
spread); a `forEach` whose callback is one instruction +7.7%, since a
nested dispatch loop entered and left that quickly stalls on its own
epilogue. Measured then: a call and return cost about 40 cycles here,
28 in QuickJS, 35 in JavaScriptCore's interpreter. Tried
(2026-09-28): builtins that call back (map, forEach, reduce) keeping
their state in a continuation frame so each callback ran in the one
dispatch loop -- 7-11% slower on every such method, since a callback
from a builtin already costs about 74 cycles (QuickJS 81,
JavaScriptCore 101), less than a call from bytecode (89); the state in
registers cost more than the nested loop saved. The arrays gap to V8 is
per callback, not per nesting: sort makes as many comparisons as V8
(262k against 260k) at about 100 cycles each to its 56. What that
costs is entering and leaving the dispatch loop for a callback of two
or three instructions, so a leaf -- a function of straight-line
arithmetic, comparisons, forward branches, and cached reads, with no
call, store, loop, or `this` -- called back by a builtin runs in a small
loop of its own with no frame, and anything off its fast paths runs the
call in full from the start (nothing a leaf does is observable): arrays
-23.7%, map/filter/reduce -31.7%, sort -31.8%, the rest level, in cycles
over eight placements. Its property read checks the site's cache itself:
calling loadCached from a second place stopped clang inlining it into
the dispatch loop, and properties and polymorphic lost 8-10%.
Then a call to an
ordinary function (not a generator, not async, not a class constructor)
builds its frame inline, with no call on the way: calls -5.9%, closures
-3.6%, map/filter/reduce -4.7%, arrays -1.0%, the rest level.

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
instructions, maps -5%, the rest -3% or unchanged). Then (2026-09-27),
measured in cycles, since on this core fewer instructions did not by
themselves mean less time: `return t ? a : b` returns from each arm and a
conditional's test fuses with its branch (fib's base case runs 2
instructions where it ran 5); an instruction's spare byte became a fourth
operand, so a call names its callee's register and its arguments' first,
a method call its receiver's, and `new` its constructor's: a local callee,
receiver, constructor, or lone local argument is read where it is (the
closures loop runs 12 instructions where it ran 16); values stored into a
property, an object literal, or an environment, and the right operand of
a compound assignment, are read in place. Together, over the kernels:
calls -11.7%, closures -8.8%, allocation -5.6%, maps -4.0%, geometric mean
-3.5%. Left: string constants as operands; a method call's lone
argument, which still goes to its block. Fused branches for equality
(`===` and the rest in a condition, one instruction for two) were
written and measured: the four new arms in the dispatch loop cost the
kernels 1-3% (calls, closures, properties), more than they saved where
equality is tested, so they waited for the loop's restructuring (done
below).
Loops (2026-09-27): `while` and `for` test their condition at the
bottom, entered by one jump, so an iteration runs one compare-and-branch
where it ran a test and a jump back (that jump was 6% of the instructions
dispatched over the kernels). The fused branches take a flag in the
spare byte to jump when the comparison holds, so no arm was added, and a
backward branch taken is a safe point as the jump was. The dispatch loop
is left only by the instruction that returns or throws, rather than
testing for either, and for the end of the code, after every
instruction; then an instruction whose path ran no conversion and no
call (a load, a move, a jump, an int32 or cached-property fast path, a
strict-equality or boolean branch) goes straight to the next without the
check for a pending throw: polymorphic -9.7%, allocation -8.1%,
properties -7.5%, strings -1.8%, calls -1.4%, closures +1.6%. Then the
same for the arms that take a pending throw themselves (calls, globals,
`-`, `--`, element stores) and for allocation, with number fast paths
for `*` and `%`: arrays -2.9%, calls -1.8%, properties -1.6%,
polymorphic -1.4%. Over the kernels, in cycles averaged over eight placements
of the dispatch loop's code (a change to one arm moves every other, and
one placement alone swung a kernel by up to 12%): allocation -8.0%,
polymorphic -7.5%, properties -3.9%, closures -3.3%, arrays -2.3%,
strings -1.9%, json -1.4%, calls +1.3% (no loops; its branch now tests
the flag), regexp +2.3%. Then an operand literal takes 16 bits, the
instruction's spare byte its high half, and `*` and `%` take one too:
`(i * 7919 + round) % 10007` is three instructions where it was five
(arrays -4.4%, allocation -3.6%, maps -1.6%, the rest within noise).
Array literal elements compile into their slots (allocation -3.8%), and
`===` and `!==` in a condition compare and branch in one instruction,
against a register or a literal, with the jump-when-true flag serving
both operators and a loop's bottom, so two arms serve all four cases
(allocation -5.9%, properties -2.9%, polymorphic -2.2%, maps and
closures -1.2%). A closure is made from its function's constant by one
instruction, where a load of the function preceded it (closures -1.9%,
calls -1.3%).

**Built-in fast paths.** JSON was the widest gap (6x); stringify now
walks an object's shape with no allocation per object and parse caches
the transitions it takes (json 49 -> 28 ms, ahead of QuickJS and Hermes,
still 3.5x JavaScriptCore). Then (2026-09-27): stringify writes bytes
and widens only when a unit needs it (it had built units and narrowed
them at the end), reads a narrow string's storage in place, writes
`true` and `false` without an array each (an allocation per boolean had
been most of the gap), and skips the lookup of `toJSON` for a chain of
ordinary objects in class mode already found to have none; parse builds
a narrow string's bytes directly; the output buffer starts at the last
result's length. json -28% in cycles (stringify -38%, parse -14%).
Tried: parsing a narrow text as bytes, not units -- a branch per
character between the two forms cost more than the copy it saved.
Strings (2026-09-27): the byte-first builder JSON uses became a shared
one (`builtins/builder.zs`), which `join` now builds through where it
built units and narrowed them; `indexOf`, `includes`, and `split`
search the two strings' storage in place where they copied both; a
small string appended to a concatenation's buffer is copied from the
arena directly; `+` on two primitives skips the conversions an object
would need. strings -15% in cycles.
Regular expressions (2026-09-27): `replace` builds its result through
the same builder, reading the input where it is, and copies the input
to units only for a template with a `$`; a regular expression whose
class and prototype's class were seen with the builtin `exec` skips the
lookup of `exec` while the prototype's slot still holds it, and reads
and writes `lastIndex` and its flags at known slots. regexp -12% in
cycles.
Sort (2026-09-28): the merge sort merges each level from one buffer into
the other, copying nothing back, and joins halves of four or more that
are already in order after one comparison: sorted input takes 24k
comparisons for 20k elements where it took 139k (V8 20k), -53% in
cycles; random input level (1.6% more comparisons).
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

**Profile-guided optimization** (measured 2026-09-26, not yet a lever
with a place in the build). The generated C built with clang's
instrumentation, trained, and rebuilt with the profile: trained on the
speed kernels and the expectation cases, every kernel -7% to -19%
(binary +6 KB); trained on the expectation cases alone and measured on
the kernels, allocation -17% and maps -10% but regexp +15% and json +9%.
What it gives depends on a training set that stands for real programs,
which small correctness cases do not. It also answers the code-layout
noise that moves single kernels by up to 10% from unrelated changes.
Needs: a training corpus of realistic programs, and a way to pass the
profile through `z build` (or a build step compiling the emitted C).

## Order

1. Bytecode quality
2. Call protocol
3. Object model and allocator together, as one redesign of the heap
4. Built-in fast paths, JSON first, alongside the others
5. Precompiled bytecode and the runtime without a compiler

## Tried and not kept

- A compact per-function record for calls (code range, frame size,
  `this` register, flags) apart from the function's code and caches, a
  frame entry without a separate fill loop, a return that reads the frame
  where it is instead of copying it out (2026-09-27): fewer instructions
  per call (fib 771 -> 694), no fewer cycles once the dispatch loop's
  layout changes were taken out; reordering the frame's fields alone had
  moved single kernels by 2-4% either way.
- Direct-threaded dispatch (computed goto), measured 2026-09-26 by
  rewriting the generated C by hand: slower on Apple silicon (polymorphic
  +39%, properties +24%, calls +6%). The cost is in what each
  instruction does, not in the dispatch branch.
