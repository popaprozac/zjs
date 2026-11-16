# Speed and size levers

The plan for the first two goals in [goals.md](goals.md): the fastest
engine without a JIT, and small. Each lever below names what it changes,
the evidence for it, the kernels it should move, and what it does to
size. All of them are to be pursued; the order is at the end. Update a
lever's status in the same commit that moves it.

## The gap

`bench/speed`, `results/2026-10-16-matrix.json` (engine `2ce664c`, after
the JSON plans and parse keys, load 5), milliseconds per kernel, startup
subtracted, against the fastest engine without a JIT on each, and the
engine's figure the day before (`results/2026-10-15-dispatch-matrix.json`,
engine `62c8113`, load 4). JavaScriptCore's interpreter and V8 jitless are
measured in the same run; QuickJS and Hermes, not on the machine, are their
2026-09-29 figures (`results/2026-09-29-core.json`). Both engines' own
figures move from run to run with the machine's load, so compare the gaps,
not the milliseconds across runs:

| Kernel | zjsz | 2026-10-15 | Fastest jit-less | Engine | Gap |
|---|---|---|---|---|---|
| allocation | 15 | 14 | 22 | V8 | ahead |
| arrays | 70 | 68 | 84 | V8 | ahead |
| calls | 9 | 9 | 8 | Hermes precompiled | 1.1x |
| closures | 14 | 15 | 12 | Hermes precompiled | 1.2x |
| helpers | 16 | 17 | 22 | Hermes precompiled | ahead |
| json | 13 | 18 | 8 | JavaScriptCore | 1.7x |
| long-strings | 3 | 4 | 3 | JavaScriptCore | 1.2x |
| maps | 37 | 37 | 51 | Hermes precompiled | ahead |
| polymorphic | 9 | 8 | 17 | QuickJS | ahead |
| properties | 24 | 23 | 26 | JavaScriptCore | ahead |
| regexp | 20 | 20 | 16 | JavaScriptCore | 1.3x |
| strings | 8 | 8 | 10 | JavaScriptCore | ahead |

Over the twelve kernels the engine is 1.39 times faster than
JavaScriptCore's interpreter and 1.37 times faster than V8 jitless in the
same run, and about 1.9, 1.7, and 1.6 times faster than QuickJS, Hermes,
and Hermes on precompiled bytecode on their 2026-09-29 figures. Startup is
3.5 ms against 6.9 and 30.7.

Four kernels added on 2026-11-15 are not in this table:
`borrowed-methods` (names read off functions, and calls made through
`call` and `apply`), `method-shapes` (one name read off receivers of
several shapes), `prototype-chains` (names found past an object's first
prototype, or nowhere), and `array-methods` (the array methods that
take no callback, on 64 elements). The engine is behind V8 jitless and
JavaScriptCore's interpreter on all four, far behind on the last: on
`borrowed-methods` 1.42 times V8's time, 1.66 times JavaScriptCore's,
and 1.08 times QuickJS's; on `method-shapes` 1.08, 1.18, and 0.99; on
`prototype-chains` 1.17, 1.03, and 0.92; on `array-methods` 3.84, 3.77,
and 0.34 (`bench/gc/results/array-species.json`). When each was added
the figures were 2.78, 3.14, and 2.07 (`function-inherited-reads.json`),
2.41, 2.69, and 2.25 (`shared-loads.json`), 2.07, 1.69, and 1.51
(`prototype-chains.json`), and 11.64, 10.76, and 1.01
(`array-methods.json`).

The day before the margins were 1.28 over JavaScriptCore and 1.42 over V8
(geometric mean of engine time over zjsz time, within one run). Behind on
five: json 1.7x (was 2.4x) and long-strings 1.2x (JavaScriptCore), regexp
1.3x (JavaScriptCore), closures 1.2x and calls 1.1x (Hermes precompiled).
For size, the engine's minimal embedder is 0.77 MB of code (0.56 MB on a
core context); the
Hermes VM alone is 2.75 MB, with its compiler 3.34 MB (arm64).

## The levers

