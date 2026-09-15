// Z AST dump: same preorder lines as tools/astdump-ref.c, from the Z parser.
// tools/oracle-ast.sh diffs the two over a corpus.
import console from "std/console";
import fs from "std/fs";
import process from "std/process";
import { parseProgram } from "../../engine/parser.zs";
import { Ast, NO_NODE, nodeKindCode } from "../../engine/ast.zs";
import { kindCode } from "../../engine/token.zs";

// A literal in ternary position does not take the declared u8 type, so the
// flags are spelled through typed bindings.
const ONE: u8 = 1;
const ZERO: u8 = 0;

function dumpNode(in ast: Ast, index: u32, depth: u32): void {
  if (index == NO_NODE) {
    console.log(`${depth} -`);
    return;
  }
  const n = ast.node(index);
  const flag: u8 = n.boolValue ? ONE : ZERO;
  console.log(`${depth} ${nodeKindCode(n.kind)} ${n.start} ${n.end} ${kindCode(n.op)} ${n.num.toBits()} ${flag} ${n.nameStart} ${n.nameLength} ${n.childrenCount}`);
  dumpNode(in ast, n.left, depth + 1);
  dumpNode(in ast, n.right, depth + 1);
  dumpNode(in ast, n.third, depth + 1);
  let child: u32 = 0;
  while (child < n.childrenCount) {
    dumpNode(in ast, ast.child(index, child), depth + 1);
    child = child + 1;
  }
}

function dump(in path: String, isModule: boolean): i32 throws String {
  const source = try fs.readText(path);
  const result = parseProgram(move source, isModule);
  const flag: u8 = result.hadError ? ONE : ZERO;
  console.log(`error ${flag}`);
  if (!result.hadError) dumpNode(in result.parser.ast, result.root, 0);
  return 0;
}

function main(): i32 {
  const arguments = process.args();
  if (arguments.length < 1) {
    console.log("usage: astdump-z <file.js> [--module]");
    return 2;
  }
  const outcome = attempt dump(arguments[0], arguments.length > 1);
  return match (outcome) {
    success(code) => code;
    failure(message) => 2;
  };
}
