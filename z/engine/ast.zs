// AST -- emitted by the parser, consumed by the bytecode compiler.
//
// One flat node shape with every field the reference uses; only the fields
// relevant to each kind are meaningful. Variant ORDER mirrors src/ast.zc
// exactly and `nodeKindCode` reproduces its integer numbering, so AST dumps
// from both engines diff line-for-line. Generated from src/ast.zc; do not
// reorder by hand.
//
// Nodes live in one Array and refer to each other by index. Index 0 is
// reserved as "no node", which is what the reference spells NULL. Child
// lists are contiguous ranges in a shared index Array. No pointers anywhere,
// so the tree is position-independent and the whole AST is freed by dropping
// the two Arrays -- the reference needs an allocation tracker for the same
// effect.

import { expect } from "std/test";
import { TokenKind } from "./token.zs";

export enum NodeKind {
  program,
  numberExpr,
  bigIntExpr,
  stringExpr,
  templateExpr,
  templatePartExpr,
  taggedTemplate,
  boolExpr,
  nullExpr,
  undefinedExpr,
  holeExpr,
  thisExpr,
  identExpr,
  regexExpr,
  binary,
  logical,
  unary,
  postfix,
  conditional,
  assignment,
  call,
  optionalCall,
  newExpr,   // `new` is reserved in Z; index unchanged
  member,
  optionalMember,
  computed,
  optionalComputed,
  sequence,
  array,
  object,
  objectProp,
  paren,
  blockStmt,
  varDecl,
  declarator,
  ifStmt,
  returnStmt,
  whileStmt,
  doWhileStmt,
  withStmt,
  forStmt,
  breakStmt,
  continueStmt,
  emptyStmt,
  labeledStmt,
  functionDecl,
  functionExpr,
  arrowFunc,
  forInStmt,
  forOfStmt,
  throwStmt,
  tryStmt,
  classDecl,
  classExpr,
  methodDef,
  superExpr,
  superCall,
  restParam,
  spread,
  awaitExpr,
  yieldExpr,
  objectPattern,
  arrayPattern,
  patternEntry,
  classField,
  staticBlock,
  switchStmt,
  switchCase,
  importDecl,
  importClause,
  exportDecl,
  exportClause,
  importCall,
  importMetaExpr,
}

export const NO_NODE: u32 = 0;

export struct AstNode {
  kind: NodeKind;
  start: u32;
  end: u32;
  op: TokenKind;
  num: f64;
  boolValue: boolean;
  left: u32;
  right: u32;
  third: u32;
  childrenStart: u32;
  childrenCount: u32;
  nameStart: u32;
  nameLength: u32;
  scopeId: u32;
  // A function written as an object literal's method, getter, or setter
  // (`{ m() {} }`, `{ get x() {} }`), which has no [[Construct]] -- unlike
  // `{ m: function () {} }`, which is an ordinary function. The tree shape
  // does not tell them apart, so the parser records it here. Internal:
  // the AST dump does not print it.
  conciseMethod: boolean;
}

export struct Ast {
  nodes: Array<AstNode>;
  children: Array<u32>;

  function newNode(inout this, kind: NodeKind, start: u32, end: u32): u32 {
    this.nodes.push(AstNode({
      kind: kind, start: start, end: end, op: TokenKind.eof, num: 0.0,
      boolValue: false, left: NO_NODE, right: NO_NODE, third: NO_NODE,
      childrenStart: 0, childrenCount: 0, nameStart: 0, nameLength: 0, scopeId: 0, conciseMethod: false,
    }));
    return u32(this.nodes.length - 1);
  }

  // Attach a child list by copying it into the shared index Array. Lists are
  // built in a local Array while parsing, then attached once complete.
  function setChildren(inout this, node: u32, in list: Array<u32>): void {
    const start = u32(this.children.length);
    let index: usize = 0;
    while (index < list.length) {
      this.children.push(list[index]);
      index = index + 1;
    }
    this.nodes[usize(node)].childrenStart = start;
    this.nodes[usize(node)].childrenCount = u32(list.length);
  }

