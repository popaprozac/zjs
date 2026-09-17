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
import { Runtime, truncateDouble } from "../../engine/runtime.zs";
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

// gc(): a forced collection, exposed under --expose-gc for tests. It runs
// where any host call runs -- a call site, the arguments and the caller's
// registers rooted -- the same point an ordinary collection may take.
function gcHost(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  runtime.collectGarbage();
  return undefinedValue();
}

function runFile(in path: String, dictThreshold: i32, stats: boolean, exposeGc: boolean, gcStats: boolean, gcFloor: i32, gcGrowth: i32): i32 throws String {
  const source = try fs.readBytes(path);
  let runtime = createEngine();
  if (dictThreshold >= 0) runtime.heap.dictThreshold = u32(dictThreshold);
  if (gcFloor > 0) {
    runtime.heap.collectFloor = u32(gcFloor);
    runtime.heap.collectThreshold = u32(gcFloor);
  }
  if (gcGrowth > 0) runtime.heap.collectGrowthPercent = u32(gcGrowth);
  runtime.gcTiming = gcStats;
  installConsole(inout runtime);
  if (exposeGc) {
    const gcText: String = "gc";
    runtime.setGlobal("gc", cellValue(runtime.defineHostFunction(gcHost, undefinedValue(), 0, in gcText)));
  }
  const outcome = evaluate(inout runtime, move source);
  if (stats) reportStats(in runtime);
  if (gcStats) reportGcStats(in runtime);
  if (!outcome.isThrow) return 0;
  reportThrow(inout runtime, outcome.value);
  return 1;
}

// Heap figures after a run, on stderr: slots in use, live cells,
// dictionary-mode objects, collections.
function reportStats(in runtime: Runtime): void {
  let line = Array<u8>();
  appendText(inout line, "zjsz: slots ");
  appendDecimal(inout line, runtime.heap.slotsInUse());
  appendText(inout line, " cells ");
  appendDecimal(inout line, runtime.heap.liveCells());
  appendText(inout line, " dictionaries ");
  appendDecimal(inout line, runtime.heap.dictionaryCount());
  appendText(inout line, " collections ");
  appendDecimal(inout line, runtime.heap.collections);
  appendText(inout line, " weak-cleared ");
  appendDecimal(inout line, runtime.heap.weakCleared);
  appendText(inout line, " ephemeron-passes ");
  appendDecimal(inout line, runtime.heap.ephemeronPasses);
  appendText(inout line, " weak-visits ");
  appendDecimal(inout line, runtime.heap.weakVisits);
  appendText(inout line, " marked ");
  appendDecimal(inout line, runtime.heap.markedCells);
  appendText(inout line, " pending-scratch ");
  appendDecimal(inout line, u32(runtime.heap.pendingScratchBytes()));
  line.push(10);
  writeError(in line);
}

// Collection figures after a run, on stderr: how many, their total, and
// the pause distribution in microseconds, with what the engine's own
// storage holds in use at the end.
function reportGcStats(in runtime: Runtime): void {
  let pauses = Array<f64>.withCapacity(runtime.gcPauses.length);
  let total: f64 = 0.0;
  let index: usize = 0;
  while (index < runtime.gcPauses.length) {
    pauses.push(runtime.gcPauses[index]);
    total = total + runtime.gcPauses[index];
    index = index + 1;
  }
  sortAscending(inout pauses);
  let line = Array<u8>();
  appendText(inout line, "zjsz-gc: collections ");
  appendDecimal(inout line, u32(pauses.length));
  appendText(inout line, " total-us ");
  appendDecimal(inout line, microseconds(total));
  appendText(inout line, " p50-us ");
  appendDecimal(inout line, microseconds(percentile(in pauses, 50)));
  appendText(inout line, " p95-us ");
  appendDecimal(inout line, microseconds(percentile(in pauses, 95)));
  appendText(inout line, " p99-us ");
  appendDecimal(inout line, microseconds(percentile(in pauses, 99)));
  appendText(inout line, " max-us ");
  appendDecimal(inout line, microseconds(percentile(in pauses, 100)));
  appendText(inout line, " in-use-kib ");
  appendDecimal(inout line, u32(truncateDouble(runtime.heap.bytesInUse() / 1024.0)));
  line.push(10);
  writeError(in line);
}

function microseconds(nanoseconds: f64): u32 {
  const value = truncateDouble(nanoseconds / 1000.0);
  if (value >= 4294967295.0) return 4294967295;
  return u32(value);
}

