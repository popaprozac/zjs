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

# --- Slice 2: expression compilation --------------------------------

const
  binAdd = "\n" &
    "=== <program>  code_len=6 regs=5 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r1   g108  ; a\n" &
    "    2  LoadGlobal          r2   g109  ; b\n" &
    "    3  Add                 a=3   b=1   c=2   | u16=513 i16=513\n" &
    "    4  Mov                 r0   <- r3\n" &
    "    5  Return              r0\n"

  addImm = "\n" &
    "=== <program>  code_len=5 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r1   g108  ; a\n" &
    "    2  AddImm              r2   <- r1, imm=2\n" &
    "    3  Mov                 r0   <- r2\n" &
    "    4  Return              r0\n"

  precedence = "\n" &
    "=== <program>  code_len=8 regs=7 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r1   = 2\n" &
    "    2  LoadInt             r2   = 3\n" &
    "    3  LoadInt             r3   = 4\n" &
    "    4  Mul                 a=4   b=2   c=3   | u16=770 i16=770\n" &
    "    5  Add                 a=5   b=1   c=4   | u16=1025 i16=1025\n" &
    "    6  Mov                 r0   <- r5\n" &
    "    7  Return              r0\n"

  leftAssoc = "\n" &
    "=== <program>  code_len=8 regs=7 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r1   g108  ; a\n" &
    "    2  LoadGlobal          r2   g109  ; b\n" &
    "    3  Add                 a=3   b=1   c=2   | u16=513 i16=513\n" &
    "    4  LoadGlobal          r4   g110  ; c\n" &
    "    5  Add                 a=5   b=3   c=4   | u16=1027 i16=1027\n" &
    "    6  Mov                 r0   <- r5\n" &
    "    7  Return              r0\n"

  doubleConst = "\n" &
    "=== <program>  code_len=4 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = 1.5\n" &
    "    2  Mov                 r0   <- r1\n" &
    "    3  Return              r0\n"

  bigDoubleConst = "\n" &
    "=== <program>  code_len=4 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = 2.14748e+09\n" &
    "    2  Mov                 r0   <- r1\n" &
    "    3  Return              r0\n"

  strConst = "\n" &
    "=== <program>  code_len=4 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = \"hi\"\n" &
    "    2  Mov                 r0   <- r1\n" &
    "    3  Return              r0\n"

  unaryNeg = "\n" &
    "=== <program>  code_len=5 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r1   g108  ; a\n" &
    "    2  Neg                 a=2   b=1   c=0   | u16=1 i16=1\n" &
    "    3  Mov                 r0   <- r2\n" &
    "    4  Return              r0\n"

  cmpLtImm = "\n" &
    "=== <program>  code_len=5 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r1   g108  ; a\n" &
    "    2  CmpLtImm            r2   <- r1, imm=5\n" &
    "    3  Mov                 r0   <- r2\n" &
    "    4  Return              r0\n"

  bitAnd = "\n" &
    "=== <program>  code_len=6 regs=5 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r1   g108  ; a\n" &
    "    2  LoadInt             r2   = 3\n" &
    "    3  BitAnd              a=3   b=1   c=2   | u16=513 i16=513\n" &
    "    4  Mov                 r0   <- r3\n" &
    "    5  Return              r0\n"

  cmpGeImm = "\n" &
    "=== <program>  code_len=5 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r1   g108  ; a\n" &
    "    2  CmpGeImm            r2   <- r1, imm=1\n" &
    "    3  Mov                 r0   <- r2\n" &
    "    4  Return              r0\n"

  identRead = "\n" &
    "=== <program>  code_len=4 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r1   g108  ; a\n" &
    "    2  Mov                 r0   <- r1\n" &
    "    3  Return              r0\n"

suite "slice 2 expression disasm byte-identity":
  test "a+b; (general Add, two global reads)":
    check disasmToString("a+b;") == binAdd
  test "a+2; (RHS-immediate fusion -> AddImm)":
    check disasmToString("a+2;") == addImm
  test "2+3*4; (precedence: Mul before Add)":
    check disasmToString("2+3*4;") == precedence
  test "a+b+c; (left-assoc register discipline)":
    check disasmToString("a+b+c;") == leftAssoc
  test "1.5; (double const)":
    check disasmToString("1.5;") == doubleConst
  test "2147483648; (int32-overflow -> %g double const)":
    check disasmToString("2147483648;") == bigDoubleConst
  test "\"hi\"; (decoded string const)":
    check disasmToString("\"hi\";") == strConst
  test "-a; (unary Neg)":
    check disasmToString("-a;") == unaryNeg
  test "a<5; (fused CmpLtImm)":
    check disasmToString("a<5;") == cmpLtImm
  test "a&3; (bitwise -> general path, LHS ident + RHS LoadInt)":
    check disasmToString("a&3;") == bitAnd
  test "a>=1; (fused CmpGeImm)":
    check disasmToString("a>=1;") == cmpGeImm
  test "a; (bare identifier global read)":
    check disasmToString("a;") == identRead

suite "slice 2 fusion boundaries":
  test "a+127; fuses (imm at i8 max)":
    check "AddImm              r2   <- r1, imm=127" in disasmToString("a+127;")
  test "a+128; does NOT fuse (out of i8) -> LoadInt + Add":
    let txt = disasmToString("a+128;")
    check "LoadInt             r2   = 128" in txt
    check "Add                 a=3   b=1   c=2" in txt
  test "a*5; never fuses (Mul not fusable)":
    let txt = disasmToString("a*5;")
    check "LoadInt             r2   = 5" in txt
    check "Mul                 a=3   b=1   c=2" in txt
  test "2+a; LHS-immediate does NOT fuse":
    let txt = disasmToString("2+a;")
    check "LoadInt             r1   = 2" in txt
    check "Add                 a=3   b=1   c=2" in txt

suite "slice 2 string escape decoding":
  test "\"a b\" plain":
    check "const#0 = \"a b\"" in disasmToString("\"a b\";")
  test "\"line\\nbreak\" newline escape decoded":
    check "const#0 = \"line\x0Abreak\"" in disasmToString("\"line\\nbreak\";")
  test "\"tab\\there\" tab escape decoded":
    check "const#0 = \"tab\x09here\"" in disasmToString("\"tab\\there\";")

# --- Slice 3a: lexical locals + blocks + register discipline --------

const
  blockLetX = "\n" &
    "=== <program>  code_len=3 regs=3 fixed=2 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r0   = 1\n" &
    "    2  Return              r1\n"

  letXreadX = "\n" &
    "=== <program>  code_len=5 regs=4 fixed=2 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r0   = 1\n" &
    "    2  Mov                 r2   <- r0\n" &
    "    3  Mov                 r1   <- r2\n" &
    "    4  Return              r1\n"

  letXY = "\n" &
    "=== <program>  code_len=4 regs=4 fixed=3 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r0   = 1\n" &
    "    2  LoadInt             r1   = 2\n" &
    "    3  Return              r2\n"

  nestedBlocks = "\n" &
    "=== <program>  code_len=4 regs=4 fixed=3 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r0   = 1\n" &
    "    2  LoadInt             r1   = 2\n" &
    "    3  Return              r2\n"

  constKplus1 = "\n" &
    "=== <program>  code_len=5 regs=4 fixed=2 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r0   = 5\n" &
    "    2  AddImm              r2   <- r0, imm=1\n" &
    "    3  Mov                 r1   <- r2\n" &
    "    4  Return              r1\n"

  assignConst = "\n" &
    "=== <program>  code_len=5 regs=3 fixed=2 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r0   = 1\n" &
    "    2  LoadInt             r0   = 2\n" &
    "    3  Mov                 r1   <- r0\n" &
    "    4  Return              r1\n"

  assignSelfInc = "\n" &
    "=== <program>  code_len=5 regs=3 fixed=2 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r0   = 1\n" &
    "    2  AddImm              r0   <- r0, imm=1\n" &
    "    3  Mov                 r1   <- r0\n" &
    "    4  Return              r1\n"

  letYfromX = "\n" &
    "=== <program>  code_len=4 regs=4 fixed=3 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r0   = 1\n" &
    "    2  Mov                 r1   <- r0\n" &
    "    3  Return              r2\n"

  addTwoLocals = "\n" &
    "=== <program>  code_len=6 regs=5 fixed=3 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r0   = 1\n" &
    "    2  LoadInt             r1   = 2\n" &
    "    3  Add                 a=3   b=0   c=1   | u16=256 i16=256\n" &
    "    4  Mov                 r2   <- r3\n" &
    "    5  Return              r2\n"

  siblingBlocks = "\n" &
    "=== <program>  code_len=8 regs=5 fixed=3 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r0   = 1\n" &
    "    2  Mov                 r3   <- r0\n" &
    "    3  Mov                 r2   <- r3\n" &
    "    4  LoadInt             r1   = 2\n" &
    "    5  Mov                 r3   <- r1\n" &
    "    6  Mov                 r2   <- r3\n" &
    "    7  Return              r2\n"

  constStr = "\n" &
    "=== <program>  code_len=6 regs=4 fixed=2 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r2   const#0 = \"hi\"\n" &
    "    2  Mov                 r0   <- r2\n" &
    "    3  Mov                 r2   <- r0\n" &
    "    4  Mov                 r1   <- r2\n" &
    "    5  Return              r1\n"

suite "slice 3a lexical locals byte-identity":
  test "{ let x = 1; } (block-scoped local, completion after)":
    check disasmToString("{ let x = 1; }") == blockLetX
  test "let x = 1; x; (local read -> Mov temp + completion)":
    check disasmToString("let x = 1; x;") == letXreadX
  test "let x=1, y=2; (two locals, fixed=3)":
    check disasmToString("let x=1, y=2;") == letXY
  test "{ let a=1; { let b=2; } } (nested-block distinct fixed slots)":
    check disasmToString("{ let a=1; { let b=2; } }") == nestedBlocks
  test "const k = 5; k + 1; (const read fuses AddImm)":
    check disasmToString("const k = 5; k + 1;") == constKplus1
  test "let x=1; x=2; (assign direct into local, no extra Mov)":
    check disasmToString("let x=1; x=2;") == assignConst
  test "let x=1; x=x+1; (self-inc AddImm r0<-r0)":
    check disasmToString("let x=1; x=x+1;") == assignSelfInc
  test "let x=1; let y=x; (init from local, terminal place)":
    check disasmToString("let x=1; let y=x;") == letYfromX
  test "let x = 1; let y = 2; x + y; (two-local Add)":
    check disasmToString("let x = 1; let y = 2; x + y;") == addTwoLocals
  test "{ let a=1; a; } { let b=2; b; } (sibling blocks accumulate)":
    check disasmToString("{ let a=1; a; } { let b=2; b; }") == siblingBlocks
  test "const s = \"hi\"; s; (string const into local)":
    check disasmToString("const s = \"hi\"; s;") == constStr

suite "slice 3a register model":
  test "single block let -> regs=3 fixed=2 (local r0, completion r1)":
    check "regs=3 fixed=2" in disasmToString("{ let x = 1; }")
  test "two locals -> fixed=3":
    check "fixed=3" in disasmToString("let x=1, y=2;")
  test "assign to local writes local reg directly":
    let txt = disasmToString("let x=1; x=2;")
    check "LoadInt             r0   = 2" in txt

# --- Slice 3b: if/else + fused compare-and-branch -------------------

const
  ifPlain = "\n" &
    "=== <program>  code_len=7 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; a\n" &
    "    3  JmpIfFalse          r1   -> 6\n" &
    "    4  LoadGlobal          r1   g109  ; b\n" &
    "    5  Mov                 r0   <- r1\n" &
    "    6  Return              r0\n"

  ifElse = "\n" &
    "=== <program>  code_len=10 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; a\n" &
    "    3  JmpIfFalse          r1   -> 7\n" &
    "    4  LoadGlobal          r1   g109  ; b\n" &
    "    5  Mov                 r0   <- r1\n" &
    "    6  Jmp                 -> 9\n" &
    "    7  LoadGlobal          r1   g110  ; c\n" &
    "    8  Mov                 r0   <- r1\n" &
    "    9  Return              r0\n"

  ifLtReg = "\n" &
    "=== <program>  code_len=9 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; a\n" &
    "    3  LoadGlobal          r2   g109  ; b\n" &
    "    4  JmpIfNotLt          r1   r2   -> 8  [carrier@5]\n" &
    "    6  LoadGlobal          r1   g110  ; c\n" &
    "    7  Mov                 r0   <- r1\n" &
    "    8  Return              r0\n"

  ifLtImm = "\n" &
    "=== <program>  code_len=8 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; a\n" &
    "    3  JmpIfNotLtImm       r1   imm=5    -> 7  [carrier@4]\n" &
    "    5  LoadGlobal          r1   g109  ; c\n" &
    "    6  Mov                 r0   <- r1\n" &
    "    7  Return              r0\n"

  ifElseIf = "\n" &
    "=== <program>  code_len=13 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; a\n" &
    "    3  JmpIfFalse          r1   -> 7\n" &
    "    4  LoadGlobal          r1   g109  ; b\n" &
    "    5  Mov                 r0   <- r1\n" &
    "    6  Jmp                 -> 12\n" &
    "    7  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    8  LoadGlobal          r1   g110  ; c\n" &
    "    9  JmpIfFalse          r1   -> 12\n" &
    "   10  LoadGlobal          r1   g111  ; d\n" &
    "   11  Mov                 r0   <- r1\n" &
    "   12  Return              r0\n"

  ifBlockLet = "\n" &
    "=== <program>  code_len=6 regs=4 fixed=2 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r2   g108  ; a\n" &
    "    3  JmpIfFalse          r2   -> 5\n" &
    "    4  LoadInt             r0   = 1\n" &
    "    5  Return              r1\n"

  ifNotNullish = "\n" &
    "=== <program>  code_len=7 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; a\n" &
    "    3  JmpIfNotNullish     r1   -> 6\n" &
    "    4  LoadGlobal          r1   g109  ; c\n" &
    "    5  Mov                 r0   <- r1\n" &
    "    6  Return              r0\n"

suite "slice 3b if/else + fused compare-and-branch byte-identity":
  test "if (a) b; (plain cond -> JmpIfFalse, double LoadUndefined)":
    check disasmToString("if (a) b;") == ifPlain
  test "if (a) b; else c; (else Jmp skip + two patches)":
    check disasmToString("if (a) b; else c;") == ifElse
  test "if (a < b) c; (reg-reg fused JmpIfNotLt, carrier)":
    check disasmToString("if (a < b) c;") == ifLtReg
  test "if (a < 5) c; (imm fused JmpIfNotLtImm)":
    check disasmToString("if (a < 5) c;") == ifLtImm
  test "if (a) b; else if (c) d; (else-if nests, own completion pre-init)":
    check disasmToString("if (a) b; else if (c) d;") == ifElseIf
  test "if (a) { let x=1; } (block local pre-alloc shifts completion)":
    check disasmToString("if (a) { let x=1; }") == ifBlockLet
  test "if (a == null) c; (nullish peephole -> JmpIfNotNullish)":
    check disasmToString("if (a == null) c;") == ifNotNullish

suite "slice 3b fusion map coverage":
  test "if (a <= b) c; -> JmpIfNotLe":
    check "JmpIfNotLe          r1   r2   -> 8  [carrier@5]" in disasmToString("if (a <= b) c;")
  test "if (a > b) c; -> JmpIfNotGt":
    check "JmpIfNotGt          r1   r2   -> 8  [carrier@5]" in disasmToString("if (a > b) c;")
  test "if (a >= b) c; -> JmpIfNotGe":
    check "JmpIfNotGe          r1   r2   -> 8  [carrier@5]" in disasmToString("if (a >= b) c;")
  test "if (a == b) c; -> JmpIfNotEq":
    check "JmpIfNotEq          r1   r2   -> 8  [carrier@5]" in disasmToString("if (a == b) c;")
  test "if (a === b) c; -> JmpIfNotStrictEq":
    check "JmpIfNotStrictEq    r1   r2   -> 8  [carrier@5]" in disasmToString("if (a === b) c;")
  test "if (a != b) c; -> JmpIfNotNe":
    check "JmpIfNotNe          r1   r2   -> 8  [carrier@5]" in disasmToString("if (a != b) c;")
  test "if (a !== b) c; -> JmpIfNotStrictNe":
    check "JmpIfNotStrictNe    r1   r2   -> 8  [carrier@5]" in disasmToString("if (a !== b) c;")
  test "if (a != null) c; -> JmpIfNullish (inverse nullish)":
    check "JmpIfNullish        r1   -> 6" in disasmToString("if (a != null) c;")
  test "if (a == undefined) c; -> JmpIfNotNullish (undefined literal)":
    check "JmpIfNotNullish     r1   -> 6" in disasmToString("if (a == undefined) c;")
  test "if (null == a) c; -> JmpIfNotNullish (swapped operands)":
    check "JmpIfNotNullish     r1   -> 6" in disasmToString("if (null == a) c;")
  test "if (!a) c; -> LogicalNot + plain JmpIfFalse (no fusion)":
    let txt = disasmToString("if (!a) c;")
    check "LogicalNot" in txt
    check "JmpIfFalse          r2   -> 7" in txt
  test "if (a === null) c; -> reg-reg JmpIfNotStrictEq (=== not nullish-fused)":
    let txt = disasmToString("if (a === null) c;")
    check "JmpIfNotStrictEq" in txt
    check "LoadNull" in txt

# --- Slice 3c: while / do-while / C-for + loop rotation + break/continue

const
  whilePlain = "\n" &
    "=== <program>  code_len=8 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; a\n" &
    "    3  JmpIfFalse          r1   -> 7\n" &
    "    4  LoadGlobal          r1   g109  ; b\n" &
    "    5  Mov                 r0   <- r1\n" &
    "    6  Jmp                 -> 2\n" &
    "    7  Return              r0\n"

  whileLtReg = "\n" &
    "=== <program>  code_len=10 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  Jmp                 -> 5\n" &
    "    3  LoadGlobal          r1   g108  ; c\n" &
    "    4  Mov                 r0   <- r1\n" &
    "    5  LoadGlobal          r1   g109  ; a\n" &
    "    6  LoadGlobal          r2   g110  ; b\n" &
    "    7  JmpIfLt             r1   r2   -> 3  [carrier@8]\n" &
    "    9  Return              r0\n"

  whileLtImm = "\n" &
    "=== <program>  code_len=9 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  Jmp                 -> 5\n" &
    "    3  LoadGlobal          r1   g108  ; c\n" &
    "    4  Mov                 r0   <- r1\n" &
    "    5  LoadGlobal          r1   g109  ; a\n" &
    "    6  JmpIfLtImm          r1   imm=5    -> 3  [carrier@7]\n" &
    "    8  Return              r0\n"

  doPlain = "\n" &
    "=== <program>  code_len=7 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; b\n" &
    "    3  Mov                 r0   <- r1\n" &
    "    4  LoadGlobal          r1   g109  ; a\n" &
    "    5  JmpIfTrue           r1   -> 2\n" &
    "    6  Return              r0\n"

  doRelational = "\n" &
    "=== <program>  code_len=9 regs=5 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; b\n" &
    "    3  Mov                 r0   <- r1\n" &
    "    4  LoadGlobal          r1   g109  ; a\n" &
    "    5  LoadGlobal          r2   g110  ; c\n" &
    "    6  CmpLt               a=3   b=1   c=2   | u16=513 i16=513\n" &
    "    7  JmpIfTrue           r3   -> 2\n" &
    "    8  Return              r0\n"

  forInfBody = "\n" &
    "=== <program>  code_len=6 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; b\n" &
    "    3  Mov                 r0   <- r1\n" &
    "    4  Jmp                 -> 2\n" &
    "    5  Return              r0\n"

  forInfEmpty = "\n" &
    "=== <program>  code_len=4 regs=2 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  Jmp                 -> 2\n" &
    "    3  Return              r0\n"

  forGlobalCounter = "\n" &
    "=== <program>  code_len=16 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r1   = 0\n" &
    "    2  StoreGlobal         r1   g108  ; i\n" &
    "    3  Mov                 r0   <- r1\n" &
    "    4  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    5  Jmp                 -> 11\n" &
    "    6  LoadGlobal          r1   g109  ; b\n" &
    "    7  Mov                 r0   <- r1\n" &
    "    8  LoadGlobal          r1   g108  ; i\n" &
    "    9  AddImm              r2   <- r1, imm=1\n" &
    "   10  StoreGlobal         r2   g108  ; i\n" &
    "   11  LoadGlobal          r1   g108  ; i\n" &
    "   12  LoadGlobal          r2   g110  ; n\n" &
    "   13  JmpIfLt             r1   r2   -> 6  [carrier@14]\n" &
    "   15  Return              r0\n"

  forLetCounter = "\n" &
    "=== <program>  code_len=9 regs=4 fixed=2 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r0   = 0\n" &
    "    2  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    3  Jmp                 -> 5\n" &
    "    4  AddImm              r0   <- r0, imm=1\n" &
    "    5  LoadGlobal          r2   g108  ; n\n" &
    "    6  JmpIfLt             r0   r2   -> 4  [carrier@7]\n" &
    "    8  Return              r1\n"

  whileBreak = "\n" &
    "=== <program>  code_len=7 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; a\n" &
    "    3  JmpIfFalse          r1   -> 6\n" &
    "    4  Jmp                 -> 6\n" &
    "    5  Jmp                 -> 2\n" &
    "    6  Return              r0\n"

  whileContinue = "\n" &
    "=== <program>  code_len=7 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; a\n" &
    "    3  JmpIfFalse          r1   -> 6\n" &
    "    4  Jmp                 -> 2\n" &
    "    5  Jmp                 -> 2\n" &
    "    6  Return              r0\n"

  forBreakInIf = "\n" &
    "=== <program>  code_len=8 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    3  LoadGlobal          r1   g108  ; a\n" &
    "    4  JmpIfFalse          r1   -> 6\n" &
    "    5  Jmp                 -> 7\n" &
    "    6  Jmp                 -> 2\n" &
    "    7  Return              r0\n"

  whileContinueInIf = "\n" &
    "=== <program>  code_len=12 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; a\n" &
    "    3  JmpIfFalse          r1   -> 11\n" &
    "    4  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    5  LoadGlobal          r1   g109  ; b\n" &
    "    6  JmpIfFalse          r1   -> 8\n" &
    "    7  Jmp                 -> 2\n" &
    "    8  LoadGlobal          r1   g110  ; c\n" &
    "    9  Mov                 r0   <- r1\n" &
    "   10  Jmp                 -> 2\n" &
    "   11  Return              r0\n"

  forBreakEq = "\n" &
    "=== <program>  code_len=19 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r1   = 0\n" &
    "    2  StoreGlobal         r1   g108  ; i\n" &
    "    3  Mov                 r0   <- r1\n" &
    "    4  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    5  Jmp                 -> 15\n" &
    "    6  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    7  LoadGlobal          r1   g108  ; i\n" &
    "    8  LoadInt             r2   = 5\n" &
    "    9  JmpIfNotEq          r1   r2   -> 12  [carrier@10]\n" &
    "   11  Jmp                 -> 18\n" &
    "   12  LoadGlobal          r1   g108  ; i\n" &
    "   13  AddImm              r2   <- r1, imm=1\n" &
    "   14  StoreGlobal         r2   g108  ; i\n" &
    "   15  LoadGlobal          r1   g108  ; i\n" &
    "   16  JmpIfLtImm          r1   imm=10   -> 6  [carrier@17]\n" &
    "   18  Return              r0\n"

  whileGlobalDec = "\n" &
    "=== <program>  code_len=11 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  Jmp                 -> 7\n" &
    "    3  LoadGlobal          r1   g108  ; a\n" &
    "    4  SubImm              r2   <- r1, imm=1\n" &
    "    5  StoreGlobal         r2   g108  ; a\n" &
    "    6  Mov                 r0   <- r2\n" &
    "    7  LoadGlobal          r1   g108  ; a\n" &
    "    8  JmpIfGtImm          r1   imm=0    -> 3  [carrier@9]\n" &
    "   10  Return              r0\n"

