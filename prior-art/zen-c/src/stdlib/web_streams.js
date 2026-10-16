// @ts-check
// --- Shared helpers -----------------------------------------

/**
 * Returns a Promise plus its resolve/reject as a single record so
 * async code can settle the promise from outside. Inside the executor
 * `r` and `j` are synchronously captured before it returns, so the
 * returned record's resolve/reject are always non-null at use time.
 * The JSDoc cast hand-asserts that shape (TS infers them as
 * `T | undefined` from the closed-over assignment, which would force
 * a non-null check on every caller).
 *
 * @returns {{ promise: Promise<any>,
 *             resolve: (value?: any) => void,
 *             reject:  (reason?: any) => void }}
 */
function deferred() {
  var r, j;
  var p = new Promise(function(res, rej) { r = res; j = rej; });
  return /** @type {any} */ ({ promise: p, resolve: r, reject: j });
}
function isCallable(x) { return typeof x === 'function'; }
function defaultSize(_chunk) { return 1; }
function callOrUndefined(fn, thisArg, args) {
  if (!isCallable(fn)) return undefined;
  return fn.apply(thisArg, args || []);
}

// =====================================================================
// ReadableStream
// =====================================================================
var ReadableStreamDefaultController = class {
  constructor(stream, underlyingSource, highWaterMark, sizeFn) {
    this.__stream = stream;
    this.__source = underlyingSource || {};
    this.__queue = [];
    this.__queueTotalSize = 0;
    this.__hwm = highWaterMark;
    this.__size = sizeFn || defaultSize;
    this.__started = false;
    this.__closeRequested = false;
    this.__pullAgain = false;
    this.__pulling = false;
  }
  get desiredSize() {
    var s = this.__stream.__state;
    if (s === 'errored') return null;
    if (s === 'closed')  return 0;
    return this.__hwm - this.__queueTotalSize;
  }
  enqueue(chunk) {
    if (this.__stream.__state !== 'readable') {
      throw new TypeError('Cannot enqueue on a closed/errored stream');
    }
    // BYOB: pending read requests carry {view, dfd}. Push the
    // chunk into the queue first and let the reader's fill-from-
    // queue logic copy bytes into pending views in order.
    var reader = this.__stream.__reader;
    if (reader && reader.__readRequests.length > 0
        && reader.__readRequests[0].view !== undefined) {
      this.__queue.push(chunk);
      this.__queueTotalSize = this.__queueTotalSize + (chunk.byteLength || 1);
      while (reader.__readRequests.length > 0 && this.__queue.length > 0) {
        var pending = reader.__readRequests[0];
        var filled = reader.__fillFromQueue(pending.view);
        if (!filled) break;
        reader.__readRequests.shift();
        pending.dfd.resolve(filled);
      }
      this.__callPullIfNeeded();
      return;
    }
    // Default reader: deliver directly without queueing.
    if (reader && reader.__readRequests.length > 0) {
      var req = reader.__readRequests.shift();
      req.resolve({ value: chunk, done: false });
      this.__callPullIfNeeded();
      return;
    }
    var sz = 1;
    try { sz = Number(this.__size(chunk)) || 0; } catch (e) { this.error(e); throw e; }
    this.__queue.push(chunk);
    this.__queueTotalSize = this.__queueTotalSize + sz;
    this.__callPullIfNeeded();
  }
  close() {
    if (this.__closeRequested) return;
    if (this.__stream.__state !== 'readable') return;
    this.__closeRequested = true;
    if (this.__queue.length === 0) this.__finishClose();
  }
  error(e) {
    if (this.__stream.__state !== 'readable') return;
    this.__queue = [];
    this.__queueTotalSize = 0;
    this.__stream.__errorStream(e);
  }
  __finishClose() {
    this.__stream.__closeStream();
  }
  __callPullIfNeeded() {
    if (!this.__started) return;
    if (this.__pulling) { this.__pullAgain = true; return; }
    if (this.__closeRequested) return;
    var reader = this.__stream.__reader;
    var hasPending = reader && reader.__readRequests.length > 0;
    var roomToPull = (this.__hwm - this.__queueTotalSize) > 0;
    if (!hasPending && !roomToPull) return;
    if (!isCallable(this.__source.pull)) return;
    var self = this;
    this.__pulling = true;
    this.__pullAgain = false;
    Promise.resolve()
      .then(function() { return self.__source.pull(self); })
      .then(function() {
        self.__pulling = false;
        if (self.__pullAgain) self.__callPullIfNeeded();
      }, function(err) {
        self.__pulling = false;
        self.error(err);
      });
  }
  __startSource() {
    var self = this;
    var startResult;
    try { startResult = callOrUndefined(this.__source.start, this.__source, [this]); }
    catch (e) { this.error(e); return; }
    Promise.resolve(startResult).then(function() {
      self.__started = true;
      self.__callPullIfNeeded();
    }, function(err) { self.error(err); });
  }
  __takeQueued() {
    if (this.__queue.length === 0) return undefined;
    var chunk = this.__queue.shift();
    this.__queueTotalSize = Math.max(0, this.__queueTotalSize - 1);
    if (this.__queue.length === 0 && this.__closeRequested) {
      this.__finishClose();
    } else {
      this.__callPullIfNeeded();
    }
    return { value: chunk, done: false };
  }
};