| Lever | Moves | Size | Cost | Status |
|---|---|---|---|---|
| Object model | properties, polymorphic, arrays, allocation, json | smaller | 2-3 days | attributes in shapes done; header, slot, and site-cache reads unchecked (properties -10%); slots beside the header measured at most -3%, not taken (`docs/heap-layout.md`); a shape a site's entry does not hold answered from a table all sites share (`method-shapes` -50%, `borrowed-methods` -35%); a name past the first prototype, or found nowhere, kept as a fact (`prototype-chains` -39%) |
| Allocator and collector | allocation, strings, json, maps, closures; memory | about even | 3-5 days | young generation done; minor collections cost what survives; full collections in slices (longest pause 1-2 ms where it was 6-55) |
| Call protocol | calls, closures, arrays, every callback | about even | 2-3 days | frame redesign waits on Z's cold mark; the dispatch loop as tail-called handlers done (calls -9%, helpers -8.5%, closures -7%) |
| Bytecode quality | all | about even | 1-2 days | calls, stores, loops, first inlining done |
| Built-in fast paths | json, strings, regexp, arrays, promises and async | small growth | 1-2 days each | JSON, strings, regexp, arrays done; promises and async under way (the promise and async loops -13 to -27% over two changes, the async ones -3 to -9% more over a third, await-fresh -19% over a fourth); names read off functions cached (`borrowed-methods` -15%); the array methods without a callback read elements in place (`array-methods` -58%); an ordinary array's species found without asking (`list.slice(1)` -77%) |
| Precompiled bytecode | startup, and all through better bytecode | much smaller, opt-in | 3-5 days | the format, its loader, and the ABI's calls done; a core context running bytecode links no front end, 393 KB of `__TEXT` against 573 KB (`docs/bytecode-files.md`); load time and the compiler's spare time next |
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
Measured before the next step (2026-09-29): the dispatch loop runs about
9 instructions a cycle, so time follows instruction count. A `mov` costs
about 35 instructions, a cached property read 92, a cached store 104, an
array element read 147 (loops differing by one instruction, instructions
retired). Of a property read's 70 past dispatch: 14 to read and test the
object's register, 11 for the header's bounds and tag, 22 to reach the
site's cache (the function table, then its cache array, each bounds
checked), 5 for the class, 11 for the slot (overflow and bounds checks),
4 for the hole test, 4 to write the result. Slots beside the header
would keep the same two dependent loads (the handle's record, then the
slot) and change only cache locality, which the kernels do not lack;
the costs are the checks and the dispatch (docs/z-findings.md: dispatch,
and checked indexing, which measured -6% to -13% unchecked). Tried and
dropped: all caches in one runtime table indexed from a dispatch-loop
local beside `codeStart` (properties +2.8%, polymorphic +4.5%: the local
costs more than the indirection it saves); moving 33 arms no kernel uses
(loose equality, `**`, iterator steps, TDZ checks, ...) out of the loop
to relieve its registers (4% fewer instructions, cycles level). Done
(2026-10-14): the heap's header reads, slot reads and writes, and a
property site's cache read skip their bounds checks (`uncheckedAt`,
still checked in a debug build): the engine reads only a reachable,
so live, cell's header, a full collection trims the header table only
above its highest survivor, a live cell's slots lie in the arena, and
installing a function gives each of its sites a cache. (The first
statement of this said the table only grows; it can shrink. A suspended
generator held its environment where tracing could not see it, the one
read of a dead cell found, fixed on 2026-10-15.)
In cycles over eight placements, three runs with no encode job running
(2026-10-15, load 6): properties -9 to -10%, allocation -7 to -9%,
polymorphic -6 to -8%, closures -7%, arrays -6 to -7%, strings -6 to
-7%, long-strings -4 to -6%, helpers -4 to -5%, json -3 to -4%, maps
-2%, calls and regexp level (the first runs, under an encode job, had
put long-strings +3 to +6%). libzjs.a -7 KiB.
The function table keeps its check: its element owns arrays, and
unchecked access is for elements without cleanup. Slots beside the header, one dependent load
instead of two, measured from the other side on 2026-10-15: one more
level in every slot access cost properties 2.5 to 3.3%, helpers 3.5 to
4%, closures 2%, polymorphic 1 to 1.6%, so the redesign it needs is not
worth it for speed alone (`docs/heap-layout.md`).
One name on several shapes (2026-11-15). A site's entry holds four
shapes of an own property and one of anything else, and a function's
sites of one name share the entry. So a method called on two classes'
objects took the general path at every other call or at every call (82
cycles a call at one site, against 36 for one class; 149 for two sites,
against 57), and an array's and a string's method of one name in one
function at every read (`list.indexOf` beside `text.indexOf`: 730
cycles, V8 87). What the general path finds it now also keeps in one
table for the runtime, 512 facts found by shape and name (12 KB, made
when the first is kept), and it looks there before it searches when the
site's entry is for another shape. A fact says what a site's entry says
and is checked against the receiver the same way, so it answers for any
site and nothing invalidates it. A plain object's class does not say
what its prototype is (every instance of a class with no fields of its
own has the root class), so the prototype takes part in where a fact is
kept. The handler is untouched; the look is in loadProp's general path.
A site keeps its entry while shapes take turns and gives it up to one
that has come sixteen times; a site of own properties takes the shape
beside its others while it has a place; a site that has recorded
nothing does not look, since a name it never finds would pay for the
look every time; and a site the table fails 255 times, less four for
each answer, stops asking. Over eight placements `method-shapes`,
written for this, is -49.6% and `borrowed-methods` -34.7%,
long-strings -2.2%, the other eleven kernels within 1.3%, `big-program`
+2.3% (`shared-loads.txt`, `shared-loads.json`). A method on two classes at one site now takes 51
cycles (V8 66, QuickJS 55) and at two sites 88 (V8 96); the array's and
the string's `indexOf` 183; a field on six shapes 28, from 58. Costs:
`big-program` reads one field off 4,000 shapes at one site, more than
the table serves, and such a read goes from 635 instructions to 660; a
function's inherited or computed name goes from 236 to 265, answered
now by the code that answers the table's facts; `__text` +3.1 KB. Tried
on the way: a place per shape without the prototype (two classes'
instances evicted each other, and the method call went from 83 cycles
to 101); a site of own properties sent to search for a shape the table
had, so that the search would add it to the site (splay +3.9% in
instructions: its loads and stores of `left` and `right` share entries,
a store writes over the entry, and each load after it searched for and
kept a fact the table had); stopping after 64 failures (a site's shapes
all fail once before any is answered, so a site of 150 would stop in
its first pass).
Names past the first prototype, and names found nowhere (2026-11-15). A
site recorded a name found on the object or on its first prototype and
nothing else. So a base class's method called on a subclass's object
was searched for at every call (59 cycles, against 36 for a method one
prototype away; V8 43), and so was a property an object does not have,
which code asks about all the time (`options.limit === undefined`: 114
cycles, V8 8). Both are now facts like the others: the object's class
and the class of each prototype passed, up to four, with the slot in
the last, or with nothing after the last. No handle is kept. A class
fixes that its object lacks the name or where it holds it; a read
follows the prototypes it finds, checks each one's class, and for a
name found nowhere that the last has no prototype. So the fact for one
subclass serves another whose prototypes have the same classes, and
nothing a program does to a chain has to find the fact: adding the name
anywhere on it changes a class the read checks, and changing a
prototype changes what the read follows. A site with no entry takes
such a fact as its entry; a site whose entry the handler answers from
keeps it, and the table answers. These reads are answered in the
general path, not the handler. Not kept: an accessor, a prototype that
is not a plain object in class mode, a chain of more than four,
anything read off the global object (which answers a name it lacks from
the global variables), and `length` on a wrapper. Over eight placements
`prototype-chains`, written for this, is -39.3%, async-gen -1.7%,
`borrowed-methods` -1.5%, regexp -2.0%, `method-shapes` +2.3%, the
other eleven kernels within 0.6% (`prototype-chains.txt`,
`prototype-chains.json`). The base class's method takes 42 cycles (V8
43, QuickJS 35), `hasOwnProperty` on an instance 52 from 104 (V8 18),
a property an object lacks 34 (V8 8, QuickJS 8). `borrowed-methods`
gains because a function's own entry is now answered before the rest of
the general path is set up (`f.call` 265 instructions to 257);
`method-shapes` loses because a read the table answers is 15 to 20
instructions longer, the code that answers having more to carry.
`__text` +1.6 KB; a fact is 32 bytes where it was 24, the table 16 KB.
Left: these reads still leave the handler (a pass of the read that
finds nothing is 300 instructions, of one that finds an own property
133), which is the distance to V8 on them; a name a function or an
array lacks is searched for on every read (1,023 and 1,065
instructions); and the search itself walks the class chain.

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
400,000 records alive under churn (`bench/memory`), peak resident
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
Growth in place (2026-09-29): a cell whose slots are the arena's last
range, allocated or grown since the last collection, grows where it is
instead of copying to a fresh range and abandoning the old; an array's
new capacity is filled with holes as it is pushed. A push loop now
copies nothing: arrays -5.7% over 8 placements, the rest within 1%;
arrays' peak memory 56 -> 36 MB.
Minor collections that cost what survives (2026-11-13, `bench/gc`). A
phase profile showed a minor collection spending 2.4 ns on every young
cell whatever survived, 95% of its time where little did, and scanning
every function's constants and every hidden class's name as roots (43 us
a collection on a program of 4,000 functions). Now its sweep leaves the
dead young cells alone: the free list's top moves back up over their
handles, the survivors' places in it are repaired, and the young cells
that own storage outside the arenas or are atoms are listed when they
come to, so only those are visited (0.47 ns a young cell). Its roots
skip the functions and hidden classes an earlier collection traced.
And when 60% of a young generation survives, the next seven are made
old untraced and the eighth is traced to see whether it still holds.
Together, cycles less startup over 32 workloads
(`bench/gc/results/final-incremental.json`): geometric mean -5.7%, fifo
-18%, the large heap -10.5%, the 4,000-function program -11%, closures
-9%, allocation -7.5%; over 8 placements allocation -7.6%, closures
-5.7%, no kernel slower beyond +0.4%; `__text` +1.3 KB; test262
unchanged.
Full collections in slices (2026-11-13). A full collection stopped the
program for a time proportional to the live heap: 6 ms at 0.4 million
cells, 35 to 55 ms at 1.3 to 6 million. It is now spread over the
collections that follow its start (heap.zs, Full collections): marking
in slices, with an old cell stored into an old one queued by the write
barrier's slow half; then the sweep, then the slide of the slot ranges,
each a slice at a time. A handle never changes, so the slide moves
ranges between slices with no forwarding and nothing for the program to
check. A heap one slice can mark is still collected whole. Longest
pause, before and after (`bench/gc/results/incremental-vs-kept.json`):
splay 47.2 -> 1.9 ms, old-to-young 13.4 -> 2.1,
frames 11.2 -> 1.4, the large heap 11.0 -> 1.4, fifo 6.1 -> 2.1,
then-chain 4.4 -> 0.7, and 53 -> 6.7 after a burst of two million
objects, where cutting the handle table back is still one step. Time
over those ten workloads is level (+0.2% geometric mean, least of 12
runs each). The cost is
memory: the cells made old while a collection runs are kept until the
next, so resident memory is 0 to 10% higher on most of them and 26 to
50% on the three with the highest turnover (fifo 55 -> 77 MB,
binary-trees 27 -> 41, old-to-young 80 -> 101); `--gc-slice 0` gives
the whole collection back. `__text` +5.2 KB; kernels within 1% over 8
placements except helpers -1.7%; test262 unchanged, also with a
collection every 64 allocations and 16 units of marking at each. The
collection's entry point is marked cold: grown, it had been inlined
into the loop back edge's safe point and cost polymorphic 7.7% and
properties 3.2%.
Left: every allocation pushes its slots one call at a time (Z has no
bulk append); growth that does not move (Z upstream: reserved address
space or remapping); cell headers are 20 bytes; a large array or table
is traced, and the small strings' bytes compacted, in one step; marking
is bound by cache misses (about 8 ns a cell, three times faster when
the heap is laid out in the order it is traced), which a prefetch hint
in Z would ease.

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
the dispatch loop, and properties and polymorphic lost 8-10%. Then an
ordinary call to a leaf runs it the same way, the leaf bit kept in the
function cell's header so the check costs a flag test: code calling
small helpers -22% (a helpers kernel, added for this), calls +3.6% and
arrays +2.6% (every call tests the flag, and the callback path now calls
the runner rather than inlining it).
Then a call to an
ordinary function (not a generator, not async, not a class constructor)
builds its frame inline, with no call on the way: calls -5.9%, closures
-3.6%, map/filter/reduce -4.7%, arrays -1.0%, the rest level.
Then (2026-09-29) a builtin checks once whether its callback is a leaf
and writes each call's arguments straight into the leaf's registers,
skipping the argument area and the per-call checks, and the runner
copies arguments only when they are elsewhere: arrays -7.8%,
map/filter/reduce -13.1%, sort -11.8%, the rest level. Then a walk roots
only elements a full call or a getter produced (map/filter/reduce -3.0%)
and sort reads a numeric comparator result directly (sort -6.1%). Left
against V8 without its JIT (millions of cycles, startup excluded):
map/filter/reduce 147 vs 122, sort 88 vs 80 (JavaScriptCore 79); an
indexed sum 54 vs JavaScriptCore's 40, a per-dispatch cost; filling by
push level with V8.
Measured before the frame redesign (2026-09-29): a fib call costs about
73 cycles here, 54 in QuickJS, 39 in Hermes; about 40 of ours is the call
and return. Tried and dropped: a dense per-function record of what a call
reads (calls -1.8%, closures -1.6%, arrays +1.6%); counting the argument
copy in u32 so clang does not set up a vector copy (level); the frame
push written into the dispatch loop's `invoke` arm (calls -6.3%, closures
-3.0%, but properties +5.2%, polymorphic +4.3%, helpers +3.8% on every
placement -- a larger loop allocates registers worse for every arm).
Frames on the register stack put more code in the loop still, so the
redesign waits on a way to mark the loop's rare arms cold (asked of Z,
docs/z-findings.md).

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

