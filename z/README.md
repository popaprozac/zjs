# ZJS in Z

The Z rewrite of the ZJS engine. Design:
[`docs/superpowers/specs/2026-09-14-zjs-z-rewrite-design.md`](../docs/superpowers/specs/2026-09-14-zjs-z-rewrite-design.md).

`src/` (Zen-c) remains the shipping engine and the behavioral oracle. This tree
is built beside it, never on top of it.

## Status — Phases 4–5 in progress: the engine evaluates JavaScript

The loop works end to end: the **unmodified** `tests/test262_runner.c` links
against a Z-implemented `libzjs.a` and runs. It reports 0 passed, because no
JavaScript is evaluated yet. Every phase after this is about making that
number climb.

Phase 2 added the foundation the interpreter will sit on — NaN-boxed values
and a handle-based cell heap, with each context owning its own heap. 12 unit
tests via `z test`.

Phase 3: the lexer produces **byte-identical token streams** to the Zen-c
reference over the whole local corpus (24 files, 33,168 tokens,
`./z/oracle-tokens.sh`), and the parser produces **byte-identical ASTs** for
all 24 real files plus an 11-file synthetic corpus covering every construct
(`./z/oracle-ast.sh`). Both reference dumps link `build/libzjs.a` directly, so
the oracles need no Zen-c toolchain. The parser is ordinary Z throughout; its
one native call is `strtod` for decimal literals.

Phases 4–5, grown as vertical slices against a **behavioral oracle**
(`./z/oracle-eval.sh`: both engines evaluate a file and print a canonical
rendering of the completion value or uncaught throw): numbers with the
reference's int32 fast paths, strings as byte arrays with interning,
concatenation, number/string coercions and formatting, equality and ordering,
logical operators, `var`/`let`/`const`, assignment in all forms, `++`/`--`,
`if`/`while`/`do`/`for`/`break`/`continue`; functions, calls, recursion,
defaults, hoisting, the conditional operator; objects on hidden classes with
prototype chains (an object past 64 properties, or one that loses a property
other than its newest, moves to dictionary mode: pairs in insertion order
plus a hash index, constant-time lookup, insertion, and deletion, the same
ordering, attributes, and accessors, and no inline cache ever recorded for
it; deleting the newest property steps back to the parent class, so small
objects stay on the fast path; the threshold comes from the table below), arrays with holes, property access in every form, method
calls with `this`, `new` with `prototype`/`constructor`, `typeof`; the Error
family as Z builtins, `throw`, `try`/`catch`/`finally` with unwinding across
frames; closures -- captured bindings live in environment cells addressed by
slot, resolved at compile time through the scope chain, with arrows keeping
the `this` of their creation; block scoping -- a block, switch body, loop
head, or catch clause declares its `let` / `const` / `class` bindings when
it opens and drops them when it closes, an inner declaration shadows an
outer one only inside, a captured block binding lives in an environment
created at each entry (per iteration for a loop head), a lexical binding is
a hole until its declaration runs and a read that can reach it before then
checks and throws a ReferenceError (`typeof` included), assignment to a
`const` throws a TypeError, and `break` / `continue` / `return` / `throw`
out of a scope restore the environment on the way (an inlined `finally`
runs in its own scope); parameters with a default anywhere in the list
bind in order, each a hole until its turn, so a default that reads a later
parameter or itself throws; a function declaration in a block is the
block's own binding, created as the block opens (sloppy code also assigns
the function-scoped var, or global, when the declaration is reached, and
not at all when a lexical declaration of the name would conflict); a derived
constructor's `this` is uninitialized until `super()` returns: reading it
before that throws a ReferenceError (`typeof this` included, and through an
arrow created earlier, which sees the bound value afterwards), a second
`super()` runs the parent and then throws, fields initialize right after
the first, and a derived constructor's return follows the specification
(an object; else `this`, a ReferenceError if unbound, a TypeError for any
other primitive); template literals, `switch`, labeled
`break`/`continue`, `for`-`in` (keys in insertion order across the prototype
chain) and `for`-`of` over arrays, `in`/`instanceof`/`delete`, `++`/`--` and
logical assignment on properties, and `Object`. **34 of 34** corpus files
identical.

