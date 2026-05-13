# zjs Phase 3.1e — Host Functions, Built-ins, and Growing test262

> Adds the machinery for the engine to expose host-implemented
> functions as JavaScript values. Uses that machinery to ship a
> minimal `Error` constructor and a `Math.*` namespace. Threads the
> `new` operator and `typeof` through compile + execute so more of
> the test262 surface starts evaluating.

## Scope

In scope:
- New cell type: `ZjsHostFunction` (`TAG_HOST_FUNCTION = 4`)
  - Wraps a C function pointer matching `ZjsValue (*)(ZjsContext*, ZjsValue* args, uint32_t argc)`
  - Allocated + tracked exactly like other cells
- `Op::Invoke` extended: dispatch on cell tag — user `Function` (recursive interpret) or `HostFunction` (direct C call)
- `Op::Typeof` opcode + compiler dispatch for `typeof x`
  - Returns: `"undefined"`, `"object"` (null + objects + arrays), `"boolean"`, `"number"`, `"string"`, `"function"`
- `new` operator: compiled identically to a `Call` for now. Without prototype chains this is a no-op semantic difference — the user-visible behavior is "call the function with the given args and use its return value." Host constructors (like Error) return a fresh object, which is what real `new` would yield.
- `ctx_init_builtins` invoked from `zjs_new_context`:
  - Global `Error` — host function. `Error("msg")` and `new Error("msg")` both return `{ message: <msg>, name: "Error" }`
  - Global `Math` — plain object with host-function properties: `abs`, `floor`, `ceil`, `round`, `max`, `min`, `sqrt`, `pow`
- Expanded test262 harness: uses `throw new Error(...)` for richer failure messages so failures are distinguishable from successes
- Tests for every new built-in and the new operators

Out of scope:
- **Prototype chain** — `instanceof Error` still doesn't work; deferred
- **Functions-as-objects** — can't `assert.x = function...` because Function cells don't yet hold property dictionaries; the harness uses object-shaped assert
- **`Object`, `Array`, `String`, `Number`, `Boolean` constructors / namespaces** — Phase 3.1f
- **More Math** — `random`, `log`, `sin`, `cos`, `atan2`, `hypot`, etc. — easy to add later
- **`console.log`** — not part of test262; obviously useful, defer to runtime layer phase
- **Real GC** — still Phase 3.1d after this

## Built-in functions land in globals

```
zjs_new_context()
  ├─ ... existing init ...
  └─ ctx_init_builtins()
        ├─ register Error  → global slot "Error"
        └─ build Math object with abs/floor/.../pow as host fn cells
           └─ register Math → global slot "Math"
```

These are persistent — they survive across multiple `zjs_eval` calls on
the same context.

## Verification

```bash
zjs eval "typeof 42"                       => number
zjs eval "typeof 'hi'"                     => string
zjs eval "typeof undefined"                => undefined
zjs eval "typeof null"                     => object
zjs eval "typeof (function(){})"           => function
zjs eval "typeof [1,2,3]"                  => object
zjs eval "typeof {a:1}"                    => object

zjs eval "Math.abs(-7)"                    => 7
zjs eval "Math.max(1, 5, 3)"               => 5
zjs eval "Math.min(1, 5, 3)"               => 1
zjs eval "Math.floor(3.7)"                 => 3
zjs eval "Math.ceil(3.1)"                  => 4
zjs eval "Math.round(2.5)"                 => 3
zjs eval "Math.sqrt(16)"                   => 4
zjs eval "Math.pow(2, 10)"                 => 1024

zjs eval "let e = Error('boom'); e.message"      => boom
zjs eval "let e = new Error('boom'); e.message"  => boom
zjs eval "let e = Error('x'); e.name"            => Error

zjs eval "try { throw new Error('msg') } catch (e) { e.message }"  => msg
```

## What's next

- **Phase 3.1d** — mark-sweep GC. With the cell graph richer (host fns + Error objects + Math properties), the per-context cells list is starting to feel weighty. Real GC replaces it.
- **Phase 3.1f / 3.2** — more built-ins. `Object.keys`, `Array.prototype.push`, `String.prototype.indexOf`, etc. Each unlocks more test262.
- Eventually: prototype chain + `instanceof` + class syntax.
