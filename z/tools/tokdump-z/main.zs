// Z token dump: same `kind start length` lines as tools/tokdump-ref.c, from
// the Z lexer. tools/oracle-tokens.sh diffs the two over a corpus.
import console from "std/console";
import fs from "std/fs";
import process from "std/process";
import { tokenize } from "../../engine/lexer.zs";
import { kindCode } from "../../engine/token.zs";

function dump(in path: String): i32 throws String {
  const source = try fs.readText(path);
  const tokens = tokenize(move source);
  let index: usize = 0;
  while (index < tokens.length) {
    const token = tokens[index];
    console.log(`${kindCode(token.kind)} ${token.start} ${token.length}`);
    index = index + 1;
  }
  return 0;
}

function main(): i32 {
  const arguments = process.args();
  if (arguments.length < 1) {
    console.log("usage: tokdump-z <file.js>");
    return 2;
  }
  const outcome = attempt dump(arguments[0]);
  return match (outcome) {
    success(code) => code;
    failure(message) => 2;
  };
}
