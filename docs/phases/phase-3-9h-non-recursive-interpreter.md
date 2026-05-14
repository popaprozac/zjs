# zjs Phase 3.9h — Non-Recursive Interpreter (Frame Stack Model)

> JS-to-JS function calls currently recurse through the C `interpret()`
> function. Each call pays C call overhead (prologue/epilogue, alloca,
> register init, root-frame push). For call-heavy workloads (fib,
> deep recursion, callback-heavy code) this is the dominant cost.
> This phase moves to a single outer loop with an explicit `CallFrame`
> stack — Op::Invoke and Op::Return manipulate the frame stack
> directly instead of recursing.

## Why

Bench measurement (2026-05-13):

| bench | zjs | qjs | gap |
|---|---|---|---|
| fib_recursive (depth 32, ~7M calls) | 152 ms | 106 ms | 1.4× |
| closure_call (200k iter) | 9.3 ms | 7.5 ms | 1.2× |

The remaining fib gap to qjs is per-call C overhead — qjs has a
single-loop interpreter; we recurse `interpret()` once per JS call.
Rough cost breakdown of one fib invocation in zjs:

| step | cycles (estimated) | mitigable |
|---|---|---|
| C function prologue + alloca | 5-8 | only by removing the call |
| arg copy | 1 per param | unavoidable |
| init remaining regs to undefined | 1 per slot | unavoidable (GC safety) |
| `ctx_push_root_frame` | 2-3 | replaceable |
| run dispatch loop | bulk | unchanged |
| `ctx_pop_root_frame` | 1 | replaceable |
| C function epilogue | 3-5 | only by removing the call |
| Op::Invoke caller-side teardown | 2-3 | unchanged |

7M fib calls × ~10 mitigable cycles = ~25 M cycles = ~8 ms on this
hardware. Realistic estimate for the gain on `fib_recursive`: 5-10%
(150 ms → ~140 ms). Smaller benches (closure_call, method_call) see
proportionally less because they call fewer times.

**The structural win, not just the perf number**, is what makes this
worth doing:

- **Tail-call optimization becomes natural** — a tail Op::Invoke
  reuses the current frame instead of growing the stack.
- **Inline call-site caching gains real value** — an Invoke IC can
  cache resolved callee + register layout because the dispatch is
  on the same loop; the type-tag dispatch we just measured to be
  net-negative would become net-positive because we'd skip more work.
- **Better debuggability** — a single C-level stack to inspect.
- **Step-debugger / source-map hooks** plug in cleanly at the outer
  loop's instruction-fetch point.
- **Coroutines / generators** later need this structure anyway —
  resuming a suspended generator means restoring its CallFrame
  onto the stack, which is incoherent if frames live on the C
  stack.

## Architecture

### CallFrame struct

```zc
struct CallFrame {
    f:                  Function*;       // the function this frame executes
    ip:                 usize;           // instruction pointer (frame-local)
    regs_base:          u32;             // start offset into ctx.reg_stack
    reg_count:          u32;             // size of this frame's register window
    return_dst:         u8;              // caller's reg to receive return value
    saved_host_this:    ZjsValue;        // restored on Return
    saved_current_closure: ZjsClosure*;  // restored on Return; NULL = plain fn
    try_depth_at_entry: u32;             // for throw unwinding
    finally_depth_at_entry: u32;         // (if we add cross-frame finally walking)
}
```

### Shared register stack

One per `ZjsContext` (or per top-level `interpret()` entry; TBD):

```zc
reg_stack:        ZjsValue*;   // grown geometrically
reg_stack_cap:    u32;
reg_stack_top:    u32;         // current high-water mark

frames:           CallFrame*;
frame_count:      u32;
frame_cap:        u32;
```

Each frame owns `regs[regs_base .. regs_base + reg_count]`. The GC
walks `reg_stack[0..reg_stack_top]` — one contiguous range instead
of N separate per-frame ranges.

### Shared try stack

Replace the per-frame `try_stack: TryFrame[32]` with a single global
try stack. Each `TryFrame` gains a `frame_index` field so unwinding
knows which frames to pop.

```zc
struct TryFrame {
    frame_index: u32;            // which CallFrame this try lives in
    catch_ip:    usize;          // local to that frame's function
    catch_reg:   u8;
}
```

`MAX_TRY_DEPTH` is now context-wide (raise from 32 to, e.g., 256).

### Outer loop shape

