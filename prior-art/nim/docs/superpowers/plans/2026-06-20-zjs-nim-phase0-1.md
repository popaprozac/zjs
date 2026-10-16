# ZJS-Nim Phase 0 + Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Nim ZJS engine skeleton — a `nim/`-rooted project that builds a C-ABI-compatible `libzjs.a`, links the *existing* `test262_runner.c` unchanged, and implements the NaN-boxed immediate value system (int32 / double / bool / null / undefined) behind the same C ABI the embedder uses.

**Architecture:** Pure idiomatic Nim core with a thin `{.exportc, cdecl.}` C-ABI shim (the "two registers" principle from the design doc). The Nim engine grows in `nim/` beside the Zen-c engine in `src/`; both share `include/zjs.h`, `tests/test262_runner.c`, and `vendor/test262`. The C ABI (`zjs.h`) is the frozen parity seam. Value encoding mirrors the proven Zen-c scheme bit-for-bit (the golden rule permits perf re-tuning in Phase 7).

**Tech Stack:** Nim 2.2.10 (C backend, `--mm:arc`), clang, the existing C test harness, `std/unittest` for Nim unit tests.

**Reference:** `docs/superpowers/specs/2026-06-20-zjs-nim-migration-design.md` (the approved design). This plan covers **Phase 0** (scaffold + test262 loop) and **Phase 1** (value system + stub) only.

---

## Toolchain facts (verified by spike before writing this plan)

- **Static lib build:** `nim c --app:staticlib --noMain:on --mm:arc -d:release --nimcache:<dir> --out:<path>/libzjs.a <entry>.nim` produces a `.a`.
- **Runtime init:** with `--noMain`, the Nim runtime must be initialized by calling the generated `NimMain()` once before any exported proc allocates. We make the C ABI **self-initializing** — `zjs_new_context` lazily calls `NimMain()` on first use — so `test262_runner.c` (shared with the Zen-c build) needs **zero changes**. Verified: a `newSeq` inside an exported proc works with no host-side `NimMain()` call.
- **Linking:** `clang -O2 -Iinclude tests/test262_runner.c <path>/libzjs.a -lm -o <out>` links the static lib directly (no `-L`/`-lzjs`/`-rpath`).
- **`ZjsValue` ABI:** `zjs.h` defines `typedef struct { uint64_t bits; } ZjsValue;` — passed/returned by value, same ABI as `uint64_t`. The Nim side declares `type ZjsValue {.bycopy.} = object` with one `uint64` field; a single-`uint64` struct is ABI-identical across C and Nim (returned in a register).

---

## File Structure

| File | Responsibility |
|---|---|
| `nim/src/zjs.nim` | C-ABI entry module. `{.exportc, cdecl.}` shims for the 4 harness functions + the immediate value constructors/predicates. Lazy `NimMain` init. The *only* file that knows about the C ABI. |
| `nim/src/zjs/value.nim` | Idiomatic Nim value core: the `ZjsValue` type, NaN-boxing constants, immediate constructors/predicates/unboxers. No C-ABI naming. Systems register. |
| `nim/src/zjs/context.nim` | The engine context object (Phase 0: near-empty, holds `hadError`). Grows in later phases. |
| `nim/tests/tvalue.nim` | `std/unittest` round-trip tests for the value core. |
| `build/nim/libzjs.a` | Build output (gitignored). |
| `Makefile` | New targets: `nim-lib`, `nim-test262`, `nim-unit`. |

**Naming convention (the two registers):** internal Nim is idiomatic camelCase with real types (`isInt32(v): bool`); the C ABI shim is snake_case `{.exportc.}` (`zjs_is_int32(v): cint`). The shim is a one-line adapter per function.

---

## PHASE 0 — Scaffold + test262 loop

### Task 1: Project scaffold + self-initializing C-ABI skeleton

**Files:**
- Create: `nim/src/zjs/context.nim`
- Create: `nim/src/zjs.nim`
- Create: `nim/.gitignore`

- [ ] **Step 1: Create the context module**