Phase 7, builtins, in progress. Builtins are Z modules under
`engine/builtins/`, each registering its functions in the runtime's
host-function table (Z function values with an any-thread contract) and
attaching them to the intrinsic prototypes -- the runtime module knows
nothing of them, so they call back into it, and through `callValue` into
JavaScript, with no import cycle. Landed: the Error family, `Object` and
its prototype's `toString` / `valueOf` / `hasOwnProperty` / `isPrototypeOf`,
`Function.prototype.call` / `apply`, `Array` with `isArray` and the core
prototype methods, `eval` (global scope), `parseInt` / `parseFloat` /
`isNaN` / `isFinite`, and `globalThis` as a real object whose properties
fall through to the globals table. ToPrimitive runs `valueOf` / `toString`,
so `"" + obj` and `obj + 1` follow user code. Top-level and sloppy-call
`this` are the global object. Then `Boolean`, `Number` (with `toString`
in any radix, `toFixed`, the `is*` predicates and constants), `String`
(the byte-string prototype: `charAt` through `split`, `replace` with a
string pattern), wrapper objects keyed by an unforgeable hidden atom, and
`Math` in full over the C library with a xorshift `random`. Then property
attributes: one attribute byte beside every slot, accessor cells for
getters and setters (object literals included), `[[DefineOwnProperty]]`
with its validation, own keys in specification order, extensibility flags,
strict-mode rejection of read-only writes; `Object`'s statics and `Reflect`;
`Function` compiled from source, `bind`, and host functions that are not
constructors. A function object's [[Prototype]] is separate from its
`prototype` property: it is Function.prototype unless a class heritage,
`bind`, or `setPrototypeOf` gave it another (null included), and
property reads and writes, inherited accessors (against the receiver),
statics, `super()` (the active function's [[Prototype]] when it runs),
`isPrototypeOf`, and `instanceof` all follow it; `Object.setPrototypeOf`
and `Reflect.setPrototypeOf` refuse a cycle or a non-extensible target,
one by throwing and the other by answering false. An own property of a
function hides the virtual `name` / `length` / `prototype` and whatever
is inherited, even when it holds undefined. A bound function is an
instance of one trampoline over [target, boundThis, arguments]. Whether
it was called or constructed comes from the construct protocol, which
hands a builtin its new target, never from the shape of `this`: a call
uses boundThis, a construct ignores it and constructs the target, with
the target as new target only when the new target was the bound function
itself. It is constructable exactly when its target is, inherits from
what its target inherits from, and has no `prototype` of its own (the
program may define one; construction never reads it). `length` comes
from the target's own `length` when that is a Number (infinity kept),
`name` from the target's `name` when that is a String, read in that
order. `instanceof` is InstanceofOperator throughout: a bound function
asks its target, a custom `@@hasInstance` included, and any other
callable's `prototype` is read each time and must be an object. An
array's [[Prototype]] can be changed too (it is kept under a hidden key
in the array's bag, so the collector reaches it through the array, and
an array never given one pays a single link check), and a prototype
chain may pass through arrays and functions as well as plain objects:
reads carry the receiver through all of them, a write asks the chain
for an inherited setter or a read-only property before creating an own
one -- for an absent index of an ordinary array too, which asks
Array.prototype and its ancestors as any assignment does, with push,
unshift, splice, and fill assigning and literals, map, from, and
defineProperty defining. That write takes a direct path only until any
non-array object anywhere has been given an element; the heap records
that when the property is made, whatever object it lands on, so a chain
replaced afterwards is covered, and once set it stays set. `in`,
`for`-`in`, `isPrototypeOf`, `instanceof`, and the
cycle check follow the same chain. A function written as an object
literal's method, getter, or setter has no [[Construct]] and no
`prototype`, like a class method; the parser records that on the
function's node, as internal metadata the AST dump does not print,
since `{ m() {} }` and `{ m: function () {} }` are the same tree shape
and the second stays an ordinary constructable function. The
`@@hasInstance` lookup is always made; when it finds the builtin (which
is neither writable nor configurable) the call is skipped for the
OrdinaryHasInstance it would have run. The
`arguments` object (an array tagged for
`Object.prototype.toString`, shared with arrows through the environment)
and rest parameters read the frame's actual arguments. `Symbol`: a symbol
is a cell whose property key is a hidden atom (0xFF, a counter) linked
back to it, so the property machinery is unchanged and the key is
unforgeable; the registry, the well-known symbols, `@@toPrimitive` with
the default hint for `+` and `==`, `@@toStringTag`, `@@hasInstance`, and
symbol keys last in `Reflect.ownKeys`. `JSON.parse` (a byte-level
recursive-descent parser with the reviver walk) and `JSON.stringify`
(`toJSON`, replacer function and allow-list, indentation, wrappers, cycle
detection). The iteration protocol: `for`-`of` drives GetIterator /
IteratorStep and closes the iterator on `break`, `continue` past it, and
`return`; spread in array literals, calls, and `new`; array iterators
(values / keys / entries, with an allocation-free step while `next` is
pristine), `String.prototype[@@iterator]`, `Array.from` / `of`.
Destructuring in every position -- declarations, parameters (with
defaults), catch parameters, loop heads, and assignment -- with nested
patterns, defaults, holes, rest elements, object rest, and computed keys,
through the iterator protocol for arrays. Control flow that leaves a
region undoes it on the way out: a `break`, `continue`, or `return`
pops the try handlers it crosses, runs the `finally` blocks it crosses
inline, and closes the `for`-`of` iterators it leaves; a throw inside a
`for`-`of` body closes the iterator too. Anonymous functions take the name
of the binding, property, or parameter they initialize (accessors with a
`get ` / `set ` prefix); only a function expression written with a name
binds it inside itself. Generators: a generator object is an ordinary
object holding a record under a hidden key; a call runs the parameter
prologue and suspends at GeneratorStart, `yield` copies the frame's
register window and open try handlers out, and `next` / `throw` / `return`
push a fresh frame and copy them back. `yield*` delegates in full: the
delegate's result objects reach the caller as they are, `next(v)` /
`throw(e)` / `return(v)` are forwarded to the delegate's methods (a
delegate without `throw` is closed and the throw becomes a TypeError; one
without `return`, or whose `return` finishes, makes the outer generator
return through its finally blocks), and a delegate that finishes on
`next` or `throw` hands its value to the expression. `return(v)` on a
generator suspended at a plain `yield` re-enters it and returns `v` through
its finally blocks (which may yield again or return something else); on an
unstarted generator it completes at once.
Keyed collections: `Map`, `Set`, `WeakMap`, `WeakSet` as ordinary objects
holding a record under a hidden key -- keys and values in insertion order
with a deleted marker, an open-addressed index hashed consistently with
SameValueZero, and the live count -- so iteration walks by position and
sees additions and deletions during the walk; `forEach`, the three
iterators (`Map Iterator` / `Set Iterator` prototypes), `Map.groupBy` /
`Object.groupBy`, `getOrInsert` / `getOrInsertComputed`, the Set methods
(`union` through `isDisjointFrom` over any set-like), and
`get [Symbol.species]` on `Map`, `Set`, and `Array`. `WeakMap` and
`WeakSet` hold their keys weakly: their entries live in the heap's weak
records, whose keys are marked only by other references and whose values
are marked once their key is (a key-indexed pending table completes the
ephemeron closure during the strong-root drain, one visit per entry in
any discovery order; a verification scan follows, then the atom rebuild
and the sweep), entries of dead keys
are dropped and the storage compacted in place, and a key must be an
object or an unregistered symbol (`Symbol.for` keys are refused; `get` on
anything else is undefined, `has` / `delete` false). See
`docs/weak-collections.md` for the model and its measured cost. Deleting a
global through the global object undefines the
binding. `Array.prototype` complete and generic: every method takes any
array-like through ToObject / LengthOfArrayLike and the property
protocol (lengths as doubles up to 2^53 - 1, `HasProperty` through the
prototype chain for holes and String wrappers), with ArraySpeciesCreate
for `map` / `filter` / `slice` / `splice` / `concat` / `flat`, a stable
merge sort over rooted heap arrays, `@@isConcatSpreadable`, the ES2023
copying methods, and `@@unscopables`; a real array's `push` / `pop`
keep their direct path. `new Array(n)` has no elements. Classes: a
declaration or expression compiles to a constructor function carrying
the class flags, a prototype object, and the members defined in source
order -- methods, accessors, statics, instance and static fields with
define semantics (computed keys evaluated once, at definition), static
blocks, and private names, which are fresh private-symbol keys held in
the class's environment slots and never appear as own keys. `super`
calls and property access go through the method's home object,
recorded when the method is defined (object-literal methods too);
`new.target` rides in the frame. A derived constructor starts with
`this` uninitialized until super() returns, and its instance fields are
defined right after each super(); a class constructor called without
`new` throws; methods are not constructors; a class's [[Prototype]] is
its parent, so statics inherit. Function values of class members are
fresh per evaluation. Anonymous class expressions take the name of what
they initialize; identifier names with unicode escapes decode (`l\u0065t`
names the identifier `let` and never opens a declaration).
Promises and async: a promise is an ordinary object holding a record
under a hidden key: state, result, reactions, handled. The reactions
slot holds nothing while nothing waits, the one reaction while one
does, and a list from the second on; a reaction is one cell carrying
the handler for each outcome, its destination, and the body an async
reaction resumes. A job is four values in a queue that reuses its own
storage, not a cell; the runtime drains the queue after each script,
before control returns to the host, and a job that has run holds
nothing. An async body hands its driver a value and a flag rather than
an iterator result, a suspension reuses the register array the last
one filled, and awaiting a value that is not an object queues the
continuation directly (the promise the specification wraps it in cannot
be observed, and the job lands in the same place). An async
function is a coroutine on the generator machinery: its call runs the
body to the first `await` and returns a promise; each await parks a
continuation reaction on the awaited value's promise; completion or an
uncaught throw settles the function's promise. An async generator
queues its `next` / `return` / `throw` requests on its record, each
with a promise; a `yield` awaits its value and answers the front
request, an `await` parks the body, and completion answers the rest as
done. `Promise.prototype.then` / `catch` / `finally`, `resolve` /
`reject` / `all` / `allSettled` / `any` / `race` / `withResolvers`,
species, `%AsyncIteratorPrototype%`, and `%AsyncGeneratorPrototype%`.
Promise construction is constructor-generic. A capability is the array
[promise, resolve, reject] that NewPromiseCapability fills by
constructing the chosen constructor with an executor of the engine's
own (length 2, callable once with functions); what the constructor
returns need not be a promise the engine made, so a reaction's
destination is either an engine promise, settled directly, or such a
capability, reached only by calling its two functions. `then` and
`finally` take their constructor from the receiver's species (every
read observable, in order); the statics take it from their receiver
and never consult species, look `resolve` up once, invoke each
element's own `then`, and close the iterator when a later step throws.
`catch` and `finally` go through `this.then`. Only the intrinsic
constructor is shortcut, since constructing it has no step a program
can see, and the call to its species getter is skipped while that
getter is the one the engine installed (it only returns its receiver;
the `constructor` read before it is always made); `await` and async bodies always use intrinsic promises, read
the awaited promise's `constructor` as PromiseResolve requires (a throw
there is thrown at the `await`), and never call a native promise's own
`then`. `Promise` itself makes its own object: the executor is checked
before the new target's `prototype` is read, and a plain call throws
whatever `this` is. A job that has run is released as the queue drains
and run-time builtins (resolving and element functions, bound
functions) share one host-table entry each, so a program that settles
promises indefinitely runs in bounded memory.
The `zjsz` tool supplies `console`. Optional chains: a spine of member,
element, and call links with a `?.` short-circuits as a whole through
one exit. A private name read or written on a value that lacks it
throws. Tagged templates: the site's template object -- the cooked
strings as a frozen array carrying a frozen `raw` array -- is built once
at compile time as a constant, so every evaluation of the site passes
the same object; a member tag keeps its receiver. `String.prototype`
gains `codePointAt`, `replaceAll`, `normalize`, `isWellFormed` /
`toWellFormed`, the locale case methods, `$`-pattern substitution in
`replace` / `replaceAll`, Unicode whitespace in `trim`, and spec position
clamping in `includes` / `startsWith` / `endsWith`; `String.raw` and
`String.fromCodePoint`. Strings are UTF-16 code units, as the
specification says: `length`, every index, `charCodeAt`, slicing, the
iterator (by code point), regular-expression captures and `lastIndex`,
JSON, and property keys all count units, and a lone surrogate is kept
as itself. Storage is one byte per unit when every unit fits in Latin-1
(so ASCII text costs what it did) and two bytes per unit otherwise,
with the narrow form canonical. The boundaries are explicit: source
text and host text come in as UTF-8 (a byte that is not UTF-8 becomes
the unit with its value; a string handed back to the parser by `eval`
or `Function` travels as generalized UTF-8 so a lone surrogate returns
as itself); host output goes out as UTF-8 with a lone surrogate written
as U+FFFD; the regex backend receives the storage as libregexp's 8-bit
or 16-bit mode, nothing transcoded. Case mapping covers ASCII and
Latin-1 plus the sharp s expansion; the full Unicode tables are not
here. The common `String.prototype` methods -- search, slicing, split,
replace with a string, case mapping, trim, repeat, padding, concat --
work on a narrow string's storage bytes directly and build a narrow
result in one pass; wide strings take the units path, same algorithms
generic over the element. `z/tools/alloc-attr.c` attributes allocator
calls and bytes to their calling sites (see `z/bench/alloc`), and
`z/tools/malloc-count.c` is a dylib to
`DYLD_INSERT_LIBRARIES` when counting allocator calls. `Date`: the time value lives in a hidden slot,
the arithmetic is the specification's over `f64`, the wall clock and the
local zone's offset and abbreviation come from libc through a three-
function C header the Z module imports directly, the Date Time String
Format and the `toString` / `toUTCString` forms parse back, and the whole
surface is there: the constructor's forms, `now` / `parse` / `UTC`, the
local and UTC getters and setters, the string forms, `toJSON`,
`@@toPrimitive`, and the Annex B `getYear` / `setYear` / `toGMTString`.
`EvalError`, `URIError`, `AggregateError` (its iterable kept as
`errors`), an options object's `cause` on every error constructor, the
`Error.prototype.stack` accessor over an error-data slot, and the four
URI functions over the byte strings. `RegExp`: the matcher is QuickJS-NG's
libregexp, the same vendored copy the reference uses, behind a nine-function
C adapter (`engine/native/zjs_regexp.c`) that the Z module `engine/regex.zs`
alone talks to; patterns are cached by source and flags (256 slots, least
recently used out, freed at context teardown), a compile failure is a
SyntaxError carrying libregexp's message, and the matcher's failures are
distinct RangeErrors (memory, step budget, stack budget; the stack floor
is real, the step budget is off unless the embedder sets one). The Z side
owns everything the program sees: literals (a fresh object per evaluation),
the constructor's forms, `exec` / `test` / `toString`, the flag getters,
`source` escaping, `lastIndex` as an own property, `@@match` / `@@matchAll`
/ `@@replace` / `@@search` / `@@split` with species, named groups, the `d`
flag's indices, `%RegExpStringIteratorPrototype%`, and the string methods'
dispatch through those symbols. Text: an all-ASCII input is matched as
8-bit units (identical to UTF-16 there); any other input is transcoded to
UTF-16 at the boundary with a unit-to-byte map, so classes, case folding,
dot, and the `u` flag see what the specification defines, and offsets come
back as bytes -- a boundary inside a surrogate pair rounds to the pair's
sequence. `yield*` in an async generator takes the operand's async
iterator (a sync one wrapped through `%AsyncFromSyncIteratorPrototype%`),
awaits each answer from the delegate's `next` / `throw` / `return` before
checking it, forwards what each resumption sends by its mode (a delegate
without `throw` is closed, its `return` awaited, and the throw is a
TypeError; one without `return`, or whose `return` finishes, makes the
generator return through its finally blocks), hands each delegate value to
the request as it is, and makes the delegate's final value the
expression's. A return request into a suspended async generator awaits
its value and re-enters the body in return mode, so finally blocks run
(they may await, yield, throw, or return an override); on an unstarted or
completed generator the value is awaited and the request settles with it.
`for await` iterates the same way.

