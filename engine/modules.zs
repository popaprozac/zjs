// ES modules (docs/modules.md): a graph read through the runtime's loader,
// linked, and evaluated in the specification's order. A runtime that never
// runs a module links none of this.
import { thread } from "std/thread";
import { replace } from "std/memory";
import { Value, int32Value, asInt32, isCell, asCell, cellValue, undefinedValue } from "./value.zs";
import { Runtime, RunResult, ModuleRecord, ModuleImport, ModuleExport, ModuleIndirect, ModuleInfo, CompiledModule, LoadedSource, emptyModuleInfo, appendBytes, MODULE_NAMESPACE, MODULE_NEW, MODULE_LINKED, MODULE_EVALUATING, MODULE_EVALUATED, MODULE_FAILED, MODULE_EVALUATING_ASYNC, HOST_NAMESPACE_GET, HOST_MODULE_FULFILLED, HOST_MODULE_REJECTED, HOST_IMPORT_FULFILLED, HOST_IMPORT_REJECTED, HOST_IMPORT_CONTINUE, HostFunction, PROMISE_REJECTED, ERROR_KIND_TYPE, ERROR_KIND_SYNTAX } from "./runtime.zs";
import { isBytecodeFile, loadModuleProgram } from "./bytecode_file.zs";
import { bytesOf, PROP_ENUMERABLE, PROP_WRITABLE, PROP_CONFIGURABLE, PROP_ACCESSOR, PROP_NONE, FLAG_NAMESPACE } from "./heap.zs";

const RESOLVE_NONE: u8 = 0;
const RESOLVE_FOUND: u8 = 1;
const RESOLVE_AMBIGUOUS: u8 = 2;

// What an export name resolves to: a binding (the module and its slot),
// a module's namespace, nothing, or two bindings star exports disagree on.
struct Resolution {
  kind: u8;
  module: u32;
  slot: u32;
  namespace: boolean;
}

// A (module, name) pair ResolveExport has visited: a second visit is a
// cycle, which resolves to nothing.
struct ResolveStep {
  module: u32;
  name: u32;
}

function unresolved(): Resolution {
  return Resolution({ kind: RESOLVE_NONE, module: 0, slot: 0, namespace: false });
}

function findModule(in runtime: Runtime, key: u32): i32 {
  let i: usize = 0;
  while (i < runtime.modules.length) {
    if (runtime.modules[i].key == key) return i32(i);
    i = i + 1;
  }
  return -1;
}

// Compile `source` as the module keyed `key` and add its record: its
// index, or below 0 with the error pending.
function addModule(inout runtime: Runtime, key: u32, source: Array<u8>): i32 {
  // A module's file is loaded, as a script's is; source is compiled,
  // which only a runtime with the module compiler can.
  let compiled = CompiledModule({ index: -1, info: emptyModuleInfo() });
  if (isBytecodeFile(source)) {
    compiled = loadModuleProgram(inout runtime, source);
    if (compiled.index < 0) {
      raiseNaming(inout runtime, ERROR_KIND_SYNTAX, "bytecode: the module file '", key, "' is not one this engine reads, or is damaged");
      return -1;
    }
  } else {
    const compile = runtime.moduleCompiler;
    compiled = compile(inout runtime, move source);
  }
  if (compiled.index < 0) {
    const error = runtime.compileFailure(compiled.index);
    runtime.raise(error);
    return -1;
  }
  const info = replace(inout compiled.info, emptyModuleInfo());
  const hasAwait = runtime.functions[usize(compiled.index)].isAsync;
  // A module is its own cycle's root until its evaluation finds one.
  runtime.modules.push(ModuleRecord({ key: key, info: move info, code: u32(compiled.index), generator: undefinedValue(), env: 0, requested: Array<u32>(), status: MODULE_NEW, error: undefinedValue(), namespace: 0, dfsIndex: 0, dfsAncestor: 0, hasAwait: hasAwait, asyncEvaluation: false, asyncOrder: 0, pendingAsync: 0, asyncParents: Array<u32>(), cycleRoot: u32(runtime.modules.length), capability: undefinedValue(), meta: 0 }));
  return i32(runtime.modules.length - 1);
}

function raiseNaming(inout runtime: Runtime, kind: u32, before: String, atom: u32, after: String): void {
  let message = bytesOf(in before);
  appendBytes(inout message, runtime.heap.stringUtf8(atom));
  appendBytes(inout message, bytesOf(in after));
  const error = runtime.makeError(kind, move message);
  runtime.raise(error);
}

