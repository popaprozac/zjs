# zjs Phase 3.1b — Objects, Arrays, Property Access

> Adds the two heavyweight cell kinds — objects (dictionary-mode) and
> arrays (dense numeric storage) — and the read/write machinery that
> connects them to the existing AST's `Member`, `Computed`, `Array`,
> and `Object` nodes. After this, programs can use plain JS data
> structures.

## Scope

In scope:
- `ZjsObject` cell type with a property list (linear search for MVP)
- `ZjsArray` cell type with dense `ZjsValue*` element storage + `length`
- Predicates: `zjs_is_object`, `zjs_is_array` (via cell-header tag)
- Allocators: `ctx_new_object`, `ctx_new_array`; both register on the context
- Property ops (helpers): `object_get`, `object_set`; `array_get`, `array_set` (auto-extending on store)
- New bytecode opcodes:
  - `NewObject dst` — empty object literal
  - `NewArray dst, base, count` — array from a contiguous register range
  - `LoadElem dst, obj_reg, key_reg` — read a property by key
  - `StoreElem obj_reg, key_reg, val_reg` — write a property by key
- Compiler:
  - `ObjectExpr` → `NewObject` + per-property `LoadConst`(name) + `StoreElem`
  - `Array` → `NewArray` from compiled-into-consecutive-regs
  - `Member` access → emits LoadConst of name then `LoadElem`
  - `Computed` access → emits the key expression then `LoadElem`
  - Assignment to `Member` / `Computed` LHS → `StoreElem`
  - Compound assignment to `Member` / `Computed` (e.g. `o.x += 5`)
- Arrays:
  - Integer-indexable from numbers OR numeric-string keys (e.g. `arr["0"]` works)
  - `.length` property returns current length
  - Out-of-bounds reads return `undefined`
  - Out-of-bounds writes extend the array (holes initialized to `undefined`)
- CLI `print_value` recursively prints arrays and objects in a readable form

Out of scope:
- **Prototype chain** — no `Object.prototype`, no `__proto__`, no inheritance
- **Built-in methods** — `.push()`, `.indexOf()`, `.toString()`, etc.
- **Property descriptors / getters / setters / writable / enumerable**
- **Hidden classes / shape transitions** — linear prop search is the MVP
- **Inline caches** — comes after hidden classes
- **`for-in` / `for-of` execution** — parser supports, but bytecode lowering deferred
- **String-keyed property literals** in object literals (`{"a": 1}` works syntactically but the compiler errors on string-form keys for now; `{a: 1}` is fine)
- **Symbol keys / computed property keys** in literals
- **Sparse-array optimization** — backing store grows linearly with max index used
- **Numeric-key string keys on plain objects** (e.g. `({}).["0"]` — works via ToString, not specially optimized)

## Data layout

```c
struct ZjsObject {
    CellHeader header;        // { type_tag = TAG_OBJECT }
    ObjectProp* props;         // grown geometrically
    uint32_t    prop_count;
    uint32_t    prop_cap;
};

struct ObjectProp {
    ZjsString* name;           // borrowed pointer into the cell list
    ZjsValue   value;
};

struct ZjsArray {
    CellHeader header;        // { type_tag = TAG_ARRAY }
    ZjsValue*  elements;       // grown geometrically; holes init to undefined
    uint32_t   length;         // observable JS length
    uint32_t   cap;            // backing capacity
};
```

`TAG_OBJECT = 2`, `TAG_ARRAY = 3`.

## Verification

`make test` continues to pass everything earlier, plus the new
property-access cases:

```
zjs eval "let o = {a: 1, b: 2}; o.a + o.b"        => 3
zjs eval "let o = {}; o.x = 5; o.x"               => 5
zjs eval "let a = [10, 20, 30]; a[0] + a[2]"      => 40
zjs eval "[1, 2, 3].length"                       => 3
zjs eval "let a = []; a[5] = 99; a.length"        => 6
zjs eval "let o = {x: [1, 2, 3]}; o.x[1]"         => 2
zjs eval "let o = {n: 'Zach'}; 'hi, ' + o.n"      => "hi, Zach"
```

## Files

- `src/value.zc` — extend `TAG_*` + cell structs; predicates + allocation helpers
- `src/context.zc` — `ctx_new_object` / `ctx_new_array`, `object_get/set`, `array_get/set`, free dispatch
- `src/bytecode.zc` — new opcodes
- `src/compiler.zc` — literal codegen + access compile + member-LHS assignment
- `src/interpreter.zc` — opcode handlers + numeric-string `.length` shortcut on arrays
- `src/tools/zjs.zc` — recursive `print_value` for arrays and objects
- `tests/interpreter_test.zc` — coverage
- `tests/embed_smoke.c` — a couple of representative C-side eval cases

## What's next

- **3.1c** — Throw / try / catch + atom interning of property names (so identity-compare replaces byte-compare in the property lookup hot path)
- **3.1d** — Mark-sweep GC. Replaces the per-context allocation list with proper reachability tracking.
- **3.1e** — test262 with real conformance signal (load `harness/assert.js` as preamble; count actual assertion outcomes).