function percentile(in sorted: Array<f64>, percent: usize): f64 {
  if (sorted.length == 0) return 0.0;
  let at = sorted.length * percent / 100;
  if (at >= sorted.length) at = sorted.length - 1;
  return sorted[at];
}

// Shell sort: a few hundred thousand pauses at most, no allocation.
function sortAscending(inout values: Array<f64>): void {
  let gap = values.length / 2;
  while (gap > 0) {
    let i = gap;
    while (i < values.length) {
      const moving = values[i];
      let j = i;
      while (j >= gap && values[j - gap] > moving) {
        values[j] = values[j - gap];
        j = j - gap;
      }
      values[j] = moving;
      i = i + 1;
    }
    gap = gap / 2;
  }
}

function appendDecimal(inout line: Array<u8>, value: u32): void {
  let digits = Array<u8>();
  let rest = value;
  if (rest == 0) digits.push(48);
  while (rest > 0) {
    digits.push(u8(48 + rest % 10));
    rest = rest / 10;
  }
  let index = digits.length;
  while (index > 0) {
    index = index - 1;
    line.push(digits[index]);
  }
}

// A decimal option value, or -1.
function decimalOf(in text: String): i32 {
  let value: i32 = 0;
  let index: usize = 0;
  const length = text.byteLength;
  if (length == 0) return -1;
  while (index < length) {
    const byte = text.byteAt(index);
    if (byte < 48 || byte > 57) return -1;
    value = value * 10 + i32(byte - 48);
    index = index + 1;
  }
  return value;
}

function main(): i32 {
  // Arguments exclude the program name:
  //   run [--dict-threshold N] [--stats] [--gc-stats] [--gc-floor N]
  //       [--gc-growth P] [--expose-gc] <file>
  // --dict-threshold sets the property count at which an object leaves
  // its hidden class (for measurement); --stats prints heap figures
  // after the run; --gc-stats times every collection and prints the
  // pause distribution; --gc-floor and --gc-growth set the collection
  // policy's floor (cells) and survivor multiple (percent), for
  // measurement; --expose-gc defines a global gc() that collects.
  const arguments = process.args();
  if (arguments.length < 2) {
    console.error("usage: zjsz run [--dict-threshold N] [--stats] [--expose-gc] <file>");
    return 2;
  }
  const commandLength = arguments[0].byteLength;
  const command = arguments[0].copyBytes(0, commandLength);
  if (command != "run") {
    console.error("usage: zjsz run [--dict-threshold N] [--stats] [--expose-gc] <file>");
    return 2;
  }
  let index: usize = 1;
  let dictThreshold: i32 = -1;
  let stats = false;
  let exposeGc = false;
  let gcStats = false;
  let gcFloor: i32 = -1;
  let gcGrowth: i32 = -1;
  while (index + 1 < arguments.length) {
    const optionLength = arguments[index].byteLength;
    const option = arguments[index].copyBytes(0, optionLength);
    if (option == "--stats") {
      stats = true;
      index = index + 1;
    } else if (option == "--gc-stats") {
      gcStats = true;
      index = index + 1;
    } else if ((option == "--gc-floor" || option == "--gc-growth") && index + 2 < arguments.length) {
      const valueLength = arguments[index + 1].byteLength;
      const value = arguments[index + 1].copyBytes(0, valueLength);
      const parsed = decimalOf(in value);
      if (parsed <= 0) {
        console.error("zjsz: --gc-floor and --gc-growth need a positive decimal");
        return 2;
      }
      if (option == "--gc-floor") {
        gcFloor = parsed;
      } else {
        gcGrowth = parsed;
      }
      index = index + 2;
    } else if (option == "--expose-gc") {
      exposeGc = true;
      index = index + 1;
    } else if (option == "--dict-threshold" && index + 2 < arguments.length) {
      const valueLength = arguments[index + 1].byteLength;
      const value = arguments[index + 1].copyBytes(0, valueLength);
      dictThreshold = decimalOf(in value);
      if (dictThreshold < 0) {
        console.error("zjsz: --dict-threshold needs a decimal count");
        return 2;
      }
      index = index + 2;
    } else {
      break;
    }
  }
  const pathLength = arguments[index].byteLength;
  const path = arguments[index].copyBytes(0, pathLength);
  const outcome = attempt runFile(in path, dictThreshold, stats, exposeGc, gcStats, gcFloor, gcGrowth);
  return match (outcome) {
    success(code) => code;
    failure(message) => 2;
  };
}