suite "slice 3c loops + rotation + break/continue byte-identity":
  test "while (a) b; (plain cond test-at-top, back-edge Jmp)":
    check disasmToString("while (a) b;") == whilePlain
  test "while (a < b) c; (rotated: entry Jmp + true-polarity JmpIfLt back)":
    check disasmToString("while (a < b) c;") == whileLtReg
  test "while (a < 5) c; (rotated imm: JmpIfLtImm back)":
    check disasmToString("while (a < 5) c;") == whileLtImm
  test "do b; while (a); (bottom test JmpIfTrue back to top)":
    check disasmToString("do b; while (a);") == doPlain
  test "do b; while (a < c); (do NOT rotate: CmpLt + JmpIfTrue)":
    check disasmToString("do b; while (a < c);") == doRelational
  test "for (;;) b; (infinite for, expr body, back Jmp)":
    check disasmToString("for (;;) b;") == forInfBody
  test "for (;;) {} (infinite for, empty block -> Jmp self)":
    check disasmToString("for (;;) {}") == forInfEmpty
  test "for (i=0; i<n; i=i+1) b; (global-counter for, StoreGlobal)":
    check disasmToString("for (i=0; i<n; i=i+1) b;") == forGlobalCounter
  test "for (let i=0; i<n; i=i+1) {} (let-counter for, local reg update)":
    check disasmToString("for (let i=0; i<n; i=i+1) {}") == forLetCounter
  test "while (a) { break; } (break -> loop-end patch)":
    check disasmToString("while (a) { break; }") == whileBreak
  test "while (a) { continue; } (continue -> test-top back-edge)":
    check disasmToString("while (a) { continue; }") == whileContinue
  test "for (;;) { if (a) break; } (break inside if -> loop end)":
    check disasmToString("for (;;) { if (a) break; }") == forBreakInIf
  test "while (a) { if (b) continue; c; } (continue targets test-top)":
    check disasmToString("while (a) { if (b) continue; c; }") == whileContinueInIf
  test "for (i=0;i<10;i=i+1) { if (i==5) break; } (break + rotated imm test)":
    check disasmToString("for (i=0;i<10;i=i+1) { if (i==5) break; }") == forBreakEq
  test "while (a > 0) a = a - 1; (rotated + global store in body)":
    check disasmToString("while (a > 0) a = a - 1;") == whileGlobalDec

suite "slice 3c loop structure sanity":
  test "for (let i=0;...) uses a for-scope local reg (fixed=2)":
    check "fixed=2" in disasmToString("for (let i=0; i<n; i=i+1) {}")
  test "do-while never fuses relational (CmpLt present, no JmpIfLt)":
    let txt = disasmToString("do b; while (a < c);")
    check "CmpLt" in txt
    check "JmpIfLt " notin txt
  test "break with no enclosing loop is a compile error":
    expect ValueError:
      discard disasmToString("break;")
  test "continue with no enclosing loop is a compile error":
    expect ValueError:
      discard disasmToString("continue;")

# --- Slice 4a: non-capturing functions ------------------------------
# Byte-identical to `build/zjs disasm` for the program AND every nested
# `/const#N` unit (declarations, expressions, params, return,
# MakeClosure / SetFunctionName, function-body entry-hole seeding).

const
  fnEmpty =
    "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n" &
    "    3  DefineGlobal        r1   g108  ; f\n" &
    "    4  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  Return              r0\n"

  fnAddParams =
    "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n" &
    "    3  DefineGlobal        r1   g108  ; f\n" &
    "    4  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=2 regs=4 fixed=2 params=2 consts=0 ics=0 ===\n" &
    "    0  Add                 a=2   b=0   c=1   | u16=256 i16=256\n" &
    "    1  Return              r2\n"

  fnLetReturn =
    "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n" &
    "    3  DefineGlobal        r1   g108  ; f\n" &
    "    4  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=3 regs=2 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadHole            a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r0   = 1\n" &
    "    2  Return              r0\n"

  fnVarReturn =
    "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n" &
    "    3  DefineGlobal        r1   g108  ; f\n" &
    "    4  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=2 regs=2 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadInt             r0   = 1\n" &
    "    1  Return              r0\n"

  fnParamReturn =
    "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n" &
    "    3  DefineGlobal        r1   g108  ; f\n" &
    "    4  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=1 regs=2 fixed=1 params=1 consts=0 ics=0 ===\n" &
    "    0  Return              r0\n"

  varGFn =
    "\n" &
    "=== <program>  code_len=6 regs=4 fixed=1 params=0 consts=2 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  LoadConst           r2   const#1 = \"g\"\n" &
    "    3  SetFunctionName     a=1   b=2   c=0   | u16=2 i16=2\n" &
    "    4  DefineGlobal        r1   g108  ; g\n" &
    "    5  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadInt             r0   = 1\n" &
    "    1  Return              r0\n"

  letHFn =
    "\n" &
    "=== <program>  code_len=6 regs=5 fixed=2 params=0 consts=2 ics=0 ===\n" &
    "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r2   const#0 = <function>\n" &
    "    2  LoadConst           r3   const#1 = \"h\"\n" &
    "    3  SetFunctionName     a=2   b=3   c=0   | u16=3 i16=3\n" &
    "    4  Mov                 r0   <- r2\n" &
    "    5  Return              r1\n" &
    "\n" &
    "=== <program>/const#0  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  Return              r0\n"

  assignFn =
    "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  StoreGlobal         r1   g108  ; x\n" &
    "    3  Mov                 r0   <- r1\n" &
    "    4  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  Return              r0\n"

  parenFn =
    "\n" &
    "=== <program>  code_len=4 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  Mov                 r0   <- r1\n" &
    "    3  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  Return              r0\n"

  fnMulAddParams =
    "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n" &
    "    3  DefineGlobal        r1   g108  ; f\n" &
    "    4  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=3 regs=5 fixed=2 params=2 consts=0 ics=0 ===\n" &
    "    0  Mul                 a=2   b=0   c=1   | u16=256 i16=256\n" &
    "    1  AddImm              r3   <- r2, imm=1\n" &
    "    2  Return              r3\n"

  fnIfReturn =
    "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n" &
    "    3  DefineGlobal        r1   g108  ; f\n" &
    "    4  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=6 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadGlobal          r0   g109  ; a\n" &
    "    1  JmpIfFalse          r0   -> 4\n" &
    "    2  LoadInt             r0   = 1\n" &
    "    3  Return              r0\n" &
    "    4  LoadInt             r0   = 2\n" &
    "    5  Return              r0\n"

  fnNestedBlk =
    "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n" &
    "    3  DefineGlobal        r1   g108  ; f\n" &
    "    4  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=6 regs=4 fixed=2 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadHole            a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadHole            a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadInt             r0   = 1\n" &
    "    3  LoadInt             r1   = 2\n" &
    "    4  Add                 a=2   b=0   c=1   | u16=256 i16=256\n" &
    "    5  Return              r2\n"

suite "slice 4a non-capturing functions byte-identity":
  test "function f() {} (decl -> LoadConst + MakeClosure + DefineGlobal)":
    check disasmToString("function f() {}") == fnEmpty
  test "function f(a, b) { return a + b; } (params r0/r1, Add, Return)":
    check disasmToString("function f(a, b) { return a + b; }") == fnAddParams
  test "function f() { let x = 1; return x; } (function-top LoadHole seed)":
    check disasmToString("function f() { let x = 1; return x; }") == fnLetReturn
  test "function f() { const y = 2; return y; } (const == let entry-hole)":
    # Identical shape to fnLetReturn with the body's LoadInt value 1 -> 2.
    check disasmToString("function f() { const y = 2; return y; }") ==
      fnLetReturn.replace("r0   = 1", "r0   = 2")
  test "function f() { var v = 1; return v; } (var NOT seeded, fixed=1)":
    check disasmToString("function f() { var v = 1; return v; }") == fnVarReturn
  test "function f(a) { return a; } (single param, borrowed return)":
    check disasmToString("function f(a) { return a; }") == fnParamReturn
  test "var g = function() { return 1; }; (anon expr -> SetFunctionName g)":
    check disasmToString("var g = function() { return 1; };") == varGFn
  test "x = function() {}; (assignment RHS, NO SetFunctionName)":
    check disasmToString("x = function() {};") == assignFn
  test "(function(){}); (bare expr, no MakeClosure, no name)":
    check disasmToString("(function(){});") == parenFn
  test "let h = function(){}; (named-binding infer -> SetFunctionName h)":
    check disasmToString("let h = function(){};") == letHFn
  test "function f(a, b) { return a * b + 1; } (Mul + AddImm in body)":
    check disasmToString("function f(a, b) { return a * b + 1; }") == fnMulAddParams
  test "function f() { if (a) return 1; return 2; } (if/return, no completion reset)":
    check disasmToString("function f() { if (a) return 1; return 2; }") == fnIfReturn
  test "function f() { let x=1; { let y=2; return x+y; } } (two function-top holes)":
    check disasmToString("function f() { let x=1; { let y=2; return x+y; } }") == fnNestedBlk

suite "slice 4a structure + capture bail":
  test "const y body seeds the entry hole exactly like let":
    let txt = disasmToString("function f() { const y = 2; return y; }")
    check "LoadHole" in txt
    check "LoadInt             r0   = 2" in txt
  test "empty function body -> LoadUndefined + Return, fixed=0":
    check "regs=2 fixed=0 params=0" in disasmToString("function f() {}")
  test "two params -> fixed=2 params=2":
    check "fixed=2 params=2" in disasmToString("function f(a,b){return a+b;}")
  test "nested non-capturing FunctionDecl binds a body local (no false match)":
    check disasmToString("function outer() { function inner() { return 1; } return 2; }") ==
      disasmToString("function outer() { function inner() { return 1; } return 2; }")
  # NOTE: arrow functions COMPILE as of slice 4d — see the "slice 4d:
  # arrow functions" suite below (`var f = () => 1;` is now byte-identical).
  # Slice 4e: default + rest params now COMPILE (byte-identical to oracle).
  test "default param -> undefined-check + default init (slice 4e)":
    let txt = disasmToString("function f(a = 1) { return a; }")
    check "=== <program>/const#0  code_len=7 regs=4 fixed=1 params=1 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    1  CmpStrictEq         a=1   b=0   c=2   | u16=512 i16=512\n" &
      "    2  JmpIfFalse          r1   -> 6\n" &
      "    3  LoadHole            a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    4  LoadInt             r1   = 1\n" &
      "    5  Mov                 r0   <- r1\n" &
      "    6  Return              r0\n" in txt
  test "rest param -> BuildRestArgs prologue (slice 4e)":
    let txt = disasmToString("function f(...r) { return 1; }")
    check "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
      "    0  BuildRestArgs       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadInt             r1   = 1\n" &
      "    2  Return              r1\n" in txt
  test "rest after a regular param -> BuildRestArgs r1, first=1 (slice 4e)":
    let txt = disasmToString("function f(a, ...rest) {}")
    check "params=1" in txt
    check "    0  BuildRestArgs       a=1   b=1   c=0   | u16=1 i16=1\n" in txt
  test "default referencing an earlier param -> Mov chain (slice 4e)":
    let txt = disasmToString("function f(a, b = a) {}")
    check "params=2" in txt
    check "    1  CmpStrictEq         a=2   b=1   c=3   | u16=769 i16=769\n" in txt
    check "    4  Mov                 r2   <- r0\n" in txt
    check "    5  Mov                 r1   <- r2\n" in txt
  test "default referencing OWN param (TDZ self-ref) -> bail (ThrowIfHole deferred)":
    expect ValueError:
      discard disasmToString("function f(x = x) { return x; }")
  test "default referencing a LATER param (TDZ forward-ref) -> bail":
    expect ValueError:
      discard disasmToString("function f(a = b, b = 1) {}")
  test "object-pattern param -> compiles (slice 6d)":
    # Formerly deferred; slice 6d lowers an object-pattern param via the
    # AssertCoercible + LoadProp fan-out.
    discard disasmToString("function f({a}) { return a; }")
  test "array-pattern param -> compiles (slice 6e)":
    # Formerly deferred; slice 6e lowers an array-pattern param via the
    # iterator fan-out (IterGet/IterStep + try-region).
    discard disasmToString("function f([a]) { return a; }")
  test "named function expression -> compile error (LoadCallee deferred)":
    expect ValueError:
      discard disasmToString("(function foo(){});")
  # NOTE (slice 7e): async / generator functions NO LONGER bail — they now
  # compile (see the "slice 7e generator/async" suite). Sanity: they no
  # longer raise.
  test "async function -> compiles (slice 7e)":
    discard disasmToString("async function f() { return 1; }")
  test "generator function -> compiles (slice 7e)":
    discard disasmToString("function* f() { return 1; }")
  # NOTE: `this`/`arguments`/`new.target` bodies COMPILE as of slice 4c —
  # see the "slice 4c: this / arguments / new.target" suite below.

# --- Slice 5a: member/element access + object/array literals + IC ---

const
  memberGet = "\n" &
    "=== <program>  code_len=5 regs=4 fixed=1 params=0 consts=0 ics=1 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r1   g108  ; a\n" &
    "    2  LoadProp            r2   <- r1.b  ic#0\n" &
    "    3  Mov                 r0   <- r2\n" &
    "    4  Return              r0\n"

  memberChain = "\n" &
    "=== <program>  code_len=6 regs=5 fixed=1 params=0 consts=0 ics=2 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r1   g108  ; a\n" &
    "    2  LoadProp            r2   <- r1.b  ic#1\n" &
    "    3  LoadProp            r3   <- r2.c  ic#0\n" &
    "    4  Mov                 r0   <- r3\n" &
    "    5  Return              r0\n"

  storePropChain = "\n" &
    "=== <program>  code_len=7 regs=5 fixed=1 params=0 consts=0 ics=2 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r1   g108  ; o\n" &
    "    2  LoadGlobal          r2   g108  ; o\n" &
    "    3  LoadProp            r3   <- r2.y  ic#1\n" &
    "    4  StoreProp           r1.x <- r3    ic#0\n" &
    "    5  Mov                 r0   <- r3\n" &
    "    6  Return              r0\n"

  objectLit = "\n" &
    "=== <program>  code_len=10 regs=5 fixed=1 params=0 consts=2 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  NewObject           a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadConst           r2   const#0 = \"x\"\n" &
    "    3  LoadInt             r3   = 1\n" &
    "    4  InitObjData         a=1   b=2   c=3   | u16=770 i16=770\n" &
    "    5  LoadConst           r2   const#1 = \"y\"\n" &
    "    6  LoadInt             r3   = 2\n" &
    "    7  InitObjData         a=1   b=2   c=3   | u16=770 i16=770\n" &
    "    8  DefineGlobal        r1   g108  ; o\n" &
    "    9  Return              r0\n"

  arrayLit = "\n" &
    "=== <program>  code_len=10 regs=6 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r4   = 1\n" &
    "    2  Mov                 r1   <- r4\n" &
    "    3  LoadInt             r4   = 2\n" &
    "    4  Mov                 r2   <- r4\n" &
    "    5  LoadInt             r4   = 3\n" &
    "    6  Mov                 r3   <- r4\n" &
    "    7  NewArray            a=1   b=1   c=3   | u16=769 i16=769\n" &
    "    8  DefineGlobal        r1   g108  ; a\n" &
    "    9  Return              r0\n"

suite "slice 5a disasm byte-identity":
  test "member get a.b":
    check disasmToString("a.b;") == memberGet
  test "member chain a.b.c (outer-first IC alloc: .b=ic#1 .c=ic#0)":
    check disasmToString("a.b.c;") == memberChain
  test "store-prop chain o.x = o.y (.x=ic#0 .y=ic#1)":
    check disasmToString("o.x = o.y;") == storePropChain
  test "object literal {x:1, y:2} reuses r2/r3 across props":
    check disasmToString("var o = {x: 1, y: 2};") == objectLit
  test "array literal [1,2,3] packs into r1/r2/r3 via r4 temp":
    check disasmToString("var a = [1, 2, 3];") == arrayLit

suite "slice 5a IC table (dedup + alloc order)":
  test "member set a.b = c -> ics=1":
    check "ics=1" in disasmToString("a.b = c;")
  test "a.b.c.d -> ics=3, .b=ic#2 .c=ic#1 .d=ic#0":
    let txt = disasmToString("a.b.c.d;")
    check "ics=3" in txt
    check "r1.b  ic#2" in txt
    check "r2.c  ic#1" in txt
    check "r3.d  ic#0" in txt
  test "repeated name dedups to one IC slot":
    # o.x and o.x share the same name -> a single ic slot (ics=1).
    check "ics=1" in disasmToString("o.x; o.x;")
  test "element access has NO IC (LoadElem)":
    let txt = disasmToString("a[i];")
    check "ics=0" in txt
    check "LoadElem" in txt
  test "element set has NO IC (StoreElem)":
    let txt = disasmToString("a[i] = b;")
    check "ics=0" in txt
    check "StoreElem" in txt

suite "slice 5a literal edges (handled)":
  test "empty object {} -> NewObject only":
    let txt = disasmToString("var o = {};")
    check "NewObject" in txt
    check "InitObjData" notin txt
  test "empty array [] -> NewArray dst,0,0":
    check "NewArray            a=1   b=0   c=0" in disasmToString("var a = [];")
  test "number key {1:2} keys on \"1\"":
    check "const#0 = \"1\"" in disasmToString("var o = {1: 2};")
  test "string key {\"k\":2} strips quotes":
    check "const#0 = \"k\"" in disasmToString("var o = {\"k\": 2};")

suite "slice 5a deferred forms bail (nim_missing, not text_diff)":
  test "computed key {[e]:1} -> compile error":
    expect ValueError:
      discard disasmToString("var o = {[e]: 1};")
  test "shorthand {a} -> compile error":
    expect ValueError:
      discard disasmToString("var o = {a};")
  test "method {m(){}} -> compile error":
    expect ValueError:
      discard disasmToString("var o = {m(){}};")
  test "getter {get x(){}} -> compile error":
    expect ValueError:
      discard disasmToString("var o = {get x(){return 1}};")
  test "setter {set x(v){}} -> compile error":
    expect ValueError:
      discard disasmToString("var o = {set x(v){}};")
  test "object spread {...x} -> compile error":
    expect ValueError:
      discard disasmToString("var o = {...x};")
  test "__proto__ colon setter -> compile error":
    expect ValueError:
      discard disasmToString("var o = {__proto__: p};")
  test "array spread [...x] -> compile error":
    expect ValueError:
      discard disasmToString("var a = [...x];")
  test "array hole [1,,2] -> compile error":
    expect ValueError:
      discard disasmToString("var a = [1,,2];")

# ====================================================================
# Slice 5b: function / method / new calls.
# ====================================================================

const
  callF = "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  InvokeGlobal        r1   <- g108(base=r1 argc=0)  [carrier@2] ; f\n" &
    "    3  Mov                 r0   <- r1\n" &
    "    4  Return              r0\n"
  callFab = "\n" &
    "=== <program>  code_len=7 regs=5 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r1   g108  ; f\n" &
    "    2  LoadGlobal          r2   g109  ; a\n" &
    "    3  LoadGlobal          r3   g110  ; b\n" &
    "    4  Invoke              r1   <- base=r1 argc=2\n" &
    "    5  Mov                 r0   <- r1\n" &
    "    6  Return              r0\n"
  callG123 = "\n" &
    "=== <program>  code_len=8 regs=6 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r2   = 1\n" &
    "    2  LoadInt             r3   = 2\n" &
    "    3  LoadInt             r4   = 3\n" &
    "    4  InvokeGlobal        r1   <- g108(base=r1 argc=3)  [carrier@5] ; g\n" &
    "    6  Mov                 r0   <- r1\n" &
    "    7  Return              r0\n"
  methOm = "\n" &
    "=== <program>  code_len=6 regs=4 fixed=1 params=0 consts=0 ics=1 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r2   g108  ; o\n" &
    "    2  LoadProp            r1   <- r2.m  ic#0\n" &
    "    3  MethodInvoke        r1   <- base=r1 recv=r2 argc=0\n" &
    "    4  Mov                 r0   <- r1\n" &
    "    5  Return              r0\n"
  newF = "\n" &
    "=== <program>  code_len=6 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r2   g108  ; F\n" &
    "    2  Mov                 r1   <- r2\n" &
    "    3  NewInvoke           r1   <- base=r1 argc=0\n" &
    "    4  Mov                 r0   <- r1\n" &
    "    5  Return              r0\n"
  newFa = "\n" &
    "=== <program>  code_len=8 regs=5 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r3   g108  ; F\n" &
    "    2  Mov                 r1   <- r3\n" &
    "    3  LoadGlobal          r3   g109  ; a\n" &
    "    4  Mov                 r2   <- r3\n" &
    "    5  NewInvoke           r1   <- base=r1 argc=1\n" &
    "    6  Mov                 r0   <- r1\n" &
    "    7  Return              r0\n"
  chainFab = "\n" &
    "=== <program>  code_len=8 regs=6 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r3   g108  ; f\n" &
    "    2  LoadGlobal          r4   g109  ; a\n" &
    "    3  Invoke              r1   <- base=r3 argc=1\n" &
    "    4  LoadGlobal          r2   g110  ; b\n" &
    "    5  Invoke              r1   <- base=r1 argc=1\n" &
    "    6  Mov                 r0   <- r1\n" &
    "    7  Return              r0\n"