`./z/test262.py` runs the reference's own test262 runner logic
(`scripts/test262/run.py`: harness assembly, strict/sloppy modes, curated
subset, classification) against both engines through matching command
lines, `z/build/zjs-ref` (public ABI) and `z/build/zjsz` (Z), and reports
the gap with the tests the reference passes and Z does not. Needs
`vendor/test262`. Measurements so far: `language/statements/if` 117 of the
reference's 121; `built-ins/Math` 614 of 618; `built-ins/Object` 5714 of
6244; `built-ins/Number` 578 of 582; `built-ins/Symbol` 130 against the
reference's 90; `built-ins/JSON` 224 of 224 -- with Z passing 18, 230,
64, 50, and 18 tests respectively that the reference fails. `built-ins/Map`
395 against the reference's 367, `WeakMap` 273 against 244, `WeakSet` 166
against 154, and `Set` 628 of 725, where the gap is the class syntax the
set-method tests are written with. `built-ins/Array` 5300 against the
reference's 5259 (`Array.prototype` 4894 of 5002, the rest `Date`,
`RegExp`, `Proxy`, and cross-realm tests). The largest remaining gaps are
the missing `Date` and `RegExp`, classes, and the rest of
`String.prototype`.

Phase 6, the collector: mark-sweep over the handle heap with stable handles.
Marking walks from the runtime's roots (registers, globals, frames, the
realm, compiled code's constants and property names); sweeping frees dead
headers onto a free list for reuse and compacts every live cell's slots into
another arena, so an object that outgrew its range leaves no permanent hole
and nothing outside the heap needs updating. That arena is sized once,
for the slots traced plus what the next cycle is expected to allocate;
while it is under about nine megabytes the two arenas change places at
every collection and neither is allocated again, and a larger heap sizes
a fresh one and frees the old. The handle table has an extent: when a
large table's survivors all sit in its lowest quarter a sweep cuts the
extent back to the highest of them, takes the handles above it off the
free list, and rebuilds a table left far larger than it needs, so a
collection after a burst costs what is alive. A sweep visits handles
from the top down, which lists what it frees highest first, so
allocation reuses the lowest handles and survivors gather low. A
collection is due after a number of cells allocated: twice what
survived the last one, and never fewer than 4,096 (see
[docs/allocation.md](docs/allocation.md) for what that floor costs and
buys). The atom table is weak. It runs
at instruction boundaries only -- returns and loop back edges -- so no value
is ever held only in a Z local across a collection. The ABI smoke test runs a
200,000-iteration allocating loop and checks the heap stays bounded.