var ReadableStreamDefaultReader = class {
  constructor(stream) {
    if (stream.__reader) {
      throw new TypeError('Stream is already locked to a reader');
    }
    this.__stream = stream;
    this.__readRequests = [];
    this.__closedDfd = deferred();
    stream.__reader = this;
    if (stream.__state === 'closed') {
      this.__closedDfd.resolve(undefined);
    } else if (stream.__state === 'errored') {
      this.__closedDfd.reject(stream.__storedError);
    }
  }
  get closed() { return this.__closedDfd.promise; }
  read() {
    if (!this.__stream) {
      return Promise.reject(new TypeError('Reader is no longer attached'));
    }
    var s = this.__stream;
    if (s.__state === 'errored') return Promise.reject(s.__storedError);
    if (s.__state === 'readable') {
      var queued = s.__controller.__takeQueued();
      if (queued) return Promise.resolve(queued);
    }
    if (s.__state === 'closed' && s.__controller.__queue.length === 0) {
      return Promise.resolve({ value: undefined, done: true });
    }
    var d = deferred();
    this.__readRequests.push(d);
    s.__controller.__callPullIfNeeded();
    return d.promise;
  }
  releaseLock() {
    if (!this.__stream) return;
    if (this.__readRequests.length > 0) {
      throw new TypeError('Cannot release a reader with pending reads');
    }
    this.__stream.__reader = null;
    this.__stream = null;
    // closed promise rejects with TypeError per spec.
    this.__closedDfd.reject(new TypeError('Released reader'));
  }
  cancel(reason) {
    if (!this.__stream) return Promise.reject(new TypeError('Reader is no longer attached'));
    return this.__stream.cancel(reason);
  }
};

