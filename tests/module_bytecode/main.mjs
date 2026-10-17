// The root of tests/module_bytecode_test.c's graph, compiled to a module
// file with the others: it throws when anything is not as expected, and
// when it runs a second time.
import { count, bump } from "./dep.mjs";
import * as dep from "./dep.mjs";
globalThis.mainRuns = (globalThis.mainRuns || 0) + 1;
if (globalThis.mainRuns > 1) throw new Error("main ran twice");
bump();
if (count !== 2 || dep.count !== 2) throw new Error("live binding");
const lazy = await import("./lazy.mjs");
if (lazy.value !== "lazy") throw new Error("import()");
if (!import.meta.url.endsWith("/main.mjs")) throw new Error("import.meta");
export const ok = true;
