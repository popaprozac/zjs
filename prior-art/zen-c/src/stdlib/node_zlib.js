// node:zlib — gzip / deflate / raw via the native __zjs_zlib one-shot
// codec (platform zlib). Sync forms plus Node's callback-async forms.
// Stream classes (createGzip etc.) are intentionally omitted for now —
// use CompressionStream or the *Sync forms.
//
// Output is a Buffer when the global Buffer is present, else a
// Uint8Array. Input accepts Buffer / Uint8Array / ArrayBuffer / string.

// Looked up at call time — a builtin module body may evaluate before the
// __zjs_zlib global is installed, so capturing it at module scope would
// pin undefined.
function zcodec() { return globalThis.__zjs_zlib; }

function asBuffer(u8) {
  if (globalThis.Buffer) return Buffer.from(u8);
  return u8;
}
function toInput(data) {
  if (typeof data === "string") return data;
  if (data instanceof Uint8Array) return data;
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  return new Uint8Array(data);
}
function level(opts) {
  return (opts && typeof opts.level === "number") ? opts.level : -1;
}

function makeSync(fmt, compress) {
  return function (data, opts) {
    const Z = zcodec();
    if (typeof Z !== "function") throw new Error("zlib unavailable on this platform");
    return asBuffer(Z(fmt, compress, toInput(data), level(opts)));
  };
}
// Node's async signature: fn(data[, opts], callback) → callback(err, result).
function makeAsync(syncFn) {
  return function (data, opts, cb) {
    if (typeof opts === "function") { cb = opts; opts = undefined; }
    queueMicrotask(() => {
      try { const r = syncFn(data, opts); cb(null, r); }
      catch (e) { cb(e); }
    });
  };
}

const gzipSync       = makeSync(1, true);
const gunzipSync     = makeSync(1, false);
const deflateSync    = makeSync(0, true);
const inflateSync    = makeSync(0, false);
const deflateRawSync = makeSync(2, true);
const inflateRawSync = makeSync(2, false);
// unzip auto-detects gzip vs zlib on decompress; our gzip codec path
// (windowBits 15+16) only reads gzip — use gunzip for gzip, inflate for
// zlib. unzipSync tries gzip then zlib.
function unzipSync(data, opts) {
  try { return gunzipSync(data, opts); } catch (e) { return inflateSync(data, opts); }
}

const gzip       = makeAsync(gzipSync);
const gunzip     = makeAsync(gunzipSync);
const deflate    = makeAsync(deflateSync);
const inflate    = makeAsync(inflateSync);
const deflateRaw = makeAsync(deflateRawSync);
const inflateRaw = makeAsync(inflateRawSync);
const unzip      = makeAsync(unzipSync);

const constants = {
  Z_NO_COMPRESSION: 0, Z_BEST_SPEED: 1, Z_BEST_COMPRESSION: 9,
  Z_DEFAULT_COMPRESSION: -1,
  Z_NO_FLUSH: 0, Z_FINISH: 4,
};

export {
  gzipSync, gunzipSync, deflateSync, inflateSync, deflateRawSync, inflateRawSync, unzipSync,
  gzip, gunzip, deflate, inflate, deflateRaw, inflateRaw, unzip,
  constants,
};
export default {
  gzipSync, gunzipSync, deflateSync, inflateSync, deflateRawSync, inflateRawSync, unzipSync,
  gzip, gunzip, deflate, inflate, deflateRaw, inflateRaw, unzip,
  constants,
};