// BYOB (Bring Your Own Buffer) reader for `type: 'bytes'` streams.
// MVP: copies bytes from the controller's queued ArrayBufferView
// chunks into the caller's view. Producer-side byobRequest
// (zero-copy pull into the consumer's buffer) is deferred â the
// underlying source still uses enqueue(Uint8Array). This gives
// consumers the BYOB API surface (fetch().body.getReader({mode:'byob'})
// shape) without the full reference-implementation lift.
function bytesFrom(chunk) {
  // Coerce any ArrayBufferView to a Uint8Array view over the same
  // bytes. Required because the spec lets producers enqueue any
  // typed array but the BYOB reader works in raw bytes.
  if (chunk instanceof Uint8Array) return chunk;
  if (chunk && chunk.buffer instanceof ArrayBuffer) {
    return new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength);
  }
  return chunk;
}
var ReadableStreamBYOBReader = class {
  constructor(stream) {
    if (stream.__reader) {
      throw new TypeError('Stream is already locked to a reader');
    }
    this.__stream = stream;
    this.__readRequests = [];  // {view, dfd} entries
    this.__closedDfd = deferred();
    stream.__reader = this;
    if (stream.__state === 'closed') {
      this.__closedDfd.resolve(undefined);
    } else if (stream.__state === 'errored') {
      this.__closedDfd.reject(stream.__storedError);
    }
  }
  get closed() { return this.__closedDfd.promise; }
  read(view) {
    if (!this.__stream) {
      return Promise.reject(new TypeError('Reader is no longer attached'));
    }
    // Spec wants an ArrayBufferView; we currently expose only
    // Uint8Array (no shared `.buffer` accessor yet), so duck-type
    // on byteLength + indexable.
    if (!view || typeof view.byteLength !== 'number') {
      return Promise.reject(new TypeError('view must be an ArrayBufferView'));
    }
    if (view.byteLength === 0) {
      return Promise.reject(new TypeError('view byteLength is 0'));
    }
    var s = this.__stream;
    if (s.__state === 'errored') return Promise.reject(s.__storedError);
    var filled = this.__fillFromQueue(view);
    if (filled) return Promise.resolve(filled);
    if (s.__state === 'closed') {
      return Promise.resolve({ value: view.slice(0, 0), done: true });
    }
    var d = deferred();
    this.__readRequests.push({ view: view, dfd: d });
    s.__controller.__callPullIfNeeded();
    return d.promise;
  }
  // Copy bytes from the controller's queue into `view`, advancing
  // the front-of-queue chunk. Returns {value, done} with `value`
  // as view.subarray(0, have) â spec asks for a new view over the
  // same backing buffer; subarray gives an equivalent view that
  // works without exposing the raw ArrayBuffer.
  __fillFromQueue(view) {
    var ctrl = this.__stream.__controller;
    if (ctrl.__queue.length === 0) return null;
    var have = 0;
    var want = view.byteLength;
    while (have < want && ctrl.__queue.length > 0) {
      var head = ctrl.__queue[0];
      var take = Math.min(want - have, head.byteLength);
      for (var i = 0; i < take; i++) view[have + i] = head[i];
      have += take;
      if (take === head.byteLength) {
        ctrl.__queue.shift();
      } else {
        ctrl.__queue[0] = head.slice(take);
      }
      ctrl.__queueTotalSize = Math.max(0, ctrl.__queueTotalSize - take);
    }
    if (ctrl.__queue.length === 0 && ctrl.__closeRequested) {
      ctrl.__finishClose();
    } else {
      ctrl.__callPullIfNeeded();
    }
    if (have === 0) return null;
    return { value: view.slice(0, have), done: false };
  }
  releaseLock() {
    if (!this.__stream) return;
    if (this.__readRequests.length > 0) {
      throw new TypeError('Cannot release a reader with pending reads');
    }
    this.__stream.__reader = null;
    this.__stream = null;
    this.__closedDfd.reject(new TypeError('Released reader'));
  }
  cancel(reason) {
    if (!this.__stream) return Promise.reject(new TypeError('Reader is no longer attached'));
    return this.__stream.cancel(reason);
  }
};