`nim/src/zjs/context.nim`:

```nim
## Engine context. Phase 0: minimal — just enough for the C ABI to
## allocate/free a handle and track the uncaught-error flag. Grows in
## later phases (heap, globals, GC, frames).

type
  Context* = object
    hadError*: bool

proc newContext*(): ptr Context =
  ## Allocate a zeroed Context on the manual (non-Nim-GC) heap. The JS
  ## runtime heap is always manual; see the design doc's two-heap rule.
  result = cast[ptr Context](alloc0(sizeof(Context)))

proc freeContext*(c: ptr Context) =
  if c != nil: dealloc(c)
```

- [ ] **Step 2: Create the C-ABI entry module with lazy runtime init**

`nim/src/zjs.nim`:

```nim
## C-ABI entry module. Exposes the zjs.h surface via {.exportc, cdecl.}.
## This is the ONLY file aware of the C ABI; everything else is
## idiomatic Nim. The static lib is built with --noMain, so we init the
## Nim runtime lazily on first context creation (keeps test262_runner.c
## unchanged across the Zen-c and Nim builds).

import zjs/context

proc NimMain() {.importc, cdecl.}

var runtimeReady {.global.} = false
proc ensureRuntime() {.inline.} =
  if not runtimeReady:
    runtimeReady = true
    NimMain()

# --- ZjsValue: ABI-identical to `struct { uint64_t bits; }` in zjs.h ---
type ZjsValue {.bycopy.} = object
  bits: uint64

# --- The 4 functions test262_runner.c needs ---

proc zjs_new_context(): ptr Context {.exportc, cdecl.} =
  ensureRuntime()
  newContext()

proc zjs_free_context(c: ptr Context) {.exportc, cdecl.} =
  freeContext(c)

proc zjs_had_error(c: ptr Context): cint {.exportc, cdecl.} =
  if c != nil and c.hadError: 1 else: 0

proc zjs_eval(c: ptr Context, source: cstring): ZjsValue {.exportc, cdecl.} =
  ## Phase 0 stub: nothing is implemented yet, so every program is
  ## treated as "failed to run" (hadError = 1). This makes the test262
  ## loop report ~0 passing — the honest baseline. Real eval arrives in
  ## Phase 4. `source` is intentionally unused here.
  if c != nil: c.hadError = true
  ZjsValue(bits: 10'u64)   # VALUE_UNDEFINED (see Phase 1)
```

- [ ] **Step 3: Create nim/.gitignore**

`nim/.gitignore`:

```
nimcache/
```

- [ ] **Step 4: Build the static lib manually to verify it compiles**

Run:
```bash
mkdir -p build/nim/cache
nim c --app:staticlib --noMain:on --mm:arc -d:release \
  --nimcache:build/nim/cache --out:build/nim/libzjs.a nim/src/zjs.nim
```
Expected: ends with `... libzjs.a [SuccessX]` and `build/nim/libzjs.a` exists.

- [ ] **Step 5: Commit**

```bash
git add nim/ && git commit -m "nim: scaffold — self-initializing C-ABI skeleton (phase 0)"
```

---

### Task 2: Makefile integration + run the test262 harness against the Nim lib

**Files:**
- Modify: `Makefile` (add `nim-lib`, `nim-test262` targets)

- [ ] **Step 1: Add the Nim build + harness targets to the Makefile**

Add to `Makefile` (near the other test262 targets, after the `test262-runner` block):

