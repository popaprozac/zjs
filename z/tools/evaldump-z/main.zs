// Z eval dump: same canonical rendering as tools/evaldump-ref.c, from the Z
// engine. tools/oracle-eval.sh diffs the two over a corpus.
import console from "std/console";
import fs from "std/fs";
import process from "std/process";
import { Value, isUndefined, isNull, isBoolean, isTrue, isInt32, asInt32, isDouble, asDouble, isCell } from "../../engine/value.zs";
import { Runtime, createRuntime } from "../../engine/runtime.zs";
import { evaluate } from "../../engine/lib.zs";

function render(value: Value): String {
  if (isUndefined(value)) return "undefined";
  if (isNull(value)) return "null";
  if (isBoolean(value)) return isTrue(value) ? "true" : "false";
  if (isInt32(value)) return `int32 ${asInt32(value)}`;
  if (isDouble(value)) return `double ${asDouble(value).toBits()}`;
  return "cell";
}

function dump(in path: String): i32 throws String {
  const source = try fs.readText(path);
  let runtime = createRuntime();
  const outcome = evaluate(inout runtime, move source);
  const rendered = render(outcome.value);
  if (outcome.isThrow) {
    console.log(`throw ${rendered}`);
  } else {
    console.log(`value ${rendered}`);
  }
  return 0;
}

function main(): i32 {
  const arguments = process.args();
  if (arguments.length < 1) {
    console.log("usage: evaldump-z <file.js>");
    return 2;
  }
  const outcome = attempt dump(arguments[0]);
  return match (outcome) {
    success(code) => code;
    failure(message) => 2;
  };
}
