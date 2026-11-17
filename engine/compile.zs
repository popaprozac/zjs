// The front end as the runtime reaches it: eval and the Function
// constructor compile through what installCompiler sets, so a runtime it
// never runs on -- one that only loads bytecode files -- links no lexer,
// parser, or compiler.
import { thread } from "std/thread";
import { Runtime, CompiledModule, emptyModuleInfo, COMPILE_PARSE_ERROR, COMPILE_ERROR, COMPILE_STACK } from "./runtime.zs";
import { parseProgram, parseScript } from "./parser.zs";
import { compileProgram, compileEval, compileModule } from "./compiler.zs";

// Why a compile gave no function: the compiler ran out of native stack,
// as it says in the runtime, or the source is in error.
function compileStopped(inout runtime: Runtime): i32 {
  if (!runtime.compileSpent) return COMPILE_ERROR;
  runtime.compileSpent = false;
  return COMPILE_STACK;
}

function compileScriptSource(inout runtime: Runtime, source: Array<u8>): i32 on thread.any {
  const parsed = parseProgram(move source, false, runtime.stackFloor());
  if (parsed.hadError) return parsed.parser.stackSpent ? COMPILE_STACK : COMPILE_PARSE_ERROR;
  const index = compileProgram(in parsed.parser, parsed.root, inout runtime);
  if (index < 0) return compileStopped(inout runtime);
  return index;
}

function compileEvalSource(inout runtime: Runtime, source: Array<u8>, caller: u32, site: u32): i32 on thread.any {
  const strict = runtime.functions[usize(caller)].evalSites[usize(site)].strict;
  let parsed = parseScript(move source, false, strict, runtime.stackFloor());
  if (parsed.hadError) return parsed.parser.stackSpent ? COMPILE_STACK : COMPILE_PARSE_ERROR;
  const index = compileEval(inout parsed.parser, parsed.root, inout runtime, caller, site);
  if (index < 0) return compileStopped(inout runtime);
  return index;
}

function compileModuleSource(inout runtime: Runtime, source: Array<u8>): CompiledModule on thread.any {
  const parsed = parseProgram(move source, true, runtime.stackFloor());
  if (parsed.hadError) return CompiledModule({ index: parsed.parser.stackSpent ? COMPILE_STACK : COMPILE_PARSE_ERROR, info: emptyModuleInfo() });
  let compiled = compileModule(in parsed.parser, parsed.root, inout runtime);
  if (compiled.index < 0) return CompiledModule({ index: compileStopped(inout runtime), info: emptyModuleInfo() });
  return compiled;
}

// Give the runtime a compiler; giving it again changes nothing.
export function installCompiler(inout runtime: Runtime): void {
  runtime.scriptCompiler = compileScriptSource;
  runtime.evalCompiler = compileEvalSource;
}

// Give the runtime a compiler for modules as well (docs/modules.md): a
// front end that compiles only scripts links none of it.
export function installModuleCompiler(inout runtime: Runtime): void {
  installCompiler(inout runtime);
  runtime.moduleCompiler = compileModuleSource;
}