```zc
fn interpret(ctx: ZjsContext*, f: Function*, args: ZjsValue*, arg_count: u32) -> InterpretResult {
    // push the initial frame
    let entry_frame_index = ctx.frame_count;
    push_call_frame(ctx, f, args, arg_count, /* return_dst */ 0);
    defer pop_call_frames_to(ctx, entry_frame_index);

    let throwing: bool = false;
    let thrown:   ZjsValue = zjs_undefined();

    while ctx.frame_count > entry_frame_index {
        let frame = &ctx.frames[ctx.frame_count - 1];
        let code  = frame.f.code;
        let regs  = &ctx.reg_stack[frame.regs_base];

        // Inner loop — runs until this frame's function returns or throws
        let do_continue: bool = true;
        while do_continue && frame.ip < frame.f.code_len {
            // GC poll moved off hot path (3.9e)
            // Throw unwinding here

            let inst = code[frame.ip];
            // ... dispatch table ...
            //
            // Op::Return: pop frame, write return value to caller's dst,
            //             break out of inner loop → outer loop sees fewer frames.
            // Op::Invoke (JS callee): push new frame, break out → outer
            //             loop will see the new frame next iteration.
            // Op::Invoke (host callee): synchronous, like today.
            // Anything else: do its work, frame.ip = frame.ip + 1, continue.
        }

        // Inner loop exited because frame is done, threw, or transferred
        // control to a new frame. Outer loop's `while ctx.frame_count > ...`
        // condition handles the rest.
    }

    return InterpretResult { is_throw: false, value: ctx.reg_stack[/* result slot */] };
}
```

Important: the inner loop hoists `code` and `regs` into locals at
frame entry. This is exactly how `interpret()` works today — those
locals stay in CPU registers across the dispatch. The Op::Invoke and
Op::Return handlers must **invalidate** these by breaking out of the
inner loop, so the outer loop can re-fetch them for the new top frame.

### Op::Invoke (JS callee — Function or Closure)

```
Resolve callee from regs[base].
If host function: call synchronously like today.
Else (JS):
    Compute argv_ptr = &regs[base + 1]
    Save host_this and current_closure into a SCRATCH area (or directly
        into the *new* frame's saved_* fields — see below).
    Set host_this = undefined (Invoke) or regs[base+1] (MethodInvoke)
    Set current_closure = cl (if closure)
    push_call_frame(ctx, target_fn, argv_ptr, argc, return_dst=dst)
    The new frame's saved_host_this / saved_current_closure are
        what they were BEFORE we changed them.
    Set frame.ip += 1 for the OUTER (caller) frame BEFORE pushing,
        so when the new frame returns, the caller resumes at the
        right instruction.
    break out of inner loop.
```

### Op::Return

```
Capture return value = regs[inst.a].
Restore ctx.host_this = current_frame.saved_host_this.
Restore ctx.current_closure = current_frame.saved_current_closure.
pop_call_frame(ctx) (also shrinks reg_stack by reg_count).
If frame_count == entry_frame_index, this was the top frame — set
    `final_result = return_value`, exit outer loop.
Else: write return value into NEW top frame's regs[return_dst].
    break out of inner loop.
```

### Throw unwinding

`throw` (or any handler that sets `throwing = true`) breaks the inner
loop. The outer loop checks for an unhandled throw:

```
if throwing {
    // walk back through the try stack
    while ctx.try_depth > 0 {
        let tf = &ctx.try_stack[ctx.try_depth - 1];
        // pop frames above tf.frame_index
        while ctx.frame_count > tf.frame_index + 1 {
            restore host_this / current_closure from top frame
            pop_call_frame(ctx)
        }
        ctx.try_depth -= 1
        let new_top = &ctx.frames[tf.frame_index]
        new_top.ip = tf.catch_ip
        ctx.reg_stack[new_top.regs_base + tf.catch_reg] = thrown
        throwing = false
        break  // resume outer loop, fall into inner loop
    }
    if throwing {
        // no catcher — propagate out of interpret()
        return InterpretResult { is_throw: true, value: thrown }
    }
}
```

This replaces the current per-frame `try_stack[]`. Finally bodies
are still compiler-inlined into break/continue/return paths
(Phase 3.9d), so they Just Work as long as Op::Return doesn't
short-circuit the inlined finallies (it already doesn't — the
compiler emits them before Op::Return).

### GC interactions

**Root scanning** simplifies a lot:

```
// old: walk each root_frames[i].regs[0..reg_count]
// new: walk reg_stack[0..reg_stack_top] as one contiguous range
gc_mark_value_range(ctx.reg_stack, ctx.reg_stack_top)
```

Also mark each frame's saved_host_this and saved_current_closure
(both are roots while the frame is live).

The temp_roots stay; the atoms stay; the globals stay.

**GC safe-points** stay where they are today (backward branches,
Op::Return). Op::Invoke is also a natural safe-point — the new
frame's regs are zero-initialized before any allocation, and the
caller's regs are live in `reg_stack`.

### Host functions (`ZjsHostFunction`)

Unchanged externally. When called from Op::Invoke (host callee), we
invoke the C function pointer synchronously — same as today. Host
functions that call back into JS (e.g., `Array.forEach(callback)`,
`zjs_call_value`) re-enter `interpret()` recursively. That's fine:
each `interpret()` call manages its own portion of the frame stack
(from `entry_frame_index` to `frame_count`). The OUTER `interpret()`
sees its frames untouched when the inner one returns.

