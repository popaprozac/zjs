// node:stream — classic Node streams (pragmatic subset).
//
// Readable / Writable / Duplex / Transform / PassThrough built on a
// small inlined EventEmitter. Flowing + paused read modes, pipe, async
// iteration, Readable.from, simplified highWaterMark backpressure, plus
// pipeline() and finished(). Not byte-exact with Node internals, but
// covers the common on('data')/pipe/write/end/Transform usage.
//
// Two engine workarounds shape the structure: every class carries an
// explicit `constructor(...){ super(...) }` (default derived ctors in a
// 3+ level chain mis-handle the super-call — task #322), and the
// writable methods are shared free functions invoked from both Writable
// and Duplex rather than grafted onto a prototype (assigning to
// D.prototype[x] then `class T extends D` breaks subclassing — #323).

const nextTick = (globalThis.process && globalThis.process.nextTick)
  ? globalThis.process.nextTick
  : (fn, ...a) => queueMicrotask(() => fn(...a));

class EventEmitter {
  constructor() { this._events = Object.create(null); }
  on(ev, fn) { (this._events[ev] || (this._events[ev] = [])).push(fn); return this; }
  addListener(ev, fn) { return this.on(ev, fn); }
  prependListener(ev, fn) { (this._events[ev] || (this._events[ev] = [])).unshift(fn); return this; }
  once(ev, fn) {
    const self = this;
    function g(...a) { self.removeListener(ev, g); return fn.apply(this, a); }
    g.listener = fn;
    return this.on(ev, g);
  }
  removeListener(ev, fn) {
    const l = this._events[ev];
    if (l) { const i = l.findIndex(x => x === fn || x.listener === fn); if (i >= 0) l.splice(i, 1); }
    return this;
  }
  off(ev, fn) { return this.removeListener(ev, fn); }
  removeAllListeners(ev) { if (ev === undefined) this._events = Object.create(null); else delete this._events[ev]; return this; }
  listeners(ev) { return (this._events[ev] || []).slice(); }
  listenerCount(ev) { return (this._events[ev] || []).length; }
  emit(ev, ...args) {
    const l = this._events[ev];
    if (!l || l.length === 0) {
      if (ev === "error") throw (args[0] instanceof Error ? args[0] : new Error("Unhandled 'error' event"));
      return false;
    }
    for (const fn of l.slice()) fn.apply(this, args);
    return true;
  }
}

class Stream extends EventEmitter {
  constructor() { super(); }
}

// ============ Readable-side helpers (shared by Readable + Duplex) ============
function initReadable(self, opts) {
  self._readableState = {
    buffer: [], flowing: null, ended: false, endEmitted: false,
    reading: false, destroyed: false,
    objectMode: !!opts.objectMode,
    highWaterMark: opts.highWaterMark != null ? opts.highWaterMark : (opts.objectMode ? 16 : 16384),
  };
  self.readable = true;
  if (typeof opts.read === "function") self._read = opts.read;
}
function rPush(self, chunk, enc) {
  const s = self._readableState;
  if (chunk === null) {
    s.ended = true;
    if (s.buffer.length === 0) rEnd(self);
    else if (s.flowing) rFlow(self);
    else self.emit("readable");
    return false;
  }
  if (typeof chunk === "string" && !s.objectMode && globalThis.Buffer) chunk = Buffer.from(chunk, enc);
  s.buffer.push(chunk);
  if (s.flowing) rFlow(self);
  else self.emit("readable");
  return s.buffer.length < s.highWaterMark;
}
function rEnd(self) {
  const s = self._readableState;
  if (s.endEmitted) return;
  s.endEmitted = true; self.readable = false;
  nextTick(() => self.emit("end"));
}
function rFlow(self) {
  const s = self._readableState;
  while (s.flowing && s.buffer.length > 0) self.emit("data", s.buffer.shift());
  if (s.flowing && s.ended && s.buffer.length === 0) rEnd(self);
}
function rResume(self) {
  const s = self._readableState;
  if (!s.flowing) { s.flowing = true; self.emit("resume"); nextTick(() => rFlow(self)); }
  return self;
}
function rPipe(src, dest, opts) {
  opts = opts || {};
  src.on("data", (chunk) => {
    if (dest.write(chunk) === false) { src.pause(); dest.once("drain", () => src.resume()); }
  });
  if (opts.end !== false) src.once("end", () => dest.end());
  src.once("error", (e) => { if (dest.destroy) dest.destroy(e); });
  dest.emit("pipe", src);
  return dest;
}
function rAsyncIterator(src) {
  const pending = []; let pres = null, done = false, error = null;
  src.on("data", (c) => { if (pres) { const r = pres; pres = null; r({ value: c, done: false }); } else pending.push(c); });
  src.once("end", () => { done = true; if (pres) { const r = pres; pres = null; r({ value: undefined, done: true }); } });
  src.once("error", (e) => { error = e; if (pres) { const r = pres; pres = null; r(Promise.reject(e)); } });
  return {
    next() {
      if (error) return Promise.reject(error);
      if (pending.length > 0) return Promise.resolve({ value: pending.shift(), done: false });
      if (done) return Promise.resolve({ value: undefined, done: true });
      return new Promise((res) => { pres = res; });
    },
    [Symbol.asyncIterator]() { return this; },
  };
}