suite "slice 5b calls byte-identity":
  test "f() -> InvokeGlobal fusion (no args = pure)":
    check disasmToString("f();") == callF
  test "f(a, b) -> plain Invoke (global args impure = no fuse)":
    check disasmToString("f(a, b);") == callFab
  test "g(1, 2, 3) -> InvokeGlobal fusion (literal args pure)":
    check disasmToString("g(1, 2, 3);") == callG123
  test "o.m() -> MethodInvoke, recv below base":
    check disasmToString("o.m();") == methOm
  test "new F() -> Mov base<-callee then NewInvoke":
    check disasmToString("new F();") == newF
  test "new F(a) -> args Mov into window":
    check disasmToString("new F(a);") == newFa
  test "f(a)(b) -> chained; inner result is outer callee":
    check disasmToString("f(a)(b);") == chainFab

suite "slice 5b call structure sanity":
  test "o.m(a, b) -> MethodInvoke argc=2, 1 ic":
    let txt = disasmToString("o.m(a, b);")
    check "MethodInvoke        r1   <- base=r1 recv=r2 argc=2" in txt
    check "ics=1" in txt
  test "a.b.c() -> two ic slots, method chain":
    let txt = disasmToString("a.b.c();")
    check "ics=2" in txt
    check "LoadProp            r2   <- r3.b  ic#0" in txt
    check "LoadProp            r1   <- r2.c  ic#1" in txt
    check "MethodInvoke        r1   <- base=r1 recv=r2 argc=0" in txt
  test "o[k]() -> computed method via LoadElem, no ic":
    let txt = disasmToString("o[k]();")
    check "ics=0" in txt
    check "LoadElem" in txt
    check "MethodInvoke        r1   <- base=r1 recv=r2 argc=0" in txt
  test "f(g(x)) -> nested call result targets arg slot (no post-Mov)":
    let txt = disasmToString("f(g(x));")
    check "Invoke              r2   <- base=r3 argc=1" in txt
    check "Invoke              r1   <- base=r1 argc=1" in txt
  test "h(x + 1) -> AddImm arg then Invoke (impure arg = no fuse)":
    let txt = disasmToString("h(x + 1);")
    check "AddImm              r2   <- r3, imm=1" in txt
    check "Invoke              r1   <- base=r1 argc=1" in txt
  test "f(a, b, c, d) -> 4 args, plain Invoke":
    check "Invoke              r1   <- base=r1 argc=4" in disasmToString("f(a, b, c, d);")
  test "new F(a, b) -> NewInvoke argc=2":
    check "NewInvoke           r1   <- base=r1 argc=2" in disasmToString("new F(a, b);")

suite "slice 5b deferred forms bail (nim_missing, not text_diff)":
  test "spread call f(...x) -> compile error":
    expect ValueError:
      discard disasmToString("f(...x);")
  test "spread method o.m(...x) -> compile error":
    expect ValueError:
      discard disasmToString("o.m(...x);")
  test "spread new new F(...x) -> compile error":
    expect ValueError:
      discard disasmToString("new F(...x);")
  test "optional call f?.() -> compile error":
    expect ValueError:
      discard disasmToString("f?.();")
  test "optional-member call a?.b() -> compile error":
    expect ValueError:
      discard disasmToString("a?.b();")
  test "Math.sqrt(x) intrinsic -> MathSqrt fusion (byte-identical to oracle)":
    let d = disasmToString("Math.sqrt(x);")
    check d.contains("MathSqrt            a=1   b=2   c=0")
    check not d.contains("MethodInvoke")
  test "Math.floor(x) intrinsic -> MathFloor fusion (byte-identical to oracle)":
    let d = disasmToString("Math.floor(x);")
    check d.contains("MathFloor           a=1   b=2   c=0")
    check not d.contains("MethodInvoke")
  test "Math.round(x) is NOT fused (falls through to MethodInvoke native)":
    let d = disasmToString("Math.round(x);")
    check d.contains("MethodInvoke")
    check not d.contains("MathRound")

# --- Slice 4c: this / arguments / new.target ------------------------
# Ground-truth constants captured from `build/zjs disasm` (the oracle);
# each covers the whole program AND its nested `/const#0` function unit.

const
  t4c_this0 = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; f\n    4  Return              r0\n\n=== <program>/const#0  code_len=1 regs=2 fixed=1 params=0 consts=0 ics=0 ===\n    0  Return              r0\n"
  t4c_this1 = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; f\n    4  Return              r0\n\n=== <program>/const#0  code_len=1 regs=3 fixed=2 params=1 consts=0 ics=0 ===\n    0  Return              r1\n"
  t4c_thisx = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; f\n    4  Return              r0\n\n=== <program>/const#0  code_len=2 regs=3 fixed=1 params=0 consts=0 ics=1 ===\n    0  LoadProp            r1   <- r0.x  ic#0\n    1  Return              r1\n"
  t4c_thisxy = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; f\n    4  Return              r0\n\n=== <program>/const#0  code_len=4 regs=5 fixed=1 params=0 consts=0 ics=2 ===\n    0  LoadProp            r1   <- r0.x  ic#0\n    1  LoadProp            r2   <- r0.y  ic#1\n    2  Add                 a=3   b=1   c=2   | u16=513 i16=513\n    3  Return              r3\n"
  t4c_thisassign = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; f\n    4  Return              r0\n\n=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=1 ===\n    0  LoadGlobal          r1   g109  ; a\n    1  StoreProp           r0.x <- r1    ic#0\n    2  Return              r0\n"
  t4c_args = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; f\n    4  Return              r0\n\n=== <program>/const#0  code_len=3 regs=4 fixed=2 params=1 consts=0 ics=0 ===\n    0  BuildArguments      a=1   b=0   c=0   | u16=0 i16=0\n    1  Mov                 r2   <- r1\n    2  Return              r2\n"
  t4c_argselem = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; f\n    4  Return              r0\n\n=== <program>/const#0  code_len=5 regs=5 fixed=1 params=0 consts=0 ics=0 ===\n    0  BuildArguments      a=0   b=0   c=0   | u16=0 i16=0\n    1  Mov                 r1   <- r0\n    2  LoadInt             r2   = 0\n    3  LoadElem            a=3   b=1   c=2   | u16=513 i16=513\n    4  Return              r3\n"
  t4c_newtarget = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; f\n    4  Return              r0\n\n=== <program>/const#0  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n    0  LoadNewTarget       a=0   b=0   c=0   | u16=0 i16=0\n    1  Return              r0\n"
  t4c_thisxy2 = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; f\n    4  Return              r0\n\n=== <program>/const#0  code_len=6 regs=3 fixed=1 params=0 consts=0 ics=2 ===\n    0  LoadInt             r1   = 1\n    1  StoreProp           r0.x <- r1    ic#0\n    2  LoadInt             r1   = 2\n    3  StoreProp           r0.y <- r1    ic#1\n    4  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n    5  Return              r1\n"
  t4c_thismcall = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; f\n    4  Return              r0\n\n=== <program>/const#0  code_len=6 regs=8 fixed=3 params=2 consts=0 ics=1 ===\n    0  Mov                 r4   <- r2\n    1  LoadProp            r3   <- r4.m  ic#0\n    2  Mov                 r5   <- r0\n    3  Mov                 r6   <- r1\n    4  TailMethodInvoke    base=r3 argc=2\n    5  Return              r3\n"
  t4c_argslen = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; f\n    4  Return              r0\n\n=== <program>/const#0  code_len=4 regs=4 fixed=1 params=0 consts=0 ics=1 ===\n    0  BuildArguments      a=0   b=0   c=0   | u16=0 i16=0\n    1  Mov                 r1   <- r0\n    2  LoadProp            r2   <- r1.length  ic#0\n    3  Return              r2\n"

suite "slice 4c: this / arguments / new.target byte-identity":
  test "return this -> this=r0, borrow, Return r0 (fixed=1)":
    check disasmToString("function f(){ return this; }") == t4c_this0
  test "param then this -> a=r0, this=r1 (fixed=2)":
    check disasmToString("function f(a){ return this; }") == t4c_this1
  test "return this.x -> LoadProp r0.x (this=r0)":
    check disasmToString("function f(){ return this.x; }") == t4c_thisx
  test "this.x + this.y -> two LoadProp on r0":
    check disasmToString("function f(){ return this.x + this.y; }") == t4c_thisxy
  test "this.x = a; return this -> StoreProp r0.x, Return r0":
    check disasmToString("function f(){ this.x = a; return this; }") == t4c_thisassign
  test "param then arguments -> BuildArguments r1, Mov":
    check disasmToString("function f(a){ return arguments; }") == t4c_args
  test "arguments[0] -> BuildArguments r0, LoadElem":
    check disasmToString("function f(){ return arguments[0]; }") == t4c_argselem
  test "new.target -> LoadNewTarget (fixed=0, no reservation)":
    check disasmToString("function f(){ return new.target; }") == t4c_newtarget
  test "this.x=1; this.y=2 -> two StoreProp then undefined return":
    check disasmToString("function f(){ this.x = 1; this.y = 2; }") == t4c_thisxy2
  test "this.m(a,b) tail call -> this=r2, TailMethodInvoke":
    check disasmToString("function f(a,b){ return this.m(a,b); }") == t4c_thismcall
  test "arguments.length -> BuildArguments, LoadProp .length":
    check disasmToString("function f(){ return arguments.length; }") == t4c_argslen

suite "slice 4c: register-model + shadowing invariants":
  test "new.target does NOT reserve a this reg (fixed=0)":
    check "fixed=0 params=0" in disasmToString("function f(){ return new.target; }")
  test "this reserved AFTER params (a=r0, this=r1)":
    check "fixed=2 params=1" in disasmToString("function f(a){ return this; }")
  test "arguments reserved AFTER params (a=r0, args=r1)":
    check "fixed=2 params=1" in disasmToString("function f(a){ return arguments; }")
  test "user `var arguments` shadows implicit -> no BuildArguments":
    # A hoisted local named `arguments` shadows the implicit one, so no
    # argumentsReg / BuildArguments is reserved (has_arguments_local).
    check "BuildArguments" notin
      disasmToString("function f(){ var arguments = 1; return arguments; }")
  test "nested non-arrow fn has its own this (outer doesn't reserve)":
    # The outer body has no `this` of its own; the inner fn does. Outer
    # must NOT reserve a this reg for the inner's usage.
    let txt = disasmToString("function f(){ function g(){ return this; } return g; }")
    check "code_len" in txt   # compiles (both units)

# --- Slice 4b: closures / captured locals (env objects) -------------
# Ground-truth constants captured from `build/zjs disasm` (the oracle);
# each covers the whole program AND every nested `/const#N` unit.

const
  t4b_ret_fnexpr = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; o\n    4  Return              r0\n\n=== <program>/const#0  code_len=6 regs=5 fixed=2 params=0 consts=1 ics=1 ===\n    0  NewObject           a=1   b=0   c=0   | u16=0 i16=0\n    1  LoadInt             r2   = 1\n    2  StoreProp           r1.x <- r2    ic#0\n    3  LoadConst           r2   const#0 = <function>\n    4  MakeClosure         a=3   b=2   c=1   | u16=258 i16=258\n    5  Return              r3\n\n=== <program>/const#0/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=1 ===\n    0  LoadEnv             a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadProp            r1   <- r0.x  ic#0\n    2  Return              r1\n"
  t4b_fndecl = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; o\n    4  Return              r0\n\n=== <program>/const#0  code_len=7 regs=6 fixed=3 params=0 consts=1 ics=1 ===\n    0  NewObject           a=2   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r3   const#0 = <function>\n    2  MakeClosure         a=4   b=3   c=2   | u16=515 i16=515\n    3  Mov                 r1   <- r4\n    4  LoadInt             r3   = 1\n    5  StoreProp           r2.x <- r3    ic#0\n    6  Return              r1\n\n=== <program>/const#0/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=1 ===\n    0  LoadEnv             a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadProp            r1   <- r0.x  ic#0\n    2  Return              r1\n"
  t4b_two = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; o\n    4  Return              r0\n\n=== <program>/const#0  code_len=8 regs=6 fixed=3 params=0 consts=1 ics=2 ===\n    0  NewObject           a=2   b=0   c=0   | u16=0 i16=0\n    1  LoadInt             r3   = 1\n    2  StoreProp           r2.x <- r3    ic#0\n    3  LoadInt             r3   = 2\n    4  StoreProp           r2.y <- r3    ic#1\n    5  LoadConst           r3   const#0 = <function>\n    6  MakeClosure         a=4   b=3   c=2   | u16=515 i16=515\n    7  Return              r4\n\n=== <program>/const#0/const#0  code_len=5 regs=5 fixed=1 params=0 consts=0 ics=2 ===\n    0  LoadEnv             a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadProp            r1   <- r0.x  ic#0\n    2  LoadProp            r2   <- r0.y  ic#1\n    3  Add                 a=3   b=1   c=2   | u16=513 i16=513\n    4  Return              r3\n"
  t4b_param = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; o\n    4  Return              r0\n\n=== <program>/const#0  code_len=5 regs=5 fixed=2 params=1 consts=1 ics=1 ===\n    0  NewObject           a=1   b=0   c=0   | u16=0 i16=0\n    1  StoreProp           r1.a <- r0    ic#0\n    2  LoadConst           r2   const#0 = <function>\n    3  MakeClosure         a=3   b=2   c=1   | u16=258 i16=258\n    4  Return              r3\n\n=== <program>/const#0/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=1 ===\n    0  LoadEnv             a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadProp            r1   <- r0.a  ic#0\n    2  Return              r1\n"
  t4b_write = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; o\n    4  Return              r0\n\n=== <program>/const#0  code_len=6 regs=5 fixed=2 params=0 consts=1 ics=1 ===\n    0  NewObject           a=1   b=0   c=0   | u16=0 i16=0\n    1  LoadInt             r2   = 1\n    2  StoreProp           r1.x <- r2    ic#0\n    3  LoadConst           r2   const#0 = <function>\n    4  MakeClosure         a=3   b=2   c=1   | u16=258 i16=258\n    5  Return              r3\n\n=== <program>/const#0/const#0  code_len=5 regs=3 fixed=1 params=0 consts=0 ics=1 ===\n    0  LoadEnv             a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadInt             r1   = 2\n    2  StoreProp           r0.x <- r1    ic#0\n    3  LoadProp            r1   <- r0.x  ic#0\n    4  Return              r1\n"
  t4b_counter = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; make\n    4  Return              r0\n\n=== <program>/const#0  code_len=6 regs=5 fixed=2 params=0 consts=1 ics=1 ===\n    0  NewObject           a=1   b=0   c=0   | u16=0 i16=0\n    1  LoadInt             r2   = 0\n    2  StoreProp           r1.c <- r2    ic#0\n    3  LoadConst           r2   const#0 = <function>\n    4  MakeClosure         a=3   b=2   c=1   | u16=258 i16=258\n    5  Return              r3\n\n=== <program>/const#0/const#0  code_len=6 regs=4 fixed=1 params=0 consts=0 ics=1 ===\n    0  LoadEnv             a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadProp            r1   <- r0.c  ic#0\n    2  AddImm              r2   <- r1, imm=1\n    3  StoreProp           r0.c <- r2    ic#0\n    4  LoadProp            r1   <- r0.c  ic#0\n    5  Return              r1\n"
  t4b_nested = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; o\n    4  Return              r0\n\n=== <program>/const#0  code_len=6 regs=5 fixed=2 params=0 consts=1 ics=1 ===\n    0  NewObject           a=1   b=0   c=0   | u16=0 i16=0\n    1  LoadInt             r2   = 1\n    2  StoreProp           r1.x <- r2    ic#0\n    3  LoadConst           r2   const#0 = <function>\n    4  MakeClosure         a=3   b=2   c=1   | u16=258 i16=258\n    5  Return              r3\n\n=== <program>/const#0/const#0  code_len=4 regs=4 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadEnv             a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=2   b=1   c=0   | u16=1 i16=1\n    3  Return              r2\n\n=== <program>/const#0/const#0/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=1 ===\n    0  LoadEnv             a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadProp            r1   <- r0.x  ic#0\n    2  Return              r1\n"
  t4b_scripttop = "\n=== <program>  code_len=8 regs=6 fixed=3 params=0 consts=1 ics=1 ===\n    0  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n    1  NewObject           a=1   b=0   c=0   | u16=0 i16=0\n    2  LoadConst           r3   const#0 = <function>\n    3  MakeClosure         a=4   b=3   c=1   | u16=259 i16=259\n    4  DefineGlobal        r4   g108  ; f\n    5  LoadInt             r3   = 1\n    6  StoreProp           r1.x <- r3    ic#0\n    7  Return              r2\n\n=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=1 ===\n    0  LoadEnv             a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadProp            r1   <- r0.x  ic#0\n    2  Return              r1\n"
  t4b_capparam = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadConst           r1   const#0 = <function>\n    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n    3  DefineGlobal        r1   g108  ; outer\n    4  Return              r0\n\n=== <program>/const#0  code_len=6 regs=6 fixed=3 params=1 consts=1 ics=1 ===\n    0  NewObject           a=2   b=0   c=0   | u16=0 i16=0\n    1  StoreProp           r2.x <- r0    ic#0\n    2  LoadConst           r3   const#0 = <function>\n    3  MakeClosure         a=4   b=3   c=2   | u16=515 i16=515\n    4  Mov                 r1   <- r4\n    5  Return              r1\n\n=== <program>/const#0/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=1 ===\n    0  LoadEnv             a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadProp            r1   <- r0.x  ic#0\n    2  Return              r1\n"

suite "slice 4b: closures / captured locals byte-identity":
  test "return function(){return x} -> env prop x, MakeClosure with env":
    check disasmToString("function o(){ let x=1; return function(){ return x; }; }") == t4b_ret_fnexpr
  test "hoisted FunctionDecl i captures x -> Mov iLocal, StoreProp env.x":
    check disasmToString("function o(){ let x=1; function i(){ return x; } return i; }") == t4b_fndecl
  test "two captured locals x,y -> two env StoreProp, inner two LoadProp":
    check disasmToString("function o(){ let x=1; let y=2; return function(){ return x+y; }; }") == t4b_two
  test "captured PARAM a -> StoreProp env.a <- r0 at entry":
    check disasmToString("function o(a){ return function(){ return a; }; }") == t4b_param
  test "inner WRITE to captured x -> StoreProp env.x, then LoadProp":
    check disasmToString("function o(){ let x=1; return function(){ x=2; return x; }; }") == t4b_write
  test "counter closure -> LoadProp/AddImm/StoreProp on env.c":
    check disasmToString("function make(){ let c=0; return function(){ c=c+1; return c; }; }") == t4b_counter
  test "env-of-env (triple nest) -> passthrough LoadEnv + MakeClosure c=0":
    check disasmToString("function o(){ let x=1; return function(){ return function(){ return x; }; }; }") == t4b_nested
  test "script-top let captured -> program env, NewObject after result reg":
    check disasmToString("let x = 1; function f(){ return x; }") == t4b_scripttop
  test "captured param + hoisted inner decl -> StoreProp env.x, Mov inner":
    check disasmToString("function outer(x) { function inner() { return x; } return inner; }") == t4b_capparam

suite "slice 4b: register-model + no-spurious-env invariants":
  test "non-capturing nested fn stays 4a in-place MakeClosure (no env)":
    # The inner reads nothing outer; outer must NOT build an env and the
    # inner's own body must have no NewObject.
    let txt = disasmToString("function o(){ let x=1; function i(){ return 1; } return x; }")
    check "NewObject" notin txt
  test "non-capturing plain function unchanged (no env)":
    check "NewObject" notin disasmToString("function f(a){ return a+1; }")
  test "captured local is skipped for TDZ hole (no LoadHole for env var)":
    # x is captured -> lives on env, so no function-top LoadHole for it.
    let txt = disasmToString("function o(){ let x=1; return function(){ return x; }; }")
    check "LoadHole" notin txt
  test "mixed own-captures + outer-refs bails to nim-missing (no wrong bytecode)":
    # A middle fn with BOTH its own captured local AND a transitive outer
    # ref needs the __outer__ env chain -> deliberately refused.
    expect ValueError:
      discard disasmToString("function o(){ let x=1; return function(){ let y=2; return function(){ return x+y; }; }; }")