Splitting the rest measured 2026-10-15, in a copy of the generated C
(`bench/speed/thread-dispatch.py`): each of the loop's 105 instruction
arms a function of its own, ending in a tail call to the next
instruction's handler through a table, the loop's state in arguments.
In cycles over eight placements, three runs: calls -8.7 to -9.5%,
helpers -8.7 to -9.4%, closures -8%, strings -3.5 to -5%, allocation
-3.5 to -4%, properties -3.2 to -4%, arrays -2 to -3%, maps -2.2 to
-2.4%, json and regexp level to -1.8%, long-strings -4.6 to +0.5%,
polymorphic -0.0 to +1.8%; text +16 KiB; test262 unchanged
(`bench/speed/results/2026-10-15-tail-call-dispatch.json`). Two
conditions. The handlers need a calling convention that keeps the
loop's state in registers the helpers they call preserve (clang's
`preserve_none`): with the platform's own, sixteen threaded
instructions made calls 4% slower where `preserve_none` made them 10%
faster. And nothing else may call the arms' helpers: with the switch's
arms left in beside the handlers, the property cache's lookup lost
clang's single-caller inlining (properties +4%, text +48 KiB). The same
arms in one function, each ending in a computed goto, were 6 to 56%
slower on ten kernels (Tried and not kept, below), so the gain is each
instruction getting a register allocation of its own, not the dispatch
branch. Z can write neither form; asked of Z (docs/z-findings.md,
interpreter dispatch).

