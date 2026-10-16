# zjs Phase 2.1 — NaN-boxed Value Representation

> First slice of Phase 2. Replaces the Phase 0 stub `ZjsValue` with the
> production-shape NaN-boxed layout from Decision 1 of
> [`docs/jitless-design-study.md`](../jitless-design-study.md).

## Why this is its own slice

Phase 2 in the design study covers value rep + lexer + parser — three
substantial pieces. The value representation touches everything later
(parser tokens, AST literals, interpreter values, GC objects, embed API),
so it ships first and stands alone. Lexer follows on a separate sub-plan;
parser after that.

## Scope

In scope:
- JSC-style NaN-box layout for `ZjsValue` (64-bit immediate values)
- Constants and bit math (`NumberTag`, `OtherTag`, `DoubleEncodeOffset`, immediate singletons)
- Constructors for the *immediate* value kinds: `int32`, `double`, `bool`, `null`, `undefined`
- Type predicates: `is_int32`, `is_double`, `is_number`, `is_bool`, `is_null`, `is_undefined`, `is_cell`
- Unboxers (precondition: caller already checked the type): `as_int32`, `as_double`, `as_bool`
- Public C ABI surface for all of the above in `include/zjs.h`
- Pure-C smoke test exercising every constructor → predicate → unbox roundtrip, plus edge cases (INT_MIN/INT_MAX, ±0.0, NaN, infinity)

Out of scope (deferred to later sub-phases):
- **Cell types** (heap objects, strings, functions, arrays) — they need the GC, which is Phase 5. The `is_cell` predicate is in scope; constructing a cell is not.
- **Symbol, BigInt** — sub-questions of value rep; defer until test262 hits them.
- **ToBoolean / ToNumber / ToString** spec coercions — those live in the interpreter (Phase 3).
- **Lexer / parser** — separate sub-plans.

## Layout (JSC convention, 64-bit immediates)

```
Constants:
  NumberTag           = 0xfffe000000000000
  OtherTag            = 0x0000000000000002
  BoolTag             = 0x0000000000000004
  UndefinedTag        = 0x0000000000000008
  NotCellMask         = NumberTag | OtherTag = 0xfffe000000000002
  DoubleEncodeOffset  = 1 << 49             = 0x0002000000000000

Immediate singletons:
  ValueNull           = OtherTag                       = 0x0000000000000002
  ValueUndefined      = OtherTag | UndefinedTag        = 0x000000000000000a
  ValueFalse          = OtherTag | BoolTag | 0         = 0x0000000000000006
  ValueTrue           = OtherTag | BoolTag | 1         = 0x0000000000000007
  ValueEmpty          = 0                              = 0x0000000000000000  (sentinel — internal use only)

Encoded values:
  Int32(i)            = NumberTag | (uint32_t)i        = 0xfffe0000_iiiiiiii
  Double(d)           = u64_bits(d) + DoubleEncodeOffset  (lands in 0x0002…0xfffc)
  Cell(p)             = (uint64_t)p                    = 0x0000_pppppppppppp  (low 48 bits)
```

## Type predicates (single-instruction or near it)

```
is_cell(v)       =  (v & NotCellMask) == 0
is_int32(v)      =  (v & NumberTag)   == NumberTag
is_number(v)     =  (v & NumberTag)   != 0
is_double(v)     =  is_number(v) && !is_int32(v)        // or single mask test on the high 16 bits
is_bool(v)       =  (v & ~1) == ValueFalse              // 0x6 or 0x7
is_null(v)       =  v == ValueNull
is_undefined(v)  =  v == ValueUndefined
```

## Public API additions (`include/zjs.h`)

```c
// Constructors
ZjsValue zjs_int32(int32_t i);
ZjsValue zjs_double(double d);
ZjsValue zjs_bool(int b);                  // any nonzero → true
ZjsValue zjs_null(void);
ZjsValue zjs_undefined(void);

// Type predicates (return 0 or 1)
int zjs_is_int32(ZjsValue v);
int zjs_is_double(ZjsValue v);
int zjs_is_number(ZjsValue v);
int zjs_is_bool(ZjsValue v);
int zjs_is_null(ZjsValue v);
int zjs_is_undefined(ZjsValue v);
int zjs_is_cell(ZjsValue v);

// Unboxers — UB if the type predicate is false. Caller's responsibility to check.
int32_t zjs_as_int32(ZjsValue v);
double  zjs_as_double(ZjsValue v);
int     zjs_as_bool(ZjsValue v);
```

`zjs_value_to_int` (the Phase 0 catch-all) is **removed**. Callers were
the CLI and the C smoke test, both updated in this slice.

## Implementation notes (Zen-c)

- Constants live in `src/value.zc` as `def` declarations so they're compile-time.
- `bool` parameter on `zjs_bool` is `int` in the C ABI (legacy C-friendliness); 0 = false, anything else = true.
- **Bit-reinterpret between `f64` and `u64`** has no Zen-c equivalent — uses a `raw { memcpy(...) }` block. This is the legitimate `raw{}` case per [[feedback-zen-c-idioms]] (no language-level intrinsic for type-punning).
- Everything else is straight Zen-c: bitwise operators, casts, struct literals, `if`/`return`.

## Verification

`make test` must:
1. Build clean (no warnings beyond the `-w` suppress set).
2. `./build/zjs --version` works (unchanged behavior).
3. `./build/zjs eval "anything"` prints `42` — but now `42` is a real
   int32 packed in a NaN-box, formatted by the CLI's type dispatch.
4. `./build/smoke` exercises every constructor / predicate / unboxer.
   It must verify:
   - `zjs_int32(0)`, `zjs_int32(1)`, `zjs_int32(-1)`, `zjs_int32(INT_MIN)`, `zjs_int32(INT_MAX)` all roundtrip.
   - `zjs_double(0.0)`, `zjs_double(-0.0)`, `zjs_double(1.5)`, `zjs_double(NAN)`, `zjs_double(INFINITY)`, `zjs_double(-INFINITY)` all roundtrip.
   - Singletons match the constants byte-for-byte.
   - Predicates are mutually exclusive within each category and inclusive of the right things (`is_number = is_int32 || is_double`).
   - Wrong-type unboxers don't crash the smoke test setup — they're UB-on-wrong-type per the contract, but the smoke test should never call them on the wrong type.

## Critical files modified

- `/Users/zach/code/zjs/include/zjs.h` — API surface
- `/Users/zach/code/zjs/src/value.zc` — full rewrite from stub
- `/Users/zach/code/zjs/src/eval.zc` — return `zjs_int32(42)` instead of stub
- `/Users/zach/code/zjs/tools/zjs.zc` — value-type dispatch for output formatting
- `/Users/zach/code/zjs/tests/embed_smoke.c` — full NaN-box test surface

## What's next after this slice

Phase 2.2 — Lexer. Hand-written, single-pass. Tokens for numbers
(int + double), strings, identifiers, keywords, operators, punctuation.
Output: a token stream the parser can consume. Plan to follow once
this slice lands.
