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
