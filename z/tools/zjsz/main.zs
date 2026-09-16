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
import { Value, isCell, asCell, cellValue, undefinedValue } from "../../engine/value.zs";
import { thread } from "std/thread";
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
  // The host boundary: UTF-8 out, a lone surrogate as U+FFFD.
  const bytes = runtime.heap.stringUtf8(asCell(value));
  let index: usize = 0;
  while (index < bytes.length) {
    line.push(bytes[index]);
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

// console.log / console.error: the arguments' string forms joined by
// spaces, one line, to stdout or stderr. The engine has no console of
// its own; a host supplies one.
function consoleWrite(inout runtime: Runtime, argsBase: u32, argc: u32, toError: boolean): Value {
  let line = Array<u8>();
  let index: u32 = 0;
  while (index < argc) {
    if (index > 0) line.push(32);
    const text = runtime.toStringValue(runtime.argument(argsBase, argc, index));
    if (runtime.pendingThrow) return undefinedValue();
    appendString(inout line, in runtime, text);
    index = index + 1;
  }
  line.push(10);
  if (toError) {
    writeError(in line);
  } else {
    writeOut(in line);
  }
  return undefinedValue();
}

function consoleLog(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return consoleWrite(inout runtime, argsBase, argc, false);
}

function consoleError(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return consoleWrite(inout runtime, argsBase, argc, true);
}

function installConsole(inout runtime: Runtime): void {
  const objectProto = runtime.objectProto;
  const console = runtime.heap.allocateObject(objectProto);
  const logText: String = "log";
  runtime.defineMethod(console, in logText, consoleLog, 0);
  const errorText: String = "error";
  runtime.defineMethod(console, in errorText, consoleError, 0);
  runtime.setGlobal("console", cellValue(console));
}

function nativeWriteOut(buffer: usize, count: usize): void = raw c { fwrite((const void *)buffer, 1, count, stdout); fflush(stdout); }

function writeOut(in bytes: Array<u8>): void {
  const buffer = nativeAlloc(bytes.length + 1);
  let index: usize = 0;
  while (index < bytes.length) {
    nativeStoreByte(buffer, index, bytes[index]);
    index = index + 1;
  }
  nativeWriteOut(buffer, bytes.length);
  nativeFree(buffer);
}

function runFile(in path: String): i32 throws String {
  const source = try fs.readBytes(path);
  let runtime = createEngine();
  installConsole(inout runtime);
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
