# zjs Phase 3.5 — More Built-ins

> Real JS programs lean heavily on Array.prototype, String.prototype,
> Object.keys, and JSON. test262 conformance also requires them. This
> phase adds the infrastructure for "method calls on built-in cell
> types" plus a useful first slice of those methods.

## Scope

Split into two commits for review-ability:

### 3.5a — Method dispatch + simple prototype methods + Object.keys

- **Method-call infrastructure**
  - `ctx.host_this: ZjsValue` — implicit receiver for host functions, set
    by the new `MethodInvoke` opcode and restored after.
  - **`MethodInvoke a=dst, b=base, c=arg_count`** — like `Invoke` but
    `regs[base+1]` is the receiver, args are at `regs[base+2..]`. For user
    `Function`/`Closure` callees the receiver is ignored (no `this`
    binding yet — that's deferred to a future phase).
  - Compiler: when a `Call` node's callee is a `Member` or `Computed`
    member access, emit `MethodInvoke` and route the receiver into
    `regs[base+1]`. Plain calls keep using `Invoke`.
- **Built-in prototype intercept (`property_get`)**
  - Two new lazy-initialized objects on `ZjsContext`:
    - `array_proto: ZjsObject*` — populated with `push`, `pop`, `indexOf`
    - `string_proto: ZjsObject*` — populated with `indexOf`, `slice`,
      `split`
  - `property_get` on `TAG_ARRAY` for an unrecognized string key falls
    back to looking up the key on `array_proto`. Same for strings.
  - This is **not** a real prototype chain (that's Phase 3.6). It's just
    enough lookup logic to make `arr.push(x)` and `"abc".slice(1)` work.
- **`Object.keys(obj)`** — global `Object` namespace, returns array of
  own-property names.
- Host functions read `ctx.host_this` (helper `zjs_get_host_this(ctx)`).

### 3.5b — Higher-order + JSON

- **`Array.prototype.map(fn)`**, **`Array.prototype.forEach(fn)`** —
  these need to call a JS function from host code. Adds a small helper
  `zjs_invoke_value(ctx, callee, args, argc) -> InterpretResult` that
  mirrors what `Op::Invoke` does, dispatching by callee tag.
- **`JSON.stringify(value)`** — basic: numbers, strings, booleans, null,
  arrays, plain objects. No `space`, no `replacer`, no `toJSON()`,
  no cycle detection (cycles overflow the stack — fine for MVP).
- **`JSON.parse(source)`** — basic hand-rolled JSON parser. Numbers,
  strings (with `\n \t \r \b \f \\ \/ \"` and `\uXXXX`), `true`,
  `false`, `null`, arrays, objects.

## Out of scope

- Real prototype-chain dispatch (`Object.getPrototypeOf`, `__proto__`) —
  that's Phase 3.6.
- `this` binding for user functions called as `obj.f()`. We pass the
  receiver via `ctx.host_this` only for host functions. User functions
  don't see it.
- `Array.prototype.{slice, concat, join, reverse, sort, filter, reduce}`
  — natural next-batch additions, not in the MVP.
- `String.prototype.{toUpperCase, toLowerCase, charAt, replace, trim,
  padStart, padEnd, repeat}` — same.
- `Object.{values, entries, assign, freeze}` — Object.keys first; the
  rest follow the same pattern when we need them.
- JSON `space`/`replacer`/`reviver` parameters and `toJSON()` hooks.
- Numeric edge cases in `JSON.stringify` (NaN/Infinity become `null`
  in the spec — we just emit the literal string for now and address
  spec-compliance later).

## Optimization path

The intercept in `property_get` walks `array_proto`/`string_proto` as
plain object lookups — IC-cacheable via the existing infrastructure if
the receiver is consistently an array or a string. When Phase 3.6 lands,
this gets replaced by walking `obj.cls.proto`, which is the same
mechanism generalized.

Host method calls read `ctx.host_this` once per invocation. That's one
field load — cheap. Eventually we'll inline-specialize common method
calls (e.g., `Array.prototype.push` becomes a dedicated `ArrayPush`
opcode emitted when the compiler can prove the receiver is an array)
but profile first.

## Verification

```bash
zjs eval "let a = [1,2,3]; a.push(4); a.push(5); a.length"          # 5
zjs eval "let a = [10,20,30]; a.pop()"                              # 30
zjs eval "[1,2,3,4,5].indexOf(3)"                                   # 2
zjs eval "Object.keys({a:1,b:2,c:3}).length"                        # 3
zjs eval "\"hello world\".indexOf(\"world\")"                       # 6
zjs eval "\"hello\".slice(1,4)"                                     # "ell"
zjs eval "\"a,b,c\".split(\",\").length"                            # 3
zjs eval "[1,2,3].map(function(x){return x*x})[2]"                   # 9 (3.5b)
zjs eval "JSON.stringify({a:1, b:[2,3]})"                            # {"a":1,"b":[2,3]} (3.5b)
zjs eval "JSON.parse('[1,2,3]')[1]"                                  # 2 (3.5b)
```

## What's next

- **3.4 — for-in / for-of.** Parser already handles them; bytecode
  lowering pending. for-of will use the array-as-iterable path for now.
- **3.6 — prototype chain + `instanceof`.** Replaces the `array_proto`
  intercept with general `cls.proto` walking. Unlocks classes.
- **3.7 — class syntax.**
