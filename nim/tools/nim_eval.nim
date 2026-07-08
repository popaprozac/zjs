## nim-eval -- Nim port of `zjs eval '<src>'` (tools/zjs.zc run_eval /
## print_value, ~442-458). Reads JS SOURCE as argv[1] (like `zjs eval`),
## lexes+parses+compiles+executes the top-level program, and prints the
## completion value via `printValue` (a port of `print_value` →
## `write_value`, tools/zjs.zc ~339).
##
## Bail discipline (CRITICAL): if parse fails, or the VM hits an op /
## value shape outside the slice-1 subset, print NOTHING to stdout and
## exit nonzero. A WRONG result is far worse than a bail.
##
## Output MUST match `build/zjs eval '<src>'` byte-for-byte for the
## arithmetic / control-flow subset.

import std/[os, strformat]
import ../src/zjs/[parser, compiler, vm, value]

# --- printValue: port of write_value(quoted=false) (tools/zjs.zc ~339) --
# int32 → "%d"; double → NaN/±Infinity special-cases else "%g" (matched
# by Nim's &"{d:g}", verified against C for 1/3, 0.1+0.2, 2**53, -0);
# bool → true/false; null; undefined; string → raw chars UNQUOTED.
proc printValue(x: VmVal): string =
  case x.kind
  of vkString:
    return x.s          # write_value string arm, quoted=false → raw bytes
  of vkFunction:
    # A function-valued completion prints its source-ish form in the oracle
    # (`function name() { … }`), which we can't reproduce here. Out of
    # scope → bail (print nothing). Our targets never complete on a function.
    raise newException(VmBail, "printValue on function value")
  of vkVal:
    let v = x.v
    if isInt32(v):
      return $asInt32(v)
    if isDouble(v):
      let d = asDouble(v)
      if d != d:                       # isnan
        return "NaN"
      if d == Inf:  return "Infinity"
      if d == NegInf: return "-Infinity"
      return &"{d:g}"                  # C %g (incl. -0 → "-0")
    if isBool(v):
      return if asBool(v) != 0: "true" else: "false"
    if isNull(v):      return "null"
    if isUndefined(v): return "undefined"
    # Anything else (a heap cell) is out of scope for slice 1.
    raise newException(VmBail, "printValue on non-primitive")

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

  var globals: seq[VmVal] = @[]
  var outText: string
  try:
    let completion = runFunction(f, globals)
    outText = printValue(completion)
  except VmBail:
    # Honest "can't run" — print NOTHING, exit nonzero. (nim_missing)
    quit(1)

  stdout.write(outText & "\n")

when isMainModule:
  main()