var ReadableStream = class {
  constructor(underlyingSource, queuingStrategy) {
    underlyingSource = underlyingSource || {};
    queuingStrategy = queuingStrategy || {};
    var hwm = queuingStrategy.highWaterMark !== undefined
      ? Number(queuingStrategy.highWaterMark) : 1;
    var sizeFn = queuingStrategy.size;
    this.__state = 'readable';
    this.__storedError = undefined;
    this.__reader = null;
    // A `type: 'bytes'` source is a byte stream â enqueue only
    // accepts ArrayBufferViews and getReader({mode:'byob'}) is
    // allowed. Other types are reserved; v0.1 treats anything
    // non-bytes as the default stream.
    this.__isBytes = underlyingSource.type === 'bytes';
    this.__controller = new ReadableStreamDefaultController(
      this, underlyingSource, hwm, sizeFn);
    this.__controller.__startSource();
  }
  get locked() { return this.__reader !== null; }
  getReader(options) {
    if (options && options.mode === 'byob') {
      if (!this.__isBytes) {
        throw new TypeError("BYOB reader requires a 'bytes' stream");
      }
      return new ReadableStreamBYOBReader(this);
    }
    return new ReadableStreamDefaultReader(this);
  }
  cancel(reason) {
    if (this.__state === 'closed')  return Promise.resolve(undefined);
    if (this.__state === 'errored') return Promise.reject(this.__storedError);
    this.__controller.__queue = [];
    this.__controller.__queueTotalSize = 0;
    var src = this.__controller.__source;
    var self = this;
    var cancelResult;
    try { cancelResult = callOrUndefined(src.cancel, src, [reason]); }
    catch (e) { return Promise.reject(e); }
    this.__closeStream();
    return Promise.resolve(cancelResult).then(function() { return undefined; });
  }
  pipeTo(dest, options) {
    options = options || {};
    if (this.locked) return Promise.reject(new TypeError('Source is locked'));
    if (dest.locked) return Promise.reject(new TypeError('Destination is locked'));
    var src = this;
    var reader = src.getReader();
    var writer = dest.getWriter();
    var preventClose  = !!options.preventClose;
    var preventAbort  = !!options.preventAbort;
    var preventCancel = !!options.preventCancel;
    return new Promise(function(resolve, reject) {
      function pump() {
        reader.read().then(function(r) {
          if (r.done) {
            if (!preventClose) writer.close().then(resolve, reject);
            else resolve(undefined);
            return;
          }
          writer.write(r.value).then(pump, function(err) {
            if (!preventCancel) reader.cancel(err);
            reject(err);
          });
        }, function(err) {
          if (!preventAbort) writer.abort(err);
          reject(err);
        });
      }
      pump();
    });
  }
  pipeThrough(transform, options) {
    if (!transform || !transform.readable || !transform.writable) {
      throw new TypeError('pipeThrough requires { readable, writable }');
    }
    this.pipeTo(transform.writable, options).catch(function(){});
    return transform.readable;
  }
  // Split into two streams that observe the same chunks. Spec
  // ReadableStreamTee (default-reader case): pull from this once,
  // fan-out each chunk to both branches. Either branch's cancel
  // marks its side dead; only when both sides cancel do we cancel
  // the source. Errors mirror to both branches eagerly.
  tee() {
    if (this.locked) throw new TypeError('Source is locked');
    var reader = this.getReader();
    var c1, c2;
    var canceled1 = false, canceled2 = false;
    var reason1, reason2;
    var pulling = false;
    var cancelDfd;
    function pull() {
      if (pulling) return;
      pulling = true;
      reader.read().then(function(r) {
        pulling = false;
        if (r.done) {
          if (!canceled1) c1.close();
          if (!canceled2) c2.close();
          return;
        }
        if (!canceled1) c1.enqueue(r.value);
        if (!canceled2) c2.enqueue(r.value);
      }, function(err) {
        pulling = false;
        if (!canceled1) c1.error(err);
        if (!canceled2) c2.error(err);
      });
    }
    var b1 = new ReadableStream({
      start(ctrl) { c1 = ctrl; },
      pull() { pull(); },
      cancel(reason) {
        canceled1 = true; reason1 = reason;
        if (canceled2) {
          var p = reader.cancel(reason);
          if (cancelDfd) { cancelDfd.resolve(p); cancelDfd = undefined; }
          return p;
        }
        if (!cancelDfd) cancelDfd = deferred();
        return cancelDfd.promise;
      },
    });
    var b2 = new ReadableStream({
      start(ctrl) { c2 = ctrl; },
      pull() { pull(); },
      cancel(reason) {
        canceled2 = true; reason2 = reason;
        if (canceled1) {
          var p = reader.cancel(reason);
          if (cancelDfd) { cancelDfd.resolve(p); cancelDfd = undefined; }
          return p;
        }
        if (!cancelDfd) cancelDfd = deferred();
        return cancelDfd.promise;
      },
    });
    return [b1, b2];
  }
  __closeStream() {
    if (this.__state !== 'readable') return;
    this.__state = 'closed';
    if (this.__reader) {
      while (this.__reader.__readRequests.length > 0) {
        var req = this.__reader.__readRequests.shift();
        if (req.view !== undefined) {
          // BYOB pending read: spec says resolve with a zero-length
          // view + done:true (consumer detects end via byteLength).
          req.dfd.resolve({ value: req.view.slice(0, 0), done: true });
        } else {
          req.resolve({ value: undefined, done: true });
        }
      }
      this.__reader.__closedDfd.resolve(undefined);
    }
  }
  __errorStream(e) {
    if (this.__state !== 'readable') return;
    this.__state = 'errored';
    this.__storedError = e;
    if (this.__reader) {
      while (this.__reader.__readRequests.length > 0) {
        var req = this.__reader.__readRequests.shift();
        if (req.view !== undefined) { req.dfd.reject(e); }
        else { req.reject(e); }
      }
      this.__reader.__closedDfd.reject(e);
    }
  }
  [Symbol.asyncIterator]() {
    var reader = this.getReader();
    return {
      next: function() {
        return reader.read().then(function(r) {
          if (r.done) reader.releaseLock();
          return r;
        }, function(err) { reader.releaseLock(); throw err; });
      },
      return: function(value) {
        return reader.cancel(value).then(function() {
          reader.releaseLock();
          return { value: value, done: true };
        });
      },
      [Symbol.asyncIterator]: function() { return this; },
    };
  }
};