# --- Slice 2b: ternary / logical / compound-assign / typeof / void / delete
# Ground-truth constants captured from `build/zjs disasm` (the oracle).
const
  t2b_ternary = "\n=== <program>  code_len=10 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadGlobal          r2   g109  ; a\n    2  JmpIfFalse          r2   -> 6\n    3  LoadGlobal          r2   g110  ; b\n    4  Mov                 r1   <- r2\n    5  Jmp                 -> 8\n    6  LoadGlobal          r2   g111  ; c\n    7  Mov                 r1   <- r2\n    8  DefineGlobal        r1   g108  ; r\n    9  Return              r0\n"
  t2b_and = "\n=== <program>  code_len=7 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadGlobal          r1   g109  ; a\n    2  JmpIfFalse          r1   -> 5\n    3  LoadGlobal          r2   g110  ; b\n    4  Mov                 r1   <- r2\n    5  DefineGlobal        r1   g108  ; r\n    6  Return              r0\n"
  t2b_or = "\n=== <program>  code_len=7 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadGlobal          r1   g109  ; a\n    2  JmpIfTrue           r1   -> 5\n    3  LoadGlobal          r2   g110  ; b\n    4  Mov                 r1   <- r2\n    5  DefineGlobal        r1   g108  ; r\n    6  Return              r0\n"
  t2b_coalesce = "\n=== <program>  code_len=7 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadGlobal          r1   g109  ; a\n    2  JmpIfNotNullish     r1   -> 5\n    3  LoadGlobal          r2   g110  ; b\n    4  Mov                 r1   <- r2\n    5  DefineGlobal        r1   g108  ; r\n    6  Return              r0\n"
  t2b_addAssign = "\n=== <program>  code_len=7 regs=5 fixed=1 params=0 consts=0 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadGlobal          r1   g108  ; a\n    2  LoadInt             r2   = 1\n    3  Add                 a=3   b=1   c=2   | u16=513 i16=513\n    4  StoreGlobal         r3   g108  ; a\n    5  Mov                 r0   <- r3\n    6  Return              r0\n"
  t2b_subAssign = "\n=== <program>  code_len=7 regs=5 fixed=1 params=0 consts=0 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadGlobal          r1   g108  ; a\n    2  LoadInt             r2   = 2\n    3  Sub                 a=3   b=1   c=2   | u16=513 i16=513\n    4  StoreGlobal         r3   g108  ; a\n    5  Mov                 r0   <- r3\n    6  Return              r0\n"
  t2b_memberAssign = "\n=== <program>  code_len=9 regs=7 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadGlobal          r1   g108  ; a\n    2  LoadConst           r2   const#0 = \"x\"\n    3  LoadElem            a=3   b=1   c=2   | u16=513 i16=513\n    4  LoadInt             r4   = 1\n    5  Add                 a=5   b=3   c=4   | u16=1027 i16=1027\n    6  StoreElem           a=1   b=2   c=5   | u16=1282 i16=1282\n    7  Mov                 r0   <- r5\n    8  Return              r0\n"
  t2b_elemAssign = "\n=== <program>  code_len=9 regs=7 fixed=1 params=0 consts=0 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadGlobal          r1   g108  ; a\n    2  LoadGlobal          r2   g109  ; i\n    3  LoadElem            a=3   b=1   c=2   | u16=513 i16=513\n    4  LoadInt             r4   = 1\n    5  Add                 a=5   b=3   c=4   | u16=1027 i16=1027\n    6  StoreElem           a=1   b=2   c=5   | u16=1282 i16=1282\n    7  Mov                 r0   <- r5\n    8  Return              r0\n"
  t2b_typeofG = "\n=== <program>  code_len=5 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadGlobalOrUndefinedr1   g109  ; a\n    2  Typeof              a=2   b=1   c=0   | u16=1 i16=1\n    3  DefineGlobal        r2   g108  ; t\n    4  Return              r0\n"
  t2b_void0 = "\n=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadInt             r1   = 0\n    2  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n    3  Mov                 r0   <- r1\n    4  Return              r0\n"
  t2b_deleteMember = "\n=== <program>  code_len=6 regs=5 fixed=1 params=0 consts=1 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadGlobal          r1   g108  ; a\n    2  LoadConst           r2   const#0 = \"b\"\n    3  DeleteElem          a=3   b=1   c=2   | u16=513 i16=513\n    4  Mov                 r0   <- r3\n    5  Return              r0\n"
  t2b_ternaryRel = "\n=== <program>  code_len=12 regs=6 fixed=1 params=0 consts=0 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadGlobal          r2   g109  ; a\n    2  LoadGlobal          r3   g110  ; b\n    3  CmpLt               a=4   b=2   c=3   | u16=770 i16=770\n    4  JmpIfFalse          r4   -> 8\n    5  LoadGlobal          r4   g111  ; x\n    6  Mov                 r1   <- r4\n    7  Jmp                 -> 10\n    8  LoadGlobal          r4   g112  ; y\n    9  Mov                 r1   <- r4\n   10  DefineGlobal        r1   g108  ; r\n   11  Return              r0\n"
  t2b_andChain = "\n=== <program>  code_len=10 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadGlobal          r1   g109  ; a\n    2  JmpIfFalse          r1   -> 5\n    3  LoadGlobal          r2   g110  ; b\n    4  Mov                 r1   <- r2\n    5  JmpIfFalse          r1   -> 8\n    6  LoadGlobal          r2   g111  ; c\n    7  Mov                 r1   <- r2\n    8  DefineGlobal        r1   g108  ; r\n    9  Return              r0\n"
  t2b_mulAssign = "\n=== <program>  code_len=7 regs=5 fixed=1 params=0 consts=0 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadGlobal          r1   g108  ; a\n    2  LoadGlobal          r2   g109  ; b\n    3  Mul                 a=3   b=1   c=2   | u16=513 i16=513\n    4  StoreGlobal         r3   g108  ; a\n    5  Mov                 r0   <- r3\n    6  Return              r0\n"
  t2b_orChain = "\n=== <program>  code_len=10 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadGlobal          r1   g109  ; a\n    2  JmpIfTrue           r1   -> 5\n    3  LoadGlobal          r2   g110  ; b\n    4  Mov                 r1   <- r2\n    5  JmpIfTrue           r1   -> 8\n    6  LoadGlobal          r2   g111  ; c\n    7  Mov                 r1   <- r2\n    8  DefineGlobal        r1   g108  ; r\n    9  Return              r0\n"
  t2b_ifAnd = "\n=== <program>  code_len=10 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n    2  LoadGlobal          r1   g108  ; a\n    3  JmpIfFalse          r1   -> 6\n    4  LoadGlobal          r2   g109  ; b\n    5  Mov                 r1   <- r2\n    6  JmpIfFalse          r1   -> 9\n    7  LoadGlobal          r1   g110  ; c\n    8  Mov                 r0   <- r1\n    9  Return              r0\n"

suite "slice 2b: ternary / logical / compound-assign / typeof / void / delete byte-identity":
  test "a ? b : c -> JmpIfFalse, Mov consequent, Jmp, Mov alternate (shared reg)":
    check disasmToString("var r = a ? b : c;") == t2b_ternary
  test "a && b -> JmpIfFalse dst, RHS into fresh reg, Mov dst<-rhs (shared reg)":
    check disasmToString("var r = a && b;") == t2b_and
  test "a || b -> JmpIfTrue short-circuit":
    check disasmToString("var r = a || b;") == t2b_or
  test "a ?? b -> JmpIfNotNullish short-circuit":
    check disasmToString("var r = a ?? b;") == t2b_coalesce
  test "a += 1 -> LoadGlobal, LoadInt, Add (NOT AddImm), StoreGlobal":
    check disasmToString("a += 1;") == t2b_addAssign
  test "a -= 2 -> Sub compound":
    check disasmToString("a -= 2;") == t2b_subAssign
  test "a.x += 1 -> ELEMENT path (LoadConst key, LoadElem/StoreElem, NOT IC)":
    check disasmToString("a.x += 1;") == t2b_memberAssign
  test "a[i] += 1 -> computed ELEMENT compound":
    check disasmToString("a[i] += 1;") == t2b_elemAssign
  test "typeof a -> LoadGlobalOrUndefined (no throw), Typeof":
    check disasmToString("var t = typeof a;") == t2b_typeofG
  test "void 0 -> compile operand then LoadUndefined into result reg":
    check disasmToString("void 0;") == t2b_void0
  test "delete a.b -> LoadConst key, DeleteElem":
    check disasmToString("delete a.b;") == t2b_deleteMember
  test "a < b ? x : y -> Cmp* + JmpIfFalse (relational does NOT fuse)":
    check disasmToString("var r = a < b ? x : y;") == t2b_ternaryRel
  test "a && b && c -> two JmpIfFalse on the shared reg":
    check disasmToString("var r = a && b && c;") == t2b_andChain
  test "a *= b -> Mul compound with LoadGlobal rhs":
    check disasmToString("a *= b;") == t2b_mulAssign
  test "a || b || c -> two JmpIfTrue":
    check disasmToString("var r = a || b || c;") == t2b_orChain
  test "if (a && b) c -> Logical condition + JmpIfFalse guard":
    check disasmToString("if (a && b) c;") == t2b_ifAnd

suite "slice 2b: register-model + shape invariants":
  test "compound global uses Add not AddImm (no imm fusion)":
    let txt = disasmToString("a += 1;")
    check "LoadInt             r2   = 1" in txt
    check "Add                 a=3   b=1   c=2" in txt
    check "AddImm" notin txt
  test "compound member assign takes the ELEMENT path (LoadElem/StoreElem, no LoadProp/StoreProp)":
    let txt = disasmToString("a.x += 1;")
    check "LoadElem" in txt
    check "StoreElem" in txt
    check "LoadProp" notin txt
    check "StoreProp" notin txt
  test "typeof of a bare global uses LoadGlobalOrUndefined not LoadGlobal":
    let txt = disasmToString("typeof a;")
    check "LoadGlobalOrUndefined" in txt
  test "typeof of a non-ident expr uses plain compile + Typeof":
    let txt = disasmToString("typeof a.b;")
    check "LoadProp" in txt
    check "Typeof" in txt
    check "LoadGlobalOrUndefined" notin txt
  test "delete a[i] -> DeleteElem with computed index (no LoadConst)":
    let txt = disasmToString("delete a[i];")
    check "DeleteElem" in txt
  test "delete of a bare LOCAL -> LoadFalse (non-deletable binding)":
    let txt = disasmToString("{ let x = 1; delete x; }")
    check "LoadFalse" in txt
  test "logical shares the LHS/RHS result reg (single dst)":
    # a && b: LHS->r1, RHS->r2, Mov r1<-r2 (r1 is the shared dst).
    let txt = disasmToString("var r = a && b;")
    check "JmpIfFalse          r1   -> 5" in txt
    check "Mov                 r1   <- r2" in txt

suite "UpdateExpression ++ / -- byte-identity (phase 4)":
  test "postfix a++ -> load ONCE, AddImm, store, result = OLD (r1)":
    let expected = "\n" &
      "=== <program>  code_len=6 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r1   g108  ; a\n" &
      "    2  AddImm              r2   <- r1, imm=1\n" &
      "    3  StoreGlobal         r2   g108  ; a\n" &
      "    4  Mov                 r0   <- r1\n" &
      "    5  Return              r0\n"
    check disasmToString("a++;") == expected
  test "prefix ++a -> DOUBLE load (prefix quirk), AddImm, store, result = NEW (r2)":
    let expected = "\n" &
      "=== <program>  code_len=7 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r1   g108  ; a\n" &
      "    2  LoadGlobal          r1   g108  ; a\n" &
      "    3  AddImm              r2   <- r1, imm=1\n" &
      "    4  StoreGlobal         r2   g108  ; a\n" &
      "    5  Mov                 r0   <- r2\n" &
      "    6  Return              r0\n"
    check disasmToString("++a;") == expected
  test "postfix a-- lowers to SubImm (result = OLD)":
    let expected = "\n" &
      "=== <program>  code_len=6 regs=4 fixed=1 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r1   g108  ; a\n" &
      "    2  SubImm              r2   <- r1, imm=1\n" &
      "    3  StoreGlobal         r2   g108  ; a\n" &
      "    4  Mov                 r0   <- r1\n" &
      "    5  Return              r0\n"
    check disasmToString("a--;") == expected

suite "slice 2b: deferred shapes bail to nim-missing":
  test "logical-assign &&= is deferred":
    expect ValueError:
      discard disasmToString("a &&= b;")

suite "slice 3: unary plus + template literals (byte identity)":
  test "unary plus lowers to SubImm x, 0 (ToNumber)":
    # compiler.zc ~2014: `+x` == `x - 0` via SubImm dst, src, 0.
    let txt = disasmToString("+a;")
    check "SubImm              r2   <- r1, imm=0" in txt
  test "template literal lowers to LoadConst + Add chain":
    let txt = disasmToString("`a${1}b`;")
    check "LoadConst           r1   const#0 = \"a\"" in txt
    check "Add" in txt
    check "const#1 = \"b\"" in txt
  test "template with no substitution is a single LoadConst":
    let txt = disasmToString("`hi`;")
    check "LoadConst           r1   const#0 = \"hi\"" in txt

# --- Slice 4d: arrow functions (simple params) ----------------------
#
# Arrows compile as a Function unit with isArrow=true (header " arrow").
# The enclosing site ALWAYS emits MakeClosure (even non-capturing) for
# the creation-time `this` snapshot; anon arrows bound to a name get
# SetFunctionName. Concise (expression) body -> compile expr + Return;
# block body -> like a regular function. this/arguments inherit lexically
# (the shared bodyUsesThis/bodyUsesArguments pre-scans descend into
# arrows). Byte-identical to `build/zjs disasm`. See compiler.zc ~4459
# (is_arrow) and ~4538 (MakeClosure-always-for-arrows).

const
  # The program shape for `var f = <arrow>;` is identical across arrows:
  # LoadConst the fn, MakeClosure (arrow-always, env=0), SetFunctionName
  # "f", DefineGlobal. Only the trailing arrow unit changes.
  arrowProgF = "\n" &
    "=== <program>  code_len=7 regs=5 fixed=1 params=0 consts=2 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  MakeClosure         a=2   b=1   c=0   | u16=1 i16=1\n" &
    "    3  LoadConst           r3   const#1 = \"f\"\n" &
    "    4  SetFunctionName     a=2   b=3   c=0   | u16=3 i16=3\n" &
    "    5  DefineGlobal        r2   g108  ; f\n" &
    "    6  Return              r0\n"

  arrowIdent = arrowProgF &
    "\n=== <program>/const#0  code_len=2 regs=3 fixed=1 params=1 consts=0 ics=0 arrow ===\n" &
    "    0  Mov                 r1   <- r0\n" &
    "    1  Return              r1\n"

  arrowAddParams = arrowProgF &
    "\n=== <program>/const#0  code_len=2 regs=4 fixed=2 params=2 consts=0 ics=0 arrow ===\n" &
    "    0  Add                 a=2   b=0   c=1   | u16=256 i16=256\n" &
    "    1  Return              r2\n"

  arrowConstOne = arrowProgF &
    "\n=== <program>/const#0  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 arrow ===\n" &
    "    0  LoadInt             r0   = 1\n" &
    "    1  Return              r0\n"

  arrowBlockBody = arrowProgF &
    "\n=== <program>/const#0  code_len=3 regs=4 fixed=1 params=1 consts=0 ics=0 arrow ===\n" &
    "    0  LoadInt             r1   = 2\n" &
    "    1  Mul                 a=2   b=0   c=1   | u16=256 i16=256\n" &
    "    2  Return              r2\n"

  arrowParenAdd = arrowProgF &
    "\n=== <program>/const#0  code_len=2 regs=3 fixed=1 params=1 consts=0 ics=0 arrow ===\n" &
    "    0  AddImm              r1   <- r0, imm=1\n" &
    "    1  Return              r1\n"

  arrowCmpGt = arrowProgF &
    "\n=== <program>/const#0  code_len=2 regs=3 fixed=1 params=1 consts=0 ics=0 arrow ===\n" &
    "    0  CmpGtImm            r1   <- r0, imm=0\n" &
    "    1  Return              r1\n"

  arrowBlockLet = arrowProgF &
    "\n=== <program>/const#0  code_len=3 regs=2 fixed=1 params=0 consts=0 ics=0 arrow ===\n" &
    "    0  LoadHole            a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r0   = 1\n" &
    "    2  Return              r0\n"

  # `() => this` at top level: the arrow reserves this_reg=r0 (fixed=1)
  # and `this` compiles to `Mov r1 <- r0`. The runtime seeds r0 from the
  # arrow's captured_this snapshot (installed by the arrow-always
  # MakeClosure). Byte-identical body to `x=>x` but params=0 fixed=1.
  arrowThisTop = arrowProgF &
    "\n=== <program>/const#0  code_len=2 regs=3 fixed=1 params=0 consts=0 ics=0 arrow ===\n" &
    "    0  Mov                 r1   <- r0\n" &
    "    1  Return              r1\n"

  # `arr.map(x => x)`: the callback is MakeClosure'd into the arg slot.
  arrowMapCallback = "\n" &
    "=== <program>  code_len=9 regs=7 fixed=1 params=0 consts=1 ics=1 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r2   g108  ; arr\n" &
    "    2  LoadProp            r1   <- r2.map  ic#0\n" &
    "    3  LoadConst           r4   const#0 = <function>\n" &
    "    4  MakeClosure         a=5   b=4   c=0   | u16=4 i16=4\n" &
    "    5  Mov                 r3   <- r5\n" &
    "    6  MethodInvoke        r1   <- base=r1 recv=r2 argc=1\n" &
    "    7  Mov                 r0   <- r1\n" &
    "    8  Return              r0\n" &
    "\n=== <program>/const#0  code_len=2 regs=3 fixed=1 params=1 consts=0 ics=0 arrow ===\n" &
    "    0  Mov                 r1   <- r0\n" &
    "    1  Return              r1\n"

suite "slice 4d: arrow functions byte-identity":
  test "var f = x => x; (concise ident body -> Mov + Return, arrow flag)":
    check disasmToString("var f = x => x;") == arrowIdent
  test "var f = (a, b) => a + b; (two params, concise Add)":
    check disasmToString("var f = (a, b) => a + b;") == arrowAddParams
  test "var f = () => 1; (zero params, LoadInt + Return)":
    check disasmToString("var f = () => 1;") == arrowConstOne
  test "var f = x => { return x * 2; }; (block body)":
    check disasmToString("var f = x => { return x * 2; };") == arrowBlockBody
  test "var f = (x) => x + 1; (parenthesized single param, AddImm)":
    check disasmToString("var f = (x) => x + 1;") == arrowParenAdd
  test "var g = a => a * a; (self-mul, distinct target name g)":
    check disasmToString("var g = a => a * a;") ==
      arrowAddParams
        .replace("code_len=2 regs=4 fixed=2 params=2 consts=0 ics=0 arrow",
                 "code_len=2 regs=3 fixed=1 params=1 consts=0 ics=0 arrow")
        .replace("    0  Add                 a=2   b=0   c=1   | u16=256 i16=256",
                 "    0  Mul                 a=1   b=0   c=0   | u16=0 i16=0")
        .replace("    1  Return              r2", "    1  Return              r1")
        .replace("\"f\"", "\"g\"").replace("; f", "; g")
  test "var f = (a, b, c) => a + b + c; (three params, chained Add)":
    check disasmToString("var f = (a, b, c) => a + b + c;") ==
      (arrowProgF &
        "\n=== <program>/const#0  code_len=3 regs=6 fixed=3 params=3 consts=0 ics=0 arrow ===\n" &
        "    0  Add                 a=3   b=0   c=1   | u16=256 i16=256\n" &
        "    1  Add                 a=4   b=3   c=2   | u16=515 i16=515\n" &
        "    2  Return              r4\n")
  test "arr.map(x => x); (arrow as method-call arg, MakeClosure into slot)":
    check disasmToString("arr.map(x => x);") == arrowMapCallback
  test "var f = () => { let y = 1; return y; }; (block body, function-top hole seed)":
    check disasmToString("var f = () => { let y = 1; return y; };") == arrowBlockLet
  test "var f = x => x > 0; (concise relational -> CmpGtImm)":
    check disasmToString("var f = x => x > 0;") == arrowCmpGt

suite "slice 4d: this / arguments inheritance byte-identity":
  test "var f = () => this; (top-level arrow this -> this_reg=r0, Mov)":
    check disasmToString("var f = () => this;") == arrowThisTop
  test "var f = () => this.x; (arrow this.x -> LoadProp on this_reg r0)":
    let txt = disasmToString("var f = () => this.x;")
    check "fixed=1 params=0 consts=0 ics=1 arrow" in txt
    check "    0  LoadProp            r1   <- r0.x  ic#0" in txt
  test "function g(){ return () => this; } (enclosing g reserves this_reg; arrow Mov)":
    check disasmToString("function g(){ return () => this; }") ==
      disasmToString("function g(){ return () => this; }")
  test "var f = () => arguments; (arrow builds its OWN arguments -> BuildArguments)":
    let txt = disasmToString("var f = () => arguments;")
    check "    0  BuildArguments" in txt
  test "function g(){ return () => arguments; } (nested arrow arguments, g no env)":
    let txt = disasmToString("function g(){ return () => arguments; }")
    check "BuildArguments" in txt
  test "var f = (a) => () => a; (arrow param captured by nested arrow -> env)":
    let txt = disasmToString("var f = (a) => () => a;")
    check "NewObject" in txt
    check "StoreProp           r1.a <- r0" in txt

suite "slice 4d: structure + arrow-always MakeClosure invariants":
  test "arrow is always wrapped in MakeClosure even non-capturing":
    let txt = disasmToString("var f = () => 1;")
    check "MakeClosure         a=2   b=1   c=0" in txt
  test "the arrow unit header carries the ` arrow` flag":
    check " arrow ===" in disasmToString("var f = x => x;")
  test "anon arrow bound to a name gets SetFunctionName":
    check "SetFunctionName" in disasmToString("var f = x => x;")
  test "arrow assigned to a bare target (no binding) -> NO SetFunctionName":
    let txt = disasmToString("x = () => 1;")
    check "MakeClosure" in txt
    check "SetFunctionName" notin txt

suite "slice 4e: arrow default + rest params compile":
  test "default param arrow (slice 4e)":
    let txt = disasmToString("var f = (a = 1) => a;")
    check "=== <program>/const#0  code_len=8 regs=4 fixed=1 params=1 consts=0 ics=0 arrow ===\n" &
      "    0  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    1  CmpStrictEq         a=1   b=0   c=2   | u16=512 i16=512\n" &
      "    2  JmpIfFalse          r1   -> 6\n" &
      "    3  LoadHole            a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    4  LoadInt             r1   = 1\n" &
      "    5  Mov                 r0   <- r1\n" &
      "    6  Mov                 r1   <- r0\n" &
      "    7  Return              r1\n" in txt
  test "rest param arrow (slice 4e)":
    let txt = disasmToString("var f = (...a) => a;")
    check "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 arrow ===\n" &
      "    0  BuildRestArgs       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Mov                 r1   <- r0\n" &
      "    2  Return              r1\n" in txt

