// The Z engine's command line: `zjsz run <file>`.
//
// The contract mirrors tools/zjs.zc so scripts/test262/run.py's
// classification applies to both engines unchanged: exit 0 when the
// program completes, otherwise `zjs: throw: <name>: <message>` on stderr
// and exit 1. A parse or compile failure is a SyntaxError whose message
// names the phase, which the runner reads as a parse-phase throw.
import console from "std/console";
import process from "std/process";
import fs from "std/fs";
import { Value, isCell, asCell } from "../../engine/value.zs";
import { Runtime } from "../../engine/runtime.zs";
import { createEngine } from "../../engine/builtins.zs";
import { evaluate } from "../../engine/lib.zs";

function nativeAlloc(count: usize): usize = raw c { return (uintptr_t)calloc(count, 1); }
function nativeStoreByte(buffer: usize, index: usize, value: u8): void = raw c { ((uint8_t *)buffer)[index] = value; }
function nativeWriteError(buffer: usize, count: usize): void = raw c { fwrite((const void *)buffer, 1, count, stderr); }
function nativeFree(buffer: usize): void = raw c { free((void *)buffer); }

function writeError(in bytes: Array<u8>): void {
  const buffer = nativeAlloc(bytes.length + 1);
  let index: usize = 0;
  while (index < bytes.length) {
    nativeStoreByte(buffer, index, bytes[index]);
    index = index + 1;
  }
  nativeWriteError(buffer, bytes.length);
  nativeFree(buffer);
}

function appendString(inout line: Array<u8>, in runtime: Runtime, value: Value): void {
  if (!runtime.isStringValue(value)) return;
  const handle = asCell(value);
  const length = runtime.heap.stringLength(handle);
  let index: usize = 0;
  while (index < length) {
    line.push(runtime.heap.stringByte(handle, index));
    index = index + 1;
  }
}

function appendText(inout line: Array<u8>, text: String): void {
  const bytes = text.copyBytes(0, text.byteLength);
  let index: usize = 0;
  while (index < bytes.byteLength) {
    line.push(bytes.byteAt(index));
    index = index + 1;
  }
}

// `zjs: throw: <name>: <message>`, from the thrown value's own or
// inherited properties; a non-object throw reports its string form.
function reportThrow(inout runtime: Runtime, thrown: Value): void {
  let line = Array<u8>();
  appendText(inout line, "zjs: throw: ");
  if (runtime.isObjectLike(thrown)) {
    const nameText: String = "name";
    const nameKey = runtime.internText(in nameText);
    const nameValue = runtime.getProperty(thrown, nameKey);
    if (runtime.isStringValue(nameValue)) {
      appendString(inout line, in runtime, nameValue);
    } else {
      appendText(inout line, "(unknown)");
    }
    const messageText: String = "message";
    const messageKey = runtime.internText(in messageText);
    const messageValue = runtime.getProperty(thrown, messageKey);
    if (runtime.isStringValue(messageValue)) {
      appendText(inout line, ": ");
      appendString(inout line, in runtime, messageValue);
    }
  } else {
    const text = runtime.toStringValue(thrown);
    appendString(inout line, in runtime, text);
  }
  line.push(10);
  writeError(in line);
}

function runFile(in path: String): i32 throws String {
  const source = try fs.readText(path);
  let runtime = createEngine();
  const outcome = evaluate(inout runtime, move source);
  if (!outcome.isThrow) return 0;
  reportThrow(inout runtime, outcome.value);
  return 1;
}

function main(): i32 {
  // Arguments exclude the program name: `run <file>`.
  const arguments = process.args();
  if (arguments.length < 2) {
    console.error("usage: zjsz run <file>");
    return 2;
  }
  const commandLength = arguments[0].byteLength;
  const command = arguments[0].copyBytes(0, commandLength);
  if (command != "run") {
    console.error("usage: zjsz run <file>");
    return 2;
  }
  const pathLength = arguments[1].byteLength;
  const path = arguments[1].copyBytes(0, pathLength);
  const outcome = attempt runFile(in path);
  return match (outcome) {
    success(code) => code;
    failure(message) => 2;
  };
}
