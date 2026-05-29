// @ts-check
var AbortSignal = class extends EventTarget {
  constructor() {
    super();
    this.aborted = false;
    this.reason = undefined;
    this.onabort = null;
  }
  throwIfAborted() {
    if (this.aborted) throw this.reason;
  }
  static abort(reason) {
    var s = new AbortSignal();
    s.aborted = true;
    s.reason = reason === undefined
      ? new DOMException('signal is aborted without reason', 'AbortError')
      : reason;
    return s;
  }
  static timeout(ms) {
    var s = new AbortSignal();
    setTimeout(function() {
      if (s.aborted) return;
      s.aborted = true;
      s.reason = new DOMException('signal timed out', 'TimeoutError');
      try { s.dispatchEvent(new Event('abort')); }
      catch (e) { reportError(e); }
      if (typeof s.onabort === 'function') {
        try { s.onabort.call(s, new Event('abort')); }
        catch (e) { reportError(e); }
      }
    }, ms);
    return s;
  }
  static any(signals) {
    var composite = new AbortSignal();
    var settle = function(reason) {
      if (composite.aborted) return;
      composite.aborted = true;
      composite.reason = reason;
      try { composite.dispatchEvent(new Event('abort')); }
      catch (e) { reportError(e); }
      if (typeof composite.onabort === 'function') {
        try { composite.onabort.call(composite, new Event('abort')); }
        catch (e) { reportError(e); }
      }
    };
    for (var i = 0; i < signals.length; ++i) {
      var sig = signals[i];
      if (sig.aborted) { settle(sig.reason); return composite; }
      sig.addEventListener('abort', function() { settle(sig.reason); }, { once: true });
    }
    return composite;
  }
};

var AbortController = class {
  constructor() {
    this.signal = new AbortSignal();
  }
  abort(reason) {
    var s = this.signal;
    if (s.aborted) return;
    s.aborted = true;
    s.reason = reason === undefined
      ? new DOMException('The operation was aborted', 'AbortError')
      : reason;
    try { s.dispatchEvent(new Event('abort')); }
    catch (e) { reportError(e); }
    if (typeof s.onabort === 'function') {
      try { s.onabort.call(s, new Event('abort')); }
      catch (e) { reportError(e); }
    }
  }
};
