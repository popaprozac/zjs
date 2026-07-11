## nim-disasm -- Nim port of `disasm_function` in `tools/zjs.zc`.
##
## Reads JS source from a FILE PATH (like `zjs disasm <file>`), parses,
## compiles, and dumps the bytecode of the top-level program plus every
## nested function reachable through constant pools. Output must match
## `build/zjs disasm <file>` byte-for-byte.
##
## The renderer (`disasmToString`) builds the text into a string so tests
## can assert on it directly; `main()` streams it to stdout.

import std/[os, strutils, strformat, tables]
import ../src/zjs/[parser, bytecode, compiler, builtins_globals]

# --- C `%g` for doubles (used by LoadConst) -------------------------
# Nim's `&"{d:g}"` matches C printf `%g` byte-for-byte for the values a
# JS NumberExpr can produce (verified against `cc` for the exponential
# and mantissa-trimming cases: 2.14748e+09, 1e+10, 1e+06, 1.23457e+08).
# This is the same approach `nim/tools/nim_parse.nim` uses for the AST
# dump, and it is the oracle-matching path.
proc formatG(d: float64): string =
  &"{d:g}"

# --- C printf-style field formatting --------------------------------
# We reproduce the exact widths/justification of the fprintf calls in
# disasm_function so the text is byte-identical.

proc padRight(s: string, width: int): string =
  ## C `%-Ns`: left-justify, pad with spaces on the right.
  if s.len >= width: s else: s & repeat(' ', width - s.len)

proc padLeft(s: string, width: int): string =
  ## C `%Nu` (right-justify): pad with spaces on the left.
  if s.len >= width: s else: repeat(' ', width - s.len) & s

# --- Op-name table (positional, mirrors interpreter.zc) -------------
# The disasm prints names from a table aligned with the Op enum. Nim's
# `$op` yields the same identifier text, so we use it directly.
proc opName(op: Op): string = $op

# --- Disassembler ---------------------------------------------------