Places the corpus deliberately steps around, where the reference is wrong and
the Z engine follows the specification: a property write to `undefined`
throws a TypeError (the reference drops it); `Error.prototype.message` is
`""` (the reference has no such property); `for`-`in` over a string visits
its indices (the reference visits nothing); a postfix `++` on a property
holding a string yields its numeric value (the reference concatenates);
`Map()` without `new` throws a TypeError (the reference returns
undefined); `Map.prototype[@@iterator]` is `entries` and
`Set.prototype.keys` / `[@@iterator]` are `values` (the reference makes
distinct functions); `Object.prototype.toString` on a collection iterator
reads its `@@toStringTag` (the reference says `[object Object]`); a
closure created inside `catch` sees the catch parameter (the reference
throws a ReferenceError); `eval` of a string literal holding a raw NUL
byte yields the three-byte string (the reference throws a SyntaxError);
`Array.prototype[@@unscopables]` exists (the reference has none);
`Array.prototype.join.call("abc", "-")` sees the string's characters
(the reference joins nothing); `new Array(-1)` throws a RangeError (the
reference returns an array); `new Array(3)` has no elements (the
reference fills them with undefined); an async function has no
`prototype` and cannot be constructed (the reference gives it one and
allows `new`); an async generator object inherits from its function's
`prototype` (the reference gives it another prototype); a named class
expression binds its name inside its own body (the reference does not);
a `super` property that is a getter runs with the instance as receiver
(the reference gets NaN); statics inherit through the parent
constructor (the reference finds nothing); a derived class's field
initializers run after `super()` returns and see what the base
constructor set (the reference runs them first); a class declaration
binds its name inside its own body, so a static block can refer to the
class (the reference leaves the assignment unmade);
`String.fromCodePoint(0x1F600)` is the four-byte encoding, equal to the
literal (the reference produces something else); `Date` keeps local
time (the reference has none), `Date()` called as a function returns a
string (the reference constructs), `getDay` / `getUTCDay`, `toJSON`,
`@@toPrimitive`, and the locale methods exist (the reference lacks
them), the string forms follow the specification and an invalid date
prints `Invalid Date` (the reference prints ISO or `[object]`), a
six-digit year carries its sign in `toISOString`, `2026-13-01` and
`T24:00:01` do not parse, a `+02:00` offset and a negative six-digit
year parse to the right instant, and the `toString` / `toUTCString`
forms parse at all (the reference differs on each); `"é".length` is 1
and every index, slice, and capture offset counts code units, `eval` of
a lone surrogate returns it, and `toUpperCase` maps Latin-1 letters and
expands the sharp s (the reference counts bytes and maps ASCII only);
an instance made through a bound function is an `instanceof` that bound
function, which asks its target (the reference says no);
the oracle's dump renders a string as UTF-8 with its byte length, so
well-formed text still compares, and the corpus keeps only cases whose
values agree with node; a RegExp's `toString`
gives `/source/flags` (the reference gives `[object]`), `source` escapes
`/` and is `(?:)` when empty, a bad pattern or flag string throws a
SyntaxError (the reference swallows it and never matches), `RegExp(re)`
returns `re`, named groups, `matchAll`, and the `@@`-methods exist, and a
non-ASCII input matches by code unit (the reference matches bytes, so `.`
takes one byte of a multi-byte character); the native error
constructors have `length` 1 (AggregateError 2) and their prototypes
carry `name` (the reference has 0 and nothing); `new AggregateError([])`
has an empty message and a non-enumerable `errors` (the reference has
`undefined` and enumerable); the URI functions have `length` 1 and throw
URIError on malformed input, and `decodeURI` leaves reserved escapes
as written (the reference has 0, never throws, and decodes them).

