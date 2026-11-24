# Embedding

The public ABI (`include/zjs.h`) as the Z library implements it: how a
context lives and dies, what each kind of context holds, and what the
shim promises for values, calls, and host functions. `tests/lifecycle_test.c`
is the evidence and runs on every build.

## The model

### Ownership

```
Engine (ARC class, the library root; one field)
  registry: Mutex<Registry>
    slots: Array<Option<Context>>      one entry per handle index, none when freed
    generations: Array<u32>            bumped when a slot is freed; handles carry it
    freeSlots                          freed slots to reuse
    live, created, detached            the counters the lifecycle test reads
Context (ARC class; shareable because its one field is a Mutex)
  state: Mutex<ContextState>
    runtime: Runtime                   the heap and everything on it; its deinit
                                       releases the regex context and the lent
                                       string copies, and Z frees the rest
    hadError, lastResult, evalCount, interrupted
```

A handle is `(index + 1) | generation << 32`, cast into the pointer-shaped
`ZjsContext*` the frozen header promises. A stale handle (freed slot, or a
reused slot with a newer generation) is refused by every call.

### Admission and locking

An ABI call takes the registry lock only to look its context up and
retain it, then releases it and takes the context's own lock for the
work. That successful lookup is admission: an admitted call completes
with its own reference, including one still waiting for the context
lock, whatever `free` does meanwhile. `free` invalidates later lookups;
it is not cancellation. Evaluations of independent contexts proceed
concurrently on host threads (each host thread enters through the
generated wrapper's active-call count, an ordinary supported entry);
calls on one context serialize on its lock.

Handles are bounded: slot index plus one in the low 32 bits, the slot's
generation in the high 32, in a 64-bit host word (the shim asserts it).
A slot whose generation reaches its last value is retired, never reused,
so an exhausted generation cannot wrap and revive a stale handle. The
token is pointer-shaped only because the frozen header says
`ZjsContext*`; it is not a pointer, and that is a documented limitation
of the ABI, not of the model.

### Destruction

`zjs_free_context` takes the registry lock, checks the generation,
detaches the slot's reference (retaining a copy, setting the slot to
`none`, bumping the generation), releases the lock, and only then drops
the copy. So native cleanup never runs under the registry lock: the
`Runtime` and its regex context are destroyed by whichever reference
drops last, immediately or when an admitted evaluation on another thread
returns. Freeing twice, freeing a stale handle, and freeing `NULL` are
no-ops.

### Reentrancy and callbacks

A host function (`zjs_register_host_function`) runs inside its context's
lock, held by the call that is running the JavaScript that called it. A
zjs_* call it makes on that context must not take the lock again, and
does not: when JavaScript calls a host function, the engine calls it
through `zjs_host_call` (`engine/native/zjs_host.c`) and lends it a
closure over the runtime the interpreter holds, for the length of the
call. `zjs_host_call` keeps that service on a per-thread list of running
host calls (a pthread key, made by the first host call: a C thread-local
would cost every process that links the engine at launch), and the shim
sends every call on a context that has a host call running on this
thread through the innermost one (`zjs_host_call_for_handle`, and
`zjs_host_call_for_slot` for `zjs_string_bytes` and `zjs_array_length`).
A call on that context from another thread is not on the list, and waits
for the lock as any other does.

Inside a host function:

- Values, strings, properties, elements, globals, `zjs_call`, pins,
  roots, `zjs_register_host_function`, the interrupt handler, and the
  collector's calls work as outside. `zjs_get_this` is the receiver;
  outside a host function it is `undefined`. What `zjs_throw` was given is
  thrown when the function returns; outside one it does nothing.
- The error and result of its calls (`zjs_had_error`, `zjs_get_error`,
  `zjs_is_interrupted`) are its own: each host function starts with none,
  and the enclosing one's come back when it returns.
- `zjs_call` runs no promise jobs, and `zjs_drain_microtasks` does
  nothing: the jobs run when the call that entered the engine returns.
- The evaluators, `zjs_compile_to_bytecode`, and the installers are
  refused: they do nothing, and the error is a `TypeError`.
