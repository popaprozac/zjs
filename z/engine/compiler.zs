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
import { Op, Inst, FunctionCode, createFunctionCode, instA, instAB, instABC, instAU16, instAI16, instI16, instU16 } from "./bytecode.zs";
import { Runtime } from "./runtime.zs";
import { bytesOf } from "./heap.zs";
import { cellValue } from "./value.zs";
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
  // The statement's label, if any, and whether `continue` may target it
  // (a loop, as opposed to a switch or a labeled block).
  labelStart: u32;
  labelLength: u32;
  isIter: boolean;
}

// A binding of the function being compiled. It lives in a register, or --
// when a nested function refers to it -- in a slot of the function's
// environment cell, so the nested function can outlive the frame.
struct Local {
  nameStart: u32;
  nameLength: u32;
  reg: u8;
  envSlot: i32;
}

// An enclosing function's bindings, as seen from a nested one: the
// captured ones are reachable through the environment chain.
struct Scope {
  names: Array<Local>;
  hasEnv: boolean;
}

// Where an identifier resolved outside the current function.
struct OuterRef {
  found: boolean;
  hops: u8;
  slot: i32;
  scopeIndex: usize;
}

// What compiling a nested function tells its parent.
struct CompiledFunction {
  index: i32;
  // The outermost enclosing scope the function (or anything nested in
  // it) refers to; `scopes.length` when it refers to none.
  minOuterScope: usize;
}

export struct Compiler {
  code: Array<Inst>;
  constants: Array<Value>;
  nextReg: u8;
  maxReg: u8;
  fixedRegs: u8;
  locals: Array<Local>;
  // The enclosing functions' bindings, outermost first; the program's
  // top-level lexical bindings are scope 0.
  outerScopes: Array<Scope>;
  // Bindings a nested function refers to, found by the capture scan
  // before the body compiles. Those already in `locals` are marked in
  // place; the rest (let, const, catch parameters) are recorded here and
  // take their slot when they are bound.
  capturedNames: Array<Local>;
  hasEnv: boolean;
  envSize: u32;
  // The outermost enclosing scope anything in this function refers to;
  // `outerScopes.length` for none. A function that reaches past its
  // parent makes the parent a closure too.
  minOuterScope: usize;
  // The program's reserved result register, or -1 inside a function.
  lastExprReg: i32;
  // Compiling a function body (as opposed to the script top level).
  isFunction: boolean;
  hadError: boolean;
  strict: boolean;
  // Loop stack: `loopDepth` marks the live extent of a reused array, since
  // Z's Array cannot remove elements.
  loops: Array<LoopFrame>;
  loopDepth: usize;
  // A label waiting for the loop statement it names.
  pendingLabelStart: u32;
  pendingLabelLength: u32;
  // The register holding `this` in a function that reads it, or -1.
  thisReg: i32;
  // Interned names for LoadProp / StoreProp; the instruction carries an
  // index into this table.
  propertyNames: Array<u32>;

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