// A module the loader found: the one the runtime has by its key, else
// its source compiled and added.
function moduleFor(inout runtime: Runtime, specifier: u32, referrer: u32): i32 {
  const load = runtime.moduleLoader;
  let loaded = load(inout runtime, specifier, referrer);
  if (runtime.pendingThrow) return -1;
  if (!loaded.found) {
    raiseNaming(inout runtime, ERROR_KIND_TYPE, "Cannot find module '", specifier, "'");
    return -1;
  }
  const known = findModule(in runtime, loaded.key);
  if (known >= 0) return known;
  const source = replace(inout loaded.source, Array<u8>());
  return addModule(inout runtime, loaded.key, move source);
}

// Every module the graph from `root` names, read and compiled before any
// links: false with the error pending when one cannot be found or does
// not compile. A module linked already has its graph.
function loadGraph(inout runtime: Runtime, root: u32): boolean {
  let pending = Array<u32>();
  pending.push(root);
  let seen = Array<boolean>();
  let cursor: usize = 0;
  while (cursor < pending.length) {
    const m = usize(pending[cursor]);
    cursor = cursor + 1;
    while (seen.length < runtime.modules.length) { seen.push(false); }
    if (seen[m] || runtime.modules[m].status != MODULE_NEW) continue;
    seen[m] = true;
    const count = runtime.modules[m].info.requests.length;
    if (runtime.modules[m].requested.length < count) {
      let resolved = Array<u32>();
      let r: usize = 0;
      while (r < count) {
        const specifier = runtime.modules[m].info.requests[r];
        const referrer = runtime.modules[m].key;
        const found = moduleFor(inout runtime, specifier, referrer);
        if (found < 0) return false;
        resolved.push(u32(found));
        r = r + 1;
      }
      runtime.modules[m].requested = move resolved;
    }
    let r: usize = 0;
    while (r < count) {
      pending.push(runtime.modules[m].requested[r]);
      r = r + 1;
    }
  }
  return true;
}

// ResolveExport: the binding `name` names among `m`'s exports.
function resolveExport(inout runtime: Runtime, m: u32, name: u32, inout visited: Array<ResolveStep>): Resolution {
  let v: usize = 0;
  while (v < visited.length) {
    if (visited[v].module == m && visited[v].name == name) return unresolved();
    v = v + 1;
  }
  visited.push(ResolveStep({ module: m, name: name }));
  const record = usize(m);
  let i: usize = 0;
  while (i < runtime.modules[record].info.locals.length) {
    if (runtime.modules[record].info.locals[i].name == name) {
      return Resolution({ kind: RESOLVE_FOUND, module: m, slot: runtime.modules[record].info.locals[i].slot, namespace: false });
    }
    i = i + 1;
  }
  i = 0;
  while (i < runtime.modules[record].info.indirect.length) {
    if (runtime.modules[record].info.indirect[i].name == name) {
      const target = runtime.modules[record].requested[usize(runtime.modules[record].info.indirect[i].request)];
      const importName = runtime.modules[record].info.indirect[i].importName;
      if (importName == MODULE_NAMESPACE) return Resolution({ kind: RESOLVE_FOUND, module: target, slot: 0, namespace: true });
      return resolveExport(inout runtime, target, importName, inout visited);
    }
    i = i + 1;
  }
  const defaultText: String = "default";
  if (name == runtime.atomOf(in defaultText)) return unresolved();
  let star = unresolved();
  i = 0;
  while (i < runtime.modules[record].info.stars.length) {
    const target = runtime.modules[record].requested[usize(runtime.modules[record].info.stars[i])];
    const resolution = resolveExport(inout runtime, target, name, inout visited);
    if (resolution.kind == RESOLVE_AMBIGUOUS) return resolution;
    if (resolution.kind == RESOLVE_FOUND) {
      if (star.kind == RESOLVE_NONE) {
        star = resolution;
      } else if (star.module != resolution.module || star.slot != resolution.slot || star.namespace != resolution.namespace) {
        return Resolution({ kind: RESOLVE_AMBIGUOUS, module: 0, slot: 0, namespace: false });
      }
    }
    i = i + 1;
  }
  return star;
}