- An interrupt that stops JavaScript the host function called is its
  error (`zjs_is_interrupted` answers 1), and the termination goes on:
  nothing more runs, its `zjs_throw` is dropped, and the call that
  entered the engine ends interrupted.

Host functions nest: JavaScript a host function calls may call another,
on the same context or, through a context it evaluates, on another; each
call on a context finds that context's innermost host call. Two threads
that wait on each other's contexts can still deadlock (thread 1 inside
A's host function calls B while thread 2 inside B's calls A); that is the
embedder's to avoid.

### Initialization and teardown

The shim initializes the Z runtime on the first `zjs_new_context` or
`zjs_new_core_context`, under
a mutex: concurrent first callers wait; readiness is published only after
the generated runtime reports success; a failed attempt (an invalid
configuration) leaves later attempts possible, and `zjs_shim_init_status`
(shim-level; the frozen header has no lifecycle status) reports the last
attempt. The first call may come from any host thread: the root is a
compiler-proven shareable class (one `Mutex` field, contexts with
`deinit on thread.any`), so the generated header's
`REQUIRES_MAIN_THREAD` and `REQUIRES_ENQUEUE_RELEASE` are both zero, the
shim provides no hooks and asserts both flags at compile time, and a
worker-first embedding needs nothing from the main thread. Z has no
fallible allocation: an allocation failure inside the engine traps the
process, which the contract states. Shutdown and unload are not
supported through `zjs.h`; the generated runtime's `zjsz_runtime_shutdown`
closes the root on any registered thread and releases its strong
reference after unlocking (a context still retained by a running call
survives it), which the lifecycle test exercises directly, but nothing
in the frozen ABI reaches it, and no claim of complete unload is made.

### Pending work

Promise jobs are drained at the end of every evaluation and of every
`zjs_call` before control returns to the host. A property read or write
through the ABI can run an accessor that queues a job, and that job
waits: `zjs_has_pending_work` answers 1, and `zjs_drain_microtasks`, the
next `zjs_call`, or the next evaluation runs it. A job queued while a
host function runs waits for the call that entered the engine. A context
freed with jobs queued discards them. There are no timers
(`zjs_next_timer_ms` and `zjs_run_pending_timers` are not implemented),
so `zjs_has_pending_work` reports jobs only.

## Contexts and installers

`zjs_new_core_context` makes a context with the language and the builtins
it cannot do without: Object, Function, Array, String, Number, Boolean,
Symbol, Math, the error constructors, iterators and generators, and the
global functions. Each installer adds one family, and an embedder links
only the installers it calls:

| Installer | Adds |
|---|---|
| `zjs_install_json` | JSON |
| `zjs_install_regexp` | RegExp, and String's `match`, `matchAll`, and `search`; before it, a regular-expression literal throws a TypeError |
| `zjs_install_date` | Date |
| `zjs_install_collections` | Map, Set, WeakMap, WeakSet |
| `zjs_install_promise` | Promise; before it, async functions run, but their promises have no Promise methods |
| `zjs_install_reflect` | Reflect |
| `zjs_install_typed_arrays` | ArrayBuffer, DataView, and the typed arrays |
| `zjs_install_proxy` | Proxy, with the `get`, `set`, `has`, and `deleteProperty` traps; `new Proxy` throws a TypeError for a handler that has any other trap, and for a target that is a function |
| `zjs_install_compiler` | the source compiler, for `eval` and the `Function` constructor |

`zjs_new_context` is the core with every installer run. Installing a
family twice does nothing the second time. `zjs_eval` and
`zjs_compile_to_bytecode` bring the compiler to any context they run on;
a core context that only runs bytecode never has it, so there `eval` and
`Function` throw an EvalError and the embedder links no lexer, parser, or
compiler ([`bytecode-files.md`](bytecode-files.md)).
`tests/core_context_test.c`, run by `build.sh`, checks what a core context
has and lacks, what each installer adds, and that installing twice
changes nothing.

## Values