Performance, measured after classes with four micro-benchmarks (best of
three, release builds of both engines): the Z engine ran the integer loop
in 0.92 s against the reference's 0.41, calls 0.17 against 0.09,
constructing 0.52 against 0.25, and array methods 0.32 against 0.13. A
one-day spike then rebuilt the generated C by hand to find the costs
before changing the design: switch dispatch was worth 14 to 18 percent,
the bounds and overflow checks on every index 7 to 13 percent, and the
two-level instruction fetch a further few. The first and third landed in
Z (the opcode chain is a `match`, which lowers to a switch; register
arithmetic wraps; all installed code lives in one segment): the loop is
now 0.65 s, calls 0.14, array methods 0.29. Inline caches then went in:
each property name a function uses has one cache entry recording the
receiver's hidden class and where the property was found -- an own
slot, a slot on the direct prototype, or the class transition that adds
it, with the prototype chain (at most two objects, then null) recorded
so a later setter is noticed. Validation is by class, so nothing is
invalidated and a reused handle cannot alias. Constructing two million
objects went from 0.46 s to 0.23 s, ahead of the reference's 0.24; a
property-read loop from 0.59 to 0.34 (reference 0.19). The remaining
gap is per-instruction overhead -- about thirty instructions of loop,
fetch, checks, and dispatch around each opcode's own work. None of it
is a representation problem: the handle heap and the NaN-boxed values
stay. The checked-index cost and the field-borrow limitation are
recorded as compiler findings with the measurements.