// GetExportedNames: `m`'s export names, star exports' after its own,
// `default` never through a star.
function exportedNames(inout runtime: Runtime, m: u32, inout visited: Array<u32>, inout names: Array<u32>): void {
  let v: usize = 0;
  while (v < visited.length) {
    if (visited[v] == m) return;
    v = v + 1;
  }
  visited.push(m);
  const record = usize(m);
  let i: usize = 0;
  while (i < runtime.modules[record].info.locals.length) {
    names.push(runtime.modules[record].info.locals[i].name);
    i = i + 1;
  }
  i = 0;
  while (i < runtime.modules[record].info.indirect.length) {
    names.push(runtime.modules[record].info.indirect[i].name);
    i = i + 1;
  }
  const defaultText: String = "default";
  const defaultAtom = runtime.atomOf(in defaultText);
  i = 0;
  while (i < runtime.modules[record].info.stars.length) {
    const target = runtime.modules[record].requested[usize(runtime.modules[record].info.stars[i])];
    let starNames = Array<u32>();
    exportedNames(inout runtime, target, inout visited, inout starNames);
    let s: usize = 0;
    while (s < starNames.length) {
      const name = starNames[s];
      let present = name == defaultAtom;
      let n: usize = 0;
      while (n < names.length && !present) {
        present = names[n] == name;
        n = n + 1;
      }
      if (!present) names.push(name);
      s = s + 1;
    }
    i = i + 1;
  }
}

// Where a resolved binding is read: an environment and a slot in it. A
// namespace is held in a one-slot array of its own.
function bindingHolder(inout runtime: Runtime, resolution: Resolution): u32 {
  if (!resolution.namespace) return runtime.modules[usize(resolution.module)].env;
  const namespace = namespaceOf(inout runtime, resolution.module);
  const holder = runtime.heap.allocateArray(1);
  runtime.heap.setSlot(holder, 0, cellValue(namespace));
  return holder;
}

// A namespace's getter for one export: the binding as it is now, a
// ReferenceError while it is uninitialized.
function namespaceGet(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return runtime.namespaceBinding(callee);
}

// The namespace object of module `m`, made the first time it is asked
// for: its exports that resolve, in code-unit order, each read live; no
// prototype, no new properties, and @@toStringTag "Module". Each export
// is held as an accessor, which the runtime's internal methods present as
// the specification's writable, enumerable, non-configurable data
// property (FLAG_NAMESPACE).
function namespaceOf(inout runtime: Runtime, m: u32): u32 {
  const record = usize(m);
  if (runtime.modules[record].namespace != 0) return runtime.modules[record].namespace;
  let visited = Array<u32>();
  let names = Array<u32>();
  exportedNames(inout runtime, m, inout visited, inout names);
  let kept = Array<u32>();
  let resolutions = Array<Resolution>();
  let i: usize = 0;
  while (i < names.length) {
    let steps = Array<ResolveStep>();
    const resolution = resolveExport(inout runtime, m, names[i], inout steps);
    if (resolution.kind == RESOLVE_FOUND) {
      // Insertion by code units: a module exports few names.
      let at = kept.length;
      while (at > 0 && runtime.heap.compareStrings(kept[at - 1], names[i]) > 0) { at = at - 1; }
      kept.push(names[i]);
      resolutions.push(resolution);
      let j = kept.length - 1;
      while (j > at) {
        kept[j] = kept[j - 1];
        resolutions[j] = resolutions[j - 1];
        j = j - 1;
      }
      kept[at] = names[i];
      resolutions[at] = resolution;
    }
    i = i + 1;
  }
  const namespace = runtime.heap.allocateObject(0);
  runtime.modules[record].namespace = namespace;
  if (runtime.sharedHosts.length <= HOST_NAMESPACE_GET || runtime.sharedHosts[HOST_NAMESPACE_GET] == 0) {
    runtime.registerSharedHost(HOST_NAMESPACE_GET, namespaceGet);
  }
  i = 0;
  while (i < kept.length) {
    const holder = bindingHolder(inout runtime, resolutions[i]);
    const data = runtime.heap.allocateArray(3);
    runtime.heap.setSlot(data, 0, cellValue(holder));
    runtime.heap.setSlot(data, 1, int32Value(i32(resolutions[i].slot)));
    runtime.heap.setSlot(data, 2, cellValue(kept[i]));
    const getter = runtime.newSharedHost(HOST_NAMESPACE_GET, cellValue(data), 0);
    runtime.defineAccessorAttr(cellValue(namespace), cellValue(kept[i]), cellValue(getter), undefinedValue(), true, PROP_ENUMERABLE | PROP_ACCESSOR);
    i = i + 1;
  }
  const tagText: String = "Module";
  const tag = runtime.internUtf8Value(bytesOf(in tagText));
  const tagKey = runtime.heap.symbolKeyAtom(asCell(runtime.symbolToStringTag));
  runtime.heap.objectDefine(namespace, tagKey, tag, PROP_NONE);
  runtime.preventExtensions(cellValue(namespace));
  runtime.heap.setFlags(namespace, runtime.heap.flagsOf(namespace) | FLAG_NAMESPACE);
  return namespace;
}

