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

// Whether direct eval code at this site may call super(): the function
// the call is in, past any arrows, is a derived constructor (it keeps
// `this` in its environment for such code), and the call is not in a
// field's initializer.
function evalMayCallSuper(in runtime: Runtime, caller: u32, site: u32): boolean {
  if (runtime.functions[usize(caller)].evalSites[usize(site)].inField) return false;
  let level = runtime.functions[usize(caller)].evalSites[usize(site)].levels.length;
  while (level > 0) {
    level = level - 1;
    if (!runtime.functions[usize(caller)].evalSites[usize(site)].levels[level].isArrow) {
      return runtime.functions[usize(caller)].evalSites[usize(site)].levels[level].thisSlot >= 0;
    }
  }
  return false;
}

// Whether direct eval code at this site may name new.target: the call
// is in a function, past arrows and eval code. Level 0 is a script's.
// shortcut: a module's own code compiles as a function, so eval there may name it too (as undefined); a fact on the EvalSite if one ever needs the error.
function evalInFunction(in runtime: Runtime, caller: u32, site: u32): boolean {
  let level = runtime.functions[usize(caller)].evalSites[usize(site)].levels.length;
  while (level > 1) {
    level = level - 1;
    if (!runtime.functions[usize(caller)].evalSites[usize(site)].levels[level].isArrow) return true;
  }
  return false;
}

function compileEvalSource(inout runtime: Runtime, source: Array<u8>, caller: u32, site: u32, inMethod: boolean): i32 on thread.any {
  const strict = runtime.functions[usize(caller)].evalSites[usize(site)].strict;
  const inFunction = evalInFunction(in runtime, caller, site);
  const superCall = evalMayCallSuper(in runtime, caller, site);
  const inField = runtime.functions[usize(caller)].evalSites[usize(site)].inField;
  let parsed = parseScript(move source, false, strict, inFunction, inMethod, superCall, inField, runtime.stackFloor());
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
