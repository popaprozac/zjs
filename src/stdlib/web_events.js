// @ts-check
var __DOM_CODES = {
  IndexSizeError: 1, HierarchyRequestError: 3, WrongDocumentError: 4,
  InvalidCharacterError: 5, NoModificationAllowedError: 7,
  NotFoundError: 8, NotSupportedError: 9, InUseAttributeError: 10,
  InvalidStateError: 11, SyntaxError: 12, InvalidModificationError: 13,
  NamespaceError: 14, InvalidAccessError: 15, SecurityError: 18,
  NetworkError: 19, AbortError: 20, URLMismatchError: 21,
  QuotaExceededError: 22, TimeoutError: 23, InvalidNodeTypeError: 24,
  DataCloneError: 25,
};

var DOMException = class extends Error {
  constructor(message, name) {
    super(message || '');
    this.name = String(name === undefined ? 'Error' : name);
    this.code = __DOM_CODES[this.name] || 0;
  }
};

var Event = class {
  constructor(type, options) {
    options = options || {};
    this.type = String(type);
    this.bubbles = !!options.bubbles;
    this.cancelable = !!options.cancelable;
    this.composed = !!options.composed;
    this.target = null;
    this.currentTarget = null;
    this.defaultPrevented = false;
    this.timeStamp = performance.now();
    this.isTrusted = false;
    this.__sP = false;
    this.__sI = false;
  }
  preventDefault() { if (this.cancelable) this.defaultPrevented = true; }
  stopPropagation() { this.__sP = true; }
  stopImmediatePropagation() { this.__sP = true; this.__sI = true; }
};

var CustomEvent = class extends Event {
  constructor(type, options) {
    options = options || {};
    super(type, options);
    this.detail = options.detail === undefined ? null : options.detail;
  }
};

var EventTarget = class {
  constructor() {
    this.__lst = new Map();
  }
  addEventListener(type, listener, options) {
    if (typeof listener !== 'function') return;
    var t = String(type);
    var list = this.__lst.get(t);
    if (!list) { list = []; this.__lst.set(t, list); }
    var once = !!(options && options.once);
    for (var i = 0; i < list.length; ++i) {
      if (list[i].listener === listener && list[i].once === once) return;
    }
    list.push({ listener: listener, once: once });
  }
  removeEventListener(type, listener) {
    // Engine gap: Array.splice() doesn't mutate (#249). Rebuild
    // the list by filtering instead.
    var t = String(type);
    var list = this.__lst.get(t);
    if (!list) return;
    var out = [];
    for (var i = 0; i < list.length; ++i) {
      if (list[i].listener !== listener) out.push(list[i]);
    }
    this.__lst.set(t, out);
  }
  dispatchEvent(event) {
    if (!event || typeof event.type !== 'string') {
      throw new TypeError('dispatchEvent requires an Event');
    }
    event.target = this;
    event.currentTarget = this;
    var list = this.__lst.get(event.type);
    if (!list || list.length === 0) return !event.defaultPrevented;
    var snapshot = [];
    for (var i = 0; i < list.length; ++i) snapshot.push(list[i]);
    for (var i = 0; i < snapshot.length; ++i) {
      var entry = snapshot[i];
      try { entry.listener.call(this, event); }
      catch (e) { reportError(e); }
      if (entry.once) this.removeEventListener(event.type, entry.listener);
      if (event.__sI) break;
    }
    event.currentTarget = null;
    return !event.defaultPrevented;
  }
};