// Bind module `m`'s imports, each to the binding it resolves to, and
// check its indirect exports resolve: false with a SyntaxError pending
// for one that resolves to nothing or to two bindings.
function bindImports(inout runtime: Runtime, m: u32): boolean {
  const record = usize(m);
  const env = runtime.modules[record].env;
  let i: usize = 0;
  while (i < runtime.modules[record].info.imports.length) {
    const target = runtime.modules[record].requested[usize(runtime.modules[record].info.imports[i].request)];
    const name = runtime.modules[record].info.imports[i].name;
    const slot = runtime.modules[record].info.imports[i].slot;
    if (name == MODULE_NAMESPACE) {
      const namespace = namespaceOf(inout runtime, target);
      runtime.heap.setSlot(env, slot, cellValue(namespace));
    } else {
      let steps = Array<ResolveStep>();
      const resolution = resolveExport(inout runtime, target, name, inout steps);
      if (!resolved(inout runtime, resolution, target, name)) return false;
      const holder = bindingHolder(inout runtime, resolution);
      runtime.heap.setSlot(env, slot, cellValue(holder));
      runtime.heap.setSlot(env, slot + 1, int32Value(i32(resolution.slot)));
    }
    i = i + 1;
  }
  i = 0;
  while (i < runtime.modules[record].info.indirect.length) {
    const importName = runtime.modules[record].info.indirect[i].importName;
    if (importName != MODULE_NAMESPACE) {
      const target = runtime.modules[record].requested[usize(runtime.modules[record].info.indirect[i].request)];
      let steps = Array<ResolveStep>();
      const resolution = resolveExport(inout runtime, target, importName, inout steps);
      if (!resolved(inout runtime, resolution, target, importName)) return false;
    }
    i = i + 1;
  }
  return true;
}

function resolved(inout runtime: Runtime, resolution: Resolution, target: u32, name: u32): boolean {
  if (resolution.kind == RESOLVE_FOUND) return true;
  let message = Array<u8>();
  const before: String = "The requested module '";
  appendBytes(inout message, bytesOf(in before));
  appendBytes(inout message, runtime.heap.stringUtf8(runtime.modules[usize(target)].key));
  if (resolution.kind == RESOLVE_AMBIGUOUS) {
    const ambiguous: String = "' contains conflicting star exports for name '";
    appendBytes(inout message, bytesOf(in ambiguous));
  } else {
    const missing: String = "' does not provide an export named '";
    appendBytes(inout message, bytesOf(in missing));
  }
  appendBytes(inout message, runtime.heap.stringUtf8(name));
  const after: String = "'";
  appendBytes(inout message, bytesOf(in after));
  const error = runtime.makeError(ERROR_KIND_SYNTAX, move message);
  runtime.raise(error);
  return false;
}

// The graph's modules in `status`, from `root`, each once.
function graphMembers(in runtime: Runtime, root: u32, status: u8): Array<u32> {
  let members = Array<u32>();
  let seen = Array<boolean>();
  while (seen.length < runtime.modules.length) { seen.push(false); }
  let pending = Array<u32>();
  pending.push(root);
  let cursor: usize = 0;
  while (cursor < pending.length) {
    const m = pending[cursor];
    cursor = cursor + 1;
    if (seen[usize(m)] || runtime.modules[usize(m)].status != status) continue;
    seen[usize(m)] = true;
    members.push(m);
    let r: usize = 0;
    while (r < runtime.modules[usize(m)].requested.length) {
      pending.push(runtime.modules[usize(m)].requested[r]);
      r = r + 1;
    }
  }
  return members;
}

// Link the graph's new modules: each one's environment and function
// declarations made (its generator's first step), then its imports
// bound. On failure, with the error pending, they are new again, to be
// linked afresh.
function linkGraph(inout runtime: Runtime, root: u32): boolean {
  const members = graphMembers(in runtime, root, MODULE_NEW);
  let ok = true;
  let i: usize = 0;
  while (i < members.length && ok) {
    const record = usize(members[i]);
    const callee = runtime.functionValue(runtime.modules[record].code);
    const generator = runtime.callValue0(callee, undefinedValue());
    if (runtime.pendingThrow) {
      ok = false;
    } else {
      runtime.modules[record].generator = generator;
      const env = runtime.heap.slot(runtime.generatorRecord(asCell(generator)), 8);
      runtime.modules[record].env = isCell(env) ? asCell(env) : 0;
      runtime.generatorResume(asCell(generator), undefinedValue(), 0);
      ok = !runtime.pendingThrow;
    }
    i = i + 1;
  }
  i = 0;
  while (i < members.length && ok) {
    ok = bindImports(inout runtime, members[i]);
    i = i + 1;
  }
  i = 0;
  while (i < members.length) {
    const record = usize(members[i]);
    if (ok) {
      runtime.modules[record].status = MODULE_LINKED;
    } else {
      runtime.modules[record].generator = undefinedValue();
      runtime.modules[record].env = 0;
      runtime.modules[record].namespace = 0;
    }
    i = i + 1;
  }
  return ok;
}