// =====================================================================
// WritableStream
// =====================================================================
var WritableStreamDefaultController = class {
  constructor(stream, underlyingSink, highWaterMark, sizeFn) {
    this.__stream = stream;
    this.__sink = underlyingSink || {};
    this.__queue = [];
    this.__queueTotalSize = 0;
    this.__hwm = highWaterMark;
    this.__size = sizeFn || defaultSize;
    this.__started = false;
    this.__writing = false;
  }
  error(e) {
    if (this.__stream.__state !== 'writable') return;
    this.__queue = [];
    this.__queueTotalSize = 0;
    this.__stream.__errorStream(e);
  }
  __startSink() {
    var self = this;
    var sr;
    try { sr = callOrUndefined(this.__sink.start, this.__sink, [this]); }
    catch (e) { this.error(e); return; }
    Promise.resolve(sr).then(function() {
      self.__started = true;
      self.__advance();
    }, function(err) { self.error(err); });
  }
  __enqueue(chunk, dfd) {
    var sz = 1;
    try { sz = Number(this.__size(chunk)) || 0; }
    catch (e) { this.error(e); dfd.reject(e); return; }
    this.__queue.push({ chunk: chunk, dfd: dfd });
    this.__queueTotalSize = this.__queueTotalSize + sz;
    if (this.__started && !this.__writing) this.__advance();
  }
  __advance() {
    if (this.__writing) return;
    if (this.__queue.length === 0) {
      // Resolve any pending close.
      var st = this.__stream;
      if (st.__closeRequested) {
        var sink = this.__sink;
        var self = this;
        var cr;
        try { cr = callOrUndefined(sink.close, sink, []); }
        catch (e) { st.__closeRequest && st.__closeRequest.reject(e); this.error(e); return; }
        Promise.resolve(cr).then(function() {
          st.__state = 'closed';
          if (st.__closeRequest) st.__closeRequest.resolve(undefined);
          if (st.__writer) st.__writer.__closedDfd.resolve(undefined);
        }, function(err) {
          self.error(err);
          if (st.__closeRequest) st.__closeRequest.reject(err);
        });
      }
      return;
    }
    var entry = this.__queue.shift();
    this.__queueTotalSize = Math.max(0, this.__queueTotalSize - 1);
    this.__writing = true;
    var sink = this.__sink;
    var self = this;
    Promise.resolve()
      .then(function() { return callOrUndefined(sink.write, sink, [entry.chunk, self]); })
      .then(function() {
        self.__writing = false;
        entry.dfd.resolve(undefined);
        self.__advance();
      }, function(err) {
        self.__writing = false;
        entry.dfd.reject(err);
        self.error(err);
      });
  }
};