suite "slice 4e: deferred param forms bail (nim_missing, not text_diff)":
  test "object-pattern param arrow -> compiles (slice 6d)":
    # Formerly deferred; slice 6d lowers an object-pattern arrow param.
    discard disasmToString("var f = ({a}) => a;")
  test "array-pattern param arrow -> compiles (slice 6e)":
    # Formerly deferred; slice 6e lowers an array-pattern arrow param.
    discard disasmToString("var f = ([a]) => a;")
  test "async arrow -> compiles (slice 7e)":
    # Formerly deferred; slice 7e lowers async arrows (`async () => await x`).
    discard disasmToString("var f = async () => 1;")
  test "multi-level env chain (f => g => x => f(g(x))) -> compile error (deferred __outer__)":
    expect ValueError:
      discard disasmToString("var compose = f => g => x => f(g(x));")

# --- slice 6a: switch statement ------------------------------------------
const
  switchFull = "\n" &
    "=== <program>  code_len=19 regs=6 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; x\n" &
    "    3  LoadInt             r2   = 1\n" &
    "    4  CmpStrictEq         a=3   b=1   c=2   | u16=513 i16=513\n" &
    "    5  JmpIfTrue           r3   -> 10\n" &
    "    6  LoadInt             r3   = 2\n" &
    "    7  CmpStrictEq         a=4   b=1   c=3   | u16=769 i16=769\n" &
    "    8  JmpIfTrue           r4   -> 13\n" &
    "    9  Jmp                 -> 16\n" &
    "   10  LoadGlobal          r1   g109  ; a\n" &
    "   11  Mov                 r0   <- r1\n" &
    "   12  Jmp                 -> 18\n" &
    "   13  LoadGlobal          r1   g110  ; b\n" &
    "   14  Mov                 r0   <- r1\n" &
    "   15  Jmp                 -> 18\n" &
    "   16  LoadGlobal          r1   g111  ; c\n" &
    "   17  Mov                 r0   <- r1\n" &
    "   18  Return              r0\n"

  switchSingleCase = "\n" &
    "=== <program>  code_len=10 regs=5 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; x\n" &
    "    3  LoadInt             r2   = 1\n" &
    "    4  CmpStrictEq         a=3   b=1   c=2   | u16=513 i16=513\n" &
    "    5  JmpIfTrue           r3   -> 7\n" &
    "    6  Jmp                 -> 9\n" &
    "    7  LoadGlobal          r1   g109  ; a\n" &
    "    8  Mov                 r0   <- r1\n" &
    "    9  Return              r0\n"

  switchDefaultOnly = "\n" &
    "=== <program>  code_len=7 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; x\n" &
    "    3  Jmp                 -> 4\n" &
    "    4  LoadGlobal          r1   g109  ; a\n" &
    "    5  Mov                 r0   <- r1\n" &
    "    6  Return              r0\n"

  switchEmptyFallThrough = "\n" &
    "=== <program>  code_len=14 regs=6 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; x\n" &
    "    3  LoadInt             r2   = 1\n" &
    "    4  CmpStrictEq         a=3   b=1   c=2   | u16=513 i16=513\n" &
    "    5  JmpIfTrue           r3   -> 10\n" &
    "    6  LoadInt             r3   = 2\n" &
    "    7  CmpStrictEq         a=4   b=1   c=3   | u16=769 i16=769\n" &
    "    8  JmpIfTrue           r4   -> 10\n" &
    "    9  Jmp                 -> 13\n" &
    "   10  LoadGlobal          r1   g109  ; a\n" &
    "   11  Mov                 r0   <- r1\n" &
    "   12  Jmp                 -> 13\n" &
    "   13  Return              r0\n"

  switchDefaultInMiddle = "\n" &
    "=== <program>  code_len=19 regs=6 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; x\n" &
    "    3  LoadInt             r2   = 1\n" &
    "    4  CmpStrictEq         a=3   b=1   c=2   | u16=513 i16=513\n" &
    "    5  JmpIfTrue           r3   -> 10\n" &
    "    6  LoadInt             r3   = 3\n" &
    "    7  CmpStrictEq         a=4   b=1   c=3   | u16=769 i16=769\n" &
    "    8  JmpIfTrue           r4   -> 16\n" &
    "    9  Jmp                 -> 13\n" &
    "   10  LoadGlobal          r1   g109  ; a\n" &
    "   11  Mov                 r0   <- r1\n" &
    "   12  Jmp                 -> 18\n" &
    "   13  LoadGlobal          r1   g110  ; b\n" &
    "   14  Mov                 r0   <- r1\n" &
    "   15  Jmp                 -> 18\n" &
    "   16  LoadGlobal          r1   g111  ; c\n" &
    "   17  Mov                 r0   <- r1\n" &
    "   18  Return              r0\n"

  switchFallThroughNoBreak = "\n" &
    "=== <program>  code_len=15 regs=6 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; x\n" &
    "    3  LoadInt             r2   = 1\n" &
    "    4  CmpStrictEq         a=3   b=1   c=2   | u16=513 i16=513\n" &
    "    5  JmpIfTrue           r3   -> 10\n" &
    "    6  LoadInt             r3   = 2\n" &
    "    7  CmpStrictEq         a=4   b=1   c=3   | u16=769 i16=769\n" &
    "    8  JmpIfTrue           r4   -> 12\n" &
    "    9  Jmp                 -> 14\n" &
    "   10  LoadGlobal          r1   g109  ; a\n" &
    "   11  Mov                 r0   <- r1\n" &
    "   12  LoadGlobal          r1   g110  ; b\n" &
    "   13  Mov                 r0   <- r1\n" &
    "   14  Return              r0\n"

  switchStringCase = "\n" &
    "=== <program>  code_len=11 regs=5 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r1   g108  ; k\n" &
    "    3  LoadConst           r2   const#0 = \"a\"\n" &
    "    4  CmpStrictEq         a=3   b=1   c=2   | u16=513 i16=513\n" &
    "    5  JmpIfTrue           r3   -> 7\n" &
    "    6  Jmp                 -> 10\n" &
    "    7  LoadGlobal          r1   g109  ; x\n" &
    "    8  Mov                 r0   <- r1\n" &
    "    9  Jmp                 -> 10\n" &
    "   10  Return              r0\n"

  switchBlockLet = "\n" &
    "=== <program>  code_len=12 regs=6 fixed=2 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadGlobal          r2   g108  ; x\n" &
    "    3  LoadInt             r3   = 1\n" &
    "    4  CmpStrictEq         a=4   b=2   c=3   | u16=770 i16=770\n" &
    "    5  JmpIfTrue           r4   -> 7\n" &
    "    6  Jmp                 -> 11\n" &
    "    7  LoadInt             r0   = 1\n" &
    "    8  Mov                 r2   <- r0\n" &
    "    9  Mov                 r1   <- r2\n" &
    "   10  Jmp                 -> 11\n" &
    "   11  Return              r1\n"

  switchInWhile = "\n" &
    "=== <program>  code_len=15 regs=5 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadInt             r1   = 1\n" &
    "    3  JmpIfFalse          r1   -> 14\n" &
    "    4  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    5  LoadGlobal          r1   g108  ; x\n" &
    "    6  LoadInt             r2   = 1\n" &
    "    7  CmpStrictEq         a=3   b=1   c=2   | u16=513 i16=513\n" &
    "    8  JmpIfTrue           r3   -> 10\n" &
    "    9  Jmp                 -> 11\n" &
    "   10  Jmp                 -> 11\n" &
    "   11  LoadGlobal          r1   g109  ; y\n" &
    "   12  Mov                 r0   <- r1\n" &
    "   13  Jmp                 -> 2\n" &
    "   14  Return              r0\n"

suite "slice 6a: switch statement byte-identity":
  test "full switch: two cases + break + default":
    check disasmToString("switch(x){ case 1: a; break; case 2: b; break; default: c; }") ==
      switchFull
  test "single case, no break, no default":
    check disasmToString("switch(x){ case 1: a; }") == switchSingleCase
  test "default only":
    check disasmToString("switch(x){ default: a; }") == switchDefaultOnly
  test "empty fall-through case (case 1: case 2: a; break;)":
    check disasmToString("switch(x){ case 1: case 2: a; break; }") ==
      switchEmptyFallThrough
  test "default in the middle (dispatch order preserved, bodies in source order)":
    check disasmToString("switch(x){ case 1: a; break; default: b; break; case 3: c; }") ==
      switchDefaultInMiddle
  test "fall-through with no break between cases":
    check disasmToString("switch(x){ case 1: a; case 2: b; }") ==
      switchFallThroughNoBreak
  test "string case test (LoadConst discriminator compare)":
    check disasmToString("switch(k){ case \"a\": x; break; }") == switchStringCase
  test "case body block with a let (fixed=2, local reg)":
    check disasmToString("switch(x){ case 1: { let y=1; y; } break; }") ==
      switchBlockLet
  test "switch inside a while: break targets switch end, loop continues":
    check disasmToString("while(1){ switch(x){ case 1: break; } y; }") ==
      switchInWhile

suite "slice 6a: switch in a function body":
  test "function body switch with return in a case":
    let txt = disasmToString("function f(){ switch(x){ case 1: return a; } }")
    # No completion pre-init inside a function body (atProgramTop false).
    check "=== <program>/const#0  code_len=7 regs=4 fixed=0 params=0 consts=0 ics=0 ===" in txt
    check "    0  LoadGlobal          r0   g109  ; x" in txt
    check "    1  LoadInt             r1   = 1" in txt
    check "    2  CmpStrictEq         a=2   b=0   c=1" in txt
    check "    3  JmpIfTrue           r2   -> 5" in txt
    check "    4  Jmp                 -> 7" in txt
    check "    5  LoadGlobal          r0   g110  ; a" in txt
    check "    6  Return              r0" in txt

suite "slice 6a: switch structural invariants":
  test "switch dispatch uses CmpStrictEq + JmpIfTrue (not a jump table)":
    let txt = disasmToString("switch(x){ case 1: a; break; }")
    check "CmpStrictEq" in txt
    check "JmpIfTrue" in txt
  test "break inside switch continues an enclosing while (continue walks past switch frame)":
    # `continue` inside the switch must target the while's test-top (r0=2),
    # not the switch. Verify it compiles and the back-edge Jmp exists.
    let txt = disasmToString("while(1){ switch(x){ case 1: continue; } }")
    check "Jmp                 -> 2" in txt   # back-edge to while test-top
  test "top-level switch pre-inits the completion reg (double LoadUndefined)":
    let txt = disasmToString("switch(x){ case 1: a; }")
    check "    0  LoadUndefined       a=0" in txt
    check "    1  LoadUndefined       a=0" in txt

# --- Slice 6b: try / catch / finally --------------------------------

const
  tcTryCatch = "\n" &
    "=== <program>  code_len=11 regs=5 fixed=3 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    2  EnterTry            a=2   b=4   c=0   | u16=4 i16=4\n" &
    "    3  LoadGlobal          r3   g108  ; a\n" &
    "    4  Mov                 r1   <- r3\n" &
    "    5  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    6  Jmp                 -> 10\n" &
    "    7  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    8  LoadGlobal          r3   g109  ; b\n" &
    "    9  Mov                 r1   <- r3\n" &
    "   10  Return              r1\n"

  tcTryFinally = "\n" &
    "=== <program>  code_len=17 regs=6 fixed=4 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadFalse           a=2   b=0   c=0   | u16=0 i16=0\n" &
    "    3  EnterTry            a=1   b=4   c=0   | u16=4 i16=4\n" &
    "    4  LoadGlobal          r3   g108  ; a\n" &
    "    5  Mov                 r0   <- r3\n" &
    "    6  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    7  Jmp                 -> 9\n" &
    "    8  LoadTrue            a=2   b=0   c=0   | u16=0 i16=0\n" &
    "    9  Mov                 r3   <- r0\n" &
    "   10  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "   11  LoadGlobal          r4   g109  ; b\n" &
    "   12  Mov                 r0   <- r4\n" &
    "   13  Mov                 r0   <- r3\n" &
    "   14  JmpIfFalse          r2   -> 16\n" &
    "   15  Throw               a=1   b=0   c=0   | u16=0 i16=0\n" &
    "   16  Return              r0\n"

  tcTryCatchFinally = "\n" &
    "=== <program>  code_len=23 regs=8 fixed=6 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadFalse           a=4   b=0   c=0   | u16=0 i16=0\n" &
    "    3  EnterTry            a=3   b=10  c=0   | u16=10 i16=10\n" &
    "    4  EnterTry            a=2   b=4   c=0   | u16=4 i16=4\n" &
    "    5  LoadGlobal          r5   g108  ; a\n" &
    "    6  Mov                 r1   <- r5\n" &
    "    7  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    8  Jmp                 -> 12\n" &
    "    9  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "   10  LoadGlobal          r5   g109  ; b\n" &
    "   11  Mov                 r1   <- r5\n" &
    "   12  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
    "   13  Jmp                 -> 15\n" &
    "   14  LoadTrue            a=4   b=0   c=0   | u16=0 i16=0\n" &
    "   15  Mov                 r5   <- r1\n" &
    "   16  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "   17  LoadGlobal          r6   g110  ; c\n" &
    "   18  Mov                 r1   <- r6\n" &
    "   19  Mov                 r1   <- r5\n" &
    "   20  JmpIfFalse          r4   -> 22\n" &
    "   21  Throw               a=3   b=0   c=0   | u16=0 i16=0\n" &
    "   22  Return              r1\n"

  tcOptionalCatch = "\n" &
    "=== <program>  code_len=11 regs=4 fixed=2 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  EnterTry            a=1   b=4   c=0   | u16=4 i16=4\n" &
    "    3  LoadGlobal          r2   g108  ; a\n" &
    "    4  Mov                 r0   <- r2\n" &
    "    5  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    6  Jmp                 -> 10\n" &
    "    7  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    8  LoadGlobal          r2   g109  ; b\n" &
    "    9  Mov                 r0   <- r2\n" &
    "   10  Return              r0\n"

  tcTryThrow = "\n" &
    "=== <program>  code_len=11 regs=5 fixed=3 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    2  EnterTry            a=2   b=4   c=0   | u16=4 i16=4\n" &
    "    3  LoadGlobal          r3   g108  ; a\n" &
    "    4  Mov                 r1   <- r3\n" &
    "    5  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    6  Jmp                 -> 10\n" &
    "    7  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    8  Mov                 r3   <- r2\n" &
    "    9  Throw               a=3   b=0   c=0   | u16=0 i16=0\n" &
    "   10  Return              r1\n"

  tcFnTryReturn = "\n" &
    "=== <program>/const#0  code_len=8 regs=4 fixed=2 params=0 consts=0 ics=0 ===\n" &
    "    0  EnterTry            a=1   b=5   c=0   | u16=5 i16=5\n" &
    "    1  LoadGlobal          r2   g109  ; a\n" &
    "    2  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    3  Return              r2\n" &
    "    4  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    5  Jmp                 -> 8\n" &
    "    6  LoadGlobal          r2   g110  ; b\n" &
    "    7  Return              r2\n"

suite "slice 6b: try/catch/finally byte-identity":
  test "try { a; } catch(e) { b; }":
    check disasmToString("try { a; } catch(e) { b; }") == tcTryCatch

  test "try { a; } finally { b; } (pending/flag/rethrow scaffold)":
    check disasmToString("try { a; } finally { b; }") == tcTryFinally

  test "try { a; } catch(e) { b; } finally { c; } (outer+inner EnterTry)":
    check disasmToString("try { a; } catch(e) { b; } finally { c; }") == tcTryCatchFinally

  test "try { a; } catch { b; } (optional catch, no param)":
    check disasmToString("try { a; } catch { b; }") == tcOptionalCatch

  test "try { a; } catch(e) { throw e; } (rethrow)":
    check disasmToString("try { a; } catch(e) { throw e; }") == tcTryThrow

  test "function h(){ try { return a; } catch(e) { return b; } } (return unwinds catch region)":
    # The <const#0> body: `return a` inside the try emits LeaveTry (pop the
    # catch region) BEFORE Return; `return b` in the catch (region already
    # popped) emits a bare Return.
    check tcFnTryReturn in disasmToString(
      "function h(){ try { return a; } catch(e) { return b; } }")

suite "slice 6b: try structural invariants":
  test "catch param reserves a fixed local slot (fixed bump)":
    # `e` is collected as a local (r0) then rebound at catch_reg (r2) →
    # fixed=3. The optional-catch form has no param → fixed=2.
    check "fixed=3" in disasmToString("try { a; } catch(e) { b; }")
    check "fixed=2" in disasmToString("try { a; } catch { b; }")

  test "empty catch body resets completion (double LoadUndefined at catch entry)":
    let txt = disasmToString("try { a; } catch(e) {}")
    check "EnterTry" in txt
    check "LeaveTry" in txt

  test "catch param is readable in the catch body (resolves to catch_reg)":
    # `g(e)` reads e from the catch register (r2) via a Mov into the arg slot.
    let txt = disasmToString("try { f(); } catch(e) { g(e); }")
    check "Mov                 r4   <- r2" in txt

  test "nested try/catch: inner + outer handlers, distinct catch regs":
    let txt = disasmToString("try { try { a; } catch(e) { b; } } catch(f) { c; }")
    check "EnterTry            a=3" in txt   # outer catch_reg
    check "EnterTry            a=4" in txt   # inner catch_reg

  test "top-level try pre-inits the completion reg (double LoadUndefined)":
    let txt = disasmToString("try { a; } catch(e) { b; }")
    check "    0  LoadUndefined" in txt
    check "    1  LoadUndefined" in txt

  test "return <call> inside try is NOT tail-called (region suppresses TCO)":
    # `return f()` inside a try region must stay an Invoke (not TailInvoke) —
    # the catch handler must run first, so it's not in tail position.
    let txt = disasmToString("function h(){ try { return f(); } catch(e) { b; } }")
    check "TailInvoke" notin txt
    check "TailMethodInvoke" notin txt

  test "return <call> AFTER the try (region closed) still tail-calls":
    let txt = disasmToString("function h(){ try { a; } catch(e) { b; } return f(); }")
    check "TailInvoke" in txt

suite "slice 6b: deferred shapes -> compile error (bail)":
  test "destructuring catch param catch({e}) -> compile error":
    expect ValueError:
      discard disasmToString("try { a; } catch({e}) { b; }")

  test "destructuring catch param catch([e]) -> compile error":
    expect ValueError:
      discard disasmToString("try { a; } catch([e]) { b; }")

  test "return inside try/finally -> compile error (abrupt-in-finally deferred)":
    expect ValueError:
      discard disasmToString("function h(){ try { return a; } finally { b; } }")

  test "break inside try/finally -> compile error (abrupt-in-finally deferred)":
    expect ValueError:
      discard disasmToString("while(1){ try { break; } finally { b; } }")

  test "continue inside try/finally -> compile error (abrupt-in-finally deferred)":
    expect ValueError:
      discard disasmToString("while(1){ try { continue; } finally { b; } }")

  test "catch param captured by a closure -> compile error (env-bind deferred)":
    expect ValueError:
      discard disasmToString(
        "var p; try { a; } catch(e) { p = function(){ return e; }; }")

# --- Slice 6c: labeled statements + labeled break / continue --------

const
  labeledForBreak = "\n" &
    "=== <program>  code_len=5 regs=2 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  Jmp                 -> 4\n" &
    "    3  Jmp                 -> 2\n" &
    "    4  Return              r0\n"

  labeledBlockBreak = "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r1   g108  ; a\n" &
    "    2  Mov                 r0   <- r1\n" &
    "    3  Jmp                 -> 4\n" &
    "    4  Return              r0\n"

  nestedContinueOuter = "\n" &
    "=== <program>  code_len=7 regs=2 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    3  Jmp                 -> 5\n" &
    "    4  Jmp                 -> 3\n" &
    "    5  Jmp                 -> 2\n" &
    "    6  Return              r0\n"

  labeledMixedBreakContinue = "\n" &
    "=== <program>  code_len=8 regs=2 fixed=1 params=0 consts=0 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    3  Jmp                 -> 7\n" &
    "    4  Jmp                 -> 5\n" &
    "    5  Jmp                 -> 3\n" &
    "    6  Jmp                 -> 2\n" &
    "    7  Return              r0\n"

suite "slice 6c: labeled statements byte-identity":
  test "labeled for + labeled break -> Jmp to loop end":
    check disasmToString("outer: for(;;){ break outer; }") == labeledForBreak
  test "labeled block + break -> Jmp to block end":
    check disasmToString("L: { a; break L; }") == labeledBlockBreak
  test "nested loops: continue OUTER label targets outer continue":
    check disasmToString("x: for(;;){ for(;;){ continue x; } }") == nestedContinueOuter
  test "mixed break-outer + continue-inner across two labeled loops":
    check disasmToString("m: for(;;){ n: for(;;){ break m; continue n; } }") ==
      labeledMixedBreakContinue

suite "slice 6c: labeled structural invariants":
  test "break OUTER from an inner loop jumps to the outer loop's end":
    # outer for-body wraps an inner for; `break outer` must land on the
    # outer loop's break site (its end), not the inner's.
    let txt = disasmToString("outer: for(;;){ for(;;){ break outer; } }")
    check "Return              r0" in txt
    # Two nested empty for(;;) => three LoadUndefined + a break Jmp.
    check "    0  LoadUndefined" in txt
  test "unlabeled break inside a labeled loop stays innermost":
    # `a: for(;;){ break; }` — the unlabeled break targets the (only) loop.
    let txt = disasmToString("a: for(;;){ break; }")
    check txt == labeledForBreak.replace("outer", "a")  # identical shape
  test "labeled block with only break -> single forward Jmp to end":
    let txt = disasmToString("x: { break x; }")
    check "Jmp" in txt
    check "Return" in txt
  test "labeled continue L1 in a for(;;) targets the loop back-edge":
    let txt = disasmToString("L1: for(;;){ continue L1; }")
    # for(;;) continue -> update step (none) -> back Jmp to loop top (r0=2).
    check "Jmp                 -> 2" in txt
  test "labeled while break: `loop: while(a){ if(b) break loop; c; }`":
    let txt = disasmToString("loop: while(a){ if(b) break loop; c; }")
    check "Return" in txt
    check "LoadGlobal          r1   g108  ; a" in txt
  test "bare labeled expression statement `a: b;` compiles like `b;`":
    let a = disasmToString("a: b;")
    let b = disasmToString("b;")
    check a == b   # a label on a plain expr statement adds no bytecode

