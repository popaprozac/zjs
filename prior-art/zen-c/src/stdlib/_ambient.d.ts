// Minimal ambient declarations for the stdlib bootstrap files. Just
// enough to let `tsc -p tsconfig.stdlib.json` type-check our own .js
// without the full WebWorker lib (which conflicts with the stdlib
// re-implementations of Blob/EventTarget/etc and triggers a TS
// internal crash on the `class X extends EventTarget` pattern).
//
// Anything declared here is something zjs provides at runtime but
// we don't import via lib. Keep it tight — adding the real spec
// shape from lib.webworker.d.ts is the wrong move; we just need
// names to resolve so typo-catching works inside .js bodies.

declare var performance: {
  now(): number;
  timeOrigin: number;
  mark?: any;
  measure?: any;
  clearMarks?: any;
  clearMeasures?: any;
  getEntries?: any;
  getEntriesByName?: any;
  getEntriesByType?: any;
};

declare function setTimeout(cb: (...args: any[]) => any, ms?: number, ...args: any[]): any;
declare function clearTimeout(id: any): void;
declare function setInterval(cb: (...args: any[]) => any, ms?: number, ...args: any[]): any;
declare function clearInterval(id: any): void;
declare function queueMicrotask(cb: () => any): void;
declare function reportError(err: any): void;

// Encoding — re-implemented in web_blob.js / web_streams.js, but the
// host versions also exist. Use `any` here so we don't shadow either.
declare var TextEncoder: any;
declare var TextDecoder: any;

// DOMException — defined in web_events.js. Mark optional so check
// works on files that reference it before web_events runs.
declare var DOMException: any;

// console — present in zjs core.
declare var console: {
  log(...args: any[]): void;
  warn(...args: any[]): void;
  error(...args: any[]): void;
  info(...args: any[]): void;
  debug(...args: any[]): void;
};

// `Blob` / `File` / `FormData` — declared by web_blob.js. Same
// pattern as above: shadow with `any` so cross-file references
// don't trip.
declare var Blob: any;
declare var File: any;
declare var FormData: any;

// AbortSignal / AbortController — declared by web_abort.js.
declare var AbortSignal: any;
declare var AbortController: any;

// Stream globals — declared by web_streams.js.
declare var ReadableStream: any;
declare var WritableStream: any;
declare var TransformStream: any;
declare var ReadableStreamDefaultController: any;
declare var ReadableStreamDefaultReader: any;
declare var ReadableStreamBYOBReader: any;
declare var TextEncoderStream: any;
declare var TextDecoderStream: any;
declare var CountQueuingStrategy: any;
declare var ByteLengthQueuingStrategy: any;

// Event / EventTarget / CustomEvent — declared by web_events.js.
declare var Event: any;
declare var CustomEvent: any;
declare var EventTarget: any;

// structuredClone is declared in web_clone.js itself — don't shadow.
