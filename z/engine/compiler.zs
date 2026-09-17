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

import { wtf8Length, pushCodePoint, unitsToUtf8 } from "./text.zs";
import { expect } from "std/test";
import { Value, int32Value, doubleValue, isInt32, asInt32 } from "./value.zs";
import { TokenKind } from "./token.zs";
import { NodeKind, AstNode, NO_NODE } from "./ast.zs";
import { Parser, ParseResult, parseProgram } from "./parser.zs";
import { Op, Inst, FunctionCode, createFunctionCode, instA, instAB, instABC, instAU16, instAI16, instI16, instU16 } from "./bytecode.zs";
import { Runtime } from "./runtime.zs";
import { bytesOf, sliceBytes } from "./heap.zs";
import { cellValue, deletedValue } from "./value.zs";
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
  // The region depth when the frame was pushed (what a break unwinds to)
  // and after the loop's own iterator region (what a continue unwinds to).
  regionsAtEntry: usize;
  continueRegions: usize;
  // Environments open when the frame was pushed: what a jump to it
  // leaves the frame's environment at.
  openEnvs: u32;
}

// Something control must undo on its way out: a try handler to pop, a
// finally block to run, a for-of iterator to close.
const REGION_TRY: u32 = 0;
const REGION_FINALLY: u32 = 1;
const REGION_ITERATOR: u32 = 2;

struct Region {
  kind: u32;
  finallyNode: u32;
  iterReg: u8;
  doneReg: u8;
  // The scope the region was opened in: a finally block inlined on the
  // way out runs with this many environments open and only the bindings
  // declared by then visible.
  openEnvs: u32;
  localsLength: usize;
}

// A lexical binding captured from inside a block, loop head, switch, or
// catch clause: the capture scan records it under this slot, and it
// takes a real slot in that scope's environment when the scope opens.
const BLOCK_SLOT: i32 = -2;

// A binding of the function being compiled. It lives in a register, or --
// when a nested function refers to it -- in a slot of the function's
// environment cell, so the nested function can outlive the frame.
struct Local {
  nameStart: u32;
  nameLength: u32;
  reg: u8;
  envSlot: i32;
  // For a captured binding, how many nested environments (per-iteration
  // or block) sit between the function's environment and the one
  // holding it (zero: the function's own).
  envDepth: u32;
  // Lives in an environment; a block-level one takes its slot when its
  // scope opens.
  captured: boolean;
  isConst: boolean;
  // Known to be initialized at the current point of this function. A
  // lexical binding read before that must check for the hole.
  initialized: boolean;
  // Reads always check: a switch body can be entered past the declaration.
  alwaysCheck: boolean;
  // The scope stores a hole at entry, because something can read the
  // binding before its declaration runs.
  needsHole: boolean;
  // The name as a constant, for the hole check's message; -1 when no
  // check can apply.
  nameConst: i32;
  // A function declaration inside a block: the block's binding, created
  // when the block opens.
  blockFunction: boolean;
  // Declared by let, const, class, or a block's function declaration (as
  // opposed to var, a parameter, or a catch parameter).
  lexical: boolean;
}

// What a scope records when it opens, to close it again.
struct ScopeMark {
  locals: usize;
  fixedRegs: u8;
  envReg: u8;
  hasEnv: boolean;
}

// An enclosing function's bindings, as seen from a nested one: the
// captured ones are reachable through the environment chain.
struct Scope {
  names: Array<Local>;
  hasEnv: boolean;
  // Nested environments open in that function where the nested function
  // was created: each is one more hop to its bindings.
  openEnvs: u32;
  // An arrow function, which has no `this` of its own.
  isArrow: boolean;
  // A derived constructor's environment slot holding `this` for the
  // arrows inside it; -1 when it has none.
  thisSlot: i32;
}

// Where an identifier resolved outside the current function.
struct OuterRef {
  found: boolean;
  hops: u8;
  slot: i32;
  scopeIndex: usize;
  // The binding may still be a hole where the function was created.
  needsCheck: boolean;
  isConst: boolean;
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
  // Nested environments currently open -- per-iteration ones for loops
  // whose lexical head bindings are captured, block ones for scopes with
  // captured bindings -- and the register tracking each, innermost last.
  // Every environment access counts them.
  openEnvs: u32;
  envRegs: Array<u8>;
  // Binding a declaration's pattern: its targets initialize their
  // bindings rather than assign to them.
  initializing: boolean;
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
  // Open loops, innermost last.
  loops: Array<LoopFrame>;
  // A label waiting for the loop statement it names.
  pendingLabelStart: u32;
  pendingLabelLength: u32;
  // Open regions, innermost last; `regionDepth` is the live extent.
  regions: Array<Region>;
  regionDepth: usize;
  // The name an anonymous function defined by the next expression takes:
  // the binding, property, or parameter it initializes. Consumed by the
  // expression, passed through parentheses, dropped by anything else.
  pendingNameStart: u32;
  pendingNameLength: u32;
  pendingNamePrefix: u32;
  // The register holding `this` in a function that reads it, or -1.
  thisReg: i32;
  // An arrow function; a derived class constructor. A derived
  // constructor's `this` is uninitialized until super() returns, so its
  // reads are checked; with arrows reading it, it also lives in an
  // environment slot the arrows read (the current value, not the one at
  // their creation).
  isArrow: boolean;
  derivedCtor: boolean;
  thisEnvSlot: i32;
  // A class constructor's instance field statements (the first `fieldCount`
  // statements of its body, injected by the parser), compiled with define
  // semantics: inline at the top of a base constructor, after each super()
  // in a derived one.
  fieldSource: u32;
  fieldCount: u32;
  // Compiling an async function's body: `await` suspends like yield.
  isAsyncBody: boolean;
  // Compiling an async generator's body: `yield*` delegates asynchronously.
  isAsyncGeneratorBody: boolean;
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