// A shared host function, registered the first time it is needed.
function hostOf(inout runtime: Runtime, which: usize, fn: HostFunction): void {
  if (runtime.sharedHosts.length <= which || runtime.sharedHosts[which] == 0) runtime.registerSharedHost(which, fn);
}

// ExecuteModule for a module without top-level await: its second step.
// A throw is left pending.
function executeModule(inout runtime: Runtime, m: u32): void {
  const generator = runtime.modules[usize(m)].generator;
  runtime.generatorResume(asCell(generator), undefinedValue(), 0);
}

// ExecuteAsyncModule: the module's run starts (to its first await), and
// its outcome reaches AsyncModuleExecutionFulfilled or ...Rejected.
function executeAsyncModule(inout runtime: Runtime, m: u32): void {
  hostOf(inout runtime, HOST_MODULE_FULFILLED, moduleFulfilled);
  hostOf(inout runtime, HOST_MODULE_REJECTED, moduleRejected);
  const generator = runtime.modules[usize(m)].generator;
  const promise = runtime.asyncGeneratorEnqueue(asCell(generator), 0, undefinedValue());
  runtime.pushTempRoot(promise);
  const onFulfilled = runtime.newSharedHost(HOST_MODULE_FULFILLED, int32Value(i32(m)), 1);
  runtime.pushTempRoot(cellValue(onFulfilled));
  const onRejected = runtime.newSharedHost(HOST_MODULE_REJECTED, int32Value(i32(m)), 1);
  runtime.performThen(asCell(promise), cellValue(onFulfilled), cellValue(onRejected), undefinedValue());
  runtime.popTempRoot();
  runtime.popTempRoot();
}

function moduleFulfilled(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  asyncModuleFulfilled(inout runtime, u32(asInt32(runtime.heap.slot(callee, 0))));
  return undefinedValue();
}

function moduleRejected(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  asyncModuleRejected(inout runtime, u32(asInt32(runtime.heap.slot(callee, 0))), runtime.argument(argsBase, argc, 0));
  return undefinedValue();
}

// GatherAvailableAncestors: the modules waiting on `m` that wait on
// nothing else now, and, through those without an await of their own,
// theirs.
function gatherAncestors(inout runtime: Runtime, m: u32, inout ready: Array<u32>): void {
  let i: usize = 0;
  while (i < runtime.modules[usize(m)].asyncParents.length) {
    const parent = runtime.modules[usize(m)].asyncParents[i];
    let listed = false;
    let j: usize = 0;
    while (j < ready.length && !listed) {
      listed = ready[j] == parent;
      j = j + 1;
    }
    const root = runtime.modules[usize(parent)].cycleRoot;
    if (!listed && runtime.modules[usize(root)].status != MODULE_FAILED && runtime.modules[usize(parent)].pendingAsync > 0) {
      runtime.modules[usize(parent)].pendingAsync = runtime.modules[usize(parent)].pendingAsync - 1;
      if (runtime.modules[usize(parent)].pendingAsync == 0) {
        ready.push(parent);
        if (!runtime.modules[usize(parent)].hasAwait) gatherAncestors(inout runtime, parent, inout ready);
      }
    }
    i = i + 1;
  }
}

// A module's evaluation is done: its top-level promise resolves.
function finishEvaluation(inout runtime: Runtime, m: u32): void {
  runtime.modules[usize(m)].asyncEvaluation = false;
  runtime.modules[usize(m)].status = MODULE_EVALUATED;
  runtime.modules[usize(m)].generator = undefinedValue();
  const capability = runtime.modules[usize(m)].capability;
  if (isCell(capability)) runtime.resolvePromise(asCell(capability), undefinedValue());
}