proc disasmFunction(buf: var string, f: Function, label: string) =
  # Header. Trailing flags only appear when set.
  var flags = ""
  if f.isAsync:      flags.add(" async")
  if f.isGenerator:  flags.add(" generator")
  if f.isArrow:      flags.add(" arrow")
  if f.isClassCtor:  flags.add(" class-ctor")
  buf.add("\n=== " & label & "  code_len=" & $f.code.len &
    " regs=" & $f.registerCount & " fixed=" & $f.fixedRegs &
    " params=" & $f.paramCount & " consts=" & $f.constCount &
    " ics=" & $f.icCount & flags & " ===\n")

  # Global slot -> name lookup for this function.
  var gnames = initTable[uint32, string]()
  for g in f.globalNames:
    gnames[g.slot] = g.name

  var i = 0
  while i < f.code.len:
    let inst = f.code[i]
    let op = inst.op
    # `%5zu  %-20s`
    buf.add(padLeft($i, 5) & "  " & padRight(opName(op), 20))

    case op
    of LoadGlobal, LoadGlobalOrUndefined, StoreGlobal, DefineGlobal,
       StoreGlobalStrict:
      let slot = instBcU16(inst)
      let nm = if gnames.hasKey(uint32(slot)): gnames[uint32(slot)]
               else: builtinName(uint32(slot))
      # `r%-3u g%-4u ; %.*s`
      buf.add("r" & padRight($inst.a, 3) & " g" & padRight($slot, 4) & " ; " & nm)
    of LoadConst:
      let ci = instBcU16(inst)
      # `r%-3u const#%u`
      buf.add("r" & padRight($inst.a, 3) & " const#" & $ci)
      if int(ci) < f.constants.len:
        let cv = f.constants[int(ci)]
        case cv.kind
        of ckInt:      buf.add(" = " & $cv.i)
        of ckDouble:   buf.add(" = " & formatG(cv.d))
        of ckString:
          # C prints ` = "%.24s%s"` where `%.24s` walks `s->data` as a
          # NUL-terminated C string (stops at the first embedded NUL,
          # capped at 24 bytes), and the `...` suffix is gated on the
          # STORED length (`s->length > 24`) -- not the displayed slice.
          var disp = ""
          for j in 0 ..< cv.s.len:
            if j >= 24: break
            if cv.s[j] == '\0': break
            disp.add(cv.s[j])
          let ell = if cv.s.len > 24: "..." else: ""
          buf.add(" = \"" & disp & ell & "\"")
        of ckFunction: buf.add(" = <function>")
    of LoadInt:
      # `r%-3u = %d`
      buf.add("r" & padRight($inst.a, 3) & " = " & $instBcI16(inst))
    of Jmp:
      let off = instBcI16(inst)
      buf.add("-> " & $(i + 1 + int(off)))
    of JmpIfTrue, JmpIfFalse, JmpIfNullish, JmpIfNotNullish:
      let off = instBcI16(inst)
      buf.add("r" & padRight($inst.a, 3) & " -> " & $(i + 1 + int(off)))
    of JmpIfNotLt, JmpIfNotLe, JmpIfNotGt, JmpIfNotGe,
       JmpIfNotLtImm, JmpIfNotLeImm, JmpIfNotGtImm, JmpIfNotGeImm,
       JmpIfNotEq, JmpIfNotNe, JmpIfNotStrictEq, JmpIfNotStrictNe,
       JmpIfLt, JmpIfLe, JmpIfGt, JmpIfGe,
       JmpIfLtImm, JmpIfLeImm, JmpIfGtImm, JmpIfGeImm:
      # 2-slot fused compare-and-branch: operands here, i16 offset in the
      # J+1 carrier, branch base J+2. *Imm forms carry an i8 immediate in b.
      let coff = instBcI16(f.code[i + 1])
      let target = i + 2 + int(coff)
      let isImm = op in {JmpIfNotLtImm, JmpIfNotLeImm, JmpIfNotGtImm, JmpIfNotGeImm,
                         JmpIfLtImm, JmpIfLeImm, JmpIfGtImm, JmpIfGeImm}
      if isImm:
        buf.add("r" & padRight($inst.a, 3) & " imm=" & padRight($int(cast[int8](inst.b)), 4) &
          " -> " & $target & "  [carrier@" & $(i + 1) & "]")
      else:
        buf.add("r" & padRight($inst.a, 3) & " r" & padRight($inst.b, 3) &
          " -> " & $target & "  [carrier@" & $(i + 1) & "]")
      buf.add("\n")
      i = i + 1        # consume the carrier slot
      inc i
      continue
    of InvokeGlobal:
      # 2-slot fused global-callee call: operands here, u16 global slot in
      # the J+1 carrier. `r%-3u <- g%u(base=r%u argc=%u)  [carrier@N] ; name`.
      let gslot = instBcU16(f.code[i + 1])
      let gnm = if gnames.hasKey(uint32(gslot)): gnames[uint32(gslot)]
                else: builtinName(uint32(gslot))
      buf.add("r" & padRight($inst.a, 3) & " <- g" & $gslot &
        "(base=r" & $inst.b & " argc=" & $inst.c & ")  [carrier@" &
        $(i + 1) & "] ; " & gnm)
      buf.add("\n")
      i = i + 1        # consume the carrier slot
      inc i
      continue
    of Invoke, NewInvoke:
      buf.add("r" & padRight($inst.a, 3) & " <- base=r" & $inst.b & " argc=" & $inst.c)
    of MethodInvoke:
      buf.add("r" & padRight($inst.a, 3) & " <- base=r" & $inst.b &
        " recv=r" & $(uint(inst.b) + 1) & " argc=" & $inst.c)
    of TailInvoke, TailMethodInvoke:
      buf.add("base=r" & $inst.b & " argc=" & $inst.c)
    of LoadProp:
      # `r%-3u <- r%u.%s  ic#%u` -- a=dst, b=objReg, name from ics[c],
      # c=ic slot.
      let pn = if int(inst.c) < f.ics.len: f.ics[int(inst.c)] else: "?"
      buf.add("r" & padRight($inst.a, 3) & " <- r" & $inst.b & "." & pn &
        "  ic#" & $inst.c)
    of StoreProp:
      # `r%u.%s <- r%-3u  ic#%u` -- a=objReg, name from ics[b], value reg
      # is c, ic slot is b.
      let sn = if int(inst.b) < f.ics.len: f.ics[int(inst.b)] else: "?"
      buf.add("r" & $inst.a & "." & sn & " <- r" & padRight($inst.c, 3) &
        "  ic#" & $inst.b)
    of Mov:
      buf.add("r" & padRight($inst.a, 3) & " <- r" & $inst.b)
    of AddImm, SubImm, CmpLtImm, CmpLeImm, CmpGtImm, CmpGeImm:
      buf.add("r" & padRight($inst.a, 3) & " <- r" & $inst.b &
        ", imm=" & $int(cast[int8](inst.c)))
    of Return:
      buf.add("r" & $inst.a)
    else:
      # `a=%-3u b=%-3u c=%-3u | u16=%u i16=%d`
      buf.add("a=" & padRight($inst.a, 3) & " b=" & padRight($inst.b, 3) &
        " c=" & padRight($inst.c, 3) & " | u16=" & $instBcU16(inst) &
        " i16=" & $instBcI16(inst))
    buf.add("\n")
    inc i

  # Recurse into nested functions in the constant pool, in order.
  var k = 0
  while k < f.constants.len:
    let cv = f.constants[k]
    if cv.kind == ckFunction and cv.fn != nil:
      disasmFunction(buf, cv.fn, label & "/const#" & $k)
    inc k

proc disasmToString*(src: string): string =
  ## Parse + compile `src`, returning the `<program>` disasm text (or
  ## raising `ValueError` on parse / compile failure). Used by tests.
  var p = initParser(src)
  let root = p.parseProgram()
  if p.hadError:
    raise newException(ValueError, "parse error")
  let f = compileProgram(src, root)
  if f == nil:
    raise newException(ValueError, "compile error")
  result = ""
  disasmFunction(result, f, "<program>")

proc main() =
  if paramCount() < 1:
    stderr.write("usage: nim-disasm <file.js>\n")
    quit(2)
  let path = paramStr(1)
  var src: string
  try:
    src = readFile(path)
  except IOError:
    stderr.write("zjs: cannot open input\n")
    quit(2)

  var p = initParser(src)
  let root = p.parseProgram()
  if p.hadError:
    stderr.write("zjs: parse error\n")
    quit(1)
  let f = compileProgram(src, root)
  if f == nil:
    stderr.write("zjs: compile error\n")
    quit(1)

  var buf = ""
  disasmFunction(buf, f, "<program>")
  stdout.write(buf)

when isMainModule:
  main()