```makefile
# --- Nim engine (migration track; see docs/superpowers/specs/2026-06-20-...) ---
NIM            ?= nim
NIM_OUT        := build/nim
NIM_LIB        := $(NIM_OUT)/libzjs.a
NIM_ENTRY      := nim/src/zjs.nim
NIM_RUNNER     := $(NIM_OUT)/test262_runner

nim-lib: $(NIM_LIB)
$(NIM_LIB): $(wildcard nim/src/*.nim nim/src/zjs/*.nim) | $(NIM_OUT)
	$(NIM) c --app:staticlib --noMain:on --mm:arc -d:release \
	  --nimcache:$(NIM_OUT)/cache --out:$(NIM_LIB) $(NIM_ENTRY)

$(NIM_OUT):
	mkdir -p $(NIM_OUT)

# Build the SHARED test262 runner against the Nim lib (runner is unchanged).
$(NIM_RUNNER): tests/test262_runner.c include/zjs.h $(NIM_LIB) | $(NIM_OUT)
	$(CLANG) -O2 -Wall -Iinclude tests/test262_runner.c $(NIM_LIB) -lm -o $@

nim-test262: $(NIM_RUNNER)
	@$(NIM_RUNNER) $(T262_DIR)

.PHONY: nim-lib nim-test262
```

- [ ] **Step 2: Build the Nim lib via the Makefile**

Run: `make nim-lib`
Expected: `... libzjs.a [SuccessX]`, exit 0.

- [ ] **Step 3: Build the runner against the Nim lib**

Run: `make build/nim/test262_runner` (or just `make nim-test262`, which builds it as a dependency).
Expected: clang link succeeds, `build/nim/test262_runner` exists.

- [ ] **Step 4: Run the harness on a tiny subset to prove the loop**

Run:
```bash
build/nim/test262_runner vendor/test262/test/language/types/boolean
```
Expected: it runs to completion, prints a `passed/failed` summary line, **does not crash/segfault**, and reports **~0 passing** (the Phase-0 stub fails everything). The exact number is meaningless until Phase 4 — the deliverable is "the loop runs end-to-end."

- [ ] **Step 5: Commit**

```bash
git add Makefile && git commit -m "nim: Makefile targets + test262 harness runs against the Nim lib (phase 0)"
```

---

## PHASE 1 — Value system (NaN-boxed immediates)

**Scope note:** the design doc's Phase 1 also mentions a cell header + bump
allocator. Those are deferred to the first phase that introduces an actual cell
type (string/object), per YAGNI — there is nothing to allocate or test yet. This
plan's Phase 1 is the *immediate* value encoding only.

The value encoding mirrors `src/value.zc` bit-for-bit. Scheme (JSC-style):
- `NUMBER_TAG = 0xfffe'u64 shl 48`; an int32 is `NUMBER_TAG or uint32(i)`.
- A double is stored as `cast[uint64](d) + DOUBLE_ENCODE_OFFSET` where `DOUBLE_ENCODE_OFFSET = 1'u64 shl 49` (shifts doubles out of tag space so they never collide with int32/cell tags).
- Singletons: `null = 2`, `undefined = 10`, `false = 6`, `true = 7`.
- `is_number = (bits and NUMBER_TAG) != 0`; `is_int32 = (bits and NUMBER_TAG) == NUMBER_TAG`; `is_double = is_number and not is_int32`.
- `is_cell = (bits and NOT_CELL_MASK) == 0`, `NOT_CELL_MASK = NUMBER_TAG or 2` (cell pointers arrive in a later phase; the predicate is defined now).

### Task 3: Value type + immediate constructors (TDD)

**Files:**
- Create: `nim/src/zjs/value.nim`
- Create: `nim/tests/tvalue.nim`

- [ ] **Step 1: Write the failing test**

`nim/tests/tvalue.nim`:

```nim
import std/unittest
import ../src/zjs/value

suite "value constructors":
  test "int32 round-trips through encode/decode":
    check isInt32(int32Val(5'i32))
    check asInt32(int32Val(5'i32)) == 5'i32
    check asInt32(int32Val(-1'i32)) == -1'i32
    check asInt32(int32Val(high(int32))) == high(int32)
    check asInt32(int32Val(low(int32))) == low(int32)

  test "double round-trips and is distinct from int32":
    check isDouble(doubleVal(3.5))
    check asDouble(doubleVal(3.5)) == 3.5
    check not isInt32(doubleVal(3.5))
    # A double whose raw bits resemble the int32 tag must NOT decode as int32:
    check not isInt32(doubleVal(-1.7e308))

  test "singletons":
    check isNull(nullVal())
    check isUndefined(undefinedVal())
    check isBool(boolVal(true))
    check isBool(boolVal(false))
    check asBool(boolVal(true)) == 1
    check asBool(boolVal(false)) == 0
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nim c -r --mm:arc --hints:off nim/tests/tvalue.nim`
Expected: FAIL — `value` module / `int32Val` not found (compile error). That is the expected red.

