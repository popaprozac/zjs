# Embedding lifecycle: ownership model

Status: implemented (review points incorporated); the root is
main-independent since z-lang `bdd92241`. The "what the scaffold did"
section describes what this replaced. The public ABI
(`include/zjs.h`) is unchanged; what changed is what the Z library does
behind it and what the shim promises. `tests/lifecycle_test.c` is the
evidence and runs on every build.

## What the scaffold did (replaced)

- One root, `Engine`, published through `Once<T>` and retained by the
  generated runtime (`target.runtime.initialize`). It holds
  `registry: Mutex<Registry>` and a field it never reads,
  `publicationEpoch: i32 on thread.main`, because `Once<T>` rejects a
  class that is not main-bound. That field makes the generated header
  demand a main-thread proof and an executor release hook.
- The shim (`shim/zjs_shim.c`) answers those hooks with
  `is_main_thread = always true` and `enqueue_release = finalize inline`.
  Both are placeholders, not facts about the host.
- Every ABI call holds the registry lock for its whole duration, the
  evaluation included, so two contexts never run at once.
- `zjs_free_context` marks the slot dead and releases the regex context;
  the `Runtime` (heap, atoms, functions) stays in the registry array for
  the life of the process. Handles are 1-based indices, never reused.
- `zjs_eval` returns `undefined` unconditionally; the completion value is
  reachable only as raw bits through `zjs_z_last_result_bits`.

## The proposed model

### Ownership

```
Engine (ARC class, the library root; one field)
  registry: Mutex<Registry>
    slots: Array<Option<Context>>      one entry per handle index, none when freed
    generations: Array<u32>            bumped when a slot is freed; handles carry it
Context (ARC class; shareable because its one field is a Mutex)
  state: Mutex<ContextState>
    runtime: Runtime                   the heap and everything on it
    hadError, lastResult, evalCount
    deinit: runtime.releaseNative()    the regex context; Z frees the rest
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

There are no host callbacks at the ABI (`zjs_register_host_function` is a
placeholder); the only host functions are the ones the `zjsz` tool
installs in Z. When callbacks arrive, a callback runs inside its
context's lock: an ABI call on that same context from within it would
wait on its own lock, and a call on another context can deadlock too
(A calls B while B's evaluation calls A, or two threads acquire two
context locks in opposite orders). The entry path will therefore refuse
a call on a context whose lock is held by the calling thread rather than
block, and cross-context calls from callbacks are not promised safe. The
owner check needs a thread identity the first tier of Z does not expose;
callbacks stay deferred until it does.

### Initialization and teardown

The shim initializes the Z runtime on the first `zjs_new_context`, under
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
next `zjs_call`, or the next evaluation runs it. A context freed with
jobs queued discards them. There are no timers yet (`zjs_next_timer_ms`
and `zjs_run_pending_timers` are placeholders), so
`zjs_has_pending_work` reports jobs only.

## What Z blocked

- **Shareable root** (resolved at z-lang `bdd92241`): `Once<T>` used to
  require a main-bound class (Z0604), so the root carried a main-bound
  field it never read and the generated header demanded a main-thread
  proof and a release hook. `Once<T>` now accepts a compiler-proven
  shareable class; the field, the shim's hooks, and the main-thread
  initialization contract are gone (probe `shareable-once-root`,
  `LANDED`; evidence 0 and 8).
- Not a block, a pattern: an `Option<Context>` element cannot be returned
  from the lock callback directly (Z0204, a move out of the owner); the
  `match ... some(context) => Option<Context>.some(context)` spelling
  retains a copy and is accepted.
- Minor: the lock callback captures the source bytes by borrow, so the
  evaluation receives a second copy of the script (`sliceToBytes`, then
  `sliceBytes` inside the lock).

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
are the engine's own markers. Eleven bits hold the slot, so the cells of
a context past the 2,047th slot are refused by those two calls.

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

## ABI placeholders

The shim provides the contexts and their installers, the evaluators and
`zjs_compile_to_bytecode`, `zjs_had_error` and `zjs_get_error`, the
interrupt handler, `zjs_version`, the values of the Values section (the
constructors, predicates, and unboxers, `zjs_new_string`,
`zjs_string_bytes`, `zjs_new_object`, `zjs_new_array`,
`zjs_array_length`, pins, and roots), and the calls of the section
above: properties, elements, and globals, `zjs_call`,
`zjs_drain_microtasks`, `zjs_has_pending_work`, `zjs_gc`,
`zjs_cell_count`, and the GC statistics. The rest of the header is
unimplemented, and calling it is a link error: host functions
(`zjs_register_host_function`, `zjs_get_this`, `zjs_throw`);
`zjs_next_timer_ms` and `zjs_run_pending_timers`;
`zjs_set_process_argv`; `zjs_new_minimal_context`,
`zjs_install_stdlib_extensions`, the `zjs_install_web_*` installers,
`zjs_install_node_net_globals`, and `ctx_register_stdlib_modules`.

## Evidence

`tests/lifecycle_test.c`, linked against `libzjs.a`, run by `build.sh`,
with the library's counters as witnesses (`zjs_z_live_contexts`,
`zjs_z_created_contexts`, `zjs_z_detached_contexts`, and the native
`zjs_re_live_contexts`):

1. A thousand create / evaluate / destroy cycles: bytes in use identical
   after the first and the last cycle (10,848), native contexts back to
   zero, detached count exact.
2. Overlap, by synchronization: two evaluators on two contexts each
   pause at a test gate while holding their context lock, and the test
   observes both paused at once before resuming either. The timing line
   (one long evaluation 1.37 s, two concurrently 1.40 s) is printed as a
   benchmark, not asserted.
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

Two Z findings came out of this, both in `docs/z-findings.md` and both
fixed upstream: the root had to be main-bound (probe
`shareable-once-root`; fixed at z-lang `bdd92241`, after which the root
lost its main-bound field and the shim its hooks), and a class stored
through a lock callback was never destroyed (probe
`lock-callback-capture-release`; fixed at `23bb4f73`, after which
contexts are built outside the registry lock again).

## Acceptance mapping

| Target | Where |
|---|---|
| Free the actual Runtime | Destruction; evidence 1 and 4 |
| Independent contexts concurrent | Admission and locking; evidence 2 |
| Same-context rules explicit | Admission and locking, Reentrancy; evidence 3 |
| Real init / thread registration, no lying hooks | Initialization; evidence 0 and 8; no hooks at all since the root is shareable |
| Init failure and partial teardown safe | Initialization; evidence 4 to 6 |
| Cycles, contexts, jobs, callbacks exercised | Evidence 1 to 7; callbacks deferred |
| ABI placeholders tracked | ABI placeholders |
| Values cross the ABI and outlive collections | Values; `tests/abi_values_test.c` |
| Properties, globals, and calls from C | Properties, globals, and calls; `tests/abi_calls_test.c` |
| Stale comments updated | lib.zs and the shim |
