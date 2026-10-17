// The file loader (docs/modules.md): what `zjs_eval_module` and `zjsz`
// give a runtime to find modules with. A relative specifier resolves
// against the referring module's directory, any other is a path as
// written; `.` and `..` are resolved, and the result is the module's key.
import { thread } from "std/thread";
import fs from "std/fs";
import { Runtime, LoadedSource } from "./runtime.zs";

function startsWith(in bytes: Array<u8>, in prefix: String): boolean {
  if (bytes.length < prefix.byteLength) return false;
  let i: usize = 0;
  while (i < prefix.byteLength) {
    if (bytes[i] != prefix.byteAt(i)) return false;
    i = i + 1;
  }
  return true;
}

// `path` with `.` segments dropped and each `..` taking the segment
// before it; a leading `/` kept.
function normalizePath(in path: Array<u8>): Array<u8> {
  let segments = Array<Array<u8>>();
  let current = Array<u8>();
  let i: usize = 0;
  while (i <= path.length) {
    if (i == path.length || path[i] == 47) {
      const dot = current.length == 1 && current[0] == 46;
      const dots = current.length == 2 && current[0] == 46 && current[1] == 46;
      if (dots) {
        if (segments.length > 0) { const dropped = segments.pop(); }
      } else if (!dot && current.length > 0) {
        segments.push(move current);
      }
      current = Array<u8>();
    } else {
      current.push(path[i]);
    }
    i = i + 1;
  }
  let joined = Array<u8>();
  if (path.length > 0 && path[0] == 47) joined.push(47);
  let s: usize = 0;
  while (s < segments.length) {
    if (s > 0) joined.push(47);
    let b: usize = 0;
    while (b < segments[s].length) {
      joined.push(segments[s][b]);
      b = b + 1;
    }
    s = s + 1;
  }
  return joined;
}

function loadModuleFile(inout runtime: Runtime, specifier: u32, referrer: u32): LoadedSource on thread.any {
  const written = runtime.heap.stringUtf8(specifier);
  let path = Array<u8>();
  if (referrer != 0 && (startsWith(in written, "./") || startsWith(in written, "../"))) {
    const base = runtime.heap.stringUtf8(referrer);
    let end = base.length;
    while (end > 0 && base[end - 1] != 47) { end = end - 1; }
    let i: usize = 0;
    while (i < end) {
      path.push(base[i]);
      i = i + 1;
    }
  }
  let i: usize = 0;
  while (i < written.length) {
    path.push(written[i]);
    i = i + 1;
  }
  const normalized = normalizePath(in path);
  const name = match (attempt String.fromBytes(normalized)) {
    success(text) => text;
    failure(error) => "";
  };
  const key = runtime.internUtf8(move normalized);
  const read = attempt fs.readBytes(name);
  return match (read) {
    success(bytes) => LoadedSource({ found: true, key: key, source: move bytes });
    failure(error) => LoadedSource({ found: false, key: key, source: Array<u8>() });
  };
}

// Give the runtime the file loader.
export function installFileLoader(inout runtime: Runtime): void {
  runtime.moduleLoader = loadModuleFile;
}
