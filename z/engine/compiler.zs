// Bytecode compiler -- AST to FunctionCode.
//
// A port of src/compiler.zc grown in vertical slices alongside the
// interpreter, each checked against the reference engine's observable
// results through tools/oracle-eval.sh. Bytecode is internal and may differ
// from the reference; behaviour may not.
//
// Register allocation is the reference's high-water scheme: expression
// temporaries are allocated above a fixed watermark (params, locals, and the
// program's result register) and reset after each statement.

import { expect } from "std/test";
import { Value, int32Value, doubleValue, isInt32, asInt32 } from "./value.zs";
import { TokenKind } from "./token.zs";
import { NodeKind, AstNode, NO_NODE } from "./ast.zs";
import { Parser, ParseResult, parseProgram } from "./parser.zs";
import { Op, Inst, FunctionCode, createFunctionCode, instA, instAB, instABC, instAU16, instAI16 } from "./bytecode.zs";
import { Runtime } from "./runtime.zs";
import { replace } from "std/memory";

const B_LF: u8 = 10;

// A lexical binding held in a register.
struct Local {
  nameStart: u32;
  nameLength: u32;
  reg: u8;
}

export struct Compiler {
  code: Array<Inst>;
  constants: Array<Value>;
  nextReg: u8;
  maxReg: u8;
  fixedRegs: u8;
  locals: Array<Local>;
  // The program's reserved result register, or -1 inside a function.
  lastExprReg: i32;
  hadError: boolean;
  strict: boolean;

  // --- Emission ---

  function emit(inout this, inst: Inst): u32 {
    this.code.push(inst);
    return u32(this.code.length - 1);
  }

  function addConst(inout this, value: Value): u16 {
    this.constants.push(value);
    return u16(this.constants.length - 1);
  }

  function allocReg(inout this): u8 {
    const reg = this.nextReg;
    this.nextReg = this.nextReg + 1;
    if (this.nextReg > this.maxReg) this.maxReg = this.nextReg;
    return reg;
  }

  // Release expression temporaries back to the watermark after a statement.
  function resetTemps(inout this): void {
    this.nextReg = this.fixedRegs;
  }

  // --- Names ---

  function nameMatches(in parser: Parser, aStart: u32, aLength: u32, bStart: u32, bLength: u32): boolean {
    return parser.slicesEqual(aStart, aLength, bStart, bLength);
  }

  function findLocal(in parser: Parser, nameStart: u32, nameLength: u32): i32 {
    let index: usize = this.locals.length;
    while (index > 0) {
      index = index - 1;
      const local = this.locals[index];
      if (local.nameLength == nameLength && this.nameMatches(in parser, local.nameStart, local.nameLength, nameStart, nameLength)) {
        return i32(index);
      }
    }
    return -1;
  }

  function addLocal(inout this, nameStart: u32, nameLength: u32): u8 {
    const reg = this.allocReg();
    this.locals.push(Local({ nameStart: nameStart, nameLength: nameLength, reg: reg }));
    return reg;
  }

  // --- Expressions ---
  //
  // Each returns the register holding the result.

