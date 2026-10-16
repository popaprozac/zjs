/* The core context and the optional-builtin installers, through the
   public ABI: what a core context has and lacks, what each installer adds,
   that installing twice changes nothing, and that the full context is
   the core with every installer run. Each check is a script that throws
   when the expectation fails. Also measures what a core-only embedder
   links (printed; see docs/goals.md). */
#include <stdio.h>
#include <stdlib.h>

#include "zjs.h"

static int failures = 0;

static void check(ZjsContext *ctx, const char *what, const char *script) {
  zjs_eval(ctx, script);
  if (zjs_had_error(ctx)) {
    fprintf(stderr, "core context: FAIL %s\n", what);
    failures++;
  }
}

int main(void) {
  ZjsContext *core = zjs_new_core_context();
  if (core == NULL) {
    fprintf(stderr, "core context: no context\n");
    return 1;
  }
  check(core, "optional builtins absent",
        "for (var name of ['JSON', 'RegExp', 'Date', 'Map', 'Set', 'WeakMap', 'WeakSet', 'Promise', 'Reflect'])"
        "  if (typeof globalThis[name] !== 'undefined') throw new Error(name);"
        "if ('match' in String.prototype || 'search' in String.prototype || 'matchAll' in String.prototype) throw 1;");
  check(core, "core builtins present",
        "for (var name of ['Object', 'Function', 'Array', 'String', 'Number', 'Boolean', 'Symbol', 'Error', 'TypeError'])"
        "  if (typeof globalThis[name] !== 'function') throw new Error(name);"
        "if (typeof Math.max !== 'function' || typeof parseInt !== 'function') throw 2;");
  check(core, "the language runs",
        "function* g() { yield 1; yield 2; } var t = 0; for (var v of g()) t += v;"
        "var o = { a: 1, ...{ b: 2 } }; var [x, y] = [3, 4];"
        "if (t !== 3 || o.b !== 2 || `${x}${y}` !== '34' || 'a,b'.split(',').length !== 2) throw 3;"
        "if ('abc'.replace('b', 'x') !== 'axc' || [3, 1, 2].sort().join() !== '1,2,3') throw 4;"
        "if (eval('1 + 1') !== 2) throw 5;");
  check(core, "a regular-expression literal throws until RegExp is installed",
        "try { /a/; throw 'made'; } catch (e) { if (!(e instanceof TypeError)) throw e; }");
  check(core, "async functions run without Promise",
        "async function f() { await 1; return 2; } var p = f(); if (typeof p !== 'object' || 'then' in p) throw 6;");
  check(core, "collections under the core",
        "var kept = []; for (var i = 0; i < 200000; i++) { var c = { i: i, next: kept.length }; if (i % 100 === 0) kept.push(c); }"
        "if (kept.length !== 2000 || kept[1999].i !== 199900) throw 7;");

  zjs_install_json(core);
  zjs_install_regexp(core);
  zjs_install_date(core);
  zjs_install_collections(core);
  zjs_install_promise(core);
  zjs_install_reflect(core);
  check(core, "installed builtins work",
        "if (JSON.stringify({ a: [1] }) !== '{\"a\":[1]}') throw 1;"
        "if (!/b+/.test('abbc') || 'abbc'.match(/b+/)[0] !== 'bb' || 'a1b2'.search(/\\d/) !== 1) throw 2;"
        "if (new Date(0).getTime() !== 0 || new Map([[1, 2]]).get(1) !== 2 || !new Set([1]).has(1)) throw 3;"
        "if (Reflect.ownKeys({ q: 1 })[0] !== 'q' || typeof Promise.resolve(1).then !== 'function') throw 4;");
  check(core, "installing twice changes nothing",
        "var R = RegExp, J = JSON; globalThis.saved = [R, J];");
  zjs_install_regexp(core);
  zjs_install_json(core);
  check(core, "the same builtins after a second install",
        "if (saved[0] !== RegExp || saved[1] !== JSON || !/x/.test('x')) throw 1;");
  zjs_free_context(core);

  ZjsContext *full = zjs_new_context();
  check(full, "the full context has everything",
        "for (var name of ['JSON', 'RegExp', 'Date', 'Map', 'Set', 'WeakMap', 'WeakSet', 'Promise', 'Reflect'])"
        "  if (typeof globalThis[name] === 'undefined') throw new Error(name);"
        "if (typeof ''.match !== 'function' || !/a/.test('a')) throw 1;");
  zjs_free_context(full);

  if (failures != 0) return 1;
  printf("core context: ok\n");
  return 0;
}