Done 2026-10-15 with Z's `dispatch while` (z-lang e75c8b0d), which lowers
a marked loop into those handlers itself and keeps the switch for C
compilers without `musttail` and `preserve_none`. Which locals a handler
takes in its arguments decides the speed. The engine's arms now set the
thrown value and `throwing`, or the result, and break right there. So no
instruction hands those on, and they stay out of the arguments: the
handlers take the runtime, the instruction, ip, codeStart, base,
frameIndex, fi, and the loop's record, as the prototype did. The
twenty `if (returned || throwing) break` checks they made dead are gone,
and so is `returned`. In cycles over eight placements, three runs, against
the unmarked engine: calls -8.6 to -9.4%, helpers -8.1 to -8.8%, closures
-6.3 to -7.3%, allocation -3.8 to -4.8%, properties -3.7 to -3.9%,
strings -3.2 to -4.6%, arrays -1.6 to -2.1%, maps -2.0 to -2.3%,
regexp -0.9 to -1.5%, json and polymorphic level; within noise of the
prototype; text +16 KiB; test262 unchanged
(`bench/speed/results/2026-10-15-dispatch-loop.json`). Built with the
switch instead, the same engine is level against the old one. The native
compiler lowers the loop the same way since z-lang 027dc49b: built
natively, threaded against its own switch build, closures -14.7%, helpers
-10.6%, calls -10%, polymorphic -7.7%, properties -7%, allocation and
strings -4% (`bench/speed/results/2026-10-15-dispatch-loop-native.json`).

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
Inlining (2026-09-28): Hermes's compiler inlines a small function a
scope declares and never reassigns (the `helpers` kernel's four become a
multiply, a compare, and two property reads in its loop: 22 ms to our
40). Now the engine's does too: a call to a function declared in a
function body, whose body is `return <expression>` over its parameters
alone (literals, operators, conditionals, property reads; 24 nodes at
most), whose name nothing in that function writes (no assignment,
update, pattern, loop head, other declaration, eval, or with), compiles
to the expression with the parameters bound to the arguments' registers.
helpers -42.3%, the rest level. Not yet: bodies with more than one
statement, functions that read the enclosing scope, calls through a
property.
Captured bindings (2026-09-28): `x += e` on a binding in an environment,
e a literal or a local in a register (so nothing it runs can change x
between the read and the store), is one instruction, and `return x`
just after a store to x returns the register it was stored from -- unless
a jump may land there, which the compiler now tracks. The closures
kernel's closure runs 2 instructions where it ran 5: closures -13.1%,
calls -2.6%, the rest level.
Counted loops (2026-09-29): an instruction costs about 35-50 machine
instructions before its own work, so the pairs the kernels run most
(counted over all eleven, weighted by each kernel's share) are the
candidates. A `for` loop whose update is `i++` and whose test is
`i < bound` -- a literal, another register binding, or such a binding's
`length` -- tests once ahead of the loop and steps and tests at the
bottom in one instruction; an array's or a string's length is read in
place. polymorphic -20.2%, properties -11.1%, arrays -5.6%, allocation
-2.9%, helpers and closures -1.9%, the rest within a point. Then
`(a + b) | 0` is one instruction (the kernels all accumulate this way,
so they gain more than most code will): polymorphic -14.5%, properties
-7.6%, helpers -6.1%, allocation -3.6%, closures -2.5%, arrays -2.4%,
strings -2.0%, maps -1.5%, the rest level. Tried and dropped: a
method call's lone local argument passed from its own register rather
than copied into the call's window (the copy is 30 of a builtin call's
~600 instructions; the extra select in the call arm cost the dispatch
loop 1% more instructions on a kernel with no calls). The builtin
itself was the larger part: a string method on a string receiver with
an int32 index skips its conversions (a charCodeAt loop 677 -> 514
instructions an iteration, strings -5.9%), and a Map or Set lookup
probes through slices (maps -1.9%; the rest of its cost is three
random reads per probe into tables of ten thousand entries). Then
`a[i].name` is one instruction: an array's element read in place and the
name through the site's cache (its own copy of the check, so the
dispatch loop's property read keeps its one inlined caller), anything
else both general paths: polymorphic -10.1%, the rest level. An object
literal assigned to a local is built in the local's register when nothing
can see it half-built (the literal does not name the local or call eval,
and no try in the function is open): allocation -2.6%, the rest level.
`a[k]` with k a small integer literal carries k in the instruction:
allocation -1.6%, the rest level. Tried and dropped: a string chain
naming its literal pieces and locals in words after concatN, so
`s += "item" + i + ","` runs 2 instructions where it ran 6 (0.8% fewer
instructions: copying the pieces in the cold handler costs what the
dispatches did, and an iteration is ~1,470 instructions, most of them
gathering and appending bytes one at a time and collecting the string
headers each step leaves -- work for the string representation, not
the bytecode).

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
Tried (2026-09-28): stringify caching each class's key list per call
(json -1.0%, within noise, dropped); quoting a narrow string through a
local array moved out of the builder, so its length stays in a register
(json +1.6%: the strings are short and the move costs more than the
bytes). What stringify spends is a call per byte: `putByte` is 60
instructions with the array's growth inside, which clang will not inline
at its 39 call sites, and a run of bytes cannot be appended at once (the
inline hint and bulk append asked of Z, docs/z-findings.md). Tried
(2026-09-29): comparing a parsed key with its atom's bytes in place, not
a call per byte (level: the samples moved into the comparison), and
widening the parse input to units through a slice (json -1%, within
noise); both dropped. Then (2026-10-14): parse reads a narrow text as
its bytes and appends a string body's plain run whole, which bulk append
in Z now allows (the bytes alone had cost more than they saved, above):
json -0.4 to -0.8% in cycles over three runs with no encode job (-1.1 to
-1.7% under one), 6.4% fewer instructions,
libzjs.a +2 KiB (`bench/speed/results/2026-10-14-json-narrow-parse.json`).
Then (2026-10-16): stringify writes an object in class mode from its
class's plan, made once per class -- the keys already quoted, the slots
their values are in, which hold accessors, whether the class wraps a
primitive -- where each object had pushed its key list and quoted each
key; a narrow string's runs without escapes go out whole; an int32,
string, boolean, or null property value is written without a
SerializeJSONProperty call of its own. json -13.5 to -14.3% in cycles
over eight placements, three runs (stringify alone -31%), the other
kernels within 1.5%, test262 unchanged
(`bench/speed/results/2026-10-16-json-stringify-plans.json`). What is
left of stringify is the per-byte Array push, which clang will not
inline at its many call sites while the growth is inside it.
Tried (2026-10-16), in the compiler: every generated Array's growth
moved into a cold out-of-line function, the room check left inline, and
`push` always inlined. json -3 to -5% over eight placements, but
properties +3 to +4% and strings +3 to +4% on every placement, helpers
+1 to +2.5%. Passing the array's address to the cold function had kept
local arrays in memory on the fast path (strings +6%); passing its
fields and taking the new storage back in registers fixed that, and
leaving `push` to clang did not help. Dropped: what the split moves is
clang's inlining elsewhere, not the cost of a push.
Then (2026-10-16): parse expects of each object the key its class last
moved on by, as a document repeating a shape names the same key next,
and compares the text with that class's name in place -- no copy, no
interning, no root, since a class and its name are never freed -- then
defines it through the transition; a string with nothing escaped is made
from the text's bytes; an int32 of up to 9 digits is read in one pass,
where it had been scanned twice through the parser's checks. json -13.8
to -15.3% in cycles over eight placements, three runs, the other
kernels within 1.5%, test262 unchanged, libzjs.a +2 KiB; parse alone
-31%, from 1.58x JavaScriptCore's interpreter to 1.10x
(`bench/speed/results/2026-10-16-json-parse-keys.json`). Tried: parsing
objects and arrays in functions of their own, so a scalar would not
need the registers they save -- clang inlined them back, identical
code; reading a scalar member without the recursive call -- clang kept
the new helpers out of line, parse +2.8%. Both dropped.
The engine retires about six instructions a cycle on json and on calls,
so fewer instructions buy little now unless they shorten a chain of
dependent loads.
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
String joins (2026-09-29): a `+` chain whose first piece is a string
literal (or whose second is, after a quiet first), with every later piece
a literal or a local in a register, is one instruction that converts the
pieces in order and appends them at once -- `s += "item" + i + ","` makes
one string where it made three; template literals join the same way, each
substitution made a string (ToString, not `+`'s default hint, which they
had used) as it is evaluated. strings -17.2% (its building loop -33%).
Split and join (2026-09-29): split searches a narrow receiver for every
separator in one pass and fills an array made at the pieces' count;
join reads an array's elements in place, and when every element is a
narrow string, a number, a boolean, `undefined`, or `null` (none runs
anything to become a string) gathers their bytes in one local buffer and
makes one string; anything else takes the general path from the start.
The builder's range copy moves its bytes to a local first, since an
array behind an `inout` reloads its length and data after every byte
pushed. Over 8 placements: split -19.8%, join -22.5%, strings -10.5%,
regexp -1.7%, the rest within 0.4%. Then a chain's pieces are copied
into the gather buffer as blocks, and indexOf tries a start only when
the needle's first and last bytes both match there: strings -2.3%,
indexOf -5.1%. Left against JavaScriptCore's interpreter (millions of
cycles, startup excluded): building 16.2 vs 11.8, split 7.2 vs 5.0,
join 4.4 vs 3.2, indexOf 2.9 vs 2.1.
Block copies (2026-09-30): Z now appends a run of elements in one call
(`Array.append`, with `values.slice(start, end)` for part of an array),
so every copy of string storage -- extending a concatenation's buffer in
place, arena and buffer copies, the join gather, number digits, UTF-16
unit copies -- is one capacity check and one copy. Kilobyte
concatenations and joins (the new `long-strings` kernel) -69.9% in
cycles over 8 placements; the other eleven kernels within noise
(-1.4..+0.8%), after the compiler copies runs of 16 or fewer inline (a
`memcpy` call for a few bytes had made `strings` +3.7%). `libzjs.a`
+4 KiB (1094 KiB). Results in `bench/speed/results/2026-09-30-append.json`.
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
Promises and async (2026-11-15). A sample profile of the promise loops
in `bench/alloc/workloads` put 70 to 90% of their time in the runtime's
own promise machinery, 10 to 31% in bytecode handlers, and 2 to 5% in
the collector. Five changes so far, the last two in how a function's
properties are read. `then` and `finally` skip the
`constructor` and species reads when no program could observe them, and
an anonymous builtin function takes its name from an atom the runtime
holds, where each had looked the empty string up (then-loop -13%;
combinators, await-suspended, and then-chain -5 to -6%;
`bench/gc/results/promise-species.json`). A promise is one cell whose
first four properties are its fields, where it was an object and a
record; and promises, generator objects, and iterator results are
allocated with a class made beforehand, where each had searched the
empty class's transitions for its first name and every access had found
the record by name (then-chain -18% and a quarter less memory, then-loop
-16%, combinators -15%, await-fresh -14%, async-gen -13%,
await-suspended -11%; the 32 workloads' geometric mean -3.2%;
`promise-fields.json`). Against V8's interpreter in that run: then-loop
from 1.58 times its time to 1.32, async-gen 1.52 to 1.32, await-fresh
1.45 to 1.25, combinators 1.22 to 1.04, await-suspended 1.14 to 1.02,
then-chain 0.89 to 0.73. A suspension saved each register through the
write barrier, whose slow half is a call for every store into an old
cell, and the saved array and the record of a body that outlives a
collection are old. The registers now go to the heap as one run under
one barrier decision (a young cell takes them as they are; an old one is
listed whole for the next minor collection; while a full collection
marks, each store takes the barrier as before), and the numbers a
generator's record holds are stored with no barrier, a collection
following nothing through them. Over eight placements: async-gen -8.8%,
await-fresh -6.6%, await-prim -6.0%, await-settled -5.2%,
await-suspended -3.4%, five kernels and two promise loops within 0.7%
(`promise-suspend-placements.txt`); in instructions the five lose 6.5
to 10.9% and no other workload moves by more than 0.6%
(`promise-suspend.json`). A read of a function's own property
(`Promise.resolve`, a class's static method) missed its site's cache
every time, the cache recording plain objects and what arrays and
strings inherit, and took the general path: 432 instructions for
`Promise.resolve` where a cached read on an object takes 105. A function
keeps its own properties in a bag, an object with a class, so the site
now records the bag's class and the slot, and a hit is a test of the
cell's tag, the bag, and one comparison: 142 instructions. Over eight
placements await-fresh -18.8% and combinators -3.1%; in instructions
-10.6% and -2.3%, and no other workload moves beyond what its own runs
differ by (`function-own-reads.json`, `function-own-reads.txt`). Against
V8's interpreter await-fresh goes from 1.22 times its time to 0.98.
`__text` grows 576 bytes. The names a function inherits from
Function.prototype (`call`, `apply`, `bind`) and the ones it computes
(`prototype`, `length`, `name`) took the general path as well: 353 to
541 instructions, and 1,441 for `Object.prototype`, three searches of a
builtin's many properties. For these the site records the class of the
function's bag (the root class for no bag), which fixes that the
function holds neither the name nor a prototype other than
Function.prototype, and with it the class of Function.prototype's bag
and the slot there, or which name to compute. They are answered in
loadProp's general path, which is now one function out of line that
also fills the cache: inlined in the handler they cost every cached
read 10 instructions, where this way the handler's own reads are 3 to 4
shorter. A read of these names takes 196 to 296 instructions. A kernel
written for them, `borrowed-methods`, is -15.1% over eight placements,
closures -2.2%, the other eleven within 1% (`function-inherited-reads.txt`,
`function-inherited-reads.json`). `__text` grows 704 bytes. That kernel
took 7,525 instructions a pass, 1,777 of them `Object.prototype` and
`Array.prototype` evicting each other from the one entry a function has
for a name, which the shared table ended (Object model, above): 6,200
now. Left: `apply` builds a list and enters a second interpreter loop
(1,612 instructions against 140 for the call written out), array
`indexOf` takes 99 cycles on two elements against V8's 24, and `bind`
is 6 times V8's; a read on a function that finds nothing
(`type.defaultProps`) walks to Object.prototype every time, 1,023
instructions; resuming copies the registers back one checked store at
a time; and a generator object still keeps its record in a second cell.

Array methods that take no callback (2026-11-15). A call to a built-in
costs what it should (`Math.abs` 37 cycles a pass, V8 31), so
`list.indexOf` at four times V8 was not the call. `indexOf`,
`lastIndexOf`, `includes`, `slice`, `concat`, and `reverse` took the
specification's steps for each element through the general property
paths: is the index there, read it, compare or define it, each step
converting the index to a key. 269 instructions an element in `indexOf`,
385 in `slice`, 411 in `reverse`; on 64 elements 8 to 25 times V8,
where the methods that take a callback, which already read in place,
are level with it. The six now read as those do: a present data
element comes from the heap, and a hole, an accessor, or a receiver
that is no array takes the steps as before, index by index, so an
accessor that changes the array as it runs is seen. `reverse` swaps in
place two present elements of an array with no flag set. Two int32s
are compared in the loop without a call. Over eight placements
`array-methods`, written for this, is -58.1%, `method-shapes` -14.2%,
`borrowed-methods` -6.5%, the other thirteen kernels within 1.0%
(`array-methods.txt`, `array-methods.json`). On 64 numbers `indexOf`
goes from 2,191 cycles to 455 (V8 72), `reverse` from 3,300 to 440 (V8
120), `slice` from 3,470 to 1,790 (V8 150), `concat` of two from 7,080
to 3,580; on three, `indexOf` from 134 to 51 (V8 32). `__text` +1.1 KB.
One cost found by the full run and removed: `reverse` had called
`heap.writableElement`, which the element store's handler had inlined
as its one caller, and fifo paid a call on every store (+0.9% in
instructions). Every `slice`, `map`, `filter`, `concat`, `splice`,
`flat`, and `flatMap` of an array first asked for its species: a read
of `constructor`, which is the first name Array.prototype was given and
so the far end of its class chain, then a call of the Symbol.species
getter, then a call of Array with an argument list made for it. About
600 cycles before anything is copied, four fifths of `list.slice(1)`.
For an ordinary array none of that can be observed, and the result is
an ordinary array. So it is made directly when the array has no named
properties of its own (no `constructor`, and Array.prototype for a
prototype), Array.prototype's `constructor` is still data holding the
intrinsic Array, and Array's Symbol.species is still the getter it was
installed with. Where `constructor` sits is remembered for the shape
Array.prototype has, so a prototype a program has added methods to is
searched once. `list.slice(1)` goes from 752 cycles a pass to 175 (V8
64) and `list.map(twice)` from 830 to 225 (V8 172); on 64 elements
`slice` from 1,780 to 1,180 and `map` from 3,490 to 2,730 (V8 2,480).
Over eight placements `array-methods` is -15.7%, the other fifteen
kernels within 1.5%; their arrays are long, and the saving is per call
(`array-species.txt`, `array-species.json`). `__text` +1.0 KB. Left,
from the same profile: a search is still a call to read each element
and 48 instructions an element, 6 times V8 on 64; `list.slice(1)` is
still 1,418 instructions for two elements; spread and `Array.from` of
an array run the iterator protocol for each element, 47 and 32 times
V8; `Object.keys` is 28 times V8 and over half of it is allocating and
freeing lists; `class X extends Array` makes instances that are not
instances of X.

**Precompiled bytecode.** Hermes compiles at the application's build
time and ships bytecode, so it pays no parse on the device and can
afford optimizing passes. As an opt-in for embedders, a bytecode format
the engine loads would let a runtime link without the lexer, parser, and
compiler, which are 29% of the engine (about 170 KB), and would let the
compiler spend more time on the bytecode above. Needs a versioned format
and a loader that validates what it is given. After bytecode quality, so
the format is not fixed too early. Done (2026-10-16): the format, a
writer, and a loader that refuses a corrupt, truncated, or mismatched
file with nothing added (`docs/bytecode-files.md`), behind
`zjs_compile_to_bytecode` and `zjs_eval_bytecode`; `zjsz run` loads a
bytecode file, and `--via-bytecode` runs source through the round trip.
test262 through the round trip: 53,330 tests, no outcome changed;
expectation cases 71 of 71. libzjs.a +32 KiB (the loader 14 KB, the
writer 7 KB). Bytecode is trusted input, as for QuickJS and Hermes:
proving an untrusted file's environment operands would put a verifier
in the runtime this lever shrinks. Then eval and the Function
constructor reach the compiler through the runtime, which a context
gets only when it compiles source or asks for one
(`zjs_install_compiler`), so a core context that only loads bytecode
links no lexer, parser, or compiler: `__text` 365,904 bytes against
548,148 for the same context running source (-33%), dead-stripped from
the same libzjs.a.

**Z upstream** (docs/z-findings.md). Appending one repeated value in a
single call landed 2026-09-30 with the run of elements (above): the heap's
fills use it (arrays -5.8%, allocation -3.7%, calls -1.9%, closures -1.8%,
maps -1.4% in cycles, `bench/speed/results/2026-09-30-fill.json`). Still open: locale-independent
conversion between numbers and text,
which would also replace the formatting passes above; build-time
selection, for opt-in features and platform code. The dispatch loop as
tail-called handlers landed 2026-10-15 as `dispatch while` (calls -9%,
Call protocol above). Two now measured as
worth several percent everywhere (2026-09-26): an inlining hint, since
clang will not inline even two-line helpers into the dispatch loop
(forcing five inline: calls -9%, properties, closures, and arrays -5%),
landed 2026-10-02 as `inline function` (calls -3.2%, helpers -3.6%,
properties -3.4% on top of the unchecked access below, text +3.8 KB,
`bench/speed/results/2026-10-02-inline.json`; `cold function` beside it,
with no use yet that measured a win); and unchecked element access where an invariant checked once makes the
per-access check redundant (every bounds check off: -6% to -13% on every
kernel; the register file and instruction fetch alone: properties -8%,
closures -6%, calls -5%). The second landed 2026-09-30 as `uncheckedAt`
and `uncheckedSet` inside `unsafe`, checked in debug builds: the register
accessors and the dispatch loop's fetches use it (properties -6.8%, calls
-5.9%, polymorphic -4.7%, closures -4.2%, arrays -3.5% in cycles,
`bench/speed/results/2026-09-30-unchecked.json`), and so do the call
paths' argument copies, frame register setup, and the leaf interpreter's
fetches (all of it against the same C with those checks kept: calls
-8.4%, properties -7.2%, arrays -5.7%, closures -5.4%, polymorphic -4.6%,
`bench/speed/results/2026-09-30-call-paths.json`). The fourteen register
and code accesses left checked -- generator save and restore, the
collector's roots, string joins, eval-var operands -- moved nothing in
the control with every check off.

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

