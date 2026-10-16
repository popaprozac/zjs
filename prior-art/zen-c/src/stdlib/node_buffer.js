// node:buffer + global Buffer — a Uint8Array subclass.
//
// Buffer.prototype chains to Uint8Array.prototype, and Buffer.from /
// alloc / etc. set that prototype on a plain Uint8Array via
// Object.setPrototypeOf (the engine gives TAG_UINT8_ARRAY a per-instance
// proto; methods resolve through it — see object_set/property_get).
//
// Numeric read/write go byte-by-byte (TAG_UINT8_ARRAY owns its bytes and
// has no backing ArrayBuffer, so DataView-over-buffer isn't available);
// float/double borrow a scratch DataView. subarray aliases slice (copy)
// because true shared-memory views aren't representable yet.
(function () {
  "use strict";
  var U8 = Uint8Array;
  // BufProto is Buffer's own .prototype, re-parented to Uint8Array.prototype
  // (assigning Buffer.prototype = X doesn't stick on a closure, so we adopt
  // the existing object and set its [[Prototype]] instead).
  var BufProto;

  var enc = new TextEncoder();
  var dec = new TextDecoder();
  var scratch = new DataView(new ArrayBuffer(8));

  function normEnc(e) {
    if (e === undefined || e === null) return "utf8";
    e = ("" + e).toLowerCase();
    if (e === "utf-8") return "utf8";
    if (e === "ucs-2" || e === "utf16le" || e === "utf-16le") return "ucs2";
    if (e === "binary") return "latin1";
    return e;
  }
  function isEncoding(e) {
    switch (normEnc(e)) {
      case "utf8": case "hex": case "base64": case "base64url":
      case "latin1": case "ascii": case "ucs2": return true;
      default: return false;
    }
  }

  function bytesFromString(str, encoding) {
    var e = normEnc(encoding);
    str = "" + str;
    if (e === "utf8") return enc.encode(str);
    if (e === "ascii" || e === "latin1") {
      var a = new U8(str.length);
      for (var i = 0; i < str.length; i++) a[i] = str.charCodeAt(i) & 0xff;
      return a;
    }
    if (e === "hex") {
      var n = str.length >> 1, h = new U8(n);
      for (var j = 0; j < n; j++) {
        var b = parseInt(str.substr(j * 2, 2), 16);
        if (isNaN(b)) { h = h.slice(0, j); break; }
        h[j] = b;
      }
      return h;
    }
    if (e === "base64" || e === "base64url") {
      var s = str.replace(/[-_]/g, function (c) { return c === "-" ? "+" : "/"; })
                 .replace(/[^A-Za-z0-9+/]/g, "");
      while (s.length % 4) s += "=";
      var bin = atob(s);
      var u = new U8(bin.length);
      for (var k = 0; k < bin.length; k++) u[k] = bin.charCodeAt(k);
      return u;
    }
    if (e === "ucs2") {
      var m = new U8(str.length * 2);
      for (var p = 0; p < str.length; p++) {
        var cc = str.charCodeAt(p);
        m[p * 2] = cc & 0xff;
        m[p * 2 + 1] = (cc >> 8) & 0xff;
      }
      return m;
    }
    return enc.encode(str);
  }

  function bytesToString(u, encoding, start, end) {
    var e = normEnc(encoding);
    start = start | 0;
    if (end === undefined) end = u.length; else end = end | 0;
    if (start < 0) start = 0;
    if (end > u.length) end = u.length;
    if (end < start) end = start;
    var view = start === 0 && end === u.length ? u : u.slice(start, end);
    if (e === "utf8") return dec.decode(view);
    if (e === "ascii") {
      var r = "";
      for (var i = 0; i < view.length; i++) r += String.fromCharCode(view[i] & 0x7f);
      return r;
    }
    if (e === "latin1") {
      var r2 = "";
      for (var j = 0; j < view.length; j++) r2 += String.fromCharCode(view[j]);
      return r2;
    }
    if (e === "hex") {
      var h = "";
      for (var k = 0; k < view.length; k++) {
        var s = view[k].toString(16);
        h += s.length === 1 ? "0" + s : s;
      }
      return h;
    }
    if (e === "base64" || e === "base64url") {
      var bin = "";
      for (var p = 0; p < view.length; p++) bin += String.fromCharCode(view[p]);
      var b64 = btoa(bin);
      if (e === "base64url") b64 = b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
      return b64;
    }
    if (e === "ucs2") {
      var r3 = "";
      for (var q = 0; q + 1 < view.length; q += 2) r3 += String.fromCharCode(view[q] | (view[q + 1] << 8));
      return r3;
    }
    return dec.decode(view);
  }

  function brand(u) { Object.setPrototypeOf(u, BufProto); return u; }

  function Buffer(arg, encoding) {
    // Legacy callable form: Buffer(x) === Buffer.from(x) / alloc(n).
    if (typeof arg === "number") return Buffer.alloc(arg);
    return Buffer.from(arg, encoding);
  }

  // Adopt Buffer's own prototype object and chain it to Uint8Array.prototype.
  BufProto = Buffer.prototype;
  Object.setPrototypeOf(BufProto, U8.prototype);
  BufProto.constructor = Buffer;
  BufProto._isBuffer = true;

  Buffer.poolSize = 8192;

  Buffer.alloc = function (size, fill, encoding) {
    size = size | 0;
    var u = brand(new U8(size < 0 ? 0 : size));
    if (fill !== undefined && fill !== 0) u.fill(fill, encoding);
    return u;
  };
  Buffer.allocUnsafe = function (size) { return Buffer.alloc(size); };
  Buffer.allocUnsafeSlow = function (size) { return Buffer.alloc(size); };

  Buffer.from = function (value, encOrOffset, length) {
    if (typeof value === "string") return brand(bytesFromString(value, encOrOffset));
    if (value instanceof U8 || (value && value._isBuffer)) {
      var c = new U8(value.length);
      for (var i = 0; i < value.length; i++) c[i] = value[i];
      return brand(c);
    }
    if (value instanceof ArrayBuffer) {
      var off = encOrOffset | 0;
      var len = length === undefined ? value.byteLength - off : length | 0;
      var view = new U8(value, off, len);
      // new U8(ArrayBuffer,...) gives a view; copy into an owned buffer.
      var cc = new U8(view.length);
      for (var k = 0; k < view.length; k++) cc[k] = view[k];
      return brand(cc);
    }
    if (Array.isArray(value) || (value && typeof value.length === "number")) {
      var n = value.length | 0, a = new U8(n);
      for (var j = 0; j < n; j++) a[j] = value[j] & 0xff;
      return brand(a);
    }
    throw new TypeError("First argument must be a string, Buffer, ArrayBuffer, Array, or array-like object.");
  };

  Buffer.isBuffer = function (b) { return !!(b && b._isBuffer); };
  Buffer.isEncoding = function (e) { return isEncoding(e); };

  Buffer.byteLength = function (str, encoding) {
    if (typeof str !== "string") {
      if (str && typeof str.length === "number") return str.length;
      return 0;
    }
    return bytesFromString(str, encoding).length;
  };

  Buffer.concat = function (list, totalLength) {
    if (!Array.isArray(list)) throw new TypeError('"list" argument must be an Array of Buffers');
    var total = 0, i;
    if (totalLength === undefined) {
      for (i = 0; i < list.length; i++) total += list[i].length;
    } else total = totalLength | 0;
    var out = Buffer.alloc(total), pos = 0;
    for (i = 0; i < list.length && pos < total; i++) {
      var src = list[i];
      for (var j = 0; j < src.length && pos < total; j++) out[pos++] = src[j];
    }
    return out;
  };

  Buffer.compare = function (a, b) {
    var len = Math.min(a.length, b.length);
    for (var i = 0; i < len; i++) {
      if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
    }
    if (a.length < b.length) return -1;
    if (a.length > b.length) return 1;
    return 0;
  };

  // --- instance methods ---
  BufProto.toString = function (encoding, start, end) {
    return bytesToString(this, encoding, start, end);
  };
  BufProto.toJSON = function () {
    var data = new Array(this.length);
    for (var i = 0; i < this.length; i++) data[i] = this[i];
    return { type: "Buffer", data: data };
  };
  BufProto.equals = function (other) { return Buffer.compare(this, other) === 0; };
  BufProto.compare = function (other) { return Buffer.compare(this, other); };

  BufProto.slice = function (start, end) {
    var len = this.length;
    if (start === undefined) start = 0; else { start = start | 0; if (start < 0) start += len; if (start < 0) start = 0; }
    if (end === undefined) end = len; else { end = end | 0; if (end < 0) end += len; if (end > len) end = len; }
    if (end < start) end = start;
    var out = Buffer.alloc(end - start);
    for (var i = 0; i < out.length; i++) out[i] = this[start + i];
    return out;
  };
  BufProto.subarray = BufProto.slice;

  BufProto.write = function (string, offset, length, encoding) {
    if (typeof offset === "string") { encoding = offset; offset = 0; length = undefined; }
    else if (typeof length === "string") { encoding = length; length = undefined; }
    offset = offset | 0;
    var src = bytesFromString(string, encoding);
    var max = this.length - offset;
    var n = length === undefined ? src.length : Math.min(length | 0, src.length);
    if (n > max) n = max;
    for (var i = 0; i < n; i++) this[offset + i] = src[i];
    return n;
  };

  BufProto.copy = function (target, targetStart, sourceStart, sourceEnd) {
    targetStart = targetStart | 0;
    sourceStart = sourceStart | 0;
    if (sourceEnd === undefined) sourceEnd = this.length; else sourceEnd = sourceEnd | 0;
    var n = 0;
    for (var i = sourceStart; i < sourceEnd && targetStart + n < target.length; i++) {
      target[targetStart + n] = this[i];
      n++;
    }
    return n;
  };

  BufProto.fill = function (value, start, end, encoding) {
    if (typeof start === "string") { encoding = start; start = 0; end = this.length; }
    else if (typeof end === "string") { encoding = end; end = this.length; }
    start = start | 0;
    if (end === undefined) end = this.length; else end = end | 0;
    if (typeof value === "string") {
      var bytes = bytesFromString(value, encoding);
      if (bytes.length === 0) return this;
      for (var i = start; i < end; i++) this[i] = bytes[(i - start) % bytes.length];
      return this;
    }
    var v = (typeof value === "number") ? (value & 0xff) : 0;
    for (var j = start; j < end; j++) this[j] = v;
    return this;
  };

  BufProto.indexOf = function (value, byteOffset, encoding) {
    var needle;
    if (typeof value === "number") needle = U8.of(value & 0xff);
    else if (typeof value === "string") needle = bytesFromString(value, encoding);
    else needle = value;
    byteOffset = byteOffset | 0;
    if (byteOffset < 0) byteOffset = Math.max(0, this.length + byteOffset);
    if (needle.length === 0) return byteOffset <= this.length ? byteOffset : this.length;
    for (var i = byteOffset; i <= this.length - needle.length; i++) {
      var ok = true;
      for (var j = 0; j < needle.length; j++) { if (this[i + j] !== needle[j]) { ok = false; break; } }
      if (ok) return i;
    }
    return -1;
  };
  BufProto.includes = function (value, byteOffset, encoding) {
    return this.indexOf(value, byteOffset, encoding) !== -1;
  };

  // --- numeric accessors (byte-by-byte) ---
  function checkOff(buf, off, n) { if (off < 0 || off + n > buf.length) throw new RangeError("Index out of range"); }

  BufProto.readUInt8 = function (o) { o = o | 0; checkOff(this, o, 1); return this[o]; };
  BufProto.readInt8 = function (o) { var v = this.readUInt8(o); return v & 0x80 ? v - 0x100 : v; };
  BufProto.readUInt16LE = function (o) { o = o | 0; checkOff(this, o, 2); return this[o] | (this[o + 1] << 8); };
  BufProto.readUInt16BE = function (o) { o = o | 0; checkOff(this, o, 2); return (this[o] << 8) | this[o + 1]; };
  BufProto.readInt16LE = function (o) { var v = this.readUInt16LE(o); return v & 0x8000 ? v - 0x10000 : v; };
  BufProto.readInt16BE = function (o) { var v = this.readUInt16BE(o); return v & 0x8000 ? v - 0x10000 : v; };
  BufProto.readUInt32LE = function (o) { o = o | 0; checkOff(this, o, 4); return (this[o] | (this[o + 1] << 8) | (this[o + 2] << 16) | (this[o + 3] << 24)) >>> 0; };
  BufProto.readUInt32BE = function (o) { o = o | 0; checkOff(this, o, 4); return ((this[o] << 24) | (this[o + 1] << 16) | (this[o + 2] << 8) | this[o + 3]) >>> 0; };
  BufProto.readInt32LE = function (o) { return this.readUInt32LE(o) | 0; };
  BufProto.readInt32BE = function (o) { return this.readUInt32BE(o) | 0; };

  BufProto.writeUInt8 = function (v, o) { o = o | 0; checkOff(this, o, 1); this[o] = v & 0xff; return o + 1; };
  BufProto.writeInt8 = BufProto.writeUInt8;
  BufProto.writeUInt16LE = function (v, o) { o = o | 0; checkOff(this, o, 2); this[o] = v & 0xff; this[o + 1] = (v >>> 8) & 0xff; return o + 2; };
  BufProto.writeUInt16BE = function (v, o) { o = o | 0; checkOff(this, o, 2); this[o] = (v >>> 8) & 0xff; this[o + 1] = v & 0xff; return o + 2; };
  BufProto.writeInt16LE = BufProto.writeUInt16LE;
  BufProto.writeInt16BE = BufProto.writeUInt16BE;
  BufProto.writeUInt32LE = function (v, o) { o = o | 0; checkOff(this, o, 4); this[o] = v & 0xff; this[o + 1] = (v >>> 8) & 0xff; this[o + 2] = (v >>> 16) & 0xff; this[o + 3] = (v >>> 24) & 0xff; return o + 4; };
  BufProto.writeUInt32BE = function (v, o) { o = o | 0; checkOff(this, o, 4); this[o] = (v >>> 24) & 0xff; this[o + 1] = (v >>> 16) & 0xff; this[o + 2] = (v >>> 8) & 0xff; this[o + 3] = v & 0xff; return o + 4; };
  BufProto.writeInt32LE = BufProto.writeUInt32LE;
  BufProto.writeInt32BE = BufProto.writeUInt32BE;

  BufProto.readFloatLE = function (o) { o = o | 0; checkOff(this, o, 4); for (var i = 0; i < 4; i++) scratch.setUint8(i, this[o + i]); return scratch.getFloat32(0, true); };
  BufProto.readFloatBE = function (o) { o = o | 0; checkOff(this, o, 4); for (var i = 0; i < 4; i++) scratch.setUint8(i, this[o + i]); return scratch.getFloat32(0, false); };
  BufProto.readDoubleLE = function (o) { o = o | 0; checkOff(this, o, 8); for (var i = 0; i < 8; i++) scratch.setUint8(i, this[o + i]); return scratch.getFloat64(0, true); };
  BufProto.readDoubleBE = function (o) { o = o | 0; checkOff(this, o, 8); for (var i = 0; i < 8; i++) scratch.setUint8(i, this[o + i]); return scratch.getFloat64(0, false); };
  BufProto.writeFloatLE = function (v, o) { o = o | 0; checkOff(this, o, 4); scratch.setFloat32(0, v, true); for (var i = 0; i < 4; i++) this[o + i] = scratch.getUint8(i); return o + 4; };
  BufProto.writeFloatBE = function (v, o) { o = o | 0; checkOff(this, o, 4); scratch.setFloat32(0, v, false); for (var i = 0; i < 4; i++) this[o + i] = scratch.getUint8(i); return o + 4; };
  BufProto.writeDoubleLE = function (v, o) { o = o | 0; checkOff(this, o, 8); scratch.setFloat64(0, v, true); for (var i = 0; i < 8; i++) this[o + i] = scratch.getUint8(i); return o + 8; };
  BufProto.writeDoubleBE = function (v, o) { o = o | 0; checkOff(this, o, 8); scratch.setFloat64(0, v, false); for (var i = 0; i < 8; i++) this[o + i] = scratch.getUint8(i); return o + 8; };

  BufProto.swap16 = function () { for (var i = 0; i + 1 < this.length; i += 2) { var t = this[i]; this[i] = this[i + 1]; this[i + 1] = t; } return this; };
  BufProto.swap32 = function () { for (var i = 0; i + 3 < this.length; i += 4) { var a = this[i], b = this[i + 1]; this[i] = this[i + 3]; this[i + 1] = this[i + 2]; this[i + 2] = b; this[i + 3] = a; } return this; };

  globalThis.Buffer = Buffer;
  // Module exports object for `node:buffer`, read by populate_node_buffer.
  globalThis.__zjs_node_buffer = {
    Buffer: Buffer,
    SlowBuffer: Buffer,
    kMaxLength: 0x7fffffff,
    INSPECT_MAX_BYTES: 50,
    atob: globalThis.atob,
    btoa: globalThis.btoa,
    constants: { MAX_LENGTH: 0x7fffffff, MAX_STRING_LENGTH: 0x1fffffff }
  };
})();
