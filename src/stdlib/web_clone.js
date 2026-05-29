// @ts-check
var __structuredCloneImpl = (function() {
  var TA_CLASSES;
  function getTAClasses() {
    if (TA_CLASSES) return TA_CLASSES;
    TA_CLASSES = [];
    var names = ['Uint8Array','Int8Array','Uint8ClampedArray',
                 'Uint16Array','Int16Array','Uint32Array','Int32Array',
                 'Float32Array','Float64Array'];
    for (var i = 0; i < names.length; ++i) {
      var c = globalThis[names[i]];
      if (c) TA_CLASSES.push(c);
    }
    return TA_CLASSES;
  }
  function isTypedArray(v) {
    var cs = getTAClasses();
    for (var i = 0; i < cs.length; ++i) {
      if (v instanceof cs[i]) return cs[i];
    }
    return null;
  }
  function clone(v, seen) {
    if (v === null) return null;
    var t = typeof v;
    if (t === 'undefined' || t === 'boolean' || t === 'number' || t === 'string' || t === 'bigint') return v;
    if (t === 'function') throw new DOMException('Function cannot be cloned', 'DataCloneError');
    if (t === 'symbol') throw new DOMException('Symbol cannot be cloned', 'DataCloneError');
    if (seen.has(v)) return seen.get(v);
    if (v instanceof Date) {
      var d = new Date(v.getTime()); seen.set(v, d); return d;
    }
    if (v instanceof RegExp) {
      var r = new RegExp(v.source, v.flags); seen.set(v, r); return r;
    }
    var TA = isTypedArray(v);
    if (TA) {
      var copy = new TA(v.length);
      for (var i = 0; i < v.length; ++i) copy[i] = v[i];
      seen.set(v, copy);
      return copy;
    }
    if (v instanceof Map) {
      var m = new Map(); seen.set(v, m);
      v.forEach(function(val, key) { m.set(clone(key, seen), clone(val, seen)); });
      return m;
    }
    if (v instanceof Set) {
      var s = new Set(); seen.set(v, s);
      v.forEach(function(val) { s.add(clone(val, seen)); });
      return s;
    }
    if (v instanceof Error) {
      var Ctor = /** @type {ErrorConstructor} */ (v.constructor || Error);
      var e = new Ctor(v.message); seen.set(v, e);
      if (v.name !== undefined) e.name = v.name;
      if (v.stack !== undefined) e.stack = v.stack;
      return e;
    }
    if (Array.isArray(v)) {
      var a = new Array(v.length); seen.set(v, a);
      for (var i = 0; i < v.length; ++i) a[i] = clone(v[i], seen);
      return a;
    }
    if (t === 'object') {
      var o = {}; seen.set(v, o);
      var keys = Object.keys(v);
      for (var i = 0; i < keys.length; ++i) o[keys[i]] = clone(v[keys[i]], seen);
      return o;
    }
    throw new DOMException('Value cannot be cloned', 'DataCloneError');
  }
  return function structuredClone(value, options) {
    return clone(value, new Map());
  };
})();
var structuredClone = __structuredCloneImpl;