- Second chances for a shape a site does not hold, three ways that
  lost (2026-11-15, the Object model passage on one name and several
  shapes): keyed without the prototype, an own-property site sent to
  search, and giving up after 64 failures. Before them, the reads on
  functions inlined in the loadProp handler: every cached read 10
  instructions longer (103 to 113).
- Testing for a cell before the write barrier's call (2026-11-15,
  `bench/gc/results/promise-suspend.json`, build `cells`). A number
  stored into an old cell calls the barrier's slow half only to return.
  With the test inline at every store the async loops lose 4 to 7% more
  instructions, and nearly every other workload gains 0.5 to 1.9%
  (allocation +1.9%, closures +1.2%, arrays +1.0%), 640 bytes of code:
  every store pays for the test. Storing a generator record's numbers
  with no barrier gave the async loops the same and cost the rest
  nothing.
- Collector settings and trims (2026-11-13, `bench/gc/results`). Other
  nursery sizes: 4K +1.2%, 8K +0.2%, 32K +0.7%, 64K +1.7% against 16K.
  Other growth multiples: 100% costs 2% for 15 to 30% less memory on
  old-garbage workloads, 50% costs 13.6%; 200% stays the default.
  Skipping minor collections until the next full one while most cells
  survive: frames +10.6% and half again the memory; making the young old
  untraced, sampled, replaced it. Strings marked without queueing and
  dead cells left unwritten by the full sweep: the sweep 25% faster,
  the slide 50% slower, level. A list of every old cell's slot range
  kept in arena order, so the slide needs no sort: an entry for every
  cell promoted cost 10% on fifo; the sort cut into slices replaced it.

