// Ambient globals available in every zjs program.
//
// Most of the WinterTC surface (fetch/URL/Headers/streams/crypto/
// encoding/AbortController/EventTarget/Blob/structuredClone/timers/
// console/btoa/atob/queueMicrotask) is supplied by TypeScript's
// `lib.webworker.d.ts`, which we reference below. This file only
// declares the deltas — things zjs ships that webworker doesn't (or
// that we shape differently).

/// <reference lib="es2022" />
/// <reference lib="webworker" />

// ---------------------------------------------------------------------
// performance — User Timing Level 3 entries.
// `performance.now` / `.timeOrigin` are in lib.webworker; the rest is
// our pure-JS bootstrap on top.
// ---------------------------------------------------------------------

// Note: `detail` is `any` (not `unknown`) to merge with lib.webworker's
// existing PerformanceMarkOptions / PerformanceMeasureOptions, which
// declare `detail?: any`. Diverging there would force every consumer
// to assert before using `detail`.
interface PerformanceMarkOptions {
  detail?: any;
  startTime?: number;
}

interface PerformanceMeasureOptions {
  detail?: any;
  start?: number | string;
  end?: number | string;
  duration?: number;
}

interface PerformanceEntryLike {
  readonly name: string;
  readonly entryType: 'mark' | 'measure';
  readonly startTime: number;
  readonly duration: number;
  readonly detail: unknown;
}

interface Performance {
  mark(name: string, options?: PerformanceMarkOptions): PerformanceEntryLike;
  measure(
    name: string,
    startMarkOrOptions?: string | PerformanceMeasureOptions,
    endMark?: string,
  ): PerformanceEntryLike;
  clearMarks(name?: string): void;
  clearMeasures(name?: string): void;
  getEntries(): PerformanceEntryLike[];
  getEntriesByName(name: string, type?: 'mark' | 'measure'): PerformanceEntryLike[];
  getEntriesByType(type: 'mark' | 'measure'): PerformanceEntryLike[];
}

// ---------------------------------------------------------------------
// process — Node-flavored global. Mirrors `import * as process from
// 'node:process'`; see node-process.d.ts for the module-level types.
// ---------------------------------------------------------------------

interface ProcessVersions {
  zjs: string;
  // Real Node ships dozens of keys here; we expose only what we set.
  [key: string]: string;
}

interface ProcessHrtime {
  (time?: [number, number]): [number, number];
  bigint(): bigint;
}

interface NodeJSProcess {
  argv: string[];
  env: Record<string, string | undefined>;
  platform: 'darwin' | 'linux' | 'win32' | string;
  arch: 'x64' | 'arm64' | string;
  pid: number;
  versions: ProcessVersions;
  cwd(): string;
  chdir(directory: string): void;
  exit(code?: number): never;
  hrtime: ProcessHrtime;
  nextTick(callback: (...args: unknown[]) => void, ...args: unknown[]): void;
  stdout: { write(chunk: string | Uint8Array): boolean };
  stderr: { write(chunk: string | Uint8Array): boolean };
}

declare var process: NodeJSProcess;

// ---------------------------------------------------------------------
// Legacy escape / unescape — Annex B globals zjs exposes for libraries
// (e.g. the uuid package's v5 path). Not in lib.webworker.
// ---------------------------------------------------------------------

declare function escape(input: string): string;
declare function unescape(input: string): string;
