// Z eval dump: same canonical rendering as tools/evaldump-ref.c, from the Z
// engine. tools/oracle-eval.sh diffs the two over a corpus.
import console from "std/console";
import fs from "std/fs";
import process from "std/process";
import { Value, isUndefined, isNull, isBoolean, isTrue, isInt32, asInt32, isDouble, asDouble, isCell, asCell } from "../../engine/value.zs";
import { Runtime, createRuntime } from "../../engine/runtime.zs";
import { bytesOf } from "../../engine/heap.zs";
import { evaluate } from "../../engine/lib.zs";
import stdio from "stdio.h";
import stdlib from "stdlib.h";

// Strings are written as raw bytes -- they may contain NULs, which a Z
// String cannot carry to the console.
function nativeAlloc(count: usize): usize = raw c { return (uintptr_t)calloc(count, 1); }
function nativeStoreByte(buffer: usize, index: usize, value: u8): void = raw c { ((uint8_t *)buffer)[index] = value; }
function nativeWrite(buffer: usize, count: usize): void = raw c { fwrite((const void *)buffer, 1, count, stdout); fflush(stdout); }
function nativeFree(buffer: usize): void = raw c { free((void *)buffer); }

function writeBytes(in bytes: Array<u8>): void {
  const length = bytes.length;
  const buffer = nativeAlloc(length + 1);
  let index: usize = 0;
  while (index < length) {
    nativeStoreByte(buffer, index, bytes[index]);
    index = index + 1;
  }
  nativeWrite(buffer, length);
  nativeFree(buffer);
}

// `<prefix> string <length> <bytes>\n`, entirely through one output path.
function writeStringLine(in runtime: Runtime, in prefix: String, handle: u32): void {
  const head: String = `${prefix} string ${runtime.heap.stringLength(handle)} `;
  let line = bytesOf(in head);
  const length = runtime.heap.stringLength(handle);
  let index: usize = 0;
  while (index < length) {
    line.push(runtime.heap.stringByte(handle, index));
    index = index + 1;
  }
  line.push(10);
  writeBytes(in line);
}

function render(in runtime: Runtime, value: Value): String {
  if (isUndefined(value)) return "undefined";
  if (isNull(value)) return "null";
  if (isBoolean(value)) return isTrue(value) ? "true" : "false";
  if (isInt32(value)) return `int32 ${asInt32(value)}`;
  if (isDouble(value)) return `double ${asDouble(value).toBits()}`;
  if (isCell(value) && asCell(value) != 0) {
    const handle = asCell(value);
    if (runtime.heap.isArray(handle)) return "array";
    if (runtime.heap.isFunction(handle) || runtime.heap.isHostFunction(handle) || runtime.heap.isClosure(handle)) return "function";
    if (runtime.heap.isObject(handle)) return "object";
  }
  return "cell";
}

function dump(in path: String): i32 throws String {
  const source = try fs.readText(path);
  let runtime = createRuntime();
  const outcome = evaluate(inout runtime, move source);
  const prefix: String = outcome.isThrow ? "throw" : "value";
  if (runtime.isStringValue(outcome.value)) {
    writeStringLine(in runtime, in prefix, asCell(outcome.value));
    return 0;
  }
  const rendered = render(in runtime, outcome.value);
  console.log(`${prefix} ${rendered}`);
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
