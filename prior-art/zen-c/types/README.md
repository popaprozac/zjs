# zjs-types

TypeScript declarations for the [zjs](https://github.com/popaprozac/zjs)
JavaScript engine: ambient globals plus `node:` module shims.

## Install

```bash
npm install --save-dev zjs-types
```

## Use

In your `tsconfig.json`:

```jsonc
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "types": ["zjs-types"]
  }
}
```

That's it — your project now sees `fetch`, `URL`, `performance.mark`,
`process`, `import * as fs from 'node:fs'`, etc.

## What you get

### Ambient globals

The bulk of the WinterTC surface (fetch, URL, Headers, streams, crypto,
encoding, AbortController, EventTarget, Blob, structuredClone, timers,
console, btoa/atob, queueMicrotask, …) comes from TypeScript's
`lib.webworker.d.ts` via a triple-slash reference. zjs-specific
additions on top:

- `process` — Node-style global with `argv`/`env`/`platform`/`arch`/
  `pid`/`versions`/`cwd`/`chdir`/`exit`/`hrtime`/`nextTick`/`stdout`/
  `stderr`
- `performance.mark` / `measure` / `clearMarks` / `clearMeasures` /
  `getEntries` / `getEntriesByName` / `getEntriesByType` — User
  Timing Level 3 layered on top of `performance.now`
- `escape` / `unescape` — Annex B legacy globals
- `TextEncoderStream` / `TextDecoderStream` — encoding-stream pair

### `node:` modules

One `declare module 'node:xxx'` per built-in zjs ships. Each typed to
the surface zjs actually exposes — not full Node:

- `node:fs` + `node:fs/promises`
- `node:path` (POSIX only)
- `node:process`
- `node:os`
- `node:tty`
- `node:events` (EventEmitter)
- `node:util` (promisify, callbackify, inspect, format, types)
- `node:assert`
- `node:net` (TCP server-side only)
- `node:http` (HTTP/1.1 server-side only)
- `node:child_process` (sync trio + thin async wrappers)

## Versioning

The types track the engine they came from. Use the same major as your
zjs runtime; minor versions follow zjs minors. Breaking type changes
happen only on a major bump even if the runtime API is forwards-compatible.

## Spec gaps

These types describe what zjs implements *today*. Things that aren't
typed here aren't shipped — file an issue if a surface you need is
missing and we'll either add it or document why it's deliberately out
of scope.