var WritableStreamDefaultWriter = class {
  constructor(stream) {
    if (stream.__writer) {
      throw new TypeError('Stream is already locked to a writer');
    }
    this.__stream = stream;
    this.__closedDfd = deferred();
    this.__readyDfd  = deferred();
    stream.__writer = this;
    if (stream.__state === 'writable') this.__readyDfd.resolve(undefined);
    else if (stream.__state === 'closed') {
      this.__readyDfd.resolve(undefined);
      this.__closedDfd.resolve(undefined);
    } else if (stream.__state === 'errored') {
      this.__readyDfd.reject(stream.__storedError);
      this.__closedDfd.reject(stream.__storedError);
    }
  }
  get closed() { return this.__closedDfd.promise; }
  get ready()  { return this.__readyDfd.promise; }
  get desiredSize() {
    var s = this.__stream.__state;
    if (s === 'errored' || s === 'erroring') return null;
    if (s === 'closed') return 0;
    return this.__stream.__controller.__hwm - this.__stream.__controller.__queueTotalSize;
  }
  write(chunk) {
    if (!this.__stream) return Promise.reject(new TypeError('Writer is no longer attached'));
    var s = this.__stream;
    if (s.__state === 'errored') return Promise.reject(s.__storedError);
    if (s.__state !== 'writable') return Promise.reject(new TypeError('Stream is not writable'));
    var d = deferred();
    s.__controller.__enqueue(chunk, d);
    return d.promise;
  }
  close() {
    if (!this.__stream) return Promise.reject(new TypeError('Writer is no longer attached'));
    var s = this.__stream;
    if (s.__state === 'errored') return Promise.reject(s.__storedError);
    if (s.__state !== 'writable') return Promise.reject(new TypeError('Stream is not writable'));
    s.__closeRequested = true;
    var d = deferred();
    s.__closeRequest = d;
    s.__controller.__advance();
    return d.promise;
  }
  abort(reason) {
    if (!this.__stream) return Promise.reject(new TypeError('Writer is no longer attached'));
    return this.__stream.abort(reason);
  }
  releaseLock() {
    if (!this.__stream) return;
    this.__stream.__writer = null;
    this.__stream = null;
    this.__closedDfd.reject(new TypeError('Released writer'));
    this.__readyDfd.reject(new TypeError('Released writer'));
  }
};

var WritableStream = class {
  constructor(underlyingSink, queuingStrategy) {
    underlyingSink = underlyingSink || {};
    queuingStrategy = queuingStrategy || {};
    var hwm = queuingStrategy.highWaterMark !== undefined
      ? Number(queuingStrategy.highWaterMark) : 1;
    var sizeFn = queuingStrategy.size;
    this.__state = 'writable';
    this.__storedError = undefined;
    this.__writer = null;
    this.__closeRequested = false;
    this.__closeRequest = null;
    this.__controller = new WritableStreamDefaultController(
      this, underlyingSink, hwm, sizeFn);
    this.__controller.__startSink();
  }
  get locked() { return this.__writer !== null; }
  getWriter() { return new WritableStreamDefaultWriter(this); }
  close() {
    if (this.locked) return Promise.reject(new TypeError('Cannot close a locked stream'));
    var w = this.getWriter();
    var p = w.close();
    w.releaseLock();
    return p;
  }
  abort(reason) {
    if (this.__state === 'closed')  return Promise.resolve(undefined);
    if (this.__state === 'errored') return Promise.reject(this.__storedError);
    var sink = this.__controller.__sink;
    var self = this;
    var ar;
    try { ar = callOrUndefined(sink.abort, sink, [reason]); }
    catch (e) { return Promise.reject(e); }
    return Promise.resolve(ar).then(function() {
      self.__errorStream(reason !== undefined ? reason
        : new TypeError('Aborted with no reason'));
    });
  }
  __errorStream(e) {
    if (this.__state !== 'writable') return;
    this.__state = 'errored';
    this.__storedError = e;
    var w = this.__writer;
    if (w) {
      w.__closedDfd.reject(e);
      w.__readyDfd.reject(e);
    }
    // Reject any queued writes still in the controller.
    var q = this.__controller.__queue;
    while (q.length > 0) {
      var entry = q.shift();
      entry.dfd.reject(e);
    }
    this.__controller.__queueTotalSize = 0;
    if (this.__closeRequest) this.__closeRequest.reject(e);
  }
};

// =====================================================================
// TransformStream â connects a writable side to a readable side via
// a transformer { start, transform, flush }. Backpressure is just
// the readable side's queueing strategy; the writable side awaits
// transform completion.
// =====================================================================
var TransformStreamDefaultController = class {
  constructor(transformStream, transformer) {
    this.__ts = transformStream;
    this.__transformer = transformer || {};
  }
  get desiredSize() {
    return this.__ts.readable.__controller.desiredSize;
  }
  enqueue(chunk) {
    this.__ts.readable.__controller.enqueue(chunk);
  }
  error(e) {
    this.__ts.readable.__controller.error(e);
    this.__ts.writable.__errorStream(e);
  }
  terminate() {
    this.__ts.readable.__controller.close();
  }
};