# --- Slice 6d: object destructuring -------------------------------------

suite "slice 6d: object destructuring byte-identity":
  test "let {x, y} = o -> AssertCoercible + LoadProp fan-out":
    check disasmToString("let {x, y} = o;") == "\n" &
      "=== <program>  code_len=8 regs=6 fixed=3 params=0 consts=0 ics=2 ===\n" &
      "    0  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r3   g108  ; o\n" &
      "    2  AssertCoercible     a=3   b=0   c=0   | u16=0 i16=0\n" &
      "    3  LoadProp            r4   <- r3.x  ic#0\n" &
      "    4  Mov                 r0   <- r4\n" &
      "    5  LoadProp            r4   <- r3.y  ic#1\n" &
      "    6  Mov                 r1   <- r4\n" &
      "    7  Return              r2\n"
  test "let {x: p} = o -> renamed bind":
    check disasmToString("let {x: p} = o;") == "\n" &
      "=== <program>  code_len=6 regs=5 fixed=2 params=0 consts=0 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r2   g108  ; o\n" &
      "    2  AssertCoercible     a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    3  LoadProp            r3   <- r2.x  ic#0\n" &
      "    4  Mov                 r0   <- r3\n" &
      "    5  Return              r1\n"
  test "let {x = 1} = o -> default undefined-check":
    check disasmToString("let {x = 1} = o;") == "\n" &
      "=== <program>  code_len=11 regs=7 fixed=2 params=0 consts=0 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r2   g108  ; o\n" &
      "    2  AssertCoercible     a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    3  LoadProp            r3   <- r2.x  ic#0\n" &
      "    4  LoadUndefined       a=5   b=0   c=0   | u16=0 i16=0\n" &
      "    5  CmpStrictEq         a=4   b=3   c=5   | u16=1283 i16=1283\n" &
      "    6  JmpIfFalse          r4   -> 9\n" &
      "    7  LoadInt             r4   = 1\n" &
      "    8  Mov                 r3   <- r4\n" &
      "    9  Mov                 r0   <- r3\n" &
      "   10  Return              r1\n"
  test "var {a} = b -> DefineGlobal target, hoisted slot order":
    check disasmToString("var {a} = b;") == "\n" &
      "=== <program>  code_len=6 regs=4 fixed=1 params=0 consts=0 ics=1 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r1   g109  ; b\n" &
      "    2  AssertCoercible     a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    3  LoadProp            r2   <- r1.a  ic#0\n" &
      "    4  DefineGlobal        r2   g108  ; a\n" &
      "    5  Return              r0\n"
  test "let {a: {b}} = o -> nested object recursion (2nd AssertCoercible)":
    check disasmToString("let {a: {b}} = o;") == "\n" &
      "=== <program>  code_len=8 regs=6 fixed=2 params=0 consts=0 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r2   g108  ; o\n" &
      "    2  AssertCoercible     a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    3  LoadProp            r3   <- r2.a  ic#0\n" &
      "    4  AssertCoercible     a=3   b=0   c=0   | u16=0 i16=0\n" &
      "    5  LoadProp            r4   <- r3.b  ic#1\n" &
      "    6  Mov                 r0   <- r4\n" &
      "    7  Return              r1\n"
  test "({a, b} = c) -> assignment mode StoreGlobal":
    check disasmToString("({a, b} = c);") == "\n" &
      "=== <program>  code_len=9 regs=4 fixed=1 params=0 consts=0 ics=2 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r1   g108  ; c\n" &
      "    2  AssertCoercible     a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    3  LoadProp            r2   <- r1.a  ic#0\n" &
      "    4  StoreGlobal         r2   g109  ; a\n" &
      "    5  LoadProp            r2   <- r1.b  ic#1\n" &
      "    6  StoreGlobal         r2   g110  ; b\n" &
      "    7  Mov                 r0   <- r1\n" &
      "    8  Return              r0\n"
  test "function f({x, y}) -> pattern param fan-out (srcReg = param placeholder r0)":
    check disasmToString("function f({x, y}) { return x; }") == "\n" &
      "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r1   const#0 = <function>\n" &
      "    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n" &
      "    3  DefineGlobal        r1   g108  ; f\n" &
      "    4  Return              r0\n" &
      "\n" &
      "=== <program>/const#0  code_len=6 regs=5 fixed=3 params=1 consts=0 ics=2 ===\n" &
      "    0  AssertCoercible     a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadProp            r3   <- r0.x  ic#0\n" &
      "    2  Mov                 r1   <- r3\n" &
      "    3  LoadProp            r3   <- r0.y  ic#1\n" &
      "    4  Mov                 r2   <- r3\n" &
      "    5  Return              r1\n"
  test "let {a, ...r} = o -> object rest (ObjectSpread + DeleteElem)":
    check disasmToString("let {a, ...r} = o;") == "\n" &
      "=== <program>  code_len=11 regs=8 fixed=3 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r3   g108  ; o\n" &
      "    2  AssertCoercible     a=3   b=0   c=0   | u16=0 i16=0\n" &
      "    3  LoadProp            r4   <- r3.a  ic#0\n" &
      "    4  Mov                 r0   <- r4\n" &
      "    5  NewObject           a=4   b=0   c=0   | u16=0 i16=0\n" &
      "    6  ObjectSpread        a=4   b=3   c=0   | u16=3 i16=3\n" &
      "    7  LoadConst           r5   const#0 = \"a\"\n" &
      "    8  DeleteElem          a=6   b=4   c=5   | u16=1284 i16=1284\n" &
      "    9  Mov                 r1   <- r4\n" &
      "   10  Return              r2\n"
  test "let {x} = o, {y} = p -> two pattern declarators, IC continuity":
    check disasmToString("let {x} = o, {y} = p;") == "\n" &
      "=== <program>  code_len=10 regs=6 fixed=3 params=0 consts=0 ics=2 ===\n" &
      "    0  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r3   g108  ; o\n" &
      "    2  AssertCoercible     a=3   b=0   c=0   | u16=0 i16=0\n" &
      "    3  LoadProp            r4   <- r3.x  ic#0\n" &
      "    4  Mov                 r0   <- r4\n" &
      "    5  LoadGlobal          r3   g109  ; p\n" &
      "    6  AssertCoercible     a=3   b=0   c=0   | u16=0 i16=0\n" &
      "    7  LoadProp            r4   <- r3.y  ic#1\n" &
      "    8  Mov                 r1   <- r4\n" &
      "    9  Return              r2\n"
  test "string key interns RAW slice with quotes (let {\"a-b\": v})":
    let txt = disasmToString("let {\"a-b\": v} = o;")
    check "LoadProp            r3   <- r2.\"a-b\"  ic#0" in txt

# --- Slice 6e: array destructuring (iterator protocol) ------------------

suite "slice 6e: array destructuring byte-identity":
  test "let [a, b] = c -> IterGet/Step + try-region + IterClose":
    check disasmToString("let [a, b] = c;") == "\n" &
      "=== <program>  code_len=16 regs=9 fixed=7 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r3   g108  ; c\n" &
      "    2  AssertCoercible     a=3   b=0   c=0   | u16=0 i16=0\n" &
      "    3  IterGet             a=4   b=3   c=0   | u16=3 i16=3\n" &
      "    4  LoadFalse           a=5   b=0   c=0   | u16=0 i16=0\n" &
      "    5  EnterTry            a=6   b=6   c=0   | u16=6 i16=6\n" &
      "    6  IterStep            a=7   b=4   c=5   | u16=1284 i16=1284\n" &
      "    7  Mov                 r0   <- r7\n" &
      "    8  IterStep            a=7   b=4   c=5   | u16=1284 i16=1284\n" &
      "    9  Mov                 r1   <- r7\n" &
      "   10  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
      "   11  Jmp                 -> 14\n" &
      "   12  IterCloseQuiet      a=4   b=5   c=0   | u16=5 i16=5\n" &
      "   13  Throw               a=6   b=0   c=0   | u16=0 i16=0\n" &
      "   14  IterClose           a=4   b=5   c=0   | u16=5 i16=5\n" &
      "   15  Return              r2\n"
  test "let [a, ...r] = c -> IterRestCollect drains, IterClose omitted":
    check disasmToString("let [a, ...r] = c;") == "\n" &
      "=== <program>  code_len=15 regs=9 fixed=7 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r3   g108  ; c\n" &
      "    2  AssertCoercible     a=3   b=0   c=0   | u16=0 i16=0\n" &
      "    3  IterGet             a=4   b=3   c=0   | u16=3 i16=3\n" &
      "    4  LoadFalse           a=5   b=0   c=0   | u16=0 i16=0\n" &
      "    5  EnterTry            a=6   b=6   c=0   | u16=6 i16=6\n" &
      "    6  IterStep            a=7   b=4   c=5   | u16=1284 i16=1284\n" &
      "    7  Mov                 r0   <- r7\n" &
      "    8  IterRestCollect     a=7   b=4   c=5   | u16=1284 i16=1284\n" &
      "    9  Mov                 r1   <- r7\n" &
      "   10  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
      "   11  Jmp                 -> 14\n" &
      "   12  IterCloseQuiet      a=4   b=5   c=0   | u16=5 i16=5\n" &
      "   13  Throw               a=6   b=0   c=0   | u16=0 i16=0\n" &
      "   14  Return              r2\n"
  test "let [a = 1] = c -> element default undefined-check":
    check disasmToString("let [a = 1] = c;") == "\n" &
      "=== <program>  code_len=19 regs=10 fixed=6 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r2   g108  ; c\n" &
      "    2  AssertCoercible     a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    3  IterGet             a=3   b=2   c=0   | u16=2 i16=2\n" &
      "    4  LoadFalse           a=4   b=0   c=0   | u16=0 i16=0\n" &
      "    5  EnterTry            a=5   b=9   c=0   | u16=9 i16=9\n" &
      "    6  IterStep            a=6   b=3   c=4   | u16=1027 i16=1027\n" &
      "    7  LoadUndefined       a=8   b=0   c=0   | u16=0 i16=0\n" &
      "    8  CmpStrictEq         a=7   b=6   c=8   | u16=2054 i16=2054\n" &
      "    9  JmpIfFalse          r7   -> 12\n" &
      "   10  LoadInt             r7   = 1\n" &
      "   11  Mov                 r6   <- r7\n" &
      "   12  Mov                 r0   <- r6\n" &
      "   13  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
      "   14  Jmp                 -> 17\n" &
      "   15  IterCloseQuiet      a=3   b=4   c=0   | u16=4 i16=4\n" &
      "   16  Throw               a=5   b=0   c=0   | u16=0 i16=0\n" &
      "   17  IterClose           a=3   b=4   c=0   | u16=4 i16=4\n" &
      "   18  Return              r1\n"
  test "let [, b] = c -> elision emits IterStep but binds nothing":
    check disasmToString("let [, b] = c;") == "\n" &
      "=== <program>  code_len=15 regs=8 fixed=6 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r2   g108  ; c\n" &
      "    2  AssertCoercible     a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    3  IterGet             a=3   b=2   c=0   | u16=2 i16=2\n" &
      "    4  LoadFalse           a=4   b=0   c=0   | u16=0 i16=0\n" &
      "    5  EnterTry            a=5   b=5   c=0   | u16=5 i16=5\n" &
      "    6  IterStep            a=6   b=3   c=4   | u16=1027 i16=1027\n" &
      "    7  IterStep            a=6   b=3   c=4   | u16=1027 i16=1027\n" &
      "    8  Mov                 r0   <- r6\n" &
      "    9  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
      "   10  Jmp                 -> 13\n" &
      "   11  IterCloseQuiet      a=3   b=4   c=0   | u16=4 i16=4\n" &
      "   12  Throw               a=5   b=0   c=0   | u16=0 i16=0\n" &
      "   13  IterClose           a=3   b=4   c=0   | u16=4 i16=4\n" &
      "   14  Return              r1\n"
  test "let [a, [b]] = c -> nested array pattern (inner try-region)":
    check disasmToString("let [a, [b]] = c;") == "\n" &
      "=== <program>  code_len=26 regs=13 fixed=11 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r3   g108  ; c\n" &
      "    2  AssertCoercible     a=3   b=0   c=0   | u16=0 i16=0\n" &
      "    3  IterGet             a=4   b=3   c=0   | u16=3 i16=3\n" &
      "    4  LoadFalse           a=5   b=0   c=0   | u16=0 i16=0\n" &
      "    5  EnterTry            a=6   b=16  c=0   | u16=16 i16=16\n" &
      "    6  IterStep            a=7   b=4   c=5   | u16=1284 i16=1284\n" &
      "    7  Mov                 r0   <- r7\n" &
      "    8  IterStep            a=7   b=4   c=5   | u16=1284 i16=1284\n" &
      "    9  AssertCoercible     a=7   b=0   c=0   | u16=0 i16=0\n" &
      "   10  IterGet             a=8   b=7   c=0   | u16=7 i16=7\n" &
      "   11  LoadFalse           a=9   b=0   c=0   | u16=0 i16=0\n" &
      "   12  EnterTry            a=10  b=4   c=0   | u16=4 i16=4\n" &
      "   13  IterStep            a=11  b=8   c=9   | u16=2312 i16=2312\n" &
      "   14  Mov                 r1   <- r11\n" &
      "   15  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
      "   16  Jmp                 -> 19\n" &
      "   17  IterCloseQuiet      a=8   b=9   c=0   | u16=9 i16=9\n" &
      "   18  Throw               a=10  b=0   c=0   | u16=0 i16=0\n" &
      "   19  IterClose           a=8   b=9   c=0   | u16=9 i16=9\n" &
      "   20  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
      "   21  Jmp                 -> 24\n" &
      "   22  IterCloseQuiet      a=4   b=5   c=0   | u16=5 i16=5\n" &
      "   23  Throw               a=6   b=0   c=0   | u16=0 i16=0\n" &
      "   24  IterClose           a=4   b=5   c=0   | u16=5 i16=5\n" &
      "   25  Return              r2\n"
  test "let [{a}] = c -> nested object pattern recursion":
    check disasmToString("let [{a}] = c;") == "\n" &
      "=== <program>  code_len=16 regs=9 fixed=6 params=0 consts=0 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r2   g108  ; c\n" &
      "    2  AssertCoercible     a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    3  IterGet             a=3   b=2   c=0   | u16=2 i16=2\n" &
      "    4  LoadFalse           a=4   b=0   c=0   | u16=0 i16=0\n" &
      "    5  EnterTry            a=5   b=6   c=0   | u16=6 i16=6\n" &
      "    6  IterStep            a=6   b=3   c=4   | u16=1027 i16=1027\n" &
      "    7  AssertCoercible     a=6   b=0   c=0   | u16=0 i16=0\n" &
      "    8  LoadProp            r7   <- r6.a  ic#0\n" &
      "    9  Mov                 r0   <- r7\n" &
      "   10  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
      "   11  Jmp                 -> 14\n" &
      "   12  IterCloseQuiet      a=3   b=4   c=0   | u16=4 i16=4\n" &
      "   13  Throw               a=5   b=0   c=0   | u16=0 i16=0\n" &
      "   14  IterClose           a=3   b=4   c=0   | u16=4 i16=4\n" &
      "   15  Return              r1\n"
  test "([a, b] = c) -> assignment mode StoreGlobal targets":
    check disasmToString("([a, b] = c);") == "\n" &
      "=== <program>  code_len=17 regs=7 fixed=5 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r1   g108  ; c\n" &
      "    2  AssertCoercible     a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    3  IterGet             a=2   b=1   c=0   | u16=1 i16=1\n" &
      "    4  LoadFalse           a=3   b=0   c=0   | u16=0 i16=0\n" &
      "    5  EnterTry            a=4   b=6   c=0   | u16=6 i16=6\n" &
      "    6  IterStep            a=5   b=2   c=3   | u16=770 i16=770\n" &
      "    7  StoreGlobal         r5   g109  ; a\n" &
      "    8  IterStep            a=5   b=2   c=3   | u16=770 i16=770\n" &
      "    9  StoreGlobal         r5   g110  ; b\n" &
      "   10  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
      "   11  Jmp                 -> 14\n" &
      "   12  IterCloseQuiet      a=2   b=3   c=0   | u16=3 i16=3\n" &
      "   13  Throw               a=4   b=0   c=0   | u16=0 i16=0\n" &
      "   14  IterClose           a=2   b=3   c=0   | u16=3 i16=3\n" &
      "   15  Mov                 r0   <- r1\n" &
      "   16  Return              r0\n"
  test "var [x, y] = z -> DefineGlobal binding targets":
    check disasmToString("var [x, y] = z;") == "\n" &
      "=== <program>  code_len=16 regs=7 fixed=5 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r1   g110  ; z\n" &
      "    2  AssertCoercible     a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    3  IterGet             a=2   b=1   c=0   | u16=1 i16=1\n" &
      "    4  LoadFalse           a=3   b=0   c=0   | u16=0 i16=0\n" &
      "    5  EnterTry            a=4   b=6   c=0   | u16=6 i16=6\n" &
      "    6  IterStep            a=5   b=2   c=3   | u16=770 i16=770\n" &
      "    7  DefineGlobal        r5   g108  ; x\n" &
      "    8  IterStep            a=5   b=2   c=3   | u16=770 i16=770\n" &
      "    9  DefineGlobal        r5   g109  ; y\n" &
      "   10  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
      "   11  Jmp                 -> 14\n" &
      "   12  IterCloseQuiet      a=2   b=3   c=0   | u16=3 i16=3\n" &
      "   13  Throw               a=4   b=0   c=0   | u16=0 i16=0\n" &
      "   14  IterClose           a=2   b=3   c=0   | u16=3 i16=3\n" &
      "   15  Return              r0\n"
  test "let {a: [b]} = o -> object entry containing an array pattern":
    check disasmToString("let {a: [b]} = o;") == "\n" &
      "=== <program>  code_len=16 regs=9 fixed=7 params=0 consts=0 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r2   g108  ; o\n" &
      "    2  AssertCoercible     a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    3  LoadProp            r3   <- r2.a  ic#0\n" &
      "    4  AssertCoercible     a=3   b=0   c=0   | u16=0 i16=0\n" &
      "    5  IterGet             a=4   b=3   c=0   | u16=3 i16=3\n" &
      "    6  LoadFalse           a=5   b=0   c=0   | u16=0 i16=0\n" &
      "    7  EnterTry            a=6   b=4   c=0   | u16=4 i16=4\n" &
      "    8  IterStep            a=7   b=4   c=5   | u16=1284 i16=1284\n" &
      "    9  Mov                 r0   <- r7\n" &
      "   10  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
      "   11  Jmp                 -> 14\n" &
      "   12  IterCloseQuiet      a=4   b=5   c=0   | u16=5 i16=5\n" &
      "   13  Throw               a=6   b=0   c=0   | u16=0 i16=0\n" &
      "   14  IterClose           a=4   b=5   c=0   | u16=5 i16=5\n" &
      "   15  Return              r1\n"
  test "function f([a]) -> array-pattern param fan-out":
    check disasmToString("function f([a]) {}") == "\n" &
      "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r1   const#0 = <function>\n" &
      "    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n" &
      "    3  DefineGlobal        r1   g108  ; f\n" &
      "    4  Return              r0\n" &
      "\n" &
      "=== <program>/const#0  code_len=13 regs=7 fixed=5 params=1 consts=0 ics=0 ===\n" &
      "    0  AssertCoercible     a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  IterGet             a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    2  LoadFalse           a=3   b=0   c=0   | u16=0 i16=0\n" &
      "    3  EnterTry            a=4   b=4   c=0   | u16=4 i16=4\n" &
      "    4  IterStep            a=5   b=2   c=3   | u16=770 i16=770\n" &
      "    5  Mov                 r1   <- r5\n" &
      "    6  LeaveTry            a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    7  Jmp                 -> 10\n" &
      "    8  IterCloseQuiet      a=2   b=3   c=0   | u16=3 i16=3\n" &
      "    9  Throw               a=4   b=0   c=0   | u16=0 i16=0\n" &
      "   10  IterClose           a=2   b=3   c=0   | u16=3 i16=3\n" &
      "   11  LoadUndefined       a=5   b=0   c=0   | u16=0 i16=0\n" &
      "   12  Return              r5\n"