// Mixin: install Readable's instance methods on a prototype object.
function applyReadableMethods(proto) {
  proto._read = function (_n) {};
  proto.push = function (chunk, enc) { return rPush(this, chunk, enc); };
  proto.read = function (_n) {
    const s = this._readableState;
    if (s.buffer.length > 0) { const c = s.buffer.shift(); if (s.ended && s.buffer.length === 0) rEnd(this); return c; }
    if (!s.ended && !s.reading) { s.reading = true; try { this._read(s.highWaterMark); } finally { s.reading = false; } if (s.buffer.length > 0) return s.buffer.shift(); }
    if (s.ended) rEnd(this);
    return null;
  };
  proto.pause = function () { this._readableState.flowing = false; this.emit("pause"); return this; };
  proto.resume = function () { return rResume(this); };
  proto.isPaused = function () { return this._readableState.flowing === false; };
  proto.pipe = function (dest, opts) { return rPipe(this, dest, opts); };
  proto.unpipe = function () { this.removeAllListeners("data"); return this; };
  proto.on = function (ev, fn) {
    EventEmitter.prototype.on.call(this, ev, fn);
    if (ev === "data") { if (this._readableState.flowing !== false) rResume(this); }
    else if (ev === "readable") { const s = this._readableState; if (!s.reading && !s.ended) nextTick(() => { try { this._read(s.highWaterMark); } catch (e) { this.destroy(e); } }); }
    return this;
  };
  proto.addListener = proto.on;
  proto.destroy = function (err) {
    const s = this._readableState;
    if (s.destroyed) return this;
    s.destroyed = true; this.readable = false;
    (this._destroy || ((e, cb) => cb(e))).call(this, err || null, (e) => { if (e) this.emit("error", e); this.emit("close"); });
    return this;
  };
  proto[Symbol.asyncIterator] = function () { return rAsyncIterator(this); };
}

// ============ Writable-side helpers (shared by Writable + Duplex) ============
function initWritable(self, opts) {
  self._writableState = {
    ended: false, finished: false, destroyed: false, needDrain: false,
    objectMode: !!opts.objectMode,
    highWaterMark: opts.highWaterMark != null ? opts.highWaterMark : (opts.objectMode ? 16 : 16384),
    buffered: 0,
  };
  self.writable = true;
  if (typeof opts.write === "function") self._write = opts.write;
  if (typeof opts.final === "function") self._final = opts.final;
}
function applyWritableMethods(proto) {
  proto._write = function (_chunk, _enc, cb) { cb(); };
  proto._final = function (cb) { cb(); };
  proto.write = function (chunk, enc, cb) {
    if (typeof enc === "function") { cb = enc; enc = undefined; }
    const s = this._writableState;
    if (s.ended) { const e = new Error("write after end"); if (cb) nextTick(cb, e); else this.emit("error", e); return false; }
    if (typeof chunk === "string" && !s.objectMode && globalThis.Buffer) chunk = Buffer.from(chunk, enc);
    const sz = (chunk && chunk.length) || 1;
    s.buffered += sz;
    let called = false;
    const done = (err) => {
      if (called) return; called = true;
      s.buffered -= sz;
      if (cb) cb(err);
      if (err) { this.emit("error", err); return; }
      if (s.needDrain && s.buffered < s.highWaterMark) { s.needDrain = false; this.emit("drain"); }
    };
    try { this._write(chunk, enc, done); } catch (e) { done(e); }
    if (s.buffered >= s.highWaterMark) { s.needDrain = true; return false; }
    return true;
  };
  proto.end = function (chunk, enc, cb) {
    if (typeof chunk === "function") { cb = chunk; chunk = undefined; }
    else if (typeof enc === "function") { cb = enc; enc = undefined; }
    const s = this._writableState;
    if (chunk != null) this.write(chunk, enc);
    if (s.ended) { if (cb) nextTick(cb); return this; }
    s.ended = true; this.writable = false;
    this._final((err) => {
      if (err) { this.emit("error", err); return; }
      s.finished = true;
      if (cb) cb();
      this.emit("finish");
    });
    return this;
  };
  proto.cork = function () {};
  proto.uncork = function () {};
}