var TransformStream = class {
  constructor(transformer, writableStrategy, readableStrategy) {
    transformer = transformer || {};
    writableStrategy = writableStrategy || {};
    readableStrategy = readableStrategy || {};
    var ts = this;
    // The two streams share a controller that bridges between them.
    this.__controller = new TransformStreamDefaultController(this, transformer);
    var ctrl = this.__controller;
    this.readable = new ReadableStream({
      start: function(c) {
        // Stash readable controller so the TS controller can enqueue.
        // ReadableStream already wires its own; nothing to do here.
      },
      pull: function() { /* writable side drives */ },
      cancel: function(reason) {
        ts.writable.__errorStream(reason);
      },
    }, readableStrategy);
    this.writable = new WritableStream({
      start: function() {
        try { return callOrUndefined(transformer.start, transformer, [ctrl]); }
        catch (e) { ctrl.error(e); throw e; }
      },
      write: function(chunk) {
        var t = transformer.transform;
        if (!isCallable(t)) { ctrl.enqueue(chunk); return Promise.resolve(); }
        try {
          var r = t(chunk, ctrl);
          return Promise.resolve(r);
        } catch (e) { ctrl.error(e); return Promise.reject(e); }
      },
      close: function() {
        var f = transformer.flush;
        var p = isCallable(f) ? Promise.resolve().then(function() { return f(ctrl); })
                              : Promise.resolve();
        return p.then(function() { ctrl.terminate(); });
      },
      abort: function(reason) { ctrl.error(reason); },
    }, writableStrategy);
  }
};

// =====================================================================
// Queuing strategies â minimal versions of CountQueuingStrategy and
// ByteLengthQueuingStrategy. Most consumers either pass {highWaterMark}
// directly or use these classes; we expose both shapes.
// =====================================================================
var CountQueuingStrategy = class {
  constructor(init) {
    this.highWaterMark = init && init.highWaterMark !== undefined
      ? Number(init.highWaterMark) : 1;
  }
  size(_chunk) { return 1; }
};
var ByteLengthQueuingStrategy = class {
  constructor(init) {
    this.highWaterMark = init && init.highWaterMark !== undefined
      ? Number(init.highWaterMark) : 1;
  }
  size(chunk) {
    if (chunk && typeof chunk.byteLength === 'number') return chunk.byteLength;
    if (chunk && typeof chunk.length === 'number') return chunk.length;
    return 1;
  }
};

// =====================================================================
// TextEncoderStream / TextDecoderStream â WinterTC encoding-stream pair.
// Built on TransformStream over the existing TextEncoder/TextDecoder.
// Note: our TextDecoder doesn't preserve partial UTF-8 sequences across
// decode() calls, so split multi-byte chars across chunks will mis-decode.
// Good enough for the common case (ASCII-heavy data, whole-chunk-at-a-time).
// =====================================================================
var TextEncoderStream = class {
  constructor() {
    var encoder = new TextEncoder();
    this.__encoder = encoder;
    this.__ts = new TransformStream({
      transform(chunk, controller) {
        controller.enqueue(encoder.encode(String(chunk)));
      }
    });
  }
  get encoding() { return 'utf-8'; }
  get readable() { return this.__ts.readable; }
  get writable() { return this.__ts.writable; }
};

var TextDecoderStream = class {
  constructor(label, options) {
    var decoder = new TextDecoder(label, options);
    this.__decoder = decoder;
    this.__ts = new TransformStream({
      transform(chunk, controller) {
        var s = decoder.decode(chunk);
        if (s) controller.enqueue(s);
      }
    });
  }
  get encoding()  { return this.__decoder.encoding; }
  get fatal()     { return this.__decoder.fatal; }
  get ignoreBOM() { return this.__decoder.ignoreBOM; }
  get readable()  { return this.__ts.readable; }
  get writable()  { return this.__ts.writable; }
};