// AsyncModuleExecutionFulfilled: the module is done, and the modules that
// were waiting only on it run, in the order their evaluations turned
// async.
function asyncModuleFulfilled(inout runtime: Runtime, m: u32): void {
  if (runtime.modules[usize(m)].status != MODULE_EVALUATING_ASYNC) return;
  finishEvaluation(inout runtime, m);
  let ready = Array<u32>();
  gatherAncestors(inout runtime, m, inout ready);
  // By asyncOrder: a module's place among those that turned async.
  let i: usize = 1;
  while (i < ready.length) {
    let j = i;
    while (j > 0 && runtime.modules[usize(ready[j - 1])].asyncOrder > runtime.modules[usize(ready[j])].asyncOrder) {
      const held = ready[j];
      ready[j] = ready[j - 1];
      ready[j - 1] = held;
      j = j - 1;
    }
    i = i + 1;
  }
  i = 0;
  while (i < ready.length) {
    const next = ready[i];
    if (runtime.modules[usize(next)].status == MODULE_FAILED) {
      // Failed meanwhile, through another module it waited on.
    } else if (runtime.modules[usize(next)].hasAwait) {
      executeAsyncModule(inout runtime, next);
    } else {
      executeModule(inout runtime, next);
      if (runtime.pendingThrow) {
        const error = runtime.takePending();
        asyncModuleRejected(inout runtime, next, error);
      } else {
        finishEvaluation(inout runtime, next);
      }
    }
    i = i + 1;
  }
}

// AsyncModuleExecutionRejected: the module fails, every module waiting on
// it with it, and its top-level promise rejects.
function asyncModuleRejected(inout runtime: Runtime, m: u32, error: Value): void {
  if (runtime.modules[usize(m)].status == MODULE_FAILED) return;
  runtime.modules[usize(m)].status = MODULE_FAILED;
  runtime.modules[usize(m)].error = error;
  runtime.modules[usize(m)].generator = undefinedValue();
  let i: usize = 0;
  while (i < runtime.modules[usize(m)].asyncParents.length) {
    asyncModuleRejected(inout runtime, runtime.modules[usize(m)].asyncParents[i], error);
    i = i + 1;
  }
  const capability = runtime.modules[usize(m)].capability;
  if (isCell(capability)) runtime.rejectPromise(asCell(capability), error);
}

// InnerModuleEvaluation: `m`'s requested modules, then `m`, the modules
// of a cycle finishing together; the next DFS index. A module that
// awaits, or waits on one that does, starts its run once what it waits
// on is done. A throw is left pending.
function evaluateFrom(inout runtime: Runtime, m: u32, inout stack: Array<u32>, index: u32): u32 {
  const record = usize(m);
  const status = runtime.modules[record].status;
  if (status == MODULE_FAILED) {
    const error = runtime.modules[record].error;
    runtime.raise(error);
    return index;
  }
  if (status != MODULE_LINKED) return index;
  runtime.modules[record].status = MODULE_EVALUATING;
  runtime.modules[record].dfsIndex = index;
  runtime.modules[record].dfsAncestor = index;
  runtime.modules[record].pendingAsync = 0;
  let next = index + 1;
  stack.push(m);
  let r: usize = 0;
  while (r < runtime.modules[record].requested.length) {
    let required = runtime.modules[record].requested[r];
    next = evaluateFrom(inout runtime, required, inout stack, next);
    if (runtime.pendingThrow) return next;
    if (runtime.modules[usize(required)].status == MODULE_EVALUATING) {
      if (runtime.modules[usize(required)].dfsAncestor < runtime.modules[record].dfsAncestor) {
        runtime.modules[record].dfsAncestor = runtime.modules[usize(required)].dfsAncestor;
      }
    } else {
      required = runtime.modules[usize(required)].cycleRoot;
      if (runtime.modules[usize(required)].status == MODULE_FAILED) {
        const error = runtime.modules[usize(required)].error;
        runtime.raise(error);
        return next;
      }
    }
    if (runtime.modules[usize(required)].asyncEvaluation) {
      runtime.modules[record].pendingAsync = runtime.modules[record].pendingAsync + 1;
      runtime.modules[usize(required)].asyncParents.push(m);
    }
    r = r + 1;
  }
  if (runtime.modules[record].pendingAsync > 0 || runtime.modules[record].hasAwait) {
    runtime.modules[record].asyncEvaluation = true;
    runtime.modules[record].asyncOrder = runtime.moduleAsyncOrder;
    runtime.moduleAsyncOrder = runtime.moduleAsyncOrder + 1;
    if (runtime.modules[record].pendingAsync == 0) executeAsyncModule(inout runtime, m);
  } else {
    executeModule(inout runtime, m);
    if (runtime.pendingThrow) return next;
  }
  if (runtime.modules[record].dfsAncestor == runtime.modules[record].dfsIndex) {
    let done = false;
    while (!done) {
      const member = stack[stack.length - 1];
      stack.pop();
      const pending = runtime.modules[usize(member)].asyncEvaluation;
      runtime.modules[usize(member)].status = pending ? MODULE_EVALUATING_ASYNC : MODULE_EVALUATED;
      if (!pending) runtime.modules[usize(member)].generator = undefinedValue();
      runtime.modules[usize(member)].cycleRoot = m;
      done = member == m;
    }
  }
  return next;
}

