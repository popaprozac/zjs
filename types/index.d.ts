// zjs-types — TypeScript declarations for the zjs JavaScript engine.
//
// What this provides:
//   - Ambient globals: WinterTC web globals (fetch/URL/Headers/streams/
//     crypto/encoding/timers/EventTarget/AbortController/Blob/…) plus
//     zjs-specific extras (the `process` global, performance User Timing
//     entries).
//   - `declare module 'node:<name>'` shims for every `node:` module zjs
//     ships. The surface tracks what we actually expose, not full Node —
//     things zjs doesn't implement aren't typed.
//
// Usage:
//   1. npm install --save-dev zjs-types
//   2. In tsconfig.json:  "types": ["zjs-types"]
//
// Each sub-module is a separate file so the surface is easy to audit
// and update as the engine evolves.

/// <reference path="./globals.d.ts" />

/// <reference path="./node-fs.d.ts" />
/// <reference path="./node-path.d.ts" />
/// <reference path="./node-process.d.ts" />
/// <reference path="./node-os.d.ts" />
/// <reference path="./node-tty.d.ts" />
/// <reference path="./node-events.d.ts" />
/// <reference path="./node-util.d.ts" />
/// <reference path="./node-assert.d.ts" />
/// <reference path="./node-net.d.ts" />
/// <reference path="./node-http.d.ts" />
/// <reference path="./node-child_process.d.ts" />