  // Operands are a byte; a function that needs more registers than fit
  // fails to compile rather than wrapping (the counter stops short of
  // the top so the fixed-width call layouts below never overflow it).
  function allocReg(inout this): u8 {
    if (this.nextReg >= 252) {
      this.hadError = true;
      this.nextReg = 252;
      return 252;
    }
    const reg = this.nextReg;
    this.nextReg = reg + 1;
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
      regionsAtEntry: this.regionDepth, continueRegions: this.regionDepth,
      openEnvs: this.openEnvs,
    });
    this.pendingLabelStart = 0;
    this.pendingLabelLength = 0;
    this.loops.push(frame);
  }

  function loopSetContinue(inout this, target: u32): void {
    const top = this.loops.length - 1;
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

  // --- Regions ---

  function pushRegion(inout this, kind: u32, finallyNode: u32, iterReg: u8, doneReg: u8): void {
    const region = Region({ kind: kind, finallyNode: finallyNode, iterReg: iterReg, doneReg: doneReg, openEnvs: this.openEnvs, localsLength: this.locals.length });
    if (this.regionDepth < this.regions.length) {
      this.regions[this.regionDepth] = region;
    } else {
      this.regions.push(region);
    }
    this.regionDepth = this.regionDepth + 1;
  }

  function popRegion(inout this): void {
    this.regionDepth = this.regionDepth - 1;
  }

  // Open a try handler as a region.
  function emitEnterTry(inout this, catchReg: u8): u32 {
    this.pushRegion(REGION_TRY, NO_NODE, 0, 0);
    return this.emit(instAI16(Op.enterTry, catchReg, 0));
  }

  function emitLeaveTry(inout this): void {
    this.popRegion();
    this.emit(instA(Op.leaveTry, 0));
  }

  // Undo every region above `depth` before control jumps out of them,
  // innermost first: pop a handler, run a finally block inline, close an
  // iterator. A finally block runs with the regions above it already
  // gone, so its own jumps unwind from there. The regions stay recorded:
  // the code after the jump is still inside them.
  function emitUnwind(inout this, in parser: Parser, inout runtime: Runtime, depth: usize): void {
    const saved = this.regionDepth;
    let index = this.regionDepth;
    while (index > depth) {
      index = index - 1;
      const kind = this.regions[index].kind;
      if (kind == REGION_TRY) {
        this.emit(instA(Op.leaveTry, 0));
      } else if (kind == REGION_FINALLY) {
        this.emit(instA(Op.leaveTry, 0));
        const finallyNode = this.regions[index].finallyNode;
        // The block runs in the try statement's own scope: with its
        // environment, and with the bindings declared since hidden.
        const savedEnvs = this.openEnvs;
        const regionEnvs = this.regions[index].openEnvs;
        if (this.openEnvs > regionEnvs) {
          const envReg = this.envRegs[usize(regionEnvs)];
          this.emit(instA(Op.exitEnv, envReg));
        }
        let hiddenRegs = Array<u8>();
        while (this.envRegs.length > usize(regionEnvs)) {
          match (this.envRegs.pop()) {
            some(envReg) => {
              hiddenRegs.push(envReg);
            }
            none => {
            }
          }
        }
        this.openEnvs = regionEnvs;
        let hidden = Array<Local>();
        const keep = this.regions[index].localsLength;
        while (this.locals.length > keep) {
          match (this.locals.pop()) {
            some(local) => {
              hidden.push(local);
            }
            none => {
            }
          }
        }
        this.regionDepth = index;
        this.compileStmt(in parser, inout runtime, finallyNode);
        while (hidden.length > 0) {
          match (hidden.pop()) {
            some(local) => {
              this.locals.push(local);
            }
            none => {
            }
          }
        }
        while (hiddenRegs.length > 0) {
          match (hiddenRegs.pop()) {
            some(envReg) => {
              this.envRegs.push(envReg);
            }
            none => {
            }
          }
        }
        this.openEnvs = savedEnvs;
      } else {
        const iterReg = this.regions[index].iterReg;
        const doneReg = this.regions[index].doneReg;
        this.emit(instAB(Op.iterClose, iterReg, doneReg));
      }
    }
    this.regionDepth = saved;
  }

  // The open frame carrying `label`, or -1.
  function findLabeledFrame(in parser: Parser, nameStart: u32, nameLength: u32): i32 {
    let index = this.loops.length;
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
    const top = this.loops.length - 1;
    let i: usize = 0;
    const count = this.loops[top].breakPatches.length;
    while (i < count) {
      const bound1 = this.loops[top].breakPatches[i];
      this.patchJump(bound1);
      i = i + 1;
    }
    const dropped = this.loops.pop();
  }

  // --- Scopes ---
  //
  // A block, a switch body, a loop head, or a catch clause declares its
  // let / const / class bindings when it opens, ahead of its statements,
  // and drops them when it closes, so an inner declaration shadows an
  // outer one only inside. Bindings that nested functions capture live
  // in an environment created at each entry (a closure made in one entry
  // keeps that entry's values); the function's own environment holds
  // only its body-level bindings. Every environment access counts the
  // nested environments open between here and the function's own.
  //
  // A lexical binding starts out as a hole when something can read it
  // before its declaration runs -- a reference earlier in its scope, or
  // one inside a hoisted function declaration -- and such reads check
  // for the hole and throw a ReferenceError. A read the compiler can
  // see follows the declaration, in this function or in a closure made
  // after it, pays nothing.

  // A scope's lexical names against each other and against the names
  // var-declared in it.
  function checkRedeclarations(inout this, in parser: Parser, in lexical: Array<NameRef>, in vars: Array<NameRef>): void {
    let i: usize = 0;
    while (i < lexical.length) {
      let j: usize = 0;
      while (j < i) {
        if (lexical[i].length == lexical[j].length && parser.slicesEqual(lexical[i].start, lexical[i].length, lexical[j].start, lexical[j].length)) {
          if (this.strict || !lexical[i].plainFunction || !lexical[j].plainFunction) this.hadError = true;
        }
        j = j + 1;
      }
      let v: usize = 0;
      while (v < vars.length) {
        if (lexical[i].length == vars[v].length && parser.slicesEqual(lexical[i].start, lexical[i].length, vars[v].start, vars[v].length)) this.hadError = true;
        v = v + 1;
      }
      i = i + 1;
    }
  }

  // A block or switch body: its let / const / class / function names
  // against the vars declared inside it.
  function checkBlockRedeclarations(inout this, in parser: Parser, block: u32, in statements: Array<u32>): void {
    let lexical = Array<NameRef>();
    let i: usize = 0;
    while (i < statements.length) {
      pushLexicalNames(in parser, statements[i], true, inout lexical);
      i = i + 1;
    }
    if (lexical.length == 0) return;
    let vars = Array<NameRef>();
    collectVarNames(in parser, block, inout vars);
    this.checkRedeclarations(in parser, in lexical, in vars);
  }

  // A function body or script: its let / const / class names against the
  // parameters, the body-level function declarations, and every var.
  function checkBodyRedeclarations(inout this, in parser: Parser, fn: u32, body: u32): void {
    const n = parser.ast.node(body);
    let lexical = Array<NameRef>();
    let vars = Array<NameRef>();
    let i: u32 = 0;
    while (i < n.childrenCount) {
      const statement = parser.ast.child(body, i);
      pushLexicalNames(in parser, statement, false, inout lexical);
      const st = parser.ast.node(statement);
      if (st.kind == NodeKind.functionDecl && st.nameLength > 0) pushName(inout vars, st.nameStart, st.nameLength, false);
      i = i + 1;
    }
    if (lexical.length == 0) return;
    if (fn != NO_NODE) collectParameterNames(in parser, fn, inout vars);
    collectVarNames(in parser, body, inout vars);
    this.checkRedeclarations(in parser, in lexical, in vars);
  }

  // A loop head's lexical names against each other and the loop's vars.
  function checkHeadRedeclarations(inout this, in parser: Parser, loop: u32, head: u32): void {
    let lexical = Array<NameRef>();
    pushLexicalNames(in parser, head, false, inout lexical);
    let vars = Array<NameRef>();
    collectVarNames(in parser, loop, inout vars);
    this.checkRedeclarations(in parser, in lexical, in vars);
  }

  // A parameter that binds in order starts as a hole.
  function markOrderedParameter(inout this, in parser: Parser, inout runtime: Runtime, index: usize): void {
    this.locals[index].initialized = false;
    this.locals[index].needsHole = true;
    const start = this.locals[index].nameStart;
    const length = this.locals[index].nameLength;
    const named = this.nameConstOf(in parser, inout runtime, start, length);
    this.locals[index].nameConst = i32(named);
  }

  function openScope(): ScopeMark {
    return ScopeMark({ locals: this.locals.length, fixedRegs: this.fixedRegs, envReg: 0, hasEnv: false });
  }

  // Declare one lexical binding of the scope being opened. `key` is the
  // position the capture scan recorded it under; `limit` the end of its
  // declaration; `scope` the node a reference before that would sit in.
  function declareLexical(inout this, in parser: Parser, inout runtime: Runtime, nameStart: u32, nameLength: u32, key: u32, isConst: boolean, alwaysCheck: boolean, extent: u32, limit: u32): void {
    const unusedReg = this.addLocalKeyed(nameStart, nameLength, key);
    const index = this.locals.length - 1;
    this.locals[index].lexical = true;
    this.locals[index].isConst = isConst;
    this.locals[index].initialized = false;
    this.locals[index].alwaysCheck = alwaysCheck;
    const needsHole = alwaysCheck || nameReferencedBefore(in parser, extent, nameStart, nameLength, limit, false);
    this.locals[index].needsHole = needsHole;
    if (needsHole) {
      const named = this.nameConstOf(in parser, inout runtime, nameStart, nameLength);
      this.locals[index].nameConst = i32(named);
    }
  }

  function declarePatternLexicals(inout this, in parser: Parser, inout runtime: Runtime, pattern: u32, isConst: boolean, alwaysCheck: boolean, extent: u32, limit: u32): void {
    if (pattern == NO_NODE) return;
    const n = parser.ast.node(pattern);
    if (n.kind == NodeKind.identExpr) {
      if (n.nameLength > 0) this.declareLexical(in parser, inout runtime, n.nameStart, n.nameLength, n.nameStart, isConst, alwaysCheck, extent, limit);
      return;
    }
    if (n.kind == NodeKind.patternEntry) {
      this.declarePatternLexicals(in parser, inout runtime, n.left, isConst, alwaysCheck, extent, limit);
      return;
    }
    if (n.kind == NodeKind.arrayPattern || n.kind == NodeKind.objectPattern) {
      let i: u32 = 0;
      while (i < n.childrenCount) {
        this.declarePatternLexicals(in parser, inout runtime, parser.ast.child(pattern, i), isConst, alwaysCheck, extent, limit);
        i = i + 1;
      }
    }
  }

  // The lexical declarations directly in one statement of a scope. A
  // script's top-level classes are globals, not lexical bindings.
  function declareStatementLexicals(inout this, in parser: Parser, inout runtime: Runtime, statement: u32, alwaysCheck: boolean, extent: u32, skipClasses: boolean, inBlock: boolean): void {
    const st = parser.ast.node(statement);
    if (st.kind == NodeKind.functionDecl && inBlock && st.nameLength > 0) {
      // Initialized when the block opens, before anything can read it:
      // no hole, no check.
      this.declareLexical(in parser, inout runtime, st.nameStart, st.nameLength, st.nameStart, false, false, extent, st.end);
      const index = this.locals.length - 1;
      this.locals[index].needsHole = false;
      this.locals[index].nameConst = -1;
      this.locals[index].blockFunction = true;
      return;
    }
    if (st.kind == NodeKind.varDecl && st.op != TokenKind.kwVar) {
      const isConst = st.op == TokenKind.kwConst;
      let d: u32 = 0;
      while (d < st.childrenCount) {
        const decl = parser.ast.node(parser.ast.child(statement, d));
        if (decl.nameLength > 0) {
          this.declareLexical(in parser, inout runtime, decl.nameStart, decl.nameLength, decl.nameStart, isConst, alwaysCheck, extent, decl.end);
        } else if (decl.third != NO_NODE) {
          this.declarePatternLexicals(in parser, inout runtime, decl.third, isConst, alwaysCheck, extent, decl.end);
        }
        d = d + 1;
      }
      return;
    }
    if (st.kind == NodeKind.classDecl && !skipClasses && st.nameLength > 0) {
      this.declareLexical(in parser, inout runtime, st.nameStart, st.nameLength, st.nameStart, false, alwaysCheck, extent, st.end);
    }
  }

  function declareBlockLexicals(inout this, in parser: Parser, inout runtime: Runtime, block: u32, alwaysCheck: boolean, skipClasses: boolean, inBlock: boolean): void {
    const n = parser.ast.node(block);
    let i: u32 = 0;
    while (i < n.childrenCount) {
      this.declareStatementLexicals(in parser, inout runtime, parser.ast.child(block, i), alwaysCheck, block, skipClasses, inBlock);
      i = i + 1;
    }
  }

  // Create a block's function declarations as it opens, so they are
  // callable before their statements (hoisted within the block).
  function hoistBlockFunctions(inout this, in parser: Parser, inout runtime: Runtime, in statements: Array<u32>): void {
    let i: usize = 0;
    while (i < statements.length) {
      const statement = statements[i];
      const st = parser.ast.node(statement);
      if (st.kind == NodeKind.functionDecl && st.nameLength > 0) {
        const local = this.findLocal(in parser, st.nameStart, st.nameLength);
        if (local >= 0 && this.locals[usize(local)].blockFunction) {
          const r = this.allocReg();
          this.emitFunctionValue(in parser, inout runtime, statement, r, 0, 0, 0);
          if (this.hadError) return;
          this.initLocal(usize(local), r);
          this.resetTemps();
        }
      }
      i = i + 1;
    }
  }

  // The function-scoped binding of a name (a var, parameter, or
  // body-level function), the oldest such local, or -1.
  function findVarLocal(in parser: Parser, nameStart: u32, nameLength: u32): i32 {
    let index: usize = 0;
    while (index < this.locals.length) {
      const local = this.locals[index];
      if (!local.lexical && local.nameLength == nameLength && this.nameMatches(in parser, local.nameStart, local.nameLength, nameStart, nameLength)) return i32(index);
      index = index + 1;
    }
    return -1;
  }

  // Whether a lexical binding of the name other than `except` is in
  // scope: then a var of that name would be an early error, and sloppy
  // code makes no var for a block's function declaration (Annex B).
  function hasLexicalConflict(in parser: Parser, nameStart: u32, nameLength: u32, except: usize): boolean {
    let index: usize = 0;
    while (index < this.locals.length) {
      const local = this.locals[index];
      if (index != except && local.lexical && local.nameLength == nameLength && this.nameMatches(in parser, local.nameStart, local.nameLength, nameStart, nameLength)) return true;
      index = index + 1;
    }
    return false;
  }

  // Whether a block declares anything lexical, so a scope is worth opening.
  function hasLexicalDeclarations(in parser: Parser, block: u32): boolean {
    const n = parser.ast.node(block);
    let i: u32 = 0;
    while (i < n.childrenCount) {
      const st = parser.ast.node(parser.ast.child(block, i));
      if (st.kind == NodeKind.varDecl && st.op != TokenKind.kwVar) return true;
      if (st.kind == NodeKind.classDecl) return true;
      if (st.kind == NodeKind.functionDecl) return true;
      i = i + 1;
    }
    return false;
  }

  // Open the scope's environment, when any of its bindings are captured,
  // then store the holes.
  function enterScope(inout this, inout mark: ScopeMark): void {
    let count: usize = 0;
    let i = mark.locals;
    while (i < this.locals.length) {
      if (this.locals[i].captured) {
        this.locals[i].envSlot = i32(count);
        count = count + 1;
      }
      i = i + 1;
    }
    if (count > 0) {
      const reg = this.allocReg();
      this.emit(instU16(Op.newEnv, u16(count)));
      this.emit(instA(Op.envToReg, reg));
      this.envRegs.push(reg);
      this.openEnvs = this.openEnvs + 1;
      const depth = this.openEnvs;
      i = mark.locals;
      while (i < this.locals.length) {
        if (this.locals[i].captured) this.locals[i].envDepth = depth;
        i = i + 1;
      }
      mark.hasEnv = true;
      mark.envReg = reg;
    }
    this.fixedRegs = this.nextReg;
    this.emitHoles(mark.locals);
  }

  // Store the hole into every binding declared since `since` that can
  // be read before its declaration runs.
  function emitHoles(inout this, since: usize): void {
    let holeReg: i32 = -1;
    let i = since;
    while (i < this.locals.length) {
      if (this.locals[i].needsHole) {
        const slot = this.locals[i].envSlot;
        if (slot >= 0) {
          if (holeReg < 0) {
            holeReg = i32(this.allocReg());
            this.emit(instA(Op.loadHole, u8(holeReg)));
          }
          const hops = u8(this.openEnvs - this.locals[i].envDepth);
          this.emit(instABC(Op.storeEnvSlot, u8(holeReg), hops, u8(slot)));
        } else {
          const reg = this.locals[i].reg;
          this.emit(instA(Op.loadHole, reg));
        }
      }
      i = i + 1;
    }
    this.resetTemps();
  }

  // Close the scope: leave its environment, drop its bindings, release
  // their registers.
  function closeScope(inout this, in mark: ScopeMark): void {
    if (mark.hasEnv) {
      this.emit(instA(Op.exitEnv, mark.envReg));
      this.openEnvs = this.openEnvs - 1;
      const droppedReg = this.envRegs.pop();
    }
    while (this.locals.length > mark.locals) {
      const dropped = this.locals.pop();
    }
    this.fixedRegs = mark.fixedRegs;
    this.nextReg = mark.fixedRegs;
  }

  // Before a jump to a frame that had `target` environments open: back
  // to that environment (the parent of the first one opened since).
  function emitLeaveEnvs(inout this, target: u32): void {
    if (this.openEnvs <= target) return;
    const envReg = this.envRegs[usize(target)];
    this.emit(instA(Op.exitEnv, envReg));
  }

  // The body-level lexical bindings of a function or script: in the
  // function's own environment (the capture scan gave them slots) or in
  // registers, declared ahead of everything else in the body.
  function declareBodyLexicals(inout this, in parser: Parser, inout runtime: Runtime, body: u32, skipClasses: boolean): void {
    const since = this.locals.length;
    this.declareBlockLexicals(in parser, inout runtime, body, false, skipClasses, false);
    this.fixedRegs = this.nextReg;
    this.emitHoles(since);
  }

  // A binding's name as a constant, for a hole check's message.
  function nameConstOf(inout this, in parser: Parser, inout runtime: Runtime, nameStart: u32, nameLength: u32): u16 {
    return this.addConst(runtime.internUtf8Value(sliceBytes(in parser.source, usize(nameStart), usize(nameStart + nameLength))));
  }

  // --- Per-iteration environments ---
  //
  // A loop whose lexical head bindings are captured by a closure gives
  // each iteration its own environment holding those bindings, so a
  // closure made in one iteration keeps that iteration's values.

  // The locals of a lexical loop head that live in the environment.
  function headCaptures(inout this, in parser: Parser, head: u32): Array<usize> {
    let found = Array<usize>();
    if (head == NO_NODE) return found;
    const binding = parser.ast.node(head);
    if (binding.kind != NodeKind.varDecl || binding.op == TokenKind.kwVar) return found;
    let d: u32 = 0;
    while (d < binding.childrenCount) {
      const decl = parser.ast.node(parser.ast.child(head, d));
      if (decl.nameLength > 0) {
        this.pushCapturedLocal(in parser, decl.nameStart, decl.nameLength, inout found);
      } else if (decl.third != NO_NODE) {
        this.pushPatternCaptures(in parser, decl.third, inout found);
      }
      d = d + 1;
    }
    return found;
  }

  function pushCapturedLocal(inout this, in parser: Parser, nameStart: u32, nameLength: u32, inout found: Array<usize>): void {
    const index = this.findLocal(in parser, nameStart, nameLength);
    if (index < 0) return;
    if (this.locals[usize(index)].captured) found.push(usize(index));
  }

  function pushPatternCaptures(inout this, in parser: Parser, pattern: u32, inout found: Array<usize>): void {
    if (pattern == NO_NODE) return;
    const n = parser.ast.node(pattern);
    if (n.kind == NodeKind.identExpr) {
      if (n.nameLength > 0) this.pushCapturedLocal(in parser, n.nameStart, n.nameLength, inout found);
      return;
    }
    if (n.kind == NodeKind.patternEntry) {
      this.pushPatternCaptures(in parser, n.left, inout found);
      return;
    }
    if (n.kind == NodeKind.arrayPattern || n.kind == NodeKind.objectPattern) {
      let i: u32 = 0;
      while (i < n.childrenCount) {
        this.pushPatternCaptures(in parser, parser.ast.child(pattern, i), inout found);
        i = i + 1;
      }
    }
  }

  // Declare a for head's let / const bindings ahead of their
  // initializers. `scope` is where a read before the declaration could
  // sit: the head itself, or the sequence a for-in / for-of walks.
  function declareLexicalHead(inout this, in parser: Parser, inout runtime: Runtime, head: u32, extent: u32, limit: u32): void {
    const binding = parser.ast.node(head);
    const isConst = binding.op == TokenKind.kwConst;
    let d: u32 = 0;
    while (d < binding.childrenCount) {
      const decl = parser.ast.node(parser.ast.child(head, d));
      const end = limit == 0 ? decl.end : limit;
      if (decl.nameLength > 0) {
        this.declareLexical(in parser, inout runtime, decl.nameStart, decl.nameLength, decl.nameStart, isConst, false, extent, end);
      } else {
        this.declarePatternLexicals(in parser, inout runtime, decl.third, isConst, false, extent, end);
      }
      d = d + 1;
    }
    this.fixedRegs = this.nextReg;
  }

  function initializeLexicalHead(inout this, in parser: Parser, inout runtime: Runtime, head: u32): void {
    const binding = parser.ast.node(head);
    let d: u32 = 0;
    while (d < binding.childrenCount) {
      const decl = parser.ast.node(parser.ast.child(head, d));
      if (decl.nameLength > 0) {
        const local = this.findLocal(in parser, decl.nameStart, decl.nameLength);
        if (local < 0) {
          this.hadError = true;
          return;
        }
        if (decl.left != NO_NODE) {
          this.nameNext(decl.nameStart, decl.nameLength, 0);
          const value = this.compileExpr(in parser, inout runtime, decl.left);
          this.initLocal(usize(local), value);
        } else {
          const undefinedReg = this.allocReg();
          this.emit(instA(Op.loadUndefined, undefinedReg));
          this.initLocal(usize(local), undefinedReg);
        }
      } else {
        if (decl.third == NO_NODE || decl.left == NO_NODE) {
          this.hadError = true;
          return;
        }
        const value = this.compileExpr(in parser, inout runtime, decl.left);
        const wasInitializing = this.initializing;
        this.initializing = true;
        this.destructure(in parser, inout runtime, decl.third, value);
        this.initializing = wasInitializing;
      }
      this.resetTemps();
      d = d + 1;
    }
  }

  // Open a per-iteration environment for these locals: the register
  // that tracks it, with the locals' former homes recorded in `saved`.
  function enterIterationEnv(inout this, in captures: Array<usize>, inout saved: Array<i32>): u8 {
    const iterReg = this.allocReg();
    if (iterReg + 1 > this.fixedRegs) this.fixedRegs = iterReg + 1;
    this.emit(instU16(Op.newEnv, u16(captures.length)));
    this.emit(instA(Op.envToReg, iterReg));
    this.envRegs.push(iterReg);
    this.openEnvs = this.openEnvs + 1;
    let i: usize = 0;
    while (i < captures.length) {
      const index = captures[i];
      saved.push(this.locals[index].envSlot);
      saved.push(i32(this.locals[index].envDepth));
      this.locals[index].envSlot = i32(i);
      this.locals[index].envDepth = this.openEnvs;
      i = i + 1;
    }
    return iterReg;
  }

  function renewIterationEnv(inout this, iterReg: u8, count: usize): void {
    this.emit(instAU16(Op.renewEnv, iterReg, u16(count)));
  }

  function leaveIterationEnv(inout this, iterReg: u8, in captures: Array<usize>, in saved: Array<i32>): void {
    this.emit(instA(Op.exitEnv, iterReg));
    this.openEnvs = this.openEnvs - 1;
    const droppedReg = this.envRegs.pop();
    let i: usize = 0;
    while (i < captures.length) {
      const index = captures[i];
      this.locals[index].envSlot = saved[i * 2];
      this.locals[index].envDepth = u32(saved[i * 2 + 1]);
      i = i + 1;
    }
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
    return this.addLocalKeyed(nameStart, nameLength, nameStart);
  }

  // `key` is the position the capture scan recorded the binding under.
  // A block-level captured binding takes its slot when its scope opens.
  function addLocalKeyed(inout this, nameStart: u32, nameLength: u32, key: u32): u8 {
    let envSlot = this.capturedSlot(key);
    const captured = envSlot != -1;
    if (envSlot == BLOCK_SLOT) envSlot = -1;
    let reg: u8 = 0;
    if (!captured) reg = this.allocReg();
    this.locals.push(Local({ nameStart: nameStart, nameLength: nameLength, reg: reg, envSlot: envSlot, envDepth: 0, captured: captured, isConst: false, initialized: true, alwaysCheck: false, needsHole: false, nameConst: -1, blockFunction: false, lexical: false }));
    return reg;
  }

  // Whether a read of the binding here must check for the hole.
  function mustCheck(index: usize): boolean {
    const local = this.locals[index];
    return local.nameConst >= 0 && (local.alwaysCheck || !local.initialized);
  }

  // Load a binding of this function into a register.
  function loadLocal(inout this, index: usize, dst: u8): void {
    const slot = this.locals[index].envSlot;
    if (slot >= 0) {
      const hops = u8(this.openEnvs - this.locals[index].envDepth);
      this.emit(instABC(Op.loadEnvSlot, dst, hops, u8(slot)));
    } else {
      const reg = this.locals[index].reg;
      this.emit(instAB(Op.mov, dst, reg));
    }
    if (this.mustCheck(index)) {
      const named = u16(this.locals[index].nameConst);
      this.emit(instAU16(Op.throwIfHole, dst, named));
    }
  }

  // Assign a register to a binding of this function: checked for the
  // hole and for a constant. A declaration's own store is `initLocal`.
  function storeLocal(inout this, index: usize, value: u8): void {
    if (this.mustCheck(index)) {
      const current = this.allocReg();
      this.loadLocal(index, current);
    }
    if (this.locals[index].isConst) {
      this.emit(instA(Op.throwConstAssign, 0));
      return;
    }
    this.initLocal(index, value);
  }

  // Store a register into a binding, initializing it.
  function initLocal(inout this, index: usize, value: u8): void {
    const slot = this.locals[index].envSlot;
    if (slot >= 0) {
      const hops = u8(this.openEnvs - this.locals[index].envDepth);
      this.emit(instABC(Op.storeEnvSlot, value, hops, u8(slot)));
    } else {
      const reg = this.locals[index].reg;
      this.emit(instAB(Op.mov, reg, value));
    }
    this.locals[index].initialized = true;
  }

  // Resolve a name in the enclosing functions. `hops` counts the
  // environments between here and the one holding it: this function's
  // open nested ones and its own, then, per enclosing function, the
  // nested ones open where the nested function was created and that
  // function's own -- stopping short at the binding's depth.
  function findOuter(inout this, in parser: Parser, nameStart: u32, nameLength: u32): OuterRef {
    let hops: u32 = this.openEnvs;
    if (this.hasEnv) hops = hops + 1;
    let level: usize = this.outerScopes.length;
    while (level > 0) {
      level = level - 1;
      let index: usize = this.outerScopes[level].names.length;
      while (index > 0) {
        index = index - 1;
        const outer = this.outerScopes[level].names[index];
        if (outer.nameLength == nameLength && this.nameMatches(in parser, outer.nameStart, outer.nameLength, nameStart, nameLength)) {
          if (level < this.minOuterScope) this.minOuterScope = level;
          const above = this.outerScopes[level].openEnvs - outer.envDepth;
          const needsCheck = outer.needsHole && (outer.alwaysCheck || !outer.initialized);
          return OuterRef({ found: true, hops: u8(hops + above), slot: outer.envSlot, scopeIndex: level, needsCheck: needsCheck, isConst: outer.isConst });
        }
      }
      hops = hops + this.outerScopes[level].openEnvs;
      if (this.outerScopes[level].hasEnv) hops = hops + 1;
    }
    return OuterRef({ found: false, hops: 0, slot: -1, scopeIndex: 0, needsCheck: false, isConst: false });
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
      if (local.nameLength > 0 && local.envSlot < 0 && capturedBy(in parser, body, local.nameStart, local.nameLength, false)) {
        const envSlot = i32(this.envSize);
        this.locals[index].envSlot = envSlot;
        // The slot is on record for the binding's own statement too, so
        // a let / const bound later lands in the same slot the function
        // declarations compiled before it were resolved against.
        this.capturedNames.push(Local({ nameStart: local.nameStart, nameLength: local.nameLength, reg: 0, envSlot: envSlot, envDepth: 0, captured: false, isConst: false, initialized: true, alwaysCheck: false, needsHole: false, nameConst: -1, blockFunction: false, lexical: false }));
        this.envSize = this.envSize + 1;
      }
      index = index + 1;
    }
    const root = parser.ast.node(body);
    if (root.kind == NodeKind.blockStmt || root.kind == NodeKind.program) {
      let i: u32 = 0;
      while (i < root.childrenCount) {
        this.scanLateBindings(in parser, parser.ast.child(body, i), body, false);
        i = i + 1;
      }
    } else {
      this.scanLateBindings(in parser, body, body, false);
    }
    this.hasEnv = this.envSize > 0;
  }

  // A parameter (or a pattern parameter's name) that a closure inside a
  // parameter default refers to lives in the environment too; the body
  // scan does not see the defaults.
  function scanParameterCaptures(inout this, in parser: Parser, fn: u32, upTo: usize): void {
    const n = parser.ast.node(fn);
    let index: usize = 0;
    while (index < upTo) {
      const local = this.locals[index];
      if (local.nameLength > 0 && local.envSlot < 0) {
        let p: u32 = 0;
        let captured = false;
        while (p < n.childrenCount && !captured) {
          const paramIndex = parser.ast.child(fn, p);
          const param = parser.ast.node(paramIndex);
          if (param.right != NO_NODE && capturedBy(in parser, param.right, local.nameStart, local.nameLength, false)) captured = true;
          const pattern = parameterPattern(in parser, paramIndex);
          if (pattern != NO_NODE && capturedBy(in parser, pattern, local.nameStart, local.nameLength, false)) captured = true;
          p = p + 1;
        }
        if (captured) {
          const envSlot = i32(this.envSize);
          this.locals[index].envSlot = envSlot;
          this.capturedNames.push(Local({ nameStart: local.nameStart, nameLength: local.nameLength, reg: 0, envSlot: envSlot, envDepth: 0, captured: false, isConst: false, initialized: true, alwaysCheck: false, needsHole: false, nameConst: -1, blockFunction: false, lexical: false }));
          this.envSize = this.envSize + 1;
        }
      }
      index = index + 1;
    }
  }

  // Record a captured lexical binding: a body-level one takes a slot in
  // the function's environment now; a nested one takes a slot in its
  // scope's environment when that scope opens.
  function recordCapture(inout this, nameStart: u32, nameLength: u32, nested: boolean): void {
    let envSlot = BLOCK_SLOT;
    if (!nested) {
      envSlot = i32(this.envSize);
      this.envSize = this.envSize + 1;
    }
    this.capturedNames.push(Local({ nameStart: nameStart, nameLength: nameLength, reg: 0, envSlot: envSlot, envDepth: 0, captured: false, isConst: false, initialized: true, alwaysCheck: false, needsHole: false, nameConst: -1, blockFunction: false, lexical: false }));
  }

  // The identifiers of a lexical pattern that nested functions capture.
  function scanPatternCaptures(inout this, in parser: Parser, pattern: u32, extent: u32, nested: boolean): void {
    if (pattern == NO_NODE) return;
    const n = parser.ast.node(pattern);
    if (n.kind == NodeKind.identExpr) {
      if (n.nameLength > 0 && this.capturedSlot(n.nameStart) < 0 && capturedBy(in parser, extent, n.nameStart, n.nameLength, false)) {
        this.recordCapture(n.nameStart, n.nameLength, nested);
      }
      return;
    }
    if (n.kind == NodeKind.patternEntry) {
      this.scanPatternCaptures(in parser, n.left, extent, nested);
      if (n.right != NO_NODE) this.scanLateBindings(in parser, n.right, extent, nested);
      return;
    }
    if (n.kind == NodeKind.arrayPattern || n.kind == NodeKind.objectPattern) {
      let i: u32 = 0;
      while (i < n.childrenCount) {
        this.scanPatternCaptures(in parser, parser.ast.child(pattern, i), extent, nested);
        i = i + 1;
      }
    }
  }

  // A class body's own bindings live in the enclosing function's
  // environment, always: each private name and each computed instance
  // field key gets a slot, and a named class expression's inner name
  // gets one when a member refers to it. Methods reach them through the
  // scope chain like any captured binding.
  function scanClassBindings(inout this, in parser: Parser, node: u32, extent: u32, nested: boolean): void {
    const n = parser.ast.node(node);
    // A declaration's inner name is recorded under the `class` keyword,
    // apart from the block-level binding the declaration creates.
    if (n.nameLength > 0 && capturedBy(in parser, node, n.nameStart, n.nameLength, false)) {
      const key = n.kind == NodeKind.classExpr ? n.nameStart : n.start;
      this.capturedNames.push(Local({ nameStart: key, nameLength: n.nameLength, reg: 0, envSlot: i32(this.envSize), envDepth: 0, captured: false, isConst: false, initialized: true, alwaysCheck: false, needsHole: false, nameConst: -1, blockFunction: false, lexical: false }));
      this.envSize = this.envSize + 1;
    }
    let i: u32 = 0;
    while (i < n.childrenCount) {
      const memberIndex = parser.ast.child(node, i);
      const member = parser.ast.node(memberIndex);
      if (this.isPrivateName(in parser, member.nameStart, member.nameLength)) {
        if (this.capturedSlotByText(in parser, member.nameStart, member.nameLength) < 0) {
          this.capturedNames.push(Local({ nameStart: member.nameStart, nameLength: member.nameLength, reg: 0, envSlot: i32(this.envSize), envDepth: 0, captured: false, isConst: false, initialized: true, alwaysCheck: false, needsHole: false, nameConst: -1, blockFunction: false, lexical: false }));
          this.envSize = this.envSize + 1;
        }
      } else if (member.kind == NodeKind.classField && !member.boolValue && member.nameLength == 0 && member.third != NO_NODE) {
        // Named by the source from its opening bracket, so the binding
        // can never shadow an identifier the key expression reads.
        const key = parser.ast.node(member.third);
        this.capturedNames.push(Local({ nameStart: key.start - 1, nameLength: key.end - key.start + 1, reg: 0, envSlot: i32(this.envSize), envDepth: 0, captured: false, isConst: false, initialized: true, alwaysCheck: false, needsHole: false, nameConst: -1, blockFunction: false, lexical: false }));
        this.envSize = this.envSize + 1;
      }
      // Static initializers and computed keys run in this function.
      if (member.kind == NodeKind.classField && member.boolValue) this.scanLateBindings(in parser, member.left, extent, nested);
      if (member.third != NO_NODE && member.kind != NodeKind.methodDef) this.scanLateBindings(in parser, member.third, extent, nested);
      i = i + 1;
    }
  }

  // The environment slot reserved for a binding spelled like the source
  // at `nameStart`, innermost first; -1 if none.
  function capturedSlotByText(in parser: Parser, nameStart: u32, nameLength: u32): i32 {
    let index: usize = this.capturedNames.length;
    while (index > 0) {
      index = index - 1;
      const candidate = this.capturedNames[index];
      if (candidate.nameLength == nameLength && this.nameMatches(in parser, candidate.nameStart, candidate.nameLength, nameStart, nameLength)) return candidate.envSlot;
    }
    return -1;
  }

  function isPrivateName(in parser: Parser, nameStart: u32, nameLength: u32): boolean {
    return nameLength > 0 && parser.source[usize(nameStart)] == 35;
  }

  // Load a binding by its spelling: a local, a captured outer binding,
  // else an error (class-scope names are always bound).
  function emitLoadBinding(inout this, in parser: Parser, nameStart: u32, nameLength: u32, dst: u8): void {
    const local = this.findLocal(in parser, nameStart, nameLength);
    if (local >= 0) {
      this.loadLocal(usize(local), dst);
      return;
    }
    const outer = this.findOuter(in parser, nameStart, nameLength);
    if (outer.found && outer.slot >= 0) {
      this.emit(instABC(Op.loadEnvSlot, dst, outer.hops, u8(outer.slot)));
      return;
    }
    this.hadError = true;
  }

  // The private key bound to `#name`, in a fresh register.
  function privateKeyReg(inout this, in parser: Parser, nameStart: u32, nameLength: u32): u8 {
    const dst = this.allocReg();
    this.emitLoadBinding(in parser, nameStart, nameLength, dst);
    return dst;
  }

  // `this` into dst: a static initializer's constructor register, a
  // function's this register, or the top level's.
  function emitThis(inout this, dst: u8): void {
    const source = this.thisSource();
    if (this.hadError) return;
    if (source != dst) this.emit(instAB(Op.mov, dst, source));
  }

  // The register holding `this`. In a derived constructor it is checked
  // (uninitialized until super() returns); in an arrow inside one it is
  // read from the constructor's environment, so the arrow sees the
  // value bound after its creation.
  function thisSource(inout this): u8 {
    if (this.isArrow && this.thisReg >= 0) {
      const found = this.findConstructorThis();
      if (found.found) {
        const dst = this.allocReg();
        this.emit(instABC(Op.loadEnvSlot, dst, found.hops, u8(found.slot)));
        this.emit(instA(Op.checkThis, dst));
        return dst;
      }
    }
    if (this.thisReg >= 0) {
      const reg = u8(this.thisReg);
      if (this.derivedCtor) this.emit(instA(Op.checkThis, reg));
      return reg;
    }
    if (this.isFunction) {
      this.hadError = true;
      return 0;
    }
    const dst = this.allocReg();
    this.emit(instA(Op.loadThis, dst));
    return dst;
  }

  // From an arrow: the nearest enclosing non-arrow function's `this`
  // slot, with the hops to its environment, when it is a derived
  // constructor keeping `this` there.
  function findConstructorThis(inout this): OuterRef {
    let hops: u32 = this.openEnvs;
    if (this.hasEnv) hops = hops + 1;
    let level: usize = this.outerScopes.length;
    while (level > 0) {
      level = level - 1;
      if (!this.outerScopes[level].isArrow) {
        const slot = this.outerScopes[level].thisSlot;
        if (slot < 0) return OuterRef({ found: false, hops: 0, slot: -1, scopeIndex: 0, needsCheck: false, isConst: false });
        hops = hops + this.outerScopes[level].openEnvs;
        if (level < this.minOuterScope) this.minOuterScope = level;
        return OuterRef({ found: true, hops: u8(hops), slot: slot, scopeIndex: level, needsCheck: false, isConst: false });
      }
      hops = hops + this.outerScopes[level].openEnvs;
      if (this.outerScopes[level].hasEnv) hops = hops + 1;
    }
    return OuterRef({ found: false, hops: 0, slot: -1, scopeIndex: 0, needsCheck: false, isConst: false });
  }

  // After super() binds `this`: the environment copy for the arrows.
  function emitThisToEnv(inout this): void {
    if (this.thisEnvSlot < 0 || this.thisReg < 0) return;
    const reg = u8(this.thisReg);
    const hops = u8(this.openEnvs);
    const slot = u8(this.thisEnvSlot);
    this.emit(instABC(Op.storeEnvSlot, reg, hops, slot));
  }

  // The callee of a method call into base and its receiver into base +
  // 1: `super.m` reads the home object's prototype with `this` as the
  // receiver; `o.#m` goes through the private key.
  function emitCalleeAndReceiver(inout this, in parser: Parser, inout runtime: Runtime, callee: AstNode, base: u8): void {
    if (parser.ast.node(callee.left).kind == NodeKind.superExpr) {
      let key: u8 = 0;
      if (callee.kind == NodeKind.member) {
        const atom = this.propertyNameAtom(in parser, inout runtime, callee.nameStart, callee.nameLength);
        key = this.emitKey(atom);
      } else {
        key = this.compileExpr(in parser, inout runtime, callee.right);
      }
      this.emit(instAB(Op.loadSuper, base, key));
      this.emitThis(base + 1);
      return;
    }
    const receiver = this.compileExpr(in parser, inout runtime, callee.left);
    if (receiver != base + 1) this.emit(instAB(Op.mov, base + 1, receiver));
    if (callee.kind == NodeKind.member) {
      if (this.isPrivateName(in parser, callee.nameStart, callee.nameLength)) {
        const key = this.privateKeyReg(in parser, callee.nameStart, callee.nameLength);
        this.emit(instABC(Op.loadElem, base, base + 1, key));
        return;
      }
      const atom = this.propertyNameAtom(in parser, inout runtime, callee.nameStart, callee.nameLength);
      const nameIndex = this.nameSlot(atom);
      this.emit(instABC(Op.loadProp, base, base + 1, nameIndex));
      return;
    }
    const key = this.compileExpr(in parser, inout runtime, callee.right);
    this.emit(instABC(Op.loadElem, base, base + 1, key));
  }

  // An optional chain: a spine of member / element / call links with at
  // least one `?.`. A nullish base at any optional link makes the whole
  // chain undefined, so every such link jumps to one exit.
  function compileOptionalChain(inout this, in parser: Parser, inout runtime: Runtime, node: u32): u8 {
    const dst = this.allocReg();
    let exits = Array<u32>();
    const produced = this.compileChainLink(in parser, inout runtime, node, inout exits);
    if (produced != dst) this.emit(instAB(Op.mov, dst, produced));
    const over = this.emit(instAI16(Op.jmp, 0, 0));
    let i: usize = 0;
    while (i < exits.length) {
      this.patchJump(exits[i]);
      i = i + 1;
    }
    this.emit(instA(Op.loadUndefined, dst));
    this.patchJump(over);
    this.nextReg = dst + 1;
    return dst;
  }

  // One link of the spine; the base of an optional link jumps out when
  // nullish. Links off the spine (arguments, computed keys) compile as
  // ordinary expressions.
  function compileChainLink(inout this, in parser: Parser, inout runtime: Runtime, node: u32, inout exits: Array<u32>): u8 {
    const n = parser.ast.node(node);
    const k = n.kind;
    if (k == NodeKind.member || k == NodeKind.optionalMember || k == NodeKind.computed || k == NodeKind.optionalComputed) {
      const object = this.compileChainLink(in parser, inout runtime, n.left, inout exits);
      if (k == NodeKind.optionalMember || k == NodeKind.optionalComputed) exits.push(this.emit(instAI16(Op.jmpIfNullish, object, 0)));
      const dst = this.allocReg();
      if (k == NodeKind.member || k == NodeKind.optionalMember) {
        if (this.isPrivateName(in parser, n.nameStart, n.nameLength)) {
          const key = this.privateKeyReg(in parser, n.nameStart, n.nameLength);
          this.emit(instABC(Op.loadElem, dst, object, key));
        } else {
          const atom = this.propertyNameAtom(in parser, inout runtime, n.nameStart, n.nameLength);
          this.emit(instABC(Op.loadProp, dst, object, this.nameSlot(atom)));
        }
      } else {
        const key = this.compileExpr(in parser, inout runtime, n.right);
        this.emit(instABC(Op.loadElem, dst, object, key));
      }
      this.nextReg = dst + 1;
      return dst;
    }
    if (k == NodeKind.call || k == NodeKind.optionalCall) {
      if (this.hasSpreadArgument(in parser, node)) {
        this.hadError = true;
        return 0;
      }
      const callee = parser.ast.node(n.left);
      const argCount = n.childrenCount;
      const isMethod = callee.kind == NodeKind.member || callee.kind == NodeKind.optionalMember || callee.kind == NodeKind.computed || callee.kind == NodeKind.optionalComputed;
      const base = this.allocReg();
      const first: u8 = isMethod ? base + 2 : base + 1;
      let slot: u32 = 0;
      while (slot < u32(first - base) + argCount - 1) {
        this.allocReg();
        slot = slot + 1;
      }
      if (isMethod) {
        const receiver = this.compileChainLink(in parser, inout runtime, callee.left, inout exits);
        if (callee.kind == NodeKind.optionalMember || callee.kind == NodeKind.optionalComputed) exits.push(this.emit(instAI16(Op.jmpIfNullish, receiver, 0)));
        if (receiver != base + 1) this.emit(instAB(Op.mov, base + 1, receiver));
        this.nextReg = first + u8(argCount);
        if (callee.kind == NodeKind.member || callee.kind == NodeKind.optionalMember) {
          if (this.isPrivateName(in parser, callee.nameStart, callee.nameLength)) {
            const key = this.privateKeyReg(in parser, callee.nameStart, callee.nameLength);
            this.emit(instABC(Op.loadElem, base, base + 1, key));
          } else {
            const atom = this.propertyNameAtom(in parser, inout runtime, callee.nameStart, callee.nameLength);
            this.emit(instABC(Op.loadProp, base, base + 1, this.nameSlot(atom)));
          }
        } else {
          const key = this.compileExpr(in parser, inout runtime, callee.right);
          this.emit(instABC(Op.loadElem, base, base + 1, key));
        }
      } else {
        const fn = this.compileChainLink(in parser, inout runtime, n.left, inout exits);
        if (fn != base) this.emit(instAB(Op.mov, base, fn));
      }
      if (k == NodeKind.optionalCall) exits.push(this.emit(instAI16(Op.jmpIfNullish, base, 0)));
      this.nextReg = first + u8(argCount);
      let a: u32 = 0;
      while (a < argCount) {
        const argReg = this.compileExpr(in parser, inout runtime, parser.ast.child(node, a));
        if (argReg != first + u8(a)) this.emit(instAB(Op.mov, first + u8(a), argReg));
        this.nextReg = first + u8(argCount);
        a = a + 1;
      }
      if (isMethod) {
        this.emit(instABC(Op.methodInvoke, base, base, u8(argCount)));
      } else {
        this.emit(instABC(Op.invoke, base, base, u8(argCount)));
      }
      this.nextReg = base + 1;
      return base;
    }
    return this.compileExpr(in parser, inout runtime, node);
  }

  // One step of an async iterator: `result = await iterator.next(sent)`
  // (no argument when `withArgument` is false).
  function emitAsyncIteratorStep(inout this, inout runtime: Runtime, iterator: u8, sent: u8, withArgument: boolean, result: u8): void {
    const base = this.allocReg();
    this.allocReg();
    this.allocReg();
    this.emit(instAB(Op.mov, base + 1, iterator));
    const nextText: String = "next";
    const nextAtom = runtime.atomOf(in nextText);
    this.emit(instABC(Op.loadProp, base, base + 1, this.nameSlot(nextAtom)));
    if (withArgument) {
      this.emit(instAB(Op.mov, base + 2, sent));
      this.emit(instABC(Op.methodInvoke, base, base, 1));
    } else {
      this.emit(instABC(Op.methodInvoke, base, base, 0));
    }
    this.emit(instAB(Op.awaitOp, result, base));
    this.nextReg = base;
  }

  // The instance fields of a derived constructor, defined once super()
  // has produced `this`.
  function emitFieldInitializers(inout this, in parser: Parser, inout runtime: Runtime): void {
    if (this.fieldCount == 0 || this.fieldSource == NO_NODE) return;
    let i: u32 = 0;
    while (i < this.fieldCount) {
      this.compileFieldStatement(in parser, inout runtime, parser.ast.child(this.fieldSource, i));
      i = i + 1;
    }
  }

  // One injected field statement, `this.<key> = <init>`, with define
  // semantics: a private key from its binding, a computed key from the
  // slot the class definition evaluated it into, a name as an atom.
  function compileFieldStatement(inout this, in parser: Parser, inout runtime: Runtime, node: u32): void {
    const n = parser.ast.node(node);
    const target = parser.ast.node(n.left);
    const receiver = this.allocReg();
    this.emitThis(receiver);
    let key: u8 = 0;
    if (target.kind == NodeKind.member) {
      if (this.isPrivateName(in parser, target.nameStart, target.nameLength)) {
        key = this.privateKeyReg(in parser, target.nameStart, target.nameLength);
      } else {
        const atom = this.propertyNameAtom(in parser, inout runtime, target.nameStart, target.nameLength);
        key = this.emitKey(atom);
      }
      this.nameNext(target.nameStart, target.nameLength, 0);
    } else {
      const keyNode = parser.ast.node(target.right);
      key = this.allocReg();
      this.emitLoadBinding(in parser, keyNode.start - 1, keyNode.end - keyNode.start + 1, key);
    }
    const value = this.compileExpr(in parser, inout runtime, n.right);
    this.emit(instABC(Op.defineField, receiver, key, value));
    this.resetTemps();
  }

  // A class: the constructor as a function value with the class flags,
  // its prototype, the members in source order, the static initializers
  // running with `this` bound to the constructor. Private names are
  // fresh symbols stored in the class's environment slots.
  function compileClass(inout this, in parser: Parser, inout runtime: Runtime, node: u32, contextualStart: u32, contextualLength: u32): u8 {
    const n = parser.ast.node(node);
    const derived = n.right != NO_NODE;
    // An anonymous class expression takes the name of what it initializes.
    const classNameStart: u32 = n.nameLength > 0 ? n.nameStart : contextualStart;
    const classNameLength: u32 = n.nameLength > 0 ? n.nameLength : contextualLength;
    const ctorReg = this.allocReg();
    const protoReg = this.allocReg();
    const localsBefore = this.locals.length;
    // The class's own name, bound inside its body (a declaration's
    // outer binding is a hole until the definition completes).
    let innerSlot: i32 = -1;
    if (n.nameLength > 0) {
      innerSlot = this.capturedSlot(n.kind == NodeKind.classExpr ? n.nameStart : n.start);
      this.locals.push(Local({ nameStart: n.nameStart, nameLength: n.nameLength, reg: ctorReg, envSlot: innerSlot, envDepth: 0, captured: false, isConst: false, initialized: true, alwaysCheck: false, needsHole: false, nameConst: -1, blockFunction: false, lexical: false }));
    }
    let fieldCount: u32 = 0;
    let ctorNode: u32 = NO_NODE;
    let i: u32 = 0;
    while (i < n.childrenCount) {
      const memberIndex = parser.ast.child(node, i);
      const member = parser.ast.node(memberIndex);
      if (member.kind == NodeKind.classField && !member.boolValue) fieldCount = fieldCount + 1;
      if (member.kind == NodeKind.methodDef && !member.boolValue && member.third == NO_NODE
          && (member.num == 2.0 || (member.nameLength == 11 && parser.sliceEquals(member.nameStart, 11, "constructor")))) {
        ctorNode = memberIndex;
      }
      if (member.kind == NodeKind.classField && !member.boolValue && member.nameLength == 0 && member.third != NO_NODE) {
        // The slot the definition evaluates the computed key into, bound
        // by the key's spelling for the constructor's field statement.
        const keyNode = parser.ast.node(member.third);
        const keySlot = this.capturedSlot(keyNode.start - 1);
        if (keySlot < 0) {
          this.hadError = true;
          return ctorReg;
        }
        this.locals.push(Local({ nameStart: keyNode.start - 1, nameLength: keyNode.end - keyNode.start + 1, reg: 0, envSlot: keySlot, envDepth: 0, captured: false, isConst: false, initialized: true, alwaysCheck: false, needsHole: false, nameConst: -1, blockFunction: false, lexical: false }));
      }
      if (this.isPrivateName(in parser, member.nameStart, member.nameLength) && this.findLocal(in parser, member.nameStart, member.nameLength) < 0) {
        const slot = this.capturedSlotByText(in parser, member.nameStart, member.nameLength);
        if (slot < 0) {
          this.hadError = true;
          return ctorReg;
        }
        this.locals.push(Local({ nameStart: member.nameStart, nameLength: member.nameLength, reg: 0, envSlot: slot, envDepth: 0, captured: false, isConst: false, initialized: true, alwaysCheck: false, needsHole: false, nameConst: -1, blockFunction: false, lexical: false }));
        const description = this.addConst(runtime.internUtf8Value(sliceBytes(in parser.source, usize(member.nameStart), usize(member.nameStart + member.nameLength))));
        const key = this.allocReg();
        this.emit(instAU16(Op.newPrivateName, key, description));
        const keyHops = u8(this.openEnvs);
        this.emit(instABC(Op.storeEnvSlot, key, keyHops, u8(slot)));
        this.nextReg = key;
      }
      i = i + 1;
    }
    let parentReg: u8 = 0;
    if (derived) parentReg = this.compileExpr(in parser, inout runtime, n.right);
    if (ctorNode != NO_NODE) {
      this.emitClassFunction(in parser, inout runtime, ctorNode, ctorReg, classNameStart, classNameLength, 0, derived ? 2 : 1, fieldCount);
    } else {
      // No constructor written: an empty one, or for a derived class
      // one that forwards its arguments to the parent.
      const index = runtime.reserveFunction();
      let code = createFunctionCode();
      if (classNameLength > 0) code.nameAtom = this.atomOfSlice(in parser, inout runtime, classNameStart, classNameLength);
      code.strict = true;
      code.isClassConstructor = true;
      code.isDerived = derived;
      if (derived) {
        code.code.push(instAB(Op.buildRestArgs, 0, 0));
        code.code.push(instAB(Op.spreadSuperCall, 1, 0));
        code.code.push(instA(Op.loadUndefined, 2));
        code.code.push(instA(Op.returnOp, 2));
        code.registerCount = 3;
      } else {
        code.code.push(instA(Op.loadUndefined, 0));
        code.code.push(instA(Op.returnOp, 0));
        code.registerCount = 1;
      }
      runtime.setFunction(index, move code);
      const constant = this.addConst(runtime.functionValue(index));
      this.emit(instAU16(Op.loadConst, ctorReg, constant));
      this.emit(instAB(Op.makeClosure, ctorReg, ctorReg));
    }
    if (this.hadError) return ctorReg;
    this.emit(instA(Op.newObject, protoReg));
    if (derived) {
      this.emit(instABC(Op.initClass, ctorReg, protoReg, parentReg));
    } else {
      this.emit(instAB(Op.initClassBase, ctorReg, protoReg));
    }
    const classHops = u8(this.openEnvs);
    if (innerSlot >= 0) this.emit(instABC(Op.storeEnvSlot, ctorReg, classHops, u8(innerSlot)));
    this.nextReg = protoReg + 1;
    i = 0;
    while (i < n.childrenCount && !this.hadError) {
      const memberIndex = parser.ast.child(node, i);
      const member = parser.ast.node(memberIndex);
      if (member.kind == NodeKind.methodDef && memberIndex != ctorNode) {
        const fnReg = this.allocReg();
        let prefix: u32 = 0;
        if (member.op == TokenKind.kwGet) prefix = 1;
        if (member.op == TokenKind.kwSet) prefix = 2;
        const nameStart: u32 = member.third != NO_NODE ? 0 : member.nameStart;
        const nameLength: u32 = member.third != NO_NODE ? 0 : member.nameLength;
        this.emitClassFunction(in parser, inout runtime, memberIndex, fnReg, nameStart, nameLength, prefix, 3, 0);
        const target: u8 = member.boolValue ? ctorReg : protoReg;
        let key: u8 = 0;
        if (member.third != NO_NODE) {
          key = this.compileExpr(in parser, inout runtime, member.third);
        } else if (this.isPrivateName(in parser, member.nameStart, member.nameLength)) {
          key = this.privateKeyReg(in parser, member.nameStart, member.nameLength);
        } else {
          const atom = this.propertyNameAtom(in parser, inout runtime, member.nameStart, member.nameLength);
          key = this.emitKey(atom);
        }
        if (prefix == 1) {
          this.emit(instABC(Op.defineMethodGetter, target, key, fnReg));
        } else if (prefix == 2) {
          this.emit(instABC(Op.defineMethodSetter, target, key, fnReg));
        } else {
          this.emit(instABC(Op.defineMethodComputed, target, key, fnReg));
        }
      } else if (member.kind == NodeKind.classField && member.boolValue) {
        const savedThis = this.thisReg;
        this.thisReg = i32(ctorReg);
        let key: u8 = 0;
        if (member.third != NO_NODE) {
          key = this.compileExpr(in parser, inout runtime, member.third);
        } else if (this.isPrivateName(in parser, member.nameStart, member.nameLength)) {
          key = this.privateKeyReg(in parser, member.nameStart, member.nameLength);
        } else {
          const atom = this.propertyNameAtom(in parser, inout runtime, member.nameStart, member.nameLength);
          key = this.emitKey(atom);
          this.nameNext(member.nameStart, member.nameLength, 0);
        }
        let value: u8 = 0;
        if (member.left != NO_NODE) {
          value = this.compileExpr(in parser, inout runtime, member.left);
        } else {
          value = this.allocReg();
          this.emit(instA(Op.loadUndefined, value));
        }
        this.emit(instABC(Op.defineField, ctorReg, key, value));
        this.thisReg = savedThis;
      } else if (member.kind == NodeKind.classField && member.third != NO_NODE) {
        // An instance field's computed key is evaluated once, here, into
        // the slot its initializer reads.
        const keyNode = parser.ast.node(member.third);
        const slot = this.capturedSlot(keyNode.start - 1);
        if (slot < 0) {
          this.hadError = true;
          return ctorReg;
        }
        const key = this.compileExpr(in parser, inout runtime, member.third);
        const keyHops = u8(this.openEnvs);
        this.emit(instABC(Op.storeEnvSlot, key, keyHops, u8(slot)));
      } else if (member.kind == NodeKind.staticBlock) {
        const fnReg = this.allocReg();
        this.emitClassFunction(in parser, inout runtime, memberIndex, fnReg, 0, 0, 0, 3, 0);
        const base = this.allocReg();
        this.allocReg();
        this.emit(instAB(Op.mov, base, fnReg));
        this.emit(instAB(Op.mov, base + 1, ctorReg));
        this.emit(instABC(Op.methodInvoke, base, base, 0));
      }
      this.nextReg = protoReg + 1;
      i = i + 1;
    }
    let u = this.locals.length;
    while (u > localsBefore) {
      u = u - 1;
      this.unbindLocal(u);
    }
    this.nextReg = ctorReg + 1;
    return ctorReg;
  }

  // A class member as a function value: compiled with its class role
  // and always wrapped as a closure, so every evaluation of the class
  // gets fresh function objects.
  function emitClassFunction(inout this, in parser: Parser, inout runtime: Runtime, node: u32, dst: u8, nameStart: u32, nameLength: u32, namePrefix: u32, role: u32, fieldCount: u32): void {
    const hasEnv = this.hasEnv;
    const strict = this.strict;
    const compiled = compileFunction(in parser, inout runtime, node, in this.outerScopes, in this.locals, hasEnv, this.openEnvs, this.isArrow, this.thisEnvSlot, strict, nameStart, nameLength, namePrefix, role, fieldCount);
    if (compiled.index < 0) {
      this.hadError = true;
      return;
    }
    const constant = this.addConst(runtime.functionValue(u32(compiled.index)));
    this.emit(instAU16(Op.loadConst, dst, constant));
    this.emit(instAB(Op.makeClosure, dst, dst));
    const ownScope = this.outerScopes.length;
    if (compiled.minOuterScope < ownScope && compiled.minOuterScope < this.minOuterScope) this.minOuterScope = compiled.minOuterScope;
  }

  // let / const declarations and catch parameters of this function's
  // body, not entering nested functions.
  // `scope` is the node a binding found here belongs to, the extent a
  // nested function must sit in to capture it; `nested` says it is
  // inside a block, loop, switch, or catch clause rather than at the
  // body's top level, so its slot is that scope's, not the function's.
  function scanLateBindings(inout this, in parser: Parser, node: u32, extent: u32, nested: boolean): void {
    if (node == NO_NODE) return;
    const n = parser.ast.node(node);
    const k = n.kind;
    if (k == NodeKind.functionDecl) {
      if (nested && n.nameLength > 0 && this.capturedSlot(n.nameStart) < 0 && capturedBy(in parser, extent, n.nameStart, n.nameLength, false)) {
        this.recordCapture(n.nameStart, n.nameLength, true);
      }
      return;
    }
    if (k == NodeKind.functionExpr || k == NodeKind.arrowFunc || k == NodeKind.methodDef || k == NodeKind.staticBlock) return;
    if (k == NodeKind.classDecl || k == NodeKind.classExpr) {
      if (k == NodeKind.classDecl && n.nameLength > 0 && this.capturedSlot(n.nameStart) < 0 && capturedBy(in parser, extent, n.nameStart, n.nameLength, false)) {
        this.recordCapture(n.nameStart, n.nameLength, nested);
      }
      this.scanClassBindings(in parser, node, extent, nested);
      return;
    }
    if (k == NodeKind.varDecl && n.op != TokenKind.kwVar) {
      let i: u32 = 0;
      while (i < n.childrenCount) {
        const declIndex = parser.ast.child(node, i);
        const decl = parser.ast.node(declIndex);
        if (decl.nameLength > 0 && this.capturedSlot(decl.nameStart) < 0 && capturedBy(in parser, extent, decl.nameStart, decl.nameLength, false)) {
          this.recordCapture(decl.nameStart, decl.nameLength, nested);
        }
        if (decl.nameLength == 0 && decl.third != NO_NODE) this.scanPatternCaptures(in parser, decl.third, extent, nested);
        if (decl.left != NO_NODE) this.scanLateBindings(in parser, decl.left, extent, nested);
        i = i + 1;
      }
      return;
    }
    if (k == NodeKind.tryStmt && n.nameLength > 0 && this.capturedSlot(n.nameStart) < 0 && capturedBy(in parser, n.right, n.nameStart, n.nameLength, false)) {
      this.recordCapture(n.nameStart, n.nameLength, true);
    }
    // A block, loop, or switch scopes what it declares.
    let innerExtent = extent;
    let innerNested = nested;
    if (k == NodeKind.blockStmt || k == NodeKind.forStmt || k == NodeKind.forInStmt || k == NodeKind.forOfStmt || k == NodeKind.switchStmt) {
      innerExtent = node;
      innerNested = true;
    }
    this.scanLateBindings(in parser, n.left, innerExtent, innerNested);
    this.scanLateBindings(in parser, n.right, innerExtent, innerNested);
    this.scanLateBindings(in parser, n.third, innerExtent, innerNested);
    let i: u32 = 0;
    while (i < n.childrenCount) {
      this.scanLateBindings(in parser, parser.ast.child(node, i), innerExtent, innerNested);
      i = i + 1;
    }
  }

  // Function-scoped bindings of a body: var and nested function
  // declarations, all as registers. Lexical declarations belong to their
  // scopes. Nested functions are not entered; their bindings are their own.
  function collectBodyLocals(inout this, in parser: Parser, body: u32): void {
    const n = parser.ast.node(body);
    if (n.kind != NodeKind.blockStmt) {
      this.collectLocals(in parser, body, true);
      return;
    }
    let i: u32 = 0;
    while (i < n.childrenCount) {
      this.collectLocals(in parser, parser.ast.child(body, i), false);
      i = i + 1;
    }
  }

  // `nested`: inside a block rather than at the body's top level. A
  // function declaration there is the block's own binding; sloppy code
  // also gives it a function-scoped var (assigned when the declaration
  // is evaluated), strict code does not.
  function collectLocals(inout this, in parser: Parser, node: u32, nested: boolean): void {
    if (node == NO_NODE) return;
    const n = parser.ast.node(node);
    const k = n.kind;
    if (k == NodeKind.functionDecl) {
      if (nested && this.strict) return;
      if (this.findLocal(in parser, n.nameStart, n.nameLength) < 0) this.addLocal(n.nameStart, n.nameLength);
      return;
    }
    if (k == NodeKind.functionExpr || k == NodeKind.arrowFunc || k == NodeKind.classExpr || k == NodeKind.classDecl) return;
    if (k == NodeKind.varDecl && n.op != TokenKind.kwVar) return;
    if (k == NodeKind.varDecl) {
      let i: u32 = 0;
      while (i < n.childrenCount) {
        const decl = parser.ast.node(parser.ast.child(node, i));
        if (decl.nameLength > 0 && this.findLocal(in parser, decl.nameStart, decl.nameLength) < 0) {
          this.addLocal(decl.nameStart, decl.nameLength);
        }
        if (decl.nameLength == 0 && decl.third != NO_NODE) this.collectPatternLocals(in parser, decl.third);
        if (decl.left != NO_NODE) this.collectLocals(in parser, decl.left, true);
        i = i + 1;
      }
      return;
    }
    if (n.left != NO_NODE) this.collectLocals(in parser, n.left, true);
    if (n.right != NO_NODE) this.collectLocals(in parser, n.right, true);
    if (n.third != NO_NODE) this.collectLocals(in parser, n.third, true);
    let i: u32 = 0;
    while (i < n.childrenCount) {
      this.collectLocals(in parser, parser.ast.child(node, i), true);
      i = i + 1;
    }
  }

  // Every identifier a pattern declares becomes a local.
  function collectPatternLocals(inout this, in parser: Parser, pattern: u32): void {
    if (pattern == NO_NODE) return;
    const n = parser.ast.node(pattern);
    if (n.kind == NodeKind.identExpr) {
      if (n.nameLength > 0 && this.findLocal(in parser, n.nameStart, n.nameLength) < 0) this.addLocal(n.nameStart, n.nameLength);
      return;
    }
    if (n.kind == NodeKind.patternEntry) {
      this.collectPatternLocals(in parser, n.left);
      return;
    }
    if (n.kind == NodeKind.arrayPattern || n.kind == NodeKind.objectPattern) {
      let i: u32 = 0;
      while (i < n.childrenCount) {
        this.collectPatternLocals(in parser, parser.ast.child(pattern, i));
        i = i + 1;
      }
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
      if (outer.needsCheck) {
        const current = this.allocReg();
        this.emit(instABC(Op.loadEnvSlot, current, outer.hops, u8(outer.slot)));
        const named = this.nameConstOf(in parser, inout runtime, target.nameStart, target.nameLength);
        this.emit(instAU16(Op.throwIfHole, current, named));
      }
      if (outer.isConst) {
        this.emit(instA(Op.throwConstAssign, 0));
        return;
      }
      this.emit(instABC(Op.storeEnvSlot, value, outer.hops, u8(outer.slot)));
      return;
    }
    const slot = runtime.globalSlotBytes(globalNameBytes(in parser, target.nameStart, target.nameLength));
    this.emit(instAU16(Op.storeGlobal, value, slot));
  }

  // A local bound to a register chosen by the caller (a catch parameter).
  // A captured one is copied into its environment slot by the caller once
  // its scope has opened.
  function bindLocal(inout this, nameStart: u32, nameLength: u32, reg: u8): usize {
    let envSlot = this.capturedSlot(nameStart);
    const captured = envSlot != -1;
    if (envSlot == BLOCK_SLOT) envSlot = -1;
    this.locals.push(Local({ nameStart: nameStart, nameLength: nameLength, reg: reg, envSlot: envSlot, envDepth: 0, captured: captured, isConst: false, initialized: true, alwaysCheck: false, needsHole: false, nameConst: -1, blockFunction: false, lexical: false }));
    return this.locals.length - 1;
  }

  // Close a binding's scope. The entry stays, since Z's Array cannot
  // remove elements, but an empty name never matches a lookup.
  function unbindLocal(inout this, index: usize): void {
    this.locals[index].nameLength = 0;
  }

  // --- Property names ---

  function atomOfSlice(in parser: Parser, inout runtime: Runtime, start: u32, length: u32): u32 {
    return runtime.internUtf8(sliceBytes(in parser.source, usize(start), usize(start + length)));
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
    const first = parser.source[usize(nameStart)];
    if (first == 34 || first == 39) {
      if (nameLength < 2) {
        this.hadError = true;
        return 0;
      }
      return runtime.internUnits(decodeStringBody(in parser, nameStart + 1, nameStart + nameLength - 1));
    }
    if (first == 35) {
      this.hadError = true;
      return 0;
    }
    // A numeric literal names the property by its canonical string.
    if ((first >= 48 && first <= 57) || first == 46) {
      const number = parser.parseNumberLiteral(nameStart, nameLength);
      return runtime.propertyKey(doubleValue(number));
    }
    // An identifier name written with unicode escapes names the
    // property by its decoded characters.
    let i: u32 = 0;
    while (i < nameLength) {
      if (parser.source[usize(nameStart + i)] == 92) return runtime.internUnits(decodeIdentifierName(in parser, nameStart, nameLength));
      i = i + 1;
    }
    return this.atomOfSlice(in parser, inout runtime, nameStart, nameLength);
  }

  function hasSpreadArgument(in parser: Parser, node: u32): boolean {
    const n = parser.ast.node(node);
    let i: u32 = 0;
    while (i < n.childrenCount) {
      if (parser.ast.node(parser.ast.child(node, i)).kind == NodeKind.spread) return true;
      i = i + 1;
    }
    return false;
  }

  // The arguments of a call with a spread, gathered into the array in
  // `argsReg`: plain arguments pushed, spreads appended.
  function compileArgumentsArray(inout this, in parser: Parser, inout runtime: Runtime, node: u32, argsReg: u8): void {
    const n = parser.ast.node(node);
    this.emit(instABC(Op.newArray, argsReg, 0, 0));
    const watermark = this.nextReg;
    let i: u32 = 0;
    while (i < n.childrenCount) {
      const argumentNode = parser.ast.child(node, i);
      const argument = parser.ast.node(argumentNode);
      if (argument.kind == NodeKind.spread) {
        const iterable = this.compileExpr(in parser, inout runtime, argument.left);
        this.emit(instAB(Op.arraySpread, argsReg, iterable));
      } else {
        const value = this.compileExpr(in parser, inout runtime, argumentNode);
        this.emit(instAB(Op.arrayPush, argsReg, value));
      }
      this.nextReg = watermark;
      i = i + 1;
    }
  }

  // Compile a nested function and load its value into `dst`. The value
  // is a closure when the function refers to enclosing bindings or is an
  // arrow (which keeps the `this` of its creation); reaching past this
  // function makes this one a closure as well.
  function emitFunctionValue(inout this, in parser: Parser, inout runtime: Runtime, node: u32, dst: u8, nameStart: u32, nameLength: u32, namePrefix: u32): void {
    const hasEnv = this.hasEnv;
    const strict = this.strict;
    const compiled = compileFunction(in parser, inout runtime, node, in this.outerScopes, in this.locals, hasEnv, this.openEnvs, this.isArrow, this.thisEnvSlot, strict, nameStart, nameLength, namePrefix, 0, 0);
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

  // Name the anonymous function the next expression defines.
  function nameNext(inout this, nameStart: u32, nameLength: u32, prefix: u32): void {
    this.pendingNameStart = nameStart;
    this.pendingNameLength = nameLength;
    this.pendingNamePrefix = prefix;
  }

  function compileExpr(inout this, in parser: Parser, inout runtime: Runtime, node: u32): u8 {
    if (node == NO_NODE) return 0;
    const n = parser.ast.node(node);
    const k = n.kind;
    const contextualStart = this.pendingNameStart;
    const contextualLength = this.pendingNameLength;
    const contextualPrefix = this.pendingNamePrefix;
    this.pendingNameLength = 0;
    this.pendingNamePrefix = 0;

    if (k == NodeKind.numberExpr) {
      const dst = this.allocReg();
      const value = n.num;
      const truncated = f64ToInt32Exact(value);
      // -0 has no int32 form.
      const negativeZero = value == 0.0 && 1.0 / value < 0.0;
      if (negativeZero) {
        const index = this.addConst(doubleValue(value));
        this.emit(instAU16(Op.loadConst, dst, index));
      } else if (truncated.exact && truncated.value >= -32768 && truncated.value <= 32767) {
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
    if (k == NodeKind.paren) {
      this.nameNext(contextualStart, contextualLength, contextualPrefix);
      return this.compileExpr(in parser, inout runtime, n.left);
    }
    if (k == NodeKind.regexExpr) {
      // /source/flags: the two strings as constants, a fresh object at
      // every evaluation.
      let lastSlash = n.end - 1;
      while (lastSlash > n.start && parser.source[usize(lastSlash)] != 47) { lastSlash = lastSlash - 1; }
      const sourceIndex = this.addConst(runtime.internUtf8Value(sliceBytes(in parser.source, usize(n.start + 1), usize(lastSlash))));
      const flagsIndex = this.addConst(runtime.internUtf8Value(sliceBytes(in parser.source, usize(lastSlash + 1), usize(n.end))));
      const dst = this.allocReg();
      if (sourceIndex < 256 && flagsIndex < 256) {
        this.emit(instABC(Op.newRegex, dst, u8(sourceIndex), u8(flagsIndex)));
      } else {
        const sourceReg = this.allocReg();
        this.emit(instAU16(Op.loadConst, sourceReg, sourceIndex));
        const flagsReg = this.allocReg();
        this.emit(instAU16(Op.loadConst, flagsReg, flagsIndex));
        this.emit(instABC(Op.newRegexR, dst, sourceReg, flagsReg));
        this.nextReg = dst + 1;
      }
      return dst;
    }
    if (k == NodeKind.stringExpr) {
      const decoded = decodeStringBody(in parser, n.start + 1, n.end > 0 ? n.end - 1 : n.start + 1);
      const index = this.addConst(runtime.internUnitsValue(move decoded));
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
        if (outer.needsCheck) {
          const named = this.nameConstOf(in parser, inout runtime, n.nameStart, n.nameLength);
          this.emit(instAU16(Op.throwIfHole, dst, named));
        }
        return dst;
      }
      const slot = runtime.globalSlotBytes(globalNameBytes(in parser, n.nameStart, n.nameLength));
      this.emit(instAU16(Op.loadGlobal, dst, slot));
      return dst;
    }
    if (k == NodeKind.templatePartExpr) {
      const decoded = decodeStringBody(in parser, n.start, n.end);
      const index = this.addConst(runtime.internUnitsValue(move decoded));
      const dst = this.allocReg();
      this.emit(instAU16(Op.loadConst, dst, index));
      return dst;
    }
    if (k == NodeKind.templateExpr) {
      // Literal segments and substitutions, concatenated left to right.
      if (n.childrenCount == 0) {
        const index = this.addConst(runtime.internLatin1Value(Array<u8>()));
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
    if (k == NodeKind.taggedTemplate) {
      // tag`...`: the site's template object (built once, a constant)
      // and the substitutions as the tag's arguments; a member tag keeps
      // its receiver.
      const template = parser.ast.node(n.right);
      let cooked = Array<Value>();
      let raw = Array<Value>();
      let substitutions = Array<u32>();
      let i: u32 = 0;
      while (i < template.childrenCount) {
        const partIndex = parser.ast.child(n.right, i);
        const part = parser.ast.node(partIndex);
        if (part.kind == NodeKind.templatePartExpr) {
          cooked.push(runtime.internUnitsValue(decodeStringBody(in parser, part.start, part.end)));
          raw.push(runtime.internUtf8Value(sliceBytes(in parser.source, usize(part.start), usize(part.end))));
        } else {
          substitutions.push(partIndex);
        }
        i = i + 1;
      }
      // A template with no literal text still has one empty string.
      if (cooked.length == 0) {
        cooked.push(runtime.internLatin1Value(Array<u8>()));
        raw.push(runtime.internLatin1Value(Array<u8>()));
      }
      const templateObject = runtime.newTemplateObject(move cooked, move raw);
      const constant = this.addConst(templateObject);
      const callee = parser.ast.node(n.left);
      const isMethod = callee.kind == NodeKind.member || callee.kind == NodeKind.computed;
      const argCount = u32(substitutions.length) + 1;
      const base = this.allocReg();
      const first: u8 = isMethod ? base + 2 : base + 1;
      let slot: u32 = 0;
      while (slot < u32(first - base) + argCount - 1) {
        this.allocReg();
        slot = slot + 1;
      }
      if (isMethod) {
        this.emitCalleeAndReceiver(in parser, inout runtime, callee, base);
      } else {
        const fn = this.compileExpr(in parser, inout runtime, n.left);
        if (fn != base) this.emit(instAB(Op.mov, base, fn));
      }
      this.nextReg = first + u8(argCount);
      this.emit(instAU16(Op.loadConst, first, constant));
      let a: u32 = 0;
      while (a < u32(substitutions.length)) {
        const argReg = this.compileExpr(in parser, inout runtime, substitutions[usize(a)]);
        if (argReg != first + 1 + u8(a)) this.emit(instAB(Op.mov, first + 1 + u8(a), argReg));
        this.nextReg = first + u8(argCount);
        a = a + 1;
      }
      if (isMethod) {
        this.emit(instABC(Op.methodInvoke, base, base, u8(argCount)));
      } else {
        this.emit(instABC(Op.invoke, base, base, u8(argCount)));
      }
      this.nextReg = base + 1;
      return base;
    }
    if (k == NodeKind.awaitExpr) {
      // Suspend on the awaited value; the async driver resumes with the
      // settled value (into dst) or throws the rejection here.
      if (!this.isAsyncBody) {
        this.hadError = true;
        return 0;
      }
      const value = this.compileExpr(in parser, inout runtime, n.left);
      const dst = this.allocReg();
      this.emit(instAB(Op.awaitOp, dst, value));
      return dst;
    }
    if (k == NodeKind.yieldExpr) {
      if (n.boolValue && this.isAsyncGeneratorBody) {
        // yield* in an async generator: the operand's async iterator
        // (a sync one wrapped), each next() awaited, each value handed
        // to the request as it is, what next() sends forwarded, and the
        // delegate's final value the expression's. A return or throw
        // sent while delegating is not forwarded (limitation).
        const iterable = this.compileExpr(in parser, inout runtime, n.left);
        const iterator = this.allocReg();
        this.emit(instAB(Op.iterGetAsync, iterator, iterable));
        const sent = this.allocReg();
        const result = this.allocReg();
        if (result + 1 > this.fixedRegs) this.fixedRegs = result + 1;
        this.emit(instA(Op.loadUndefined, sent));
        const loopTop = u32(this.code.length);
        this.emitAsyncIteratorStep(inout runtime, iterator, sent, true, result);
        const done = this.allocReg();
        const doneText: String = "done";
        const doneAtom = runtime.atomOf(in doneText);
        this.emit(instABC(Op.loadProp, done, result, this.nameSlot(doneAtom)));
        const exit = this.emit(instAI16(Op.jmpIfTrue, done, 0));
        const value = this.allocReg();
        const valueText: String = "value";
        const valueAtom = runtime.atomOf(in valueText);
        this.emit(instABC(Op.loadProp, value, result, this.nameSlot(valueAtom)));
        this.emit(instAB(Op.yieldRaw, sent, value));
        this.emitJumpBack(loopTop);
        this.patchJump(exit);
        const dst = this.allocReg();
        this.emit(instABC(Op.loadProp, dst, result, this.nameSlot(valueAtom)));
        return dst;
      }
      if (n.boolValue) {
        // yield*: the delegate's results go to the caller as they are;
        // each resumption is forwarded by its mode -- next(v) to
        // next(v), throw(e) to throw(e) (a delegate without one is
        // closed and the throw is a TypeError), return(v) to return(v)
        // (a delegate without one, or one that finishes, makes this
        // generator return, through its finally blocks); a delegate that
        // finishes on next or throw hands its value to the expression.
        const iterable = this.compileExpr(in parser, inout runtime, n.left);
        const iterator = this.allocReg();
        this.emit(instAB(Op.iterGet, iterator, iterable));
        const received = this.allocReg();
        const mode = this.allocReg();
        const result = this.allocReg();
        if (result + 1 > this.fixedRegs) this.fixedRegs = result + 1;
        this.emit(instA(Op.loadUndefined, received));
        this.emit(instAI16(Op.loadInt, mode, 0));
        const doneText: String = "done";
        const doneAtom = runtime.atomOf(in doneText);
        const valueText: String = "value";
        const valueAtom = runtime.atomOf(in valueText);
        const loopTop = u32(this.code.length);
        const one = this.allocReg();
        this.emit(instAI16(Op.loadInt, one, 1));
        const isThrow = this.allocReg();
        this.emit(instABC(Op.cmpStrictEq, isThrow, mode, one));
        const toThrow = this.emit(instAI16(Op.jmpIfTrue, isThrow, 0));
        const two = this.allocReg();
        this.emit(instAI16(Op.loadInt, two, 2));
        const isReturn = this.allocReg();
        this.emit(instABC(Op.cmpStrictEq, isReturn, mode, two));
        const toReturn = this.emit(instAI16(Op.jmpIfTrue, isReturn, 0));
        this.emit(instABC(Op.iterNextWith, result, iterator, received));
        const toCheck = this.emit(instI16(Op.jmp, 0));
        this.patchJump(toThrow);
        this.emit(instABC(Op.iterThrowWith, result, iterator, received));
        const toCheck2 = this.emit(instI16(Op.jmp, 0));
        this.patchJump(toReturn);
        this.emit(instABC(Op.iterReturnWith, result, iterator, received));
        const returnDone = this.allocReg();
        this.emit(instABC(Op.loadProp, returnDone, result, this.nameSlot(doneAtom)));
        const toYield = this.emit(instAI16(Op.jmpIfFalse, returnDone, 0));
        // The delegate finished a return: this generator returns its value.
        const returned = this.allocReg();
        this.emit(instABC(Op.loadProp, returned, result, this.nameSlot(valueAtom)));
        if (this.regionDepth > 0) {
          const savedFixed = this.fixedRegs;
          if (returned + 1 > this.fixedRegs) this.fixedRegs = returned + 1;
          this.emitUnwind(in parser, inout runtime, 0);
          this.fixedRegs = savedFixed;
        }
        this.emit(instA(Op.returnOp, returned));
        this.patchJump(toCheck);
        this.patchJump(toCheck2);
        const done = this.allocReg();
        this.emit(instABC(Op.loadProp, done, result, this.nameSlot(doneAtom)));
        const finished = this.emit(instAI16(Op.jmpIfTrue, done, 0));
        this.patchJump(toYield);
        this.emit(instAB(Op.yieldDelegate, received, result));
        this.emit(instA(Op.resumeMode, mode));
        this.emitJumpBack(loopTop);
        this.patchJump(finished);
        const dst = this.allocReg();
        this.emit(instABC(Op.loadProp, dst, result, this.nameSlot(valueAtom)));
        return dst;
      }
      let value: u8 = 0;
      if (n.left != NO_NODE) {
        value = this.compileExpr(in parser, inout runtime, n.left);
      } else {
        value = this.allocReg();
        this.emit(instA(Op.loadUndefined, value));
      }
      const dst = this.allocReg();
      this.emit(instAB(Op.yieldOp, dst, value));
      {
        // Resumed by return(v): return v from here, through the finally
        // blocks, as a return statement would (an async generator's
        // driver has awaited v by then).
        const skip = this.emit(instI16(Op.jmpIfNotReturn, 0));
        if (this.regionDepth > 0) {
          const savedFixed = this.fixedRegs;
          if (dst + 1 > this.fixedRegs) this.fixedRegs = dst + 1;
          this.emitUnwind(in parser, inout runtime, 0);
          this.fixedRegs = savedFixed;
        }
        this.emit(instA(Op.returnOp, dst));
        this.patchJump(skip);
      }
      return dst;
    }
    if (k == NodeKind.thisExpr) {
      if (n.boolValue) {
        const dst = this.allocReg();
        this.emit(instA(Op.loadNewTarget, dst));
        return dst;
      }
      // A static initializer routes `this` to the constructor's register.
      return this.thisSource();
    }
    if ((k == NodeKind.member || k == NodeKind.computed || k == NodeKind.call || k == NodeKind.optionalMember || k == NodeKind.optionalComputed || k == NodeKind.optionalCall)
        && chainHasOptional(in parser, node)) {
      return this.compileOptionalChain(in parser, inout runtime, node);
    }
    if (k == NodeKind.member) {
      // `#x` alone (the left operand of `#x in obj`) is the private key.
      if (n.left == NO_NODE) return this.privateKeyReg(in parser, n.nameStart, n.nameLength);
      if (parser.ast.node(n.left).kind == NodeKind.superExpr) {
        const atom = this.propertyNameAtom(in parser, inout runtime, n.nameStart, n.nameLength);
        const key = this.emitKey(atom);
        const dst = this.allocReg();
        this.emit(instAB(Op.loadSuper, dst, key));
        return dst;
      }
      const object = this.compileExpr(in parser, inout runtime, n.left);
      if (this.isPrivateName(in parser, n.nameStart, n.nameLength)) {
        const key = this.privateKeyReg(in parser, n.nameStart, n.nameLength);
        const dst = this.allocReg();
        this.emit(instABC(Op.loadElem, dst, object, key));
        return dst;
      }
      const atom = this.propertyNameAtom(in parser, inout runtime, n.nameStart, n.nameLength);
      const slot = this.nameSlot(atom);
      const dst = this.allocReg();
      this.emit(instABC(Op.loadProp, dst, object, slot));
      return dst;
    }
    if (k == NodeKind.computed) {
      if (parser.ast.node(n.left).kind == NodeKind.superExpr) {
        const key = this.compileExpr(in parser, inout runtime, n.right);
        const dst = this.allocReg();
        this.emit(instAB(Op.loadSuper, dst, key));
        return dst;
      }
      const object = this.compileExpr(in parser, inout runtime, n.left);
      const key = this.compileExpr(in parser, inout runtime, n.right);
      const dst = this.allocReg();
      this.emit(instABC(Op.loadElem, dst, object, key));
      return dst;
    }
    if (k == NodeKind.classExpr) {
      return this.compileClass(in parser, inout runtime, node, contextualStart, contextualLength);
    }
    if (k == NodeKind.object) {
      const dst = this.allocReg();
      this.emit(instA(Op.newObject, dst));
      let i: u32 = 0;
      while (i < n.childrenCount) {
        const propertyIndex = parser.ast.child(node, i);
        const property = parser.ast.node(propertyIndex);
        if (property.kind == NodeKind.spread) {
          // { ...source }: the source's own enumerable properties copied in.
          const source = this.compileExpr(in parser, inout runtime, property.left);
          this.emit(instAB(Op.objectSpread, dst, source));
          this.nextReg = dst + 1;
          i = i + 1;
          continue;
        }
        if (property.kind != NodeKind.objectProp) {
          this.hadError = true;
          return 0;
        }
        let key: u8 = 0;
        if (property.third != NO_NODE) {
          key = this.compileExpr(in parser, inout runtime, property.third);
        } else {
          const atom = this.propertyNameAtom(in parser, inout runtime, property.nameStart, property.nameLength);
          key = this.emitKey(atom);
          let prefix: u32 = 0;
          if (property.op == TokenKind.kwGet) prefix = 1;
          if (property.op == TokenKind.kwSet) prefix = 2;
          // A quoted key names the function without its quotes.
          const firstByte = parser.source[usize(property.nameStart)];
          if ((firstByte == 34 || firstByte == 39) && property.nameLength >= 2) {
            this.nameNext(property.nameStart + 1, property.nameLength - 2, prefix);
          } else {
            this.nameNext(property.nameStart, property.nameLength, prefix);
          }
        }
        const value = this.compileExpr(in parser, inout runtime, property.left);
        if (property.op == TokenKind.kwGet) {
          this.emit(instABC(Op.defineGetter, dst, key, value));
        } else if (property.op == TokenKind.kwSet) {
          this.emit(instABC(Op.defineSetter, dst, key, value));
        } else {
          this.emit(instABC(Op.initObjData, dst, key, value));
        }
        this.nextReg = dst + 1;
        i = i + 1;
      }
      return dst;
    }
    if (k == NodeKind.holeExpr) {
      // An elision: the deleted marker in a slot is a hole.
      const index = this.addConst(deletedValue());
      const dst = this.allocReg();
      this.emit(instAU16(Op.loadConst, dst, index));
      return dst;
    }
    if (k == NodeKind.array) {
      const count = n.childrenCount;
      let hasSpread = false;
      let i: u32 = 0;
      while (i < count) {
        if (parser.ast.node(parser.ast.child(node, i)).kind == NodeKind.spread) hasSpread = true;
        i = i + 1;
      }
      if (count == 0 || count > 32 || hasSpread) {
        // Element by element into an empty array; a spread appends
        // everything its iterable yields.
        const dst = this.allocReg();
        this.emit(instABC(Op.newArray, dst, 0, 0));
        i = 0;
        while (i < count) {
          const elementNode = parser.ast.child(node, i);
          const elementInfo = parser.ast.node(elementNode);
          if (elementInfo.kind == NodeKind.spread) {
            const iterable = this.compileExpr(in parser, inout runtime, elementInfo.left);
            this.emit(instAB(Op.arraySpread, dst, iterable));
          } else {
            const element = this.compileExpr(in parser, inout runtime, elementNode);
            this.emit(instAB(Op.arrayPush, dst, element));
          }
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
    if (k == NodeKind.newExpr && this.hasSpreadArgument(in parser, node)) {
      // new f(...args): callee at base, the arguments array above it.
      const base = this.allocReg();
      const argsReg = this.allocReg();
      const calleeReg = this.compileExpr(in parser, inout runtime, n.left);
      if (calleeReg != base) this.emit(instAB(Op.mov, base, calleeReg));
      this.nextReg = base + 2;
      this.compileArgumentsArray(in parser, inout runtime, node, argsReg);
      this.emit(instABC(Op.spreadNewInvoke, base, base, 0));
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
            const slot = runtime.globalSlotBytes(globalNameBytes(in parser, target.nameStart, target.nameLength));
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
    if (k == NodeKind.assignment && n.op == TokenKind.eq
        && (parser.ast.node(n.left).kind == NodeKind.arrayPattern || parser.ast.node(n.left).kind == NodeKind.objectPattern)) {
      const value = this.compileExpr(in parser, inout runtime, n.right);
      this.destructure(in parser, inout runtime, n.left, value);
      return value;
    }
    if (k == NodeKind.assignment) {
      const target = parser.ast.node(n.left);
      if (target.kind == NodeKind.identExpr) {
        let value: u8 = 0;
        if (n.op == TokenKind.eq) {
          this.nameNext(target.nameStart, target.nameLength, 0);
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
      if ((target.kind == NodeKind.member || target.kind == NodeKind.computed) && n.op == TokenKind.eq && target.left != NO_NODE && parser.ast.node(target.left).kind == NodeKind.superExpr) {
        let key: u8 = 0;
        if (target.kind == NodeKind.member) {
          const atom = this.propertyNameAtom(in parser, inout runtime, target.nameStart, target.nameLength);
          key = this.emitKey(atom);
        } else {
          key = this.compileExpr(in parser, inout runtime, target.right);
        }
        const value = this.compileExpr(in parser, inout runtime, n.right);
        this.emit(instAB(Op.storeSuper, key, value));
        return value;
      }
      if (target.kind == NodeKind.member && n.op == TokenKind.eq && this.isPrivateName(in parser, target.nameStart, target.nameLength)) {
        const object = this.compileExpr(in parser, inout runtime, target.left);
        const key = this.privateKeyReg(in parser, target.nameStart, target.nameLength);
        const value = this.compileExpr(in parser, inout runtime, n.right);
        this.emit(instABC(Op.storeElem, object, key, value));
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
      this.emitFunctionValue(in parser, inout runtime, node, dst, contextualStart, contextualLength, contextualPrefix);
      return dst;
    }
    if (k == NodeKind.call && this.hasSpreadArgument(in parser, node)) {
      // f(...args) / o.m(...args): the arguments gathered into an array.
      const callee = parser.ast.node(n.left);
      if (callee.kind == NodeKind.superExpr) {
        const argsReg = this.allocReg();
        this.compileArgumentsArray(in parser, inout runtime, node, argsReg);
        const dst = this.allocReg();
        this.emit(instAB(Op.spreadSuperCall, dst, argsReg));
        this.emitThisToEnv();
        this.emitFieldInitializers(in parser, inout runtime);
        return dst;
      }
      const base = this.allocReg();
      if (callee.kind == NodeKind.member || callee.kind == NodeKind.computed) {
        this.allocReg();
        const argsReg = this.allocReg();
        this.emitCalleeAndReceiver(in parser, inout runtime, callee, base);
        this.nextReg = base + 3;
        this.compileArgumentsArray(in parser, inout runtime, node, argsReg);
        this.emit(instABC(Op.spreadMethodInvoke, base, base, 0));
        this.nextReg = base + 1;
        return base;
      }
      const argsReg = this.allocReg();
      const calleeReg = this.compileExpr(in parser, inout runtime, n.left);
      if (calleeReg != base) this.emit(instAB(Op.mov, base, calleeReg));
      this.nextReg = base + 2;
      this.compileArgumentsArray(in parser, inout runtime, node, argsReg);
      this.emit(instABC(Op.spreadInvoke, base, base, 0));
      this.nextReg = base + 1;
      return base;
    }
    if (k == NodeKind.call) {
      const callee = parser.ast.node(n.left);
      const argCount = n.childrenCount;
      if (argCount > 255) {
        this.hadError = true;
        return 0;
      }
      if (callee.kind == NodeKind.superExpr) {
        // super(...): the arguments above base, the constructed object
        // into base, then the instance fields.
        const base = this.allocReg();
        let slot: u32 = 0;
        while (slot < argCount) {
          this.allocReg();
          slot = slot + 1;
        }
        let a: u32 = 0;
        while (a < argCount) {
          const argReg = this.compileExpr(in parser, inout runtime, parser.ast.child(node, a));
          if (argReg != base + 1 + u8(a)) this.emit(instAB(Op.mov, base + 1 + u8(a), argReg));
          this.nextReg = base + u8(1 + argCount);
          a = a + 1;
        }
        this.emit(instABC(Op.superCall, base, base + 1, u8(argCount)));
        this.nextReg = base + 1;
        this.emitThisToEnv();
        this.emitFieldInitializers(in parser, inout runtime);
        return base;
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
        this.emitCalleeAndReceiver(in parser, inout runtime, callee, base);
        this.nextReg = base + u8(2 + argCount);
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
    // The case block is one scope, open from the case tests on. Control
    // can enter it past a declaration, so its bindings are always checked.
    const savedFixed = this.fixedRegs;
    if (discriminant + 1 > this.fixedRegs) this.fixedRegs = discriminant + 1;
    let mark = this.openScope();
    let caseStatements = Array<u32>();
    let c: u32 = 0;
    while (c < count) {
      const clauseIndex = parser.ast.child(node, c);
      const clause = parser.ast.node(clauseIndex);
      let statement: u32 = 0;
      while (statement < clause.childrenCount) {
        const statementIndex = parser.ast.child(clauseIndex, statement);
        caseStatements.push(statementIndex);
        this.declareStatementLexicals(in parser, inout runtime, statementIndex, true, node, false, true);
        statement = statement + 1;
      }
      c = c + 1;
    }
    this.checkBlockRedeclarations(in parser, node, in caseStatements);
    this.enterScope(inout mark);
    this.hoistBlockFunctions(in parser, inout runtime, in caseStatements);
    if (this.hadError) return;
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
        this.resetTemps();
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
    this.closeScope(in mark);
    this.fixedRegs = savedFixed;
    this.resetTemps();
  }

  // --- for-in / for-of ---
  //
  // for-in walks an array of keys prepared up front; for-of drives the
  // iterator protocol. The loop's bookkeeping registers sit below the
  // temporaries watermark so statement resets leave them alone.
  function compileForEach(inout this, in parser: Parser, inout runtime: Runtime, node: u32): void {
    const n = parser.ast.node(node);
    if (n.kind == NodeKind.forOfStmt) {
      this.compileForOf(in parser, inout runtime, node);
      return;
    }
    this.resetCompletion();
    // A lexical head binding is declared once, scoped to the statement,
    // ahead of the sequence (which cannot read it: a hole until each
    // iteration binds it).
    let mark = this.openScope();
    const binding = parser.ast.node(n.left);
    let lexical: i32 = -1;
    if (binding.kind == NodeKind.varDecl && binding.op != TokenKind.kwVar) {
      this.checkHeadRedeclarations(in parser, node, n.left);
      this.declareLexicalHead(in parser, inout runtime, n.left, n.right, 4294967295);
      const decl = parser.ast.node(parser.ast.child(n.left, 0));
      if (decl.nameLength > 0) lexical = i32(this.locals.length - 1);
    }
    const captures = this.headCaptures(in parser, n.left);
    let saved = Array<i32>();
    let iterReg: u8 = 0;
    if (captures.length > 0) iterReg = this.enterIterationEnv(in captures, inout saved);
    this.emitHoles(mark.locals);
    const source = this.compileExpr(in parser, inout runtime, n.right);
    const sequence = this.allocReg();
    this.emit(instABC(Op.iterPrepare, sequence, source, 0));
    const length = this.allocReg();
    const index = this.allocReg();
    this.emit(instAI16(Op.loadInt, index, 0));
    if (index + 1 > this.fixedRegs) this.fixedRegs = index + 1;
    const loopTop = u32(this.code.length);
    this.loopPush(true);
    if (captures.length > 0) this.renewIterationEnv(iterReg, captures.length);
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
    if (captures.length > 0) this.leaveIterationEnv(iterReg, in captures, in saved);
    this.closeScope(in mark);
  }

  // for-of: GetIterator once, then IteratorStep each round; the head
  // binding takes each value; break, continue past it, and return close
  // the iterator.
  function compileForOf(inout this, in parser: Parser, inout runtime: Runtime, node: u32): void {
    const n = parser.ast.node(node);
    // `for await`: the async iterator, each next() awaited.
    const isAwait = n.boolValue;
    this.resetCompletion();
    let mark = this.openScope();
    const binding = parser.ast.node(n.left);
    let lexical: i32 = -1;
    if (binding.kind == NodeKind.varDecl && binding.op != TokenKind.kwVar) {
      this.checkHeadRedeclarations(in parser, node, n.left);
      this.declareLexicalHead(in parser, inout runtime, n.left, n.right, 4294967295);
      const decl = parser.ast.node(parser.ast.child(n.left, 0));
      if (decl.nameLength > 0) lexical = i32(this.locals.length - 1);
    }
    const captures = this.headCaptures(in parser, n.left);
    let saved = Array<i32>();
    let iterReg: u8 = 0;
    if (captures.length > 0) iterReg = this.enterIterationEnv(in captures, inout saved);
    this.emitHoles(mark.locals);
    const source = this.compileExpr(in parser, inout runtime, n.right);
    const iterator = this.allocReg();
    this.emit(instAB(isAwait ? Op.iterGetAsync : Op.iterGet, iterator, source));
    const done = this.allocReg();
    const value = this.allocReg();
    const result = this.allocReg();
    if (result + 1 > this.fixedRegs) this.fixedRegs = result + 1;
    const loopTop = u32(this.code.length);
    this.loopPush(true);
    const top = this.loops.length - 1;
    this.pushRegion(REGION_ITERATOR, NO_NODE, iterator, done);
    this.loops[top].continueRegions = this.regionDepth;
    this.loopSetContinue(loopTop);
    if (captures.length > 0) this.renewIterationEnv(iterReg, captures.length);
    if (isAwait) {
      this.emitAsyncIteratorStep(inout runtime, iterator, value, false, result);
      const doneText: String = "done";
      const doneAtom = runtime.atomOf(in doneText);
      this.emit(instABC(Op.loadProp, done, result, this.nameSlot(doneAtom)));
    } else {
      this.emit(instABC(Op.iterStep, value, iterator, done));
    }
    const exit = this.emit(instAI16(Op.jmpIfTrue, done, 0));
    if (isAwait) {
      const valueText: String = "value";
      const valueAtom = runtime.atomOf(in valueText);
      this.emit(instABC(Op.loadProp, value, result, this.nameSlot(valueAtom)));
    }
    // A throw from the binding or the body closes the iterator (quietly)
    // and continues unwinding.
    const thrownReg = this.allocReg();
    if (thrownReg + 1 > this.fixedRegs) this.fixedRegs = thrownReg + 1;
    const enter = this.emitEnterTry(thrownReg);
    this.assignLoopBinding(in parser, inout runtime, n.left, lexical, value);
    this.resetTemps();
    this.compileStmt(in parser, inout runtime, parser.ast.child(node, 0));
    this.emitLeaveTry();
    this.emitJumpBack(loopTop);
    this.patchJump(enter);
    this.emit(instAB(Op.iterCloseQuiet, iterator, done));
    this.emit(instA(Op.throwOp, thrownReg));
    this.patchJump(exit);
    this.popRegion();
    this.loopPop();
    if (captures.length > 0) this.leaveIterationEnv(iterReg, in captures, in saved);
    this.closeScope(in mark);
  }

  // Store the current element into a for-in / for-of head: a declared
  // binding, an identifier, or a property.
  function assignLoopBinding(inout this, in parser: Parser, inout runtime: Runtime, target: u32, lexical: i32, value: u8): void {
    const binding = parser.ast.node(target);
    if (binding.kind == NodeKind.varDecl) {
      if (lexical >= 0) {
        this.initLocal(usize(lexical), value);
        return;
      }
      const decl = parser.ast.node(parser.ast.child(target, 0));
      if (decl.nameLength == 0) {
        const wasInitializing = this.initializing;
        if (binding.op != TokenKind.kwVar) this.initializing = true;
        this.destructure(in parser, inout runtime, decl.third, value);
        this.initializing = wasInitializing;
        return;
      }
      this.storeIdent(in parser, inout runtime, decl, value);
      return;
    }
    if (binding.kind == NodeKind.identExpr) {
      this.storeIdent(in parser, inout runtime, binding, value);
      return;
    }
    if (binding.kind == NodeKind.arrayPattern || binding.kind == NodeKind.objectPattern) {
      this.destructure(in parser, inout runtime, target, value);
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

  // --- Destructuring ---
  //
  // A pattern binds each of its targets from a source register. In
  // declaration form every target is an identifier (or a nested pattern);
  // in assignment form a target may also be a property.

  // Bind one target -- identifier, property, or nested pattern -- to the
  // value in `value`.
  function bindTarget(inout this, in parser: Parser, inout runtime: Runtime, target: u32, value: u8): void {
    const n = parser.ast.node(target);
    if (n.kind == NodeKind.identExpr) {
      if (this.initializing) {
        const local = this.findLocal(in parser, n.nameStart, n.nameLength);
        if (local >= 0) {
          this.initLocal(usize(local), value);
          return;
        }
      }
      this.storeIdent(in parser, inout runtime, n, value);
      return;
    }
    if (n.kind == NodeKind.arrayPattern || n.kind == NodeKind.objectPattern) {
      this.destructure(in parser, inout runtime, target, value);
      return;
    }
    if (n.kind == NodeKind.member) {
      const object = this.compileExpr(in parser, inout runtime, n.left);
      if (this.isPrivateName(in parser, n.nameStart, n.nameLength)) {
        const key = this.privateKeyReg(in parser, n.nameStart, n.nameLength);
        this.emit(instABC(Op.storeElem, object, key, value));
        return;
      }
      const atom = this.propertyNameAtom(in parser, inout runtime, n.nameStart, n.nameLength);
      const slot = this.nameSlot(atom);
      this.emit(instABC(Op.storeProp, object, slot, value));
      return;
    }
    if (n.kind == NodeKind.computed) {
      const object = this.compileExpr(in parser, inout runtime, n.left);
      const key = this.compileExpr(in parser, inout runtime, n.right);
      this.emit(instABC(Op.storeElem, object, key, value));
      return;
    }
    this.hadError = true;
  }

  // Apply a default: when the value is undefined, evaluate the initializer
  // into the same register.
  function applyDefault(inout this, in parser: Parser, inout runtime: Runtime, initializer: u32, value: u8, target: u32): void {
    if (initializer == NO_NODE) return;
    const undefinedReg = this.allocReg();
    this.emit(instA(Op.loadUndefined, undefinedReg));
    const test = this.allocReg();
    this.emit(instABC(Op.cmpStrictEq, test, value, undefinedReg));
    const skip = this.emit(instAI16(Op.jmpIfFalse, test, 0));
    if (target != NO_NODE) {
      const targetNode = parser.ast.node(target);
      if (targetNode.kind == NodeKind.identExpr) this.nameNext(targetNode.nameStart, targetNode.nameLength, 0);
    }
    const wasInitializing = this.initializing;
    this.initializing = false;
    const init = this.compileExpr(in parser, inout runtime, initializer);
    this.initializing = wasInitializing;
    if (init != value) this.emit(instAB(Op.mov, value, init));
    this.patchJump(skip);
  }

  function destructure(inout this, in parser: Parser, inout runtime: Runtime, pattern: u32, source: u8): void {
    const n = parser.ast.node(pattern);
    if (n.kind == NodeKind.objectPattern) {
      this.destructureObject(in parser, inout runtime, pattern, source);
    } else {
      this.destructureArray(in parser, inout runtime, pattern, source);
    }
  }

  function destructureObject(inout this, in parser: Parser, inout runtime: Runtime, pattern: u32, source: u8): void {
    const n = parser.ast.node(pattern);
    this.emit(instA(Op.assertCoercible, source));
    // With a rest entry, every key taken before it is collected in an
    // array for the rest to leave out -- computed keys included.
    let hasRest = false;
    let scan: u32 = 0;
    while (scan < n.childrenCount) {
      if (parser.ast.node(parser.ast.child(pattern, scan)).boolValue) hasRest = true;
      scan = scan + 1;
    }
    let keys: u8 = 0;
    if (hasRest) {
      keys = this.allocReg();
      this.emit(instABC(Op.newArray, keys, 0, 0));
    }
    let i: u32 = 0;
    while (i < n.childrenCount) {
      const entryIndex = parser.ast.child(pattern, i);
      const entry = parser.ast.node(entryIndex);
      const watermark = this.nextReg;
      if (entry.boolValue) {
        // { ...rest }
        const rest = this.allocReg();
        this.emit(instABC(Op.objectRest, rest, source, keys));
        this.bindTarget(in parser, inout runtime, entry.left, rest);
        this.nextReg = watermark;
        i = i + 1;
        continue;
      }
      const value = this.allocReg();
      if (entry.third != NO_NODE) {
        const key = this.compileExpr(in parser, inout runtime, entry.third);
        this.emit(instABC(Op.loadElem, value, source, key));
        if (hasRest) this.emit(instAB(Op.arrayPush, keys, key));
      } else {
        const atom = this.propertyNameAtom(in parser, inout runtime, entry.nameStart, entry.nameLength);
        const slot = this.nameSlot(atom);
        this.emit(instABC(Op.loadProp, value, source, slot));
        if (hasRest) {
          const keyReg = this.emitKey(atom);
          this.emit(instAB(Op.arrayPush, keys, keyReg));
        }
      }
      this.applyDefault(in parser, inout runtime, entry.right, value, entry.left);
      this.bindTarget(in parser, inout runtime, entry.left, value);
      this.nextReg = watermark;
      i = i + 1;
    }
  }

  function destructureArray(inout this, in parser: Parser, inout runtime: Runtime, pattern: u32, source: u8): void {
    const n = parser.ast.node(pattern);
    const iterator = this.allocReg();
    this.emit(instAB(Op.iterGet, iterator, source));
    const done = this.allocReg();
    this.emit(instA(Op.loadFalse, done));
    let i: u32 = 0;
    while (i < n.childrenCount) {
      const entryIndex = parser.ast.child(pattern, i);
      const entry = parser.ast.node(entryIndex);
      const watermark = this.nextReg;
      const value = this.allocReg();
      if (entry.boolValue) {
        this.emit(instABC(Op.iterRestCollect, value, iterator, done));
        this.bindTarget(in parser, inout runtime, entry.left, value);
        this.nextReg = watermark;
        i = i + 1;
        continue;
      }
      // A step past the end leaves the value undefined and done true.
      this.emit(instA(Op.loadUndefined, value));
      const stepped = this.emit(instAI16(Op.jmpIfTrue, done, 0));
      this.emit(instABC(Op.iterStep, value, iterator, done));
      this.patchJump(stepped);
      if (entry.left != NO_NODE) {
        this.applyDefault(in parser, inout runtime, entry.right, value, entry.left);
        this.bindTarget(in parser, inout runtime, entry.left, value);
      }
      this.nextReg = watermark;
      i = i + 1;
    }
    this.emit(instAB(Op.iterClose, iterator, done));
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
    const hasCatch = n.right != NO_NODE;
    const hasFinally = n.third != NO_NODE;
    let catchReg: u8 = 0;
    if (hasCatch) {
      catchReg = this.allocReg();
      if (catchReg + 1 > this.fixedRegs) this.fixedRegs = catchReg + 1;
    }
    if (!hasFinally) {
      const enter = this.emitEnterTry(catchReg);
      this.compileStmt(in parser, inout runtime, n.left);
      this.emitLeaveTry();
      const skip = this.emit(instI16(Op.jmp, 0));
      this.patchJump(enter);
      this.resetCompletion();
      this.compileCatch(in parser, inout runtime, n, catchReg, node);
      this.patchJump(skip);
      return;
    }
    const pendingReg = this.allocReg();
    const flagReg = this.allocReg();
    if (flagReg + 1 > this.fixedRegs) this.fixedRegs = flagReg + 1;
    this.emit(instA(Op.loadFalse, flagReg));
    this.pushRegion(REGION_FINALLY, n.third, 0, 0);
    const outerEnter = this.emit(instAI16(Op.enterTry, pendingReg, 0));
    if (hasCatch) {
      const innerEnter = this.emitEnterTry(catchReg);
      this.compileStmt(in parser, inout runtime, n.left);
      this.emitLeaveTry();
      const skipCatch = this.emit(instI16(Op.jmp, 0));
      this.patchJump(innerEnter);
      this.resetCompletion();
      this.compileCatch(in parser, inout runtime, n, catchReg, node);
      this.patchJump(skipCatch);
    } else {
      this.compileStmt(in parser, inout runtime, n.left);
    }
    this.emitLeaveTry();
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

  // The catch block, with its parameter -- an identifier or a pattern --
  // bound from the catch register.
  function compileCatch(inout this, in parser: Parser, inout runtime: Runtime, n: AstNode, catchReg: u8, node: u32): void {
    // The parameter's names: no duplicates, not redeclared lexically in
    // the block, and (a destructured parameter) not with var either.
    let parameterNames = Array<NameRef>();
    if (n.nameLength > 0) pushName(inout parameterNames, n.nameStart, n.nameLength, false);
    if (n.childrenCount > 0) pushPatternNames(in parser, parser.ast.child(node, 0), inout parameterNames);
    let blockLexicals = Array<NameRef>();
    const body = parser.ast.node(n.right);
    if (body.kind == NodeKind.blockStmt) {
      let b: u32 = 0;
      while (b < body.childrenCount) {
        pushLexicalNames(in parser, parser.ast.child(n.right, b), true, inout blockLexicals);
        b = b + 1;
      }
    }
    if (n.childrenCount > 0) collectVarNames(in parser, n.right, inout blockLexicals);
    this.checkRedeclarations(in parser, in parameterNames, in blockLexicals);
    let mark = this.openScope();
    let bound: i32 = -1;
    if (n.nameLength > 0) bound = i32(this.bindLocal(n.nameStart, n.nameLength, catchReg));
    let pattern: u32 = NO_NODE;
    if (n.childrenCount > 0) {
      pattern = parser.ast.child(node, 0);
      this.collectPatternLocals(in parser, pattern);
    }
    this.enterScope(inout mark);
    if (bound >= 0) {
      const paramSlot = this.locals[usize(bound)].envSlot;
      if (paramSlot >= 0) this.emit(instABC(Op.storeEnvSlot, catchReg, 0, u8(paramSlot)));
    }
    if (pattern != NO_NODE) {
      this.destructure(in parser, inout runtime, pattern, catchReg);
      this.resetTemps();
    }
    this.compileStmt(in parser, inout runtime, n.right);
    this.closeScope(in mark);
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
          // A pattern: its names are already bound (hoisted var, or
          // lexical locals declared here); the initializer is required.
          if (decl.third == NO_NODE || decl.left == NO_NODE) {
            this.hadError = true;
            return;
          }
          const value = this.compileExpr(in parser, inout runtime, decl.left);
          const wasInitializing = this.initializing;
          if (n.op != TokenKind.kwVar) this.initializing = true;
          this.destructure(in parser, inout runtime, decl.third, value);
          this.initializing = wasInitializing;
          this.resetTemps();
          i = i + 1;
          continue;
        }
        if (n.op == TokenKind.kwVar && this.isFunction) {
          // A var inside a function is one of its locals.
          const local = this.findLocal(in parser, decl.nameStart, decl.nameLength);
          if (local < 0) {
            this.hadError = true;
            return;
          }
          if (decl.left != NO_NODE) {
            this.nameNext(decl.nameStart, decl.nameLength, 0);
            const value = this.compileExpr(in parser, inout runtime, decl.left);
            this.storeLocal(usize(local), value);
          }
        } else if (n.op == TokenKind.kwVar) {
          // Script-mode `var` is a global binding.
          const slot = runtime.globalSlotBytes(globalNameBytes(in parser, decl.nameStart, decl.nameLength));
          if (decl.left != NO_NODE) {
            this.nameNext(decl.nameStart, decl.nameLength, 0);
            const value = this.compileExpr(in parser, inout runtime, decl.left);
            this.emit(instAU16(Op.defineGlobal, value, slot));
          } else {
            const undefinedReg = this.allocReg();
            this.emit(instA(Op.loadUndefined, undefinedReg));
            this.emit(instAU16(Op.defineGlobal, undefinedReg, slot));
          }
        } else {
          // let / const: declared when its scope opened; this is its
          // initialization.
          const local = this.findLocal(in parser, decl.nameStart, decl.nameLength);
          if (local < 0) {
            this.hadError = true;
            return;
          }
          if (decl.left != NO_NODE) {
            this.nameNext(decl.nameStart, decl.nameLength, 0);
            const value = this.compileExpr(in parser, inout runtime, decl.left);
            this.initLocal(usize(local), value);
          } else {
            const undefinedReg = this.allocReg();
            this.emit(instA(Op.loadUndefined, undefinedReg));
            this.initLocal(usize(local), undefinedReg);
          }
        }
        this.resetTemps();
        i = i + 1;
      }
      return;
    }
    if (k == NodeKind.emptyStmt) return;
    if (k == NodeKind.functionDecl) {
      const blockLocal = this.findLocal(in parser, n.nameStart, n.nameLength);
      if (blockLocal >= 0 && this.locals[usize(blockLocal)].blockFunction) {
        // Created when its block opened. Sloppy code also assigns the
        // function-scoped binding (or global) of the name here.
        if (this.strict) return;
        if (this.hasLexicalConflict(in parser, n.nameStart, n.nameLength, usize(blockLocal))) return;
        const value = this.allocReg();
        this.loadLocal(usize(blockLocal), value);
        if (this.isFunction) {
          const varLocal = this.findVarLocal(in parser, n.nameStart, n.nameLength);
          if (varLocal >= 0) this.storeLocal(usize(varLocal), value);
        } else {
          const slot = runtime.defineGlobalSlotBytes(globalNameBytes(in parser, n.nameStart, n.nameLength));
          this.emit(instAU16(Op.defineGlobal, value, slot));
        }
        this.resetTemps();
        return;
      }
      const r = this.allocReg();
      this.emitFunctionValue(in parser, inout runtime, node, r, 0, 0, 0);
      if (this.hadError) return;
      if (this.isFunction) {
        const local = this.findLocal(in parser, n.nameStart, n.nameLength);
        if (local < 0) {
          this.hadError = true;
          return;
        }
        this.storeLocal(usize(local), r);
      } else {
        const slot = runtime.defineGlobalSlotBytes(globalNameBytes(in parser, n.nameStart, n.nameLength));
        this.emit(instAU16(Op.defineGlobal, r, slot));
      }
      this.resetTemps();
      return;
    }
    if (k == NodeKind.classDecl) {
      const r = this.compileClass(in parser, inout runtime, node, 0, 0);
      if (this.hadError) return;
      // A lexical binding of its scope; at a script's top level, a global.
      const local = this.findLocal(in parser, n.nameStart, n.nameLength);
      if (local >= 0) {
        this.initLocal(usize(local), r);
      } else if (this.isFunction) {
        this.hadError = true;
        return;
      } else {
        const slot = runtime.defineGlobalSlotBytes(globalNameBytes(in parser, n.nameStart, n.nameLength));
        this.emit(instAU16(Op.defineGlobal, r, slot));
      }
      this.resetTemps();
      return;
    }
    if (k == NodeKind.returnStmt) {
      let r: u8 = 0;
      if (n.left != NO_NODE) {
        r = this.compileExpr(in parser, inout runtime, n.left);
        if (this.isAsyncGeneratorBody) {
          // An async generator awaits what it returns, before its
          // finally blocks run.
          const awaited = this.allocReg();
          this.emit(instAB(Op.awaitOp, awaited, r));
          r = awaited;
        }
      } else {
        r = this.allocReg();
        this.emit(instA(Op.loadUndefined, r));
      }
      if (this.regionDepth > 0) {
        // Leave every region first, with the value kept safe from the
        // temporaries a finally block uses.
        const savedFixed = this.fixedRegs;
        if (r + 1 > this.fixedRegs) this.fixedRegs = r + 1;
        this.emitUnwind(in parser, inout runtime, 0);
        this.fixedRegs = savedFixed;
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
      // Captured lexical head bindings get a fresh environment per
      // iteration: one for the initializer, a copy before the first
      // test, and a copy after each body before the update.
      let mark = this.openScope();
      let lexicalHead = false;
      if (n.left != NO_NODE) {
        const head = parser.ast.node(n.left);
        lexicalHead = head.kind == NodeKind.varDecl && head.op != TokenKind.kwVar;
      }
      if (lexicalHead) {
        this.checkHeadRedeclarations(in parser, node, n.left);
        this.declareLexicalHead(in parser, inout runtime, n.left, n.left, 0);
      }
      const captures = this.headCaptures(in parser, n.left);
      let saved = Array<i32>();
      let iterReg: u8 = 0;
      if (captures.length > 0) iterReg = this.enterIterationEnv(in captures, inout saved);
      this.emitHoles(mark.locals);
      if (lexicalHead) {
        this.initializeLexicalHead(in parser, inout runtime, n.left);
      } else if (n.left != NO_NODE) {
        this.compileStmtOrExpr(in parser, inout runtime, n.left);
      }
      if (this.hadError) return;
      if (captures.length > 0) this.renewIterationEnv(iterReg, captures.length);
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
      if (captures.length > 0) this.renewIterationEnv(iterReg, captures.length);
      if (n.third != NO_NODE) {
        const unused = this.compileExpr(in parser, inout runtime, n.third);
        this.resetTemps();
      }
      this.emitJumpBack(loopTop);
      if (jumpExit >= 0) this.patchJump(u32(jumpExit));
      this.loopPop();
      if (captures.length > 0) this.leaveIterationEnv(iterReg, in captures, in saved);
      this.closeScope(in mark);
      return;
    }
    if (k == NodeKind.breakStmt) {
      if (this.loops.length == 0) {
        this.hadError = true;
        return;
      }
      let target = i32(this.loops.length) - 1;
      if (n.nameLength > 0) target = this.findLabeledFrame(in parser, n.nameStart, n.nameLength);
      if (target < 0) {
        this.hadError = true;
        return;
      }
      const regionsAtEntry = this.loops[usize(target)].regionsAtEntry;
      this.emitUnwind(in parser, inout runtime, regionsAtEntry);
      const targetEnvs = this.loops[usize(target)].openEnvs;
      this.emitLeaveEnvs(targetEnvs);
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
        let walk = i32(this.loops.length) - 1;
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
      const continueRegions = this.loops[frame].continueRegions;
      this.emitUnwind(in parser, inout runtime, continueRegions);
      const targetEnvs = this.loops[frame].openEnvs;
      this.emitLeaveEnvs(targetEnvs);
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
      let statements = Array<u32>();
      let c: u32 = 0;
      while (c < n.childrenCount) {
        statements.push(parser.ast.child(node, c));
        c = c + 1;
      }
      this.checkBlockRedeclarations(in parser, node, in statements);
      const scoped = this.hasLexicalDeclarations(in parser, node);
      let mark = this.openScope();
      if (scoped) {
        this.declareBlockLexicals(in parser, inout runtime, node, false, false, true);
        this.enterScope(inout mark);
        this.hoistBlockFunctions(in parser, inout runtime, in statements);
        if (this.hadError) return;
      }
      let i: u32 = 0;
      while (i < n.childrenCount) {
        this.compileStmt(in parser, inout runtime, parser.ast.child(node, i));
        i = i + 1;
      }
      if (scoped) this.closeScope(in mark);
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
  return k == NodeKind.withStmt || k == NodeKind.importDecl || k == NodeKind.exportDecl;
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

// The units of a string literal's body: escapes decoded (a \u escape may
// name a lone surrogate), source text decoded from UTF-8, a byte that is
// not UTF-8 kept as the unit with its value.
function decodeStringBody(in parser: Parser, rawStart: u32, rawEnd: u32): Array<u16> {
  const rawLength: u32 = rawEnd > rawStart ? rawEnd - rawStart : 0;
  let bytes = Array<u16>();
  let i: u32 = 0;
  while (i < rawLength) {
    const ch = parser.source[usize(rawStart + i)];
    if (ch == B_BACKSLASH && i + 1 < rawLength) {
      const next = parser.source[usize(rawStart + i + 1)];
      if (next == B_LF) {
        i = i + 2;
        continue;
      }
      if (next == B_CR) {
        if (i + 2 < rawLength && parser.source[usize(rawStart + i + 2)] == B_LF) {
          i = i + 3;
        } else {
          i = i + 2;
        }
        continue;
      }
      if (next == B_x && i + 3 < rawLength) {
        const h1 = hexValue(parser.source[usize(rawStart + i + 2)]);
        const h2 = hexValue(parser.source[usize(rawStart + i + 3)]);
        if (h1 >= 0 && h2 >= 0) {
          bytes.push(u16((h1 << 4) | h2));
          i = i + 4;
          continue;
        }
      }
      if (next == B_u) {
        let codePoint: u32 = 0;
        let consumed: u32 = 0;
        if (i + 2 < rawLength && parser.source[usize(rawStart + i + 2)] == B_LBRACE) {
          let p: u32 = i + 3;
          let valid = true;
          while (p < rawLength) {
            const cc = parser.source[usize(rawStart + p)];
            if (cc == B_RBRACE) break;
            const d = hexValue(cc);
            if (d < 0) {
              valid = false;
              break;
            }
            codePoint = codePoint.wrappingMultiply(16) + u32(d);
            p = p + 1;
          }
          if (valid && p < rawLength && parser.source[usize(rawStart + p)] == B_RBRACE) {
            consumed = p - i + 1;
          }
        } else if (i + 5 < rawLength) {
          const h1 = hexValue(parser.source[usize(rawStart + i + 2)]);
          const h2 = hexValue(parser.source[usize(rawStart + i + 3)]);
          const h3 = hexValue(parser.source[usize(rawStart + i + 4)]);
          const h4 = hexValue(parser.source[usize(rawStart + i + 5)]);
          if (h1 >= 0 && h2 >= 0 && h3 >= 0 && h4 >= 0) {
            codePoint = u32((h1 << 12) | (h2 << 8) | (h3 << 4) | h4);
            consumed = 6;
          }
        }
        if (consumed > 0) {
          pushCodePoint(inout bytes, codePoint);
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
      bytes.push(u16(mapped));
      i = i + 2;
    } else if (ch < 0x80) {
      bytes.push(u16(ch));
      i = i + 1;
    } else {
      const at = usize(rawStart + i);
      let sequence = wtf8Length(in parser.source, at);
      if (sequence == 0 || usize(rawStart + rawLength) < at + sequence) {
        bytes.push(u16(ch));
        i = i + 1;
      } else {
        let value: u32 = u32(ch) & u32(0x3F >> (sequence - 1));
        let k: usize = 1;
        while (k < sequence) {
          value = (value << 6) | u32(parser.source[at + k] & 0x3F);
          k = k + 1;
        }
        pushCodePoint(inout bytes, value);
        i = i + u32(sequence);
      }
    }
  }
  return bytes;
}

// --- Functions ------------------------------------------------------------

// Compile a function body into the runtime's function table; returns its
// index or -1. Mirrors the reference: parameters first as locals, then the
// body's own bindings, defaults evaluated at entry, function declarations
// compiled before other statements, an implicit undefined return.
function compileFunction(in parser: Parser, inout runtime: Runtime, node: u32, in enclosingScopes: Array<Scope>, in enclosingLocals: Array<Local>, enclosingHasEnv: boolean, enclosingOpenEnvs: u32, enclosingIsArrow: boolean, enclosingThisSlot: i32, enclosingStrict: boolean, contextualStart: u32, contextualLength: u32, namePrefix: u32, role: u32, fieldCount: u32): CompiledFunction {
  const n = parser.ast.node(node);
  // A function expression written with a name binds it inside itself. A
  // name the parser attached to a method or accessor does not.
  const writtenName = n.kind == NodeKind.functionExpr && n.nameLength > 0 && parser.sliceEquals(n.start, 8, "function");
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
    scopes.push(Scope({ names: move names, hasEnv: enclosingScopes[i].hasEnv, openEnvs: enclosingScopes[i].openEnvs, isArrow: enclosingScopes[i].isArrow, thisSlot: enclosingScopes[i].thisSlot }));
    i = i + 1;
  }
  let parentNames = Array<Local>();
  i = 0;
  while (i < enclosingLocals.length) {
    parentNames.push(enclosingLocals[i]);
    i = i + 1;
  }
  scopes.push(Scope({ names: move parentNames, hasEnv: enclosingHasEnv, openEnvs: enclosingOpenEnvs, isArrow: enclosingIsArrow, thisSlot: enclosingThisSlot }));
  const scopeCount = scopes.length;
  const failed = CompiledFunction({ index: -1, minOuterScope: scopeCount });
  let compiler = Compiler({
    code: Array<Inst>(), constants: Array<Value>(), nextReg: 0, maxReg: 0, fixedRegs: 0, openEnvs: 0, envRegs: Array<u8>(), initializing: false,
    locals: Array<Local>(), outerScopes: move scopes, capturedNames: Array<Local>(),
    hasEnv: false, envSize: 0, minOuterScope: scopeCount, lastExprReg: -1, isFunction: true,
    hadError: false, strict: enclosingStrict || role != 0, loops: Array<LoopFrame>(),
    pendingLabelStart: 0, pendingLabelLength: 0, regions: Array<Region>(), regionDepth: 0,
    pendingNameStart: 0, pendingNameLength: 0, pendingNamePrefix: 0, thisReg: -1, isArrow: false, derivedCtor: false, thisEnvSlot: -1, fieldSource: NO_NODE, fieldCount: 0, isAsyncBody: false, isAsyncGeneratorBody: false, propertyNames: Array<u32>(),
  });
  if (!compiler.strict && n.left != NO_NODE && parser.bodyHasUseStrictDirective(n.left)) compiler.strict = true;
  compiler.isArrow = n.kind == NodeKind.arrowFunc;
  compiler.derivedCtor = role == 2;

  // Parameters: plain identifiers only for now (patterns and rest need
  // objects and arrays).
  let paramCount: u32 = 0;
  let restIndex: i32 = -1;
  let p: u32 = 0;
  while (p < n.childrenCount) {
    const param = parser.ast.node(parser.ast.child(node, p));
    if (param.kind == NodeKind.restParam) {
      // `...rest` binds the arguments past the plain parameters; it is
      // filled at entry from the frame's actual arguments.
      const inner = parser.ast.node(param.left);
      if (inner.kind != NodeKind.identExpr || inner.nameLength == 0) return failed;
      compiler.addLocal(inner.nameStart, inner.nameLength);
      restIndex = i32(compiler.locals.length - 1);
      p = p + 1;
      continue;
    }
    if (parameterPattern(in parser, parser.ast.child(node, p)) != NO_NODE) {
      // A pattern parameter: the argument lands in a register with no
      // name; the pattern's own names are locals bound at entry.
      const reg = compiler.allocReg();
      compiler.locals.push(Local({ nameStart: 0, nameLength: 0, reg: reg, envSlot: -1, envDepth: 0, captured: false, isConst: false, initialized: true, alwaysCheck: false, needsHole: false, nameConst: -1, blockFunction: false, lexical: false }));
      paramCount = paramCount + 1;
      p = p + 1;
      continue;
    }
    if (param.kind != NodeKind.identExpr || param.nameLength == 0) return failed;
    // Parameters arrive in the first registers; a captured one is copied
    // into the environment once it exists.
    const reg = compiler.allocReg();
    compiler.locals.push(Local({ nameStart: param.nameStart, nameLength: param.nameLength, reg: reg, envSlot: -1, envDepth: 0, captured: false, isConst: false, initialized: true, alwaysCheck: false, needsHole: false, nameConst: -1, blockFunction: false, lexical: false }));
    paramCount = paramCount + 1;
    p = p + 1;
  }
  // The names inside pattern parameters.
  const patternNamesStart = compiler.locals.length;
  p = 0;
  while (p < n.childrenCount) {
    const pattern = parameterPattern(in parser, parser.ast.child(node, p));
    if (pattern != NO_NODE) compiler.collectPatternLocals(in parser, pattern);
    p = p + 1;
  }
  const patternNamesEnd = compiler.locals.length;
  // A named function expression binds its own name.
  const index = runtime.reserveFunction();
  let selfReg: i32 = -1;
  let selfLocal: i32 = -1;
  if (writtenName) {
    selfReg = i32(compiler.addLocal(n.nameStart, n.nameLength));
    selfLocal = i32(compiler.locals.length - 1);
  }
  if (n.left != NO_NODE) compiler.collectBodyLocals(in parser, n.left);
  if (n.left != NO_NODE && bodyUsesThis(in parser, n.left)) compiler.thisReg = i32(compiler.allocReg());
  // `arguments`, when the body (or an arrow inside it) reads it and no
  // parameter or declaration takes the name, is a local built at entry.
  let argumentsIndex: i32 = -1;
  if (n.kind != NodeKind.arrowFunc && n.left != NO_NODE) {
    const usage = argumentsUsage(in parser, n.left);
    if (usage != 0 && compiler.findLocal(in parser, usage, 9) < 0) {
      compiler.addLocal(usage, 9);
      argumentsIndex = i32(compiler.locals.length - 1);
    }
  }
  compiler.scanParameterCaptures(in parser, node, patternNamesEnd);
  if (n.left != NO_NODE) compiler.scanCaptures(in parser, n.left);
  // With a default anywhere in the list, the parameters bind in order:
  // each is a hole until its own turn, so a default that reads a later
  // parameter (or its own) throws. A named parameter's binding then
  // lives apart from the register its argument arrived in.
  const orderedParams = parametersHaveExpressions(in parser, node);
  if (orderedParams) {
    p = 0;
    while (p < paramCount) {
      if (compiler.locals[usize(p)].nameLength > 0) {
        if (compiler.locals[usize(p)].envSlot < 0) compiler.locals[usize(p)].reg = compiler.allocReg();
        compiler.markOrderedParameter(in parser, inout runtime, usize(p));
      }
      p = p + 1;
    }
    let named = patternNamesStart;
    while (named < patternNamesEnd) {
      compiler.markOrderedParameter(in parser, inout runtime, named);
      named = named + 1;
    }
  }
  // A derived constructor whose arrows read `this` keeps it in the
  // environment as well, so those arrows see it once super() binds it.
  if (role == 2 && n.left != NO_NODE && arrowsUseThis(in parser, n.left)) {
    compiler.thisEnvSlot = i32(compiler.envSize);
    compiler.envSize = compiler.envSize + 1;
    compiler.hasEnv = true;
  }
  compiler.fixedRegs = compiler.nextReg;

  // The environment first, then the captured parameters into it (in
  // order, later, when the list has expressions).
  if (compiler.hasEnv) {
    compiler.emit(instU16(Op.newEnv, u16(compiler.envSize)));
    p = 0;
    while (p < paramCount) {
      const slot = compiler.locals[usize(p)].envSlot;
      if (slot >= 0 && !orderedParams) compiler.emit(instABC(Op.storeEnvSlot, u8(p), 0, u8(slot)));
      p = p + 1;
    }
  }
  if (compiler.thisEnvSlot >= 0) {
    const uninitialized = compiler.allocReg();
    compiler.emit(instA(Op.loadHole, uninitialized));
    compiler.emit(instABC(Op.storeEnvSlot, uninitialized, 0, u8(compiler.thisEnvSlot)));
    compiler.resetTemps();
  }
  if (orderedParams) compiler.emitHoles(0);
  // A named function expression's own name is the value it was called
  // through, which carries the environment when it is a closure.
  if (selfReg >= 0) {
    const selfIndex = usize(selfLocal);
    const callee = compiler.allocReg();
    compiler.emit(instA(Op.loadCallee, callee));
    compiler.storeLocal(selfIndex, callee);
    compiler.resetTemps();
  }
  if (argumentsIndex >= 0) {
    const built = compiler.allocReg();
    compiler.emit(instA(Op.buildArguments, built));
    compiler.storeLocal(usize(argumentsIndex), built);
    compiler.resetTemps();
  }
  if (restIndex >= 0) {
    const built = compiler.allocReg();
    compiler.emit(instAB(Op.buildRestArgs, built, u8(paramCount)));
    compiler.storeLocal(usize(restIndex), built);
    compiler.resetTemps();
  }
  const isGenerator = n.kind == NodeKind.methodDef ? (n.num == 4.0 || n.num == 5.0) : n.num == 3.0;
  // Async: a flag on functions and arrows, a kind code on methods.
  const isAsync = n.kind == NodeKind.methodDef ? (n.num == 1.0 || n.num == 5.0) : n.boolValue;
  // Async functions and async generators are coroutines driven by
  // promises; both suspend on await.
  const isCoroutine = isGenerator || isAsync;
  // Defaults: a parameter that arrived undefined takes its initializer.
  // A pattern parameter then destructures into its names.
  p = 0;
  while (p < n.childrenCount) {
    const paramIndex = parser.ast.child(node, p);
    const param = parser.ast.node(paramIndex);
    if (param.kind == NodeKind.restParam) {
      p = p + 1;
      continue;
    }
    const paramReg = u8(p);
    if (param.right != NO_NODE) {
      const undefinedReg = compiler.allocReg();
      compiler.emit(instA(Op.loadUndefined, undefinedReg));
      const test = compiler.allocReg();
      compiler.emit(instABC(Op.cmpStrictEq, test, paramReg, undefinedReg));
      const skip = compiler.emit(instAI16(Op.jmpIfFalse, test, 0));
      if (param.nameLength > 0) compiler.nameNext(param.nameStart, param.nameLength, 0);
      const init = compiler.compileExpr(in parser, inout runtime, param.right);
      if (init != paramReg) compiler.emit(instAB(Op.mov, paramReg, init));
      compiler.resetTemps();
      compiler.patchJump(skip);
    }
    const pattern = parameterPattern(in parser, paramIndex);
    if (pattern != NO_NODE) {
      const wasInitializing = compiler.initializing;
      if (orderedParams) compiler.initializing = true;
      compiler.destructure(in parser, inout runtime, pattern, paramReg);
      compiler.initializing = wasInitializing;
      compiler.resetTemps();
    } else if (orderedParams) {
      compiler.initLocal(usize(p), paramReg);
    }
    p = p + 1;
  }
  // A generator suspends here, its parameters initialized, and the call
  // returns the generator object.
  if (isCoroutine) {
    const resume = compiler.allocReg();
    compiler.emit(instA(Op.generatorStart, resume));
    compiler.resetTemps();
  }

  // A constructor's instance fields: inline first for a base class,
  // after each super() for a derived one. A synthesized derived
  // constructor forwards its arguments to the parent.
  if (role == 1 || role == 2) {
    compiler.fieldSource = n.left;
    compiler.fieldCount = fieldCount;
  }
  compiler.isAsyncBody = isAsync;
  compiler.isAsyncGeneratorBody = isAsync && isGenerator;
  const forwards = role == 2 && n.num == 2.0;
  if (forwards) {
    const rest = compiler.allocReg();
    compiler.emit(instAB(Op.buildRestArgs, rest, 0));
    const produced = compiler.allocReg();
    compiler.emit(instAB(Op.spreadSuperCall, produced, rest));
    compiler.emitFieldInitializers(in parser, inout runtime);
    compiler.resetTemps();
  }
  if (!forwards && n.left != NO_NODE) {
    const body = parser.ast.node(n.left);
    if (body.kind == NodeKind.blockStmt) {
      compiler.checkBodyRedeclarations(in parser, node, n.left);
      compiler.declareBodyLexicals(in parser, inout runtime, n.left, false);
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
        if (parser.ast.node(statement).kind != NodeKind.functionDecl) {
          if (b < fieldCount) {
            if (role == 1) compiler.compileFieldStatement(in parser, inout runtime, statement);
          } else {
            compiler.compileStmt(in parser, inout runtime, statement);
          }
        }
        b = b + 1;
      }
    } else {
      // Concise arrow body: the expression is the return value.
      const r = compiler.compileExpr(in parser, inout runtime, n.left);
      compiler.emit(instA(Op.returnOp, r));
    }
  }
  // The fall-off-the-end return. Always emitted: a trailing return
  // instruction may be a branch's target rather than the last statement
  // (a yield's injected return, with the resumption jumping past it).
  {
    const r = compiler.allocReg();
    compiler.emit(instA(Op.loadUndefined, r));
    compiler.emit(instA(Op.returnOp, r));
  }
  if (compiler.hadError) return failed;

  let compiled = createFunctionCode();
  const code = replace(inout compiler.code, Array<Inst>());
  const constants = replace(inout compiler.constants, Array<Value>());
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
  compiled.isGenerator = isGenerator;
  compiled.isAsync = isAsync;
  compiler.isAsyncBody = false;
  compiled.strict = compiler.strict;
  compiled.isClassConstructor = role == 1 || role == 2;
  compiled.isDerived = role == 2;
  compiled.isMethod = role == 3;
  compiled.thisReg = compiler.thisReg;
  // The name: written, else the parser's (methods, accessors), else the
  // context's; accessors carry a "get " / "set " prefix.
  let nameStart = n.nameStart;
  let nameLength = n.nameLength;
  // A constructor is named after its class.
  if (role == 1 || role == 2) {
    nameStart = contextualStart;
    nameLength = contextualLength;
  }
  if (nameLength == 0) {
    nameStart = contextualStart;
    nameLength = contextualLength;
  }
  if (nameLength > 0) {
    let nameBytes = Array<u8>();
    if (namePrefix == 1) {
      const getPrefix: String = "get ";
      nameBytes = bytesOf(in getPrefix);
    } else if (namePrefix == 2) {
      const setPrefix: String = "set ";
      nameBytes = bytesOf(in setPrefix);
    }
    const textBytes = sliceBytes(in parser.source, usize(nameStart), usize(nameStart + nameLength));
    let b: usize = 0;
    while (b < textBytes.length) {
      nameBytes.push(textBytes[b]);
      b = b + 1;
    }
    compiled.nameAtom = runtime.internUtf8(move nameBytes);
  }
  const propertyNames = replace(inout compiler.propertyNames, Array<u32>());
  compiled.propertyNames = move propertyNames;
  runtime.setFunction(index, move compiled);
  return CompiledFunction({ index: i32(index), minOuterScope: compiler.minOuterScope });
}

// --- Early errors: redeclarations ---
//
// A scope's lexically declared names (let, const, class, and in a block
// or switch also function declarations) may not repeat, and may not also
// be var-declared anywhere in the scope -- nested blocks included, nested
// functions not. Sloppy code may repeat a plain function declaration in a
// block. A function's parameters count as var-declared for its body; a
// catch parameter may not be redeclared lexically in its block, and a
// destructured one not with var either. A violation is a SyntaxError
// reported as a compile error.

struct NameRef {
  start: u32;
  length: u32;
  plainFunction: boolean;
}

function pushName(inout names: Array<NameRef>, start: u32, length: u32, plainFunction: boolean): void {
  names.push(NameRef({ start: start, length: length, plainFunction: plainFunction }));
}

function pushPatternNames(in parser: Parser, pattern: u32, inout names: Array<NameRef>): void {
  if (pattern == NO_NODE) return;
  const n = parser.ast.node(pattern);
  if (n.kind == NodeKind.identExpr) {
    if (n.nameLength > 0) pushName(inout names, n.nameStart, n.nameLength, false);
    return;
  }
  if (n.kind == NodeKind.patternEntry) {
    pushPatternNames(in parser, n.left, inout names);
    return;
  }
  if (n.kind == NodeKind.arrayPattern || n.kind == NodeKind.objectPattern) {
    let i: u32 = 0;
    while (i < n.childrenCount) {
      pushPatternNames(in parser, parser.ast.child(pattern, i), inout names);
      i = i + 1;
    }
  }
}

// The names a statement declares lexically in the scope holding it.
// Function declarations are lexical inside blocks only.
function pushLexicalNames(in parser: Parser, statement: u32, inBlock: boolean, inout names: Array<NameRef>): void {
  const st = parser.ast.node(statement);
  if (st.kind == NodeKind.varDecl && st.op != TokenKind.kwVar) {
    let d: u32 = 0;
    while (d < st.childrenCount) {
      const decl = parser.ast.node(parser.ast.child(statement, d));
      if (decl.nameLength > 0) {
        pushName(inout names, decl.nameStart, decl.nameLength, false);
      } else {
        pushPatternNames(in parser, decl.third, inout names);
      }
      d = d + 1;
    }
    return;
  }
  if (st.kind == NodeKind.classDecl && st.nameLength > 0) {
    pushName(inout names, st.nameStart, st.nameLength, false);
    return;
  }
  if (st.kind == NodeKind.functionDecl && inBlock && st.nameLength > 0) {
    const plain = st.num != 3.0 && !st.boolValue;
    pushName(inout names, st.nameStart, st.nameLength, plain);
  }
}

// The names var-declared within `node`, nested functions and classes
// excluded.
function collectVarNames(in parser: Parser, node: u32, inout names: Array<NameRef>): void {
  if (node == NO_NODE) return;
  const n = parser.ast.node(node);
  const k = n.kind;
  if (k == NodeKind.functionDecl || k == NodeKind.functionExpr || k == NodeKind.arrowFunc || k == NodeKind.methodDef
      || k == NodeKind.staticBlock || k == NodeKind.classDecl || k == NodeKind.classExpr) return;
  if (k == NodeKind.varDecl) {
    if (n.op != TokenKind.kwVar) return;
    let d: u32 = 0;
    while (d < n.childrenCount) {
      const decl = parser.ast.node(parser.ast.child(node, d));
      if (decl.nameLength > 0) {
        pushName(inout names, decl.nameStart, decl.nameLength, false);
      } else {
        pushPatternNames(in parser, decl.third, inout names);
      }
      d = d + 1;
    }
    return;
  }
  collectVarNames(in parser, n.left, inout names);
  collectVarNames(in parser, n.right, inout names);
  collectVarNames(in parser, n.third, inout names);
  let i: u32 = 0;
  while (i < n.childrenCount) {
    collectVarNames(in parser, parser.ast.child(node, i), inout names);
    i = i + 1;
  }
}

// The names a function's parameters bind.
function collectParameterNames(in parser: Parser, fn: u32, inout names: Array<NameRef>): void {
  const n = parser.ast.node(fn);
  let p: u32 = 0;
  while (p < n.childrenCount) {
    const paramIndex = parser.ast.child(fn, p);
    const param = parser.ast.node(paramIndex);
    if (param.kind == NodeKind.restParam) {
      pushPatternNames(in parser, param.left, inout names);
    } else if (param.kind == NodeKind.identExpr && param.nameLength > 0) {
      pushName(inout names, param.nameStart, param.nameLength, false);
    } else {
      pushPatternNames(in parser, parameterPattern(in parser, paramIndex), inout names);
    }
    p = p + 1;
  }
}

// Whether an identifier spelled like the binding appears in `node`
// before `limit` -- or anywhere inside a function declaration, which is
// hoisted above the declaration -- so the binding may be read before
// its declaration has run.
function nameReferencedBefore(in parser: Parser, node: u32, nameStart: u32, nameLength: u32, limit: u32, hoisted: boolean): boolean {
  if (node == NO_NODE) return false;
  const n = parser.ast.node(node);
  if (n.kind == NodeKind.identExpr && n.nameLength == nameLength && (hoisted || n.nameStart < limit)
      && parser.slicesEqual(n.nameStart, n.nameLength, nameStart, nameLength)) {
    return true;
  }
  const inside = hoisted || n.kind == NodeKind.functionDecl;
  if (nameReferencedBefore(in parser, n.left, nameStart, nameLength, limit, inside)) return true;
  if (nameReferencedBefore(in parser, n.right, nameStart, nameLength, limit, inside)) return true;
  if (nameReferencedBefore(in parser, n.third, nameStart, nameLength, limit, inside)) return true;
  let i: u32 = 0;
  while (i < n.childrenCount) {
    if (nameReferencedBefore(in parser, parser.ast.child(node, i), nameStart, nameLength, limit, inside)) return true;
    i = i + 1;
  }
  return false;
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
  if (k == NodeKind.functionDecl || k == NodeKind.functionExpr || k == NodeKind.arrowFunc || k == NodeKind.methodDef || k == NodeKind.staticBlock) {
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
    const paramIndex = parser.ast.child(fn, p);
    const param = parser.ast.node(paramIndex);
    if (param.kind == NodeKind.identExpr && param.nameLength == nameLength
        && parser.slicesEqual(param.nameStart, param.nameLength, nameStart, nameLength)) {
      return true;
    }
    if (param.kind == NodeKind.restParam && patternBinds(in parser, param.left, nameStart, nameLength)) return true;
    if (patternBinds(in parser, parameterPattern(in parser, paramIndex), nameStart, nameLength)) return true;
    p = p + 1;
  }
  return bodyBinds(in parser, n.left, nameStart, nameLength);
}

// Whether any parameter has a default, directly or inside a pattern.
function parametersHaveExpressions(in parser: Parser, fn: u32): boolean {
  const n = parser.ast.node(fn);
  let p: u32 = 0;
  while (p < n.childrenCount) {
    const paramIndex = parser.ast.child(fn, p);
    const param = parser.ast.node(paramIndex);
    if (param.right != NO_NODE) return true;
    if (patternHasDefault(in parser, parameterPattern(in parser, paramIndex))) return true;
    p = p + 1;
  }
  return false;
}

function patternHasDefault(in parser: Parser, pattern: u32): boolean {
  if (pattern == NO_NODE) return false;
  const n = parser.ast.node(pattern);
  if (n.kind == NodeKind.patternEntry) {
    if (n.right != NO_NODE) return true;
    return patternHasDefault(in parser, n.left);
  }
  if (n.kind == NodeKind.arrayPattern || n.kind == NodeKind.objectPattern) {
    let i: u32 = 0;
    while (i < n.childrenCount) {
      if (patternHasDefault(in parser, parser.ast.child(pattern, i))) return true;
      i = i + 1;
    }
  }
  return false;
}

// The pattern a parameter node carries: the parser wraps `[a]` / `{a}`
// parameters in a nameless identifier node whose `third` is the pattern.
function parameterPattern(in parser: Parser, param: u32): u32 {
  if (param == NO_NODE) return NO_NODE;
  const n = parser.ast.node(param);
  if (n.kind == NodeKind.arrayPattern || n.kind == NodeKind.objectPattern) return param;
  if (n.kind == NodeKind.identExpr && n.nameLength == 0 && n.third != NO_NODE) return n.third;
  return NO_NODE;
}

// An identifier name with its `\uXXXX` / `\u{...}` escapes decoded to
// UTF-8; other bytes copied through.
// The units of an identifier written with escapes (source UTF-8 kept as
// its bytes' code points).
// A global's name as UTF-8: the identifier's text, with any `\u` escapes
// decoded (`l\u0065t` names the global `let`).
function globalNameBytes(in parser: Parser, start: u32, length: u32): Array<u8> {
  let i: u32 = 0;
  while (i < length) {
    if (parser.source[usize(start + i)] == 92) {
      const units = decodeIdentifierName(in parser, start, length);
      return unitsToUtf8(in units);
    }
    i = i + 1;
  }
  return sliceBytes(in parser.source, usize(start), usize(start + length));
}

function decodeIdentifierName(in parser: Parser, start: u32, length: u32): Array<u16> {
  let bytes = Array<u16>();
  let i: u32 = 0;
  while (i < length) {
    const byte = parser.source[usize(start + i)];
    if (byte == 92 && i + 1 < length && parser.source[usize(start + i + 1)] == 117) {
      let codePoint: u32 = 0;
      let j: u32 = i + 2;
      if (j < length && parser.source[usize(start + j)] == 123) {
        j = j + 1;
        while (j < length && parser.source[usize(start + j)] != 125) {
          codePoint = codePoint * 16 + hexDigitValue(parser.source[usize(start + j)]);
          j = j + 1;
        }
        j = j + 1;
      } else {
        let digits: u32 = 0;
        while (digits < 4 && j < length) {
          codePoint = codePoint * 16 + hexDigitValue(parser.source[usize(start + j)]);
          j = j + 1;
          digits = digits + 1;
        }
      }
      pushCodePoint(inout bytes, codePoint);
      i = j;
    } else if (byte < 0x80) {
      bytes.push(u16(byte));
      i = i + 1;
    } else {
      const at = usize(start + i);
      const sequence = wtf8Length(in parser.source, at);
      if (sequence == 0 || usize(start + length) < at + sequence) {
        bytes.push(u16(byte));
        i = i + 1;
      } else {
        let value: u32 = u32(byte) & u32(0x3F >> (sequence - 1));
        let k: usize = 1;
        while (k < sequence) {
          value = (value << 6) | u32(parser.source[at + k] & 0x3F);
          k = k + 1;
        }
        pushCodePoint(inout bytes, value);
        i = i + u32(sequence);
      }
    }
  }
  return bytes;
}

function hexDigitValue(byte: u8): u32 {
  if (byte >= 48 && byte <= 57) return u32(byte - 48);
  if (byte >= 97 && byte <= 102) return u32(byte - 87);
  if (byte >= 65 && byte <= 70) return u32(byte - 55);
  return 0;
}

function appendUtf8(inout bytes: Array<u8>, codePoint: u32): void {
  if (codePoint < 0x80) {
    bytes.push(u8(codePoint));
  } else if (codePoint < 0x800) {
    bytes.push(u8(0xC0 | (codePoint >> 6)));
    bytes.push(u8(0x80 | (codePoint & 0x3F)));
  } else if (codePoint < 0x10000) {
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

// Whether a member / element / call spine contains an optional link.
function chainHasOptional(in parser: Parser, node: u32): boolean {
  let current = node;
  while (current != NO_NODE) {
    const n = parser.ast.node(current);
    const k = n.kind;
    if (k == NodeKind.optionalMember || k == NodeKind.optionalComputed || k == NodeKind.optionalCall) return true;
    if (k != NodeKind.member && k != NodeKind.computed && k != NodeKind.call) return false;
    current = n.left;
  }
  return false;
}

// Whether a pattern (or identifier) binds `name`.
function patternBinds(in parser: Parser, pattern: u32, nameStart: u32, nameLength: u32): boolean {
  if (pattern == NO_NODE) return false;
  const n = parser.ast.node(pattern);
  if (n.kind == NodeKind.identExpr) {
    return n.nameLength == nameLength && parser.slicesEqual(n.nameStart, n.nameLength, nameStart, nameLength);
  }
  if (n.kind == NodeKind.patternEntry) return patternBinds(in parser, n.left, nameStart, nameLength);
  if (n.kind == NodeKind.arrayPattern || n.kind == NodeKind.objectPattern) {
    let i: u32 = 0;
    while (i < n.childrenCount) {
      if (patternBinds(in parser, parser.ast.child(pattern, i), nameStart, nameLength)) return true;
      i = i + 1;
    }
  }
  return false;
}

// var, let, const, and function declarations of a body, not entering
// nested functions.
function bodyBinds(in parser: Parser, node: u32, nameStart: u32, nameLength: u32): boolean {
  if (node == NO_NODE) return false;
  const n = parser.ast.node(node);
  const k = n.kind;
  if (k == NodeKind.functionExpr || k == NodeKind.arrowFunc || k == NodeKind.classExpr || k == NodeKind.methodDef || k == NodeKind.staticBlock) return false;
  if (k == NodeKind.functionDecl || k == NodeKind.classDecl) {
    return n.nameLength == nameLength && parser.slicesEqual(n.nameStart, n.nameLength, nameStart, nameLength);
  }
  if (k == NodeKind.varDecl) {
    let i: u32 = 0;
    while (i < n.childrenCount) {
      const declIndex = parser.ast.child(node, i);
      const decl = parser.ast.node(declIndex);
      if (decl.nameLength == nameLength && parser.slicesEqual(decl.nameStart, decl.nameLength, nameStart, nameLength)) return true;
      if (decl.nameLength == 0 && patternBinds(in parser, decl.third, nameStart, nameLength)) return true;
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

// The position of the first `arguments` read in a body, looking into
// arrows but not into nested functions, which have their own; 0 for none.
function argumentsUsage(in parser: Parser, node: u32): u32 {
  if (node == NO_NODE) return 0;
  const n = parser.ast.node(node);
  if (n.kind == NodeKind.functionDecl || n.kind == NodeKind.functionExpr) return 0;
  if (n.kind == NodeKind.identExpr && n.nameLength == 9 && parser.sliceEquals(n.nameStart, 9, "arguments")) return n.nameStart;
  const left = argumentsUsage(in parser, n.left);
  if (left != 0) return left;
  const right = argumentsUsage(in parser, n.right);
  if (right != 0) return right;
  const third = argumentsUsage(in parser, n.third);
  if (third != 0) return third;
  let i: u32 = 0;
  while (i < n.childrenCount) {
    const found = argumentsUsage(in parser, parser.ast.child(node, i));
    if (found != 0) return found;
    i = i + 1;
  }
  return 0;
}

// Whether a body reads `this` outside any nested non-arrow function.
// Whether an arrow function somewhere in `node` (not inside another kind
// of function) reads `this` or `super`.
function arrowsUseThis(in parser: Parser, node: u32): boolean {
  if (node == NO_NODE) return false;
  const n = parser.ast.node(node);
  const k = n.kind;
  if (k == NodeKind.functionDecl || k == NodeKind.functionExpr || k == NodeKind.methodDef || k == NodeKind.staticBlock) return false;
  if (k == NodeKind.arrowFunc) return bodyUsesThis(in parser, node);
  if (arrowsUseThis(in parser, n.left)) return true;
  if (arrowsUseThis(in parser, n.right)) return true;
  if (arrowsUseThis(in parser, n.third)) return true;
  let i: u32 = 0;
  while (i < n.childrenCount) {
    if (arrowsUseThis(in parser, parser.ast.child(node, i))) return true;
    i = i + 1;
  }
  return false;
}

function bodyUsesThis(in parser: Parser, node: u32): boolean {
  if (node == NO_NODE) return false;
  const n = parser.ast.node(node);
  if (n.kind == NodeKind.functionDecl || n.kind == NodeKind.functionExpr || n.kind == NodeKind.methodDef || n.kind == NodeKind.staticBlock) return false;
  if (n.kind == NodeKind.thisExpr) return !n.boolValue;
  // `super.x` reads through `this`.
  if (n.kind == NodeKind.superExpr) return true;
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
// `enclosing` carries the lexical names of the scopes on the way down:
// a block's function declaration gets a global (sloppy code, Annex B)
// only when no enclosing scope but its own declares its name lexically.
function hoistProgramDecls(in parser: Parser, inout runtime: Runtime, node: u32, nested: boolean, inout enclosing: Array<NameRef>): void {
  if (node == NO_NODE) return;
  const n = parser.ast.node(node);
  const k = n.kind;
  if (k == NodeKind.classDecl) {
    if (!nested) runtime.defineGlobalSlotBytes(globalNameBytes(in parser, n.nameStart, n.nameLength));
    return;
  }
  if (k == NodeKind.functionDecl) {
    if (!nested) {
      runtime.defineGlobalSlotBytes(globalNameBytes(in parser, n.nameStart, n.nameLength));
    } else if (!parser.strictMode && !enclosingDeclares(in parser, in enclosing, n.nameStart, n.nameLength)) {
      runtime.defineGlobalSlotBytes(globalNameBytes(in parser, n.nameStart, n.nameLength));
    }
    return;
  }
  const childNested = nested || k != NodeKind.program;
  // A scope's own lexical names are in force for everything inside it.
  const before = enclosing.length;
  if (k == NodeKind.program || k == NodeKind.blockStmt) {
    let c: u32 = 0;
    while (c < n.childrenCount) {
      pushLexicalNames(in parser, parser.ast.child(node, c), k == NodeKind.blockStmt, inout enclosing);
      c = c + 1;
    }
  } else if (k == NodeKind.switchStmt) {
    let c: u32 = 0;
    while (c < n.childrenCount) {
      const clauseIndex = parser.ast.child(node, c);
      const clause = parser.ast.node(clauseIndex);
      let statement: u32 = 0;
      while (statement < clause.childrenCount) {
        pushLexicalNames(in parser, parser.ast.child(clauseIndex, statement), true, inout enclosing);
        statement = statement + 1;
      }
      c = c + 1;
    }
  }
  if (k == NodeKind.functionExpr || k == NodeKind.arrowFunc || k == NodeKind.classExpr) return;
  if (k == NodeKind.varDecl) {
    if (n.op != TokenKind.kwVar) return;
    let j: u32 = 0;
    while (j < n.childrenCount) {
      const decl = parser.ast.node(parser.ast.child(node, j));
      if (decl.nameLength > 0) runtime.defineGlobalSlotBytes(globalNameBytes(in parser, decl.nameStart, decl.nameLength));
      if (decl.nameLength == 0) hoistPatternGlobals(in parser, inout runtime, decl.third);
      j = j + 1;
    }
    return;
  }
  if (n.left != NO_NODE) hoistProgramDecls(in parser, inout runtime, n.left, childNested, inout enclosing);
  if (n.right != NO_NODE) hoistProgramDecls(in parser, inout runtime, n.right, childNested, inout enclosing);
  if (n.third != NO_NODE) hoistProgramDecls(in parser, inout runtime, n.third, childNested, inout enclosing);
  let i: u32 = 0;
  while (i < n.childrenCount) {
    hoistProgramDecls(in parser, inout runtime, parser.ast.child(node, i), childNested, inout enclosing);
    i = i + 1;
  }
  while (enclosing.length > before) {
    const dropped = enclosing.pop();
  }
}

// Whether the names carry `name` declared somewhere other than at
// `nameStart` itself.
function enclosingDeclares(in parser: Parser, in enclosing: Array<NameRef>, nameStart: u32, nameLength: u32): boolean {
  let i: usize = 0;
  while (i < enclosing.length) {
    if (enclosing[i].start != nameStart && enclosing[i].length == nameLength && parser.slicesEqual(enclosing[i].start, enclosing[i].length, nameStart, nameLength)) return true;
    i = i + 1;
  }
  return false;
}

// Every identifier a script-level var pattern declares is a global.
function hoistPatternGlobals(in parser: Parser, inout runtime: Runtime, pattern: u32): void {
  if (pattern == NO_NODE) return;
  const n = parser.ast.node(pattern);
  if (n.kind == NodeKind.identExpr) {
    if (n.nameLength > 0) runtime.defineGlobalSlotBytes(globalNameBytes(in parser, n.nameStart, n.nameLength));
    return;
  }
  if (n.kind == NodeKind.patternEntry) {
    hoistPatternGlobals(in parser, inout runtime, n.left);
    return;
  }
  if (n.kind == NodeKind.arrayPattern || n.kind == NodeKind.objectPattern) {
    let i: u32 = 0;
    while (i < n.childrenCount) {
      hoistPatternGlobals(in parser, inout runtime, parser.ast.child(pattern, i));
      i = i + 1;
    }
  }
}

// --- Entry ----------------------------------------------------------------

// Compiles a parsed program into the runtime's function table; returns the
// function index, or -1 on error.
export function compileProgram(in parser: Parser, root: u32, inout runtime: Runtime): i32 {
  let compiler = Compiler({
    code: Array<Inst>(), constants: Array<Value>(), nextReg: 0, maxReg: 0, fixedRegs: 0, openEnvs: 0, envRegs: Array<u8>(), initializing: false,
    locals: Array<Local>(), outerScopes: Array<Scope>(), capturedNames: Array<Local>(),
    hasEnv: false, envSize: 0, minOuterScope: 0, lastExprReg: -1, isFunction: false,
    hadError: false, strict: parser.strictMode, loops: Array<LoopFrame>(),
    pendingLabelStart: 0, pendingLabelLength: 0, regions: Array<Region>(), regionDepth: 0,
    pendingNameStart: 0, pendingNameLength: 0, pendingNamePrefix: 0, thisReg: -1, isArrow: false, derivedCtor: false, thisEnvSlot: -1, fieldSource: NO_NODE, fieldCount: 0, isAsyncBody: false, isAsyncGeneratorBody: false, propertyNames: Array<u32>(),
  });
  const resultReg = compiler.allocReg();
  compiler.emit(instA(Op.loadUndefined, resultReg));
  compiler.fixedRegs = resultReg + 1;
  compiler.lastExprReg = i32(resultReg);

  const program = parser.ast.node(root);
  let enclosingLexicals = Array<NameRef>();
  hoistProgramDecls(in parser, inout runtime, root, false, inout enclosingLexicals);
  // Top-level let / const that functions refer to live in an environment;
  // var and function declarations are globals and need none.
  compiler.scanCaptures(in parser, root);
  if (compiler.hasEnv) compiler.emit(instU16(Op.newEnv, u16(compiler.envSize)));
  compiler.checkBodyRedeclarations(in parser, NO_NODE, root);
  compiler.declareBodyLexicals(in parser, inout runtime, root, true);
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
  // out and leaves empty ones behind.
  let compiled = createFunctionCode();
  const code = replace(inout compiler.code, Array<Inst>());
  const constants = replace(inout compiler.constants, Array<Value>());
  compiled.code = move code;
  compiled.constants = move constants;
  compiled.registerCount = u32(compiler.maxReg) + 1;
  compiled.fixedRegs = u32(compiler.fixedRegs);
  compiled.strict = compiler.strict;
  const propertyNames = replace(inout compiler.propertyNames, Array<u32>());
  compiled.propertyNames = move propertyNames;
  return i32(runtime.addFunction(move compiled));
}