// Evaluate(): the promise for the evaluation of `start`'s graph (from
// its cycle's root, once it has begun), which settles when every module
// of it, async ones included, is done.
function evaluateRoot(inout runtime: Runtime, start: u32): Value {
  let root = start;
  const status = runtime.modules[usize(root)].status;
  if (status == MODULE_EVALUATING_ASYNC || status == MODULE_EVALUATED || status == MODULE_FAILED) root = runtime.modules[usize(root)].cycleRoot;
  const existing = runtime.modules[usize(root)].capability;
  if (isCell(existing)) return existing;
  const promise = runtime.newPromise();
  runtime.modules[usize(root)].capability = promise;
  let stack = Array<u32>();
  evaluateFrom(inout runtime, root, inout stack, 0);
  if (runtime.pendingThrow) {
    const error = runtime.takePending();
    let i: usize = 0;
    while (i < stack.length) {
      const record = usize(stack[i]);
      runtime.modules[record].status = MODULE_FAILED;
      runtime.modules[record].error = error;
      runtime.modules[record].generator = undefinedValue();
      i = i + 1;
    }
    runtime.rejectPromise(asCell(promise), error);
  } else if (!runtime.modules[usize(root)].asyncEvaluation) {
    runtime.resolvePromise(asCell(promise), undefinedValue());
  }
  return promise;
}

// Load, link, and evaluate the graph from module `root`, then run the
// jobs it queued (an async module's run among them): its namespace, or
// what it threw. A graph still waiting once the jobs are done (on
// something only the host can bring) gives its namespace.
function runModule(inout runtime: Runtime, root: i32): RunResult {
  let ok = root >= 0 && loadGraph(inout runtime, u32(root));
  ok = ok && linkGraph(inout runtime, u32(root));
  if (!ok) {
    const error = runtime.takePending();
    runtime.runJobs();
    return RunResult({ isThrow: true, value: error });
  }
  const promise = evaluateRoot(inout runtime, u32(root));
  runtime.pushTempRoot(promise);
  runtime.runJobs();
  runtime.popTempRoot();
  if (runtime.promiseState(asCell(promise)) == PROMISE_REJECTED) return RunResult({ isThrow: true, value: runtime.promiseResult(asCell(promise)) });
  const namespace = namespaceOf(inout runtime, u32(root));
  return RunResult({ isThrow: false, value: cellValue(namespace) });
}

// The module whose function is `code`.
function moduleOfCode(in runtime: Runtime, code: i32): i32 {
  if (code < 0) return -1;
  let i: usize = 0;
  while (i < runtime.modules.length) {
    if (i32(runtime.modules[i].code) == code) return i32(i);
    i = i + 1;
  }
  return -1;
}

// `import(specifier)` (docs/modules.md): the module's graph loaded at
// once, then, as a job (ContinueDynamicImport runs from the load's
// promise), linked and evaluated as a static import's is; the promise
// fulfilled with its namespace once its evaluation is done, or rejected
// with what went wrong on the way.
function importDynamic(inout runtime: Runtime, specifier: Value, referrer: i32): Value on thread.any {
  const promise = runtime.newPromise();
  runtime.pushTempRoot(promise);
  const text = runtime.toStringValue(specifier);
  if (!runtime.pendingThrow) {
    const atom = runtime.propertyKey(text);
    let referrerKey = runtime.scriptKey;
    const owner = moduleOfCode(in runtime, referrer);
    if (owner >= 0) referrerKey = runtime.modules[usize(owner)].key;
    const found = moduleFor(inout runtime, atom, referrerKey);
    if (found >= 0 && loadGraph(inout runtime, u32(found))) {
      hostOf(inout runtime, HOST_IMPORT_CONTINUE, importContinue);
      const data = runtime.heap.allocateArray(2);
      runtime.heap.setSlot(data, 0, promise);
      runtime.heap.setSlot(data, 1, int32Value(found));
      runtime.pushTempRoot(cellValue(data));
      const loaded = runtime.newPromise();
      runtime.pushTempRoot(loaded);
      runtime.resolvePromise(asCell(loaded), undefinedValue());
      const onLoaded = runtime.newSharedHost(HOST_IMPORT_CONTINUE, cellValue(data), 1);
      runtime.performThen(asCell(loaded), cellValue(onLoaded), undefinedValue(), undefinedValue());
      runtime.popTempRoot();
      runtime.popTempRoot();
    }
  }
  if (runtime.pendingThrow) {
    const error = runtime.takePending();
    runtime.rejectPromise(asCell(promise), error);
  }
  runtime.popTempRoot();
  return promise;
}