Strings follow ECMAScript: `length`, indexing, slicing, capture offsets,
and every String method count UTF-16 code units, and a lone surrogate is
preserved. Storage is one of two forms behind the same interface: Latin-1
(one byte per unit, the canonical form whenever every unit fits) or UTF-16
(two bytes per unit); the reference counts bytes, which is why the eval
corpus keeps only cases whose values agree with node. Text has three
distinct roles and never crosses between them by accident: source text is
bytes end to end (the lexer, parser, and compiler read `Array<u8>`, `eval`
and `Function` hand their bytes to the parser as WTF-8, and the C API
copies the caller's bytes without validating them, so a script that is not
UTF-8 cannot abort the host); string values are code units, decoded from
UTF-8 at the source and host boundaries (a byte that is not UTF-8 becomes
the unit with its value) and encoded back to UTF-8 for the host with a
lone surrogate as U+FFFD (every conversion, slice, concatenation, and
builder reserves its known size up front, which took the ASCII string loop
from 0.62 to 0.46 s and its reallocations from 9.0M to 1.2M); and only
diagnostics for the host -- `zjsz`'s
throw line, log output -- decode to a Z `String`, replacing each maximal
invalid subsequence with U+FFFD so the result always satisfies String's
valid-UTF-8 invariant and is never mistaken for the original bytes.