- The interrupt poll's countdown (zjs_set_interrupt_handler) kept in a
  dispatch-loop local, which took the handlers' ninth argument register,
  rather than in the runtime (2026-10-15): properties +0.7% where the
  field costs +1.3 to +2.1%, but allocation +5.1 to +5.9% where the field
  costs +1.6 to +1.9%; with nine state registers pinned the allocating
  handlers have too few left
  (`bench/speed/results/2026-10-15-interrupt-poll.json`).
- A compact per-function record for calls (code range, frame size,
  `this` register, flags) apart from the function's code and caches, a
  frame entry without a separate fill loop, a return that reads the frame
  where it is instead of copying it out (2026-09-27): fewer instructions
  per call (fib 771 -> 694), no fewer cycles once the dispatch loop's
  layout changes were taken out; reordering the frame's fields alone had
  moved single kernels by 2-4% either way.
- Frames read and stored without per-access checks (`uncheckedAt`, the
  same invariant as the heap's: the frame array only grows and a frame
  is pushed only once it is full), 2026-10-14: every frame access in the
  runtime made calls retire 3.2% fewer instructions and closures 3.7%,
  but cycles moved -1% for them and +1 to +4% for properties,
  polymorphic, helpers, and allocation; the push and pop alone, level.
  The checks are predicted branches; what a call costs is elsewhere
  (`bench/speed/results/2026-10-14-unchecked-frames.json`).