- [ ] **Step 3: Write the value module**

`nim/src/zjs/value.nim`:

```nim
## NaN-boxed JS value. Idiomatic Nim core (systems register). Mirrors
## src/value.zc bit-for-bit; the golden rule permits perf re-tuning in
## Phase 7. ZjsValue is a single uint64 wrapped in a distinct-ish object
## so the C-ABI shim can hand it across the boundary unchanged.

type
  ZjsValue* {.bycopy.} = object
    bits*: uint64

const
  NUMBER_TAG*           = 0xfffe'u64 shl 48
  DOUBLE_ENCODE_OFFSET* = 1'u64 shl 49
  NOT_CELL_MASK*        = NUMBER_TAG or 2'u64
  VALUE_NULL*           = 2'u64
  VALUE_UNDEFINED*      = 10'u64
  VALUE_FALSE*          = 6'u64
  VALUE_TRUE*           = 7'u64

# --- bit casts ---
proc doubleToBits(d: float64): uint64 {.inline.} = cast[uint64](d)
proc bitsToDouble(b: uint64): float64 {.inline.} = cast[float64](b)

# --- constructors ---
proc int32Val*(i: int32): ZjsValue {.inline.} =
  ZjsValue(bits: NUMBER_TAG or uint64(cast[uint32](i)))

proc doubleVal*(d: float64): ZjsValue {.inline.} =
  ZjsValue(bits: doubleToBits(d) + DOUBLE_ENCODE_OFFSET)

proc boolVal*(b: bool): ZjsValue {.inline.} =
  ZjsValue(bits: if b: VALUE_TRUE else: VALUE_FALSE)

proc nullVal*(): ZjsValue {.inline.} = ZjsValue(bits: VALUE_NULL)
proc undefinedVal*(): ZjsValue {.inline.} = ZjsValue(bits: VALUE_UNDEFINED)

# --- predicates ---
proc isInt32*(v: ZjsValue): bool {.inline.} =
  (v.bits and NUMBER_TAG) == NUMBER_TAG
proc isNumber*(v: ZjsValue): bool {.inline.} =
  (v.bits and NUMBER_TAG) != 0
proc isDouble*(v: ZjsValue): bool {.inline.} =
  isNumber(v) and not isInt32(v)
proc isBool*(v: ZjsValue): bool {.inline.} =
  (v.bits and not 1'u64) == VALUE_FALSE
proc isNull*(v: ZjsValue): bool {.inline.} = v.bits == VALUE_NULL
proc isUndefined*(v: ZjsValue): bool {.inline.} = v.bits == VALUE_UNDEFINED
proc isCell*(v: ZjsValue): bool {.inline.} =
  (v.bits and NOT_CELL_MASK) == 0

# --- unboxers (UB if the matching predicate is false, as in Zen-c) ---
proc asInt32*(v: ZjsValue): int32 {.inline.} = cast[int32](uint32(v.bits))
proc asDouble*(v: ZjsValue): float64 {.inline.} =
  bitsToDouble(v.bits - DOUBLE_ENCODE_OFFSET)
proc asBool*(v: ZjsValue): cint {.inline.} = cint(v.bits and 1'u64)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `nim c -r --mm:arc --hints:off nim/tests/tvalue.nim`
Expected: PASS — `[OK]` for all three tests, `0 failures`.

- [ ] **Step 5: Commit**

```bash
git add nim/src/zjs/value.nim nim/tests/tvalue.nim
git commit -m "nim: NaN-boxed immediate value system + round-trip tests (phase 1)"
```

---

### Task 4: Collision + edge-case hardening (TDD)

The value scheme's correctness hinges on int32/double/singleton spaces never aliasing. Lock that with explicit adversarial tests.

**Files:**
- Modify: `nim/tests/tvalue.nim`

- [ ] **Step 1: Add the failing edge-case tests**

Append to `nim/tests/tvalue.nim`:

```nim
suite "value non-aliasing":
  test "NaN double round-trips and does not read as int32":
    let nan = doubleVal(0.0/0.0)
    check isDouble(nan)
    check not isInt32(nan)
    check asDouble(nan) != asDouble(nan)   # NaN != NaN

  test "+Inf / -Inf round-trip":
    check asDouble(doubleVal(1.0/0.0)) == 1.0/0.0
    check asDouble(doubleVal(-1.0/0.0)) == -1.0/0.0

  test "zero and negative-zero":
    check asDouble(doubleVal(0.0)) == 0.0
    check asDouble(doubleVal(-0.0)) == 0.0
    # sign bit preserved on -0.0
    check cast[uint64](asDouble(doubleVal(-0.0))) == cast[uint64](-0.0)

  test "singletons are mutually distinct and not numbers/cells":
    for v in [nullVal(), undefinedVal(), boolVal(true), boolVal(false)]:
      check not isNumber(v)
      check not isCell(v)
    check nullVal().bits != undefinedVal().bits
    check boolVal(true).bits != boolVal(false).bits

  test "every int32 boundary decodes exactly":
    for i in [0'i32, 1'i32, -1'i32, high(int32), low(int32), 1234567'i32, -7654321'i32]:
      check isInt32(int32Val(i))
      check asInt32(int32Val(i)) == i
      check not isDouble(int32Val(i))
```

- [ ] **Step 2: Run to verify (these should already pass if the scheme is correct)**

Run: `nim c -r --mm:arc --hints:off nim/tests/tvalue.nim`
Expected: PASS. If any fail, the encoding has a real bug — fix `value.nim`, do not weaken the test. (These tests are the contract.)

- [ ] **Step 3: Commit**

```bash
git add nim/tests/tvalue.nim
git commit -m "nim: adversarial value non-aliasing tests (NaN/Inf/-0/boundaries) (phase 1)"
```

---

### Task 5: Wire the value core into the C ABI + a C-level smoke test

Expose the embedder-facing immediate value functions (`zjs_int32`, `zjs_double`, `zjs_bool`, `zjs_null`, `zjs_undefined`, `zjs_is_*`, `zjs_as_*`) through the C ABI shim, and prove they work from C (the way Zapp calls them).

**Files:**
- Modify: `nim/src/zjs.nim`
- Create: `nim/tests/cabi_smoke.c`

- [ ] **Step 1: Add the C-ABI value shims to the entry module**

In `nim/src/zjs.nim`, replace the local `type ZjsValue` block with an import of the real one and add the shims. Change the top imports to:

```nim
import zjs/context
import zjs/value   # ZjsValue + the idiomatic core
```

Delete the local `type ZjsValue {.bycopy.} = object` block (now provided by `value`). Update the `zjs_eval` stub's return to use the core:

```nim
proc zjs_eval(c: ptr Context, source: cstring): ZjsValue {.exportc, cdecl.} =
  if c != nil: c.hadError = true
  undefinedVal()
```

Append the value shims (thin adapters — idiomatic core → C ABI):

```nim
# --- Immediate value constructors (C ABI) ---
proc zjs_int32(i: cint): ZjsValue {.exportc, cdecl.} = int32Val(int32(i))
proc zjs_double(d: cdouble): ZjsValue {.exportc, cdecl.} = doubleVal(float64(d))
proc zjs_bool(b: cint): ZjsValue {.exportc, cdecl.} = boolVal(b != 0)
proc zjs_null(): ZjsValue {.exportc, cdecl.} = nullVal()
proc zjs_undefined(): ZjsValue {.exportc, cdecl.} = undefinedVal()

# --- Predicates (C ABI: return cint 0/1) ---
proc zjs_is_int32(v: ZjsValue): cint {.exportc, cdecl.} = cint(isInt32(v))
proc zjs_is_double(v: ZjsValue): cint {.exportc, cdecl.} = cint(isDouble(v))
proc zjs_is_number(v: ZjsValue): cint {.exportc, cdecl.} = cint(isNumber(v))
proc zjs_is_bool(v: ZjsValue): cint {.exportc, cdecl.} = cint(isBool(v))
proc zjs_is_null(v: ZjsValue): cint {.exportc, cdecl.} = cint(isNull(v))
proc zjs_is_undefined(v: ZjsValue): cint {.exportc, cdecl.} = cint(isUndefined(v))
proc zjs_is_cell(v: ZjsValue): cint {.exportc, cdecl.} = cint(isCell(v))

# --- Unboxers (C ABI) ---
proc zjs_as_int32(v: ZjsValue): cint {.exportc, cdecl.} = cint(asInt32(v))
proc zjs_as_double(v: ZjsValue): cdouble {.exportc, cdecl.} = cdouble(asDouble(v))
proc zjs_as_bool(v: ZjsValue): cint {.exportc, cdecl.} = asBool(v)
```

- [ ] **Step 2: Write the C-level smoke test (mimics how the embedder calls in)**

`nim/tests/cabi_smoke.c`:

```c
#include <stdio.h>
#include "zjs.h"

#define CHECK(cond) do { if (!(cond)) { printf("FAIL: %s\n", #cond); fails++; } } while (0)

int main(void) {
    int fails = 0;
    CHECK(zjs_is_int32(zjs_int32(42)));
    CHECK(zjs_as_int32(zjs_int32(42)) == 42);
    CHECK(zjs_as_int32(zjs_int32(-7)) == -7);
    CHECK(zjs_is_double(zjs_double(3.5)));
    CHECK(zjs_as_double(zjs_double(3.5)) == 3.5);
    CHECK(!zjs_is_int32(zjs_double(3.5)));
    CHECK(zjs_is_bool(zjs_bool(1)));
    CHECK(zjs_as_bool(zjs_bool(1)) == 1);
    CHECK(zjs_as_bool(zjs_bool(0)) == 0);
    CHECK(zjs_is_null(zjs_null()));
    CHECK(zjs_is_undefined(zjs_undefined()));
    CHECK(!zjs_is_number(zjs_null()));
    if (fails == 0) printf("cabi_smoke: all passed\n");
    return fails;
}
```

- [ ] **Step 3: Add a Makefile target and build/run it**

Add to `Makefile` (in the Nim section from Task 2):

```makefile
nim-cabi-smoke: $(NIM_LIB)
	$(CLANG) -O2 -Wall -Iinclude nim/tests/cabi_smoke.c $(NIM_LIB) -lm -o $(NIM_OUT)/cabi_smoke
	@$(NIM_OUT)/cabi_smoke

.PHONY: nim-cabi-smoke
```

Run: `make nim-lib && make nim-cabi-smoke`
Expected: `cabi_smoke: all passed`, exit 0.

- [ ] **Step 4: Confirm the Nim unit tests still pass**

Run: `nim c -r --mm:arc --hints:off nim/tests/tvalue.nim`
Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add nim/src/zjs.nim nim/tests/cabi_smoke.c Makefile
git commit -m "nim: immediate value C ABI shims + C-level smoke test (phase 1)"
```

---

## Done criteria for this plan

- `make nim-lib` builds `build/nim/libzjs.a` from pure Nim.
- `make nim-test262 T262_DIR=<dir>` runs the **unchanged** `test262_runner.c` against the Nim lib end-to-end (reports ~0 passing — meaningful conformance arrives in Phase 4).
- `make nim-cabi-smoke` passes (C-level proof the immediate value ABI is correct).
- `nim c -r nim/tests/tvalue.nim` passes (the value-encoding contract, including adversarial non-aliasing).

This is the verifiable foundation for Phase 2 (lexer/parser/AST), which begins the differential oracle against the live Zen-c engine.