  function setLeft(inout this, node: u32, value: u32): void { this.nodes[usize(node)].left = value; }
  function setRight(inout this, node: u32, value: u32): void { this.nodes[usize(node)].right = value; }
  function setThird(inout this, node: u32, value: u32): void { this.nodes[usize(node)].third = value; }
  function setOp(inout this, node: u32, value: TokenKind): void { this.nodes[usize(node)].op = value; }
  function setNum(inout this, node: u32, value: f64): void { this.nodes[usize(node)].num = value; }
  function setBool(inout this, node: u32, value: boolean): void { this.nodes[usize(node)].boolValue = value; }
  function setConciseMethod(inout this, node: u32): void { this.nodes[usize(node)].conciseMethod = true; }
  function setStart(inout this, node: u32, value: u32): void { this.nodes[usize(node)].start = value; }
  function setEnd(inout this, node: u32, value: u32): void { this.nodes[usize(node)].end = value; }
  function setName(inout this, node: u32, start: u32, length: u32): void {
    this.nodes[usize(node)].nameStart = start;
    this.nodes[usize(node)].nameLength = length;
  }

  function child(node: u32, index: u32): u32 {
    const header = this.nodes[usize(node)];
    return this.children[usize(header.childrenStart + index)];
  }

  function node(index: u32): AstNode {
    return this.nodes[usize(index)];
  }

  function count(): u32 {
    return u32(this.nodes.length - 1);
  }
}

export function createAst(): Ast {
  let nodes = Array<AstNode>();
  // Reserve index 0 as "no node".
  nodes.push(AstNode({
    kind: NodeKind.program, start: 0, end: 0, op: TokenKind.eof, num: 0.0,
    boolValue: false, left: NO_NODE, right: NO_NODE, third: NO_NODE,
    childrenStart: 0, childrenCount: 0, nameStart: 0, nameLength: 0, scopeId: 0, conciseMethod: false,
  }));
  return Ast({ nodes: move nodes, children: Array<u32>() });
}

// Reference numbering (C enum order in src/ast.zc).
export function nodeKindCode(kind: NodeKind): i32 {
  return match (kind) {
    program => 0;
    numberExpr => 1;
    bigIntExpr => 2;
    stringExpr => 3;
    templateExpr => 4;
    templatePartExpr => 5;
    taggedTemplate => 6;
    boolExpr => 7;
    nullExpr => 8;
    undefinedExpr => 9;
    holeExpr => 10;
    thisExpr => 11;
    identExpr => 12;
    regexExpr => 13;
    binary => 14;
    logical => 15;
    unary => 16;
    postfix => 17;
    conditional => 18;
    assignment => 19;
    call => 20;
    optionalCall => 21;
    newExpr => 22;
    member => 23;
    optionalMember => 24;
    computed => 25;
    optionalComputed => 26;
    sequence => 27;
    array => 28;
    object => 29;
    objectProp => 30;
    paren => 31;
    blockStmt => 32;
    varDecl => 33;
    declarator => 34;
    ifStmt => 35;
    returnStmt => 36;
    whileStmt => 37;
    doWhileStmt => 38;
    withStmt => 39;
    forStmt => 40;
    breakStmt => 41;
    continueStmt => 42;
    emptyStmt => 43;
    labeledStmt => 44;
    functionDecl => 45;
    functionExpr => 46;
    arrowFunc => 47;
    forInStmt => 48;
    forOfStmt => 49;
    throwStmt => 50;
    tryStmt => 51;
    classDecl => 52;
    classExpr => 53;
    methodDef => 54;
    superExpr => 55;
    superCall => 56;
    restParam => 57;
    spread => 58;
    awaitExpr => 59;
    yieldExpr => 60;
    objectPattern => 61;
    arrayPattern => 62;
    patternEntry => 63;
    classField => 64;
    staticBlock => 65;
    switchStmt => 66;
    switchCase => 67;
    importDecl => 68;
    importClause => 69;
    exportDecl => 70;
    exportClause => 71;
    importCall => 72;
    importMetaExpr => 73;
  };
}

test "node zero is reserved and new nodes index from one" {
  let ast = createAst();
  expect(ast.count()).toEqual(0);
  const first = ast.newNode(NodeKind.numberExpr, 3, 4);
  expect(first).toEqual(1);
  expect(ast.count()).toEqual(1);
}

test "child lists attach as contiguous ranges" {
  let ast = createAst();
  const program = ast.newNode(NodeKind.program, 0, 10);
  const a = ast.newNode(NodeKind.identExpr, 0, 1);
  const b = ast.newNode(NodeKind.identExpr, 2, 3);
  let list = Array<u32>();
  list.push(a);
  list.push(b);
  ast.setChildren(program, in list);
  expect(ast.node(program).childrenCount).toEqual(2);
  expect(ast.child(program, 0)).toEqual(a);
  expect(ast.child(program, 1)).toEqual(b);
}