- The call entry's argument copy counted in u32 with wrapping indices,
  so clang sets up no vector loop and checks no overflow per step
  (2026-10-14): calls and closures +2% in cycles and +2.3 to 2.5% in
  instructions, properties +8 to +18%, helpers +9%
  (`bench/speed/results/2026-10-14-call-entry-u32.json`).
- Each frame keeping its function's code start, so a call and a return
  resume without looking the function up, one dependent load fewer
  (2026-10-15): instructions down 1 to 3%, but in cycles on a quiet
  machine calls +1 to +3%, polymorphic and properties +3%, helpers +5%
  (`bench/speed/results/2026-10-15-frame-code-start.json`). Any change to
  the call and return arms moves the dispatch loop's register allocation
  more than the work it removes.
- Direct-threaded dispatch (computed goto), measured 2026-09-26 by
  rewriting the generated C by hand: slower on Apple silicon (polymorphic
  +39%, properties +24%, calls +6%). The cost is in what each
  instruction does, not in the dispatch branch. Again 2026-10-15, all 105
  arms over eight placements: properties +55 to +56%, helpers +45 to +46%,
  polymorphic +23%, closures +21 to +22%, allocation and calls +19 to
  +21%, arrays +11%, maps +10%, strings +6 to +7%, json and regexp
  within 1%; the loop's stack spills and reloads went from 363 to 860
  (`bench/speed/results/2026-10-15-computed-goto-dispatch.json`).