  // Open a break target: a loop (which `continue` may also target) or a
  // switch / labeled block. A pending label attaches to it.
  function loopPush(inout this, isIter: boolean): void {
    const frame = LoopFrame({
      continueTarget: 0, haveContinue: false,
      breakPatches: Array<u32>(), continuePatches: Array<u32>(),
      labelStart: this.pendingLabelStart, labelLength: this.pendingLabelLength, isIter: isIter,
    });
    this.pendingLabelStart = 0;
    this.pendingLabelLength = 0;
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

  // The open frame carrying `label`, or -1.
  function findLabeledFrame(in parser: Parser, nameStart: u32, nameLength: u32): i32 {
    let index = this.loopDepth;
    while (index > 0) {
      index = index - 1;
      const labelStart = this.loops[index].labelStart;
      const labelLength = this.loops[index].labelLength;
      if (labelLength == nameLength && this.nameMatches(in parser, labelStart, labelLength, nameStart, nameLength)) return i32(index);
    }
    return -1;
  }

  // Patch a jump at `at` to land on instruction `target`.
  function patchJumpTo(inout this, at: u32, target: u32): void {
    const inst = this.code[usize(at)];
    this.code[usize(at)] = instAI16(inst.op, inst.a, i32(target) - (i32(at) + 1));
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

  // The environment slot the capture scan reserved for a binding
  // declared at `nameStart`, or -1.
  function capturedSlot(nameStart: u32): i32 {
    let index: usize = 0;
    while (index < this.capturedNames.length) {
      if (this.capturedNames[index].nameStart == nameStart) return this.capturedNames[index].envSlot;
      index = index + 1;
    }
    return -1;
  }

  function addLocal(inout this, nameStart: u32, nameLength: u32): u8 {
    const envSlot = this.capturedSlot(nameStart);
    let reg: u8 = 0;
    if (envSlot < 0) reg = this.allocReg();
    this.locals.push(Local({ nameStart: nameStart, nameLength: nameLength, reg: reg, envSlot: envSlot }));
    return reg;
  }

  // Load a binding of this function into a register.
  function loadLocal(inout this, index: usize, dst: u8): void {
    const slot = this.locals[index].envSlot;
    if (slot >= 0) {
      this.emit(instABC(Op.loadEnvSlot, dst, 0, u8(slot)));
    } else {
      const reg = this.locals[index].reg;
      this.emit(instAB(Op.mov, dst, reg));
    }
  }

  // Store a register into a binding of this function.
  function storeLocal(inout this, index: usize, value: u8): void {
    const slot = this.locals[index].envSlot;
    if (slot >= 0) {
      this.emit(instABC(Op.storeEnvSlot, value, 0, u8(slot)));
    } else {
      const reg = this.locals[index].reg;
      this.emit(instAB(Op.mov, reg, value));
    }
  }

  // Resolve a name in the enclosing functions. `hops` counts the
  // environments between here and the one holding it: this function's
  // own, if it has one, then one per enclosing function that has one.
  function findOuter(inout this, in parser: Parser, nameStart: u32, nameLength: u32): OuterRef {
    let hops: u8 = this.hasEnv ? 1 : 0;
    let level: usize = this.outerScopes.length;
    while (level > 0) {
      level = level - 1;
      let index: usize = this.outerScopes[level].names.length;
      while (index > 0) {
        index = index - 1;
        const outer = this.outerScopes[level].names[index];
        if (outer.nameLength == nameLength && this.nameMatches(in parser, outer.nameStart, outer.nameLength, nameStart, nameLength)) {
          if (level < this.minOuterScope) this.minOuterScope = level;
          return OuterRef({ found: true, hops: hops, slot: outer.envSlot, scopeIndex: level });
        }
      }
      if (this.outerScopes[level].hasEnv) hops = hops + 1;
    }
    return OuterRef({ found: false, hops: 0, slot: -1, scopeIndex: 0 });
  }

  // --- Capture scan ---
  //
  // Before a body compiles, every binding a nested function refers to is
  // given a slot in this function's environment. Bindings already
  // collected are marked in place; let, const, and catch parameters,
  // which bind as they are compiled, are recorded for `addLocal` and
  // `bindLocal` to find.
  function scanCaptures(inout this, in parser: Parser, body: u32): void {
    let index: usize = 0;
    while (index < this.locals.length) {
      const local = this.locals[index];
      if (local.nameLength > 0 && capturedBy(in parser, body, local.nameStart, local.nameLength, false)) {
        this.locals[index].envSlot = i32(this.envSize);
        this.envSize = this.envSize + 1;
      }
      index = index + 1;
    }
    this.scanLateBindings(in parser, body, body);
    this.hasEnv = this.envSize > 0;
  }

  // let / const declarations and catch parameters of this function's
  // body, not entering nested functions.
  function scanLateBindings(inout this, in parser: Parser, node: u32, body: u32): void {
    if (node == NO_NODE) return;
    const n = parser.ast.node(node);
    const k = n.kind;
    if (k == NodeKind.functionDecl || k == NodeKind.functionExpr || k == NodeKind.arrowFunc) return;
    if (k == NodeKind.varDecl && n.op != TokenKind.kwVar) {
      let i: u32 = 0;
      while (i < n.childrenCount) {
        const declIndex = parser.ast.child(node, i);
        const decl = parser.ast.node(declIndex);
        if (decl.nameLength > 0 && capturedBy(in parser, body, decl.nameStart, decl.nameLength, false)) {
          this.capturedNames.push(Local({ nameStart: decl.nameStart, nameLength: decl.nameLength, reg: 0, envSlot: i32(this.envSize) }));
          this.envSize = this.envSize + 1;
        }
        if (decl.left != NO_NODE) this.scanLateBindings(in parser, decl.left, body);
        i = i + 1;
      }
      return;
    }
    if (k == NodeKind.tryStmt && n.nameLength > 0 && capturedBy(in parser, n.right, n.nameStart, n.nameLength, false)) {
      this.capturedNames.push(Local({ nameStart: n.nameStart, nameLength: n.nameLength, reg: 0, envSlot: i32(this.envSize) }));
      this.envSize = this.envSize + 1;
    }
    this.scanLateBindings(in parser, n.left, body);
    this.scanLateBindings(in parser, n.right, body);
    this.scanLateBindings(in parser, n.third, body);
    let i: u32 = 0;
    while (i < n.childrenCount) {
      this.scanLateBindings(in parser, parser.ast.child(node, i), body);
      i = i + 1;
    }
  }

  // Function-scoped bindings of a body: var, let, const, and nested
  // function declarations, all as registers. Nested functions are not
  // entered; their bindings are their own.
  function collectLocals(inout this, in parser: Parser, node: u32): void {
    if (node == NO_NODE) return;
    const n = parser.ast.node(node);
    const k = n.kind;
    if (k == NodeKind.functionDecl) {
      if (this.findLocal(in parser, n.nameStart, n.nameLength) < 0) this.addLocal(n.nameStart, n.nameLength);
      return;
    }
    if (k == NodeKind.functionExpr || k == NodeKind.arrowFunc || k == NodeKind.classDecl || k == NodeKind.classExpr) return;
    if (k == NodeKind.varDecl) {
      let i: u32 = 0;
      while (i < n.childrenCount) {
        const decl = parser.ast.node(parser.ast.child(node, i));
        if (decl.nameLength > 0 && this.findLocal(in parser, decl.nameStart, decl.nameLength) < 0) {
          this.addLocal(decl.nameStart, decl.nameLength);
        }
        i = i + 1;
      }
      return;
    }
    if (n.left != NO_NODE) this.collectLocals(in parser, n.left);
    if (n.right != NO_NODE) this.collectLocals(in parser, n.right);
    if (n.third != NO_NODE) this.collectLocals(in parser, n.third);
    let i: u32 = 0;
    while (i < n.childrenCount) {
      this.collectLocals(in parser, parser.ast.child(node, i));
      i = i + 1;
    }
  }

  // Store a register into the binding an identifier names.
  function storeIdent(inout this, in parser: Parser, inout runtime: Runtime, target: AstNode, value: u8): void {
    const local = this.findLocal(in parser, target.nameStart, target.nameLength);
    if (local >= 0) {
      this.storeLocal(usize(local), value);
      return;
    }
    const outer = this.findOuter(in parser, target.nameStart, target.nameLength);
    if (outer.found) {
      if (outer.slot < 0) {
        this.hadError = true;
        return;
      }
      this.emit(instABC(Op.storeEnvSlot, value, outer.hops, u8(outer.slot)));
      return;
    }
    const slot = runtime.globalSlot(parser.source.copyBytes(usize(target.nameStart), usize(target.nameStart + target.nameLength)));
    this.emit(instAU16(Op.storeGlobal, value, slot));
  }

  // A local bound to a register chosen by the caller (a catch parameter).
  // A captured one is copied on into its environment slot.
  function bindLocal(inout this, nameStart: u32, nameLength: u32, reg: u8): usize {
    const envSlot = this.capturedSlot(nameStart);
    this.locals.push(Local({ nameStart: nameStart, nameLength: nameLength, reg: reg, envSlot: envSlot }));
    if (envSlot >= 0) this.emit(instABC(Op.storeEnvSlot, reg, 0, u8(envSlot)));
    return this.locals.length - 1;
  }

  // Close a binding's scope. The entry stays, since Z's Array cannot
  // remove elements, but an empty name never matches a lookup.
  function unbindLocal(inout this, index: usize): void {
    this.locals[index].nameLength = 0;
  }

  // --- Property names ---

  function atomOfSlice(in parser: Parser, inout runtime: Runtime, start: u32, length: u32): u32 {
    const text = parser.source.copyBytes(usize(start), usize(start + length));
    return runtime.internBytes(bytesOf(in text));
  }

  // The name operand of LoadProp / StoreProp: an index into the
  // function's property-name table, shared by every use of the name.
  function nameSlot(inout this, atom: u32): u8 {
    let index: usize = 0;
    while (index < this.propertyNames.length) {
      if (this.propertyNames[index] == atom) return u8(index);
      index = index + 1;
    }
    if (this.propertyNames.length >= 256) {
      this.hadError = true;
      return 0;
    }
    this.propertyNames.push(atom);
    return u8(this.propertyNames.length - 1);
  }

  // A key register holding an interned name.
  function emitKey(inout this, atom: u32): u8 {
    const constant = this.addConst(cellValue(atom));
    const reg = this.allocReg();
    this.emit(instAU16(Op.loadConst, reg, constant));
    return reg;
  }

  // An object-literal or member name as an atom. Quoted keys drop their
  // quotes and decode escapes; private names are not supported yet.
  function propertyNameAtom(inout this, in parser: Parser, inout runtime: Runtime, nameStart: u32, nameLength: u32): u32 {
    if (nameLength == 0) {
      this.hadError = true;
      return 0;
    }
    const first = parser.source.byteAt(usize(nameStart));
    if (first == 34 || first == 39) {
      if (nameLength < 2) {
        this.hadError = true;
        return 0;
      }
      return runtime.internBytes(decodeStringBody(in parser, nameStart + 1, nameStart + nameLength - 1));
    }
    if (first == 35) {
      this.hadError = true;
      return 0;
    }
    return this.atomOfSlice(in parser, inout runtime, nameStart, nameLength);
  }

  // Compile a nested function and load its value into `dst`. The value
  // is a closure when the function refers to enclosing bindings or is an
  // arrow (which keeps the `this` of its creation); reaching past this
  // function makes this one a closure as well.
  function emitFunctionValue(inout this, in parser: Parser, inout runtime: Runtime, node: u32, dst: u8): void {
    const hasEnv = this.hasEnv;
    const strict = this.strict;
    const compiled = compileFunction(in parser, inout runtime, node, in this.outerScopes, in this.locals, hasEnv, strict);
    if (compiled.index < 0) {
      this.hadError = true;
      return;
    }
    const constant = this.addConst(runtime.functionValue(u32(compiled.index)));
    this.emit(instAU16(Op.loadConst, dst, constant));
    const ownScope = this.outerScopes.length;
    const isArrow = parser.ast.node(node).kind == NodeKind.arrowFunc;
    if (isArrow || compiled.minOuterScope <= ownScope) this.emit(instAB(Op.makeClosure, dst, dst));
    if (compiled.minOuterScope < ownScope && compiled.minOuterScope < this.minOuterScope) this.minOuterScope = compiled.minOuterScope;
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
    if (k == NodeKind.conditional) {
      const condition = this.compileExpr(in parser, inout runtime, n.left);
      const jumpElse = this.emit(instAI16(Op.jmpIfFalse, condition, 0));
      const dst = this.allocReg();
      const savedNext = this.nextReg;
      const consequent = this.compileExpr(in parser, inout runtime, n.right);
      this.emit(instAB(Op.mov, dst, consequent));
      const jumpEnd = this.emit(instI16(Op.jmp, 0));
      this.patchJump(jumpElse);
      this.nextReg = savedNext;
      const alternate = this.compileExpr(in parser, inout runtime, n.third);
      this.emit(instAB(Op.mov, dst, alternate));
      this.nextReg = savedNext;
      this.patchJump(jumpEnd);
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
        this.loadLocal(usize(local), dst);
        return dst;
      }
      const outer = this.findOuter(in parser, n.nameStart, n.nameLength);
      if (outer.found) {
        if (outer.slot < 0) {
          // The capture scan should have moved it into an environment.
          this.hadError = true;
          return dst;
        }
        this.emit(instABC(Op.loadEnvSlot, dst, outer.hops, u8(outer.slot)));
        return dst;
      }
      const slot = runtime.globalSlot(parser.source.copyBytes(usize(n.nameStart), usize(n.nameStart + n.nameLength)));
      this.emit(instAU16(Op.loadGlobal, dst, slot));
      return dst;
    }
    if (k == NodeKind.templatePartExpr) {
      const decoded = decodeStringBody(in parser, n.start, n.end);
      const index = this.addConst(runtime.internValue(move decoded));
      const dst = this.allocReg();
      this.emit(instAU16(Op.loadConst, dst, index));
      return dst;
    }
    if (k == NodeKind.templateExpr) {
      // Literal segments and substitutions, concatenated left to right.
      if (n.childrenCount == 0) {
        const index = this.addConst(runtime.internValue(Array<u8>()));
        const dst = this.allocReg();
        this.emit(instAU16(Op.loadConst, dst, index));
        return dst;
      }
      let acc = this.compileExpr(in parser, inout runtime, parser.ast.child(node, 0));
      let i: u32 = 1;
      while (i < n.childrenCount) {
        const next = this.compileExpr(in parser, inout runtime, parser.ast.child(node, i));
        const dst = this.allocReg();
        this.emit(instABC(Op.add, dst, acc, next));
        acc = dst;
        i = i + 1;
      }
      return acc;
    }
    if (k == NodeKind.thisExpr) {
      if (n.boolValue) {
        // new.target
        this.hadError = true;
        return 0;
      }
      if (this.isFunction) {
        if (this.thisReg < 0) {
          this.hadError = true;
          return 0;
        }
        return u8(this.thisReg);
      }
      const dst = this.allocReg();
      this.emit(instA(Op.loadThis, dst));
      return dst;
    }
    if (k == NodeKind.member) {
      const object = this.compileExpr(in parser, inout runtime, n.left);
      const atom = this.propertyNameAtom(in parser, inout runtime, n.nameStart, n.nameLength);
      const slot = this.nameSlot(atom);
      const dst = this.allocReg();
      this.emit(instABC(Op.loadProp, dst, object, slot));
      return dst;
    }
    if (k == NodeKind.computed) {
      const object = this.compileExpr(in parser, inout runtime, n.left);
      const key = this.compileExpr(in parser, inout runtime, n.right);
      const dst = this.allocReg();
      this.emit(instABC(Op.loadElem, dst, object, key));
      return dst;
    }
    if (k == NodeKind.object) {
      const dst = this.allocReg();
      this.emit(instA(Op.newObject, dst));
      let i: u32 = 0;
      while (i < n.childrenCount) {
        const propertyIndex = parser.ast.child(node, i);
        const property = parser.ast.node(propertyIndex);
        // Accessors and spread arrive with property descriptors and
        // iteration.
        if (property.kind != NodeKind.objectProp || property.op == TokenKind.kwGet || property.op == TokenKind.kwSet) {
          this.hadError = true;
          return 0;
        }
        let key: u8 = 0;
        if (property.third != NO_NODE) {
          key = this.compileExpr(in parser, inout runtime, property.third);
        } else {
          const atom = this.propertyNameAtom(in parser, inout runtime, property.nameStart, property.nameLength);
          key = this.emitKey(atom);
        }
        const value = this.compileExpr(in parser, inout runtime, property.left);
        this.emit(instABC(Op.initObjData, dst, key, value));
        this.nextReg = dst + 1;
        i = i + 1;
      }
      return dst;
    }
    if (k == NodeKind.array) {
      const count = n.childrenCount;
      let i: u32 = 0;
      while (i < count) {
        if (parser.ast.node(parser.ast.child(node, i)).kind == NodeKind.spread) {
          this.hadError = true;
          return 0;
        }
        i = i + 1;
      }
      if (count == 0 || count > 32) {
        // Element by element into an empty array.
        const dst = this.allocReg();
        this.emit(instABC(Op.newArray, dst, 0, 0));
        i = 0;
        while (i < count) {
          const element = this.compileExpr(in parser, inout runtime, parser.ast.child(node, i));
          this.emit(instAB(Op.arrayPush, dst, element));
          this.nextReg = dst + 1;
          i = i + 1;
        }
        return dst;
      }
      // Elements contiguous from base, then one instruction builds the array.
      const base = this.nextReg;
      i = 0;
      while (i < count) {
        this.allocReg();
        i = i + 1;
      }
      i = 0;
      while (i < count) {
        const target = base + u8(i);
        const element = this.compileExpr(in parser, inout runtime, parser.ast.child(node, i));
        if (element != target) this.emit(instAB(Op.mov, target, element));
        this.nextReg = base + u8(count);
        i = i + 1;
      }
      this.emit(instABC(Op.newArray, base, base, u8(count)));
      this.nextReg = base + 1;
      return base;
    }
    if (k == NodeKind.newExpr) {
      // Callee at base, arguments above it, the constructed object into base.
      const argCount = n.childrenCount;
      if (argCount > 255) {
        this.hadError = true;
        return 0;
      }
      const base = this.allocReg();
      let slot: u32 = 0;
      while (slot < argCount) {
        this.allocReg();
        slot = slot + 1;
      }
      const calleeReg = this.compileExpr(in parser, inout runtime, n.left);
      if (calleeReg != base) this.emit(instAB(Op.mov, base, calleeReg));
      this.nextReg = base + u8(1 + argCount);
      let j: u32 = 0;
      while (j < argCount) {
        const argument = parser.ast.child(node, j);
        if (parser.ast.node(argument).kind == NodeKind.spread) {
          this.hadError = true;
          return 0;
        }
        const target = base + u8(1 + j);
        const argReg = this.compileExpr(in parser, inout runtime, argument);
        if (argReg != target) this.emit(instAB(Op.mov, target, argReg));
        this.nextReg = base + u8(1 + argCount);
        j = j + 1;
      }
      this.emit(instABC(Op.newInvoke, base, base, u8(argCount)));
      this.nextReg = base + 1;
      return base;
    }
    if (k == NodeKind.binary && (n.op == TokenKind.kwIn || n.op == TokenKind.kwInstanceof)) {
      const left = this.compileExpr(in parser, inout runtime, n.left);
      const right = this.compileExpr(in parser, inout runtime, n.right);
      const dst = this.allocReg();
      this.emit(instABC(n.op == TokenKind.kwIn ? Op.inOp : Op.instanceofOp, dst, left, right));
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
      if (target.kind == NodeKind.member || target.kind == NodeKind.computed) {
        // Read through the key, step, write back through the same key.
        const object = this.compileExpr(in parser, inout runtime, target.left);
        let key: u8 = 0;
        if (target.kind == NodeKind.member) {
          const atom = this.propertyNameAtom(in parser, inout runtime, target.nameStart, target.nameLength);
          key = this.emitKey(atom);
        } else {
          key = this.compileExpr(in parser, inout runtime, target.right);
        }
        const loaded = this.allocReg();
        this.emit(instABC(Op.loadElem, loaded, object, key));
        const zero = this.allocReg();
        this.emit(instAI16(Op.loadInt, zero, 0));
        const old = this.allocReg();
        this.emit(instABC(Op.sub, old, loaded, zero));
        const one = this.allocReg();
        this.emit(instAI16(Op.loadInt, one, 1));
        const updated = this.allocReg();
        this.emit(instABC(n.op == TokenKind.plusPlus ? Op.add : Op.sub, updated, old, one));
        this.emit(instABC(Op.storeElem, object, key, updated));
        return k == NodeKind.postfix ? old : updated;
      }
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
    if (k == NodeKind.unary && n.op == TokenKind.kwDelete) {
      let operandNode = n.left;
      while (operandNode != NO_NODE && parser.ast.node(operandNode).kind == NodeKind.paren) {
        operandNode = parser.ast.node(operandNode).left;
      }
      const target = parser.ast.node(operandNode);
      const dst = this.allocReg();
      if (target.kind == NodeKind.member || target.kind == NodeKind.computed) {
        const object = this.compileExpr(in parser, inout runtime, target.left);
        let key: u8 = 0;
        if (target.kind == NodeKind.member) {
          const atom = this.propertyNameAtom(in parser, inout runtime, target.nameStart, target.nameLength);
          key = this.emitKey(atom);
        } else {
          key = this.compileExpr(in parser, inout runtime, target.right);
        }
        this.emit(instABC(Op.deleteElem, dst, object, key));
        return dst;
      }
      // A binding cannot be deleted; anything else evaluates and yields true.
      if (target.kind == NodeKind.identExpr) {
        this.emit(instA(Op.loadFalse, dst));
        return dst;
      }
      this.compileExpr(in parser, inout runtime, operandNode);
      this.emit(instA(Op.loadTrue, dst));
      return dst;
    }
    if (k == NodeKind.unary) {
      if (n.op == TokenKind.kwTypeof) {
        // `typeof name` on an undeclared global is "undefined", not a
        // ReferenceError.
        let operandNode = n.left;
        while (operandNode != NO_NODE && parser.ast.node(operandNode).kind == NodeKind.paren) {
          operandNode = parser.ast.node(operandNode).left;
        }
        if (operandNode != NO_NODE) {
          const target = parser.ast.node(operandNode);
          if (target.kind == NodeKind.identExpr
              && this.findLocal(in parser, target.nameStart, target.nameLength) < 0
              && !this.findOuter(in parser, target.nameStart, target.nameLength).found) {
            const slot = runtime.globalSlot(parser.source.copyBytes(usize(target.nameStart), usize(target.nameStart + target.nameLength)));
            const src = this.allocReg();
            this.emit(instAU16(Op.loadGlobalOrUndefined, src, slot));
            const dst = this.allocReg();
            this.emit(instAB(Op.typeofOp, dst, src));
            return dst;
          }
        }
      }
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
      if (n.op == TokenKind.kwVoid) {
        this.emit(instA(Op.loadUndefined, dst));
        return dst;
      }
      if (n.op == TokenKind.kwTypeof) {
        this.emit(instAB(Op.typeofOp, dst, operand));
        return dst;
      }
      this.hadError = true;
      return 0;
    }
    if (k == NodeKind.assignment && (n.op == TokenKind.ampAmpEq || n.op == TokenKind.pipePipeEq || n.op == TokenKind.questionQuestionEq)) {
      // Short-circuit: the right side is evaluated and stored only when
      // the current value calls for it; the result is whichever won.
      const target = parser.ast.node(n.left);
      let jumpOp = Op.jmpIfFalse;
      if (n.op == TokenKind.pipePipeEq) jumpOp = Op.jmpIfTrue;
      if (n.op == TokenKind.questionQuestionEq) jumpOp = Op.jmpIfNotNullish;
      if (target.kind == NodeKind.identExpr) {
        const current = this.compileExpr(in parser, inout runtime, n.left);
        const dst = this.allocReg();
        this.emit(instAB(Op.mov, dst, current));
        const skip = this.emit(instAI16(jumpOp, dst, 0));
        const value = this.compileExpr(in parser, inout runtime, n.right);
        this.emit(instAB(Op.mov, dst, value));
        this.storeIdent(in parser, inout runtime, target, dst);
        this.patchJump(skip);
        return dst;
      }
      if (target.kind == NodeKind.member || target.kind == NodeKind.computed) {
        const object = this.compileExpr(in parser, inout runtime, target.left);
        let key: u8 = 0;
        if (target.kind == NodeKind.member) {
          const atom = this.propertyNameAtom(in parser, inout runtime, target.nameStart, target.nameLength);
          key = this.emitKey(atom);
        } else {
          key = this.compileExpr(in parser, inout runtime, target.right);
        }
        const dst = this.allocReg();
        this.emit(instABC(Op.loadElem, dst, object, key));
        const skip = this.emit(instAI16(jumpOp, dst, 0));
        const value = this.compileExpr(in parser, inout runtime, n.right);
        this.emit(instAB(Op.mov, dst, value));
        this.emit(instABC(Op.storeElem, object, key, dst));
        this.patchJump(skip);
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
      if (target.kind == NodeKind.member || target.kind == NodeKind.computed) {
        const object = this.compileExpr(in parser, inout runtime, target.left);
        if (n.op == TokenKind.eq) {
          if (target.kind == NodeKind.member) {
            const atom = this.propertyNameAtom(in parser, inout runtime, target.nameStart, target.nameLength);
            const slot = this.nameSlot(atom);
            const value = this.compileExpr(in parser, inout runtime, n.right);
            this.emit(instABC(Op.storeProp, object, slot, value));
            return value;
          }
          const key = this.compileExpr(in parser, inout runtime, target.right);
          const value = this.compileExpr(in parser, inout runtime, n.right);
          this.emit(instABC(Op.storeElem, object, key, value));
          return value;
        }
        // Compound: read through the key, operate, write back.
        let key: u8 = 0;
        if (target.kind == NodeKind.member) {
          const atom = this.propertyNameAtom(in parser, inout runtime, target.nameStart, target.nameLength);
          key = this.emitKey(atom);
        } else {
          key = this.compileExpr(in parser, inout runtime, target.right);
        }
        const current = this.allocReg();
        this.emit(instABC(Op.loadElem, current, object, key));
        const right = this.compileExpr(in parser, inout runtime, n.right);
        const op = compoundOp(n.op);
        if (op == Op.halt) {
          this.hadError = true;
          return 0;
        }
        const value = this.allocReg();
        this.emit(instABC(op, value, current, right));
        this.emit(instABC(Op.storeElem, object, key, value));
        return value;
      }
    }
    if (k == NodeKind.functionExpr || k == NodeKind.arrowFunc) {
      const dst = this.allocReg();
      this.emitFunctionValue(in parser, inout runtime, node, dst);
      return dst;
    }
    if (k == NodeKind.call) {
      const callee = parser.ast.node(n.left);
      const argCount = n.childrenCount;
      if (argCount > 255 || callee.kind == NodeKind.superExpr) {
        this.hadError = true;
        return 0;
      }
      if (callee.kind == NodeKind.member || callee.kind == NodeKind.computed) {
        // Method call: callee at base, receiver at base + 1, arguments
        // above, result into base.
        const base = this.allocReg();
        this.allocReg();
        let slot: u32 = 0;
        while (slot < argCount) {
          this.allocReg();
          slot = slot + 1;
        }
        const receiver = this.compileExpr(in parser, inout runtime, callee.left);
        if (receiver != base + 1) this.emit(instAB(Op.mov, base + 1, receiver));
        this.nextReg = base + u8(2 + argCount);
        if (callee.kind == NodeKind.member) {
          const atom = this.propertyNameAtom(in parser, inout runtime, callee.nameStart, callee.nameLength);
          const nameIndex = this.nameSlot(atom);
          this.emit(instABC(Op.loadProp, base, base + 1, nameIndex));
        } else {
          const key = this.compileExpr(in parser, inout runtime, callee.right);
          this.emit(instABC(Op.loadElem, base, base + 1, key));
          this.nextReg = base + u8(2 + argCount);
        }
        let j: u32 = 0;
        while (j < argCount) {
          const argument = parser.ast.child(node, j);
          if (parser.ast.node(argument).kind == NodeKind.spread) {
            this.hadError = true;
            return 0;
          }
          const target = base + u8(2 + j);
          const argReg = this.compileExpr(in parser, inout runtime, argument);
          if (argReg != target) this.emit(instAB(Op.mov, target, argReg));
          this.nextReg = base + u8(2 + argCount);
          j = j + 1;
        }
        this.emit(instABC(Op.methodInvoke, base, base, u8(argCount)));
        this.nextReg = base + 1;
        return base;
      }
      // Callee at base, arguments contiguous above it, result into base.
      const base = this.allocReg();
      let slot: u32 = 0;
      while (slot < argCount) {
        this.allocReg();
        slot = slot + 1;
      }
      const calleeReg = this.compileExpr(in parser, inout runtime, n.left);
      if (calleeReg != base) this.emit(instAB(Op.mov, base, calleeReg));
      let j: u32 = 0;
      while (j < argCount) {
        const argument = parser.ast.child(node, j);
        if (parser.ast.node(argument).kind == NodeKind.spread) {
          this.hadError = true;
          return 0;
        }
        const target = base + u8(1 + j);
        const argReg = this.compileExpr(in parser, inout runtime, argument);
        if (argReg != target) this.emit(instAB(Op.mov, target, argReg));
        j = j + 1;
      }
      this.emit(instABC(Op.invoke, base, base, u8(argCount)));
      this.nextReg = base + 1;
      return base;
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

  // --- switch ---
  //
  // Every case test is compared first, jumping to its body on a match;
  // a final jump goes to the default body or past the switch. Bodies are
  // laid out in order so control falls through. `break` targets the
  // switch; `continue` passes it by.
  function compileSwitch(inout this, in parser: Parser, inout runtime: Runtime, node: u32): void {
    const n = parser.ast.node(node);
    this.resetCompletion();
    const discriminant = this.compileExpr(in parser, inout runtime, n.left);
    const count = n.childrenCount;
    let casePatches = Array<u32>();
    let defaultIndex: i32 = -1;
    let i: u32 = 0;
    while (i < count) {
      const clause = parser.ast.node(parser.ast.child(node, i));
      if (clause.boolValue) {
        if (defaultIndex < 0) defaultIndex = i32(i);
        casePatches.push(0);
      } else {
        const test = this.compileExpr(in parser, inout runtime, clause.left);
        const matched = this.allocReg();
        this.emit(instABC(Op.cmpStrictEq, matched, discriminant, test));
        casePatches.push(this.emit(instAI16(Op.jmpIfTrue, matched, 0)));
        this.nextReg = discriminant + 1;
      }
      i = i + 1;
    }
    this.resetTemps();
    const toDefaultOrEnd = this.emit(instI16(Op.jmp, 0));
    this.loopPush(false);
    let bodyStarts = Array<u32>();
    i = 0;
    while (i < count) {
      bodyStarts.push(u32(this.code.length));
      const clauseIndex = parser.ast.child(node, i);
      const clause = parser.ast.node(clauseIndex);
      let statement: u32 = 0;
      while (statement < clause.childrenCount) {
        this.compileStmt(in parser, inout runtime, parser.ast.child(clauseIndex, statement));
        statement = statement + 1;
      }
      i = i + 1;
    }
    const end = u32(this.code.length);
    i = 0;
    while (i < count) {
      const clause = parser.ast.node(parser.ast.child(node, i));
      if (!clause.boolValue) this.patchJumpTo(casePatches[usize(i)], bodyStarts[usize(i)]);
      i = i + 1;
    }
    this.patchJumpTo(toDefaultOrEnd, defaultIndex >= 0 ? bodyStarts[usize(defaultIndex)] : end);
    this.loopPop();
  }

  // --- for-in / for-of ---
  //
  // for-in walks an array of keys prepared up front; for-of walks an
  // array's elements by index (other iterables wait for the iterator
  // protocol). The loop's bookkeeping registers sit below the temporaries
  // watermark so statement resets leave them alone.
  function compileForEach(inout this, in parser: Parser, inout runtime: Runtime, node: u32): void {
    const n = parser.ast.node(node);
    const isKeys = n.kind == NodeKind.forInStmt;
    this.resetCompletion();
    const source = this.compileExpr(in parser, inout runtime, n.right);
    const sequence = this.allocReg();
    if (isKeys) {
      this.emit(instABC(Op.iterPrepare, sequence, source, 0));
    } else {
      this.emit(instAB(Op.mov, sequence, source));
    }
    const length = this.allocReg();
    const index = this.allocReg();
    this.emit(instAI16(Op.loadInt, index, 0));
    if (index + 1 > this.fixedRegs) this.fixedRegs = index + 1;
    // A lexical head binding is declared once, before the loop.
    const binding = parser.ast.node(n.left);
    let lexical: i32 = -1;
    if (binding.kind == NodeKind.varDecl && binding.op != TokenKind.kwVar) {
      const decl = parser.ast.node(parser.ast.child(n.left, 0));
      this.addLocal(decl.nameStart, decl.nameLength);
      lexical = i32(this.locals.length - 1);
      this.fixedRegs = this.nextReg;
    }
    const loopTop = u32(this.code.length);
    this.loopPush(true);
    this.emit(instAB(Op.arrayLength, length, sequence));
    const condition = this.allocReg();
    this.emit(instABC(Op.cmpLt, condition, index, length));
    const exit = this.emit(instAI16(Op.jmpIfFalse, condition, 0));
    const element = this.allocReg();
    this.emit(instABC(Op.loadElem, element, sequence, index));
    this.assignLoopBinding(in parser, inout runtime, n.left, lexical, element);
    this.resetTemps();
    this.compileStmt(in parser, inout runtime, parser.ast.child(node, 0));
    this.loopSetContinue(u32(this.code.length));
    const one = this.allocReg();
    this.emit(instAI16(Op.loadInt, one, 1));
    this.emit(instABC(Op.add, index, index, one));
    this.resetTemps();
    this.emitJumpBack(loopTop);
    this.patchJump(exit);
    this.loopPop();
  }

  // Store the current element into a for-in / for-of head: a declared
  // binding, an identifier, or a property.
  function assignLoopBinding(inout this, in parser: Parser, inout runtime: Runtime, target: u32, lexical: i32, value: u8): void {
    const binding = parser.ast.node(target);
    if (binding.kind == NodeKind.varDecl) {
      if (lexical >= 0) {
        this.storeLocal(usize(lexical), value);
        return;
      }
      const decl = parser.ast.node(parser.ast.child(target, 0));
      this.storeIdent(in parser, inout runtime, decl, value);
      return;
    }
    if (binding.kind == NodeKind.identExpr) {
      this.storeIdent(in parser, inout runtime, binding, value);
      return;
    }
    if (binding.kind == NodeKind.member || binding.kind == NodeKind.computed) {
      const object = this.compileExpr(in parser, inout runtime, binding.left);
      let key: u8 = 0;
      if (binding.kind == NodeKind.member) {
        const atom = this.propertyNameAtom(in parser, inout runtime, binding.nameStart, binding.nameLength);
        key = this.emitKey(atom);
      } else {
        key = this.compileExpr(in parser, inout runtime, binding.right);
      }
      this.emit(instABC(Op.storeElem, object, key, value));
      return;
    }
    this.hadError = true;
  }

  // --- try / catch / finally ---
  //
  // EnterTry records a handler for the current frame: on a throw, control
  // resumes at the catch block with the value in the catch register.
  // finally is compiled once, after both the normal and the caught paths;
  // a flag register says whether the pending value must be rethrown.
  // `return` and `break` out of a try with a finally do not yet run the
  // finally block.
  function compileTry(inout this, in parser: Parser, inout runtime: Runtime, node: u32): void {
    const n = parser.ast.node(node);
    this.resetCompletion();
    if (n.childrenCount > 0) {
      // A destructuring catch parameter.
      this.hadError = true;
      return;
    }
    const hasCatch = n.right != NO_NODE;
    const hasFinally = n.third != NO_NODE;
    let catchReg: u8 = 0;
    if (hasCatch) {
      catchReg = this.allocReg();
      if (catchReg + 1 > this.fixedRegs) this.fixedRegs = catchReg + 1;
    }
    if (!hasFinally) {
      const enter = this.emit(instAI16(Op.enterTry, catchReg, 0));
      this.compileStmt(in parser, inout runtime, n.left);
      this.emit(instA(Op.leaveTry, 0));
      const skip = this.emit(instI16(Op.jmp, 0));
      this.patchJump(enter);
      this.resetCompletion();
      this.compileCatch(in parser, inout runtime, n, catchReg);
      this.patchJump(skip);
      return;
    }
    const pendingReg = this.allocReg();
    const flagReg = this.allocReg();
    if (flagReg + 1 > this.fixedRegs) this.fixedRegs = flagReg + 1;
    this.emit(instA(Op.loadFalse, flagReg));
    const outerEnter = this.emit(instAI16(Op.enterTry, pendingReg, 0));
    if (hasCatch) {
      const innerEnter = this.emit(instAI16(Op.enterTry, catchReg, 0));
      this.compileStmt(in parser, inout runtime, n.left);
      this.emit(instA(Op.leaveTry, 0));
      const skipCatch = this.emit(instI16(Op.jmp, 0));
      this.patchJump(innerEnter);
      this.resetCompletion();
      this.compileCatch(in parser, inout runtime, n, catchReg);
      this.patchJump(skipCatch);
    } else {
      this.compileStmt(in parser, inout runtime, n.left);
    }
    this.emit(instA(Op.leaveTry, 0));
    const skipOuter = this.emit(instI16(Op.jmp, 0));
    this.patchJump(outerEnter);
    this.emit(instA(Op.loadTrue, flagReg));
    this.patchJump(skipOuter);
    // The finally block runs with the completion value set aside.
    let bodySave: i32 = -1;
    if (this.lastExprReg >= 0) {
      const saveReg = this.allocReg();
      if (saveReg + 1 > this.fixedRegs) this.fixedRegs = saveReg + 1;
      this.emit(instAB(Op.mov, saveReg, u8(this.lastExprReg)));
      this.resetCompletion();
      bodySave = i32(saveReg);
    }
    this.compileStmt(in parser, inout runtime, n.third);
    if (bodySave >= 0) this.emit(instAB(Op.mov, u8(this.lastExprReg), u8(bodySave)));
    const skipRethrow = this.emit(instAI16(Op.jmpIfFalse, flagReg, 0));
    this.emit(instA(Op.throwOp, pendingReg));
    this.patchJump(skipRethrow);
  }

  // The catch block, with its parameter bound to the catch register.
  function compileCatch(inout this, in parser: Parser, inout runtime: Runtime, n: AstNode, catchReg: u8): void {
    let bound: i32 = -1;
    if (n.nameLength > 0) bound = i32(this.bindLocal(n.nameStart, n.nameLength, catchReg));
    this.compileStmt(in parser, inout runtime, n.right);
    if (bound >= 0) this.unbindLocal(usize(bound));
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
        if (n.op == TokenKind.kwVar && this.isFunction) {
          // A var inside a function is one of its locals.
          const local = this.findLocal(in parser, decl.nameStart, decl.nameLength);
          if (local < 0) {
            this.hadError = true;
            return;
          }
          if (decl.left != NO_NODE) {
            const value = this.compileExpr(in parser, inout runtime, decl.left);
            this.storeLocal(usize(local), value);
          }
        } else if (n.op == TokenKind.kwVar) {
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
          // let / const: a lexical binding, in a register or (if a
          // nested function refers to it) in the environment.
          this.addLocal(decl.nameStart, decl.nameLength);
          const local = this.locals.length - 1;
          this.fixedRegs = this.nextReg;
          if (decl.left != NO_NODE) {
            const value = this.compileExpr(in parser, inout runtime, decl.left);
            this.storeLocal(local, value);
          } else {
            const undefinedReg = this.allocReg();
            this.emit(instA(Op.loadUndefined, undefinedReg));
            this.storeLocal(local, undefinedReg);
          }
        }
        this.resetTemps();
        i = i + 1;
      }
      return;
    }
    if (k == NodeKind.emptyStmt) return;
    if (k == NodeKind.functionDecl) {
      const r = this.allocReg();
      this.emitFunctionValue(in parser, inout runtime, node, r);
      if (this.hadError) return;
      if (this.isFunction) {
        const local = this.findLocal(in parser, n.nameStart, n.nameLength);
        if (local < 0) {
          this.hadError = true;
          return;
        }
        this.storeLocal(usize(local), r);
      } else {
        const slot = runtime.defineGlobalSlot(parser.source.copyBytes(usize(n.nameStart), usize(n.nameStart + n.nameLength)));
        this.emit(instAU16(Op.defineGlobal, r, slot));
      }
      this.resetTemps();
      return;
    }
    if (k == NodeKind.returnStmt) {
      let r: u8 = 0;
      if (n.left != NO_NODE) {
        r = this.compileExpr(in parser, inout runtime, n.left);
      } else {
        r = this.allocReg();
        this.emit(instA(Op.loadUndefined, r));
      }
      this.emit(instA(Op.returnOp, r));
      this.resetTemps();
      return;
    }
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
      this.loopPush(true);
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
      this.loopPush(true);
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
      this.loopPush(true);
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
      if (this.loopDepth == 0) {
        this.hadError = true;
        return;
      }
      let target = i32(this.loopDepth) - 1;
      if (n.nameLength > 0) target = this.findLabeledFrame(in parser, n.nameStart, n.nameLength);
      if (target < 0) {
        this.hadError = true;
        return;
      }
      const at = this.emit(instI16(Op.jmp, 0));
      this.loops[usize(target)].breakPatches.push(at);
      return;
    }
    if (k == NodeKind.continueStmt) {
      // The nearest loop, or the labeled one -- which must be a loop.
      let target: i32 = -1;
      if (n.nameLength > 0) {
        target = this.findLabeledFrame(in parser, n.nameStart, n.nameLength);
        if (target >= 0 && !this.loops[usize(target)].isIter) target = -1;
      } else {
        let walk = i32(this.loopDepth) - 1;
        while (walk >= 0 && target < 0) {
          if (this.loops[usize(walk)].isIter) target = walk;
          walk = walk - 1;
        }
      }
      if (target < 0) {
        this.hadError = true;
        return;
      }
      const frame = usize(target);
      if (this.loops[frame].haveContinue) {
        const continueTarget = this.loops[frame].continueTarget;
        this.emitJumpBack(continueTarget);
      } else {
        const at = this.emit(instI16(Op.jmp, 0));
        this.loops[frame].continuePatches.push(at);
      }
      return;
    }
    if (k == NodeKind.labeledStmt) {
      const inner = parser.ast.node(n.left);
      const ik = inner.kind;
      if (ik == NodeKind.whileStmt || ik == NodeKind.doWhileStmt || ik == NodeKind.forStmt
          || ik == NodeKind.forInStmt || ik == NodeKind.forOfStmt) {
        // The loop takes the label when it opens its frame.
        this.pendingLabelStart = n.nameStart;
        this.pendingLabelLength = n.nameLength;
        this.compileStmt(in parser, inout runtime, n.left);
        this.pendingLabelStart = 0;
        this.pendingLabelLength = 0;
        return;
      }
      this.pendingLabelStart = n.nameStart;
      this.pendingLabelLength = n.nameLength;
      this.loopPush(false);
      this.compileStmt(in parser, inout runtime, n.left);
      this.loopPop();
      return;
    }
    if (k == NodeKind.switchStmt) {
      this.compileSwitch(in parser, inout runtime, node);
      return;
    }
    if (k == NodeKind.forInStmt || k == NodeKind.forOfStmt) {
      this.compileForEach(in parser, inout runtime, node);
      return;
    }
    if (k == NodeKind.throwStmt) {
      const value = this.compileExpr(in parser, inout runtime, n.left);
      this.emit(instA(Op.throwOp, value));
      this.resetTemps();
      return;
    }
    if (k == NodeKind.tryStmt) {
      this.compileTry(in parser, inout runtime, node);
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
  return k == NodeKind.withStmt || k == NodeKind.classDecl || k == NodeKind.importDecl || k == NodeKind.exportDecl;
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

// --- Functions ------------------------------------------------------------

// Compile a function body into the runtime's function table; returns its
// index or -1. Mirrors the reference: parameters first as locals, then the
// body's own bindings, defaults evaluated at entry, function declarations
// compiled before other statements, an implicit undefined return.
function compileFunction(in parser: Parser, inout runtime: Runtime, node: u32, in enclosingScopes: Array<Scope>, in enclosingLocals: Array<Local>, enclosingHasEnv: boolean, enclosingStrict: boolean): CompiledFunction {
  const n = parser.ast.node(node);
  // The enclosing scopes, outermost first, ending with the parent's own.
  let scopes = Array<Scope>();
  let i: usize = 0;
  while (i < enclosingScopes.length) {
    let names = Array<Local>();
    let j: usize = 0;
    while (j < enclosingScopes[i].names.length) {
      names.push(enclosingScopes[i].names[j]);
      j = j + 1;
    }
    scopes.push(Scope({ names: move names, hasEnv: enclosingScopes[i].hasEnv }));
    i = i + 1;
  }
  let parentNames = Array<Local>();
  i = 0;
  while (i < enclosingLocals.length) {
    parentNames.push(enclosingLocals[i]);
    i = i + 1;
  }
  scopes.push(Scope({ names: move parentNames, hasEnv: enclosingHasEnv }));
  const scopeCount = scopes.length;
  const failed = CompiledFunction({ index: -1, minOuterScope: scopeCount });
  let compiler = Compiler({
    code: Array<Inst>(), constants: Array<Value>(), nextReg: 0, maxReg: 0, fixedRegs: 0,
    locals: Array<Local>(), outerScopes: move scopes, capturedNames: Array<Local>(),
    hasEnv: false, envSize: 0, minOuterScope: scopeCount, lastExprReg: -1, isFunction: true,
    hadError: false, strict: enclosingStrict, loops: Array<LoopFrame>(), loopDepth: 0,
    pendingLabelStart: 0, pendingLabelLength: 0, thisReg: -1, propertyNames: Array<u32>(),
  });
  if (!compiler.strict && n.left != NO_NODE && parser.bodyHasUseStrictDirective(n.left)) compiler.strict = true;

  // Parameters: plain identifiers only for now (patterns and rest need
  // objects and arrays).
  let paramCount: u32 = 0;
  let p: u32 = 0;
  while (p < n.childrenCount) {
    const param = parser.ast.node(parser.ast.child(node, p));
    if (param.kind != NodeKind.identExpr || param.nameLength == 0) return failed;
    // Parameters arrive in the first registers; a captured one is copied
    // into the environment once it exists.
    const reg = compiler.allocReg();
    compiler.locals.push(Local({ nameStart: param.nameStart, nameLength: param.nameLength, reg: reg, envSlot: -1 }));
    paramCount = paramCount + 1;
    p = p + 1;
  }
  // A named function expression binds its own name.
  const index = runtime.reserveFunction();
  let selfReg: i32 = -1;
  if (n.kind == NodeKind.functionExpr && n.nameLength > 0) {
    selfReg = i32(compiler.addLocal(n.nameStart, n.nameLength));
  }
  if (n.left != NO_NODE) compiler.collectLocals(in parser, n.left);
  if (n.left != NO_NODE && bodyUsesThis(in parser, n.left)) compiler.thisReg = i32(compiler.allocReg());
  if (n.left != NO_NODE) compiler.scanCaptures(in parser, n.left);
  compiler.fixedRegs = compiler.nextReg;

  // The environment first, then the captured parameters into it.
  if (compiler.hasEnv) {
    compiler.emit(instU16(Op.newEnv, u16(compiler.envSize)));
    p = 0;
    while (p < paramCount) {
      const slot = compiler.locals[usize(p)].envSlot;
      if (slot >= 0) compiler.emit(instABC(Op.storeEnvSlot, u8(p), 0, u8(slot)));
      p = p + 1;
    }
  }
  // A named function expression's own name is the value it was called
  // through, which carries the environment when it is a closure.
  if (selfReg >= 0) {
    const selfIndex = usize(paramCount);
    const callee = compiler.allocReg();
    compiler.emit(instA(Op.loadCallee, callee));
    compiler.storeLocal(selfIndex, callee);
    compiler.resetTemps();
  }
  // Defaults: a parameter that arrived undefined takes its initializer.
  p = 0;
  while (p < n.childrenCount) {
    const paramIndex = parser.ast.child(node, p);
    const param = parser.ast.node(paramIndex);
    if (param.right != NO_NODE) {
      const paramReg = u8(p);
      const undefinedReg = compiler.allocReg();
      compiler.emit(instA(Op.loadUndefined, undefinedReg));
      const test = compiler.allocReg();
      compiler.emit(instABC(Op.cmpStrictEq, test, paramReg, undefinedReg));
      const skip = compiler.emit(instAI16(Op.jmpIfFalse, test, 0));
      const init = compiler.compileExpr(in parser, inout runtime, param.right);
      if (init != paramReg) compiler.emit(instAB(Op.mov, paramReg, init));
      compiler.resetTemps();
      compiler.patchJump(skip);
    }
    p = p + 1;
  }

  if (n.left != NO_NODE) {
    const body = parser.ast.node(n.left);
    if (body.kind == NodeKind.blockStmt) {
      // Function declarations first, then everything else.
      let b: u32 = 0;
      while (b < body.childrenCount && !compiler.hadError) {
        const statement = parser.ast.child(n.left, b);
        if (parser.ast.node(statement).kind == NodeKind.functionDecl) compiler.compileStmt(in parser, inout runtime, statement);
        b = b + 1;
      }
      b = 0;
      while (b < body.childrenCount && !compiler.hadError) {
        const statement = parser.ast.child(n.left, b);
        if (parser.ast.node(statement).kind != NodeKind.functionDecl) compiler.compileStmt(in parser, inout runtime, statement);
        b = b + 1;
      }
    } else {
      // Concise arrow body: the expression is the return value.
      const r = compiler.compileExpr(in parser, inout runtime, n.left);
      compiler.emit(instA(Op.returnOp, r));
    }
  }
  let needReturn = true;
  if (compiler.code.length > 0 && compiler.code[compiler.code.length - 1].op == Op.returnOp) needReturn = false;
  if (needReturn) {
    const r = compiler.allocReg();
    compiler.emit(instA(Op.loadUndefined, r));
    compiler.emit(instA(Op.returnOp, r));
  }
  if (compiler.hadError) return failed;

  let compiled = createFunctionCode();
  const code: Array<Inst> = replace(inout compiler.code, Array<Inst>());
  const constants: Array<Value> = replace(inout compiler.constants, Array<Value>());
  compiled.code = move code;
  compiled.constants = move constants;
  compiled.registerCount = u32(compiler.maxReg) + 1;
  if (compiled.registerCount < paramCount) compiled.registerCount = paramCount;
  compiled.fixedRegs = u32(compiler.fixedRegs);
  compiled.paramCount = paramCount;
  let expected: u32 = 0;
  p = 0;
  while (p < n.childrenCount) {
    const param = parser.ast.node(parser.ast.child(node, p));
    if (param.right != NO_NODE) break;
    expected = expected + 1;
    p = p + 1;
  }
  compiled.expectedArgCount = expected;
  compiled.isArrow = n.kind == NodeKind.arrowFunc;
  compiled.strict = compiler.strict;
  compiled.thisReg = compiler.thisReg;
  const propertyNames: Array<u32> = replace(inout compiler.propertyNames, Array<u32>());
  compiled.propertyNames = move propertyNames;
  runtime.setFunction(index, move compiled);
  return CompiledFunction({ index: i32(index), minOuterScope: compiler.minOuterScope });
}

// --- Capture scan ---

// Whether a function nested somewhere in `node` refers to the binding
// named at `nameStart` -- unless a function on the way binds the name
// itself. `insideNested` is set once the walk has entered a nested
// function.
function capturedBy(in parser: Parser, node: u32, nameStart: u32, nameLength: u32, insideNested: boolean): boolean {
  if (node == NO_NODE) return false;
  const n = parser.ast.node(node);
  const k = n.kind;
  if (k == NodeKind.functionDecl || k == NodeKind.functionExpr || k == NodeKind.arrowFunc) {
    if (functionBinds(in parser, node, nameStart, nameLength)) return false;
    return capturedInside(in parser, node, nameStart, nameLength, true);
  }
  if (insideNested && k == NodeKind.identExpr && n.nameLength == nameLength
      && parser.slicesEqual(n.nameStart, n.nameLength, nameStart, nameLength)) {
    return true;
  }
  return capturedInside(in parser, node, nameStart, nameLength, insideNested);
}

function capturedInside(in parser: Parser, node: u32, nameStart: u32, nameLength: u32, insideNested: boolean): boolean {
  const n = parser.ast.node(node);
  if (capturedBy(in parser, n.left, nameStart, nameLength, insideNested)) return true;
  if (capturedBy(in parser, n.right, nameStart, nameLength, insideNested)) return true;
  if (capturedBy(in parser, n.third, nameStart, nameLength, insideNested)) return true;
  let i: u32 = 0;
  while (i < n.childrenCount) {
    if (capturedBy(in parser, parser.ast.child(node, i), nameStart, nameLength, insideNested)) return true;
    i = i + 1;
  }
  return false;
}

// Whether a function node binds the name itself: as a parameter, as its
// own name, or by a declaration in its body.
function functionBinds(in parser: Parser, fn: u32, nameStart: u32, nameLength: u32): boolean {
  const n = parser.ast.node(fn);
  if (n.kind == NodeKind.functionExpr && n.nameLength == nameLength
      && parser.slicesEqual(n.nameStart, n.nameLength, nameStart, nameLength)) {
    return true;
  }
  let p: u32 = 0;
  while (p < n.childrenCount) {
    const param = parser.ast.node(parser.ast.child(fn, p));
    if (param.kind == NodeKind.identExpr && param.nameLength == nameLength
        && parser.slicesEqual(param.nameStart, param.nameLength, nameStart, nameLength)) {
      return true;
    }
    p = p + 1;
  }
  return bodyBinds(in parser, n.left, nameStart, nameLength);
}

// var, let, const, and function declarations of a body, not entering
// nested functions.
function bodyBinds(in parser: Parser, node: u32, nameStart: u32, nameLength: u32): boolean {
  if (node == NO_NODE) return false;
  const n = parser.ast.node(node);
  const k = n.kind;
  if (k == NodeKind.functionExpr || k == NodeKind.arrowFunc || k == NodeKind.classExpr) return false;
  if (k == NodeKind.functionDecl) {
    return n.nameLength == nameLength && parser.slicesEqual(n.nameStart, n.nameLength, nameStart, nameLength);
  }
  if (k == NodeKind.varDecl) {
    let i: u32 = 0;
    while (i < n.childrenCount) {
      const decl = parser.ast.node(parser.ast.child(node, i));
      if (decl.nameLength == nameLength && parser.slicesEqual(decl.nameStart, decl.nameLength, nameStart, nameLength)) return true;
      i = i + 1;
    }
    return false;
  }
  if (bodyBinds(in parser, n.left, nameStart, nameLength)) return true;
  if (bodyBinds(in parser, n.right, nameStart, nameLength)) return true;
  if (bodyBinds(in parser, n.third, nameStart, nameLength)) return true;
  let i: u32 = 0;
  while (i < n.childrenCount) {
    if (bodyBinds(in parser, parser.ast.child(node, i), nameStart, nameLength)) return true;
    i = i + 1;
  }
  return false;
}

// Whether a body reads `this` outside any nested non-arrow function.
function bodyUsesThis(in parser: Parser, node: u32): boolean {
  if (node == NO_NODE) return false;
  const n = parser.ast.node(node);
  if (n.kind == NodeKind.functionDecl || n.kind == NodeKind.functionExpr) return false;
  if (n.kind == NodeKind.thisExpr) return !n.boolValue;
  if (bodyUsesThis(in parser, n.left)) return true;
  if (bodyUsesThis(in parser, n.right)) return true;
  if (bodyUsesThis(in parser, n.third)) return true;
  let i: u32 = 0;
  while (i < n.childrenCount) {
    if (bodyUsesThis(in parser, parser.ast.child(node, i))) return true;
    i = i + 1;
  }
  return false;
}

// Script-level hoisting: var and function declarations are global bindings
// that exist before the first statement runs.
function hoistProgramDecls(in parser: Parser, inout runtime: Runtime, node: u32): void {
  if (node == NO_NODE) return;
  const n = parser.ast.node(node);
  const k = n.kind;
  if (k == NodeKind.functionDecl || k == NodeKind.classDecl) {
    runtime.defineGlobalSlot(parser.source.copyBytes(usize(n.nameStart), usize(n.nameStart + n.nameLength)));
    return;
  }
  if (k == NodeKind.functionExpr || k == NodeKind.arrowFunc || k == NodeKind.classExpr) return;
  if (k == NodeKind.varDecl) {
    if (n.op != TokenKind.kwVar) return;
    let j: u32 = 0;
    while (j < n.childrenCount) {
      const decl = parser.ast.node(parser.ast.child(node, j));
      if (decl.nameLength > 0) runtime.defineGlobalSlot(parser.source.copyBytes(usize(decl.nameStart), usize(decl.nameStart + decl.nameLength)));
      j = j + 1;
    }
    return;
  }
  if (n.left != NO_NODE) hoistProgramDecls(in parser, inout runtime, n.left);
  if (n.right != NO_NODE) hoistProgramDecls(in parser, inout runtime, n.right);
  if (n.third != NO_NODE) hoistProgramDecls(in parser, inout runtime, n.third);
  let i: u32 = 0;
  while (i < n.childrenCount) {
    hoistProgramDecls(in parser, inout runtime, parser.ast.child(node, i));
    i = i + 1;
  }
}

// --- Entry ----------------------------------------------------------------

// Compiles a parsed program into the runtime's function table; returns the
// function index, or -1 on error.
export function compileProgram(in parser: Parser, root: u32, inout runtime: Runtime): i32 {
  let compiler = Compiler({
    code: Array<Inst>(), constants: Array<Value>(), nextReg: 0, maxReg: 0, fixedRegs: 0,
    locals: Array<Local>(), outerScopes: Array<Scope>(), capturedNames: Array<Local>(),
    hasEnv: false, envSize: 0, minOuterScope: 0, lastExprReg: -1, isFunction: false,
    hadError: false, strict: parser.strictMode, loops: Array<LoopFrame>(), loopDepth: 0,
    pendingLabelStart: 0, pendingLabelLength: 0, thisReg: -1, propertyNames: Array<u32>(),
  });
  const resultReg = compiler.allocReg();
  compiler.emit(instA(Op.loadUndefined, resultReg));
  compiler.fixedRegs = resultReg + 1;
  compiler.lastExprReg = i32(resultReg);

  const program = parser.ast.node(root);
  hoistProgramDecls(in parser, inout runtime, root);
  // Top-level let / const that functions refer to live in an environment;
  // var and function declarations are globals and need none.
  compiler.scanCaptures(in parser, root);
  if (compiler.hasEnv) compiler.emit(instU16(Op.newEnv, u16(compiler.envSize)));
  // Function declarations first, then everything else.
  let i: u32 = 0;
  while (i < program.childrenCount && !compiler.hadError) {
    const statement = parser.ast.child(root, i);
    if (parser.ast.node(statement).kind == NodeKind.functionDecl) compiler.compileStmt(in parser, inout runtime, statement);
    i = i + 1;
  }
  i = 0;
  while (i < program.childrenCount && !compiler.hadError) {
    const statement = parser.ast.child(root, i);
    if (parser.ast.node(statement).kind != NodeKind.functionDecl) compiler.compileStmt(in parser, inout runtime, statement);
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
  const propertyNames: Array<u32> = replace(inout compiler.propertyNames, Array<u32>());
  compiled.propertyNames = move propertyNames;
  return i32(runtime.addFunction(move compiled));
}