A `ZjsValue` has the engine's own bits for a number, a boolean, null, and
undefined, so the shim makes and reads those with no call into the
engine. A cell is the engine's handle with two things packed above it,
inside the 48 bits the header gives a cell: the slot of the context whose
heap it is in, and its kind (string, object, array, function, host
function). The kind makes the header's cell predicates bit tests; the
slot lets `zjs_string_bytes` and `zjs_array_length`, which are given no
context, find the heap. A context takes as `undefined` a cell that names
another context's slot, a handle outside its heap's table, and bits that
are the engine's own markers. Eleven bits hold the slot: a context past
the 2,047th slot exports its cells with no slot, so those two calls refuse
them, and another context cannot tell them from its own.

Lifetime is the header's: a value a call returned is good until the next
call on its context that can allocate, unless it is reachable from
JavaScript, pinned (`zjs_pin`, a stack), or rooted (`zjs_root`, a table
whose freed places are used again). Pins and roots are roots of every
collection. The engine cannot tell a handle whose cell has died from a
live one, so a value used past its lifetime reads whatever has the handle
now.

`zjs_string_bytes` returns a NUL-terminated UTF-8 copy that the context
owns, not a pointer into the heap: the engine keeps a string as bytes or
as 16-bit units, and a small string's bytes move when their arena is
compacted. The copy stays where it is for as long as the string lives.
The heap marks a string whose text was lent and lists it when it dies
(`lendString`, `lentDead` in `engine/heap.zs`); the copies of the dead are
freed before the next is looked up, and all of them with the context.

Text from the host (source and strings) is taken as bytes and not
validated, so a script that is not UTF-8 cannot abort the host: a byte
that is not UTF-8 becomes the code unit with its value. Text back to the
host is UTF-8, with a lone surrogate as U+FFFD.

`zjs_eval` and the other evaluators return what the program produced, or
`undefined` when it threw; `zjs_get_error` then returns what was thrown.

`tests/abi_values_test.c`, run by `build.sh`, is the evidence: every kind
of value out of an evaluation and back in, strings in UTF-8 both ways,
roots and pins across collections, 2,400 strings read with collections
between, a second context's values refused, and bits no call returned.

## Properties, globals, and calls

`zjs_get_property` and `zjs_set_property` read and assign as a program's
`obj.name` and `obj.name = v` do, outside strict mode: prototypes are
walked, accessors run, a number or a string answers through its
prototype, and a write that an object refuses (frozen, or made to a
primitive) does nothing. The name is UTF-8. `zjs_get_element` and
`zjs_set_element` are the same with the index as the key, so an object's
element 7 is its property `"7"`, and a write past an array's end
lengthens it. `zjs_get_global` and `zjs_set_global` read and assign a
property of the global object: a script's `var` and function
declarations are seen, its `let` and `const` are not.

Any of these can run JavaScript. What it throws, a property of `null`
or `undefined` included, becomes the context's error (`zjs_had_error`,
`zjs_get_error`) and the call answers `undefined`. One that does not
throw leaves the error of an earlier call as it was; only an evaluation
or `zjs_call` clears it.

`zjs_call` calls a function with a receiver and `argc` values at `argv`,
then runs the jobs the call queued, and returns the function's value. It
clears the context's error first. What the function throws, or a callee
that is not callable (a `TypeError`), is the context's error, and the
call returns `undefined`. The interrupt handler stops a call, and an
accessor a property read runs, as it stops an evaluation.

`zjs_gc` runs a whole collection. `zjs_cell_count` is the cells in the
heap now. `zjs_gc_collections` counts the collections completed, minor
and full. `zjs_gc_pause_ns_total` and `zjs_gc_pause_ns_max` are over
every stop the collector makes, of which a full collection done in
slices is several; the clock is read twice a stop to keep them.
`zjs_gc_cells_freed` is the cells made less `zjs_cell_count`.

A cell of another context is `undefined` to each of these, so reading
its property is the `TypeError` of reading `undefined`'s. A freed or
`NULL` context answers `undefined` or 0 and does nothing, and so does a
`NULL` name or a `NULL` `argv` with a nonzero `argc`.