Not yet: `RegExp.prototype.compile` and the legacy statics, `Promise.try`, `Object.prototype.__proto__` and `__proto__` in object literals, the `caller` / `arguments` poison accessors on Function.prototype, a callable %Function.prototype%, naming an object-literal function from a computed key, direct `eval` seeing the caller's locals, subclassing `Array`, a private name shadowed by an inner
class of the same spelling, `super()` from an arrow inside a
constructor, a function that needs more than 252 registers (operands
are a byte; it fails to compile, where the reference compiles it), and
the remaining builtins. A function declaration
evaluated more than once yields the same function object each time
(class members do not). The collector is stop-the-world and
non-generational; the reference's nursery is a later refinement.

```
$ ./z/oracle.sh
reference passed: 5   z passed: 0   gap: 5
```

## Dictionary mode: the threshold

One million property operations per cell, seconds, best of three, on
objects of N properties; `class` never leaves the hidden class, `dict`
always does. Uncached lookups (`hit`, computed keys), misses, and
enumeration are within noise of each other up to 32 properties and turn
in the dictionary's favour from 64, where class mode's chain walk grows
with N and passes a second per million at a thousand; a monomorphic
named access (`named`, the inline-cache path) stays about a quarter faster
in class mode at every size, and class mode holds half the slots. So
objects keep their class through 64 properties and leave it on the
65th.

| N | hit class | hit dict | miss class | miss dict | enumerate class | enumerate dict | named class | named dict |
|---|---|---|---|---|---|---|---|---|
| 16 | 0.117 | 0.112 | 0.250 | 0.236 | 0.185 | 0.101 | 0.088 | 0.075 |
| 32 | 0.146 | 0.127 | 0.376 | 0.161 | 0.131 | 0.110 | 0.059 | 0.075 |
| 64 | 0.170 | 0.127 | 0.592 | 0.390 | 0.241 | 0.065 | 0.058 | 0.073 |
| 128 | 0.257 | 0.124 | 1.068 | 0.188 | 0.414 | 0.059 | 0.064 | 0.071 |
| 1024 | 1.027 | 0.115 | 8.019 | 0.169 | 1.620 | 0.054 | 0.068 | 0.066 |
| 100000 | timeout | 0.297 | timeout | 0.426 | timeout | 0.109 | | |

Construction of a million properties' worth of objects: 0.09 s (class)
against 0.15 s (dict) at four properties, 0.58 against 0.15 at 128, a
timeout against 0.30 at a hundred thousand. Slots in use for a million
properties: about one per property in class mode, two per pair plus the
index in dictionary mode. Delete-and-reinsert is level across sizes in
dictionary mode and reaches 1.9 s at 16k in class mode. The runner is
`--dict-threshold` over generated files (bounded at 20 s per run).

## Embedding lifecycle

A context is an ARC class behind its own lock; the registry lock covers
lookup only, so independent contexts evaluate concurrently and freeing a
context destroys its runtime and native state once the last reference
drops. `docs/lifecycle.md` states the admission, destruction,
reentrancy, and initialization rules, the ABI placeholders, and the
evidence `z/tests/lifecycle_test.c` produces on every build.

## Layout