  function compileExpr(inout this, in parser: Parser, inout runtime: Runtime, node: u32): u8 {
    if (node == NO_NODE) return 0;
    const n = parser.ast.node(node);
    const k = n.kind;

    if (k == NodeKind.numberExpr) {
      const dst = this.allocReg();
      const value = n.num;
      const truncated = f64ToInt32Exact(value);
      if (truncated.exact && truncated.value >= -32768 && truncated.value <= 32767) {
        this.emit(instAI16(Op.loadInt, dst, truncated.value));
      } else if (truncated.exact) {
        const index = this.addConst(int32Value(truncated.value));
        this.emit(instAU16(Op.loadConst, dst, index));
      } else {
        const index = this.addConst(doubleValue(value));
        this.emit(instAU16(Op.loadConst, dst, index));
      }
      return dst;
    }
    if (k == NodeKind.boolExpr) {
      const dst = this.allocReg();
      this.emit(instA(n.boolValue ? Op.loadTrue : Op.loadFalse, dst));
      return dst;
    }
    if (k == NodeKind.nullExpr) {
      const dst = this.allocReg();
      this.emit(instA(Op.loadNull, dst));
      return dst;
    }
    if (k == NodeKind.undefinedExpr) {
      const dst = this.allocReg();
      this.emit(instA(Op.loadUndefined, dst));
      return dst;
    }
    if (k == NodeKind.paren) return this.compileExpr(in parser, inout runtime, n.left);
    if (k == NodeKind.identExpr) {
      const local = this.findLocal(in parser, n.nameStart, n.nameLength);
      const dst = this.allocReg();
      if (local >= 0) {
        this.emit(instAB(Op.mov, dst, this.locals[usize(local)].reg));
        return dst;
      }
      const slot = runtime.globalSlot(parser.source.copyBytes(usize(n.nameStart), usize(n.nameStart + n.nameLength)));
      this.emit(instAU16(Op.loadGlobal, dst, slot));
      return dst;
    }
    if (k == NodeKind.binary) {
      const left = this.compileExpr(in parser, inout runtime, n.left);
      const right = this.compileExpr(in parser, inout runtime, n.right);
      const op = binaryOp(n.op);
      if (op == Op.halt) {
        this.hadError = true;
        return 0;
      }
      const dst = this.allocReg();
      this.emit(instABC(op, dst, left, right));
      return dst;
    }
    if (k == NodeKind.unary) {
      const operand = this.compileExpr(in parser, inout runtime, n.left);
      const dst = this.allocReg();
      if (n.op == TokenKind.minus) {
        this.emit(instAB(Op.neg, dst, operand));
        return dst;
      }
      if (n.op == TokenKind.plus) {
        // Unary plus is ToNumber; `x - 0` has the same result on numbers
        // and the engine only has numbers so far.
        const zero = this.allocReg();
        this.emit(instAI16(Op.loadInt, zero, 0));
        this.emit(instABC(Op.sub, dst, operand, zero));
        return dst;
      }
      if (n.op == TokenKind.bang) {
        this.emit(instAB(Op.logicalNot, dst, operand));
        return dst;
      }
      if (n.op == TokenKind.tilde) {
        this.emit(instAB(Op.bitNot, dst, operand));
        return dst;
      }
      this.hadError = true;
      return 0;
    }
    if (k == NodeKind.assignment && n.op == TokenKind.eq) {
      const target = parser.ast.node(n.left);
      if (target.kind == NodeKind.identExpr) {
        const value = this.compileExpr(in parser, inout runtime, n.right);
        const local = this.findLocal(in parser, target.nameStart, target.nameLength);
        if (local >= 0) {
          this.emit(instAB(Op.mov, this.locals[usize(local)].reg, value));
          return value;
        }
        const slot = runtime.globalSlot(parser.source.copyBytes(usize(target.nameStart), usize(target.nameStart + target.nameLength)));
        this.emit(instAU16(Op.storeGlobal, value, slot));
        return value;
      }
    }
    if (k == NodeKind.sequence) {
      let last: u8 = 0;
      let i: u32 = 0;
      while (i < n.childrenCount) {
        last = this.compileExpr(in parser, inout runtime, parser.ast.child(node, i));
        i = i + 1;
      }
      return last;
    }

    // Not yet ported.
    this.hadError = true;
    return 0;
  }

  // --- Statements ---

  function compileStmt(inout this, in parser: Parser, inout runtime: Runtime, node: u32): void {
    if (node == NO_NODE) return;
    const n = parser.ast.node(node);
    const k = n.kind;

    if (k == NodeKind.varDecl) {
      let i: u32 = 0;
      while (i < n.childrenCount) {
        const declIndex = parser.ast.child(node, i);
        const decl = parser.ast.node(declIndex);
        if (decl.nameLength == 0) {
          this.hadError = true;
          return;
        }
        if (n.op == TokenKind.kwVar) {
          // Script-mode `var` is a global binding.
          const slot = runtime.globalSlot(parser.source.copyBytes(usize(decl.nameStart), usize(decl.nameStart + decl.nameLength)));
          if (decl.left != NO_NODE) {
            const value = this.compileExpr(in parser, inout runtime, decl.left);
            this.emit(instAU16(Op.defineGlobal, value, slot));
          } else {
            const undefinedReg = this.allocReg();
            this.emit(instA(Op.loadUndefined, undefinedReg));
            this.emit(instAU16(Op.defineGlobal, undefinedReg, slot));
          }
        } else {
          // let / const: a register-held lexical binding.
          const reg = this.addLocal(decl.nameStart, decl.nameLength);
          this.fixedRegs = this.nextReg;
          if (decl.left != NO_NODE) {
            const value = this.compileExpr(in parser, inout runtime, decl.left);
            this.emit(instAB(Op.mov, reg, value));
          } else {
            this.emit(instA(Op.loadUndefined, reg));
          }
        }
        this.resetTemps();
        i = i + 1;
      }
      return;
    }
    if (k == NodeKind.emptyStmt) return;
    if (k == NodeKind.blockStmt) {
      let i: u32 = 0;
      while (i < n.childrenCount) {
        this.compileStmt(in parser, inout runtime, parser.ast.child(node, i));
        i = i + 1;
      }
      return;
    }
    if (isStatementKind(k)) {
      // Not yet ported.
      this.hadError = true;
      return;
    }

    // An expression statement. At the program top level its value is moved
    // into the reserved result register so the final Return picks up the
    // last one whatever path ran.
    const r = this.compileExpr(in parser, inout runtime, node);
    if (this.lastExprReg >= 0) {
      const dst = u8(this.lastExprReg);
      if (r != dst) this.emit(instAB(Op.mov, dst, r));
    }
    this.resetTemps();
  }
}