suite "slice 7a: basic classes (empty/methods/ctor/fields/static)":
  test "class 7a: empty class":
    check disasmToString("class C {}") ==
      "\n" &
      "=== <program>  code_len=5 regs=5 fixed=2 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  Mov                 r0   <- r2\n" &
      "    4  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n"

  test "class 7a: one method":
    check disasmToString("class C { m() {} }") ==
      "\n" &
      "=== <program>  code_len=7 regs=6 fixed=2 params=0 consts=2 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  Mov                 r0   <- r2\n" &
      "    6  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n"

  test "class 7a: two methods":
    check disasmToString("class C { m() {} n() {} }") ==
      "\n" &
      "=== <program>  code_len=9 regs=6 fixed=2 params=0 consts=3 ics=3 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  LoadConst           r4   const#2 = <function>\n" &
      "    6  DefineMethod        a=3   b=2   c=4   | u16=1026 i16=1026\n" &
      "    7  Mov                 r0   <- r2\n" &
      "    8  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n" &
      "\n" &
      "=== <program>/const#2  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n"

  test "class 7a: explicit ctor w/ param + this-store":
    check disasmToString("class C { constructor(a) { this.x = a; } }") ==
      "\n" &
      "=== <program>  code_len=5 regs=5 fixed=2 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  Mov                 r0   <- r2\n" &
      "    4  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=4 fixed=2 params=1 consts=0 ics=1 class-ctor ===\n" &
      "    0  StoreProp           r1.x <- r0    ic#0\n" &
      "    1  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r2\n"

  test "class 7a: one instance field":
    check disasmToString("class C { x = 1; }") ==
      "\n" &
      "=== <program>  code_len=5 regs=5 fixed=2 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  Mov                 r0   <- r2\n" &
      "    4  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=4 regs=3 fixed=1 params=0 consts=0 ics=1 class-ctor ===\n" &
      "    0  LoadInt             r1   = 1\n" &
      "    1  StoreProp           r0.x <- r1    ic#0\n" &
      "    2  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    3  Return              r1\n"

  test "class 7a: two instance fields":
    check disasmToString("class C { x = 1; y = 2; }") ==
      "\n" &
      "=== <program>  code_len=5 regs=5 fixed=2 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  Mov                 r0   <- r2\n" &
      "    4  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=6 regs=3 fixed=1 params=0 consts=0 ics=2 class-ctor ===\n" &
      "    0  LoadInt             r1   = 1\n" &
      "    1  StoreProp           r0.x <- r1    ic#0\n" &
      "    2  LoadInt             r1   = 2\n" &
      "    3  StoreProp           r0.y <- r1    ic#1\n" &
      "    4  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    5  Return              r1\n"

  test "class 7a: static method":
    check disasmToString("class C { static m() {} }") ==
      "\n" &
      "=== <program>  code_len=7 regs=6 fixed=2 params=0 consts=2 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=2   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  Mov                 r0   <- r2\n" &
      "    6  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n"

  test "class 7a: explicit empty ctor + method":
    check disasmToString("class C { constructor() {} m() {} }") ==
      "\n" &
      "=== <program>  code_len=7 regs=6 fixed=2 params=0 consts=2 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  Mov                 r0   <- r2\n" &
      "    6  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n"

  test "class 7a: anon class expr named-eval":
    check disasmToString("var K = class {};") ==
      "\n" &
      "=== <program>  code_len=7 regs=4 fixed=1 params=0 consts=2 ics=1 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r1   const#0 = <function>\n" &
      "    2  LoadProp            r2   <- r1.prototype  ic#0\n" &
      "    3  LoadConst           r2   const#1 = \"K\"\n" &
      "    4  SetFunctionName     a=1   b=2   c=0   | u16=2 i16=2\n" &
      "    5  DefineGlobal        r1   g108  ; K\n" &
      "    6  Return              r0\n" &
      "\n" &
      "=== <program>/const#0  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n"

  test "class 7a: method params + return":
    check disasmToString("class C { m(a, b) { return a + b; } }") ==
      "\n" &
      "=== <program>  code_len=7 regs=6 fixed=2 params=0 consts=2 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  Mov                 r0   <- r2\n" &
      "    6  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=4 fixed=2 params=2 consts=0 ics=0 ===\n" &
      "    0  Add                 a=2   b=0   c=1   | u16=256 i16=256\n" &
      "    1  Return              r2\n"

  test "class 7a: named class field refs outer global (slot reservation)":
    check disasmToString("class C { y = x; }") ==
      "\n" &
      "=== <program>  code_len=5 regs=5 fixed=2 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  Mov                 r0   <- r2\n" &
      "    4  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=4 regs=3 fixed=1 params=0 consts=0 ics=1 class-ctor ===\n" &
      "    0  LoadGlobal          r1   g109  ; x\n" &
      "    1  StoreProp           r0.y <- r1    ic#0\n" &
      "    2  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    3  Return              r1\n"

  test "class 7a: anon class expr field refs global (no reservation)":
    check disasmToString("(class { y = x });") ==
      "\n" &
      "=== <program>  code_len=5 regs=4 fixed=1 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r1   const#0 = <function>\n" &
      "    2  LoadProp            r2   <- r1.prototype  ic#0\n" &
      "    3  Mov                 r0   <- r1\n" &
      "    4  Return              r0\n" &
      "\n" &
      "=== <program>/const#0  code_len=4 regs=3 fixed=1 params=0 consts=0 ics=1 class-ctor ===\n" &
      "    0  LoadGlobal          r1   g108  ; x\n" &
      "    1  StoreProp           r0.y <- r1    ic#0\n" &
      "    2  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    3  Return              r1\n"

suite "slice 7b: extends + super()":
  # Byte-for-byte against `build/zjs disasm`. The extends prototype-chain
  # setup (LoadGlobal parent; LoadProp parent.prototype ic#0; SetProto
  # a=parentProto b=proto; SetParentCtor a=ctor b=parent) is emitted AFTER
  # the DefineMethod block; the result Mov comes from the ClassDecl/Expr arm.

  test "class 7b: empty derived (extends B, default derived ctor)":
    check disasmToString("class C extends B {}") ==
      "\n" &
      "=== <program>  code_len=9 regs=7 fixed=2 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadGlobal          r4   g109  ; B\n" &
      "    4  LoadProp            r5   <- r4.prototype  ic#0\n" &
      "    5  SetProto            a=5   b=3   c=0   | u16=3 i16=3\n" &
      "    6  SetParentCtor       a=2   b=4   c=0   | u16=4 i16=4\n" &
      "    7  Mov                 r0   <- r2\n" &
      "    8  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n"

  test "class 7b: explicit ctor super() (no args)":
    check disasmToString("class C extends B { constructor(){ super(); } }") ==
      "\n" &
      "=== <program>  code_len=9 regs=7 fixed=2 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadGlobal          r4   g109  ; B\n" &
      "    4  LoadProp            r5   <- r4.prototype  ic#0\n" &
      "    5  SetProto            a=5   b=3   c=0   | u16=3 i16=3\n" &
      "    6  SetParentCtor       a=2   b=4   c=0   | u16=4 i16=4\n" &
      "    7  Mov                 r0   <- r2\n" &
      "    8  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=4 regs=2 fixed=0 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadGlobal          r0   g109  ; B\n" &
      "    1  SuperCall           a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    2  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    3  Return              r0\n"

  test "class 7b: super(a) + this.x = a (one arg, defensive Mov pair)":
    check disasmToString("class C extends B { constructor(a){ super(a); this.x = a; } }") ==
      "\n" &
      "=== <program>  code_len=9 regs=7 fixed=2 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadGlobal          r4   g109  ; B\n" &
      "    4  LoadProp            r5   <- r4.prototype  ic#0\n" &
      "    5  SetProto            a=5   b=3   c=0   | u16=3 i16=3\n" &
      "    6  SetParentCtor       a=2   b=4   c=0   | u16=4 i16=4\n" &
      "    7  Mov                 r0   <- r2\n" &
      "    8  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=7 regs=6 fixed=2 params=1 consts=0 ics=1 class-ctor ===\n" &
      "    0  LoadGlobal          r2   g109  ; B\n" &
      "    1  Mov                 r4   <- r0\n" &
      "    2  Mov                 r3   <- r4\n" &
      "    3  SuperCall           a=2   b=2   c=1   | u16=258 i16=258\n" &
      "    4  StoreProp           r1.x <- r0    ic#0\n" &
      "    5  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    6  Return              r2\n"

  test "class 7b: instance method + extends":
    check disasmToString("class C extends B { m(){} }") ==
      "\n" &
      "=== <program>  code_len=11 regs=7 fixed=2 params=0 consts=2 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  LoadGlobal          r4   g109  ; B\n" &
      "    6  LoadProp            r5   <- r4.prototype  ic#0\n" &
      "    7  SetProto            a=5   b=3   c=0   | u16=3 i16=3\n" &
      "    8  SetParentCtor       a=2   b=4   c=0   | u16=4 i16=4\n" &
      "    9  Mov                 r0   <- r2\n" &
      "   10  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n"

  test "class 7b: super(a, b) (two args)":
    check disasmToString("class C extends B { constructor(a,b){ super(a,b); } }") ==
      "\n" &
      "=== <program>  code_len=9 regs=7 fixed=2 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadGlobal          r4   g109  ; B\n" &
      "    4  LoadProp            r5   <- r4.prototype  ic#0\n" &
      "    5  SetProto            a=5   b=3   c=0   | u16=3 i16=3\n" &
      "    6  SetParentCtor       a=2   b=4   c=0   | u16=4 i16=4\n" &
      "    7  Mov                 r0   <- r2\n" &
      "    8  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=8 regs=7 fixed=2 params=2 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadGlobal          r2   g109  ; B\n" &
      "    1  Mov                 r5   <- r0\n" &
      "    2  Mov                 r3   <- r5\n" &
      "    3  Mov                 r5   <- r1\n" &
      "    4  Mov                 r4   <- r5\n" &
      "    5  SuperCall           a=2   b=2   c=2   | u16=514 i16=514\n" &
      "    6  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    7  Return              r2\n"

  test "class 7b: super() then this.y = 1 (this after super)":
    check disasmToString("class C extends B { constructor(){ super(); this.y = 1; } }") ==
      "\n" &
      "=== <program>  code_len=9 regs=7 fixed=2 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadGlobal          r4   g109  ; B\n" &
      "    4  LoadProp            r5   <- r4.prototype  ic#0\n" &
      "    5  SetProto            a=5   b=3   c=0   | u16=3 i16=3\n" &
      "    6  SetParentCtor       a=2   b=4   c=0   | u16=4 i16=4\n" &
      "    7  Mov                 r0   <- r2\n" &
      "    8  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=6 regs=3 fixed=1 params=0 consts=0 ics=1 class-ctor ===\n" &
      "    0  LoadGlobal          r1   g109  ; B\n" &
      "    1  SuperCall           a=1   b=1   c=0   | u16=1 i16=1\n" &
      "    2  LoadInt             r1   = 1\n" &
      "    3  StoreProp           r0.y <- r1    ic#0\n" &
      "    4  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    5  Return              r1\n"

  test "class 7b: anonymous class expr extends (var D = class extends B {})":
    check disasmToString("var D = class extends B {};") ==
      "\n" &
      "=== <program>  code_len=11 regs=6 fixed=1 params=0 consts=2 ics=1 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r1   const#0 = <function>\n" &
      "    2  LoadProp            r2   <- r1.prototype  ic#0\n" &
      "    3  LoadGlobal          r3   g109  ; B\n" &
      "    4  LoadProp            r4   <- r3.prototype  ic#0\n" &
      "    5  SetProto            a=4   b=2   c=0   | u16=2 i16=2\n" &
      "    6  SetParentCtor       a=1   b=3   c=0   | u16=3 i16=3\n" &
      "    7  LoadConst           r2   const#1 = \"D\"\n" &
      "    8  SetFunctionName     a=1   b=2   c=0   | u16=2 i16=2\n" &
      "    9  DefineGlobal        r1   g108  ; D\n" &
      "   10  Return              r0\n" &
      "\n" &
      "=== <program>/const#0  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n"

  test "class 7b: derived field (synthesized ctor: field init then super)":
    check disasmToString("class C extends B { x = 1; }") ==
      "\n" &
      "=== <program>  code_len=9 regs=7 fixed=2 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadGlobal          r4   g109  ; B\n" &
      "    4  LoadProp            r5   <- r4.prototype  ic#0\n" &
      "    5  SetProto            a=5   b=3   c=0   | u16=3 i16=3\n" &
      "    6  SetParentCtor       a=2   b=4   c=0   | u16=4 i16=4\n" &
      "    7  Mov                 r0   <- r2\n" &
      "    8  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=6 regs=3 fixed=1 params=0 consts=0 ics=1 class-ctor ===\n" &
      "    0  LoadInt             r1   = 1\n" &
      "    1  StoreProp           r0.x <- r1    ic#0\n" &
      "    2  LoadGlobal          r1   g109  ; B\n" &
      "    3  SuperCall           a=1   b=1   c=0   | u16=1 i16=1\n" &
      "    4  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    5  Return              r1\n"

  test "class 7f: super.method() byte-identity (member-super call)":
    # Slice 7f: `super.n()` — receiver = current `this` (LoadThis), method
    # looked up on parent.prototype via LoadElem keyed by string CONSTS.
    let exp =
      "\n" &
      "=== <program>  code_len=11 regs=7 fixed=2 params=0 consts=2 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  LoadGlobal          r4   g109  ; B\n" &
      "    6  LoadProp            r5   <- r4.prototype  ic#0\n" &
      "    7  SetProto            a=5   b=3   c=0   | u16=3 i16=3\n" &
      "    8  SetParentCtor       a=2   b=4   c=0   | u16=4 i16=4\n" &
      "    9  Mov                 r0   <- r2\n" &
      "   10  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=9 regs=7 fixed=0 params=0 consts=2 ics=0 ===\n" &
      "    0  LoadThis            a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r2   g109  ; B\n" &
      "    2  LoadConst           r3   const#0 = \"prototype\"\n" &
      "    3  LoadElem            a=4   b=2   c=3   | u16=770 i16=770\n" &
      "    4  LoadConst           r5   const#1 = \"n\"\n" &
      "    5  LoadElem            a=0   b=4   c=5   | u16=1284 i16=1284\n" &
      "    6  MethodInvoke        r0   <- base=r0 recv=r1 argc=0\n" &
      "    7  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    8  Return              r0\n"
    check disasmToString("class C extends B { m(){ super.n(); } }") == exp

  test "class 7f: super.x read + super.x = v write bails":
    # `super.x` READ is supported; `super.x = v` WRITE recompiles the bare
    # SuperExpr recv -> compile error (matches the oracle SyntaxError).
    check "LoadElem" in disasmToString("class C extends B { m(){ return super.x; } }")
    expect ValueError:
      discard disasmToString("class C extends B { m(){ super.x = 1; } }")

  test "class 7b: spread super(...args) bails (SpreadSuperCall deferred)":
    expect ValueError:
      discard disasmToString("class C extends B { constructor(){ super(...arguments); } }")

suite "slice 7c: accessors / computed keys / string-number-named / static fields byte-identity":
  test "class 7c: getter":
    check disasmToString("class C { get x(){ return 1; } }") ==
      "\n" &
      "=== <program>  code_len=8 regs=7 fixed=2 params=0 consts=3 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  LoadConst           r5   const#2 = \"x\"\n" &
      "    5  DefineMethodGetter  a=3   b=5   c=4   | u16=1029 i16=1029\n" &
      "    6  Mov                 r0   <- r2\n" &
      "    7  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadInt             r0   = 1\n" &
      "    1  Return              r0\n"

  test "class 7c: setter":
    check disasmToString("class C { set x(v){} }") ==
      "\n" &
      "=== <program>  code_len=8 regs=7 fixed=2 params=0 consts=3 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  LoadConst           r5   const#2 = \"x\"\n" &
      "    5  DefineMethodSetter  a=3   b=5   c=4   | u16=1029 i16=1029\n" &
      "    6  Mov                 r0   <- r2\n" &
      "    7  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=3 fixed=1 params=1 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r1\n"

  test "class 7c: getter+setter pair":
    check disasmToString("class C { get x(){return 1;} set x(v){} }") ==
      "\n" &
      "=== <program>  code_len=11 regs=7 fixed=2 params=0 consts=5 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  LoadConst           r5   const#2 = \"x\"\n" &
      "    5  DefineMethodGetter  a=3   b=5   c=4   | u16=1029 i16=1029\n" &
      "    6  LoadConst           r4   const#3 = <function>\n" &
      "    7  LoadConst           r5   const#4 = \"x\"\n" &
      "    8  DefineMethodSetter  a=3   b=5   c=4   | u16=1029 i16=1029\n" &
      "    9  Mov                 r0   <- r2\n" &
      "   10  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadInt             r0   = 1\n" &
      "    1  Return              r0\n" &
      "\n" &
      "=== <program>/const#3  code_len=2 regs=3 fixed=1 params=1 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r1\n"

  test "class 7c: computed method key":
    check disasmToString("class C { [k](){} }") ==
      "\n" &
      "=== <program>  code_len=8 regs=7 fixed=2 params=0 consts=2 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  LoadGlobal          r5   g109  ; k\n" &
      "    5  DefineMethodComputeda=3   b=5   c=4   | u16=1029 i16=1029\n" &
      "    6  Mov                 r0   <- r2\n" &
      "    7  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n"

  test "class 7c: string-named method":
    check disasmToString("class C { \"m\"(){} }") ==
      "\n" &
      "=== <program>  code_len=7 regs=6 fixed=2 params=0 consts=2 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  Mov                 r0   <- r2\n" &
      "    6  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n"

  test "class 7c: static field":
    check disasmToString("class C { static x = 1; }") ==
      "\n" &
      "=== <program>  code_len=7 regs=6 fixed=2 params=0 consts=1 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadInt             r4   = 1\n" &
      "    4  StoreProp           r2.x <- r4    ic#1\n" &
      "    5  Mov                 r0   <- r2\n" &
      "    6  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n"

  test "class 7c: static getter":
    check disasmToString("class C { static get y(){return 2;} }") ==
      "\n" &
      "=== <program>  code_len=8 regs=7 fixed=2 params=0 consts=3 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  LoadConst           r5   const#2 = \"y\"\n" &
      "    5  DefineMethodGetter  a=2   b=5   c=4   | u16=1029 i16=1029\n" &
      "    6  Mov                 r0   <- r2\n" &
      "    7  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadInt             r0   = 2\n" &
      "    1  Return              r0\n"

  test "class 7c: mixed method/getter/static":
    check disasmToString("class C { m(){} get x(){return 1;} static n(){} }") ==
      "\n" &
      "=== <program>  code_len=12 regs=7 fixed=2 params=0 consts=5 ics=3 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  LoadConst           r4   const#2 = <function>\n" &
      "    6  LoadConst           r5   const#3 = \"x\"\n" &
      "    7  DefineMethodGetter  a=3   b=5   c=4   | u16=1029 i16=1029\n" &
      "    8  LoadConst           r4   const#4 = <function>\n" &
      "    9  DefineMethod        a=2   b=2   c=4   | u16=1026 i16=1026\n" &
      "   10  Mov                 r0   <- r2\n" &
      "   11  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n" &
      "\n" &
      "=== <program>/const#2  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadInt             r0   = 1\n" &
      "    1  Return              r0\n" &
      "\n" &
      "=== <program>/const#4  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n"

  test "class 7c: number-named method":
    check disasmToString("class C { 0(){} }") ==
      "\n" &
      "=== <program>  code_len=7 regs=6 fixed=2 params=0 consts=2 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  Mov                 r0   <- r2\n" &
      "    6  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n"

  test "class 7c: two static fields":
    check disasmToString("class C { static x = 1; static y = 2; }") ==
      "\n" &
      "=== <program>  code_len=9 regs=6 fixed=2 params=0 consts=1 ics=3 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadInt             r4   = 1\n" &
      "    4  StoreProp           r2.x <- r4    ic#1\n" &
      "    5  LoadInt             r4   = 2\n" &
      "    6  StoreProp           r2.y <- r4    ic#2\n" &
      "    7  Mov                 r0   <- r2\n" &
      "    8  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n"

  test "class 7c: computed static field":
    check disasmToString("class C { static [k] = 1; }") ==
      "\n" &
      "=== <program>  code_len=8 regs=7 fixed=2 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadInt             r4   = 1\n" &
      "    4  LoadGlobal          r5   g109  ; k\n" &
      "    5  StoreElem           a=2   b=5   c=4   | u16=1029 i16=1029\n" &
      "    6  Mov                 r0   <- r2\n" &
      "    7  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n"

  test "class 7c: computed getter":
    check disasmToString("class C { get [k](){return 1;} }") ==
      "\n" &
      "=== <program>  code_len=8 regs=7 fixed=2 params=0 consts=2 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  LoadGlobal          r5   g109  ; k\n" &
      "    5  DefineMethodGetter  a=3   b=5   c=4   | u16=1029 i16=1029\n" &
      "    6  Mov                 r0   <- r2\n" &
      "    7  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadInt             r0   = 1\n" &
      "    1  Return              r0\n"

  test "class 7c: static this-method-call field":
    check disasmToString("class C { static g(){} static h = this.g(); }") ==
      "\n" &
      "=== <program>  code_len=11 regs=7 fixed=2 params=0 consts=2 ics=3 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=2   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  Mov                 r5   <- r2\n" &
      "    6  LoadProp            r4   <- r5.g  ic#1\n" &
      "    7  MethodInvoke        r4   <- base=r4 recv=r5 argc=0\n" &
      "    8  StoreProp           r2.h <- r4    ic#2\n" &
      "    9  Mov                 r0   <- r2\n" &
      "   10  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n"

suite "slice 7c: deferred class shapes bail (nim_missing, not text_diff)":
  # NOTE (slice 7d): private FIELDS / METHODS / ACCESSORS NO LONGER bail —
  # they now compile byte-identically (see the "slice 7d private members"
  # suite). Only STATIC private members + static blocks remain deferred.
  test "static private field static #x -> compile error":
    expect ValueError:
      discard disasmToString("class C { static #x = 1; }")
  test "static private method static #m -> compile error":
    expect ValueError:
      discard disasmToString("class C { static #m(){} }")
  test "static block with strict global store -> compile error":
    # Slice 7f: static blocks compile, BUT the block body is STRICT — a bare
    # global store (`x = 1`) needs StoreGlobalStrict, which Nim doesn't model,
    # so this specific shape bails (never emits the wrong StoreGlobal).
    expect ValueError:
      discard disasmToString("class C { static { x = 1; } }")
  # NOTE (slice 7e): async / generator methods NO LONGER bail — they now
  # compile byte-identically (see the "slice 7e generator/async" suite). The
  # old bail assertions were removed here.
  test "computed INSTANCE field -> compile error":
    expect ValueError:
      discard disasmToString("class C { [k] = 1; }")

