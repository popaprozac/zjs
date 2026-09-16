# Embedding lifecycle: ownership model (proposal, for review)

Status: proposed at `c66731d`. Nothing below is implemented yet except the
probes it cites. The public ABI (`include/zjs.h`) does not change; what
changes is what the Z library does behind it and what the shim promises.

## What exists today

- One root, `Engine`, published through `Once<T>` and retained by the
  generated runtime (`target.runtime.initialize`). It holds
  `registry: Mutex<Registry>` and a field it never reads,
  `publicationEpoch: i32 on thread.main`, because `Once<T>` rejects a
  class that is not main-bound. That field makes the generated header
  demand a main-thread proof and an executor release hook.
- The shim (`z/shim/zjs_shim.c`) answers those hooks with
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

### Locking

An ABI call takes the registry lock only to look the context up and
retain it (the `match` copy in probe `rootprobe`, which Z accepts), then
releases it and takes the context's own lock for the work. Evaluations of
independent contexts therefore proceed concurrently on host threads --
each host thread enters through the generated wrapper's active-call
count, which Z documents as an ordinary supported entry. Measured on the
probe: two threads, two contexts, 200,000 locked increments each, no
serialization between them.

Same-context calls serialize on the context lock; a second caller waits.

### Destruction

`zjs_free_context` takes the registry lock, checks the generation, sets
the slot to `none`, bumps the generation, releases the lock. The `Runtime`
is destroyed when the last reference drops: immediately, or -- if another
thread is inside an evaluation holding its own retained reference -- when
that evaluation returns. Freeing twice, freeing a stale handle, and
freeing `NULL` are no-ops. Nothing is left in the registry but a `none`
and a generation.

### Reentrancy and callbacks

There are no host callbacks at the ABI today (`zjs_register_host_function`
is a placeholder); the only host functions are the ones the `zjsz` tool
installs in Z (`console`). The rule for when they arrive: a host callback
runs inside the context's lock and must not call an ABI function on that
same context (it would wait on its own lock). Calling into a different
context from a callback is fine. A reentrant "current context" path is a
later tier and will need a thread-owner check the first tier does not
have.

### Initialization and partial teardown

The shim initializes the Z runtime on the first `zjs_new_context`. If the
generated `zjsz_runtime_initialize` reports anything but `OK`, the call
returns `NULL` and the status is kept for `zjs_had_error`-style inquiry
(a shim-level accessor; the frozen header has none). Z has no fallible
allocation: an allocation failure inside the engine traps the process,
which the embedding contract states. A context freed while another thread
evaluates it is the destruction case above. `zjsz_runtime_shutdown` is
not reachable from `zjs.h`; the library is released with the process.

### Pending work

Promise jobs are drained at the end of every evaluation before control
returns to the host; a context never holds pending jobs between calls,
so destruction never discards them. There are no timers or host-driven
queues yet (`zjs_has_pending_work` / `zjs_next_timer_ms` are
placeholders).

## What Z blocks

- **G36**: `Once<T>` requires a main-bound class (Z0604), so the root
  cannot be the shareable class above; the generated header keeps
  `REQUIRES_MAIN_THREAD` and `REQUIRES_ENQUEUE_RELEASE`. Probe
  `shareable-once-root`, minimal, `COMPILER-REJECTED`. Until it lands the
  root keeps a main-bound field; the shim stops lying instead: it reports
  the real thread through `pthread_main_np()`, so initialization must
  happen on the main thread (a stated contract), and the release hook
  runs a finalizer inline on main or queues it for the next main-thread
  ABI call. Everything else in the model is implementable now: the probe
  compiles and runs with the vestigial field in place.
- Not a block, a pattern: an `Option<Context>` element cannot be returned
  from the lock callback directly (Z0204, a move out of the owner); the
  `match ... some(context) => Option<Context>.some(context)` spelling
  retains a copy and is accepted.
- Minor: the lock callback captures the source bytes by borrow, so the
  evaluation receives a second copy of the script (`sliceToBytes`, then
  `sliceBytes` inside the lock).

## ABI placeholders

The shim provides `zjs_new_context`, `zjs_free_context`, `zjs_eval`,
`zjs_had_error`, and nothing else of `zjs.h`. Of those, `zjs_eval` returns
`undefined` whatever the script produced: the engine's NaN-box layout is
not yet mapped onto `ZjsValue`, and the harness reads only `zjs_had_error`.
Everything else in the header -- value constructors and predicates, string
access, properties, globals, host functions, `zjs_call`, `zjs_throw`,
`zjs_get_error`, bytecode, modules, GC statistics, `process.argv`, timers
-- is unimplemented and calling it is a link error.

## Tests the checkpoint adds

`z/tests/lifecycle_test.c`, linked against `libzjs.a`, run by `build.sh`:

1. One thousand create / evaluate / destroy cycles; `mstats()` bytes in use
   after the cycles within a small constant of the value after the first.
2. Two host threads, one context each, evaluating concurrently ten
   thousand times; results checked; no shared state.
3. A stale handle after free: evaluate returns an error, no crash; a
   freed slot reused by a later context does not answer the old handle.
4. Free during evaluation: thread A evaluates a long loop, thread B frees
   the context, A completes and the context is destroyed after.
5. Promise jobs: a reaction queued in one evaluation is observed by the
   next; a context freed after a script that queued jobs leaks nothing.

## Acceptance mapping

| Target | Where |
|---|---|
| Free the actual Runtime | Destruction: the slot drops its reference |
| Independent contexts concurrent | Locking: registry lock for lookup only |
| Same-context rules explicit | Locking, Reentrancy |
| Real init / thread registration, no lying hooks | Initialization; G36 for the field |
| Init failure and partial teardown safe | Initialization and partial teardown |
| Cycles, contexts, jobs, callbacks exercised | Tests |
| ABI placeholders tracked | ABI placeholders |
| Stale comments updated | lib.zs and the shim, with the change |