| Path | What |
|---|---|
| `engine/value.zs` | NaN-boxed value, JSC layout, handle-carrying cells |
| `engine/heap.zs` | handle-based cell heap: headers, slots, mark bits |
| `engine/lib.zs` | context registry and the C ABI exports |
| `engine/token.zs` | token kinds (order mirrors `src/token.zc`; numbering generated) |
| `engine/lexer.zs` | the lexer, idiomatic register, no `raw c` |
| `engine/ast.zs` | AST: one flat node shape, index-linked, order mirrors `src/ast.zc` |
| `engine/parser.zs` | recursive-descent parser, index-linked nodes, no raw pointers |
| `engine/bytecode.zs` | opcodes (order mirrors `src/bytecode.zc`), instructions, compiled functions |
| `engine/compiler.zs` | AST to bytecode; high-water register allocation |
| `engine/runtime.zs` | per-context state and the interpreter loop; coercions and comparisons |
| `tools/evaldump-ref.c`, `tools/evaldump-z/` | eval-result dumps from each engine |
| `tests/eval-corpus/` | behavioral corpus for the eval oracle |
| `tools/astdump-ref.c`, `tools/astdump-z/` | AST dumps from each engine |
| `tests/parse-corpus/` | synthetic corpus, one file per construct family |
| `tools/tokdump-ref.c`, `tools/tokdump-z/` | token dumps from each engine |
| `probes/` | executable acceptance cases for `docs/z-findings.md` |
| `shim/zjs_shim.c` | frozen-ABI shim: exact `zjs.h` signatures over the Z exports |
| `spike/` | Phase 0 measurements — see [`spike/RESULTS.md`](spike/RESULTS.md) |
| `tests/` | `loop_smoke.c` and a synthetic corpus for the oracle |
| `build.sh` | build the engine, shim, `libzjs.a`, and the runner |
| `oracle.sh` | run a corpus through both engines and diff |

## Commands

```sh
./z/build.sh                      # engine + shim + libzjs.a + runner (Stage 0 in $Z_LANG)
Z_BIN=<native z> ./z/build.sh     # the same, built by a native compiler binary (z/zc.sh)
./z/build/loop_smoke              # ABI round-trip assertions
./z/oracle.sh                     # differential oracle, synthetic corpus
./z/oracle.sh vendor/test262/test/language/expressions   # real corpus
./z/oracle-tokens.sh              # lexer oracle: diff token dumps, both engines
./z/oracle-ast.sh                 # parser oracle: diff AST dumps, both engines
./z/oracle-eval.sh                # behavioral oracle: diff eval results, both engines
./z/expect.sh                     # expectation cases recorded from node (z/tests/expect)
./z/gc-check.sh                   # collector checks on engine counters (z/tests/gc)
./z/probes/run.sh                 # z-lang acceptance probes (see probes/README.md)
Z_BIN=<native z> ./z/probes/native/run.sh   # programs Stage 0 accepts that a native compiler rejects
./z/spike/run.sh                  # Phase 0 measurements
./z/build/zjsz run [--dict-threshold N] [--stats] [--gc-stats] [--mem-stats] [--gc-floor N] [--gc-growth P] [--expose-gc] file.js
                                  # --dict-threshold: property count at which an
                                  #   object leaves its hidden class (measurement)
                                  # --stats: slots, cells, dictionaries, collections,
                                  #   weak entries cleared, ephemeron passes
                                  # --gc-stats: times every collection; prints their
                                  #   count, total, pause percentiles, cells and
                                  #   slots allocated, engine storage in use
                                  # --mem-stats: storage alive, in use, and held by
                                  #   capacity; the allocator's in use and reserved;
                                  #   resident and footprint now, and resident peak
                                  # --gc-floor, --gc-growth: the collection policy's
                                  #   floor in cells and survivor multiple in
                                  #   percent (measurement)
                                  # --expose-gc: a global gc() that collects (tests)

cd ~/code/z-lang && bun run z test ~/code/zjs/z/engine/heap.zs   # unit tests
```

The real corpus is not vendored:
`git clone --depth 1 https://github.com/tc39/test262 vendor/test262`.

## Two decisions already made, and why

**Contexts cross the ABI as handles, not pointers.** Contexts live in a
Z-owned `Array` behind a `Mutex`, published once through the manifest runtime
root. What the host receives is an index, cast into the opaque `ZjsContext*`
the frozen header promises. No raw pointer touches Z state. This is the same
choice the spike settled for heap cells, applied one level up.

**The interpreter will be written in ordinary Z, not `raw c`.** The spike
measured an `if`-chain interpreter in plain Z at **0.84× the C computed-goto
baseline** — faster than C, and faster than the same loop written as
whole-function `raw c` (0.99×). Dropping to C for the hot loop is the worst
trade available.

## Phase 1 compromises, since removed

Both were recorded in [`docs/z-findings.md`](../docs/z-findings.md); neither
survived into the embedding lifecycle (`docs/lifecycle.md`).

- `Engine` carried a vestigial main-bound field because `Once<T>` required a
  main-bound class. z-lang `bdd92241` accepts a compiler-proven shareable
  class; the field is gone and the generated header requires no main-thread
  proof and no release hook.
- The shim reported every thread as main and released inline. It now
  provides no hooks at all and asserts at compile time that the library
  needs none; the first ABI call may come from any host thread.