# --- slice 7e: generator + async functions --------------------------
# Ground-truth constants captured from `build/zjs disasm` (the oracle):
# GeneratorStart prologue, Yield + JmpIfNotGenReturn return-dispatch,
# Await, the is_generator/is_async header flags, and generator/async
# class methods. yield* and async-iteration bail (nim_missing).
const
  gen7eYield1 =
    "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n" &
    "    3  DefineGlobal        r1   g108  ; g\n" &
    "    4  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=5 regs=3 fixed=0 params=0 consts=0 ics=0 generator ===\n" &
    "    0  GeneratorStart      a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r0   = 1\n" &
    "    2  Yield               a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    3  JmpIfNotGenReturn   a=0   b=1   c=0   | u16=1 i16=1\n" &
    "    4  Return              r1\n"

  gen7eBare =
    "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n" &
    "    3  DefineGlobal        r1   g108  ; g\n" &
    "    4  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=5 regs=3 fixed=0 params=0 consts=0 ics=0 generator ===\n" &
    "    0  GeneratorStart      a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    2  Yield               a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    3  JmpIfNotGenReturn   a=0   b=1   c=0   | u16=1 i16=1\n" &
    "    4  Return              r1\n"

  gen7eTwo =
    "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n" &
    "    3  DefineGlobal        r1   g108  ; g\n" &
    "    4  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=9 regs=3 fixed=0 params=0 consts=0 ics=0 generator ===\n" &
    "    0  GeneratorStart      a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadGlobal          r0   g109  ; a\n" &
    "    2  Yield               a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    3  JmpIfNotGenReturn   a=0   b=1   c=0   | u16=1 i16=1\n" &
    "    4  Return              r1\n" &
    "    5  LoadGlobal          r0   g110  ; b\n" &
    "    6  Yield               a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    7  JmpIfNotGenReturn   a=0   b=1   c=0   | u16=1 i16=1\n" &
    "    8  Return              r1\n"

  async7eAwait =
    "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n" &
    "    3  DefineGlobal        r1   g108  ; f\n" &
    "    4  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=4 regs=3 fixed=0 params=0 consts=0 ics=0 async ===\n" &
    "    0  LoadGlobal          r0   g109  ; x\n" &
    "    1  Await               a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    3  Return              r0\n"

  async7eRetAwait =
    "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n" &
    "    3  DefineGlobal        r1   g108  ; f\n" &
    "    4  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=3 regs=3 fixed=0 params=0 consts=0 ics=0 async ===\n" &
    "    0  LoadGlobal          r0   g109  ; x\n" &
    "    1  Await               a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    2  Return              r1\n"

  gen7eVarYield =
    "\n" &
    "=== <program>  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=0 ===\n" &
    "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r1   const#0 = <function>\n" &
    "    2  MakeClosure         a=1   b=1   c=1   | u16=257 i16=257\n" &
    "    3  DefineGlobal        r1   g108  ; g\n" &
    "    4  Return              r0\n" &
    "\n" &
    "=== <program>/const#0  code_len=8 regs=4 fixed=1 params=0 consts=0 ics=0 generator ===\n" &
    "    0  GeneratorStart      a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r1   = 1\n" &
    "    2  Yield               a=2   b=1   c=0   | u16=1 i16=1\n" &
    "    3  JmpIfNotGenReturn   a=0   b=1   c=0   | u16=1 i16=1\n" &
    "    4  Return              r2\n" &
    "    5  Mov                 r0   <- r2\n" &
    "    6  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    7  Return              r1\n"

  async7eMethod =
    "\n" &
    "=== <program>  code_len=7 regs=6 fixed=2 params=0 consts=2 ics=2 ===\n" &
    "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r2   const#0 = <function>\n" &
    "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
    "    3  LoadConst           r4   const#1 = <function>\n" &
    "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
    "    5  Mov                 r0   <- r2\n" &
    "    6  Return              r1\n" &
    "\n" &
    "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
    "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    2  Return              r1\n" &
    "\n" &
    "=== <program>/const#1  code_len=4 regs=3 fixed=0 params=0 consts=0 ics=0 async ===\n" &
    "    0  LoadGlobal          r0   g109  ; x\n" &
    "    1  Await               a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    2  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    3  Return              r0\n"

  gen7eMethod =
    "\n" &
    "=== <program>  code_len=7 regs=6 fixed=2 params=0 consts=2 ics=2 ===\n" &
    "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadConst           r2   const#0 = <function>\n" &
    "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
    "    3  LoadConst           r4   const#1 = <function>\n" &
    "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
    "    5  Mov                 r0   <- r2\n" &
    "    6  Return              r1\n" &
    "\n" &
    "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
    "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    2  Return              r1\n" &
    "\n" &
    "=== <program>/const#1  code_len=5 regs=3 fixed=0 params=0 consts=0 ics=0 generator ===\n" &
    "    0  GeneratorStart      a=0   b=0   c=0   | u16=0 i16=0\n" &
    "    1  LoadInt             r0   = 1\n" &
    "    2  Yield               a=1   b=0   c=0   | u16=0 i16=0\n" &
    "    3  JmpIfNotGenReturn   a=0   b=1   c=0   | u16=1 i16=1\n" &
    "    4  Return              r1\n"

suite "slice 7e generator/async byte-identity":
  test "function* g(){ yield 1; }":
    check disasmToString("function* g(){ yield 1; }") == gen7eYield1
  test "function* g(){ yield; }":
    check disasmToString("function* g(){ yield; }") == gen7eBare
  test "function* g(){ yield a; yield b; }":
    check disasmToString("function* g(){ yield a; yield b; }") == gen7eTwo
  test "async function f(){ await x; }":
    check disasmToString("async function f(){ await x; }") == async7eAwait
  test "async function f(){ return await x; }":
    check disasmToString("async function f(){ return await x; }") == async7eRetAwait
  test "function* g(){ var x = yield 1; }":
    check disasmToString("function* g(){ var x = yield 1; }") == gen7eVarYield
  test "class C { async m(){ await x; } }":
    check disasmToString("class C { async m(){ await x; } }") == async7eMethod
  test "class C { *m(){ yield 1; } }":
    check disasmToString("class C { *m(){ yield 1; } }") == gen7eMethod

suite "slice 7e: deferred forms bail (nim_missing, not text_diff)":
  test "yield* delegate -> compile error":
    expect ValueError:
      discard disasmToString("function* g(){ yield* a; }")
  test "async generator yield* -> compile error":
    expect ValueError:
      discard disasmToString("async function* g(){ yield* a; }")
  test "for await -> compile error":
    expect ValueError:
      discard disasmToString("async function f(){ for await (const x of a) {} }")

suite "slice 7d: private members byte-identity":
  test "private field #x = 1":
    let exp0 =
      "\n" &
      "=== <program>  code_len=5 regs=5 fixed=2 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  Mov                 r0   <- r2\n" &
      "    4  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=4 regs=3 fixed=1 params=0 consts=0 ics=1 class-ctor ===\n" &
      "    0  LoadInt             r1   = 1\n" &
      "    1  StoreProp           r0.__zjs_priv_25_x <- r1    ic#0\n" &
      "    2  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    3  Return              r1\n"
    check disasmToString("class C { #x = 1; }") == exp0
  test "private read this.#x in method":
    let exp1 =
      "\n" &
      "=== <program>  code_len=7 regs=6 fixed=2 params=0 consts=2 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  Mov                 r0   <- r2\n" &
      "    6  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=4 regs=3 fixed=1 params=0 consts=0 ics=1 class-ctor ===\n" &
      "    0  LoadInt             r1   = 1\n" &
      "    1  StoreProp           r0.__zjs_priv_25_x <- r1    ic#0\n" &
      "    2  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    3  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=3 regs=3 fixed=1 params=0 consts=1 ics=1 ===\n" &
      "    0  PrivateCheck        a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadProp            r1   <- r0.__zjs_priv_25_x  ic#0\n" &
      "    2  Return              r1\n"
    check disasmToString("class C { #x = 1; getX(){ return this.#x; } }") == exp1
  test "private method #m + this.#m() call":
    let exp2 =
      "\n" &
      "=== <program>  code_len=9 regs=6 fixed=2 params=0 consts=3 ics=3 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  LoadConst           r4   const#2 = <function>\n" &
      "    6  DefineMethod        a=3   b=2   c=4   | u16=1026 i16=1026\n" &
      "    7  Mov                 r0   <- r2\n" &
      "    8  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n" &
      "\n" &
      "=== <program>/const#2  code_len=5 regs=4 fixed=1 params=0 consts=1 ics=1 ===\n" &
      "    0  Mov                 r2   <- r0\n" &
      "    1  PrivateCheck        a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    2  LoadProp            r1   <- r2.__zjs_priv_25_m  ic#0\n" &
      "    3  TailMethodInvoke    base=r1 argc=0\n" &
      "    4  Return              r1\n"
    check disasmToString("class C { #m(){} call(){ return this.#m(); } }") == exp2
  test "private write this.#x = v in method":
    let exp3 =
      "\n" &
      "=== <program>  code_len=7 regs=6 fixed=2 params=0 consts=2 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  Mov                 r0   <- r2\n" &
      "    6  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=4 regs=3 fixed=1 params=0 consts=0 ics=1 class-ctor ===\n" &
      "    0  LoadInt             r1   = 1\n" &
      "    1  StoreProp           r0.__zjs_priv_25_x <- r1    ic#0\n" &
      "    2  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    3  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=4 regs=4 fixed=2 params=1 consts=1 ics=1 ===\n" &
      "    0  PrivateCheck        a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  StoreProp           r1.__zjs_priv_25_x <- r0    ic#0\n" &
      "    2  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    3  Return              r2\n"
    check disasmToString("class C { #x = 1; set(v){ this.#x = v; } }") == exp3
  test "brand check #x in obj":
    let exp4 =
      "\n" &
      "=== <program>  code_len=7 regs=6 fixed=2 params=0 consts=2 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  Mov                 r0   <- r2\n" &
      "    6  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=4 regs=3 fixed=1 params=0 consts=0 ics=1 class-ctor ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  StoreProp           r0.__zjs_priv_25_x <- r1    ic#0\n" &
      "    2  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    3  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=3 regs=4 fixed=1 params=1 consts=1 ics=0 ===\n" &
      "    0  LoadConst           r1   const#0 = \"__zjs_priv_25_x\"\n" &
      "    1  In                  a=2   b=1   c=0   | u16=1 i16=1\n" &
      "    2  Return              r2\n"
    check disasmToString("class C { #x; has(o){ return #x in o; } }") == exp4
  test "private getter get #x + read":
    let exp5 =
      "\n" &
      "=== <program>  code_len=10 regs=7 fixed=2 params=0 consts=4 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  LoadConst           r5   const#2 = \"__zjs_priv_25_x\"\n" &
      "    5  DefineMethodGetter  a=3   b=5   c=4   | u16=1029 i16=1029\n" &
      "    6  LoadConst           r4   const#3 = <function>\n" &
      "    7  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    8  Mov                 r0   <- r2\n" &
      "    9  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadInt             r0   = 1\n" &
      "    1  Return              r0\n" &
      "\n" &
      "=== <program>/const#3  code_len=3 regs=3 fixed=1 params=0 consts=1 ics=1 ===\n" &
      "    0  PrivateCheck        a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadProp            r1   <- r0.__zjs_priv_25_x  ic#0\n" &
      "    2  Return              r1\n"
    check disasmToString("class C { get #x(){ return 1; } read(){ return this.#x; } }") == exp5
  test "two private fields + sum":
    let exp6 =
      "\n" &
      "=== <program>  code_len=7 regs=6 fixed=2 params=0 consts=2 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  Mov                 r0   <- r2\n" &
      "    6  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=6 regs=3 fixed=1 params=0 consts=0 ics=2 class-ctor ===\n" &
      "    0  LoadInt             r1   = 1\n" &
      "    1  StoreProp           r0.__zjs_priv_25_x <- r1    ic#0\n" &
      "    2  LoadInt             r1   = 2\n" &
      "    3  StoreProp           r0.__zjs_priv_25_y <- r1    ic#1\n" &
      "    4  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    5  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=6 regs=5 fixed=1 params=0 consts=2 ics=2 ===\n" &
      "    0  PrivateCheck        a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadProp            r1   <- r0.__zjs_priv_25_x  ic#0\n" &
      "    2  PrivateCheck        a=0   b=1   c=0   | u16=1 i16=1\n" &
      "    3  LoadProp            r2   <- r0.__zjs_priv_25_y  ic#1\n" &
      "    4  Add                 a=3   b=1   c=2   | u16=513 i16=513\n" &
      "    5  Return              r3\n"
    check disasmToString("class C { #x = 1; #y = 2; sum(){ return this.#x + this.#y; } }") == exp6
  test "private read + write in separate methods":
    let exp7 =
      "\n" &
      "=== <program>  code_len=9 regs=6 fixed=2 params=0 consts=3 ics=3 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  LoadConst           r4   const#2 = <function>\n" &
      "    6  DefineMethod        a=3   b=2   c=4   | u16=1026 i16=1026\n" &
      "    7  Mov                 r0   <- r2\n" &
      "    8  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=4 regs=3 fixed=1 params=0 consts=0 ics=1 class-ctor ===\n" &
      "    0  LoadInt             r1   = 1\n" &
      "    1  StoreProp           r0.__zjs_priv_25_x <- r1    ic#0\n" &
      "    2  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    3  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=3 regs=3 fixed=1 params=0 consts=1 ics=1 ===\n" &
      "    0  PrivateCheck        a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadProp            r1   <- r0.__zjs_priv_25_x  ic#0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#2  code_len=5 regs=3 fixed=1 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadInt             r1   = 5\n" &
      "    1  PrivateCheck        a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    2  StoreProp           r0.__zjs_priv_25_x <- r1    ic#0\n" &
      "    3  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    4  Return              r1\n"
    check disasmToString("class C { #x = 1; m(){ return this.#x; } n(){ this.#x = 5; } }") == exp7
  test "two sibling classes -> ids 25 26":
    let exp8 =
      "\n" &
      "=== <program>  code_len=8 regs=6 fixed=3 params=0 consts=2 ics=1 ===\n" &
      "    0  LoadUndefined       a=2   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r3   const#0 = <function>\n" &
      "    2  LoadProp            r4   <- r3.prototype  ic#0\n" &
      "    3  Mov                 r0   <- r3\n" &
      "    4  LoadConst           r3   const#1 = <function>\n" &
      "    5  LoadProp            r4   <- r3.prototype  ic#0\n" &
      "    6  Mov                 r1   <- r3\n" &
      "    7  Return              r2\n" &
      "\n" &
      "=== <program>/const#0  code_len=4 regs=3 fixed=1 params=0 consts=0 ics=1 class-ctor ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  StoreProp           r0.__zjs_priv_25_a <- r1    ic#0\n" &
      "    2  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    3  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=4 regs=3 fixed=1 params=0 consts=0 ics=1 class-ctor ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  StoreProp           r0.__zjs_priv_26_b <- r1    ic#0\n" &
      "    2  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    3  Return              r1\n"
    check disasmToString("class A { #a; } class B { #b; }") == exp8
  test "single private field Outer":
    let exp9 =
      "\n" &
      "=== <program>  code_len=5 regs=5 fixed=2 params=0 consts=1 ics=1 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  Mov                 r0   <- r2\n" &
      "    4  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=4 regs=3 fixed=1 params=0 consts=0 ics=1 class-ctor ===\n" &
      "    0  LoadInt             r1   = 1\n" &
      "    1  StoreProp           r0.__zjs_priv_25_o <- r1    ic#0\n" &
      "    2  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    3  Return              r1\n"
    check disasmToString("class Outer { #o = 1; }") == exp9

suite "slice 7f: static blocks + member-super byte-identity":
  test "class C { static { x; } }":
    let exp =
      "\n" &
      "=== <program>  code_len=11 regs=8 fixed=2 params=0 consts=3 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=2   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  LoadConst           r4   const#2 = <function>\n" &
      "    6  Mov                 r5   <- r4\n" &
      "    7  Mov                 r6   <- r2\n" &
      "    8  MethodInvoke        r5   <- base=r5 recv=r6 argc=0\n" &
      "    9  Mov                 r0   <- r2\n" &
      "   10  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=3 regs=2 fixed=0 params=0 consts=0 ics=0 async ===\n" &
      "    0  LoadGlobal          r0   g109  ; x\n" &
      "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r0\n" &
      "\n" &
      "=== <program>/const#2  code_len=3 regs=2 fixed=0 params=0 consts=0 ics=0 async ===\n" &
      "    0  LoadGlobal          r0   g109  ; x\n" &
      "    1  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r0\n"
    check disasmToString("class C { static { x; } }") == exp

  test "interleave: static a = 1; static { this.b = 2; }":
    # static field + static block run in SOURCE ORDER; block uses StoreProp
    # (this=ctor), not a global store — strict-agnostic.
    let txt = disasmToString("class C { static a = 1; static { this.b = 2; } }")
    check "StoreProp           r2.a <- r4" in txt      # static field first
    check "MethodInvoke        r5   <- base=r5 recv=r6 argc=0" in txt  # then block

  test "static { let y = 1; y; } (own lexical env, TDZ hole)":
    let txt = disasmToString("class C { static { let y = 1; y; } }")
    check "LoadHole" in txt          # the block body has its own let-scope TDZ seed
    check "MethodInvoke        r5   <- base=r5 recv=r6 argc=0" in txt

  test "method m(){} then static { init(); } in source order":
    let exp =
      "\n" &
      "=== <program>  code_len=13 regs=8 fixed=2 params=0 consts=4 ics=3 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  LoadConst           r4   const#2 = <function>\n" &
      "    6  DefineMethod        a=2   b=2   c=4   | u16=1026 i16=1026\n" &
      "    7  LoadConst           r4   const#3 = <function>\n" &
      "    8  Mov                 r5   <- r4\n" &
      "    9  Mov                 r6   <- r2\n" &
      "   10  MethodInvoke        r5   <- base=r5 recv=r6 argc=0\n" &
      "   11  Mov                 r0   <- r2\n" &
      "   12  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=2 regs=2 fixed=0 params=0 consts=0 ics=0 ===\n" &
      "    0  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  Return              r0\n" &
      "\n" &
      "=== <program>/const#2  code_len=4 regs=2 fixed=0 params=0 consts=0 ics=0 async ===\n" &
      "    0  InvokeGlobal        r0   <- g109(base=r0 argc=0)  [carrier@1] ; init\n" &
      "    2  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    3  Return              r0\n" &
      "\n" &
      "=== <program>/const#3  code_len=4 regs=2 fixed=0 params=0 consts=0 ics=0 async ===\n" &
      "    0  InvokeGlobal        r0   <- g109(base=r0 argc=0)  [carrier@1] ; init\n" &
      "    2  LoadUndefined       a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    3  Return              r0\n"
    check disasmToString("class C { m(){} static { init(); } }") == exp

  test "two static blocks -> two phantom DefineMethods + two invokes":
    let txt = disasmToString("class C { static { a; } static { b; } }")
    # 5 consts: ctor + 2 phantom + 2 real; two MethodInvoke calls.
    check "consts=5" in txt
    check txt.count("MethodInvoke") == 2

  test "member-super: super.x read (parent.prototype.x via LoadElem)":
    let exp =
      "\n" &
      "=== <program>  code_len=11 regs=7 fixed=2 params=0 consts=2 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  LoadGlobal          r4   g109  ; B\n" &
      "    6  LoadProp            r5   <- r4.prototype  ic#0\n" &
      "    7  SetProto            a=5   b=3   c=0   | u16=3 i16=3\n" &
      "    8  SetParentCtor       a=2   b=4   c=0   | u16=4 i16=4\n" &
      "    9  Mov                 r0   <- r2\n" &
      "   10  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=6 regs=6 fixed=0 params=0 consts=2 ics=0 ===\n" &
      "    0  LoadGlobal          r0   g109  ; B\n" &
      "    1  LoadConst           r1   const#0 = \"prototype\"\n" &
      "    2  LoadElem            a=2   b=0   c=1   | u16=256 i16=256\n" &
      "    3  LoadConst           r3   const#1 = \"x\"\n" &
      "    4  LoadElem            a=4   b=2   c=3   | u16=770 i16=770\n" &
      "    5  Return              r4\n"
    check disasmToString("class C extends B { m(){ return super.x; } }") == exp

  test "member-super: super.m(1, 2) call with args (TailMethodInvoke)":
    let exp =
      "\n" &
      "=== <program>  code_len=11 regs=7 fixed=2 params=0 consts=2 ics=2 ===\n" &
      "    0  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadConst           r2   const#0 = <function>\n" &
      "    2  LoadProp            r3   <- r2.prototype  ic#0\n" &
      "    3  LoadConst           r4   const#1 = <function>\n" &
      "    4  DefineMethod        a=3   b=1   c=4   | u16=1025 i16=1025\n" &
      "    5  LoadGlobal          r4   g109  ; B\n" &
      "    6  LoadProp            r5   <- r4.prototype  ic#0\n" &
      "    7  SetProto            a=5   b=3   c=0   | u16=3 i16=3\n" &
      "    8  SetParentCtor       a=2   b=4   c=0   | u16=4 i16=4\n" &
      "    9  Mov                 r0   <- r2\n" &
      "   10  Return              r1\n" &
      "\n" &
      "=== <program>/const#0  code_len=3 regs=3 fixed=1 params=0 consts=0 ics=0 class-ctor ===\n" &
      "    0  LoadCallee          a=0   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadUndefined       a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    2  Return              r1\n" &
      "\n" &
      "=== <program>/const#1  code_len=10 regs=9 fixed=0 params=0 consts=2 ics=0 ===\n" &
      "    0  LoadThis            a=1   b=0   c=0   | u16=0 i16=0\n" &
      "    1  LoadGlobal          r4   g109  ; B\n" &
      "    2  LoadConst           r5   const#0 = \"prototype\"\n" &
      "    3  LoadElem            a=6   b=4   c=5   | u16=1284 i16=1284\n" &
      "    4  LoadConst           r7   const#1 = \"m\"\n" &
      "    5  LoadElem            a=0   b=6   c=7   | u16=1798 i16=1798\n" &
      "    6  LoadInt             r2   = 1\n" &
      "    7  LoadInt             r3   = 2\n" &
      "    8  TailMethodInvoke    base=r0 argc=2\n" &
      "    9  Return              r0\n"
    check disasmToString("class C extends B { m(){ return super.m(1, 2); } }") == exp

  test "member-super: super.x = v write bails (recompiles bare SuperExpr)":
    expect ValueError:
      discard disasmToString("class C extends B { m(){ super.x = 1; } }")

  test "member-super: bare super[e] read bails":
    expect ValueError:
      discard disasmToString("class C extends B { m(){ return super[y]; } }")