`tests/abi_calls_test.c`, run by `build.sh`, is the evidence: properties
and elements of every kind set, read, and seen from a program; getters,
setters, and inherited properties; throws from each kind of call and
what clears them; calls with a receiver, no arguments, and three hundred
arguments; a call's jobs run before it returns and a getter's wait for a
drain; an endless call and an endless getter stopped by the interrupt
handler; twenty thousand objects given back and counted; and another
context's, a freed context's, and no context's values refused.

`tests/abi_host_test.c`, run by `build.sh`, is the evidence for host
functions: called from JavaScript with every count of arguments, spread,
bound, and passed to a builtin; their receiver and their throw; every
kind of call made from inside one, nested thirty deep through
JavaScript, with its own error; what is refused there; a job queued
inside that waits; strings read and collections run inside; a host
function registered from inside one; an interrupt inside one that ends
the evaluation and runs nothing after; and a host function that
evaluates another context whose host function reads the first.

## Not implemented

The shim provides the contexts and their installers, the evaluators and
`zjs_compile_to_bytecode`, `zjs_had_error` and `zjs_get_error`, the
interrupt handler, `zjs_version`, the values of the Values section (the
constructors, predicates, and unboxers, `zjs_new_string`,
`zjs_string_bytes`, `zjs_new_object`, `zjs_new_array`,
`zjs_array_length`, pins, and roots), the calls of the section above
(properties, elements, and globals, `zjs_call`, `zjs_drain_microtasks`,
`zjs_has_pending_work`, `zjs_gc`, `zjs_cell_count`, and the GC
statistics), and host functions (`zjs_register_host_function`,
`zjs_get_this`, `zjs_throw`; Reentrancy and callbacks). The rest of the
header is unimplemented, and calling it is a link error:
`zjs_next_timer_ms` and `zjs_run_pending_timers`;
`zjs_set_process_argv`; `zjs_new_minimal_context`,
`zjs_install_stdlib_extensions`, the `zjs_install_web_*` installers,
`zjs_install_node_net_globals`, and `ctx_register_stdlib_modules`.

## Evidence

`tests/lifecycle_test.c`, run by `build.sh` and linked against its own
build of the library (`tests/lifecycle/`, which adds the test-only gate),
with the library's counters as witnesses (`zjs_z_live_contexts`,
`zjs_z_created_contexts`, `zjs_z_detached_contexts`, and the native
`zjs_re_live_contexts`):

1. A thousand create / evaluate / destroy cycles: bytes in use after the
   last cycle within 2 MB of those after the first, native contexts back
   to zero, detached count exact.
2. Overlap, by synchronization: two evaluators on two contexts each
   pause at a test gate while holding their context lock, and the test
   observes both paused at once before resuming either. A timing line
   (one long evaluation against two at once) is printed, not asserted.
3. Serialization: two threads evaluating on one context, 400 evaluations
   adding to one global, the total exact, every evaluation counted.
4. Free after admission: the evaluator pauses at the gate after its
   lookup, retain, and lock; `free` then returns at once, the handle is
   stale at once, the native context is still alive; resumed, the
   evaluation completes and reports its result through its own reference
   (the stale handle cannot), and only then is the context destroyed.
5. Free before lookup (the other order): the evaluation is refused.
6. Stale handles: a reused slot answers only its new generation; double
   free and `NULL` are no-ops.
7. Promise jobs drain within the evaluation that queued them; a context
   freed afterward leaves nothing alive.
8. Shutdown on a worker: after 512 contexts were created and freed (the
   registry holds their slots), `zjsz_runtime_shutdown` on a third host
   thread returns OK, a later initialize reports shut down, bytes in use
   drop by the registry's size, native contexts stay at zero. Exported
   calls are only valid inside the published interval (the generated
   entry guard traps outside it), so the test asks the runtime's own
   status entries, never the library, before and after.
0. (First of all) Worker-first initialization: before any call, shutdown
   reports not initialized; the first ABI call, which initializes the
   runtime, runs on a host thread that is not main; it succeeds, the
   shim's status is OK, a second initialize reports already initialized.

The gate is `engine/native/zjs_testing.h` and the test-only export
`zjs_z_eval_gated`, neither part of the embedding ABI.