// Kinds that are statements but not yet compiled.
function isStatementKind(k: NodeKind): boolean {
  return k == NodeKind.ifStmt || k == NodeKind.whileStmt || k == NodeKind.doWhileStmt
    || k == NodeKind.forStmt || k == NodeKind.forInStmt || k == NodeKind.forOfStmt
    || k == NodeKind.returnStmt || k == NodeKind.breakStmt || k == NodeKind.continueStmt
    || k == NodeKind.throwStmt || k == NodeKind.tryStmt || k == NodeKind.switchStmt
    || k == NodeKind.labeledStmt || k == NodeKind.withStmt || k == NodeKind.functionDecl
    || k == NodeKind.classDecl || k == NodeKind.importDecl || k == NodeKind.exportDecl;
}

function binaryOp(kind: TokenKind): Op {
  if (kind == TokenKind.plus) return Op.add;
  if (kind == TokenKind.minus) return Op.sub;
  if (kind == TokenKind.star) return Op.mul;
  if (kind == TokenKind.slash) return Op.div;
  if (kind == TokenKind.percent) return Op.mod;
  if (kind == TokenKind.starStar) return Op.pow;
  if (kind == TokenKind.amp) return Op.bitAnd;
  if (kind == TokenKind.pipe) return Op.bitOr;
  if (kind == TokenKind.caret) return Op.bitXor;
  if (kind == TokenKind.ltLt) return Op.shl;
  if (kind == TokenKind.gtGt) return Op.shr;
  if (kind == TokenKind.gtGtGt) return Op.uShr;
  return Op.halt;
}

struct ExactInt32 {
  exact: boolean;
  value: i32;
}

// Whether a double is exactly an int32 (and which), mirroring the
// reference's `(f64)(i32)v == v` test. -0 is not an int32.
function f64ToInt32Exact(value: f64): ExactInt32 {
  const lowest: f64 = -2147483648.0;
  const highest: f64 = 2147483647.0;
  if (value < lowest || value > highest) return ExactInt32({ exact: false, value: 0 });
  if (value != value) return ExactInt32({ exact: false, value: 0 });
  const truncated = i32(math_trunc(value));
  if (f64(truncated) != value) return ExactInt32({ exact: false, value: 0 });
  if (truncated == 0 && value.toBits() != 0) return ExactInt32({ exact: false, value: 0 });
  return ExactInt32({ exact: true, value: truncated });
}

function math_trunc(value: f64): f64 = raw c {
  return __builtin_trunc(value);
}

// --- Entry ----------------------------------------------------------------

// Compiles a parsed program into the runtime's function table; returns the
// function index, or -1 on error.
export function compileProgram(in parser: Parser, root: u32, inout runtime: Runtime): i32 {
  let compiler = Compiler({
    code: Array<Inst>(), constants: Array<Value>(), nextReg: 0, maxReg: 0, fixedRegs: 0,
    locals: Array<Local>(), lastExprReg: -1, hadError: false, strict: parser.strictMode,
  });
  const resultReg = compiler.allocReg();
  compiler.emit(instA(Op.loadUndefined, resultReg));
  compiler.fixedRegs = resultReg + 1;
  compiler.lastExprReg = i32(resultReg);

  const program = parser.ast.node(root);
  let i: u32 = 0;
  while (i < program.childrenCount && !compiler.hadError) {
    compiler.compileStmt(in parser, inout runtime, parser.ast.child(root, i));
    i = i + 1;
  }
  compiler.emit(instA(Op.returnOp, resultReg));
  if (compiler.hadError) return -1;

  // A field cannot be moved out of its owner; replace hands the buffers
  // out and leaves empty ones behind. The result types are written out
  // because inference on replace of an Array field mis-lowers today.
  let compiled = createFunctionCode();
  const code: Array<Inst> = replace(inout compiler.code, Array<Inst>());
  const constants: Array<Value> = replace(inout compiler.constants, Array<Value>());
  compiled.code = move code;
  compiled.constants = move constants;
  compiled.registerCount = u32(compiler.maxReg) + 1;
  compiled.fixedRegs = u32(compiler.fixedRegs);
  compiled.strict = compiler.strict;
  return i32(runtime.addFunction(move compiled));
}