This means **host-to-JS calls are still recursive C calls**. Only
**JS-to-JS calls** become non-recursive. That's the bulk of the
benefit because pure-JS hot paths (fib, callbacks once dispatched
from host code) live in a single `interpret()` invocation.

## Invariants (must preserve)

1. **Per-frame register lifetime**: a frame's regs are valid from
   push to pop. GC must see them all marked. Nothing outside the
   frame's window may write into it.
2. **Throw never tears down state the catcher needs**: host_this,
   current_closure, and reg_stack must be restored to the catching
   frame's state before the catch handler runs.
3. **Op::Return preserves caller's regs**: the caller's regs were
   *not* changed during the callee's execution. Only the
   return_dst slot is written on pop.
4. **`finally` still runs on Return**: compiler-inlined finally
   bodies execute before Op::Return is reached. Throwing from
   inside a finally is handled by the same unwind code (just
   sets `throwing` again).
5. **Stack overflow**: the frame_count / reg_stack_top must have
   a soft cap. Returning a TypeError-thrown "RangeError: Maximum
   call stack size exceeded" is the ECMA-262 behavior.

## Phasing

I'll land this in measurable increments — each one keeps all 412
interpreter tests green, runs benches, and is a complete commit.

### Phase A — Foundation, no behavior change
- Add `CallFrame`, `reg_stack`, `try_stack` to `ZjsContext`.
- Helpers: `push_call_frame`, `pop_call_frame`, `pop_call_frames_to`.
- New helpers are unused; `interpret()` is unchanged.
- Tests still pass. Bench unchanged. **Pure scaffolding commit.**

### Phase B — Convert `interpret()` to outer-loop shape
- Rewrite `interpret()` to push an initial frame, then run the
  outer/inner loop pair.
- JS-to-JS Op::Invoke pushes a frame and breaks inner loop.
- Op::Return pops frame, writes to caller, breaks inner loop.
- Op::Throw and dispatched throws unwind through the frame stack.
- GC root scan switches to the contiguous reg_stack model.
- Replace per-frame `TryFrame[32]` with the shared try stack.
- **This is the high-risk commit.** Everything must pass.

### Phase C — Tail-call optimization
- Detect when Op::Invoke is immediately followed by Op::Return
  (the call is in tail position).
- Compiler emits `Op::TailInvoke` instead.
- Handler: instead of `push_call_frame`, reuse current frame's
  slot — replace `frame.f`, reset ip/regs, copy args. No stack
  growth.
- This is the part qjs and most production interpreters do that
  we currently don't.
- **Big win on recursive code without manual loop conversion.**

### Phase D — Measurement
- Bench against the baseline.
- If gains are below ~5%, document the finding in
  `future-work.md` and consider whether C → D phases were worth it.
- If gains hit ~10%+ on fib, we celebrate.

Phasing rationale: A is safe and lets me audit the new types
in isolation. B is where bugs hide; landing it as its own commit
makes git-bisect work. C is the structural payoff. D is the
honest accounting.

## Risks

- **Throw unwinding bugs.** The current per-frame try_stack is
  easy to reason about; the shared stack with frame indices is
  more subtle. Test coverage exists (Phase 3.9c+ has rich
  throw/try/catch/finally tests) — those will catch regressions.

- **GC root range off-by-one.** The contiguous reg_stack approach
  is simpler than per-frame ranges, but a pop_frame that doesn't
  shrink reg_stack_top would leak (free'd cells stay marked).
  Audit pop_call_frame carefully.

- **Performance might not show up.** The estimate is ~5-10%; if
  the actual gain is <3%, the structural benefits (tail calls,
  generators, debuggability) still justify the change, but the
  perf number alone won't.

- **Host-callable boundary.** `zjs_call_value` (from host code,
  including builtins like Array.forEach) re-enters `interpret()`.
  The frame stack must support nested entry without confusing
  the throw-unwinding code. The `entry_frame_index` parameter to
  the throw walker handles this — verify with an Array.forEach
  test that throws.

- **Debugger/inspector compatibility.** Anyone using
  `ctx.root_frames` externally breaks. Grep confirmed only
  `gc_mark_roots` consumes it; nothing external.

## Expected gain (honest range)

- fib_recursive: 152 → 135-145 ms (5-10% better)
- closure_call: 9.3 → ~8.8 ms (5%)
- int_loop family: ~no change (no JS-to-JS calls in the loop)
- property_*: ~no change

The structural wins (tail-call optimization in Phase C, future
generator support) are the larger payoff.

## Out of scope

- **Async/await, generators.** These need a more sophisticated
  CallFrame that can be detached and resumed. The architecture
  here makes it *possible* but doesn't implement it.
- **Stack-overflow recovery.** We'll add a soft cap on
  frame_count that throws RangeError, but no graceful tear-down
  beyond that.
- **Direct-threaded dispatch.** Still tracked separately in
  `future-work.md`. Could be layered on top of this — each
  per-handler tail-call would also push/pop frames as needed.
