// ES modules (docs/modules.md): a graph read through the runtime's loader,
// linked, and evaluated in the specification's order. A runtime that never
// runs a module links none of this.
import { thread } from "std/thread";
import { replace } from "std/memory";
import { Value, int32Value, asInt32, isCell, asCell, cellValue, undefinedValue, isHole } from "./value.zs";
import { Runtime, RunResult, ModuleRecord, ModuleImport, ModuleExport, ModuleIndirect, ModuleInfo, CompiledModule, LoadedSource, emptyModuleInfo, appendBytes, MODULE_NAMESPACE, MODULE_NEW, MODULE_LINKED, MODULE_EVALUATING, MODULE_EVALUATED, MODULE_FAILED, HOST_NAMESPACE_GET, ERROR_KIND_TYPE, ERROR_KIND_REFERENCE, ERROR_KIND_SYNTAX } from "./runtime.zs";
import { bytesOf, PROP_ENUMERABLE, PROP_ACCESSOR, PROP_NONE } from "./heap.zs";

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
  const compile = runtime.moduleCompiler;
  let compiled = compile(inout runtime, move source);
  if (compiled.index < 0) {
    const error = runtime.compileFailure(compiled.index);
    runtime.raise(error);
    return -1;
  }
  const info = replace(inout compiled.info, emptyModuleInfo());
  runtime.modules.push(ModuleRecord({ key: key, info: move info, code: u32(compiled.index), generator: undefinedValue(), env: 0, requested: Array<u32>(), status: MODULE_NEW, error: undefinedValue(), namespace: 0, dfsIndex: 0, dfsAncestor: 0 }));
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
  const data = asCell(runtime.heap.slot(callee, 0));
  const holder = asCell(runtime.heap.slot(data, 0));
  const slot = u32(asInt32(runtime.heap.slot(data, 1)));
  const value = runtime.heap.slot(holder, slot);
  if (isHole(value)) {
    raiseNaming(inout runtime, ERROR_KIND_REFERENCE, "Cannot access '", asCell(runtime.heap.slot(data, 2)), "' before initialization");
    return undefinedValue();
  }
  return value;
}

// The namespace object of module `m`, made the first time it is asked
// for: its exports that resolve, in code-unit order, each read live; no
// prototype, no new properties, and @@toStringTag "Module".
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

// InnerModuleEvaluation: `m`'s requested modules, then `m`, the modules
// of a cycle finishing together; the next DFS index. A throw is left
// pending.
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
  let next = index + 1;
  stack.push(m);
  let r: usize = 0;
  while (r < runtime.modules[record].requested.length) {
    const required = runtime.modules[record].requested[r];
    next = evaluateFrom(inout runtime, required, inout stack, next);
    if (runtime.pendingThrow) return next;
    if (runtime.modules[usize(required)].status == MODULE_EVALUATING && runtime.modules[usize(required)].dfsAncestor < runtime.modules[record].dfsAncestor) {
      runtime.modules[record].dfsAncestor = runtime.modules[usize(required)].dfsAncestor;
    }
    r = r + 1;
  }
  const generator = runtime.modules[record].generator;
  runtime.generatorResume(asCell(generator), undefinedValue(), 0);
  if (runtime.pendingThrow) return next;
  if (runtime.modules[record].dfsAncestor == runtime.modules[record].dfsIndex) {
    let done = false;
    while (!done) {
      const member = stack[stack.length - 1];
      stack.pop();
      runtime.modules[usize(member)].status = MODULE_EVALUATED;
      runtime.modules[usize(member)].generator = undefinedValue();
      done = member == m;
    }
  }
  return next;
}

// Evaluate the graph from `root`: false with the error pending when a
// module throws, and every module still evaluating fails with it.
function evaluateGraph(inout runtime: Runtime, root: u32): boolean {
  let stack = Array<u32>();
  evaluateFrom(inout runtime, root, inout stack, 0);
  if (!runtime.pendingThrow) return true;
  const error = runtime.pendingValue;
  let i: usize = 0;
  while (i < stack.length) {
    const record = usize(stack[i]);
    runtime.modules[record].status = MODULE_FAILED;
    runtime.modules[record].error = error;
    runtime.modules[record].generator = undefinedValue();
    i = i + 1;
  }
  return false;
}

// Load, link, and evaluate the graph from module `root`, then run the
// jobs it queued: its namespace, or what it threw.
function runModule(inout runtime: Runtime, root: i32): RunResult {
  let ok = root >= 0 && loadGraph(inout runtime, u32(root));
  ok = ok && linkGraph(inout runtime, u32(root));
  ok = ok && evaluateGraph(inout runtime, u32(root));
  if (!ok) {
    const error = runtime.takePending();
    runtime.runJobs();
    return RunResult({ isThrow: true, value: error });
  }
  runtime.runJobs();
  const namespace = namespaceOf(inout runtime, u32(root));
  return RunResult({ isThrow: false, value: cellValue(namespace) });
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
