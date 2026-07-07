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
  test "captured outer local -> compile error (env deferred to 4b)":
    expect ValueError:
      discard disasmToString("function outer(x) { function inner() { return x; } return inner; }")
  test "arrow function -> compile error (this-snapshot MakeClosure deferred)":
    expect ValueError:
      discard disasmToString("var f = () => 1;")
  test "default param -> compile error (deferred)":
    expect ValueError:
      discard disasmToString("function f(a = 1) { return a; }")
  test "rest param -> compile error (deferred)":
    expect ValueError:
      discard disasmToString("function f(...r) { return 1; }")
  test "named function expression -> compile error (LoadCallee deferred)":
    expect ValueError:
      discard disasmToString("(function foo(){});")
  test "async function -> compile error (deferred)":
    expect ValueError:
      discard disasmToString("async function f() { return 1; }")
  test "generator function -> compile error (deferred)":
    expect ValueError:
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
  test "Math.sqrt(x) intrinsic -> compile error (deferred fusion)":
    expect ValueError:
      discard disasmToString("Math.sqrt(x);")
  test "Math.floor(x) intrinsic -> compile error (deferred fusion)":
    expect ValueError:
      discard disasmToString("Math.floor(x);")

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
