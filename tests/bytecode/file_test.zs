// Bytecode files (engine/bytecode_file.zs): a program written by one
// engine runs in another, and a file that is not whole is refused with
// nothing added. Run with `z test tests/bytecode/file_test.zs`.
import { expect } from "std/test";
import { isInt32, asInt32 } from "../../engine/value.zs";
import { Runtime } from "../../engine/runtime.zs";
import { createEngine } from "../../engine/builtins.zs";
import { parseProgram } from "../../engine/parser.zs";
import { compileProgram } from "../../engine/compiler.zs";
import { writeProgram, loadProgram, LOAD_NOT_BYTECODE, LOAD_OTHER_VERSION, LOAD_DAMAGED } from "../../engine/bytecode_file.zs";

function sourceBytes(in text: String): Array<u8> {
  let bytes = Array<u8>();
  let index: usize = 0;
  while (index < text.byteLength) {
    bytes.push(text.byteAt(index));
    index = index + 1;
  }
  return bytes;
}

// The program compiled in an engine of its own and written out.
function compiled(in text: String): Array<u8> {
  let compiling = createEngine();
  const parsed = parseProgram(sourceBytes(in text), false);
  const first = compiling.functions.length;
  const root = compileProgram(in parsed.parser, parsed.root, inout compiling);
  return writeProgram(inout compiling, u32(first), u32(root));
}

// What the program's script returns, loaded into a fresh engine; -1 if
// the file is refused.
function loadedResult(bytes: Slice<u8>): i32 {
  let runtime = createEngine();
  const script = loadProgram(inout runtime, bytes);
  if (script < 0) return -1;
  const outcome = runtime.run(u32(script));
  if (outcome.isThrow || !isInt32(outcome.value)) return -2;
  return asInt32(outcome.value);
}

function fnv(bytes: Slice<u8>, start: usize): u32 {
  let hash: u32 = 2166136261;
  let index = start;
  while (index < bytes.length) {
    hash = (hash ^ u32(bytes[index])).wrappingMultiply(16777619);
    index = index + 1;
  }
  return hash;
}

// The file's checksum made right again after an edit to its payload.
function resealed(bytes: Array<u8>): Array<u8> {
  let file = move bytes;
  const sum = fnv(file, 20);
  file[16] = u8(sum & 0xFF);
  file[17] = u8((sum >> 8) & 0xFF);
  file[18] = u8((sum >> 16) & 0xFF);
  file[19] = u8(sum >> 24);
  return file;
}

const PROGRAM: String = "var total = 0; function add(a, b) { return a + b; } var label = `n${1}`; for (var i = 0; i < 10; i++) total = add(total, i); total + label.length + [1, , 3].length + ((0.5 * 2) | 0);";

test "a program written by one engine runs in another" {
  const bytes = compiled(in PROGRAM);
  expect(bytes.length > 20).toEqual(true);
  // 45 from the loop, 2 for the label, 3 for the array, 1 for the product.
  expect(loadedResult(bytes)).toEqual(51);
}

test "a file that is not whole is refused with nothing added" {
  const bytes = compiled(in PROGRAM);
  let runtime = createEngine();
  const before = runtime.functions.length;
  const empty = Array<u8>();
  expect(loadProgram(inout runtime, empty)).toEqual(LOAD_NOT_BYTECODE);
  let cut: usize = 0;
  while (cut < bytes.length) {
    let truncated = Array<u8>();
    truncated.append(bytes.slice(0, cut));
    const refused = loadProgram(inout runtime, truncated);
    expect(refused < 0).toEqual(true);
    cut = cut + 1;
  }
  let flip: usize = 0;
  while (flip < bytes.length) {
    let damaged = Array<u8>();
    damaged.append(bytes);
    damaged[flip] = damaged[flip] ^ 0x5A;
    const refused = loadProgram(inout runtime, damaged);
    expect(refused < 0).toEqual(true);
    flip = flip + 1;
  }
  expect(runtime.functions.length).toEqual(before);
}

test "another format or instruction set is refused as such" {
  const bytes = compiled(in PROGRAM);
  let runtime = createEngine();
  let format = Array<u8>();
  format.append(bytes);
  format[4] = format[4] + 1;
  expect(loadProgram(inout runtime, format)).toEqual(LOAD_OTHER_VERSION);
  let instructionSet = Array<u8>();
  instructionSet.append(bytes);
  instructionSet[8] = instructionSet[8] + 1;
  expect(loadProgram(inout runtime, instructionSet)).toEqual(LOAD_OTHER_VERSION);
}

test "an index past what the file holds is refused under a good checksum" {
  const bytes = compiled(in PROGRAM);
  let runtime = createEngine();
  const before = runtime.functions.length;
  // The string count, the payload's first word, raised past the strings
  // the file holds.
  let edited = Array<u8>();
  edited.append(bytes);
  edited[20] = edited[20] + 1;
  const sealed = resealed(move edited);
  expect(loadProgram(inout runtime, sealed)).toEqual(LOAD_DAMAGED);
  // A trailing byte past the last function.
  let longer = Array<u8>();
  longer.append(bytes);
  longer.push(0);
  const payload = u32(longer.length - 20);
  longer[12] = u8(payload & 0xFF);
  longer[13] = u8((payload >> 8) & 0xFF);
  longer[14] = u8((payload >> 16) & 0xFF);
  longer[15] = u8(payload >> 24);
  const sealedLonger = resealed(move longer);
  expect(loadProgram(inout runtime, sealedLonger)).toEqual(LOAD_DAMAGED);
  expect(runtime.functions.length).toEqual(before);
}