// ============ classes ============
class Readable extends Stream {
  constructor(opts = {}) { super(); initReadable(this, opts); if (typeof opts.destroy === "function") this._destroy = opts.destroy; }
  static from(iterable, opts) {
    const r = new Readable({ objectMode: true, ...(opts || {}), read() {} });
    (async () => {
      try { for await (const chunk of iterable) r.push(chunk); r.push(null); }
      catch (e) { r.destroy(e); }
    })();
    return r;
  }
}
applyReadableMethods(Readable.prototype);

class Writable extends Stream {
  constructor(opts = {}) { super(); initWritable(this, opts); if (typeof opts.destroy === "function") this._destroy = opts.destroy; }
  destroy(err) {
    const s = this._writableState;
    if (s.destroyed) return this;
    s.destroyed = true; this.writable = false;
    (this._destroy || ((e, cb) => cb(e))).call(this, err || null, (e) => { if (e) this.emit("error", e); this.emit("close"); });
    return this;
  }
}
applyWritableMethods(Writable.prototype);

class Duplex extends Readable {
  constructor(opts = {}) { super(opts); initWritable(this, opts); this.allowHalfOpen = opts.allowHalfOpen !== false; }
}
applyWritableMethods(Duplex.prototype);

class Transform extends Duplex {
  constructor(opts = {}) {
    super(opts);
    if (typeof opts.transform === "function") this._transform = opts.transform;
    if (typeof opts.flush === "function") this._flush = opts.flush;
  }
  _transform(chunk, _enc, cb) { cb(null, chunk); }
  _flush(cb) { cb(); }
  _write(chunk, enc, cb) {
    this._transform(chunk, enc, (err, data) => {
      if (err) return cb(err);
      if (data != null) this.push(data);
      cb();
    });
  }
  _final(cb) {
    this._flush((err, data) => {
      if (err) return cb(err);
      if (data != null) this.push(data);
      this.push(null);
      cb();
    });
  }
}

class PassThrough extends Transform {
  constructor(opts = {}) { super(opts); }
}

// ============ helpers ============
function finished(stream, cb) {
  let called = false;
  const done = (err) => { if (called) return; called = true; nextTick(cb, err || null); };
  stream.once("end", () => done());
  stream.once("finish", () => done());
  stream.once("close", () => done());
  stream.once("error", (e) => done(e));
  return () => { called = true; };
}
function pipeline(...args) {
  let cb = args[args.length - 1];
  if (typeof cb === "function") args = args.slice(0, -1); else cb = () => {};
  let errored = false;
  const fail = (e) => { if (errored) return; errored = true; cb(e); };
  for (let i = 0; i < args.length - 1; i++) args[i].pipe(args[i + 1]);
  for (const s of args) if (s.once) s.once("error", fail);
  const last = args[args.length - 1];
  last.once("finish", () => { if (!errored) cb(null); });
  last.once("end", () => { if (!errored) cb(null); });
  return last;
}

Stream.Readable = Readable;
Stream.Writable = Writable;
Stream.Duplex = Duplex;
Stream.Transform = Transform;
Stream.PassThrough = PassThrough;
Stream.Stream = Stream;
Stream.EventEmitter = EventEmitter;
Stream.finished = finished;
Stream.pipeline = pipeline;

export { Readable, Writable, Duplex, Transform, PassThrough, Stream, finished, pipeline };
export default Stream;