// ContinueDynamicImport: link the graph, evaluate it, and settle the
// import's promise with the evaluation's outcome.
function importContinue(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const data = asCell(runtime.heap.slot(callee, 0));
  const promise = runtime.heap.slot(data, 0);
  const found = u32(asInt32(runtime.heap.slot(data, 1)));
  if (!linkGraph(inout runtime, found)) {
    const error = runtime.takePending();
    runtime.rejectPromise(asCell(promise), error);
    return undefinedValue();
  }
  const evaluation = evaluateRoot(inout runtime, found);
  runtime.pushTempRoot(evaluation);
  hostOf(inout runtime, HOST_IMPORT_FULFILLED, importFulfilled);
  hostOf(inout runtime, HOST_IMPORT_REJECTED, importRejected);
  const onFulfilled = runtime.newSharedHost(HOST_IMPORT_FULFILLED, cellValue(data), 1);
  runtime.pushTempRoot(cellValue(onFulfilled));
  const onRejected = runtime.newSharedHost(HOST_IMPORT_REJECTED, cellValue(data), 1);
  runtime.performThen(asCell(evaluation), cellValue(onFulfilled), cellValue(onRejected), undefinedValue());
  runtime.popTempRoot();
  runtime.popTempRoot();
  return undefinedValue();
}

function importFulfilled(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const data = asCell(runtime.heap.slot(callee, 0));
  const promise = runtime.heap.slot(data, 0);
  const namespace = namespaceOf(inout runtime, u32(asInt32(runtime.heap.slot(data, 1))));
  runtime.resolvePromise(asCell(promise), cellValue(namespace));
  return undefinedValue();
}

function importRejected(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const data = asCell(runtime.heap.slot(callee, 0));
  const promise = runtime.heap.slot(data, 0);
  runtime.rejectPromise(asCell(promise), runtime.argument(argsBase, argc, 0));
  return undefinedValue();
}

// `import.meta`: an object of the module's own, without a prototype, its
// `url` the module's key -- a `file:` URL for an absolute path.
function importMeta(inout runtime: Runtime, referrer: i32): Value on thread.any {
  const m = moduleOfCode(in runtime, referrer);
  if (m < 0) return undefinedValue();
  if (runtime.modules[usize(m)].meta != 0) return cellValue(runtime.modules[usize(m)].meta);
  const meta = runtime.heap.allocateObject(0);
  runtime.modules[usize(m)].meta = meta;
  const key = runtime.heap.stringUtf8(runtime.modules[usize(m)].key);
  let url = Array<u8>();
  if (key.length > 0 && key[0] == 47) {
    const scheme: String = "file://";
    appendBytes(inout url, bytesOf(in scheme));
  }
  appendBytes(inout url, key);
  const value = runtime.internUtf8Value(move url);
  const urlText: String = "url";
  runtime.heap.objectDefine(meta, runtime.atomOf(in urlText), value, PROP_ENUMERABLE | PROP_WRITABLE | PROP_CONFIGURABLE);
  return cellValue(meta);
}

// Give the runtime `import()` and `import.meta` (docs/modules.md).
export function installModuleSupport(inout runtime: Runtime): void {
  runtime.dynamicImporter = importDynamic;
  runtime.metaMaker = importMeta;
}

// The module the loader finds for `specifier`, evaluated with its graph:
// its namespace, or what it threw. A module evaluated already is not
// again.
export function evaluateModule(inout runtime: Runtime, specifier: Array<u8>): RunResult {
  const atom = runtime.internUtf8(move specifier);
  const root = moduleFor(inout runtime, atom, 0);
  return runModule(inout runtime, root);
}

// `source` as the module keyed `key`, the base its relative imports
// resolve against; the module the runtime has by that key if it has one.
export function evaluateModuleSource(inout runtime: Runtime, key: Array<u8>, source: Array<u8>): RunResult {
  const atom = runtime.internUtf8(move key);
  let root = findModule(in runtime, atom);
  if (root < 0) root = addModule(inout runtime, atom, move source);
  return runModule(inout runtime, root);
}
