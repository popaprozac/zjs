// @ts-check
(function() {
  function bytesFromPart(p) {
    if (p instanceof Uint8Array) return p;
    if (p instanceof Blob)       return p.__bytes;
    if (typeof p === 'string')   return new TextEncoder().encode(p);
    // ArrayBuffer or view we can't introspect well: try .length /
    // .byteLength fallback. Anything else: throw.
    if (p && typeof p.length === 'number') {
      var u = new Uint8Array(p.length);
      for (var i = 0; i < p.length; ++i) u[i] = p[i] | 0;
      return u;
    }
    throw new TypeError('Blob part must be string/Blob/Uint8Array');
  }
  function concatBytes(parts) {
    var total = 0;
    for (var i = 0; i < parts.length; ++i) total += parts[i].length;
    var out = new Uint8Array(total);
    var off = 0;
    for (var i = 0; i < parts.length; ++i) {
      var p = parts[i];
      for (var j = 0; j < p.length; ++j) out[off + j] = p[j];
      off += p.length;
    }
    return out;
  }

  var Blob = class {
    constructor(parts, options) {
      options = options || {};
      parts = parts || [];
      var byteParts = [];
      for (var i = 0; i < parts.length; ++i) {
        byteParts.push(bytesFromPart(parts[i]));
      }
      this.__bytes = concatBytes(byteParts);
      this.size = this.__bytes.length;
      this.type = options.type ? String(options.type) : '';
    }
    slice(start, end, contentType) {
      var len = this.__bytes.length;
      var s = start === undefined ? 0 : (start | 0);
      var e = end === undefined ? len : (end | 0);
      if (s < 0) s = Math.max(0, len + s);
      if (e < 0) e = Math.max(0, len + e);
      s = Math.min(s, len);
      e = Math.min(e, len);
      if (e < s) e = s;
      var slice = new Uint8Array(e - s);
      for (var i = 0; i < e - s; ++i) slice[i] = this.__bytes[s + i];
      var b = new Blob([], { type: contentType || '' });
      b.__bytes = slice;
      b.size = slice.length;
      return b;
    }
    text() {
      return Promise.resolve(new TextDecoder().decode(this.__bytes));
    }
    arrayBuffer() {
      var copy = new Uint8Array(this.__bytes.length);
      for (var i = 0; i < this.__bytes.length; ++i) copy[i] = this.__bytes[i];
      return Promise.resolve(copy);
    }
    bytes() { return this.arrayBuffer(); }
  };

  var File = class extends Blob {
    constructor(parts, name, options) {
      options = options || {};
      super(parts, options);
      this.name = String(name);
      this.lastModified = options.lastModified !== undefined
        ? Number(options.lastModified)
        : Date.now();
    }
  };

  var FormData = class {
    constructor() {
      this.__entries = [];
    }
    append(name, value, filename) {
      this.__entries.push({
        name: String(name),
        value: this.__normalize(value, filename),
      });
    }
    set(name, value, filename) {
      var n = String(name);
      var v = this.__normalize(value, filename);
      var first = true;
      var out = [];
      for (var i = 0; i < this.__entries.length; ++i) {
        if (this.__entries[i].name === n) {
          if (first) { out.push({ name: n, value: v }); first = false; }
        } else {
          out.push(this.__entries[i]);
        }
      }
      if (first) out.push({ name: n, value: v });
      this.__entries = out;
    }
    delete(name) {
      var n = String(name);
      var out = [];
      for (var i = 0; i < this.__entries.length; ++i) {
        if (this.__entries[i].name !== n) out.push(this.__entries[i]);
      }
      this.__entries = out;
    }
    get(name) {
      var n = String(name);
      for (var i = 0; i < this.__entries.length; ++i) {
        if (this.__entries[i].name === n) return this.__entries[i].value;
      }
      return null;
    }
    getAll(name) {
      var n = String(name);
      var out = [];
      for (var i = 0; i < this.__entries.length; ++i) {
        if (this.__entries[i].name === n) out.push(this.__entries[i].value);
      }
      return out;
    }
    has(name) {
      var n = String(name);
      for (var i = 0; i < this.__entries.length; ++i) {
        if (this.__entries[i].name === n) return true;
      }
      return false;
    }
    __iter(project) {
      var entries = this.__entries;
      var i = 0;
      var it = {
        next: function() {
          if (i >= entries.length) return { value: undefined, done: true };
          var v = project(entries[i]); i = i + 1;
          return { value: v, done: false };
        },
      };
      it[Symbol.iterator] = function() { return this; };
      return it;
    }
    keys()    { return this.__iter(function(e) { return e.name; }); }
    values()  { return this.__iter(function(e) { return e.value; }); }
    entries() { return this.__iter(function(e) { return [e.name, e.value]; }); }
    [Symbol.iterator]() { return this.entries(); }
    forEach(cb, thisArg) {
      for (var i = 0; i < this.__entries.length; ++i) {
        cb.call(thisArg, this.__entries[i].value, this.__entries[i].name, this);
      }
    }
    __normalize(value, filename) {
      if (value instanceof Blob && !(value instanceof File)) {
        // Wrap as File with filename so multipart can name it.
        return new File([value], filename || 'blob',
                        { type: value.type, lastModified: Date.now() });
      }
      if (value instanceof File) return value;
      return String(value);
    }
  };

  globalThis.Blob = Blob;
  globalThis.File = File;
  globalThis.FormData = FormData;
})();
