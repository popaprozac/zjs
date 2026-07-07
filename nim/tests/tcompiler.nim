## Slice-1 compiler tests -- assert disasm TEXT is byte-identical to the
## `build/zjs disasm` oracle for the four scaffold targets.

import std/[unittest, strutils]
import ../tools/nim_disasm

const
  varX = "\n" &
    "=== <program>  code_len=4 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r1   = 1\n" &
    "    2  DefineGlobal        r1   g108  ; x\n" &
    "    3  Return              r0\n"

  exprOne = "\n" &
    "=== <program>  code_len=4 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r1   = 1\n" &
    "    2  Mov                 r0   <- r1\n" &
    "    3  Return              r0\n"

  varXvarY = "\n" &
    "=== <program>  code_len=6 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r1   = 1\n" &
    "    2  DefineGlobal        r1   g108  ; x\n" &
    "    3  LoadInt             r1   = 2\n" &
    "    4  DefineGlobal        r1   g109  ; y\n" &
    "    5  Return              r0\n"

  exprTrue = "\n" &
    "=== <program>  code_len=4 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadTrue            a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    2  Mov                 r0   <- r1\n" &
    "    3  Return              r0\n"

suite "slice 1 disasm byte-identity":
  test "var x = 1;":
    check disasmToString("var x = 1;") == varX

  test "1;":
    check disasmToString("1;") == exprOne

  test "var x = 1; var y = 2;":
    check disasmToString("var x = 1; var y = 2;") == varXvarY

  test "true;":
    check disasmToString("true;") == exprTrue

suite "slice 1 register model":
  test "single var -> regs=3 fixed=1":
    # regs = max_reg + 1; max_reg reaches 2 (r0 result + r1 temp).
    check "regs=3 fixed=1" in disasmToString("var x = 1;")

  test "null literal statement":
    let txt = disasmToString("null;")
    check "LoadNull" in txt
    check "Mov                 r0   <- r1" in txt
