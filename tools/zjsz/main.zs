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
import { parseProgram } from "../../engine/parser.zs";
import { compileProgram } from "../../engine/compiler.zs";
import { bcU16, bcI16 } from "../../engine/bytecode.zs";
import { opName } from "./opnames.zs";
import native from "./memstat.h";

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
  runtime.collectAll();
  return undefinedValue();
}

function runFile(in path: String, dictThreshold: i32, stats: boolean, exposeGc: boolean, gcStats: boolean, memStats: boolean, gcFloor: i32, gcGrowth: i32, gcNursery: i32): i32 throws String {
  const source = try fs.readBytes(path);
  let runtime = createEngine();
  if (dictThreshold >= 0) runtime.heap.dictThreshold = u32(dictThreshold);
  if (gcFloor > 0) {
    runtime.heap.collectFloor = u32(gcFloor);
    runtime.heap.majorThreshold = u32(gcFloor);
  }
  if (gcGrowth > 0) runtime.heap.collectGrowthPercent = u32(gcGrowth);
  if (gcNursery >= 0) runtime.heap.nurseryCells = u32(gcNursery);
  runtime.heap.collectThreshold = runtime.heap.nurseryCells == 0 ? runtime.heap.majorThreshold : runtime.heap.nurseryCells;
  runtime.gcTiming = gcStats;
  installConsole(inout runtime);
  if (exposeGc) {
    const gcText: String = "gc";
    runtime.setGlobal("gc", cellValue(runtime.defineHostFunction(gcHost, undefinedValue(), 0, in gcText)));
  }
  const outcome = evaluate(inout runtime, move source);
  if (stats) reportStats(in runtime);
  if (gcStats) reportGcStats(in runtime);
  if (memStats) reportMemStats(in runtime);
  if (!outcome.isThrow) return 0;
  reportThrow(inout runtime, outcome.value);
  return 1;
}

// The bytecode a script compiles to, on stdout: each function's header
// (index, name, registers, parameters) and its instructions with their
// operands, a 16-bit operand shown both signed and unsigned.
function dumpFile(in path: String): i32 throws String {
  const source = try fs.readBytes(path);
  let runtime = createEngine();
  const parsed = parseProgram(move source, false);
  if (parsed.hadError) {
    console.error("zjsz dump: parse error");
    return 1;
  }
  const first = runtime.functions.length;
  const root = compileProgram(in parsed.parser, parsed.root, inout runtime);
  if (root < 0) {
    console.error("zjsz dump: compile error");
    return 1;
  }
  let fi = first;
  while (fi < runtime.functions.length) {
    let line = Array<u8>();
    appendText(inout line, "function ");
    appendDecimal(inout line, u32(fi));
    appendText(inout line, " ");
    const nameAtom = runtime.functions[fi].nameAtom;
    if (nameAtom != 0) {
      appendString(inout line, in runtime, cellValue(nameAtom));
    } else {
      appendText(inout line, "(anonymous)");
    }
    appendText(inout line, " registers ");
    appendDecimal(inout line, runtime.functions[fi].registerCount);
    appendText(inout line, " params ");
    appendDecimal(inout line, runtime.functions[fi].paramCount);
    appendText(inout line, " instructions ");
    appendDecimal(inout line, runtime.functions[fi].codeLength);
    line.push(10);
    writeOut(in line);
    const start = usize(runtime.functions[fi].codeStart);
    const count = usize(runtime.functions[fi].codeLength);
    let ip: usize = 0;
    while (ip < count) {
      const inst = runtime.codeSegment[start + ip];
      let text = Array<u8>();
      appendText(inout text, "  ");
      appendDecimal(inout text, u32(ip));
      appendText(inout text, "  ");
      appendText(inout text, opName(inst.op));
      appendText(inout text, " ");
      appendDecimal(inout text, u32(inst.a));
      appendText(inout text, " ");
      appendDecimal(inout text, u32(inst.b));
      appendText(inout text, " ");
      appendDecimal(inout text, u32(inst.c));
      if (inst.d != 0) {
        appendText(inout text, " ");
        appendDecimal(inout text, u32(inst.d));
      }
      appendText(inout text, "  (u16 ");
      appendDecimal(inout text, u32(bcU16(inst)));
      appendText(inout text, ", i16 ");
      const signed = bcI16(inst);
      if (signed < 0) {
        appendText(inout text, "-");
        appendDecimal(inout text, u32(0 - signed));
      } else {
        appendDecimal(inout text, u32(signed));
      }
      appendText(inout text, ")");
      text.push(10);
      writeOut(in text);
      ip = ip + 1;
    }
    fi = fi + 1;
  }
  return 0;
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
  appendText(inout line, " minor ");
  appendDecimal(inout line, runtime.heap.minorCollections);
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
  appendText(inout line, " cells-allocated ");
  appendDecimal(inout line, clampCount(runtime.heap.cellsAllocated()));
  appendText(inout line, " slots-allocated ");
  appendDecimal(inout line, clampCount(runtime.heap.slotsAllocated()));
  appendText(inout line, " in-use-kib ");
  appendDecimal(inout line, u32(truncateDouble(runtime.heap.bytesInUse() / 1024.0)));
  line.push(10);
  writeError(in line);
}

