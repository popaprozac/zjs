## nim-eval -- Nim port of `zjs eval '<src>'` (tools/zjs.zc run_eval /
## print_value / write_value, ~335-445). Reads JS SOURCE as argv[1] (like
## `zjs eval`), lexes+parses+compiles+executes the top-level program, and
## prints the completion value via `inspectVmVal` (a port of
## `write_value`, tools/zjs.zc ~339).
##
## Bail discipline (CRITICAL): if parse fails, or the VM hits an op /
## value shape outside the supported subset, print NOTHING to stdout and
## exit nonzero. A WRONG result is far worse than a bail.
##
## Output MUST match `build/zjs eval '<src>'` byte-for-byte for the
## supported subset (arithmetic / control-flow / functions / strings, and
## Phase 6 slice 1: a bare OBJECT / ARRAY completion value).

import std/[os, strformat, strutils, tables]
import ../src/zjs/[parser, compiler, vm, value, gc, builtins]

# --- inspectValue: port of write_value (tools/zjs.zc ~339) --------------
# Recursive value printer. `quoted` controls whether a STRING is wrapped in
# double quotes: the TOP-LEVEL completion prints a bare string UNQUOTED
# (quoted=false, JS-shell style), but a string NESTED inside an object /
# array prints QUOTED for readability (quoted=true). Numbers use C %g
# (Nim's `{d:g}`, verified against the oracle for 1/3, 0.1, -0); bool /
# null / undefined print their keywords.
#
# Objects:  "{ " + `key: valueInspect` joined by ", " + " }". EMPTY = "{  }"
#           (TWO spaces). Keys are own property NAMES in insertion order
#           (unquoted); values printed quoted=true.
# Arrays:   "[" + elems joined ", " + "]" (NO inner padding). EMPTY = "[]".
#           Elements printed quoted=true; an array HOLE prints nothing (an
#           empty position between the comma separators) — matches
#           write_value's `if zjs_is_deleted(slot) == 0`.
#
# DEFER (bail cleanly — never a wrong string): a FUNCTION value inside a
# container (write_value prints "[function]", but reproducing that shape is
# a later slice), getters, Symbol / exotic keys, and a non-integer double
# that would need dtoa (unreachable here — %g is exact for our doubles).

const MAX_INSPECT_DEPTH = 1000
  ## Recursion cap. A cyclic completion value (e.g. `var o={}; o.self=o; o`)
  ## would recurse forever; the reference's write_value has NO cycle guard
  ## and simply overflows the C stack (crash → empty output). We BAIL once
  ## the cap is exceeded — never hang, never a wrong string. Comfortably
  ## above any finite nesting the corpus produces, and below Nim's own
  ## native stack limit so the recursion can't segfault before the guard.

proc inspectZ(heap: GcHeap, v: ZjsValue, quoted: bool, depth: int): string =
  ## write_value over a ZjsValue (the recursion carrier: nested container
  ## values are ZjsValues read from the object/array side tables).
  if depth > MAX_INSPECT_DEPTH:
    raise newException(VmBail, "inspect depth cap exceeded (cycle?)")
  # --- primitives (write_value int32 / double / bool / null / undefined) --
  if isInt32(v): return $asInt32(v)
  if isDouble(v):
    let d = asDouble(v)
    if d != d:      return "NaN"
    if d == Inf:    return "Infinity"
    if d == NegInf: return "-Infinity"
    return &"{d:g}"                        # C %g (incl. -0 → "-0")
  if isBool(v):      return (if asBool(v) != 0: "true" else: "false")
  if isNull(v):      return "null"
  if isUndefined(v): return "undefined"
  # --- heap cells ---------------------------------------------------------
  if not isCell(v) or cellAsPtr(v) == nil:
    raise newException(VmBail, "inspect on unrepresentable value")
  case cellHeader(v).typeTag
  of TAG_STRING:
    # write_value string arm: quoted → "…", else raw bytes.
    let s = strCellVal(heap, v)
    return (if quoted: "\"" & s & "\"" else: s)
  of TAG_ARRAY:
    # write_value array arm: '[' + elems joined ", " + ']' (no inner pad).
    let p = cellAsPtr(v)
    var parts: seq[string]
    if heap.arrTable.hasKey(p):
      for e in heap.arrTable[p]:
        if e.bits == VALUE_DELETED:
          parts.add("")                    # array hole → empty position
        else:
          parts.add(inspectZ(heap, e, true, depth + 1))
    return "[" & parts.join(", ") & "]"
  of TAG_OBJECT:
    # write_value object arm: "{ " + key: value joined ", " + " }";
    # EMPTY = "{  }" (two spaces). Names = own keys in insertion order.
    let o = cast[ptr ObjectCell](cellAsPtr(v))
    let names = objKeys(heap, o)
    if names.len == 0: return "{  }"
    var parts: seq[string]
    for name in names:
      parts.add(name & ": " & inspectZ(heap, objGet(heap, o, name), true, depth + 1))
    return "{ " & parts.join(", ") & " }"
  of TAG_FUNCTION, TAG_HOSTFN:
    # write_value function arm: every callable prints "[function]" (top-level
    # and nested), matching the oracle for host fns / user fns / arrows.
    return "[function]"
  else:
    # Any other cell shape → bail (never wrong).
    raise newException(VmBail, "inspect on unsupported cell")

proc inspectVmVal(heap: GcHeap, x: VmVal, quoted: bool): string =
  ## Top-level completion inspect over a VmVal. A bare string is UNQUOTED at
  ## the top level (quoted=false); a function value is out of scope (bail —
  ## the oracle prints its source-ish form, which we can't reproduce here).
  case x.kind
  of vkString:
    return (if quoted: "\"" & x.s & "\"" else: x.s)
  of vkFunction:
    return "[function]"
  of vkVal:
    return inspectZ(heap, x.v, quoted, 0)

proc main() =
  if paramCount() < 1:
    stderr.write("usage: nim-eval '<src>'\n")
    quit(2)
  let src = paramStr(1)

  var p = initParser(src)
  let root = p.parseProgram()
  if p.hadError:
    # zjs's eval on a parse error prints nothing useful for our oracle
    # subset — bail (nothing on stdout, nonzero exit).
    quit(1)

  let f = compileProgram(src, root)
  if f == nil:
    quit(1)

  # Own the heap for the whole run AND for formatting: a bare object/array
  # completion value reads its contents from the heap side tables, which the
  # 2-arg runFunction would destroy before we could print. Format first,
  # then destroy.
  var globals: seq[VmVal] = @[]
  var heap = newGcHeap()
  # Install the realm's built-in globals (native isNaN/isFinite + value globals
  # NaN/Infinity) BEFORE the run, into the SAME heap threaded into runFunction
  # so the native cells are rooted via `globals` and survive any collect.
  installBuiltins(globals, heap)
  var outText: string
  var ok = true
  try:
    let completion = runFunction(f, globals, heap, 0)
    outText = inspectVmVal(heap, completion, false)
  except VmBail as e:
    # Honest "can't run / can't format" — print NOTHING, exit nonzero. With
    # ZJS_TRACE_BAIL=1 the bail reason goes to stderr (for gap ranking only).
    ok = false
    if getEnv("ZJS_TRACE_BAIL") == "1":
      stderr.write("BAIL: " & e.msg & "\n")
  finally:
    destroyHeap(heap)

  if not ok:
    quit(1)
  stdout.write(outText & "\n")

when isMainModule:
  main()
