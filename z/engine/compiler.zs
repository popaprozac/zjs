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
import { Op, Inst, FunctionCode, createFunctionCode, instA, instAB, instABC, instAU16, instAI16, instI16 } from "./bytecode.zs";
import { Runtime } from "./runtime.zs";
import { replace } from "std/memory";

const B_LF: u8 = 10;
const B_CR: u8 = 13;
const B_BACKSLASH: u8 = 92;
const B_0: u8 = 48;
const B_9: u8 = 57;
const B_a: u8 = 97;
const B_f: u8 = 102;
const B_UPPER_A: u8 = 65;
const B_UPPER_F: u8 = 70;
const B_x: u8 = 120;
const B_u: u8 = 117;
const B_LBRACE: u8 = 123;
const B_RBRACE: u8 = 125;

function hexValue(c: u8): i32 {
  if (c >= B_0 && c <= B_9) return i32(c - B_0);
  if (c >= B_a && c <= B_f) return i32(c - B_a) + 10;
  if (c >= B_UPPER_A && c <= B_UPPER_F) return i32(c - B_UPPER_A) + 10;
  return -1;
}

// A loop being compiled: where `continue` goes, and the jumps that
// `break` / `continue` left to be patched when the loop's shape is known.
struct LoopFrame {
  continueTarget: u32;
  haveContinue: boolean;
  breakPatches: Array<u32>;
  continuePatches: Array<u32>;
}

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
  // Loop stack: `loopDepth` marks the live extent of a reused array, since
  // Z's Array cannot remove elements.
  loops: Array<LoopFrame>;
  loopDepth: usize;

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

  // Patch a forward jump at `at` to land on the next emitted instruction.
  function patchJump(inout this, at: u32): void {
    const here = i32(this.code.length);
    const inst = this.code[usize(at)];
    const offset = here - (i32(at) + 1);
    this.code[usize(at)] = instAI16(inst.op, inst.a, offset);
  }

  function emitJumpBack(inout this, target: u32): void {
    const here = i32(this.code.length);
    this.emit(instI16(Op.jmp, i32(target) - (here + 1)));
  }

  function emitJumpBackIf(inout this, op: Op, src: u8, target: u32): void {
    const here = i32(this.code.length);
    this.emit(instAI16(op, src, i32(target) - (here + 1)));
  }

  // --- Loops ---

  function loopPush(inout this): void {
    const frame = LoopFrame({
      continueTarget: 0, haveContinue: false,
      breakPatches: Array<u32>(), continuePatches: Array<u32>(),
    });
    if (this.loopDepth < this.loops.length) {
      this.loops[this.loopDepth] = frame;
    } else {
      this.loops.push(frame);
    }
    this.loopDepth = this.loopDepth + 1;
  }

  function loopSetContinue(inout this, target: u32): void {
    const top = this.loopDepth - 1;
    this.loops[top].continueTarget = target;
    this.loops[top].haveContinue = true;
    let i: usize = 0;
    const count = this.loops[top].continuePatches.length;
    while (i < count) {
      const at = this.loops[top].continuePatches[i];
      const inst = this.code[usize(at)];
      this.code[usize(at)] = instAI16(inst.op, inst.a, i32(target) - (i32(at) + 1));
      i = i + 1;
    }
  }

  // Patch every pending break to the next instruction, then drop the loop.
  function loopPop(inout this): void {
    const top = this.loopDepth - 1;
    let i: usize = 0;
    const count = this.loops[top].breakPatches.length;
    while (i < count) {
      const bound1 = this.loops[top].breakPatches[i];
      this.patchJump(bound1);
      i = i + 1;
    }
    this.loopDepth = this.loopDepth - 1;
  }

  // The top-level completion value resets to undefined before a
  // statement that may not run its body.
  function resetCompletion(inout this): void {
    if (this.lastExprReg >= 0) this.emit(instA(Op.loadUndefined, u8(this.lastExprReg)));
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

  // Store a register into the binding an identifier names.
  function storeIdent(inout this, in parser: Parser, inout runtime: Runtime, target: AstNode, value: u8): void {
    const local = this.findLocal(in parser, target.nameStart, target.nameLength);
    if (local >= 0) {
      const reg = this.locals[usize(local)].reg;
      this.emit(instAB(Op.mov, reg, value));
      return;
    }
    const slot = runtime.globalSlot(parser.source.copyBytes(usize(target.nameStart), usize(target.nameStart + target.nameLength)));
    this.emit(instAU16(Op.storeGlobal, value, slot));
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
    if (k == NodeKind.stringExpr) {
      const decoded = decodeStringBody(in parser, n.start + 1, n.end > 0 ? n.end - 1 : n.start + 1);
      const index = this.addConst(runtime.internValue(move decoded));
      const dst = this.allocReg();
      this.emit(instAU16(Op.loadConst, dst, index));
      return dst;
    }
    if (k == NodeKind.logical) {
      // Short-circuit: evaluate the left into dst, skip the right when the
      // operator's outcome is already decided.
      const dst = this.compileExpr(in parser, inout runtime, n.left);
      let jumpOp = Op.jmpIfFalse;
      if (n.op == TokenKind.pipePipe) jumpOp = Op.jmpIfTrue;
      if (n.op == TokenKind.questionQuestion) jumpOp = Op.jmpIfNotNullish;
      const skip = this.emit(instAI16(jumpOp, dst, 0));
      const savedNext = this.nextReg;
      const right = this.compileExpr(in parser, inout runtime, n.right);
      this.emit(instAB(Op.mov, dst, right));
      this.nextReg = savedNext;
      this.patchJump(skip);
      return dst;
    }
    if (k == NodeKind.identExpr) {
      const local = this.findLocal(in parser, n.nameStart, n.nameLength);
      const dst = this.allocReg();
      if (local >= 0) {
        const bound2 = instAB(Op.mov, dst, this.locals[usize(local)].reg);
        this.emit(bound2);
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
    if ((k == NodeKind.unary || k == NodeKind.postfix) && (n.op == TokenKind.plusPlus || n.op == TokenKind.minusMinus)) {
      const target = parser.ast.node(n.left);
      if (target.kind != NodeKind.identExpr) {
        this.hadError = true;
        return 0;
      }
      // ToNumeric(old) is `old - 0` for the numbers and strings the engine
      // has; a postfix expression's value is that numeric old value.
      const loaded = this.compileExpr(in parser, inout runtime, n.left);
      const zero = this.allocReg();
      this.emit(instAI16(Op.loadInt, zero, 0));
      const old = this.allocReg();
      this.emit(instABC(Op.sub, old, loaded, zero));
      const one = this.allocReg();
      this.emit(instAI16(Op.loadInt, one, 1));
      const updated = this.allocReg();
      this.emit(instABC(n.op == TokenKind.plusPlus ? Op.add : Op.sub, updated, old, one));
      this.storeIdent(in parser, inout runtime, target, updated);
      return k == NodeKind.postfix ? old : updated;
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
    if (k == NodeKind.assignment) {
      const target = parser.ast.node(n.left);
      if (target.kind == NodeKind.identExpr) {
        let value: u8 = 0;
        if (n.op == TokenKind.eq) {
          value = this.compileExpr(in parser, inout runtime, n.right);
        } else {
          // Compound assignment: current value, operator, right operand.
          const current = this.compileExpr(in parser, inout runtime, n.left);
          const right = this.compileExpr(in parser, inout runtime, n.right);
          const op = compoundOp(n.op);
          if (op == Op.halt) {
            this.hadError = true;
            return 0;
          }
          value = this.allocReg();
          this.emit(instABC(op, value, current, right));
        }
        this.storeIdent(in parser, inout runtime, target, value);
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

  // A for-init slot: a declaration or an expression whose value is dropped.
  function compileStmtOrExpr(inout this, in parser: Parser, inout runtime: Runtime, node: u32): void {
    if (parser.ast.node(node).kind == NodeKind.varDecl) {
      this.compileStmt(in parser, inout runtime, node);
      return;
    }
    const unused = this.compileExpr(in parser, inout runtime, node);
    this.resetTemps();
  }

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
    if (k == NodeKind.ifStmt) {
      this.resetCompletion();
      const condition = this.compileExpr(in parser, inout runtime, n.left);
      const jumpElse = this.emit(instAI16(Op.jmpIfFalse, condition, 0));
      this.resetTemps();
      this.compileStmt(in parser, inout runtime, n.right);
      if (n.third != NO_NODE) {
        const jumpEnd = this.emit(instI16(Op.jmp, 0));
        this.patchJump(jumpElse);
        this.compileStmt(in parser, inout runtime, n.third);
        this.patchJump(jumpEnd);
      } else {
        this.patchJump(jumpElse);
      }
      return;
    }
    if (k == NodeKind.whileStmt) {
      this.resetCompletion();
      const loopTop = u32(this.code.length);
      this.loopPush();
      this.loopSetContinue(loopTop);
      const condition = this.compileExpr(in parser, inout runtime, n.left);
      const jumpExit = this.emit(instAI16(Op.jmpIfFalse, condition, 0));
      this.resetTemps();
      this.compileStmt(in parser, inout runtime, n.right);
      this.emitJumpBack(loopTop);
      this.patchJump(jumpExit);
      this.loopPop();
      return;
    }
    if (k == NodeKind.doWhileStmt) {
      this.resetCompletion();
      const loopTop = u32(this.code.length);
      this.loopPush();
      this.compileStmt(in parser, inout runtime, n.left);
      const bound4 = u32(this.code.length);
      this.loopSetContinue(bound4);
      const condition = this.compileExpr(in parser, inout runtime, n.right);
      this.emitJumpBackIf(Op.jmpIfTrue, condition, loopTop);
      this.resetTemps();
      this.loopPop();
      return;
    }
    if (k == NodeKind.forStmt) {
      if (n.left != NO_NODE) this.compileStmtOrExpr(in parser, inout runtime, n.left);
      this.resetCompletion();
      const loopTop = u32(this.code.length);
      this.loopPush();
      let jumpExit: i32 = -1;
      if (n.right != NO_NODE) {
        const condition = this.compileExpr(in parser, inout runtime, n.right);
        jumpExit = i32(this.emit(instAI16(Op.jmpIfFalse, condition, 0)));
        this.resetTemps();
      }
      if (n.childrenCount > 0) this.compileStmt(in parser, inout runtime, parser.ast.child(node, 0));
      const bound5 = u32(this.code.length);
      this.loopSetContinue(bound5);
      if (n.third != NO_NODE) {
        const unused = this.compileExpr(in parser, inout runtime, n.third);
        this.resetTemps();
      }
      this.emitJumpBack(loopTop);
      if (jumpExit >= 0) this.patchJump(u32(jumpExit));
      this.loopPop();
      return;
    }
    if (k == NodeKind.breakStmt) {
      if (this.loopDepth == 0 || n.nameLength > 0) {
        this.hadError = true;
        return;
      }
      const at = this.emit(instI16(Op.jmp, 0));
      const top = this.loopDepth - 1;
      this.loops[top].breakPatches.push(at);
      return;
    }
    if (k == NodeKind.continueStmt) {
      if (this.loopDepth == 0 || n.nameLength > 0) {
        this.hadError = true;
        return;
      }
      const top = this.loopDepth - 1;
      if (this.loops[top].haveContinue) {
        const bound6 = this.loops[top].continueTarget;
        this.emitJumpBack(bound6);
      } else {
        const at = this.emit(instI16(Op.jmp, 0));
        this.loops[top].continuePatches.push(at);
      }
      return;
    }
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
  return k == NodeKind.forInStmt || k == NodeKind.forOfStmt
    || k == NodeKind.returnStmt
    || k == NodeKind.throwStmt || k == NodeKind.tryStmt || k == NodeKind.switchStmt
    || k == NodeKind.labeledStmt || k == NodeKind.withStmt || k == NodeKind.functionDecl
    || k == NodeKind.classDecl || k == NodeKind.importDecl || k == NodeKind.exportDecl;
}

function compoundOp(kind: TokenKind): Op {
  if (kind == TokenKind.plusEq) return Op.add;
  if (kind == TokenKind.minusEq) return Op.sub;
  if (kind == TokenKind.starEq) return Op.mul;
  if (kind == TokenKind.slashEq) return Op.div;
  if (kind == TokenKind.percentEq) return Op.mod;
  if (kind == TokenKind.starStarEq) return Op.pow;
  if (kind == TokenKind.ampEq) return Op.bitAnd;
  if (kind == TokenKind.pipeEq) return Op.bitOr;
  if (kind == TokenKind.caretEq) return Op.bitXor;
  if (kind == TokenKind.ltLtEq) return Op.shl;
  if (kind == TokenKind.gtGtEq) return Op.shr;
  if (kind == TokenKind.gtGtGtEq) return Op.uShr;
  return Op.halt;
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
  if (kind == TokenKind.eqEq) return Op.cmpEq;
  if (kind == TokenKind.bangEq) return Op.cmpNe;
  if (kind == TokenKind.eqEqEq) return Op.cmpStrictEq;
  if (kind == TokenKind.bangEqEq) return Op.cmpStrictNe;
  if (kind == TokenKind.lt) return Op.cmpLt;
  if (kind == TokenKind.ltEq) return Op.cmpLe;
  if (kind == TokenKind.gt) return Op.cmpGt;
  if (kind == TokenKind.gtEq) return Op.cmpGe;
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

// --- String literals --------------------------------------------------------
//
// Decode the body of a string literal (between the quotes): escapes, hex and
// unicode escapes (encoded as UTF-8), and line continuations. Mirrors the
// reference's decode_string_body. The result is the string's bytes.

function pushUtf8(inout bytes: Array<u8>, codePoint: u32): void {
  if (codePoint < 0x80) {
    bytes.push(u8(codePoint));
  } else if (codePoint < 0x800) {
    bytes.push(u8(0xC0 | (codePoint >> 6)));
    bytes.push(u8(0x80 | (codePoint & 0x3F)));
  } else if (codePoint < 0x1_0000) {
    bytes.push(u8(0xE0 | (codePoint >> 12)));
    bytes.push(u8(0x80 | ((codePoint >> 6) & 0x3F)));
    bytes.push(u8(0x80 | (codePoint & 0x3F)));
  } else {
    bytes.push(u8(0xF0 | (codePoint >> 18)));
    bytes.push(u8(0x80 | ((codePoint >> 12) & 0x3F)));
    bytes.push(u8(0x80 | ((codePoint >> 6) & 0x3F)));
    bytes.push(u8(0x80 | (codePoint & 0x3F)));
  }
}

function decodeStringBody(in parser: Parser, rawStart: u32, rawEnd: u32): Array<u8> {
  const rawLength: u32 = rawEnd > rawStart ? rawEnd - rawStart : 0;
  let bytes = Array<u8>();
  let i: u32 = 0;
  while (i < rawLength) {
    const ch = parser.source.byteAt(usize(rawStart + i));
    if (ch == B_BACKSLASH && i + 1 < rawLength) {
      const next = parser.source.byteAt(usize(rawStart + i + 1));
      if (next == B_LF) {
        i = i + 2;
        continue;
      }
      if (next == B_CR) {
        if (i + 2 < rawLength && parser.source.byteAt(usize(rawStart + i + 2)) == B_LF) {
          i = i + 3;
        } else {
          i = i + 2;
        }
        continue;
      }
      if (next == B_x && i + 3 < rawLength) {
        const h1 = hexValue(parser.source.byteAt(usize(rawStart + i + 2)));
        const h2 = hexValue(parser.source.byteAt(usize(rawStart + i + 3)));
        if (h1 >= 0 && h2 >= 0) {
          bytes.push(u8((h1 << 4) | h2));
          i = i + 4;
          continue;
        }
      }
      if (next == B_u) {
        let codePoint: u32 = 0;
        let consumed: u32 = 0;
        if (i + 2 < rawLength && parser.source.byteAt(usize(rawStart + i + 2)) == B_LBRACE) {
          let p: u32 = i + 3;
          let valid = true;
          while (p < rawLength) {
            const cc = parser.source.byteAt(usize(rawStart + p));
            if (cc == B_RBRACE) break;
            const d = hexValue(cc);
            if (d < 0) {
              valid = false;
              break;
            }
            codePoint = codePoint.wrappingMultiply(16) + u32(d);
            p = p + 1;
          }
          if (valid && p < rawLength && parser.source.byteAt(usize(rawStart + p)) == B_RBRACE) {
            consumed = p - i + 1;
          }
        } else if (i + 5 < rawLength) {
          const h1 = hexValue(parser.source.byteAt(usize(rawStart + i + 2)));
          const h2 = hexValue(parser.source.byteAt(usize(rawStart + i + 3)));
          const h3 = hexValue(parser.source.byteAt(usize(rawStart + i + 4)));
          const h4 = hexValue(parser.source.byteAt(usize(rawStart + i + 5)));
          if (h1 >= 0 && h2 >= 0 && h3 >= 0 && h4 >= 0) {
            codePoint = u32((h1 << 12) | (h2 << 8) | (h3 << 4) | h4);
            consumed = 6;
          }
        }
        if (consumed > 0) {
          pushUtf8(inout bytes, codePoint);
          i = i + consumed;
          continue;
        }
      }
      let mapped: u8 = next;
      if (next == 110) {
        mapped = 10;
      } else if (next == 116) {
        mapped = 9;
      } else if (next == 114) {
        mapped = 13;
      } else if (next == 98) {
        mapped = 8;
      } else if (next == 102) {
        mapped = 12;
      } else if (next == 118) {
        mapped = 11;
      } else if (next == 48) {
        mapped = 0;
      }
      bytes.push(mapped);
      i = i + 2;
    } else {
      bytes.push(ch);
      i = i + 1;
    }
  }
  return bytes;
}

// --- Entry ----------------------------------------------------------------

// Compiles a parsed program into the runtime's function table; returns the
// function index, or -1 on error.
export function compileProgram(in parser: Parser, root: u32, inout runtime: Runtime): i32 {
  let compiler = Compiler({
    code: Array<Inst>(), constants: Array<Value>(), nextReg: 0, maxReg: 0, fixedRegs: 0,
    locals: Array<Local>(), lastExprReg: -1, hadError: false, strict: parser.strictMode,
    loops: Array<LoopFrame>(), loopDepth: 0,
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