// Storage figures after a run and before anything is torn down, on
// stderr, in KiB, all read at the same moment so they can be set against
// each other: what the last collection found alive; what the engine has
// in use now (garbage since included); what its arrays hold by capacity,
// part by part; what the allocator says the program holds and what it
// has reserved from the system; and the process's resident size and
// physical footprint now, beside the peak resident size, which says
// nothing about now.
function reportMemStats(in runtime: Runtime): void {
  let line = Array<u8>();
  appendText(inout line, "zjsz-mem: live-at-last-collection-kib ");
  appendDecimal(inout line, kib(runtime.heap.bytesLiveAtLastCollection()));
  appendText(inout line, " in-use-kib ");
  appendDecimal(inout line, kib(runtime.heap.bytesInUse()));
  appendText(inout line, " held-arena-kib ");
  appendDecimal(inout line, kib(runtime.heap.arenaBytesHeld()));
  appendText(inout line, " held-table-kib ");
  appendDecimal(inout line, kib(runtime.heap.tableBytesHeld()));
  appendText(inout line, " held-strings-kib ");
  appendDecimal(inout line, kib(runtime.heap.stringBytesHeld()));
  appendText(inout line, " held-other-kib ");
  appendDecimal(inout line, kib(runtime.heap.otherBytesHeld() + runtime.runtimeBytesHeld()));
  appendText(inout line, " allocator-in-use-kib ");
  appendDecimal(inout line, kib(native.zjsz_alloc_in_use()));
  appendText(inout line, " allocator-reserved-kib ");
  appendDecimal(inout line, kib(native.zjsz_alloc_reserved()));
  appendText(inout line, " allocator-peak-in-use-kib ");
  appendDecimal(inout line, kib(native.zjsz_alloc_peak_in_use()));
  appendText(inout line, " resident-now-kib ");
  appendDecimal(inout line, kib(native.zjsz_resident_now()));
  appendText(inout line, " footprint-now-kib ");
  appendDecimal(inout line, kib(native.zjsz_footprint_now()));
  appendText(inout line, " resident-peak-kib ");
  appendDecimal(inout line, kib(native.zjsz_resident_peak()));
  line.push(10);
  writeError(in line);
}

function kib(bytes: f64): u32 {
  return clampCount(bytes / 1024.0);
}

function clampCount(value: f64): u32 {
  if (value >= 4294967295.0) return 4294967295;
  return u32(truncateDouble(value));
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
  //   run [--dict-threshold N] [--stats] [--gc-stats] [--mem-stats]
  //       [--gc-floor N] [--gc-growth P] [--gc-nursery N] [--expose-gc] <file>
  //   dump <file>        the bytecode the file compiles to
  // --dict-threshold sets the property count at which an object leaves
  // its hidden class (for measurement); --stats prints heap figures
  // after the run; --gc-stats times every collection and prints the
  // pause distribution; --mem-stats prints storage figures (alive, in
  // use, held by capacity, the allocator's, the process's now and at
  // peak); --gc-floor and --gc-growth set the collection
  // policy's floor (cells promoted between full collections) and
  // survivor multiple (percent), and --gc-nursery the allocations
  // between minor collections (0: every collection is full), for
  // measurement and testing; --expose-gc defines a global gc() that
  // collects everything.
  const arguments = process.args();
  if (arguments.length < 2) {
    console.error("usage: zjsz run [--dict-threshold N] [--stats] [--expose-gc] <file>");
    return 2;
  }
  const commandLength = arguments[0].byteLength;
  const command = arguments[0].copyBytes(0, commandLength);
  if (command == "dump") {
    const pathLength = arguments[1].byteLength;
    const dumpPath = arguments[1].copyBytes(0, pathLength);
    const dumped = attempt dumpFile(in dumpPath);
    return match (dumped) {
      success(code) => code;
      failure(message) => 2;
    };
  }
  if (command != "run") {
    console.error("usage: zjsz run [--dict-threshold N] [--stats] [--expose-gc] <file>");
    return 2;
  }
  let index: usize = 1;
  let dictThreshold: i32 = -1;
  let stats = false;
  let exposeGc = false;
  let gcStats = false;
  let memStats = false;
  let gcFloor: i32 = -1;
  let gcGrowth: i32 = -1;
  let gcNursery: i32 = -1;
  while (index + 1 < arguments.length) {
    const optionLength = arguments[index].byteLength;
    const option = arguments[index].copyBytes(0, optionLength);
    if (option == "--stats") {
      stats = true;
      index = index + 1;
    } else if (option == "--gc-stats") {
      gcStats = true;
      index = index + 1;
    } else if (option == "--mem-stats") {
      memStats = true;
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
    } else if (option == "--gc-nursery" && index + 2 < arguments.length) {
      const valueLength = arguments[index + 1].byteLength;
      const value = arguments[index + 1].copyBytes(0, valueLength);
      gcNursery = decimalOf(in value);
      if (gcNursery < 0) {
        console.error("zjsz: --gc-nursery needs a decimal count");
        return 2;
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
  const outcome = attempt runFile(in path, dictThreshold, stats, exposeGc, gcStats, memStats, gcFloor, gcGrowth, gcNursery);
  return match (outcome) {
    success(code) => code;
    failure(message) => 2;
  };
}
