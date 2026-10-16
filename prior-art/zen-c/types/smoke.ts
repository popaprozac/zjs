// Type-only smoke test. Compiled with `tsc -p tsconfig.smoke.json` to
// validate the consumer-facing surface end-to-end. Not shipped in the
// package (excluded via package.json's `files` field).

import fs from 'node:fs/promises';
import * as fsSync from 'node:fs';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import assert from 'node:assert';
import { createServer as createNetServer } from 'node:net';
import { createServer as createHttpServer, type IncomingMessage } from 'node:http';
import { spawnSync } from 'node:child_process';

// Ambient globals ----------------------------------------------------

const r: Response = await fetch('https://example.com');
const _body: ReadableStream<Uint8Array> | null = r.body;

const u = new URL('https://example.com/x?y=1');
const _host: string = u.hostname;

const enc = new TextEncoder();
const _bytes: Uint8Array = enc.encode('hi');

const stream = new TransformStream<string, string>();
const _writable: WritableStream<string> = stream.writable;

const ac = new AbortController();
ac.abort();
const _aborted: boolean = ac.signal.aborted;

// Performance User Timing --------------------------------------------

const mark = performance.mark('start');
const _markName: string = mark.name;
performance.measure('m', { start: 0, end: performance.now(), detail: { tag: 1 } });
const entries = performance.getEntriesByType('measure');
const _firstDur: number = entries[0]?.duration ?? 0;
performance.clearMarks();

// process global -----------------------------------------------------

const _argv: string[] = process.argv;
const _hr: bigint = process.hrtime.bigint();
process.nextTick(() => {});

// node:fs ------------------------------------------------------------

const s = await fs.readFile('/tmp/x', 'utf-8');
const _sLen: number = s.length;
const stats = fsSync.statSync('/tmp/x');
const _isDir: boolean = stats.isDirectory();
fsSync.accessSync('/tmp/x', fsSync.R_OK);

// node:path ----------------------------------------------------------

const _joined: string = path.join('/a', 'b', 'c');
const _parsed = path.parse('/a/b.txt');
const _ext: string = _parsed.ext;

// node:events --------------------------------------------------------

class Bus extends EventEmitter {}
new Bus().on('x', () => {}).emit('x', 1, 2);

// node:assert --------------------------------------------------------

assert.ok(true);
assert.strictEqual(1, 1);

// node:net / node:http -----------------------------------------------

const nServer = createNetServer((sock) => {
  sock.write('hi');
  sock.end();
});
nServer.listen(0);

const hServer = createHttpServer((req: IncomingMessage, res) => {
  res.writeHead(200);
  res.end(JSON.stringify({ method: req.method }));
});
hServer.listen(0);

// node:child_process -------------------------------------------------

const sp = spawnSync('echo', ['hi']);
const _status: number | null = sp.status;
