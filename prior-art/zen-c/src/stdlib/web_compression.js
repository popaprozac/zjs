// CompressionStream / DecompressionStream — WHATWG compression globals.
//
// Backed by the native one-shot __zjs_zlib codec. Because that codec is
// one-shot (no incremental zlib state across chunks), these buffer all
// written chunks and (de)compress the concatenation on flush. Correct
// for the dominant "pipe a whole body through" usage; not true chunked
// streaming. format ∈ "gzip" | "deflate" | "deflate-raw".
(function () {
  "use strict";
  if (typeof globalThis.TransformStream !== "function" || typeof globalThis.__zjs_zlib !== "function") return;

  function fmtCode(format) {
    if (format === "gzip") return 1;
    if (format === "deflate") return 0;
    if (format === "deflate-raw") return 2;
    return -1;
  }
  function concat(chunks, total) {
    const out = new Uint8Array(total);
    let off = 0;
    for (const c of chunks) { out.set(c, off); off += c.length; }
    return out;
  }
  function toU8(chunk) {
    if (chunk instanceof Uint8Array) return chunk;
    if (chunk instanceof ArrayBuffer) return new Uint8Array(chunk);
    if (typeof chunk === "string") return new TextEncoder().encode(chunk);
    return new Uint8Array(chunk);
  }

  function makeCodecStream(format, compress) {
    const fmt = fmtCode(format);
    if (fmt < 0) throw new TypeError("Unsupported " + (compress ? "compression" : "decompression") + " format: " + format);
    const chunks = [];
    let total = 0;
    const ts = new TransformStream({
      transform(chunk) { const u = toU8(chunk); chunks.push(u); total += u.length; },
      flush(controller) {
        const input = chunks.length === 1 ? chunks[0] : concat(chunks, total);
        const result = globalThis.__zjs_zlib(fmt, compress, input);
        if (result && result.length) controller.enqueue(result);
      },
    });
    return ts;
  }

  var CompressionStream = class CompressionStream {
    constructor(format) {
      const ts = makeCodecStream(format, true);
      this.readable = ts.readable;
      this.writable = ts.writable;
    }
  };
  var DecompressionStream = class DecompressionStream {
    constructor(format) {
      const ts = makeCodecStream(format, false);
      this.readable = ts.readable;
      this.writable = ts.writable;
    }
  };

  globalThis.CompressionStream = CompressionStream;
  globalThis.DecompressionStream = DecompressionStream;
})();
